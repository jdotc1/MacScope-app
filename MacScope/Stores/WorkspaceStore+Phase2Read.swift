import Foundation

/// One exact authorization paired with the immutable native cut it authorized.
struct Phase2PreparedRead: Sendable {
    let authorization: Phase2ReadAuthorization
    let input: Phase2ReadProjectionInput

    /// Only this app-owned coordinator file may mint an executable prepared read. Other app code
    /// can inspect the inert value it receives, but cannot wrap a forged authorization in it.
    fileprivate init(
        authorization: Phase2ReadAuthorization,
        input: Phase2ReadProjectionInput
    ) {
        self.authorization = authorization
        self.input = input
    }
}

enum Phase2ReadPreparationDecision: Sendable {
    case prepared(Phase2PreparedRead)
    case unavailable(Phase2ReadUnavailableReason)
    case rejected(Phase2ReadDisposition)
}

/// The projected facts and their app-owned terminal acceptance record.
struct Phase2ReadExecution: Sendable {
    let candidate: Phase2ReadEvidenceCandidate
    let outcome: Phase2ReadTerminalOutcome
    let acceptedEvidence: Phase2AcceptedEvidence?

    var disposition: Phase2ReadDisposition { outcome.disposition }
}

@MainActor
extension WorkspaceStore {
    func preparePhase2Read(
        operation: Phase2ReadOperationID,
        proposingPrincipal: Phase2Principal = .model,
        limits: Phase2ReadLimits = .maximum,
        nativeDecompilerState: NativeDecompilerPresentationState = .idle,
        reaResultRead: REAResultReadSelector? = nil
    ) -> Phase2ReadPreparationDecision {
        guard let descriptor = TypedReadRegistry().descriptor(for: operation) else {
            return .rejected(.unsupported)
        }

        let capturedSnapshot = snapshot
        let capturedFocus = capturedSnapshot.binary(in: focusedImageSlot) == nil
            ? nil
            : focusedImageSlot

        let subject: Phase2ReadSubject
        let image: Phase2ReadImageIdentity?
        let facets: [Phase2ReadFacet]
        let strictWholeWorkspace: Bool

        switch operation {
        case .workspaceSummary, .applicationGraphSummary, .reaResultsList, .reaResultsGet:
            image = capturedFocus.flatMap {
                phase2ReadLedger.imageIdentity(in: $0, snapshot: capturedSnapshot)
            }
            subject = .workspace(phase2ReadLedger.workspace)
            if operation == .applicationGraphSummary {
                guard image != nil else {
                    return .unavailable(.unresolvedOwner)
                }
                facets = [.workspaceTopology, .loaderMetadata]
            } else {
                facets = image == nil
                    ? [.workspaceTopology]
                    : [.workspaceTopology, .functionBoundaries]
            }
            strictWholeWorkspace = true

        case .selectionExplain:
            guard let selection = selectedImageAddress else {
                return .unavailable(.noSelection)
            }
            guard let exactImage = phase2ReadLedger.imageIdentity(
                in: selection.slot,
                snapshot: capturedSnapshot
            ) else {
                return .unavailable(.unresolvedOwner)
            }
            image = exactImage
            subject = .staticLocation(.init(
                image: exactImage,
                domain: .imageVirtualAddress,
                address: selection.address
            ))
            facets = [.functionBoundaries, .instructionDecoding]
            strictWholeWorkspace = false

        case .functionReview, .functionCallSites, .decompilerNativeResult, .decompilerMacScopeResult,
             .decompilerCompare:
            guard let selection = selectedImageAddress else {
                return .unavailable(.noSelection)
            }
            guard let exactImage = phase2ReadLedger.imageIdentity(
                in: selection.slot,
                snapshot: capturedSnapshot
            ), let analysis = capturedSnapshot.analysis(in: selection.slot) else {
                return .unavailable(.unresolvedOwner)
            }
            if operation == .functionCallSites,
               analysis.xrefs.count > Phase2FunctionCallSitesProjector.maximumInputReferences {
                return .rejected(.limitExceeded)
            }
            let matches = analysis.functions.filter {
                $0.endAddress > $0.startAddress
                    && selection.address >= $0.startAddress
                    && selection.address < $0.endAddress
            }
            guard matches.count == 1, let function = matches.first else {
                return .unavailable(matches.isEmpty ? .notFound : .ambiguous)
            }
            image = exactImage
            subject = .functionRange(.init(
                image: exactImage,
                start: function.startAddress,
                endExclusive: function.endAddress
            ))
            if operation == .functionCallSites {
                facets = Phase2ReadOperationID.functionCallSiteFacets
            } else {
                facets = operation == .functionReview
                    ? [.functionBoundaries, .instructionDecoding]
                    : [.functionBoundaries, .instructionDecoding, .pseudocode]
            }
            strictWholeWorkspace = false

        default:
            return .rejected(.unsupported)
        }

        let dependencies = phase2ReadLedger.dependencies(
            for: facets,
            image: image,
            snapshot: capturedSnapshot
        )
        let currentState = phase2ReadLedger.currentState(
            for: image?.slot,
            snapshot: capturedSnapshot
        )
        let precondition = Phase2ReadPrecondition(
            workspace: phase2ReadLedger.workspace,
            workspaceRevision: phase2ReadLedger.workspaceRevision,
            strictWholeWorkspace: strictWholeWorkspace,
            image: image,
            dependencies: dependencies
        )
        let resolvedREASelector: REAResultReadSelector?
        if operation == .reaResultsGet, reaResultRead == nil, let record = reaResultEvidence.records.last {
            resolvedREASelector = .init(evidenceID: record.evidenceID, responseSHA256: record.responseSHA256)
        } else { resolvedREASelector = reaResultRead }
        let readRecord = resolvedREASelector?.evidenceID.flatMap { id in
            reaResultEvidence.records.first { $0.evidenceID == id }
        } ?? reaResultEvidence.records.last
        let activeREA = readRecord.flatMap { reaAuthority(imageSHA256: $0.authority.imageSHA256, snapshotID: $0.authority.snapshotID) }
        let request = Phase2ReadRequest(
            requestID: UUID(),
            invocationID: UUID(),
            sequence: 1,
            proposingPrincipal: proposingPrincipal,
            descriptor: descriptor,
            subject: subject,
            precondition: precondition,
            limits: limits,
            reaResultRead: resolvedREASelector
        )
        switch TypedReadRegistry().authorize(request, authorizingPrincipal: .app) {
        case .authorized(let authorization):
            return .prepared(.init(
                authorization: authorization,
                input: .init(
                    workspaceName: workspaceName,
                    snapshot: capturedSnapshot,
                    currentState: currentState,
                    focusedImageSlot: capturedFocus,
                    nativeDecompilerState: nativeDecompilerState,
                    reaResultStore: reaResultEvidence, reaWorkspaceID: workspaceID,
                    reaActiveAuthority: activeREA
                )
            ))
        case .rejected(let disposition):
            return .rejected(disposition)
        }
    }

