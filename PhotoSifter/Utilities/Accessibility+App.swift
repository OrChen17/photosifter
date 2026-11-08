import SwiftUI

extension View {
    /// Turns a tap-gesture card into one VoiceOver button. Used where a real
    /// `Button` would lose its tap to a surrounding scroll view.
    /// Without `label`, VoiceOver reads the card's own text.
    func cardButton(
        label: String? = nil,
        hint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        modifier(CardButtonModifier(label: label, hint: hint, action: action))
    }
}

private struct CardButtonModifier: ViewModifier {
    let label: String?
    let hint: String?
    let action: () -> Void

    func body(content: Content) -> some View {
        let element = content
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .accessibilityHint(hint ?? "")
        if let label {
            element.accessibilityLabel(label)
        } else {
            element
        }
    }
}

enum StripAccessibility {
    static func label(position: Int, count: Int, decision: Decision?, isCurrent: Bool) -> String {
        var parts = [String(localized: "Photo \(position) of \(count)")]
        switch decision {
        case .keep: parts.append(String(localized: "kept"))
        case .delete: parts.append(String(localized: "marked for delete"))
        case nil: break
        }
        if isCurrent { parts.append(String(localized: "current")) }
        return parts.joined(separator: ", ")
    }
}

extension AnyTransition {
    /// Scale-and-fade for overlays. With Reduce Motion on, a plain crossfade.
    static func scaleFade(_ scale: CGFloat, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: scale, anchor: .center).combined(with: .opacity)
    }
}
