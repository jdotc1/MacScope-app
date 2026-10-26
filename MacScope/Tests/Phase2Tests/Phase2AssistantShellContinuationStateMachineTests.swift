import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class Phase2AssistantShellContinuationStateMachineTests: XCTestCase {
    func testHappyPathUsesOneLogicalTurnAndOneFreshContinuationRequest() throws {
        let fixture = try Fixture()
        var machine = try fixture.machineThroughReview()

        XCTAssertSuccess(machine.apply(.approveAndReserveExecution(fixture.approval)))
        XCTAssertEqual(machine.state, .executingShell)
        XCTAssertTrue(machine.approvalWasConsumed)
        XCTAssertSuccess(machine.apply(.sealCompletedExecution(fixture.join, fixture.coordinate)))
        XCTAssertEqual(machine.state, .awaitingShellContinuation)
        XCTAssertSuccess(machine.apply(.reserveContinuation(fixture.coordinate)))
        XCTAssertEqual(machine.state, .continuingShell)
        XCTAssertSuccess(machine.apply(.acceptContinuationFinal(fixture.coordinate)))
        XCTAssertEqual(machine.state, .completed)
        XCTAssertEqual(machine.coordinate?.inferenceTurnID, fixture.identity.inferenceTurnID)
        XCTAssertEqual(machine.coordinate?.turnSequence, fixture.identity.turnSequence)
        XCTAssertNotEqual(
            machine.coordinate?.continuationRequestID,
            fixture.identity.originatingFinalizationRequestID
        )
    }

    func testOrdinaryNoShellTurnCompletesWithoutContinuationFacts() throws {
        let fixture = try Fixture()
        var machine = try XCTUnwrap(Phase2AssistantShellContinuationMachine(
            turnIdentity: fixture.identity
        ))
        XCTAssertSuccess(machine.apply(.beginToolSelection(fixture.identity)))
        XCTAssertSuccess(machine.apply(.beginFinalization(fixture.identity)))
        XCTAssertSuccess(machine.apply(.completeWithoutShell(fixture.identity)))
        XCTAssertEqual(machine.state, .completed)
        XCTAssertNil(machine.proposal)
        XCTAssertNil(machine.coordinate)
    }

    func testDuplicateApprovalExecutionAndContinuationAreRejectedWithoutMutation() throws {
        let fixture = try Fixture()
        var machine = try fixture.machineThroughReview()
        XCTAssertSuccess(machine.apply(.approveAndReserveExecution(fixture.approval)))
        XCTAssertEqual(
            machine.apply(.approveAndReserveExecution(fixture.approval)).failure,
            .invalidTransition(from: .executingShell)
        )
        XCTAssertSuccess(machine.apply(.sealCompletedExecution(fixture.join, fixture.coordinate)))
        XCTAssertEqual(
            machine.apply(.sealCompletedExecution(fixture.join, fixture.coordinate)).failure,
            .invalidTransition(from: .awaitingShellContinuation)
        )
        XCTAssertSuccess(machine.apply(.reserveContinuation(fixture.coordinate)))
        XCTAssertEqual(
            machine.apply(.reserveContinuation(fixture.coordinate)).failure,
            .invalidTransition(from: .continuingShell)
        )
    }

    func testApprovalRejectsZeroOrAliasedReservedExecutionIdentity() throws {
        let fixture = try Fixture()
        for executionID in [
            UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            fixture.identity.workspaceID,
            fixture.identity.conversationID,
            fixture.identity.inferenceTurnID,
            fixture.identity.originatingFinalizationRequestID,
            fixture.proposal.proposalID,
        ] {
            var machine = try fixture.machineThroughReview()
            let approval = Phase2AssistantShellApproval(
                turnIdentity: fixture.identity,
                proposalID: fixture.proposal.proposalID,
                proposalDigest: fixture.proposal.proposalDigest,
                reservedExecutionID: executionID
            )
            XCTAssertEqual(
                machine.apply(.approveAndReserveExecution(approval)).failure,
                .approvalMismatch
            )
            XCTAssertEqual(machine.state, .awaitingShellReview)
            XCTAssertFalse(machine.approvalWasConsumed)
        }
    }

    func testForeignTurnAndPTYProposalFailClosedBeforeApproval() throws {
        let fixture = try Fixture()
        var machine = try XCTUnwrap(Phase2AssistantShellContinuationMachine(
            turnIdentity: fixture.identity
        ))
        let foreign = fixture.identity(replacingConversationID: UUID())
        XCTAssertEqual(
            machine.apply(.beginToolSelection(foreign)).failure,
            .staleOrForeignIdentity
        )
        XCTAssertEqual(machine.state, .prepared)

        XCTAssertSuccess(machine.apply(.beginToolSelection(fixture.identity)))
        XCTAssertSuccess(machine.apply(.beginFinalization(fixture.identity)))
        let pty = Phase2AssistantShellProposalProvenance(
            turnIdentity: fixture.identity,
            proposalID: fixture.proposal.proposalID,
            proposalDigest: fixture.proposal.proposalDigest,
            executionSurface: .shellBrokerPTY,
            isLegacy: false
        )
        XCTAssertEqual(machine.apply(.stageProposal(pty)).failure, .invalidProposalProvenance)
        XCTAssertEqual(machine.state, .finalizing)
        XCTAssertNil(machine.proposal)
    }

    func testExecutionJoinRequiresCompletedOneShotMatchingEnabledAuthority() throws {
        let fixture = try Fixture()
        var machine = try fixture.machineThroughExecution()

        XCTAssertEqual(
            machine.apply(.sealCompletedExecution(
                fixture.join(replacingDisposition: .nonZeroExit),
                fixture.coordinate
            )).failure,
            .executionMismatch
        )
        XCTAssertEqual(
            machine.apply(.sealCompletedExecution(
                fixture.join(replacingAuthorityEnabled: false),
                fixture.coordinate
            )).failure,
            .invalidRuntimeAuthority
        )
        XCTAssertEqual(
            machine.apply(.sealCompletedExecution(
                fixture.join(replacingAlreadyConsumed: true),
                fixture.coordinate
            )).failure,
            .executionAlreadyConsumed
        )
        XCTAssertEqual(machine.state, .executingShell)
        XCTAssertNil(machine.coordinate)
    }

    func testEveryCoordinateFieldParticipatesInValidationAndIntegrity() throws {
        let fixture = try Fixture()
        XCTAssertTrue(fixture.coordinate.isIntegrityValid)
        XCTAssertNil(fixture.coordinate(replacingTurnSequence: 0))
        XCTAssertNil(fixture.coordinate(replacingProviderRevision: 0))
        XCTAssertNil(fixture.coordinate(replacingOrdinal: 2))
        XCTAssertNil(fixture.coordinate(replacingProposalDigest: "not-a-digest"))
        XCTAssertNil(fixture.coordinate(replacingManifestIdentity: "phase2-r4"))
        XCTAssertNil(fixture.coordinate(replacingIntegrityDigest: Fixture.digest("tampered")))

        let mutations: [Phase2AssistantShellContinuationCoordinate] = try [
            XCTUnwrap(fixture.coordinate(replacingWorkspaceID: UUID())),
            XCTUnwrap(fixture.coordinate(replacingDocumentDigest: Fixture.digest("other-doc"))),
            XCTUnwrap(fixture.coordinate(replacingConversationID: UUID())),
            XCTUnwrap(fixture.coordinate(replacingInferenceTurnID: UUID())),
            XCTUnwrap(fixture.coordinate(replacingTurnSequence: 5)),
            XCTUnwrap(fixture.coordinate(replacingOriginatingRequestID: UUID())),
            XCTUnwrap(fixture.coordinate(replacingProposalID: UUID())),
            XCTUnwrap(fixture.coordinate(replacingExecutionID: UUID())),
            XCTUnwrap(fixture.coordinate(replacingAuthorityID: UUID())),
            XCTUnwrap(fixture.coordinate(replacingProposalDigest: Fixture.digest("other-proposal"))),
            XCTUnwrap(fixture.coordinate(replacingExecutionDigest: Fixture.digest("other-result"))),
            XCTUnwrap(fixture.coordinate(replacingAuthorityDigest: Fixture.digest("other-authority"))),
            XCTUnwrap(fixture.coordinate(replacingManifestIdentity: "sha256:\(Fixture.digest("other-manifest"))")),
            XCTUnwrap(fixture.coordinate(replacingProviderRevision: 8)),
            XCTUnwrap(fixture.coordinate(replacingContinuationRequestID: UUID())),
        ]
        XCTAssertEqual(Set(mutations.map(\.integrityDigest)).count, mutations.count)
        XCTAssertTrue(mutations.allSatisfy(\.isIntegrityValid))
    }

    func testExecutionResultDigestDistinguishesSubsecondTimestamps() {
        func result(at timestamp: TimeInterval) -> Phase2AIShellOneShotExecutionResult {
            let date = Date(timeIntervalSince1970: timestamp)
            return .init(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                proposalID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                executablePath: "/usr/bin/true",
                arguments: [],
                workingDirectoryPath: nil,
                timeoutMilliseconds: 1_000,
                maximumOutputBytes: 1_024,
                disposition: .completed,
                terminationStatus: 0,
                standardOutput: "ok\n",
                standardError: "",
                outputWasTruncated: false,
                startedAt: date,
                completedAt: date,
                failureMessage: nil
            )
        }

        XCTAssertNotEqual(
            Phase2AssistantShellExecutionResultCanonicalizer.digest(result(at: 1.1)),
            Phase2AssistantShellExecutionResultCanonicalizer.digest(result(at: 1.9))
        )
    }

    func testZeroAndAliasedIdentifiersFailBeforeExecutionReservation() throws {
        let fixture = try Fixture()
        var machine = try XCTUnwrap(
            Phase2AssistantShellContinuationMachine(turnIdentity: fixture.identity)
        )
        XCTAssertSuccess(machine.apply(.beginToolSelection(fixture.identity)))
        XCTAssertSuccess(machine.apply(.beginFinalization(fixture.identity)))
        let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let zero = Phase2AssistantShellProposalProvenance(
            turnIdentity: fixture.identity,
            proposalID: zeroUUID,
            proposalDigest: fixture.proposal.proposalDigest,
            executionSurface: .restrictedOneShotJob,
            isLegacy: false
        )
        XCTAssertEqual(
            machine.apply(.stageProposal(zero)).failure,
            .invalidProposalProvenance
        )

        let aliased = Phase2AssistantShellProposalProvenance(
            turnIdentity: fixture.identity,
            proposalID: fixture.identity.inferenceTurnID,
            proposalDigest: fixture.proposal.proposalDigest,
            executionSurface: .restrictedOneShotJob,
            isLegacy: false
        )
        XCTAssertEqual(
            machine.apply(.stageProposal(aliased)).failure,
            .invalidProposalProvenance
        )

        XCTAssertSuccess(machine.apply(.stageProposal(fixture.proposal)))
        let aliasedApproval = Phase2AssistantShellApproval(
            turnIdentity: fixture.identity,
            proposalID: fixture.proposal.proposalID,
            proposalDigest: fixture.proposal.proposalDigest,
            reservedExecutionID: fixture.identity.originatingFinalizationRequestID
        )
        XCTAssertEqual(
            machine.apply(.approveAndReserveExecution(aliasedApproval)).failure,
            .approvalMismatch
        )
        XCTAssertFalse(machine.approvalWasConsumed)
        XCTAssertEqual(machine.state, .awaitingShellReview)
    }

    func testCoordinateMismatchCannotSealOrCompleteTurn() throws {
        let fixture = try Fixture()
        var machine = try fixture.machineThroughExecution()
        let foreignCoordinate = try XCTUnwrap(fixture.coordinate(replacingExecutionID: UUID()))
        XCTAssertEqual(
            machine.apply(.sealCompletedExecution(fixture.join, foreignCoordinate)).failure,
            .invalidCoordinate
        )
        XCTAssertEqual(machine.state, .executingShell)

        XCTAssertSuccess(machine.apply(.sealCompletedExecution(fixture.join, fixture.coordinate)))
        XCTAssertSuccess(machine.apply(.reserveContinuation(fixture.coordinate)))
        let foreignRequest = try XCTUnwrap(fixture.coordinate(replacingContinuationRequestID: UUID()))
        XCTAssertEqual(
            machine.apply(.acceptContinuationFinal(foreignRequest)).failure,
            .continuationMismatch
        )
        XCTAssertEqual(machine.state, .continuingShell)
    }

    func testRestoreNeverRepeatsAmbiguousExecutionOrProviderDispatch() throws {
        let fixture = try Fixture()
        var executing = try fixture.machineThroughExecution()
        XCTAssertEqual(
            executing.applyRestorePolicy(hasDurablyCorrelatedContinuationTerminal: false),
            .failedClosed(.ambiguousRestoredExecution)
        )
        XCTAssertEqual(executing.state, .failed)

        var awaiting = try fixture.machineThroughAwaitingContinuation()
        XCTAssertEqual(
            awaiting.applyRestorePolicy(hasDurablyCorrelatedContinuationTerminal: false),
            .reserveUndispatchedContinuation
        )
        XCTAssertEqual(awaiting.state, .awaitingShellContinuation)

        var continuing = awaiting
        XCTAssertSuccess(continuing.apply(.reserveContinuation(fixture.coordinate)))
        XCTAssertEqual(
            continuing.applyRestorePolicy(hasDurablyCorrelatedContinuationTerminal: false),
            .failedClosed(.ambiguousRestoredContinuation)
        )
        XCTAssertEqual(continuing.state, .failed)

        var terminalAvailable = awaiting
        XCTAssertSuccess(terminalAvailable.apply(.reserveContinuation(fixture.coordinate)))
        XCTAssertEqual(
            terminalAvailable.applyRestorePolicy(hasDurablyCorrelatedContinuationTerminal: true),
            .reduceDurablyCorrelatedTerminalOnly
        )
        XCTAssertEqual(terminalAvailable.state, .continuingShell)
    }

    func testCancellationIsOnceOnlyAndNeverRevivesApproval() throws {
        let fixture = try Fixture()
        var machine = try fixture.machineThroughReview()
        XCTAssertSuccess(machine.apply(.cancel(fixture.identity)))
        XCTAssertEqual(machine.state, .cancelled)
        XCTAssertEqual(
            machine.apply(.approveAndReserveExecution(fixture.approval)).failure,
            .invalidTransition(from: .cancelled)
        )
        XCTAssertEqual(
            machine.apply(.cancel(fixture.identity)).failure,
            .invalidTransition(from: .cancelled)
        )
        XCTAssertFalse(machine.approvalWasConsumed)
    }

    func testZeroAndAliasedAuthorityIdentifiersAreRejected() throws {
        let fixture = try Fixture()
        XCTAssertNil(Phase2AssistantShellContinuationMachine(turnIdentity: .init(
            workspaceID: Fixture.zero,
            workspaceDocumentIdentityDigest: fixture.identity.workspaceDocumentIdentityDigest,
            conversationID: fixture.identity.conversationID,
            inferenceTurnID: fixture.identity.inferenceTurnID,
            turnSequence: 1,
            originatingFinalizationRequestID: fixture.identity.originatingFinalizationRequestID
        )))
        XCTAssertNil(fixture.coordinate(replacingExecutionID: Fixture.zero))
        XCTAssertNil(fixture.coordinate(
            replacingContinuationRequestID: fixture.coordinate.shellExecutionID
        ))
        XCTAssertNil(fixture.coordinate(
            replacingAuthorityID: fixture.coordinate.shellProposalID
        ))
    }
}

