import AVFoundation
import Photos

/// A finished transcode waiting to replace its original in Photos.
struct ShrinkOutput: Equatable, Sendable {
    let candidateID: String     // localIdentifier of the original
    let fileURL: URL
    let bytes: Int64
}

enum VideoShrinkError: LocalizedError {
    case assetMissing
    case iCloudOnly
    case noVideoTrack
    case exportUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .assetMissing:      return "The video is no longer in your library."
        case .iCloudOnly:        return "The video is in iCloud and iCloud downloads are off."
        case .noVideoTrack:      return "The video couldn't be read."
        case .exportUnavailable: return "This video can't be converted on this device."
        case .exportFailed:      return "The conversion failed."
        }
    }
}

/// Seam for `VideoShrinkViewModel` so tests can run without Photos or AVFoundation.
protocol VideoShrinking: Sendable {
    func fetchCandidates() async -> [VideoCandidate]
    /// Writes a 1080p / ≤30 fps copy to a temp file. Throws `CancellationError`
    /// when the calling task is cancelled.
    func transcode(_ candidate: VideoCandidate, progress: @escaping @Sendable (Double) -> Void) async throws -> ShrinkOutput
    /// Adds every output to Photos and deletes the originals in ONE change
    /// block, so iOS shows a single delete prompt and a cancel rolls back the
    /// whole batch (nothing is added, nothing is deleted).
    func replaceOriginals(with outputs: [ShrinkOutput]) async throws
    func discard(_ outputs: [ShrinkOutput]) async
    func availableDiskBytes() async -> Int64?
}

