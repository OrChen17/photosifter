import Photos
import SwiftUI

protocol DeletionService: Sendable {
    func deleteAssets(_ assets: [PHAsset]) async throws
}
extension PhotoLibraryService: DeletionService {}

enum DeletionOutcome: Equatable {
    case nothingToDelete   // user kept everything
    case committed         // photos actually moved to Recently Deleted
    case cancelledByUser   // user dismissed the system delete prompt
    case failed(String)    // any other error
}

@Observable
@MainActor
final class SifterViewModel {
    var group: PhotoGroup
    // Mutable display order — skip moves an asset to the end
    var displayOrder: [PHAsset]
    var currentIndex: Int = 0
    var isComplete: Bool = false
    var isCommittingDeletes: Bool = false
    var deletionOutcome: DeletionOutcome?
    var deletedBytes: Int64 = 0

    // Computed from group decisions, not a race-prone counter (#2, #4)
    var deletedCount: Int { group.decisions.values.filter { $0 == .delete }.count }

    private let deletionService: any DeletionService
    private let haptics = HapticManager.shared
    private let sounds = SoundManager.shared

    // Deletes are queued here and only executed when the group is finalized
    private var pendingDeletes: [PHAsset] = []
    private var decisionHistory: [(index: Int, decision: Decision, asset: PHAsset)] = []
    // Track which assets have already been skipped once (can't skip twice)
    private var skippedIdentifiers: Set<String> = []

    init(group: PhotoGroup, deletionService: (any DeletionService)? = nil) {
        self.group = group
        self.displayOrder = group.assets
        self.deletionService = deletionService ?? PhotoLibraryService.shared
        // Resume mid-batch: jump past assets already decided in a previous
        // session, and re-queue their pending deletes so commit catches them.
        self.currentIndex = group.assets.firstIndex {
            group.decisions[$0.localIdentifier] == nil
        } ?? group.assets.count
        self.pendingDeletes = group.assets.filter {
            group.decisions[$0.localIdentifier] == .delete
        }
        if currentIndex >= group.assets.count && !group.assets.isEmpty {
            // Restored a group whose decisions were all made — flag complete
            // so the parent immediately commits and shows summary.
            self.isComplete = true
        }
    }

    /// True if the user has made at least one decision in this session.
    /// Used to decide whether the back button should prompt to save.
    var hasUnsavedDecisions: Bool { !decisionHistory.isEmpty }

    // MARK: - Queries

    var currentAsset: PHAsset? {
        guard currentIndex < displayOrder.count else { return nil }
        return displayOrder[currentIndex]
    }

    var progress: Double {
        guard !displayOrder.isEmpty else { return 1 }
        return Double(currentIndex) / Double(displayOrder.count)
    }

    var canUndo: Bool { !decisionHistory.isEmpty }

    var canSkipCurrent: Bool {
        guard let asset = currentAsset else { return false }
        return !skippedIdentifiers.contains(asset.localIdentifier)
    }

    /// True when this is the last undecided photo and nothing has been kept yet.
    var isLastUndecidedWithNoKept: Bool {
        let undecidedAhead = displayOrder[currentIndex...].filter {
            group.decisions[$0.localIdentifier] == nil
        }
        return undecidedAhead.count == 1 && group.keptAssets.isEmpty
    }

    // MARK: - Swipe actions

    func swipeRight() {
        guard let asset = currentAsset else { return }
        recordDecision(.keep, for: asset)
        haptics.playKeep()
        sounds.playKeep()
        advance()
    }

    // Queues the delete; nothing touches the photo library until commitDeletes().
    func swipeLeft() {
        guard let asset = currentAsset else { return }
        recordDecision(.delete, for: asset)
        pendingDeletes.append(asset)
        haptics.playDelete()
        sounds.playDelete()
        advance()
    }

    // MARK: - Skip

    func skipCurrent() {
        guard let asset = currentAsset,
              !skippedIdentifiers.contains(asset.localIdentifier) else { return }
        skippedIdentifiers.insert(asset.localIdentifier)
        displayOrder.remove(at: currentIndex)
        displayOrder.append(asset)
        // currentIndex stays — the next asset slides in automatically
        // Edge case: if this was the last asset, we're done
        if currentIndex >= displayOrder.count {
            finishGroup()
        }
    }

    // MARK: - Keep only this

    /// Marks the current photo as keep, queues everything else undecided for deletion, completes group.
    func keepOnlyCurrentAndDeleteRest() {
        guard let asset = currentAsset else { return }
        recordDecision(.keep, for: asset)
        for other in displayOrder where group.decisions[other.localIdentifier] == nil
                                    && other.localIdentifier != asset.localIdentifier {
            recordDecision(.delete, for: other)
            pendingDeletes.append(other)
        }
        finishGroup()
    }

    // MARK: - Quick win bulk actions

    /// Marks every undecided asset as delete and completes the group.
    /// Intentionally bypasses the isLastUndecidedWithNoKept guard — this is a
    /// deliberate bulk delete (confirmed by the caller before invoking).
    func deleteAll() {
        for asset in displayOrder where group.decisions[asset.localIdentifier] == nil {
            recordDecision(.delete, for: asset)
            pendingDeletes.append(asset)
        }
        finishGroup()
    }

