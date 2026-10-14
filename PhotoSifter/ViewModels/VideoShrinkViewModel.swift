import Foundation
import Photos

enum ShrinkPhase: Equatable {
    case idle
    /// `current` is 1-based; `fraction` is overall progress across the batch.
    case converting(current: Int, total: Int, fraction: Double)
    /// Converted copies are being written to Photos (iOS delete prompt is up).
    case saving
    /// The user cancelled the iOS prompt. Nothing changed in Photos; the
    /// converted files are kept so "Replace" can re-prompt without re-encoding.
    case awaitingRetry(count: Int, savedBytes: Int64)
    case done(count: Int, savedBytes: Int64, failed: Int)
    case failed(String)
}

@Observable
@MainActor
final class VideoShrinkViewModel {
    private(set) var candidates: [VideoCandidate] = []
    var selection: Set<String> = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var phase: ShrinkPhase = .idle
    /// Lifetime bytes freed by this tab, shown in the header.
    private(set) var totalSavedBytes: Int64
    var sortOrder: VideoSortOrder {
        didSet {
            defaults.set(sortOrder.rawValue, forKey: Self.sortOrderKey)
            candidates = sortOrder.sorted(candidates)
        }
    }

    static let sortOrderKey = "videoShrink.sortOrder"
    static let totalSavedKey = "videoShrink.totalSavedBytes"
    /// Headroom kept free on top of the converted copies. Photos copies each
    /// file in, so the batch briefly needs about twice its output size.
    static let diskHeadroomBytes: Int64 = 200_000_000

    private let service: VideoShrinking
    private let defaults: UserDefaults
    private var pendingOutputs: [ShrinkOutput] = []
    private var pendingFailedCount = 0
    private var shrinkTask: Task<Void, Never>?

    init(service: VideoShrinking = VideoShrinkService.shared, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        sortOrder = defaults.string(forKey: Self.sortOrderKey).flatMap(VideoSortOrder.init) ?? .largest
        totalSavedBytes = Int64(defaults.integer(forKey: Self.totalSavedKey))
    }

    // MARK: - Derived

    var selectedCandidates: [VideoCandidate] { candidates.filter { selection.contains($0.id) } }
    var selectedOriginalBytes: Int64 { selectedCandidates.reduce(0) { $0 + $1.spec.fileBytes } }
    var selectedEstimatedBytes: Int64 { selectedCandidates.reduce(0) { $0 + $1.estimatedBytes } }
    var selectedSavings: Int64 { selectedCandidates.reduce(0) { $0 + $1.estimatedSavings } }
    var totalPossibleSavings: Int64 { candidates.reduce(0) { $0 + $1.estimatedSavings } }
    var isAllSelected: Bool { !candidates.isEmpty && selection.count == candidates.count }

    var isWorking: Bool {
        switch phase {
        case .converting, .saving: return true
        default: return false
        }
    }

    // MARK: - Scan

    func load() async {
        guard !isScanning else { return }
        isScanning = true
        let found = await service.fetchCandidates()
        candidates = sortOrder.sorted(found)
        // Keep selections that still exist after a rescan.
        selection.formIntersection(Set(found.map(\.id)))
        isScanning = false
        hasScanned = true
    }

    // MARK: - Selection

