import Foundation
import XCTest
@testable import MacScope

/// DOT-08 focused, newly authored selectors. UNEXECUTED in the portable handback.
/// The macOS owner chooses affected selectors; this is not a request to rerun replay suites.
/// Add ReconstructionReplayEconomyFixtures.swift to this test target with `@testable import MacScope`.
final class ReconstructionReplayEconomyTests: XCTestCase {
    func testExactRetryPreservesCanonicalAndProviderBytes() throws {
        for scenario in try ReplayEconomyFixtures.scenarios() where scenario.expected == .sameIdentity {
            let first = try ReconstructionPromptReplayIdentity.canonicalRequest(scenario.original)
            let retry = try ReconstructionPromptReplayIdentity.canonicalRequest(scenario.current)
            XCTAssertEqual(try first.replayEncodedRequest(), try retry.replayEncodedRequest(), scenario.name)
            XCTAssertEqual(try providerBytes(first, model: scenario.originalModel),
                try providerBytes(retry, model: scenario.currentModel), scenario.name)
            XCTAssertEqual(try ReplayEconomyFixtures.identity(request: scenario.original,
                model: scenario.originalModel, toolRequests: scenario.originalTools),
                try ReplayEconomyFixtures.identity(request: scenario.current,
                    model: scenario.currentModel, toolRequests: scenario.currentTools), scenario.name)
            if case .sourceRevision(let value) = retry {
                XCTAssertEqual(value.checkpointRevision, 3, "Retain the semantic diagnostic floor")
                guard case .sourceRevision(let original) = scenario.original else {
                    return XCTFail("Source fixture changed kinds")
                }
                XCTAssertEqual(value.context, original.context)
            }
        }
    }

    func testSemanticAndModelChangesCannotShareReplayKeys() throws {
        for scenario in try ReplayEconomyFixtures.scenarios()
        where scenario.expected == .differentIdentity || scenario.expected == .modelChanged {
            let first = try ReplayEconomyFixtures.identity(request: scenario.original,
                model: scenario.originalModel, toolRequests: scenario.originalTools)
            let next = try ReplayEconomyFixtures.identity(request: scenario.current,
                model: scenario.currentModel, toolRequests: scenario.currentTools)
            XCTAssertNotEqual(try first.key, try next.key, scenario.name)
            let original = try ReconstructionPromptReplayIdentity.canonicalRequest(scenario.original)
            let current = try ReconstructionPromptReplayIdentity.canonicalRequest(scenario.current)
            XCTAssertNotEqual(try providerBytes(original, model: scenario.originalModel),
                try providerBytes(current, model: scenario.currentModel), scenario.name)
            if scenario.expected == .modelChanged {
                XCTAssertEqual(original, current, "Model identity is separate from semantic request identity")
            }
        }
    }

    func testSmallByteBudgetsRetainTypedRefusals() throws {
        for scenario in try ReplayEconomyFixtures.scenarios() {
            if scenario.expected == .providerBudgetRefusal {
                XCTAssertThrowsError(try Phase2ReconstructionOpenAIChatRequestEncoder(
                    maximumProviderBodyBytes: try XCTUnwrap(scenario.maximumProviderBodyBytes)).encode(
                        request: scenario.current,
                        configuration: scenario.currentModel.configuration(for: scenario.current))) {
                    XCTAssertEqual($0 as? Phase2ReconstructionOpenAIChatRequestEncodingError, .providerBodyLimitExceeded)
                }
            }
            if scenario.expected == .contextBudgetRefusal {
                XCTAssertThrowsError(try scenario.contextInput.compile(
                    maximumContextBytes: try XCTUnwrap(scenario.maximumContextBytes))) {
                    XCTAssertEqual($0 as? ReconstructionContextCompilerError, .contextBudgetExceeded)
                }
            }
        }
    }

    func testImmutableProjectionAndIdentityRemainIsolatedAcrossCalls() throws {
        let fixtures = try ReplayEconomyFixtures.scenarios()
        let a = try XCTUnwrap(fixtures.first { $0.name == "round_exact_retry" })
        let b = try XCTUnwrap(fixtures.first { $0.name == "changed_objective" })
        let projector = try ReconstructionReadablePromptProjection()
        let before = try projector.projectR2(a.current)
        let different = try projector.projectR2(b.current)
        let after = try projector.projectR2(a.current)
        XCTAssertEqual(before, after, "A → B → A cannot reuse another request's immutable encoding")
        XCTAssertNotEqual(before.userJSON, different.userJSON)
        XCTAssertNotEqual(before.canonicalAuthorityRequestSHA256, different.canonicalAuthorityRequestSHA256)
        let beforeIdentity = try ReplayEconomyFixtures.identity(request: a.current,
            model: a.currentModel, toolRequests: a.currentTools)
        let differentIdentity = try ReplayEconomyFixtures.identity(request: b.current,
            model: b.currentModel, toolRequests: b.currentTools)
        let afterIdentity = try ReplayEconomyFixtures.identity(request: a.current,
            model: a.currentModel, toolRequests: a.currentTools)
        XCTAssertEqual(beforeIdentity, afterIdentity)
        XCTAssertNotEqual(beforeIdentity, differentIdentity)
    }

    private func providerBytes(_ request: ReconstructionAIWorkerRequest,
                               model: ReplayEconomyFixtures.Model) throws -> Data {
        try Phase2ReconstructionOpenAIChatRequestEncoder().encode(request: request,
            configuration: model.configuration(for: request)).requestBody
    }
}
