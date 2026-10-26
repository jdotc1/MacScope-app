import XCTest
@testable import MacScope

final class DebuggerLaunchAdmissionPresentationTests: XCTestCase {
    func testLaunchAdmissionDiagnosticUsesTypedBackendEvidence() {
        XCTAssertEqual(
            DebuggerLaunchAdmissionDiagnosticPresentation(
                capabilities: unavailableCapabilities(reason: "No LLDB executable.")
            ),
            DebuggerLaunchAdmissionDiagnosticPresentation(
                kind: .toolchainUnavailable,
                title: "Xcode LLDB unavailable",
                reason: "No LLDB executable.",
                guidance: "Verify that the current Xcode 27 toolchain is installed and selected, then relaunch MacScope.",
                systemImage: "wrench.and.screwdriver",
                isTruncated: false
            )
        )
    }

    func testLaunchAdmissionDiagnosticUsesBackendSummaryForDiscoveredToolchain() {
        let capabilities = DebuggerCapabilityReport(
            backendName: "Xcode LLDB",
            isBackendAvailable: false,
            canLaunch: false,
            canAttach: false,
            canControlExecution: false,
            limitations: ["Generic launch denial."],
            entitlementNotes: [],
            backendAvailability: .discovered(
                toolPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb",
                details: "LLDB readiness proof exited before initialization."
            ),
            launchSupport: .unsupported(reason: "Generic launch denial."),
            attachSupport: .unsupported(reason: "Generic attach denial."),
            executionControlSupport: .unsupported(reason: "Generic control denial.")
        )

        XCTAssertEqual(
            DebuggerLaunchAdmissionDiagnosticPresentation(capabilities: capabilities),
            DebuggerLaunchAdmissionDiagnosticPresentation(
                kind: .readinessProofFailed,
                title: "LLDB readiness check failed",
                reason: "LLDB readiness proof exited before initialization.",
                guidance: "Verify the selected Xcode LLDB can start; inspect MacScope's Console entries if the reason persists.",
                systemImage: "exclamationmark.triangle",
                isTruncated: false
            )
        )
    }

    func testLaunchAdmissionDiagnosticUsesLaunchAuthorityReasonForReadyBackend() {
        let capabilities = DebuggerCapabilityReport(
            backendName: "Xcode LLDB",
            isBackendAvailable: true,
            canLaunch: false,
            canAttach: false,
            canControlExecution: false,
            limitations: ["Global launch authority is missing."],
            entitlementNotes: [],
            backendAvailability: .ready(
                adapterName: "Xcode LLDB",
                details: "LLDB readiness proof passed."
            ),
            launchSupport: .unsupported(reason: "Global launch authority is missing."),
            attachSupport: .unsupported(reason: "Attach is unavailable."),
            executionControlSupport: .unsupported(reason: "Execution control is unavailable.")
        )

        XCTAssertEqual(
            DebuggerLaunchAdmissionDiagnosticPresentation(capabilities: capabilities),
            DebuggerLaunchAdmissionDiagnosticPresentation(
                kind: .launchAuthorityUnavailable,
                title: "Debugger launch unavailable",
                reason: "Global launch authority is missing.",
                guidance: "Restart MacScope if app-global launch authority should be present; the debugger remains fail-closed.",
                systemImage: "lock.shield",
                isTruncated: false
            )
        )
    }

    func testLaunchAdmissionDiagnosticIsNilWhenLaunchIsSupported() {
        XCTAssertNil(
            DebuggerLaunchAdmissionDiagnosticPresentation(
                capabilities: readyCapabilities(
                    launchSupport: .supported,
                    attachSupport: .supported
                )
            )
        )
    }

    func testLaunchAdmissionDiagnosticIsNilForAttachOnlyUnsupportedState() {
        XCTAssertNil(
            DebuggerLaunchAdmissionDiagnosticPresentation(
                capabilities: readyCapabilities(
                    launchSupport: .supported,
                    attachSupport: .unsupported(reason: "Attach is unavailable.")
                )
            )
        )
    }

    func testLaunchAdmissionDiagnosticPublishesEveryTypedReasonSafely() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let omittedTail = "RAW-DIAGNOSTIC-TAIL-MUST-NOT-PUBLISH"
        let rawReason = "\(home)/Private\nnext\t\u{0001}\u{007F} "
            + String(repeating: "🙂", count: 400)
            + omittedTail
        let cases: [(DebuggerCapabilityReport, DebuggerLaunchAdmissionDiagnosticKind)] = [
            (unavailableCapabilities(reason: rawReason), .toolchainUnavailable),
            (discoveredCapabilities(details: rawReason), .readinessProofFailed),
            (
                readyCapabilities(
                    launchSupport: .unsupported(reason: rawReason),
                    attachSupport: .supported
                ),
                .launchAuthorityUnavailable
            )
        ]

