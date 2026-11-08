import SwiftUI
import UIKit

extension Color {
    static let appBackground   = Color(light: "F2F2F7", dark: "0A0A0F")
    static let appCard         = Color(light: "FFFFFF", dark: "1C1C24")
    /// Primary text and the base for hairlines / tracks (use with `.opacity`).
    /// White on dark, near-black on light. Keep plain `.white` for content that
    /// sits on a photo or an accent gradient.
    static let appForeground   = Color(light: "0A0A0F", dark: "FFFFFF")
    static let appKeep         = Color(light: "0891B2", dark: "22D3EE")
    static let appKeepGlow     = Color(light: "22D3EE", dark: "67E8F9")
    static let appDelete       = Color(hex: "FF2D78")
    static let appAccent       = Color(hex: "FF2D78")
    /// Triadic-yellow companion to appKeep (cyan) / appDelete (pink). Used by
    /// the revert/undo affordance so the action reads as a "warning, take it back".
    static let appRevert       = Color(light: "CA8A04", dark: "FFD60A")
    static let appTextSecondary = Color(light: "6B6B73", dark: "8C8C8C")

    init(hex: String) {
        let (r, g, b) = Self.rgb(hex)
        self.init(red: r, green: g, blue: b)
    }

    init(light: String, dark: String) {
        let lightColor = Self.uiColor(light)
        let darkColor = Self.uiColor(dark)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
    }

    private static func uiColor(_ hex: String) -> UIColor {
        let (r, g, b) = rgb(hex)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    private static func rgb(_ hex: String) -> (Double, Double, Double) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        return (r, g, b)
    }
}

extension ShapeStyle where Self == Color {
    static var appBackground: Color      { Color.appBackground }
    static var appCard: Color            { Color.appCard }
    static var appForeground: Color      { Color.appForeground }
    static var appKeep: Color            { Color.appKeep }
    static var appKeepGlow: Color        { Color.appKeepGlow }
    static var appDelete: Color          { Color.appDelete }
    static var appAccent: Color          { Color.appAccent }
    static var appRevert: Color          { Color.appRevert }
    static var appTextSecondary: Color   { Color.appTextSecondary }
}
