import SwiftUI

extension Color {
    static let appBackground   = Color(hex: "0A0A0F")
    static let appCard         = Color(hex: "1C1C24")
    static let appKeep         = Color(hex: "22D3EE")
    static let appDelete       = Color(hex: "FF2D78")
    static let appAccent       = Color(hex: "FF2D78")
    /// Triadic-yellow companion to appKeep (cyan) / appDelete (pink). Used by
    /// the revert/undo affordance so the action reads as a "warning, take it back".
    static let appRevert       = Color(hex: "FFD60A")
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
    static var appDelete: Color          { Color.appDelete }
    static var appAccent: Color          { Color.appAccent }
    static var appRevert: Color          { Color.appRevert }
    static var appTextSecondary: Color   { Color.appTextSecondary }
}
