import SwiftUI

/// Slim stacked horizontal bar showing how a user's library decomposes into
/// kept / deleted / untouched photo counts. Drives the visual on top of the
/// History tab. Total = kept + deleted + untouched (deleted are no longer in
/// the library; the union approximates "every photo the user has ever taken").
struct CoverageBarView: View {
    let keptCount: Int
    let deletedCount: Int
    let untouchedCount: Int

    private var total: Int { max(1, keptCount + deletedCount + untouchedCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if keptCount > 0 {
                        Rectangle()
                            .fill(Color.appKeep)
                            .frame(width: width(geo, keptCount))
                    }
                    if deletedCount > 0 {
                        Rectangle()
                            .fill(Color.appDelete)
                            .frame(width: width(geo, deletedCount))
                    }
                    if untouchedCount > 0 {
                        // No explicit width — soaks up the remainder so we don't
                        // accumulate rounding error across three segments.
                        Rectangle()
                            .fill(Color.appTextSecondary.opacity(0.25))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)

            HStack(spacing: 14) {
                legendDot(color: .appKeep, label: "Kept")
                legendDot(color: .appDelete, label: "Deleted")
                legendDot(color: .appTextSecondary.opacity(0.45), label: "Untouched")
            }
        }
    }

    private func width(_ geo: GeometryProxy, _ count: Int) -> CGFloat {
        max(0, geo.size.width * CGFloat(count) / CGFloat(total))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.appTextSecondary)
        }
    }
}
