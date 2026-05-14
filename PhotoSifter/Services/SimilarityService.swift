import Vision
import Photos
import UIKit

/// Abstracts the asset-similarity capability so tests can plug in a
/// deterministic mock — useful on iOS Simulator, where the CoreML/espresso
/// runtime can't load the VNGenerateImageFeaturePrintRequest model.
protocol SimilarityProviding: Sendable {
    /// Returns the feature-print distance between two assets.
    /// Smaller = more similar. Throws if either asset's print can't be computed.
    func distance(between a: PHAsset, and b: PHAsset) async throws -> Float
}

actor SimilarityService: SimilarityProviding {
    static let shared = SimilarityService()

    private var cache: [String: VNFeaturePrintObservation] = [:]

    func featurePrint(for asset: PHAsset) async throws -> VNFeaturePrintObservation {
        if let cached = cache[asset.localIdentifier] { return cached }

        let image = try await loadImage(for: asset)
        let observation = try await computeFeaturePrint(for: image)
        cache[asset.localIdentifier] = observation
        return observation
    }

    func distance(
        from a: VNFeaturePrintObservation,
        to b: VNFeaturePrintObservation
    ) throws -> Float {
        var dist: Float = 0
        try a.computeDistance(&dist, to: b)
        return dist
    }

    func distance(between a: PHAsset, and b: PHAsset) async throws -> Float {
        let pa = try await featurePrint(for: a)
        let pb = try await featurePrint(for: b)
        return try distance(from: pa, to: pb)
    }

    func clearCache() {
        cache.removeAll()
    }

    private func loadImage(for asset: PHAsset) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            // .fastFormat returns nil when no fast cache exists (e.g. assets
            // freshly imported via `simctl addmedia`). highQualityFormat
            // delivers a single, reliable callback.
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let targetSize = CGSize(width: 512, height: 512)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
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

    private func computeFeaturePrint(for image: CGImage) async throws -> VNFeaturePrintObservation {
        try await withCheckedThrowingContinuation { continuation in
            // `perform([request])` invokes the request's completion handler
            // synchronously *and* may throw — guard against double-resume.
            final class Once { var fired = false }
            let once = Once()
            func resume(_ result: Result<VNFeaturePrintObservation, Error>) {
                guard !once.fired else { return }
                once.fired = true
                switch result {
                case .success(let v): continuation.resume(returning: v)
                case .failure(let e): continuation.resume(throwing: e)
                }
            }
            let request = VNGenerateImageFeaturePrintRequest { request, error in
                if let error { resume(.failure(error)); return }
                guard let r = request.results?.first as? VNFeaturePrintObservation else {
                    resume(.failure(SimilarityError.noFeaturePrint)); return
                }
                resume(.success(r))
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                resume(.failure(error))
            }
        }
    }
}

enum SimilarityError: Error {
    case imageLoadFailed
    case noFeaturePrint
}
