import SwiftUI
import Photos

enum StripMetrics {
    static let thumbSize: CGFloat = 110
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 10
    static let currentScale: CGFloat = 1.08
    static let verticalPadding: CGFloat = 6
    static let height: CGFloat = thumbSize + verticalPadding * 2
}

struct BatchStripView: View {
    let group: PhotoGroup
    let currentAssetID: String?   // replaces currentIndex — works with skip reordering
    var onTap: ((PHAsset) -> Void)? = nil

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var scrollID: String?

    private let thumbSize = StripMetrics.thumbSize
    private let cornerRadius = StripMetrics.cornerRadius
    // Subtle tint — color signals the decision without overwhelming the photo.
    private let decisionTintOpacity: Double = 0.35

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: StripMetrics.spacing) {
                ForEach(Array(group.assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                    thumbnail(for: asset, position: idx + 1)
                        .id(asset.localIdentifier)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, StripMetrics.verticalPadding)
        }
        .scrollPosition(id: $scrollID, anchor: .center)
        .frame(height: StripMetrics.height)
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
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(decision == .delete ? 0.45 : 1.0)

            if let decision {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(decision == .keep
                          ? Color.appKeep.opacity(decisionTintOpacity)
                          : Color.appDelete.opacity(decisionTintOpacity))
                    .frame(width: thumbSize, height: thumbSize)
            }

            if isCurrent {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.appForeground, lineWidth: 2.5)
                    .frame(width: thumbSize, height: thumbSize)
            }
        }
        .frame(width: thumbSize, height: thumbSize)
        .scaleEffect(isCurrent ? StripMetrics.currentScale : 1.0)
        .animation(.spring(duration: 0.3), value: isCurrent)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .cardButton(label: StripAccessibility.label(
            position: position,
            count: group.assets.count,
            decision: decision,
            isCurrent: isCurrent
        )) { onTap?(asset) }
        .accessibilityIdentifier("stripThumb_\(asset.localIdentifier)")
    }

    private func loadAllThumbnails() async {
        let size = CGSize(width: thumbSize * displayScale, height: thumbSize * displayScale)
        for asset in group.assets {
            let img = await PhotoLibraryService.shared.loadThumbnail(for: asset, size: size)
            if let img { thumbnails[asset.localIdentifier] = img }
        }
    }
}
