import SwiftUI
import Photos

struct SifterView: View {
    @State private var vm: SifterViewModel
    @State private var showSummary: Bool = false
    @State private var cardKey: UUID = UUID()  // forces card re-render on advance
    @Environment(LibraryViewModel.self) private var libraryVM

    init(group: PhotoGroup) {
        _vm = State(initialValue: SifterViewModel(group: group))
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if vm.isComplete {
                completionFlash
            } else {
                mainContent
            }
        }
        .navigationBarBackButtonHidden(false)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar { undoButton }
        .fullScreenCover(isPresented: $showSummary) {
            SessionSummaryView(group: vm.group, deletedCount: vm.deletedCount)
        }
        .onChange(of: vm.isComplete) { _, complete in
            if complete {
                libraryVM.markGroupComplete(vm.group)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    showSummary = true
                }
            }
        }
    }

    private var navigationTitle: String {
        let total = vm.group.assets.count
        let current = min(vm.currentIndex + 1, total)
        return "\(current) of \(total)"
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Batch context strip
            BatchStripView(group: vm.group, currentIndex: vm.currentIndex)
                .padding(.top, 8)

            // Card area
            if let asset = vm.currentAsset {
                SwipeCardView(
                    asset: asset,
                    onSwipeRight: { vm.swipeRight(); cardKey = UUID() },
                    onSwipeLeft: { vm.swipeLeft(); cardKey = UUID() }
                )
                .id(cardKey)
                .accessibilityIdentifier("photoCard")
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            // Progress + action buttons
            bottomBar
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 20) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [.appAccent, .appKeep],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * vm.progress, height: 4)
                        .animation(.spring(duration: 0.4), value: vm.progress)
                }
            }
            .frame(height: 4)

            // Action hint
            HStack(spacing: 0) {
                Label("Delete", systemImage: "xmark")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.appDelete.opacity(0.7))
                Spacer()
                Label("Keep", systemImage: "checkmark")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.appKeep.opacity(0.7))
            }
        }
    }

    @ToolbarContentBuilder
    private var undoButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                vm.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(vm.canUndo ? .white : .appTextSecondary)
                    .accessibilityIdentifier("undoButton")
            }
            .disabled(!vm.canUndo)
        }
    }

    // MARK: - Completion flash

    private var completionFlash: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "star.fill")
                .font(.system(size: 64))
                .foregroundStyle(.appAccent)
                .scaleEffect(1.0)
                .symbolEffect(.bounce)

            Text("Batch done!")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
        }
    }
}
