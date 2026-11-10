import AVFoundation
import Observation
import Photos
import UIKit

enum VideoCompressionFailure: Equatable {
    case unavailable
    case notEnoughSpace
    case encodeFailed
    case notSmaller
    case saveFailed

    var message: String {
        switch self {
        case .unavailable:
            String(localized: "A video is not on this iPhone. It may be stored in iCloud.")
        case .notEnoughSpace:
            String(localized: "Not enough free space to make the smaller copy.")
        case .encodeFailed:
            String(localized: "A video could not be compressed.")
        case .notSmaller:
            String(localized: "A result was not smaller than the original, so it was not replaced.")
        case .saveFailed:
            String(localized: "A smaller copy could not be saved to Photos.")
        }
    }
}

/// The Videos queue: every video in the library, biggest first, flicked like
/// photos. Right keeps, left compresses with the chosen caps and trim, and the
/// delete button marks for delete. Picking compress starts the encode into a
/// temp file right away, one video at a time. Nothing touches Photos until
/// `apply()`.
@Observable
@MainActor
final class VideoSifterViewModel {
    struct ApplyProgress: Equatable {
        var index: Int
        var total: Int
        var fraction: Double
    }

    struct EncodedVideo: Equatable {
        let url: URL
        let bytes: Int64
        let duration: Double
    }

    enum EncodeState: Equatable {
        case waiting
        case encoding
        case ready(EncodedVideo)
        case failed(VideoCompressionFailure)

        var isFinished: Bool {
            switch self {
            case .waiting, .encoding: false
            case .ready, .failed: true
            }
        }
    }

    struct ApplyResult: Equatable {
        var compressedCount = 0
        var deletedCount = 0
        var keptCount = 0
        var savedBytes: Int64 = 0
        var failure: VideoCompressionFailure?
        var failedCount = 0
        /// Copies are saved but the user said no to the delete prompt.
        var deleteDeclined = false
    }

    static let thumbnailCount = 8
    private static let thumbnailMaxSide: CGFloat = 160
    private static let freeSpaceMargin = 1.2
    private static let timescale: CMTimeScale = 600
    private static let playheadInterval = 0.05
    private static let applyPollInterval = Duration.milliseconds(100)

    private(set) var queue: [VideoItem] = []
    private(set) var isLoading = true
    private(set) var currentIndex = 0
    private(set) var decisions: [String: VideoDecision] = [:]

    private(set) var source: VideoSource?
    private(set) var thumbnails: [UIImage] = []
    private(set) var player: AVPlayer?
    private(set) var isCurrentUnavailable = false
    private(set) var isPlaying = false
    private(set) var playhead: Double = 0

    private(set) var applyProgress: ApplyProgress?
    var lastResult: ApplyResult?

    private(set) var sessionSavedBytes: Int64 = 0
    private(set) var sessionResolvedCount = 0

    private var settingsByID: [String: VideoCompressionSettings] = [:]
    private var skippedIDs: Set<String> = []
    private var actionHistory: [(id: String, decision: VideoDecision?)] = []
    private var readyCopies: [String: VideoCopy] = [:]
    private var copyBytes: [String: Int64] = [:]
    private var timeObserver: Any?
    private var currentAsset: AVAsset?
    private var previewTask: Task<Void, Never>?
    private(set) var encodeStates: [String: EncodeState] = [:]
    private(set) var encodeFraction: Double = 0
    private var activeEncodeID: String?
    private var activeTranscoder: VideoTranscoder?
    private var encodeWorker: Task<Void, Never>?
    private var applyCancelled = false

    private let replacer: VideoReplacer
    private let keptStore: VideoKeptStore

    init(
        library: any VideoLibraryReplacing = VideoLibraryService.shared,
        keptStore: VideoKeptStore = .shared
    ) {
        self.replacer = VideoReplacer(library: library)
        self.keptStore = keptStore
    }

    // MARK: - Queue

    func load() async {
        guard isLoading else { return }
        VideoTranscoder.clearWorkDirectory()
        let kept = await keptStore.all()
        queue = await VideoLibraryService.shared.fetchVideos(excluding: kept)
        isLoading = false
    }

    var currentItem: VideoItem? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    var nextItem: VideoItem? {
        queue.indices.contains(currentIndex + 1) ? queue[currentIndex + 1] : nil
    }

    var isQueueExhausted: Bool { currentIndex >= queue.count }
    var hasPendingDecisions: Bool { !decisions.isEmpty }
    var canUndo: Bool { !actionHistory.isEmpty }
    var canSkip: Bool { currentItem.map { !skippedIDs.contains($0.id) } ?? false }
    var isApplying: Bool { applyProgress != nil }

