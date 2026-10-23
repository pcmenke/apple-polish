import Network
import PolishRemote
import UIKit

@MainActor
final class ViewerModel: ObservableObject {
    enum State: Equatable { case needsKey, disconnected, connecting, connected }

    @Published private(set) var state = State.needsKey
    @Published private(set) var items: [RemoteItem] = []
    @Published private(set) var macs: [DiscoveredMac] = []
    @Published var message: String?

    let thumbnails = RemoteThumbnails()
    private var key: PairingKey?
    /// A scanned link whose Mac wasn't reachable yet; connects as soon as Bonjour finds it.
    private var pendingMacName: String?
    private var client: RemoteClient?
    private let browser = MacBrowser()
    private static let keyAccount = "pairing-key"
    private static let hostDefault = "lastManualHost"

    init() {
        if let saved = KeychainStore.load(account: Self.keyAccount).flatMap(PairingKey.init(string:)) {
            key = saved
            state = .disconnected
        }
        browser.onChange = { [weak self] macs in
            Task { @MainActor in
                self?.macs = macs
                self?.connectPendingMacIfFound()
            }
        }
        browser.start()
    }

    var lastManualHost: String { UserDefaults.standard.string(forKey: Self.hostDefault) ?? "" }

    func pair(with text: String) -> Bool {
        guard let parsed = PairingKey(string: text) else { message = "That doesn't look like a pairing key."; return false }
        KeychainStore.save(parsed.display, account: Self.keyAccount)
        key = parsed
        state = .disconnected
        message = nil
        return true
    }

    /// Pairs from a scanned or tapped `applepolish://pair` link and connects straight away.
    @discardableResult
    func handle(link: PairingLink) -> Bool {
        disconnect()
        KeychainStore.save(link.key.display, account: Self.keyAccount)
        key = link.key
        state = .disconnected
        message = nil
        Task {
            if let host = link.host, let port = link.port, await connectClient(host: host, port: port) { return }
            if let name = link.name, let mac = macs.first(where: { $0.name == name }) { await connect(to: mac); return }
            pendingMacName = link.name
            message = "Paired. Couldn't reach the Mac yet; make sure Share to iPhone is on and you're on the same network."
        }
        return true
    }

    func handle(url: URL) {
        guard let link = PairingLink(url: url) else { return }
        handle(link: link)
    }

    private func connectPendingMacIfFound() {
        guard let name = pendingMacName, state != .connected, state != .connecting,
              let mac = macs.first(where: { $0.name == name }) else { return }
        pendingMacName = nil
        Task { await connect(to: mac) }
    }

    func forgetPairing() {
        disconnect()
        KeychainStore.delete(account: Self.keyAccount)
        key = nil
        state = .needsKey
    }

    func connect(to mac: DiscoveredMac) async { _ = await connect(RemoteClient(endpoint: mac.endpoint, key: key!)) }

    func connect(host: String, port: UInt16) async { _ = await connectClient(host: host, port: port) }

    @discardableResult
    private func connectClient(host: String, port: UInt16) async -> Bool {
        guard let key, let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        UserDefaults.standard.set(host, forKey: Self.hostDefault)
        return await connect(RemoteClient(endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort), key: key))
    }

    @discardableResult
    private func connect(_ client: RemoteClient) async -> Bool {
        guard key != nil else { return false }
        state = .connecting
        message = nil
        do {
            try await client.connect()
            self.client = client
            await thumbnails.use(client)
            state = .connected
            await reload()
            return true
        } catch {
            state = .disconnected
            message = "\(error.localizedDescription) Check that sharing is on and the key matches."
            return false
        }
    }

    func disconnect() {
        client?.close()
        client = nil
        items = []
        if key != nil { state = .disconnected }
        Task { await thumbnails.use(nil) }
    }

    func reload() async {
        guard let client else { return }
        do {
            items = try await client.request(.list).items ?? []
        } catch {
            message = error.localizedDescription
            state = .disconnected
        }
    }

    /// Asks the Mac to move these files to its Trash (recoverable there).
    func trashOnMac(_ ids: [String]) async {
        guard let client else { return }
        do {
            let response = try await client.request(.trash, itemIDs: ids)
            let moved = response.trashed ?? 0
            message = "Moved \(moved) file\(moved == 1 ? "" : "s") to the Mac's Trash." +
                ((response.failed ?? 0) > 0 ? " \(response.failed!) could not be moved." : "")
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    func openConversation(_ item: RemoteItem) {
        let url = MessagesLink.conversationURL(chatIdentifier: item.chatIdentifier, isGroup: item.isGroup)
            ?? URL(string: "sms:")!
        UIApplication.shared.open(url)
    }
}