private extension Result where Success == Void, Failure == Phase2AssistantShellContinuationRejection {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private func XCTAssertSuccess(
    _ result: Result<Void, Phase2AssistantShellContinuationRejection>,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if case .failure(let error) = result {
        XCTFail("Expected success, got \(error)", file: file, line: line)
    }
}

private struct Fixture {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    let identity: Phase2AssistantShellTurnIdentity
    let proposal: Phase2AssistantShellProposalProvenance
    let approval: Phase2AssistantShellApproval
    let join: Phase2AssistantShellExecutionAuthorityJoin
    let coordinate: Phase2AssistantShellContinuationCoordinate

    init() throws {
        identity = .init(
            workspaceID: Self.id(1),
            workspaceDocumentIdentityDigest: Self.digest("document"),
            conversationID: Self.id(2),
            inferenceTurnID: Self.id(3),
            turnSequence: 4,
            originatingFinalizationRequestID: Self.id(5)
        )
        proposal = .init(
            turnIdentity: identity,
            proposalID: Self.id(6),
            proposalDigest: Self.digest("proposal"),
            executionSurface: .restrictedOneShotJob,
            isLegacy: false
        )
        approval = .init(
            turnIdentity: identity,
            proposalID: proposal.proposalID,
            proposalDigest: proposal.proposalDigest,
            reservedExecutionID: Self.id(7)
        )
        join = .init(
            turnIdentity: identity,
            proposalID: proposal.proposalID,
            proposalDigest: proposal.proposalDigest,
            executionID: approval.reservedExecutionID,
            executionProposalID: proposal.proposalID,
            executionResultDigest: Self.digest("result"),
            executionDisposition: .completed,
            runtimeAuthorityRecordID: Self.id(8),
            runtimeAuthoritySessionID: approval.reservedExecutionID,
            runtimeAuthorityRecordDigest: Self.digest("authority"),
            runtimeAuthoritySurfaces: [.providerVisibleShellExecution],
            providerVisibleShellExecutionEnabled: true,
            productionManifestIdentity: "sha256:\(Self.digest("manifest"))",
            providerRevision: 7,
            wasAlreadyConsumed: false,
            continuationRequestID: Self.id(9)
        )
        coordinate = try XCTUnwrap(Self.makeCoordinate(identity: identity, proposal: proposal, join: join))
    }

