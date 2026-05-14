import XCTest
import Vision
import Photos
@testable import PhotoSifter

final class SimilarityServiceTests: XCTestCase {

    private let service = SimilarityService.shared

    // MARK: - Feature print computation

    func testFeaturePrint_returnsSameResultForSameAsset() async throws {
        let assets = try requirePhotoAssets(minimum: 1)
        let asset = assets[0]

        let fp1 = try await service.featurePrint(for: asset)
        let fp2 = try await service.featurePrint(for: asset)

        // Should hit the cache — same object reference
        XCTAssertTrue(fp1 === fp2, "Cache should return the identical observation object")
    }

    func testFeaturePrint_differentAssetsProduceDifferentPrints() async throws {
        let assets = try requirePhotoAssets(minimum: 2)

        let fp0 = try await service.featurePrint(for: assets[0])
        let fp1 = try await service.featurePrint(for: assets[1])

        // They may be similar if images happen to look alike, but the objects are distinct
        XCTAssertFalse(fp0 === fp1)
    }

    // MARK: - Distance

    func testDistance_selfToSelf_isZero() async throws {
        let assets = try requirePhotoAssets(minimum: 1)
        let fp = try await service.featurePrint(for: assets[0])
        let dist = try await service.distance(from: fp, to: fp)
        XCTAssertEqual(dist, 0.0, accuracy: 0.001)
    }

    func testDistance_isSymmetric() async throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let fpA = try await service.featurePrint(for: assets[0])
        let fpB = try await service.featurePrint(for: assets[1])

        let ab = try await service.distance(from: fpA, to: fpB)
        let ba = try await service.distance(from: fpB, to: fpA)

        XCTAssertEqual(ab, ba, accuracy: 0.001, "Distance should be symmetric")
    }

    func testDistance_nonNegative() async throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let fpA = try await service.featurePrint(for: assets[0])
        let fpB = try await service.featurePrint(for: assets[1])

        let dist = try await service.distance(from: fpA, to: fpB)
        XCTAssertGreaterThanOrEqual(dist, 0.0)
    }

    // MARK: - Cache invalidation

    func testClearCache_causesNewComputationOnNextCall() async throws {
        let assets = try requirePhotoAssets(minimum: 1)
        let asset = assets[0]

        let fp1 = try await service.featurePrint(for: asset)
        await service.clearCache()
        let fp2 = try await service.featurePrint(for: asset)

        // After clear, the observation should be recomputed — a new object
        XCTAssertFalse(fp1 === fp2, "After cache clear, a new observation should be created")
    }
}
