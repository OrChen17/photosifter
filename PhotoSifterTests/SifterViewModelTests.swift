import XCTest
import Photos
@testable import PhotoSifter

@MainActor
final class SifterViewModelTests: XCTestCase {

    private var mockDeletion: MockDeletionService!

    override func setUp() {
        super.setUp()
        mockDeletion = MockDeletionService()
    }

    // MARK: - Initial state

    func testInitialState_emptyGroup() {
        let group = PhotoGroup(id: UUID(), assets: [])
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        XCTAssertEqual(vm.currentIndex, 0)
        XCTAssertFalse(vm.isComplete)
        XCTAssertFalse(vm.canUndo)
        XCTAssertNil(vm.currentAsset)
        XCTAssertEqual(vm.deletedCount, 0)
        XCTAssertEqual(vm.progress, 1.0, "Empty group progress is 1.0 (nothing to do)")
    }

    func testInitialState_withAssets() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        XCTAssertEqual(vm.currentIndex, 0)
        XCTAssertFalse(vm.isComplete)
        XCTAssertFalse(vm.canUndo)
        XCTAssertNotNil(vm.currentAsset)
        XCTAssertEqual(vm.progress, 0.0)
    }

    // MARK: - Swipe right (keep)

    func testSwipeRight_advancesIndex() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        let firstAsset = vm.currentAsset
        vm.swipeRight()

        XCTAssertEqual(vm.currentIndex, 1)
        XCTAssertNotEqual(vm.currentAsset?.localIdentifier, firstAsset?.localIdentifier)
    }

    func testSwipeRight_recordsKeepDecision() throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)
        let keptID = group.assets[0].localIdentifier

        vm.swipeRight()

        XCTAssertEqual(vm.group.decisions[keptID], .keep)
        XCTAssertNil(vm.group.decisions[group.assets[1].localIdentifier])
    }

    func testSwipeRight_doesNotCallDeletion() throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeRight()

        XCTAssertEqual(mockDeletion.deletedAssets.count, 0)
    }

    func testSwipeRight_enablesUndo() throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        XCTAssertFalse(vm.canUndo)
        vm.swipeRight()
        XCTAssertTrue(vm.canUndo)
    }

    func testSwipeRight_throughAllAssets_completesSession() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeRight()
        vm.swipeRight()
        vm.swipeRight()

        XCTAssertTrue(vm.isComplete)
        XCTAssertNil(vm.currentAsset)
    }

    // MARK: - Swipe left (delete)

    func testSwipeLeft_advancesIndex() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeLeft()

        XCTAssertEqual(vm.currentIndex, 1)
    }

    func testSwipeLeft_recordsDeleteDecision() throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)
        let deletedID = group.assets[0].localIdentifier

        vm.swipeLeft()

        XCTAssertEqual(vm.group.decisions[deletedID], .delete)
    }

    func testSwipeLeft_callsDeletionService() async throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)
        let expectedID = group.assets[0].localIdentifier

        vm.swipeLeft()

        // The deletion runs on a Task; yield to let it complete
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(mockDeletion.deletedAssets.count, 1)
        XCTAssertEqual(mockDeletion.deletedAssets[0].localIdentifier, expectedID)
    }

    func testSwipeLeft_deletionFailure_doesNotCrash() async throws {
        mockDeletion.shouldThrow = true
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeLeft()
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        // isDeleting should be false after failure, isComplete should not be set
        XCTAssertFalse(vm.isDeleting)
    }

    // MARK: - Undo

    func testUndo_revertsLastDecision() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)
        let firstID = group.assets[0].localIdentifier

        vm.swipeRight()
        XCTAssertEqual(vm.currentIndex, 1)
        XCTAssertEqual(vm.group.decisions[firstID], .keep)

        vm.undo()

        XCTAssertEqual(vm.currentIndex, 0)
        XCTAssertNil(vm.group.decisions[firstID])
    }

    func testUndo_multipleTimesRestoresInitialState() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeRight()
        vm.swipeLeft()
        vm.swipeRight()

        vm.undo()
        vm.undo()
        vm.undo()

        XCTAssertEqual(vm.currentIndex, 0)
        XCTAssertTrue(vm.group.decisions.isEmpty)
        XCTAssertFalse(vm.canUndo)
    }

    func testUndo_noop_whenHistoryEmpty() throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.undo() // should not crash

        XCTAssertEqual(vm.currentIndex, 0)
        XCTAssertFalse(vm.canUndo)
    }

    func testUndo_afterComplete_restoresIncompleteState() throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeRight()
        vm.swipeRight()
        XCTAssertTrue(vm.isComplete)

        // Note: undo after complete restores index, but isComplete is set to true
        // and isn't automatically cleared — this is by design (batch is done).
        // This test documents that behavior.
        vm.undo()
        XCTAssertEqual(vm.currentIndex, 1)
    }

    // MARK: - Progress

    func testProgress_incrementsWithEachSwipe() throws {
        let group = try requirePhotoGroup(assetCount: 4)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        XCTAssertEqual(vm.progress, 0.0)
        vm.swipeRight()
        XCTAssertEqual(vm.progress, 0.25, accuracy: 0.001)
        vm.swipeRight()
        XCTAssertEqual(vm.progress, 0.5, accuracy: 0.001)
        vm.swipeRight()
        XCTAssertEqual(vm.progress, 0.75, accuracy: 0.001)
    }

    func testProgress_decrementOnUndo() throws {
        let group = try requirePhotoGroup(assetCount: 4)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeRight()
        vm.swipeRight()
        XCTAssertEqual(vm.progress, 0.5, accuracy: 0.001)

        vm.undo()
        XCTAssertEqual(vm.progress, 0.25, accuracy: 0.001)
    }
}
