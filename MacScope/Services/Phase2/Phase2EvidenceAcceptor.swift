import CryptoKit
import Foundation

/// Canonical app-issued evidence created only after a candidate passes the complete acceptance
/// boundary. The initializer is intentionally file-private so untrusted candidates cannot be
/// wrapped as accepted evidence elsewhere in the app.
struct Phase2AcceptedEvidence: Hashable, Sendable {
    let evidenceID: UUID
    let candidateID: UUID
    let invocationID: UUID
    let sequence: UInt64
    let descriptor: Phase2ReadOperationDescriptor
    let producingPrincipal: Phase2Principal
    let precondition: Phase2ReadPrecondition
    let citations: [Phase2ReadCitation]
    let data: Phase2ReadCandidateData
    let payloadDigest: String

    fileprivate init(
        evidenceID: UUID,
        candidate: Phase2ReadEvidenceCandidate,
        descriptor: Phase2ReadOperationDescriptor,
        payloadDigest: String
    ) {
        self.evidenceID = evidenceID
        candidateID = candidate.candidateID
        invocationID = candidate.invocationID
        sequence = candidate.sequence
        self.descriptor = descriptor
        producingPrincipal = candidate.producingPrincipal
        precondition = candidate.precondition
        citations = candidate.citations
        data = candidate.data
        self.payloadDigest = payloadDigest
    }
}

/// App-owned terminal-state boundary for Phase 2 typed-read evidence.
///
/// It binds every candidate to an exact app-issued authorization, revalidates
/// freshness, and records exactly one terminal outcome per invocation.
struct Phase2EvidenceAcceptor: Sendable {
    private var terminalOutcomesByInvocationID: [UUID: Phase2ReadTerminalOutcome] = [:]
    private var acceptedEvidenceByInvocationID: [UUID: Phase2AcceptedEvidence] = [:]
    private var acceptedEvidenceIDs: Set<UUID> = []

    var terminalCount: Int {
        terminalOutcomesByInvocationID.count
    }

    func isTerminal(invocationID: UUID) -> Bool {
        terminalOutcomesByInvocationID[invocationID] != nil
    }

    func terminalOutcome(for invocationID: UUID) -> Phase2ReadTerminalOutcome? {
        terminalOutcomesByInvocationID[invocationID]
    }

    func acceptedEvidence(for invocationID: UUID) -> Phase2AcceptedEvidence? {
        acceptedEvidenceByInvocationID[invocationID]
    }

    /// Reserves the invocation's one terminal slot for cancellation.
    @discardableResult
    mutating func cancel(
        invocationID: UUID,
        sequence: UInt64 = 0
    ) -> Phase2ReadTerminalOutcome {
        if let existing = terminalOutcomesByInvocationID[invocationID] {
            return existing
        }

        let outcome = Phase2ReadTerminalOutcome(
            invocationID: invocationID,
            sequence: sequence,
            disposition: .cancelled
        )
        terminalOutcomesByInvocationID[invocationID] = outcome
        return outcome
    }

    /// Evaluates one evidence candidate against the current app-owned state.
    ///
    /// Duplicate or late candidates are rejected without disturbing the first
    /// terminal result.
    mutating func evaluate(
        _ candidate: Phase2ReadEvidenceCandidate,
        authorization: Phase2ReadAuthorization,
        against currentState: Phase2ReadCurrentState,
        acceptingEvidenceID: UUID = UUID()
    ) -> Phase2ReadTerminalOutcome {
        guard terminalOutcomesByInvocationID[candidate.invocationID] == nil else {
            return Phase2ReadTerminalOutcome(
                invocationID: candidate.invocationID,
                sequence: candidate.sequence,
                disposition: .duplicate
            )
        }

        let disposition: Phase2ReadDisposition
        var evidenceIDs: [UUID] = []
        var conflicts: [Phase2ReadConflict] = []
        var acceptedEvidence: Phase2AcceptedEvidence?

        if candidate.cancelled {
            disposition = .cancelled
        } else if !authorization.isValid
                    || !candidate.matches(authorization: authorization)
                    || !candidate.citationsAreAuthorized(by: authorization) {
            disposition = candidate.schemaIsSupported ? .unauthorized : .unsupported
        } else if !candidate.fits(within: authorization.approvedLimits) {
            disposition = .limitExceeded
        } else {
            let freshness = candidate.precondition.compared(to: currentState)
            if !freshness.isOwnerCurrent {
                disposition = .ownerMismatch
            } else if freshness.isStale {
                disposition = .stale
            } else {
                if acceptedEvidenceIDs.contains(acceptingEvidenceID) {
                    disposition = .duplicate
                } else {
                    switch candidate.data {
                    case .conflict(let conflict) where conflict.isValid:
                        if let evidence = makeAcceptedEvidence(
                            evidenceID: acceptingEvidenceID,
                            candidate: candidate,
                            descriptor: authorization.canonicalDescriptor
                        ) {
                            disposition = .conflict
                            conflicts = [conflict]
                            acceptedEvidence = evidence
                        } else {
                            disposition = .unsupported
                        }
                    case .conflict:
                        disposition = .unsupported
                    case .value, .unavailable:
                        if let evidence = makeAcceptedEvidence(
                            evidenceID: acceptingEvidenceID,
                            candidate: candidate,
                            descriptor: authorization.canonicalDescriptor
                        ) {
                            disposition = .accepted
                            acceptedEvidence = evidence
                        } else {
                            disposition = .unsupported
                        }
                    }

                    if acceptedEvidence != nil {
                        evidenceIDs = [acceptingEvidenceID]
                    }
                }
            }
        }

        let outcome = Phase2ReadTerminalOutcome(
            invocationID: candidate.invocationID,
            sequence: candidate.sequence,
            disposition: disposition,
            evidenceIDs: evidenceIDs,
            conflicts: conflicts
        )
        terminalOutcomesByInvocationID[candidate.invocationID] = outcome
        if let acceptedEvidence {
            acceptedEvidenceByInvocationID[candidate.invocationID] = acceptedEvidence
            acceptedEvidenceIDs.insert(acceptedEvidence.evidenceID)
        }
        return outcome
    }

