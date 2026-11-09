import SwiftUI
import Photos
import PostHog

/// Grid of every open group. Tapping one flicks just that group, as an
/// alternative to the endless Flick Forever deck on the home screen.
struct MemoriesView: View {
    @Environment(LibraryViewModel.self) private var vm
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedGroup: PhotoGroup?

    /// Cap the prefetch window so we don't warm thousands of thumbnails at once.
    private static let prefetchGroupCap = 30

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if !vm.groups.isEmpty {
                grid
            } else if vm.isScanning {
                ProgressView()
                    .tint(.appTextSecondary)
            } else {
                emptyState
            }
        }
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(item: $selectedGroup) { group in
            SifterView(group: group)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 12),
                    count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
                ),
                spacing: 12
            ) {
                ForEach(vm.groups) { group in
                    MemoryCardView(group: group)
                        .cardButton(hint: String(localized: "Opens the group to flick")) {
                            PostHogSDK.shared.capture("sifting_started", properties: [
                                "entry_point": "photo_group",
                                "photo_count": group.assets.count
                            ])
                            HapticManager.shared.playNavigate()
                            selectedGroup = group
                        }
                        .accessibilityIdentifier("groupRow_\(group.id)")
                        .transition(.asymmetric(
                            insertion: .scaleFade(0.9, reduceMotion: reduceMotion),
                            removal: .opacity
                        ))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .task(id: vm.groups.prefix(Self.prefetchGroupCap).map(\.id)) {
            let px = 200.0 * displayScale
            let size = CGSize(width: px, height: px)
            let assets = vm.groups.prefix(Self.prefetchGroupCap).compactMap { $0.assets.first }
            guard !assets.isEmpty else { return }
            await PhotoLibraryService.shared.startCachingThumbnails(for: assets, size: size)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 64)
                .foregroundStyle(.appKeep)

            Text("All clear!")
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(.appForeground)

            Text("No near-duplicate photo groups found.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.appTextSecondary)
        }
    }
}

// MARK: - Memory Card (grid cell)

struct MemoryCardView: View {
    let group: PhotoGroup
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var thumbnail: UIImage? = nil
    @State private var groupBytes: Int64 = 0

    private var metaRowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 6))
    }

    var body: some View {
        VStack(spacing: 0) {
            thumbnailStack

            VStack(alignment: .leading, spacing: 3) {
                metaRowLayout {
                    Text("\(group.assets.count) photos")
                        .scaledFont(size: 14, weight: .semibold, design: .rounded)
                        .foregroundStyle(.appForeground)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                    if groupBytes > 0 {
                        Text(formattedBytes(groupBytes))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.appTextSecondary)
                    }
                }
                .lineLimit(1)

                metaRowLayout {
                    if let date = group.captureDate {
                        Text(Self.relativeDateFormatter.localizedString(for: date, relativeTo: .now))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.appTextSecondary)
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                    if group.deleteCount > 0 {
                        Text("\(group.deleteCount) marked")
                            .font(.system(.caption, design: .rounded, weight: .medium))
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
                        .fill(Color.appForeground.opacity(opacity))
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

