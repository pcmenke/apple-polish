import Foundation
import PolishCore

/// Tracks which grid cells are on screen and, once scrolling settles, asks the thumbnail
/// service to warm a bounded window around them (ahead of the scroll direction first).
/// A plain reference type on purpose: updating it must not invalidate the SwiftUI grid.
@MainActor
final class ViewportTracker {
    var items: [MediaItem] = [] { didSet { visible.removeAll(); schedule() } }
    private var visible = Set<Int>()
    private var settleTask: Task<Void, Never>?
    private let ahead = 40
    private let behind = 12

    func appeared(_ index: Int) { visible.insert(index); schedule() }
    func disappeared(_ index: Int) { visible.remove(index); schedule() }

    private func schedule() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))  // scroll-settle, like papr's 150 ms
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        guard let low = visible.min(), let high = visible.max(), !items.isEmpty else {
            ThumbnailService.shared.setPrefetch([])
            return
        }
        let forward = Array(items[min(items.count, high + 1) ..< min(items.count, high + 1 + ahead)])
        let backward = Array(items[max(0, low - behind) ..< low].reversed())
        ThumbnailService.shared.setPrefetch(forward + backward)
    }
}
