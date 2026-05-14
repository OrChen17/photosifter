import Photos
import SwiftUI

@Observable
@MainActor
final class LibraryViewModel {
    var groups: [PhotoGroup] = []
    var authStatus: PHAuthorizationStatus = .notDetermined
    var isScanning: Bool = false
    var scanProgress: (current: Int, total: Int) = (0, 0)
    var error: String?

    private let photoService = PhotoLibraryService.shared
    private let groupingService = GroupingService.shared

    func checkAuthorization() async {
        authStatus = await photoService.requestAuthorization()
        if authStatus == .authorized || authStatus == .limited {
            await load()
        }
    }

    func load() async {
        error = nil

        // Layer 1: Serve cached groups immediately
        if let cached = await groupingService.loadCachedGroups(), !cached.isEmpty {
            groups = cached
        }

        // Layer 2: Re-scan in background, streaming results in
        isScanning = true
        var freshGroups: [PhotoGroup] = []
        let assets = await photoService.fetchAllAssets()
        scanProgress = (0, assets.count)

        for await group in await groupingService.streamGroups(from: assets) {
            withAnimation(.spring(duration: 0.35)) {
                freshGroups.append(group)
                // Sort by group size desc, then date desc
                groups = freshGroups.sorted {
                    if $0.assets.count != $1.assets.count { return $0.assets.count > $1.assets.count }
                    return ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast)
                }
            }
        }

        isScanning = false
        await groupingService.persistGroups(groups)
    }

    func markGroupComplete(_ group: PhotoGroup) {
        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
            groups[idx] = group
        }
    }

    func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
    }
}
