import SwiftUI

extension Color {
    static let appBackground   = Color(hex: "0A0A0F")
    static let appCard         = Color(hex: "1C1C24")
    static let appKeep         = Color(hex: "34C759")
    static let appDelete       = Color(hex: "FF3B30")
    static let appAccent       = Color(hex: "6C63FF")
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