    func executePhase2Read(_ prepared: Phase2PreparedRead) -> Phase2ReadExecution {
        executePhase2Read(prepared, acceptingWith: &phase2EvidenceAcceptor)
    }

    /// The scripting invocation may own its acceptance lifetime explicitly. The
    /// default coordinator retains its terminal ledger and duplicate semantics.
    func executePhase2Read(
        _ prepared: Phase2PreparedRead,
        acceptingWith acceptor: inout Phase2EvidenceAcceptor
    ) -> Phase2ReadExecution {
        let authorization = prepared.authorization
        let candidate = Phase2ReadProjector.project(
            authorization: authorization,
            input: prepared.input
        )
        let currentState = phase2ReadLedger.currentState(
            for: authorization.request.precondition.image?.slot,
            snapshot: snapshot
        )
        let acceptingEvidenceID = UUID()
        let outcome = acceptor.evaluate(
            candidate,
            authorization: authorization,
            against: currentState,
            acceptingEvidenceID: acceptingEvidenceID
        )
        return Phase2ReadExecution(
            candidate: candidate,
            outcome: outcome,
            acceptedEvidence: outcome.evidenceIDs == [acceptingEvidenceID]
                ? acceptor.acceptedEvidence(for: candidate.invocationID)
                : nil
        )
    }

