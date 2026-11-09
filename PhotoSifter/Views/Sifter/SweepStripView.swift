import SwiftUI
import Photos

/// Virtualized horizontal strip showing every asset in a Sweep session.
/// Cells lazy-load their thumbnail on appear so this scales to hundreds of
/// assets without paying the up-front fetch cost.
struct SweepStripView: View {
    let assets: [PHAsset]
    let currentAssetID: String?
    let decisions: [String: Decision]
    /// Identity of the source memory each asset belongs to, used to draw a
    /// hairline divider whenever two adjacent cells span a memory boundary.
    let groupID: (PHAsset) -> UUID?
    let onTap: (PHAsset) -> Void

    private let cellSize = StripMetrics.thumbSize
    private let cellSpacing = StripMetrics.spacing
    @State private var scrollID: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cellSpacing) {
                ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                    let crossesBoundary = idx > 0 && groupID(assets[idx - 1]) != groupID(asset)
                    SweepStripCell(
                        asset: asset,
                        size: cellSize,
                        decision: decisions[asset.localIdentifier],
                        isCurrent: asset.localIdentifier == currentAssetID,
                        showDivider: crossesBoundary,
                        dividerSpacing: cellSpacing
                    )
                    .cardButton(label: StripAccessibility.label(
                        position: idx + 1,
                        count: assets.count,
                        decision: decisions[asset.localIdentifier],
                        isCurrent: asset.localIdentifier == currentAssetID
                    ), pressedScale: PressScale.thumbnail) {
                        HapticManager.shared.playDragTick()
                        onTap(asset)
                    }
                    .id(asset.localIdentifier)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, StripMetrics.verticalPadding)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: assets.map(\.localIdentifier))
        }
        .scrollPosition(id: $scrollID, anchor: .center)
        .frame(height: StripMetrics.height)
        .onChange(of: currentAssetID) { _, id in
            guard let id else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                scrollID = id
            }
        }
        .onAppear { scrollID = currentAssetID }
    }
}

private struct SweepStripCell: View {
    let asset: PHAsset
    let size: CGFloat
    let decision: Decision?
    let isCurrent: Bool
    var showDivider: Bool = false
    var dividerSpacing: CGFloat = 6

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Color.appBackground
                    .frame(width: size, height: size)
            }

            if let decision {
                Rectangle()
                    .fill((decision == .keep ? Color.appKeep : Color.appDelete).opacity(0.35))
                    .frame(width: size, height: size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: StripMetrics.cornerRadius, style: .continuous))
        .opacity(decision == .delete ? 0.45 : 1.0)
        .overlay(
            RoundedRectangle(cornerRadius: StripMetrics.cornerRadius, style: .continuous)
                .stroke(isCurrent ? Color.appForeground : .clear, lineWidth: 2.5)
        )
        .overlay(alignment: .leading) {
            if showDivider {
                Rectangle()
                    .fill(Color.appTextSecondary.opacity(0.35))
                    .frame(width: 2, height: size * 0.8)
                    .offset(x: -(dividerSpacing / 2 + 1))
            }
        }
        .scaleEffect(isCurrent ? StripMetrics.currentScale : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isCurrent)
        .task(id: asset.localIdentifier) {
            guard thumbnail == nil else { return }
            let px = size * displayScale
            let img = await PhotoLibraryService.shared.loadThumbnail(
                for: asset,
                size: CGSize(width: px, height: px)
            )
            thumbnail = img
        }
    }
}
