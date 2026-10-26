import XCTest
@testable import MacScope

final class AnalysisResourceBudgetTests: XCTestCase {
    func testCommonM1MaxAndGenericCPUCeilings() {
        let max = AnalysisHostResourcePolicy.reconstructionParallelism(processorCount: 10)
        XCTAssertEqual(max.outer, 2)
        XCTAssertEqual(max.inner, 3)
        for cores in [Int.min, 0, 1, 2, 4, 8, 10, 12, 64, Int.max] {
            let slots = AnalysisHostResourcePolicy.reconstructionParallelism(processorCount: cores)
            XCTAssertGreaterThan(slots.outer, 0)
            XCTAssertGreaterThan(slots.inner, 0)
            XCTAssertLessThanOrEqual(slots.outer * slots.inner, Swift.max(1, Swift.min(64, cores)))
        }
        XCTAssertEqual(AnalysisHostResourcePolicy.interactiveParallelism(
            processorCount: 10, thermalState: .nominal, lowPowerMode: false), 8)
        XCTAssertEqual(AnalysisHostResourcePolicy.interactiveParallelism(
            processorCount: 10, thermalState: .nominal, lowPowerMode: true), 4)
        XCTAssertEqual(AnalysisHostResourcePolicy.interactiveParallelism(
            processorCount: 10, thermalState: .fair, lowPowerMode: false), 6)
        XCTAssertEqual(AnalysisHostResourcePolicy.interactiveParallelism(
            processorCount: 10, thermalState: .fair, lowPowerMode: true), 4)
        XCTAssertEqual(AnalysisHostResourcePolicy.interactiveParallelism(
            processorCount: 10, thermalState: .serious, lowPowerMode: false), 2)
        XCTAssertEqual(AnalysisHostResourcePolicy.interactiveParallelism(
            processorCount: 10, thermalState: .critical, lowPowerMode: false), 1)
    }

    func testExplicitBudgetWrapsInProcessFactoryWithoutChangingDefaultProvider() {
        let defaultProvider = AnalysisProviderFactory.makeDefault(
            arguments: ["MacScope", "--macscope-in-process-analysis"], environment: [:])
        XCTAssertTrue(defaultProvider is AnalysisEngine)
        let bounded = AnalysisProviderFactory.makeDefault(
            arguments: ["MacScope", "--macscope-in-process-analysis"], environment: [:],
            resourceBudget: .init(maximumParallelism: 3))
        let wrapper = bounded as? ResourceBudgetedAnalysisProvider
        XCTAssertEqual(wrapper?.budget.maximumParallelism, 3)
        XCTAssertTrue(wrapper?.provider is AnalysisEngine)
    }

