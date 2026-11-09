import Vision
import Photos
import UIKit

/// A per-asset fingerprint. `GroupingService` computes one per photo (many at
/// once), then compares them pairwise with plain synchronous calls.
protocol SimilaritySignature: Sendable {
    /// Smaller = more similar. Throws if the two signatures can't be compared.
    func distance(to other: any SimilaritySignature) throws -> Float
}

/// Abstracts the asset-similarity capability so tests can plug in a
/// deterministic mock — useful on iOS Simulator, where the CoreML/espresso
/// runtime can't load the VNGenerateImageFeaturePrintRequest model.
protocol SimilarityProviding: Sendable {
    /// Computes the asset's signature. Throws if it can't be computed; the
    /// asset is then left out of grouping.
    func signature(for asset: PHAsset) async throws -> any SimilaritySignature
}

extension SimilarityProviding {
    func distance(between a: PHAsset, and b: PHAsset) async throws -> Float {
        let sa = try await signature(for: a)
        let sb = try await signature(for: b)
        return try sa.distance(to: sb)
    }
}

/// `VNFeaturePrintObservation` is immutable once Vision returns it.
struct FeaturePrintSignature: SimilaritySignature, @unchecked Sendable {
    let observation: VNFeaturePrintObservation

    func distance(to other: any SimilaritySignature) throws -> Float {
        guard let other = other as? FeaturePrintSignature else {
            throw SimilarityError.incompatibleSignature
        }
        var dist: Float = 0
        try observation.computeDistance(&dist, to: other.observation)
        return dist
    }
}

actor SimilarityService: SimilarityProviding {
    static let shared = SimilarityService()

    private static let imageTargetSize = CGSize(width: 512, height: 512)

    private var cache: [String: VNFeaturePrintObservation] = [:]

    /// Cached lookup for tests and diagnostics. The scan uses `signature(for:)`.
    func featurePrint(for asset: PHAsset) async throws -> VNFeaturePrintObservation {
        if let cached = cache[asset.localIdentifier] { return cached }
        let observation = try await Self.computeFeaturePrint(for: asset)
        cache[asset.localIdentifier] = observation
        return observation
    }

    /// Not cached and not isolated to the actor, so the scan can run several
    /// at once and drop each print as soon as its time bucket is done. The old
    /// actor-isolated path ran every Vision request one after another and kept
    /// every print in memory for the whole scan.
    nonisolated func signature(for asset: PHAsset) async throws -> any SimilaritySignature {
        FeaturePrintSignature(observation: try await Self.computeFeaturePrint(for: asset))
    }

    func distance(
        from a: VNFeaturePrintObservation,
        to b: VNFeaturePrintObservation
    ) throws -> Float {
        var dist: Float = 0
        try a.computeDistance(&dist, to: b)
        return dist
    }

    func clearCache() {
        cache.removeAll()
    }

    private static func computeFeaturePrint(for asset: PHAsset) async throws -> VNFeaturePrintObservation {
        let image = try await loadImage(for: asset)
        try Task.checkCancellation()
        return try featurePrint(of: image)
    }

    private static func loadImage(for asset: PHAsset) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            // .fastFormat returns nil when no fast cache exists (e.g. assets
            // freshly imported via `simctl addmedia`). highQualityFormat
            // delivers a single, reliable callback.
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = AppSettings.cloudDownloadEnabled
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: imageTargetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                if let cgImage = image?.cgImage {
                    continuation.resume(returning: cgImage)
                } else {
                    continuation.resume(throwing: SimilarityError.imageLoadFailed)
                }
            }
        }
    }

    private static func featurePrint(of image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw SimilarityError.noFeaturePrint
        }
        return observation
    }
}

enum SimilarityError: Error {
    case imageLoadFailed
    case noFeaturePrint
    case incompatibleSignature
}
