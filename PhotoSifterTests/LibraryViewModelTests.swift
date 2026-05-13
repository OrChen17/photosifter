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

    // MARK: - markGroupComplete

    func testMarkGroupComplete_updatesExistingGroup() throws {
        let vm = LibraryViewModel()
        var group = try requirePhotoGroup(assetCount: 2)
        vm.groups = [group]

        group.decisions[group.assets[0].localIdentifier] = .keep
        group.decisions[group.assets[1].localIdentifier] = .delete
        vm.markGroupComplete(group)

        XCTAssertEqual(vm.groups[0].deleteCount, 1)
        XCTAssertTrue(vm.groups[0].isComplete)
    }

    func testMarkGroupComplete_ignoredForUnknownID() throws {
        let vm = LibraryViewModel()
        let existingGroup = try requirePhotoGroup(assetCount: 2)
        vm.groups = [existingGroup]

        // A group with a different UUID
        var stranger = try requirePhotoGroup(assetCount: 2)
        stranger.decisions[stranger.assets[0].localIdentifier] = .keep
        vm.markGroupComplete(stranger)

        // Original group should be unchanged
        XCTAssertTrue(vm.groups[0].decisions.isEmpty)
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

    // MARK: - Multiple group operations

    func testMultipleGroups_individualUpdates() throws {
        let vm = LibraryViewModel()
        var g1 = try requirePhotoGroup(assetCount: 2)
        var g2 = try requirePhotoGroup(assetCount: 2)
        vm.groups = [g1, g2]

        g1.decisions[g1.assets[0].localIdentifier] = .delete
        vm.markGroupComplete(g1)

        // g2 should remain untouched
        XCTAssertTrue(vm.groups[1].decisions.isEmpty)
        XCTAssertEqual(vm.groups[0].deleteCount, 1)
    }
}
