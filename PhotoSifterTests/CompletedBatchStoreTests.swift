import XCTest
@testable import PhotoSifter

final class CompletedBatchStoreTests: XCTestCase {
    private var tempURL: URL!
    private var store: CompletedBatchStore!

    override func setUp() async throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        store = CompletedBatchStore(fileURL: tempURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testLoadAll_emptyFileReturnsEmpty() async {
        let all = await store.loadAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testAppend_persistsAndLoadsBack() async {
        let batch = makeBatch(deleted: 3, bytes: 1024)
        await store.append(batch)

        let fresh = CompletedBatchStore(fileURL: tempURL)
        let loaded = await fresh.loadAll()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, batch.id)
        XCTAssertEqual(loaded[0].deletedCount, 3)
        XCTAssertEqual(loaded[0].savedBytes, 1024)
    }

    func testAppend_prependsNewestFirst() async {
        let first  = makeBatch(deleted: 1, bytes: 100)
        let second = makeBatch(deleted: 2, bytes: 200)
        await store.append(first)
        await store.append(second)

        let loaded = await store.loadAll()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, second.id, "Most recently appended should be at index 0")
        XCTAssertEqual(loaded[1].id, first.id)
    }

    // MARK: - Helpers

    private func makeBatch(deleted: Int, bytes: Int64) -> CompletedBatch {
        CompletedBatch(
            id: UUID(),
            photoCount: deleted + 2,
            deletedCount: deleted,
            savedBytes: bytes,
            completedAt: Date(),
            captureDate: nil,
            previewAssetIdentifiers: []
        )
    }
}
