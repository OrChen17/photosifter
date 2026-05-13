import XCTest
import Photos
@testable import PhotoSifter

final class PhotoGroupTests: XCTestCase {

    // MARK: - Empty group

    func testEmptyGroup_isComplete() {
        let group = PhotoGroup(id: UUID(), assets: [])
        XCTAssertTrue(group.isComplete, "A group with no assets and no decisions is vacuously complete")
    }

    func testEmptyGroup_countsAreZero() {
        let group = PhotoGroup(id: UUID(), assets: [])
        XCTAssertEqual(group.deleteCount, 0)
        XCTAssertEqual(group.undecidedAssets.count, 0)
        XCTAssertEqual(group.keptAssets.count, 0)
        XCTAssertEqual(group.deletedAssets.count, 0)
    }

    func testEmptyGroup_captureDateIsNil() {
        let group = PhotoGroup(id: UUID(), assets: [])
        XCTAssertNil(group.captureDate)
    }

    // MARK: - Decision recording (requires library assets)

    func testUndecidedAssets_returnsAllBeforeAnyDecision() throws {
        var group = try requirePhotoGroup(assetCount: 3)
        XCTAssertEqual(group.undecidedAssets.count, 3)
        XCTAssertFalse(group.isComplete)
    }

    func testKeepDecision_movesAssetToKept() throws {
        var group = try requirePhotoGroup(assetCount: 3)
        let target = group.assets[0]

        group.decisions[target.localIdentifier] = .keep

        XCTAssertEqual(group.keptAssets.count, 1)
        XCTAssertEqual(group.keptAssets[0].localIdentifier, target.localIdentifier)
        XCTAssertEqual(group.undecidedAssets.count, 2)
        XCTAssertFalse(group.isComplete)
    }

    func testDeleteDecision_movesAssetToDeleted() throws {
        var group = try requirePhotoGroup(assetCount: 3)
        let target = group.assets[1]

        group.decisions[target.localIdentifier] = .delete

        XCTAssertEqual(group.deletedAssets.count, 1)
        XCTAssertEqual(group.deleteCount, 1)
        XCTAssertEqual(group.undecidedAssets.count, 2)
    }

    func testMixedDecisions_computedPropertiesAreConsistent() throws {
        var group = try requirePhotoGroup(assetCount: 4)

        group.decisions[group.assets[0].localIdentifier] = .keep
        group.decisions[group.assets[1].localIdentifier] = .delete
        group.decisions[group.assets[2].localIdentifier] = .keep
        group.decisions[group.assets[3].localIdentifier] = .delete

        XCTAssertEqual(group.keptAssets.count, 2)
        XCTAssertEqual(group.deletedAssets.count, 2)
        XCTAssertEqual(group.deleteCount, 2)
        XCTAssertEqual(group.undecidedAssets.count, 0)
        XCTAssertTrue(group.isComplete)
    }

    func testIsComplete_falseWhenOneUndecided() throws {
        var group = try requirePhotoGroup(assetCount: 3)

        group.decisions[group.assets[0].localIdentifier] = .keep
        group.decisions[group.assets[1].localIdentifier] = .delete
        // assets[2] is undecided

        XCTAssertFalse(group.isComplete)
    }

    func testIsComplete_trueWhenAllDecided() throws {
        var group = try requirePhotoGroup(assetCount: 2)

        group.decisions[group.assets[0].localIdentifier] = .keep
        group.decisions[group.assets[1].localIdentifier] = .delete

        XCTAssertTrue(group.isComplete)
    }

    func testOverwritingDecision_updatesCount() throws {
        var group = try requirePhotoGroup(assetCount: 2)
        let id = group.assets[0].localIdentifier

        group.decisions[id] = .delete
        XCTAssertEqual(group.deleteCount, 1)

        group.decisions[id] = .keep
        XCTAssertEqual(group.deleteCount, 0)
        XCTAssertEqual(group.keptAssets.count, 1)
    }

    func testCaptureDate_returnsFirstAssetDate() throws {
        let group = try requirePhotoGroup(assetCount: 2)
        XCTAssertEqual(group.captureDate, group.assets.first?.creationDate)
    }
}
