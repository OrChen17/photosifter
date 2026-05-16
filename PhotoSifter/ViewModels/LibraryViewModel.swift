import Photos
import SwiftUI

enum GroupSortOrder: String, CaseIterable {
    case oldestBiggest
    case newestBiggest
    case biggestFirst
    case random

    var label: String {
        switch self {
        case .oldestBiggest: return "Oldest first"
        case .newestBiggest: return "Newest first"
        case .biggestFirst: return "Largest groups"
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
    var sortOrder: GroupSortOrder = .biggestFirst

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
        error = nil
        isScanning = true

        // Load stats immediately so counters are non-zero on first render
        completedBatches = await CompletedBatchStore.shared.loadAll()

        // Layer 1: Serve cached groups immediately (hydrated with saved decisions)
        var baseGroups: [PhotoGroup] = []
        if let cached = await groupingService.loadCachedGroups(), !cached.isEmpty {
            baseGroups = await groupingService.hydrateDecisions(into: cached)
                .filter { !completedGroupIDs.contains($0.id) }
            groups = sorted(baseGroups)
        }

        // Identify assets already in a cached group and the last scan cutoff so
        // Vision skips photos it has already processed.
        let knownIDs = Set(baseGroups.flatMap { $0.assets.map(\.localIdentifier) })
        let cutoff = await groupingService.loadScanCutoff()
        // Record now (before fetching) so photos added during a slow scan are
        // caught on the next launch rather than permanently skipped.
        let scanStartDate = Date()

        // Layer 2: Stream only new/changed groups; existing ones stay in the list
        let assets = await photoService.fetchAllAssets()
        scanProgress = (0, assets.count)

        var allGroups = baseGroups
        for await group in await groupingService.streamGroups(from: assets, excluding: knownIDs, since: cutoff) {
            let hydrated = await groupingService.hydrateDecisions(into: [group]).first ?? group
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

    private func sorted(_ groups: [PhotoGroup]) -> [PhotoGroup] {
        switch sortOrder {
        case .oldestBiggest:
            return groups.sorted {
                if $0.assets.count != $1.assets.count { return $0.assets.count > $1.assets.count }
                return ($0.captureDate ?? .distantFuture) < ($1.captureDate ?? .distantFuture)
            }
        case .newestBiggest:
            return groups.sorted {
                if $0.assets.count != $1.assets.count { return $0.assets.count > $1.assets.count }
                return ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast)
            }
        case .biggestFirst:
            return groups.sorted { $0.assets.count > $1.assets.count }
        case .random:
            return groups.shuffled()
        }
    }

    func markGroupComplete(_ group: PhotoGroup) {
        completedGroupIDs.insert(group.id)
        groups.removeAll { $0.id == group.id }
        quickWins.removeAll { $0.group.id == group.id }
        Task { await groupingService.saveDecisions(for: PhotoGroup(id: group.id, assets: group.assets, decisions: [:])) }
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

    /// Returns the next incomplete group chronologically after `current` —
    /// the one to suggest behind a "Continue" CTA. Pure lookup, no mutation,
    /// so the caller can decide when to actually navigate.
    func nextIncompleteGroup(after current: PhotoGroup) -> PhotoGroup? {
        let currentDate = current.captureDate ?? .distantPast
        return groups
            .filter { $0.id != current.id && !$0.isComplete && ($0.captureDate ?? .distantPast) > currentDate }
            .min(by: { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) })
    }
}
