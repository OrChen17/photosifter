import Foundation

struct CompletedBatch: Codable, Identifiable, Sendable {
    let id: UUID
    var photoCount: Int
    let deletedCount: Int
    let savedBytes: Int64
    let completedAt: Date
    let captureDate: Date?
    /// First 4 localIdentifiers stored for thumbnail attempts; assets may be deleted.
    /// Retained for backwards compat — superseded by `keptAssetIdentifiers` for new batches.
    let previewAssetIdentifiers: [String]
    /// LocalIdentifiers of photos that were KEPT (not deleted) in this batch. Drives
    /// non-black thumbnails and the Revisit/restore flow. `nil` for batches recorded
    /// before this field existed.
    var keptAssetIdentifiers: [String]?
    /// Total bytes of kept photos. `nil` for legacy batches; new batches always set this.
    var keptBytes: Int64?
    /// Links this batch to a `PhotoGroup.id`. Set by Sweep and Sifter so a
    /// memory touched across multiple sessions merges into a single History
    /// row instead of producing duplicates. `nil` for legacy batches and
    /// non-group flows (e.g. QuickWins).
    ///
    /// Stability: only stable *within a single app run* — `PhotoGroup.id` is
    /// regenerated each scan. Cross-launch merging is out of scope here.
    var sourceGroupID: UUID? = nil

    /// A batch is "revisitable" if it still has kept photos we can re-flick.
    /// Old batches (no `keptAssetIdentifiers`) fall through to the History list.
    var isRevisitable: Bool {
        (keptAssetIdentifiers?.isEmpty == false)
    }
}
