import SwiftUI
import Photos

/// Reference-type image cache shared between SifterView/SweepSifterView and their cards.
/// Being a class means writes don't trigger SwiftUI view re-evaluations, so preloading
/// a new image won't interrupt an in-progress drag gesture.
final class ImagePreloadCache {
    private let store = NSCache<NSString, UIImage>()

    func image(for id: String) -> UIImage? {
        store.object(forKey: id as NSString)
    }

    func set(_ image: UIImage, for id: String) {
        store.setObject(image, forKey: id as NSString)
    }

    func removeImage(for id: String) {
        store.removeObject(forKey: id as NSString)
    }

    func removeAll() {
        store.removeAllObjects()
    }
}

/// Shared card-swiping container used by SifterView (single memory) and
/// SweepSifterView (multi-memory queue).
///
/// Owns: behind-card preview with scale/offset animation, card-entrance wobble,
/// drag-progress vignette, and post-throw flash + haptics/sounds.
/// Preloading and VM state stay in the parent; the parent passes the photo
/// strip and action bar as ViewBuilder slots.
struct FlickCardArea<Strip: View, PrimaryActions: View, BottomBar: View>: View {
    let currentAsset: PHAsset?
    let nextAsset: PHAsset?
    let imageCache: ImagePreloadCache
    /// Changing this value resets the card-entrance wobble — pass the current
    /// group's id so the wobble fires again when the user moves to a new memory.
    let groupID: AnyHashable
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void
    let onSkip: (() -> Void)?
    /// Forwarded to the top SwipeCardView so the parent can drive button-state
    /// inversion from the live drag.
    var onProgressChange: ((Double) -> Void)? = nil
    /// Setting this triggers a programmatic throw on the top card.
    var throwCommand: ThrowCommand? = nil
    /// Live horizontal drag progress of the top card in [-1, 1], forwarded from the
    /// parent. Drives the behind card "growing into place" as the top card is flicked.
    var dragProgress: Double = 0
    @ViewBuilder let strip: () -> Strip
    /// Overlaid on top of the card, anchored to the bottom — used for the
    /// big keep/delete buttons so the photo can stay full-size.
    @ViewBuilder let primaryActions: () -> PrimaryActions
    @ViewBuilder let bottomBar: () -> BottomBar

    @State private var flashTint: Color = .appKeep
    @State private var flashCounter: Int = 0
    @State private var isTopCardThrown: Bool = false
    @State private var thrownCardID: String?
    @State private var exitOffset: CGSize = .zero
    @State private var cardAppearWobble: Double = 1.875
    @AppStorage(SwipeHintView.storageKey) private var hintSwipeCount: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                strip()

                if let asset = currentAsset {
                    ZStack {
                        if let next = nextAsset {
                            // Reveal tracks how far the top card is flicked on the x-axis
                            // (0 at rest → 1 at the throw threshold), so the behind card
                            // scales up into the top slot as the current one is thrown.
                            SwipeCardView(
                                asset: next,
                                preloadedImage: imageCache.image(for: next.localIdentifier),
                                onSwipeRight: {},
                                onSwipeLeft: {}
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(Color.black.opacity(behindCardDim))
                            )
                            .scaleEffect(behindCardScale)
                            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: behindCardReveal)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .id(next.localIdentifier)
                            .zIndex(0)
                        }

                        SwipeCardView(
                            asset: asset,
                            preloadedImage: imageCache.image(for: asset.localIdentifier),
                            onSwipeRight: {
                                isTopCardThrown = false
                                recordHintSwipe()
                                onSwipeRight()
                            },
                            onSwipeLeft: {
                                isTopCardThrown = false
                                recordHintSwipe()
                                onSwipeLeft()
                            },
                            onSkip: onSkip.map { action in
                                { isTopCardThrown = false; recordHintSwipe(); action() }
                            },
                            onProgressChange: onProgressChange,
                            onThrowRight: {
                                markThrown(asset, exit: CGSize(width: CardExit.distance, height: CardExit.lift))
                                isTopCardThrown = true
                                flashTint = .appKeep
                                triggerFlash()
                                HapticManager.shared.playKeep()
                                SoundManager.shared.playKeep()
                            },
                            onThrowLeft: {
                                markThrown(asset, exit: CGSize(width: -CardExit.distance, height: CardExit.lift))
                                isTopCardThrown = true
                                flashTint = .appDelete
                                triggerFlash()
                                HapticManager.shared.playDelete()
                                SoundManager.shared.playDelete()
                            },
                            onThrowUp: {
                                markThrown(asset, exit: CGSize(width: 0, height: -CardExit.distance))
                            },
                            commitsImmediately: true,
                            throwCommand: throwCommand
                        )
                        .id(asset.localIdentifier)
                        .zIndex(thrownCardID == asset.localIdentifier ? 2 : 1)
                        .transition(topCardTransition)
                        .rotationEffect(.degrees(reduceMotion ? 0 : cardAppearWobble))
                        .onAppear {
                            guard cardAppearWobble != 0 else { return }
                            Task {
                                try? await Task.sleep(for: .milliseconds(120))
                                withAnimation(.spring(duration: 0.9, bounce: 0.72)) { cardAppearWobble = 0 }
                            }
                        }
                        .accessibilityIdentifier("photoCard")
                    }
                    .animation(cardSwapAnimation, value: asset.localIdentifier)
                    .overlay(alignment: .bottom) {
                        primaryActions()
                            .padding(.bottom, 44)
                            .allowsHitTesting(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                bottomBar()
                    .environment(\.swipeHint, SwipeHintState(
                        isActive: showsSwipeHint && currentAsset != nil,
                        isDimmed: isTopCardThrown || dragProgress != 0
                    ))
                    .animation(.easeOut(duration: 0.25), value: showsSwipeHint)
            }

            FlashVignetteView(tint: flashTint, counter: flashCounter).allowsHitTesting(false)
        }
        .onChange(of: groupID) { _, _ in cardAppearWobble = 1.875 }
    }

    /// 0 at rest, 1 once the top card is past the throw threshold.
    private var behindCardReveal: Double { min(1, abs(dragProgress)) }

    private var behindCardScale: CGFloat {
        reduceMotion ? 1 : BehindCard.restScale + (1 - BehindCard.restScale) * behindCardReveal
    }

    /// A dim overlay instead of a blur: same depth cue, no per-frame blur pass.
    private var behindCardDim: Double { BehindCard.restDim * (1 - behindCardReveal) }

    private func triggerFlash() { flashCounter += 1 }

    private func markThrown(_ asset: PHAsset, exit: CGSize) {
        thrownCardID = asset.localIdentifier
        exitOffset = exit
    }

    private var topCardTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .scale(scale: CardExit.insertScale), removal: .offset(exitOffset))
    }

    private var cardSwapAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.3, bounce: 0.08)
    }

    private var showsSwipeHint: Bool { hintSwipeCount < SwipeHintView.swipesUntilHidden }

    private func recordHintSwipe() {
        guard showsSwipeHint else { return }
        hintSwipeCount += 1
    }
}

