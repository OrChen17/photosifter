import SwiftUI

/// Glass chip that grows in at the card's edge while the user drags toward a
/// decision. Replaces the rotated stamp look with FlickPic's own: tinted
/// glass plus an icon, upright, scaling in with the drag.
struct DecisionBadgeView: View {
    enum Kind { case keep, delete, skip }

    let kind: Kind
    let opacity: Double
    var label: String? = nil

    private var defaultLabel: String {
        switch kind {
        case .keep: CardActionName.keep
        case .delete: CardActionName.delete
        case .skip: CardActionName.skip
        }
    }

    private var icon: String {
        switch kind {
        case .keep: "heart.fill"
        case .delete: "xmark"
        case .skip: "arrow.up"
        }
    }

    private var tint: Color? {
        switch kind {
        case .keep: .appKeepFill
        case .delete: .appDelete
        case .skip: nil
        }
    }

    private var foreground: Color {
        kind == .keep ? .appOnKeep : .white
    }

    var body: some View {
        HStack(spacing: 6) {
            if label == nil {
                Image(systemName: icon)
                    .font(.system(.subheadline, weight: .heavy))
            }
            Text(label ?? defaultLabel)
                .font(.system(.title3, design: .rounded, weight: .heavy))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .appGlass(in: Capsule(style: .continuous), tint: tint, interactive: false)
        .scaleEffect(0.8 + 0.2 * opacity)
        .opacity(opacity)
    }
}
