import SwiftUI
import Photos

struct CompletedBatchCardView: View {
    let batch: CompletedBatch
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage? = nil

    var body: some View {
        VStack(spacing: 0) {
            thumbnailStack

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(batch.photoCount) photos")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    if batch.deletedCount > 0 {
                        Text("·").foregroundStyle(.appTextSecondary)
                        Text("\(batch.deletedCount) deleted")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.appDelete)
                    }
                }
                .lineLimit(1)

                HStack(spacing: 6) {
                    if let date = batch.captureDate {
                        Text(date, format: .dateTime.month(.abbreviated).day().year())
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.appTextSecondary)
                    }
                    if batch.savedBytes > 0 {
                        if batch.captureDate != nil {
                            Text("·").foregroundStyle(.appTextSecondary)
                        }
                        Text(ByteCountFormatter.string(fromByteCount: batch.savedBytes, countStyle: .file))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.appKeep)
                    }
                }
                .lineLimit(1)
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
        .task { await loadThumbnail() }
    }

    /// One hero thumbnail with 1–2 thin card-edge strips peeking from the top to
    /// suggest a stack of completed photos. Mirrors `MemoryCardView.thumbnailStack`.
    private var thumbnailStack: some View {
        GeometryReader { geo in
            let peek: CGFloat = 8
            let numBackLayers = min(batch.photoCount - 1, 2)
            let frontHeight = geo.size.height - CGFloat(numBackLayers) * peek
            ZStack(alignment: .bottom) {
                ForEach(0..<numBackLayers, id: \.self) { idx in
                    let fromFront = numBackLayers - idx
                    let inset = CGFloat(fromFront) * 6
                    let opacity = 0.20 + Double(numBackLayers - fromFront) * 0.16
                    RoundedRectangle(cornerRadius: 14 - CGFloat(fromFront), style: .continuous)
                        .fill(Color.white.opacity(opacity))
                        .frame(
                            width: geo.size.width - inset * 2,
                            height: frontHeight + CGFloat(fromFront) * peek
                        )
                }
                Group {
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.appBackground
                    }
                }
                .frame(width: geo.size.width, height: frontHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func loadThumbnail() async {
        guard let firstID = batch.previewAssetIdentifiers.first else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [firstID], options: nil)
        guard let asset = result.firstObject else { return }
        let px = 200.0 * displayScale
        let size = CGSize(width: px, height: px)
        if let img = await PhotoLibraryService.shared.loadThumbnail(for: asset, size: size) {
            thumbnail = img
        }
    }
}
