import Foundation
import XCTest

@testable import MacScope

final class NativeDecompilerDriveStateMachineTests: XCTestCase {
    func testPatchFencesSubmittedTicketUntilStructuralLanding() throws {
        var fixture = try makeSubmittedFixture()
        XCTAssertEqual(try fixture.machine.handle(.patchedBytesChanged), [.invalidateOutstanding])
        XCTAssertEqual(fixture.machine.state, .waitingForReadiness(
            fixture.context,
            NativeDriveTargetSeed(context: fixture.context, owner: fixture.owner,
                                  selectedAddress: fixture.target.functionStart),
            .structuralReanalysisPending
        ))
        XCTAssertEqual(try fixture.machine.handle(.request), [])
        let movedSeed = NativeDriveTargetSeed(
            context: fixture.context, owner: fixture.owner,
            selectedAddress: fixture.target.functionStart + 2
        )
        XCTAssertEqual(try fixture.machine.handle(
            .targetChanged(seed: movedSeed, resolved: fixture.target)
        ), [])
        XCTAssertEqual(fixture.machine.state, .waitingForReadiness(
            fixture.context, movedSeed, .structuralReanalysisPending
        ))
        XCTAssertEqual(try fixture.machine.handle(.terminal(.success, ticket: fixture.ticket)), [])
        let effects = try fixture.machine.handle(.acceptedStructuralLanding(fixture.target))
        guard case let .submit(next, _) = try XCTUnwrap(effects.first) else {
            return XCTFail("Expected replacement ticket after structural landing")
        }
        XCTAssertGreaterThan(next.semanticInputGeneration, fixture.ticket.semanticInputGeneration)
    }

    /// B573-1: Refresh while patched analysis is pending must not drop the
    /// structural fence; a same-image selection change then submits nothing
    /// until the patched analysis lands.
    func testRefreshDuringPatchedReanalysisKeepsStructuralFence() throws {
        var fixture = try makeSubmittedFixture()
        XCTAssertEqual(try fixture.machine.handle(.patchedBytesChanged), [.invalidateOutstanding])
        XCTAssertEqual(try fixture.machine.handle(.refresh), [])
        let movedSeed = NativeDriveTargetSeed(
            context: fixture.context, owner: fixture.owner,
            selectedAddress: fixture.target.functionStart + 2
        )
        XCTAssertEqual(try fixture.machine.handle(
            .targetChanged(seed: movedSeed, resolved: fixture.target)
        ), [], "no request before patched analysis lands")
        XCTAssertEqual(fixture.machine.state, .waitingForReadiness(
            fixture.context, movedSeed, .structuralReanalysisPending
        ))
        let effects = try fixture.machine.handle(.acceptedStructuralLanding(fixture.target))
        guard case let .submit(next, _) = try XCTUnwrap(effects.first) else {
            return XCTFail("the landing submits the refreshed request")
        }
        XCTAssertGreaterThan(next.semanticInputGeneration, fixture.ticket.semanticInputGeneration)
    }

    /// Control: a Refresh without a pending patch still resubmits immediately.
    func testRefreshWithoutPendingPatchResubmits() throws {
        var fixture = try makeSubmittedFixture()
        let effects = try fixture.machine.handle(.refresh)
        XCTAssertTrue(effects.contains { if case .submit = $0 { return true }; return false }, "\(effects)")
    }

    func testFreshRestoreAndInteractiveOriginsEstablishDistinctContexts() throws {
        assertDriveContract(["freshImport", "authoritativeRestore", "interactiveAdoption"])
    }

    func testSameHandlerBindingIsIdempotentAndReplacementAdvancesBindingGeneration() throws {
        assertDriveContract(["handlerBindingGeneration", "NativeDriveHandlerBindingID"])
    }

    func testTicketIsStoredBeforeSubmitEffectIsReturned() throws {
        assertDriveContract(["state = .submitted(ticket)", ".submit(ticket:"])
    }

    func testDuplicateAndReentrantCurrentEventsEmitNoSecondSubmit() throws {
        assertDriveContract(["lastSubmittedTicket", "submitted"])
    }

