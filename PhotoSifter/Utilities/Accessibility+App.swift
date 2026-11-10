import SwiftUI

extension View {
    /// Turns a card into one button: a single VoiceOver element plus the shared
    /// press-down shrink (`PressScaleButtonStyle`).
    /// Without `label`, VoiceOver reads the card's own text.
    func cardButton(
        label: String? = nil,
        hint: String? = nil,
        pressedScale: CGFloat = PressScale.card,
        action: @escaping () -> Void
    ) -> some View {
        modifier(CardButtonModifier(label: label, hint: hint, pressedScale: pressedScale, action: action))
    }
}

private struct CardButtonModifier: ViewModifier {
    let label: String?
    let hint: String?
    let pressedScale: CGFloat
    let action: () -> Void

    func body(content: Content) -> some View {
        let element = Button(action: action) { content.contentShape(Rectangle()) }
            .buttonStyle(PressScaleButtonStyle(pressedScale: pressedScale))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(hint ?? "")
        if let label {
            element.accessibilityLabel(label)
        } else {
            element
        }
    }
}

enum StripAccessibility {
    static func label(
        position: Int, count: Int, decision: Decision?, isCurrent: Bool, mark: String? = nil
    ) -> String {
        var parts = [String(localized: "Photo \(position) of \(count)")]
        switch decision {
        case .keep: parts.append(String(localized: "kept"))
        case .delete: parts.append(String(localized: "marked for delete"))
        case nil: break
        }
        if let mark { parts.append(mark) }
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