    func pendingCount(_ decision: VideoDecision) -> Int {
        decisions.values.reduce(0) { $0 + ($1 == decision ? 1 : 0) }
    }

    // MARK: - Settings and plan

    var settings: VideoCompressionSettings {
        get {
            guard let item = currentItem else { return VideoCompressionSettings(duration: 0) }
            return settingsByID[item.id] ?? defaultSettings(for: item)
        }
        set {
            guard let item = currentItem else { return }
            let old = settings
            settingsByID[item.id] = newValue
            if old.resolution != newValue.resolution || old.frameRate != newValue.frameRate {
                refreshPreview()
            }
        }
    }

    var currentSource: VideoSource? { source ?? currentItem?.metadataSource }

    var plan: VideoCompressionPlan? {
        currentSource.map { VideoCompressionPlan(source: $0, settings: settings) }
    }

    var canCompress: Bool { !isCurrentUnavailable && (plan?.canCompress ?? false) }

    private func defaultSettings(for item: VideoItem) -> VideoCompressionSettings {
        let duration = item.id == currentItem?.id ? source?.duration ?? item.asset.duration : item.asset.duration
        return VideoCompressionSettings(duration: duration)
    }

    // MARK: - Decisions

    func keep() { record(.keep) }

    func compress() {
        guard canCompress, let item = currentItem else { return }
        settingsByID[item.id] = settings
        record(.compress)
        startEncode(for: item.id)
    }

    func delete() { record(.delete) }

    private func record(_ decision: VideoDecision) {
        guard let item = currentItem else { return }
        decisions[item.id] = decision
        actionHistory.append((item.id, decision))
        var next = currentIndex + 1
        while next < queue.count, decisions[queue[next].id] != nil { next += 1 }
        currentIndex = min(next, queue.count)
    }

    func skip() {
        guard let item = currentItem, !skippedIDs.contains(item.id) else { return }
        skippedIDs.insert(item.id)
        actionHistory.append((item.id, nil))
        var next = currentIndex + 1
        while next < queue.count, decisions[queue[next].id] != nil || skippedIDs.contains(queue[next].id) {
            next += 1
        }
        currentIndex = min(next, queue.count)
        HapticManager.shared.playNavigate()
        SoundManager.shared.playSkip()
    }

    func undo() {
        guard let last = actionHistory.popLast() else { return }
        if last.decision != nil {
            clearDecision(for: last.id)
        } else {
            skippedIDs.remove(last.id)
        }
        if let index = queue.firstIndex(where: { $0.id == last.id }) { currentIndex = index }
        HapticManager.shared.playUndo()
        SoundManager.shared.playUndo()
    }

    func jumpTo(assetID: String) {
        guard let index = queue.firstIndex(where: { $0.id == assetID }) else { return }
        if decisions[assetID] != nil {
            clearDecision(for: assetID)
            actionHistory.removeAll { $0.id == assetID }
        }
        currentIndex = index
    }

    private func clearDecision(for id: String) {
        decisions[id] = nil
        readyCopies[id] = nil
        copyBytes[id] = nil
        cancelEncode(for: id)
    }

    // MARK: - Background encode

    private func startEncode(for id: String) {
        guard readyCopies[id] == nil else { return }
        encodeStates[id] = .waiting
        guard encodeWorker == nil else { return }
        encodeWorker = Task { [weak self] in await self?.runEncodes() }
    }

    private func cancelEncode(for id: String) {
        if case .ready(let video) = encodeStates[id] {
            try? FileManager.default.removeItem(at: video.url)
        }
        if activeEncodeID == id { activeTranscoder?.cancel() }
        encodeStates[id] = nil
    }

    private func runEncodes() async {
        while let item = queue.first(where: { encodeStates[$0.id] == .waiting }) {
            activeEncodeID = item.id
            encodeStates[item.id] = .encoding
            encodeFraction = 0
            let outcome = await encode(item)
            activeEncodeID = nil
            if encodeStates[item.id] == .encoding {
                encodeStates[item.id] = outcome
            } else if case .ready(let video) = outcome {
                try? FileManager.default.removeItem(at: video.url)
            }
        }
        encodeWorker = nil
    }

