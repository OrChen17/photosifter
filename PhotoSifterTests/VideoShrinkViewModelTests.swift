import XCTest
import Photos
@testable import PhotoSifter

@MainActor
final class VideoShrinkViewModelTests: XCTestCase {

    private var defaults: UserDefaults!
    private var service: MockVideoShrinkService!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "VideoShrinkViewModelTests")!
        defaults.removePersistentDomain(forName: "VideoShrinkViewModelTests")
        service = MockVideoShrinkService()
        service.candidates = [
            candidate("small", mb: 200, seconds: 60),   // saves 125 MB
            candidate("big", mb: 900, seconds: 120),    // saves 750 MB
            candidate("mid", mb: 500, seconds: 60),     // saves 425 MB
        ]
    }

    private func candidate(_ id: String, mb: Int64, seconds: TimeInterval) -> VideoCandidate {
        VideoCandidate(
            id: id,
            spec: VideoSpec(width: 3840, height: 2160, fps: 60, duration: seconds, fileBytes: mb * 1_000_000),
            creationDate: nil
        )
    }

    private func makeLoadedVM() async -> VideoShrinkViewModel {
        let vm = VideoShrinkViewModel(service: service, defaults: defaults)
        await vm.load()
        return vm
    }

    // MARK: - Scan + sort

    func testLoadSortsLargestFirstByDefault() async {
        let vm = await makeLoadedVM()
        XCTAssertEqual(vm.candidates.map(\.id), ["big", "mid", "small"])
        XCTAssertTrue(vm.hasScanned)
        XCTAssertFalse(vm.isScanning)
        XCTAssertTrue(vm.selection.isEmpty)
    }

    func testSortOrderIsPersistedAndApplied() async {
        let vm = await makeLoadedVM()
        vm.sortOrder = .mostSavings
        XCTAssertEqual(defaults.string(forKey: VideoShrinkViewModel.sortOrderKey), "mostSavings")

        let reopened = VideoShrinkViewModel(service: service, defaults: defaults)
        XCTAssertEqual(reopened.sortOrder, .mostSavings)
    }

    func testRescanDropsSelectionsThatAreGone() async {
        let vm = await makeLoadedVM()
        vm.toggleAll()
        service.candidates.removeAll { $0.id == "mid" }
        await vm.load()
        XCTAssertEqual(vm.selection, ["big", "small"])
    }

    // MARK: - Selection math

    func testSelectionTotals() async {
        let vm = await makeLoadedVM()
        vm.toggle("big")
        vm.toggle("small")
        XCTAssertEqual(vm.selectedOriginalBytes, 1_100_000_000)
        XCTAssertEqual(vm.selectedEstimatedBytes, 150_000_000 + 75_000_000)
        XCTAssertEqual(vm.selectedSavings, 750_000_000 + 125_000_000)
        XCTAssertEqual(vm.totalPossibleSavings, 750_000_000 + 425_000_000 + 125_000_000)
    }

    func testToggleAllSelectsThenClears() async {
        let vm = await makeLoadedVM()
        vm.toggleAll()
        XCTAssertTrue(vm.isAllSelected)
        vm.toggleAll()
        XCTAssertTrue(vm.selection.isEmpty)
    }

    // MARK: - Shrink

    func testShrinkReplacesSelectedInOneBatchAndRecordsSavings() async {
        let vm = await makeLoadedVM()
        vm.toggle("big")
        vm.toggle("mid")

        await vm.shrinkSelected()

        XCTAssertEqual(service.replaceCalls.count, 1, "one Photos change → one iOS prompt")
        XCTAssertEqual(Set(service.replaceCalls[0].map(\.candidateID)), ["big", "mid"])
        XCTAssertEqual(vm.candidates.map(\.id), ["small"])
        XCTAssertTrue(vm.selection.isEmpty)
        XCTAssertEqual(vm.phase, .done(count: 2, savedBytes: 1_175_000_000, failed: 0))
        XCTAssertEqual(vm.totalSavedBytes, 1_175_000_000)
        XCTAssertEqual(defaults.integer(forKey: VideoShrinkViewModel.totalSavedKey), 1_175_000_000)
    }

    func testSavingsUseActualOutputSize() async {
        service.outputBytes["big"] = 300_000_000
        let vm = await makeLoadedVM()
        vm.toggle("big")
        await vm.shrinkSelected()
        XCTAssertEqual(vm.phase, .done(count: 1, savedBytes: 600_000_000, failed: 0))
    }

    func testFailedConversionIsSkippedAndCounted() async {
        service.failingIDs = ["mid"]
        let vm = await makeLoadedVM()
        vm.toggleAll()
        await vm.shrinkSelected()

        XCTAssertEqual(Set(service.replaceCalls[0].map(\.candidateID)), ["big", "small"])
        XCTAssertEqual(vm.candidates.map(\.id), ["mid"])
        guard case .done(let count, _, let failed) = vm.phase else { return XCTFail("\(vm.phase)") }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(failed, 1)
    }

    func testOutputThatIsNotSmallerIsDiscardedNotReplaced() async {
        service.outputBytes["small"] = 250_000_000   // bigger than the 200 MB original
        let vm = await makeLoadedVM()
        vm.toggle("small")
        await vm.shrinkSelected()

        XCTAssertTrue(service.replaceCalls.isEmpty)
        XCTAssertEqual(service.discarded.map(\.candidateID), ["small"])
        XCTAssertEqual(vm.candidates.count, 3)
        guard case .failed = vm.phase else { return XCTFail("\(vm.phase)") }
    }

    func testCancellingTheIOSPromptKeepsFilesForRetry() async {
        service.replaceError = PHPhotosError(.userCancelled)
        let vm = await makeLoadedVM()
        vm.toggle("big")
        await vm.shrinkSelected()

        XCTAssertEqual(vm.phase, .awaitingRetry(count: 1, savedBytes: 750_000_000))
        XCTAssertTrue(service.discarded.isEmpty)
        XCTAssertEqual(vm.candidates.count, 3, "nothing was replaced")
        XCTAssertEqual(vm.totalSavedBytes, 0)

        service.replaceError = nil
        await vm.retryReplace()
        XCTAssertEqual(service.transcoded, ["big"], "retry must not re-encode")
        XCTAssertEqual(vm.phase, .done(count: 1, savedBytes: 750_000_000, failed: 0))
    }

    func testNSUserCancelledAlsoCountsAsCancel() async {
        service.replaceError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        let vm = await makeLoadedVM()
        vm.toggle("big")
        await vm.shrinkSelected()
        XCTAssertEqual(vm.phase, .awaitingRetry(count: 1, savedBytes: 750_000_000))
    }

    func testDiscardPendingDeletesConvertedFiles() async {
        service.replaceError = PHPhotosError(.userCancelled)
        let vm = await makeLoadedVM()
        vm.toggle("big")
        await vm.shrinkSelected()
        await vm.discardPending()

        XCTAssertEqual(service.discarded.map(\.candidateID), ["big"])
        XCTAssertEqual(vm.phase, .idle)
        await vm.retryReplace()
        XCTAssertEqual(service.replaceCalls.count, 1, "nothing left to retry")
    }

    func testReplaceFailureDiscardsAndReports() async {
        service.replaceError = NSError(domain: "Photos", code: 42)
        let vm = await makeLoadedVM()
        vm.toggle("big")
        await vm.shrinkSelected()

        XCTAssertEqual(service.discarded.map(\.candidateID), ["big"])
        XCTAssertEqual(vm.candidates.count, 3)
        guard case .failed = vm.phase else { return XCTFail("\(vm.phase)") }
    }

    func testNotEnoughDiskSpaceStopsBeforeConverting() async {
        service.freeBytes = 100_000_000
        let vm = await makeLoadedVM()
        vm.toggle("big")
        await vm.shrinkSelected()

        XCTAssertTrue(service.transcoded.isEmpty)
        guard case .failed(let message) = vm.phase else { return XCTFail("\(vm.phase)") }
        XCTAssertTrue(message.contains("free space"))
    }

    func testCancelMidBatchDiscardsEverythingAndChangesNothing() async {
        let vm = await makeLoadedVM()
        vm.toggleAll()
        service.cancelOnID = "mid"     // order is big, mid, small
        await vm.startShrinking()?.value

        XCTAssertEqual(service.transcoded, ["big"])
        XCTAssertTrue(service.replaceCalls.isEmpty)
        XCTAssertEqual(service.discarded.map(\.candidateID), ["big"])
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(vm.candidates.count, 3)
    }

    func testSelectionIsLockedWhileWorking() async {
        let vm = await makeLoadedVM()
        vm.toggle("big")
        service.onTranscode = { _ in
            Task { @MainActor in
                vm.toggle("small")
                vm.toggleAll()
            }
        }
        await vm.shrinkSelected()
        XCTAssertFalse(vm.selection.contains("small"))
    }
}
