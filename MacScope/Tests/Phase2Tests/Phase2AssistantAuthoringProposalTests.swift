import XCTest
@testable import MacScope

@MainActor
final class Phase2AssistantAuthoringProposalTests: XCTestCase {
    func testParserExtractsOnlyTerminalStrictBoundedEnvelope() throws {
        let evidenceID = UUID()
        let text = """
        Grounded explanation.
        <macscope-authoring-proposal-v1>{"operation":"rename","value":"decoded_entry","evidence_id":"\(evidenceID.uuidString)"}</macscope-authoring-proposal-v1>
        """

        let extraction = Phase2AssistantAuthoringProposalDraft.extract(from: text)
        XCTAssertEqual(extraction.answer, "Grounded explanation.")
        XCTAssertEqual(extraction.draft?.operation, .rename)
        XCTAssertEqual(extraction.draft?.value, "decoded_entry")
        XCTAssertEqual(extraction.draft?.evidenceID, evidenceID)

        let unknownKey = text.replacingOccurrences(
            of: "\"evidence_id\"",
            with: "\"unexpected\":true,\"evidence_id\""
        )
        XCTAssertNil(Phase2AssistantAuthoringProposalDraft.extract(from: unknownKey).draft)
        XCTAssertNil(Phase2AssistantAuthoringProposalDraft.extract(from: text + " trailing").draft)
    }

    func testAcceptRenameUsesExistingUndoableStoreMutation() throws {
        let store = makeStore()
        let target = try selectFirstInstruction(in: store)
        store.stagePhase2AssistantAuthoringProposal(
            from: try acceptedResult(store: store, operation: .rename, value: "decoded_entry")
        )

        guard case .staged(let proposal) = store.phase2AssistantAuthoringProposalReview else {
            return XCTFail("Expected a staged proposal")
        }
        XCTAssertEqual(proposal.target, target)
        XCTAssertEqual(proposal.image.binaryID, store.snapshot.binary(in: .primary)?.id)
        XCTAssertFalse(proposal.citations.isEmpty)

        XCTAssertTrue(store.acceptPhase2AssistantAuthoringProposal())
        XCTAssertEqual(store.snapshot.addressOverrides[target]?.customName, "decoded_entry")
        XCTAssertTrue(store.undoManager.canUndo)
        store.undoManager.undo()
        XCTAssertNil(store.snapshot.addressOverrides[target]?.customName)
    }

    func testEvidenceLinksRenderReadableLocationsInsteadOfDebugText() throws {
        let store = makeStore()
        _ = try selectFirstInstruction(in: store)
        store.stagePhase2AssistantAuthoringProposal(
            from: try acceptedResult(store: store, operation: .rename, value: "decoded_entry")
        )
        guard case .staged(let proposal) = store.phase2AssistantAuthoringProposalReview else {
            return XCTFail("Expected a staged proposal")
        }

        let details = proposal.citationDisplays.map(\.detail)
        XCTAssertFalse(details.isEmpty)
        for detail in details {
            XCTAssertFalse(detail.contains("Phase2Read"), detail)
            XCTAssertFalse(detail.contains("("), detail)
        }
        XCTAssertEqual(zip(proposal.citations, details).map { $0.0.target.displayLabel }, details)

        let image = try XCTUnwrap(store.phase2ReadCurrentState(for: .primary).image)
        XCTAssertEqual(
            Phase2ReadCitationTarget.staticLocation(
                .init(image: image, domain: .imageVirtualAddress, address: 0x1_0000_0434)
            ).displayLabel,
            "image 0 · 0x100000434"
        )
        XCTAssertEqual(
            Phase2ReadCitationTarget.functionRange(
                .init(image: image, start: 0x1_0000_0434, endExclusive: 0x1_0000_045c)
            ).displayLabel,
            "image 0 · 0x100000434–0x10000045c"
        )
        XCTAssertEqual(
            Phase2ReadCitationTarget.staticLocation(
                .init(image: image, domain: .fileOffset, address: 0x434)
            ).displayLabel,
            "image 0 · file offset 0x434"
        )
        XCTAssertEqual(
            Phase2ReadFactValue.staticLocation(
                .init(image: image, domain: .imageVirtualAddress, address: 0x1_0000_0448)
            ).displayValue,
            "image 0 · 0x100000448",
            "Evidence summaries and Location rows show the readable location, not ImageSlot debug text"
        )
    }

