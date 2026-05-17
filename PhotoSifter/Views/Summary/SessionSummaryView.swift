import SwiftUI
import Photos

struct SessionSummaryView: View {
    let group: PhotoGroup
    let nextGroup: PhotoGroup?
    let outcome: DeletionOutcome?
    let deletedBytes: Int64
    var onDismiss: (() -> Void)? = nil
    var onContinue: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private func doDissmiss() { onDismiss != nil ? onDismiss!() : dismiss() }
    @State private var animatedCount: Int = 0
    @State private var animatedBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0
    @State private var headline: String = ""
    @State private var nextThumbnails: [UIImage] = []
    @State private var countdown: Int = 5
    @State private var autoTask: Task<Void, Never>?

    private var deletedCount: Int { group.deletedAssets.count }
    private var isCancelledOrFailed: Bool {
        if case .cancelledByUser = outcome { return true }
        if case .failed = outcome { return true }
        return false
    }

    private static let headlinePool: [String] = [
        "Nice work.",
        "Cleaned up.",
        "Crisp.",
        "Sifted.",
        "Space restored.",
        "Storage thanks you.",
        "Lighter library.",
        "Goodbye, doubles.",
        "Decisively curated.",
        "Quality wins.",
        "Bytes back.",
        "Batch banished.",
        "Mission complete.",
        "On a roll.",
        "Past you smiles.",
        "Pruning paid off.",
        "Album, refined.",
        "Less is more.",
        "iCloud breathes easier.",
        "Decisive.",
        "Curated, not hoarded.",
        "Photographer mode: on.",
        "Tidy hands.",
        "Future you waves.",
        "Done and dusted.",
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 28) {
                if isCancelledOrFailed {
                    cancelledOrFailedContent
                } else {
                    committedContent
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 32)

            Button { doDissmiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.white.opacity(0.25))
                    .padding(16)
            }
            .padding(.top, 8)
        }
        .task {
            await loadNextThumbnails()
            // Run the count-up on initial appear when outcome is already
            // committed / nothing-to-delete (normal completion path).
            if !isCancelledOrFailed {
                await runCommittedAnimation()
            }
        }
        .onDisappear { autoTask?.cancel() }
        .onChange(of: outcome) { _, newOutcome in
            guard newOutcome == .committed || newOutcome == .nothingToDelete else { return }
            Task { await runCommittedAnimation() }
        }
        // Tick on each integer increment during the count-up animation
        .onChange(of: animatedCount) { _, newCount in
            guard newCount > 0 else { return }
            HapticManager.shared.playTick()
        }
        // Tick on each countdown decrement (4 → 3 → 2 → 1)
        .onChange(of: countdown) { _, newVal in
            guard newVal < 5 else { return }
            HapticManager.shared.playTick()
        }
    }

    private func runCommittedAnimation() async {
        headline = Self.headlinePool.randomElement() ?? "Done."
        totalBytes = deletedBytes
        animatedCount = 0
        animatedBytes = 0
        await tickUp(count: deletedCount, bytes: totalBytes, duration: 1.0)
        if nextGroup != nil { startCountdown() }
    }

    private func startCountdown() {
        autoTask?.cancel()
        countdown = 5
        autoTask = Task {
            for i in stride(from: 5, through: 1, by: -1) {
                countdown = i
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            doDissmiss()
            onContinue?()
        }
    }

    // MARK: - Committed (success / nothing-to-delete)

    @ViewBuilder
    private var committedContent: some View {
        Text(headline)
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)

        statsRow

        if deletedCount == 0 {
            Text("All photos kept this round.")
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.appTextSecondary)
        }

        actionStack
    }

    private var statsRow: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .center, spacing: 6) {
                Text("\(animatedCount)")
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.appDelete, Color(hex: "9B8BFF")],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(deletedCount == 1 ? "photo deleted" : "photos deleted")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.appTextSecondary)
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1, height: 56)
                .padding(.horizontal, 20)

            VStack(alignment: .center, spacing: 6) {
                Text(totalBytes > 0 ? animatedBytesString : "—")
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.appKeep, Color(hex: "67E8F9")],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text("space saved")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.appTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var actionStack: some View {
        VStack(spacing: 10) {
            if let next = nextGroup {
                // UP NEXT card + Continue merged into one tappable block
                Button {
                    HapticManager.shared.playNavigate()
                    autoTask?.cancel()
                    doDissmiss()
                    onContinue?()
                } label: {
                    nextBatchCard(next: next, countdown: countdown)
                }
                .accessibilityIdentifier("continueSiftingButton")
            } else {
                Button {
                    HapticManager.shared.playNavigate()
                    doDissmiss()
                    onContinue?()
                } label: {
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
                .accessibilityIdentifier("continueSiftingButton")
            }

            if deletedCount > 0 {
                Button {
                    HapticManager.shared.playNavigate()
                    openRecentlyDeleted()
                } label: {
                    Label("View Recently Deleted", systemImage: "trash")
                        .accessibilityIdentifier("viewRecentlyDeletedButton")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func nextBatchCard(next: PhotoGroup, countdown: Int? = nil) -> some View {
        VStack(spacing: 0) {
            // 2x2 thumbnail grid fills most of the card
            GeometryReader { geo in
                let cell = geo.size.width / 2
                LazyVGrid(columns: [GridItem(.fixed(cell), spacing: 2), GridItem(.fixed(cell), spacing: 2)], spacing: 2) {
                    ForEach(0..<min(4, next.assets.count), id: \.self) { i in
                        Group {
                            if i < nextThumbnails.count {
                                Image(uiImage: nextThumbnails[i])
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: cell, height: cell)
                                    .clipped()
                            } else {
                                Color.appCard
                                    .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // Metadata + Continue inside the card
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                    Text("UP NEXT")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.appTextSecondary)
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                }

                VStack(spacing: 2) {
                    Text("\(next.assets.count) photos")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    if let date = next.captureDate {
                        Text(date, format: .dateTime.month(.abbreviated).day().year())
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.appTextSecondary)
                    }
                }

                Text(countdown.map { "Continue · \($0)" } ?? "Continue")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .contentTransition(.numericText())
                    .animation(.default, value: countdown)
                    .background(
                        LinearGradient(
                            colors: [.appAccent, Color(hex: "9B59B6")],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .background(Color.appCard.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Cancelled / failed branch

    @ViewBuilder
    private var cancelledOrFailedContent: some View {
        Spacer(minLength: 0)

        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 44))
            .foregroundStyle(Color(hex: "FFB84D"))

        Text(cancelledTitle)
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)

        Text(cancelledSubtitle)
            .font(.system(size: 15, design: .rounded))
            .foregroundStyle(.appTextSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)

        Spacer(minLength: 16)

        VStack(spacing: 10) {
            Button {
                onRetry?()
            } label: {
                Text("Try Again")
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

            if let next = nextGroup {
                Button {
                    doDissmiss()
                    onContinue?()
                } label: {
                    nextBatchCard(next: next)
                }
            } else {
                Button {
                    doDissmiss()
                    onContinue?()
                } label: {
                    Text("Back to Library")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private var cancelledTitle: String {
        if case .cancelledByUser = outcome { return "Nothing was deleted" }
        return "Couldn't delete photos"
    }

    private var cancelledSubtitle: String {
        switch outcome {
        case .cancelledByUser:
            return "You dismissed the deletion request. Your swipe decisions are saved — try again whenever you're ready."
        case .failed(let reason):
            return reason
        default:
            return ""
        }
    }

    // MARK: - Helpers

    private var animatedBytesString: String {
        if animatedBytes >= 1_000_000_000 {
            return String(format: "%.0f GB", Double(animatedBytes) / 1_000_000_000)
        } else if animatedBytes >= 1_000_000 {
            return String(format: "%.0f MB", Double(animatedBytes) / 1_000_000)
        } else {
            return ByteCountFormatter.string(fromByteCount: animatedBytes, countStyle: .file)
        }
    }

    private func loadNextThumbnails() async {
        guard let next = nextGroup else { return }
        let size = CGSize(width: 320, height: 320)
        for asset in next.assets.prefix(4) {
            if let img = await PhotoLibraryService.shared.loadThumbnail(for: asset, size: size) {
                nextThumbnails.append(img)
            }
        }
    }

    private func tickUp(count target: Int, bytes targetBytes: Int64, duration: TimeInterval) async {
        let steps = 60
        let stepDelay = UInt64((duration / Double(steps)) * 1_000_000_000)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let eased = 1 - pow(1 - t, 3)
            animatedCount = Int((Double(target) * eased).rounded())
            animatedBytes = Int64((Double(targetBytes) * eased).rounded())
            try? await Task.sleep(nanoseconds: stepDelay)
        }
        animatedCount = target
        animatedBytes = targetBytes
    }

    private func openRecentlyDeleted() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url) { success in
                if !success, let fallback = URL(string: "photos-library://") {
                    UIApplication.shared.open(fallback)
                }
            }
        }
    }
}
