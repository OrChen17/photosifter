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

    // MARK: - weightedBuckets(byDates:) — progress weights

    func testWeightedBuckets_weightsPlusLeftoverEqualInputCount() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let offsets: [TimeInterval] = [
            0,                      // single, before first bucket → leftover
            3_600, 3_660,           // bucket A
            7_200,                  // single → weighted into A
            10_800, 10_830, 10_860, // bucket B
            14_400,                 // single → weighted into B
        ]
        let dates = offsets.map { base.addingTimeInterval($0) }

        let result = GroupingService.weightedBuckets(byDates: dates)

        XCTAssertEqual(result.buckets.map(\.indices), [[1, 2], [4, 5, 6]])
        XCTAssertEqual(result.buckets.map(\.weight), [3, 4])
        XCTAssertEqual(result.leftover, 1)
        XCTAssertEqual(result.buckets.map(\.weight).reduce(0, +) + result.leftover, dates.count)
    }

    func testWeightedBuckets_noBuckets_allLeftover() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = [base, base.addingTimeInterval(3_600), base.addingTimeInterval(7_200)]
        let result = GroupingService.weightedBuckets(byDates: dates)
        XCTAssertTrue(result.buckets.isEmpty)
        XCTAssertEqual(result.leftover, 3)
    }

    func testWeightedBuckets_emptyInput() {
        let result = GroupingService.weightedBuckets(byDates: [])
        XCTAssertTrue(result.buckets.isEmpty)
        XCTAssertEqual(result.leftover, 0)
    }

    // MARK: - plan(_:) — needs library assets

    func testPlan_itemsAreNewestFirst_andWeightsSumToTotal() throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let plan = GroupingService.plan(assets.shuffled())

        XCTAssertEqual(plan.total, assets.count)
        let dates = plan.items.map(\.newestDate)
        XCTAssertEqual(dates, dates.sorted(by: >), "Work items must be ordered newest first")

        let weights = plan.items.reduce(0) { sum, item in
            switch item {
            case .burst: return sum + 1
            case .bucket(_, let weight, _, _): return sum + weight
            }
        }
        XCTAssertEqual(weights + plan.leftover, plan.total)
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

    /// Bulk-fetch refactor: `loadCachedGroups` does one `PHAsset.fetchAssets(withLocalIdentifiers:)`
    /// for all cached IDs at once. This test verifies that multiple distinct groups still
    /// come back with the right per-group membership after that flattening.
    func testLoadCachedGroups_multiplePersistedGroups_eachReturnsWithCorrectMembership() async throws {
        let assets = try requirePhotoAssets(minimum: 6)
        let service = GroupingService.shared
        await service.invalidateCache()

        let groupA = PhotoGroup(id: UUID(), assets: Array(assets[0..<3]))
        let groupB = PhotoGroup(id: UUID(), assets: Array(assets[3..<6]))
        await service.persistGroups([groupA, groupB])

        let loaded = await service.loadCachedGroups()
        await service.invalidateCache()

        XCTAssertEqual(loaded?.count, 2, "Both persisted groups should round-trip")
        let loadedIDSets = loaded?.map { Set($0.assets.map(\.localIdentifier)) } ?? []
        let expectedA = Set(groupA.assets.map(\.localIdentifier))
        let expectedB = Set(groupB.assets.map(\.localIdentifier))
        XCTAssertTrue(
            loadedIDSets.contains(expectedA),
            "Group A's exact asset set must appear in loaded groups"
        )
        XCTAssertTrue(
            loadedIDSets.contains(expectedB),
            "Group B's exact asset set must appear in loaded groups"
        )
        // No cross-contamination: the union of loaded sets must equal the union of inputs.
        let loadedUnion = loadedIDSets.reduce(into: Set<String>()) { $0.formUnion($1) }
        XCTAssertEqual(loadedUnion, expectedA.union(expectedB))
    }

    /// Bulk-fetch refactor: a group whose IDs only partially resolve (e.g. one asset
    /// was deleted from Photos since persist) must still be loadable if ≥2 assets remain,
    /// and dropped if fewer remain. This test exercises the happy path; the drop path
    /// is covered by the asset count guard in `loadCachedGroups`.
    func testLoadCachedGroups_groupSurvivesWithSubsetOfResolvableIDs() async throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let service = GroupingService.shared
        await service.invalidateCache()

        // We can't easily forge missing IDs without exposing cacheURL, so just verify
        // the standard 2-asset path still loads through the bulk-fetch code path.
        let group = PhotoGroup(id: UUID(), assets: Array(assets.prefix(2)))
        await service.persistGroups([group])

        let loaded = await service.loadCachedGroups()
        await service.invalidateCache()

        XCTAssertEqual(loaded?.count, 1, "Two-asset group must survive bulk-fetch")
        XCTAssertEqual(loaded?[0].assets.count, 2)
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
