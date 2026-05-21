import Photos
import SwiftUI

enum GroupSortOrder: String, CaseIterable {
    case oldestBiggest
    case newestBiggest
    case biggestFirst
    case random

    var label: String {
        switch self {
        case .oldestBiggest: return "Oldest"
        case .newestBiggest: return "Newest"
        case .biggestFirst: return "Largest"
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
    var sortOrder: GroupSortOrder {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.sortOrderKey) }
    }

    private static let sortOrderKey = "library.groupSortOrder"

    var totalDeletedCount: Int { completedBatches.reduce(0) { $0 + $1.deletedCount } }
    var totalSavedBytes: Int64 { completedBatches.reduce(Int64(0)) { $0 + $1.savedBytes } }

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
            sortOrder = .biggestFirst
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
        elapsed("stats loaded")

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
        // If we have a prior scan cutoff, fetch only photos newer than `cutoff - bucketGap`.
        // The carry-back window ensures any new photo close to the cutoff can still bucket
        // with an old photo near the boundary; old singletons far from the cutoff won't
        // be re-evaluated, but by definition they can't pair with new photos (creationDate
        // gap > bucketGap = no shared bucket).
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
        case .random:
            return groups.shuffled()
        }
    }

    func markGroupComplete(_ group: PhotoGroup) {
        completedGroupIDs.insert(group.id)
        groups.removeAll { $0.id == group.id }
        quickWins.removeAll { $0.group.id == group.id }
        let remaining = groups
        let assetIDs = group.assets.map(\.localIdentifier)
        Task {
            await groupingService.addFlickedIdentifiers(assetIDs)
            await groupingService.saveDecisions(for: PhotoGroup(id: group.id, assets: group.assets, decisions: [:]))
            // Persist the updated group list immediately so a force-quit during an
            // active scan doesn't cause the completed group to reappear on next launch.
            await groupingService.persistGroups(remaining)
        }
    }

    func recordCompletedBatch(_ batch: CompletedBatch) async {
        await CompletedBatchStore.shared.append(batch)
        completedBatches.insert(batch, at: 0)
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
}