    func testSelectionMoveWithinSameResolvedFunctionDoesNotCancelOrResubmit() throws {
        var fixture = try makeSubmittedFixture()
        let movedSeed = NativeDriveTargetSeed(
            context: fixture.context,
            owner: fixture.owner,
            selectedAddress: 0x1002
        )

        XCTAssertEqual(
            try fixture.machine.handle(
                .targetChanged(seed: movedSeed, resolved: fixture.target)
            ),
            [],
            "Moving within the same resolved function must preserve its in-flight request"
        )
        XCTAssertEqual(fixture.machine.state, .submitted(fixture.ticket))
    }

    func testChangingFunctionWaitsForItsOwnSemanticProjectionBeforeSubmitting() throws {
        var fixture = try makeSubmittedFixture()
        let replacement = NativeDriveResolvedTarget(
            context: fixture.context,
            owner: fixture.owner,
            functionID: UUID(),
            functionStart: 0x2000,
            analysisFingerprintSHA256: fixture.target.analysisFingerprintSHA256
        )
        let replacementSeed = NativeDriveTargetSeed(
            context: fixture.context,
            owner: fixture.owner,
            selectedAddress: 0x2000
        )

        XCTAssertEqual(
            try fixture.machine.handle(
                .targetChanged(seed: replacementSeed, resolved: replacement)
            ),
            [.invalidateOutstanding]
        )
        XCTAssertEqual(fixture.machine.state, .ready(fixture.context, replacement))

        let effects = try fixture.machine.handle(
            .semanticInputChanged(validSemantic("c"), deferUntilStructuralLanding: false)
        )
        XCTAssertEqual(effects.count, 1)
        guard case let .submit(ticket, .allowValidatedCache) = try XCTUnwrap(effects.first) else {
            return XCTFail("Expected one replacement submission after its semantic projection")
        }
        XCTAssertEqual(ticket.target, replacement)
        XCTAssertEqual(fixture.machine.state, .submitted(ticket))
    }

    func testDistinctInvalidDiagnosticsCancelOnceAndCannotReviveStaleTicket() throws {
        var fixture = try makeSubmittedFixture()
        let first = NativeAuthoredProjectionDiagnostic.invalid(
            id: .init(code: "invalid-a", imageSlot: .primary, subject: "function")
        )
        let second = NativeAuthoredProjectionDiagnostic.invalid(
            id: .init(code: "invalid-b", imageSlot: .primary, subject: "function")
        )

        let firstEffects = try fixture.machine.handle(
            .semanticInputChanged(.invalid(first), deferUntilStructuralLanding: false)
        )
        XCTAssertEqual(firstEffects.first, .invalidateOutstanding)
        guard case let .publishProjectionFailure(firstObserved, firstTicket) = try XCTUnwrap(
            firstEffects.last
        ) else {
            return XCTFail("Expected the first invalid diagnostic to publish")
        }
        XCTAssertEqual(firstObserved, first)
        XCTAssertEqual(firstTicket.semanticInputGeneration, 2)
        XCTAssertEqual(fixture.machine.state, .ready(fixture.context, fixture.target))
        let secondEffects = try fixture.machine.handle(
            .semanticInputChanged(.invalid(second), deferUntilStructuralLanding: false)
        )
        guard case let .publishProjectionFailure(secondObserved, secondTicket) = try XCTUnwrap(
            secondEffects.first
        ) else {
            return XCTFail("Expected the distinct invalid diagnostic to publish")
        }
        XCTAssertEqual(secondEffects.count, 1)
        XCTAssertEqual(secondObserved, second)
        XCTAssertEqual(secondTicket.semanticInputGeneration, 3)
        XCTAssertEqual(
            try fixture.machine.handle(.terminal(.success, ticket: fixture.ticket)),
            []
        )
        XCTAssertEqual(try fixture.machine.handle(.retry), [])
        XCTAssertEqual(fixture.machine.state, .ready(fixture.context, fixture.target))
    }

