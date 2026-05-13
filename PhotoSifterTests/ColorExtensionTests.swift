import XCTest
import SwiftUI
@testable import PhotoSifter

final class ColorExtensionTests: XCTestCase {

    // MARK: - Hex parsing

    func testHexParsing_black() {
        let color = Color(hex: "000000")
        assertRGB(color, r: 0, g: 0, b: 0)
    }

    func testHexParsing_white() {
        let color = Color(hex: "FFFFFF")
        assertRGB(color, r: 1, g: 1, b: 1)
    }

    func testHexParsing_red() {
        let color = Color(hex: "FF0000")
        assertRGB(color, r: 1, g: 0, b: 0)
    }

    func testHexParsing_green() {
        let color = Color(hex: "00FF00")
        assertRGB(color, r: 0, g: 1, b: 0)
    }

    func testHexParsing_blue() {
        let color = Color(hex: "0000FF")
        assertRGB(color, r: 0, g: 0, b: 1)
    }

    func testHexParsing_appBackground() {
        let color = Color(hex: "0A0A0F")
        let r = 0x0A / 255.0
        let b = 0x0F / 255.0
        assertRGB(color, r: r, g: r, b: b)
    }

    func testHexParsing_appKeepGreen() {
        let color = Color(hex: "34C759")
        assertRGB(color, r: 0x34 / 255.0, g: 0xC7 / 255.0, b: 0x59 / 255.0)
    }

    func testHexParsing_appDeleteRed() {
        let color = Color(hex: "FF3B30")
        assertRGB(color, r: 1.0, g: 0x3B / 255.0, b: 0x30 / 255.0)
    }

    func testHexParsing_hashPrefixStripped() {
        let withHash    = Color(hex: "#FF0000")
        let withoutHash = Color(hex: "FF0000")
        assertRGB(withHash, r: 1, g: 0, b: 0)
        assertRGB(withoutHash, r: 1, g: 0, b: 0)
    }

    func testHexParsing_lowercaseAccepted() {
        let lower = Color(hex: "ff3b30")
        let upper = Color(hex: "FF3B30")
        assertRGB(lower, r: resolved(upper).red, g: resolved(upper).green, b: resolved(upper).blue)
    }

    // MARK: - Static token constants exist

    func testStaticTokens_compileAndAreNonNil() {
        // Verifies the static properties are defined and accessible
        _ = Color.appBackground
        _ = Color.appCard
        _ = Color.appKeep
        _ = Color.appDelete
        _ = Color.appAccent
        _ = Color.appTextSecondary
    }

    // MARK: - Helpers

    private func resolved(_ color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }

    private func assertRGB(
        _ color: Color,
        r: CGFloat, g: CGFloat, b: CGFloat,
        accuracy: CGFloat = 0.004,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let c = resolved(color)
        XCTAssertEqual(c.red,   r, accuracy: accuracy, "Red component mismatch",   file: file, line: line)
        XCTAssertEqual(c.green, g, accuracy: accuracy, "Green component mismatch", file: file, line: line)
        XCTAssertEqual(c.blue,  b, accuracy: accuracy, "Blue component mismatch",  file: file, line: line)
    }
}
