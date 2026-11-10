import AVFoundation
import AVKit
import SwiftUI
import UIKit

enum VideoSymbol {
    static let compress = "arrow.down.right.and.arrow.up.left"
    static let delete = "trash.fill"
    static let keep = "checkmark.circle.fill"
    static let play = "play.fill"
    static let fullScreen = "arrow.up.left.and.arrow.down.right"
    static let unavailable = "icloud.slash"
}

enum VideoActionName {
    static let compress = String(localized: "Compress")
}

extension VideoDecision {
    /// Compress is the space-saving choice, so it wears the "space saved" lime.
    static let compressTint = Color.appAccent
}

// MARK: - Player inside the card

/// The video itself, drawn over the card's poster frame. Tap to play or pause.
/// No system controls, so the card can still be flicked.
struct VideoCardPlayer: View {
    let player: AVPlayer?
    let isPlaying: Bool
    let isUnavailable: Bool
    let qualitySample: VideoSifterViewModel.QualitySampleState
    let onToggle: () -> Void
    let onFullScreen: () -> Void

    private static let playButtonSide: CGFloat = 64
    private static let fullScreenButtonSide: CGFloat = 40
    private static let fullScreenButtonInset: CGFloat = 12

    var body: some View {
        ZStack {
            if let player {
                PlayerLayerView(player: player)
            }
            if isUnavailable {
                Label("Not on this iPhone", systemImage: VideoSymbol.unavailable)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .appFrostedGlass(in: Capsule(style: .continuous))
            } else if player != nil, !isPlaying, qualitySample != .preparing {
                Image(systemName: VideoSymbol.play)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: Self.playButtonSide, height: Self.playButtonSide)
                    .appFrostedGlass(in: Circle())
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isPlaying)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .accessibilityElement()
        .accessibilityLabel(isPlaying ? String(localized: "Pause video") : String(localized: "Play video"))
        .accessibilityAddTraits(.isButton)
        .overlay(alignment: .topLeading) {
            if qualitySample != .none {
                HStack(spacing: 6) {
                    if qualitySample == .preparing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(qualitySample == .preparing
                         ? String(localized: "Making quality sample")
                         : String(localized: "Quality sample"))
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .frame(height: Self.fullScreenButtonSide)
                .appFrostedGlass(in: Capsule(style: .continuous))
                .padding(Self.fullScreenButtonInset)
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityIdentifier("videoQualitySampleBadge")
            }
        }
        .animation(.easeOut(duration: 0.2), value: qualitySample)
        .overlay(alignment: .topTrailing) {
            if player != nil, !isUnavailable {
                Button(action: onFullScreen) {
                    Image(systemName: VideoSymbol.fullScreen)
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: Self.fullScreenButtonSide, height: Self.fullScreenButtonSide)
                        .appFrostedGlass(in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .padding(Self.fullScreenButtonInset)
                .accessibilityLabel(String(localized: "Full screen"))
                .accessibilityIdentifier("videoFullScreenButton")
            }
        }
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.playerLayer?.videoGravity = .resizeAspect
        view.playerLayer?.player = player
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer?.player !== player { view.playerLayer?.player = player }
    }
}

// MARK: - Segment bar

/// Glass capsule with one cyan-filled choice, for the resolution and frame rate caps.
struct GlassSegmentBar<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }
    }

    let title: String
    let options: [Option]
    let selection: Value
    let onSelect: (Value) -> Void

    private static var segmentHeight: CGFloat { 36 }
    private static var inset: CGFloat { 3 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = option.value == selection
                Button {
                    guard !isSelected else { return }
                    HapticManager.shared.playTick()
                    onSelect(option.value)
                } label: {
                    Text(option.label)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(isSelected ? Color.appOnKeep : Color.appForeground)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: Self.segmentHeight)
                        .background(isSelected ? Color.appKeepFill : Color.clear, in: Capsule(style: .continuous))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel("\(title), \(option.label)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(Self.inset)
        .appGlass(in: Capsule(style: .continuous), interactive: false)
        .animation(.snappy(duration: 0.2), value: selection)
    }
}

// MARK: - Compress / Delete / Keep

/// The three choices for the current video. Compress sits on the left and Keep
/// on the right, the same sides as the flick.
struct VideoActionButtons: View {
    let savedBytes: Int64?
    let canCompress: Bool
    let onCompress: () -> Void
    let onDelete: () -> Void
    let onKeep: () -> Void

    private static let height: CGFloat = 54

    var body: some View {
        AppGlassGroup {
            HStack(spacing: 10) {
                button(
                    title: VideoActionName.compress,
                    detail: canCompress ? savedBytes.map { "−\(VideoFormat.bytes($0))" } : nil,
                    symbol: VideoSymbol.compress,
                    tint: .appForeground,
                    isEnabled: canCompress,
                    action: onCompress
                )
                .accessibilityIdentifier("videoCompressButton")
                button(
                    title: CardActionName.delete,
                    detail: nil,
                    symbol: VideoSymbol.delete,
                    tint: .appDelete,
                    isEnabled: true,
                    action: onDelete
                )
                .accessibilityIdentifier("videoDeleteButton")
                button(
                    title: CardActionName.keep,
                    detail: nil,
                    symbol: VideoSymbol.keep,
                    tint: .appKeep,
                    isEnabled: true,
                    action: onKeep
                )
                .accessibilityIdentifier("videoKeepButton")
            }
        }
    }

    private func button(
        title: String,
        detail: String?,
        symbol: String,
        tint: Color,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(.footnote, weight: .bold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    if let detail {
                        Text(detail)
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.appAccent)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isEnabled ? tint : Color.appForeground.opacity(0.3))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .appGlass(in: Capsule(style: .continuous), interactive: false)
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(!isEnabled)
        .animation(.easeOut(duration: 0.2), value: isEnabled)
    }
}

// MARK: - Full screen

enum VideoFullScreenPlayer {
    @MainActor
    static func present(_ player: AVPlayer?) {
        guard let player, let top = topViewController(in: keyWindow()), !(top is AVPlayerViewController) else { return }
        let controller = AVPlayerViewController()
        controller.player = player
        controller.modalPresentationStyle = .fullScreen
        top.present(controller, animated: true) { player.play() }
        restorePortraitAfterDismissal(of: controller)
    }

    private static let dismissPollInterval = Duration.milliseconds(150)
    private static let relayoutDelay = Duration.milliseconds(400)

    @MainActor
    private static func restorePortraitAfterDismissal(of controller: UIViewController) {
        Task { @MainActor in
            while controller.presentingViewController != nil {
                try? await Task.sleep(for: dismissPollInterval)
            }
            guard let window = keyWindow() else { return }
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            try? await Task.sleep(for: relayoutDelay)
            relayout(window.rootViewController)
        }
    }

    @MainActor
    private static func relayout(_ controller: UIViewController?) {
        guard let controller else { return }
        if let navigation = controller as? UINavigationController {
            navigation.navigationBar.setNeedsLayout()
            navigation.navigationBar.layoutIfNeeded()
        }
        controller.view.setNeedsLayout()
        controller.children.forEach(relayout)
    }

    @MainActor
    static func topViewController(in window: UIWindow?) -> UIViewController? {
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    @MainActor
    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

final class AppOrientationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        VideoFullScreenPlayer.topViewController(in: window) is AVPlayerViewController ? .allButUpsideDown : .portrait
    }
}
