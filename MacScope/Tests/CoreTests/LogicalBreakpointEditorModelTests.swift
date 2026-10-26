import Foundation
import XCTest
@testable import MacScope

final class LogicalBreakpointEditorModelTests: XCTestCase {
    func testEveryFrozenLocatorBuildsExactDurableSubmission() throws {
        let owner = try owner()

        var address = LogicalBreakpointEditorDraft(owner: owner)
        address.preferredAddressText = "0x1_0000_1000"
        guard case .preferredAddress(let addressOwner, let preferredVA) = try address.validatedSubmission().target else {
            return XCTFail("Expected preferred-address target.")
        }
        XCTAssertEqual(addressOwner, owner)
        XCTAssertEqual(preferredVA, 0x1_0000_1000)

        var offset = LogicalBreakpointEditorDraft(owner: owner)
        offset.locatorKind = .imageOffset
        offset.segmentName = "__TEXT"
        offset.segmentPreferredStartText = "0x100000000"
        offset.imageOffsetText = "4096"
        guard case .imageOffset(let offsetOwner, let segment, let start, let displacement)
            = try offset.validatedSubmission().target else {
            return XCTFail("Expected image-offset target.")
        }
        XCTAssertEqual(offsetOwner, owner)
        XCTAssertEqual(segment, "__TEXT")
        XCTAssertEqual(start, 0x1_0000_0000)
        XCTAssertEqual(displacement, 4_096)

        var function = LogicalBreakpointEditorDraft(owner: owner)
        function.locatorKind = .function
        function.functionEntryText = "0x100002000"
        function.functionRawLinkageNameHint = "_$s4Demo4mainyyF"
        guard case .function(let functionOwner, let entry, let hint)
            = try function.validatedSubmission().target else {
            return XCTFail("Expected function target.")
        }
        XCTAssertEqual(functionOwner, owner)
        XCTAssertEqual(entry, 0x1_0000_2000)
        XCTAssertEqual(hint, "_$s4Demo4mainyyF")

        var symbol = LogicalBreakpointEditorDraft(owner: owner)
        symbol.locatorKind = .symbol
        symbol.symbolRawLinkageName = "_$s4Demo6workeryyF"
        symbol.symbolKind = "T"
        symbol.symbolLibraryName = "DemoCore"
        symbol.cardinality = .allExactMatches
        guard case .symbol(let symbolOwner, let name, let kind, let library, let cardinality)
            = try symbol.validatedSubmission().target else {
            return XCTFail("Expected symbol target.")
        }
        XCTAssertEqual(symbolOwner, owner)
        XCTAssertEqual(name, "_$s4Demo6workeryyF")
        XCTAssertEqual(kind, "T")
        XCTAssertEqual(library, "DemoCore")
        XCTAssertEqual(cardinality, .allExactMatches)

        var source = LogicalBreakpointEditorDraft(owner: owner)
        source.locatorKind = .source
        source.selectSourceChoice(try sourceChoice(for: owner))
        source.sourceLineText = "27"
        source.usesExactSourceColumn = true
        source.sourceColumnText = "9"
        source.cardinality = .exactlyOne
        guard case .source(let sourceOwner, let file, let line, let column, let sourceCardinality)
            = try source.validatedSubmission().target else {
            return XCTFail("Expected source target.")
        }
        XCTAssertEqual(sourceOwner, owner)
        XCTAssertEqual(file, try sourceIdentity())
        XCTAssertEqual(line, 27)
        XCTAssertEqual(column, .exact(9))
        XCTAssertEqual(sourceCardinality, .exactlyOne)
    }

