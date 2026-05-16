import SwiftUI
import Photos
import CoreLocation
import Contacts

struct SwipeCardView: View {
    let asset: PHAsset
    let preloadedImage: UIImage?
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void
    var onSkip: (() -> Void)? = nil
    /// Reports horizontal swipe progress in [-1, 1] to the parent so it can
    /// drive a screen-wide vignette. -1 = full left (delete), +1 = full right (keep).
    var onProgressChange: ((Double) -> Void)? = nil
    /// Fires at throw start (before the animation completes) — use for immediate haptic/flash feedback.
    var onThrowRight: (() -> Void)? = nil
    var onThrowLeft: (() -> Void)? = nil
    /// Override the badge labels (defaults: "KEEP" / "DELETE")
    var rightBadgeLabel: String? = nil
    var leftBadgeLabel: String? = nil

    @State private var offset: CGSize = .zero
    @State private var isThrown: Bool = false
    @State private var image: UIImage?
    @State private var locationLabel: String?
    @State private var hasCrossedBadgeThreshold: Bool = false

    private let snapThreshold: CGFloat = 120
    private let badgeThreshold: CGFloat = 60

    private var keepOpacity: Double { max(0, min(1, Double(offset.width / badgeThreshold))) }
    private var deleteOpacity: Double { max(0, min(1, Double(-offset.width / badgeThreshold))) }
    private var horizontalProgress: Double {
        max(-1, min(1, Double(offset.width) / Double(snapThreshold)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                cardPhoto(size: geo.size)

                // KEEP badge — top left when dragging right
                VStack {
                    HStack {
                        DecisionBadgeView(kind: .keep, opacity: keepOpacity, label: rightBadgeLabel)
                            .padding(24)
                        Spacer()
                    }
                    Spacer()
                }

                // DELETE badge — top right when dragging left
                VStack {
                    HStack {
                        Spacer()
                        DecisionBadgeView(kind: .delete, opacity: deleteOpacity, label: leftBadgeLabel)
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
            if let preloaded = preloadedImage {
                image = preloaded
            } else {
                image = await PhotoLibraryService.shared.loadFullImage(for: asset)
            }
            await loadLocationLabel()
        }
        .onChange(of: offset) { _, _ in
            onProgressChange?(horizontalProgress)
        }
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
                if let date = asset.creationDate {
                    Text(date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().second()))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                Spacer()
                HStack(spacing: 4) {
                    if let loc = locationLabel {
                        Image(systemName: "location.fill")
                            .font(.system(size: 9))
                        Text(loc)
                            .lineLimit(1)
                    }
                    if let size = fileSize {
                        if locationLabel != nil { Text("·") }
                        Text(size)
                    }
                }
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    private func loadLocationLabel() async {
        guard let loc = asset.location else { return }
        if let cached = SwipeCardView.locationCache[Self.cacheKey(loc)] {
            locationLabel = cached
            return
        }
        let geocoder = CLGeocoder()
        if let placemark = try? await geocoder.reverseGeocodeLocation(loc).first {
            // Prefer city; fall back to admin area, then country
            let label = placemark.locality
                ?? placemark.subAdministrativeArea
                ?? placemark.administrativeArea
                ?? placemark.country
            if let label {
                SwipeCardView.locationCache[Self.cacheKey(loc)] = label
                locationLabel = label
            }
        }
    }

    /// Reverse-geocode cache keyed by ~1km-rounded coords so nearby photos
    /// don't each hit the geocoder. Static so it survives card recreation.
    nonisolated(unsafe) static var locationCache: [String: String] = [:]
    private static func cacheKey(_ l: CLLocation) -> String {
        String(format: "%.2f,%.2f", l.coordinate.latitude, l.coordinate.longitude)
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
        if direction > 0 { onThrowRight?() } else { onThrowLeft?() }
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
