import SwiftUI

/// Prominent entrypoint card above the memories grid for starting a
/// cross-memory Sweep session. Hidden if there's nothing meaningful to sweep.
struct SweepBannerView: View {
    let memoryCount: Int
    let photoCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.appOnKeep.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "wand.and.stars")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(Color.appOnKeep)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Flick Forever")
                        .font(.system(.callout, design: .rounded, weight: .bold))
                        .foregroundStyle(Color.appOnKeep)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(Color.appOnKeep.opacity(0.85))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(Color.appOnKeep.opacity(0.9))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [.appKeepFill, .appKeepDeep],
                    startPoint: .leading, endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .shadow(color: .appKeep.opacity(0.25), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sweepBanner")
    }

    private var subtitle: String {
        let mems = "\(memoryCount) memor\(memoryCount == 1 ? "y" : "ies")"
        return "\(mems) · \(photoCount) photos"
    }
}
