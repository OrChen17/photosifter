import SwiftUI

struct DecisionBadgeView: View {
    enum Kind { case keep, delete }

    let kind: Kind
    let opacity: Double
    var label: String? = nil

    var body: some View {
        Text(label ?? (kind == .keep ? "KEEP" : "DELETE"))
            .font(.system(size: 28, weight: .black, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white, lineWidth: 3)
            )
            .rotationEffect(kind == .keep ? .degrees(-15) : .degrees(15))
            .opacity(opacity)
    }
}
