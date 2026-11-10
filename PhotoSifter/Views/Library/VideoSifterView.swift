import Photos
import PostHog
import SwiftUI

/// The Videos queue. Same deck, strip and action bar as the home screen:
/// flick right to keep, left to compress, up to skip. Below the card sit the
/// trim bar, the resolution and frame rate caps, and Compress / Delete / Keep.
struct VideoSifterView: View {
    let vm: VideoSifterViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var imageCache = ImagePreloadCache()
    @State private var dragProgress: Double = 0
    @State private var throwCommand: ThrowCommand?
    /// What the next left throw means. A drag is always compress; the Delete
    /// button borrows the left throw for one card.
    @State private var leftAction: VideoDecision = .compress

    private static let deckID = "videos"
    private static let appliedEvent = "videos_applied"

    var body: some View {
        ZStack {
            AmbientBackdrop(asset: vm.currentItem?.asset)

            if vm.isLoading {
                ProgressView().tint(.appTextSecondary)
            } else if let progress = vm.applyProgress {
                applyingContent(progress).transition(.opacity)
            } else if let result = vm.lastResult {
                resultContent(result).transition(.scaleFade(0.88, reduceMotion: reduceMotion))
            } else if !vm.isQueueExhausted {
                mainContent
            } else if vm.hasPendingDecisions {
                pendingContent.transition(.opacity)
            } else {
                doneContent.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: vm.isApplying)
        .animation(.easeInOut(duration: 0.3), value: vm.lastResult)
        .animation(.easeInOut(duration: 0.3), value: vm.isQueueExhausted)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(vm.isApplying)
        .toolbar {
            ToolbarItem(placement: .principal) { titleView }
            if vm.sessionSavedBytes > 0 {
                ToolbarItem(placement: .topBarTrailing) { savedBadge }
            }
        }
        .task { await vm.load() }
        .task(id: vm.currentItem?.id) { await vm.loadCurrent() }
        .onChange(of: vm.isQueueExhausted) { _, exhausted in
            if exhausted, vm.hasPendingDecisions { Task { await runApply() } }
        }
        .onChange(of: vm.isApplying) { _, applying in
            UIApplication.shared.isIdleTimerDisabled = applying
        }
        .onDisappear {
            vm.pause()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Top bar

    private var titleText: String {
        guard !vm.queue.isEmpty, !vm.isQueueExhausted, !vm.isApplying, vm.lastResult == nil else {
            return String(localized: "Videos")
        }
        return "\(vm.currentIndex + 1) of \(vm.queue.count)"
    }

    private var titleView: some View {
        Text(titleText)
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.appForeground)
            .contentTransition(.numericText())
            .animation(.snappy, value: titleText)
    }

    private var savedBadge: some View {
        Text("−\(VideoFormat.bytes(vm.sessionSavedBytes))")
            .font(.system(.footnote, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.appAccent)
            .padding(.horizontal, 4)
            .accessibilityLabel("\(VideoFormat.bytes(vm.sessionSavedBytes)) saved this session")
    }

    // MARK: - Deck

    private var mainContent: some View {
        FlickCardArea(
            currentAsset: vm.currentItem?.asset,
            nextAsset: vm.nextItem?.asset,
            imageCache: imageCache,
            groupID: AnyHashable(Self.deckID),
            onSwipeRight: {
                dragProgress = 0
                vm.keep()
            },
            onSwipeLeft: {
                dragProgress = 0
                if leftAction == .delete { vm.delete() } else { vm.compress() }
                leftAction = .compress
            },
            onSkip: vm.canSkip ? { skip() } : nil,
            onProgressChange: { dragProgress = $0 },
            throwCommand: throwCommand,
            dragProgress: dragProgress,
            leftTint: leftAction == .delete ? .appDelete : VideoDecision.compressTint,
            leftBadgeLabel: leftAction == .delete ? CardActionName.delete : VideoActionName.compress,
            isLeftEnabled: leftAction == .delete || vm.canCompress,
            topCardContent: AnyView(VideoCardPlayer(
                player: vm.player,
                isPlaying: vm.isPlaying,
                isUnavailable: vm.isCurrentUnavailable,
                onToggle: vm.togglePlayback
            )),
            strip: {
                SweepStripView(
                    assets: vm.queue.map(\.asset),
                    currentAssetID: vm.currentItem?.id,
                    decisions: stripDecisions,
                    groupID: { _ in nil },
                    onTap: { vm.jumpTo(assetID: $0.localIdentifier) },
                    marks: stripMarks
                )
                .padding(.top, 4)
            },
            primaryActions: { EmptyView() },
            bottomBar: {
                controls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }
        )
    }

    private var stripDecisions: [String: Decision] {
        vm.decisions.compactMapValues { decision in
            switch decision {
            case .keep: .keep
            case .delete: .delete
            case .compress: nil
            }
        }
    }

    private var stripMarks: [String: StripMark] {
        let mark = StripMark(tint: VideoDecision.compressTint, label: String(localized: "marked to compress"))
        return vm.decisions.compactMapValues { $0 == .compress ? mark : nil }
    }

    // MARK: - Controls under the card

    private var controls: some View {
        @Bindable var vm = vm
        return VStack(spacing: 12) {
            if let source = vm.currentSource {
                VideoTrimBar(
                    start: $vm.settings.trimStart,
                    end: $vm.settings.trimEnd,
                    duration: source.duration,
                    thumbnails: vm.thumbnails,
                    playhead: vm.playhead,
                    onScrub: vm.scrub(to:)
                )
                capBars(source: source)
            }
            VideoActionButtons(
                savedBytes: vm.plan?.savedBytes,
                canCompress: vm.canCompress,
                onCompress: { throwLeft(.compress) },
                onDelete: { throwLeft(.delete) },
                onKeep: { throwCommand = ThrowCommand(.right) }
            )
            SifterSecondaryActions(
                onSkip: skip,
                isSkipEnabled: vm.canSkip,
                apply: SifterSecondaryActions.ApplyConfig(
                    deleteCount: vm.pendingCount(.delete),
                    keepCount: vm.pendingCount(.keep),
                    isEnabled: vm.hasPendingDecisions,
                    action: { Task { await runApply() } },
                    compressCount: vm.pendingCount(.compress)
                ),
                onRevert: {
                    dragProgress = 0
                    vm.undo()
                },
                isRevertEnabled: vm.canUndo
            )
        }
    }

    private func capBars(source: VideoSource) -> some View {
        HStack(spacing: 10) {
            GlassSegmentBar(
                title: String(localized: "Resolution"),
                options: VideoResolutionCap.options(for: source).map {
                    .init(value: $0, label: $0.label(for: source))
                },
                selection: vm.settings.resolution.effective(for: source),
                onSelect: { vm.settings.resolution = $0 }
            )
            .accessibilityIdentifier("videoResolutionBar")
            GlassSegmentBar(
                title: String(localized: "Frame rate"),
                options: VideoFrameRateCap.options(for: source).map {
                    .init(value: $0, label: $0.label(for: source))
                },
                selection: vm.settings.frameRate.effective(for: source),
                onSelect: { vm.settings.frameRate = $0 }
            )
            .accessibilityIdentifier("videoFrameRateBar")
        }
    }

    private func throwLeft(_ action: VideoDecision) {
        leftAction = action
        throwCommand = ThrowCommand(.left)
    }

    private func skip() {
        dragProgress = 0
        vm.skip()
    }

    // MARK: - Apply

    private func runApply() async {
        guard vm.hasPendingDecisions, !vm.isApplying else { return }
        await vm.apply()
        guard let result = vm.lastResult else { return }
        if result.deleteDeclined || result.failure != nil {
            SoundManager.shared.playFailure()
        } else {
            SoundManager.shared.playSuccess()
            HapticManager.shared.playBatchComplete()
        }
        PostHogSDK.shared.capture(Self.appliedEvent, properties: [
            "compressed_count": result.compressedCount,
            "deleted_count": result.deletedCount,
            "kept_count": result.keptCount,
            "saved_bytes": result.savedBytes,
            "failed_count": result.failedCount,
            "delete_declined": result.deleteDeclined,
        ])
    }

    private func applyingContent(_ progress: VideoSifterViewModel.ApplyProgress) -> some View {
        StatusPanel(
            symbol: VideoSymbol.compress,
            symbolColor: .appAccent,
            title: progress.total > 0
                ? String(localized: "Compressing \(progress.index) of \(progress.total)")
                : String(localized: "Applying…"),
            message: Self.deletePromptNote(count: vm.pendingDeleteCount)
                ?? String(localized: "Keep FlickPic open.")
        ) {
            VStack(spacing: 18) {
                ProgressView(value: progress.fraction)
                    .tint(.appAccent)
                    .frame(maxWidth: 240)
                glassButton(String(localized: "Cancel"), tint: .appForeground) { vm.cancelApply() }
            }
        }
    }

    private func resultContent(_ result: VideoSifterViewModel.ApplyResult) -> some View {
        StatusPanel(
            symbol: result.deleteDeclined ? "square.on.square" : "checkmark.seal.fill",
            symbolColor: result.deleteDeclined ? .appTextSecondary : .appKeep,
            title: resultTitle(result),
            message: resultMessage(result)
        ) {
            VStack(spacing: 12) {
                if result.deleteDeclined {
                    glassButton(String(localized: "Delete originals"), tint: .appDelete) {
                        vm.lastResult = nil
                        Task { await runApply() }
                    }
                }
                glassButton(
                    vm.isQueueExhausted ? String(localized: "Done") : String(localized: "Continue Flicking"),
                    tint: .appForeground
                ) { vm.lastResult = nil }
                .accessibilityIdentifier("videoResultDone")
            }
        }
    }

    private func resultTitle(_ result: VideoSifterViewModel.ApplyResult) -> String {
        if result.deleteDeclined { return String(localized: "Nothing deleted") }
        if result.savedBytes > 0 { return String(localized: "Saved \(VideoFormat.bytes(result.savedBytes))") }
        return result.failure == nil ? String(localized: "All kept.") : String(localized: "Nothing changed")
    }

    private func resultMessage(_ result: VideoSifterViewModel.ApplyResult) -> String {
        var parts: [String] = []
        if result.deleteDeclined {
            parts.append(String(localized: "Smaller copies are saved in Photos next to the originals, so no space is saved yet."))
        } else {
            var counts: [String] = []
            if result.compressedCount > 0 { counts.append(String(localized: "\(result.compressedCount) compressed")) }
            if result.deletedCount > 0 { counts.append(String(localized: "\(result.deletedCount) deleted")) }
            if result.keptCount > 0 { counts.append(String(localized: "\(result.keptCount) kept")) }
            if !counts.isEmpty { parts.append(counts.joined(separator: " · ") + ".") }
            if result.compressedCount + result.deletedCount > 0 {
                parts.append(String(localized: "Originals are in Recently Deleted for 30 days."))
            }
        }
        if let failure = result.failure { parts.append(failure.message) }
        return parts.joined(separator: " ")
    }

    // MARK: - Idle states

    private var pendingContent: some View {
        StatusPanel(
            symbol: "tray.full.fill",
            symbolColor: .appKeep,
            title: String(localized: "Ready to apply"),
            message: Self.deletePromptNote(count: vm.pendingDeleteCount)
                ?? String(localized: "Your choices are not applied yet.")
        ) {
            VStack(spacing: 12) {
                glassButton(String(localized: "Apply"), tint: .appKeep) { Task { await runApply() } }
                glassButton(String(localized: "Go back one"), tint: .appForeground) { vm.undo() }
            }
        }
    }

    private static func deletePromptNote(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? String(localized: "Smaller copies are saved first. Then iOS asks once to delete 1 video. It stays in Recently Deleted for 30 days.")
            : String(localized: "Smaller copies are saved first. Then iOS asks once to delete \(count) videos. They stay in Recently Deleted for 30 days.")
    }

    private var doneContent: some View {
        StatusPanel(
            symbol: "checkmark.circle.fill",
            symbolColor: .appKeep,
            title: vm.sessionResolvedCount > 0 ? String(localized: "Videos done.") : String(localized: "No videos to go through"),
            message: vm.sessionSavedBytes > 0
                ? String(localized: "\(VideoFormat.bytes(vm.sessionSavedBytes)) saved this session.")
                : nil
        ) { EmptyView() }
    }

    private func glassButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 22)
                .frame(minWidth: 200, minHeight: 50)
                .appGlass(in: Capsule(style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: PressScale.card))
    }
}
