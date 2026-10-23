import Foundation

/// What the iPhone knows about one asset in its own Photos library (no PhotoKit types, so the
/// filtering and sorting is testable on the Mac).
public struct LocalAssetInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var isVideo: Bool
    public var isScreenshot: Bool
    public var isLivePhoto: Bool
    public var duration: TimeInterval
    public var date: Date?
    /// Total bytes of the asset's resources; nil until measured.
    public var size: Int64?

    public init(id: String, isVideo: Bool, isScreenshot: Bool = false, isLivePhoto: Bool = false,
                duration: TimeInterval = 0, date: Date? = nil, size: Int64? = nil) {
        self.id = id; self.isVideo = isVideo; self.isScreenshot = isScreenshot
        self.isLivePhoto = isLivePhoto; self.duration = duration; self.date = date; self.size = size
    }
}

public enum LocalFilter: Hashable, Sendable, CaseIterable {
    case all, videos, photos, screenshots, livePhotos

    public var title: String {
        switch self {
        case .all: return "Photos + videos"
        case .videos: return "Videos"
        case .photos: return "Photos"
        case .screenshots: return "Screenshots"
        case .livePhotos: return "Live Photos"
        }
    }

    func matches(_ a: LocalAssetInfo) -> Bool {
        switch self {
        case .all: return true
        case .videos: return a.isVideo
        case .photos: return !a.isVideo
        case .screenshots: return a.isScreenshot
        case .livePhotos: return a.isLivePhoto
        }
    }
}

public enum LocalSort: Hashable, Sendable, CaseIterable {
    case largest, oldest, newest

    public var title: String {
        switch self {
        case .largest: return "Largest first"
        case .oldest: return "Oldest first"
        case .newest: return "Newest first"
        }
    }
}

public enum LocalLibraryQuery {
    /// Filters, drops anything below `minBytes` (unmeasured assets are kept so they don't vanish
    /// while sizes are still being computed), and sorts. Unmeasured assets sort last by size.
    public static func apply(_ assets: [LocalAssetInfo], filter: LocalFilter, sort: LocalSort,
                             minBytes: Int64 = 0) -> [LocalAssetInfo] {
        let kept = assets.filter { filter.matches($0) && ($0.size.map { $0 >= minBytes } ?? true) }
        switch sort {
        case .largest: return kept.sorted { ($0.size ?? -1) > ($1.size ?? -1) }
        case .oldest: return kept.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        case .newest: return kept.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
    }

    public static func totalBytes(_ assets: [LocalAssetInfo]) -> Int64 { assets.reduce(0) { $0 + ($1.size ?? 0) } }
}
