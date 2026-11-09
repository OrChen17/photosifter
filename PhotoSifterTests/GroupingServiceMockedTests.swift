import XCTest
import Photos
@testable import PhotoSifter

/// Exercises GroupingService.streamGroups via an injected mock similarity
/// provider, so the clustering logic can be validated on simulator where
/// Vision/CoreML is not functional.
final class GroupingServiceMockedTests: XCTestCase {

    func testClustering_pairsDeclaredSimilar_endUpInSameGroup() async throws {
        // We need real PHAssets so they survive the actor hop / time-bucketing.
        let assets = try requireAssetsInSameBucket(count: 4)

        let mock = MockSimilarityService()
        // Make assets[0]==assets[1] and assets[2]==assets[3] similar; nothing else.
        mock.similarPairs = [
            [assets[0].localIdentifier, assets[1].localIdentifier],
            [assets[2].localIdentifier, assets[3].localIdentifier],
        ]

        let service = GroupingService(similarity: mock)
        var groups: [PhotoGroup] = []
        for await g in await service.streamGroups(from: assets) {
            groups.append(g)
        }

        // We expect exactly two Vision-derived groups of 2 (plus any burst groups
        // from the real library — those don't depend on the mock).
        let visionDerived = groups.filter { $0.assets.count == 2 }
        XCTAssertGreaterThanOrEqual(visionDerived.count, 2,
            "Expected at least two pair-groups from the mocked similarities")

        let groupedIDs = Set(visionDerived.flatMap { $0.assets.map(\.localIdentifier) })
        XCTAssertTrue(groupedIDs.contains(assets[0].localIdentifier))
        XCTAssertTrue(groupedIDs.contains(assets[1].localIdentifier))
        XCTAssertTrue(groupedIDs.contains(assets[2].localIdentifier))
        XCTAssertTrue(groupedIDs.contains(assets[3].localIdentifier))
    }

    func testClustering_transitivity_threeMutuallySimilar_formOneGroup() async throws {
        let assets = try requireAssetsInSameBucket(count: 3)

        let mock = MockSimilarityService()
        // A~B, B~C — Union-Find should merge all three.
        mock.similarPairs = [
            [assets[0].localIdentifier, assets[1].localIdentifier],
            [assets[1].localIdentifier, assets[2].localIdentifier],
        ]

        let service = GroupingService(similarity: mock)
        var groups: [PhotoGroup] = []
        for await g in await service.streamGroups(from: assets) {
            groups.append(g)
        }

        let bigGroup = groups.first { $0.assets.count >= 3 }
        XCTAssertNotNil(bigGroup, "Union-Find should merge A~B and B~C into one 3-asset group")
        let ids = Set(bigGroup?.assets.map(\.localIdentifier) ?? [])
        XCTAssertTrue(ids.isSuperset(of: assets.prefix(3).map(\.localIdentifier)))
    }

    func testClustering_noSimilarPairs_producesNoVisionGroups() async throws {
        let assets = try requireAssetsInSameBucket(count: 3)

        let mock = MockSimilarityService()
        // similarPairs is empty — nothing should cluster.

        let service = GroupingService(similarity: mock)
        var groupedSets: [Set<String>] = []
        for await g in await service.streamGroups(from: assets) {
            groupedSets.append(Set(g.assets.map(\.localIdentifier)))
        }

        let inputIDs = Set(assets.map(\.localIdentifier))
        for group in groupedSets {
            XCTAssertTrue(
                group.intersection(inputIDs).isEmpty,
                "Mock declared nothing similar — no input assets should cluster. Got: \(group)"
            )
        }
    }

    func testClustering_failingAssets_areSkippedNotPropagated() async throws {
        let assets = try requireAssetsInSameBucket(count: 3)

        let mock = MockSimilarityService()
        mock.failingAssets = [assets[0].localIdentifier]
        // Even though we declare 0~1 similar, the failing asset 0 should drop out.
        mock.similarPairs = [[assets[0].localIdentifier, assets[1].localIdentifier]]

        let service = GroupingService(similarity: mock)
        var groups: [PhotoGroup] = []
        for await g in await service.streamGroups(from: assets) {
            groups.append(g)
        }

        // No group should contain the failing asset.
        for g in groups {
            XCTAssertFalse(
                g.assets.map(\.localIdentifier).contains(assets[0].localIdentifier),
                "Asset whose distance computation throws must not appear in a group"
            )
        }
    }

    // MARK: - Scan pipeline: concurrency, order, progress

