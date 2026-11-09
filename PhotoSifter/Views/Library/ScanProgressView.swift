import SwiftUI

/// Live scan status. `.hero` fills an empty screen before the first group
/// arrives; `.compact` sits above the grid (or under the Forever deck) while
/// groups keep streaming in.
struct ScanProgressView: View {
    enum Style {
        case hero
        case compact
    }

    let progress: ScanProgress
    var groupCount: Int = 0
    var style: Style = .compact
    /// Overrides the hero title, e.g. "Finding more photos" in Forever.
    var title: String? = nil

    var body: some View {
        switch style {
        case .hero: hero
        case .compact: compact
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 20) {
            ScanGlyph()

            VStack(spacing: 8) {
                Text(title ?? String(localized: "Finding similar photos"))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.appForeground)
                    .multilineTextAlignment(.center)

                Text(countLine)
                    .font(.system(.callout, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
            }

            ScanProgressBar(progress: progress, height: 8)
                .frame(maxWidth: 280)

            VStack(spacing: 6) {
                if let position = positionLine {
                    Text(position)
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(.appTextSecondary)
                }
                if let cloud = cloudLine {
                    Label(cloud, systemImage: "icloud.slash")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.appTextSecondary)
                }
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? String(localized: "Finding similar photos"))
        .accessibilityValue(accessibilitySummary)
        .accessibilityIdentifier("scanProgressHero")
    }

    // MARK: - Compact

    private var compact: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(progress.phase == .reading ? "Reading your library" : "Checking photos")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.appForeground)
                Spacer(minLength: 8)
                if progress.phase != .reading {
                    Text(progress.fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.appTextSecondary)
                        .contentTransition(.numericText())
                }
            }

            ScanProgressBar(progress: progress, height: 6)

            Text(compactDetail)
                .font(.system(.caption, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.appTextSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Checking photos")
        .accessibilityValue(accessibilitySummary)
        .accessibilityIdentifier("scanProgressCard")
    }

    // MARK: - Copy

    private var countLine: String {
        switch progress.phase {
        case .idle, .reading:
            return String(localized: "Reading your library…")
        case .comparing, .finished:
            return String(localized: "Checked \(progress.checked.formatted()) of \(progress.total.formatted()) photos")
        }
    }

    private var positionLine: String? {
        guard progress.phase == .comparing else { return nil }
        guard let date = progress.reachedDate else { return String(localized: "Newest photos first") }
        return String(localized: "Newest first · now at \(date.formatted(.dateTime.month(.wide).year()))")
    }

    private var cloudLine: String? {
        guard progress.cloudSkipped > 0 else { return nil }
        return String(localized: "\(progress.cloudSkipped.formatted()) iCloud-only photos skipped")
    }

    private var compactDetail: String {
        var parts: [String] = []
        if progress.phase == .comparing {
            parts.append(String(localized: "\(progress.checked.formatted()) of \(progress.total.formatted())"))
            if let date = progress.reachedDate {
                parts.append(String(localized: "now at \(date.formatted(.dateTime.month(.abbreviated).year()))"))
            }
        }
        if groupCount > 0 {
            parts.append(groupCount == 1
                ? String(localized: "1 group")
                : String(localized: "\(groupCount) groups"))
        }
        if progress.cloudSkipped > 0 {
            parts.append(String(localized: "\(progress.cloudSkipped.formatted()) in iCloud skipped"))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        var parts = [countLine]
        if progress.phase == .comparing {
            parts.append(progress.fraction.formatted(.percent.precision(.fractionLength(0))))
        }
        if groupCount > 0 { parts.append(String(localized: "\(groupCount) groups found")) }
        if let cloud = cloudLine { parts.append(cloud) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Bar

/// Lime capsule on a neutral track. While the asset list is still loading
/// (total unknown) a short segment slides across instead of a fill.
struct ScanProgressBar: View {
    let progress: ScanProgress
    var height: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    private var isIndeterminate: Bool { progress.phase == .reading || progress.phase == .idle }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.appForeground.opacity(0.1))
                if isIndeterminate {
                    Capsule()
                        .fill(Color.appAccent)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: reduceMotion ? geo.size.width * 0.35 : (sweep ? geo.size.width * 0.7 : 0))
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                            value: sweep
                        )
                } else {
                    Capsule()
                        .fill(Color.appAccent)
                        .frame(width: max(height, geo.size.width * progress.fraction))
                        .animation(.easeOut(duration: 0.3), value: progress.fraction)
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .onAppear { sweep = !reduceMotion }
        .accessibilityHidden(true)
    }
}

// MARK: - Glyph

/// Stacked-photos symbol with a slow breathing pulse, so the screen reads as
/// alive even between progress ticks. Static with Reduce Motion.
private struct ScanGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.appKeep.opacity(0.12))
                .frame(width: 96, height: 96)
                .scaleEffect(pulse ? 1.08 : 0.94)
            Image(systemName: "photo.stack")
                .scaledFont(size: 40, weight: .semibold)
                .foregroundStyle(.appKeep)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = !reduceMotion }
        .accessibilityHidden(true)
    }
}
