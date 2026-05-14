import Photos
@testable import PhotoSifter

/// Deterministic SimilarityProviding used by tests that want to exercise
/// GroupingService clustering without depending on Vision/CoreML (broken
/// on iOS Simulator). Configure `similarPairs` with sets of local
/// identifiers that should be treated as duplicates.
final class MockSimilarityService: SimilarityProviding, @unchecked Sendable {

    /// Each entry is a pair of localIdentifiers considered "near-duplicates".
    /// Order within the pair doesn't matter.
    var similarPairs: [Set<String>] = []

    /// Distance returned for pairs declared similar. Must be < the threshold
    /// in GroupingService (0.65) for clustering to fire.
    var similarDistance: Float = 0.1

    /// Distance returned for everything else.
    var dissimilarDistance: Float = 0.9

    /// Optional error injection — keys are localIdentifiers that should fail.
    var failingAssets: Set<String> = []

    enum MockError: Error { case injected }

    func distance(between a: PHAsset, and b: PHAsset) async throws -> Float {
        if failingAssets.contains(a.localIdentifier) || failingAssets.contains(b.localIdentifier) {
            throw MockError.injected
        }
        let key: Set<String> = [a.localIdentifier, b.localIdentifier]
        return similarPairs.contains(key) ? similarDistance : dissimilarDistance
    }
}
