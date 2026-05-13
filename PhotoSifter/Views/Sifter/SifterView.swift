import SwiftUI
import Photos

// How many cards ahead to preload full-res images for. Change to tune memory vs. latency.
private let preloadAhead = 3

struct SifterView: View {
    @State private var vm: SifterViewModel
    @State private var showSummary: Bool = false
    @State private var cardKey: UUID = UUID()
    @State private var showDeleteLastWarning: Bool = false
    @State private var imageCache: [String: UIImage] = [:]
    @Environment(LibraryViewModel.self) private var libraryVM

    private var groupFirstDate: Date? {
        vm.group.assets.compactMap { $0.creationDate }.min()
    }

    init(group: PhotoGroup) {
        _vm = State(initialValue: SifterViewModel(group: group))
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if vm.isComplete {
                completionFlash
            } else {
                mainContent
            }
        }
        .navigationBarBackButtonHidden(false)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar { undoButton }
        .fullScreenCover(isPresented: $showSummary) {
            SessionSummaryView(group: vm.group)
        }
        .alert("Delete All Photos?", isPresented: $showDeleteLastWarning) {
            Button("Delete Anyway", role: .destructive) {
                vm.swipeLeft()
                cardKey = UUID()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You haven't kept any photo from this group. Deleting this one removes all of them.")
        }
        .onChange(of: vm.isComplete) { _, complete in
            guard complete else { return }
            Task {
                // Commit queued deletes, then show summary
                await vm.commitDeletes()
                libraryVM.markGroupComplete(vm.group)
                try? await Task.sleep(for: .milliseconds(800))
                showSummary = true
            }
        }
        .onChange(of: vm.currentIndex) { _, _ in
            preloadUpcomingCards()
        }
        .task {
            preloadUpcomingCards()
        }
    }

    private var navigationTitle: String {
        let total = vm.displayOrder.count
        let current = min(vm.currentIndex + 1, total)
        return "\(current) of \(total)"
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            BatchStripView(group: vm.group, currentAssetID: vm.currentAsset?.localIdentifier)
                .padding(.top, 8)

            if let asset = vm.currentAsset {
                SwipeCardView(
                    asset: asset,
                    groupFirstDate: groupFirstDate,
                    preloadedImage: imageCache[asset.localIdentifier],
                    onSwipeRight: {
                        vm.swipeRight()
                        cardKey = UUID()
                        preloadUpcomingCards()
                    },
                    onSwipeLeft: {
                        if vm.isLastUndecidedWithNoKept {
                            showDeleteLastWarning = true
                        } else {
                            vm.swipeLeft()
                            cardKey = UUID()
                            preloadUpcomingCards()
                        }
                    },
                    onSkip: vm.canSkipCurrent ? {
                        vm.skipCurrent()
                        cardKey = UUID()
                        preloadUpcomingCards()
                    } : nil
                )
                .id(cardKey)
                .accessibilityIdentifier("photoCard")
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            bottomBar
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 14) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [.appAccent, .appKeep], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * vm.progress, height: 4)
                        .animation(.spring(duration: 0.4), value: vm.progress)
                }
            }
            .frame(height: 4)

            // Swipe hints + keep-only button
            HStack(spacing: 0) {
                Label("Delete", systemImage: "xmark")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.appDelete.opacity(0.7))

                Spacer()

                // Keep-only button — shown when group has 3+ photos so it's genuinely useful
                if vm.group.assets.count >= 3 {
                    Button {
                        vm.keepOnlyCurrentAndDeleteRest()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "star.circle")
                            Text("Keep only this")
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.appAccent)
                    }
                }

                Spacer()

                Label("Keep", systemImage: "checkmark")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.appKeep.opacity(0.7))
            }

            // Skip hint — only shown if skipping is available
            if vm.canSkipCurrent {
                Text("Swipe ↑ to skip")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.appTextSecondary)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var undoButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { vm.undo() } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(vm.canUndo ? .white : .appTextSecondary)
                    .accessibilityIdentifier("undoButton")
            }
            .disabled(!vm.canUndo)
        }
    }

    // MARK: - Completion flash

    private var completionFlash: some View {
        VStack(spacing: 24) {
            Spacer()
            Group {
                if vm.isCommittingDeletes {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.appAccent)
                } else {
                    Image(systemName: "star.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.appAccent)
                        .symbolEffect(.bounce)
                }
            }
            Text(vm.isCommittingDeletes ? "Cleaning up…" : "Batch done!")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
        }
    }

    // MARK: - Preloading

    private func preloadUpcomingCards() {
        let assets = vm.displayOrder
        let start = vm.currentIndex + 1
        let end = min(start + preloadAhead, assets.count)
        guard start < end else { return }
        for i in start..<end {
            let asset = assets[i]
            let id = asset.localIdentifier
            guard imageCache[id] == nil else { continue }
            Task(priority: .utility) {
                if let img = await PhotoLibraryService.shared.loadFullImage(for: asset) {
                    imageCache[id] = img
                }
            }
        }
    }
}
