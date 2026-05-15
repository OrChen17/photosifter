import Photos
import SwiftUI

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

    var totalDeletedCount: Int { completedBatches.reduce(0) { $0 + $1.deletedCount } }
    var totalSavedBytes: Int64 { completedBatches.reduce(Int64(0)) { $0 + $1.savedBytes } }

    private let photoService = PhotoLibraryService.shared
    private let groupingService = GroupingService.shared

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

        // Layer 1: Serve cached groups immediately (hydrated with saved decisions)
        if let cached = await groupingService.loadCachedGroups(), !cached.isEmpty {
            groups = await groupingService.hydrateDecisions(into: cached)
        }

        // Layer 2: Re-scan in background, streaming results in
        var freshGroups: [PhotoGroup] = []
        let assets = await photoService.fetchAllAssets()
        scanProgress = (0, assets.count)

        for await group in await groupingService.streamGroups(from: assets) {
            // Hydrate this single new group's decisions before insertion
            let hydrated = await groupingService.hydrateDecisions(into: [group]).first ?? group
            withAnimation(.spring(duration: 0.35)) {
                freshGroups.append(hydrated)
                // Sort by group size desc, then date desc
                groups = freshGroups.sorted {
                    if $0.assets.count != $1.assets.count { return $0.assets.count > $1.assets.count }
                    return ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast)
                }
            }
        }

        isScanning = false
        await groupingService.persistGroups(groups)
        completedBatches = await CompletedBatchStore.shared.loadAll()

        // Quick wins fetch runs at utility priority after scan — doesn't block the grid
        Task(priority: .utility) {
            let wins = await QuickWinsService.shared.fetchAll()
            await MainActor.run { self.quickWins = wins }
        }
    }

    func markGroupComplete(_ group: PhotoGroup) {
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
