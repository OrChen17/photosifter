import Photos
import Foundation

actor GroupingService {
    #if DEBUG && targetEnvironment(simulator)
    // Simulator's Vision/CoreML can't load the feature-print model, so use a
    // time-proximity stub to populate the UI with real groups. Never ships.
    static let shared = GroupingService(similarity: DebugTimeProximitySimilarity())
    #else
    static let shared = GroupingService()
    #endif

    private let similarity: any SimilarityProviding
    private let cacheURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("grouped_identifiers.json")
    }()
    private let decisionsURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("group_decisions.json")
    }()
    private let scanCutoffURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("scan_cutoff.json")
    }()
    private let flickedURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("flicked_identifiers.json")
    }()

    init(similarity: any SimilarityProviding = SimilarityService.shared) {
        self.similarity = similarity
        // iOS doesn't create Application Support automatically — without this,
        // every persistence write silently fails (try? swallows the error) and
        // mid-batch progress never survives. (#decisions-not-persisting)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    private static let similarityThreshold: Float = 0.55
    private static let timeBucketGap: TimeInterval = 5 * 60   // 5 minutes

    // MARK: - Public API

    /// Streams PhotoGroups as they are found, skipping assets already in a cached
    /// group (`knownIDs`). Burst groups are emitted first (instant, no Vision
    /// needed), then Vision-based groups stream in afterwards.
    func streamGroups(
        from assets: [PHAsset],
        excluding knownIDs: Set<String> = []
    ) -> AsyncStream<PhotoGroup> {
        // Pre-filter before any ML work: skip only assets already in a cached group.
        // The cutoff is intentionally NOT applied here — photos that weren't grouped
        // on a previous scan (singletons) must still be re-evaluated since they could
        // form a group with newly imported photos or with each other in a future run.
        let toScan = assets.filter { !knownIDs.contains($0.localIdentifier) }

        return AsyncStream { continuation in
            let task = Task(priority: .background) {
                // Phase 1: Burst groups — skip representatives already grouped
                let burstGroups = await Self.fetchBurstGroups(excluding: knownIDs)
                let burstIDs = Set(burstGroups.flatMap { $0.assets.map { $0.localIdentifier } })
                for g in burstGroups { continuation.yield(g) }

                // Phase 2: Vision clustering on new non-burst assets only
                let nonBurst = toScan.filter { !burstIDs.contains($0.localIdentifier) }
                let buckets = Self.splitIntoBuckets(nonBurst)

                for bucket in buckets {
                    guard !Task.isCancelled else { break }
                    let groups = (try? await self.clusterBucket(bucket)) ?? []
                    for g in groups { continuation.yield(g) }
                }
                continuation.finish()
            }
            // Cancel the background task when the consumer abandons the stream
            // (e.g. LibraryViewModel navigates away or starts a new load()).
            continuation.onTermination = { _ in task.cancel() }
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

    // MARK: - Per-group decision persistence (partial-save on mid-batch exit)

    /// Saves the in-progress decisions for one group, keyed by the stable
    /// identifier set so the mapping survives across launches even though
    /// `PhotoGroup.id` (UUID) is regenerated each scan.
    func saveDecisions(for group: PhotoGroup) {
        var all = loadAllDecisionsRaw()
        let key = Self.persistenceKey(for: group)
        if group.decisions.isEmpty {
            all.removeValue(forKey: key)
        } else {
            all[key] = group.decisions.mapValues { $0.rawValue }
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: decisionsURL, options: .atomic)
    }

    /// Hydrates each input group's `.decisions` from the persisted store.
    func hydrateDecisions(into groups: [PhotoGroup]) -> [PhotoGroup] {
        let all = loadAllDecisionsRaw()
        return groups.map { group in
            var copy = group
            if let raw = all[Self.persistenceKey(for: group)] {
                copy.decisions = raw.compactMapValues { Decision(rawValue: $0) }
            }
            return copy
        }
    }

    private func loadAllDecisionsRaw() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: decisionsURL),
              let dict = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return dict
    }

    static func persistenceKey(for group: PhotoGroup) -> String {
        group.assets.map(\.localIdentifier).sorted().joined(separator: "|")
    }

    func loadScanCutoff() -> Date? {
        guard let data = try? Data(contentsOf: scanCutoffURL),
              let date = try? JSONDecoder().decode(Date.self, from: data)
        else { return nil }
        return date
    }

    func saveScanCutoff(_ date: Date) {
        guard let data = try? JSONEncoder().encode(date) else { return }
        try? data.write(to: scanCutoffURL, options: .atomic)
    }

    func loadFlickedIdentifiers() -> Set<String> {
        guard let data = try? Data(contentsOf: flickedURL),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    func addFlickedIdentifiers(_ ids: [String]) {
        var current = loadFlickedIdentifiers()
        current.formUnion(ids)
        guard let data = try? JSONEncoder().encode(Array(current)) else { return }
        try? data.write(to: flickedURL, options: .atomic)
    }

    func invalidateCache() {
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: decisionsURL)
        try? FileManager.default.removeItem(at: scanCutoffURL)
    }

    // MARK: - Burst groups (#16)

    /// Returns photo groups formed from iOS burst captures — no Vision needed.
    /// When cloud download is disabled, filters out any burst assets not stored on device.
    private static func fetchBurstGroups(excluding knownIDs: Set<String> = []) async -> [PhotoGroup] {
        let options = PHFetchOptions()
        // `representsBurst` isn't accepted by PHQuery's predicate parser, so
        // filter by mediaType at the DB level and check representsBurst in code.
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let allImages = PHAsset.fetchAssets(with: options)
        guard allImages.count > 0 else { return [] }

        let filterForLocal = !AppSettings.cloudDownloadEnabled
        var representatives: [(PHAsset, String)] = []
        allImages.enumerateObjects { representative, _, _ in
            guard representative.representsBurst,
                  let burstID = representative.burstIdentifier,
                  !knownIDs.contains(representative.localIdentifier) else { return }
            representatives.append((representative, burstID))
        }

        var groups: [PhotoGroup] = []
        for (representative, burstID) in representatives {
            // Burst shots are milliseconds apart — if the representative isn't on device,
            // the rest almost certainly aren't either. Skip the whole burst early.
            if filterForLocal, await !PhotoLibraryService.shared.isLocallyAvailable(representative) {
                continue
            }

            let burstOptions = PHFetchOptions()
            burstOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            burstOptions.includeAllBurstAssets = true

            let burstResult = PHAsset.fetchAssets(withBurstIdentifier: burstID, options: burstOptions)
            var burstAssets: [PHAsset] = []
            burstResult.enumerateObjects { asset, _, _ in burstAssets.append(asset) }

            if filterForLocal {
                // Some burst members may be in cloud even when the representative is local
                // (e.g. only the starred photo was kept on device). Check each member.
                burstAssets = await withTaskGroup(of: (PHAsset, Bool).self) { group in
                    for asset in burstAssets {
                        group.addTask { (asset, await PhotoLibraryService.shared.isLocallyAvailable(asset)) }
                    }
                    var local: [PHAsset] = []
                    for await (asset, available) in group where available { local.append(asset) }
                    return local.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                }
            }

            guard burstAssets.count >= 2 else { continue }
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
        var parent: [String: String] = Dictionary(uniqueKeysWithValues: bucket.map { ($0.localIdentifier, $0.localIdentifier) })

        func find(_ x: String) -> String {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]!]!; x = parent[x]! }
            return x
        }

        for i in 0..<bucket.count {
            for j in (i + 1)..<bucket.count {
                let a = bucket[i], b = bucket[j]
                guard let dist = try? await similarity.distance(between: a, and: b),
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
