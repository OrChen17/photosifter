import SwiftUI
import Photos

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct LibraryView: View {
    @Environment(LibraryViewModel.self) private var vm
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.displayScale) private var displayScale
    @State private var stripCollapsed = false
    @State private var initialGridY: CGFloat? = nil
    @State private var showingSettings = false

    /// Cap the prefetch window so we don't try to warm thousands of thumbnails at once.
    /// 30 groups × 2 representatives = 60 thumbnails, plenty for the visible window
    /// plus generous lookahead on a 2-column grid.
    private static let prefetchGroupCap = 30

    var body: some View {
        @Bindable var vm = vm
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if vm.groups.isEmpty && vm.isScanning {
                    scanningState
                } else if vm.groups.isEmpty && !vm.isScanning {
                    emptyState
                } else {
                    groupList
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environment(appSettings)
                    .presentationDetents([.medium])
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.appTextSecondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(GroupSortOrder.allCases, id: \.self) { order in
                            Button {
                                vm.sortOrder = order
                                vm.applySort()
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
                if vm.isScanning {
                    ToolbarItem(placement: .topBarTrailing) {
                        ScanningBadge()
                    }
                }
            }
            .navigationDestination(item: $vm.selectedGroup) { group in
                SifterView(group: group)
            }
            .navigationDestination(item: $vm.selectedQuickWin) { win in
                SifterView(group: win.group, mode: .screenshots)
            }
            .navigationDestination(item: $vm.selectedDuplicateSession) { session in
                DuplicateGroupSifterView(groups: session.groups)
            }
            .navigationDestination(item: $vm.selectedSweepSession) { session in
                SweepSifterView(groups: session.groups)
            }
        }
    }

    private var groupList: some View {
        ScrollView {
            // Sweep entrypoint — collapses alongside Quick Wins on scroll
            if vm.groups.count >= 2 {
                SweepBannerView(
                    memoryCount: vm.groups.count,
                    photoCount: vm.groups.reduce(0) { $0 + $1.assets.count },
                    action: {
                        HapticManager.shared.playNavigate()
                        vm.startSweepSession()
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(height: stripCollapsed ? 0 : nil)
                .opacity(stripCollapsed ? 0 : 1)
                .clipped()
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: stripCollapsed)
            }

            // Quick wins strip — collapses when user scrolls down
            if !vm.quickWins.isEmpty {
                QuickWinsStripView(quickWins: vm.quickWins) { win in
                    HapticManager.shared.playNavigate()
                    switch win.category {
                    case .screenshots:
                        vm.selectedQuickWin = win
                    case .duplicates:
                        let groups = vm.quickWins
                            .filter { $0.category == .duplicates }
                            .map { $0.group }
                        if !groups.isEmpty {
                            vm.selectedDuplicateSession = DuplicateSession(groups: groups)
                        }
                    }
                }
                .frame(height: stripCollapsed ? 0 : nil)
                .clipped()
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: stripCollapsed)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(vm.groups) { group in
                    MemoryCardView(group: group)
                        .onTapGesture {
                            HapticManager.shared.playNavigate()
                            vm.selectedGroup = group
                        }
                        .accessibilityIdentifier("groupRow_\(group.id)")
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetKey.self,
                        value: geo.frame(in: .global).minY
                    )
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .onPreferenceChange(ScrollOffsetKey.self) { y in
                if initialGridY == nil { initialGridY = y }
                let offset = (initialGridY ?? y) - y
                let should = offset > 60
                if should != stripCollapsed {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        stripCollapsed = should
                    }
                }
            }

            Spacer().frame(height: 32)
        }
        // Warm PHCachingImageManager for the top-of-grid window so thumbnails are
        // already decoded by the time MemoryCardView.task fires its request.
        .task(id: vm.groups.prefix(Self.prefetchGroupCap).map(\.id)) {
            let px = 200.0 * displayScale
            let size = CGSize(width: px, height: px)
            let assets = vm.groups.prefix(Self.prefetchGroupCap).compactMap { $0.assets.first }
            guard !assets.isEmpty else { return }
            await PhotoLibraryService.shared.startCachingThumbnails(for: assets, size: size)
        }
    }

    private var scanningState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(.appAccent)

            Text("Loading Photos...")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.appTextSecondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.appKeep)

            Text("All clear!")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("No near-duplicate photo groups found.")
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(.appTextSecondary)
        }
    }
}

// MARK: - Memory Card (grid cell)

struct MemoryCardView: View {
    let group: PhotoGroup
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage? = nil
    @State private var groupBytes: Int64 = 0

    var body: some View {
        VStack(spacing: 0) {
            thumbnailStack

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(group.assets.count) photos")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer(minLength: 4)
                    if groupBytes > 0 {
                        Text(formattedBytes(groupBytes))
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.appTextSecondary)
                    }
                }
                .lineLimit(1)

                HStack(spacing: 6) {
                    if let date = group.captureDate {
                        Text(Self.relativeDateFormatter.localizedString(for: date, relativeTo: .now))
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.appTextSecondary)
                    }
                    Spacer(minLength: 4)
                    if group.deleteCount > 0 {
                        Text("\(group.deleteCount) marked")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.appDelete)
                    }
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task { await loadThumbnails() }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// One hero thumbnail with 1–2 thin card-edge strips peeking from the top to
    /// suggest a stack of photos. All layers stay inside the square cell bounds so
    /// the grid layout doesn't shift between cells with different group sizes.
    private var thumbnailStack: some View {
        GeometryReader { geo in
            let peek: CGFloat = 7
            let numBackLayers = min(group.assets.count - 1, 2)
            let frontHeight = geo.size.height - CGFloat(numBackLayers) * peek
            ZStack(alignment: .bottom) {
                ForEach(0..<numBackLayers, id: \.self) { idx in
                    // idx 0 is the back-most layer (drawn first → bottom of ZStack).
                    let fromFront = numBackLayers - idx
                    let inset = CGFloat(fromFront) * 6
                    let opacity = 0.20 + Double(numBackLayers - fromFront) * 0.16
                    RoundedRectangle(cornerRadius: 14 - CGFloat(fromFront), style: .continuous)
                        .fill(Color.white.opacity(opacity))
                        .frame(
                            width: geo.size.width - inset * 2,
                            height: frontHeight + CGFloat(fromFront) * peek
                        )
                }
                Group {
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.appBackground
                    }
                }
                .frame(width: geo.size.width, height: frontHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func loadThumbnails() async {
        // targetSize is in pixels. Scale by screen density so thumbnails aren't
        // upscaled and blurry on 2x/3x devices.
        let px = 200.0 * displayScale
        let size = CGSize(width: px, height: px)
        // The group already has its byte total computed by GroupingService.byteFilled;
        // recomputing here would mean N more PHAssetResource calls per cell.
        groupBytes = group.totalFileBytes

        guard let hero = group.assets.first else { return }
        // The OS thumbnail cache yields a degraded image first (instant), then
        // the HQ image upgrades the same slot when ready.
        let stream = await PhotoLibraryService.shared.loadThumbnailStream(for: hero, size: size)
        for await img in stream {
            thumbnail = img
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        } else if bytes >= 1_000_000 {
            return String(format: "%.0f MB", Double(bytes) / 1_000_000)
        } else {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }
}

// MARK: - Scanning Badge

struct ScanningBadge: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.appAccent)
                .frame(width: 8, height: 8)
                .scaleEffect(isAnimating ? 1.3 : 0.8)
                .animation(.easeInOut(duration: 0.7).repeatForever(), value: isAnimating)

            Text("Scanning")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.appTextSecondary)
        }
        .onAppear { isAnimating = true }
    }
}
