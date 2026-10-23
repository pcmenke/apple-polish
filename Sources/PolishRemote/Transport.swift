import Foundation
import Network

public enum RemoteError: Error, LocalizedError {
    case notConnected, connectionFailed(String), badResponse, remote(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the Mac."
        case .connectionFailed(let why): return "Could not connect: \(why)"
        case .badResponse: return "The Mac sent a response this app could not read."
        case .remote(let why): return why
        }
    }
}

enum RemoteTLS {
    /// TLS 1.2 with a pre-shared key: no certificates, and a peer without the key cannot complete
    /// the handshake. Same construction as Apple's Network.framework PSK sample.
    static func parameters(key: PairingKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let keyData = key.bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("applepolish".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, keyData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}

// MARK: Server (runs inside the Mac app)

public final class RemoteServer: @unchecked Sendable {
    public typealias Handler = @Sendable (RemoteRequest) async -> RemoteResponse

    private let queue = DispatchQueue(label: "applepolish.remote.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let handler: Handler
    public var onStateChange: (@Sendable (String) -> Void)?

    public init(handler: @escaping Handler) { self.handler = handler }

    /// Starts listening (port 0 = pick one) and advertises over Bonjour as `name`.
    public func start(key: PairingKey, name: String, port: UInt16 = 0) throws {
        let listener = try NWListener(
            using: RemoteTLS.parameters(key: key),
            on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: name, type: Wire.serviceType)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: self?.onStateChange?("Sharing on port \(listener?.port?.rawValue ?? 0)")
            case .failed(let error): self?.onStateChange?("Sharing failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
    }

    public var port: UInt16? { listener?.port?.rawValue }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.sync { connections.values.forEach { $0.cancel() }; connections.removeAll() }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.connections[id] = nil }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, decoder: FrameDecoder())
    }

    private func receive(on connection: NWConnection, decoder: FrameDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var decoder = decoder
            if let data, !data.isEmpty {
                guard let frames = try? decoder.append(data) else { connection.cancel(); return }
                for payload in frames { self.handle(payload, on: connection) }
            }
            if error != nil || done { connection.cancel(); return }
            self.receive(on: connection, decoder: decoder)
        }
    }

    private func handle(_ payload: Data, on connection: NWConnection) {
        guard let request = try? Wire.decode(RemoteRequest.self, from: payload) else { return }
        Task { [handler] in
            let response = await handler(request)
            guard let body = try? Wire.encode(response) else { return }
            connection.send(content: Framing.frame(body), completion: .contentProcessed { _ in })
        }
    }
}

// MARK: Client (runs in the iPhone viewer)

public final class RemoteClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "applepolish.remote.client")
    private let connection: NWConnection
    private var pending: [UInt32: CheckedContinuation<RemoteResponse, Error>] = [:]
    private var nextID: UInt32 = 1
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var isReady = false

    public init(endpoint: NWEndpoint, key: PairingKey) {
        connection = NWConnection(to: endpoint, using: RemoteTLS.parameters(key: key))
    }

    public convenience init(host: String, port: UInt16, key: PairingKey) {
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), key: key)
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connectContinuation = cont
                self.connection.stateUpdateHandler = { [weak self] state in self?.queue.async { self?.stateChanged(state) } }
                self.connection.start(queue: self.queue)
            }
        }
        receive(decoder: FrameDecoder())
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            connectContinuation?.resume()
            connectContinuation = nil
        case .failed(let error):
            fail(RemoteError.connectionFailed("\(error)"))
        case .waiting(let error):
            // Wrong key or unreachable Mac: the handshake keeps retrying, so surface it now.
            fail(RemoteError.connectionFailed("\(error)"))
        case .cancelled:
            fail(RemoteError.notConnected)
        default: break
        }
    }

    private func fail(_ error: Error) {
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        isReady = false
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
        connection.cancel()
    }

    private func receive(decoder: FrameDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var decoder = decoder
            if let data, !data.isEmpty {
                guard let frames = try? decoder.append(data) else { self.queue.async { self.fail(RemoteError.badResponse) }; return }
                for payload in frames {
                    guard let response = try? Wire.decode(RemoteResponse.self, from: payload) else { continue }
                    self.queue.async { self.pending.removeValue(forKey: response.id)?.resume(returning: response) }
                }
            }
            if error != nil || done { self.queue.async { self.fail(RemoteError.notConnected) }; return }
            self.receive(decoder: decoder)
        }
    }

    public func request(_ op: RemoteRequest.Op, itemID: String? = nil, itemIDs: [String]? = nil) async throws -> RemoteResponse {
        let response: RemoteResponse = try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.isReady else { cont.resume(throwing: RemoteError.notConnected); return }
                let id = self.nextID
                self.nextID &+= 1
                guard let body = try? Wire.encode(RemoteRequest(id: id, op: op, itemID: itemID, itemIDs: itemIDs)) else {
                    cont.resume(throwing: RemoteError.badResponse); return
                }
                self.pending[id] = cont
                self.connection.send(content: Framing.frame(body), completion: .contentProcessed { error in
                    if let error { self.queue.async { self.pending.removeValue(forKey: id)?.resume(throwing: error) } }
                })
            }
        }
        if let message = response.error { throw RemoteError.remote(message) }
        return response
    }

    public func close() { queue.async { self.fail(RemoteError.notConnected) } }
}

// MARK: Discovery (iPhone side)

public struct DiscoveredMac: Identifiable, Hashable, @unchecked Sendable {
    public var id: String { name }
    public let name: String
    public let endpoint: NWEndpoint
}

public final class MacBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    public var onChange: (@Sendable ([DiscoveredMac]) -> Void)?

    public init() {}

    public func start() {
        let browser = NWBrowser(for: .bonjour(type: Wire.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { result -> DiscoveredMac? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredMac(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            self?.onChange?(macs)
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() { browser?.cancel(); browser = nil }
}