    private func encode(_ item: VideoItem) async -> EncodeState {
        guard let asset = await VideoLibraryService.shared.loadAVAsset(for: item.asset),
              let source = try? await VideoTranscoder.loadSource(from: asset, fileBytes: item.fileBytes)
        else { return .failed(.unavailable) }
        let settings = settingsByID[item.id] ?? defaultSettings(for: item)
        let plan = VideoCompressionPlan(source: source, settings: settings)

        if let free = VideoLibraryService.freeDiskBytes(),
           Double(free) < Double(plan.estimatedBytes) * Self.freeSpaceMargin {
            return .failed(.notEnoughSpace)
        }

        let transcoder = VideoTranscoder()
        activeTranscoder = transcoder
        defer { activeTranscoder = nil }
        let outputURL = VideoTranscoder.makeOutputURL()
        let id = item.id

        do {
            try await transcoder.transcode(asset: asset, plan: plan, to: outputURL) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.activeEncodeID == id else { return }
                    self.encodeFraction = value
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            return .failed(.encodeFailed)
        }
        guard await VideoTranscoder.isValidOutput(at: outputURL, expectedDuration: plan.duration) else {
            try? FileManager.default.removeItem(at: outputURL)
            return .failed(.encodeFailed)
        }
        let newBytes = Self.fileBytes(at: outputURL)
        guard newBytes > 0, newBytes < item.fileBytes else {
            try? FileManager.default.removeItem(at: outputURL)
            return .failed(.notSmaller)
        }
        return .ready(EncodedVideo(url: outputURL, bytes: newBytes, duration: plan.duration))
    }

    // MARK: - Current video