    func machineThroughReview() throws -> Phase2AssistantShellContinuationMachine {
        var machine = try XCTUnwrap(Phase2AssistantShellContinuationMachine(turnIdentity: identity))
        XCTAssertSuccess(machine.apply(.beginToolSelection(identity)))
        XCTAssertSuccess(machine.apply(.beginFinalization(identity)))
        XCTAssertSuccess(machine.apply(.stageProposal(proposal)))
        return machine
    }

    func machineThroughExecution() throws -> Phase2AssistantShellContinuationMachine {
        var machine = try machineThroughReview()
        XCTAssertSuccess(machine.apply(.approveAndReserveExecution(approval)))
        return machine
    }

    func machineThroughAwaitingContinuation() throws -> Phase2AssistantShellContinuationMachine {
        var machine = try machineThroughExecution()
        XCTAssertSuccess(machine.apply(.sealCompletedExecution(join, coordinate)))
        return machine
    }

    func identity(replacingConversationID conversationID: UUID) -> Phase2AssistantShellTurnIdentity {
        .init(
            workspaceID: identity.workspaceID,
            workspaceDocumentIdentityDigest: identity.workspaceDocumentIdentityDigest,
            conversationID: conversationID,
            inferenceTurnID: identity.inferenceTurnID,
            turnSequence: identity.turnSequence,
            originatingFinalizationRequestID: identity.originatingFinalizationRequestID
        )
    }

