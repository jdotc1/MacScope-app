import Foundation

@MainActor
extension WorkspaceStore {
    func stagePhase2AssistantAuthoringProposal(from result: Phase2AssistantSessionResult) {
        publishPhase2AssistantAuthoringProposalReview(.inactive)
        guard result.isFullyGrounded,
              result.intent == .explainSelection || result.intent == .reviewFunction,
              let candidate = result.inferenceOutcome?.finalCandidate,
              candidate.kind == .answer,
              let context = result.groundedContext
        else { return }

        let extraction = Phase2AssistantAuthoringProposalDraft.extract(from: candidate.text)
        guard let draft = extraction.draft,
              candidate.evidenceIDs.contains(draft.evidenceID),
              let record = context.records.first(where: { $0.evidenceID == draft.evidenceID }),
              let image = record.precondition.image,
              let selection = selectedImageAddress,
              selection.slot == image.slot,
              focusedImageSlot == image.slot,
              let target = proposalTarget(
                operation: draft.operation,
                selection: selection,
                citations: record.citations.map(\.target)
              ),
              let instruction = snapshot.instruction(at: target)
        else { return }

        let end = target.address.addingReportingOverflow(instruction.byteWidth)
        guard !end.overflow else { return }
        let originalValue = proposalOriginalValue(
            operation: draft.operation,
            target: target,
            instruction: instruction
        )
        let proposal = Phase2AssistantAuthoringProposal(
            id: UUID(),
            intent: result.intent,
            operation: draft.operation,
            value: draft.value,
            evidenceID: draft.evidenceID,
            citations: record.citations,
            precondition: record.precondition,
            image: image,
            openingSelection: selection,
            target: target,
            instructionEndExclusive: end.partialValue,
            originalValue: originalValue
        )

        guard proposalPayloadIsValid(proposal, instruction: instruction) else {
            publishPhase2AssistantAuthoringProposalReview(.refused(
                proposal,
                reason: "The proposed value is not valid for the cited instruction span."
            ))
            return
        }
        publishPhase2AssistantAuthoringProposalReview(.staged(proposal))
    }

    @discardableResult
    func acceptPhase2AssistantAuthoringProposal() -> Bool {
        guard case .staged(let proposal) = phase2AssistantAuthoringProposalReview else {
            return false
        }
        guard proposalIsCurrent(proposal) else {
            publishPhase2AssistantAuthoringProposalReview(.refused(
                proposal,
                reason: "The workspace, selected image, selection, evidence, or target bytes changed."
            ))
            return false
        }
        guard let instruction = snapshot.instruction(at: proposal.target),
              proposalPayloadIsValid(proposal, instruction: instruction)
        else {
            publishPhase2AssistantAuthoringProposalReview(.refused(
                proposal,
                reason: "The proposed value is not valid for the current instruction span."
            ))
            return false
        }

        switch proposal.operation {
        case .rename:
            setCustomName(proposal.target.address, in: proposal.target.slot, name: proposal.value)
        case .comment:
            setCustomComment(proposal.target.address, in: proposal.target.slot, comment: proposal.value)
        case .type:
            setAppliedType(proposal.target.address, in: proposal.target.slot, name: proposal.value)
        case .byteEdit:
            guard let patch = BytePatch.parse(hex: proposal.value),
                  setPatch(proposal.target.address, in: proposal.target.slot, patch)
            else {
                publishPhase2AssistantAuthoringProposalReview(.refused(
                    proposal,
                    reason: "MacScope refused the bounded byte edit without changing the workspace."
                ))
                return false
            }
        }
        publishPhase2AssistantAuthoringProposalReview(.applied(proposal))
        return true
    }

    func rejectPhase2AssistantAuthoringProposal() {
        guard case .staged(let proposal) = phase2AssistantAuthoringProposalReview else { return }
        publishPhase2AssistantAuthoringProposalReview(.rejected(proposal))
    }

    func dismissPhase2AssistantAuthoringProposalReview() {
        publishPhase2AssistantAuthoringProposalReview(.inactive)
    }

    /// The cited evidence and selected instruction that a default comment
    /// proposal from this context would stage against, if any.
    func phase2AssistantAuthoringProposalAnchor(
        in context: Phase2GroundedContext
    ) -> (evidenceID: UUID, target: ImageAddress)? {
        guard let selection = selectedImageAddress, focusedImageSlot == selection.slot else { return nil }
        for record in context.records {
            guard let image = record.precondition.image,
                  image.slot == selection.slot,
                  let target = proposalTarget(
                    operation: .comment,
                    selection: selection,
                    citations: record.citations.map(\.target)
                  ),
                  snapshot.instruction(at: target) != nil
            else { continue }
            return (record.evidenceID, target)
        }
        return nil
    }

    private func proposalTarget(
        operation: Phase2AssistantAuthoringOperation,
        selection: ImageAddress,
        citations: [Phase2ReadCitationTarget]
    ) -> ImageAddress? {
        for citation in citations {
            switch citation {
            case .staticLocation(let location)
                where location.domain == .imageVirtualAddress
                    && location.image.slot == selection.slot
                    && location.address == selection.address:
                return selection
            case .functionRange(let range)
                where range.image.slot == selection.slot
                    && selection.address >= range.start
                    && selection.address < range.endExclusive:
                let address = operation == .rename || operation == .type
                    ? range.start
                    : selection.address
                return ImageAddress(slot: range.image.slot, address: address)
            default:
                continue
            }
        }
        return nil
    }

    private func proposalOriginalValue(
        operation: Phase2AssistantAuthoringOperation,
        target: ImageAddress,
        instruction: InstructionRow
    ) -> String? {
        let override = snapshot.addressOverrides[target]
        switch operation {
        case .rename: return override?.customName
        case .comment: return override?.customComment
        case .type: return override?.appliedTypeName
        case .byteEdit: return instruction.bytes
        }
    }

    private func proposalPayloadIsValid(
        _ proposal: Phase2AssistantAuthoringProposal,
        instruction: InstructionRow
    ) -> Bool {
        let end = proposal.target.address.addingReportingOverflow(instruction.byteWidth)
        guard instruction.address == proposal.target.address,
              !end.overflow,
              proposal.instructionEndExclusive == end.partialValue
        else { return false }
        switch proposal.operation {
        case .rename, .type:
            return !proposal.value.isEmpty
                && proposal.value.utf8.count <= 256
                && !proposal.value.contains(where: \.isNewline)
        case .comment:
            return !proposal.value.isEmpty && proposal.value.utf8.count <= 2_048
        case .byteEdit:
            guard let patch = BytePatch.parse(hex: proposal.value),
                  patch.bytes.count == Int(instruction.byteWidth),
                  (try? BytePatchOverlay(patches: [proposal.target.address: patch])) != nil
            else { return false }
            return true
        }
    }

    private func proposalIsCurrent(_ proposal: Phase2AssistantAuthoringProposal) -> Bool {
        guard focusedImageSlot == proposal.image.slot,
              selectedImageAddress == proposal.openingSelection,
              snapshot.binary(in: proposal.image.slot)?.id == proposal.image.binaryID,
              let instruction = snapshot.instruction(at: proposal.target),
              proposalOriginalValue(
                operation: proposal.operation,
                target: proposal.target,
                instruction: instruction
              ) == proposal.originalValue
        else { return false }

        let current = phase2ReadLedger.currentState(
            for: proposal.image.slot,
            snapshot: snapshot
        )
        return current.workspace == proposal.precondition.workspace
            && current.workspaceRevision == proposal.precondition.workspaceRevision
            && current.image == proposal.image
            && proposal.precondition.compared(to: current).isCurrent
    }
}
