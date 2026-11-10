import SwiftUI

/// Filmstrip with a handle on each end and a playhead. Dragging a handle trims
/// that end; dragging on the strip moves through the video. Both report the
/// time under the finger so the player can show that frame.
struct VideoTrimBar: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let thumbnails: [UIImage]
    let playhead: Double
    let onScrub: (Double) -> Void

    static let minimumLength = 1.0
    private static let handleWidth: CGFloat = 20
    private static let barHeight: CGFloat = 56
    private static let cornerRadius: CGFloat = 10
    private static let accessibilityStep = 1.0
    private static let playheadWidth: CGFloat = 3

    @State private var startDragOrigin: Double?
    @State private var endDragOrigin: Double?

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let track = max(1, geo.size.width - Self.handleWidth * 2)
                let startX = CGFloat(start / safeDuration) * track
                let endX = CGFloat(end / safeDuration) * track

                ZStack(alignment: .leading) {
                    filmstrip
                        .frame(width: track, height: Self.barHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0).onChanged { value in
                                let time = Double(value.location.x / track) * safeDuration
                                onScrub(min(max(start, time), end))
                            }
                        )
                        .offset(x: Self.handleWidth)
                        .accessibilityHidden(true)

                    Color.appBackground.opacity(0.7)
                        .frame(width: startX, height: Self.barHeight)
                        .offset(x: Self.handleWidth)
                    Color.appBackground.opacity(0.7)
                        .frame(width: max(0, track - endX), height: Self.barHeight)
                        .offset(x: Self.handleWidth + endX)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: Self.playheadWidth, height: Self.barHeight - 10)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .offset(x: Self.handleWidth + playheadX(track: track) - Self.playheadWidth / 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(Color.appKeep, lineWidth: 3)
                        .frame(width: endX - startX + Self.handleWidth * 2, height: Self.barHeight)
                        .offset(x: startX)
                        .allowsHitTesting(false)

                    handle(systemImage: "chevron.compact.left")
                        .offset(x: startX)
                        .gesture(drag(origin: $startDragOrigin, current: start, track: track, apply: setStart))
                        .accessibilityLabel(String(localized: "Trim start"))
                        .accessibilityValue(VideoFormat.duration(start))
                        .accessibilityAdjustableAction { direction in
                            setStart(start + (direction == .increment ? Self.accessibilityStep : -Self.accessibilityStep))
                        }

                    handle(systemImage: "chevron.compact.right")
                        .offset(x: endX + Self.handleWidth)
                        .gesture(drag(origin: $endDragOrigin, current: end, track: track, apply: setEnd))
                        .accessibilityLabel(String(localized: "Trim end"))
                        .accessibilityValue(VideoFormat.duration(end))
                        .accessibilityAdjustableAction { direction in
                            setEnd(end + (direction == .increment ? Self.accessibilityStep : -Self.accessibilityStep))
                        }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            }
            .frame(height: Self.barHeight)

            HStack {
                Text(VideoFormat.duration(start))
                Spacer()
                Text(VideoFormat.duration(end - start))
                    .foregroundStyle(.appForeground)
                    .fontWeight(.semibold)
                Spacer()
                Text(VideoFormat.duration(end))
            }
            .font(.system(.caption, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.appTextSecondary)
        }
    }

    private var safeDuration: Double { max(duration, 0.001) }

    private func playheadX(track: CGFloat) -> CGFloat {
        CGFloat(min(max(start, playhead), end) / safeDuration) * track
    }

    private var minimumLength: Double { min(Self.minimumLength, duration) }

    private var filmstrip: some View {
        HStack(spacing: 0) {
            if thumbnails.isEmpty {
                Color.appCard
            } else {
                ForEach(thumbnails.indices, id: \.self) { index in
                    Color.clear
                        .overlay {
                            Image(uiImage: thumbnails[index])
                                .resizable()
                                .scaledToFill()
                        }
                        .clipped()
                }
            }
        }
    }

    private func handle(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(.body, weight: .bold))
            .foregroundStyle(.appOnKeep)
            .frame(width: Self.handleWidth, height: Self.barHeight)
            .background(Color.appKeep)
            .contentShape(Rectangle().inset(by: -12))
    }

    private func drag(
        origin: Binding<Double?>,
        current: Double,
        track: CGFloat,
        apply: @escaping (Double) -> Void
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let base = origin.wrappedValue ?? current
                if origin.wrappedValue == nil { origin.wrappedValue = base }
                apply(base + Double(value.translation.width / track) * safeDuration)
            }
            .onEnded { _ in origin.wrappedValue = nil }
    }

    private func setStart(_ value: Double) {
        start = min(max(0, value), end - minimumLength)
        onScrub(start)
    }

    private func setEnd(_ value: Double) {
        end = max(min(duration, value), start + minimumLength)
        onScrub(end)
    }
}