    func testInvalidSemanticStatePublishesWhenReadinessResolvesExactTarget() throws {
        var machine = NativeDecompilerDriveStateMachine()
        let context = makeContext()
        let owner = NativeDriveImageOwner(imageSlot: .primary, binaryID: UUID())
        let seed = NativeDriveTargetSeed(
            context: context,
            owner: owner,
            selectedAddress: 0x1000
        )
        let target = makeTarget(context: context, owner: owner)
        let diagnostic = NativeAuthoredProjectionDiagnostic.invalid(
            id: .init(code: "invalid-before-ready", imageSlot: .primary, subject: "function")
        )

        _ = try machine.handle(.establish(context))
        _ = try machine.handle(.bind(NativeDriveHandlerBindingID(rawValue: UUID())))
        _ = try machine.handle(
            .installTarget(
                seed: seed,
                resolved: nil,
                waitReason: .selectedOwnerNeedsRehydration
            )
        )
        XCTAssertEqual(
            try machine.handle(
                .semanticInputChanged(.invalid(diagnostic), deferUntilStructuralLanding: false)
            ),
            []
        )
        let effects = try machine.handle(.selectedOwnerReady(target))
        guard case let .publishProjectionFailure(observed, ticket) = try XCTUnwrap(effects.first)
        else {
            return XCTFail("Expected the current invalid state to publish after exact readiness")
        }
        XCTAssertEqual(observed, diagnostic)
        XCTAssertEqual(ticket.target, target)
    }

    func testTerminalSuccessAndFailureDoNotClearTicketOrAutoRetry() throws {
        for result in [
            NativeDriveTerminalResult.success,
            .retryableFailure,
            .terminalFailure,
        ] {
            var fixture = try makeSubmittedFixture()
            XCTAssertEqual(try fixture.machine.handle(.terminal(result, ticket: fixture.ticket)), [])
            XCTAssertEqual(try fixture.machine.handle(.terminal(result, ticket: fixture.ticket)), [])
            XCTAssertEqual(fixture.machine.state, .submitted(fixture.ticket))
        }
    }

    func testCounterExhaustionFailsClosedWithoutWrap() throws {
        var driveMachine = NativeDecompilerDriveStateMachine()
        let driveContext = makeContext()
        _ = try driveMachine.handle(.establish(driveContext))
        XCTAssertEqual(
            try driveMachine.handle(.counterExhausted(.drive)),
            [.publishReadinessFailure(.counterExhausted(.drive))]
        )
        XCTAssertEqual(
            driveMachine.state,
            .exhausted(.drive)
        )
        XCTAssertEqual(try driveMachine.handle(.establish(makeContext())), [])
        XCTAssertEqual(try driveMachine.handle(.request), [])
        XCTAssertEqual(driveMachine.state, .exhausted(.drive))

        var handlerMachine = NativeDecompilerDriveStateMachine(
            handlerBindingGeneration: .max
        )
        XCTAssertEqual(
            try handlerMachine.handle(.bind(.init(rawValue: UUID()))),
            [.publishReadinessFailure(.counterExhausted(.handlerBinding))]
        )
        XCTAssertEqual(handlerMachine.state, .exhausted(.handlerBinding))
        XCTAssertEqual(try handlerMachine.handle(.establish(makeContext())), [])

        var semanticMachine = NativeDecompilerDriveStateMachine(
            semanticInputGeneration: .max
        )
        XCTAssertEqual(
            try semanticMachine.handle(
                .semanticInputChanged(validSemantic("b"), deferUntilStructuralLanding: false)
            ),
            [.publishReadinessFailure(.counterExhausted(.semanticInput))]
        )
        XCTAssertEqual(
            semanticMachine.state,
            .exhausted(.semanticInput)
        )
        let semanticContext = makeContext()
        let semanticOwner = NativeDriveImageOwner(imageSlot: .primary, binaryID: UUID())
        XCTAssertEqual(
            try semanticMachine.handle(
                .selectedOwnerReady(makeTarget(context: semanticContext, owner: semanticOwner))
            ),
            []
        )

        var manualFixture = try makeSubmittedFixture(
            machine: NativeDecompilerDriveStateMachine(manualIntentGeneration: .max)
        )
        XCTAssertEqual(
            try manualFixture.machine.handle(.refresh),
            [.publishReadinessFailure(.counterExhausted(.manualIntent))]
        )
        XCTAssertEqual(
            manualFixture.machine.state,
            .exhausted(.manualIntent)
        )
        XCTAssertEqual(try manualFixture.machine.handle(.targetChanged(
            seed: NativeDriveTargetSeed(
                context: manualFixture.context,
                owner: manualFixture.owner,
                selectedAddress: manualFixture.target.functionStart
            ),
            resolved: manualFixture.target
        )), [])

        var cancellationFixture = try makeSubmittedFixture(
            machine: NativeDecompilerDriveStateMachine(cancellationFence: .max)
        )
        XCTAssertEqual(
            try cancellationFixture.machine.handle(.cancel),
            [.publishReadinessFailure(.counterExhausted(.cancellationFence))]
        )
        XCTAssertEqual(
            cancellationFixture.machine.state,
            .exhausted(.cancellationFence)
        )
    }

