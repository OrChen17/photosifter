import SwiftUI

extension Color {
    static let appBackground   = Color(hex: "0A0A0F")
    static let appCard         = Color(hex: "1C1C24")
    static let appKeep         = Color(hex: "22D3EE")
    static let appKeepDeep     = Color(hex: "06B6D4")
    /// Text and glyphs drawn on an appKeep fill. Cyan is too light for white.
    static let appOnKeep       = Color(hex: "083344")
    static let appDelete      = Color(hex: "FF2D78")
    /// Lime third of the cyan / magenta / lime triad. Owns progress and wins
    /// (progress bars, primary CTAs, space saved), never a keep/delete decision.
    static let appAccent       = Color(hex: "A3E635")
    static let appAccentDeep   = Color(hex: "84CC16")
    /// Text and glyphs drawn on an appAccent fill. Lime is too light for white.
    static let appOnAccent     = Color(hex: "1A2E05")
    /// Neutral so undo never competes with the keep / delete / progress hues.
    static let appRevert       = Color(white: 0.92)
    static let appTextSecondary = Color(white: 0.55)

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension ShapeStyle where Self == Color {
    static var appBackground: Color      { Color.appBackground }
    static var appCard: Color            { Color.appCard }
    static var appKeep: Color            { Color.appKeep }
    static var appKeepDeep: Color        { Color.appKeepDeep }
    static var appOnKeep: Color          { Color.appOnKeep }
    static var appDelete: Color          { Color.appDelete }
    static var appAccent: Color          { Color.appAccent }
    static var appAccentDeep: Color      { Color.appAccentDeep }
    static var appOnAccent: Color        { Color.appOnAccent }
    static var appRevert: Color          { Color.appRevert }
    static var appTextSecondary: Color   { Color.appTextSecondary }
}