    private func makeAcceptedEvidence(
        evidenceID: UUID,
        candidate: Phase2ReadEvidenceCandidate,
        descriptor: Phase2ReadOperationDescriptor
    ) -> Phase2AcceptedEvidence? {
        struct DigestInput: Encodable {
            let descriptor: Phase2ReadOperationDescriptor
            let producingPrincipal: Phase2Principal
            let precondition: Phase2ReadPrecondition
            let citations: [Phase2ReadCitation]
            let data: Phase2ReadCandidateData
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(DigestInput(
            descriptor: descriptor,
            producingPrincipal: candidate.producingPrincipal,
            precondition: candidate.precondition,
            citations: candidate.citations,
            data: candidate.data
        )) else { return nil }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return Phase2AcceptedEvidence(
            evidenceID: evidenceID,
            candidate: candidate,
            descriptor: descriptor,
            payloadDigest: digest
        )
    }
}

private extension Phase2ReadEvidenceCandidate {
    var schemaIsSupported: Bool {
        registryVersion == .v1
            && operationVersion == .v1
            && Phase2ReadOperationID.allKnown.contains(operationID)
    }

    func matches(authorization: Phase2ReadAuthorization) -> Bool {
        let request = authorization.request
        return schemaIsSupported
            && invocationID == request.invocationID
            && sequence == request.sequence
            && registryVersion == authorization.canonicalDescriptor.registryVersion
            && operationID == authorization.canonicalDescriptor.id
            && operationVersion == authorization.canonicalDescriptor.operationVersion
            && precondition == request.precondition
            && producingPrincipal == authorization.canonicalDescriptor.executorPrincipal
    }

    func citationsAreAuthorized(by authorization: Phase2ReadAuthorization) -> Bool {
        guard !citations.isEmpty else { return false }
        let request = authorization.request
        let precondition = request.precondition
        let allowedDependencies = Set(precondition.dependencies)
        guard allowedDependencies.count == precondition.dependencies.count else { return false }

        func isAuthorized(_ citation: Phase2ReadCitation) -> Bool {
            let dependencies = Set(citation.dependencies)
            guard dependencies.count == citation.dependencies.count,
                  dependencies.isSubset(of: allowedDependencies)
            else { return false }

            return citation.target.isAuthorized(by: request.subject, precondition: precondition)
        }

        guard citations.allSatisfy(isAuthorized) else { return false }
        if case .conflict(let conflict) = data {
            return conflict.claims.allSatisfy {
                !$0.citations.isEmpty && $0.citations.allSatisfy(isAuthorized)
            }
        }
        return true
    }
}

extension Phase2ReadEvidenceCandidate {
    /// Shared pure budget predicate. Acceptance, freshness and evidence IDs
    /// remain owned by Phase2EvidenceAcceptor. Projectors may trim against it.
    func fits(within limits: Phase2ReadLimits) -> Bool {
        guard let encoded = try? JSONEncoder().encode(self),
              encoded.count <= limits.encodedResultBytes
        else { return false }

        switch data {
        case .value(let value):
            return value.fits(within: limits, depth: 1)
        case .unavailable:
            return true
        case .conflict(let conflict):
            return conflict.claims.count <= limits.pageItems
                && conflict.claims.allSatisfy {
                    $0.value.fits(within: limits, depth: 1)
                        && $0.contentDigest.utf8.count <= limits.stringBytes
                }
        }
    }
}

private extension Phase2ReadCitationTarget {
    func isAuthorized(
        by subject: Phase2ReadSubject,
        precondition: Phase2ReadPrecondition
    ) -> Bool {
        switch (subject, self) {
        case let (.workspace(expected), .workspace(actual)):
            return actual == expected && actual == precondition.workspace
        case let (.workspace, .image(image)):
            return image == precondition.image
        case let (.staticLocation(expected), .staticLocation(actual)):
            return actual == expected
        case let (.staticLocation(location), .functionRange(range)):
            return range.isValid
                && range.image == location.image
                && range.contains(location.address)
        case let (.functionRange(expected), .functionRange(actual)):
            return actual == expected
        case let (.functionRange(range), .staticLocation(location)):
            return location.image == range.image && range.contains(location.address)
        default:
            return false
        }
    }
}

private extension Phase2ReadFunctionRange {
    func contains(_ address: UInt64) -> Bool {
        isValid && address >= start && address < endExclusive
    }
}

private extension Phase2ReadFactValue {
    func fits(within limits: Phase2ReadLimits, depth: Int) -> Bool {
        guard depth <= limits.structuralNesting else { return false }
        switch self {
        case .boolean, .signedInteger, .unsignedInteger, .staticLocation:
            return true
        case .text(let text):
            return text.utf8.count <= limits.stringBytes
        case .list(let values):
            return values.count <= limits.arrayItems
                && values.allSatisfy { $0.fits(within: limits, depth: depth + 1) }
        case .object(let fields):
            return fields.count <= limits.objectMembers
                && fields.allSatisfy {
                    $0.name.utf8.count <= limits.stringBytes
                        && $0.value.fits(within: limits, depth: depth + 1)
                }
        }
    }
}
