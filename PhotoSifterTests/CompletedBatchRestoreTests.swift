import XCTest
import Photos
@testable import PhotoSifter

/// Verifies the restore (Revisit) flow preserves the deleted-side stats while
/// moving kept-side bytes back into the "unflicked" pool. This is the
/// user-facing invariant: revisiting a memory must never inflate or shrink the
/// "MB saved" / "deleted" totals shown on the History tab.
@MainActor
final class CompletedBatchRestoreTests: XCTestCase {

    func testRestoreBatch_preservesDeletedCountAndSavedBytes() async throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let vm = LibraryViewModel()
        let batch = makeBatch(
            keptIDs: assets.map(\.localIdentifier),
            keptBytes: 5_000_000,
            deletedCount: 3,
            savedBytes: 9_000_000
        )
        vm.completedBatches = [batch]

        let deletedBefore = vm.totalDeletedCount
        let savedBefore = vm.totalSavedBytes

        let restored = await vm.restoreBatch(batch)

        XCTAssertNotNil(restored, "Restore should succeed when kept assets resolve")
        XCTAssertEqual(vm.totalDeletedCount, deletedBefore,
                       "Deleted total must be preserved across restore")
        XCTAssertEqual(vm.totalSavedBytes, savedBefore,
                       "Saved-bytes total must be preserved across restore")
    }

    func testRestoreBatch_zerosKeptSideAndShrinksTotals() async throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let vm = LibraryViewModel()
        let batch = makeBatch(
            keptIDs: assets.map(\.localIdentifier),
            keptBytes: 5_000_000,
            deletedCount: 1,
            savedBytes: 1024
        )
        vm.completedBatches = [batch]

        _ = await vm.restoreBatch(batch)

        let updated = vm.completedBatches[0]
        XCTAssertEqual(updated.keptAssetIdentifiers, [],
                       "Kept identifiers must be emptied")
        XCTAssertEqual(updated.keptBytes, 0,
                       "Kept-bytes must be zeroed so totals shrink by exactly this batch's contribution")
        XCTAssertEqual(updated.photoCount, batch.deletedCount,
                       "photoCount should collapse to deletedCount after restore")
        XCTAssertEqual(vm.totalKeptBytes, 0)
        XCTAssertEqual(vm.totalKeptCount, 0)
        XCTAssertFalse(updated.isRevisitable, "A restored batch must no longer appear in Revisit")
    }

    func testRestoreBatch_legacyBatchWithoutKeptIDsIsNoop() async {
        let vm = LibraryViewModel()
        let legacy = CompletedBatch(
            id: UUID(),
            photoCount: 5,
            deletedCount: 2,
            savedBytes: 2048,
            completedAt: Date(),
            captureDate: nil,
            previewAssetIdentifiers: []
        )
        vm.completedBatches = [legacy]

        let result = await vm.restoreBatch(legacy)

        XCTAssertNil(result, "Legacy batches without kept-asset tracking can't be restored")
        XCTAssertNil(vm.selectedRestoreSession, "No navigation session should be published for a no-op restore")
        XCTAssertEqual(vm.completedBatches.count, 1)
        XCTAssertNil(vm.completedBatches[0].keptAssetIdentifiers,
                     "Legacy batch must not gain kept-asset tracking from a failed restore")
    }

    func testRestoreBatch_publishesRestoreSessionWithKeptAssets() async throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let vm = LibraryViewModel()
        let batch = makeBatch(
            keptIDs: assets.map(\.localIdentifier),
            keptBytes: 1024,
            deletedCount: 1,
            savedBytes: 512
        )
        vm.completedBatches = [batch]

        _ = await vm.restoreBatch(batch)

        XCTAssertNotNil(vm.selectedRestoreSession, "Restore must publish a session for navigation")
        XCTAssertEqual(vm.selectedRestoreSession?.group.assets.count, assets.count,
                       "Session group should hold the resolved kept assets")
    }

    /// The key user invariant: after re-flicking a memory, the new deletes must
    /// accumulate onto the original batch (same row in History, deletedCount and
    /// savedBytes summed), not produce a duplicate row.
    func testRestoreThenRecord_mergesNewDeletesIntoSourceBatch() async throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let vm = LibraryViewModel()
        let original = makeBatch(
            keptIDs: assets.map(\.localIdentifier),
            keptBytes: 5_000_000,
            deletedCount: 2,
            savedBytes: 4_000_000
        )
        vm.completedBatches = [original]

        // Simulate the user tapping Revisit.
        let restored = await vm.restoreBatch(original)
        XCTAssertNotNil(restored)
        XCTAssertEqual(vm.currentRestoreSourceBatchID, original.id,
                       "Restore must set the merge target so the next recordCompletedBatch merges in")

        // Simulate completing the re-flick: deleted 2 more, kept nothing.
        let reflickBatch = CompletedBatch(
            id: UUID(),  // new id — would create a duplicate row pre-merge
            photoCount: 2,
            deletedCount: 2,
            savedBytes: 3_000_000,
            completedAt: Date(),
            captureDate: nil,
            previewAssetIdentifiers: [],
            keptAssetIdentifiers: [],
            keptBytes: 0
        )
        await vm.recordCompletedBatch(reflickBatch)

        XCTAssertEqual(vm.completedBatches.count, 1,
                       "Merge must not create a duplicate History row")
        let merged = vm.completedBatches[0]
        XCTAssertEqual(merged.id, original.id, "Merged batch keeps the original id")
        XCTAssertEqual(merged.deletedCount, 4,
                       "deletedCount must accumulate: original 2 + reflick 2 = 4")
        XCTAssertEqual(merged.savedBytes, 7_000_000,
                       "savedBytes must accumulate: 4_000_000 + 3_000_000")
        XCTAssertEqual(merged.keptAssetIdentifiers, [],
                       "kept side reflects current survivors (none in this scenario)")
        XCTAssertEqual(merged.keptBytes, 0)
        XCTAssertNil(vm.currentRestoreSourceBatchID,
                     "Merge target must be cleared after the merge so unrelated sift sessions don't accumulate into it")
    }

    func testRecordCompletedBatch_withoutRestoreContext_appendsNewRow() async {
        let vm = LibraryViewModel()
        XCTAssertNil(vm.currentRestoreSourceBatchID)
        let batch = CompletedBatch(
            id: UUID(),
            photoCount: 5,
            deletedCount: 3,
            savedBytes: 1024,
            completedAt: Date(),
            captureDate: nil,
            previewAssetIdentifiers: []
        )

        await vm.recordCompletedBatch(batch)

        XCTAssertEqual(vm.completedBatches.count, 1)
        XCTAssertEqual(vm.completedBatches[0].id, batch.id,
                       "Without a restore context, batch must be appended as-is, not merged")
    }

    func testDismissingRestoreSession_clearsMergeTarget() async throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let vm = LibraryViewModel()
        let batch = makeBatch(
            keptIDs: assets.map(\.localIdentifier),
            keptBytes: 1024,
            deletedCount: 1,
            savedBytes: 512
        )
        vm.completedBatches = [batch]
        _ = await vm.restoreBatch(batch)
        XCTAssertNotNil(vm.currentRestoreSourceBatchID)

        // User backs out of the SifterView — NavigationStack nils the binding.
        vm.selectedRestoreSession = nil

        XCTAssertNil(vm.currentRestoreSourceBatchID,
                     "Dismissing the restore session must clear the merge target so unrelated sessions don't accumulate")
    }

    func testRestoreBatch_removesKeptIDsFromFlickedSet() async throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let keptIDs = assets.map(\.localIdentifier)
        await GroupingService.shared.addFlickedIdentifiers(keptIDs)

        let vm = LibraryViewModel()
        let batch = makeBatch(keptIDs: keptIDs, keptBytes: 4096, deletedCount: 1, savedBytes: 1024)
        vm.completedBatches = [batch]

        _ = await vm.restoreBatch(batch)

        let flicked = await GroupingService.shared.loadFlickedIdentifiers()
        for id in keptIDs {
            XCTAssertFalse(flicked.contains(id),
                           "Kept ID \(id) must be removed from the flicked set so future scans can re-pick it")
        }
    }

    // MARK: - Source-group merge (Sweep cross-session / Sweep→Sifter)

    /// Two Sweep applies on the same memory must collapse to one row, with
    /// `deletedCount` and `savedBytes` accumulated. The kept side reflects
    /// the most recent apply's snapshot — matches the restore-merge rule.
    func testRecordCompletedBatch_mergesBySourceGroupID() async {
        let vm = LibraryViewModel()
        let gid = UUID()
        let first = CompletedBatch(
            id: UUID(),
            photoCount: 3,
            deletedCount: 1,
            savedBytes: 1_000_000,
            completedAt: Date(timeIntervalSince1970: 1_000),
            captureDate: Date(timeIntervalSince1970: 500),
            previewAssetIdentifiers: ["a"],
            keptAssetIdentifiers: ["a", "b"],
            keptBytes: 2_000_000,
            sourceGroupID: gid
        )
        await vm.recordCompletedBatch(first)

        let second = CompletedBatch(
            id: UUID(),
            photoCount: 2,
            deletedCount: 1,
            savedBytes: 500_000,
            completedAt: Date(timeIntervalSince1970: 2_000),
            captureDate: Date(timeIntervalSince1970: 600),
            previewAssetIdentifiers: ["b"],
            keptAssetIdentifiers: ["b"],
            keptBytes: 800_000,
            sourceGroupID: gid
        )
        await vm.recordCompletedBatch(second)

        XCTAssertEqual(vm.completedBatches.count, 1,
                       "Same sourceGroupID must collapse to one History row")
        let merged = vm.completedBatches[0]
        XCTAssertEqual(merged.id, first.id, "Merged row keeps the original batch id")
        XCTAssertEqual(merged.deletedCount, 2, "Deletes accumulate across sweeps")
        XCTAssertEqual(merged.savedBytes, 1_500_000, "Saved-bytes accumulate")
        XCTAssertEqual(merged.keptAssetIdentifiers, ["b"],
                       "Kept side reflects the latest snapshot")
        XCTAssertEqual(merged.keptBytes, 800_000)
        XCTAssertEqual(merged.completedAt, first.completedAt,
                       "completedAt preserved from original (memory keeps identity)")
        XCTAssertEqual(merged.sourceGroupID, gid)
    }

    /// A batch tagged with `sourceGroupID` but no prior match appends as a
    /// new row — first-touch of a memory.
    func testRecordCompletedBatch_sourceGroupID_firstTouchAppends() async {
        let vm = LibraryViewModel()
        let batch = CompletedBatch(
            id: UUID(),
            photoCount: 2,
            deletedCount: 1,
            savedBytes: 1024,
            completedAt: Date(),
            captureDate: nil,
            previewAssetIdentifiers: [],
            keptAssetIdentifiers: ["x"],
            keptBytes: 2048,
            sourceGroupID: UUID()
        )
        await vm.recordCompletedBatch(batch)
        XCTAssertEqual(vm.completedBatches.count, 1)
        XCTAssertEqual(vm.completedBatches[0].id, batch.id,
                       "First-touch of a sourceGroup must NOT merge into anything")
    }

    /// In-progress Sweep batches (memory still in the main grid) must stay
    /// hidden from both `revisitableBatches` and `historyOnlyBatches` so a
    /// partial sweep does not show a half-finished History row.
    func testInProgressBatch_hiddenFromHistoryUntilGroupLeavesGrid() async {
        let vm = LibraryViewModel()
        let gid = UUID()
        let inProgress = CompletedBatch(
            id: UUID(),
            photoCount: 3,
            deletedCount: 1,
            savedBytes: 1024,
            completedAt: Date(),
            captureDate: nil,
            previewAssetIdentifiers: [],
            keptAssetIdentifiers: ["a", "b"],
            keptBytes: 2048,
            sourceGroupID: gid
        )
        await vm.recordCompletedBatch(inProgress)

        // Place a group with the same id in the live grid — simulates a
        // partially-resolved memory still showing in the main grid.
        vm.groups = [PhotoGroup(id: gid, assets: [])]

        XCTAssertTrue(vm.revisitableBatches.isEmpty,
                      "In-progress batch must be hidden from Revisit")
        XCTAssertTrue(vm.historyOnlyBatches.isEmpty,
                      "In-progress batch must be hidden from Completed")

        // Now the user finishes the memory — group leaves the grid.
        vm.groups = []

        XCTAssertEqual(vm.revisitableBatches.count, 1,
                       "Batch reappears in Revisit once the memory leaves the grid")
    }

    /// Restore-merge must take priority over source-group-merge: re-flicking
    /// a Revisit card accumulates into the *restored* batch (via
    /// `currentRestoreSourceBatchID`), not any other batch that happens to
    /// share the new session's group id.
    func testRestoreMergeTakesPriorityOverSourceGroupMerge() async throws {
        let assets = try requirePhotoAssets(minimum: 2)
        let vm = LibraryViewModel()
        let restoreTarget = makeBatch(
            keptIDs: assets.map(\.localIdentifier),
            keptBytes: 4096,
            deletedCount: 1,
            savedBytes: 2048
        )
        // A second batch sharing nothing — it must NOT be touched.
        let unrelated = CompletedBatch(
            id: UUID(),
            photoCount: 2,
            deletedCount: 1,
            savedBytes: 9999,
            completedAt: Date(),
            captureDate: nil,
            previewAssetIdentifiers: [],
            keptAssetIdentifiers: ["z"],
            keptBytes: 5555,
            sourceGroupID: UUID()
        )
        vm.completedBatches = [restoreTarget, unrelated]

        let restored = await vm.restoreBatch(restoreTarget)
        XCTAssertNotNil(restored)
        XCTAssertEqual(vm.currentRestoreSourceBatchID, restoreTarget.id)

        // The re-flick batch carries the unrelated batch's sourceGroupID by
        // coincidence — restore-merge must still win.
        let reflick = CompletedBatch(
            id: UUID(),
            photoCount: 2,
            deletedCount: 2,
            savedBytes: 100,
            completedAt: Date(),
            captureDate: nil,
            previewAssetIdentifiers: [],
            keptAssetIdentifiers: [],
            keptBytes: 0,
            sourceGroupID: unrelated.sourceGroupID
        )
        await vm.recordCompletedBatch(reflick)

        XCTAssertEqual(vm.completedBatches.count, 2,
                       "Restore merge must NOT spawn a third row")
        XCTAssertEqual(vm.completedBatches.first { $0.id == restoreTarget.id }?.deletedCount, 3,
                       "Restore-target accumulated: original 1 + reflick 2 = 3")
        XCTAssertEqual(vm.completedBatches.first { $0.id == unrelated.id }?.deletedCount, 1,
                       "Unrelated batch with same sourceGroupID must remain untouched")
    }

    // MARK: - Helpers

    private func makeBatch(
        keptIDs: [String],
        keptBytes: Int64,
        deletedCount: Int,
        savedBytes: Int64
    ) -> CompletedBatch {
        CompletedBatch(
            id: UUID(),
            photoCount: keptIDs.count + deletedCount,
            deletedCount: deletedCount,
            savedBytes: savedBytes,
            completedAt: Date(),
            captureDate: nil,
            previewAssetIdentifiers: [],
            keptAssetIdentifiers: keptIDs,
            keptBytes: keptBytes
        )
    }
}
