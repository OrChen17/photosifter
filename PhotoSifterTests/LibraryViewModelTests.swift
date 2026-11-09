import XCTest
import Photos
@testable import PhotoSifter

@MainActor
final class LibraryViewModelTests: XCTestCase {

    // MARK: - Initial state

    func testInitialState() {
        let vm = LibraryViewModel()
        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertFalse(vm.isScanning)
        XCTAssertEqual(vm.scanProgress.checked, 0)
        XCTAssertEqual(vm.scanProgress.total, 0)
        XCTAssertNil(vm.error)
    }

    func testSortOrder_defaultIsRandom() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: LibraryViewModel.sortOrderKey)
        defaults.removeObject(forKey: LibraryViewModel.sortOrderKey)
        defer { defaults.set(saved, forKey: LibraryViewModel.sortOrderKey) }

        XCTAssertEqual(LibraryViewModel().sortOrder, .random)
    }

    // MARK: - Inserted-photo neighbours

    func testIsNear_matchesDatesWithinGapOnEitherSide() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let dates = [base, base.addingTimeInterval(3_600)]
        let gap: TimeInterval = 300

        XCTAssertTrue(LibraryViewModel.isNear(base, sortedDates: dates, within: gap))
        XCTAssertTrue(LibraryViewModel.isNear(base.addingTimeInterval(-300), sortedDates: dates, within: gap))
        XCTAssertTrue(LibraryViewModel.isNear(base.addingTimeInterval(299), sortedDates: dates, within: gap))
        XCTAssertTrue(LibraryViewModel.isNear(base.addingTimeInterval(3_400), sortedDates: dates, within: gap))
        XCTAssertFalse(LibraryViewModel.isNear(base.addingTimeInterval(1_800), sortedDates: dates, within: gap))
        XCTAssertFalse(LibraryViewModel.isNear(base.addingTimeInterval(-301), sortedDates: dates, within: gap))
        XCTAssertFalse(LibraryViewModel.isNear(base.addingTimeInterval(3_901), sortedDates: dates, within: gap))
        XCTAssertFalse(LibraryViewModel.isNear(base, sortedDates: [], within: gap))
    }

    // MARK: - markGroupComplete

    func testMarkGroupComplete_removesGroupFromList() throws {
        let vm = LibraryViewModel()
        let group = try requirePhotoGroup(assetCount: 2)
        vm.groups = [group]

        vm.markGroupComplete(group)

        XCTAssertTrue(vm.groups.isEmpty, "markGroupComplete must remove the group from the list")
    }

    func testMarkGroupComplete_onlyRemovesMatchingGroup() throws {
        let vm = LibraryViewModel()
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 2)
        vm.groups = [g1, g2]

        vm.markGroupComplete(g1)

        XCTAssertEqual(vm.groups.count, 1)
        XCTAssertEqual(vm.groups[0].id, g2.id, "Only the completed group should be removed")
    }

    func testMarkGroupComplete_unknownIDIsNoop() throws {
        let vm = LibraryViewModel()
        let group = try requirePhotoGroup(assetCount: 2)
        vm.groups = [group]

        let stranger = PhotoGroup(id: UUID(), assets: [])
        vm.markGroupComplete(stranger)

        XCTAssertEqual(vm.groups.count, 1, "Unknown group ID must not affect existing groups")
    }

    func testMarkGroupComplete_calledTwiceIsIdempotent() throws {
        let vm = LibraryViewModel()
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 2)
        vm.groups = [g1, g2]

        vm.markGroupComplete(g1)
        vm.markGroupComplete(g1)

        XCTAssertEqual(vm.groups.count, 1)
        XCTAssertEqual(vm.groups[0].id, g2.id)
    }

    // MARK: - removeGroup

    func testRemoveGroup_removesCorrectGroup() throws {
        let vm = LibraryViewModel()
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 2)
        vm.groups = [g1, g2]

        vm.removeGroup(id: g1.id)

        XCTAssertEqual(vm.groups.count, 1)
        XCTAssertEqual(vm.groups[0].id, g2.id)
    }

    func testRemoveGroup_noopForMissingID() throws {
        let vm = LibraryViewModel()
        let g1 = try requirePhotoGroup(assetCount: 2)
        vm.groups = [g1]

        vm.removeGroup(id: UUID())

        XCTAssertEqual(vm.groups.count, 1)
    }

    func testRemoveGroup_emptyListAfterRemovingLast() throws {
        let vm = LibraryViewModel()
        let g1 = try requirePhotoGroup(assetCount: 2)
        vm.groups = [g1]

        vm.removeGroup(id: g1.id)

        XCTAssertTrue(vm.groups.isEmpty)
    }

    // MARK: - completedBatches stats (fix: loaded early, not after scan)

    func testTotalDeletedCount_sumsBatchDeletedCounts() {
        let vm = LibraryViewModel()
        vm.completedBatches = [makeBatch(deleted: 2, bytes: 0), makeBatch(deleted: 4, bytes: 0)]
        XCTAssertEqual(vm.totalDeletedCount, 6)
    }

    func testTotalSavedBytes_sumsBatchSavedBytes() {
        let vm = LibraryViewModel()
        vm.completedBatches = [makeBatch(deleted: 1, bytes: 1_000_000), makeBatch(deleted: 1, bytes: 2_500_000)]
        XCTAssertEqual(vm.totalSavedBytes, 3_500_000)
    }

    func testTotalDeletedCount_emptyBatches_isZero() {
        let vm = LibraryViewModel()
        XCTAssertEqual(vm.totalDeletedCount, 0)
        XCTAssertEqual(vm.totalSavedBytes, 0)
    }

    // MARK: - Sort

    func testApplySort_biggestFirst_mostBytesFirst() throws {
        let vm = LibraryViewModel()
        var small  = try requirePhotoGroup(assetCount: 2)
        var large  = try requirePhotoGroup(assetCount: 2)
        var medium = try requirePhotoGroup(assetCount: 2)
        small.totalFileBytes = 1_000
        large.totalFileBytes = 9_000
        medium.totalFileBytes = 5_000
        vm.groups = [small, large, medium]

        vm.sortOrder = .biggestFirst
        vm.applySort()

        XCTAssertEqual(vm.groups.map(\.totalFileBytes), [9_000, 5_000, 1_000])
    }

    func testApplySort_random_preservesGroupCount() throws {
        let vm = LibraryViewModel()
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 3)
        let g3 = try requirePhotoGroup(assetCount: 4)
        vm.groups = [g1, g2, g3]

        vm.sortOrder = .random
        vm.applySort()

        XCTAssertEqual(vm.groups.count, 3)
    }

    func testApplySort_switchingOrders_neverDropsGroups() throws {
        let vm = LibraryViewModel()
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 3)
        vm.groups = [g1, g2]

        for order in GroupSortOrder.allCases {
            vm.sortOrder = order
            vm.applySort()
            XCTAssertEqual(vm.groups.count, 2, "Sort order \(order) must not drop groups")
        }
    }

    func testApplySort_newestBiggest_dateIsPrimaryKey() throws {
        let assets = try requirePhotoAssets(minimum: 4)
        // requirePhotoAssets fetches sorted oldest-first, so prefix = older, suffix = newer
        let olderGroup = PhotoGroup(id: UUID(), assets: Array(assets.prefix(2)))
        let newerGroup = PhotoGroup(id: UUID(), assets: Array(assets.suffix(2)))
        let vm = LibraryViewModel()
        vm.groups = [olderGroup, newerGroup]
        vm.sortOrder = .newestBiggest
        vm.applySort()

        XCTAssertEqual(vm.groups.count, 2)
        let separationDate0 = assets[1].creationDate
        let separationDate1 = assets[2].creationDate
        guard let old = separationDate0, let new = separationDate1, old < new else { return }
        XCTAssertEqual(vm.groups[0].id, newerGroup.id, "newestBiggest must put newer dates first")
    }

    func testApplySort_oldestBiggest_dateIsPrimaryKey() throws {
        let assets = try requirePhotoAssets(minimum: 4)
        let olderGroup = PhotoGroup(id: UUID(), assets: Array(assets.prefix(2)))
        let newerGroup = PhotoGroup(id: UUID(), assets: Array(assets.suffix(2)))
        let vm = LibraryViewModel()
        vm.groups = [newerGroup, olderGroup]  // intentionally reversed
        vm.sortOrder = .oldestBiggest
        vm.applySort()

        XCTAssertEqual(vm.groups.count, 2)
        let separationDate0 = assets[1].creationDate
        let separationDate1 = assets[2].creationDate
        guard let old = separationDate0, let new = separationDate1, old < new else { return }
        XCTAssertEqual(vm.groups[0].id, olderGroup.id, "oldestBiggest must put older dates first")
    }

    func testApplySort_newestBiggest_sizeBreaksTie() throws {
        // When dates are equal, larger group wins
        let assets = try requirePhotoAssets(minimum: 3)
        let small = PhotoGroup(id: UUID(), assets: Array(assets.prefix(2)))
        let large = PhotoGroup(id: UUID(), assets: assets)
        let vm = LibraryViewModel()
        vm.groups = [small, large]
        vm.sortOrder = .newestBiggest
        vm.applySort()

        XCTAssertEqual(vm.groups.count, 2)
        // Only assert size order when both groups share the same captureDate
        guard let d0 = small.captureDate, let d1 = large.captureDate, d0 == d1 else { return }
        XCTAssertEqual(vm.groups[0].id, large.id, "Same date: larger group must come first")
    }

    // MARK: - nextIncompleteGroup

    func testNextIncompleteGroup_returnsNextInArrayOrder() throws {
        let vm = LibraryViewModel()
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 2)
        let g3 = try requirePhotoGroup(assetCount: 2)
        vm.groups = [g1, g2, g3]

        XCTAssertEqual(vm.nextIncompleteGroup(after: g1)?.id, g2.id)
        XCTAssertEqual(vm.nextIncompleteGroup(after: g2)?.id, g3.id)
    }

    func testNextIncompleteGroup_skipsCompleteGroups() throws {
        let vm = LibraryViewModel()
        let g1 = try requirePhotoGroup(assetCount: 2)
        var g2 = try requirePhotoGroup(assetCount: 2)
        let g3 = try requirePhotoGroup(assetCount: 2)
        for asset in g2.assets { g2.decisions[asset.localIdentifier] = .keep }
        vm.groups = [g1, g2, g3]

        XCTAssertEqual(vm.nextIncompleteGroup(after: g1)?.id, g3.id,
                       "Complete groups must be skipped")
    }

    func testNextIncompleteGroup_returnsNilAtEnd() throws {
        let vm = LibraryViewModel()
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 2)
        vm.groups = [g1, g2]

        XCTAssertNil(vm.nextIncompleteGroup(after: g2))
    }

    func testNextIncompleteGroup_returnsNilWhenAllRemainingComplete() throws {
        let vm = LibraryViewModel()
        let g1 = try requirePhotoGroup(assetCount: 2)
        var g2 = try requirePhotoGroup(assetCount: 2)
        for asset in g2.assets { g2.decisions[asset.localIdentifier] = .keep }
        vm.groups = [g1, g2]

        XCTAssertNil(vm.nextIncompleteGroup(after: g1))
    }

    func testNextIncompleteGroup_returnsNilWhenCurrentNotInList() throws {
        let vm = LibraryViewModel()
        let g1 = try requirePhotoGroup(assetCount: 2)
        let outsider = PhotoGroup(id: UUID(), assets: [])
        vm.groups = [g1]

        XCTAssertNil(vm.nextIncompleteGroup(after: outsider))
    }

    // MARK: - Helpers

    private func makeBatch(deleted: Int, bytes: Int64) -> CompletedBatch {
        CompletedBatch(
            id: UUID(),
            photoCount: deleted + 1,
            deletedCount: deleted,
            savedBytes: bytes,
            completedAt: Date(),
            captureDate: nil,
            previewAssetIdentifiers: []
        )
    }
}
