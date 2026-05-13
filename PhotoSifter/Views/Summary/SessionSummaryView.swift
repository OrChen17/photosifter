import SwiftUI
import Photos

struct SessionSummaryView: View {
    let group: PhotoGroup
    let deletedCount: Int

    @Environment(\.dismiss) private var dismiss
    @State private var animatedCount: Int = 0
    @State private var thumbnails: [UIImage] = []

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Hero count
                VStack(spacing: 8) {
                    Text("\(animatedCount)")
                        .font(.system(size: 80, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.appDelete, Color(hex: "FF6B6B")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .contentTransition(.numericText())

                    Text(deletedCount == 1 ? "photo moved to trash" : "photos moved to trash")
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                }

                // Thumbnail scroll of deleted photos
                if !thumbnails.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, img in
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .opacity(0.6)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Color.appDelete.opacity(0.4), lineWidth: 1)
                                    }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .frame(height: 80)
                }

                Spacer()

                // Actions
                VStack(spacing: 14) {
                    Button {
                        openRecentlyDeleted()
                    } label: {
                        Label("View Recently Deleted", systemImage: "trash")
                            .accessibilityIdentifier("viewRecentlyDeletedButton")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(Color.appDelete.opacity(0.2), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.appDelete.opacity(0.4), lineWidth: 1)
                            )
                    }

                    Button {
                        dismiss()
                    } label: {
                        Text("Continue Sifting")
                            .accessibilityIdentifier("continueSiftingButton")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                LinearGradient(
                                    colors: [.appAccent, Color(hex: "9B59B6")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
        .task {
            await loadDeletedThumbnails()
            withAnimation(.spring(duration: 0.6)) {
                animatedCount = deletedCount
            }
        }
    }

    private func loadDeletedThumbnails() async {
        let size = CGSize(width: 160, height: 160)
        for asset in group.deletedAssets {
            if let img = await PhotoLibraryService.shared.loadThumbnail(for: asset, size: size) {
                thumbnails.append(img)
            }
        }
    }

    private func openRecentlyDeleted() {
        // Deep-link into Photos app — works on iOS 16+ as a URL scheme
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }
}
