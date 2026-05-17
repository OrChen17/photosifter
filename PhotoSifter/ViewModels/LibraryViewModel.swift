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
    var sortOrder: GroupSortOrder = .oldestBiggest

    var totalDeletedCount: Int { completedBatches.reduce(0) { $0 + $1.deletedCount } }
    var totalSavedBytes: Int64 { completedBatches.reduce(Int64(0)) { $0 + $1.savedBytes } }

    private let photoService = PhotoLibraryService.shared
    private let groupingService = GroupingService.shared
    private var completedGroupIDs: Set<UUID> = []

    init() {
        // Read current status synchronously so ContentView shows the correct
        // screen on first render without waiting for any user interaction.
        authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
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

        // Load stats immediately so counters are non-zero on first render
        completedBatches = await CompletedBatchStore.shared.loadAll()

        // Layer 1: Serve cached groups immediately (hydrated with saved decisions)
        var baseGroups: [PhotoGroup] = []
        if let cached = await groupingService.loadCachedGroups(), !cached.isEmpty {
            baseGroups = await groupingService.hydrateDecisions(into: cached)
                .filter { !completedGroupIDs.contains($0.id) }
                .map { filledWithBytes($0) }
            groups = sorted(baseGroups)
        }

        // Identify assets already in a cached group so Vision skips re-evaluating them.
        let knownIDs = Set(baseGroups.flatMap { $0.assets.map(\.localIdentifier) })
        let scanStartDate = Date()

        // Layer 2: Stream new groups; already-grouped assets are excluded via knownIDs.
        let assets = await photoService.fetchAllAssets()
        scanProgress = (0, assets.count)

        var allGroups = baseGroups
        for await group in await groupingService.streamGroups(from: assets, excluding: knownIDs) {
            let hydrated = filledWithBytes(await groupingService.hydrateDecisions(into: [group]).first ?? group)
            guard !completedGroupIDs.contains(hydrated.id) else { continue }
            withAnimation(.spring(duration: 0.35)) {
                allGroups.append(hydrated)
                groups = sorted(allGroups)
            }
        }

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

    private func filledWithBytes(_ group: PhotoGroup) -> PhotoGroup {
        guard group.totalFileBytes == 0 else { return group }
        var g = group
        let acceptable: Set<PHAssetResourceType> = [.photo, .fullSizePhoto, .alternatePhoto, .adjustmentBasePhoto]
        g.totalFileBytes = g.assets.reduce(Int64(0)) { sum, asset in
            let resources = PHAssetResource.assetResources(for: asset)
            guard let r = resources.first(where: { acceptable.contains($0.type) }),
                  let bytes = r.value(forKey: "fileSize") as? Int64 else { return sum }
            return sum + bytes
        }
        return g
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
        Task {
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
