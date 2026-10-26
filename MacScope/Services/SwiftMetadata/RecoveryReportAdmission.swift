import Foundation
import RecoveryKit

/// A thin, synchronous publication boundary for an existing host task. The caller supplies its
/// native coordinator fence token and current image coordinate; this type never schedules work.
/// Image changes, cancellation and publication must share the main actor, as they do in the
/// native workspace session. A token check alone is not a cross-thread publication lock.
@MainActor
final class RecoveryReportAdmission {
    static let producer = "macscope.swift-recovery-import"
    static let ruleVersion = "1"

    struct Ticket: Sendable {
        fileprivate let id: UUID
        fileprivate let identity: RecoveryImportIdentity
        fileprivate let generation: NativeDecompilerAdmissionToken
    }

    struct Presentation: Sendable {
        let image: String
        let factCount: Int
        let unresolved: [String]
        let sourceValidation: String
    }

    private var latest: Ticket?
    private var consumed: Set<UUID> = []
    private var issued: Set<UUID> = []
    private var admittedSourceFacts: [String: ProofFact] = [:]
    private var projectedIDs: [String: String] = [:]
    private var admittedIDs: Set<String> = []
    private var unresolved: [String] = []
    private var sourceValidation = "not_run"
    private var published = false

    func begin(taskID: UUID, identity: RecoveryImportIdentity,
               generation: NativeDecompilerAdmissionToken) throws -> Ticket {
        guard generation.isCurrent else { throw RecoveryImportError.staleCompletion }
        guard !issued.contains(taskID) else { throw RecoveryImportError.duplicateTask }
        issued.insert(taskID)
        if latest?.identity != identity {
            admittedSourceFacts = [:]
            projectedIDs = [:]
            admittedIDs = []
        }
        let ticket = Ticket(id: taskID, identity: identity, generation: generation)
        latest = ticket
        published = false
        return ticket
    }

    func invalidate() {
        latest = nil
        admittedSourceFacts = [:]
        published = false
        projectedIDs = [:]
        admittedIDs = []
    }

