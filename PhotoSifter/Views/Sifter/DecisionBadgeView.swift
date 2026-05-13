import SwiftUI

struct DecisionBadgeView: View {
    enum Kind { case keep, delete }

    let kind: Kind
    let opacity: Double

    var body: some View {
        Text(kind == .keep ? "KEEP" : "DELETE")
            .font(.system(size: 28, weight: .black, design: .rounded))
            .foregroundStyle(kind == .keep ? Color.appKeep : Color.appDelete)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(kind == .keep ? Color.appKeep : Color.appDelete, lineWidth: 3)
            )
            .rotationEffect(kind == .keep ? .degrees(-15) : .degrees(15))
            .opacity(opacity)
    }
}
