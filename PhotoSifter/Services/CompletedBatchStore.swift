import Foundation

actor CompletedBatchStore {
    static let shared = CompletedBatchStore()

    private let url: URL

    init(fileURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.url = fileURL ?? support.appendingPathComponent("completed_batches.json")
    }

    func append(_ batch: CompletedBatch) {
        var all = loadAll()
        all.insert(batch, at: 0)   // newest first
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
    }

    func loadAll() -> [CompletedBatch] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CompletedBatch].self, from: data)) ?? []
    }
}
