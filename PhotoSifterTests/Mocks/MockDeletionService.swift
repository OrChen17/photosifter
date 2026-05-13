import Photos
@testable import PhotoSifter

/// In-memory deletion service — records which assets were deleted without touching the photo library.
final class MockDeletionService: DeletionService, @unchecked Sendable {
    private(set) var deletedAssets: [PHAsset] = []
    var shouldThrow: Bool = false

    func deleteAssets(_ assets: [PHAsset]) async throws {
        if shouldThrow { throw MockError.simulatedFailure }
        deletedAssets.append(contentsOf: assets)
    }

    var deleteCallCount: Int { deletedAssets.count }
}

enum MockError: Error {
    case simulatedFailure
}
