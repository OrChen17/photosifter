import AVFoundation
import Photos

/// The photo-library steps of a replace, split out so the ordering rule in
/// `VideoReplacer` can be tested without touching Photos.
protocol VideoLibraryReplacing: Sendable {
    /// Saves the file as a new video that copies the original's date, location,
    /// favourite, hidden flag and albums. Returns the new localIdentifier.
    func createCopy(of originalID: String, fromFileAt url: URL) async throws -> String
    func isUsableCopy(_ copyID: String, expectedDuration: Double) async -> Bool
    /// One library change, so iOS asks the user once for the whole batch.
    func delete(_ assetIDs: [String]) async throws
}

/// A smaller copy that is saved in Photos and was read back from the library.
struct VideoCopy: Equatable, Sendable {
    let originalID: String
    let copyID: String
    let expectedDuration: Double
}

struct VideoDeleteResult: Equatable, Sendable {
    /// Everything that left the library: replaced originals and plain deletes.
    var deletedIDs: Set<String> = []
    /// Originals left alone because their copy could not be found again.
    var unverifiedOriginalIDs: Set<String> = []
    /// The user said no to the iOS prompt, or the delete failed. Nothing was deleted.
    var wasDeclined = false
}

enum VideoReplaceError: Error, Equatable {
    case originalMissing
    case copyNotCreated
    case copyNotVerified
}

/// The only code path that deletes an original video. An original is deleted
/// strictly after its copy is saved and read back from the library.
struct VideoReplacer: Sendable {
    let library: any VideoLibraryReplacing

    func makeCopy(originalID: String, fromFileAt url: URL, expectedDuration: Double) async throws -> VideoCopy {
        let copyID = try await library.createCopy(of: originalID, fromFileAt: url)
        guard copyID != originalID,
              await library.isUsableCopy(copyID, expectedDuration: expectedDuration)
        else { throw VideoReplaceError.copyNotVerified }
        return VideoCopy(originalID: originalID, copyID: copyID, expectedDuration: expectedDuration)
    }

    /// Re-checks every copy right before deleting. `extraIDs` are videos the
    /// user chose to delete outright.
    func deleteOriginals(of copies: [VideoCopy], alsoDeleting extraIDs: [String]) async -> VideoDeleteResult {
        var result = VideoDeleteResult()
        var toDelete = extraIDs
        for copy in copies {
            if await library.isUsableCopy(copy.copyID, expectedDuration: copy.expectedDuration) {
                toDelete.append(copy.originalID)
            } else {
                result.unverifiedOriginalIDs.insert(copy.originalID)
            }
        }
        guard !toDelete.isEmpty else { return result }
        do {
            try await library.delete(toDelete)
            result.deletedIDs = Set(toDelete)
        } catch {
            result.wasDeclined = true
        }
        return result
    }
}

