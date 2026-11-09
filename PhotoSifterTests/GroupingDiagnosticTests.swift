import XCTest
import Photos
import Vision
@testable import PhotoSifter

/// End-to-end diagnostic: walks the entire grouping pipeline against the
/// simulator's actual photo library and prints what is happening at each
/// stage. Use this to figure out *why* no groups are being emitted.
///
/// Run with:
///   xcodebuild test \
///     -project PhotoSifter.xcodeproj \
///     -scheme PhotoSifter \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///     -only-testing:PhotoSifterTests/GroupingDiagnosticTests
final class GroupingDiagnosticTests: XCTestCase {

    /// Sanity-check that Vision feature print works on this host at all,
    /// independent of Photos / image loading. If this fails on simulator
    /// the entire pipeline is dead because clusterBucket silently swallows
    /// feature-print errors via `try?`.
    func testVisionAlone_canComputeFeaturePrintOnBlankImage() async throws {
        // Render a small solid-color CGImage so there is no Photos dependency.
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                            bytesPerRow: 64*4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.7, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let img = ctx.makeImage()!

        for rev in [VNGenerateImageFeaturePrintRequestRevision1,
                    VNGenerateImageFeaturePrintRequestRevision2] {
            do {
                let p: VNFeaturePrintObservation = try await withCheckedThrowingContinuation { cont in
                    final class Once { var fired = false }
                    let once = Once()
                    func resume(_ r: Result<VNFeaturePrintObservation, Error>) {
                        guard !once.fired else { return }
                        once.fired = true
                        switch r {
                        case .success(let v): cont.resume(returning: v)
                        case .failure(let e): cont.resume(throwing: e)
                        }
                    }
                    let request = VNGenerateImageFeaturePrintRequest { req, err in
                        if let err { resume(.failure(err)); return }
                        guard let r = req.results?.first as? VNFeaturePrintObservation else {
                            resume(.failure(SimilarityError.noFeaturePrint)); return
                        }
                        resume(.success(r))
                    }
                    request.revision = rev
                    let h = VNImageRequestHandler(cgImage: img)
                    do { try h.perform([request]) }
                    catch { resume(.failure(error)) }
                }
                print("VISION rev=\(rev) ✓ elementCount=\(p.elementCount) type=\(p.elementType.rawValue)")
            } catch {
                print("VISION rev=\(rev) ✗ \(error)")
            }
        }
    }

    func testDiagnose_endToEnd() async throws {
        try requireRealVision()
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        print("AUTH status: \(status.rawValue) (\(status))")
        try XCTSkipIf(
            status == .denied || status == .restricted,
            "Photo library access denied — grant Photos to the test host."
        )

        // ---------- Stage 1: fetch all assets ----------
        let allAssets = await PhotoLibraryService.shared.fetchAllAssets()
        print("STAGE 1 — fetchAllAssets returned \(allAssets.count) assets")
        for (i, a) in allAssets.prefix(20).enumerated() {
            print("  [\(i)] id=\(a.localIdentifier.prefix(8))… "
                + "date=\(a.creationDate.map(String.init(describing:)) ?? "nil") "
                + "burst=\(a.representsBurst) burstID=\(a.burstIdentifier ?? "nil") "
                + "size=\(a.pixelWidth)x\(a.pixelHeight)")
        }
        XCTAssertGreaterThan(allAssets.count, 0, "Simulator has no photos — addmedia first")

        // ---------- Stage 2: time-bucket split ----------
        let buckets = GroupingService.splitIntoBuckets(allAssets)
        print("STAGE 2 — splitIntoBuckets produced \(buckets.count) buckets (≥2 assets each)")
        for (i, b) in buckets.enumerated() {
            let first = b.first?.creationDate.map(String.init(describing:)) ?? "nil"
            let last = b.last?.creationDate.map(String.init(describing:)) ?? "nil"
            print("  bucket[\(i)] count=\(b.count) first=\(first) last=\(last)")
        }

        // ---------- Stage 3: image load + feature print ----------
        // Limit to the first bucket (or first 10 assets) to keep test time bounded
        let probe = Array((buckets.first ?? allAssets).prefix(10))
        print("STAGE 3 — probing \(probe.count) assets for feature prints")
        var prints: [(PHAsset, VNFeaturePrintObservation)] = []
        for asset in probe {
            do {
                let p = try await SimilarityService.shared.featurePrint(for: asset)
                prints.append((asset, p))
                print("  ✓ \(asset.localIdentifier.prefix(8))… "
                    + "elementCount=\(p.elementCount) "
                    + "type=\(p.elementType.rawValue)")
            } catch {
                print("  ✗ \(asset.localIdentifier.prefix(8))… FAILED: \(error)")
            }
        }

        XCTAssertGreaterThan(
            prints.count, 0,
            "No feature prints could be computed. Image loading is broken — check isNetworkAccessAllowed / PHPhotosErrorDomain 3303 in the log."
        )

        // ---------- Stage 4: all-pairs distances ----------
        print("STAGE 4 — pairwise distances (threshold = 0.65, smaller = more similar)")
        struct Pair { let i: Int; let j: Int; let dist: Float }
        var pairs: [Pair] = []
        for i in 0..<prints.count {
            for j in (i+1)..<prints.count {
                if let d = try? await SimilarityService.shared.distance(from: prints[i].1, to: prints[j].1) {
                    pairs.append(Pair(i: i, j: j, dist: d))
                }
            }
        }
        let sorted = pairs.sorted { $0.dist < $1.dist }
        for p in sorted.prefix(20) {
            let mark = p.dist < 0.65 ? "← under threshold" : ""
            print(String(format: "  [%d,%d] dist=%.4f %@", p.i, p.j, p.dist, mark))
        }
        let underThreshold = pairs.filter { $0.dist < 0.65 }.count
        print("STAGE 4 — \(underThreshold) of \(pairs.count) pairs are under threshold 0.65")

        // ---------- Stage 5: actual streamGroups ----------
        print("STAGE 5 — running streamGroups on all \(allAssets.count) assets")
        var streamedGroups: [PhotoGroup] = []
        for await g in await GroupingService.shared.streamGroups(from: allAssets) {
            streamedGroups.append(g)
            print("  + group of \(g.assets.count) (first id=\(g.assets.first?.localIdentifier.prefix(8) ?? "nil")…)")
        }
        print("STAGE 5 — streamGroups emitted \(streamedGroups.count) total groups")

        // Final assertion is loose — we just want the diagnostic output.
        // If everything's wired right and the simulator photos are similar,
        // we expect at least one group. If not, the printout above tells us why.
        if streamedGroups.isEmpty {
            XCTFail("No groups emitted. See stage-by-stage output above for the failure point.")
        }
    }
}
