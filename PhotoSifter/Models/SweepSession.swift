import Foundation

/// Wraps a snapshot of memories for a single cross-memory Sweep session.
/// Stable identity so SwiftUI's `navigationDestination(item:)` can drive
/// navigation; new sessions allocate a fresh `id` so re-entry starts clean.
struct SweepSession: Identifiable, Hashable, Sendable {
    let id: UUID
    let groups: [PhotoGroup]

    init(groups: [PhotoGroup]) {
        self.id = UUID()
        self.groups = groups
    }
}
