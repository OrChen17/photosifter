import Photos
import SwiftUI

protocol DeletionService: Sendable {
    func deleteAssets(_ assets: [PHAsset]) async throws
}
extension PhotoLibraryService: DeletionService {}

@Observable
@MainActor
final class SifterViewModel {
    var group: PhotoGroup
    // Mutable display order — skip moves an asset to the end
    var displayOrder: [PHAsset]
    var currentIndex: Int = 0
    var isComplete: Bool = false
    var isCommittingDeletes: Bool = false

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
    }

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
    func commitDeletes() async {
        guard !pendingDeletes.isEmpty else { return }
        isCommittingDeletes = true
        let batch = pendingDeletes
        pendingDeletes = []
        try? await deletionService.deleteAssets(batch)
        isCommittingDeletes = false
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
