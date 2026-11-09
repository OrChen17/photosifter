import SwiftUI
import PostHog

struct PermissionView: View {
    let onRequest: () async -> Void

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                VStack(spacing: 28) {
                    FlickDemoStack()

                    VStack(spacing: 12) {
                        Text("FlickPic")
                            .scaledFont(size: 36, weight: .bold, design: .rounded)
                            .foregroundStyle(.appForeground)

                        Text("Flick right to keep, left to delete.\nKeep only the best shots.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.appTextSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                VStack(spacing: 16) {
                    FeatureRow(icon: "wand.and.stars", text: "AI groups your near-duplicates")
                    FeatureRow(icon: "trash.slash", text: "Deleted photos go to Recently Deleted")
                }
                .padding(.horizontal, 32)

                Spacer()

                Button {
                    PostHogSDK.shared.capture("photo_library_access_requested")
                    PostHogAppLogger.photoLibraryAccessRequested()
                    Task { await onRequest() }
                } label: {
                    Text("Allow Full Access")
                        .scaledFont(size: 18, weight: .semibold, design: .rounded)
                        .foregroundStyle(.appOnKeep)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            LinearGradient(
                                colors: [.appKeepFill, .appKeepDeep],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
                .accessibilityIdentifier("allowPhotoAccessButton")
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(.title3))
                .foregroundStyle(.appKeep)
                .frame(width: 32)

            Text(text)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.appForeground)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
    }
}

private struct FlickDemoStack: View {
    private enum Move: CaseIterable {
        case keep, delete

        var direction: CGFloat { self == .keep ? 1 : -1 }
        var badge: DecisionBadgeView.Kind { self == .keep ? .keep : .delete }
        var glow: Color { self == .keep ? .appKeep : .appDelete }
    }

    private enum Layout {
        static let cardSize = CGSize(width: 168, height: 216)
        static let cornerRadius: CGFloat = 22
        static let visibleCards = 3
        static let behindScaleStep: CGFloat = 0.07
        static let behindLift: CGFloat = -14
        static let leanDistance: CGFloat = 64
        static let exitDistance: CGFloat = 420
    }

    private enum Timing {
        static let rest: Duration = .milliseconds(900)
        static let lean: Duration = .milliseconds(450)
        static let exit: Duration = .milliseconds(240)
    }

    private static let script: [Move] = [.keep, .delete, .keep, .keep, .delete]

    @State private var step = 0
    @State private var leanID = 0
    @State private var leanX: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var move: Move { Self.script[step % Self.script.count] }

    var body: some View {
        ZStack {
            ForEach((step..<step + Layout.visibleCards).reversed(), id: \.self) { id in
                card(id: id)
            }
        }
        .frame(width: Layout.cardSize.width + 60, height: Layout.cardSize.height + 30)
        .accessibilityHidden(true)
        .task(id: reduceMotion) { await loop() }
    }

    @ViewBuilder
    private func card(id: Int) -> some View {
        let depth = id - step
        let isTop = depth == 0
        let x = id == leanID ? leanX : 0
        let leanProgress = min(1, abs(x) / Layout.leanDistance)
        let scale = 1 - Layout.behindScaleStep * CGFloat(depth)
        DemoPhoto(scene: DemoPhoto.scenes[id % DemoPhoto.scenes.count])
            .frame(width: Layout.cardSize.width, height: Layout.cardSize.height)
            .overlay {
                if isTop {
                    RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                        .strokeBorder(move.glow.opacity(leanProgress), lineWidth: 3)
                    VStack {
                        HStack {
                            if move == .delete { Spacer() }
                            DecisionBadgeView(kind: move.badge, opacity: leanProgress)
                                .scaleEffect(0.75)
                            if move == .keep { Spacer() }
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous))
            .shadow(color: isTop ? move.glow.opacity(0.5 * leanProgress) : .clear, radius: 18)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.12 * Double(depth)))
            }
            .scaleEffect(scale)
            .offset(y: Layout.behindLift * CGFloat(depth))
            .offset(x: x)
            .rotationEffect(.degrees(Double(x) / 14), anchor: .bottom)
            .zIndex(Double(Layout.visibleCards - depth))
            .transition(.opacity)
    }

    private func loop() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Timing.rest)
            let direction = move.direction
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                leanID = step
                leanX = 0
            }
            withAnimation(.spring(duration: 0.45, bounce: 0.2)) { leanX = direction * Layout.leanDistance }
            try? await Task.sleep(for: Timing.lean)
            withAnimation(.easeIn(duration: 0.24)) { leanX = direction * Layout.exitDistance }
            try? await Task.sleep(for: Timing.exit)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { step += 1 }
        }
    }
}

private struct DemoPhoto: View {
    struct Scene {
        let sky: [Color]
        let sun: Color
        let ground: Color
        let sunPosition: UnitPoint
    }

    static let scenes: [Scene] = [
        Scene(sky: [.orange, .pink], sun: .yellow, ground: .indigo, sunPosition: UnitPoint(x: 0.68, y: 0.3)),
        Scene(sky: [.teal, .blue], sun: .white, ground: .black, sunPosition: UnitPoint(x: 0.3, y: 0.24)),
        Scene(sky: [.purple, .pink], sun: .orange, ground: .indigo, sunPosition: UnitPoint(x: 0.55, y: 0.36)),
        Scene(sky: [.mint, .green], sun: .yellow, ground: .teal, sunPosition: UnitPoint(x: 0.72, y: 0.2)),
        Scene(sky: [.cyan, .indigo], sun: .pink, ground: .black, sunPosition: UnitPoint(x: 0.4, y: 0.28)),
    ]

    let scene: Scene

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: scene.sky, startPoint: .top, endPoint: .bottom)
                Circle()
                    .fill(scene.sun.opacity(0.9))
                    .frame(width: w * 0.32)
                    .position(x: w * scene.sunPosition.x, y: h * scene.sunPosition.y)
                HStack(alignment: .bottom, spacing: w * 0.03) {
                    ForEach(Array([0.34, 0.52, 0.28, 0.44, 0.38].enumerated()), id: \.offset) { _, height in
                        Rectangle()
                            .fill(scene.ground.opacity(0.55))
                            .frame(width: w * 0.16, height: h * height)
                    }
                }
                .frame(width: w, alignment: .leading)
            }
        }
    }
}

