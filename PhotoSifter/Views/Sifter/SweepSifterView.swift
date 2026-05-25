import SwiftUI
import Photos

struct SweepSifterView: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.dismiss) private var dismiss
    @State private var vm: SweepSifterViewModel
    @State private var imageCache = ImagePreloadCache()
    @State private var showDiscardConfirm: Bool = false
    @State private var showSweepSummary: Bool = false
    @State private var summaryOutcome: DeletionOutcome? = nil
    @State private var summaryDeletedCount: Int = 0
    @State private var summaryDeletedBytes: Int64 = 0

    @State private var dragProgress: Double = 0
    @State private var throwCommand: ThrowCommand? = nil

    init(groups: [PhotoGroup]) {
        _vm = State(initialValue: SweepSifterViewModel(groups: groups))
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if vm.isQueueExhausted {
                finishedContent
            } else if !vm.isApplying {
                mainContent
            }

            if showSweepSummary {
                if vm.isQueueExhausted {
                    summaryView(paintsBackground: true)
                        .transition(.scale(scale: 0.88, anchor: .center).combined(with: .opacity))
                        .zIndex(10)
                } else {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea()
                            .overlay(Color.black.opacity(0.35).ignoresSafeArea())
                            .contentShape(Rectangle())
                            .onTapGesture { dismissSummary() }

                        summaryView(paintsBackground: false)
                            .frame(maxWidth: 480)
                            .background(
                                Color.appCard,
                                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                            .padding(.horizontal, 20)
                    }
                    .transition(.scale(scale: 0.88, anchor: .center).combined(with: .opacity))
                    .zIndex(10)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { handleBack() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Library").font(.system(size: 17))
                    }
                    .foregroundStyle(.white)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.appDelete)
                        Text("\(vm.sessionDeletedCount)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.appKeep)
                        Text("\(vm.sessionKeptCount)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .alert("Discard \(vm.pendingDeleteCount + vm.pendingKeepCount) pending decisions?",
               isPresented: $showDiscardConfirm) {
            Button("Apply first", role: .none) {
                Task {
                    await runApply()
                    dismiss()
                }
            }
            Button("Discard", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Going back will lose your pending choices unless you apply them first.")
        }
        .task { preloadUpcomingImages() }
        .onChange(of: vm.currentIndex) { _, _ in
            preloadUpcomingImages()
        }
    }

    private var navTitle: String {
        let total = vm.queue.count
        guard total > 0 else { return "Sweep" }
        let position = min(vm.currentIndex + 1, total)
        return "\(position) of \(total)"
    }

    // MARK: - Main content

    private var mainContent: some View {
        FlickCardArea(
            currentAsset: vm.currentAsset,
            nextAsset: vm.nextAsset,
            imageCache: imageCache,
            groupID: AnyHashable("sweep"),
            onSwipeRight: {
                dragProgress = 0
                vm.swipeRight()
            },
            onSwipeLeft:  {
                dragProgress = 0
                vm.swipeLeft()
            },
            onSkip: {
                dragProgress = 0
                vm.skip()
                preloadUpcomingImages()
            },
            onProgressChange: { dragProgress = $0 },
            throwCommand: throwCommand,
            strip: {
                SweepStripView(
                    assets: vm.queue,
                    currentAssetID: vm.currentAsset?.localIdentifier,
                    decisions: vm.decisions,
                    groupID: { vm.groupID(for: $0) },
                    onTap: { vm.jumpTo(asset: $0) }
                )
                .padding(.top, 4)
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
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        SifterSecondaryActions(
            onSkip: {
                dragProgress = 0
                vm.skip()
                preloadUpcomingImages()
            },
            isSkipEnabled: vm.currentAsset != nil,
            apply: SifterSecondaryActions.ApplyConfig(
                label: applyLabel,
                isEnabled: vm.hasPendingDecisions,
                action: { Task { await runApply() } }
            ),
            onRevert: {
                dragProgress = 0
                vm.undo()
            },
            isRevertEnabled: vm.canUndo
        )
    }

    private var applyLabel: String {
        guard vm.hasPendingDecisions else { return "Apply" }
        return "Apply (\(vm.pendingDeleteCount), \(vm.pendingKeepCount))"
    }

    // MARK: - States

    private var finishedContent: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.appKeep)

            Text("Library swept.")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            HStack(spacing: 28) {
                VStack(spacing: 4) {
                    Text("\(vm.sessionDeletedCount)")
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .foregroundStyle(.appDelete)
                    Text("deleted")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                }
                VStack(spacing: 4) {
                    Text("\(vm.sessionKeptCount)")
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .foregroundStyle(.appKeep)
                    Text("kept")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                }
                if vm.sessionDeletedBytes > 0 {
                    VStack(spacing: 4) {
                        Text(ByteCountFormatter.string(fromByteCount: vm.sessionDeletedBytes, countStyle: .file))
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundStyle(.appAccent)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text("freed")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.appTextSecondary)
                    }
                }
            }

            Spacer()

            Button { dismiss() } label: {
                Text("Back to Library")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [.appAccent, Color(hex: "C91E6D")],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Summary helpers

    @ViewBuilder
    private func summaryView(paintsBackground: Bool) -> some View {
        SessionSummaryView(
            group: nil,
            nextGroup: nil,
            outcome: summaryOutcome,
            deletedBytes: summaryDeletedBytes,
            onDismiss: { dismissSummary() },
            onContinue: {
                dismissSummary()
                if vm.isQueueExhausted { dismiss() }
            },
            onRetry: {
                showSweepSummary = false
                Task { await runApply() }
            },
            overrideDeletedCount: summaryDeletedCount,
            continueLabel: vm.isQueueExhausted ? "Back to Library" : "Continue Flicking",
            paintsBackground: paintsBackground,
            statsFontSize: paintsBackground ? 56 : 40
        )
    }

    private func dismissSummary() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
            showSweepSummary = false
        }
    }

    // MARK: - Apply flow

    private func runApply() async {
        guard vm.hasPendingDecisions else { return }
        let snapshot = await vm.apply()
        switch snapshot.outcome {
        case .committed:
            await libraryVM.applySweepResult(snapshot: snapshot)
            SoundManager.shared.playSuccess()
            HapticManager.shared.playBatchComplete()
        case .nothingToDelete:
            // All keeps, no deletes — still hand the snapshot off so each
            // touched memory either becomes its own Revisit row (full
            // resolution) or stays in the grid with kept assets marked.
            if !snapshot.keptIDs.isEmpty {
                await libraryVM.applySweepResult(snapshot: snapshot)
            }
        case .cancelledByUser, .failed:
            SoundManager.shared.playFailure()
        }
        summaryOutcome = snapshot.outcome
        summaryDeletedCount = snapshot.deletedIDs.count
        summaryDeletedBytes = snapshot.deletedBytes
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
            showSweepSummary = true
        }
    }

    // MARK: - Navigation

    private func handleBack() {
        if vm.hasPendingDecisions {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    // MARK: - Preloading

    private func preloadUpcomingImages() {
        let upcoming = vm.upcomingAssets(count: 3)
        Task(priority: .utility) {
            for asset in upcoming {
                let id = asset.localIdentifier
                if imageCache.image(for: id) != nil { continue }
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
