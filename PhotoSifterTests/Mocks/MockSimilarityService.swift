import Foundation
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
    /// in GroupingService for clustering to fire.
    var similarDistance: Float = 0.1

    /// Distance returned for everything else.
    var dissimilarDistance: Float = 0.9

    /// Optional error injection — keys are localIdentifiers that should fail.
    var failingAssets: Set<String> = []

    /// Simulated cost of one signature, to observe concurrency and ordering.
    var signatureDelay: Duration = .zero

    enum MockError: Error { case injected }

    private let lock = NSLock()
    private var inFlight = 0
    private var _maxInFlight = 0
    private var _requestedIDs: [String] = []

    /// Highest number of signatures computed at the same time.
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    /// Asset IDs in the order their signatures were requested.
    var requestedIDs: [String] { lock.withLock { _requestedIDs } }

    struct Signature: SimilaritySignature {
        let id: String
        let owner: MockSimilarityService

        func distance(to other: any SimilaritySignature) throws -> Float {
            guard let other = other as? Signature else { throw MockError.injected }
            return owner.distance(id, other.id)
        }
    }

    func signature(for asset: PHAsset) async throws -> any SimilaritySignature {
        let id = asset.localIdentifier
        lock.withLock {
            _requestedIDs.append(id)
            inFlight += 1
            _maxInFlight = max(_maxInFlight, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        if signatureDelay > .zero {
            try await Task.sleep(for: signatureDelay)
        }
        if failingAssets.contains(id) { throw MockError.injected }
        return Signature(id: id, owner: self)
    }

    fileprivate func distance(_ a: String, _ b: String) -> Float {
        similarPairs.contains([a, b]) ? similarDistance : dissimilarDistance
    }
}