    func loadCurrent() async {
        tearDownPlayer()
        source = nil
        thumbnails = []
        isCurrentUnavailable = false
        guard let item = currentItem else { return }
        guard let asset = await VideoLibraryService.shared.loadAVAsset(for: item.asset),
              let loaded = try? await VideoTranscoder.loadSource(from: asset, fileBytes: item.fileBytes)
        else {
            if currentItem?.id == item.id { isCurrentUnavailable = true }
            return
        }
        guard currentItem?.id == item.id, !Task.isCancelled else { return }
        source = loaded
        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: Self.time(Self.playheadInterval), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        player = newPlayer
        currentAsset = asset
        applyTrimToPlayer()
        refreshPreview()
        let images = await Self.makeThumbnails(for: asset, duration: loaded.duration)
        guard currentItem?.id == item.id, !Task.isCancelled else { return }
        thumbnails = images
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            applyTrimToPlayer()
            if playhead >= settings.trimEnd - Self.playheadInterval || playhead < settings.trimStart {
                player.seek(to: Self.time(settings.trimStart), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Shows the frame at `seconds` and keeps playback inside the trimmed range.
    func scrub(to seconds: Double) {
        guard let player else { return }
        pause()
        applyTrimToPlayer()
        playhead = seconds
        player.seek(to: Self.time(seconds), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tick(_ seconds: Double) {
        guard isPlaying else { return }
        playhead = seconds
        guard seconds >= settings.trimEnd - Self.playheadInterval, let player else { return }
        player.seek(to: Self.time(settings.trimStart), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    /// Plays the video at the chosen size and frame rate, so the user sees
    /// what the smaller copy will look like before picking compress.
    private func refreshPreview() {
        previewTask?.cancel()
        guard let item = player?.currentItem, let asset = currentAsset, let plan else { return }
        guard plan.lowersResolution || plan.lowersFrameRate else {
            item.videoComposition = nil
            return
        }
        let size = plan.outputSize
        let frameRate = plan.lowersFrameRate ? plan.frameRate : nil
        previewTask = Task { [weak self] in
            guard let composition = try? await Self.previewComposition(for: asset, size: size, frameRate: frameRate),
                  !Task.isCancelled, self?.player?.currentItem === item
            else { return }
            item.videoComposition = composition
        }
    }

    private static func previewComposition(
        for asset: AVAsset, size: CGSize, frameRate: Double?
    ) async throws -> AVVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let image = request.sourceImage
            let scale = request.renderSize.width / max(1, image.extent.width)
            request.finish(with: image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), context: nil)
        }
        composition.renderSize = size
        if let frameRate {
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        }
        return composition
    }

    private func applyTrimToPlayer() {
        player?.currentItem?.forwardPlaybackEndTime = Self.time(settings.trimEnd)
    }

    private func tearDownPlayer() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        previewTask?.cancel()
        previewTask = nil
        currentAsset = nil
        player?.pause()
        player = nil
        isPlaying = false
        playhead = 0
    }

    // MARK: - Apply

    /// Waits for the encodes still running, saves every smaller copy to
    /// Photos, then asks iOS once to delete the replaced originals and the
    /// videos marked for delete.
    func apply() async {
        guard !isApplying, hasPendingDecisions else { return }
        pause()
        applyCancelled = false
        var result = ApplyResult()

        let toCompress = queue.filter { decisions[$0.id] == .compress }
        let toSave = toCompress.filter { readyCopies[$0.id] == nil }
        for item in toSave where encodeStates[item.id] == nil { startEncode(for: item.id) }
        let total = toSave.count

        while true {
            let unfinished = toSave.filter { !(encodeStates[$0.id]?.isFinished ?? true) }.count
            if unfinished == 0 { break }
            if applyCancelled {
                applyProgress = nil
                return
            }
            applyProgress = ApplyProgress(index: total - unfinished + 1, total: total, fraction: encodeFraction)
            try? await Task.sleep(for: Self.applyPollInterval)
        }
        applyProgress = ApplyProgress(index: total, total: total, fraction: 1)

        for item in toSave {
            var failure: VideoCompressionFailure?
            switch encodeStates[item.id] {
            case .ready(let video):
                do {
                    let copy = try await replacer.makeCopy(
                        originalID: item.id, fromFileAt: video.url, expectedDuration: video.duration
                    )
                    readyCopies[item.id] = copy
                    copyBytes[item.id] = video.bytes
                    await keptStore.add([copy.copyID])
                } catch {
                    failure = .saveFailed
                }
                cancelEncode(for: item.id)
            case .failed(let reason):
                failure = reason
            case .waiting, .encoding, nil:
                failure = .encodeFailed
            }
            if let failure {
                result.failure = result.failure ?? failure
                result.failedCount += 1
                clearDecision(for: item.id)
            }
        }

        let copies = toCompress.compactMap { readyCopies[$0.id] }
        let deleteItems = queue.filter { decisions[$0.id] == .delete }
        let outcome = await replacer.deleteOriginals(of: copies, alsoDeleting: deleteItems.map(\.id))
        for id in outcome.unverifiedOriginalIDs {
            clearDecision(for: id)
            result.failure = result.failure ?? .saveFailed
            result.failedCount += 1
        }

        let keptIDs = queue.filter { decisions[$0.id] == .keep }.map(\.id)
        await keptStore.add(keptIDs)
        result.keptCount = keptIDs.count
        result.deleteDeclined = outcome.wasDeclined

        for item in toCompress where outcome.deletedIDs.contains(item.id) {
            result.compressedCount += 1
            result.savedBytes += max(0, item.fileBytes - (copyBytes[item.id] ?? item.fileBytes))
        }
        for item in deleteItems where outcome.deletedIDs.contains(item.id) {
            result.deletedCount += 1
            result.savedBytes += item.fileBytes
        }

        resolve(Set(keptIDs).union(outcome.deletedIDs))
        sessionSavedBytes += result.savedBytes
        sessionResolvedCount += result.compressedCount + result.deletedCount + result.keptCount
        applyProgress = nil
        lastResult = result
    }

    /// Leaves the apply screen. Encodes keep running in the background.
    func cancelApply() {
        applyCancelled = true
    }

    /// Videos iOS will ask to delete on apply: replaced originals plus deletes.
    var pendingDeleteCount: Int { pendingCount(.compress) + pendingCount(.delete) }

    private func resolve(_ ids: Set<String>) {
        let currentID = currentItem?.id
        let removedBeforeCursor = queue.prefix(currentIndex).filter { ids.contains($0.id) }.count
        queue.removeAll { ids.contains($0.id) }
        for id in ids {
            decisions[id] = nil
            readyCopies[id] = nil
            copyBytes[id] = nil
            cancelEncode(for: id)
            settingsByID[id] = nil
            skippedIDs.remove(id)
        }
        actionHistory.removeAll { ids.contains($0.id) }
        if let currentID, let index = queue.firstIndex(where: { $0.id == currentID }) {
            currentIndex = index
        } else {
            currentIndex = max(0, min(currentIndex - removedBeforeCursor, queue.count))
        }
    }

    // MARK: - Helpers

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    private static func fileBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func makeThumbnails(for asset: AVAsset, duration: Double) async -> [UIImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailMaxSide, height: thumbnailMaxSide)
        var images: [UIImage] = []
        for index in 0..<thumbnailCount {
            let seconds = duration * (Double(index) + 0.5) / Double(thumbnailCount)
            guard let (image, _) = try? await generator.image(at: time(seconds)) else { continue }
            images.append(UIImage(cgImage: image))
        }
        return images
    }
}

extension VideoCompressionFailure: Error {}
