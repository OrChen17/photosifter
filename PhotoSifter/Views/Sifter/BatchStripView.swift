import SwiftUI
import Photos

struct BatchStripView: View {
    let group: PhotoGroup
    let currentAssetID: String?   // replaces currentIndex — works with skip reordering
    var onTap: ((PHAsset) -> Void)? = nil

    @State private var thumbnails: [String: UIImage] = [:]
    @State private var scrollID: String?

    private let thumbSize: CGFloat = 64
    // Subtle tint — color signals the decision without overwhelming the photo.
    private let decisionTintOpacity: Double = 0.35

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(Array(group.assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                    thumbnail(for: asset, position: idx + 1)
                        .id(asset.localIdentifier)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollPosition(id: $scrollID, anchor: .center)
        .frame(height: thumbSize + 8)
        .onChange(of: currentAssetID) { _, id in
            guard let id else { return }
            withAnimation(.spring(duration: 0.4)) {
                scrollID = id
            }
        }
        .task { await loadAllThumbnails() }
    }

    @ViewBuilder
    private func thumbnail(for asset: PHAsset, position: Int) -> some View {
        let isCurrent = asset.localIdentifier == currentAssetID
        let decision = group.decisions[asset.localIdentifier]

        // Button inside a horizontal ScrollView routinely loses its tap to
        // the scroll gesture — using a plain hit-tested ZStack with
        // onTapGesture is the reliable path.
        ZStack {
            Group {
                if let img = thumbnails[asset.localIdentifier] {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.appCard
                }
            }
            .frame(width: thumbSize, height: thumbSize)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(decision == .delete ? 0.45 : 1.0)

            if let decision {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(decision == .keep
                          ? Color.appKeep.opacity(decisionTintOpacity)
                          : Color.appDelete.opacity(decisionTintOpacity))
                    .frame(width: thumbSize, height: thumbSize)
            }

            if isCurrent {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.appForeground, lineWidth: 2.5)
                    .frame(width: thumbSize, height: thumbSize)
            }
        }
        .frame(width: thumbSize, height: thumbSize)
        .scaleEffect(isCurrent ? 1.08 : 1.0)
        .animation(.spring(duration: 0.3), value: isCurrent)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .cardButton(label: StripAccessibility.label(
            position: position,
            count: group.assets.count,
            decision: decision,
            isCurrent: isCurrent
        )) { onTap?(asset) }
        .accessibilityIdentifier("stripThumb_\(asset.localIdentifier)")
    }

    private func loadAllThumbnails() async {
        let size = CGSize(width: thumbSize * 2, height: thumbSize * 2)
        for asset in group.assets {
            let img = await PhotoLibraryService.shared.loadThumbnail(for: asset, size: size)
            if let img { thumbnails[asset.localIdentifier] = img }
        }
    }
}