    @discardableResult
    func cancelPhase2Read(invocationID: UUID, sequence: UInt64 = 1) -> Phase2ReadTerminalOutcome {
        phase2EvidenceAcceptor.cancel(invocationID: invocationID, sequence: sequence)
    }

    /// Internal test and future async-provider revalidation seam. It never exposes a mutable store
    /// reference or remaps the requested slot through current focus.
    func phase2ReadCurrentState(for slot: ImageSlot?) -> Phase2ReadCurrentState {
        phase2ReadLedger.currentState(for: slot, snapshot: snapshot)
    }

    /// Navigate to an app-owned Phase 2 citation only if the cited native identity is still exact.
    /// Workspace citations intentionally remain inert because they do not identify a single location.
    @discardableResult
    func navigateToPhase2Citation(_ target: Phase2ReadCitationTarget) -> Bool {
        switch target {
        case .workspace(let workspace):
            guard phase2ReadLedger.workspace == workspace else {
                lastIssue = "Citation target is no longer current."
                return false
            }
            return false

        case .image(let image):
            guard isCurrentPhase2CitationImage(image) else {
                lastIssue = "Citation target is no longer current."
                return false
            }
            focusImage(image.slot)
            return true

        case .staticLocation(let location):
            guard location.domain == .imageVirtualAddress,
                  isCurrentPhase2CitationImage(location.image)
            else {
                lastIssue = "Citation target is no longer current."
                return false
            }
            return goToAddress(location.address, in: location.image.slot)

        case .functionRange(let range):
            guard range.isValid,
                  isCurrentPhase2CitationImage(range.image),
                  let analysis = snapshot.analysis(in: range.image.slot),
                  analysis.functions.contains(where: {
                      $0.startAddress == range.start && $0.endAddress == range.endExclusive
                  })
            else {
                lastIssue = "Citation target is no longer current."
                return false
            }
            return goToAddress(range.start, in: range.image.slot)
        }
    }

    func acceptedPhase2Evidence(invocationID: UUID) -> Phase2AcceptedEvidence? {
        phase2EvidenceAcceptor.acceptedEvidence(for: invocationID)
    }

    /// Revalidates accepted evidence against one atomic current store cut immediately before
    /// compiling a provider-neutral packet. Invocation order never controls packet order.
    func compilePhase2GroundedContext(
        invocationIDs: [UUID],
        limits: Phase2GroundedContextLimits = .maximum
    ) throws -> Phase2GroundedContext {
        var accepted: [Phase2AcceptedEvidence] = []
        var currentByEvidenceID: [UUID: Phase2ReadCurrentState] = [:]

        for invocationID in invocationIDs {
            guard let evidence = phase2EvidenceAcceptor.acceptedEvidence(
                for: invocationID
            ) else {
                throw Phase2GroundedContextError.missingAcceptedEvidence(invocationID)
            }
            accepted.append(evidence)
            currentByEvidenceID[evidence.evidenceID] = phase2ReadLedger.currentState(
                for: evidence.precondition.image?.slot,
                snapshot: snapshot
            )
        }

        return try Phase2GroundedContextCompiler().compile(
            records: accepted,
            currentStateByEvidenceID: currentByEvidenceID,
            limits: limits
        )
    }

    private func isCurrentPhase2CitationImage(_ image: Phase2ReadImageIdentity) -> Bool {
        phase2ReadLedger.currentState(for: image.slot, snapshot: snapshot).image == image
    }
}
