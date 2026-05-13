import Vision
import Photos
import UIKit

actor SimilarityService {
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

    func clearCache() {
        cache.removeAll()
    }

    private func loadImage(for asset: PHAsset) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            let targetSize = CGSize(width: 512, height: 512)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
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
            let request = VNGenerateImageFeaturePrintRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let result = request.results?.first as? VNFeaturePrintObservation else {
                    continuation.resume(throwing: SimilarityError.noFeaturePrint)
                    return
                }
                continuation.resume(returning: result)
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum SimilarityError: Error {
    case imageLoadFailed
    case noFeaturePrint
}
