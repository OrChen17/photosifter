import Photos
import SwiftUI

/// One Sweep session = many memories merged into a single per-asset swipe queue.
/// Decisions are held in-memory until `apply()` commits them in a single batch
/// (one PHPhotoLibrary deletion, one flick of all touched IDs).
@Observable
@MainActor
final class SweepSifterViewModel {
    private(set) var queue: [PHAsset]
    private(set) var currentIndex: Int = 0
    private(set) var decisions: [String: Decision] = [:]

    private(set) var sessionDeletedCount: Int = 0
    private(set) var sessionKeptCount: Int = 0
    private(set) var sessionDeletedBytes: Int64 = 0

    private(set) var isApplying: Bool = false
    private(set) var lastApplyOutcome: DeletionOutcome?

    /// Reverse lookup `localIdentifier -> source group id`, used by the strip
    /// to draw cross-memory boundary dividers.
    private var groupIDByAsset: [String: UUID] = [:]
    /// Every asset this session has ever queued, applied ones included, so a
    /// later `sync` never puts a resolved photo back in the queue.
    private var knownAssetIDs: Set<String> = []

    private var skippedIDs: Set<String> = []
    /// Per-action undo log. `decision == nil` denotes a skip; otherwise a keep/delete.
    /// Skip entries let `undo()` walk the cursor back to a skipped photo instead of
    /// landing on whatever undecided slot got advanced to.
    private var actionHistory: [(assetID: String, decision: Decision?)] = []

    init(groups: [PhotoGroup]) {
        self.queue = []
        sync(with: groups)
    }

    /// Appends assets from groups that arrived after the session started (the
    /// scan streams groups in while the user is already flicking). Assets the
    /// session already knows only get their group mapping refreshed, because a
    /// rescan regenerates `PhotoGroup.id`.
    func sync(with groups: [PhotoGroup]) {
        for group in groups {
            for asset in group.assets {
                let id = asset.localIdentifier
                groupIDByAsset[id] = group.id
                if knownAssetIDs.insert(id).inserted {
                    queue.append(asset)
                }
            }
        }
    }

    // MARK: - Cursor