    func testWireBudgetsRejectHostileValues() throws {
        for value in [-1, 0, 65, Int.max] {
            let bytes = Data("{\"maximumParallelism\":\(value)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(AnalysisResourceBudget.self, from: bytes))
        }
        let budget = AnalysisResourceBudget(maximumParallelism: 3)
        XCTAssertEqual(try JSONDecoder().decode(AnalysisResourceBudget.self,
            from: JSONEncoder().encode(budget)), budget)
    }

    func testHostAdmissionOnlyReducesAnExplicitCeiling() {
        let requested = AnalysisResourceBudget(maximumParallelism: 3)
        XCTAssertEqual(requested.clamped(to: .init(maximumParallelism: 8)).maximumParallelism, 3)
        XCTAssertEqual(requested.clamped(to: .init(maximumParallelism: 2)).maximumParallelism, 2)
        XCTAssertEqual(requested.clamped(to: .init(maximumParallelism: 1)).maximumParallelism, 1)
    }

    func testNestedSynchronousScopesRestoreOnThrow() throws {
        enum Expected: Error { case failure }
        try AnalysisParallelism.withBudget(.init(maximumParallelism: 3)) {
            XCTAssertEqual(AnalysisParallelism.current.maximumParallelism, 3)
            XCTAssertThrowsError(try AnalysisParallelism.withBudget(.init(maximumParallelism: 1)) {
                XCTAssertEqual(AnalysisParallelism.current.maximumParallelism, 1)
                throw Expected.failure
            })
            XCTAssertEqual(AnalysisParallelism.current.maximumParallelism, 3)
        }
    }

    func testTileBoundariesAreContiguousWithoutIntegerOverflow() {
        for count in [1, 2, 7, 10, 123_457, Int.max] {
            for tiles in [1, Swift.min(count, 7), Swift.min(count, 384)] {
                var previousUpper = 0
                for tile in 0..<tiles {
                    let range = ConcurrentMap.tileRange(tile: tile, tileCount: tiles, count: count)
                    XCTAssertEqual(range.lowerBound, previousUpper)
                    XCTAssertFalse(range.isEmpty)
                    previousUpper = range.upperBound
                }
                XCTAssertEqual(previousUpper, count)
            }
        }
    }

    func testNestedMapsCannotMultiplyParallelismAndOutputIsIdentical() {
        let result = AnalysisParallelism.withBudget(.init(maximumParallelism: 3)) {
            ConcurrentMap.map(count: 100, threshold: 1) { index in
                XCTAssertEqual(AnalysisParallelism.current.maximumParallelism, 1)
                return ConcurrentMap.map(count: 17, threshold: 1) { index * 17 + $0 }
            }
        }
        XCTAssertEqual(result, (0..<100).map { index in (0..<17).map { index * 17 + $0 } })
    }

    func testReferenceElementsAreInitializedOnceAndOwnedOnlyByReturnedArray() {
        let lifetime = CPUMapLifetimeCounter()
        let count = 10_003
        var result: [CPUMapLifetimePayload]? = AnalysisParallelism.withBudget(.init(maximumParallelism: 3)) {
            ConcurrentMap.map(count: count, threshold: 1) { index in
                CPUMapLifetimePayload(index: index, lifetime: lifetime)
            }
        }
        weak var first = result?.first
        XCTAssertEqual(result?.map(\.index), Array(0..<count))
        XCTAssertEqual(lifetime.created, count)
        XCTAssertEqual(lifetime.destroyed, 0)
        XCTAssertNotNil(first)
        result = nil
        XCTAssertNil(first)
        XCTAssertEqual(lifetime.destroyed, count)
    }

    func testTransformExecutionNeverExceedsBudgetAndRunsExactlyOnce() {
        let recorder = CPUMapRecorder(count: 123_457)
        let result = AnalysisParallelism.withBudget(.init(maximumParallelism: 3)) {
            ConcurrentMap.map(count: 123_457, threshold: 1) { index in
                recorder.enter(index)
                defer { recorder.leave() }
                return "row-\(index)-\(index &* 31 &+ 7)"
            }
        }
        XCTAssertEqual(result, (0..<123_457).map { "row-\($0)-\($0 &* 31 &+ 7)" })
        XCTAssertEqual(recorder.visits, Array(repeating: 1, count: result.count))
        XCTAssertLessThanOrEqual(recorder.maximumActive, 3)
    }
}

private final class CPUMapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int]
    private var active = 0
    private var maximum = 0
    init(count: Int) { counts = Array(repeating: 0, count: count) }
    var visits: [Int] { lock.withLock { counts } }
    var maximumActive: Int { lock.withLock { maximum } }
    func enter(_ index: Int) { lock.withLock { counts[index] += 1; active += 1; maximum = max(maximum, active) } }
    func leave() { lock.withLock { active -= 1 } }
}

private final class CPUMapLifetimePayload: Sendable {
    let index: Int
    private let lifetime: CPUMapLifetimeCounter
    init(index: Int, lifetime: CPUMapLifetimeCounter) {
        self.index = index
        self.lifetime = lifetime
        lifetime.create()
    }
    deinit { lifetime.destroy() }
}

private final class CPUMapLifetimeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var createdCount = 0
    private var destroyedCount = 0
    var created: Int { lock.withLock { createdCount } }
    var destroyed: Int { lock.withLock { destroyedCount } }
    func create() { lock.withLock { createdCount += 1 } }
    func destroy() { lock.withLock { destroyedCount += 1 } }
}