    func testAnswerWithUnverifiedAddressesStagesNoProposal() throws {
        let store = makeStore()
        _ = try selectFirstInstruction(in: store)
        let result = try acceptedResult(
            store: store,
            operation: .rename,
            value: "decoded_entry",
            unverifiedAddresses: ["0x101012F8"]
        )
        XCTAssertTrue(result.isAcceptedFinalAnswer)
        XCTAssertFalse(result.isFullyGrounded)

        store.stagePhase2AssistantAuthoringProposal(from: result)

        XCTAssertEqual(store.phase2AssistantAuthoringProposalReview, .inactive)
    }

    func testDecodedSchemaProposalStagesExactlyLikeTheTextEnvelope() throws {
        XCTAssertEqual(Phase2GroundedFinalProposal.openingTag, Phase2AssistantAuthoringProposalDraft.openingTag)
        XCTAssertEqual(Phase2GroundedFinalProposal.closingTag, Phase2AssistantAuthoringProposalDraft.closingTag)
        let envelopeStore = makeStore()
        _ = try selectFirstInstruction(in: envelopeStore)
        let envelopeResult = try acceptedResult(store: envelopeStore, operation: .comment, value: "Loads the entry")
        envelopeStore.stagePhase2AssistantAuthoringProposal(from: envelopeResult)
        guard case .staged(let fromEnvelope) = envelopeStore.phase2AssistantAuthoringProposalReview else {
            return XCTFail("Expected the text envelope to stage")
        }

        // The model also wrote a stale envelope into text; the schema proposal replaces it.
        let schemaStore = makeStore()
        _ = try selectFirstInstruction(in: schemaStore)
        let result = try acceptedResult(store: schemaStore, operation: .comment, value: "") { evidenceID in
            try self.decodedText(
                text: "Grounded explanation.\n<macscope-authoring-proposal-v1>{\"operation\":\"comment\",\"value\":\"stale\",\"evidence_id\":\"\(evidenceID.uuidString)\"}</macscope-authoring-proposal-v1>",
                evidenceID: evidenceID,
                proposal: ["operation": "comment", "value": "Loads the entry", "evidence_id": evidenceID.uuidString]
            )
        }
        let text = try XCTUnwrap(result.inferenceOutcome?.finalCandidate?.text)
        XCTAssertEqual(text.components(separatedBy: Phase2GroundedFinalProposal.openingTag).count, 2, text)
        XCTAssertEqual(Phase2AssistantAuthoringProposalDraft.extract(from: text).answer, "Grounded explanation.")
        schemaStore.stagePhase2AssistantAuthoringProposal(from: result)
        guard case .staged(let fromSchema) = schemaStore.phase2AssistantAuthoringProposalReview else {
            return XCTFail("Expected the schema proposal to stage")
        }
        XCTAssertEqual(fromSchema.operation, fromEnvelope.operation)
        XCTAssertEqual(fromSchema.value, fromEnvelope.value)
        // Each fixture store issues its own evidence ID; both proposals cite their own.
        XCTAssertEqual(fromSchema.evidenceID, result.inferenceOutcome?.finalCandidate?.evidenceIDs.first)
        XCTAssertEqual(fromEnvelope.evidenceID, envelopeResult.inferenceOutcome?.finalCandidate?.evidenceIDs.first)
        XCTAssertEqual(fromSchema.target, fromEnvelope.target)
        XCTAssertEqual(fromSchema.instructionEndExclusive, fromEnvelope.instructionEndExclusive)
        // Each preview store also has its own binary ID, so compare the cited locations.
        XCTAssertEqual(fromSchema.citations.map(\.target.displayLabel), fromEnvelope.citations.map(\.target.displayLabel))
        XCTAssertEqual(fromSchema.originalValue, fromEnvelope.originalValue)
        XCTAssertEqual(fromSchema.intent, fromEnvelope.intent)
    }

