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

    func testLocalLibraryQueryFiltersAndSorts() {
        let day = { (n: Double) in Date(timeIntervalSince1970: n * 86_400) }
        let assets = [
            LocalAssetInfo(id: "small-photo", isVideo: false, date: day(3), size: 2_000_000),
            LocalAssetInfo(id: "big-video", isVideo: true, duration: 90, date: day(1), size: 400_000_000),
            LocalAssetInfo(id: "shot", isVideo: false, isScreenshot: true, date: day(2), size: 500_000),
            LocalAssetInfo(id: "live", isVideo: false, isLivePhoto: true, date: day(4), size: 9_000_000),
            LocalAssetInfo(id: "unmeasured", isVideo: true, date: day(5), size: nil),
        ]
        XCTAssertEqual(LocalLibraryQuery.apply(assets, filter: .all, sort: .largest).map(\.id),
                       ["big-video", "live", "small-photo", "shot", "unmeasured"], "unmeasured sorts last")
        XCTAssertEqual(LocalLibraryQuery.apply(assets, filter: .videos, sort: .newest).map(\.id), ["unmeasured", "big-video"])
        XCTAssertEqual(LocalLibraryQuery.apply(assets, filter: .screenshots, sort: .largest).map(\.id), ["shot"])
        XCTAssertEqual(LocalLibraryQuery.apply(assets, filter: .livePhotos, sort: .oldest).map(\.id), ["live"])
        XCTAssertEqual(LocalLibraryQuery.apply(assets, filter: .all, sort: .oldest, minBytes: 5_000_000).map(\.id),
                       ["big-video", "live", "unmeasured"], "below-threshold assets are dropped, unmeasured kept")
        XCTAssertEqual(LocalLibraryQuery.totalBytes(assets), 411_500_000)
    }

    private func current(_ id: String, video: Bool = false, modified: Double? = 100) -> CurrentAsset {
        CurrentAsset(id: id, isVideo: video, isScreenshot: false, isLivePhoto: false, duration: video ? 5 : 0,
                     date: Date(timeIntervalSince1970: 500), modified: modified.map(Date.init(timeIntervalSince1970:)))
    }

    private func indexed(_ id: String, size: Int64, video: Bool = false, modified: Double? = 100) -> IndexedAsset {
        IndexedAsset(info: LocalAssetInfo(id: id, isVideo: video, date: Date(timeIntervalSince1970: 500), size: size),
                     modified: modified.map(Date.init(timeIntervalSince1970:)))
    }

    func testReconcileKeepsValidSizesAndFlagsOnlyNewOrChanged() {
        let cached = ["same": indexed("same", size: 111), "edited": indexed("edited", size: 222, modified: 100),
                      "gone": indexed("gone", size: 333)]
        let result = LocalIndexReconciler.reconcile(
            current: [current("same"), current("edited", modified: 999), current("new-photo"), current("new-video", video: true)],
            cached: cached)
        XCTAssertEqual(result.infos.map(\.id), ["same", "edited", "new-photo", "new-video"], "keeps PhotoKit order")
        XCTAssertEqual(result.infos[0].size, 111, "unchanged asset reuses its cached size")
        XCTAssertNil(result.infos[1].size, "edited asset must be measured again")
        XCTAssertEqual(result.toMeasure, ["new-video", "edited", "new-photo"], "videos first")
        XCTAssertEqual(result.vanished, ["gone"])
        let forced = LocalIndexReconciler.reconcile(current: [current("same")], cached: cached, forceMeasure: true)
        XCTAssertEqual(forced.toMeasure, ["same"])
        XCTAssertNil(forced.infos[0].size)
    }

    func testLocalIndexStorePersistsAcrossReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString).sqlite").path
        defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) } }
        do {
            let store = try LocalIndexStore(path: path)
            store.upsert([indexed("a", size: 10), indexed("b", size: 20, video: true, modified: nil),
                          IndexedAsset(info: LocalAssetInfo(id: "unmeasured", isVideo: false), modified: nil)])
            store.upsert([indexed("a", size: 11)])  // replaces
            XCTAssertEqual(store.count(), 2, "unmeasured assets are not stored")
        }
        let reopened = try LocalIndexStore(path: path)
        let all = reopened.loadAll()
        XCTAssertEqual(all["a"]?.info.size, 11)
        XCTAssertEqual(all["b"]?.info.isVideo, true)
        XCTAssertNil(all["b"]?.modified)
        XCTAssertEqual(all["a"]?.modified, Date(timeIntervalSince1970: 100))
        reopened.remove(ids: ["a"])
        XCTAssertEqual(reopened.loadAll().keys.sorted(), ["b"])
        reopened.removeAll()
        XCTAssertEqual(reopened.count(), 0)
    }

    func testPairingLinkRoundTrips() throws {
        let key = PairingKey.generate()
        let full = PairingLink(key: key, name: "Ada\u{2019}s MacBook Air", host: "Adas-MacBook-Air.local", port: 55714)
        XCTAssertEqual(PairingLink(url: full.url), full)
        XCTAssertEqual(PairingLink(string: " \(full.url.absoluteString)\n"), full, "tolerates scanner whitespace")
        let bare = PairingLink(key: key)
        XCTAssertEqual(PairingLink(url: bare.url), bare)
        XCTAssertNil(PairingLink(url: bare.url)?.port)
        XCTAssertTrue(full.url.absoluteString.hasPrefix("applepolish://pair?key="))
    }

    func testPairingLinkRejectsForeignAndMalformedInput() {
        let key = PairingKey.generate().display
        XCTAssertNil(PairingLink(string: "https://example.com/pair?key=\(key)"))
        XCTAssertNil(PairingLink(string: "applepolish://other?key=\(key)"))
        XCTAssertNil(PairingLink(string: "applepolish://pair?key=NOPE"))
        XCTAssertNil(PairingLink(string: "applepolish://pair"))
        XCTAssertNil(PairingLink(string: "hello world")?.port)
        XCTAssertNil(PairingLink(string: "applepolish://pair?key=\(key)&port=999999")?.port, "out-of-range port is ignored")
        XCTAssertNotNil(PairingLink(string: "applepolish://pair?key=\(key)&port=999999"))
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