    func testBehaviorAndTypedActionsPreserveAuthoredOrder() throws {
        var draft = LogicalBreakpointEditorDraft(owner: try owner(), preferredAddress: 0x1_0000_1000)
        draft.condition = "counter > 4"
        draft.hitBehavior = .skipFirst
        draft.skipFirstCountText = String(UInt32.max)
        draft.actions = [
            LogicalBreakpointEditorActionDraft(
                kind: .log,
                logFragments: [
                    .init(kind: .literal, value: "counter="),
                    .init(kind: .targetExpression, value: "counter"),
                ]
            ),
            LogicalBreakpointEditorActionDraft(
                kind: .evaluateExpression,
                logFragments: [],
                expressionLabel: "object",
                expression: "object.description"
            ),
        ]
        draft.disposition = .continueAfterSuccessfulActions

        let submission = try draft.validatedSubmission()
        XCTAssertEqual(submission.condition, "counter > 4")
        XCTAssertEqual(submission.hitPolicy, .ignoreFirst(.max))
        XCTAssertEqual(submission.disposition, .continueAfterSuccessfulActions)
        XCTAssertEqual(submission.actions.count, 2)

        guard case .log(let template) = submission.actions[0] else {
            return XCTFail("Expected the first authored action to remain a log action.")
        }
        XCTAssertEqual(template.fragments, [
            .literal("counter="),
            .targetExpression("counter"),
        ])

        guard case .evaluateTargetExpression(let capture) = submission.actions[1] else {
            return XCTFail("Expected the second authored action to remain an expression action.")
        }
        XCTAssertEqual(capture.label, "object")
        XCTAssertEqual(capture.expression, "object.description")
    }

    func testInvalidFieldsFailBeforeSubmissionWithoutWeakFallback() throws {
        var missingOwner = LogicalBreakpointEditorDraft()
        missingOwner.preferredAddressText = "0x1000"
        XCTAssertThrowsError(try missingOwner.validatedSubmission()) { error in
            XCTAssertEqual(error as? LogicalBreakpointEditorValidationError, .missingOwner)
        }

        var invalidAddress = LogicalBreakpointEditorDraft(owner: try owner())
        invalidAddress.preferredAddressText = "not-an-address"
        XCTAssertThrowsError(try invalidAddress.validatedSubmission()) { error in
            XCTAssertEqual(
                error as? LogicalBreakpointEditorValidationError,
                .invalidAddress(field: "preferred address")
            )
        }

        var invalidSkip = LogicalBreakpointEditorDraft(owner: try owner(), preferredAddress: 0x1000)
        invalidSkip.hitBehavior = .skipFirst
        invalidSkip.skipFirstCountText = "0"
        XCTAssertThrowsError(try invalidSkip.validatedSubmission()) { error in
            XCTAssertEqual(
                error as? LogicalBreakpointEditorValidationError,
                .invalidUnsignedInteger(field: "skip-first count")
            )
        }

        var missingSource = LogicalBreakpointEditorDraft(owner: try owner())
        missingSource.locatorKind = .source
        missingSource.sourceLineText = "1"
        XCTAssertThrowsError(try missingSource.validatedSubmission()) { error in
            XCTAssertEqual(error as? LogicalBreakpointEditorValidationError, .missingSourceIdentity)
        }

        var controlBearingAction = LogicalBreakpointEditorDraft(owner: try owner(), preferredAddress: 0x1000)
        controlBearingAction.actions = [
            LogicalBreakpointEditorActionDraft(
                kind: .log,
                logFragments: [.init(kind: .literal, value: "before\nafter")]
            ),
        ]
        XCTAssertThrowsError(try controlBearingAction.validatedSubmission()) { error in
            guard let validationError = error as? LogicalBreakpointEditorValidationError,
                  case .invalidAction(index: 0, _) = validationError else {
                return XCTFail("Expected typed action validation, got \(error).")
            }
        }
    }

    func testEditingExistingSpecificationPreservesDurableFacts() throws {
        let log = try DebuggerBreakpointLogTemplate(fragments: [
            .literal("value="),
            .targetExpression("value"),
        ])
        let specification = try DebuggerLogicalBreakpointSpecification(
            id: DebuggerLogicalBreakpointID(rawValue: UUID()),
            revision: DebuggerLogicalBreakpointRevision(validating: 8),
            enabled: false,
            target: .source(
                owner: try owner(),
                file: try sourceIdentity(),
                line: 42,
                columnPolicy: .any,
                cardinality: .allExactMatches
            ),
            condition: "ready == 1",
            hitPolicy: .ignoreFirst(3),
            actions: [.log(log)],
            disposition: .continueAfterSuccessfulActions
        )

        let submission = try LogicalBreakpointEditorDraft(specification: specification)
            .validatedSubmission()
        XCTAssertEqual(submission.enabled, specification.enabled)
        XCTAssertEqual(submission.target, specification.target)
        XCTAssertEqual(submission.condition, specification.condition)
        XCTAssertEqual(submission.hitPolicy, specification.hitPolicy)
        XCTAssertEqual(submission.actions, specification.actions)
        XCTAssertEqual(submission.disposition, specification.disposition)
    }

