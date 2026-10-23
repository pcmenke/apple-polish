import AppKit
import PolishCore
import PolishRemote

/// Optional LAN server so the iPhone viewer can browse this Mac's media list and thumbnails.
/// Off by default; the pairing key lives in the Keychain; peers without the key cannot connect.
@MainActor
final class RemoteHost: ObservableObject {
    @Published private(set) var isSharing = false
    @Published private(set) var status = "Sharing is off"
    @Published private(set) var key: PairingKey
    @Published private(set) var port: UInt16?

    private static let account = "pairing-key"
    private static let enabledDefault = "shareToiPhone"
    private let store: MediaStore
    private var server: RemoteServer?
    private var index: [String: MediaItem] = [:]
    private var indexedVersion = -1

    init(store: MediaStore) {
        self.store = store
        if let saved = KeychainStore.load(account: Self.account).flatMap(PairingKey.init(string:)) {
            key = saved
        } else {
            let fresh = PairingKey.generate()
            KeychainStore.save(fresh.display, account: Self.account)
            key = fresh
        }
        if UserDefaults.standard.bool(forKey: Self.enabledDefault) { setSharing(true) }
    }

    var hostAddress: String { ProcessInfo.processInfo.hostName }

    /// What the QR code encodes. Includes the port once the listener is up.
    var pairingLink: PairingLink {
        PairingLink(key: key, name: Host.current().localizedName, host: hostAddress, port: port)
    }

    func setSharing(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledDefault)
        server?.stop()
        server = nil
        port = nil
        guard on else { isSharing = false; status = "Sharing is off"; return }
        let server = RemoteServer { [weak self] request in
            guard let self else { return RemoteResponse(id: request.id, error: "Mac app is closing") }
            return await self.respond(to: request)
        }
        server.onStateChange = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                self.status = text
                self.port = self.server?.port
            }
        }
        do {
            try server.start(key: key, name: Host.current().localizedName ?? "Mac")
            self.server = server
            isSharing = true
            status = "Starting…"
        } catch {
            isSharing = false
            status = "Could not start sharing: \(error.localizedDescription)"
        }
    }

    func regenerateKey() {
        key = .generate()
        KeychainStore.save(key.display, account: Self.account)
        if isSharing { setSharing(true) }  // drops existing phones; they must re-pair
    }

    func copyKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.display, forType: .string)
    }

    // MARK: Requests

    private func refreshIndex() {
        guard indexedVersion != store.version else { return }
        index = Dictionary(store.items.map { (RemoteID.make(path: $0.url.path), $0) }, uniquingKeysWith: { a, _ in a })
        indexedVersion = store.version
    }

    private func respond(to request: RemoteRequest) async -> RemoteResponse {
        refreshIndex()
        switch request.op {
        case .list:
            let items = index.map { id, item in
                RemoteItem(id: id, name: item.name, kind: item.kind.rawValue, size: item.size, date: item.date,
                           conversation: item.conversation, sender: item.sender, chatIdentifier: item.chatIdentifier,
                           isGroup: item.isGroup, isReadable: item.isReadable, matchedBySize: item.matchedBySize)
            }.sorted { $0.size > $1.size }
            return RemoteResponse(id: request.id, items: items)
        case .thumbnail:
            guard let id = request.itemID, let item = index[id] else {
                return RemoteResponse(id: request.id, error: "Unknown item")
            }
            guard let data = await ThumbnailService.shared.jpegData(for: item) else {
                return RemoteResponse(id: request.id, error: "No preview available")
            }
            return RemoteResponse(id: request.id, thumbnail: data)
        case .trash:
            let doomed = (request.itemIDs ?? []).compactMap { index[$0] }
            let outcome = await store.trashAndReport(doomed)
            return RemoteResponse(id: request.id, trashed: outcome.done, failed: outcome.failed)
        }
    }
}
