import Photos
import SwiftUI

enum GroupSortOrder: String, CaseIterable {
    case oldestBiggest
    case newestBiggest
    case biggestFirst
    case smallestFirst
    case random

    var label: String {
        switch self {
        case .oldestBiggest: return "Oldest"
        case .newestBiggest: return "Newest"
        case .biggestFirst: return "Largest"
        case .smallestFirst: return "Smallest"
        case .random: return "Random"
        }
    }
}

@Observable
@MainActor
final class LibraryViewModel {
    var groups: [PhotoGroup] = []
    var selectedGroup: PhotoGroup?
    var authStatus: PHAuthorizationStatus
    var isScanning: Bool = false
    var scanProgress: (current: Int, total: Int) = (0, 0)
    var error: String?
    var completedBatches: [CompletedBatch] = []
    var quickWins: [QuickWin] = []
    var selectedQuickWin: QuickWin?
    var selectedDuplicateSession: DuplicateSession?
    var selectedSweepSession: SweepSession?
    var selectedRestoreSession: RestoreSession? {
        didSet {
            // Clearing the restore session (user backed out or finished) also clears
            // the merge target so a subsequent unrelated sift session can't accidentally
            // accumulate into the previously-restored batch.
            if selectedRestoreSession == nil { currentRestoreSourceBatchID = nil }
        }
    }
    /// While a re-flick session is active, this is the id of the batch whose stats
    /// should absorb the new deletes. `nil` means the next completed batch is a
    /// brand-new memory (the normal flow).
    var currentRestoreSourceBatchID: UUID?
    /// Total non-screenshot-ish image count in the library. Used as the denominator
    /// for the History coverage graph. Refreshed on `load()` and after restores.
    var totalLibraryCount: Int = 0
    /// Total bytes across every image asset still in the library. Drives the
    /// "Unflicked" stat tile (Unflicked = total − Kept). Computed asynchronously
    /// in `load()` because PHAssetResource iteration is O(N) over assets.
    var totalLibraryBytes: Int64 = 0
    /// True while the off-actor byte-walk is in flight. HistoryView shows a
    /// spinner on the Unflicked tile so users understand the value will land soon.
    var isComputingTotalLibraryBytes: Bool = false
    var sortOrder: GroupSortOrder {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.sortOrderKey) }
    }

    private static let sortOrderKey = "library.groupSortOrder"

    var totalDeletedCount: Int { completedBatches.reduce(0) { $0 + $1.deletedCount } }
    var totalSavedBytes: Int64 { completedBatches.reduce(Int64(0)) { $0 + $1.savedBytes } }
    /// Count of photos kept across all batches (i.e. photos that survived sifting).
    /// Falls back to `photoCount - deletedCount` for legacy batches missing
    /// `keptAssetIdentifiers`, so this remains stable across the migration.
    var totalKeptCount: Int {
        completedBatches.reduce(0) { acc, b in
            acc + (b.keptAssetIdentifiers?.count ?? max(0, b.photoCount - b.deletedCount))
        }
    }
    /// Bytes of photos kept. Legacy batches (no `keptBytes`) contribute 0 — we
    /// don't have the data to retro-fit them. New batches always contribute.
    var totalKeptBytes: Int64 {
        completedBatches.reduce(Int64(0)) { $0 + ($1.keptBytes ?? 0) }
    }
    /// Photos in the library that haven't been flicked yet. The graph's third slice.
    /// Clamped at 0 because a library mutation between scans could push this negative.
    var unflickedCount: Int {
        max(0, totalLibraryCount - totalKeptCount)
    }
    /// Bytes still in the library that the user hasn't explicitly kept or deleted.
    /// Total library bytes minus the kept bytes (deleted bytes are no longer on disk).
    /// Clamped at 0 against any race between scans.
    var unflickedBytes: Int64 {
        max(0, totalLibraryBytes - totalKeptBytes)
    }
    /// Source-group ids whose memory is still in the main grid (partially
    /// resolved). Sweep emits a `CompletedBatch` on every apply (even partial)
    /// so delete-bytes are tracked, but those in-progress batches must stay
    /// hidden from History until the memory leaves the grid.
    private var inProgressGroupIDs: Set<UUID> { Set(groups.map(\.id)) }

    private func isInProgress(_ batch: CompletedBatch) -> Bool {
        guard let gid = batch.sourceGroupID else { return false }
        return inProgressGroupIDs.contains(gid)
    }

    /// Batches that can be re-opened for re-flicking (have kept photos).
    var revisitableBatches: [CompletedBatch] {
        let inProgress = inProgressGroupIDs
        return completedBatches.filter { batch in
            batch.isRevisitable && !(batch.sourceGroupID.map(inProgress.contains) ?? false)
        }
    }
    /// Fully-resolved batches that have no kept photos left (or never had data).
    /// These show as no-thumbnail history rows.
    var historyOnlyBatches: [CompletedBatch] {
        let inProgress = inProgressGroupIDs
        return completedBatches.filter { batch in
            !batch.isRevisitable && !(batch.sourceGroupID.map(inProgress.contains) ?? false)
        }
    }

    private let photoService = PhotoLibraryService.shared
    private let groupingService = GroupingService.shared
    private var completedGroupIDs: Set<UUID> = []

    init() {
        // Read current status synchronously so ContentView shows the correct
        // screen on first render without waiting for any user interaction.
        authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if let raw = UserDefaults.standard.string(forKey: Self.sortOrderKey),
           let saved = GroupSortOrder(rawValue: raw) {
            sortOrder = saved
        } else {
            sortOrder = .random
        }
    }

    func checkAuthorization() async {
        authStatus = await photoService.requestAuthorization()
        if authStatus == .authorized || authStatus == .limited {
            await load()
        }
    }

    func load() async {
        guard !isScanning else { return }
        error = nil
        isScanning = true

        let t0 = Date()
        func elapsed(_ label: String) {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[PhotoSifter] \(ms)ms — \(label)")
        }

        // Load stats immediately so counters are non-zero on first render
        completedBatches = await CompletedBatchStore.shared.loadAll()
        totalLibraryCount = await photoService.totalImageAssetCount()
        elapsed("stats loaded")

        // Total library bytes (unflicked-tile denominator) is O(N) over assets.
        // CRITICAL: must run via `Task.detached`, not a structured Task that hops
        // onto PhotoLibraryService's actor. Otherwise the byte-walk serializes
        // against `loadThumbnailStream` and the library grid won't paint until
        // it finishes. `totalImageBytes()` is `nonisolated` for the same reason.
        let service = photoService
        isComputingTotalLibraryBytes = true
        Task.detached(priority: .utility) {
            let bytes = service.totalImageBytes()
            await MainActor.run {
                self.totalLibraryBytes = bytes
                self.isComputingTotalLibraryBytes = false
            }
        }

        let flickedIDs = await groupingService.loadFlickedIdentifiers()
        let rawDecisions = await groupingService.loadRawDecisions()
        elapsed("flicked+decisions loaded")

        // Layer 1: Serve cached groups immediately (hydrated with saved decisions)
        var baseGroups: [PhotoGroup] = []
        if let cached = await groupingService.loadCachedGroups(), !cached.isEmpty {
            baseGroups = cached
                .map { GroupingService.hydrateGroup($0, using: rawDecisions) }
                .filter { !completedGroupIDs.contains($0.id) }
                .compactMap { group -> PhotoGroup? in
                    let unflicked = group.assets.filter { !flickedIDs.contains($0.localIdentifier) }
                    guard unflicked.count >= 2 else { return nil }
                    guard unflicked.count < group.assets.count else { return group }
                    var copy = PhotoGroup(id: group.id, assets: unflicked)
                    copy.decisions = group.decisions.filter { key, _ in unflicked.contains { $0.localIdentifier == key } }
                    return copy
                }
            groups = sorted(baseGroups)
        }
        elapsed("layer1 done — \(baseGroups.count) cached groups")

        // Identify assets already in a cached group OR already flicked so Vision skips them.
        let knownIDs = Set(baseGroups.flatMap { $0.assets.map(\.localIdentifier) }).union(flickedIDs)
        let scanStartDate = Date()

        // Layer 2: Stream new groups; already-grouped assets are excluded via knownIDs.
        // Fetch by modificationDate so edits and restorations from Recently Deleted are
        // picked up. The small carry-back window (bucketGap) provides a safety buffer
        // around the cutoff boundary.
        let cutoff = await groupingService.loadScanCutoff()
        let fetchSince = cutoff.map { $0.addingTimeInterval(-GroupingService.timeBucketGap) }
        let assets = await photoService.fetchAllAssets(since: fetchSince)
        elapsed("fetchAllAssets done — \(assets.count) assets, \(knownIDs.count) already known")
        scanProgress = (0, assets.count)

        var allGroups = baseGroups
        var batchBuffer: [PhotoGroup] = []
        var lastFlushDate = Date()
        var streamedGroupCount = 0

        func flushBatch() {
            guard !batchBuffer.isEmpty else { return }
            let batch = batchBuffer
            batchBuffer = []
            lastFlushDate = Date()
            withAnimation(.spring(duration: 0.35)) {
                if sortOrder == .random {
                    groups.append(contentsOf: batch)
                } else {
                    groups = sorted(allGroups)
                }
            }
        }

        for await group in await groupingService.streamGroups(from: assets, excluding: knownIDs) {
            let hydrated = GroupingService.hydrateGroup(group, using: rawDecisions)
            guard !completedGroupIDs.contains(hydrated.id) else { continue }
            guard hydrated.assets.filter({ !flickedIDs.contains($0.localIdentifier) }).count >= 2 else { continue }
            allGroups.append(hydrated)
            batchBuffer.append(hydrated)
            streamedGroupCount += 1
            if batchBuffer.count >= 8 || Date().timeIntervalSince(lastFlushDate) >= 0.4 {
                elapsed("  flush #\(streamedGroupCount) groups so far")
                flushBatch()
            }
        }
        flushBatch()
        elapsed("scan complete — \(streamedGroupCount) new groups found")

        isScanning = false
        await groupingService.saveScanCutoff(scanStartDate)
        await groupingService.persistGroups(groups)

        // Quick wins fetch runs at utility priority after scan — doesn't block the grid
        Task(priority: .utility) {
            let wins = await QuickWinsService.shared.fetchAll()
            await MainActor.run { self.quickWins = wins }
        }
    }

    func applySort() {
        groups = sorted(groups)
    }

    private func sorted(_ groups: [PhotoGroup]) -> [PhotoGroup] {
        switch sortOrder {
        case .oldestBiggest:
            return groups.sorted {
                let d0 = $0.captureDate ?? .distantFuture
                let d1 = $1.captureDate ?? .distantFuture
                if d0 != d1 { return d0 < d1 }
                return $0.assets.count > $1.assets.count
            }
        case .newestBiggest:
            return groups.sorted {
                let d0 = $0.captureDate ?? .distantPast
                let d1 = $1.captureDate ?? .distantPast
                if d0 != d1 { return d0 > d1 }
                return $0.assets.count > $1.assets.count
            }
        case .biggestFirst:
            return groups.sorted { $0.totalFileBytes > $1.totalFileBytes }
        case .smallestFirst:
            return groups.sorted { $0.totalFileBytes < $1.totalFileBytes }
        case .random:
            return groups.shuffled()
        }
    }

    func markGroupComplete(_ group: PhotoGroup) {
        completedGroupIDs.insert(group.id)
        groups.removeAll { $0.id == group.id }
        quickWins.removeAll { $0.group.id == group.id }
        let remaining = groups
        // Only flick kept assets — deleted ones are gone from the library, and if
        // ever restored from Recently Deleted they should re-enter the scan.
        let keptIDs = group.assets
            .filter { group.decisions[$0.localIdentifier] != .delete }
            .map(\.localIdentifier)
        Task {
            await groupingService.addFlickedIdentifiers(keptIDs)
            await groupingService.saveDecisions(for: PhotoGroup(id: group.id, assets: group.assets, decisions: [:]))
            // Persist the updated group list immediately so a force-quit during an
            // active scan doesn't cause the completed group to reappear on next launch.
            await groupingService.persistGroups(remaining)
        }
    }

    /// Records a `CompletedBatch`. Two merge paths take priority over append:
    ///
    /// 1. **Restore merge** — a `Revisit` re-flick session is active
    ///    (`currentRestoreSourceBatchID` set). Accumulate into that specific
    ///    batch; the kept side reflects the new survivors.
    /// 2. **Source-group merge** — the incoming batch carries a
    ///    `sourceGroupID` matching a prior batch's. Sweep emits one batch per
    ///    touched memory (even partial), and the regular Sifter tags its
    ///    batches with the same `vm.group.id`. So a memory partially touched
    ///    in Sweep and later finished in Sifter (or in a second Sweep apply)
    ///    rolls into one History row with delete-bytes accumulated.
    ///
    /// Otherwise the batch is appended as a new row.
    func recordCompletedBatch(_ batch: CompletedBatch) async {
        // Restore-merge path: re-flick of a Revisit card.
        if let sourceID = currentRestoreSourceBatchID,
           let idx = completedBatches.firstIndex(where: { $0.id == sourceID }) {
            let original = completedBatches[idx]
            let newKeptCount = batch.keptAssetIdentifiers?.count ?? 0
            let merged = CompletedBatch(
                id: original.id,
                photoCount: original.deletedCount + batch.deletedCount + newKeptCount,
                deletedCount: original.deletedCount + batch.deletedCount,
                savedBytes: original.savedBytes + batch.savedBytes,
                completedAt: original.completedAt,
                captureDate: original.captureDate,
                previewAssetIdentifiers: original.previewAssetIdentifiers,
                keptAssetIdentifiers: batch.keptAssetIdentifiers,
                keptBytes: batch.keptBytes,
                sourceGroupID: original.sourceGroupID
            )
            await CompletedBatchStore.shared.replace(merged)
            completedBatches[idx] = merged
            currentRestoreSourceBatchID = nil
            return
        }

        // Source-group-merge path: same memory touched across sessions.
        if let gid = batch.sourceGroupID,
           let idx = completedBatches.firstIndex(where: { $0.sourceGroupID == gid }) {
            let original = completedBatches[idx]
            let newKeptCount = batch.keptAssetIdentifiers?.count ?? 0
            let merged = CompletedBatch(
                id: original.id,
                photoCount: original.deletedCount + batch.deletedCount + newKeptCount,
                deletedCount: original.deletedCount + batch.deletedCount,
                savedBytes: original.savedBytes + batch.savedBytes,
                completedAt: original.completedAt,
                captureDate: original.captureDate ?? batch.captureDate,
                // Prefer the kept-side preview the new batch carries; fall
                // back to the original's preview if the new one is empty.
                previewAssetIdentifiers: batch.previewAssetIdentifiers.isEmpty
                    ? original.previewAssetIdentifiers
                    : batch.previewAssetIdentifiers,
                keptAssetIdentifiers: batch.keptAssetIdentifiers,
                keptBytes: batch.keptBytes,
                sourceGroupID: gid
            )
            await CompletedBatchStore.shared.replace(merged)
            completedBatches[idx] = merged
            return
        }

        await CompletedBatchStore.shared.append(batch)
        completedBatches.insert(batch, at: 0)
    }

    /// Reopens a completed batch's kept photos for re-flicking. The batch is
    /// mutated **in place** (`keptAssetIdentifiers = []`, `keptBytes = 0`,
    /// `photoCount = deletedCount`) so the deleted-side stats (`totalDeletedCount`,
    /// `totalSavedBytes`) are preserved exactly. The kept photos are removed from
    /// the flicked-IDs set so they're eligible for a future scan, and a
    /// `RestoreSession` is published for the HistoryView's NavigationStack.
    ///
    /// Returns the updated batch (or nil if nothing could be restored — e.g. the
    /// user had already deleted every "kept" photo from Photos directly).
    @discardableResult
    func restoreBatch(_ batch: CompletedBatch) async -> CompletedBatch? {
        guard let keptIDs = batch.keptAssetIdentifiers, !keptIDs.isEmpty else { return nil }

        // 1. Resolve assets that still exist in the library. If the user has
        //    manually nuked them all from Photos, bail without mutating state.
        let result = PHAsset.fetchAssets(withLocalIdentifiers: keptIDs, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in assets.append(a) }
        guard !assets.isEmpty else { return nil }

        // 2. Let future scans re-pick these photos.
        await groupingService.removeFlickedIdentifiers(keptIDs)

        // 3. Zero out the kept side, keep the deleted-side history intact.
        var updated = batch
        updated.keptAssetIdentifiers = []
        updated.keptBytes = 0
        updated.photoCount = batch.deletedCount
        await CompletedBatchStore.shared.replace(updated)
        if let idx = completedBatches.firstIndex(where: { $0.id == batch.id }) {
            completedBatches[idx] = updated
        }

        // 4. Hand the user a fresh PhotoGroup to flick. Chronological for the strip.
        let sorted = assets.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
        // 5. Mark this batch as the merge target so any new deletes from the
        //    upcoming sift session accumulate into it instead of spawning a
        //    duplicate History row. MUST be set before publishing the navigation
        //    session (didSet on selectedRestoreSession clears the target when
        //    set to nil, so we order set-id-first / publish-second).
        currentRestoreSourceBatchID = batch.id
        selectedRestoreSession = RestoreSession(group: PhotoGroup(id: UUID(), assets: sorted))
        return updated
    }

    /// Updates the in-memory copy of a group and persists its decisions so
    /// the user can resume the batch on next launch.
    func updateGroup(_ group: PhotoGroup) {
        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
            groups[idx] = group
        }
    }

    func saveGroupProgress(_ group: PhotoGroup) async {
        updateGroup(group)
        await groupingService.saveDecisions(for: group)
    }

    func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
    }

    func removeQuickWins(ofCategory category: QuickWinCategory) {
        quickWins.removeAll { $0.category == category }
    }

    /// Returns the next incomplete group in the current sort order after `current`.
    /// Pure lookup, no mutation, so the caller can decide when to actually navigate.
    func nextIncompleteGroup(after current: PhotoGroup) -> PhotoGroup? {
        guard let idx = groups.firstIndex(of: current) else { return nil }
        return groups[(idx + 1)...].first { !$0.isComplete }
    }

    // MARK: - Sweep session

    func startSweepSession() {
        guard groups.count >= 1 else { return }
        selectedSweepSession = nil
        Task { @MainActor in
            selectedSweepSession = SweepSession(groups: groups)
        }
    }

    /// Commit the result of a Sweep `Apply`, fanned out per source group.
    /// Every touched memory emits its own per-group `CompletedBatch` tagged
    /// with `sourceGroupID = group.id` so cross-session merging in
    /// `recordCompletedBatch` rolls multiple sweeps (and a follow-up Sifter
    /// session) on the same memory into a single History row.
    ///
    /// Per-group dispositions:
    /// - **Fully resolved** (every survivor is kept this sweep or had a prior
    ///   `.keep` decision) → emit batch with the memory's kept identifiers +
    ///   bytes, mark group complete.
    /// - **Orphan** (`survivors < 2`) → emit batch (Revisit-capable if any
    ///   keep survived), mark complete.
    /// - **Partial** → emit a batch reflecting the current kept-state,
    ///   accumulating any prior deletes; the group stays in the main grid
    ///   with `decisions[id] = .keep` hydrated. The batch is **hidden** from
    ///   History via `inProgressGroupIDs` until the group leaves the grid.
    ///
    /// Stability caveat [uncertain]: `sourceGroupID` is `PhotoGroup.id`,
    /// which is regenerated each scan. Cross-launch merging is out of scope.
    func applySweepResult(snapshot: SweepSifterViewModel.ApplySnapshot) async {
        let deletedIDs = snapshot.deletedIDs
        let keptIDs    = snapshot.keptIDs
        let touched    = deletedIDs.union(keptIDs)
        guard !touched.isEmpty else { return }

        var updated: [PhotoGroup] = []
        updated.reserveCapacity(groups.count)
        var batchesToEmit: [CompletedBatch] = []

        for group in groups {
            guard snapshot.sourceGroupIDs.contains(group.id) else {
                updated.append(group)
                continue
            }

            let groupAssetIDs = group.assets.map(\.localIdentifier)
            let groupAssetIDSet = Set(groupAssetIDs)
            let groupDeleted = groupAssetIDSet.intersection(deletedIDs)
            let groupKept    = groupAssetIDSet.intersection(keptIDs)
            let groupTouched = groupDeleted.union(groupKept)

            if groupTouched.isEmpty {
                updated.append(group)
                continue
            }

            // Survivors-after-this-sweep = everything except the deletes.
            // Kept-in-this-sweep stay as survivors with decisions[id] = .keep.
            let survivors = group.assets.filter { !groupDeleted.contains($0.localIdentifier) }

            // "Fully resolved" = every survivor has a decision (this sweep's
            // kept ones, or a prior .keep already in group.decisions). When the
            // group is fully decided, it leaves the main grid and becomes a
            // CompletedBatch.
            let fullyResolved = survivors.allSatisfy { asset in
                let id = asset.localIdentifier
                return groupKept.contains(id) || group.decisions[id] == .keep
            }
            let orphan = survivors.count < 2

            let keptAssets = survivors.filter { asset in
                let id = asset.localIdentifier
                return groupKept.contains(id) || group.decisions[id] == .keep
            }
            let keptIDsForBatch = keptAssets.map(\.localIdentifier)
            let savedBytes = groupDeleted.reduce(Int64(0)) { sum, id in
                sum + (snapshot.deletedBytesByID[id] ?? 0)
            }
            let keptBytesForBatch = groupKept.reduce(Int64(0)) { sum, id in
                sum + (snapshot.keptBytesByID[id] ?? 0)
            }
            let preview = keptIDsForBatch.isEmpty
                ? Array(groupDeleted.prefix(4))
                : Array(keptIDsForBatch.prefix(4))

            // Every touched group emits a batch (full / orphan / partial).
            // Partial batches are hidden from History until the group leaves
            // the grid; the merge logic in recordCompletedBatch accumulates
            // delete-counts and saved-bytes across sweeps.
            let batch = CompletedBatch(
                id: UUID(),
                photoCount: keptIDsForBatch.count + groupDeleted.count,
                deletedCount: groupDeleted.count,
                savedBytes: savedBytes,
                completedAt: Date(),
                captureDate: group.captureDate,
                previewAssetIdentifiers: preview,
                keptAssetIdentifiers: keptIDsForBatch,
                keptBytes: keptBytesForBatch,
                sourceGroupID: group.id
            )
            batchesToEmit.append(batch)

            if fullyResolved || orphan {
                completedGroupIDs.insert(group.id)
                // (group not appended → falls out of main grid)
                continue
            }

            // Partial: trim deleted out, hydrate newly-kept as .keep, keep
            // the group in the main grid.
            var trimmed = PhotoGroup(id: group.id, assets: survivors)
            var nextDecisions = group.decisions.filter { key, _ in
                survivors.contains { $0.localIdentifier == key }
            }
            for id in groupKept { nextDecisions[id] = .keep }
            trimmed.decisions = nextDecisions
            trimmed.totalFileBytes = group.totalFileBytes
            updated.append(trimmed)
        }

        withAnimation(.spring(duration: 0.35)) {
            groups = updated
        }

        await groupingService.addFlickedIdentifiers(Array(keptIDs))
        await groupingService.persistGroups(groups)
        for batch in batchesToEmit {
            await recordCompletedBatch(batch)
        }
    }
}
