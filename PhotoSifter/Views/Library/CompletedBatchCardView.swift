import SwiftUI
import Photos

struct CompletedBatchCardView: View {
    let batch: CompletedBatch
    @State private var thumbnails: [UIImage] = []

    var body: some View {
        VStack(spacing: 0) {
            thumbnailGrid
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("\(batch.photoCount) photos")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let date = batch.captureDate {
                    Text(date, format: .dateTime.month(.abbreviated).day().year())
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    if batch.deletedCount > 0 {
                        Text("\(batch.deletedCount) deleted")
                            .foregroundStyle(.appDelete)
                    }
                    if batch.deletedCount > 0 && batch.savedBytes > 0 {
                        Text("·").foregroundStyle(.appTextSecondary)
                    }
                    if batch.savedBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: batch.savedBytes, countStyle: .file))
                            .foregroundStyle(.appKeep)
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(Color.appCard.opacity(0.3), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .task { await loadThumbnails() }
    }

    private var thumbnailGrid: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                GeometryReader { geo in
                    let half = geo.size.width / 2
                    LazyVGrid(
                        columns: [GridItem(.fixed(half), spacing: 2), GridItem(.fixed(half), spacing: 2)],
                        spacing: 2
                    ) {
                        ForEach(0..<min(4, batch.previewAssetIdentifiers.count), id: \.self) { i in
                            Group {
                                if i < thumbnails.count {
                                    Image(uiImage: thumbnails[i])
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: half, height: half)
                                        .clipped()
                                } else {
                                    Color.appBackground
                                        .frame(width: half, height: half)
                                }
                            }
                        }
                    }
                }
            )
    }

    private func loadThumbnails() async {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: batch.previewAssetIdentifiers, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { a, _, _ in assets.append(a) }
        let size = CGSize(width: 200, height: 200)
        for asset in assets.prefix(4) {
            if let img = await PhotoLibraryService.shared.loadThumbnail(for: asset, size: size) {
                thumbnails.append(img)
            }
        }
    }
}
