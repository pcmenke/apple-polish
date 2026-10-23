import Foundation

/// What the Mac's QR code encodes: `applepolish://pair?key=…&name=…&host=…&port=…`.
/// The key is the secret; name/host/port only tell the phone where to connect.
public struct PairingLink: Equatable, Sendable {
    public static let scheme = "applepolish"

    public var key: PairingKey
    public var name: String?
    public var host: String?
    public var port: UInt16?

    public init(key: PairingKey, name: String? = nil, host: String? = nil, port: UInt16? = nil) {
        self.key = key; self.name = name; self.host = host; self.port = port
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "key", value: key.display)]
            + [("name", name), ("host", host), ("port", port.map(String.init))]
                .compactMap { pair in pair.1.map { URLQueryItem(name: pair.0, value: $0) } }
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let rawKey = items.first(where: { $0.name == "key" })?.value,
              let key = PairingKey(string: rawKey) else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        self.init(key: key, name: value("name"), host: value("host"), port: value("port").flatMap { UInt16($0) })
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }
}
