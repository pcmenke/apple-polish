import Foundation

/// What the iPhone sees of one media file. No file paths: `id` is an opaque stable hash.
public struct RemoteItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String  // "photo" | "video"
    public var size: Int64
    public var date: Date?
    public var conversation: String?
    public var sender: String?
    public var chatIdentifier: String?
    public var isGroup: Bool
    public var isReadable: Bool
    public var matchedBySize: Bool

    public var isLinked: Bool { conversation != nil }
    public var isVideo: Bool { kind == "video" }

    public init(id: String, name: String, kind: String, size: Int64, date: Date?, conversation: String?,
                sender: String?, chatIdentifier: String?, isGroup: Bool, isReadable: Bool, matchedBySize: Bool) {
        self.id = id; self.name = name; self.kind = kind; self.size = size; self.date = date
        self.conversation = conversation; self.sender = sender; self.chatIdentifier = chatIdentifier
        self.isGroup = isGroup; self.isReadable = isReadable; self.matchedBySize = matchedBySize
    }
}

public struct RemoteRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable { case list, thumbnail, trash }
    public var id: UInt32
    public var op: Op
    public var itemID: String?
    public var itemIDs: [String]?

    public init(id: UInt32, op: Op, itemID: String? = nil, itemIDs: [String]? = nil) {
        self.id = id; self.op = op; self.itemID = itemID; self.itemIDs = itemIDs
    }
}

public struct RemoteResponse: Codable, Sendable {
    public var id: UInt32
    public var error: String?
    public var items: [RemoteItem]?
    public var thumbnail: Data?
    public var trashed: Int?
    public var failed: Int?

    public init(id: UInt32, error: String? = nil, items: [RemoteItem]? = nil, thumbnail: Data? = nil,
                trashed: Int? = nil, failed: Int? = nil) {
        self.id = id; self.error = error; self.items = items; self.thumbnail = thumbnail
        self.trashed = trashed; self.failed = failed
    }
}

public enum Wire {
    public static let serviceType = "_applepolish._tcp"

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}

/// Length-prefixed frames: 4-byte big-endian length, then the payload.
public enum Framing {
    public static let maxFrame = 32 << 20

    public static func frame(_ payload: Data) -> Data {
        var out = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

public struct FrameDecoder {
    public struct TooLarge: Error {}
    private var buffer = Data()

    public init() {}

    /// Feed received bytes; returns every complete payload now available.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length <= Framing.maxFrame else { throw TooLarge() }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.subdata(in: 4 ..< 4 + length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}

/// Stable opaque id for a file path, so paths never leave the Mac.
public enum RemoteID {
    public static func make(path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325  // FNV-1a, 64-bit
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }
}
