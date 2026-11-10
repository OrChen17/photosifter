import AVFoundation
import CoreLocation
import Photos
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
        let untouched = VideoCompressionPlan(
            source: hd24, settings: VideoCompressionSettings(duration: 10, quality: .original)
        )
        XCTAssertFalse(untouched.changesVideo)
        XCTAssertFalse(untouched.canCompress)

        var trimmed = VideoCompressionSettings(duration: 10, quality: .original)
        trimmed.trimEnd = 4
        XCTAssertTrue(VideoCompressionPlan(source: hd24, settings: trimmed).canCompress)

        let uhd = source(width: 3840, height: 2160, fps: 30)
        XCTAssertTrue(VideoCompressionPlan(source: uhd, settings: VideoCompressionSettings(duration: 10)).canCompress)
        let original = VideoCompressionSettings(duration: 10, resolution: .original, frameRate: .original, quality: .original)
        XCTAssertFalse(VideoCompressionPlan(source: uhd, settings: original).canCompress)
    }

    func testLowerQualityAloneAllowsCompress() {
        let hd24 = source(width: 1920, height: 1080, fps: 24)
        let settings = VideoCompressionSettings(
            duration: 10, resolution: .original, frameRate: .original, quality: .balanced
        )
        XCTAssertTrue(VideoCompressionPlan(source: hd24, settings: settings).canCompress)
    }

    func testFrameRateAloneSavesAboutItsShare() {
        let hd30 = source(width: 1920, height: 1080, fps: 30)
        let settings = VideoCompressionSettings(
            duration: 10, resolution: .original, frameRate: .fps24, quality: .original
        )
        let plan = VideoCompressionPlan(source: hd30, settings: settings)
        let savedShare = Double(plan.savedBytes) / Double(plan.originalBytes)
        XCTAssertEqual(savedShare, 0.2, accuracy: 0.05)
    }

    func testQualityOptionsHideLevelsAboveTheSource() {
        let lean = VideoSource(
            displaySize: CGSize(width: 1920, height: 1080), frameRate: 30, duration: 10, fileBytes: 5_000_000
        )
        XCTAssertEqual(VideoQuality.options(for: lean), [.original, .small])
        XCTAssertEqual(VideoQuality.balanced.effective(for: lean), .original)
        let rich = source(width: 1920, height: 1080, fps: 30)
        XCTAssertEqual(VideoQuality.options(for: rich), VideoQuality.allCases)
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

    func testOutputFileCarriesTheCaptureDateAndPlace() async throws {
        let sourceURL = directory.appendingPathComponent("source.mov")
        try await Self.writeClip(to: sourceURL, metadata: [
            VideoMetadataFixtures.item(.quickTimeMetadataMake, VideoMetadataFixtures.make),
            VideoMetadataFixtures.item(.quickTimeMetadataModel, VideoMetadataFixtures.model),
        ])
        let asset = AVURLAsset(url: sourceURL)
        let source = try await VideoTranscoder.loadSource(from: asset, fileBytes: 1)
        let plan = VideoCompressionPlan(source: source, settings: VideoCompressionSettings(duration: source.duration))
        let outputURL = directory.appendingPathComponent("out.mov")
        let capture = VideoCaptureInfo(date: VideoMetadataFixtures.captureDate, coordinate: VideoMetadataFixtures.coordinate)

        try await VideoTranscoder().transcode(asset: asset, plan: plan, to: outputURL, capture: capture) { _ in }

        let isValid = await VideoTranscoder.isValidOutput(at: outputURL, expectedDuration: source.duration)
        XCTAssertTrue(isValid)
        let output = AVURLAsset(url: outputURL)
        let items = try await output.load(.metadata)
        let dateItem = try XCTUnwrap(items.first { $0.identifier == .quickTimeMetadataCreationDate })
        let fileDate = try await dateItem.load(.dateValue)
        XCTAssertEqual(fileDate, VideoMetadataFixtures.captureDate)
        let assetDate = try await output.load(.creationDate)?.load(.dateValue)
        XCTAssertEqual(assetDate, VideoMetadataFixtures.captureDate)
        XCTAssertEqual(try MovieHeaderDates.creationDate(ofFileAt: outputURL), VideoMetadataFixtures.captureDate)
        let place = try await XCTUnwrap(items.first { $0.identifier == .quickTimeMetadataLocationISO6709 }).load(.stringValue)
        XCTAssertEqual(place, VideoMetadataFixtures.coordinateString)
        let make = try await XCTUnwrap(items.first { $0.identifier == .quickTimeMetadataMake }).load(.stringValue)
        XCTAssertEqual(make, VideoMetadataFixtures.make)
        let model = try await XCTUnwrap(items.first { $0.identifier == .quickTimeMetadataModel }).load(.stringValue)
        XCTAssertEqual(model, VideoMetadataFixtures.model)
    }

    func testOutputWithoutPhotosDateKeepsTheSourceFileDate() async throws {
        let sourceURL = directory.appendingPathComponent("source.mov")
        try await Self.writeClip(to: sourceURL)
        try MovieHeaderDates.stamp(fileAt: sourceURL, creationDate: VideoMetadataFixtures.captureDate)
        let asset = AVURLAsset(url: sourceURL)
        let source = try await VideoTranscoder.loadSource(from: asset, fileBytes: 1)
        let plan = VideoCompressionPlan(source: source, settings: VideoCompressionSettings(duration: source.duration))
        let outputURL = directory.appendingPathComponent("out.mov")

        try await VideoTranscoder().transcode(asset: asset, plan: plan, to: outputURL) { _ in }

        XCTAssertEqual(try MovieHeaderDates.creationDate(ofFileAt: outputURL), VideoMetadataFixtures.captureDate)
    }

    func testStampLeavesAFileThatIsNotAMovieAlone() throws {
        let url = directory.appendingPathComponent("junk.mov")
        let junk = Data(repeating: 7, count: 64)
        try junk.write(to: url)
        try MovieHeaderDates.stamp(fileAt: url, creationDate: VideoMetadataFixtures.captureDate)
        XCTAssertEqual(try Data(contentsOf: url), junk)
        XCTAssertNil(try MovieHeaderDates.creationDate(ofFileAt: url))
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

    static func writeClip(to url: URL, metadata: [AVMetadataItem] = []) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = metadata
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

enum VideoMetadataFixtures {
    static let captureDate = Date(timeIntervalSince1970: 1_614_855_600)
    static let coordinate = CLLocationCoordinate2D(latitude: 32.0853, longitude: 34.7818)
    static let coordinateString = "+32.0853+034.7818/"
    static let make = "Apple"
    static let model = "iPhone 14 Pro"
    static let jerusalem = TimeZone(identifier: "Asia/Jerusalem")!
    static let sourceDateString = "2021-03-04T13:00:00+0200"

    static func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }
}

final class VideoCaptureMetadataTests: XCTestCase {
    private func strings(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) async throws -> [String] {
        var values: [String] = []
        for item in items where item.identifier == identifier {
            let value = try await item.load(.stringValue)
            values.append(try XCTUnwrap(value))
        }
        return values
    }

    func testAddsDateAndPlaceWhenTheSourceHasNone() async throws {
        let capture = VideoCaptureInfo(date: VideoMetadataFixtures.captureDate, coordinate: VideoMetadataFixtures.coordinate)
        let result = await VideoCaptureMetadata.output(
            from: [], fallbackDate: nil, capture: capture, timeZone: VideoMetadataFixtures.jerusalem
        )
        XCTAssertEqual(result.headerDate, VideoMetadataFixtures.captureDate)
        let dates = try await strings(result.items, .quickTimeMetadataCreationDate)
        XCTAssertEqual(dates, [VideoMetadataFixtures.sourceDateString])
        let places = try await strings(result.items, .quickTimeMetadataLocationISO6709)
        XCTAssertEqual(places, [VideoMetadataFixtures.coordinateString])
    }

    func testKeepsTheSourceDateStringWhenItIsTheSameInstant() async throws {
        let original = "2021-03-04T06:00:00-0500"
        let source = [
            VideoMetadataFixtures.item(.quickTimeMetadataCreationDate, original),
            VideoMetadataFixtures.item(.quickTimeMetadataLocationISO6709, VideoMetadataFixtures.coordinateString),
        ]
        let capture = VideoCaptureInfo(date: VideoMetadataFixtures.captureDate, coordinate: VideoMetadataFixtures.coordinate)
        let result = await VideoCaptureMetadata.output(
            from: source, fallbackDate: nil, capture: capture, timeZone: VideoMetadataFixtures.jerusalem
        )
        XCTAssertEqual(result.items.count, source.count)
        let dates = try await strings(result.items, .quickTimeMetadataCreationDate)
        XCTAssertEqual(dates, [original])
    }

    func testPhotosDateWinsOverADifferentSourceDate() async throws {
        let source = [VideoMetadataFixtures.item(.quickTimeMetadataCreationDate, "2019-01-01T00:00:00+0000")]
        let capture = VideoCaptureInfo(date: VideoMetadataFixtures.captureDate, coordinate: nil)
        let result = await VideoCaptureMetadata.output(
            from: source, fallbackDate: nil, capture: capture, timeZone: VideoMetadataFixtures.jerusalem
        )
        let dates = try await strings(result.items, .quickTimeMetadataCreationDate)
        XCTAssertEqual(dates, [VideoMetadataFixtures.sourceDateString])
        XCTAssertEqual(result.headerDate, VideoMetadataFixtures.captureDate)
    }

    func testFallsBackToTheFileDateWhenPhotosHasNone() async throws {
        let result = await VideoCaptureMetadata.output(
            from: [], fallbackDate: VideoMetadataFixtures.captureDate, capture: VideoCaptureInfo(),
            timeZone: VideoMetadataFixtures.jerusalem
        )
        XCTAssertEqual(result.headerDate, VideoMetadataFixtures.captureDate)
        let dates = try await strings(result.items, .quickTimeMetadataCreationDate)
        XCTAssertEqual(dates, [VideoMetadataFixtures.sourceDateString])
    }
}

final class VideoLibraryCopyTests: XCTestCase {
    private static let optInVariable = "VIDEO_LIBRARY_TESTS"
    private static let pastAddedDate = Date(timeIntervalSince1970: 1_620_000_000)
    private static let addedDateSetter = NSSelectorFromString("setAddedDate:")

    func testCopyTakesTheOriginalsDateAndLibraryPosition() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment[Self.optInVariable] == nil,
            "Adds two videos to the library. Run with TEST_RUNNER_\(Self.optInVariable)=1."
        )
        try XCTSkipIf(PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized, "Needs full photo access.")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mov")
        try await VideoTranscoderTests.writeClip(to: sourceURL)

        var originalID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: sourceURL, options: nil)
            request.creationDate = VideoMetadataFixtures.captureDate
            request.location = CLLocation(
                latitude: VideoMetadataFixtures.coordinate.latitude, longitude: VideoMetadataFixtures.coordinate.longitude
            )
            if request.responds(to: Self.addedDateSetter) {
                request.perform(Self.addedDateSetter, with: Self.pastAddedDate as NSDate)
            }
            originalID = request.placeholderForCreatedAsset?.localIdentifier
        }
        let id = try XCTUnwrap(originalID)
        let original = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        let originalAdded = try XCTUnwrap(VideoLibraryService.addedDate(of: original))
        try XCTSkipIf(
            abs(originalAdded.timeIntervalSince(Self.pastAddedDate)) > 1,
            "This system does not let a test set the added date of the original."
        )

        let avAsset = await VideoLibraryService.shared.loadAVAsset(for: original)
        let asset = try XCTUnwrap(avAsset)
        let source = try await VideoTranscoder.loadSource(from: asset, fileBytes: 1)
        let plan = VideoCompressionPlan(source: source, settings: VideoCompressionSettings(duration: source.duration))
        let outputURL = directory.appendingPathComponent("out.mov")
        let capture = VideoCaptureInfo(date: original.creationDate, coordinate: original.location?.coordinate)
        try await VideoTranscoder().transcode(asset: asset, plan: plan, to: outputURL, capture: capture) { _ in }

        let made = try await VideoReplacer(library: VideoLibraryService.shared)
            .makeCopy(originalID: id, fromFileAt: outputURL, expectedDuration: plan.duration)
        let copy = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [made.copyID], options: nil).firstObject)

        XCTAssertNotEqual(made.copyID, id)
        XCTAssertEqual(copy.creationDate, VideoMetadataFixtures.captureDate)
        XCTAssertEqual(VideoLibraryService.addedDate(of: copy), originalAdded)
        let location = try XCTUnwrap(copy.location)
        XCTAssertEqual(location.coordinate.latitude, VideoMetadataFixtures.coordinate.latitude, accuracy: 0.001)
        print("VIDEO_LIBRARY_COPY original=\(id) copy=\(made.copyID)")
    }
}
