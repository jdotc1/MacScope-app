import Foundation
import XCTest
@testable import MacScope

/// HOP-3: progress reports and a time/memory budget at the analysis phase checkpoints.
@MainActor
final class AnalysisBudgetProgressTests: XCTestCase {
    private final class PhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [AnalysisPhase] = []
        func record(_ phase: AnalysisPhase) { lock.lock(); storage.append(phase); lock.unlock() }
        var phases: [AnalysisPhase] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private static let code = Data([0x00, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]) // mov w0,#0; ret

    func testProgressReportsEveryPhaseInPipelineOrder() throws {
        let recorder = PhaseRecorder()
        let token = AnalysisCancellationToken.budgeted(progress: { recorder.record($0.phase) })
        let url = try TinyMachO.make(code: Self.code).write()
        _ = try AnalysisEngine().analyze(url: url, cancellation: token)
        var firstSeen: [AnalysisPhase] = []
        for phase in recorder.phases where !firstSeen.contains(phase) { firstSeen.append(phase) }
        XCTAssertEqual(firstSeen, [
            .load, .decode, .functionDiscovery, .listing, .jumpTables, .controlFlow,
            .dataReferences, .switchHints, .diagnostics,
        ])
        XCTAssertEqual(firstSeen.count, AnalysisPhase.analysisPhaseCount)
    }

    func testExhaustedTimeBudgetIsTypedPartialResultNotTruncation() throws {
        let token = AnalysisCancellationToken.budgeted(budget: AnalysisBudget(wallClockLimit: .zero, physicalFootprintLimitBytes: nil))
        let url = try TinyMachO.make(code: Self.code).write()
        XCTAssertThrowsError(try AnalysisEngine().analyze(url: url, cancellation: token)) { error in
            guard let exceeded = error as? AnalysisBudgetExceeded else {
                return XCTFail("expected AnalysisBudgetExceeded, got \(error)")
            }
            guard case .wallClock = exceeded.reason else { return XCTFail("expected a time reason") }
            XCTAssertEqual(exceeded.stoppedBefore, .load)
            XCTAssertEqual(exceeded.completedPhases, [])
            XCTAssertNotNil(exceeded.errorDescription)
        }
    }

    func testMemoryBudgetStopsAtTheFirstCheckpointOverTheLimit() throws {
        // An already-exceeded budget must stop at the first named checkpoint.
        let token = AnalysisCancellationToken.budgeted(
            budget: AnalysisBudget(wallClockLimit: nil, physicalFootprintLimitBytes: 1_000),
            footprint: { 2_000 }
        )
        let url = try TinyMachO.make(code: Self.code).write()
        XCTAssertThrowsError(try AnalysisEngine().analyze(url: url, cancellation: token)) { error in
            let exceeded = error as? AnalysisBudgetExceeded
            XCTAssertEqual(exceeded?.reason, .memory(limitBytes: 1_000, footprintBytes: 2_000))
            XCTAssertEqual(exceeded?.stoppedBefore, .load)
            XCTAssertEqual(exceeded?.completedPhases, [])
        }
    }

    func testUnlimitedBudgetAndCurrentFootprintProbe() throws {
        XCTAssertNotNil(AnalysisBudget.currentPhysicalFootprint())
        let url = try TinyMachO.make(code: Self.code).write()
        let snapshot = try AnalysisEngine().analyze(
            url: url, cancellation: AnalysisCancellationToken.budgeted(budget: .unlimited)
        )
        XCTAssertEqual(snapshot.functions.count, 1)
    }
}
