import SwiftUI
import Photos
import PostHog

struct DuplicateGroupSifterView: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.dismiss) private var dismiss
    @State private var vm: DuplicateGroupSifterViewModel
    @State private var cardKey: UUID = UUID()
    @State private var swipeProgress: Double = 0
    @State private var isDone: Bool = false
    @State private var currentAssetIndex: Int = 0
    @State private var imageCache: [String: UIImage] = [:]

    init(groups: [PhotoGroup]) {
        _vm = State(initialValue: DuplicateGroupSifterViewModel(groups: groups))
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if isDone {
                summaryContent
            } else if vm.isCommitting {
                committingContent
            } else {
                mainContent
            }
            swipeVignette.allowsHitTesting(false)
        }
        .navigationBarBackButtonHidden(true)
        .interactiveBackSwipe(enabled: !vm.isCommitting)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                            .font(.system(.body, weight: .semibold))
                        Text("Library")
                            .font(.system(.body))
                    }
                    .foregroundStyle(.appForeground)
                }
            }
        }
        .onChange(of: vm.isComplete) { _, complete in
            guard complete else { return }
            Task {
                await vm.commitDecisions()
                switch vm.commitOutcome {
                case .committed, .nothingToDelete:
                    PostHogSDK.shared.capture("duplicate_session_completed", properties: [
                        "group_count": vm.groups.count,
                        "merged_group_count": vm.mergedCount,
                        "deleted_photo_count": vm.deletedCount,
                        "freed_bytes": vm.deletedBytes
                    ])
                    libraryVM.removeQuickWins(ofCategory: .duplicates)
                    try? await Task.sleep(for: .milliseconds(400))
                    isDone = true
                default:
                    // cancelledByUser or failed — stay on the swipe screen so the
                    // user can retry via the back button or try again later.
                    SoundManager.shared.playFailure()
                }
            }
        }
        .onChange(of: vm.currentIndex) { _, _ in
            currentAssetIndex = 0
            cardKey = UUID()
            swipeProgress = 0
            preloadGroupImages()
        }
        .task { preloadGroupImages() }
    }

    private var navigationTitle: String {
        "Duplicate \(min(vm.currentIndex + 1, vm.groups.count)) of \(vm.groups.count)"
    }

    private var currentAsset: PHAsset? {
        guard let group = vm.currentGroup, currentAssetIndex < group.assets.count else { return nil }
        return group.assets[currentAssetIndex]
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            if let group = vm.currentGroup {
                BatchStripView(
                    group: group,
                    currentAssetID: currentAsset?.localIdentifier,
                    onTap: { asset in
                        if let idx = group.assets.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) {
                            currentAssetIndex = idx
                            cardKey = UUID()
                            swipeProgress = 0
                        }
                    }
                )
                .padding(.top, 8)
            }

            if let asset = currentAsset {
                SwipeCardView(
                    asset: asset,
                    preloadedImage: imageCache[asset.localIdentifier],
                    onSwipeRight: {
                        vm.swipeKeepAll()
                        cardKey = UUID()
                        swipeProgress = 0
                    },
                    onSwipeLeft: {
                        vm.swipeMerge()
                        cardKey = UUID()
                        swipeProgress = 0
                    },
                    onSkip: nil,
                    onProgressChange: { swipeProgress = $0 },
                    rightBadgeLabel: "KEEP ALL",
                    leftBadgeLabel: "MERGE"
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
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.appForeground.opacity(0.12))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.appAccent)
                        .frame(width: geo.size.width * vm.progress, height: 4)
                        .animation(.spring(duration: 0.4), value: vm.progress)
                }
            }
            .frame(height: 4)

            HStack {
                Label("Merge", systemImage: "arrow.left")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(.appDelete.opacity(0.7))
                Spacer()
                Label("Keep All", systemImage: "arrow.right")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(.appKeep.opacity(0.7))
            }
        }
    }

    // MARK: - States

    private var committingContent: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView().scaleEffect(1.5).tint(.appAccent)
            Text("Merging duplicates…")
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(.appForeground)
            Spacer()
        }
    }

    private var summaryContent: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("Duplicates cleared.")
                .scaledFont(size: 30, weight: .bold, design: .rounded)
                .foregroundStyle(.appForeground)
                .multilineTextAlignment(.center)

            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("\(vm.mergedCount)")
                        .scaledFont(size: 56, weight: .black, design: .rounded)
                        .foregroundStyle(.appDelete)
                    Text(vm.mergedCount == 1 ? "group merged" : "groups merged")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(.appTextSecondary)
                }
                .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(Color.appForeground.opacity(0.1))
                    .frame(width: 1, height: 56)
                    .padding(.horizontal, 20)

                VStack(spacing: 6) {
                    Text(vm.deletedBytes > 0
                         ? ByteCountFormatter.string(fromByteCount: vm.deletedBytes, countStyle: .file)
                         : (vm.deletedCount > 0 ? "\(vm.deletedCount)" : "—"))
                        .scaledFont(size: vm.deletedBytes > 0 ? 38 : 56, weight: .black, design: .rounded)
                        .foregroundStyle(.appAccent)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(vm.deletedBytes > 0 ? "space freed" : "photos deleted")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(.appTextSecondary)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            Button { dismiss() } label: {
                Text("Back to Library")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.appOnKeep)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [.appKeepFill, .appKeepDeep],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
    }

    // MARK: - Vignette

    private var swipeVignette: some View {
        GeometryReader { geo in
            let magnitude = abs(swipeProgress)
            let tint: Color = swipeProgress >= 0 ? .appKeep : .appDelete
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

    // MARK: - Preloading

    private func preloadGroupImages() {
        guard let group = vm.currentGroup else { return }
        Task(priority: .utility) {
            for asset in group.assets {
                let id = asset.localIdentifier
                guard imageCache[id] == nil else { continue }
                if case .loaded(let img) = await PhotoLibraryService.shared.loadFullImage(for: asset) {
                    imageCache[id] = img
                }
            }
        }
    }
}
