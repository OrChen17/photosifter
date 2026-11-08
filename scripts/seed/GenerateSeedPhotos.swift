// Generates the 100 predefined seed photos used by scripts/seed-simulator.sh.
// Output is deterministic: same files, same EXIF dates, every run.
//
// Usage: swift scripts/seed/GenerateSeedPhotos.swift <output-dir>

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Dates

func formatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = format
    return f
}

let inputFormatter = formatter("yyyy-MM-dd HH:mm:ss")
let exifFormatter = formatter("yyyy:MM:dd HH:mm:ss")

func parse(_ s: String) -> Date {
    guard let d = inputFormatter.date(from: s) else { fatalError("bad date \(s)") }
    return d
}

func dateString(from date: Date) -> String {
    inputFormatter.string(from: date)
}

enum Kind: String {
    case similar
    case duplicate
    case screenshot
    case single
}

struct Scene {
    let name: String
    let kind: Kind
    let count: Int
    let start: String
    let spacing: TimeInterval
    let hue: Double
}

struct Shot {
    let scene: Scene
    let index: Int
    let date: Date
}

// Near-duplicate bursts: photos 2–6s apart, each scene on its own day.
// On the simulator, DebugTimeProximitySimilarity groups anything ≤ 30s apart.
let similarScenes: [Scene] = [
    Scene(name: "Beach Sunset", kind: .similar, count: 2, start: "2026-03-02 18:40:00", spacing: 3, hue: 0.06),
    Scene(name: "Latte Art", kind: .similar, count: 2, start: "2026-03-09 09:15:00", spacing: 2, hue: 0.09),
    Scene(name: "Dog Park", kind: .similar, count: 3, start: "2026-03-16 16:05:00", spacing: 4, hue: 0.28),
    Scene(name: "Mountain Lake", kind: .similar, count: 3, start: "2026-04-04 11:30:00", spacing: 5, hue: 0.55),
    Scene(name: "Birthday Cake", kind: .similar, count: 4, start: "2026-04-18 20:10:00", spacing: 2, hue: 0.92),
    Scene(name: "City Night", kind: .similar, count: 4, start: "2026-05-01 22:45:00", spacing: 3, hue: 0.68),
    Scene(name: "Forest Trail", kind: .similar, count: 5, start: "2026-05-17 10:20:00", spacing: 4, hue: 0.36),
    Scene(name: "Concert", kind: .similar, count: 5, start: "2026-06-06 21:30:00", spacing: 2, hue: 0.80),
    Scene(name: "Family Dinner", kind: .similar, count: 6, start: "2026-06-21 19:00:00", spacing: 3, hue: 0.03),
    Scene(name: "Snow Day", kind: .similar, count: 7, start: "2026-07-12 13:15:00", spacing: 2, hue: 0.58),
    Scene(name: "Soccer Match", kind: .similar, count: 8, start: "2026-08-09 17:40:00", spacing: 2, hue: 0.33),
    Scene(name: "Wedding Toast", kind: .similar, count: 10, start: "2026-09-05 15:25:00", spacing: 2, hue: 0.14),
]

// Byte-identical copies: one file written, then copied. Exact-duplicate Quick Win.
let duplicateScenes: [Scene] = [
    Scene(name: "Receipt", kind: .duplicate, count: 2, start: "2026-03-23 12:00:00", spacing: 0, hue: 0.12),
    Scene(name: "Funny Meme", kind: .duplicate, count: 2, start: "2026-05-24 08:30:00", spacing: 0, hue: 0.47),
    Scene(name: "Parking Spot", kind: .duplicate, count: 2, start: "2026-07-26 14:50:00", spacing: 0, hue: 0.62),
    Scene(name: "Wallpaper", kind: .duplicate, count: 3, start: "2026-09-20 10:10:00", spacing: 0, hue: 0.74),
]

// PNGs at the iPhone 17 Pro screen size, tagged "Screenshot" in EXIF UserComment.
let screenshotScenes: [Scene] = [
    Scene(name: "Screenshot", kind: .screenshot, count: 12, start: "2026-03-05 10:00:00", spacing: 7 * 86_400 + 3_600, hue: 0.60),
]

