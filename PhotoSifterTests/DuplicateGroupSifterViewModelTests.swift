import XCTest
import Photos
@testable import PhotoSifter

@MainActor
final class DuplicateGroupSifterViewModelTests: XCTestCase {

    // MARK: - Initial state

    func testInitialState_singleGroup() throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [group])

        XCTAssertEqual(vm.currentIndex, 0)
        XCTAssertFalse(vm.isComplete)
        XCTAssertEqual(vm.mergedCount, 0)
        XCTAssertEqual(vm.progress, 0.0, accuracy: 0.001)
        XCTAssertEqual(vm.currentGroup?.id, group.id)
        XCTAssertNil(vm.commitOutcome)
    }

    func testInitialState_emptyGroups_isAlreadyComplete() {
        let vm = DuplicateGroupSifterViewModel(groups: [])

        XCTAssertTrue(vm.isComplete)
        XCTAssertEqual(vm.progress, 1.0, accuracy: 0.001)
        XCTAssertNil(vm.currentGroup)
    }

    // MARK: - swipeMerge

    func testSwipeMerge_advancesIndex() throws {
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [g1, g2])

        vm.swipeMerge()

        XCTAssertEqual(vm.currentIndex, 1)
        XCTAssertEqual(vm.currentGroup?.id, g2.id)
    }

    func testSwipeMerge_marksGroupForDeletion() throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [group])

        vm.swipeMerge()

        XCTAssertEqual(vm.mergedCount, 1)
    }

    func testSwipeMerge_throughAllGroups_completes() throws {
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [g1, g2])

        vm.swipeMerge()
        vm.swipeMerge()

        XCTAssertTrue(vm.isComplete)
        XCTAssertNil(vm.currentGroup)
    }

    // MARK: - swipeKeepAll

    func testSwipeKeepAll_advancesIndex() throws {
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [g1, g2])

        vm.swipeKeepAll()

        XCTAssertEqual(vm.currentIndex, 1)
        XCTAssertEqual(vm.currentGroup?.id, g2.id)
    }

    func testSwipeKeepAll_doesNotMarkGroupForMerge() throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [group])

        vm.swipeKeepAll()

        XCTAssertEqual(vm.mergedCount, 0)
    }

    func testSwipeKeepAll_throughAllGroups_completes() throws {
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [g1, g2])

        vm.swipeKeepAll()
        vm.swipeKeepAll()

        XCTAssertTrue(vm.isComplete)
    }

    // MARK: - progress

    func testProgress_incrementsWithEachDecision() throws {
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 2)
        let g3 = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [g1, g2, g3])

        XCTAssertEqual(vm.progress, 0.0, accuracy: 0.001)
        vm.swipeKeepAll()
        XCTAssertEqual(vm.progress, 1.0 / 3.0, accuracy: 0.001)
        vm.swipeMerge()
        XCTAssertEqual(vm.progress, 2.0 / 3.0, accuracy: 0.001)
    }

    // MARK: - mergedCount

    func testMergedCount_countsOnlyMergedGroups() throws {
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [g1, g2])

        vm.swipeMerge()   // merge g1
        vm.swipeKeepAll() // keep g2

        XCTAssertEqual(vm.mergedCount, 1)
    }

    func testMergedCount_allMerged() throws {
        let g1 = try requirePhotoGroup(assetCount: 2)
        let g2 = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [g1, g2])

        vm.swipeMerge()
        vm.swipeMerge()

        XCTAssertEqual(vm.mergedCount, 2)
    }

    // MARK: - assetsToDelete

    func testAssetsToDelete_returnsNMinusOne() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = DuplicateGroupSifterViewModel(groups: [group])

        let toDelete = vm.assetsToDelete(in: group)

        XCTAssertEqual(toDelete.count, 2, "Should keep exactly 1 (the best) and delete the rest")
    }

    func testAssetsToDelete_emptyGroup_returnsEmpty() {
        let group = PhotoGroup(id: UUID(), assets: [])
        let vm = DuplicateGroupSifterViewModel(groups: [group])

        XCTAssertTrue(vm.assetsToDelete(in: group).isEmpty)
    }

    func testAssetsToDelete_singleAsset_returnsEmpty() throws {
        let assets = try requirePhotoAssets(minimum: 1)
        let group = PhotoGroup(id: UUID(), assets: Array(assets.prefix(1)))
        let vm = DuplicateGroupSifterViewModel(groups: [group])

        XCTAssertTrue(vm.assetsToDelete(in: group).isEmpty, "Cannot delete the only asset")
    }

    func testAssetsToDelete_exactlyOneAssetKept() throws {
        let group = try requirePhotoGroup(assetCount: 4)
        let vm = DuplicateGroupSifterViewModel(groups: [group])

        let toDelete = vm.assetsToDelete(in: group)
        let toDeleteIDs = Set(toDelete.map(\.localIdentifier))
        let allIDs = Set(group.assets.map(\.localIdentifier))
        let keptIDs = allIDs.subtracting(toDeleteIDs)

        XCTAssertEqual(keptIDs.count, 1, "Exactly one asset should be kept")
    }

    func testAssetsToDelete_keptAssetIsNotInDeleteList() throws {
        let group = try requirePhotoGroup(assetCount: 3)
        let vm = DuplicateGroupSifterViewModel(groups: [group])

        let toDelete = vm.assetsToDelete(in: group)
        let toDeleteIDs = Set(toDelete.map(\.localIdentifier))
        let allIDs = Set(group.assets.map(\.localIdentifier))

        // The intersection of kept and deleted must be empty
        let keptIDs = allIDs.subtracting(toDeleteIDs)
        XCTAssertTrue(keptIDs.isDisjoint(with: toDeleteIDs))
    }

    // MARK: - commitDecisions (no-merge path — no PHPhotoLibrary call)

    func testCommitDecisions_noMerges_outcomeIsNothingToDelete() async throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [group])

        vm.swipeKeepAll()
        await vm.commitDecisions()

        XCTAssertEqual(vm.commitOutcome, .nothingToDelete)
    }

    func testCommitDecisions_isCommittingFalseAfterCompletion() async throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [group])
        vm.swipeKeepAll()

        XCTAssertFalse(vm.isCommitting)
        await vm.commitDecisions()
        XCTAssertFalse(vm.isCommitting, "isCommitting must be reset after commit finishes")
    }

    func testCommitDecisions_deletedCountZeroWhenNothingMerged() async throws {
        let group = try requirePhotoGroup(assetCount: 2)
        let vm = DuplicateGroupSifterViewModel(groups: [group])
        vm.swipeKeepAll()

        await vm.commitDecisions()

        XCTAssertEqual(vm.deletedCount, 0)
        XCTAssertEqual(vm.deletedBytes, 0)
    }
}
