import XCTest
@testable import PhotoSifter

final class QuickWinsServiceTests: XCTestCase {

    // MARK: - Screenshot batching (pure logic)

    func testScreenshotBatching_chunksCorrectly() {
        let identifiers = (0..<45).map { "asset-\($0)" }
        let chunks = stride(from: 0, to: identifiers.count, by: 20).map {
            Array(identifiers[$0..<min($0 + 20, identifiers.count)])
        }
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].count, 20)
        XCTAssertEqual(chunks[1].count, 20)
        XCTAssertEqual(chunks[2].count, 5)
    }

    func testScreenshotBatching_exactMultiple() {
        let identifiers = (0..<40).map { "asset-\($0)" }
        let chunks = stride(from: 0, to: identifiers.count, by: 20).map {
            Array(identifiers[$0..<min($0 + 20, identifiers.count)])
        }
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 20)
        XCTAssertEqual(chunks[1].count, 20)
    }

    // MARK: - groupIdentifiersByHash

    func testGroupIdentifiersByHash_groupsDuplicates() {
        let hashMap = ["a1": "abc", "a2": "abc", "a3": "xyz"]
        let groups = QuickWinsService.groupIdentifiersByHash(hashMap)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0]), Set(["a1", "a2"]))
    }

    func testGroupIdentifiersByHash_excludesSingles() {
        let hashMap = ["a1": "abc", "a2": "def", "a3": "ghi"]
        let groups = QuickWinsService.groupIdentifiersByHash(hashMap)
        XCTAssertTrue(groups.isEmpty)
    }

    func testGroupIdentifiersByHash_multipleGroups() {
        let hashMap: [String: String] = [
            "a1": "aaa", "a2": "aaa",
            "b1": "bbb", "b2": "bbb",
            "c1": "ccc"
        ]
        let groups = QuickWinsService.groupIdentifiersByHash(hashMap)
        XCTAssertEqual(groups.count, 2)
        let allIDs = Set(groups.flatMap { $0 })
        XCTAssertEqual(allIDs, Set(["a1", "a2", "b1", "b2"]))
    }

    func testGroupIdentifiersByHash_emptyInputReturnsEmpty() {
        let groups = QuickWinsService.groupIdentifiersByHash([:])
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - sizePrefilterIdentifiers

    func testSizePrefilterIdentifiers_removesUniqueSizes() {
        let sizeMap: [String: Int64] = ["a1": 1000, "a2": 1000, "b1": 2000]
        let result = Set(QuickWinsService.sizePrefilterIdentifiers(sizeMap))
        XCTAssertEqual(result, Set(["a1", "a2"]))
    }

    func testSizePrefilterIdentifiers_emptyWhenAllUnique() {
        let sizeMap: [String: Int64] = ["a1": 1000, "a2": 2000, "a3": 3000]
        let result = QuickWinsService.sizePrefilterIdentifiers(sizeMap)
        XCTAssertTrue(result.isEmpty)
    }

    func testSizePrefilterIdentifiers_multipleSharedSizes() {
        let sizeMap: [String: Int64] = [
            "a1": 500, "a2": 500,
            "b1": 800, "b2": 800, "b3": 800,
            "c1": 999
        ]
        let result = Set(QuickWinsService.sizePrefilterIdentifiers(sizeMap))
        XCTAssertEqual(result, Set(["a1", "a2", "b1", "b2", "b3"]))
    }
}
