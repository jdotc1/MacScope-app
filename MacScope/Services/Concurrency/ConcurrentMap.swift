import Foundation

/// Synchronous, order-preserving map. Transform must be independent and thread-safe.
/// Worker count follows the thread's `AnalysisParallelism` budget (nested maps run serially).
/// With dynamic tiling on, six dynamically claimed tiles per execution slot balance skewed
/// element costs; off (the default), each worker claims one contiguous range, which is the
/// previous fixed-chunk partition. The GCD parallel-for has only `workers` iterations: tile
/// count is not concurrency. A single result allocation avoids a second concatenated result.
enum ConcurrentMap {
    /// PERF-B: dynamic tiling stays OFF until the PERF-A comparator shows a gain (owed; the
    /// host was too busy for a clean baseline/candidate run when this landed). Opt in for the
    /// comparison with `MACSCOPE_DYNAMIC_TILING=1` in the measuring process's environment.
    static let tilesPerWorker: Int =
        ProcessInfo.processInfo.environment["MACSCOPE_DYNAMIC_TILING"] == "1" ? 6 : 1

    static func map<T>(
        count: Int,
        threshold: Int = 4_096,
        _ transform: @Sendable (Int) -> T
    ) -> [T] {
        precondition(count >= 0, "count must be non-negative")
        guard count > 0 else { return [] }
        let budget = AnalysisParallelism.current
        let workers = min(count, budget.maximumParallelism)
        guard count >= threshold, workers > 1 else { return (0..<count).map(transform) }

        let tileCount = min(count, workers * tilesPerWorker) // workers <= 64, tiles <= 6: no overflow.
        return Array<T>(unsafeUninitializedCapacity: count) { buffer, initializedCount in
            // count > 0 guarantees a nonempty allocation. The writer borrows its pointer
            // only inside this synchronous initializer; concurrentPerform joins all workers
            // before initializedCount is committed and the buffer becomes an ordinary Array.
            let writer = ConcurrentMapDisjointWriter(base: buffer.baseAddress!, count: count, tileCount: tileCount)
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                // Nested maps cannot multiply concurrency, even when a transform nests work.
                AnalysisParallelism.withBudget(.init(maximumParallelism: 1)) {
                    while let range = writer.claim() {
                        writer.initialize(range, transform: transform)
                    }
                }
            }
            // Transform cannot throw and there is no cancellation/early-exit branch. The
            // unique claimed ranges cover 0..<count and have all completed at the GCD join.
            initializedCount = count
        }
    }

    /// Quotient/remainder partitioning avoids ceil-add and index multiplication overflow,
    /// including when count is Int.max. Every range is nonempty and the union is 0..<count.
    static func tileRange(tile: Int, tileCount: Int, count: Int) -> Range<Int> {
        precondition(count >= 0 && tileCount > 0 && tileCount <= max(1, count))
        precondition(tile >= 0 && tile < tileCount)
        let quotient = count / tileCount
        let remainder = count % tileCount
        let lower = tile * quotient + min(tile, remainder)
        let width = quotient + (tile < remainder ? 1 : 0)
        return lower..<(lower + width)
    }
}

/// Narrow unchecked-Sendable proof:
/// - The borrowed pointer is private; this object never escapes the Array initializer.
/// - claim's only mutable state is lock-protected. Every tile is issued exactly once.
/// - tileRange creates disjoint nonempty ranges covering the allocation exactly.
/// - A claimant exclusively initializes its range. No worker reads any result element.
/// - No worker can throw or exit mid-range; concurrentPerform synchronously joins all writes.
/// - Only after that join does Array own/read/destroy the fully initialized elements.
/// Thus neither overlapping initialization nor an escaping/dangling pointer is permitted by
/// this implementation. T remains unconstrained to preserve the existing source API; captures
/// of the transform remain @Sendable, and returned values are never concurrently read here.
private final class ConcurrentMapDisjointWriter<T>: @unchecked Sendable {
    private let lock = NSLock()
    private let base: UnsafeMutablePointer<T>
    private let count: Int
    private let tileCount: Int
    private var nextTile = 0

    init(base: UnsafeMutablePointer<T>, count: Int, tileCount: Int) {
        self.base = base
        self.count = count
        self.tileCount = tileCount
    }

    func claim() -> Range<Int>? {
        lock.withLock {
            guard nextTile < tileCount else { return nil }
            let tile = nextTile
            nextTile += 1
            return ConcurrentMap.tileRange(tile: tile, tileCount: tileCount, count: count)
        }
    }

    func initialize(_ range: Range<Int>, transform: @Sendable (Int) -> T) {
        for index in range {
            base.advanced(by: index).initialize(to: transform(index))
        }
    }
}
