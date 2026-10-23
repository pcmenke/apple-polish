import Network
import XCTest
@testable import PolishRemote

final class PolishRemoteTests: XCTestCase {
    func testMessagesLinks() {
        XCTAssertEqual(MessagesLink.conversationURL(chatIdentifier: "+15551234567", isGroup: false)?.absoluteString, "sms:%2B15551234567")
        XCTAssertEqual(MessagesLink.conversationURL(chatIdentifier: "ada@example.com", isGroup: false)?.absoluteString, "imessage:ada@example.com")
        XCTAssertNil(MessagesLink.conversationURL(chatIdentifier: "chat123456789", isGroup: true), "groups cannot be addressed")
        XCTAssertNil(MessagesLink.conversationURL(chatIdentifier: "chatabcdef", isGroup: false), "not a phone or email")
        XCTAssertNil(MessagesLink.conversationURL(chatIdentifier: nil, isGroup: false))
    }

    func testFramingRoundTripsAcrossArbitraryChunks() throws {
        let a = Framing.frame(Data("hello".utf8)), b = Framing.frame(Data(repeating: 7, count: 70_000))
        let all = a + b
        var decoder = FrameDecoder()
        var out: [Data] = []
        for chunk in stride(from: 0, to: all.count, by: 1000) {
            out += try decoder.append(all.subdata(in: chunk ..< min(all.count, chunk + 1000)))
        }
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(String(decoding: out[0], as: UTF8.self), "hello")
        XCTAssertEqual(out[1].count, 70_000)
    }

    func testOversizedFrameIsRejected() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 1])))
    }

    func testPairingKeyDisplayAndParsing() throws {
        let key = PairingKey.generate()
        XCTAssertEqual(key.display.count, 39)  // 32 hex digits + 7 dashes
        XCTAssertEqual(PairingKey(string: key.display), key)
        XCTAssertEqual(PairingKey(string: "  " + key.display.lowercased() + "\n"), key)
        XCTAssertNil(PairingKey(string: "not a key"))
        XCTAssertNil(PairingKey(string: "ABCD-EF01"))
    }

    func testRemoteIDIsStableAndOpaque() {
        XCTAssertEqual(RemoteID.make(path: "/a/b.mov"), RemoteID.make(path: "/a/b.mov"))
        XCTAssertNotEqual(RemoteID.make(path: "/a/b.mov"), RemoteID.make(path: "/a/c.mov"))
        XCTAssertEqual(RemoteID.make(path: "/a/b.mov").count, 16)
    }

    private let sample = RemoteItem(id: "1", name: "x.mov", kind: "video", size: 42, date: Date(timeIntervalSince1970: 1000),
                                    conversation: "Ada", sender: "You", chatIdentifier: "+1555", isGroup: false,
                                    isReadable: true, matchedBySize: false)

    private func startServer(key: PairingKey) throws -> RemoteServer {
        let server = RemoteServer { [sample] request in
            switch request.op {
            case .list: return RemoteResponse(id: request.id, items: [sample])
            case .thumbnail: return RemoteResponse(id: request.id, thumbnail: Data([1, 2, 3]))
            case .trash: return RemoteResponse(id: request.id, trashed: request.itemIDs?.count ?? 0, failed: 0)
            }
        }
        try server.start(key: key, name: "test-\(UUID().uuidString.prefix(6))")
        return server
    }

    func testClientAndServerTalkOverTLSPSK() async throws {
        let key = PairingKey.generate()
        let server = try startServer(key: key)
        defer { server.stop() }
        var port: UInt16?
        for _ in 0 ..< 50 { if let p = server.port, p != 0 { port = p; break }; try await Task.sleep(for: .milliseconds(100)) }
        let client = RemoteClient(host: "127.0.0.1", port: try XCTUnwrap(port), key: key)
        try await client.connect()
        let list = try await client.request(.list)
        XCTAssertEqual(list.items, [sample])
        let thumb = try await client.request(.thumbnail, itemID: "1")
        XCTAssertEqual(thumb.thumbnail, Data([1, 2, 3]))
        let trash = try await client.request(.trash, itemIDs: ["1", "2"])
        XCTAssertEqual(trash.trashed, 2)
        // several requests in flight at once are matched to the right callers
        async let a = client.request(.thumbnail, itemID: "a")
        async let b = client.request(.list)
        let (ra, rb) = try await (a, b)
        XCTAssertNotNil(ra.thumbnail); XCTAssertNotNil(rb.items)
        client.close()
    }

    func testWrongKeyCannotConnect() async throws {
        let server = try startServer(key: PairingKey.generate())
        defer { server.stop() }
        var port: UInt16?
        for _ in 0 ..< 50 { if let p = server.port, p != 0 { port = p; break }; try await Task.sleep(for: .milliseconds(100)) }
        let intruder = RemoteClient(host: "127.0.0.1", port: try XCTUnwrap(port), key: PairingKey.generate())
        do {
            try await intruder.connect()
            XCTFail("a client with the wrong key must not complete the handshake")
        } catch {}
    }
}
