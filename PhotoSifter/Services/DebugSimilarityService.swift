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
/// NOT compiled into device or release builds.
struct DebugTimeProximitySimilarity: SimilarityProviding {
    /// Photos within this gap are reported as "similar" (distance 0.1).
    /// 30s is wide enough to merge typical phone bursts but narrow enough
    /// to keep separate moments apart.
    let maxGap: TimeInterval = 30

    func distance(between a: PHAsset, and b: PHAsset) async throws -> Float {
        guard let da = a.creationDate, let db = b.creationDate else { return 0.9 }
        return abs(da.timeIntervalSince(db)) <= maxGap ? 0.1 : 0.9
    }
}
#endif
