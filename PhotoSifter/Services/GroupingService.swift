import Photos
import Foundation
import Vision

actor GroupingService {
    static let shared = GroupingService()

    private let similarityService = SimilarityService.shared
    private let cacheURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("grouped_identifiers.json")
    }()

    private static let similarityThreshold: Float = 0.65
    private static let timeBucketGap: TimeInterval = 5 * 60   // 5 minutes

    // MARK: - Public API

    /// Streams PhotoGroups as they are found.
    /// Burst groups are emitted first (instant, no Vision needed), then
    /// Vision-based groups from non-burst photos stream in afterwards.
    /// All background tasks run at .background QoS (#17).
    func streamGroups(from assets: [PHAsset]) -> AsyncStream<PhotoGroup> {
        AsyncStream { continuation in
            Task(priority: .background) {
                // Phase 1: Burst groups (fast, no ML)
                let burstGroups = Self.fetchBurstGroups()
                let burstIDs = Set(burstGroups.flatMap { $0.assets.map { $0.localIdentifier } })
                for g in burstGroups { continuation.yield(g) }

                // Phase 2: Vision clustering on non-burst photos
                let nonBurst = assets.filter { !burstIDs.contains($0.localIdentifier) }
                let buckets = Self.splitIntoBuckets(nonBurst)

                await withTaskGroup(of: [PhotoGroup].self) { group in
                    for bucket in buckets {
                        group.addTask(priority: .background) {
                            (try? await self.clusterBucket(bucket)) ?? []
                        }
                    }
                    for await groups in group {
                        for g in groups { continuation.yield(g) }
                    }
                }
                continuation.finish()
            }
        }
    }

    func loadCachedGroups() async -> [PhotoGroup]? {
        guard let data = try? Data(contentsOf: cacheURL),
              let identifierGroups = try? JSONDecoder().decode([[String]].self, from: data)
        else { return nil }

        return identifierGroups.compactMap { ids -> PhotoGroup? in
            let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var assets: [PHAsset] = []
            result.enumerateObjects { a, _, _ in assets.append(a) }
            guard assets.count >= 2 else { return nil }
            return PhotoGroup(id: UUID(), assets: assets)
        }
    }

    func persistGroups(_ groups: [PhotoGroup]) async {
        let identifierGroups = groups.map { $0.assets.map { $0.localIdentifier } }
        guard let data = try? JSONEncoder().encode(identifierGroups) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    func invalidateCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Burst groups (#16)

    /// Returns photo groups formed from iOS burst captures — no Vision needed.
    private static func fetchBurstGroups() -> [PhotoGroup] {
        let options = PHFetchOptions()
        // Fetch only burst representative photos (one per burst series)
        options.predicate = NSPredicate(
            format: "mediaType == %d AND representsBurst == YES",
            PHAssetMediaType.image.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let representatives = PHAsset.fetchAssets(with: options)
        guard representatives.count > 0 else { return [] }

        var groups: [PhotoGroup] = []
        representatives.enumerateObjects { representative, _, _ in
            guard let burstID = representative.burstIdentifier else { return }

            let burstOptions = PHFetchOptions()
            burstOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            // Fetch all photos in this burst (including non-representative ones)
            burstOptions.includeAllBurstAssets = true

            let burstResult = PHAsset.fetchAssets(withBurstIdentifier: burstID, options: burstOptions)
            guard burstResult.count >= 2 else { return }

            var burstAssets: [PHAsset] = []
            burstResult.enumerateObjects { asset, _, _ in burstAssets.append(asset) }
            groups.append(PhotoGroup(id: UUID(), assets: burstAssets))
        }
        return groups
    }

    // MARK: - Time bucket splitting

    static func splitIntoBuckets(_ assets: [PHAsset]) -> [[PHAsset]] {
        guard !assets.isEmpty else { return [] }
        var buckets: [[PHAsset]] = []
        var current: [PHAsset] = [assets[0]]

        for i in 1..<assets.count {
            let prev = assets[i - 1].creationDate ?? .distantPast
            let curr = assets[i].creationDate ?? .distantPast
            if curr.timeIntervalSince(prev) > timeBucketGap {
                if current.count >= 2 { buckets.append(current) }
                current = [assets[i]]
            } else {
                current.append(assets[i])
            }
        }
        if current.count >= 2 { buckets.append(current) }
        return buckets
    }

    // MARK: - Vision clustering

    private func clusterBucket(_ bucket: [PHAsset]) async throws -> [PhotoGroup] {
        var prints: [String: VNFeaturePrintObservation] = [:]
        for asset in bucket {
            prints[asset.localIdentifier] = try? await similarityService.featurePrint(for: asset)
        }

        var parent: [String: String] = Dictionary(uniqueKeysWithValues: bucket.map { ($0.localIdentifier, $0.localIdentifier) })

        func find(_ x: String) -> String {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]!]!; x = parent[x]! }
            return x
        }

        for i in 0..<bucket.count {
            for j in (i + 1)..<bucket.count {
                let a = bucket[i], b = bucket[j]
                guard let pa = prints[a.localIdentifier],
                      let pb = prints[b.localIdentifier],
                      let dist = try? await similarityService.distance(from: pa, to: pb),
                      dist < Self.similarityThreshold
                else { continue }
                let ra = find(a.localIdentifier), rb = find(b.localIdentifier)
                if ra != rb { parent[ra] = rb }
            }
        }

        var clusters: [String: [PHAsset]] = [:]
        for asset in bucket {
            let root = find(asset.localIdentifier)
            clusters[root, default: []].append(asset)
        }

        return clusters.values
            .filter { $0.count >= 2 }
            .map { assets in
                // Sort chronologically so the strip shows photos in time order
                let sorted = assets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                return PhotoGroup(id: UUID(), assets: sorted)
            }
    }
}