    func accept(_ bundle: RecoveryImportBundle, ticket: Ticket,
                currentIdentity: RecoveryImportIdentity, store: inout NavigatorContractStore) throws {
        guard bundle.identity == ticket.identity else { throw RecoveryImportError.artifactMismatch }
        let envelope: AnalysisEnvelope
        do {
            envelope = try AnalysisEnvelope.load(bundle.analysis, expectedImage: ticket.identity.imageKey)
        } catch { throw RecoveryImportError.malformedReport }
        // Report identity is checked in addition to its digest key; neither can stand in for
        // the host's occurrence/slot/fingerprint. Manifest verification already preceded decode.
        guard let image = envelope.document["image"], let slice = ticket.identity.coordinate.image.machOIdentity,
              image["artifact_sha256"]?.string == ticket.identity.coordinate.artifact.contentIdentity.digest,
              image["slice_sha256"]?.string == slice.selectedSliceSHA256,
              image["slice_offset"]?.uint64 == ticket.identity.sliceOffset,
              image["slice_size"]?.uint64 == slice.selectedSliceByteCount,
              image["cpu_type"] == .signed(Int64(slice.rawCPUType)),
              image["cpu_subtype"] == .signed(Int64(slice.rawCPUSubtype)) else {
            throw RecoveryImportError.artifactMismatch
        }
        guard latest?.id == ticket.id, !consumed.contains(ticket.id), ticket.generation.isCurrent,
              currentIdentity == ticket.identity else { throw RecoveryImportError.staleCompletion }

        var pending: [ProofFact] = []
        var seen: Set<String> = []
        for value in envelope.facts {
            let fact: ProofFact
            do { fact = try JSONDecoder().decode(ProofFact.self, from: JSONEncoder().encode(value)) }
            catch { throw RecoveryImportError.malformedReport }
            guard seen.insert(fact.id).inserted else { throw RecoveryImportError.malformedReport }
            guard fact.authority != .authoritative || fact.parents.isEmpty else {
                throw RecoveryImportError.malformedReport
            }
            if let previous = admittedSourceFacts[fact.id], previous != fact {
                throw RecoveryImportError.malformedReport
            }
            pending.append(fact)
        }
        let sourceFacts = pending
        var mapping = projectedIDs
        var accepted: [NavigatorFact] = []
        var gaps = try envelope.frontier.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let live = store.liveFacts()
        // Existing mappings must still be live; a repeated parent cannot resurrect a revoked fact.
        for fact in pending where mapping[fact.id] != nil {
            guard let mapped = mapping[fact.id], live[mapped] != nil else { throw RecoveryImportError.inactiveParent }
        }
        while !pending.isEmpty {
            var progressed = false
            var next: [ProofFact] = []
            for fact in pending {
                guard fact.parents.allSatisfy({ mapping[$0] != nil }) else { next.append(fact); continue }
                let parents = fact.parents.compactMap { mapping[$0] }
                let acceptedIDs = Set(accepted.map(\.id))
                guard parents.allSatisfy({ live[$0] != nil || acceptedIDs.contains($0) }) else {
                    throw RecoveryImportError.inactiveParent
                }
                guard let projected = try project(fact, identity: ticket.identity, parents: parents,
                                                  toolchain: store.toolchain) else {
                    gaps.append("Unsupported imported fact: \(fact.subject) / \(fact.predicate) [\(fact.id)]")
                    progressed = true
                    continue
                }
                if let previous = mapping[fact.id], previous != projected.id { throw RecoveryImportError.malformedReport }
                mapping[fact.id] = projected.id
                if let previous = live[projected.id] ?? accepted.first(where: { $0.id == projected.id }),
                   previous != projected { throw RecoveryImportError.malformedReport }
                accepted.append(projected)
                progressed = true
            }
            guard progressed else { throw RecoveryImportError.inactiveParent }
            pending = next
        }
        var candidate = store
        // Unsupported facts remain visible in the import presentation. With no supported
        // facts, there is no fact publication to append to the host journal.
        if !accepted.isEmpty {
            let result = NavigatorPrimitiveResult(primitive: Self.producer, primitiveVersion: Self.ruleVersion,
                subject: NavigatorSubject(kind: "image", ref: ticket.identity.imageKey, image: ticket.identity.hostImageKey),
                budget: [:], facts: accepted)
            if let refusal = candidate.add(result, session: ticket.id.uuidString) { throw refusal }
        }
        guard ticket.generation.isCurrent else { throw RecoveryImportError.staleCompletion }
        store = candidate
        projectedIDs = mapping
        for fact in sourceFacts { admittedSourceFacts[fact.id] = fact }
        admittedIDs.formUnion(accepted.map(\.id))
        consumed.insert(ticket.id)
        unresolved = gaps
        sourceValidation = envelope.document["completion"]?["source_validation"]?.string ?? "not_run"
        published = true
    }

    func presentation(currentIdentity: RecoveryImportIdentity, store: NavigatorContractStore) -> Presentation? {
        guard published, let latest, latest.identity == currentIdentity, latest.generation.isCurrent else { return nil }
        return Presentation(image: currentIdentity.hostImageKey,
            factCount: admittedIDs.intersection(store.liveFacts().keys).count,
            unresolved: unresolved, sourceValidation: sourceValidation)
    }

    private func project(_ fact: ProofFact, identity: RecoveryImportIdentity, parents: [String],
                         toolchain: String) throws -> NavigatorFact? {
        let parts = fact.subject.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["type", "field"].contains(parts[0]),
              parts[1].hasPrefix("0x"), UInt64(parts[1].dropFirst(2), radix: 16) != nil else { return nil }
        let predicate: String
        switch (parts[0], fact.predicate) {
        case (_, "name"): predicate = "hasName"
        case ("type", "kind"): predicate = "nominalKind"
        default: return nil
        }
        guard fact.authority != .unknown else { return nil }
        guard fact.authority != .derived || !parents.isEmpty else { return nil }
        let value = try NavigatorJSONParser.parse(JSONEncoder().encode(fact.value))
        let provenance = [NavigatorProvenance(kind: "rule", ref: fact.id,
                            rule: Self.producer, ruleVersion: Self.ruleVersion),
                          NavigatorProvenance(kind: "metadataRecord", ref: fact.anchors.isEmpty ? fact.id : fact.anchors.joined(separator: ","),
                            rule: fact.rule, ruleVersion: "source")]
        return try NavigatorFact.make(subject: NavigatorSubject(kind: parts[0], ref: parts[1], image: identity.hostImageKey),
            predicate: predicate, value: value, status: fact.authority.rawValue, provenance: provenance,
            toolchain: toolchain, tier: fact.authority == .derived ? 1 : nil,
            derivedFrom: fact.authority == .derived ? [parents] : nil)
    }
}
