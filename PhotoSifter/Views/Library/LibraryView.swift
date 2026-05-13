import SwiftUI
import Photos

struct LibraryView: View {
    @Environment(LibraryViewModel.self) private var vm
    @State private var selectedGroup: PhotoGroup?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if vm.groups.isEmpty && !vm.isScanning {
                    emptyState
                } else {
                    groupList
                }
            }
            .navigationTitle("PhotoSifter")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if vm.isScanning {
                    ToolbarItem(placement: .topBarTrailing) {
                        ScanningBadge()
                    }
                }
            }
            .navigationDestination(item: $selectedGroup) { group in
                SifterView(group: group)
            }
        }
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(vm.groups) { group in
                    GroupRowView(group: group)
                        .onTapGesture { selectedGroup = group }
                        .accessibilityIdentifier("groupRow_\(group.id)")
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
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

// MARK: - Group Row

struct GroupRowView: View {
    let group: PhotoGroup
    @State private var thumbnails: [UIImage?] = []

    var body: some View {
        HStack(spacing: 14) {
            thumbnailGrid
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("\(group.assets.count) photos")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                if let date = group.captureDate {
                    Text(date, style: .relative)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                }

                if group.deleteCount > 0 {
                    Text("\(group.deleteCount) deleted")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.appDelete)
                }
            }

            Spacer()

            Image(systemName: group.isComplete ? "checkmark.circle.fill" : "chevron.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(group.isComplete ? .appKeep : .appTextSecondary)
        }
        .padding(14)
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task { await loadThumbnails() }
    }

    private var thumbnailGrid: some View {
        let preview = thumbnails.prefix(4)
        return GeometryReader { geo in
            let half = geo.size.width / 2
            LazyVGrid(columns: [GridItem(.fixed(half), spacing: 2), GridItem(.fixed(half), spacing: 2)], spacing: 2) {
                ForEach(0..<min(4, group.assets.count), id: \.self) { i in
                    Group {
                        if i < preview.count, let img = preview[i] {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: half, height: half)
                                .clipped()
                        } else {
                            Color.appCard
                                .frame(width: half, height: half)
                        }
                    }
                }
            }
        }
    }

    private func loadThumbnails() async {
        let size = CGSize(width: 100, height: 100)
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
