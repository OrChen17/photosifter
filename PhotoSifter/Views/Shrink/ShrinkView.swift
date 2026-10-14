import SwiftUI
import Photos

/// "Shrink" tab: videos above 1080p / 30 fps, re-encoded down and swapped in
/// for the originals. Logic lives in VideoShrinkViewModel; this file is UI only.
@MainActor
struct ShrinkView: View {
    @State private var vm = VideoShrinkViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if vm.candidates.isEmpty {
                    if vm.hasScanned { emptyState } else { scanningState }
                } else {
                    list
                }

                if vm.phase != .idle {
                    ShrinkProgressOverlay(vm: vm)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: vm.phase)
            .navigationTitle("Shrink")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                if !vm.selection.isEmpty && vm.phase == .idle {
                    ShrinkButton(count: vm.selection.count, savings: vm.selectedSavings) {
                        HapticManager.shared.playNavigate()
                        vm.startShrinking()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: vm.selection.isEmpty)
        }
        .task {
            if !vm.hasScanned { await vm.load() }
        }
        .onChange(of: vm.isWorking) { _, working in
            // Exports stall when the screen locks.
            UIApplication.shared.isIdleTimerDisabled = working
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !vm.candidates.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button(vm.isAllSelected ? "Deselect All" : "Select All") {
                    HapticManager.shared.playTick()
                    vm.toggleAll()
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.appAccent)
                .disabled(vm.isWorking)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(VideoSortOrder.allCases, id: \.self) { order in
                        Button {
                            vm.sortOrder = order
                        } label: {
                            if vm.sortOrder == order {
                                Label(order.label, systemImage: "checkmark")
                            } else {
                                Text(order.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 12, weight: .medium))
                        Text(vm.sortOrder.label)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.appTextSecondary)
                }
            }
        }
        if vm.isScanning && !vm.candidates.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                ScanningBadge()
            }
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                LazyVStack(spacing: 8) {
                    ForEach(vm.candidates) { candidate in
                        VideoCandidateRow(
                            candidate: candidate,
                            isSelected: vm.selection.contains(candidate.id)
                        )
                        .onTapGesture {
                            guard !vm.isWorking else { return }
                            HapticManager.shared.playTick()
                            vm.toggle(candidate.id)
                        }
                        .accessibilityIdentifier("shrinkRow_\(candidate.id)")
                    }
                }
                footnote
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .refreshable { await vm.load() }
    }

    private var header: some View {
        let hasSelection = !vm.selection.isEmpty
        let savings = hasSelection ? vm.selectedSavings : vm.totalPossibleSavings
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hasSelection ? "You'll save about" : "Up to")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.appTextSecondary)
                Text(formatBytes(savings))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.appKeep)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(hasSelection
                     ? "\(formatBytes(vm.selectedOriginalBytes)) → ~\(formatBytes(vm.selectedEstimatedBytes))"
                     : "across \(vm.candidates.count) \(vm.candidates.count == 1 ? "video" : "videos") above 1080p · 30 fps")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .animation(.spring(duration: 0.3), value: savings)

            if vm.totalSavedBytes > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.appAccent)
                    Text("\(formatBytes(vm.totalSavedBytes)) shrunk so far")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.appCard.opacity(0.3), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var footnote: some View {
        Text("Dates, locations, favorites and albums are kept. Originals move to Recently Deleted, so the space frees up once you empty it. Slo-mo, Cinematic and time-lapse videos aren't shown.")
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.appTextSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
    }

    // MARK: - Empty / scanning

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "film.stack")
                    .font(.system(size: 56))
                    .foregroundStyle(.appKeep)
                Text("Nothing to shrink")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("All your videos are already 1080p at 30 fps or smaller.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.appTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .padding(.top, 120)
        }
        .refreshable { await vm.load() }
    }

    private var scanningState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.appAccent)
                .scaleEffect(1.3)
            Text("Finding big videos…")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.appTextSecondary)
        }
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - Row

