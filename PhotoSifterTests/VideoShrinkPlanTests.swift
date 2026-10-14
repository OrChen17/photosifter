import XCTest
@testable import PhotoSifter

final class VideoShrinkPlanTests: XCTestCase {

    private func spec(
        _ w: Int, _ h: Int, fps: Double? = 30, seconds: TimeInterval = 60, mb: Int64 = 400
    ) -> VideoSpec {
        VideoSpec(width: w, height: h, fps: fps, duration: seconds, fileBytes: mb * 1_000_000)
    }

    // MARK: - What counts as too big

    func test4K30IsResizedButKeepsFrameRate() {
        let s = spec(3840, 2160)
        XCTAssertTrue(VideoShrinkPlan.needsResize(s))
        XCTAssertFalse(VideoShrinkPlan.needsFrameRateDrop(s))
        XCTAssertTrue(VideoShrinkPlan.isCandidate(s))
    }

    func test1080p60OnlyDropsFrameRate() {
        let s = spec(1920, 1080, fps: 60, mb: 200)
        XCTAssertFalse(VideoShrinkPlan.needsResize(s))
        XCTAssertTrue(VideoShrinkPlan.needsFrameRateDrop(s))
        XCTAssertTrue(VideoShrinkPlan.isCandidate(s))
    }

    func test1080p30IsNotACandidate() {
        XCTAssertFalse(VideoShrinkPlan.isCandidate(spec(1920, 1080, fps: 30)))
    }

    func testNTSCFrameRatesCountAsThirty() {
        XCTAssertFalse(VideoShrinkPlan.needsFrameRateDrop(spec(1920, 1080, fps: 29.97)))
        XCTAssertFalse(VideoShrinkPlan.needsFrameRateDrop(spec(1920, 1080, fps: 30.02)))
        XCTAssertTrue(VideoShrinkPlan.needsFrameRateDrop(spec(1920, 1080, fps: 59.94)))
    }

    func testPortrait4KIsJudgedByShortSide() {
        XCTAssertTrue(VideoShrinkPlan.needsResize(spec(2160, 3840)))
        XCTAssertFalse(VideoShrinkPlan.needsResize(spec(1080, 1920)))
    }

    func testUnknownFrameRateFallsBackToResolution() {
        XCTAssertTrue(VideoShrinkPlan.isCandidate(spec(3840, 2160, fps: nil)))
        XCTAssertFalse(VideoShrinkPlan.isCandidate(spec(1920, 1080, fps: nil)))
    }

    func testAlreadyLeanVideoIsSkipped() {
        // 4K but tiny: a 10 s clip at 6 MB would only save ~0 MB.
        XCTAssertFalse(VideoShrinkPlan.isCandidate(spec(3840, 2160, seconds: 10, mb: 6)))
    }

    // MARK: - Target dimensions

    func testTargetDimensionsLandscape4K() {
        let d = VideoShrinkPlan.targetDimensions(width: 3840, height: 2160)
        XCTAssertEqual(d.width, 1920)
        XCTAssertEqual(d.height, 1080)
    }

    func testTargetDimensionsPortrait4K() {
        let d = VideoShrinkPlan.targetDimensions(width: 2160, height: 3840)
        XCTAssertEqual(d.width, 1080)
        XCTAssertEqual(d.height, 1920)
    }

    func testTargetDimensionsAreEven() {
        // 2880×1620 (3K-ish 16:9) and an odd-aspect 4:3 clip.
        for (w, h) in [(2880, 1620), (4032, 3024), (2704, 1520)] {
            let d = VideoShrinkPlan.targetDimensions(width: w, height: h)
            XCTAssertEqual(d.width % 2, 0, "\(w)x\(h)")
            XCTAssertEqual(d.height % 2, 0, "\(w)x\(h)")
            XCTAssertEqual(min(d.width, d.height), 1080, "\(w)x\(h)")
        }
    }

    func testTargetDimensionsLeaveSmallVideosAlone() {
        let d = VideoShrinkPlan.targetDimensions(width: 1280, height: 720)
        XCTAssertEqual(d.width, 1280)
        XCTAssertEqual(d.height, 720)
    }

    func testTargetSpecDropsFrameRateOnlyWhenNeeded() {
        XCTAssertEqual(VideoShrinkPlan.target(for: spec(3840, 2160, fps: 60)).fps, 30)
        XCTAssertEqual(VideoShrinkPlan.target(for: spec(3840, 2160, fps: 24)).fps, 24)
        XCTAssertNil(VideoShrinkPlan.target(for: spec(3840, 2160, fps: nil)).fps)
    }

    // MARK: - Size estimate

    func testEstimateIsDurationTimesTargetBitrate() {
        // 60 s at 10 Mbps = 75 MB.
        let est = VideoShrinkPlan.estimatedOutputBytes(for: spec(3840, 2160, seconds: 60, mb: 400))
        XCTAssertEqual(est, 75_000_000)
    }

    func testEstimateNeverExceedsOriginal() {
        let s = spec(3840, 2160, seconds: 60, mb: 20)
        XCTAssertEqual(VideoShrinkPlan.estimatedOutputBytes(for: s), s.fileBytes)
    }

    func testEstimateScalesDownForSlowFootage() {
        let at24 = VideoShrinkPlan.estimatedOutputBytes(for: spec(3840, 2160, fps: 24, seconds: 60))
        XCTAssertEqual(at24, 60_000_000)
    }

    func testCandidateSavings() {
        let c = VideoCandidate(id: "a", spec: spec(3840, 2160, seconds: 60, mb: 400), creationDate: nil)
        XCTAssertEqual(c.estimatedSavings, 325_000_000)
    }

    // MARK: - Labels

    func testLabels() {
        XCTAssertEqual(VideoShrinkPlan.resolutionLabel(spec(3840, 2160)), "4K")
        XCTAssertEqual(VideoShrinkPlan.resolutionLabel(spec(1440, 2560)), "1440p")
        XCTAssertEqual(VideoShrinkPlan.resolutionLabel(spec(1920, 1080)), "1080p")
        XCTAssertEqual(VideoShrinkPlan.fpsLabel(spec(1920, 1080, fps: 59.94)), "60 fps")
        XCTAssertNil(VideoShrinkPlan.fpsLabel(spec(1920, 1080, fps: nil)))
    }

    // MARK: - Sorting

    func testSortOrders() {
        let old = Date(timeIntervalSince1970: 0), new = Date(timeIntervalSince1970: 1_000)
        let big = VideoCandidate(id: "big", spec: spec(3840, 2160, seconds: 300, mb: 900), creationDate: old)
        let lean = VideoCandidate(id: "lean", spec: spec(3840, 2160, seconds: 10, mb: 950), creationDate: new)
        let mid = VideoCandidate(id: "mid", spec: spec(1920, 1080, fps: 60, seconds: 60, mb: 300), creationDate: nil)
        let all = [mid, big, lean]

        XCTAssertEqual(VideoSortOrder.largest.sorted(all).map(\.id), ["lean", "big", "mid"])
        XCTAssertEqual(VideoSortOrder.mostSavings.sorted(all).map(\.id), ["lean", "big", "mid"])
        XCTAssertEqual(VideoSortOrder.newest.sorted(all).map(\.id), ["lean", "big", "mid"])
        XCTAssertEqual(VideoSortOrder.oldest.sorted(all).map(\.id), ["big", "lean", "mid"])
    }
}