    func join(
        replacingDisposition disposition: Phase2AIShellOneShotExecutionDisposition = .completed,
        replacingAuthorityEnabled enabled: Bool = true,
        replacingAlreadyConsumed consumed: Bool = false
    ) -> Phase2AssistantShellExecutionAuthorityJoin {
        .init(
            turnIdentity: join.turnIdentity,
            proposalID: join.proposalID,
            proposalDigest: join.proposalDigest,
            executionID: join.executionID,
            executionProposalID: join.executionProposalID,
            executionResultDigest: join.executionResultDigest,
            executionDisposition: disposition,
            runtimeAuthorityRecordID: join.runtimeAuthorityRecordID,
            runtimeAuthoritySessionID: join.runtimeAuthoritySessionID,
            runtimeAuthorityRecordDigest: join.runtimeAuthorityRecordDigest,
            runtimeAuthoritySurfaces: join.runtimeAuthoritySurfaces,
            providerVisibleShellExecutionEnabled: enabled,
            productionManifestIdentity: join.productionManifestIdentity,
            providerRevision: join.providerRevision,
            wasAlreadyConsumed: consumed,
            continuationRequestID: join.continuationRequestID
        )
    }

    func coordinate(
        replacingWorkspaceID workspaceID: UUID? = nil,
        replacingDocumentDigest documentDigest: String? = nil,
        replacingConversationID conversationID: UUID? = nil,
        replacingInferenceTurnID inferenceTurnID: UUID? = nil,
        replacingTurnSequence turnSequence: UInt64? = nil,
        replacingOriginatingRequestID originatingRequestID: UUID? = nil,
        replacingProposalID proposalID: UUID? = nil,
        replacingExecutionID executionID: UUID? = nil,
        replacingAuthorityID authorityID: UUID? = nil,
        replacingProposalDigest proposalDigest: String? = nil,
        replacingExecutionDigest executionDigest: String? = nil,
        replacingAuthorityDigest authorityDigest: String? = nil,
        replacingManifestIdentity manifestIdentity: String? = nil,
        replacingProviderRevision providerRevision: UInt64? = nil,
        replacingOrdinal ordinal: UInt64? = nil,
        replacingContinuationRequestID continuationRequestID: UUID? = nil,
        replacingIntegrityDigest integrityDigest: String? = nil
    ) -> Phase2AssistantShellContinuationCoordinate? {
        Phase2AssistantShellContinuationCoordinate(
            workspaceID: workspaceID ?? coordinate.workspaceID,
            workspaceDocumentIdentityDigest: documentDigest ?? coordinate.workspaceDocumentIdentityDigest,
            conversationID: conversationID ?? coordinate.conversationID,
            inferenceTurnID: inferenceTurnID ?? coordinate.inferenceTurnID,
            turnSequence: turnSequence ?? coordinate.turnSequence,
            originatingFinalizationRequestID: originatingRequestID ?? coordinate.originatingFinalizationRequestID,
            shellProposalID: proposalID ?? coordinate.shellProposalID,
            shellExecutionID: executionID ?? coordinate.shellExecutionID,
            runtimeAuthorityRecordID: authorityID ?? coordinate.runtimeAuthorityRecordID,
            shellProposalDigest: proposalDigest ?? coordinate.shellProposalDigest,
            shellExecutionResultDigest: executionDigest ?? coordinate.shellExecutionResultDigest,
            runtimeAuthorityRecordDigest: authorityDigest ?? coordinate.runtimeAuthorityRecordDigest,
            productionManifestIdentity: manifestIdentity ?? coordinate.productionManifestIdentity,
            providerRevision: providerRevision ?? coordinate.providerRevision,
            continuationOrdinal: ordinal ?? coordinate.continuationOrdinal,
            continuationRequestID: continuationRequestID ?? coordinate.continuationRequestID,
            integrityDigest: integrityDigest
        )
    }

    private static func makeCoordinate(
        identity: Phase2AssistantShellTurnIdentity,
        proposal: Phase2AssistantShellProposalProvenance,
        join: Phase2AssistantShellExecutionAuthorityJoin
    ) -> Phase2AssistantShellContinuationCoordinate? {
        .init(
            workspaceID: identity.workspaceID,
            workspaceDocumentIdentityDigest: identity.workspaceDocumentIdentityDigest,
            conversationID: identity.conversationID,
            inferenceTurnID: identity.inferenceTurnID,
            turnSequence: identity.turnSequence,
            originatingFinalizationRequestID: identity.originatingFinalizationRequestID,
            shellProposalID: proposal.proposalID,
            shellExecutionID: join.executionID,
            runtimeAuthorityRecordID: join.runtimeAuthorityRecordID,
            shellProposalDigest: proposal.proposalDigest,
            shellExecutionResultDigest: join.executionResultDigest,
            runtimeAuthorityRecordDigest: join.runtimeAuthorityRecordDigest,
            productionManifestIdentity: join.productionManifestIdentity,
            providerRevision: join.providerRevision,
            continuationRequestID: join.continuationRequestID
        )
    }

    static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    static func digest(_ seed: String) -> String {
        SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