/// Videos the user kept, and the smaller copies we made. They never come back
/// to the Videos queue.
actor VideoKeptStore {
    static let shared = VideoKeptStore()
    private static let fileName = "kept_video_identifiers.json"

    private let url: URL
    private var ids: Set<String>

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(Self.fileName)
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        ids = Set(saved ?? [])
    }

    func all() -> Set<String> { ids }

    func add(_ newIDs: [String]) {
        guard !newIDs.isEmpty else { return }
        ids.formUnion(newIDs)
        guard let data = try? JSONEncoder().encode(Array(ids)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

actor VideoLibraryService {
    static let shared = VideoLibraryService()

    /// Slow-motion and Cinematic clips carry data a plain re-encode would destroy.
    static let unsupportedSubtypes: PHAssetMediaSubtype = [.videoHighFrameRate, .videoCinematic]
    private static let videoResourceTypes: Set<PHAssetResourceType> = [.video, .fullSizeVideo]
    private static let fileSizeKey = "fileSize"
    private static let outputExtension = "mov"
    private static let durationTolerance = 0.5
    static let keepsLibraryPosition = true
    private static let addedDateKey = "addedDate"
    private static let addedDateSetter = NSSelectorFromString("setAddedDate:")

    /// Every video we can handle, biggest file first.
    func fetchVideos(excluding excluded: Set<String>) async -> [VideoItem] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var items: [VideoItem] = []
        result.enumerateObjects { asset, _, _ in
            guard !excluded.contains(asset.localIdentifier),
                  asset.mediaSubtypes.isDisjoint(with: Self.unsupportedSubtypes),
                  asset.duration > 0
            else { return }
            let bytes = Self.fileBytes(of: asset)
            guard bytes > 0 else { return }
            items.append(VideoItem(asset: asset, fileBytes: bytes))
        }
        let sorted = items.sorted { $0.fileBytes > $1.fileBytes }
        guard !AppSettings.cloudDownloadEnabled else { return sorted }
        return await Self.localOnly(sorted)
    }

    private static func localOnly(_ items: [VideoItem]) async -> [VideoItem] {
        let flags = await items.concurrentMap(limit: GroupingService.maxConcurrentLocalChecks) { item in
            guard let resource = playbackResource(of: item.asset) else { return false }
            return await PhotoLibraryService.shared.isLocallyAvailable(resource)
        }
        return zip(items, flags).filter(\.1).map(\.0)
    }

    private static func playbackResource(of asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .fullSizeVideo } ?? resources.first { $0.type == .video }
    }

    func loadAVAsset(for asset: PHAsset) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = AppSettings.cloudDownloadEnabled
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    static func freeDiskBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func fileBytes(of asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset)
            .filter { videoResourceTypes.contains($0.type) }
            .reduce(Int64(0)) { $0 + (($1.value(forKey: fileSizeKey) as? Int64) ?? 0) }
    }

    static func addedDate(of asset: PHAsset) -> Date? {
        if #available(iOS 26.0, *) { return asset.addedDate }
        guard asset.responds(to: NSSelectorFromString(addedDateKey)) else { return nil }
        return asset.value(forKey: addedDateKey) as? Date
    }

    private static func asset(withID id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }
}

extension VideoLibraryService: VideoLibraryReplacing {
    private final class IdentifierBox: @unchecked Sendable {
        var value: String?
    }

    func createCopy(of originalID: String, fromFileAt url: URL) async throws -> String {
        guard let original = Self.asset(withID: originalID) else { throw VideoReplaceError.originalMissing }

        var albums: [PHAssetCollection] = []
        PHAssetCollection
            .fetchAssetCollectionsContaining(original, with: .album, options: nil)
            .enumerateObjects { album, _, _ in
                if album.canPerform(.addContent) { albums.append(album) }
            }
        let filename = PHAssetResource.assetResources(for: original).first
            .map { ($0.originalFilename as NSString).deletingPathExtension }
            .map { "\($0).\(Self.outputExtension)" }

        let addedDate = Self.addedDate(of: original)

        let box = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            options.originalFilename = filename
            request.addResource(with: .video, fileURL: url, options: options)
            request.creationDate = original.creationDate
            request.location = original.location
            request.isFavorite = original.isFavorite
            request.isHidden = original.isHidden
            if Self.keepsLibraryPosition, let addedDate, request.responds(to: Self.addedDateSetter) {
                request.perform(Self.addedDateSetter, with: addedDate as NSDate)
            }
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            box.value = placeholder.localIdentifier
            for album in albums {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
        guard let copyID = box.value else { throw VideoReplaceError.copyNotCreated }
        return copyID
    }

    func isUsableCopy(_ copyID: String, expectedDuration: Double) async -> Bool {
        guard let copy = Self.asset(withID: copyID), copy.mediaType == .video else { return false }
        return abs(copy.duration - expectedDuration) <= Self.durationTolerance
    }

    func delete(_ assetIDs: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}
