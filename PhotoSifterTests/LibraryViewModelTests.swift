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
        XCTAssertEqual(vm.scanProgress.current, 0)
        XCTAssertEqual(vm.scanProgress.total, 0)
        XCTAssertNil(vm.error)
    }

    func testSortOrder_defaultIsOldestBiggest() {
        XCTAssertEqual(LibraryViewModel().sortOrder, .oldestBiggest)
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

    func testApplySort_biggestFirst_largestGroupFirst() throws {
        let vm = LibraryViewModel()
        let small  = try requirePhotoGroup(assetCount: 2)
        let large  = try requirePhotoGroup(assetCount: 4)
        let medium = try requirePhotoGroup(assetCount: 3)
        vm.groups = [small, large, medium]

        vm.sortOrder = .biggestFirst
        vm.applySort()

        XCTAssertEqual(vm.groups[0].assets.count, 4)
        XCTAssertEqual(vm.groups[1].assets.count, 3)
        XCTAssertEqual(vm.groups[2].assets.count, 2)
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
