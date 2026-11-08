import SwiftUI
import Photos
import CoreLocation
import Contacts

/// Reverse-geocode cache keyed by ~1km-rounded coords so nearby photos
/// don't each hit the geocoder. Actor-isolated to prevent data races when
/// multiple cards load concurrently.
private actor GeoCache {
    static let shared = GeoCache()
    private var store: [String: String] = [:]
    func get(_ key: String) -> String? { store[key] }
    func set(_ key: String, _ value: String) { store[key] = value }
}

enum ThrowDirection { case left, right }

/// Identifiable so a fresh UUID forces SwiftUI's `.onChange` to fire even when
/// the parent throws the same direction twice in a row.
struct ThrowCommand: Equatable {
    let id: UUID
    let direction: ThrowDirection
    init(_ direction: ThrowDirection) {
        self.id = UUID()
        self.direction = direction
    }
}

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
    /// Set by the parent to programmatically throw the card (used by on-screen
    /// keep/delete buttons). Fresh UUID per command so consecutive throws fire.
    var throwCommand: ThrowCommand? = nil
    /// Override the badge labels (defaults: "KEEP" / "DELETE")
    var rightBadgeLabel: String? = nil
    var leftBadgeLabel: String? = nil

    private enum CardImageState {
        case loading
        case loaded(UIImage)
        case iCloudOnly
        case failed
    }

    @State private var offset: CGSize = .zero
    @State private var isThrown: Bool = false
    @State private var imageState: CardImageState = .loading
    @State private var locationLabel: String?
    @State private var hasCrossedBadgeThreshold: Bool = false
    @State private var captureDate: Date? = nil
    @State private var fileSizeLabel: String? = nil

    private let snapThreshold: CGFloat = 120
    private let badgeThreshold: CGFloat = 60
    /// Predicted-end translation that counts as a "flick" even when the actual drag is short.
    private let flickPredictedThreshold: CGFloat = 300
    /// Minimum actual drag distance for a flick to be considered intentional (filters jitter).
    private let flickMinTranslation: CGFloat = 30

    private var keepOpacity: Double { max(0, min(1, Double(offset.width / badgeThreshold))) }
    private var deleteOpacity: Double { max(0, min(1, Double(-offset.width / badgeThreshold))) }
    private var horizontalProgress: Double {
        max(-1, min(1, Double(offset.width) / Double(snapThreshold)))
    }
    private var dragFillProgress: Double {
        min(0.8, abs(Double(offset.width)) / Double(snapThreshold))
    }
    private var dragFillColor: Color {
        offset.width >= 0 ? .appKeep : .appDelete
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                cardPhoto(size: geo.size)

                // Drag-direction color fill, capped at 80% opacity
                dragFillColor.opacity(dragFillProgress)

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
        }
        .task {
            if let preloaded = preloadedImage {
                imageState = .loaded(preloaded)
            } else {
                switch await PhotoLibraryService.shared.loadDisplayImage(for: asset) {
                case .loaded(let img): imageState = .loaded(img)
                case .iCloudOnly:      imageState = .iCloudOnly
                case .failed:          imageState = .failed
                }
            }

            // PHAsset property access can trigger a synchronous Photos DB fetch
            // on the main thread if the asset's metadata isn't cached. Run it
            // detached so it can't block swipe transitions.
            let meta = await Task.detached(priority: .utility) { [asset] in
                let date = asset.creationDate
                let location = asset.location
                let acceptable: Set<PHAssetResourceType> = [.photo, .fullSizePhoto, .alternatePhoto, .adjustmentBasePhoto]
                let resources = PHAssetResource.assetResources(for: asset)
                let resource = resources.first { acceptable.contains($0.type) }
                var size: String? = nil
                if let bytes = resource?.value(forKey: "fileSize") as? Int64, bytes > 0 {
                    size = bytes < 1_000_000
                        ? "\(bytes / 1024) KB"
                        : String(format: "%.1f MB", Double(bytes) / 1_000_000)
                }
                return (date: date, location: location, size: size)
            }.value

            captureDate = meta.date
            fileSizeLabel = meta.size
            if let loc = meta.location {
                await resolveLocationLabel(loc)
            }
        }
        .onChange(of: offset) { _, _ in
            onProgressChange?(horizontalProgress)
        }
        .onChange(of: throwCommand) { _, newValue in
            guard let cmd = newValue, !isThrown else { return }
            let direction: CGFloat = (cmd.direction == .right) ? 1 : -1
            throwCard(
                direction: direction,
                then: (cmd.direction == .right) ? onSwipeRight : onSwipeLeft
            )
        }
    }

    // MARK: - Card photo

    @ViewBuilder
    private func cardPhoto(size: CGSize) -> some View {
        switch imageState {
        case .loaded(let image):
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 28, opaque: true)
                    .brightness(-0.08)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
            }
        case .iCloudOnly:
            Color.appCard.overlay {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 36))
                    Text("Not on device")
                        .font(.system(size: 13, design: .rounded))
                    Text("Enable iCloud downloads in Settings")
                        .font(.system(size: 11, design: .rounded))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.appTextSecondary)
                .padding()
            }
        case .failed:
            Color.appCard.overlay {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                    Text("Couldn't load photo")
                        .font(.system(size: 13, design: .rounded))
                }
                .foregroundStyle(.appTextSecondary)
            }
        case .loading:
            Color.appCard.overlay {
                ProgressView().tint(.appTextSecondary)
            }
        }
    }

    // MARK: - Metadata overlay

    private var metadataOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                if let date = captureDate {
                    Text(date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().second()))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.appForeground.opacity(0.65))
                }
                Spacer()
                HStack(spacing: 4) {
                    if let loc = locationLabel {
                        Image(systemName: "location.fill")
                            .font(.system(size: 9))
                        Text(loc)
                            .lineLimit(1)
                    }
                    if let size = fileSizeLabel {
                        if locationLabel != nil { Text("·") }
                        Text(size)
                    }
                }
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.appForeground.opacity(0.65))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    private func resolveLocationLabel(_ loc: CLLocation) async {
        let key = Self.cacheKey(loc)
        if let cached = await GeoCache.shared.get(key) {
            locationLabel = cached
            return
        }
        let geocoder = CLGeocoder()
        if let placemark = try? await geocoder.reverseGeocodeLocation(loc).first {
            let label = placemark.locality
                ?? placemark.subAdministrativeArea
                ?? placemark.administrativeArea
                ?? placemark.country
            if let label {
                await GeoCache.shared.set(key, label)
                locationLabel = label
            }
        }
    }

    private static func cacheKey(_ l: CLLocation) -> String {
        String(format: "%.2f,%.2f", l.coordinate.latitude, l.coordinate.longitude)
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

                let dx = value.translation.width
                let predictedDx = value.predictedEndTranslation.width
                let dy = value.translation.height
                let predictedDy = value.predictedEndTranslation.height

                let crossedDistance = abs(dx) > snapThreshold
                let flickedHorizontal = abs(predictedDx) > flickPredictedThreshold
                    && abs(dx) > flickMinTranslation
                    && (dx == 0 || dx.sign == predictedDx.sign)

                if crossedDistance || flickedHorizontal {
                    let direction: CGFloat = (crossedDistance ? dx : predictedDx) > 0 ? 1 : -1
                    throwCard(direction: direction, velocity: value.velocity.width, then: direction > 0 ? onSwipeRight : onSwipeLeft)
                } else if let onSkip,
                          (dy < -80 || (predictedDy < -flickPredictedThreshold && dy < -flickMinTranslation)) {
                    // Upward flick = skip
                    throwCardUp(then: onSkip)
                } else {
                    withAnimation(.spring(duration: 0.5, bounce: 0.45)) {
                        offset = .zero
                    }
                }
            }
    }

    private func throwCard(direction: CGFloat, velocity: CGFloat = 800, then action: @escaping () -> Void) {
        isThrown = true
        if direction > 0 { onThrowRight?() } else { onThrowLeft?() }
        // Scale duration with gesture speed: hard flick (~1200 pts/s) → 0.15s, slow push → 0.38s
        let normalizedSpeed = min(1.0, abs(velocity) / 1200.0)
        let duration = 0.38 - 0.23 * normalizedSpeed
        withAnimation(.spring(duration: duration, bounce: 0.08)) {
            offset = CGSize(width: direction * 600, height: -50)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { action() }
    }

    private func throwCardUp(then action: @escaping () -> Void) {
        isThrown = true
        withAnimation(.spring(duration: 0.18, bounce: 0.0)) {
            offset = CGSize(width: 0, height: -700)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { action() }
    }
}
