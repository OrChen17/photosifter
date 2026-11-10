import AVFoundation
import XCTest
@testable import PhotoSifter

final class VideoCompressionPlanTests: XCTestCase {
    private func source(
        _ width: CGFloat, _ height: CGFloat, fps: Double = 60, duration: Double = 60, bytes: Int64 = 400_000_000
    ) -> VideoSource {
        VideoSource(displaySize: CGSize(width: width, height: height), frameRate: fps, duration: duration, fileBytes: bytes)
    }

    func testRecommendedCapsFourKSixtyToTenEightyTwentyFour() {
        let plan = VideoCompressionPlan(source: source(3840, 2160), settings: VideoCompressionSettings(duration: 60))
        XCTAssertEqual(plan.outputSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(plan.frameRate, 24)
        XCTAssertTrue(plan.isWorthwhile)
    }

    func testPortraitCapsTheShortSide() {
        let plan = VideoCompressionPlan(source: source(2160, 3840), settings: VideoCompressionSettings(duration: 60))
        XCTAssertEqual(plan.outputSize, CGSize(width: 1080, height: 1920))
    }

    func testNeverUpscalesOrRaisesFrameRate() {
        let plan = VideoCompressionPlan(
            source: source(1280, 720, fps: 15, bytes: 50_000_000),
            settings: VideoCompressionSettings(duration: 60)
        )
        XCTAssertEqual(plan.outputSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(plan.frameRate, 15)
    }

    func testOddDimensionsAreRoundedToEven() {
        let size = VideoCompressionPlan.cappedSize(CGSize(width: 1437, height: 2555), shortSide: 1080)
        XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(size.height.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(size.width, 1080)
    }

    func testSizesAddUp() {
        let plan = VideoCompressionPlan(source: source(3840, 2160), settings: VideoCompressionSettings(duration: 60))
        XCTAssertEqual(plan.estimatedBytes + plan.savedBytes, plan.originalBytes)
        XCTAssertLessThan(plan.estimatedBytes, plan.originalBytes)
    }

    func testBitrateStaysBelowSource() {
        let lowBitrate = source(3840, 2160, bytes: 15_000_000)
        let plan = VideoCompressionPlan(source: lowBitrate, settings: VideoCompressionSettings(duration: 60))
        let sourceBitrate = Double(lowBitrate.fileBytes) * 8 / lowBitrate.duration
        XCTAssertLessThan(Double(plan.videoBitrate), sourceBitrate)
        XCTAssertLessThanOrEqual(plan.estimatedBytes, plan.originalBytes)
    }

    func testAlreadySmallVideoIsNotWorthwhile() {
        let small = source(1920, 1080, fps: 24, bytes: 20_000_000)
        let plan = VideoCompressionPlan(source: small, settings: VideoCompressionSettings(duration: 60))
        XCTAssertFalse(plan.isWorthwhile)
    }

    func testTrimShortensDurationAndEstimate() {
        let full = VideoCompressionPlan(source: source(3840, 2160), settings: VideoCompressionSettings(duration: 60))
        var settings = VideoCompressionSettings(duration: 60)
        settings.trimStart = 10
        settings.trimEnd = 40
        let trimmed = VideoCompressionPlan(source: source(3840, 2160), settings: settings)
        XCTAssertEqual(trimmed.trimStart, 10)
        XCTAssertEqual(trimmed.duration, 30)
        XCTAssertEqual(Double(trimmed.estimatedBytes), Double(full.estimatedBytes) / 2, accuracy: 1024)
    }

    func testTrimIsClampedToTheVideo() {
        var settings = VideoCompressionSettings(duration: 60)
        settings.trimStart = -5
        settings.trimEnd = 500
        let plan = VideoCompressionPlan(source: source(3840, 2160), settings: settings)
        XCTAssertEqual(plan.trimStart, 0)
        XCTAssertEqual(plan.duration, 60)
    }

    func testUnknownFrameRateAssumesTheCap() {
        let plan = VideoCompressionPlan(source: source(3840, 2160, fps: 0), settings: VideoCompressionSettings(duration: 60))
        XCTAssertEqual(plan.frameRate, 24)
    }
}

final class FrameRateDecimatorTests: XCTestCase {
    private func keptCount(source: Double, target: Double, seconds: Int = 10) -> Int {
        let decimator = FrameRateDecimator(sourceFrameRate: source, targetFrameRate: target)
        return (0..<Int(source) * seconds).filter {
            decimator.shouldKeep(presentationSeconds: Double($0) / source)
        }.count
    }

    func testThirtyToTwentyFour() {
        XCTAssertEqual(keptCount(source: 30, target: 24), 240, accuracy: 2)
    }

    func testSixtyToTwentyFour() {
        XCTAssertEqual(keptCount(source: 60, target: 24), 240, accuracy: 2)
    }

    func testSameOrLowerSourceKeepsEveryFrame() {
        XCTAssertEqual(keptCount(source: 24, target: 24), 240)
        XCTAssertEqual(keptCount(source: 15, target: 24), 150)
    }
}

private actor MockVideoLibrary: VideoLibraryReplacing {
    enum Call: Equatable {
        case create(String)
        case verify(String)
        case delete([String])
    }

    static func copyID(of originalID: String) -> String { "copy-of-\(originalID)" }

    private(set) var calls: [Call] = []
    private var createFails = false
    private var unusableCopies: Set<String> = []
    private var deleteFails = false

    func configure(createFails: Bool = false, unusableCopies: Set<String> = [], deleteFails: Bool = false) {
        self.createFails = createFails
        self.unusableCopies = unusableCopies
        self.deleteFails = deleteFails
    }

    func createCopy(of originalID: String, fromFileAt url: URL) async throws -> String {
        calls.append(.create(originalID))
        if createFails { throw VideoReplaceError.copyNotCreated }
        return Self.copyID(of: originalID)
    }

    func isUsableCopy(_ copyID: String, expectedDuration: Double) async -> Bool {
        calls.append(.verify(copyID))
        return !unusableCopies.contains(copyID)
    }

    func delete(_ assetIDs: [String]) async throws {
        calls.append(.delete(assetIDs))
        if deleteFails { throw CocoaError(.userCancelled) }
    }
}

final class VideoReplacerTests: XCTestCase {
    private static let originalID = "original"
    private static let otherID = "other"
    private static let plainDeleteID = "plain-delete"
    private let url = URL(fileURLWithPath: "/dev/null")

    private func copy(of id: String) -> VideoCopy {
        VideoCopy(originalID: id, copyID: MockVideoLibrary.copyID(of: id), expectedDuration: 5)
    }

    private func deletes(_ library: MockVideoLibrary) async -> [MockVideoLibrary.Call] {
        await library.calls.filter { if case .delete = $0 { true } else { false } }
    }

    func testMakeCopyCreatesAndVerifiesButNeverDeletes() async throws {
        let library = MockVideoLibrary()
        let made = try await VideoReplacer(library: library)
            .makeCopy(originalID: Self.originalID, fromFileAt: url, expectedDuration: 5)
        XCTAssertEqual(made, copy(of: Self.originalID))
        let calls = await library.calls
        XCTAssertEqual(calls, [.create(Self.originalID), .verify(made.copyID)])
    }

    func testMakeCopyThrowsWhenCreationFails() async {
        let library = MockVideoLibrary()
        await library.configure(createFails: true)
        do {
            _ = try await VideoReplacer(library: library)
                .makeCopy(originalID: Self.originalID, fromFileAt: url, expectedDuration: 5)
            XCTFail("expected a throw")
        } catch {}
        let deleted = await deletes(library)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testMakeCopyThrowsWhenCopyIsNotVerified() async {
        let library = MockVideoLibrary()
        await library.configure(unusableCopies: [MockVideoLibrary.copyID(of: Self.originalID)])
        do {
            _ = try await VideoReplacer(library: library)
                .makeCopy(originalID: Self.originalID, fromFileAt: url, expectedDuration: 5)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? VideoReplaceError, .copyNotVerified)
        }
    }

    func testDeletesOriginalsAndPlainDeletesInOneCallAfterRecheck() async {
        let library = MockVideoLibrary()
        let result = await VideoReplacer(library: library).deleteOriginals(
            of: [copy(of: Self.originalID), copy(of: Self.otherID)], alsoDeleting: [Self.plainDeleteID]
        )
        XCTAssertEqual(result.deletedIDs, [Self.originalID, Self.otherID, Self.plainDeleteID])
        XCTAssertFalse(result.wasDeclined)
        let calls = await library.calls
        XCTAssertEqual(calls.last, .delete([Self.plainDeleteID, Self.originalID, Self.otherID]))
        XCTAssertEqual(calls.dropLast(), [
            .verify(MockVideoLibrary.copyID(of: Self.originalID)),
            .verify(MockVideoLibrary.copyID(of: Self.otherID)),
        ])
    }

    func testOriginalWithMissingCopyIsLeftAlone() async {
        let library = MockVideoLibrary()
        await library.configure(unusableCopies: [MockVideoLibrary.copyID(of: Self.otherID)])
        let result = await VideoReplacer(library: library).deleteOriginals(
            of: [copy(of: Self.originalID), copy(of: Self.otherID)], alsoDeleting: []
        )
        XCTAssertEqual(result.deletedIDs, [Self.originalID])
        XCTAssertEqual(result.unverifiedOriginalIDs, [Self.otherID])
        let deleted = await deletes(library)
        XCTAssertEqual(deleted, [.delete([Self.originalID])])
    }

    func testNoDeleteCallWhenNoCopyIsVerified() async {
        let library = MockVideoLibrary()
        await library.configure(unusableCopies: [MockVideoLibrary.copyID(of: Self.originalID)])
        let result = await VideoReplacer(library: library)
            .deleteOriginals(of: [copy(of: Self.originalID)], alsoDeleting: [])
        XCTAssertTrue(result.deletedIDs.isEmpty)
        let deleted = await deletes(library)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testDeclinedDeleteReportsNothingDeleted() async {
        let library = MockVideoLibrary()
        await library.configure(deleteFails: true)
        let result = await VideoReplacer(library: library)
            .deleteOriginals(of: [copy(of: Self.originalID)], alsoDeleting: [Self.plainDeleteID])
        XCTAssertTrue(result.wasDeclined)
        XCTAssertTrue(result.deletedIDs.isEmpty)
    }
}

final class VideoCapOptionTests: XCTestCase {
    private func source(width: CGFloat, height: CGFloat, fps: Double) -> VideoSource {
        VideoSource(displaySize: CGSize(width: width, height: height), frameRate: fps, duration: 10, fileBytes: 50_000_000)
    }

    func testOptionsOnlyOfferCapsThatLowerTheVideo() {
        let hd60 = source(width: 1920, height: 1080, fps: 60)
        XCTAssertEqual(VideoResolutionCap.options(for: hd60), [.original, .p720])
        XCTAssertEqual(VideoFrameRateCap.options(for: hd60), [.original, .fps30, .fps24])
        XCTAssertEqual(VideoResolutionCap.p1080.effective(for: hd60), .original)

        let uhd30 = source(width: 2160, height: 3840, fps: 30)
        XCTAssertEqual(VideoResolutionCap.options(for: uhd30), [.original, .p1080, .p720])
        XCTAssertEqual(VideoFrameRateCap.options(for: uhd30), [.original, .fps24])
        XCTAssertEqual(VideoFrameRateCap.fps30.effective(for: uhd30), .original)
    }

    func testCompressIsOffWhenNothingIsLowered() {
        let hd24 = source(width: 1920, height: 1080, fps: 24)
        let untouched = VideoCompressionPlan(source: hd24, settings: VideoCompressionSettings(duration: 10))
        XCTAssertFalse(untouched.changesVideo)
        XCTAssertFalse(untouched.canCompress)

        var trimmed = VideoCompressionSettings(duration: 10)
        trimmed.trimEnd = 4
        XCTAssertTrue(VideoCompressionPlan(source: hd24, settings: trimmed).canCompress)

        let uhd = source(width: 3840, height: 2160, fps: 30)
        XCTAssertTrue(VideoCompressionPlan(source: uhd, settings: VideoCompressionSettings(duration: 10)).canCompress)
        let original = VideoCompressionSettings(duration: 10, resolution: .original, frameRate: .original)
        XCTAssertFalse(VideoCompressionPlan(source: uhd, settings: original).canCompress)
    }
}

/// Runs the real encoder on a generated clip.
final class VideoTranscoderTests: XCTestCase {
    private static let sourceSize = CGSize(width: 2560, height: 1440)
    private static let sourceFrameRate: Int32 = 30
    private static let sourceSeconds = 3

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTranscodeCapsSizeAndFrameRateAndTrims() async throws {
        let sourceURL = directory.appendingPathComponent("source.mov")
        try await Self.writeClip(to: sourceURL)
        let asset = AVURLAsset(url: sourceURL)
        let bytes = Int64(try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let source = try await VideoTranscoder.loadSource(from: asset, fileBytes: bytes)
        XCTAssertEqual(source.displaySize, Self.sourceSize)
        XCTAssertEqual(source.frameRate, Double(Self.sourceFrameRate), accuracy: 0.5)

        var settings = VideoCompressionSettings(duration: source.duration)
        settings.trimStart = 0.5
        settings.trimEnd = 2.5
        let plan = VideoCompressionPlan(source: source, settings: settings)

        let outputURL = directory.appendingPathComponent("out.mov")
        try await VideoTranscoder().transcode(asset: asset, plan: plan, to: outputURL) { _ in }

        let isValid = await VideoTranscoder.isValidOutput(at: outputURL, expectedDuration: 2)
        XCTAssertTrue(isValid)
        let output = AVURLAsset(url: outputURL)
        let track = try await output.loadTracks(withMediaType: .video).first
        let (size, frameRate) = try await XCTUnwrap(track).load(.naturalSize, .nominalFrameRate)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(Double(frameRate), 24, accuracy: 1.5)
        let duration = try await output.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.2)
    }

    func testCancelRemovesTheOutputFile() async throws {
        let sourceURL = directory.appendingPathComponent("source.mov")
        try await Self.writeClip(to: sourceURL)
        let asset = AVURLAsset(url: sourceURL)
        let source = try await VideoTranscoder.loadSource(from: asset, fileBytes: 1)
        let plan = VideoCompressionPlan(source: source, settings: VideoCompressionSettings(duration: source.duration))
        let outputURL = directory.appendingPathComponent("out.mov")
        let transcoder = VideoTranscoder()
        transcoder.cancel()
        do {
            try await transcoder.transcode(asset: asset, plan: plan, to: outputURL) { _ in }
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    private static func writeClip(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(sourceSize.width),
            AVVideoHeightKey: Int(sourceSize.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(sourceSize.width),
            kCVPixelBufferHeightKey as String: Int(sourceSize.height),
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int(sourceFrameRate) * sourceSeconds
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 255 / frames), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: sourceFrameRate))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