private struct VideoCandidateRow: View {
    let candidate: VideoCandidate
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnail(id: candidate.id, duration: candidate.spec.duration)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    specChip(candidate.spec, highlight: false)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.appTextSecondary)
                    specChip(candidate.target, highlight: true)
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatBytes(candidate.spec.fileBytes))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("→ ~\(formatBytes(candidate.estimatedBytes))")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.appKeep)
                }

                SizeBar(ratio: Double(candidate.estimatedBytes) / Double(max(candidate.spec.fileBytes, 1)))

                if let date = candidate.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 24))
                .foregroundStyle(isSelected ? Color.appAccent : Color.appTextSecondary.opacity(0.6))
                .symbolEffect(.bounce, value: isSelected)
        }
        .padding(10)
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.appAccent.opacity(0.6) : Color.white.opacity(0.04), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func specChip(_ spec: VideoSpec, highlight: Bool) -> some View {
        let parts = [VideoShrinkPlan.resolutionLabel(spec), VideoShrinkPlan.fpsLabel(spec)].compactMap { $0 }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(highlight ? Color.appKeep : Color.white.opacity(0.8))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (highlight ? Color.appKeep.opacity(0.12) : Color.white.opacity(0.08)),
                in: Capsule()
            )
    }
}

/// Estimated output as a share of the original.
private struct SizeBar: View {
    let ratio: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(Color.appKeep)
                    .frame(width: max(4, geo.size.width * min(max(ratio, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

private struct VideoThumbnail: View {
    let id: String
    let duration: TimeInterval
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "video.fill")
                            .foregroundStyle(.appTextSecondary)
                    }
                }
                .clipped()

            Text(durationText)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(4)
        }
        .frame(width: 76, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: id) {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
            let stream = await PhotoLibraryService.shared.loadThumbnailStream(for: asset, size: CGSize(width: 228, height: 288))
            for await img in stream {
                image = img
            }
        }
    }

    private var durationText: String {
        let total = Int(duration.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - CTA

private struct ShrinkButton: View {
    let count: Int
    let savings: Int64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 16, weight: .bold))
                Text("Shrink \(count) \(count == 1 ? "video" : "videos")")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer(minLength: 8)
                Text("Save ~\(formatBytes(savings))")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(
                LinearGradient(
                    colors: [Color.appAccent, Color.appAccent.opacity(0.75)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: Color.appAccent.opacity(0.35), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shrinkButton")
    }
}

// MARK: - Progress / result overlay

private struct ShrinkProgressOverlay: View {
    let vm: VideoShrinkViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()

            VStack(spacing: 20) {
                content
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(Color.appCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .padding(24)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.phase {
        case .idle:
            EmptyView()

        case .converting(let current, let total, let fraction):
            ProgressRing(fraction: fraction)
            title(total == 1 ? "Converting" : "Converting \(current) of \(total)")
            caption("Keep FlickPic open. Nothing in Photos changes until every video is done.")
            secondaryButton("Cancel") { vm.cancelShrinking() }

        case .saving:
            ProgressRing(fraction: 1)
            title("Saving to Photos")
            caption("Approve the prompt to swap in the smaller versions.")

        case .awaitingRetry(let count, let saved):
            icon("exclamationmark.circle.fill", color: .appRevert)
            title("Nothing replaced yet")
            caption("\(count) \(count == 1 ? "video is" : "videos are") converted and ready. Replacing them saves ~\(formatBytes(saved)).")
            primaryButton("Replace") { Task { await vm.retryReplace() } }
            secondaryButton("Discard") { Task { await vm.discardPending() } }

        case .done(let count, let saved, let failed):
            icon("checkmark.circle.fill", color: .appKeep)
            Text(formatBytes(saved))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.appKeep)
            title("Shrunk \(count) \(count == 1 ? "video" : "videos")")
            caption((failed > 0 ? "\(failed) couldn't be converted and were left as is. " : "")
                    + "Empty Recently Deleted in Photos to free the space now.")
            primaryButton("Done") {
                HapticManager.shared.playNavigate()
                vm.dismissResult()
            }
            .onAppear { HapticManager.shared.playBatchComplete() }

        case .failed(let message):
            icon("xmark.octagon.fill", color: .appDelete)
            title("Couldn't shrink")
            caption(message)
            primaryButton("OK") { vm.dismissResult() }
        }
    }

    private func icon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 48))
            .foregroundStyle(color)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, design: .rounded))
            .foregroundStyle(.appTextSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.appAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.appTextSecondary)
    }
}

private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(Color.appKeep, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: fraction)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .frame(width: 96, height: 96)
    }
}
