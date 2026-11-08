import SwiftUI
import Photos

/// Card for the History tab's "Revisit" section — a completed batch that still
/// has kept photos the user can re-flick. The hero thumbnail uses the FIRST
/// kept asset (never a deleted one, so no black tiles), and a revive icon in
/// the corner signals that tapping re-opens the batch.
struct CompletedBatchCardView: View {
    let batch: CompletedBatch
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage? = nil

    var body: some View {
        VStack(spacing: 0) {
            thumbnailStack

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(keptCount) remaining")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.appForeground)
                    Spacer(minLength: 4)
                    if let bytes = batch.keptBytes, bytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.appTextSecondary)
                    }
                }
                .lineLimit(1)

                HStack(spacing: 6) {
                    if let date = batch.captureDate {
                        Text(date, format: .dateTime.month(.abbreviated).day().year())
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.appTextSecondary)
                    }
                    Spacer(minLength: 4)
                    if batch.deletedCount > 0 {
                        Text("\(batch.deletedCount) deleted")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.appDelete)
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
                .stroke(Color.appForeground.opacity(0.06), lineWidth: 1)
        )
        .task { await loadThumbnail() }
    }

    /// Kept photos available to re-flick. Falls back to `photoCount - deletedCount`
    /// for legacy batches without explicit kept-asset tracking.
    private var keptCount: Int {
        batch.keptAssetIdentifiers?.count ?? max(0, batch.photoCount - batch.deletedCount)
    }

    /// One kept-asset hero with 1–2 card-edge strips peeking from the top.
    /// The revive icon overlay invites the user to tap and re-flick.
    private var thumbnailStack: some View {
        GeometryReader { geo in
            let peek: CGFloat = 7
            let numBackLayers = min(max(0, keptCount - 1), 2)
            let frontHeight = geo.size.height - CGFloat(numBackLayers) * peek
            ZStack(alignment: .bottom) {
                ForEach(0..<numBackLayers, id: \.self) { idx in
                    let fromFront = numBackLayers - idx
                    let inset = CGFloat(fromFront) * 6
                    let opacity = 0.20 + Double(numBackLayers - fromFront) * 0.16
                    RoundedRectangle(cornerRadius: 14 - CGFloat(fromFront), style: .continuous)
                        .fill(Color.appForeground.opacity(opacity))
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
                .overlay(alignment: .topTrailing) { reviveBadge }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var reviveBadge: some View {
        Image(systemName: "arrow.counterclockwise.circle.fill")
            .font(.system(size: 22))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.appAccent)
            .padding(8)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
    }

    private func loadThumbnail() async {
        // Only kept assets can be thumbnailed. Anything in
        // `previewAssetIdentifiers` may have been deleted from Photos and
        // would render as the placeholder color.
        guard let firstID = batch.keptAssetIdentifiers?.first else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [firstID], options: nil)
        guard let asset = result.firstObject else { return }
        let px = 200.0 * displayScale
        let size = CGSize(width: px, height: px)
        if let img = await PhotoLibraryService.shared.loadThumbnail(for: asset, size: size) {
            thumbnail = img
        }
    }
}
