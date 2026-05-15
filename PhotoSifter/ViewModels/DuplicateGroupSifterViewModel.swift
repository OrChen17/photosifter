import Photos

@Observable
@MainActor
final class DuplicateGroupSifterViewModel {
    let groups: [PhotoGroup]
    private(set) var currentIndex: Int = 0
    private(set) var mergedGroupIDs: Set<UUID> = []
    private(set) var isCommitting: Bool = false
    private(set) var deletedCount: Int = 0
    private(set) var deletedBytes: Int64 = 0

    var currentGroup: PhotoGroup? {
        currentIndex < groups.count ? groups[currentIndex] : nil
    }

    var isComplete: Bool { currentIndex >= groups.count }

    var progress: Double {
        groups.isEmpty ? 1.0 : Double(currentIndex) / Double(groups.count)
    }

    var mergedCount: Int { mergedGroupIDs.count }

    init(groups: [PhotoGroup]) {
        self.groups = groups
    }

    func swipeMerge() {
        guard let g = currentGroup else { return }
        mergedGroupIDs.insert(g.id)
        currentIndex += 1
    }

    func swipeKeepAll() {
        currentIndex += 1
    }

    func commitDecisions() async {
        isCommitting = true
        defer { isCommitting = false }
        var totalDeleted = 0
        var totalBytes: Int64 = 0
        for group in groups where mergedGroupIDs.contains(group.id) {
            let toDelete = assetsToDelete(in: group)
            for asset in toDelete {
                if let sz = fileSize(for: asset) { totalBytes += sz }
            }
            try? await PhotoLibraryService.shared.deleteAssets(toDelete)
            totalDeleted += toDelete.count
        }
        deletedCount = totalDeleted
        deletedBytes = totalBytes
    }

    func assetsToDelete(in group: PhotoGroup) -> [PHAsset] {
        guard let best = bestAsset(in: group) else { return [] }
        return group.assets.filter { $0.localIdentifier != best.localIdentifier }
    }

    private func bestAsset(in group: PhotoGroup) -> PHAsset? {
        group.assets.max(by: {
            let sA = fileSize(for: $0) ?? 0
            let sB = fileSize(for: $1) ?? 0
            if sA != sB { return sA < sB }
            return ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        })
    }

    private func fileSize(for asset: PHAsset) -> Int64? {
        let types: Set<PHAssetResourceType> = [.photo, .fullSizePhoto, .alternatePhoto, .adjustmentBasePhoto]
        return PHAssetResource.assetResources(for: asset)
            .first(where: { types.contains($0.type) })?
            .value(forKey: "fileSize") as? Int64
    }
}
