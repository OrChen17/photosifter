import SwiftUI
import Photos

struct SessionSummaryView: View {
    let group: PhotoGroup
    let nextGroup: PhotoGroup?
    let outcome: DeletionOutcome?
    var onContinue: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var animatedCount: Int = 0
    @State private var animatedBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0
    @State private var headline: String = ""
    @State private var nextThumbnails: [UIImage] = []

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
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 28) {
                if isCancelledOrFailed {
                    cancelledOrFailedContent
                } else {
                    committedContent
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 64)
            .padding(.bottom, 32)
        }
        .task {
            await loadNextThumbnails()
            // Run the count-up on initial appear when outcome is already
            // committed / nothing-to-delete (normal completion path).
            if !isCancelledOrFailed {
                await runCommittedAnimation()
            }
        }
        // Re-run when a retry flips outcome to .committed so the numbers
        // count up from 0 instead of staying frozen at the initial zeros.
        .onChange(of: outcome) { _, newOutcome in
            guard newOutcome == .committed || newOutcome == .nothingToDelete else { return }
            Task { await runCommittedAnimation() }
        }
    }

    private func runCommittedAnimation() async {
        headline = Self.headlinePool.randomElement() ?? "Done."
        totalBytes = computeTotalBytes()
        animatedCount = 0
        animatedBytes = 0
        await tickUp(count: deletedCount, bytes: totalBytes, duration: 1.0)
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

        Spacer(minLength: 16)

        nextBatchPreview

        Spacer(minLength: 16)

        actionStack
    }

    private var statsRow: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(animatedCount)")
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.appDelete, Color(hex: "FF6B6B")],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(deletedCount == 1 ? "photo deleted" : "photos deleted")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.appTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1, height: 56)
                .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 6) {
                Text(totalBytes > 0 ? animatedBytesString : "—")
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.appKeep, Color(hex: "5DDC9A")],
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var nextBatchPreview: some View {
        if let next = nextGroup {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                    Text("UP NEXT")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.appTextSecondary)
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                }

                HStack(spacing: 8) {
                    ForEach(Array(nextThumbnails.prefix(4).enumerated()), id: \.offset) { _, img in
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    if nextThumbnails.isEmpty {
                        ForEach(0..<min(4, next.assets.count), id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.appCard)
                                .frame(width: 64, height: 64)
                        }
                    }
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
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.appCard.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var actionStack: some View {
        VStack(spacing: 10) {
            Button {
                dismiss()
                onContinue?()
            } label: {
                continueButtonLabel
            }
            .accessibilityIdentifier("continueSiftingButton")

            if deletedCount > 0 {
                Button { openRecentlyDeleted() } label: {
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
    private var continueButtonLabel: some View {
        VStack(spacing: 2) {
            Text(nextGroup != nil ? "Continue" : "Back to Library")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let next = nextGroup {
                Text("Next batch · \(next.assets.count) photos")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
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

        nextBatchPreview

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

            Button {
                dismiss()
                onContinue?()
            } label: {
                Text(nextGroup != nil ? "Skip — continue to next batch" : "Back to Library")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.appTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
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
            return "You dismissed the system prompt. Your swipe decisions are saved — try again whenever you're ready."
        case .failed(let reason):
            return reason
        default:
            return ""
        }
    }

    // MARK: - Helpers

    private var animatedBytesString: String {
        ByteCountFormatter.string(fromByteCount: animatedBytes, countStyle: .file)
    }

    private func computeTotalBytes() -> Int64 {
        let acceptable: Set<PHAssetResourceType> = [.photo, .fullSizePhoto, .alternatePhoto, .adjustmentBasePhoto]
        var total: Int64 = 0
        for asset in group.deletedAssets {
            let resources = PHAssetResource.assetResources(for: asset)
            if let r = resources.first(where: { acceptable.contains($0.type) }),
               let bytes = r.value(forKey: "fileSize") as? Int64 {
                total += bytes
            }
        }
        return total
    }

    private func loadNextThumbnails() async {
        guard let next = nextGroup else { return }
        let size = CGSize(width: 160, height: 160)
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
