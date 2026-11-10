import CoreGraphics
import Foundation
import Photos

enum VideoResolutionCap: String, CaseIterable, Identifiable, Sendable {
    case original
    case p1080
    case p720

    static let recommended: VideoResolutionCap = .p1080

    var id: Self { self }

    /// Cap for the short side of the frame, so portrait and landscape get the same treatment.
    var shortSide: CGFloat? {
        switch self {
        case .original: nil
        case .p1080:    1080
        case .p720:     720
        }
    }

    var label: String {
        switch self {
        case .original: String(localized: "Original")
        case .p1080:    "1080p"
        case .p720:     "720p"
        }
    }
}

enum VideoFrameRateCap: String, CaseIterable, Identifiable, Sendable {
    case original
    case half
    case third
    case quarter

    static let recommended: VideoFrameRateCap = .half
    static let lowestFrameRate = 24.0
    private static let lowestFrameRateTolerance = 0.5

    var id: Self { self }

    var divisor: Int? {
        switch self {
        case .original: nil
        case .half:     2
        case .third:    3
        case .quarter:  4
        }
    }

    func framesPerSecond(for source: VideoSource) -> Double? {
        guard let divisor, source.frameRate > 0 else { return nil }
        let rate = source.frameRate / Double(divisor)
        return rate >= Self.lowestFrameRate - Self.lowestFrameRateTolerance ? rate : nil
    }
}

enum VideoDecision: String, Sendable {
    case keep
    case compress
    case delete
}

extension VideoResolutionCap {
    /// "Original" plus the caps that would really shrink this video.
    static func options(for source: VideoSource) -> [VideoResolutionCap] {
        let short = min(source.displaySize.width, source.displaySize.height)
        return allCases.filter { cap in cap.shortSide.map { $0 < short } ?? true }
    }

    /// A cap at or above the source changes nothing, so it counts as original.
    func effective(for source: VideoSource) -> VideoResolutionCap {
        Self.options(for: source).contains(self) ? self : .original
    }

    func label(for source: VideoSource) -> String {
        self == .original ? VideoFormat.resolution(source.displaySize) : label
    }
}

extension VideoFrameRateCap {
    static func options(for source: VideoSource) -> [VideoFrameRateCap] {
        allCases.filter { $0 == .original || $0.framesPerSecond(for: source) != nil }
    }

    func effective(for source: VideoSource) -> VideoFrameRateCap {
        Self.options(for: source).contains(self) ? self : .original
    }

    func label(for source: VideoSource) -> String {
        guard source.frameRate > 0 else { return String(localized: "Original") }
        let rate = framesPerSecond(for: source) ?? source.frameRate
        return String(localized: "\(Int(rate.rounded())) fps")
    }
}

/// How many bits each pixel of each frame gets. This, not the frame rate,
/// is what most of the saving comes from, so the user picks it.
enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case original
    case high
    case balanced
    case small

    static let recommended: VideoQuality = .balanced

    var id: Self { self }

    /// nil keeps the source's own rate.
    var bitsPerPixel: Double? {
        switch self {
        case .original: nil
        case .high:     0.12
        case .balanced: 0.08
        case .small:    0.05
        }
    }

    var label: String {
        switch self {
        case .original: String(localized: "Original")
        case .high:     String(localized: "High")
        case .balanced: String(localized: "Balanced")
        case .small:    String(localized: "Small")
        }
    }

    /// Only the levels that really lower this video.
    static func options(for source: VideoSource) -> [VideoQuality] {
        guard let sourceRate = source.videoBitsPerPixel else { return allCases }
        return allCases.filter { quality in quality.bitsPerPixel.map { $0 < sourceRate } ?? true }
    }

    func effective(for source: VideoSource) -> VideoQuality {
        Self.options(for: source).contains(self) ? self : .original
    }
}

struct VideoSource: Equatable, Sendable {
    /// Size as shown on screen (rotation applied).
    var displaySize: CGSize
    /// 0 when unknown (the list estimates before the file is opened).
    var frameRate: Double
    var duration: Double
    var fileBytes: Int64

    /// Bits per pixel per frame of the video track; nil when it can't be told.
    var videoBitsPerPixel: Double? {
        let pixels = Double(displaySize.width * displaySize.height)
        guard duration > 0, pixels > 0 else { return nil }
        let rate = frameRate > 0 ? frameRate : VideoCompressionPlan.fallbackFrameRate
        let videoBitrate = Double(fileBytes) * 8 / duration - Double(VideoCompressionPlan.audioBitrate)
        guard videoBitrate > 0 else { return nil }
        return videoBitrate / (pixels * rate)
    }
}

struct VideoCompressionSettings: Equatable, Sendable {
    var resolution: VideoResolutionCap = .recommended
    var frameRate: VideoFrameRateCap = .recommended
    var quality: VideoQuality = .recommended
    var trimStart: Double = 0
    var trimEnd: Double

    init(
        duration: Double,
        resolution: VideoResolutionCap = .recommended,
        frameRate: VideoFrameRateCap = .recommended,
        quality: VideoQuality = .recommended
    ) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.quality = quality
        trimEnd = duration
    }
}

/// Everything the encoder needs, plus the size estimate shown to the user.
/// Values only ever go down: a video below the caps keeps its size and frame rate.
struct VideoCompressionPlan: Equatable, Sendable {
    static let minimumVideoBitrate = 400_000
    static let audioBitrate = 128_000
    static let containerOverhead = 1.02
    /// Never ask for more than this share of the source bitrate; re-encoding at
    /// the same rate only loses quality.
    static let sourceBitrateCeiling = 0.9
    static let minimumSavingFraction = 0.1
    static let fallbackFrameRate = 30.0
    private static let frameRateTolerance = 0.5
    private static let trimTolerance = 0.1