// Unique moments, at least 9 hours apart. Never grouped.
let singleNames = [
    "Bike Ride", "Bookshelf", "Street Art", "Sunrise", "Garden", "Market", "Bridge", "Train Window",
    "Pizza", "Museum", "Harbor", "Rooftop", "Rainy Window", "Picnic", "Lighthouse", "Desert Road",
    "Ferris Wheel", "Library", "Night Sky", "Autumn Leaves",
]
let singleScenes: [Scene] = singleNames.enumerated().map { i, name in
    Scene(
        name: name,
        kind: .single,
        count: 1,
        start: dateString(from: parse("2026-03-03 08:00:00").addingTimeInterval(Double(i) * 9.5 * 86_400 + Double(i % 3) * 3_600)),
        spacing: 0,
        hue: Double(i) / Double(singleNames.count)
    )
}

let allScenes = similarScenes + duplicateScenes + screenshotScenes + singleScenes

// MARK: - Deterministic RNG

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func seed(for name: String) -> UInt64 {
    name.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
}

// MARK: - Drawing

func color(_ h: Double, _ s: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    let h6 = (h.truncatingRemainder(dividingBy: 1)) * 6
    let c = b * s
    let x = c * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1))
    let m = b - c
    let (r, g, bl): (Double, Double, Double)
    switch Int(h6) {
    case 0: (r, g, bl) = (c, x, 0)
    case 1: (r, g, bl) = (x, c, 0)
    case 2: (r, g, bl) = (0, c, x)
    case 3: (r, g, bl) = (0, x, c)
    case 4: (r, g, bl) = (x, 0, c)
    default: (r, g, bl) = (c, 0, x)
    }
    return CGColor(srgbRed: r + m, green: g + m, blue: bl + m, alpha: a)
}

func drawText(_ text: String, in ctx: CGContext, x: CGFloat, y: CGFloat, size: CGFloat, alpha: CGFloat = 1) {
    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

func makeContext(width: Int, height: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("no context") }
    return ctx
}

func renderPhoto(_ shot: Shot) -> CGImage {
    let w = 1200, h = 1600
    let ctx = makeContext(width: w, height: h)
    var rng = SplitMix64(state: seed(for: shot.scene.name))
    let hue = shot.scene.hue
    let jitter = CGFloat(shot.index) * 14

    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(hue, 0.55, 0.95), color(hue + 0.08, 0.75, 0.45)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: 0), options: [])

    let sunX = CGFloat.random(in: 250...950, using: &rng) + jitter
    let sunY = CGFloat.random(in: 1000...1350, using: &rng) - jitter * 0.6
    ctx.setFillColor(color(hue + 0.5, 0.35, 1, 0.9))
    ctx.fillEllipse(in: CGRect(x: sunX - 140, y: sunY - 140, width: 280, height: 280))

    for _ in 0..<9 {
        let bw = CGFloat.random(in: 90...260, using: &rng)
        let bh = CGFloat.random(in: 200...700, using: &rng)
        let bx = CGFloat.random(in: -60...CGFloat(w), using: &rng) - jitter * 0.4
        let shade = Double.random(in: 0.15...0.45, using: &rng)
        ctx.setFillColor(color(hue + 0.02, 0.5, shade))
        ctx.fill(CGRect(x: bx, y: 0, width: bw, height: bh))
    }

    ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: 260))
    drawText(shot.scene.name, in: ctx, x: 60, y: 140, size: 84)
    let subtitle: String
    switch shot.scene.kind {
    case .similar: subtitle = "similar \(shot.index + 1)/\(shot.scene.count)"
    case .duplicate: subtitle = "exact duplicate ×\(shot.scene.count)"
    case .single: subtitle = "single"
    case .screenshot: subtitle = "screenshot"
    }
    drawText("\(subtitle)  ·  \(dateString(from: shot.date))", in: ctx, x: 60, y: 60, size: 40, alpha: 0.85)

    guard let image = ctx.makeImage() else { fatalError("render failed") }
    return image
}

