import SwiftUI
import Photos

struct DuplicateGroupSifterView: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(\.dismiss) private var dismiss
    @State private var vm: DuplicateGroupSifterViewModel
    @State private var cardKey: UUID = UUID()
    @State private var swipeProgress: Double = 0
    @State private var isDone: Bool = false

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
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Library")
                            .font(.system(size: 17))
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .onChange(of: vm.isComplete) { _, complete in
            guard complete else { return }
            Task {
                await vm.commitDecisions()
                libraryVM.removeQuickWins(ofCategory: .duplicates)
                try? await Task.sleep(for: .milliseconds(400))
                isDone = true
            }
        }
    }

    private var navigationTitle: String {
        "Duplicate \(min(vm.currentIndex + 1, vm.groups.count)) of \(vm.groups.count)"
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            if let group = vm.currentGroup {
                DuplicateGroupCardView(
                    group: group,
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
                    onProgressChange: { swipeProgress = $0 }
                )
                .id(cardKey)
                .padding(.horizontal, 16)
            }

            bottomBar
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [.appAccent, .appKeep], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * vm.progress, height: 4)
                        .animation(.spring(duration: 0.4), value: vm.progress)
                }
            }
            .frame(height: 4)

            HStack {
                Label("Merge", systemImage: "arrow.left")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.appDelete.opacity(0.7))
                Spacer()
                Label("Keep All", systemImage: "arrow.right")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
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
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
        }
    }

    private var summaryContent: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("Duplicates cleared.")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("\(vm.mergedCount)")
                        .font(.system(size: 56, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.appDelete, Color(hex: "9B8BFF")],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    Text(vm.mergedCount == 1 ? "group merged" : "groups merged")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                }
                .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1, height: 56)
                    .padding(.horizontal, 20)

                VStack(spacing: 6) {
                    Text(vm.deletedBytes > 0
                         ? ByteCountFormatter.string(fromByteCount: vm.deletedBytes, countStyle: .file)
                         : (vm.deletedCount > 0 ? "\(vm.deletedCount)" : "—"))
                        .font(.system(size: vm.deletedBytes > 0 ? 38 : 56, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.appKeep, Color(hex: "67E8F9")],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(vm.deletedBytes > 0 ? "space freed" : "photos deleted")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            Button { dismiss() } label: {
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
                    .init(color: tint.opacity(magnitude * 0.09), location: 0.58),
                    .init(color: tint.opacity(magnitude * 0.26), location: 0.79),
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
}

// MARK: - Card

private struct DuplicateGroupCardView: View {
    let group: PhotoGroup
    var onSwipeRight: () -> Void
    var onSwipeLeft: () -> Void
    var onProgressChange: (Double) -> Void

    @State private var offset: CGFloat = 0
    @State private var thumbnails: [UIImage] = []

    private let badgeThreshold: CGFloat = 60
    private let snapThreshold: CGFloat = 120

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.appCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )

            thumbnailGrid

            if offset > badgeThreshold {
                badge(text: "KEEP ALL", color: .appKeep)
                    .padding(16)
                    .transition(.scale.combined(with: .opacity))
            } else if offset < -badgeThreshold {
                badge(text: "MERGE", color: .appDelete)
                    .padding(16)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .rotationEffect(.degrees(Double(offset) / 18))
        .offset(x: offset, y: abs(offset) * 0.06)
        .gesture(dragGesture)
        .animation(.interactiveSpring(), value: offset)
        .task { await loadThumbnails() }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = value.translation.width
                onProgressChange(Double(value.translation.width) / 150)
            }
            .onEnded { value in
                let x = value.translation.width
                if x > snapThreshold {
                    snapOff(direction: 1, action: onSwipeRight)
                } else if x < -snapThreshold {
                    snapOff(direction: -1, action: onSwipeLeft)
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { offset = 0 }
                    onProgressChange(0)
                }
            }
    }

    private func snapOff(direction: CGFloat, action: @escaping () -> Void) {
        withAnimation(.easeIn(duration: 0.2)) { offset = direction * 600 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { action() }
    }

    private var thumbnailGrid: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                GeometryReader { geo in
                    let n = min(4, group.assets.count)
                    let cols = n == 1 ? 1 : 2
                    let cell = geo.size.width / CGFloat(cols)
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(cell), spacing: 2), count: cols),
                        spacing: 2
                    ) {
                        ForEach(0..<n, id: \.self) { i in
                            Group {
                                if i < thumbnails.count {
                                    Image(uiImage: thumbnails[i])
                                        .resizable().scaledToFill()
                                        .frame(width: cell, height: cell).clipped()
                                } else {
                                    Color.appBackground.frame(width: cell, height: cell)
                                }
                            }
                        }
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(color.opacity(0.6), lineWidth: 1.5)
            )
    }

    private func loadThumbnails() async {
        let size = CGSize(width: 400, height: 400)
        for asset in group.assets.prefix(4) {
            if let img = await PhotoLibraryService.shared.loadThumbnail(for: asset, size: size) {
                thumbnails.append(img)
            }
        }
    }
}
