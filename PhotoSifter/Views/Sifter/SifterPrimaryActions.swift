import SwiftUI

/// Top action row in the sifter — big circular DELETE (magenta X) and KEEP (cyan heart)
/// buttons that sit directly under the photo card.
///
/// Reacts to the live `dragProgress` so the corresponding button "fills in" as the
/// user swipes the card toward it. -1 = full left (delete), +1 = full right (keep).
struct SifterPrimaryActions: View {
    let dragProgress: Double
    let onDelete: () -> Void
    let onKeep: () -> Void
    var isEnabled: Bool = true

    private var deleteActivation: Double { min(1, max(0, -dragProgress)) }
    private var keepActivation:   Double { min(1, max(0,  dragProgress)) }

    var body: some View {
        HStack {
            actionCircle(
                icon: "xmark",
                tint: .appDelete,
                activation: deleteActivation,
                action: onDelete,
                accessibilityLabel: "Delete photo"
            )
            .accessibilityIdentifier("primaryDeleteButton")

            Spacer()

            actionCircle(
                icon: "heart.fill",
                tint: .appKeep,
                activation: keepActivation,
                action: onKeep,
                accessibilityLabel: "Keep photo"
            )
            .accessibilityIdentifier("primaryKeepButton")
        }
        .padding(.horizontal, 60)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.4)
        .animation(.easeOut(duration: 0.12), value: dragProgress)
    }

    private func actionCircle(
        icon: String,
        tint: Color,
        activation: Double,
        action: @escaping () -> Void,
        accessibilityLabel: String
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white)
                Circle().fill(tint).opacity(activation)

                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 29, weight: .heavy))
                        .foregroundStyle(tint)
                        .opacity(1 - activation)
                    Image(systemName: icon)
                        .font(.system(size: 29, weight: .heavy))
                        .foregroundStyle(.white)
                        .opacity(activation)
                }
            }
            .frame(width: 64, height: 64)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
