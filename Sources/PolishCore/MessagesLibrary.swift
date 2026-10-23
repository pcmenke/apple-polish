import Foundation
import SQLite3

public enum MessagesLibraryError: Error, LocalizedError, Equatable {
    /// Reading ~/Library/Messages is blocked until the app has Full Disk Access.
    case accessDenied(String)
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied(let detail): return "Can't read the Messages library (\(detail))."
        case .database(let detail): return "Messages database error: \(detail)"
        }
    }
}

/// Reads a private copy of `chat.db` and scans `Attachments/`. Never modifies or deletes anything.
public struct MessagesLibrary: Sendable {
    public let root: URL
    public let names: NameResolver

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Messages"),
                names: NameResolver = .empty) {
        self.root = root
        self.names = names
    }

    private static let query = """
        SELECT a.filename, a.mime_type, m.date, m.is_from_me, h.id,
               c.display_name, c.chat_identifier, c.style,
               (SELECT group_concat(h2.id, ',') FROM chat_handle_join chj
                  JOIN handle h2 ON h2.ROWID = chj.handle_id WHERE chj.chat_id = c.ROWID),
               a.total_bytes
        FROM attachment a
        JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
        JOIN message m ON m.ROWID = maj.message_id
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE a.filename IS NOT NULL
        """

    /// Photos and videos of at least `minBytes`, largest first: first those the database links
    /// to a conversation, then files on disk that no database row points at.
    public func load(minBytes: Int64 = 1_000_000) throws -> [MediaItem] {
        var (linked, missing) = try linkedItems(minBytes: minBytes)
        let known = Set(linked.map(\.id)).union(try allReferencedPaths())
        linked.append(contentsOf: unlinkedItems(excluding: known, minBytes: minBytes, bySize: missing))
        return linked.sorted { $0.size > $1.size }
    }

    /// Who a video message belongs to, for attributing files that exist on disk under a name
    /// the database does not know. Matching is by exact byte size, which is strong but not proof.
    struct MessageInfo: Sendable {
        let conversation: String
        let sender: String?
        let date: Date?
        let chatIdentifier: String?
        let isGroup: Bool
    }

    // MARK: Database

    private static func normalize(_ path: String) -> String {
        let expanded = path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-polish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for name in ["chat.db", "chat.db-wal", "chat.db-shm"] {
            let src = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) || name == "chat.db" else { continue }
            do { try FileManager.default.copyItem(at: src, to: tmp.appendingPathComponent(name)) }
            catch { throw MessagesLibraryError.accessDenied(error.localizedDescription) }
        }
        var db: OpaquePointer?
        let path = tmp.appendingPathComponent("chat.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MessagesLibraryError.database("could not open copy of chat.db")
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func rows(_ db: OpaquePointer, _ sql: String, _ each: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MessagesLibraryError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(stmt) }
    }

    private func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        sqlite3_column_text(stmt, col).map { String(cString: $0) }
    }

    private func linkedItems(minBytes: Int64) throws -> ([MediaItem], [Int64: MessageInfo]) {
        try withDatabase { db in
            var seen = Set<String>()
            var items: [MediaItem] = []
            var missing: [Int64: MessageInfo] = [:]
            try rows(db, Self.query) { stmt in
                guard let filename = text(stmt, 0) else { return }
                let path = Self.normalize(filename)
                let kind = MediaKind.classify(path: path, mimeType: text(stmt, 1))
                guard kind != .other, !seen.contains(path) else { return }
                let members = (text(stmt, 8) ?? "").split(separator: ",").map(String.init)
                let isGroup = sqlite3_column_int(stmt, 7) == 43
                let convo = Formatting.conversationName(
                    displayName: text(stmt, 5), identifier: text(stmt, 6).map(names.display),
                    members: members.map(names.display), isGroup: isGroup)
                let date = Formatting.date(fromMessageNanos: sqlite3_column_int64(stmt, 2))
                let sender = sqlite3_column_int(stmt, 3) != 0 ? "You" : text(stmt, 4).map(names.display)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = (attrs[.size] as? NSNumber)?.int64Value else {
                    let declared = sqlite3_column_int64(stmt, 9)
                    if kind == .video, declared >= minBytes, missing[declared] == nil {
                        missing[declared] = MessageInfo(conversation: convo, sender: sender, date: date,
                                                        chatIdentifier: text(stmt, 6), isGroup: isGroup)
                    }
                    return
                }
                guard size >= minBytes else { return }
                seen.insert(path)
                items.append(MediaItem(
                    url: URL(fileURLWithPath: path), kind: kind, size: size, date: date,
                    conversation: convo, sender: sender,
                    isReadable: kind != .video || FileSignature.looksLikeQuickTime(url: URL(fileURLWithPath: path)),
                    chatIdentifier: text(stmt, 6), isGroup: isGroup))
            }
            return (items, missing)
        }
    }

    private func allReferencedPaths() throws -> Set<String> {
        try withDatabase { db in
            var paths = Set<String>()
            try rows(db, "SELECT filename FROM attachment WHERE filename IS NOT NULL") { stmt in
                if let f = text(stmt, 0) { paths.insert(Self.normalize(f)) }
            }
            return paths
        }
    }

    // MARK: Disk

    private func unlinkedItems(excluding known: Set<String>, minBytes: Int64,
                               bySize: [Int64: MessageInfo]) -> [MediaItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root.appendingPathComponent("Attachments"),
            includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var items: [MediaItem] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.fileSize.map(Int64.init), size >= minBytes else { continue }
            let path = url.resolvingSymlinksInPath().path
            let kind = MediaKind.classify(path: path, mimeType: nil)
            guard kind != .other, !known.contains(path) else { continue }
            let owner = kind == .video ? bySize[size] : nil
            items.append(MediaItem(url: url, kind: kind, size: size, date: owner?.date ?? v.contentModificationDate,
                                   conversation: owner?.conversation, sender: owner?.sender,
                                   isReadable: kind != .video || FileSignature.looksLikeQuickTime(url: url),
                                   chatIdentifier: owner?.chatIdentifier, isGroup: owner?.isGroup ?? false,
                                   matchedBySize: owner != nil))
        }
        return items
    }
}
