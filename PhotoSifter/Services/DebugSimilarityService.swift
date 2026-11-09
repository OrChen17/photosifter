#if DEBUG && targetEnvironment(simulator)
import Photos
import Foundation

/// Debug-only stand-in for `SimilarityService`, wired into `GroupingService.shared`
/// when the app is built for the iOS Simulator. The simulator's CoreML/espresso
/// runtime cannot load the `VNGenerateImageFeaturePrintRequest` model, so the
/// real similarity path returns nothing and the UI shows "All Clear". This
/// stub treats any two photos taken within `maxGap` seconds as near-duplicates
/// so we can exercise the rest of the app — grouping UI, swipe deck, summary —
/// against the simulator's photo library.
///
/// Launch with the `SLOW_SCAN` argument to add a device-like delay per photo,
/// so the scan progress UI can be checked on the 100-photo seed library.
///
/// NOT compiled into device or release builds.
struct DebugTimeProximitySimilarity: SimilarityProviding {
    static let slowScanArgument = "SLOW_SCAN"
    /// Rough cost of one Vision feature print on a recent iPhone.
    private static let slowScanDelay: Duration = .milliseconds(120)

    /// Photos within this gap are reported as "similar" (distance 0.1).
    /// 30s is wide enough to merge typical phone bursts but narrow enough
    /// to keep separate moments apart.
    let maxGap: TimeInterval = 30

    struct Signature: SimilaritySignature {
        let date: Date?
        let maxGap: TimeInterval

        func distance(to other: any SimilaritySignature) throws -> Float {
            guard let other = other as? Signature, let a = date, let b = other.date else { return 0.9 }
            return abs(a.timeIntervalSince(b)) <= maxGap ? 0.1 : 0.9
        }
    }

    func signature(for asset: PHAsset) async throws -> any SimilaritySignature {
        if ProcessInfo.processInfo.arguments.contains(Self.slowScanArgument) {
            try await Task.sleep(for: Self.slowScanDelay)
        }
        return Signature(date: asset.creationDate, maxGap: maxGap)
    }
}
#endif
