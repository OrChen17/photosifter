import SwiftUI
import Photos

/// Shared card-swiping container used by SifterView (single memory) and
/// SweepSifterView (multi-memory queue).
///
/// Owns: behind-card preview with scale/offset animation, card-entrance wobble,
/// drag-progress vignette, and post-throw flash + haptics/sounds.
/// Preloading and VM state stay in the parent; the parent passes the photo
/// strip and action bar as ViewBuilder slots.
struct FlickCardArea<Strip: View, BottomBar: View>: View {
    let currentAsset: PHAsset?
    let nextAsset: PHAsset?
    let imageCache: [String: UIImage]
    /// Changing this value resets the card-entrance wobble — pass the current
    /// group's id so the wobble fires again when the user moves to a new memory.
    let groupID: AnyHashable
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void
    let onSkip: (() -> Void)?
    @ViewBuilder let strip: () -> Strip
    @ViewBuilder let bottomBar: () -> BottomBar

    @State private var flashTint: Color = .appKeep
    @State private var flashIntensity: Double = 0
    @State private var isTopCardThrown: Bool = false
    @State private var cardAppearWobble: Double = 1.5

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                strip()

                if let asset = currentAsset {
                    ZStack {
                        if let next = nextAsset {
                            SwipeCardView(
                                asset: next,
                                preloadedImage: imageCache[next.localIdentifier],
                                onSwipeRight: {},
                                onSwipeLeft: {}
                            )
                            .scaleEffect(isTopCardThrown ? 1.0 : 0.95)
                            .offset(y: isTopCardThrown ? 0 : 10)
                            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isTopCardThrown)
                            .allowsHitTesting(false)
                            .id(next.localIdentifier)
                        }

                        SwipeCardView(
                            asset: asset,
                            preloadedImage: imageCache[asset.localIdentifier],
                            onSwipeRight: {
                                isTopCardThrown = false
                                onSwipeRight()
                            },
                            onSwipeLeft: {
                                isTopCardThrown = false
                                onSwipeLeft()
                            },
                            onSkip: onSkip.map { action in
                                { isTopCardThrown = false; action() }
                            },
                            onThrowRight: {
                                isTopCardThrown = true
                                flashTint = .appKeep
                                triggerFlash()
                                HapticManager.shared.playKeep()
                                SoundManager.shared.playKeep()
                            },
                            onThrowLeft: {
                                isTopCardThrown = true
                                flashTint = .appDelete
                                triggerFlash()
                                HapticManager.shared.playDelete()
                                SoundManager.shared.playDelete()
                            }
                        )
                        .id(asset.localIdentifier)
                        .rotationEffect(.degrees(cardAppearWobble))
                        .onAppear {
                            guard cardAppearWobble != 0 else { return }
                            Task {
                                try? await Task.sleep(for: .milliseconds(120))
                                withAnimation(.spring(duration: 0.7, bounce: 0.45)) { cardAppearWobble = 0 }
                            }
                        }
                        .accessibilityIdentifier("photoCard")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                bottomBar()
            }

            swipeVignette.allowsHitTesting(false)
        }
        .onChange(of: groupID) { _, _ in cardAppearWobble = 1.5 }
    }

    private var currentIntensity: Double { flashIntensity }

    private var swipeVignette: some View {
        GeometryReader { geo in
            let radius = hypot(geo.size.width, geo.size.height) * 0.6
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear,                                      location: 0.00),
                    .init(color: .clear,                                      location: 0.32),
                    .init(color: flashTint.opacity(currentIntensity * 0.04),  location: 0.46),
                    .init(color: flashTint.opacity(currentIntensity * 0.09),  location: 0.58),
                    .init(color: flashTint.opacity(currentIntensity * 0.16),  location: 0.69),
                    .init(color: flashTint.opacity(currentIntensity * 0.26),  location: 0.79),
                    .init(color: flashTint.opacity(currentIntensity * 0.38),  location: 0.88),
                    .init(color: flashTint.opacity(currentIntensity * 0.52),  location: 0.95),
                    .init(color: flashTint.opacity(currentIntensity * 0.68),  location: 1.00),
                ]),
                center: .center,
                startRadius: 0,
                endRadius: radius
            )
            .ignoresSafeArea()
        }
    }

    private func triggerFlash() {
        withAnimation(.easeOut(duration: 0.08)) { flashIntensity = 1.0 }
        withAnimation(.easeOut(duration: 0.35).delay(0.08)) { flashIntensity = 0 }
    }
}