    /// Keeps the asset with the earliest creationDate, marks all others delete.
    func keepOldestAndDeleteRest() {
        guard !displayOrder.isEmpty else { return }
        let oldest = displayOrder.min(by: {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        })!
        for asset in displayOrder {
            guard group.decisions[asset.localIdentifier] == nil else { continue }
            if asset.localIdentifier == oldest.localIdentifier {
                recordDecision(.keep, for: asset)
            } else {
                recordDecision(.delete, for: asset)
                pendingDeletes.append(asset)
            }
        }
        finishGroup()
    }

    // MARK: - Jump (tap on strip)

    /// Jump the cursor to `asset`. If the asset already has a decision, that
    /// decision is cleared so the user can re-swipe it — this is how the
    /// strip-tap replaces the undo button as the "fix a mistake" affordance.
    func jumpTo(asset: PHAsset) {
        guard let idx = displayOrder.firstIndex(where: { $0.localIdentifier == asset.localIdentifier })
        else { return }

        if let existing = group.decisions[asset.localIdentifier] {
            group.decisions.removeValue(forKey: asset.localIdentifier)
            if existing == .delete {
                pendingDeletes.removeAll { $0.localIdentifier == asset.localIdentifier }
            }
            decisionHistory.removeAll { $0.asset.localIdentifier == asset.localIdentifier }
        }

        currentIndex = idx
        isComplete = false
        haptics.playUndo()
    }

    // MARK: - Undo

    func undo() {
        guard let last = decisionHistory.last else { return }
        decisionHistory.removeLast()
        group.decisions.removeValue(forKey: last.asset.localIdentifier)
        // If it was a queued delete, remove from queue (fix #1)
        if last.decision == .delete {
            pendingDeletes.removeAll { $0.localIdentifier == last.asset.localIdentifier }
        }
        currentIndex = last.index
        isComplete = false  // fix #3 — undo re-opens the session
        haptics.playUndo()
    }

    // MARK: - Commit

    /// Called once by SifterView after isComplete becomes true.
    /// Batches all pending deletes into a single PHPhotoLibrary change.
    /// Sets `deletionOutcome` so the summary screen can branch on what
    /// actually happened (committed / cancelled at system prompt / failed).
    func commitDeletes() async {
        // Re-derive from decisions so a retry after cancellation still works
        // even though pendingDeletes was cleared on the first attempt.
        let toDelete = group.assets.filter { group.decisions[$0.localIdentifier] == .delete }
        guard !toDelete.isEmpty else {
            deletionOutcome = .nothingToDelete
            return
        }
        // Compute sizes before deletion — PHAssetResource returns nothing after photos are removed
        let acceptable: Set<PHAssetResourceType> = [.photo, .fullSizePhoto, .alternatePhoto, .adjustmentBasePhoto]
        deletedBytes = toDelete.reduce(Int64(0)) { total, asset in
            let resources = PHAssetResource.assetResources(for: asset)
            guard let r = resources.first(where: { acceptable.contains($0.type) }),
                  let bytes = r.value(forKey: "fileSize") as? Int64 else { return total }
            return total + bytes
        }
        isCommittingDeletes = true
        do {
            try await deletionService.deleteAssets(toDelete)
            pendingDeletes = []
            deletionOutcome = .committed
        } catch {
            // PHPhotosError.userCancelled is the canonical cancellation, but
            // some paths surface NSUserCancelledError — accept both.
            let ns = error as NSError
            if (error as? PHPhotosError)?.code == .userCancelled
                || ns.code == NSUserCancelledError {
                deletionOutcome = .cancelledByUser
            } else {
                deletionOutcome = .failed(error.localizedDescription)
            }
        }
        isCommittingDeletes = false
    }

    func retryCommitDeletes() async {
        // Don't clear outcome here — the summary screen would render with
        // stale zeros while waiting on the iOS confirmation prompt. Keep
        // the previous outcome until commitDeletes resolves with a new one.
        await commitDeletes()
    }

    /// Replaces this VM's group with a freshly hydrated one (e.g. from disk),
    /// and recomputes the resume point. Used by SifterView on appear so the
    /// view is bulletproof against any in-memory propagation gaps.
    func applyHydratedGroup(_ hydrated: PhotoGroup) {
        guard hydrated.id == group.id else { return }
        self.group = hydrated
        self.displayOrder = hydrated.assets
        self.currentIndex = hydrated.assets.firstIndex {
            hydrated.decisions[$0.localIdentifier] == nil
        } ?? hydrated.assets.count
        self.pendingDeletes = hydrated.assets.filter {
            hydrated.decisions[$0.localIdentifier] == .delete
        }
        if currentIndex >= hydrated.assets.count && !hydrated.assets.isEmpty {
            self.isComplete = true
        }
    }

    // MARK: - Private

    private func recordDecision(_ decision: Decision, for asset: PHAsset) {
        decisionHistory.append((index: currentIndex, decision: decision, asset: asset))
        group.decisions[asset.localIdentifier] = decision
    }

    private func advance() {
        currentIndex += 1
        if currentIndex >= displayOrder.count {
            finishGroup()
        }
    }

    private func finishGroup() {
        currentIndex = displayOrder.count
        isComplete = true
        haptics.playBatchComplete()
        sounds.playComplete()
    }
}