    let outputSize: CGSize
    let frameRate: Double
    let videoBitrate: Int
    let trimStart: Double
    let duration: Double
    let originalBytes: Int64
    let estimatedBytes: Int64
    /// False when size, frame rate, quality and length all stay as they are.
    let changesVideo: Bool
    let lowersResolution: Bool
    let lowersFrameRate: Bool

    /// Compress is offered only when something is lowered or trimmed and the
    /// file gets clearly smaller.
    var canCompress: Bool { changesVideo && isWorthwhile }

    var savedBytes: Int64 { max(0, originalBytes - estimatedBytes) }

    var isWorthwhile: Bool {
        Double(savedBytes) >= Double(originalBytes) * Self.minimumSavingFraction
    }

    init(source: VideoSource, settings: VideoCompressionSettings) {
        let start = min(max(0, settings.trimStart), source.duration)
        let end = min(max(start, settings.trimEnd), source.duration)
        trimStart = start
        duration = end - start
        originalBytes = source.fileBytes

        outputSize = Self.cappedSize(source.displaySize, shortSide: settings.resolution.shortSide)

        let cap = settings.frameRate.framesPerSecond(for: source)
        if source.frameRate > 0 {
            frameRate = min(source.frameRate, cap ?? source.frameRate)
        } else {
            frameRate = cap ?? Self.fallbackFrameRate
        }

        let shrinks = outputSize != Self.cappedSize(source.displaySize, shortSide: nil)
        let slows = source.frameRate > 0
            ? frameRate < source.frameRate - Self.frameRateTolerance
            : cap != nil
        let trims = duration < source.duration - Self.trimTolerance
        let sourceRate = source.videoBitsPerPixel
        let wantedRate = settings.quality.bitsPerPixel
        let lowersQuality = wantedRate.map { wanted in sourceRate.map { wanted < $0 } ?? true } ?? false
        changesVideo = shrinks || slows || trims || lowersQuality
        lowersResolution = shrinks
        lowersFrameRate = slows

        let bitsPerPixel = [wantedRate, sourceRate].compactMap { $0 }.min()
            ?? VideoQuality.recommended.bitsPerPixel ?? 0
        let target = Double(outputSize.width * outputSize.height) * frameRate * bitsPerPixel
        var bitrate = max(Double(Self.minimumVideoBitrate), target)
        if source.duration > 0 {
            let sourceTotal = Double(source.fileBytes) * 8 / source.duration
            let ceiling = (sourceTotal - Double(Self.audioBitrate)) * Self.sourceBitrateCeiling
            bitrate = min(bitrate, max(Double(Self.minimumVideoBitrate), ceiling))
        }
        videoBitrate = Int(bitrate)

        let bits = Double(videoBitrate + Self.audioBitrate) * duration * Self.containerOverhead
        estimatedBytes = Int64(bits / 8)
    }

    static func cappedSize(_ size: CGSize, shortSide cap: CGFloat?) -> CGSize {
        let short = min(size.width, size.height)
        let scale = cap.map { short > $0 ? $0 / short : 1 } ?? 1
        return CGSize(width: even(size.width * scale), height: even(size.height * scale))
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }
}

/// Drops frames so the output never runs faster than the target rate.
/// Kept frames keep their own timestamps, so audio stays in sync.
final class FrameRateDecimator {
    private static let tolerance = 0.001
    private static let strideTolerance = 0.05
    private static let minimumStride = 2
    private let interval: Double?
    private let stride: Int?
    private var nextTime: Double?
    private var frameIndex = 0

    static func wholeStride(from sourceFrameRate: Double, to targetFrameRate: Double) -> Int? {
        guard sourceFrameRate > 0, targetFrameRate > 0 else { return nil }
        let ratio = sourceFrameRate / targetFrameRate
        let whole = ratio.rounded()
        guard Int(whole) >= minimumStride, abs(ratio - whole) <= strideTolerance else { return nil }
        return Int(whole)
    }

    init(sourceFrameRate: Double, targetFrameRate: Double) {
        let lowers = targetFrameRate > 0 && targetFrameRate < sourceFrameRate - 0.5
        stride = lowers ? Self.wholeStride(from: sourceFrameRate, to: targetFrameRate) : nil
        interval = lowers && stride == nil ? 1 / targetFrameRate : nil
    }

    func shouldKeep(presentationSeconds time: Double) -> Bool {
        if let stride {
            defer { frameIndex += 1 }
            return frameIndex % stride == 0
        }
        guard let interval else { return true }
        guard let next = nextTime else {
            nextTime = time + interval
            return true
        }
        guard time >= next - Self.tolerance else { return false }
        var following = next + interval
        while following <= time { following += interval }
        nextTime = following
        return true
    }
}

struct VideoItem: Identifiable, Hashable {
    let asset: PHAsset
    let fileBytes: Int64

    var id: String { asset.localIdentifier }

    /// What Photos knows before the file is opened. Frame rate is unknown (0).
    var metadataSource: VideoSource {
        VideoSource(
            displaySize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight),
            frameRate: 0,
            duration: asset.duration,
            fileBytes: fileBytes
        )
    }

    var recommendedPlan: VideoCompressionPlan {
        VideoCompressionPlan(source: metadataSource, settings: VideoCompressionSettings(duration: asset.duration))
    }
}

enum VideoFormat {
    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func resolution(_ size: CGSize) -> String {
        let short = Int(min(size.width, size.height))
        return short >= 2160 ? "4K" : "\(short)p"
    }
}