    func testSchemaProposalStripsEveryTextEnvelopeAndStagesOnlyItself() throws {
        func envelope(_ value: String, _ evidenceID: UUID) -> String {
            #"<macscope-authoring-proposal-v1>{"operation":"comment","value":"\#(value)","evidence_id":"\#(evidenceID.uuidString)"}</macscope-authoring-proposal-v1>"#
        }
        let store = makeStore()
        _ = try selectFirstInstruction(in: store)
        // The 9B repeats the envelope in the prose; here also once mid-text.
        let result = try acceptedResult(store: store, operation: .comment, value: "") { evidenceID in
            try self.decodedText(
                text: "Grounded \(envelope("middle", evidenceID)) explanation.\n\n\(envelope("stale", evidenceID))",
                evidenceID: evidenceID,
                proposal: ["operation": "comment", "value": "Adds 0x11 to the checksum.", "evidence_id": evidenceID.uuidString]
            )
        }
        let text = try XCTUnwrap(result.inferenceOutcome?.finalCandidate?.text)
        XCTAssertEqual(text.components(separatedBy: Phase2GroundedFinalProposal.openingTag).count, 2, text)
        let extracted = Phase2AssistantAuthoringProposalDraft.extract(from: text)
        XCTAssertEqual(extracted.answer, "Grounded  explanation.")
        XCTAssertFalse(extracted.answer.contains(Phase2GroundedFinalProposal.openingTag))
        XCTAssertFalse(extracted.answer.contains(Phase2GroundedFinalProposal.closingTag))
        store.stagePhase2AssistantAuthoringProposal(from: result)
        guard case .staged(let staged) = store.phase2AssistantAuthoringProposalReview else {
            return XCTFail("Expected the schema proposal to stage")
        }
        XCTAssertEqual(staged.operation, .comment)
        XCTAssertEqual(staged.value, "Adds 0x11 to the checksum.")

        // A refused structured proposal still clears the prose envelopes: nothing stages.
        let refusedStore = makeStore()
        _ = try selectFirstInstruction(in: refusedStore)
        let refused = try acceptedResult(store: refusedStore, operation: .comment, value: "") { evidenceID in
            try self.decodedText(
                text: "Grounded explanation.\n\(envelope("stale", evidenceID))",
                evidenceID: evidenceID,
                proposal: ["operation": "rename", "value": "x", "evidence_id": evidenceID.uuidString]
            )
        }
        XCTAssertEqual(refused.inferenceOutcome?.finalCandidate?.text, "Grounded explanation.")
        refusedStore.stagePhase2AssistantAuthoringProposal(from: refused)
        XCTAssertEqual(refusedStore.phase2AssistantAuthoringProposalReview, .inactive)
    }

    func testNullSchemaProposalStagesNothing() throws {
        let store = makeStore()
        _ = try selectFirstInstruction(in: store)
        let result = try acceptedResult(store: store, operation: .comment, value: "") { evidenceID in
            try self.decodedText(text: "Grounded explanation.", evidenceID: evidenceID, proposal: NSNull())
        }
        XCTAssertEqual(result.inferenceOutcome?.finalCandidate?.text, "Grounded explanation.")
        store.stagePhase2AssistantAuthoringProposal(from: result)
        XCTAssertEqual(store.phase2AssistantAuthoringProposalReview, .inactive)
    }