        for (capabilities, expectedKind) in cases {
            let diagnostic = try XCTUnwrap(
                DebuggerLaunchAdmissionDiagnosticPresentation(capabilities: capabilities)
            )
            XCTAssertEqual(diagnostic.kind, expectedKind)
            XCTAssertTrue(diagnostic.reason.contains("<home>/Private"))
            XCTAssertTrue(diagnostic.reason.contains("\\nnext\\t\\u{0001}\\u{007F}"))
            XCTAssertTrue(diagnostic.reason.hasSuffix("… [truncated]"))
            XCTAssertTrue(diagnostic.isTruncated)
            XCTAssertLessThanOrEqual(diagnostic.reason.utf8.count, 1_024)
            XCTAssertFalse(diagnostic.reason.contains(home))
            XCTAssertFalse(diagnostic.reason.contains(omittedTail))
            XCTAssertFalse(diagnostic.reason.contains("�"))
            XCTAssertFalse(diagnostic.reason.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x7F
            })
        }
    }

    func testLaunchAdmissionDiagnosticUsesStableFallbackForEmptyTypedEvidence() throws {
        let cases: [(DebuggerCapabilityReport, String)] = [
            (unavailableCapabilities(reason: " \n "), "Xcode LLDB is unavailable."),
            (discoveredCapabilities(details: "\t"), "LLDB readiness could not be verified."),
            (
                readyCapabilities(
                    launchSupport: .unsupported(reason: "\r"),
                    attachSupport: .supported
                ),
                "Debugger launch is unavailable."
            )
        ]

        for (capabilities, expectedReason) in cases {
            let diagnostic = try XCTUnwrap(
                DebuggerLaunchAdmissionDiagnosticPresentation(capabilities: capabilities)
            )
            XCTAssertEqual(diagnostic.reason, expectedReason)
            XCTAssertFalse(diagnostic.isTruncated)
        }
    }

    @MainActor
    func testLaunchAdmissionDiagnosticPreservesFailClosedZeroDispatchAndSession() async {
        let client = CountingUnavailableDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.importedExecutablePath = "/bin/echo"
        let sessionBeforeReadingDiagnostic = viewModel.session

        let diagnostic = viewModel.launchAdmissionDiagnostic

        XCTAssertEqual(diagnostic?.reason, "No LLDB executable.")
        XCTAssertEqual(viewModel.session, sessionBeforeReadingDiagnostic)
        XCTAssertFalse(viewModel.canLaunchSelectedTarget)
        XCTAssertEqual(
            viewModel.controlAvailability(for: .launch).disabledReason,
            "Launch unavailable: No LLDB executable."
        )

        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.launchCallCount, 0)
    }

    @MainActor
    func testDirectLaunchGuardRejectsUnsupportedCapabilityWithoutDispatch() async {
        let client = CountingUnavailableDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canLaunch)

        await viewModel.launch(
            configuration: DebuggerLaunchConfiguration(executablePath: "/bin/echo")
        )

        XCTAssertEqual(client.launchCallCount, 0)
        XCTAssertEqual(
            viewModel.session.processState,
            .unavailable(reason: "Launch unavailable: No LLDB executable.")
        )
        XCTAssertEqual(viewModel.lastError, "Launch unavailable: No LLDB executable.")
    }

    private func unavailableCapabilities(reason: String) -> DebuggerCapabilityReport {
        DebuggerCapabilityReport(
            backendName: "Xcode LLDB",
            isBackendAvailable: false,
            canLaunch: false,
            canAttach: false,
            canControlExecution: false,
            limitations: [reason],
            entitlementNotes: [],
            backendAvailability: .unavailable(reason: reason),
            launchSupport: .unsupported(reason: reason),
            attachSupport: .unsupported(reason: reason),
            executionControlSupport: .unsupported(reason: reason)
        )
    }

    private func readyCapabilities(
        launchSupport: DebuggerOperationSupport,
        attachSupport: DebuggerOperationSupport
    ) -> DebuggerCapabilityReport {
        DebuggerCapabilityReport(
            backendName: "Xcode LLDB",
            isBackendAvailable: true,
            canLaunch: launchSupport.isSupported,
            canAttach: attachSupport.isSupported,
            canControlExecution: false,
            limitations: [],
            entitlementNotes: [],
            backendAvailability: .ready(
                adapterName: "Xcode LLDB",
                details: "LLDB readiness proof passed."
            ),
            launchSupport: launchSupport,
            attachSupport: attachSupport,
            executionControlSupport: .unsupported(reason: "Execution control is unavailable.")
        )
    }

    private func discoveredCapabilities(details: String) -> DebuggerCapabilityReport {
        DebuggerCapabilityReport(
            backendName: "Xcode LLDB",
            isBackendAvailable: false,
            canLaunch: false,
            canAttach: false,
            canControlExecution: false,
            limitations: [details],
            entitlementNotes: [],
            backendAvailability: .discovered(
                toolPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb",
                details: details
            ),
            launchSupport: .unsupported(reason: details),
            attachSupport: .unsupported(reason: details),
            executionControlSupport: .unsupported(reason: details)
        )
    }
}

@MainActor
private final class CountingUnavailableDebuggerClient: DebuggerClient {
    let capabilities = DebuggerCapabilityReport(
        backendName: "Xcode LLDB",
        isBackendAvailable: false,
        canLaunch: false,
        canAttach: false,
        canControlExecution: false,
        limitations: ["No LLDB executable."],
        entitlementNotes: [],
        backendAvailability: .unavailable(reason: "No LLDB executable."),
        launchSupport: .unsupported(reason: "No LLDB executable."),
        attachSupport: .unsupported(reason: "No LLDB executable."),
        executionControlSupport: .unsupported(reason: "No LLDB executable.")
    )

    private(set) var launchCallCount = 0

    func makeInitialSnapshot() -> DebuggerSessionSnapshot {
        .empty
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        launchCallCount += 1
        return .empty
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func replaceBreakpoints(
        _ breakpoints: [DebuggerBreakpoint],
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }
}
