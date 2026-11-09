import XCTest
import Photos
@testable import PhotoSifter

/// Forever (Sweep) must take in groups the scan finds after the session started.
@MainActor
final class SweepSifterViewModelTests: XCTestCase {

    private func twoGroups() throws -> (PhotoGroup, PhotoGroup) {
        let assets = try requirePhotoAssets(minimum: 4)
        return (
            PhotoGroup(id: UUID(), assets: Array(assets[0..<2])),
            PhotoGroup(id: UUID(), assets: Array(assets[2..<4]))
        )
    }

    func testAppendGroups_addsNewGroupToTheEndOfTheQueue() throws {
        let (first, second) = try twoGroups()
        let vm = SweepSifterViewModel(groups: [first])

        vm.appendGroups([first, second])

        XCTAssertEqual(vm.queue.map(\.localIdentifier), (first.assets + second.assets).map(\.localIdentifier))
        XCTAssertEqual(vm.groupID(for: second.assets[0]), second.id)
        XCTAssertEqual(vm.currentIndex, 0, "Appending must not move the cursor mid-queue")
    }

    func testAppendGroups_ignoresGroupsAlreadySeen() throws {
        let (first, _) = try twoGroups()
        let vm = SweepSifterViewModel(groups: [first])

        vm.appendGroups([first])
        vm.appendGroups([first])

        XCTAssertEqual(vm.queue.count, first.assets.count)
    }

    func testAppendGroups_afterQueueRanOut_resumesOnFirstNewPhoto() throws {
        let (first, second) = try twoGroups()
        let vm = SweepSifterViewModel(groups: [first])
        vm.swipeRight()
        vm.swipeLeft()
        XCTAssertTrue(vm.isQueueExhausted)

        vm.appendGroups([second])

        XCTAssertFalse(vm.isQueueExhausted)
        XCTAssertEqual(vm.currentAsset?.localIdentifier, second.assets[0].localIdentifier)
        XCTAssertEqual(vm.pendingDeleteCount, 1, "Earlier decisions stay pending")
    }

    func testAppendGroups_skipsPhotosAlreadyInTheQueue() throws {
        let (first, second) = try twoGroups()
        let vm = SweepSifterViewModel(groups: [first])
        let overlapping = PhotoGroup(id: UUID(), assets: [first.assets[0]] + second.assets)

        vm.appendGroups([overlapping])

        XCTAssertEqual(vm.queue.count, 4)
        XCTAssertEqual(vm.groupID(for: first.assets[0]), first.id)
    }
}