    func testSourceChoiceRemainsQualifiedByItsImageAcrossOwnerChanges() throws {
        let ownerA = try owner(
            slot: .primary,
            binaryID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            artifactUUID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            artifactByte: "a"
        )
        let ownerB = try owner(
            slot: ImageSlot(rawValue: 1),
            binaryID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            artifactUUID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            artifactByte: "e"
        )
        let identityA = try sourceIdentity()
        let choiceA = try sourceChoice(for: ownerA, identity: identityA)
        XCTAssertEqual(choiceA.ownerCoordinate, try ownerCoordinate(for: ownerA, revision: 3))

        var draft = LogicalBreakpointEditorDraft(owner: ownerA)
        draft.locatorKind = .source
        draft.sourceLineText = "27"
        draft.selectSourceChoice(choiceA)
        XCTAssertEqual(draft.sourceIdentity, identityA)
        XCTAssertEqual(draft.sourceIdentityOwner, ownerA)

        draft.selectOwner(ownerB)
        XCTAssertEqual(draft.owner, ownerB)
        XCTAssertNil(draft.sourceIdentity)
        XCTAssertNil(draft.sourceIdentityOwner)
    }

    func testSourceSubmissionRejectsIdentityOwnedByAnotherImage() throws {
        let ownerA = try owner(
            slot: .primary,
            binaryID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            artifactUUID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            artifactByte: "a"
        )
        let ownerB = try owner(
            slot: ImageSlot(rawValue: 1),
            binaryID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            artifactUUID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            artifactByte: "e"
        )
        let choiceA = try sourceChoice(for: ownerA)

        var draft = LogicalBreakpointEditorDraft(owner: ownerB)
        draft.locatorKind = .source
        draft.sourceLineText = "27"
        draft.selectSourceChoice(choiceA)

        XCTAssertThrowsError(try draft.validatedSubmission()) { error in
            XCTAssertEqual(
                error as? LogicalBreakpointEditorValidationError,
                .sourceIdentityOwnerMismatch
            )
        }
    }

    private func owner() throws -> DebuggerWorkspaceImageOwnerSeal {
        try owner(
            slot: .primary,
            binaryID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            artifactUUID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            artifactByte: "a"
        )
    }

    private func owner(
        slot: ImageSlot,
        binaryID: UUID,
        artifactUUID: UUID,
        artifactByte: Character
    ) throws -> DebuggerWorkspaceImageOwnerSeal {
        DebuggerWorkspaceImageOwnerSeal(
            slot: slot,
            binaryID: binaryID,
            artifactIdentity: try MachOSliceArtifactIdentity(
                uuid: artifactUUID,
                rawCPUType: MachOConstants.cpuTypeARM64,
                rawCPUSubtype: 0,
                selectedSliceSHA256: String(repeating: artifactByte, count: 64),
                selectedSliceByteCount: 0x4000
            )
        )
    }

    private func ownerCoordinate(
        for owner: DebuggerWorkspaceImageOwnerSeal,
        revision: UInt64
    ) throws -> DebuggerWorkspaceArtifactCoordinate {
        DebuggerWorkspaceArtifactCoordinate(
            binaryID: owner.binaryID,
            slot: owner.slot,
            artifactIdentity: try XCTUnwrap(owner.artifactIdentity),
            ownerRevision: DebuggerWorkspaceArtifactOwnerRevision(rawValue: revision)
        )
    }

    private func sourceChoice(
        for owner: DebuggerWorkspaceImageOwnerSeal,
        identity: DebuggerCanonicalSourceFileIdentity? = nil
    ) throws -> LogicalBreakpointSourceChoice {
        LogicalBreakpointSourceChoice(
            owner: owner,
            ownerCoordinate: try ownerCoordinate(for: owner, revision: 3),
            identity: try identity ?? sourceIdentity(),
            title: "main.c",
            detail: "Exact debug source"
        )
    }

    private func sourceIdentity() throws -> DebuggerCanonicalSourceFileIdentity {
        try DebuggerCanonicalSourceFileIdentity(
            debugArtifactUUID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            debugArtifactMachOSHA256: String(repeating: "d", count: 64),
            debugArtifactMachOByteCount: 0x8000,
            lineProgramUnitOffset: 0x1234,
            fileTableIndex: 7,
            tablePath: .absoluteUTF8("/Sources/main.c")
        )
    }
}
