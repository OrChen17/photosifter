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
