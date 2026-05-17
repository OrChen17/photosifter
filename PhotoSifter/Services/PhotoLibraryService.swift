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

    func fetchAllAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // Only filter by mediaType in the DB predicate — PHQuery doesn't support
        // bitwise operators (&), so screenshot/cloud filtering is done in-memory below.
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
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

    func loadFullImage(for asset: PHAsset) async -> FullImageResult {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = AppSettings.cloudDownloadEnabled
            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
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
