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

    private let cellSize: CGFloat = 56
    private let cellSpacing: CGFloat = 6

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cellSpacing) {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                        let prevGroupID: UUID? = idx > 0 ? groupID(assets[idx - 1]) : nil
                        let thisGroupID: UUID? = groupID(asset)
                        let crossesBoundary = idx > 0 && prevGroupID != thisGroupID

                        HStack(spacing: cellSpacing) {
                            if crossesBoundary {
                                Rectangle()
                                    .fill(Color.appTextSecondary.opacity(0.35))
                                    .frame(width: 2, height: cellSize * 0.8)
                                    .padding(.horizontal, 2)
                            }
                            SweepStripCell(
                                asset: asset,
                                size: cellSize,
                                decision: decisions[asset.localIdentifier],
                                isCurrent: asset.localIdentifier == currentAssetID
                            )
                            .onTapGesture {
                                HapticManager.shared.playDragTick()
                                onTap(asset)
                            }
                            .id(asset.localIdentifier)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: assets.map(\.localIdentifier))
            }
            .frame(height: cellSize + 16)
            .onChange(of: currentAssetID) { _, newID in
                guard let newID else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
            .onAppear {
                if let currentAssetID {
                    proxy.scrollTo(currentAssetID, anchor: .center)
                }
            }
        }
    }
}

private struct SweepStripCell: View {
    let asset: PHAsset
    let size: CGFloat
    let decision: Decision?
    let isCurrent: Bool

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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(decision == .delete ? 0.45 : 1.0)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isCurrent ? Color.white : .clear, lineWidth: 2.5)
        )
        .scaleEffect(isCurrent ? 1.08 : 1.0)
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
