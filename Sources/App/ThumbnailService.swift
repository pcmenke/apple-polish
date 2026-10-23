import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import PolishCore
import UniformTypeIdentifiers

/// Result of asking for one thumbnail. NSImage is immutable once created here.
enum ThumbnailResult: @unchecked Sendable {
    case image(NSImage)
    case unavailable(String)
    case cancelled
}

/// Memory cache + bounded, prioritized thumbnail generation. Modeled on papr's page renderer:
/// visible items first (newest request first, so a fast scroll retargets to what is on screen),
/// a small prefetch window behind them, bounded concurrency with one slot kept free for
/// visible work, and queued work dropped as soon as nothing wants it.
final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()

    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var failures: [String: String] = [:]
    private lazy var scheduler = ThumbnailScheduler(maxConcurrent: 4) { [weak self] key, result in
        self?.store(key, result)
    }

    init() { cache.totalCostLimit = 192 * 1024 * 1024 }

    /// Synchronous lookup so cells that scroll back into view paint immediately.
    func resolved(_ item: MediaItem) -> ThumbnailResult? {
        if let image = cache.object(forKey: item.id as NSString) { return .image(image) }
        lock.lock(); defer { lock.unlock() }
        return failures[item.id].map { .unavailable($0) }
    }

    func result(for item: MediaItem) async -> ThumbnailResult {
        if let r = resolved(item) { return r }
        return await scheduler.request(item)
    }

    /// JPEG bytes of the thumbnail, for sending to the iPhone viewer.
    func jpegData(for item: MediaItem) async -> Data? {
        guard case .image(let image) = await result(for: item) else { return nil }
        if let onDisk = DiskCache.data(for: item) { return onDisk }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    /// Replace the set of speculative (not yet visible) thumbnails, nearest first.
    func setPrefetch(_ items: [MediaItem]) {
        let needed = items.filter { resolved($0) == nil }
        Task { await scheduler.setPrefetch(needed) }
    }

    private func store(_ key: String, _ result: ThumbnailResult) {
        switch result {
        case .image(let image):
            cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
        case .unavailable(let reason):
            lock.lock(); failures[key] = reason; lock.unlock()
        case .cancelled:
            break
        }
    }
}

actor ThumbnailScheduler {
    private final class Job {
        let item: MediaItem
        var waiters: [UUID: CheckedContinuation<ThumbnailResult, Never>] = [:]
        var prefetchRank: Int?
        var started = false
        var seq: Int
        init(item: MediaItem, seq: Int) { self.item = item; self.seq = seq }
    }

    private let maxConcurrent: Int
    private let sink: @Sendable (String, ThumbnailResult) -> Void
    private var jobs: [String: Job] = [:]
    private var running = 0
    private var counter = 0

    init(maxConcurrent: Int, sink: @escaping @Sendable (String, ThumbnailResult) -> Void) {
        self.maxConcurrent = maxConcurrent
        self.sink = sink
    }

    func request(_ item: MediaItem) async -> ThumbnailResult {
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled { cont.resume(returning: .cancelled); return }
                counter += 1
                let job = jobs[item.id] ?? Job(item: item, seq: counter)
                job.seq = counter  // newest request wins the next free slot
                job.waiters[waiter] = cont
                jobs[item.id] = job
                pump()
            }
        } onCancel: {
            Task { await self.cancel(key: item.id, waiter: waiter) }
        }
    }

    func setPrefetch(_ items: [MediaItem]) {
        let wanted = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        for (key, job) in jobs where !job.started {
            if let rank = wanted[key] {
                job.prefetchRank = rank
            } else {
                job.prefetchRank = nil
                if job.waiters.isEmpty { jobs[key] = nil }
            }
        }
        for item in items where jobs[item.id] == nil {
            counter += 1
            let job = Job(item: item, seq: counter)
            job.prefetchRank = wanted[item.id]
            jobs[item.id] = job
        }
        pump()
    }

    private func cancel(key: String, waiter: UUID) {
        guard let job = jobs[key], let cont = job.waiters.removeValue(forKey: waiter) else { return }
        cont.resume(returning: .cancelled)
        if job.waiters.isEmpty, job.prefetchRank == nil, !job.started { jobs[key] = nil }
    }

    private func nextJob() -> Job? {
        let queued = jobs.values.filter { !$0.started }
        if let visible = queued.filter({ !$0.waiters.isEmpty }).max(by: { $0.seq < $1.seq }) { return visible }
        guard running < maxConcurrent - 1 else { return nil }  // keep a slot free for visible work
        return queued.filter { $0.prefetchRank != nil }.min(by: { $0.prefetchRank! < $1.prefetchRank! })
    }

    private func pump() {
        while running < maxConcurrent, let job = nextJob() {
            job.started = true
            running += 1
            let item = job.item
            Task.detached(priority: .utility) {
                let result = await ThumbnailRenderer.render(item)
                await self.finish(key: item.id, result: result)
            }
        }
    }

    private func finish(key: String, result: ThumbnailResult) {
        running -= 1
        sink(key, result)
        if let job = jobs.removeValue(forKey: key) {
            for cont in job.waiters.values { cont.resume(returning: result) }
        }
        pump()
    }
}

enum ThumbnailRenderer {
    static let maxPixel = 480

    static func render(_ item: MediaItem) async -> ThumbnailResult {
        if let cached = DiskCache.load(item) { return .image(cached) }
        let image: CGImage?
        switch item.kind {
        case .photo:
            image = imageIOThumbnail(item.url)
        case .video:
            guard item.isReadable else { return .unavailable("Encrypted or incomplete video data") }
            image = await videoThumbnail(item.url)
        case .other:
            image = nil
        }
        guard let image else { return .unavailable("Can't preview") }
        DiskCache.store(image, for: item)
        return .image(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
    }

    private static func imageIOThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func videoThumbnail(_ url: URL) async -> CGImage? {
        await withTaskGroup(of: CGImage?.self) { group in
            group.addTask {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
                generator.requestedTimeToleranceBefore = .positiveInfinity
                generator.requestedTimeToleranceAfter = .positiveInfinity
                return try? await generator.image(at: .zero).image
            }
            group.addTask {  // a stuck decoder must not hold a worker slot forever
                try? await Task.sleep(for: .seconds(15))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Persistent thumbnails keyed by path + size + mtime, so a relaunch paints instantly.
enum DiskCache {
    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.pcmenke.applepolish/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(for item: MediaItem) -> URL {
        let mtime = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970) ?? 0
        let digest = SHA256.hash(data: Data("\(item.url.path)|\(item.size)|\(mtime)".utf8))
        return directory.appendingPathComponent(digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".jpg")
    }

    static func data(for item: MediaItem) -> Data? { try? Data(contentsOf: file(for: item)) }

    static func load(_ item: MediaItem) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(file(for: item) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func store(_ image: CGImage, for item: MediaItem) {
        guard let dest = CGImageDestinationCreateWithURL(
            file(for: item) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
