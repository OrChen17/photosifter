import SwiftUI

extension Font.TextStyle {
    static let defaultPointSizes: [(style: Font.TextStyle, size: CGFloat)] = [
        (.caption2, 11),
        (.caption, 12),
        (.footnote, 13),
        (.subheadline, 15),
        (.callout, 16),
        (.body, 17),
        (.title3, 20),
        (.title2, 22),
        (.title, 28),
        (.largeTitle, 34),
    ]

    static func nearest(to size: CGFloat) -> Font.TextStyle {
        defaultPointSizes.first { size <= $0.size }?.style ?? .largeTitle
    }
}

extension View {
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design))
    }
}

private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: Font.TextStyle.nearest(to: size))
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}
