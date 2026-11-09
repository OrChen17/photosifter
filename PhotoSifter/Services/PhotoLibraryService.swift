import Photos
import UIKit

enum FullImageResult {
    case loaded(UIImage)
    case iCloudOnly   // asset exists only in iCloud; cloud download is disabled
    case failed
}

actor PhotoLibraryService {
    static let shared = PhotoLibraryService()

    private let imageManager = PHCachingImageManager()

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// When `cutoff` is provided, only assets with `modificationDate > cutoff` are returned.
    /// Using modificationDate (rather than creationDate) means photos restored from
    /// Recently Deleted are re-fetched if iOS bumps their modificationDate on restoration.
    /// Sorted by creationDate so time bucketing doesn't depend on edit order.
    func fetchAllAssets(since cutoff: Date? = nil) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // Only filter by mediaType in the DB predicate — PHQuery doesn't support
        // bitwise operators (&), so screenshot/cloud filtering is done in-memory below.
        if let cutoff {
            options.predicate = NSPredicate(
                format: "mediaType == %d AND modificationDate > %@",
                PHAssetMediaType.image.rawValue, cutoff as NSDate
            )
        } else {
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            assets.append(asset)
        }
        return assets
    }

    func loadThumbnail(for asset: PHAsset, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = AppSettings.cloudDownloadEnabled
            // .opportunistic fires twice: degraded first (OS thumbnail cache — fast),
            // then full quality. Wait for the non-degraded result so the grid never
            // shows a blurry thumbnail that never updates.
            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    /// Progressive thumbnail loader: yields the OS-cached degraded image first
    /// (instant) and then the full-quality image (slower). Consumers that want a
    /// snappy grid should drive a `@State` image off the latest yielded value.
    func loadThumbnailStream(for asset: PHAsset, size: CGSize) -> AsyncStream<UIImage> {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = AppSettings.cloudDownloadEnabled
        let manager = imageManager
        return AsyncStream { continuation in
            let requestID = manager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if let image { continuation.yield(image) }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if !isDegraded || cancelled { continuation.finish() }
            }
            continuation.onTermination = { _ in
                manager.cancelImageRequest(requestID)
            }
        }
    }

    /// Load an image sized for on-screen display (≤2048px on the long edge).
    /// Much faster to decode than full resolution; quality is indistinguishable
    /// on any iPhone screen. Use this for swipe cards.
    func loadDisplayImage(for asset: PHAsset) async -> FullImageResult {
        await loadFullImage(for: asset, targetSize: CGSize(width: 2048, height: 2048))
    }

    func loadFullImage(for asset: PHAsset) async -> FullImageResult {
        await loadFullImage(for: asset, targetSize: PHImageManagerMaximumSize)
    }

    func loadFocusImage(for asset: PHAsset) async -> UIImage? {
        let side = PhotoLibraryService.focusImageMaxSide
        guard case .loaded(let image) = await loadFullImage(for: asset, targetSize: CGSize(width: side, height: side)) else { return nil }
        return image
    }

    static let focusImageMaxSide: CGFloat = 4096

    private func loadFullImage(for asset: PHAsset, targetSize: CGSize) async -> FullImageResult {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = AppSettings.cloudDownloadEnabled
            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard !resumed else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                resumed = true
                if let image {
                    continuation.resume(returning: .loaded(image))
                } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                    continuation.resume(returning: .iCloudOnly)
                } else {
                    continuation.resume(returning: .failed)
                }
            }
        }
    }

    /// Returns true if the primary image resource is stored on this device.
    /// Uses PHAssetResourceManager with network disabled — cancels after the
    /// first data chunk so we never read the full file, just confirm it exists locally.
    func isLocallyAvailable(_ asset: PHAsset) async -> Bool {
        let types: Set<PHAssetResourceType> = [.photo, .fullSizePhoto, .alternatePhoto, .adjustmentBasePhoto]
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { types.contains($0.type) }) else { return false }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { continuation in
            var requestID: PHAssetResourceDataRequestID = 0
            var resumed = false
            requestID = PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { _ in
                    guard !resumed else { return }
                    resumed = true
                    PHAssetResourceManager.default().cancelDataRequest(requestID)
                    continuation.resume(returning: true)
                },
                completionHandler: { error in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: error == nil)
                }
            )
        }
    }

    func startCachingThumbnails(for assets: [PHAsset], size: CGSize) {
        imageManager.startCachingImages(
            for: assets,
            targetSize: size,
            contentMode: .aspectFill,
            options: nil
        )
    }

    func deleteAssets(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
}

/// Reports photos that become visible to the app while it runs: new photos,
/// photos restored from Recently Deleted, and photos the user adds to a
/// limited-access selection. Limited-access additions keep their original
/// dates, so the incremental launch scan (which filters on modificationDate)
/// would never see them.
final class LibraryInsertionObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let lock = NSLock()
    private var fetchResult: PHFetchResult<PHAsset>
    private let onInsert: @Sendable ([String]) -> Void

    init(onInsert: @escaping @Sendable ([String]) -> Void) {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        self.fetchResult = PHAsset.fetchAssets(with: options)
        self.onInsert = onInsert
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.lock()
        guard let details = changeInstance.changeDetails(for: fetchResult) else {
            lock.unlock()
            return
        }
        let before = fetchResult
        let after = details.fetchResultAfterChanges
        fetchResult = after
        lock.unlock()

        let inserted: [String]
        if details.hasIncrementalChanges {
            inserted = details.insertedObjects.map(\.localIdentifier)
        } else {
            inserted = Self.identifiers(in: after).subtracting(Self.identifiers(in: before)).map { $0 }
        }
        guard !inserted.isEmpty else { return }
        onInsert(inserted)
    }

    private static func identifiers(in result: PHFetchResult<PHAsset>) -> Set<String> {
        var ids = Set<String>(minimumCapacity: result.count)
        result.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        return ids
    }
}