    func testScan_computesSignaturesConcurrently() async throws {
        let assets = try requireAssetsInSameBucket(count: 6)
        let mock = MockSimilarityService()
        mock.signatureDelay = .milliseconds(50)

        let service = GroupingService(similarity: mock)
        for await _ in await service.streamGroups(from: assets) {}

        XCTAssertGreaterThan(mock.maxInFlight, 1, "Signatures should be computed in parallel")
        XCTAssertLessThanOrEqual(mock.maxInFlight, GroupingService.maxConcurrentSignatures)
    }

    func testScan_startsWithTheNewestBuckets() async throws {
        let buckets = try requireBuckets(moreThan: GroupingService.maxConcurrentWorkItems)
        let mock = MockSimilarityService()

        let service = GroupingService(similarity: mock)
        for await _ in await service.streamGroups(from: buckets.flatMap { $0 }) {}

        // Only the first `maxConcurrentWorkItems` items start right away, and
        // the plan orders them newest first. Which of those runs first is up
        // to the scheduler.
        let newestIDs = Set(buckets.suffix(GroupingService.maxConcurrentWorkItems).flatMap { $0.map(\.localIdentifier) })
        let first = try XCTUnwrap(mock.requestedIDs.first)
        XCTAssertTrue(newestIDs.contains(first), "The scan must start with the newest time buckets")
    }

    func testScan_progressEndsFinishedWithEverythingChecked() async throws {
        let assets = try requirePhotoAssets(minimum: 4)
        let mock = MockSimilarityService()

        let service = GroupingService(similarity: mock)
        var updates: [ScanProgress] = []
        for await event in await service.scan(from: assets) {
            if case .progress(let p) = event { updates.append(p) }
        }

        let last = try XCTUnwrap(updates.last)
        XCTAssertEqual(last.phase, .finished)
        XCTAssertEqual(last.total, assets.count)
        XCTAssertEqual(last.checked, last.total)
        XCTAssertEqual(last.fraction, 1)
        let checked = updates.map(\.checked)
        XCTAssertEqual(checked, checked.sorted(), "Checked count must never go backwards")
    }

    func testScan_skipsKnownIDs() async throws {
        let assets = try requireAssetsInSameBucket(count: 3)
        let mock = MockSimilarityService()
        mock.similarPairs = [[assets[0].localIdentifier, assets[1].localIdentifier]]

        let service = GroupingService(similarity: mock)
        var total = 0
        for await event in await service.scan(from: assets, excluding: [assets[0].localIdentifier]) {
            if case .progress(let p) = event { total = p.total }
        }

        XCTAssertEqual(total, 2)
        XCTAssertFalse(mock.requestedIDs.contains(assets[0].localIdentifier))
    }

    // MARK: - Helpers

    /// Time buckets of non-burst photos, oldest first. Skips unless there are
    /// more than `count`.
    private func requireBuckets(
        moreThan count: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) throws -> [[PHAsset]] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var all: [PHAsset] = []
        result.enumerateObjects { a, _, _ in if !a.representsBurst { all.append(a) } }

        let buckets = GroupingService.splitIntoBuckets(all)
        guard buckets.count > count else {
            throw XCTSkip("Need more than \(count) time buckets in the library", file: file, line: line)
        }
        return buckets
    }

    /// Finds `count` consecutive assets whose creation dates all fall within
    /// one GroupingService time-bucket (5-minute window). Required because the
    /// library's first few assets are sample photos from 2012/2018/etc and
    /// time-bucketing would split them.
    private func requireAssetsInSameBucket(
        count: Int,
        maxGap: TimeInterval = 5 * 60,
        file: StaticString = #file,
        line: UInt = #line
    ) throws -> [PHAsset] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try XCTSkipIf(
            status == .denied || status == .restricted,
            "Photo library access denied", file: file, line: line
        )

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var all: [PHAsset] = []
        result.enumerateObjects { a, _, _ in all.append(a) }

        guard all.count >= count else {
            throw XCTSkip("Library has \(all.count) photos, need \(count)", file: file, line: line)
        }

        // Slide a window of size `count` looking for a run where every asset
        // has a creationDate and the span is within the bucket gap.
        for start in 0...(all.count - count) {
            let window = Array(all[start..<start + count])
            let dates = window.compactMap(\.creationDate)
            guard dates.count == window.count,
                  let first = dates.first, let last = dates.last,
                  last.timeIntervalSince(first) <= maxGap
            else { continue }
            return window
        }

        throw XCTSkip(
            "No \(count) consecutive photos within \(Int(maxGap))s found in library",
            file: file, line: line
        )
    }
}
