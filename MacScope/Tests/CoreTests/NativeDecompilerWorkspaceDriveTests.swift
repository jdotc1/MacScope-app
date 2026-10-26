import Foundation
import XCTest
@testable import MacScope

@MainActor
final class NativeDecompilerWorkspaceDriveTests: XCTestCase {
    func testCompleteRestoredTargetSubmitsExactlyOnce() throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let baseline = session.submissions.count
        store.establishNativeDriveContext(origin: .authoritativeRestore)
        store.finishNativeDriveInstallation()
        XCTAssertEqual(session.submissions.count - baseline, 1)
        guard case .submitted = store.nativeDecompilerDriveContext.machine.state else {
            return XCTFail("complete installation did not reach submitted")
        }
        store.finishNativeDriveInstallation()
        XCTAssertEqual(session.submissions.count - baseline, 1)
    }

    func testSelectedOwnerReadinessSubmitsExactlyOnce() throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let readiness = try prepareWaitingForReadiness(store)
        let baseline = session.submissions.count
        restoreResolvedAnalysis(readiness.analysis, in: store)
        store.acceptNativeReadiness(
            imageSlot: readiness.owner.imageSlot,
            binaryID: readiness.owner.binaryID,
            rehydrationEpoch: readiness.epoch
        )
        XCTAssertEqual(session.submissions.count - baseline, 1)
        guard case .submitted = store.nativeDecompilerDriveContext.machine.state else {
            return XCTFail("accepted readiness did not reach submitted")
        }
        store.acceptNativeReadiness(
            imageSlot: readiness.owner.imageSlot,
            binaryID: readiness.owner.binaryID,
            rehydrationEpoch: readiness.epoch
        )
        XCTAssertEqual(session.submissions.count - baseline, 1)
    }

    func testStaleRehydrationEpochIsIgnored() throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let readiness = try prepareWaitingForReadiness(store)
        let baseline = session.submissions.count
        let staleEpoch = readiness.epoch + 1
        restoreResolvedAnalysis(readiness.analysis, in: store)
        // Advance only the drive's captured epoch. The store's authoritative rehydration epoch
        // remains older, so the first guard—not the independent drive-epoch fence—must reject it.
        store.nativeDecompilerDriveContext.readinessEpoch = staleEpoch
        store.acceptNativeReadiness(
            imageSlot: readiness.owner.imageSlot,
            binaryID: readiness.owner.binaryID,
            rehydrationEpoch: staleEpoch
        )
        XCTAssertEqual(session.submissions.count, baseline)
        guard case .waitingForReadiness = store.nativeDecompilerDriveContext.machine.state else {
            return XCTFail("stale readiness changed drive state")
        }
    }

    func testStaleReadinessFailureIsIgnored() throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let readiness = try prepareWaitingForReadiness(store)
        let submissionBaseline = session.submissions.count
        let cancellationBaseline = session.cancelCount
        let staleEpoch = readiness.epoch + 1
        store.nativeDecompilerDriveContext.readinessEpoch = staleEpoch
        store.rejectNativeReadiness(
            imageSlot: readiness.owner.imageSlot,
            binaryID: readiness.owner.binaryID,
            rehydrationEpoch: staleEpoch,
            failure: .rehydrationFailed(code: "stale")
        )
        XCTAssertEqual(session.submissions.count, submissionBaseline)
        XCTAssertEqual(session.cancelCount, cancellationBaseline)
        XCTAssertNil(store.lastIssue)
        guard case .waitingForReadiness = store.nativeDecompilerDriveContext.machine.state else {
            return XCTFail("stale readiness failure changed drive state")
        }
    }

    func testSiblingReadinessFailureIsIgnored() throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let readiness = try prepareWaitingForReadiness(store)
        let submissionBaseline = session.submissions.count
        let cancellationBaseline = session.cancelCount
        store.rejectNativeReadiness(
            imageSlot: ImageSlot(rawValue: readiness.owner.imageSlot.rawValue + 1),
            binaryID: readiness.owner.binaryID,
            rehydrationEpoch: readiness.epoch,
            failure: .rehydrationFailed(code: "sibling")
        )
        XCTAssertEqual(session.submissions.count, submissionBaseline)
        XCTAssertEqual(session.cancelCount, cancellationBaseline)
        XCTAssertNil(store.lastIssue)
        guard case .waitingForReadiness = store.nativeDecompilerDriveContext.machine.state else {
            return XCTFail("sibling readiness failure changed drive state")
        }
    }

    func testRejectedReadinessSubmitsZeroWorkAndPublishesIssue() throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let readiness = try prepareWaitingForReadiness(store)
        let submissionBaseline = session.submissions.count
        store.rejectNativeReadiness(
            imageSlot: readiness.owner.imageSlot,
            binaryID: readiness.owner.binaryID,
            rehydrationEpoch: readiness.epoch,
            failure: .rehydrationFailed(code: "fixture-failure")
        )
        XCTAssertEqual(session.submissions.count, submissionBaseline)
        XCTAssertEqual(
            store.lastIssue,
            "Native decompilation is unavailable because analysis restore failed (fixture-failure)."
        )
        guard case .retired(_, .readinessFailed) =
                store.nativeDecompilerDriveContext.machine.state else {
            return XCTFail("rejected readiness did not retire with readinessFailed")
        }
    }

    func testReconcileSelectionOrFocusChangedRetargetsExactlyOnce() throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let secondFunction = try installSecondFunction(in: store)
        let baseline = session.submissions.count
        XCTAssertTrue(store.selectAddress(.init(slot: .primary, address: 0x2000)))
        XCTAssertEqual(session.submissions.count - baseline, 1)
        XCTAssertEqual(session.submissions.last?.functionID, secondFunction.id)
        guard case let .submitted(ticket) = store.nativeDecompilerDriveContext.machine.state else {
            return XCTFail("selection reconciliation did not submit")
        }
        XCTAssertEqual(ticket.target.functionID, secondFunction.id)
    }

    func testReconcileAcceptedStructuralLandingWithNoExactFunctionRetires() throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let baseline = session.submissions.count
        let cancellationBaseline = session.cancelCount
        let binary = try XCTUnwrap(store.snapshot.binary(in: .primary))
        var analysis = try XCTUnwrap(store.snapshot.analysis(in: .primary))
        analysis.functions = []
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: analysis
        )
        store.snapshot.analysisBySlot[.primary] = analysis
        store.reconcileNativeDecompilerDrive(reason: .acceptedStructuralAnalysis)
        XCTAssertEqual(session.submissions.count, baseline)
        XCTAssertEqual(session.cancelCount - cancellationBaseline, 1)
        guard case .retired(_, .noExactFunction) =
                store.nativeDecompilerDriveContext.machine.state else {
            return XCTFail("ambiguous structural landing did not retire with noExactFunction")
        }
    }

    func testSemanticAuthoringMutationRedrivesOnlyTheSelectedOwner() throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let baseline = session.submissions.count
        let priorTicket = try XCTUnwrap(session.submissions.last?.ticket)
        store.snapshot.addressOverrides[.primary(0x1000)] = AddressOverride(
            customName: "renamed_entry"
        )
        store.noteNativeSemanticAuthoringMutation(
            imageSlots: [.primary],
            schedulesStructuralReanalysis: false
        )
        XCTAssertEqual(session.submissions.count - baseline, 1)
        let nextTicket = try XCTUnwrap(session.submissions.last?.ticket)
        XCTAssertEqual(nextTicket.semanticInputGeneration, priorTicket.semanticInputGeneration + 1)
        store.noteNativeSemanticAuthoringMutation(
            imageSlots: [ImageSlot(rawValue: 1)],
            schedulesStructuralReanalysis: false
        )
        XCTAssertEqual(session.submissions.count - baseline, 1)
    }

    func testValidSemanticReplacementClearsUnboundStaleProjectionFailureBeforeBinding() throws {
        let (store, _) = try makeBoundNativeDriveStore()
        let drive = store.nativeDecompilerDriveContext
        drive.session = nil
        drive.sessionIdentity = nil

        store.snapshot.addressOverrides[.primary(0x1000)] = AddressOverride(
            customName: "invalid\nname"
        )
        store.noteNativeSemanticAuthoringMutation(
            imageSlots: [.primary],
            schedulesStructuralReanalysis: false
        )
        XCTAssertNotNil(drive.pendingProjectionFailure)

        store.snapshot.addressOverrides[.primary(0x1000)] = AddressOverride(
            customName: "current_name"
        )
        store.noteNativeSemanticAuthoringMutation(
            imageSlots: [.primary],
            schedulesStructuralReanalysis: false
        )

        let replacement = RecordingNativeDecompilerSession()
        store.bindNativeDecompilerSession(replacement)
        XCTAssertNil(drive.pendingProjectionFailure)
        XCTAssertTrue(replacement.projectionFailures.isEmpty)
        XCTAssertEqual(replacement.submissions.count, 1)
    }

    func testSemanticOverrideChangedDiscriminatesNameSignatureAndAppliedType() {
        XCTAssertFalse(WorkspaceStore.nativeDecompilerSemanticOverrideChanged(from: nil, to: nil))
        XCTAssertFalse(WorkspaceStore.nativeDecompilerSemanticOverrideChanged(
            from: AddressOverride(customComment: "before"),
            to: AddressOverride(customComment: "after")
        ))
        XCTAssertTrue(WorkspaceStore.nativeDecompilerSemanticOverrideChanged(
            from: nil,
            to: AddressOverride(customName: "renamed")
        ))
        XCTAssertTrue(WorkspaceStore.nativeDecompilerSemanticOverrideChanged(
            from: nil,
            to: AddressOverride(signature: .init(noReturnState: .noReturn))
        ))
        XCTAssertTrue(WorkspaceStore.nativeDecompilerSemanticOverrideChanged(
            from: nil,
            to: AddressOverride(appliedTypeName: "Header")
        ))
    }

    func testRetireNativeDecompilerDriveCancelsWithoutInventingFutureReasonDispatch() throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let baseline = session.submissions.count
        let cancellationBaseline = session.cancelCount
        // `sessionTerminated` is the sole current production caller. The focus/image/replacement
        // cases remain explicitly future-reserved API and are not manufactured by this test.
        store.retireNativeDecompilerDrive(reason: .sessionTerminated)
        XCTAssertEqual(session.submissions.count, baseline)
        XCTAssertEqual(session.cancelCount - cancellationBaseline, 1)
        guard case .retired(_, .sessionTerminated) =
                store.nativeDecompilerDriveContext.machine.state else {
            return XCTFail("explicit retirement did not preserve its reason")
        }
    }

    func testTerminateCancelsAndUnbindsExactlyOnce() throws {
        let (store, session) = try makeBoundNativeDriveStore()
        let submissionBaseline = session.submissions.count
        let cancellationBaseline = session.cancelCount
        store.terminateNativeDecompilerSession()
        XCTAssertEqual(session.submissions.count, submissionBaseline)
        XCTAssertEqual(session.cancelCount - cancellationBaseline, 1)
        XCTAssertEqual(session.terminateCount, 1)
        XCTAssertNil(store.nativeDecompilerDriveContext.session)
        XCTAssertNil(store.nativeDecompilerDriveContext.sessionIdentity)
        XCTAssertNil(store.nativeDecompilerDriveContext.bindingID)
        guard case .retired(_, .sessionTerminated) =
                store.nativeDecompilerDriveContext.machine.state else {
            return XCTFail("session termination did not retire the drive")
        }
        store.terminateNativeDecompilerSession()
        XCTAssertEqual(session.terminateCount, 1)
    }

    private struct ReadinessFixture {
        let analysis: ImageAnalysis
        let owner: NativeDriveImageOwner
        let epoch: UInt64
    }

    private func prepareWaitingForReadiness(
        _ store: WorkspaceStore
    ) throws -> ReadinessFixture {
        let binary = try XCTUnwrap(store.snapshot.binary(in: .primary))
        let resolvedAnalysis = try XCTUnwrap(store.snapshot.analysis(in: .primary))
        var persistedAnalysis = resolvedAnalysis
        persistedAnalysis.imageBytes = Data([0xc0, 0x03, 0x5f, 0xd6])
        persistedAnalysis.sections = []
        persistedAnalysis.machOMetadata = nil
        persistedAnalysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: persistedAnalysis
        )
        store.snapshot.analysisBySlot[.primary] = persistedAnalysis
        store.establishNativeDriveContext(origin: .authoritativeRestore)
        store.finishNativeDriveInstallation()
        guard case .waitingForReadiness = store.nativeDecompilerDriveContext.machine.state else {
            throw FixtureError.didNotWaitForReadiness
        }
        return .init(
            analysis: resolvedAnalysis,
            owner: .init(imageSlot: .primary, binaryID: binary.id),
            epoch: store.nativeDecompilerRehydrationEpoch
        )
    }

    private func restoreResolvedAnalysis(_ analysis: ImageAnalysis, in store: WorkspaceStore) {
        store.snapshot.analysisBySlot[.primary] = analysis
    }

    private func installSecondFunction(in store: WorkspaceStore) throws -> FunctionSummary {
        let binary = try XCTUnwrap(store.snapshot.binary(in: .primary))
        var analysis = try XCTUnwrap(store.snapshot.analysis(in: .primary))
        let function = FunctionSummary(
            id: UUID(),
            name: "second",
            startAddress: 0x2000,
            endAddress: 0x2004,
            confidence: 1
        )
        analysis.functions.append(function)
        analysis.instructions.append(InstructionRow(
            address: 0x2000,
            bytes: "c0 03 5f d6",
            mnemonic: "ret",
            operands: "",
            hasBreakpoint: false,
            comment: nil
        ))
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: analysis
        )
        store.snapshot.analysisBySlot[.primary] = analysis
        return function
    }

    private enum FixtureError: Error {
        case didNotWaitForReadiness
    }
}