    var currentAsset: PHAsset? {
        guard currentIndex >= 0, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    /// Pre-render candidate for the behind-card in FlickCardArea.
    var nextAsset: PHAsset? {
        let next = currentIndex + 1
        guard next < queue.count else { return nil }
        return queue[next]
    }

    /// Returns the next `count` assets for image preloading.
    func upcomingAssets(count: Int) -> [PHAsset] {
        let start = currentIndex
        let end = min(queue.count, start + count)
        guard start < end else { return [] }
        return Array(queue[start..<end])
    }

    var isQueueExhausted: Bool { currentIndex >= queue.count }

    /// Photos still in `queue` minus those already decided this session.
    /// The Apply button uses this to decide whether to enable; `progress` uses
    /// it for the bar denominator.
    var pendingDeleteCount: Int {
        decisions.values.reduce(0) { $0 + ($1 == .delete ? 1 : 0) }
    }
    var pendingKeepCount: Int {
        decisions.values.reduce(0) { $0 + ($1 == .keep ? 1 : 0) }
    }
    var hasPendingDecisions: Bool { !decisions.isEmpty }
    var canUndo: Bool { !actionHistory.isEmpty }

    var progress: Double {
        guard !queue.isEmpty else { return 1.0 }
        return Double(currentIndex) / Double(queue.count)
    }

    func groupID(for asset: PHAsset) -> UUID? {
        groupIDByAsset[asset.localIdentifier]
    }

    // MARK: - Swipe actions

    func swipeRight() { recordDecision(.keep) }
    func swipeLeft()  { recordDecision(.delete) }

    private func recordDecision(_ decision: Decision) {
        guard let asset = currentAsset else { return }
        let id = asset.localIdentifier
        decisions[id] = decision
        actionHistory.append((id, decision))
        advanceCursor()
    }

    /// Move the cursor to the next undecided, un-skipped asset, leaving the
    /// current asset in place in the strip. One-shot per asset so a user can't
    /// loop forever on a hard photo.
    func skip() {
        guard let asset = currentAsset else { return }
        let id = asset.localIdentifier
        guard !skippedIDs.contains(id) else { return }
        skippedIDs.insert(id)
        actionHistory.append((id, nil))
        var next = currentIndex + 1
        while next < queue.count {
            let nextID = queue[next].localIdentifier
            if decisions[nextID] == nil && !skippedIDs.contains(nextID) {
                currentIndex = next
                HapticManager.shared.playNavigate()
                SoundManager.shared.playSkip()
                return
            }
            next += 1
        }
        currentIndex = queue.count
        HapticManager.shared.playNavigate()
        SoundManager.shared.playSkip()
    }

    func undo() {
        guard let last = actionHistory.popLast() else { return }
        if last.decision != nil {
            decisions.removeValue(forKey: last.assetID)
        } else {
            skippedIDs.remove(last.assetID)
        }
        if let idx = queue.firstIndex(where: { $0.localIdentifier == last.assetID }) {
            currentIndex = idx
        }
        HapticManager.shared.playUndo()
        SoundManager.shared.playUndo()
    }

    /// Jump the cursor to a tapped strip thumbnail. Clears that asset's
    /// pending decision so it can be re-swiped, matching the existing
    /// strip-tap-replaces-undo semantics elsewhere in the app.
    func jumpTo(asset: PHAsset) {
        let id = asset.localIdentifier
        guard let idx = queue.firstIndex(where: { $0.localIdentifier == id }) else { return }
        if decisions[id] != nil {
            decisions.removeValue(forKey: id)
            actionHistory.removeAll { $0.assetID == id }
        }
        currentIndex = idx
    }

    private func advanceCursor() {
        var next = currentIndex + 1
        while next < queue.count && decisions[queue[next].localIdentifier] != nil {
            next += 1
        }
        currentIndex = min(next, queue.count)
    }

    // MARK: - Apply

    /// Result handed to `LibraryViewModel.applySweepResult` so the view layer
    /// can fan the apply out per source group: fully-resolved memories become
    /// their own Revisit-capable `CompletedBatch`, partial ones stay in the
    /// library grid with kept assets hydrated as `.keep` decisions.
    ///
    /// `deletedBytesByID` / `keptBytesByID` are keyed by localIdentifier so
    /// the per-group batch's `savedBytes` / `keptBytes` can be summed from
    /// just the assets that belonged to that source group.
    struct ApplySnapshot {
        let outcome: DeletionOutcome
        let deletedIDs: Set<String>
        let keptIDs: Set<String>
        let sourceGroupIDs: Set<UUID>
        let deletedBytes: Int64
        let deletedBytesByID: [String: Int64]
        let keptBytesByID: [String: Int64]
        let previewIdentifiers: [String]
        let earliestCaptureDate: Date?
    }

    func apply(deletionService: DeletionService = PhotoLibraryService.shared) async -> ApplySnapshot {
        isApplying = true
        defer { isApplying = false }

        let touched = decisions
        let deletes = touched.filter { $0.value == .delete }.map(\.key)
        let keeps   = touched.filter { $0.value == .keep  }.map(\.key)

        guard !touched.isEmpty else {
            let snapshot = ApplySnapshot(
                outcome: .nothingToDelete,
                deletedIDs: [],
                keptIDs: [],
                sourceGroupIDs: [],
                deletedBytes: 0,
                deletedBytesByID: [:],
                keptBytesByID: [:],
                previewIdentifiers: [],
                earliestCaptureDate: nil
            )
            lastApplyOutcome = .nothingToDelete
            return snapshot
        }

        let deleteAssets = queue.filter { deletes.contains($0.localIdentifier) }
        let keepAssets   = queue.filter { keeps.contains($0.localIdentifier) }

        let acceptable: Set<PHAssetResourceType> = [.photo, .fullSizePhoto, .alternatePhoto, .adjustmentBasePhoto]
        func resourceBytes(_ asset: PHAsset) -> Int64 {
            let resources = PHAssetResource.assetResources(for: asset)
            guard let r = resources.first(where: { acceptable.contains($0.type) }),
                  let bytes = r.value(forKey: "fileSize") as? Int64 else { return 0 }
            return bytes
        }

        var deletedBytesByID: [String: Int64] = [:]
        var deletedBytes: Int64 = 0
        for asset in deleteAssets {
            let b = resourceBytes(asset)
            deletedBytesByID[asset.localIdentifier] = b
            deletedBytes += b
        }

        var keptBytesByID: [String: Int64] = [:]
        for asset in keepAssets {
            keptBytesByID[asset.localIdentifier] = resourceBytes(asset)
        }

        // Earliest capture date across everything touched, used for the
        // History card's date label.
        let touchedIDs = Set(touched.keys)
        let earliestCaptureDate = queue
            .filter { touchedIDs.contains($0.localIdentifier) }
            .compactMap(\.creationDate)
            .min()

        let previewIDs: [String] = !deletes.isEmpty
            ? Array(deletes.prefix(4))
            : Array(keeps.prefix(4))

        let sourceGroupIDs = Set(touchedIDs.compactMap { groupIDByAsset[$0] })

        do {
            if !deleteAssets.isEmpty {
                try await deletionService.deleteAssets(deleteAssets)
            }
        } catch {
            let outcome: DeletionOutcome = {
                let ns = error as NSError
                if (error as? PHPhotosError)?.code == .userCancelled
                    || ns.code == NSUserCancelledError {
                    return .cancelledByUser
                }
                return .failed(error.localizedDescription)
            }()
            lastApplyOutcome = outcome
            return ApplySnapshot(
                outcome: outcome,
                deletedIDs: [],
                keptIDs: [],
                sourceGroupIDs: [],
                deletedBytes: 0,
                deletedBytesByID: [:],
                keptBytesByID: [:],
                previewIdentifiers: [],
                earliestCaptureDate: nil
            )
        }

        // Strip resolved items out of the queue, preserving currentIndex on a
        // surviving asset where possible.
        let priorCurrentID = currentAsset?.localIdentifier
        queue.removeAll { touchedIDs.contains($0.localIdentifier) }
        if let pid = priorCurrentID,
           let newIdx = queue.firstIndex(where: { $0.localIdentifier == pid }) {
            currentIndex = newIdx
        } else {
            currentIndex = min(currentIndex, queue.count)
        }
        decisions.removeAll()
        actionHistory.removeAll()

        sessionDeletedCount += deletes.count
        sessionKeptCount    += keeps.count
        sessionDeletedBytes += deletedBytes

        let outcome: DeletionOutcome = deletes.isEmpty ? .nothingToDelete : .committed
        lastApplyOutcome = outcome

        return ApplySnapshot(
            outcome: outcome,
            deletedIDs: Set(deletes),
            keptIDs: Set(keeps),
            sourceGroupIDs: sourceGroupIDs,
            deletedBytes: deletedBytes,
            deletedBytesByID: deletedBytesByID,
            keptBytesByID: keptBytesByID,
            previewIdentifiers: previewIDs,
            earliestCaptureDate: earliestCaptureDate
        )
    }
}
