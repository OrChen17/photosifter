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

    // Deletion is now deferred — swipeLeft only queues; commitDeletes() executes.
    func testSwipeLeft_doesNotCallDeletionServiceImmediately() async throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeLeft()
        await Task.yield()

        XCTAssertEqual(mockDeletion.deletedAssets.count, 0, "Deletion must be deferred until commitDeletes()")
    }

    func testCommitDeletes_callsDeletionServiceWithQueuedAssets() async throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)
        let deletedID = group.assets[0].localIdentifier

        vm.swipeLeft()  // queues asset[0]
        vm.swipeRight() // keeps asset[1]
        vm.swipeLeft()  // queues asset[2]
        XCTAssertTrue(vm.isComplete)

        await vm.commitDeletes()

        XCTAssertEqual(mockDeletion.deletedAssets.count, 2)
        XCTAssertTrue(mockDeletion.deletedAssets.map { $0.localIdentifier }.contains(deletedID))
    }

    func testCommitDeletes_gracefulOnDeletionFailure() async throws {
        mockDeletion.shouldThrow = true
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeLeft()
        vm.swipeRight()
        XCTAssertTrue(vm.isComplete)

        await vm.commitDeletes()  // should not throw or crash

        XCTAssertFalse(vm.isCommittingDeletes)
    }

    func testUndo_afterSwipeLeft_removesFromDeletionQueue() async throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeLeft()  // queues asset[0]
        vm.undo()       // should dequeue asset[0]
        vm.swipeRight() // keep asset[0]
        vm.swipeRight() // keep asset[1]
        vm.swipeRight() // keep asset[2]
        XCTAssertTrue(vm.isComplete)

        await vm.commitDeletes()

        XCTAssertEqual(mockDeletion.deletedAssets.count, 0, "Undone delete must not reach the deletion service")
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

    func testUndo_afterComplete_resetsIsComplete() throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeRight()
        vm.swipeRight()
        XCTAssertTrue(vm.isComplete)

        vm.undo()

        // Fix #3: undo must re-open the session
        XCTAssertFalse(vm.isComplete, "Undo after completion should reset isComplete")
        XCTAssertEqual(vm.currentIndex, 1)
    }

    // MARK: - Skip

    func testSkipCurrent_movesAssetToEndOfDisplayOrder() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)
        let firstID = group.assets[0].localIdentifier

        vm.skipCurrent()

        XCTAssertEqual(vm.displayOrder.last?.localIdentifier, firstID)
        XCTAssertNotEqual(vm.currentAsset?.localIdentifier, firstID)
        XCTAssertEqual(vm.currentIndex, 0, "Index stays the same after skip")
    }

    func testSkipCurrent_cannotSkipSameAssetTwice() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)
        let firstID = group.assets[0].localIdentifier

        vm.skipCurrent()
        // Skip again — the skipped asset is now at index 2; advance past the others first
        vm.swipeRight() // decide asset[1]
        vm.swipeRight() // decide asset[2]
        // Now the skipped asset is current again — canSkip should be false
        XCTAssertFalse(vm.canSkipCurrent, "Already-skipped asset cannot be skipped again")
    }

    func testSkipCurrent_doesNotRecordDecision() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)
        let firstID = group.assets[0].localIdentifier

        vm.skipCurrent()

        XCTAssertNil(vm.group.decisions[firstID], "Skip must not record a keep or delete decision")
    }

    // MARK: - Keep only this

    func testKeepOnlyCurrentAndDeleteRest_completesGroup() throws {
        let group = try requirePhotoGroup(assetCount: 4)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)
        let keptID = group.assets[0].localIdentifier

        vm.keepOnlyCurrentAndDeleteRest()

        XCTAssertTrue(vm.isComplete)
        XCTAssertEqual(vm.group.decisions[keptID], .keep)
        XCTAssertEqual(vm.group.keptAssets.count, 1)
        XCTAssertEqual(vm.group.deletedAssets.count, 3)
    }

    func testKeepOnlyCurrentAndDeleteRest_queuesOthersForDeletion() async throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.keepOnlyCurrentAndDeleteRest()
        await vm.commitDeletes()

        XCTAssertEqual(mockDeletion.deletedAssets.count, 2, "All non-kept photos should be sent to deletion service")
    }

    // MARK: - isLastUndecidedWithNoKept

    func testIsLastUndecidedWithNoKept_trueWhenOneRemainingAndNothingKept() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeLeft()  // delete[0]
        vm.swipeLeft()  // delete[1]
        // Only asset[2] remains, nothing kept

        XCTAssertTrue(vm.isLastUndecidedWithNoKept)
    }

    func testIsLastUndecidedWithNoKept_falseWhenSomethingAlreadyKept() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeRight() // keep[0]
        vm.swipeLeft()  // delete[1]
        // asset[2] remains, but asset[0] is kept

        XCTAssertFalse(vm.isLastUndecidedWithNoKept)
    }

    func testIsLastUndecidedWithNoKept_falseWhenMultipleRemaining() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeLeft()  // delete[0]
        // asset[1] and [2] still undecided

        XCTAssertFalse(vm.isLastUndecidedWithNoKept)
    }

    // MARK: - deletedCount (computed, not race-prone)

    func testDeletedCount_reflectsDecisions_notAsyncOperations() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        XCTAssertEqual(vm.deletedCount, 0)
        vm.swipeLeft()
        XCTAssertEqual(vm.deletedCount, 1, "deletedCount should update immediately when decision is recorded")
        vm.swipeLeft()
        XCTAssertEqual(vm.deletedCount, 2)
        vm.undo()
        XCTAssertEqual(vm.deletedCount, 1, "Undo should decrement deletedCount")
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

    // MARK: - deleteAll (used by "Delete all remaining" button, threshold >= 2)

    func testDeleteAll_twoAssetGroup_completesAndDeletesAll() throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.deleteAll()

        XCTAssertTrue(vm.isComplete)
        XCTAssertEqual(vm.group.deletedAssets.count, 2)
        XCTAssertEqual(vm.group.keptAssets.count, 0)
    }

    func testDeleteAll_afterPartialDecisions_onlyDeletesUndecided() throws {
        let group = try requirePhotoGroup(assetCount: 4)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeRight() // keep asset[0]
        vm.deleteAll()  // should delete only [1], [2], [3] (undecided)

        XCTAssertEqual(vm.group.decisions[group.assets[0].localIdentifier], .keep,
                       "Pre-decided keep must survive deleteAll")
        XCTAssertEqual(vm.group.deletedAssets.count, 3)
        XCTAssertTrue(vm.isComplete)
    }

    func testDeleteAll_marksAllAssetsDelete() throws {
        let group = try requirePhotoGroup(assetCount: 5)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.deleteAll()

        XCTAssertTrue(vm.isComplete)
        XCTAssertEqual(vm.group.deletedAssets.count, 5)
        XCTAssertEqual(vm.group.keptAssets.count, 0)
    }

    func testDeleteAll_skipsAlreadyDecidedAssets() throws {
        let group = try requirePhotoGroup(assetCount: 4)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.swipeRight() // pre-decide asset[0] as keep
        vm.swipeLeft()  // pre-decide asset[1] as delete
        vm.deleteAll()  // should only affect undecided [2] and [3]

        XCTAssertTrue(vm.isComplete)
        XCTAssertEqual(vm.group.decisions[group.assets[0].localIdentifier], .keep,  "Pre-decided keep must not be overwritten")
        XCTAssertEqual(vm.group.decisions[group.assets[1].localIdentifier], .delete, "Pre-decided delete must not be changed")
        XCTAssertEqual(vm.group.decisions[group.assets[2].localIdentifier], .delete)
        XCTAssertEqual(vm.group.decisions[group.assets[3].localIdentifier], .delete)
    }

    // MARK: - keepOldestAndDeleteRest

    func testKeepOldestAndDeleteRest_keepsEarliestCreationDate() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        let oldest = group.assets.min(by: {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        })!

        vm.keepOldestAndDeleteRest()

        XCTAssertEqual(vm.group.decisions[oldest.localIdentifier], .keep)
        for asset in group.assets where asset.localIdentifier != oldest.localIdentifier {
            XCTAssertEqual(vm.group.decisions[asset.localIdentifier], .delete)
        }
    }

    func testKeepOldestAndDeleteRest_exactlyOneKept() throws {
        let group = try requirePhotoGroup(assetCount: 4)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.keepOldestAndDeleteRest()

        XCTAssertEqual(vm.group.keptAssets.count, 1)
        XCTAssertEqual(vm.group.deletedAssets.count, 3)
    }

    func testKeepOldestAndDeleteRest_completesGroup() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = SifterViewModel(group: group, deletionService: mockDeletion)

        vm.keepOldestAndDeleteRest()

        XCTAssertTrue(vm.isComplete)
    }
}
