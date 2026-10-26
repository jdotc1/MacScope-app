import Foundation

enum UnwindAuditChangeKind: String, Hashable, Codable, Sendable {
    case unchanged
    case changed
    case ambiguous
    case incompatible
}

struct UnwindAuditMatchedChange: Hashable, Codable, Sendable {
    let match: FunctionVersionMatch
    let change: UnwindAuditChangeKind
    let beforeVerdict: String
    let afterVerdict: String
    let beforeScope: String
    let afterScope: String
    let notes: [String]
}

struct UnwindAuditComparison: Hashable, Codable, Sendable {
    let schemaVersion: Int
    let baselineIdentity: MachOSliceArtifactIdentity
    let currentIdentity: MachOSliceArtifactIdentity
    let sameSlice: Bool
    let modelCompatible: Bool
    let configurationChanged: Bool
    /// The matcher's complete result preserves evidence, ambiguity and unmatched functions.
    let matching: FunctionVersionMatchResult
    /// Audit changes are independent of the matcher's code-difference classification.
    let changes: [UnwindAuditMatchedChange]
    let limitations: [String]
}

enum UnwindAuditComparator {
    static func compare(
        baseline: UnwindAuditReport,
        current: UnwindAuditReport,
        pins: [FunctionVersionManualPin] = []
    ) throws -> UnwindAuditComparison {
        try baseline.validate()
        try current.validate()
        let matching = try FunctionVersionMatcher(
            old: baseline.findings.map(\.function),
            new: current.findings.map(\.function)
        ).match(pins: pins)
        let oldByID = Dictionary(uniqueKeysWithValues: baseline.findings.map { ($0.function.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: current.findings.map { ($0.function.id, $0) })
        let sameArchitecture = baseline.identity.rawCPUType == current.identity.rawCPUType
            && baseline.identity.rawCPUSubtype == current.identity.rawCPUSubtype
        let compatible = sameArchitecture
            && baseline.analysisModelVersion == current.analysisModelVersion
        let configurationChanged = baseline.configuration != current.configuration
        let observationsComparable = compatible && !configurationChanged
        let changes = matching.matches.compactMap { match -> UnwindAuditMatchedChange? in
            // The matcher only emits IDs from its supplied fingerprints.
            guard let before = oldByID[match.oldID], let after = newByID[match.newID] else { return nil }
            let change: UnwindAuditChangeKind = observationsComparable
                ? (Signature(before) == Signature(after) ? .unchanged : .changed)
                : .incompatible
            let notes = observationsComparable ? [] : [
                "Analysis model, architecture or configuration differs. Analyze both inputs with one model and configuration before interpreting an audit change."
            ]
            return UnwindAuditMatchedChange(
                match: match, change: change,
                beforeVerdict: before.verdict, afterVerdict: after.verdict,
                beforeScope: before.scope, afterScope: after.scope, notes: notes
            )
        }
        var limitations = [
            "Equal addresses across builds are not function identity evidence.",
            "Automatic matches are review candidates; their original basis and confidence are retained.",
            "Unmatched additions and removals are not automatically regressions or fixes.",
            "An agreement retains the checked scope and limitations of its source report."
        ]
        if configurationChanged {
            limitations.append("Analysis configuration differs; budget-related scope changes require review.")
        }
        return UnwindAuditComparison(
            schemaVersion: 1,
            baselineIdentity: baseline.identity,
            currentIdentity: current.identity,
            sameSlice: sameArchitecture
                && baseline.identity.selectedSliceSHA256 == current.identity.selectedSliceSHA256
                && baseline.identity.selectedSliceByteCount == current.identity.selectedSliceByteCount,
            modelCompatible: compatible,
            configurationChanged: configurationChanged,
            matching: matching,
            changes: changes,
            limitations: limitations
        )
    }

    private struct EvidenceSignature: Equatable {
        let code: String
        let expected: String?
        let observed: String?
        let relativeAddress: UInt64?
    }

    private struct Signature: Equatable {
        let verdict: String
        let coverage: String
        let mode: String
        let scope: String
        let encoding: UInt32?
        let reasonCodes: [String]
        let relativeCheckedPCs: [UInt64]
        let evidence: [EvidenceSignature]

        init(_ finding: UnwindAuditFinding) {
            verdict = finding.verdict
            coverage = finding.coverage
            mode = finding.mode
            scope = finding.scope
            encoding = finding.encoding
            reasonCodes = finding.reasonCodes.sorted()
            relativeCheckedPCs = finding.checkedPCs.map { $0 - finding.function.address }
            evidence = finding.evidence.map {
                EvidenceSignature(
                    code: $0.code, expected: $0.expected, observed: $0.observed,
                    relativeAddress: $0.address.map { $0 - finding.function.address }
                )
            }
        }
    }
}
