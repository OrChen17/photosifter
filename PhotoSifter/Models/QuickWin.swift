import Foundation

enum QuickWinCategory: String, CaseIterable, Hashable {
    case screenshots
    case duplicates

    var label: String {
        switch self {
        case .screenshots: return "Screenshots"
        case .duplicates:  return "Exact Duplicates"
        }
    }

    var systemImage: String {
        switch self {
        case .screenshots: return "camera.viewfinder"
        case .duplicates:  return "doc.on.doc"
        }
    }
}

struct QuickWin: Identifiable, Hashable, Sendable {
    let id: UUID
    let category: QuickWinCategory
    let group: PhotoGroup
    /// Total assets remaining across all batches in this category (for pill count display).
    let totalCount: Int

    var photoCount: Int { group.assets.count }
}

enum QuickWinMode: Sendable {
    case screenshots
    case duplicates
    case none
}

/// Wraps all duplicate-cluster groups into a single navigation item.
struct DuplicateSession: Identifiable, Hashable, Sendable {
    let id: UUID
    let groups: [PhotoGroup]

    init(groups: [PhotoGroup]) {
        self.id = UUID()
        self.groups = groups
    }
}
