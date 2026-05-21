import SwiftUI
import Photos

struct SweepSifterView: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.dismiss) private var dismiss
    @State private var vm: SweepSifterViewModel
    @State private var cardKey: UUID = UUID()
    @State private var flashTint: Color = .appKeep
    @State private var flashIntensity: Double = 0
    @State private var imageCache: [String: UIImage] = [:]
    @State private var showDiscardConfirm: Bool = false
    @State private var applyMessage: String?
    @State private var showFinishedSheet: Bool = false

    init(groups: [PhotoGroup]) {
        _vm = State(initialValue: SweepSifterViewModel(groups: groups))
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if vm.isApplying {
                applyingContent
            } else if vm.isQueueExhausted {
                finishedContent
            } else {
                mainContent
            }

            swipeVignette.allowsHitTesting(false)
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
            cardKey = UUID()
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
        VStack(spacing: 0) {
            SweepStripView(
                assets: vm.queue,
                currentAssetID: vm.currentAsset?.localIdentifier,
                decisions: vm.decisions,
                groupID: { vm.groupID(for: $0) },
                onTap: { vm.jumpTo(asset: $0) }
            )
            .padding(.top, 4)

            if let asset = vm.currentAsset {
                SwipeCardView(
                    asset: asset,
                    preloadedImage: imageCache[asset.localIdentifier],
                    onSwipeRight: {
                        vm.swipeRight()
                        cardKey = UUID()
                    },
                    onSwipeLeft: {
                        vm.swipeLeft()
                        cardKey = UUID()
                    },
                    onSkip: {
                        vm.skip()
                        cardKey = UUID()
                    },
                    onThrowRight: {
                        triggerFlash(tint: .appKeep)
                        HapticManager.shared.playKeep()
                        SoundManager.shared.playKeep()
                    },
                    onThrowLeft: {
                        triggerFlash(tint: .appDelete)
                        HapticManager.shared.playDelete()
                        SoundManager.shared.playDelete()
                    }
                )
                .id(cardKey)
                .accessibilityIdentifier("photoCard")
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            bottomBar
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 12) {
            applyButton

            HStack(spacing: 12) {
                deletedCounterPill
                if let msg = applyMessage {
                    Text(msg)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer()
                keptCounterPill
            }
        }
    }

    private var applyButton: some View {
        Button { Task { await runApply() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                Text(applyLabel)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                vm.hasPendingDecisions
                    ? AnyShapeStyle(LinearGradient(
                        colors: [.appAccent, Color(hex: "9B59B6")],
                        startPoint: .leading, endPoint: .trailing
                      ))
                    : AnyShapeStyle(Color.white.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .disabled(!vm.hasPendingDecisions)
        .opacity(vm.hasPendingDecisions ? 1.0 : 0.55)
        .animation(.easeOut(duration: 0.2), value: vm.hasPendingDecisions)
    }

    private var applyLabel: String {
        guard vm.hasPendingDecisions else { return "Apply" }
        let d = vm.pendingDeleteCount
        let k = vm.pendingKeepCount
        switch (d, k) {
        case (0, let k): return "Apply · \(k) to keep"
        case (let d, 0): return "Apply · \(d) to delete"
        default:         return "Apply · \(d) delete · \(k) keep"
        }
    }

    private var deletedCounterPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.appDelete)
            Text("\(vm.sessionDeletedCount) deleted")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private var keptCounterPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.appKeep)
            Text("\(vm.sessionKeptCount) kept")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    // MARK: - States

    private var applyingContent: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().scaleEffect(1.4).tint(.appAccent)
            Text("Applying decisions…")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
        }
    }

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
                            colors: [.appAccent, Color(hex: "9B59B6")],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Apply flow

    private func runApply() async {
        guard vm.hasPendingDecisions else { return }
        applyMessage = nil
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
        case .cancelledByUser:
            applyMessage = "Cancelled — try again"
            SoundManager.shared.playFailure()
        case .failed(let msg):
            applyMessage = "Apply failed: \(msg)"
            SoundManager.shared.playFailure()
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
        let upcoming = upcomingAssets(limit: 3)
        Task(priority: .utility) {
            for asset in upcoming {
                let id = asset.localIdentifier
                if imageCache[id] != nil { continue }
                if case .loaded(let img) = await PhotoLibraryService.shared.loadFullImage(for: asset) {
                    imageCache[id] = img
                }
            }
        }
    }

    private func upcomingAssets(limit: Int) -> [PHAsset] {
        let start = vm.currentIndex
        let end = min(vm.queue.count, start + limit)
        guard start < end else { return [] }
        return Array(vm.queue[start..<end])
    }

    // MARK: - Vignette (post-flick flash, matches SifterView)

    private var swipeVignette: some View {
        GeometryReader { geo in
            let radius = hypot(geo.size.width, geo.size.height) * 0.6
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear,                                     location: 0.00),
                    .init(color: .clear,                                     location: 0.32),
                    .init(color: flashTint.opacity(flashIntensity * 0.04),   location: 0.46),
                    .init(color: flashTint.opacity(flashIntensity * 0.09),   location: 0.58),
                    .init(color: flashTint.opacity(flashIntensity * 0.16),   location: 0.69),
                    .init(color: flashTint.opacity(flashIntensity * 0.26),   location: 0.79),
                    .init(color: flashTint.opacity(flashIntensity * 0.38),   location: 0.88),
                    .init(color: flashTint.opacity(flashIntensity * 0.52),   location: 0.95),
                    .init(color: flashTint.opacity(flashIntensity * 0.68),   location: 1.00),
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
}
