import Foundation
import XCTest
@testable import MacScope

/// HOP-3 across the worker boundary (U6a): the registry keeps each request's latest phase for a
/// polled `progress(requestID:)`, budgets travel with the request, and an exhausted budget reaches
/// the client as the typed error instead of an "unexpected" failure. No live XPC.
final class AnalysisProgressWireTests: XCTestCase {
    private static let code = Data([0x00, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]) // mov w0,#0; ret

    func testAnEarlyCancelStillWinsWithABudgetSet() {
        let registry = AnalysisWorkerCancellationRegistry()
        let id = UUID()
        registry.cancel(requestID: id)
        let token = registry.register(requestID: id, budget: AnalysisBudget(wallClockLimit: .seconds(60)))
        XCTAssertTrue(token.isCancelled)
        XCTAssertEqual(token.budget.wallClockLimit, .seconds(60))
        XCTAssertThrowsError(try token.check(.load)) { XCTAssertTrue($0 is AnalysisCancelled) }
    }

    func testPollsDuringARunAreMonotonicAndUnknownAfterwards() throws {
        let registry = AnalysisWorkerCancellationRegistry()
        let id = UUID()
        XCTAssertNil(registry.progress(requestID: id), "Unknown before registration")
        let token = registry.register(requestID: id)
        XCTAssertNil(registry.progress(requestID: id), "No phase reported yet")
        var ordinals: [Int] = []
        for phase in [AnalysisPhase.load, .decode, .functionDiscovery, .diagnostics] {
            try token.check(phase)
            ordinals.append(try XCTUnwrap(registry.progress(requestID: id)).phase.ordinal)
        }
        XCTAssertEqual(ordinals, ordinals.sorted())
        XCTAssertEqual(ordinals.last, AnalysisPhase.diagnostics.ordinal)
        registry.deregister(requestID: id)
        XCTAssertNil(registry.progress(requestID: id), "Unknown once finished")
    }

    func testAPollForAnUnknownRequestInsertsNothing() {
        let registry = AnalysisWorkerCancellationRegistry()
        let id = UUID()
        XCTAssertNil(registry.progress(requestID: id))
        XCTAssertFalse(registry.register(requestID: id).isCancelled, "A poll is not an early cancel")
    }

    func testTheProgressReplyEchoesItsRequestAndAnswersUnknownWhenFinished() throws {
        let service = AnalysisWorkerService(engine: AnalysisEngine(), codec: PayloadWireCodec())
        let id = UUID()
        let unknown = try XCTUnwrap(AnalysisProgressReply.decode(service.progressReply(requestID: id)))
        XCTAssertEqual(unknown.requestID, id)
        XCTAssertNil(unknown.phase)
        XCTAssertNil(unknown.progress(for: id))

        let reported = AnalysisProgressReply(requestID: id, progress: AnalysisProgress(phase: .listing, elapsed: .milliseconds(42)))
        let decoded = try XCTUnwrap(AnalysisProgressReply.decode(reported.encoded()))
        XCTAssertEqual(decoded.progress(for: id), AnalysisProgress(phase: .listing, elapsed: .milliseconds(42)))
        XCTAssertNil(decoded.progress(for: UUID()), "A reply for another request is ignored")
    }

    func testAnExhaustedBudgetReachesTheClientTyped() throws {
        let codec = PayloadWireCodec()
        let service = AnalysisWorkerService(engine: AnalysisEngine(), codec: codec)
        let url = try TinyMachO.make(code: Self.code).write()
        let id = UUID()
        let request = codec.encodeRequest(url: url, selection: .machOSlice(nil), overrides: [:], requestID: id,
                                          resourceBudget: nil, analysisBudget: AnalysisBudget(wallClockLimit: .zero))
        XCTAssertEqual(try codec.decodeRequest(request).analysisBudget?.wallClockLimit, .zero)
        let reply = service.handle(requestData: request, requestID: id)
        XCTAssertThrowsError(try codec.decodeReply(reply)) { error in
            let exceeded = error as? AnalysisBudgetExceeded
            XCTAssertNotNil(exceeded, "Typed, not RemoteAnalysisFailure: \(error)")
            XCTAssertEqual(exceeded?.stoppedBefore, .load)
            if case .wallClock(let limit, _)? = exceeded?.reason { XCTAssertEqual(limit, .zero) } else { XCTFail("wall clock") }
        }
    }

    func testARequestWithoutABudgetStillDecodesAsUnlimited() throws {
        let codec = PayloadWireCodec()
        let id = UUID()
        let data = codec.encodeRequest(url: URL(fileURLWithPath: "/tmp/x"), selection: .machOSlice(nil),
                                       overrides: [:], requestID: id, resourceBudget: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["analysisBudget"], "Absent on the wire when unlimited")
        XCTAssertNil(try codec.decodeRequest(data).analysisBudget)
    }

    func testOpenBinaryKeepsTheCallersProgress() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var phases: [AnalysisPhase] = []
            func record(_ phase: AnalysisPhase) { lock.lock(); phases.append(phase); lock.unlock() }
            var recorded: [AnalysisPhase] { lock.lock(); defer { lock.unlock() }; return phases }
        }
        let recorder = Recorder()
        let url = try TinyMachO.make(code: Self.code).write()
        _ = try await AnalysisEngine().openBinary(url: url, selection: .machOSlice(nil), overrides: [:],
                                                   cancellation: .budgeted(progress: { recorder.record($0.phase) }))
        XCTAssertEqual(recorder.recorded.first, .load, "openBinary no longer drops the caller's progress")
        XCTAssertTrue(recorder.recorded.contains(.diagnostics))
    }

    func testThePresentationCountsFinishedPhases() {
        XCTAssertNil(AnalysisProgressPresentation(nil).fraction)
        XCTAssertEqual(AnalysisProgressPresentation(nil).detail, AnalysisProgressPresentation.indeterminateDetail)
        let listing = AnalysisProgressPresentation(AnalysisProgress(phase: .listing, elapsed: .zero))
        XCTAssertEqual(listing.fraction, 3.0 / 9.0)
        XCTAssertEqual(listing.detail, "Step 4 of 9: Building the listing…")
        XCTAssertEqual(AnalysisProgressPresentation(AnalysisProgress(phase: .load, elapsed: .zero)).fraction, 0)
    }
}
