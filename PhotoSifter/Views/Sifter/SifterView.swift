import SwiftUI
import Photos

// How many cards ahead to preload full-res images for. Change to tune memory vs. latency.
private let preloadAhead = 3

struct SifterView: View {
    @State private var vm: SifterViewModel
    @State private var showSummary: Bool = false
    @State private var imageCache = ImagePreloadCache()
    @State private var pendingNextGroup: PhotoGroup? = nil
    @State private var isHandlingCompletion: Bool = false
    // Set true on the first handleContinue() per completion event. Guards against
    // a race where the summary's auto-countdown task and the user's tap both fire
    // onContinue — the second call would otherwise see pendingNextGroup as nil
    // and pop the user back to the grid.
    @State private var hasHandledContinue: Bool = false
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.dismiss) private var dismiss

    @State private var mode: QuickWinMode
    @AppStorage("skipUsageCount") private var skipUsageCount: Int = 0

    @State private var dragProgress: Double = 0
    @State private var throwCommand: ThrowCommand? = nil

    init(group: PhotoGroup, mode: QuickWinMode = .none) {
        _vm = State(initialValue: SifterViewModel(group: group))
        _mode = State(initialValue: mode)
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if !vm.isComplete {
                mainContent
            }

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
            await hydrateAndPreload()
        }
    }

    private var navigationTitle: String {
        let total = vm.displayOrder.count
        let decided = vm.group.decisions.count
        return "\(decided) of \(total)"
    }

    // MARK: - Main content

    private var mainContent: some View {
        FlickCardArea(
            currentAsset: vm.currentAsset,
            nextAsset: vm.nextAsset,
            imageCache: imageCache,
            groupID: vm.group.id,
            onSwipeRight: {
                dragProgress = 0
                vm.swipeRight()
                preloadUpcomingCards()
            },
            onSwipeLeft: {
                dragProgress = 0
                vm.swipeLeft()
                preloadUpcomingCards()
            },
            onSkip: vm.canSkipCurrent ? {
                dragProgress = 0
                skipUsageCount += 1
                vm.skipCurrent()
                preloadUpcomingCards()
            } : nil,
            onProgressChange: { dragProgress = $0 },
            throwCommand: throwCommand,
            strip: {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 4)
                        // Full-width gradient bar that is progressively revealed by a
                        // leading-aligned mask. Keeps the color stops anchored to the
                        // ends of the track instead of compressing them.
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [.appAccent, .appKeep], startPoint: .leading, endPoint: .trailing))
                            .frame(height: 4)
                            .mask(
                                HStack(spacing: 0) {
                                    Rectangle().frame(width: geo.size.width * vm.progress)
                                    Spacer(minLength: 0)
                                }
                            )
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
                        preloadUpcomingCards()
                    }
                )
                .padding(.top, 8)
            },
            primaryActions: {
                SifterPrimaryActions(
                    dragProgress: dragProgress,
                    onDelete: {
                        guard vm.currentAsset != nil else { return }
                        throwCommand = ThrowCommand(.left)
                    },
                    onKeep: {
                        guard vm.currentAsset != nil else { return }
                        throwCommand = ThrowCommand(.right)
                    },
                    isEnabled: vm.currentAsset != nil
                )
            },
            bottomBar: {
                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        SifterSecondaryActions(
            onSkip: {
                dragProgress = 0
                skipUsageCount += 1
                vm.skipCurrent()
                preloadUpcomingCards()
            },
            isSkipEnabled: vm.canSkipCurrent,
            apply: nil,
            onRevert: {
                dragProgress = 0
                vm.undo()
                preloadUpcomingCards()
            },
            isRevertEnabled: vm.canUndo
        )
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

    /// If there's a next batch, swap the view model in place so the user
    /// stays on the same screen — popping to the library and re-pushing
    /// would briefly reveal the grid behind the summary.
    private func handleContinue() {
        guard !hasHandledContinue else { return }
        hasHandledContinue = true
        guard let next = pendingNextGroup else {
            dismiss()
            return
        }
        vm = SifterViewModel(group: next)
        mode = .none
        pendingNextGroup = nil
        showSummary = false
        isHandlingCompletion = false
        imageCache.removeAll()
        Task { await hydrateAndPreload() }
    }

    private func hydrateAndPreload() async {
        // Re-hydrate from disk so the resume point is correct even if
        // in-memory propagation through the navigation binding missed
        // the latest decisions.
        let hydrated = await GroupingService.shared.hydrateDecisions(into: [vm.group]).first
        if let hydrated, hydrated.decisions.count > vm.group.decisions.count {
            vm.applyHydratedGroup(hydrated)
        }
        preloadUpcomingCards()
        // If the group was already complete on load (e.g., re-entering after a
        // cancelled deletion prompt), reset decisions so the user can reconsider
        // from scratch rather than being sent straight to commit.
        if vm.isComplete && !showSummary {
            vm.resetAllDecisions()
            await libraryVM.saveGroupProgress(vm.group)
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
        hasHandledContinue = false
        isHandlingCompletion = true
        defer { isHandlingCompletion = false }
        await vm.commitDeletes()
        switch vm.deletionOutcome {
        case .committed:
            SoundManager.shared.playSuccess()
            pendingNextGroup = libraryVM.nextIncompleteGroup(after: vm.group)
            let keptIDs = vm.group.assets
                .filter { vm.group.decisions[$0.localIdentifier] != .delete }
                .map { $0.localIdentifier }
            // group.totalFileBytes is populated by GroupingService.byteFilled, so
            // kept bytes = total - deleted without another PHAssetResource pass.
            let keptBytes = max(0, vm.group.totalFileBytes - vm.deletedBytes)
            let batch = CompletedBatch(
                id: UUID(),
                photoCount: vm.group.assets.count,
                deletedCount: vm.deletedCount,
                savedBytes: vm.deletedBytes,
                completedAt: Date(),
                captureDate: vm.group.captureDate,
                previewAssetIdentifiers: vm.group.assets.prefix(4).map { $0.localIdentifier },
                keptAssetIdentifiers: keptIDs,
                keptBytes: keptBytes,
                sourceGroupID: vm.group.id
            )
            await libraryVM.recordCompletedBatch(batch)
            libraryVM.markGroupComplete(vm.group)
        case .nothingToDelete:
            pendingNextGroup = libraryVM.nextIncompleteGroup(after: vm.group)
            let keptIDs = vm.group.assets.map { $0.localIdentifier }
            await libraryVM.recordCompletedBatch(CompletedBatch(
                id: UUID(),
                photoCount: vm.group.assets.count,
                deletedCount: 0,
                savedBytes: 0,
                completedAt: Date(),
                captureDate: vm.group.captureDate,
                previewAssetIdentifiers: vm.group.assets.prefix(4).map { $0.localIdentifier },
                keptAssetIdentifiers: keptIDs,
                keptBytes: vm.group.totalFileBytes,
                sourceGroupID: vm.group.id
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

    // MARK: - Preloading

    private func preloadUpcomingCards() {
        let upcoming = vm.upcomingAssets(count: preloadAhead)
        for asset in upcoming {
            let id = asset.localIdentifier
            guard imageCache.image(for: id) == nil else { continue }
            Task(priority: .utility) {
                if case .loaded(let img) = await PhotoLibraryService.shared.loadDisplayImage(for: asset) {
                    imageCache.set(img, for: id)
                }
            }
        }
        Task.detached(priority: .background) {
            for asset in upcoming {
                _ = asset.creationDate
                _ = asset.location
                _ = PHAssetResource.assetResources(for: asset)
            }
        }
    }
}