private enum CardExit {
    static let distance: CGFloat = 520
    static let lift: CGFloat = -40
    static let insertScale: CGFloat = 0.96
}

private enum BehindCard {
    static let restScale: CGFloat = 0.93
    static let restDim: Double = 0.35
}

/// First-run swipe hint. Shown in the middle of the skip / undo row for the
/// user's first few swipes, then never again.
struct SwipeHintView: View {
    static let storageKey = "flickHintSwipeCount"
    static let swipesUntilHidden = 3

    var body: some View {
        HStack(spacing: 16) {
            Label(CardActionName.delete, systemImage: "arrow.left")
                .labelStyle(HintLabelStyle(tint: .appDelete, iconLeading: true))
            Label(CardActionName.keep, systemImage: "arrow.right")
                .labelStyle(HintLabelStyle(tint: .appKeep, iconLeading: false))
        }
        .font(.subheadline.weight(.semibold))
        .fontDesign(.rounded)
        .foregroundStyle(.appTextSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .dynamicTypeSize(...DynamicTypeSize.cardOverlayMax)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SwipeHintState: Equatable {
    var isActive = false
    /// True while a card is being dragged or thrown, so the hint gets out of the way.
    var isDimmed = false
}

extension EnvironmentValues {
    @Entry var swipeHint = SwipeHintState()
}

private struct HintLabelStyle: LabelStyle {
    let tint: Color
    let iconLeading: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            if iconLeading { configuration.icon.foregroundStyle(tint) }
            configuration.title
            if !iconLeading { configuration.icon.foregroundStyle(tint) }
        }
    }
}

private struct FlashVignetteView: View {
    let tint: Color
    let counter: Int
    @State private var intensity: Double = 0

    var body: some View {
        GeometryReader { geo in
            let radius = hypot(geo.size.width, geo.size.height) * 0.6
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear,                       location: 0.00),
                    .init(color: .clear,                       location: 0.32),
                    .init(color: tint.opacity(intensity * 0.04),  location: 0.46),
                    .init(color: tint.opacity(intensity * 0.09),  location: 0.58),
                    .init(color: tint.opacity(intensity * 0.16),  location: 0.69),
                    .init(color: tint.opacity(intensity * 0.26),  location: 0.79),
                    .init(color: tint.opacity(intensity * 0.38),  location: 0.88),
                    .init(color: tint.opacity(intensity * 0.52),  location: 0.95),
                    .init(color: tint.opacity(intensity * 0.68),  location: 1.00),
                ]),
                center: .center,
                startRadius: 0,
                endRadius: radius
            )
            .ignoresSafeArea()
        }
        .onChange(of: counter) { _, _ in
            withAnimation(.easeOut(duration: 0.08)) { intensity = 1.0 }
            withAnimation(.easeOut(duration: 0.35).delay(0.08)) { intensity = 0 }
        }
    }
}
