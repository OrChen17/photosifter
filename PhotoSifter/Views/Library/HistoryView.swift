import SwiftUI

struct HistoryView: View {
    @Environment(LibraryViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if vm.completedBatches.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            statsSection

                            if !vm.revisitableBatches.isEmpty {
                                revisitSection
                            }
                            if !vm.historyOnlyBatches.isEmpty {
                                historySection
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(item: $vm.selectedRestoreSession) { session in
                SifterView(group: session.group)
            }
        }
    }

    // MARK: - Stats section

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ], spacing: 10) {
                statTile(
                    value: "\(vm.totalKeptCount)",
                    label: "Kept",
                    color: .appKeep
                )
                statTile(
                    value: "\(vm.totalDeletedCount)",
                    label: "Deleted",
                    color: .appDelete
                )
                statTile(
                    value: ByteCountFormatter.string(fromByteCount: vm.unflickedBytes, countStyle: .file),
                    label: "Unflicked",
                    color: .white
                )
                statTile(
                    value: ByteCountFormatter.string(fromByteCount: vm.totalSavedBytes, countStyle: .file),
                    label: "Saved",
                    color: .appAccent
                )
            }

            CoverageBarView(
                keptCount: vm.totalKeptCount,
                deletedCount: vm.totalDeletedCount,
                unflickedCount: vm.unflickedCount
            )
        }
        .padding(16)
        .background(Color.appCard.opacity(0.3), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func statTile(value: String, label: String, color: Color, isLoading: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.appTextSecondary)
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.55)
                        .tint(.appTextSecondary)
                        .frame(width: 12, height: 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Revisit section

    private var revisitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Revisit", subtitle: "Tap to re-flick kept photos")
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(vm.revisitableBatches) { batch in
                    CompletedBatchCardView(batch: batch)
                        .onTapGesture {
                            HapticManager.shared.playNavigate()
                            Task { await vm.restoreBatch(batch) }
                        }
                        .accessibilityIdentifier("revisitCard_\(batch.id)")
                }
            }
        }
    }

    // MARK: - History section

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Completed", subtitle: nil)
            VStack(spacing: 8) {
                ForEach(vm.historyOnlyBatches) { batch in
                    HistoryRowView(batch: batch)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.appTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Empty

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
