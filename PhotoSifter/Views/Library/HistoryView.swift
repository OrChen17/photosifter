import SwiftUI

struct HistoryView: View {
    @Environment(LibraryViewModel.self) private var vm

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if vm.completedBatches.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        statsHeader
                            .padding(.horizontal, 16)
                            .padding(.top, 8)

                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(vm.completedBatches) { batch in
                                CompletedBatchCardView(batch: batch)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        Spacer().frame(height: 32)
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private var statsHeader: some View {
        HStack(spacing: 12) {
            statPill(
                value: "\(vm.totalDeletedCount)",
                label: "deleted",
                color: .appDelete
            )

            if vm.totalSavedBytes > 0 {
                statPill(
                    value: ByteCountFormatter.string(fromByteCount: vm.totalSavedBytes, countStyle: .file),
                    label: "saved",
                    color: .appKeep
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statPill(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.appTextSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 56))
                .foregroundStyle(.appTextSecondary)

            Text("No history yet")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Completed sifting sessions will appear here.")
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.appTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
