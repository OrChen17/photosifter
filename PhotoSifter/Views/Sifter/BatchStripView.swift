import SwiftUI
import Photos

struct BatchStripView: View {
    let group: PhotoGroup
    let currentAssetID: String?   // replaces currentIndex — works with skip reordering

    @State private var thumbnails: [String: UIImage] = [:]
    @State private var scrollID: String?

    private let thumbSize: CGFloat = 64

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(group.assets, id: \.localIdentifier) { asset in
                    thumbnail(for: asset)
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
    private func thumbnail(for asset: PHAsset) -> some View {
        let isCurrent = asset.localIdentifier == currentAssetID
        let decision = group.decisions[asset.localIdentifier]

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
            .opacity(decision == .delete ? 0.4 : 1.0)

            if let decision {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(decision == .keep ? Color.appKeep.opacity(0.25) : Color.appDelete.opacity(0.25))
                    .frame(width: thumbSize, height: thumbSize)

                Image(systemName: decision == .keep ? "checkmark" : "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(decision == .keep ? .appKeep : .appDelete)
            }

            if isCurrent {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white, lineWidth: 2.5)
                    .frame(width: thumbSize, height: thumbSize)
            }
        }
        .scaleEffect(isCurrent ? 1.08 : 1.0)
        .animation(.spring(duration: 0.3), value: isCurrent)
    }

    private func loadAllThumbnails() async {
        let size = CGSize(width: thumbSize * 2, height: thumbSize * 2)
        for asset in group.assets {
            let img = await PhotoLibraryService.shared.loadThumbnail(for: asset, size: size)
            if let img { thumbnails[asset.localIdentifier] = img }
        }
    }
}
