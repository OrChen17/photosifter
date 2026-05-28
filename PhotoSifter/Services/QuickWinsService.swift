import Photos
import CryptoKit

actor QuickWinsService {
    static let shared = QuickWinsService()

    private let screenshotBatchSize = 20
    private let acceptable: Set<PHAssetResourceType> = [.photo, .fullSizePhoto, .alternatePhoto, .adjustmentBasePhoto]

    // MARK: - Public

    func fetchAll() async -> [QuickWin] {
        async let screenshots = fetchScreenshotWins()
        async let duplicates  = findExactDuplicateWins()
        let all = await screenshots + duplicates
        return all.filter { $0.photoCount > 0 }
    }

    // MARK: - Screenshots

    private func fetchScreenshotWins() async -> [QuickWin] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaSubtype & %d) != 0",
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)

        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        guard assets.count >= 2 else { return [] }

        let totalCount = assets.count
        let chunks = stride(from: 0, to: assets.count, by: screenshotBatchSize).map {
            Array(assets[$0..<min($0 + screenshotBatchSize, assets.count)])
        }

        return chunks.map { chunk in
            // Fill totalFileBytes so the History "Unflicked" tile reflects this group's
            // bytes. This walks PHAssetResource per chunk asset but stays on the
            // .utility priority task that drives fetchAll().
            var group = PhotoGroup(id: UUID(), assets: chunk, decisions: [:])
            group.totalFileBytes = chunk.reduce(Int64(0)) { $0 + (fileSize(for: $1) ?? 0) }
            return QuickWin(
                id: UUID(),
                category: .screenshots,
                group: group,
                totalCount: totalCount
            )
        }
    }

    // MARK: - Exact duplicates (size pre-filter + SHA-256, memory-conscious)

    private func findExactDuplicateWins() async -> [QuickWin] {
        // Fetch all images, then use size pre-filter to eliminate >95% before hashing.
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: fetchOptions).enumerateObjects { a, _, _ in assets.append(a) }
        guard assets.count >= 2 else { return [] }

        // Step 1: size pre-filter using the pure helper
        var sizeMap: [String: Int64] = [:]
        for asset in assets {
            if let sz = fileSize(for: asset) { sizeMap[asset.localIdentifier] = sz }
        }
        let filteredIDs = Set(Self.sizePrefilterIdentifiers(sizeMap))
        let candidates = assets.filter { filteredIDs.contains($0.localIdentifier) }
        guard !candidates.isEmpty else { return [] }

        // Step 2: hash in batches of 4 to bound memory pressure
        var hashMap: [String: String] = [:]
        let batches = stride(from: 0, to: candidates.count, by: 4).map {
            Array(candidates[$0..<min($0 + 4, candidates.count)])
        }
        for batch in batches {
            await withTaskGroup(of: (String, String?).self) { group in
                for asset in batch {
                    group.addTask { [self] in (asset.localIdentifier, await self.sha256(for: asset)) }
                }
                for await (id, digest) in group {
                    if let digest { hashMap[id] = digest }
                }
            }
        }

        // Step 3: group by hash using the pure helper
        let assetByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.localIdentifier, $0) })
        return Self.groupIdentifiersByHash(hashMap).compactMap { ids -> QuickWin? in
            let grouped = ids.compactMap { assetByID[$0] }
                .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            guard grouped.count >= 2 else { return nil }
            // sizeMap was populated above for every candidate — reuse it instead of
            // hitting PHAssetResource a second time.
            var group = PhotoGroup(id: UUID(), assets: grouped, decisions: [:])
            group.totalFileBytes = grouped.reduce(Int64(0)) { $0 + (sizeMap[$1.localIdentifier] ?? 0) }
            return QuickWin(
                id: UUID(),
                category: .duplicates,
                group: group,
                totalCount: grouped.count
            )
        }
    }

    // MARK: - Pure helpers (internal for testing)

    /// Groups asset localIdentifiers by hash value. Returns only groups with ≥ 2 members.
    static func groupIdentifiersByHash(_ hashMap: [String: String]) -> [[String]] {
        var byHash: [String: [String]] = [:]
        for (id, hash) in hashMap { byHash[hash, default: []].append(id) }
        return byHash.values.filter { $0.count >= 2 }.map { $0 }
    }

    /// Returns identifiers whose file size appears more than once (cheap pre-filter before hashing).
    static func sizePrefilterIdentifiers(_ sizeMap: [String: Int64]) -> [String] {
        var bySize: [Int64: [String]] = [:]
        for (id, size) in sizeMap { bySize[size, default: []].append(id) }
        return bySize.values.filter { $0.count >= 2 }.flatMap { $0 }
    }

    // MARK: - Private helpers

    private func fileSize(for asset: PHAsset) -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let r = resources.first(where: { acceptable.contains($0.type) }) else { return nil }
        return r.value(forKey: "fileSize") as? Int64
    }

    /// Streams raw file bytes through an incremental SHA-256 hasher.
    /// Never holds the full image in memory — only the hasher state.
    /// Returns nil if the asset is iCloud-only or hashing fails.
    private func sha256(for asset: PHAsset) async -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { acceptable.contains($0.type) }) else { return nil }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false   // skip iCloud-only assets

        var hasher = SHA256()
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in hasher.update(data: chunk) },
                completionHandler: { error in
                    guard error == nil else { continuation.resume(returning: nil); return }
                    continuation.resume(returning: hasher.finalize().compactMap { String(format: "%02x", $0) }.joined())
                }
            )
        }
    }
}
