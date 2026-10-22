import SQLite3
import XCTest
@testable import PolishCore

final class PolishCoreTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(MediaKind.classify(path: "/a/IMG_1.MOV", mimeType: nil), .video)
        XCTAssertEqual(MediaKind.classify(path: "/a/IMG_1.HEIC", mimeType: nil), .photo)
        XCTAssertEqual(MediaKind.classify(path: "/a/x.bin", mimeType: "video/quicktime"), .video)
        XCTAssertEqual(MediaKind.classify(path: "/a/x.pluginpayloadattachment", mimeType: nil), .other)
    }

    func testMessageDateIsNanosecondsSince2001() {
        XCTAssertNil(Formatting.date(fromMessageNanos: 0))
        let date = Formatting.date(fromMessageNanos: 86_400 * 1_000_000_000)
        XCTAssertEqual(date, Date(timeIntervalSinceReferenceDate: 86_400))
    }

    func testConversationName() {
        XCTAssertEqual(Formatting.conversationName(displayName: "Family", identifier: "x", members: [], isGroup: true), "Family")
        XCTAssertEqual(Formatting.conversationName(displayName: nil, identifier: "+15551234567", members: [], isGroup: false), "+15551234567")
        XCTAssertEqual(Formatting.conversationName(displayName: "", identifier: "c", members: ["a", "b", "c", "d", "e", "f"], isGroup: true), "a, b, c, d +2")
        XCTAssertEqual(Formatting.conversationName(displayName: nil, identifier: nil, members: [], isGroup: false), "Unknown conversation")
    }

    func testLoadLinksConversationsAndFindsUnlinkedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("polish-test-\(UUID().uuidString)").resolvingSymlinksInPath()
        let att = root.appendingPathComponent("Attachments/aa/bb/GUID")
        try FileManager.default.createDirectory(at: att, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func write(_ name: String, megabytes: Int) throws -> String {
            let url = att.appendingPathComponent(name)
            try Data(count: megabytes * 1_000_000).write(to: url)
            return url.path
        }
        let linkedVideo = try write("clip.mov", megabytes: 2)
        let linkedTiny = try write("tiny.heic", megabytes: 0)
        let orphanVideo = try write("loose.mov", megabytes: 3)
        _ = try write("sticker.pluginpayloadattachment", megabytes: 2)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("chat.db").path, &db), SQLITE_OK)
        let ns = 86_400 * 1_000_000_000
        let sql = """
            CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY, filename TEXT, mime_type TEXT);
            CREATE TABLE message(ROWID INTEGER PRIMARY KEY, date INTEGER, is_from_me INTEGER, handle_id INTEGER);
            CREATE TABLE message_attachment_join(message_id INTEGER, attachment_id INTEGER);
            CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, display_name TEXT, chat_identifier TEXT, style INTEGER);
            CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
            CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat_handle_join(chat_id INTEGER, handle_id INTEGER);
            INSERT INTO handle VALUES (1, '+15551234567');
            INSERT INTO chat VALUES (1, NULL, '+15551234567', 45);
            INSERT INTO message VALUES (1, \(ns), 0, 1);
            INSERT INTO attachment VALUES (1, '\(linkedVideo)', 'video/quicktime');
            INSERT INTO attachment VALUES (2, '\(linkedTiny)', 'image/heic');
            INSERT INTO attachment VALUES (3, '/nonexistent/gone.mov', 'video/quicktime');
            INSERT INTO message_attachment_join VALUES (1, 1), (1, 2), (1, 3);
            INSERT INTO chat_message_join VALUES (1, 1);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let items = try MessagesLibrary(root: root).load(minBytes: 1_000_000)
        XCTAssertEqual(items.map(\.name), ["loose.mov", "clip.mov"], "largest first; tiny, missing and non-media files skipped")
        XCTAssertEqual(items[0].url.resolvingSymlinksInPath().path, orphanVideo)
        XCTAssertFalse(items[0].isLinked)
        XCTAssertTrue(items[1].isLinked)
        XCTAssertEqual(items[1].conversation, "+15551234567")
        XCTAssertEqual(items[1].sender, "+15551234567")
        XCTAssertEqual(items[1].date, Date(timeIntervalSinceReferenceDate: 86_400))
    }

    func testMissingLibraryReportsAccessDenied() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertThrowsError(try MessagesLibrary(root: missing).load()) { error in
            guard case MessagesLibraryError.accessDenied = error else { return XCTFail("\(error)") }
        }
    }
}
