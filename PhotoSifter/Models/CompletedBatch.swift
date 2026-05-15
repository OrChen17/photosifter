import Foundation

struct CompletedBatch: Codable, Identifiable, Sendable {
    let id: UUID
    let photoCount: Int
    let deletedCount: Int
    let savedBytes: Int64
    let completedAt: Date
    let captureDate: Date?
    /// First 4 localIdentifiers stored for thumbnail attempts; assets may be deleted.
    let previewAssetIdentifiers: [String]
}
