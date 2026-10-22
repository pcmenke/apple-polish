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

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Messages")) {
        self.root = root
    }

    private static let query = """
        SELECT a.filename, a.mime_type, m.date, m.is_from_me, h.id,
               c.display_name, c.chat_identifier, c.style,
               (SELECT group_concat(h2.id, ',') FROM chat_handle_join chj
                  JOIN handle h2 ON h2.ROWID = chj.handle_id WHERE chj.chat_id = c.ROWID)
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
        var linked = try linkedItems(minBytes: minBytes)
        let known = Set(linked.map(\.id)).union(try allReferencedPaths())
        linked.append(contentsOf: unlinkedItems(excluding: known, minBytes: minBytes))
        return linked.sorted { $0.size > $1.size }
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

    private func linkedItems(minBytes: Int64) throws -> [MediaItem] {
        try withDatabase { db in
            var seen = Set<String>()
            var items: [MediaItem] = []
            try rows(db, Self.query) { stmt in
                guard let filename = text(stmt, 0) else { return }
                let path = Self.normalize(filename)
                let kind = MediaKind.classify(path: path, mimeType: text(stmt, 1))
                guard kind != .other, !seen.contains(path),
                      let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = (attrs[.size] as? NSNumber)?.int64Value, size >= minBytes
                else { return }
                seen.insert(path)
                let members = (text(stmt, 8) ?? "").split(separator: ",").map(String.init)
                let convo = Formatting.conversationName(
                    displayName: text(stmt, 5), identifier: text(stmt, 6),
                    members: members, isGroup: sqlite3_column_int(stmt, 7) == 43)
                items.append(MediaItem(
                    url: URL(fileURLWithPath: path), kind: kind, size: size,
                    date: Formatting.date(fromMessageNanos: sqlite3_column_int64(stmt, 2)),
                    conversation: convo,
                    sender: sqlite3_column_int(stmt, 3) != 0 ? "You" : text(stmt, 4)))
            }
            return items
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

    private func unlinkedItems(excluding known: Set<String>, minBytes: Int64) -> [MediaItem] {
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
            items.append(MediaItem(url: url, kind: kind, size: size, date: v.contentModificationDate,
                                   conversation: nil, sender: nil))
        }
        return items
    }
}