    func toggle(_ id: String) {
        guard !isWorking else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func toggleAll() {
        guard !isWorking else { return }
        selection = isAllSelected ? [] : Set(candidates.map(\.id))
    }

    // MARK: - Shrink

    @discardableResult
    func startShrinking() -> Task<Void, Never>? {
        guard !isWorking, !selection.isEmpty else { return nil }
        let task = Task { await shrinkSelected() }
        shrinkTask = task
        return task
    }

    func cancelShrinking() {
        shrinkTask?.cancel()
    }

    /// Converts every selected video, then swaps all originals in one Photos
    /// change. Videos that fail to convert, or that wouldn't get smaller, are
    /// left untouched.
    func shrinkSelected() async {
        let batch = selectedCandidates
        guard !batch.isEmpty, !isWorking else { return }

        if let free = await service.availableDiskBytes() {
            let needed = batch.reduce(Int64(0)) { $0 + $1.estimatedBytes } * 2 + Self.diskHeadroomBytes
            if free < needed {
                let short = ByteCountFormatter.string(fromByteCount: needed - free, countStyle: .file)
                phase = .failed("Not enough free space. Free up \(short) or pick fewer videos.")
                return
            }
        }

        var outputs: [ShrinkOutput] = []
        var failed = 0
        let total = batch.count
        for (index, candidate) in batch.enumerated() {
            if Task.isCancelled { break }
            phase = .converting(current: index + 1, total: total, fraction: Double(index) / Double(total))
            do {
                let output = try await service.transcode(candidate) { [weak self] fraction in
                    Task { @MainActor [weak self] in self?.updateProgress(fraction, index: index, total: total) }
                }
                if output.bytes > 0, output.bytes < candidate.spec.fileBytes {
                    outputs.append(output)
                } else {
                    await service.discard([output])
                    failed += 1
                }
            } catch is CancellationError {
                break
            } catch {
                print("[VideoShrink] convert failed for \(candidate.id): \(error)")
                failed += 1
            }
        }

        if Task.isCancelled {
            await service.discard(outputs)
            phase = .idle
            return
        }
        guard !outputs.isEmpty else {
            phase = .failed(total == 1
                ? "This video couldn't be converted."
                : "None of the selected videos could be converted.")
            return
        }
        pendingOutputs = outputs
        pendingFailedCount = failed
        await commitPending()
    }

    /// Re-shows the iOS prompt for videos already converted.
    func retryReplace() async {
        guard !pendingOutputs.isEmpty, !isWorking else { return }
        await commitPending()
    }

    func discardPending() async {
        await service.discard(pendingOutputs)
        pendingOutputs = []
        phase = .idle
    }

    func dismissResult() {
        guard !isWorking else { return }
        phase = .idle
    }

    private func updateProgress(_ fraction: Double, index: Int, total: Int) {
        // Late callbacks from a finished video must not rewind the ring.
        guard case .converting(let current, let t, _) = phase, current == index + 1, t == total else { return }
        let overall = (Double(index) + min(max(fraction, 0), 1)) / Double(total)
        phase = .converting(current: current, total: total, fraction: overall)
    }

    private var pendingSavings: Int64 {
        let ids = Set(pendingOutputs.map(\.candidateID))
        let original = candidates.filter { ids.contains($0.id) }.reduce(Int64(0)) { $0 + $1.spec.fileBytes }
        return max(0, original - pendingOutputs.reduce(Int64(0)) { $0 + $1.bytes })
    }

    private func commitPending() async {
        let saved = pendingSavings
        let count = pendingOutputs.count
        phase = .saving
        do {
            try await service.replaceOriginals(with: pendingOutputs)
            let ids = Set(pendingOutputs.map(\.candidateID))
            candidates.removeAll { ids.contains($0.id) }
            selection.subtract(ids)
            pendingOutputs = []
            totalSavedBytes += saved
            defaults.set(Int(totalSavedBytes), forKey: Self.totalSavedKey)
            phase = .done(count: count, savedBytes: saved, failed: pendingFailedCount)
        } catch {
            let ns = error as NSError
            // Same cancellation mapping as SifterViewModel.commitDeletes.
            if (error as? PHPhotosError)?.code == .userCancelled || ns.code == NSUserCancelledError {
                phase = .awaitingRetry(count: count, savedBytes: saved)
            } else {
                print("[VideoShrink] replace failed: \(error)")
                await service.discard(pendingOutputs)
                pendingOutputs = []
                phase = .failed("Photos couldn't save the smaller videos. Nothing was deleted.")
            }
        }
    }
}