    func testDistinctValidAndInvalidIdentityTransitionsAdvanceSemanticGeneration() throws {
        var fixture = try makeSubmittedFixture()
        let validEffects = try fixture.machine.handle(
            .semanticInputChanged(validSemantic("c"), deferUntilStructuralLanding: false)
        )
        guard case let .submit(validTicket, _) = try XCTUnwrap(validEffects.last) else {
            return XCTFail("Expected distinct valid input to submit")
        }
        XCTAssertEqual(validTicket.semanticInputGeneration, fixture.ticket.semanticInputGeneration + 1)

        let diagnostic = NativeAuthoredProjectionDiagnostic.invalid(
            id: .init(code: "invalid-generation", imageSlot: .primary, subject: "function")
        )
        let invalidEffects = try fixture.machine.handle(
            .semanticInputChanged(.invalid(diagnostic), deferUntilStructuralLanding: false)
        )
        guard case let .publishProjectionFailure(_, invalidTicket) = try XCTUnwrap(
            invalidEffects.last
        ) else {
            return XCTFail("Expected distinct invalid input to publish")
        }
        XCTAssertEqual(invalidTicket.semanticInputGeneration, validTicket.semanticInputGeneration + 1)
    }

    func testRepeatedSameValidOrInvalidIdentityIsIdempotent() throws {
        var fixture = try makeSubmittedFixture()
        XCTAssertEqual(
            try fixture.machine.handle(
                .semanticInputChanged(validSemantic("b"), deferUntilStructuralLanding: false)
            ),
            []
        )
        let diagnostic = NativeAuthoredProjectionDiagnostic.invalid(
            id: .init(code: "stable-invalid", imageSlot: .primary, subject: "function")
        )
        _ = try fixture.machine.handle(
            .semanticInputChanged(.invalid(diagnostic), deferUntilStructuralLanding: false)
        )
        XCTAssertEqual(
            try fixture.machine.handle(
                .semanticInputChanged(.invalid(diagnostic), deferUntilStructuralLanding: false)
            ),
            []
        )
    }

    func testChangeThenUndoAdvancesTwiceEvenWhenDigestReturnsToPriorValue() throws {
        assertDriveContract(["advanceSemanticGeneration"])
    }

    func testInvalidStateFencesOutstandingWorkPublishesOnceAndSubmitsZeroWork() throws {
        assertDriveContract(["publishProjectionFailure", "invalidateOutstanding"])
    }

    func testCancelFencesAttemptAndSuppressesAutomaticRedrive() throws {
        assertDriveContract(["cancellationFence", "cancelOutstanding"])
    }

    func testRetryEmitsAttemptEffectWithoutAdvancingCausalGenerationsOrTicket() throws {
        assertDriveContract(["retry(frozenTicket:", "lastSubmittedTicket"])
    }

