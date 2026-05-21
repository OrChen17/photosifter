import SwiftUI

/// Compact one-row representation of a completed batch where there are no
/// kept photos left to thumbnail (every photo was deleted, or the batch is
/// from before kept-asset tracking existed). Shows the metadata the user
/// asked for: date, # deleted, MB saved. No thumbnail = no black tiles.
struct HistoryRowView: View {
    let batch: CompletedBatch

    private static let dateFormat: Date.FormatStyle =
        .dateTime.month(.abbreviated).day().year()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.appKeep.opacity(0.7))

            VStack(alignment: .leading, spacing: 2) {
                if let date = batch.captureDate {
                    Text(date, format: Self.dateFormat)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                } else {
                    Text("Batch")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }

                HStack(spacing: 6) {
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
                    if batch.deletedCount == 0 && batch.savedBytes == 0 {
                        Text("Reviewed — nothing deleted")
                            .foregroundStyle(.appTextSecondary)
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appCard.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}
