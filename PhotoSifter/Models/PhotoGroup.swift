import Photos

enum Decision: String, Codable {
    case keep
    case delete
}

struct PhotoGroup: Identifiable, Sendable {
    let id: UUID
    let assets: [PHAsset]
    var decisions: [String: Decision] = [:]  // keyed by localIdentifier

    var undecidedAssets: [PHAsset] {
        assets.filter { decisions[$0.localIdentifier] == nil }
    }

    var keptAssets: [PHAsset] {
        assets.filter { decisions[$0.localIdentifier] == .keep }
    }

    var deletedAssets: [PHAsset] {
        assets.filter { decisions[$0.localIdentifier] == .delete }
    }

    var isComplete: Bool {
        decisions.count == assets.count
    }

    var deleteCount: Int {
        decisions.values.filter { $0 == .delete }.count
    }

    /// Populated once when a group enters the library list. Zero means not yet computed.
    var totalFileBytes: Int64 = 0

    var captureDate: Date? {
        assets.first?.creationDate
    }
}

extension PhotoGroup: Hashable {
    static func == (lhs: PhotoGroup, rhs: PhotoGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
