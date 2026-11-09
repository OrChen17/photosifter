import SwiftUI

/// How far a control shrinks while the finger is down. Bigger surfaces move
/// less so a card press doesn't feel like a jump.
enum PressScale {
    static let control: CGFloat = 0.86
    static let thumbnail: CGFloat = 0.9
    static let card: CGFloat = 0.96
}

/// Shared press-down feel for every tappable surface: shrinks on touch-down,
/// springs back on release. Reduce Motion keeps the dim but drops the scale.
struct PressScaleButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = PressScale.control

    func makeBody(configuration: Configuration) -> some View {
        PressScaleBody(configuration: configuration, pressedScale: pressedScale)
    }
}

private struct PressScaleBody: View {
    let configuration: ButtonStyleConfiguration
    let pressedScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(
                configuration.isPressed
                    ? .easeOut(duration: 0.08)
                    : .spring(response: 0.35, dampingFraction: 0.55),
                value: configuration.isPressed
            )
    }
}

extension View {
    /// Liquid Glass on iOS 26, a material surface before that. Use for controls
    /// that float over content (buttons, chips, overlays), not for content cards.
    func appGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(AppGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }
}

private struct AppGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background {
                    if let tint {
                        shape.fill(tint)
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                }
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
    }
}
