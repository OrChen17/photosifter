import Photos
import SwiftUI

protocol DeletionService: Sendable {
    func deleteAssets(_ assets: [PHAsset]) async throws
}
extension PhotoLibraryService: DeletionService {}

@Observable
@MainActor
final class SifterViewModel {
    var group: PhotoGroup
    var currentIndex: Int = 0
    var isComplete: Bool = false
    var deletedCount: Int = 0
    var isDeleting: Bool = false

    private let deletionService: any DeletionService
    private let haptics = HapticManager.shared
    private let sounds = SoundManager.shared

    private var decisionHistory: [(index: Int, decision: Decision, asset: PHAsset)] = []

    init(group: PhotoGroup, deletionService: (any DeletionService)? = nil) {
        self.group = group
        self.deletionService = deletionService ?? PhotoLibraryService.shared
    }

    var currentAsset: PHAsset? {
        guard currentIndex < group.assets.count else { return nil }
        return group.assets[currentIndex]
    }

    var progress: Double {
        guard !group.assets.isEmpty else { return 1 }
        return Double(currentIndex) / Double(group.assets.count)
    }

    func swipeRight() {
        guard let asset = currentAsset else { return }
        recordDecision(.keep, for: asset)
        haptics.playKeep()
        sounds.playKeep()
        advance()
    }

    func swipeLeft() {
        guard let asset = currentAsset else { return }
        recordDecision(.delete, for: asset)
        haptics.playDelete()
        sounds.playDelete()
        advance()

        Task {
            isDeleting = true
            try? await deletionService.deleteAssets([asset])
            deletedCount += 1
            isDeleting = false
        }
    }

    func undo() {
        guard let last = decisionHistory.last else { return }
        decisionHistory.removeLast()
        group.decisions.removeValue(forKey: last.asset.localIdentifier)
        currentIndex = last.index
        haptics.playUndo()
    }

    var canUndo: Bool { !decisionHistory.isEmpty }

    private func recordDecision(_ decision: Decision, for asset: PHAsset) {
        decisionHistory.append((index: currentIndex, decision: decision, asset: asset))
        group.decisions[asset.localIdentifier] = decision
    }

    private func advance() {
        currentIndex += 1
        if currentIndex >= group.assets.count {
            isComplete = true
            haptics.playBatchComplete()
            sounds.playComplete()
        }
    }
}
