import SwiftUI

struct QuickWinsStripView: View {
    let quickWins: [QuickWin]
    var onSelect: (QuickWin) -> Void

    // Deduplicate pills — one per category, pointing to the first batch.
    // totalCount comes from the first win of that category.
    private var pills: [(category: QuickWinCategory, win: QuickWin, totalCount: Int)] {
        var seen: Set<QuickWinCategory> = []
        var result: [(QuickWinCategory, QuickWin, Int)] = []
        for win in quickWins {
            guard !seen.contains(win.category) else { continue }
            seen.insert(win.category)
            let total = quickWins.filter { $0.category == win.category }.reduce(0) { $0 + $1.photoCount }
            result.append((win.category, win, total))
        }
        return result
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(pills, id: \.category) { category, win, total in
                QuickWinCardView(category: category, totalCount: total)
                    .onTapGesture { onSelect(win) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct QuickWinCardView: View {
    let category: QuickWinCategory
    let totalCount: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: category.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                    Text(category.label)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                Text("\(totalCount) photos")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.appForeground.opacity(0.55))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.appForeground.opacity(0.35))
        }
        .foregroundStyle(.appForeground)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.appForeground.opacity(0.08), lineWidth: 1)
        )
    }
}