    func testSchemaProposalWithInvalidEvidenceOrOperationIsRefused() throws {
        let invalid: [(UUID) -> [String: Any]] = [
            { _ in ["operation": "comment", "value": "x", "evidence_id": UUID().uuidString] },
            { ["operation": "comment", "value": "x", "evidence_id": $0.uuidString.lowercased()] },
            { ["operation": "rename", "value": "decoded_entry", "evidence_id": $0.uuidString] },
            { ["operation": "byte_edit", "value": "1F2003D5", "evidence_id": $0.uuidString] },
            { ["operation": "comment", "value": "   ", "evidence_id": $0.uuidString] },
            { ["operation": "comment", "value": "x", "evidence_id": $0.uuidString, "extra": true] },
        ]
        for (index, proposal) in invalid.enumerated() {
            let store = makeStore()
            _ = try selectFirstInstruction(in: store)
            let result = try acceptedResult(store: store, operation: .comment, value: "") { evidenceID in
                try self.decodedText(text: "Grounded explanation.", evidenceID: evidenceID, proposal: proposal(evidenceID))
            }
            XCTAssertEqual(result.inferenceOutcome?.finalCandidate?.text, "Grounded explanation.", "\(index)")
            store.stagePhase2AssistantAuthoringProposal(from: result)
            XCTAssertEqual(store.phase2AssistantAuthoringProposalReview, .inactive, "\(index)")
        }

        // A request that offered no proposal keeps the closed four-field schema.
        let evidenceID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": "answer", "text": "x", "evidence_ids": [evidenceID.uuidString], "reason": "",
            "proposal": NSNull(),
        ])
        XCTAssertThrowsError(try Phase2GroundedFinalDecoder().decode(data, allowedEvidenceIDs: [evidenceID])) {
            XCTAssertEqual($0 as? Phase2GroundedFinalDecodingError, .invalidSchema)
        }
    }

    func testRejectLeavesWorkspaceUnchanged() throws {
        let store = makeStore()
        let target = try selectFirstInstruction(in: store)
        store.stagePhase2AssistantAuthoringProposal(
            from: try acceptedResult(store: store, operation: .comment, value: "Review this path")
        )

        store.rejectPhase2AssistantAuthoringProposal()
        XCTAssertNil(store.snapshot.addressOverrides[target]?.customComment)
        XCTAssertFalse(store.undoManager.canUndo)
        guard case .rejected = store.phase2AssistantAuthoringProposalReview else {
            return XCTFail("Expected a rejected proposal")
        }
    }

    func testSelectionAndImageReplacementInvalidateProposal() throws {
        let store = makeStore()
        _ = try selectFirstInstruction(in: store)
        store.stagePhase2AssistantAuthoringProposal(
            from: try acceptedResult(store: store, operation: .comment, value: "Evidence note")
        )
        let second = try XCTUnwrap(store.snapshot.analysis(in: .primary)?.instructions.dropFirst().first)
        XCTAssertTrue(store.selectAddress(.primary(second.address)))
        XCTAssertFalse(store.acceptPhase2AssistantAuthoringProposal())

        _ = try selectFirstInstruction(in: store)
        store.stagePhase2AssistantAuthoringProposal(
            from: try acceptedResult(store: store, operation: .rename, value: "replacement_name")
        )
        var replacement = store.snapshot
        let oldBinary = try XCTUnwrap(replacement.binary(in: .primary))
        replacement.binaries[0] = BinaryImage(
            id: UUID(),
            name: oldBinary.name,
            path: oldBinary.path,
            kind: oldBinary.kind,
            architecture: oldBinary.architecture,
            selectedSliceIndex: oldBinary.selectedSliceIndex,
            slot: .primary
        )
        store.snapshot = replacement
        XCTAssertFalse(store.acceptPhase2AssistantAuthoringProposal())
    }

    func testInvalidOrChangedByteSpanIsRefusedWithoutMutation() throws {
        let store = makeStore()
        let target = try selectFirstInstruction(in: store)
        let originalOverride = store.snapshot.addressOverrides[target]
        store.stagePhase2AssistantAuthoringProposal(
            from: try acceptedResult(store: store, operation: .byteEdit, value: "90")
        )

        guard case .refused = store.phase2AssistantAuthoringProposalReview else {
            return XCTFail("A one-byte replacement must not cover a wider instruction")
        }
        XCTAssertFalse(store.acceptPhase2AssistantAuthoringProposal())
        XCTAssertEqual(store.snapshot.addressOverrides[target], originalOverride)

        let width = Int(try XCTUnwrap(store.snapshot.instruction(at: target)).byteWidth)
        store.stagePhase2AssistantAuthoringProposal(
            from: try acceptedResult(
                store: store,
                operation: .byteEdit,
                value: Array(repeating: "90", count: width).joined(separator: " ")
            )
        )
        var changed = store.snapshot
        var analysis = try XCTUnwrap(changed.analysis(in: target.slot))
        let index = try XCTUnwrap(analysis.instructions.firstIndex { $0.address == target.address })
        analysis.instructions[index].bytes = Array(repeating: "aa", count: width).joined(separator: " ")
        changed.replaceAnalysis(analysis, in: target.slot)
        store.snapshot = changed
        XCTAssertFalse(store.acceptPhase2AssistantAuthoringProposal())
        XCTAssertNil(store.snapshot.addressOverrides[target]?.patch)
    }

    private func acceptedResult(
        store: WorkspaceStore,
        operation: Phase2AssistantAuthoringOperation,
        value: String,
        unverifiedAddresses: [String] = [],
        finalText: ((UUID) throws -> String)? = nil
    ) throws -> Phase2AssistantSessionResult {
        guard case .prepared(let prepared) = store.preparePhase2Read(
            operation: .selectionExplain,
            proposingPrincipal: .model,
            limits: .maximum
        ) else { throw FixtureError.readUnavailable }
        let execution = store.executePhase2Read(prepared)
        let evidence = try XCTUnwrap(execution.acceptedEvidence)
        let context = try store.compilePhase2GroundedContext(
            invocationIDs: [prepared.authorization.request.invocationID]
        )
        let marker = """
        <macscope-authoring-proposal-v1>{"operation":"\(operation.rawValue)","value":"\(value)","evidence_id":"\(evidence.evidenceID.uuidString)"}</macscope-authoring-proposal-v1>
        """
        let candidate = Phase2InferenceFinalCandidate(
            text: try finalText?(evidence.evidenceID) ?? "Grounded explanation.\n\(marker)",
            evidenceIDs: [evidence.evidenceID]
        )
        let outcome = Phase2InferenceOutcome(
            disposition: .completed,
            previewDeltas: [],
            toolProposals: [],
            finalCandidate: candidate,
            providerUsage: nil,
            violation: nil,
            acceptedEventCount: 1,
            cumulativeEventBytes: candidate.text.utf8.count
        )
        return Phase2AssistantSessionResult(
            intent: .explainSelection,
            request: nil,
            groundedContext: context,
            readExecution: execution,
            readExecutions: [execution],
            inferenceOutcome: outcome,
            failure: nil,
            unverifiedAddresses: unverifiedAddresses
        )
    }

    /// Decodes a grounded final object the way the worker does for Explain Selection.
    private func decodedText(text: String, evidenceID: UUID, proposal: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": "answer", "text": text, "evidence_ids": [evidenceID.uuidString], "reason": "",
            "proposal": proposal,
        ])
        let output = try Phase2GroundedFinalDecoder().decode(
            data,
            allowedEvidenceIDs: [evidenceID],
            proposalOperations: ["comment"]
        )
        guard case .answer(let decoded, let evidenceIDs) = output else {
            throw FixtureError.readUnavailable
        }
        XCTAssertEqual(evidenceIDs, [evidenceID])
        return decoded
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore.bootstrapForPreviewFixture()
    }

    private func selectFirstInstruction(in store: WorkspaceStore) throws -> ImageAddress {
        let instruction = try XCTUnwrap(store.snapshot.analysis(in: .primary)?.instructions.first)
        let target = ImageAddress.primary(instruction.address)
        guard store.selectAddress(target) else { throw FixtureError.selectionUnavailable }
        return target
    }

    private enum FixtureError: Error {
        case readUnavailable
        case selectionUnavailable
    }
}
