import PolishRemote
import UIKit

/// Fetches thumbnails from the Mac with the same discipline as the Mac app: memory + disk cache,
/// duplicate requests share one fetch, at most four in flight, and visible requests always beat
/// prefetch (one slot is kept free for them). Failures are remembered so they are not retried in a loop.
actor RemoteThumbnails {
    enum Priority { case visible, prefetch }

    private let cache = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private var failed = Set<String>()
    private var running = 0
    private var visibleWaiters: [CheckedContinuation<Void, Never>] = []
    private var prefetchWaiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent = 4
    private var client: RemoteClient?

    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("remote-thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { cache.totalCostLimit = 96 * 1024 * 1024 }

    func use(_ client: RemoteClient?) {
        self.client = client
        failed.removeAll()
    }

    nonisolated func cached(_ id: String) -> UIImage? { cache.object(forKey: id as NSString) }

    func image(for id: String, priority: Priority = .visible) async -> UIImage? {
        if let hit = cache.object(forKey: id as NSString) { return hit }
        if failed.contains(id) { return nil }
        if let running = inflight[id] { return await running.value }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.load(id, priority: priority)
        }
        inflight[id] = task
        let result = await task.value
        inflight[id] = nil
        return result
    }

    private func load(_ id: String, priority: Priority) async -> UIImage? {
        let file = Self.directory.appendingPathComponent("\(id).jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return remember(image, id) }
        await acquire(priority)
        defer { release() }
        guard let client else { return nil }
        do {
            let response = try await client.request(.thumbnail, itemID: id)
            guard let data = response.thumbnail, let image = UIImage(data: data) else { failed.insert(id); return nil }
            try? data.write(to: file)
            return remember(image, id)
        } catch {
            failed.insert(id)
            return nil
        }
    }

    private func remember(_ image: UIImage, _ id: String) -> UIImage {
        cache.setObject(image, forKey: id as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    private func acquire(_ priority: Priority) async {
        if running < maxConcurrent, priority == .visible || running < maxConcurrent - 1 { running += 1; return }
        await withCheckedContinuation { cont in
            if priority == .visible { visibleWaiters.append(cont) } else { prefetchWaiters.append(cont) }
        }
    }

    private func release() {
        if let next = visibleWaiters.popLast() { next.resume(); return }  // newest visible request first
        if running < maxConcurrent, let next = prefetchWaiters.first { prefetchWaiters.removeFirst(); next.resume(); return }
        running -= 1
    }

    func dropPrefetch() {
        let waiting = prefetchWaiters
        prefetchWaiters.removeAll()
        running += waiting.count  // each resumed waiter will release() its slot after returning
        waiting.forEach { $0.resume() }
    }
}
