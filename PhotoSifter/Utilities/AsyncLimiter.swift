import Foundation

/// Caps how many async jobs run at once across many callers. The scan shares
/// one limiter between all time buckets so the number of Vision requests in
/// flight stays fixed however the buckets are sized.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func run<T>(_ body: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await body()
        release()
        return result
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

extension Array {
    /// Maps every element with at most `limit` transforms running at once.
    /// Results keep the input order.
    func concurrentMap<Result>(
        limit: Int,
        _ transform: @escaping @Sendable (Element) async -> Result
    ) async -> [Result] {
        guard !isEmpty else { return [] }
        let width = Swift.max(1, Swift.min(limit, count))
        return await withTaskGroup(of: (Int, Result).self) { group in
            var results = [Result?](repeating: nil, count: count)
            var next = 0
            func enqueue() {
                let index = next
                let element = self[index]
                group.addTask { (index, await transform(element)) }
                next += 1
            }
            while next < width { enqueue() }
            for await (index, value) in group {
                results[index] = value
                if next < count { enqueue() }
            }
            return results.map { $0! }
        }
    }
}
