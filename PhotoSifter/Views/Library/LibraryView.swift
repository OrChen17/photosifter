import SwiftUI
import Photos

struct LibraryView: View {
    @Environment(LibraryViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if vm.groups.isEmpty && !vm.isScanning {
                    emptyState
                } else {
                    groupList
                }
            }
            .navigationTitle("Memories")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if vm.isScanning {
                    ToolbarItem(placement: .topBarTrailing) {
                        ScanningBadge()
                    }
                }
            }
            .navigationDestination(item: $vm.selectedGroup) { group in
                SifterView(group: group)
            }
        }
    }

    private var groupList: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(vm.groups) { group in
                    MemoryCardView(group: group)
                        .onTapGesture { vm.selectedGroup = group }
                        .accessibilityIdentifier("groupRow_\(group.id)")
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
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
    @State private var thumbnails: [UIImage?] = []

    var body: some View {
        VStack(spacing: 0) {
            thumbnailGrid
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("\(group.assets.count) photos")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let date = group.captureDate {
                    Text(date, style: .relative)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                        .lineLimit(1)
                }

                if group.deleteCount > 0 {
                    Text("\(group.deleteCount) marked")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.appDelete)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task { await loadThumbnails() }
    }

    private var thumbnailGrid: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                GeometryReader { geo in
                    let half = geo.size.width / 2
                    LazyVGrid(
                        columns: [GridItem(.fixed(half), spacing: 2), GridItem(.fixed(half), spacing: 2)],
                        spacing: 2
                    ) {
                        ForEach(0..<min(4, group.assets.count), id: \.self) { i in
                            Group {
                                if i < thumbnails.count, let img = thumbnails[i] {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: half, height: half)
                                        .clipped()
                                } else {
                                    Color.appBackground
                                        .frame(width: half, height: half)
                                }
                            }
                        }
                    }
                }
            )
    }

    private func loadThumbnails() async {
        let size = CGSize(width: 200, height: 200)
        thumbnails = Array(repeating: nil, count: min(4, group.assets.count))
        for (i, asset) in group.assets.prefix(4).enumerated() {
            let img = await PhotoLibraryService.shared.loadThumbnail(for: asset, size: size)
            thumbnails[i] = img
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
