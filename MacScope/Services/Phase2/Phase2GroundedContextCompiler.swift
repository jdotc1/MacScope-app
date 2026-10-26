import CryptoKit
import Foundation

/// Pure compiler from app-issued accepted evidence to a deterministic provider-neutral packet.
struct Phase2GroundedContextCompiler: Sendable {
    func compile(
        records acceptedEvidence: [Phase2AcceptedEvidence],
        currentStateByEvidenceID: [UUID: Phase2ReadCurrentState],
        limits: Phase2GroundedContextLimits = .maximum
    ) throws -> Phase2GroundedContext {
        guard limits.isValid else { throw Phase2GroundedContextError.invalidLimits }

        let grouped = Dictionary(grouping: acceptedEvidence, by: \.evidenceID)
        if let duplicate = grouped.first(where: { $0.value.count != 1 })?.key {
            throw Phase2GroundedContextError.duplicateEvidenceID(duplicate)
        }

        let sortedEvidence = acceptedEvidence.sorted {
            $0.evidenceID.uuidString < $1.evidenceID.uuidString
        }
        var records: [Phase2GroundedContextRecord] = []
        var omissions: [Phase2GroundedContextOmission] = []

        for evidence in sortedEvidence {
            guard let current = currentStateByEvidenceID[evidence.evidenceID] else {
                throw Phase2GroundedContextError.missingCurrentState(evidence.evidenceID)
            }
            let freshness = evidence.precondition.compared(to: current)
            guard freshness.isOwnerCurrent else {
                throw Phase2GroundedContextError.ownerMismatch(evidence.evidenceID)
            }
            guard !freshness.isStale else {
                throw Phase2GroundedContextError.stale(evidence.evidenceID)
            }

            let record = Phase2GroundedContextRecord(
                evidenceID: evidence.evidenceID,
                candidateID: evidence.candidateID,
                invocationID: evidence.invocationID,
                sequence: evidence.sequence,
                descriptor: evidence.descriptor,
                producingPrincipal: evidence.producingPrincipal,
                trustClass: .untrustedProjectData,
                precondition: evidence.precondition,
                citations: evidence.citations.sorted {
                    $0.id.uuidString < $1.id.uuidString
                },
                data: evidence.data,
                payloadDigest: evidence.payloadDigest
            )

            if records.count < limits.maximumRecords {
                records.append(record)
            } else {
                omissions.append(.init(
                    evidenceID: evidence.evidenceID,
                    reason: .recordBudgetExceeded
                ))
            }
        }

        omissions.sort { $0.evidenceID.uuidString < $1.evidenceID.uuidString }
        var canonicalBytes = try encode(records: records, omissions: omissions)
        while canonicalBytes.count > limits.maximumCanonicalBytes, let omitted = records.popLast() {
            omissions.append(.init(
                evidenceID: omitted.evidenceID,
                reason: .recordBudgetExceeded
            ))
            omissions.sort { $0.evidenceID.uuidString < $1.evidenceID.uuidString }
            canonicalBytes = try encode(records: records, omissions: omissions)
        }
        guard canonicalBytes.count <= limits.maximumCanonicalBytes else {
            throw Phase2GroundedContextError.packetBudgetTooSmall
        }

        let digest = SHA256.hash(data: canonicalBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return .make(
            records: records,
            omissions: omissions,
            canonicalBytes: canonicalBytes,
            digest: digest
        )
    }

    private func encode(
        records: [Phase2GroundedContextRecord],
        omissions: [Phase2GroundedContextOmission]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(Phase2GroundedContextManifest(
                records: records,
                omissions: omissions
            ))
        } catch {
            throw Phase2GroundedContextError.encodingFailed
        }
    }
}
