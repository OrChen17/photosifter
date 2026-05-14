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
    // Horizontal swipe progress reported by SwipeCardView in [-1, +1].
    // Drives the screen-wide vignette: + = keep (green), - = delete (red).
    @State private var swipeProgress: Double = 0
    @State private var showExitConfirmation: Bool = false
    @AppStorage("midBatchAlwaysSave") private var midBatchAlwaysSave: Bool = false
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.dismiss) private var dismiss

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

            // Screen-wide vignette overlay driven by drag progress. Multi-stop
            // gradient: fully clear at center, tint at the screen edges.
            swipeVignette
                .allowsHitTesting(false)
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            backButton
        }
        .confirmationDialog(
            "Exit batch?",
            isPresented: $showExitConfirmation,
            titleVisibility: .visible
        ) {
            Button("Save Progress") {
                Task {
                    await libraryVM.saveGroupProgress(vm.group)
                    dismiss()
                }
            }
            Button("Don't Save", role: .destructive) {
                dismiss()
            }
            Button("Always Save (don't ask again)") {
                midBatchAlwaysSave = true
                Task {
                    await libraryVM.saveGroupProgress(vm.group)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your decisions will be saved, but no photos will be deleted until you finish this batch.")
        }
        .fullScreenCover(isPresented: $showSummary) {
            SessionSummaryView(
                group: vm.group,
                nextGroup: libraryVM.nextIncompleteGroup(after: vm.group),
                outcome: vm.deletionOutcome,
                onContinue: { handleContinue() },
                onRetry: { Task { await vm.retryCommitDeletes() } }
            )
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
                await vm.commitDeletes()
                // Only mark the group complete + clear persisted state when
                // the deletion actually succeeded (or there was nothing to
                // delete). On cancel/failure the decisions stay saved so the
                // user can retry from the summary screen.
                switch vm.deletionOutcome {
                case .committed, .nothingToDelete:
                    libraryVM.markGroupComplete(vm.group)
                case .cancelledByUser, .failed, .none:
                    await libraryVM.saveGroupProgress(vm.group)
                }
                try? await Task.sleep(for: .milliseconds(600))
                showSummary = true
            }
        }
        .onChange(of: vm.deletionOutcome) { _, newOutcome in
            // Retry path: once commitDeletes finishes on retry, refresh the
            // group's completion state in the library if it now committed.
            guard newOutcome == .committed else { return }
            libraryVM.markGroupComplete(vm.group)
        }
        .onChange(of: vm.currentIndex) { _, _ in
            preloadUpcomingCards()
        }
        .task {
            // Re-hydrate from disk on appear so the resume point is correct
            // even if in-memory propagation through the navigation binding
            // missed the latest decisions.
            let hydrated = await GroupingService.shared.hydrateDecisions(into: [vm.group]).first
            if let hydrated, hydrated.decisions.count > vm.group.decisions.count {
                vm.applyHydratedGroup(hydrated)
            }
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
            BatchStripView(
                group: vm.group,
                currentAssetID: vm.currentAsset?.localIdentifier,
                onTap: { asset in
                    vm.jumpTo(asset: asset)
                    cardKey = UUID()
                    swipeProgress = 0
                    preloadUpcomingCards()
                }
            )
            .padding(.top, 8)

            if let asset = vm.currentAsset {
                SwipeCardView(
                    asset: asset,
                    groupFirstDate: groupFirstDate,
                    preloadedImage: imageCache[asset.localIdentifier],
                    onSwipeRight: {
                        vm.swipeRight()
                        cardKey = UUID()
                        swipeProgress = 0
                        preloadUpcomingCards()
                    },
                    onSwipeLeft: {
                        if vm.isLastUndecidedWithNoKept {
                            showDeleteLastWarning = true
                        } else {
                            vm.swipeLeft()
                            cardKey = UUID()
                            swipeProgress = 0
                            preloadUpcomingCards()
                        }
                    },
                    onSkip: vm.canSkipCurrent ? {
                        vm.skipCurrent()
                        cardKey = UUID()
                        swipeProgress = 0
                        preloadUpcomingCards()
                    } : nil,
                    onProgressChange: { swipeProgress = $0 }
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

            // Keep-only button — kept because it's a useful shortcut that
            // isn't expressible by a single swipe. Delete/Keep labels removed:
            // swipes already convey direction, and the strip tint shows state.
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
                .frame(maxWidth: .infinity)
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
    private var backButton: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                handleBackTapped()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Library")
                        .font(.system(size: 17))
                }
                .foregroundStyle(.white)
            }
            .accessibilityIdentifier("backButton")
        }
    }

    /// Pop the current SifterView back to the library, then — after the
    /// pop animation — push the next chronological batch (if any).
    /// Doing it in two beats is more reliable than swapping `selectedGroup`
    /// to a new value while the destination is still mounted, which
    /// NavigationStack tends to ignore.
    private func handleContinue() {
        let next = libraryVM.nextIncompleteGroup(after: vm.group)
        dismiss()
        guard let next else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            libraryVM.selectedGroup = next
        }
    }

    private func handleBackTapped() {
        guard vm.hasUnsavedDecisions else {
            dismiss()
            return
        }
        if midBatchAlwaysSave {
            Task {
                await libraryVM.saveGroupProgress(vm.group)
                dismiss()
            }
        } else {
            showExitConfirmation = true
        }
    }

    // MARK: - Swipe vignette

    private var swipeVignette: some View {
        GeometryReader { geo in
            // Map progress [-1, 0, +1] -> intensity [1, 0, 1], direction sign
            let magnitude = abs(swipeProgress)
            let tint: Color = swipeProgress >= 0 ? .appKeep : .appDelete
            // Hypotenuse so the strongest stop sits beyond the corners.
            let radius = hypot(geo.size.width, geo.size.height) * 0.6

            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear,                         location: 0.00),
                    .init(color: .clear,                         location: 0.32),
                    .init(color: tint.opacity(magnitude * 0.04), location: 0.46),
                    .init(color: tint.opacity(magnitude * 0.09), location: 0.58),
                    .init(color: tint.opacity(magnitude * 0.16), location: 0.69),
                    .init(color: tint.opacity(magnitude * 0.26), location: 0.79),
                    .init(color: tint.opacity(magnitude * 0.38), location: 0.88),
                    .init(color: tint.opacity(magnitude * 0.52), location: 0.95),
                    .init(color: tint.opacity(magnitude * 0.68), location: 1.00),
                ]),
                center: .center,
                startRadius: 0,
                endRadius: radius
            )
            .animation(.easeOut(duration: 0.15), value: swipeProgress)
            .ignoresSafeArea()
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
