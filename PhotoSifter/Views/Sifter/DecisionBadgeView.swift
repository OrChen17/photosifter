import SwiftUI

struct DecisionBadgeView: View {
    enum Kind { case keep, delete, skip }

    let kind: Kind
    let opacity: Double
    var label: String? = nil
    var tint: Color? = nil

    private var defaultLabel: String {
        switch kind {
        case .keep: CardActionName.keep
        case .delete: CardActionName.delete
        case .skip: CardActionName.skip
        }
    }

    private var glow: Color {
        switch kind {
        case .keep: .appKeep
        case .delete: .appDelete
        case .skip: .white
        }
    }

    var body: some View {
        Text((label ?? defaultLabel).uppercased())
            .font(.system(.title2, design: .rounded, weight: .black))
            .tracking(1.5)
            .foregroundStyle(.white)
            .shadow(color: (tint ?? glow).opacity(0.9), radius: 10)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .opacity(opacity)
    }
}
