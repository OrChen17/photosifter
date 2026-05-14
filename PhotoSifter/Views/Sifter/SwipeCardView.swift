import SwiftUI
import Photos

struct SwipeCardView: View {
    let asset: PHAsset
    let groupFirstDate: Date?
    let preloadedImage: UIImage?
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void
    let onSkip: (() -> Void)?

    @State private var offset: CGSize = .zero
    @State private var isThrown: Bool = false
    @State private var image: UIImage?
    // Track threshold crossings so haptic fires once per crossing, not every frame
    @State private var hasCrossedBadgeThreshold: Bool = false

    private let snapThreshold: CGFloat = 120
    private let badgeThreshold: CGFloat = 60

    private var keepOpacity: Double { max(0, min(1, Double(offset.width / badgeThreshold))) }
    private var deleteOpacity: Double { max(0, min(1, Double(-offset.width / badgeThreshold))) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                cardPhoto(size: geo.size)

                // KEEP badge — top left when dragging right
                VStack {
                    HStack {
                        DecisionBadgeView(kind: .keep, opacity: keepOpacity)
                            .padding(24)
                        Spacer()
                    }
                    Spacer()
                }

                // DELETE badge — top right when dragging left
                VStack {
                    HStack {
                        Spacer()
                        DecisionBadgeView(kind: .delete, opacity: deleteOpacity)
                            .padding(24)
                    }
                    Spacer()
                }

                // SKIP badge — appears on upward drag
                if onSkip != nil {
                    let skipOpacity = max(0, min(1, Double(-offset.height / 50)))
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("SKIP")
                                .font(.system(size: 22, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(.white, lineWidth: 2.5)
                                )
                                .rotationEffect(.degrees(10))
                                .opacity(skipOpacity)
                                .padding(24)
                            Spacer()
                        }
                    }
                }

                // Directional tint overlay
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(tintColor)

                // Metadata strip at bottom
                metadataOverlay
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
            .offset(x: offset.width, y: offset.height * 0.4)
            .rotationEffect(.degrees(Double(offset.width) / 22))
            .gesture(swipeDrag)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.85), value: offset)
        }
        .task {
            // Use preloaded image if available, otherwise fetch
            if let preloaded = preloadedImage {
                image = preloaded
            } else {
                image = await PhotoLibraryService.shared.loadFullImage(for: asset)
            }
        }
    }

    // MARK: - Tint overlay

    private var tintColor: Color {
        if offset.width > 0 {
            return Color.appKeep.opacity(keepOpacity * 0.15)
        } else if offset.width < 0 {
            return Color.appDelete.opacity(deleteOpacity * 0.15)
        }
        return .clear
    }

    // MARK: - Card photo

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

    // MARK: - Metadata overlay

    private var metadataOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                if let date = asset.creationDate, let first = groupFirstDate {
                    let delta = date.timeIntervalSince(first)
                    Text(delta < 0.5 ? "First" : "+\(formatDelta(delta))")
                        .monospacedDigit()
                }
                Spacer()
                Text(resolutionString)
                if let size = fileSize {
                    Text("·")
                    Text(size)
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    private func formatDelta(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }

    private var resolutionString: String {
        let mp = Double(asset.pixelWidth * asset.pixelHeight) / 1_000_000
        return String(format: "%.1f MP", mp)
    }

    private var fileSize: String? {
        let acceptable: Set<PHAssetResourceType> = [.photo, .fullSizePhoto, .alternatePhoto, .adjustmentBasePhoto]
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { acceptable.contains($0.type) }
        guard let bytes = resource?.value(forKey: "fileSize") as? Int64, bytes > 0 else { return nil }
        if bytes < 1_000_000 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    // MARK: - Gesture

    private var swipeDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isThrown else { return }
                offset = value.translation

                // Haptic fires exactly once when crossing the badge threshold (#14 fix)
                let crossedNow = abs(value.translation.width) > badgeThreshold
                if crossedNow && !hasCrossedBadgeThreshold {
                    hasCrossedBadgeThreshold = true
                    HapticManager.shared.playDragTick()
                } else if !crossedNow && hasCrossedBadgeThreshold {
                    hasCrossedBadgeThreshold = false
                }
            }
            .onEnded { value in
                guard !isThrown else { return }
                hasCrossedBadgeThreshold = false

                if value.translation.width > snapThreshold {
                    throwCard(direction: 1, then: onSwipeRight)
                } else if value.translation.width < -snapThreshold {
                    throwCard(direction: -1, then: onSwipeLeft)
                } else if value.translation.height < -80, let onSkip {
                    // Upward flick = skip
                    throwCardUp(then: onSkip)
                } else {
                    withAnimation(.spring(duration: 0.5, bounce: 0.45)) {
                        offset = .zero
                    }
                }
            }
    }

    private func throwCard(direction: CGFloat, then action: @escaping () -> Void) {
        isThrown = true
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
            offset = CGSize(width: direction * 600, height: -50)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() }
    }

    private func throwCardUp(then action: @escaping () -> Void) {
        isThrown = true
        withAnimation(.spring(duration: 0.35, bounce: 0.05)) {
            offset = CGSize(width: 0, height: -700)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { action() }
    }
}
