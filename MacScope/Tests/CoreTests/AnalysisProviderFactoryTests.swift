import XCTest
@testable import MacScope

/// The GUI provider-selection policy (WS-3 Stage 3b, default-on rollout). The out-of-process XPC
/// worker is the default; explicit flags force in-process; and — critically — running under XCTest
/// forces in-process so an unrelated test's `bootstrap()` store never launches the real `.xpc`.
final class AnalysisProviderFactoryTests: XCTestCase {

    func testLaunchArgumentForcesInProcess() {
        XCTAssertFalse(
            AnalysisProviderFactory.usesOutOfProcessAnalysis(
                arguments: ["MacScope", "--macscope-in-process-analysis"],
                environment: [:]
            )
        )
    }

    func testEnvironmentForcesInProcess() {
        XCTAssertFalse(
            AnalysisProviderFactory.usesOutOfProcessAnalysis(
                arguments: ["MacScope"],
                environment: ["MACSCOPE_IN_PROCESS_ANALYSIS": "1"]
            )
        )
    }

    func testRunningUnderXCTestForcesInProcess() {
        // This assertion runs INSIDE XCTest, so the guard must win even with no forcing flag/env.
        XCTAssertFalse(
            AnalysisProviderFactory.usesOutOfProcessAnalysis(arguments: ["MacScope"], environment: [:]),
            "a test-hosted bootstrap must never launch the real XPC worker"
        )
    }

    func testMakeDefaultUnderXCTestReturnsInProcessEngine() {
        // Because this runs under XCTest, makeDefault must return the in-process engine (not an
        // XPCAnalysisProvider that would open a connection to the embedded service).
        let provider = AnalysisProviderFactory.makeDefault(arguments: ["MacScope"], environment: [:])
        XCTAssertTrue(provider is AnalysisEngine)
    }

    func testNativeRuntimeActivationDoesNotParticipateInDefaultProviderSelection() {
        let arguments = ["MacScope"]
        let nativeEnvironmentKey = "MACSCOPE_NATIVE_DECOMPILER_ENABLED"
        let baselineDecision = AnalysisProviderFactory.usesOutOfProcessAnalysis(
            arguments: arguments,
            environment: [:]
        )
        let nativeEnabledDecision = AnalysisProviderFactory.usesOutOfProcessAnalysis(
            arguments: arguments,
            environment: [nativeEnvironmentKey: "1"]
        )
        let nativeDisabledDecision = AnalysisProviderFactory.usesOutOfProcessAnalysis(
            arguments: arguments,
            environment: [nativeEnvironmentKey: "0"]
        )

        XCTAssertEqual(
            nativeEnabledDecision,
            baselineDecision,
            "enabling the native runtime must not change the authoritative analysis-provider decision"
        )
        XCTAssertEqual(
            nativeDisabledDecision,
            baselineDecision,
            "disabling the native runtime must not change the authoritative analysis-provider decision"
        )

        let provider = AnalysisProviderFactory.makeDefault(
            arguments: arguments,
            environment: [nativeEnvironmentKey: "1"]
        )
        XCTAssertTrue(
            provider is AnalysisEngine,
            "native presentation must leave AnalysisEngine authoritative for workspace analysis"
        )
        XCTAssertFalse(
            provider is XPCAnalysisProvider,
            "the native runtime flag must never select an analysis provider through this factory"
        )
    }
}
