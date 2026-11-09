import Photos
import Foundation

/// What the scan has done so far. Drives the progress UI.
struct ScanProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// Fetching the asset list from Photos. Total not known yet.
        case reading
        case comparing
        case finished
    }

    var phase: Phase = .idle
    /// Photos the scan has looked at, out of `total`.
    var checked: Int = 0
    var total: Int = 0
    /// Photos left out because they are only in iCloud and download is off.
    var cloudSkipped: Int = 0
    /// Oldest capture date reached so far. The scan walks newest to oldest.
    var reachedDate: Date?

    static let idle = ScanProgress()

    var fraction: Double {
        guard total > 0 else { return phase == .finished ? 1 : 0 }
        return min(1, Double(checked) / Double(total))
    }

    var isActive: Bool { phase == .reading || phase == .comparing }
}

enum ScanEvent: Sendable {
    case group(PhotoGroup)
    case progress(ScanProgress)
}

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
    private let fileSizesURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("file_sizes.json")
    }()

    private var fileSizeCache: [String: Int64]? = nil

    init(similarity: any SimilarityProviding = SimilarityService.shared) {
        self.similarity = similarity
        // iOS doesn't create Application Support automatically — without this,
        // every persistence write silently fails (try? swallows the error) and
        // mid-batch progress never survives. (#decisions-not-persisting)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    private static let similarityThreshold: Float = 0.5
    static let timeBucketGap: TimeInterval = 5 * 60   // 5 minutes

    /// Time buckets (and bursts) processed at the same time.
    static let maxConcurrentWorkItems = 4
    /// Vision feature prints in flight across all buckets. Loading the image
    /// from Photos is most of the cost, so a few in parallel hide that wait.
    static let maxConcurrentSignatures = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
    /// iCloud checks are cheap I/O probes, so they can run wider.
    static let maxConcurrentLocalChecks = 8
    /// Progress events are throttled so a large library doesn't flood the main actor.
    static let progressInterval: TimeInterval = 0.1

    // MARK: - Public API

    /// Scans `assets` for groups, newest photos first, and reports progress.
    ///
    /// - Assets in `knownIDs` (cached or already flicked) are skipped. The scan
    ///   cutoff is not applied here: singles from a previous scan must still be
    ///   re-checked because new photos could pair with them.
    /// - Bursts and time buckets form one work queue, ordered newest first, and
    ///   up to `maxConcurrentWorkItems` run at once. Groups are emitted as soon as
    ///   their bucket is done, so the first ones show up after a couple of
    ///   feature prints instead of after a pass over the whole library.
    /// - iCloud-only photos are filtered per bucket, only for photos that have a
    ///   neighbour within `timeBucketGap`. Singles are never probed.
    func scan(
        from assets: [PHAsset],
        excluding knownIDs: Set<String> = []
    ) -> AsyncStream<ScanEvent> {
        let similarity = self.similarity
        let cloudFilter = !AppSettings.cloudDownloadEnabled

        return AsyncStream { continuation in
            let task = Task(priority: .userInitiated) {
                #if DEBUG
                let t0 = Date()
                func log(_ msg: String) {
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    print("[GroupingService] \(ms)ms — \(msg)")
                }
                #else
                @inline(__always) func log(_ _: String) {}
                #endif

                let plan = Self.plan(assets.filter { !knownIDs.contains($0.localIdentifier) })
                var progress = ScanProgress(phase: .comparing, checked: 0, total: plan.total)
                continuation.yield(.progress(progress))
                log("plan: \(plan.total) photos, \(plan.items.count) work items, \(plan.leftover) old singles")

                let limiter = AsyncLimiter(limit: Self.maxConcurrentSignatures)
                var lastProgressAt = Date()
                var emitted = 0

                await withTaskGroup(of: WorkResult.self) { group in
                    var next = 0
                    func enqueue() {
                        let item = plan.items[next]
                        next += 1
                        group.addTask {
                            await Self.process(item, similarity: similarity, limiter: limiter, cloudFilter: cloudFilter)
                        }
                    }
                    while next < min(Self.maxConcurrentWorkItems, plan.items.count) { enqueue() }

                    for await result in group {
                        for g in result.groups {
                            continuation.yield(.group(self.byteFilled(g)))
                            emitted += 1
                            if emitted == 1 { log("first group") }
                        }
                        progress.checked += result.weight
                        progress.cloudSkipped += result.cloudSkipped
                        progress.reachedDate = [progress.reachedDate, result.oldestDate].compactMap { $0 }.min()
                        if Date().timeIntervalSince(lastProgressAt) >= Self.progressInterval {
                            lastProgressAt = Date()
                            continuation.yield(.progress(progress))
                        }
                        if !Task.isCancelled, next < plan.items.count { enqueue() }
                    }
                }

                if !Task.isCancelled {
                    progress.checked = progress.total
                    progress.reachedDate = plan.oldestDate ?? progress.reachedDate
                }
                progress.phase = .finished
                continuation.yield(.progress(progress))
                log("scan complete — \(emitted) groups, \(progress.cloudSkipped) iCloud-only skipped")
                self.saveFileSizeCache()
                continuation.finish()
            }
            // Cancel the scan when the consumer abandons the stream
            // (e.g. LibraryViewModel navigates away or starts a new load()).
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Groups only, without progress. Same scan as `scan(from:excluding:)`.
    func streamGroups(
        from assets: [PHAsset],
        excluding knownIDs: Set<String> = []
    ) -> AsyncStream<PhotoGroup> {
        let events = scan(from: assets, excluding: knownIDs)
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    if case .group(let group) = event { continuation.yield(group) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func loadCachedGroups() async -> [PhotoGroup]? {
        guard let data = try? Data(contentsOf: cacheURL),
              let identifierGroups = try? JSONDecoder().decode([[String]].self, from: data)
        else { return nil }

        // Single bulk fetch instead of one Photos DB call per cached group.
        // For libraries with hundreds of cached groups this collapses N XPC
        // round-trips into 1 — the dominant cost on warm-cache app launch.
        let allIDs = Array(Set(identifierGroups.flatMap { $0 }))
        let result = PHAsset.fetchAssets(withLocalIdentifiers: allIDs, options: nil)
        var byID: [String: PHAsset] = [:]
        byID.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }

        let groups = identifierGroups.compactMap { ids -> PhotoGroup? in
            let assets = ids.compactMap { byID[$0] }
            guard assets.count >= 2 else { return nil }
            // fetchAssets(withLocalIdentifiers:) returns assets in undefined order;
            // sort by creationDate to match freshly-scanned groups (burst + Vision).
            let sorted = assets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            return byteFilled(PhotoGroup(id: UUID(), assets: sorted))
        }
        saveFileSizeCache()
        return groups
    }

    private func ensureFileSizeCacheLoaded() {
        guard fileSizeCache == nil else { return }
        guard let data = try? Data(contentsOf: fileSizesURL),
              let dict = try? JSONDecoder().decode([String: Int64].self, from: data)
        else { fileSizeCache = [:]; return }
        fileSizeCache = dict
    }

    private func saveFileSizeCache() {
        guard let cache = fileSizeCache,
              let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileSizesURL, options: .atomic)
    }

    private func byteFilled(_ group: PhotoGroup) -> PhotoGroup {
        guard group.totalFileBytes == 0 else { return group }
        ensureFileSizeCacheLoaded()
        let acceptable: Set<PHAssetResourceType> = [.photo, .fullSizePhoto, .alternatePhoto, .adjustmentBasePhoto]
        var g = group
        g.totalFileBytes = g.assets.reduce(Int64(0)) { sum, asset in
            let id = asset.localIdentifier
            if let cached = fileSizeCache?[id] { return sum + cached }
            let resources = PHAssetResource.assetResources(for: asset)
            guard let r = resources.first(where: { acceptable.contains($0.type) }),
                  let bytes = r.value(forKey: "fileSize") as? Int64 else { return sum }
            fileSizeCache?[id] = bytes
            return sum + bytes
        }
        return g
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

    /// Loads the raw decisions dict once. Call this before a streaming loop and
    /// pass the result to `hydrateGroup(_:using:)` to avoid per-group file reads.
    func loadRawDecisions() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: decisionsURL),
              let dict = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return dict
    }

    private func loadAllDecisionsRaw() -> [String: [String: String]] { loadRawDecisions() }

    /// Hydrates a single group from a pre-loaded decisions dict — no actor crossing needed.
    static func hydrateGroup(_ group: PhotoGroup, using raw: [String: [String: String]]) -> PhotoGroup {
        guard let rawDecisions = raw[persistenceKey(for: group)] else { return group }
        var copy = group
        copy.decisions = rawDecisions.compactMapValues { Decision(rawValue: $0) }
        return copy
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

    /// Removes the given IDs from the flicked set so a future scan can re-evaluate
    /// them. Used by the Revisit flow: restored photos must be eligible for
    /// grouping again.
    func removeFlickedIdentifiers(_ ids: [String]) {
        var current = loadFlickedIdentifiers()
        current.subtract(ids)
        guard let data = try? JSONEncoder().encode(Array(current)) else { return }
        try? data.write(to: flickedURL, options: .atomic)
    }

    func invalidateCache() {
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: decisionsURL)
        try? FileManager.default.removeItem(at: scanCutoffURL)
    }

    // MARK: - Scan plan

    /// One unit of scan work. `weight` is how many scanned photos it accounts
    /// for in progress, including the singles between it and the next newer item.
    enum WorkItem {
        case burst(representative: PHAsset, date: Date)
        case bucket(assets: [PHAsset], weight: Int, newest: Date, oldest: Date)

        var newestDate: Date {
            switch self {
            case .burst(_, let date): return date
            case .bucket(_, _, let newest, _): return newest
            }
        }
    }

    struct ScanPlan {
        /// Newest first.
        let items: [WorkItem]
        let total: Int
        /// Singles older than the oldest bucket. Counted when the scan ends.
        let leftover: Int
        let oldestDate: Date?
    }

    /// Splits the photos to scan into burst items and time-bucket items, newest
    /// first. Burst representatives (the only burst member a default fetch
    /// returns) go to the burst path and are kept out of Vision buckets.
    static func plan(_ assets: [PHAsset]) -> ScanPlan {
        // Read creationDate once per asset; each read is an Objective-C call.
        let dated = assets
            .map { (asset: $0, date: $0.creationDate ?? .distantPast) }
            .sorted { $0.date < $1.date }

        var bursts: [WorkItem] = []
        var regular: [(asset: PHAsset, date: Date)] = []
        regular.reserveCapacity(dated.count)
        for entry in dated {
            if entry.asset.representsBurst, entry.asset.burstIdentifier != nil {
                bursts.append(.burst(representative: entry.asset, date: entry.date))
            } else {
                regular.append(entry)
            }
        }

        let weighted = weightedBuckets(byDates: regular.map(\.date))
        let buckets: [WorkItem] = weighted.buckets.map { bucket in
            .bucket(
                assets: bucket.indices.map { regular[$0].asset },
                weight: bucket.weight,
                newest: regular[bucket.indices.last!].date,
                oldest: regular[bucket.indices.first!].date
            )
        }

        let items = (bursts + buckets).sorted { $0.newestDate > $1.newestDate }
        return ScanPlan(items: items, total: dated.count, leftover: weighted.leftover, oldestDate: dated.first?.date)
    }

    /// Buckets from `splitIntoBuckets(byDates:)`, each with a progress weight:
    /// its own photos plus the singles after it, up to the next bucket. The
    /// singles before the first bucket are returned as `leftover`. Weights plus
    /// leftover always equal `dates.count`. `dates` must be ascending.
    static func weightedBuckets(byDates dates: [Date]) -> (buckets: [(indices: [Int], weight: Int)], leftover: Int) {
        let buckets = splitIntoBuckets(byDates: dates)
        guard let first = buckets.first?.first else { return ([], dates.count) }
        let weighted = buckets.enumerated().map { k, indices -> (indices: [Int], weight: Int) in
            let end = k + 1 < buckets.count ? buckets[k + 1][0] : dates.count
            return (indices, end - indices[0])
        }
        return (weighted, first)
    }

    // MARK: - Work item processing (runs off the actor)

    struct WorkResult {
        let groups: [PhotoGroup]
        let weight: Int
        let cloudSkipped: Int
        let oldestDate: Date?
    }

    private static func process(
        _ item: WorkItem,
        similarity: any SimilarityProviding,
        limiter: AsyncLimiter,
        cloudFilter: Bool
    ) async -> WorkResult {
        switch item {
        case .burst(let representative, let date):
            return await processBurst(representative, date: date, cloudFilter: cloudFilter)
        case .bucket(let assets, let weight, _, let oldest):
            return await processBucket(
                assets, weight: weight, oldest: oldest,
                similarity: similarity, limiter: limiter, cloudFilter: cloudFilter
            )
        }
    }

    /// Burst groups come straight from iOS burst captures, no Vision needed.
    private static func processBurst(_ representative: PHAsset, date: Date, cloudFilter: Bool) async -> WorkResult {
        func result(_ groups: [PhotoGroup], skipped: Int = 0) -> WorkResult {
            WorkResult(groups: groups, weight: 1, cloudSkipped: skipped, oldestDate: date)
        }
        guard let burstID = representative.burstIdentifier, !Task.isCancelled else { return result([]) }

        // Burst shots are milliseconds apart — if the representative isn't on device,
        // the rest almost certainly aren't either. Skip the whole burst early.
        if cloudFilter, await !PhotoLibraryService.shared.isLocallyAvailable(representative) {
            return result([], skipped: 1)
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAllBurstAssets = true
        let fetched = PHAsset.fetchAssets(withBurstIdentifier: burstID, options: options)
        var members: [PHAsset] = []
        members.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in members.append(asset) }

        if cloudFilter {
            // Some burst members may be in cloud even when the representative is local
            // (e.g. only the starred photo was kept on device). Check each member.
            members = await localOnly(members)
        }
        guard members.count >= 2 else { return result([]) }
        return result([PhotoGroup(id: UUID(), assets: members)])
    }

    /// Vision clustering for one time bucket: filter iCloud-only photos, compute
    /// one signature per photo (through the shared limiter), then union-find on
    /// pairwise distances. Signatures are dropped when the bucket is done.
    private static func processBucket(
        _ assets: [PHAsset],
        weight: Int,
        oldest: Date,
        similarity: any SimilarityProviding,
        limiter: AsyncLimiter,
        cloudFilter: Bool
    ) async -> WorkResult {
        var candidates = assets
        var skipped = 0
        if cloudFilter {
            candidates = await localOnly(assets)
            skipped = assets.count - candidates.count
        }
        guard candidates.count >= 2, !Task.isCancelled else {
            return WorkResult(groups: [], weight: weight, cloudSkipped: skipped, oldestDate: oldest)
        }

        let signatures = await candidates.concurrentMap(limit: maxConcurrentSignatures) { asset in
            await limiter.run { () async -> (any SimilaritySignature)? in
                guard !Task.isCancelled else { return nil }
                return try? await similarity.signature(for: asset)
            }
        }
        let groups = cluster(candidates, signatures: signatures)
        return WorkResult(groups: groups, weight: weight, cloudSkipped: skipped, oldestDate: oldest)
    }

    /// Union-find over pairwise distances. `assets` must be in time order; the
    /// returned groups keep that order. Assets without a signature are left out.
    static func cluster(_ assets: [PHAsset], signatures: [(any SimilaritySignature)?]) -> [PhotoGroup] {
        let valid = zip(assets, signatures).compactMap { asset, sig in sig.map { (asset, $0) } }
        let n = valid.count
        guard n >= 2 else { return [] }

        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }

        for i in 0..<n {
            if i % 32 == 0, Task.isCancelled { return [] }
            for j in (i + 1)..<n {
                guard let dist = try? valid[i].1.distance(to: valid[j].1),
                      dist < similarityThreshold else { continue }
                let ri = find(i), rj = find(j)
                if ri != rj { parent[ri] = rj }
            }
        }

        var members: [Int: [PHAsset]] = [:]
        var roots: [Int] = []
        for i in 0..<n {
            let root = find(i)
            if members[root] == nil { roots.append(root) }
            members[root, default: []].append(valid[i].0)
        }
        return roots
            .compactMap { members[$0] }
            .filter { $0.count >= 2 }
            .map { PhotoGroup(id: UUID(), assets: $0) }
    }

    private static func localOnly(_ assets: [PHAsset]) async -> [PHAsset] {
        let flags = await assets.concurrentMap(limit: maxConcurrentLocalChecks) {
            await PhotoLibraryService.shared.isLocallyAvailable($0)
        }
        return zip(assets, flags).filter(\.1).map(\.0)
    }

    // MARK: - Time bucket splitting

    static func splitIntoBuckets(_ assets: [PHAsset]) -> [[PHAsset]] {
        let dates = assets.map { $0.creationDate ?? .distantPast }
        return splitIntoBuckets(byDates: dates).map { indices in indices.map { assets[$0] } }
    }

    /// Pure, library-independent partition used by `splitIntoBuckets(_:[PHAsset])`.
    /// Returns index buckets so callers can map back to whichever asset type they hold.
    static func splitIntoBuckets(byDates dates: [Date]) -> [[Int]] {
        guard !dates.isEmpty else { return [] }
        var buckets: [[Int]] = []
        var current: [Int] = [0]

        for i in 1..<dates.count {
            if dates[i].timeIntervalSince(dates[i - 1]) > timeBucketGap {
                if current.count >= 2 { buckets.append(current) }
                current = [i]
            } else {
                current.append(i)
            }
        }
        if current.count >= 2 { buckets.append(current) }
        return buckets
    }
}
