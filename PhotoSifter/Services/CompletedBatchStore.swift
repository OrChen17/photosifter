import Foundation

actor CompletedBatchStore {
    static let shared = CompletedBatchStore()

    private let url: URL
    private var cache: [CompletedBatch]?

    init(fileURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.url = fileURL ?? support.appendingPathComponent("completed_batches.json")
    }

    func append(_ batch: CompletedBatch) {
        var all = cache ?? load()
        all.insert(batch, at: 0)   // newest first
        cache = all
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
    }

    func loadAll() -> [CompletedBatch] {
        if let cache { return cache }
        let result = load()
        cache = result
        return result
    }

    /// Replaces the stored batch matching `batch.id`. Used by the Revisit flow to
    /// mutate a batch in place (zeroing kept-side fields) while preserving its
    /// `deletedCount`/`savedBytes` so totals stay stable.
    func replace(_ batch: CompletedBatch) {
        var all = cache ?? load()
        guard let idx = all.firstIndex(where: { $0.id == batch.id }) else { return }
        all[idx] = batch
        cache = all
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
    }

    /// Test hook — drops the in-memory cache so the next `loadAll()` re-reads disk.
    func invalidateCache() {
        cache = nil
    }

    private func load() -> [CompletedBatch] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CompletedBatch].self, from: data)) ?? []
    }
}
