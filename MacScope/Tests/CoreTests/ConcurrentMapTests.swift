import XCTest
@testable import MacScope

/// `ConcurrentMap` underpins the parallelized analysis passes (the listing-row projection and the
/// arm64 decode sweep). Its one hard contract: the parallel result is BYTE-IDENTICAL to a
/// sequential `(0..<count).map` — same order, same values — so parallelism can never change
/// analysis output, only its speed. These tests force the parallel path (threshold 1) and compare
/// against the sequential reference across the sizes that break naive partitioning: empty, single,
/// either side of a chunk boundary, and counts NOT divisible by the worker count.
final class ConcurrentMapTests: XCTestCase {

    /// The order-and-value identity guarantee, swept across boundary sizes. The transform's value
    /// depends on the index, so a mis-ordered or mis-partitioned result would diverge.
    func testParallelResultIsIdenticalToSequentialAcrossSizes() {
        // Includes 0, 1, small, primes (never divisible by core count), and a large value.
        let sizes = [0, 1, 2, 3, 7, 64, 4_095, 4_096, 4_097, 9_973, 100_000, 262_144]
        for count in sizes {
            let sequential = (0..<count).map { Self.payload($0) }
            let parallel = ConcurrentMap.map(count: count, threshold: 1) { Self.payload($0) }
            XCTAssertEqual(parallel, sequential, "parallel map diverged from sequential at count=\(count)")
        }
    }

    /// Below the threshold the helper runs sequentially — still correct, and exercising that the
    /// fallback path produces the same result (so the threshold is purely a performance knob).
    func testBelowThresholdFallbackIsCorrect() {
        let count = 1_000
        let sequential = (0..<count).map { Self.payload($0) }
        let belowThreshold = ConcurrentMap.map(count: count, threshold: 100_000) { Self.payload($0) }
        XCTAssertEqual(belowThreshold, sequential)
    }

    /// A count far larger than the worker count, NOT divisible by it, must still initialize every
    /// element exactly once (no gap, no uninitialized slot). A non-string value type stresses the
    /// `unsafeUninitializedCapacity` buffer fill for a trivially-copyable T.
    func testNonDivisibleLargeCountInitializesEveryElement() {
        let count = 123_457 // prime
        let result = ConcurrentMap.map(count: count, threshold: 1) { $0 &* 2 }
        XCTAssertEqual(result.count, count)
        XCTAssertEqual(result.first, 0)
        XCTAssertEqual(result.last, (count - 1) &* 2)
        // Spot-check interior indices land at their own value (order preserved).
        for index in stride(from: 0, to: count, by: 997) {
            XCTAssertEqual(result[index], index &* 2)
        }
    }

    /// Empty input is a no-op that returns an empty array (the guard must not touch the buffer).
    func testZeroCountReturnsEmpty() {
        for threshold in [Int.min, -1, 0, 1, 4_096, Int.max] {
            let result: [Int] = ConcurrentMap.map(count: 0, threshold: threshold) { _ in
                XCTFail("Empty input must not invoke transform at threshold=\(threshold)")
                return 0
            }
            XCTAssertEqual(result, [], "Empty input must be a no-op at threshold=\(threshold)")
        }
    }

    /// A reference-type-bearing payload so the buffer fill is exercised for a non-trivial T
    /// (strings have heap storage; a botched partition would leak or double-free under ARC).
    private static func payload(_ index: Int) -> String {
        "row-\(index)-\(index &* 31 &+ 7)"
    }
}
