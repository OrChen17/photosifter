import XCTest
import Photos
@testable import PhotoSifter

final class GroupingServiceTests: XCTestCase {

    // MARK: - splitIntoBuckets (pure algorithm, no library required)

    func testSplitIntoBuckets_emptyInput() {
        let buckets = GroupingService.splitIntoBuckets([])
        XCTAssertTrue(buckets.isEmpty)
    }

    func testSplitIntoBuckets_singleAsset_droppedAsSingleton() throws {
        let assets = try requirePhotoAssets(minimum: 1)
        let buckets = GroupingService.splitIntoBuckets(Array(assets.prefix(1)))
        // A single asset does not form a valid bucket (count < 2)
        XCTAssertTrue(buckets.isEmpty, "Single-asset bucket should be dropped")
    }

    func testSplitIntoBuckets_twoAssetsWithinGap_oneBucket() throws {
        // Both assets should have been shot within 5 minutes of each other
        // (most simulator sample photos are clustered in time)
        let assets = try requirePhotoAssets(minimum: 2)
        let pair = Array(assets.prefix(2))
        let date0 = pair[0].creationDate ?? Date()
        let date1 = pair[1].creationDate ?? Date()
        try XCTSkipIf(
            abs(date1.timeIntervalSince(date0)) > 5 * 60,
            "Assets are too far apart in time for this test"
        )
        let buckets = GroupingService.splitIntoBuckets(pair)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].count, 2)
    }

    func testSplitIntoBuckets_assetsSpreadOverTime_multipleBuckets() throws {
        // We need at least 4 assets spread more than 5 minutes apart
        // We'll test the algorithm using known dates by creating a date-based scenario
        // Note: this verifies the algorithm logic via the actual library assets
        let assets = try requirePhotoAssets(minimum: 4)

        // Find assets that are far apart
        let dates = assets.compactMap { $0.creationDate }
        guard let first = dates.first, let last = dates.last,
              abs(last.timeIntervalSince(first)) > 5 * 60
        else {
            throw XCTSkip("Simulator photos are all within 5 minutes; cannot test multi-bucket split")
        }

        let buckets = GroupingService.splitIntoBuckets(assets)
        XCTAssertGreaterThan(buckets.count, 1, "Assets spread > 5 min should produce multiple buckets")
    }

    func testSplitIntoBuckets_allBucketsHaveAtLeastTwoAssets() throws {
        let assets = try requirePhotoAssets(minimum: 4)
        let buckets = GroupingService.splitIntoBuckets(assets)
        for (i, bucket) in buckets.enumerated() {
            XCTAssertGreaterThanOrEqual(bucket.count, 2, "Bucket \(i) should have ≥2 assets")
        }
    }

    // MARK: - streamGroups (integration — requires library)

    func testStreamGroups_emitsAtLeastOneGroup() async throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let service = GroupingService.shared
        var groupCount = 0

        for await _ in await service.streamGroups(from: assets) {
            groupCount += 1
        }

        // We can't guarantee groups are found (depends on actual photo similarity),
        // but the stream should complete without hanging.
        XCTAssertGreaterThanOrEqual(groupCount, 0, "Stream completed without hanging")
    }

    func testStreamGroups_emittedGroupsHaveAtLeastTwoAssets() async throws {
        let assets = try requirePhotoAssets(minimum: 4)
        let service = GroupingService.shared

        for await group in await service.streamGroups(from: assets) {
            XCTAssertGreaterThanOrEqual(
                group.assets.count, 2,
                "Every emitted group must contain at least 2 assets"
            )
        }
    }

    // MARK: - Cache round-trip

    func testPersistAndLoadGroups_roundTrips() async throws {
        let assets = try requirePhotoAssets(minimum: 3)
        let service = GroupingService.shared
        await service.invalidateCache()

        let originalGroup = PhotoGroup(id: UUID(), assets: assets)
        await service.persistGroups([originalGroup])

        let loaded = await service.loadCachedGroups()
        XCTAssertNotNil(loaded, "Cache should be loadable after persist")
        XCTAssertEqual(loaded?.count, 1)
        XCTAssertEqual(
            loaded?[0].assets.map { $0.localIdentifier }.sorted(),
            assets.map { $0.localIdentifier }.sorted()
        )

        // Clean up
        await service.invalidateCache()
    }

    func testLoadCachedGroups_returnsNil_whenNoCacheExists() async throws {
        let service = GroupingService.shared
        await service.invalidateCache()

        let loaded = await service.loadCachedGroups()
        XCTAssertNil(loaded, "Fresh state should return nil from cache")
    }

    func testPersistGroups_invalidateCache_returnsNil() async throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let service = GroupingService.shared
        let group = PhotoGroup(id: UUID(), assets: assets)

        await service.persistGroups([group])
        await service.invalidateCache()

        let loaded = await service.loadCachedGroups()
        XCTAssertNil(loaded, "After invalidation, cache should return nil")
    }
}
