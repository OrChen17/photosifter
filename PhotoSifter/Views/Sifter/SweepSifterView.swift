import SwiftUI
import Photos
import PostHog

/// The app's home screen: one endless queue of every look-alike photo in the
/// library ("Flick Forever"). New groups from the background scan join the
/// queue while the user flicks. `HomeView` owns the view model and the
/// navigation around it.
struct SweepSifterView: View {
    let vm: SweepSifterViewModel
    let onOpenHistory: () -> Void

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var imageCache = ImagePreloadCache()
    @State private var showSweepSummary: Bool = false
    @State private var summaryOutcome: DeletionOutcome? = nil
    @State private var summaryDeletedCount: Int = 0
    @State private var summaryDeletedBytes: Int64 = 0

    @State private var dragProgress: Double = 0
    @State private var throwCommand: ThrowCommand? = nil

    private var hasSessionActivity: Bool {
        vm.sessionDeletedCount + vm.sessionKeptCount > 0
    }

    var body: some View {
        ZStack {
            AmbientBackdrop(asset: vm.currentAsset)

            if !vm.isApplying {
                if !vm.isQueueExhausted {
                    mainContent
                } else if libraryVM.isScanning {
                    scanningContent
                        .transition(.opacity)
                } else if hasSessionActivity {
                    finishedContent
                        .transition(.opacity)
                } else {
                    emptyContent
                        .transition(.opacity)
                }
            }

            if showSweepSummary {
                summaryOverlay
            }
        }
        .animation(.easeInOut(duration: 0.3), value: vm.isQueueExhausted)
        .animation(.easeInOut(duration: 0.3), value: libraryVM.isScanning)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { titleView }
            if hasSessionActivity {
                ToolbarItem(placement: .topBarTrailing) { sessionCounts }
            }
        }
        .task {
            vm.appendGroups(libraryVM.groups)
            preloadUpcomingImages()
        }
        // The scan keeps streaming groups into the library while Forever is
        // open; feed them into the deck so it never runs dry mid-scan.
        .onChange(of: libraryVM.groups.map(\.id)) { _, _ in
            let wasExhausted = vm.isQueueExhausted
            if !vm.isApplying {
                vm.dropAssets(notIn: Set(libraryVM.groups.flatMap { $0.assets.map(\.localIdentifier) }))
            }
            vm.appendGroups(libraryVM.groups)
            if wasExhausted && !vm.isQueueExhausted { preloadUpcomingImages() }
        }
        .onChange(of: vm.currentIndex) { _, _ in
            preloadUpcomingImages()
        }
        .onChange(of: vm.queue.count) { _, _ in
            preloadUpcomingImages()
        }
        .onChange(of: vm.isQueueExhausted) { _, exhausted in
            if exhausted && vm.hasPendingDecisions {
                Task { await runApply() }
            }
        }
    }

    // MARK: - Top bar

    private var titleView: some View {
        HStack(spacing: 8) {
            if libraryVM.isScanning {
                ScanningDot()
            }
            Text(titleText)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.appForeground)
                .contentTransition(.numericText())
                .animation(.snappy, value: titleText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(titleAccessibilityLabel)
    }

    private var titleText: String {
        let total = vm.queue.count
        guard total > 0, !vm.isQueueExhausted else { return "FlickPic" }
        return "\(vm.currentIndex + 1) of \(total)"
    }

    private var titleAccessibilityLabel: String {
        libraryVM.isScanning ? "\(titleText), scanning for more photos" : titleText
    }

    private var sessionCounts: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "trash.fill")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.appDelete)
                Text("\(vm.sessionDeletedCount)")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.appForeground)
            }
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.appKeep)
                Text("\(vm.sessionKeptCount)")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.appForeground)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(vm.sessionDeletedCount) deleted, \(vm.sessionKeptCount) kept this session")
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
            dragProgress: dragProgress,
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
            primaryActions: { EmptyView() },
            bottomBar: {
                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }
        )
    }

    private var bottomBar: some View {
        SifterSecondaryActions(
            onSkip: {
                dragProgress = 0
                vm.skip()
                preloadUpcomingImages()
            },
            isSkipEnabled: vm.currentAsset != nil,
            apply: SifterSecondaryActions.ApplyConfig(
                deleteCount: vm.pendingDeleteCount,
                keepCount: vm.pendingKeepCount,
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

    // MARK: - Idle states

    /// The deck is empty while the scan runs. New photos slide in as soon as
    /// the library gets them.
    private var scanningContent: some View {
        VStack(spacing: 24) {
            ScanProgressView(
                progress: libraryVM.scanProgress,
                style: .hero,
                title: hasSessionActivity ? String(localized: "Finding more photos") : nil
            )
            if hasSessionActivity {
                Text("\(vm.sessionDeletedCount) deleted · \(vm.sessionKeptCount) kept so far")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.appTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyContent: some View {
        StatusPanel(
            symbol: "checkmark.circle.fill",
            symbolColor: .appKeep,
            title: "All clear!",
            message: "No look-alike photos right now."
        ) {
            quickWinButtons
        }
    }

    private var finishedContent: some View {
        StatusPanel(
            symbol: "checkmark.seal.fill",
            symbolColor: .appKeep,
            title: "Library swept.",
            message: nil
        ) {
            VStack(spacing: 28) {
                sessionStats
                Button(action: onOpenHistory) {
                    Label("See History", systemImage: "clock.arrow.circlepath")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(.appForeground)
                        .padding(.horizontal, 22)
                        .frame(minHeight: 50)
                        .appGlass(in: Capsule(style: .continuous))
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: PressScale.card))
                quickWinButtons
            }
        }
    }

    private var sessionStats: some View {
        HStack(spacing: 28) {
            statColumn(value: "\(vm.sessionDeletedCount)", label: "deleted", color: .appDelete)
            statColumn(value: "\(vm.sessionKeptCount)", label: "kept", color: .appKeep)
            if vm.sessionDeletedBytes > 0 {
                statColumn(
                    value: ByteCountFormatter.string(fromByteCount: vm.sessionDeletedBytes, countStyle: .file),
                    label: "freed",
                    color: .appAccent
                )
            }
        }
    }

    private func statColumn(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .scaledFont(size: 34, weight: .black, design: .rounded)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(color)
            Text(label)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(.appTextSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Shortcuts to Quick Wins, so an empty queue never ends in a dead end.
    @ViewBuilder
    private var quickWinButtons: some View {
        let categories = QuickWinCategory.allCases.filter { libraryVM.quickWinPhotoCount($0) > 0 }
        if !categories.isEmpty {
            AppGlassGroup {
                VStack(spacing: 10) {
                    ForEach(categories, id: \.self) { category in
                        Button { libraryVM.openQuickWin(category) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: category.systemImage)
                                    .foregroundStyle(.appKeep)
                                Text(category.label)
                                    .foregroundStyle(.appForeground)
                                Spacer(minLength: 8)
                                Text("\(libraryVM.quickWinPhotoCount(category))")
                                    .monospacedDigit()
                                    .foregroundStyle(.appTextSecondary)
                                Image(systemName: "chevron.right")
                                    .font(.system(.caption, weight: .semibold))
                                    .foregroundStyle(.appTextSecondary)
                            }
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .padding(.horizontal, 18)
                            .frame(maxWidth: 320, minHeight: 52)
                            .appGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle(pressedScale: PressScale.card))
                        .accessibilityIdentifier("quickWin_\(category)")
                    }
                }
            }
        }
    }

    // MARK: - Summary overlay

    @ViewBuilder
    private var summaryOverlay: some View {
        if vm.isQueueExhausted {
            summaryView(paintsBackground: true)
                .transition(.scaleFade(0.88, reduceMotion: reduceMotion))
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
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.appForeground.opacity(0.06), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                    .padding(.horizontal, 20)
            }
            .transition(.scaleFade(0.88, reduceMotion: reduceMotion))
            .zIndex(10)
        }
    }

    private func summaryView(paintsBackground: Bool) -> some View {
        SessionSummaryView(
            group: nil,
            nextGroup: nil,
            outcome: summaryOutcome,
            deletedBytes: summaryDeletedBytes,
            onDismiss: { dismissSummary() },
            onContinue: { dismissSummary() },
            onRetry: {
                showSweepSummary = false
                Task { await runApply() }
            },
            overrideDeletedCount: summaryDeletedCount,
            continueLabel: vm.isQueueExhausted ? "Done" : "Continue Flicking",
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
            // resolution) or stays in the queue with kept assets marked.
            if !snapshot.keptIDs.isEmpty {
                await libraryVM.applySweepResult(snapshot: snapshot)
            }
        case .cancelledByUser, .failed:
            SoundManager.shared.playFailure()
        }
        let isSuccess = snapshot.outcome == .committed || snapshot.outcome == .nothingToDelete
        if isSuccess {
            PostHogSDK.shared.capture("sweep_batch_applied", properties: [
                "source_group_count": snapshot.sourceGroupIDs.count,
                "deleted_photo_count": snapshot.deletedIDs.count,
                "kept_photo_count": snapshot.keptIDs.count,
                "freed_bytes": snapshot.deletedBytes
            ])
        }
        if vm.isQueueExhausted && isSuccess {
            // Queue done — the finished / scanning state is the landing screen.
            return
        }
        summaryOutcome = snapshot.outcome
        summaryDeletedCount = snapshot.deletedIDs.count
        summaryDeletedBytes = snapshot.deletedBytes
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
            showSweepSummary = true
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

// MARK: - Status panel

/// Centered icon + title + message + accessory, used for the scanning, empty
/// and finished states of the home screen.
private struct StatusPanel<Accessory: View>: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let message: String?
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: symbol)
                .scaledFont(size: 56, weight: .semibold)
                .foregroundStyle(symbolColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 112, height: 112)
                .appGlass(in: Circle(), interactive: false)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(.appForeground)
                if let message {
                    Text(message)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }

            accessory()
                .padding(.top, 10)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Scanning dot

struct ScanningDot: View {
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(.appKeep)
            .frame(width: 7, height: 7)
            .scaleEffect(isAnimating ? 1.3 : 0.8)
            .opacity(isAnimating ? 1 : 0.6)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(), value: isAnimating)
            .onAppear { isAnimating = !reduceMotion }
            .onChange(of: reduceMotion) { _, reduce in isAnimating = !reduce }
            .accessibilityHidden(true)
    }
}

// MARK: - Ambient backdrop

/// A heavily blurred wash of the current photo behind the whole screen, so the
/// glass controls have colour to refract. Built from a tiny thumbnail blurred
/// once on a background thread, so it costs nothing per frame while dragging.
struct AmbientBackdrop: View {
    let asset: PHAsset?
    @State private var image: UIImage?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private static let thumbnailSide: CGFloat = 48

    var body: some View {
        Color.appBackground
            .overlay {
                if !reduceTransparency, let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .opacity(colorScheme == .dark ? 0.5 : 0.35)
                        .id(image)
                        .transition(.opacity)
                }
            }
            .clipped()
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: image)
            .accessibilityHidden(true)
            .task(id: asset?.localIdentifier) { await load() }
    }

    private func load() async {
        guard let asset else {
            image = nil
            return
        }
        let size = CGSize(width: Self.thumbnailSide, height: Self.thumbnailSide)
        let stream = await PhotoLibraryService.shared.loadThumbnailStream(for: asset, size: size)
        var latest: UIImage?
        for await img in stream { latest = img }
        guard let latest, !Task.isCancelled else { return }
        let blurred = await Task.detached(priority: .utility) { BackdropBlur.blur(latest) }.value
        guard !Task.isCancelled else { return }
        image = blurred
    }
}

private enum BackdropBlur {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    private static let radius: Double = 6

    static func blur(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = input.extent
        let output = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: extent)
        guard let cg = context.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
