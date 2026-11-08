import SwiftUI
import PostHog

struct PermissionView: View {
    let onRequest: () async -> Void

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                VStack(spacing: 20) {
                    Image(systemName: "photo.stack")
                        .scaledFont(size: 72, weight: .thin)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.appKeepFill, .appKeepDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 12) {
                        Text("FlickPic")
                            .scaledFont(size: 36, weight: .bold, design: .rounded)
                            .foregroundStyle(.appForeground)

                        Text("Swipe through near-duplicate photos\nand keep only the best shots.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.appTextSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }
                }

                Spacer()

                VStack(spacing: 16) {
                    FeatureRow(icon: "wand.and.stars", text: "AI groups your near-duplicates")
                    FeatureRow(icon: "hand.draw", text: "Swipe right to keep, left to delete")
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

            Spacer()
        }
    }
}