    func testRefreshAdvancesManualIntentUsesCacheBypassAndLatchesWhileWaiting() throws {
        var fixture = try makeSubmittedFixture()
        let effects = try fixture.machine.handle(.refresh)
        XCTAssertEqual(effects.first, .invalidateOutstanding)
        guard case let .submit(refreshedTicket, .bypassCacheLookup) = try XCTUnwrap(
            effects.last
        ) else {
            return XCTFail("Expected Refresh to replace the attempt with cache bypass")
        }
        XCTAssertEqual(
            refreshedTicket.manualIntentGeneration,
            fixture.ticket.manualIntentGeneration + 1
        )

        var waitingMachine = NativeDecompilerDriveStateMachine()
        let context = makeContext()
        let owner = NativeDriveImageOwner(imageSlot: .primary, binaryID: UUID())
        let seed = NativeDriveTargetSeed(
            context: context,
            owner: owner,
            selectedAddress: 0x1000
        )
        let target = makeTarget(context: context, owner: owner)
        _ = try waitingMachine.handle(.establish(context))
        _ = try waitingMachine.handle(.bind(.init(rawValue: UUID())))
        _ = try waitingMachine.handle(
            .semanticInputChanged(validSemantic("b"), deferUntilStructuralLanding: false)
        )
        _ = try waitingMachine.handle(
            .installTarget(
                seed: seed,
                resolved: nil,
                waitReason: .selectedOwnerNeedsRehydration
            )
        )
        XCTAssertEqual(try waitingMachine.handle(.refresh), [])
        let landingEffects = try waitingMachine.handle(.selectedOwnerReady(target))
        guard case .submit(_, .bypassCacheLookup) = try XCTUnwrap(landingEffects.first) else {
            return XCTFail("Expected one latched Refresh submission at readiness")
        }
        XCTAssertEqual(landingEffects.count, 1)
    }

    private func assertDriveContract(
        _ tokens: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let source = Self.productionSource("NativeDecompilerDriveStateMachine.swift")
            + Self.modelSource
        for token in tokens {
            XCTAssertTrue(source.contains(token), "missing drive token: \(token)", file: file, line: line)
        }
    }

    private func makeSubmittedFixture(
        machine initialMachine: NativeDecompilerDriveStateMachine = .init()
    ) throws -> (
        machine: NativeDecompilerDriveStateMachine,
        context: NativeDriveContext,
        owner: NativeDriveImageOwner,
        target: NativeDriveResolvedTarget,
        ticket: NativeDriveSubmissionTicket
    ) {
        var machine = initialMachine
        let context = makeContext()
        let owner = NativeDriveImageOwner(imageSlot: .primary, binaryID: UUID())
        let seed = NativeDriveTargetSeed(
            context: context,
            owner: owner,
            selectedAddress: 0x1000
        )
        let target = makeTarget(context: context, owner: owner)
        _ = try machine.handle(.establish(context))
        _ = try machine.handle(.installTarget(seed: seed, resolved: target, waitReason: nil))
        _ = try machine.handle(.bind(NativeDriveHandlerBindingID(rawValue: UUID())))
        let effects = try machine.handle(
            .semanticInputChanged(validSemantic("b"), deferUntilStructuralLanding: false)
        )
        guard case let .submit(ticket, _) = try XCTUnwrap(effects.last) else {
            throw FixtureError.missingSubmission
        }
        return (machine, context, owner, target, ticket)
    }

    private func makeContext() -> NativeDriveContext {
        NativeDriveContext(
            documentID: UUID(),
            workspaceID: UUID(),
            driveGeneration: 1,
            origin: .freshImport
        )
    }

    private func makeTarget(
        context: NativeDriveContext,
        owner: NativeDriveImageOwner
    ) -> NativeDriveResolvedTarget {
        NativeDriveResolvedTarget(
            context: context,
            owner: owner,
            functionID: UUID(),
            functionStart: 0x1000,
            analysisFingerprintSHA256: String(repeating: "a", count: 64)
        )
    }

    private func validSemantic(_ scalar: Character) -> NativeDecompilerSemanticInputState {
        .valid(
            NativeDecompilerAuthoredProjection(
                authoredInputs: .empty,
                canonicalIdentitySHA256: String(repeating: scalar, count: 64),
                canonicalByteCount: 0
            )
        )
    }

    private enum FixtureError: Error {
        case missingSubmission
    }

    private static var modelSource: String {
        let root = sourceRoot
        return (try? String(
            contentsOf: root.appendingPathComponent("Models/NativeDecompilerDriveModels.swift"),
            encoding: .utf8
        )) ?? ""
    }

    private static var sourceRoot: URL {
        TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func productionSource(_ name: String) -> String {
        (try? String(
            contentsOf: sourceRoot.appendingPathComponent("Stores").appendingPathComponent(name),
            encoding: .utf8
        )) ?? ""
    }
}
