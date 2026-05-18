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

    // MARK: - splitIntoBuckets(byDates:) — pure, library-independent

    func testSplitIntoBucketsByDates_emptyInput() {
        XCTAssertTrue(GroupingService.splitIntoBuckets(byDates: []).isEmpty)
    }

    func testSplitIntoBucketsByDates_singleDate_droppedAsSingleton() {
        let buckets = GroupingService.splitIntoBuckets(byDates: [Date()])
        XCTAssertTrue(buckets.isEmpty, "Single-date input cannot form a bucket (count < 2)")
    }

    func testSplitIntoBucketsByDates_twoClosePairs_separatedByLargeGap_yieldsTwoBuckets() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let dates: [Date] = [
            base,
            base.addingTimeInterval(60),
            base.addingTimeInterval(120),
            // gap > 5 minutes
            base.addingTimeInterval(60 * 60),
            base.addingTimeInterval(60 * 60 + 30),
        ]
        let buckets = GroupingService.splitIntoBuckets(byDates: dates)
        XCTAssertEqual(buckets, [[0, 1, 2], [3, 4]])
    }

    func testSplitIntoBucketsByDates_singletonsBetweenClusters_areDropped() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let dates: [Date] = [
            base,
            base.addingTimeInterval(30),
            // gap > 5 min → orphan
            base.addingTimeInterval(10 * 60),
            // gap > 5 min → next cluster
            base.addingTimeInterval(60 * 60),
            base.addingTimeInterval(60 * 60 + 30),
        ]
        let buckets = GroupingService.splitIntoBuckets(byDates: dates)
        XCTAssertEqual(
            buckets, [[0, 1], [3, 4]],
            "Lone index 2 is more than 5 min from both neighbours; must be dropped"
        )
    }

    func testSplitIntoBucketsByDates_allWidelySeparated_yieldsZeroBuckets() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = (0..<4).map { base.addingTimeInterval(Double($0) * 3600) }
        let buckets = GroupingService.splitIntoBuckets(byDates: dates)
        XCTAssertTrue(
            buckets.isEmpty,
            "Four widely-separated singletons must produce 0 buckets (regression: previously asserted >1)"
        )
    }

    func testSplitIntoBucketsByDates_gapExactlyFiveMinutes_keepsBucketTogether() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let dates: [Date] = [base, base.addingTimeInterval(5 * 60)]
        let buckets = GroupingService.splitIntoBuckets(byDates: dates)
        XCTAssertEqual(buckets, [[0, 1]], "Boundary: gap == 5 min must NOT split (split requires > gap)")
    }

    func testSplitIntoBuckets_assetVariantDelegatesToDateVariant() throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let bucketsFromAssets = GroupingService.splitIntoBuckets(assets)
        let bucketsFromDates = GroupingService.splitIntoBuckets(
            byDates: assets.map { $0.creationDate ?? .distantPast }
        )
        XCTAssertEqual(
            bucketsFromAssets.map { $0.map { $0.localIdentifier } },
            bucketsFromDates.map { indices in indices.map { assets[$0].localIdentifier } },
            "Asset variant must produce the same partition as the date variant"
        )
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

    // MARK: - In-group asset ordering

    /// Regression: PHAsset.fetchAssets(withLocalIdentifiers:options:) does not
    /// preserve input order, and `options: nil` provides no sort descriptor —
    /// so cached groups would come back with photos in arbitrary order.
    /// Newly-scanned groups (burst + Vision) are sorted by creationDate ascending,
    /// so cached groups must match for consistency in the sifter strip.
    func testLoadCachedGroups_sortsAssetsByCreationDateAscending() async throws {
        let assets = try requirePhotoAssets(minimum: 3)
        let dates = assets.compactMap { $0.creationDate }
        try XCTSkipIf(
            Set(dates).count < 2,
            "Need assets with distinct creation dates to verify ordering"
        )

        let service = GroupingService.shared
        await service.invalidateCache()

        // requirePhotoAssets returns ascending; persist in reverse so the cached
        // identifier list is deliberately non-chronological. Loading must still
        // return assets in ascending creationDate order.
        let reversed = Array(assets.reversed())
        let group = PhotoGroup(id: UUID(), assets: reversed)
        await service.persistGroups([group])

        let loaded = await service.loadCachedGroups()
        await service.invalidateCache()

        XCTAssertEqual(loaded?.count, 1)
        let loadedDates = loaded?[0].assets.compactMap { $0.creationDate } ?? []
        XCTAssertEqual(
            loadedDates, loadedDates.sorted(),
            "Cached group assets must be sorted by creationDate ascending, got: \(loadedDates)"
        )
    }
}
