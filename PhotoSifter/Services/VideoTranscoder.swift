import AVFoundation
import VideoToolbox

enum VideoTranscodeError: Error, Equatable {
    case noVideoTrack
    case cannotRead
    case cannotWrite
}

/// Re-encodes one video to HEVC at the plan's size, frame rate and bitrate.
/// Writes only to the given temp file; the photo library is never touched here.
final class VideoTranscoder: @unchecked Sendable {
    static let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VideoCompression", isDirectory: true)
    private static let outputExtension = "mov"
    private static let durationTolerance = 0.5
    private static let audioSampleRate = 44_100.0
    private static let maxAudioChannels = 2
    private static let keyFrameIntervalSeconds = 2.0
    private static let timescale: CMTimeScale = 600

    private let lock = NSLock()
    private var cancelled = false
    private let queue = DispatchQueue(label: "com.flickpic.video-transcoder")

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }

    static func makeOutputURL() -> URL {
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        return workDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(outputExtension)
    }

    /// Removes leftovers from a run that was killed mid-encode.
    static func clearWorkDirectory() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    static func loadSource(from asset: AVAsset, fileBytes: Int64) async throws -> VideoSource {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoTranscodeError.noVideoTrack
        }
        let (naturalSize, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        return VideoSource(
            displaySize: displaySize(naturalSize: naturalSize, transform: transform),
            frameRate: Double(frameRate),
            duration: duration.seconds,
            fileBytes: fileBytes
        )
    }

    static func displaySize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// True when the file plays, has a video track and has the expected length.
    static func isValidOutput(at url: URL, expectedDuration: Double) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let (duration, isPlayable) = try? await asset.load(.duration, .isPlayable),
              let tracks = try? await asset.loadTracks(withMediaType: .video)
        else { return false }
        return isPlayable && !tracks.isEmpty && abs(duration.seconds - expectedDuration) <= durationTolerance
    }

    func transcode(
        asset: AVAsset,
        plan: VideoCompressionPlan,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await run(asset: asset, plan: plan, outputURL: outputURL, progress: progress)
        } onCancel: {
            cancel()
        }
    }

    private func run(
        asset: AVAsset,
        plan: VideoCompressionPlan,
        outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoTranscodeError.noVideoTrack
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (naturalSize, transform, sourceFrameRate, formats) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions
        )
        let isHDR = try await videoTrack.load(.mediaCharacteristics).contains(.containsHDRVideo)
        let metadata = try await asset.load(.metadata)

        let range = CMTimeRange(
            start: CMTime(seconds: plan.trimStart, preferredTimescale: Self.timescale),
            duration: CMTime(seconds: plan.duration, preferredTimescale: Self.timescale)
        )

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.metadata = metadata

        let pixelFormat = isHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoTranscodeError.cannotRead }
        reader.add(videoOutput)

        let display = Self.displaySize(naturalSize: naturalSize, transform: transform)
        let isQuarterTurn = (display.width > display.height) != (naturalSize.width > naturalSize.height)
        let encodedSize = isQuarterTurn
            ? CGSize(width: plan.outputSize.height, height: plan.outputSize.width)
            : plan.outputSize

        var videoSettings = Self.videoSettings(
            codec: .hevc, size: encodedSize, plan: plan, isHDR: isHDR, format: formats.first
        )
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            videoSettings = Self.videoSettings(
                codec: .h264, size: encodedSize, plan: plan, isHDR: false, format: formats.first
            )
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { throw VideoTranscodeError.cannotWrite }
        writer.add(videoInput)

        var pumps: [Pump] = []
        let decimator = FrameRateDecimator(sourceFrameRate: Double(sourceFrameRate), targetFrameRate: plan.frameRate)
        let startSeconds = range.start.seconds
        let length = max(plan.duration, 0.001)
        pumps.append(Pump(output: videoOutput, input: videoInput) { sample in
            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard decimator.shouldKeep(presentationSeconds: seconds) else { return false }
            progress(min(1, max(0, (seconds - startSeconds) / length)))
            return true
        })

        if let audioTrack {
            let channels = try await Self.channelCount(of: audioTrack)
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.audioSampleRate,
                AVNumberOfChannelsKey: channels,
            ])
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.audioSampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: VideoCompressionPlan.audioBitrate / Self.maxAudioChannels * channels,
            ])
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                pumps.append(Pump(output: audioOutput, input: audioInput) { _ in true })
            }
        }

        guard reader.startReading() else { throw reader.error ?? VideoTranscodeError.cannotRead }
        guard writer.startWriting() else { throw writer.error ?? VideoTranscodeError.cannotWrite }
        writer.startSession(atSourceTime: range.start)

        await drive(pumps)

        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? VideoTranscodeError.cannotRead
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VideoTranscodeError.cannotWrite }
        progress(1)
    }

    // MARK: - Sample pumping

    private final class Pump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let shouldAppend: (CMSampleBuffer) -> Bool
        var isDone = false

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput, shouldAppend: @escaping (CMSampleBuffer) -> Bool) {
            self.output = output
            self.input = input
            self.shouldAppend = shouldAppend
        }
    }

    /// Moves samples from every reader output to its writer input. All pumps run
    /// on one serial queue, so a failure on one track can close the others and
    /// the wait below always ends.
    private func drive(_ pumps: [Pump]) async {
        let group = DispatchGroup()
        let finish: (Pump) -> Void = { pump in
            guard !pump.isDone else { return }
            pump.isDone = true
            pump.input.markAsFinished()
            group.leave()
        }
        pumps.forEach { _ in group.enter() }
        for pump in pumps {
            pump.input.requestMediaDataWhenReady(on: queue) { [self] in
                while !pump.isDone, pump.input.isReadyForMoreMediaData {
                    let keepGoing = autoreleasepool {
                        guard !isCancelled, let sample = pump.output.copyNextSampleBuffer() else {
                            if isCancelled { pumps.forEach(finish) } else { finish(pump) }
                            return false
                        }
                        guard pump.shouldAppend(sample) else { return true }
                        guard pump.input.append(sample) else {
                            pumps.forEach(finish)
                            return false
                        }
                        return true
                    }
                    guard keepGoing else { return }
                }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: queue) { continuation.resume() }
        }
    }

    // MARK: - Settings

    private static func videoSettings(
        codec: AVVideoCodecType,
        size: CGSize,
        plan: VideoCompressionPlan,
        isHDR: Bool,
        format: CMFormatDescription?
    ) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: plan.videoBitrate,
            AVVideoExpectedSourceFrameRateKey: plan.frameRate,
            AVVideoMaxKeyFrameIntervalDurationKey: keyFrameIntervalSeconds,
        ]
        if codec == .hevc {
            compression[AVVideoProfileLevelKey] = isHDR
                ? kVTProfileLevel_HEVC_Main10_AutoLevel
                : kVTProfileLevel_HEVC_Main_AutoLevel
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let color = format.flatMap(colorProperties(of:)) {
            settings[AVVideoColorPropertiesKey] = color
        }
        return settings
    }

    /// Carries the source colour space over, so HDR stays HDR and SDR is not re-tagged.
    private static func colorProperties(of format: CMFormatDescription) -> [String: Any]? {
        guard let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any],
              let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries],
              let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction],
              let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix]
        else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
    }

    private static func channelCount(of track: AVAssetTrack) async throws -> Int {
        let formats = try await track.load(.formatDescriptions)
        let source = formats.first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
            .map(Int.init) ?? maxAudioChannels
        return min(max(1, source), maxAudioChannels)
    }
}
