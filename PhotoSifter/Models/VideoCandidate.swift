import Foundation

/// What a video is today, read from `PHAsset` + its `AVAsset` video track.
/// Dimensions are the *displayed* (orientation-applied) size, so a portrait
/// 4K clip is 2160×3840.
struct VideoSpec: Equatable, Hashable, Codable {
    var width: Int
    var height: Int
    /// `nil` when the frame rate couldn't be read (e.g. iCloud-only asset with
    /// cloud download disabled). Such videos are judged on resolution alone.
    var fps: Double?
    var duration: TimeInterval
    var fileBytes: Int64

    var shortSide: Int { min(width, height) }
}

/// A video that is bigger than 1080p and/or faster than 30 fps, plus what it
/// would become after shrinking. Holds the localIdentifier, not the `PHAsset`,
/// so view-model tests can build candidates without a photo library.
struct VideoCandidate: Identifiable, Equatable, Hashable {
    let id: String              // PHAsset.localIdentifier
    let spec: VideoSpec
    let creationDate: Date?

    var target: VideoSpec { VideoShrinkPlan.target(for: spec) }
    var estimatedBytes: Int64 { VideoShrinkPlan.estimatedOutputBytes(for: spec) }
    var estimatedSavings: Int64 { max(0, spec.fileBytes - estimatedBytes) }
}

enum VideoSortOrder: String, CaseIterable {
    case largest
    case mostSavings
    case newest
    case oldest

    var label: String {
        switch self {
        case .largest:     return "Largest"
        case .mostSavings: return "Most savings"
        case .newest:      return "Newest"
        case .oldest:      return "Oldest"
        }
    }

    func sorted(_ candidates: [VideoCandidate]) -> [VideoCandidate] {
        // Ties fall back to the identifier so the list order is stable between scans.
        candidates.sorted { a, b in
            switch self {
            case .largest:
                if a.spec.fileBytes != b.spec.fileBytes { return a.spec.fileBytes > b.spec.fileBytes }
            case .mostSavings:
                if a.estimatedSavings != b.estimatedSavings { return a.estimatedSavings > b.estimatedSavings }
            case .newest:
                let da = a.creationDate ?? .distantPast, db = b.creationDate ?? .distantPast
                if da != db { return da > db }
            case .oldest:
                let da = a.creationDate ?? .distantFuture, db = b.creationDate ?? .distantFuture
                if da != db { return da < db }
            }
            return a.id < b.id
        }
    }
}

/// The rules for "too big": anything above 1080p (short side) or above 30 fps
/// is shrunk to fit 1080p at 30 fps. Pure, so it is unit-testable off-device.
enum VideoShrinkPlan {
    static let maxShortSide = 1080
    static let maxFPS: Double = 30
    /// 29.97 and 30.0x readings are "30 fps" — only drop clearly faster footage.
    static let fpsTolerance: Double = 0.5
    /// Bitrate the export lands near for 1080p30 HEVC, video + audio. Apple's
    /// camera records 1080p30 HEVC at ~60 MB/min (8 Mbps); export presets run a
    /// little higher, so estimates stay conservative rather than over-promise.
    static let targetBitsPerSecond: Double = 10_000_000
    /// A video only makes the list if shrinking frees at least this much.
    static let minimumSavingsBytes: Int64 = 5_000_000

    static func needsResize(_ spec: VideoSpec) -> Bool {
        spec.shortSide > maxShortSide
    }

    static func needsFrameRateDrop(_ spec: VideoSpec) -> Bool {
        guard let fps = spec.fps else { return false }
        return fps > maxFPS + fpsTolerance
    }

    static func isCandidate(_ spec: VideoSpec) -> Bool {
        guard needsResize(spec) || needsFrameRateDrop(spec) else { return false }
        return spec.fileBytes - estimatedOutputBytes(for: spec) >= minimumSavingsBytes
    }

    /// Output size scaled so the short side is at most 1080, aspect kept,
    /// both sides even (H.264/HEVC encoders reject odd dimensions).
    static func targetDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        let short = min(width, height)
        guard short > maxShortSide, short > 0 else { return (width, height) }
        let scale = Double(maxShortSide) / Double(short)
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    static func target(for spec: VideoSpec) -> VideoSpec {
        let dims = targetDimensions(width: spec.width, height: spec.height)
        let fps = spec.fps.map { needsFrameRateDrop(spec) ? maxFPS : $0 }
        return VideoSpec(
            width: dims.width,
            height: dims.height,
            fps: fps,
            duration: spec.duration,
            fileBytes: estimatedOutputBytes(for: spec)
        )
    }

    /// Rough output size: duration × target bitrate, scaled down for clips that
    /// end up smaller than 1920×1080 or slower than 30 fps. Never more than the
    /// original — an export that would grow the file is a no-op.
    static func estimatedOutputBytes(for spec: VideoSpec) -> Int64 {
        let dims = targetDimensions(width: spec.width, height: spec.height)
        let pixelRatio = min(1, Double(dims.width * dims.height) / Double(1920 * 1080))
        let fpsRatio = min(1, (spec.fps ?? maxFPS) / maxFPS)
        let bits = targetBitsPerSecond * max(0, spec.duration) * pixelRatio * fpsRatio
        return min(spec.fileBytes, Int64((bits / 8).rounded()))
    }

    // MARK: - Labels

    /// "4K", "1440p", "1080p" — named by the short side like the Camera app.
    static func resolutionLabel(_ spec: VideoSpec) -> String {
        let short = spec.shortSide
        if short >= 2160 { return "4K" }
        if short >= 1440 { return "1440p" }
        return "\(short)p"
    }

    /// "60 fps", "29.97" rounds to "30 fps"; nil when unknown.
    static func fpsLabel(_ spec: VideoSpec) -> String? {
        guard let fps = spec.fps, fps > 0 else { return nil }
        return "\(Int(fps.rounded())) fps"
    }
}
