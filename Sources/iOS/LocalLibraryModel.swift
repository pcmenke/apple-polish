import Photos
import PolishRemote
import UIKit

private struct Unchecked<T>: @unchecked Sendable { let value: T }

/// The iPhone's own Photos library: sizes measured in the background (videos first), thumbnails
/// from a PHCachingImageManager with a bounded prefetch window around what is on screen.
@MainActor
final class LocalLibraryModel: ObservableObject {
    enum Access { case unknown, denied, limited, authorized }

    @Published private(set) var access = Access.unknown
    @Published private(set) var infos: [LocalAssetInfo] = []
    @Published private(set) var version = 0
    @Published private(set) var measured = 0
    @Published var message: String?

    private var byID: [String: PHAsset] = [:]
    private var indexByID: [String: Int] = [:]
    private var measureTask: Task<Void, Never>?
    private var modifiedByID: [String: Date] = [:]
    /// Persistent index of measured sizes; nil only if the database can't be opened.
    private let store: LocalIndexStore? = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("local-index.sqlite")
        let store = try? LocalIndexStore(path: url.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true  // rebuildable, so keep it out of backups
        try? url.setResourceValues(values)
        return store
    }()
    private let manager = PHCachingImageManager()
    private let thumbSize = CGSize(width: 330, height: 330)
    private var cachedWindow = Set<String>()
    private let options: PHImageRequestOptions = {
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat  // one callback; resizeMode fast keeps it cheap
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = false  // never pull iCloud originals just to draw a thumbnail
        return o
    }()

    var isMeasuring: Bool { measured < infos.count }

    func start() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        switch status {
        case .authorized: access = .authorized
        case .limited: access = .limited
        default: access = .denied; return
        }
        if infos.isEmpty { await reload() }
    }

    /// `forceMeasure` ignores the stored sizes and measures everything again.
    func reload(forceMeasure: Bool = false) async {
        measureTask?.cancel()
        let store = self.store
        let loaded = await Task.detached(priority: .userInitiated) { () -> (result: LocalIndexReconciler.Result, assets: Unchecked<[String: PHAsset]>, modified: [String: Date]) in
            let fetch = PHFetchOptions()
            fetch.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetch.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                          PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            let result = PHAsset.fetchAssets(with: fetch)
            var current: [CurrentAsset] = [], assets: [String: PHAsset] = [:], modified: [String: Date] = [:]
            current.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                assets[asset.localIdentifier] = asset
                if let m = asset.modificationDate { modified[asset.localIdentifier] = m }
                current.append(CurrentAsset(
                    id: asset.localIdentifier, isVideo: asset.mediaType == .video,
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                    isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                    duration: asset.duration, date: asset.creationDate, modified: asset.modificationDate))
            }
            let cached = forceMeasure ? [:] : (store?.loadAll() ?? [:])
            let reconciled = LocalIndexReconciler.reconcile(current: current, cached: cached, forceMeasure: forceMeasure)
            store?.remove(ids: reconciled.vanished)
            return (reconciled, Unchecked(value: assets), modified)
        }.value
        byID = loaded.assets.value
        modifiedByID = loaded.modified
        infos = loaded.result.infos
        indexByID = Dictionary(uniqueKeysWithValues: infos.enumerated().map { ($1.id, $0) })
        measured = infos.count - loaded.result.toMeasure.count  // everything the index already knew
        version += 1
        measureSizes(loaded.result.toMeasure)
    }

    /// File sizes aren't part of PHAsset's public API; the resource's `fileSize` key is the
    /// long-standing way to read them. Only assets the index doesn't know (or that changed) are
    /// measured, off the main thread, and each batch is saved so the next launch is instant.
    private func measureSizes(_ order: [String]) {
        guard !order.isEmpty else { return }
        let assets = Unchecked(value: byID)
        let modified = modifiedByID, store = self.store
        let flags = Dictionary(uniqueKeysWithValues: infos.map { ($0.id, $0) })
        let alreadyKnown = measured
        measureTask = Task.detached(priority: .utility) { [weak self] in
            var batch: [String: Int64] = [:]
            var processed = 0
            for id in order {
                if Task.isCancelled { return }
                if let asset = assets.value[id] {
                    let resources = PHAssetResource.assetResources(for: asset)
                    batch[id] = resources.reduce(Int64(0)) { $0 + Int64((($1.value(forKey: "fileSize") as? NSNumber)?.int64Value) ?? 0) }
                }
                processed += 1
                if batch.count >= 1500 || processed == order.count {
                    let chunk = batch, done = alreadyKnown + processed
                    batch = [:]
                    store?.upsert(chunk.compactMap { id, size in
                        guard var info = flags[id] else { return nil }
                        info.size = size
                        return IndexedAsset(info: info, modified: modified[id])
                    })
                    await self?.apply(sizes: chunk, measured: done)
                }
            }
        }
    }

    private func apply(sizes: [String: Int64], measured: Int) {
        for (id, size) in sizes { if let i = indexByID[id] { infos[i].size = size } }
        self.measured = measured
        version += 1
    }

    // MARK: Thumbnails

    func thumbnail(for id: String) async -> UIImage? {
        guard let asset = byID[id] else { return nil }
        let request = Unchecked(value: RequestBox())
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
                request.value.id = manager.requestImage(for: asset, targetSize: thumbSize,
                                                        contentMode: .aspectFill, options: options) { image, _ in
                    cont.resume(returning: image)
                }
            }
        } onCancel: {
            Task { @MainActor in self.manager.cancelImageRequest(request.value.id) }
        }
    }

    private final class RequestBox { var id = PHInvalidImageRequestID }

    /// Warms the cache for the items just ahead of (and a few behind) the one that appeared.
    func prefetch(_ shown: [LocalAssetInfo], around index: Int) {
        let lo = max(0, index - 8), hi = min(shown.count, index + 40)
        let window = Set(shown[lo ..< hi].map(\.id))
        let start = window.subtracting(cachedWindow).compactMap { byID[$0] }
        let stop = cachedWindow.subtracting(window).compactMap { byID[$0] }
        if !start.isEmpty { manager.startCachingImages(for: start, targetSize: thumbSize, contentMode: .aspectFill, options: options) }
        if !stop.isEmpty { manager.stopCachingImages(for: stop, targetSize: thumbSize, contentMode: .aspectFill, options: options) }
        cachedWindow = window
    }

    func stopPrefetching() {
        manager.stopCachingImagesForAllAssets()
        cachedWindow.removeAll()
    }

    // MARK: Delete

    /// Deletes through PhotoKit, which shows iOS's own confirmation. Items land in Recently
    /// Deleted for 30 days; emptying that is what frees space and iCloud storage.
    func delete(_ ids: [String]) async {
        let assets = ids.compactMap { byID[$0] }
        guard !assets.isEmpty else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            let gone = Set(ids)
            infos.removeAll { gone.contains($0.id) }
            gone.forEach { byID[$0] = nil }
            store?.remove(ids: ids)
            indexByID = Dictionary(uniqueKeysWithValues: infos.enumerated().map { ($1.id, $0) })
            measured = min(measured, infos.count)
            version += 1
            message = "Moved \(assets.count) item\(assets.count == 1 ? "" : "s") to Recently Deleted. Empty it in Photos (Albums, Recently Deleted) to free the space."
        } catch {
            let cancelled = (error as NSError).code == PHPhotosError.userCancelled.rawValue
            if !cancelled { message = "Couldn't delete: \(error.localizedDescription)" }
        }
    }
}
