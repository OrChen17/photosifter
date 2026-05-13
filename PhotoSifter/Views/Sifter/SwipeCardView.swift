import SwiftUI
import Photos

struct SwipeCardView: View {
    let asset: PHAsset
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void

    @State private var offset: CGSize = .zero
    @State private var isThrown: Bool = false
    @State private var image: UIImage?

    private let snapThreshold: CGFloat = 120
    private let badgeThreshold: CGFloat = 60

    private var dragProgress: CGFloat { offset.width / snapThreshold }
    private var keepOpacity: Double { max(0, min(1, Double(offset.width / badgeThreshold))) }
    private var deleteOpacity: Double { max(0, min(1, Double(-offset.width / badgeThreshold))) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                cardPhoto(size: geo.size)

                // Keep badge — top left
                VStack {
                    HStack {
                        DecisionBadgeView(kind: .keep, opacity: keepOpacity)
                            .padding(24)
                        Spacer()
                    }
                    Spacer()
                }

                // Delete badge — top right
                VStack {
                    HStack {
                        Spacer()
                        DecisionBadgeView(kind: .delete, opacity: deleteOpacity)
                            .padding(24)
                    }
                    Spacer()
                }

                // Colored tint overlay
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        offset.width > 0
                            ? Color.appKeep.opacity(keepOpacity * 0.15)
                            : Color.appDelete.opacity(deleteOpacity * 0.15)
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
            .offset(x: offset.width, y: offset.height * 0.3)
            .rotationEffect(.degrees(Double(offset.width) / 22))
            .gesture(swipeDrag)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.85), value: offset)
        }
        .task { await loadImage() }
    }

    @ViewBuilder
    private func cardPhoto(size: CGSize) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            Color.appCard
                .overlay {
                    ProgressView()
                        .tint(.appTextSecondary)
                }
        }
    }

    private var swipeDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isThrown else { return }
                offset = value.translation
                if abs(value.translation.width) > 5 {
                    HapticManager.shared.playDragTick()
                }
            }
            .onEnded { value in
                guard !isThrown else { return }
                if value.translation.width > snapThreshold {
                    throwCard(direction: 1, decision: .keep)
                } else if value.translation.width < -snapThreshold {
                    throwCard(direction: -1, decision: .delete)
                } else {
                    withAnimation(.spring(duration: 0.5, bounce: 0.45)) {
                        offset = .zero
                    }
                }
            }
    }

    private func throwCard(direction: CGFloat, decision: Decision) {
        isThrown = true
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
            offset = CGSize(width: direction * 600, height: -50)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if direction > 0 { onSwipeRight() } else { onSwipeLeft() }
        }
    }

    private func loadImage() async {
        image = await PhotoLibraryService.shared.loadFullImage(for: asset)
    }
}