let screenshotApps = ["Messages", "Maps", "Weather", "Notes", "Calendar", "Music", "Mail", "Settings", "Safari", "Stocks", "Wallet", "Clock"]

func renderScreenshot(_ shot: Shot) -> CGImage {
    let w = 1206, h = 2622
    let ctx = makeContext(width: w, height: h)
    let hue = Double(shot.index) / Double(screenshotApps.count)
    ctx.setFillColor(color(hue, 0.08, 0.97))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(color(hue, 0.7, 0.85))
    ctx.fill(CGRect(x: 0, y: h - 420, width: w, height: 420))
    drawText(screenshotApps[shot.index % screenshotApps.count], in: ctx, x: 70, y: CGFloat(h - 330), size: 96)

    var rng = SplitMix64(state: seed(for: "shot\(shot.index)"))
    var y = CGFloat(h - 560)
    while y > 200 {
        let lineW = CGFloat.random(in: 380...1050, using: &rng)
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 0.35))
        ctx.fill(CGRect(x: 70, y: y, width: lineW, height: 56))
        y -= CGFloat.random(in: 110...170, using: &rng)
    }
    guard let image = ctx.makeImage() else { fatalError("render failed") }
    return image
}

// MARK: - Writing

func write(_ image: CGImage, to url: URL, type: UTType, date: Date, userComment: String?) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        fatalError("cannot create \(url.path)")
    }
    let stamp = exifFormatter.string(from: date)
    var exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: stamp,
        kCGImagePropertyExifDateTimeDigitized: stamp,
    ]
    if let userComment { exif[kCGImagePropertyExifUserComment] = userComment }
    let props: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: stamp],
        kCGImageDestinationLossyCompressionQuality: 0.82,
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("write failed \(url.path)") }
}

func slug(_ s: String) -> String {
    s.lowercased().replacingOccurrences(of: " ", with: "-")
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: GenerateSeedPhotos.swift <output-dir>\n".data(using: .utf8)!)
    exit(64)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var written = 0
for scene in allScenes {
    let base = parse(scene.start)
    switch scene.kind {
    case .duplicate:
        let shot = Shot(scene: scene, index: 0, date: base)
        let first = outDir.appendingPathComponent("\(scene.kind.rawValue)-\(slug(scene.name))-1.jpg")
        write(renderPhoto(shot), to: first, type: .jpeg, date: base, userComment: nil)
        for copy in 2...scene.count {
            let dst = outDir.appendingPathComponent("\(scene.kind.rawValue)-\(slug(scene.name))-\(copy).jpg")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: first, to: dst)
        }
        written += scene.count
    case .screenshot:
        for i in 0..<scene.count {
            let date = base.addingTimeInterval(Double(i) * scene.spacing)
            let shot = Shot(scene: scene, index: i, date: date)
            let url = outDir.appendingPathComponent(String(format: "screenshot-%02d-%@.png", i + 1, slug(screenshotApps[i])))
            write(renderScreenshot(shot), to: url, type: .png, date: date, userComment: "Screenshot")
            written += 1
        }
    case .similar, .single:
        for i in 0..<scene.count {
            let date = base.addingTimeInterval(Double(i) * scene.spacing)
            let shot = Shot(scene: scene, index: i, date: date)
            let suffix = scene.count > 1 ? "-\(i + 1)" : ""
            let url = outDir.appendingPathComponent("\(scene.kind.rawValue)-\(slug(scene.name))\(suffix).jpg")
            write(renderPhoto(shot), to: url, type: .jpeg, date: date, userComment: nil)
            written += 1
        }
    }
}

let groupCount = similarScenes.count + duplicateScenes.count
print("wrote \(written) photos to \(outDir.path)")
print("expected in app: \(groupCount) groups in the grid (\(similarScenes.count) similar + \(duplicateScenes.count) duplicate sets), \(duplicateScenes.count) duplicate Quick Wins, 1 screenshot Quick Win (\(screenshotScenes[0].count)), \(singleScenes.count) singles")
