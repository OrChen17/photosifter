import SwiftUI
import Photos

// How many cards ahead to preload full-res images for. Change to tune memory vs. latency.
private let preloadAhead = 3

struct SifterView: View {
    @State private var vm: SifterViewModel
    @State private var showSummary: Bool = false
    @State private var cardKey: UUID = UUID()
    @State private var imageCache: [String: UIImage] = [:]
    // Horizontal swipe progress reported by SwipeCardView in [-1, +1].
    // Drives the screen-wide vignette: + = keep (green), - = delete (red).
    @State private var swipeProgress: Double = 0
    @State private var flashTint: Color = .appKeep
    @State private var flashIntensity: Double = 0
    @State private var isTopCardThrown: Bool = false
    @State private var cardAppearWobble: Double = 1.5
    @AppStorage("skipUsageCount") private var skipUsageCount: Int = 0
    @State private var pendingNextGroup: PhotoGroup? = nil
    @State private var isHandlingCompletion: Bool = false
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.dismiss) private var dismiss

    private let mode: QuickWinMode

    init(group: PhotoGroup, mode: QuickWinMode = .none) {
        _vm = State(initialValue: SifterViewModel(group: group))
        self.mode = mode
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

            if showSummary {
                SessionSummaryView(
                    group: vm.group,
                    nextGroup: pendingNextGroup,
                    outcome: vm.deletionOutcome,
                    deletedBytes: vm.deletedBytes,
                    onDismiss: { withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { showSummary = false } },
                    onContinue: { handleContinue() },
                    onRetry: { Task { await vm.retryCommitDeletes() } }
                )
                .transition(.scale(scale: 0.88, anchor: .center).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            backButton
        }
        .onChange(of: vm.isComplete) { _, complete in
            guard complete else { return }
            Task { await runCompletionFlow() }
        }
        .onChange(of: vm.deletionOutcome) { _, newOutcome in
            // Only active on the retry path — runCompletionFlow owns the initial commit.
            // Without this guard, both handlers fire after the first commitDeletes() call
            // because setting deletionOutcome during an await suspension triggers onChange.
            guard !isHandlingCompletion else { return }
            switch newOutcome {
            case .committed:
                if pendingNextGroup == nil {
                    pendingNextGroup = libraryVM.nextIncompleteGroup(after: vm.group)
                }
                SoundManager.shared.playSuccess()
                libraryVM.markGroupComplete(vm.group)
            case .cancelledByUser, .failed:
                SoundManager.shared.playFailure()
            default:
                break
            }
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
            // If the group was already complete before this view appeared (e.g.,
            // re-entering after a cancelled deletion prompt), isComplete is true
            // from init and onChange never fires. Reset all decisions so the user
            // can reconsider from scratch rather than being sent straight to commit.
            if vm.isComplete && !showSummary {
                vm.resetAllDecisions()
                // Clear the stale persisted decisions so re-entry next time is clean.
                await libraryVM.saveGroupProgress(vm.group)
            }
        }
    }

    private var navigationTitle: String {
        let total = vm.displayOrder.count
        let decided = vm.group.decisions.count
        return "\(decided) of \(total)"
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
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
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)

            BatchStripView(
                group: vm.group,
                currentAssetID: vm.currentAsset?.localIdentifier,
                onTap: { asset in
                    vm.jumpTo(asset: asset)
                    cardKey = UUID()
                    isTopCardThrown = false
                    swipeProgress = 0
                    preloadUpcomingCards()
                }
            )
            .padding(.top, 8)

            if let asset = vm.currentAsset {
                ZStack {
                    // Next card pre-rendered behind the current one — already
                    // visible so there's no pop-in when the top card flies away.
                    if let next = nextPreviewAsset {
                        SwipeCardView(
                            asset: next,
                            preloadedImage: imageCache[next.localIdentifier],
                            onSwipeRight: {},
                            onSwipeLeft: {}
                        )
                        .scaleEffect(isTopCardThrown ? 1.0 : 0.95)
                        .offset(y: isTopCardThrown ? 0 : 10)
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isTopCardThrown)
                        .allowsHitTesting(false)
                        .id(next.localIdentifier)
                    }

                    SwipeCardView(
                        asset: asset,
                        preloadedImage: imageCache[asset.localIdentifier],
                        onSwipeRight: {
                            vm.swipeRight()
                            cardKey = UUID()
                            isTopCardThrown = false
                            swipeProgress = 0
                            preloadUpcomingCards()
                        },
                        onSwipeLeft: {
                            vm.swipeLeft()
                            cardKey = UUID()
                            isTopCardThrown = false
                            swipeProgress = 0
                            preloadUpcomingCards()
                        },
                        onSkip: vm.canSkipCurrent ? {
                            skipUsageCount += 1
                            vm.skipCurrent()
                            cardKey = UUID()
                            isTopCardThrown = false
                            swipeProgress = 0
                            preloadUpcomingCards()
                        } : nil,
                        onProgressChange: { swipeProgress = $0 },
                        onThrowRight: {
                            isTopCardThrown = true
                            triggerFlash(tint: .appKeep)
                            HapticManager.shared.playKeep()
                            SoundManager.shared.playKeep()
                        },
                        onThrowLeft: {
                            isTopCardThrown = true
                            triggerFlash(tint: .appDelete)
                            HapticManager.shared.playDelete()
                            SoundManager.shared.playDelete()
                        }
                    )
                    .id(cardKey)
                    .rotationEffect(.degrees(cardAppearWobble))
                    .onAppear {
                        guard cardAppearWobble != 0 else { return }
                        Task {
                            try? await Task.sleep(for: .milliseconds(120))
                            withAnimation(.spring(duration: 0.7, bounce: 0.45)) { cardAppearWobble = 0 }
                        }
                    }
                    .accessibilityIdentifier("photoCard")
                }
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
            switch mode {
            case .screenshots:
                Button {
                    vm.deleteAll()
                    cardKey = UUID()
                    swipeProgress = 0
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash.circle")
                        Text("Delete All Screenshots")
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.appDelete)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("deleteAllButton")

            case .duplicates:
                Button {
                    vm.keepOldestAndDeleteRest()
                    cardKey = UUID()
                    swipeProgress = 0
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.badge.checkmark")
                        Text("Keep Oldest Only")
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.appAccent)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("keepOldestButton")

            case .none:
                if vm.group.assets.count >= 2 {
                    Button {
                        vm.deleteAll()
                        cardKey = UUID()
                        swipeProgress = 0
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash.circle")
                            Text("Delete all remaining")
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("deleteAllRemainingButton")
                }
            }

            if vm.canSkipCurrent && skipUsageCount < 3 {
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
        let next = pendingNextGroup
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
        Task {
            await libraryVM.saveGroupProgress(vm.group)
            dismiss()
        }
    }

    // Shared completion logic called both from onChange(of: vm.isComplete) and
    // from .task when isComplete is already true at view load (re-entry after cancel).
    private func runCompletionFlow() async {
        isHandlingCompletion = true
        defer { isHandlingCompletion = false }
        await vm.commitDeletes()
        switch vm.deletionOutcome {
        case .committed:
            SoundManager.shared.playSuccess()
            pendingNextGroup = libraryVM.nextIncompleteGroup(after: vm.group)
            let batch = CompletedBatch(
                id: UUID(),
                photoCount: vm.group.assets.count,
                deletedCount: vm.deletedCount,
                savedBytes: vm.deletedBytes,
                completedAt: Date(),
                captureDate: vm.group.captureDate,
                previewAssetIdentifiers: vm.group.assets.prefix(4).map { $0.localIdentifier }
            )
            await libraryVM.recordCompletedBatch(batch)
            libraryVM.markGroupComplete(vm.group)
        case .nothingToDelete:
            pendingNextGroup = libraryVM.nextIncompleteGroup(after: vm.group)
            await libraryVM.recordCompletedBatch(CompletedBatch(
                id: UUID(),
                photoCount: vm.group.assets.count,
                deletedCount: 0,
                savedBytes: 0,
                completedAt: Date(),
                captureDate: vm.group.captureDate,
                previewAssetIdentifiers: vm.group.assets.prefix(4).map { $0.localIdentifier }
            ))
            libraryVM.markGroupComplete(vm.group)
        case .cancelledByUser, .failed:
            SoundManager.shared.playFailure()
            await libraryVM.saveGroupProgress(vm.group)
        case .none:
            await libraryVM.saveGroupProgress(vm.group)
        }
        try? await Task.sleep(for: .milliseconds(50))
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { showSummary = true }
    }

    // MARK: - Swipe vignette

    private var swipeVignette: some View {
        GeometryReader { geo in
            let radius = hypot(geo.size.width, geo.size.height) * 0.6
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear,                                location: 0.00),
                    .init(color: .clear,                                location: 0.32),
                    .init(color: flashTint.opacity(flashIntensity * 0.04), location: 0.46),
                    .init(color: flashTint.opacity(flashIntensity * 0.09), location: 0.58),
                    .init(color: flashTint.opacity(flashIntensity * 0.16), location: 0.69),
                    .init(color: flashTint.opacity(flashIntensity * 0.26), location: 0.79),
                    .init(color: flashTint.opacity(flashIntensity * 0.38), location: 0.88),
                    .init(color: flashTint.opacity(flashIntensity * 0.52), location: 0.95),
                    .init(color: flashTint.opacity(flashIntensity * 0.68), location: 1.00),
                ]),
                center: .center,
                startRadius: 0,
                endRadius: radius
            )
            .ignoresSafeArea()
        }
    }

    private func triggerFlash(tint: Color) {
        flashTint = tint
        withAnimation(.easeOut(duration: 0.08)) {
            flashIntensity = 1.0
        }
        withAnimation(.easeOut(duration: 0.35).delay(0.08)) {
            flashIntensity = 0
        }
    }

    // MARK: - Completion flash

    private var completionFlash: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
                .tint(.appAccent)
            Text("Cleaning up…")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.appTextSecondary)
            Spacer()
        }
    }

    // MARK: - Preloading

    private var nextPreviewAsset: PHAsset? {
        vm.nextAsset
    }

    private func preloadUpcomingCards() {
        for asset in vm.upcomingAssets(count: preloadAhead) {
            let id = asset.localIdentifier
            guard imageCache[id] == nil else { continue }
            Task(priority: .utility) {
                if case .loaded(let img) = await PhotoLibraryService.shared.loadFullImage(for: asset) {
                    imageCache[id] = img
                }
            }
        }
    }
}
