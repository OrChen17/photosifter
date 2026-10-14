import Foundation
import Photos
@testable import PhotoSifter

/// In-memory VideoShrinking — never touches Photos or AVFoundation.
final class MockVideoShrinkService: VideoShrinking, @unchecked Sendable {
    var candidates: [VideoCandidate] = []
    /// Output size per candidate id; defaults to the plan's estimate.
    var outputBytes: [String: Int64] = [:]
    var failingIDs: Set<String> = []
    var replaceError: Error?
    var freeBytes: Int64? = 100_000_000_000
    /// Called at the start of each transcode.
    var onTranscode: ((VideoCandidate) -> Void)?
    /// Cancels the calling (shrink) task when this candidate starts converting,
    /// the way tapping Cancel mid-export does.
    var cancelOnID: String?

    private(set) var transcoded: [String] = []
    private(set) var replaceCalls: [[ShrinkOutput]] = []
    private(set) var discarded: [ShrinkOutput] = []

    func fetchCandidates() async -> [VideoCandidate] { candidates }

    func transcode(
        _ candidate: VideoCandidate,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ShrinkOutput {
        onTranscode?(candidate)
        if candidate.id == cancelOnID {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        try Task.checkCancellation()
        if failingIDs.contains(candidate.id) { throw VideoShrinkError.exportFailed }
        transcoded.append(candidate.id)
        progress(1)
        return ShrinkOutput(
            candidateID: candidate.id,
            fileURL: URL(fileURLWithPath: "/tmp/\(candidate.id).mov"),
            bytes: outputBytes[candidate.id] ?? candidate.estimatedBytes
        )
    }

    func replaceOriginals(with outputs: [ShrinkOutput]) async throws {
        replaceCalls.append(outputs)
        if let replaceError { throw replaceError }
    }

    func discard(_ outputs: [ShrinkOutput]) async {
        discarded.append(contentsOf: outputs)
    }

    func availableDiskBytes() async -> Int64? { freeBytes }
}
