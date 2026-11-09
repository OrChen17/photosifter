import SwiftUI

extension View {
    /// Liquid Glass on iOS 26, a thin material with a hairline on older systems.
    /// `tint` colours the glass; leave it nil for the clear, neutral look.
    @ViewBuilder
    func appGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = true
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.35)) }
                }
                .overlay(shape.strokeBorder(Color.appForeground.opacity(0.08), lineWidth: 1))
        }
    }

    @available(iOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Groups glass shapes so they blend and morph into each other on iOS 26.
/// A plain container on older systems.
struct AppGlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

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

