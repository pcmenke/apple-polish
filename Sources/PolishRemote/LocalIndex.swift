import Foundation
import SQLite3

/// A measured asset as stored in the index. `modified` is PHAsset.modificationDate, used to
/// notice edits so a changed asset is measured again.
public struct IndexedAsset: Equatable, Sendable {
    public var info: LocalAssetInfo
    public var modified: Date?
    public init(info: LocalAssetInfo, modified: Date?) { self.info = info; self.modified = modified }
}

/// What PhotoKit says exists right now (cheap to read, no sizes).
public struct CurrentAsset: Sendable {
    public var id: String
    public var isVideo: Bool
    public var isScreenshot: Bool
    public var isLivePhoto: Bool
    public var duration: TimeInterval
    public var date: Date?
    public var modified: Date?

    public init(id: String, isVideo: Bool, isScreenshot: Bool, isLivePhoto: Bool,
                duration: TimeInterval, date: Date?, modified: Date?) {
        self.id = id; self.isVideo = isVideo; self.isScreenshot = isScreenshot; self.isLivePhoto = isLivePhoto
        self.duration = duration; self.date = date; self.modified = modified
    }
}

public enum LocalIndexReconciler {
    public struct Result: Sendable {
        /// Every current asset, in the order given, with cached sizes filled in where still valid.
        public var infos: [LocalAssetInfo]
        /// Ids that still need measuring, videos first.
        public var toMeasure: [String]
        /// Cached ids that no longer exist.
        public var vanished: [String]
    }

    public static func reconcile(current: [CurrentAsset], cached: [String: IndexedAsset],
                                 forceMeasure: Bool = false) -> Result {
        var infos: [LocalAssetInfo] = []
        var videos: [String] = [], others: [String] = []
        infos.reserveCapacity(current.count)
        for asset in current {
            var info = LocalAssetInfo(id: asset.id, isVideo: asset.isVideo, isScreenshot: asset.isScreenshot,
                                      isLivePhoto: asset.isLivePhoto, duration: asset.duration, date: asset.date)
            if !forceMeasure, let hit = cached[asset.id], hit.info.size != nil, sameInstant(hit.modified, asset.modified) {
                info.size = hit.info.size
            } else if asset.isVideo {
                videos.append(asset.id)
            } else {
                others.append(asset.id)
            }
            infos.append(info)
        }
        let currentIDs = Set(current.map(\.id))
        return Result(infos: infos, toMeasure: videos + others,
                      vanished: cached.keys.filter { !currentIDs.contains($0) })
    }

    private static func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < 0.001
        default: return false
        }
    }
}

/// SQLite-backed index of measured assets, so relaunches skip re-measuring the whole library.
/// Safe to delete: it is rebuilt on the next launch.
public final class LocalIndexStore: @unchecked Sendable {
    public struct OpenError: Error { public let message: String }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "applepolish.localindex")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw OpenError(message: String(cString: sqlite3_errmsg(db)))
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS assets(
              id TEXT PRIMARY KEY, size INTEGER NOT NULL, modified REAL,
              is_video INTEGER NOT NULL, is_screenshot INTEGER NOT NULL, is_live INTEGER NOT NULL,
              duration REAL NOT NULL, date REAL);
            PRAGMA user_version=1;
            """)
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(err)
            throw OpenError(message: message)
        }
    }

    public func loadAll() -> [String: IndexedAsset] {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id,size,modified,is_video,is_screenshot,is_live,duration,date FROM assets", -1, &stmt, nil) == SQLITE_OK
            else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var out: [String: IndexedAsset] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let modified = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                let date = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
                out[id] = IndexedAsset(
                    info: LocalAssetInfo(id: id, isVideo: sqlite3_column_int(stmt, 3) != 0,
                                         isScreenshot: sqlite3_column_int(stmt, 4) != 0,
                                         isLivePhoto: sqlite3_column_int(stmt, 5) != 0,
                                         duration: sqlite3_column_double(stmt, 6), date: date,
                                         size: sqlite3_column_int64(stmt, 1)),
                    modified: modified)
            }
            return out
        }
    }

    public func count() -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM assets", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    /// Inserts or replaces measured assets in one transaction. Unmeasured assets are ignored.
    public func upsert(_ rows: [IndexedAsset]) {
        queue.sync {
            try? exec("BEGIN")
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO assets(id,size,modified,is_video,is_screenshot,is_live,duration,date) VALUES(?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { try? exec("ROLLBACK"); return }
            defer { sqlite3_finalize(stmt) }
            for row in rows {
                guard let size = row.info.size else { continue }
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, row.info.id, -1, Self.transient)
                sqlite3_bind_int64(stmt, 2, size)
                if let m = row.modified { sqlite3_bind_double(stmt, 3, m.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 3) }
                sqlite3_bind_int(stmt, 4, row.info.isVideo ? 1 : 0)
                sqlite3_bind_int(stmt, 5, row.info.isScreenshot ? 1 : 0)
                sqlite3_bind_int(stmt, 6, row.info.isLivePhoto ? 1 : 0)
                sqlite3_bind_double(stmt, 7, row.info.duration)
                if let d = row.info.date { sqlite3_bind_double(stmt, 8, d.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 8) }
                sqlite3_step(stmt)
            }
            try? exec("COMMIT")
        }
    }

    public func remove(ids: [String]) {
        queue.sync {
            try? exec("BEGIN")
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM assets WHERE id=?", -1, &stmt, nil) == SQLITE_OK {
                for id in ids {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, id, -1, Self.transient)
                    sqlite3_step(stmt)
                }
            }
            sqlite3_finalize(stmt)
            try? exec("COMMIT")
        }
    }

    public func removeAll() { queue.sync { try? exec("DELETE FROM assets") } }
}
