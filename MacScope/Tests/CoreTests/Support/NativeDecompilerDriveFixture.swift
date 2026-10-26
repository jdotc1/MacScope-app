import Foundation
@testable import MacScope

@MainActor
func makeBoundNativeDriveStore() throws -> (WorkspaceStore, RecordingNativeDecompilerSession) {
    let binary = BinaryImage(
        id: UUID(),
        name: "drive-fixture",
        path: "/tmp/drive-fixture",
        kind: "fixture binary",
        architecture: "arm64",
        slot: .primary
    )
    let function = FunctionSummary(
        id: UUID(),
        name: "entry",
        startAddress: 0x1000,
        endAddress: 0x1004,
        confidence: 1
    )
    var analysis = ImageAnalysis()
    analysis.functions = [function]
    analysis.instructions = [InstructionRow(
        address: 0x1000,
        bytes: "c0 03 5f d6",
        mnemonic: "ret",
        operands: "",
        hasBreakpoint: false,
        comment: nil
    )]
    analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
        binary: binary,
        analysis: analysis
    )
    let store = WorkspaceStore(
        workspaceName: "Drive controls",
        snapshot: WorkspaceSnapshot(
            binaries: [binary],
            analysisBySlot: [.primary: analysis]
        ),
        engine: AnalysisEngine(),
        autosaveScheduler: nil
    )
    let session = RecordingNativeDecompilerSession()
    store.bindNativeDecompilerSession(session)
    session.resetControlCounts()
    return (store, session)
}

@MainActor
final class RecordingNativeDecompilerSession:
    NativeDecompilerWorkspaceSessionHandling,
    @unchecked Sendable
{
    private(set) var submissions: [NativeDecompilerWorkspaceSubmission] = []
    private(set) var retries: [NativeDecompilerWorkspaceRetry] = []
    private(set) var projectionFailures: [NativeAuthoredProjectionDiagnostic] = []
    private(set) var cancelCount = 0
    private(set) var terminateCount = 0

    func submit(_ submission: NativeDecompilerWorkspaceSubmission) {
        submissions.append(submission)
    }

    func retry(_ retry: NativeDecompilerWorkspaceRetry) {
        retries.append(retry)
    }

    func publishAuthoredProjectionFailure(
        _ diagnostic: NativeAuthoredProjectionDiagnostic,
        ticket: NativeDriveSubmissionTicket
    ) {
        _ = ticket
        projectionFailures.append(diagnostic)
    }

    func cancelOutstanding() { cancelCount += 1 }
    func terminateSession() { terminateCount += 1 }

    func resetControlCounts() {
        cancelCount = 0
        terminateCount = 0
    }
}
