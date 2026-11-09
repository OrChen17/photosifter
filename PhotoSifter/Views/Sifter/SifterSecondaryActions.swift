import SwiftUI

/// Bottom action row in the sifter. Three slots:
///  - left: skip
///  - middle: apply (forever mode only; pass `nil` to leave empty)
///  - right: revert
struct SifterSecondaryActions: View {
    struct ApplyConfig {
        let deleteCount: Int
        let keepCount: Int
        let isEnabled: Bool
        let action: () -> Void
    }

    let onSkip: () -> Void
    let isSkipEnabled: Bool
    let apply: ApplyConfig?
    let onRevert: () -> Void
    let isRevertEnabled: Bool
    @Environment(\.swipeHint) private var swipeHint

    /// The first-run hint takes the middle slot until there is something to apply.
    private var showsHint: Bool {
        swipeHint.isActive && apply?.isEnabled != true
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            sideButton(
                icon: "arrow.up",
                accessibilityLabel: "Skip photo",
                isEnabled: isSkipEnabled,
                action: onSkip,
                enabledTint: .appForeground
            )
            .accessibilityIdentifier("skipButton")

            if showsHint {
                Spacer(minLength: 8)
                SwipeHintView()
                    .opacity(swipeHint.isDimmed ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: swipeHint.isDimmed)
                    .transition(.opacity)
                Spacer(minLength: 8)
            } else if let apply {
                Spacer(minLength: 8)
                applyButton(apply)
                    .accessibilityIdentifier("applyButton")
                Spacer(minLength: 8)
            } else {
                Spacer()
            }

            RevertButton(isEnabled: isRevertEnabled, action: onRevert)
                .accessibilityIdentifier("revertButton")
        }
    }

    private func sideButton(
        icon: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void,
        enabledTint: Color = .appBackground
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(isEnabled ? enabledTint : Color.appForeground.opacity(0.3))
                .frame(width: 44, height: 44)
                .appGlass(in: Circle(), interactive: isEnabled)
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func applyButton(_ config: ApplyConfig) -> some View {
        Button(action: config.action) {
            HStack(spacing: 8) {
                Text("Apply")
                if config.isEnabled {
                    if config.deleteCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "trash.fill")
                                .font(.system(.caption, weight: .semibold))
                            Text("\(config.deleteCount)")
                                .monospacedDigit()
                        }
                    }
                    if config.keepCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(.caption, weight: .semibold))
                            Text("\(config.keepCount)")
                                .monospacedDigit()
                        }
                    }
                }
            }
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(config.isEnabled ? Color.appOnKeep : Color.appForeground)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                config.isEnabled
                    ? AnyShapeStyle(LinearGradient(
                        colors: [.appKeepFill, .appKeepDeep],
                        startPoint: .leading,
                        endPoint: .trailing
                      ))
                    : AnyShapeStyle(Color.appForeground.opacity(0.08)),
                in: Capsule(style: .continuous)
            )
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(!config.isEnabled)
        .opacity(config.isEnabled ? 1.0 : 0.55)
        .animation(.easeOut(duration: 0.2), value: config.isEnabled)
    }
}

/// Revert side-button. Owns a per-tap 360° spin on the arrow so the action
/// reads as "rewind"; still picks up the PressScaleButtonStyle scale for the
/// press-in feel shared with skip/apply.
private struct RevertButton: View {
    let isEnabled: Bool
    let action: () -> Void
    @State private var spin: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if !reduceMotion {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                    spin -= 360
                }
            }
            action()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(isEnabled ? Color.appRevert : Color.appForeground.opacity(0.3))
                .rotationEffect(.degrees(spin))
                .frame(width: 44, height: 44)
                .appGlass(in: Circle(), interactive: isEnabled)
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel("Revert last action")
    }
}
