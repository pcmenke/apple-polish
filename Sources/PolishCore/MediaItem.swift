import Foundation

public enum MediaKind: String, Sendable, CaseIterable {
    case photo, video, other

    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "avi"]
    private static let photoExtensions: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "png", "gif", "webp", "tiff", "tif",
    ]

    public static func classify(path: String, mimeType: String?) -> MediaKind {
        let ext = (path as NSString).pathExtension.lowercased()
        let mime = mimeType ?? ""
        if mime.hasPrefix("video") || videoExtensions.contains(ext) { return .video }
        if mime.hasPrefix("image") || photoExtensions.contains(ext) { return .photo }
        return .other
    }
}

/// One attachment file on disk. `conversation == nil` means the Messages database has
/// no row pointing at this file (see `MessagesLibrary`).
public struct MediaItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let kind: MediaKind
    public let size: Int64
    public let date: Date?
    public let conversation: String?
    public let sender: String?
    /// False for a video whose first bytes are not a QuickTime/MP4 container (random or
    /// encrypted data). Such files can never be thumbnailed or played.
    public let isReadable: Bool
    /// The Messages `chat_identifier`: a phone number or email for 1:1 chats, an opaque id for groups.
    public let chatIdentifier: String?
    public let isGroup: Bool
    /// True when the conversation was inferred from an exact file-size match with a video message
    /// whose own file is missing, rather than from a database path.
    public let matchedBySize: Bool

    public var isLinked: Bool { conversation != nil }
    public var name: String { url.lastPathComponent }

    public init(url: URL, kind: MediaKind, size: Int64, date: Date?,
                conversation: String?, sender: String?, isReadable: Bool = true,
                chatIdentifier: String? = nil, isGroup: Bool = false, matchedBySize: Bool = false) {
        self.url = url
        self.kind = kind
        self.size = size
        self.date = date
        self.conversation = conversation
        self.sender = sender
        self.isReadable = isReadable
        self.chatIdentifier = chatIdentifier
        self.isGroup = isGroup
        self.matchedBySize = matchedBySize
    }
}

public enum Formatting {
    public static func bytes(_ count: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: count)
    }

    /// `message.date` is nanoseconds since 2001-01-01, which is Foundation's reference date.
    public static func date(fromMessageNanos nanos: Int64) -> Date? {
        nanos == 0 ? nil : Date(timeIntervalSinceReferenceDate: Double(nanos) / 1e9)
    }

    public static func conversationName(displayName: String?, identifier: String?,
                                        members: [String], isGroup: Bool) -> String {
        if let displayName, !displayName.isEmpty { return displayName }
        if isGroup, !members.isEmpty {
            let shown = members.prefix(4).joined(separator: ", ")
            return members.count > 4 ? "\(shown) +\(members.count - 4)" : shown
        }
        if let identifier, !identifier.isEmpty { return identifier }
        return "Unknown conversation"
    }
}

public enum FileSignature {
    private static let containerAtoms: Set<String> = [
        "ftyp", "moov", "mdat", "wide", "free", "skip", "pnot", "junk",
    ]

    /// True if bytes 4..<8 name a known QuickTime/MP4 top-level atom.
    public static func looksLikeQuickTime(header: Data) -> Bool {
        guard header.count >= 8 else { return false }
        let tag = String(decoding: header[header.startIndex + 4 ..< header.startIndex + 8], as: UTF8.self)
        return containerAtoms.contains(tag)
    }

    public static func looksLikeQuickTime(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return looksLikeQuickTime(header: (try? handle.read(upToCount: 12)) ?? Data())
    }
}
