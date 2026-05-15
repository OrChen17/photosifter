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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(pills, id: \.category) { category, win, total in
                    QuickWinPillView(category: category, totalCount: total)
                        .onTapGesture { onSelect(win) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

private struct QuickWinPillView: View {
    let category: QuickWinCategory
    let totalCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: category.systemImage)
                .font(.system(size: 14, weight: .medium))
            Text(category.label)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text("\(totalCount)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.15), in: Capsule())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.appCard, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}
