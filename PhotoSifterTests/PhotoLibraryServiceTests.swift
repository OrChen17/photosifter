import XCTest
import Photos
import UIKit
@testable import PhotoSifter

final class PhotoLibraryServiceTests: XCTestCase {

    // MARK: - fetchAllAssets(since:) — incremental scan cutoff

    func testFetchAllAssets_withNilCutoff_returnsAllImagesAsBefore() async throws {
        _ = try requirePhotoAssets(minimum: 1)
        let service = PhotoLibraryService.shared
        let all = await service.fetchAllAssets()
        XCTAssertGreaterThan(all.count, 0, "Library must have at least one non-screenshot image")
    }

    func testFetchAllAssets_withDistantFutureCutoff_returnsEmpty() async throws {
        _ = try requirePhotoAssets(minimum: 1)
        let service = PhotoLibraryService.shared
        let future = Date(timeIntervalSinceNow: 60 * 60 * 24 * 365 * 10)
        let filtered = await service.fetchAllAssets(since: future)
        XCTAssertEqual(filtered.count, 0, "Cutoff far in the future must exclude every existing photo")
    }

    func testFetchAllAssets_withDistantPastCutoff_matchesNilCutoffCount() async throws {
        _ = try requirePhotoAssets(minimum: 1)
        let service = PhotoLibraryService.shared
        let baseline = await service.fetchAllAssets()
        let withFloor = await service.fetchAllAssets(since: .distantPast)
        XCTAssertEqual(
            withFloor.count, baseline.count,
            "Cutoff at distantPast must be equivalent to no cutoff"
        )
    }

    /// Picks the median asset's creationDate as a real-world cutoff and verifies
    /// that fetching with that cutoff returns strictly newer assets only.
    func testFetchAllAssets_withMidLibraryCutoff_returnsOnlyAssetsCreatedAfterCutoff() async throws {
        _ = try requirePhotoAssets(minimum: 3)
        let service = PhotoLibraryService.shared
        let baseline = await service.fetchAllAssets()
        try XCTSkipIf(baseline.count < 3, "Need ≥3 assets to pick a meaningful mid-cutoff")

        let dates = baseline.compactMap { $0.creationDate }.sorted()
        try XCTSkipIf(
            Set(dates).count < 2,
            "Need assets with distinct creation dates to test cutoff filtering"
        )
        let median = dates[dates.count / 2]

        let newer = await service.fetchAllAssets(since: median)
        for asset in newer {
            if let d = asset.creationDate {
                XCTAssertGreaterThan(
                    d, median,
                    "Every returned asset must have creationDate strictly after the cutoff"
                )
            }
        }
        // Strict inequality means the cutoff itself is excluded — counts should differ.
        XCTAssertLessThan(
            newer.count, baseline.count,
            "Filtering by a mid-library cutoff must drop at least one asset"
        )
    }

    // MARK: - loadThumbnailStream — progressive delivery

    func testLoadThumbnailStream_yieldsAtLeastOneImageAndFinishes() async throws {
        let assets = try requirePhotoAssets(minimum: 1)
        let service = PhotoLibraryService.shared

        let stream = await service.loadThumbnailStream(
            for: assets[0],
            size: CGSize(width: 200, height: 200)
        )

        var images: [UIImage] = []
        for await img in stream {
            images.append(img)
        }

        XCTAssertGreaterThanOrEqual(
            images.count, 1,
            "Stream must yield at least one image (HQ) for a valid asset"
        )
        // The last yield is the HQ image; consumers rely on this to upgrade
        // a degraded preview. We can't assert HQ-vs-degraded without inspecting
        // info dict, but verifying the stream finishes proves the HQ callback fired.
    }
}