actor VideoShrinkService: VideoShrinking {
    static let shared = VideoShrinkService()

    private let videoResourceTypes: Set<PHAssetResourceType> = [.video, .fullSizeVideo]
    private let workDirectory: URL
    private let frameRateCacheURL: URL
    /// localIdentifier → nominal frame rate. Reading it means opening the
    /// AVAsset, so it's cached across launches the same way `file_sizes.json` is.
    private var frameRateCache: [String: Double]

    init() {
        let fm = FileManager.default
        workDirectory = fm.temporaryDirectory.appendingPathComponent("VideoShrink", isDirectory: true)
        try? fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // iOS doesn't create Application Support on its own (see GroupingService.init).
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        frameRateCacheURL = support.appendingPathComponent("video_frame_rates.json")
        if let data = try? Data(contentsOf: frameRateCacheURL),
           let cache = try? JSONDecoder().decode([String: Double].self, from: data) {
            frameRateCache = cache
        } else {
            frameRateCache = [:]
        }
    }

    // MARK: - Scan

    func fetchCandidates() async -> [VideoCandidate] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            // Slo-mo, Cinematic and time-lapse depend on their frame timing or
            // depth data; a plain 30 fps re-encode would flatten them.
            let skipped: PHAssetMediaSubtype = [.videoHighFrameRate, .videoCinematic, .videoTimelapse]
            guard asset.mediaSubtypes.isDisjoint(with: skipped) else { return }
            assets.append(asset)
        }

        var candidates: [VideoCandidate] = []
        let batches = stride(from: 0, to: assets.count, by: 6).map {
            Array(assets[$0..<min($0 + 6, assets.count)])
        }
        for batch in batches {
            let missing = batch.filter { frameRateCache[$0.localIdentifier] == nil }
            if !missing.isEmpty {
                await withTaskGroup(of: (String, Double?).self) { group in
                    for asset in missing {
                        group.addTask { (asset.localIdentifier, await Self.loadFrameRate(for: asset)) }
                    }
                    for await (id, fps) in group {
                        if let fps { frameRateCache[id] = fps }
                    }
                }
            }
            for asset in batch {
                guard let bytes = fileSize(for: asset) else { continue }
                let spec = VideoSpec(
                    width: asset.pixelWidth,
                    height: asset.pixelHeight,
                    fps: frameRateCache[asset.localIdentifier],
                    duration: asset.duration,
                    fileBytes: bytes
                )
                guard VideoShrinkPlan.isCandidate(spec) else { continue }
                candidates.append(VideoCandidate(
                    id: asset.localIdentifier, spec: spec, creationDate: asset.creationDate
                ))
            }
        }
        saveFrameRateCache()
        return candidates
    }

    /// Reads the video track's frame rate without downloading from iCloud.
    /// Returns nil for cloud-only videos.
    private static func loadFrameRate(for asset: PHAsset) async -> Double? {
        let options = PHVideoRequestOptions()
        options.version = .original
        options.isNetworkAccessAllowed = false
        guard let avAsset = await requestAVAsset(for: asset, options: options) else { return nil }
        do {
            guard let track = try await avAsset.loadTracks(withMediaType: .video).first else { return nil }
            let fps = try await track.load(.nominalFrameRate)
            return fps > 0 ? Double(fps) : nil
        } catch {
            print("[VideoShrink] frame rate read failed for \(asset.localIdentifier): \(error)")
            return nil
        }
    }

    private static func requestAVAsset(for asset: PHAsset, options: PHVideoRequestOptions) async -> AVAsset? {
        await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    private func fileSize(for asset: PHAsset) -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let r = resources.first(where: { videoResourceTypes.contains($0.type) }) else { return nil }
        return r.value(forKey: "fileSize") as? Int64
    }

    private func saveFrameRateCache() {
        do {
            let data = try JSONEncoder().encode(frameRateCache)
            try data.write(to: frameRateCacheURL, options: .atomic)
        } catch {
            print("[VideoShrink] frame rate cache write failed: \(error)")
        }
    }

    // MARK: - Transcode

    func transcode(
        _ candidate: VideoCandidate,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ShrinkOutput {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.id], options: nil).firstObject else {
            throw VideoShrinkError.assetMissing
        }
        let options = PHVideoRequestOptions()
        // .current bakes in any trim/filter the user applied in Photos — the
        // copy should look like what they see, since the original goes away.
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = AppSettings.cloudDownloadEnabled
        guard let avAsset = await Self.requestAVAsset(for: asset, options: options) else {
            throw AppSettings.cloudDownloadEnabled ? VideoShrinkError.noVideoTrack : VideoShrinkError.iCloudOnly
        }
        try Task.checkCancellation()

        let composition = try await Self.shrinkComposition(for: avAsset)
        let preset = AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVC1920x1080)
            ? AVAssetExportPresetHEVC1920x1080
            : AVAssetExportPreset1920x1080
        guard let session = AVAssetExportSession(asset: avAsset, presetName: preset) else {
            throw VideoShrinkError.exportUnavailable
        }
        let outputURL = workDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.videoComposition = composition
        // Carry the file-level metadata (location, capture device, etc.) into the copy.
        session.metadata = (try? await avAsset.load(.metadata)) ?? []

        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poller.cancel() }

        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            session.cancelExport()
        }

        switch session.status {
        case .completed:
            progress(1)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
            return ShrinkOutput(candidateID: candidate.id, fileURL: outputURL, bytes: bytes)
        case .cancelled:
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: outputURL)
            if let error = session.error {
                print("[VideoShrink] export failed for \(candidate.id): \(error)")
                throw error
            }
            throw VideoShrinkError.exportFailed
        }
    }

    /// A video composition that renders the clip upright at ≤1080p and, when
    /// it's faster than 30 fps, at 30 fps. Starts from the asset's own
    /// properties so HDR colour settings carry over.
    private static func shrinkComposition(for avAsset: AVAsset) async throws -> AVMutableVideoComposition {
        guard let track = try await avAsset.loadTracks(withMediaType: .video).first else {
            throw VideoShrinkError.noVideoTrack
        }
        let (naturalSize, transform, nominalFPS) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate
        )
        let duration = try await avAsset.load(.duration)

        // Phone video is stored landscape and rotated by preferredTransform;
        // size the output by how it's displayed.
        let oriented = naturalSize.applying(transform)
        let width = abs(oriented.width), height = abs(oriented.height)
        guard width > 0, height > 0 else { throw VideoShrinkError.noVideoTrack }

        let spec = VideoSpec(
            width: Int(width.rounded()), height: Int(height.rounded()),
            fps: nominalFPS > 0 ? Double(nominalFPS) : nil, duration: 0, fileBytes: 0
        )
        let target = VideoShrinkPlan.targetDimensions(width: spec.width, height: spec.height)
        let scale = CGFloat(target.width) / width

        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: avAsset)
        composition.renderSize = CGSize(width: target.width, height: target.height)
        if VideoShrinkPlan.needsFrameRateDrop(spec) {
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(VideoShrinkPlan.maxFPS))
        }

        // Rotate first, then scale: the rotation's translation is in source
        // pixels, so it must be scaled along with the frame.
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    // MARK: - Replace

    func replaceOriginals(with outputs: [ShrinkOutput]) async throws {
        guard !outputs.isEmpty else { return }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: outputs.map(\.candidateID), options: nil)
        var originals: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in originals[asset.localIdentifier] = asset }

        // Album membership has to be read before the change block.
        var albums: [String: [PHAssetCollection]] = [:]
        for (id, asset) in originals {
            var list: [PHAssetCollection] = []
            PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
                .enumerateObjects { album, _, _ in
                    if album.canPerform(.addContent) { list.append(album) }
                }
            albums[id] = list
        }

        let originalsByID = originals, albumsByID = albums
        try await PHPhotoLibrary.shared().performChanges {
            var replaced: [PHAsset] = []
            for output in outputs {
                guard let original = originalsByID[output.candidateID] else { continue }
                let request = PHAssetCreationRequest.forAsset()
                // Copy, don't move: if the user cancels the delete prompt the
                // whole block rolls back and the files are kept for a retry.
                request.addResource(with: .video, fileURL: output.fileURL, options: nil)
                request.creationDate = original.creationDate
                request.location = original.location
                request.isFavorite = original.isFavorite
                request.isHidden = original.isHidden
                if let placeholder = request.placeholderForCreatedAsset {
                    for album in albumsByID[output.candidateID] ?? [] {
                        PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                    }
                }
                replaced.append(original)
            }
            PHAssetChangeRequest.deleteAssets(replaced as NSArray)
        }
        await discard(outputs)
    }

    func discard(_ outputs: [ShrinkOutput]) async {
        for output in outputs {
            do {
                try FileManager.default.removeItem(at: output.fileURL)
            } catch {
                print("[VideoShrink] temp file cleanup failed for \(output.fileURL.lastPathComponent): \(error)")
            }
        }
    }

    func availableDiskBytes() async -> Int64? {
        let values = try? workDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
