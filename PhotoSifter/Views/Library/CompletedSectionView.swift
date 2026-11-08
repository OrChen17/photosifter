import SwiftUI

struct CompletedSectionView: View {
    let completedBatches: [CompletedBatch]
    let totalDeletedCount: Int
    let totalSavedBytes: Int64

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.35)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Completed")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.appForeground)
                        Text(subtitleText)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.appTextSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.appTextSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(.spring(duration: 0.35), value: isExpanded)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            if isExpanded {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(completedBatches) { batch in
                        CompletedBatchCardView(batch: batch)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.appCard.opacity(0.3), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var subtitleText: String {
        var parts: [String] = []
        if totalDeletedCount > 0 {
            parts.append("\(totalDeletedCount) deleted")
        }
        if totalSavedBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: totalSavedBytes, countStyle: .file) + " saved")
        }
        return parts.isEmpty ? "\(completedBatches.count) batches" : parts.joined(separator: " · ")
    }
}
