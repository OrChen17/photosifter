import Photos

enum Decision {
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

    var captureDate: Date? {
        assets.first?.creationDate
    }
}
