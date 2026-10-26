import Foundation

/// Read-only comparison of supplied parse-result snapshots, NOT type equivalence,
/// inferred layout, ODR validation, ABI compatibility, or persistent catalog data.
struct DWARFRecordedDefinitionInput: Sendable {
    let collectionLabel: String
    let sourceLabel: String
    let roots: [DWARFDIENode]
}

struct DWARFRecordedProvenance: Hashable, Sendable {
    let inputOrdinal: Int
    let collectionLabel: String
    let sourceLabel: String
    /// Ordinal in this supplied parse result, not an absolute/stable CU identity.
    let cuRootOrdinal: Int
    let cuRelativeDIEOffset: Int?
}

struct DWARFRecordedMember: Sendable {
    let provenance: DWARFRecordedProvenance
    let name: String?
    let byteOffset: UInt64?
    let unknownReasons: [String]
}

struct DWARFRecordedDefinition: Sendable {
    let provenance: DWARFRecordedProvenance
    /// Named namespace components only. Nil excludes cross-CU identity matching.
    let qualifiedName: [String]?
    let recordedName: String?
    let byteSize: UInt64?
    let members: [DWARFRecordedMember]
    let memberListComplete: Bool
    let unknownReasons: [String]
}

struct DWARFRecordedDifference: Sendable {
    let field: String
    let leftRecordedValue: String
    let rightRecordedValue: String
}

struct DWARFRecordedFinding: Sendable {
    let left: DWARFRecordedDefinition
    let right: DWARFRecordedDefinition
    let differingFields: [DWARFRecordedDifference]
    /// True means only the fully observed size/name/offset subset agrees.
    /// Nil means incomplete or ambiguous direct facts; never type compatibility.
    let directFieldsAgree: Bool?
    let unknownReasons: [String]
    var hasExplicitRecordedConflict: Bool { !differingFields.isEmpty }
}

struct DWARFRecordedComparisonReport: Sendable {
    let definitions: [DWARFRecordedDefinition]
    let findings: [DWARFRecordedFinding]
    let limitations: [String]
    let visitedNodes: Int
    let workUsed: Int
}

struct DWARFRecordedComparisonLimits: Sendable {
    var maxNodes = 4096
    var maxDepth = 64
    var maxWork = 32768
    var maxDefinitions = 128
    var maxMembers = 128
    var maxFindings = 256
    var maxStringBytes = 256
}

/// Narrow portable consumer entry point. The existing reader owns parsing;
/// this entry point only reads actual DWARFDIENode value snapshots.
/// References are never traversed: unresolved, cyclic, and cross-unit reference
/// graphs cannot induce recursion or become evidence of equal member types.
enum DWARFRecordedDefinitionComparison {
    static func compare(_ inputs: [DWARFRecordedDefinitionInput],
                        limits: DWARFRecordedComparisonLimits = .init()) -> DWARFRecordedComparisonReport {
        var engine = Engine(limits: limits)
        return engine.run(inputs)
    }

    private struct Engine {
        let limits: DWARFRecordedComparisonLimits
        var nodes = 0
        var work = 0
        var definitions: [DWARFRecordedDefinition] = []
        var limitations: [String] = [
            "Transient supplied-parse provenance only; no absolute CU identity or attribute-form provenance.",
            "Member type compatibility unknown: type references are not resolved or compared."
        ]

        mutating func note(_ value: String) {
            if !limitations.contains(value) { limitations.append(value) }
        }
        mutating func spend() -> Bool {
            guard work < limits.maxWork else { note("Work bound reached; result is partial."); return false }
            work += 1
            return true
        }
        func text(_ value: DWARFAttributeValue?) -> String? {
            guard case let .string(s)? = value, !s.isEmpty,
                  s.utf8.prefix(limits.maxStringBytes + 1).count <= limits.maxStringBytes else { return nil }
            return s
        }
        func integer(_ value: DWARFAttributeValue?) -> UInt64? {
            switch value {
            case .uint(let n)?: return n
            case .sint(let n)? where n >= 0: return UInt64(n)
            default: return nil
            }
        }
        func provenance(_ base: DWARFRecordedProvenance, _ node: DWARFDIENode) -> DWARFRecordedProvenance {
            DWARFRecordedProvenance(inputOrdinal: base.inputOrdinal,
                collectionLabel: base.collectionLabel, sourceLabel: base.sourceLabel,
                cuRootOrdinal: base.cuRootOrdinal, cuRelativeDIEOffset: node.cuOffset)
        }

        mutating func walk(_ node: DWARFDIENode, base: DWARFRecordedProvenance,
                           namespaces: [String], identityKnown: Bool, depth: Int) {
            guard spend() else { return }
            guard depth <= limits.maxDepth else { note("Depth bound reached; result is partial."); return }
            guard nodes < limits.maxNodes else { note("Node bound reached; result is partial."); return }
            nodes += 1
            var childNamespace = namespaces
            var childKnown = identityKnown
            if node.tag == 0x39 { // DW_TAG_namespace
                if let name = text(node.attributes[0x03]) { childNamespace.append(name) }
                else { childKnown = false }
                if node.attributes[0x47] != nil || node.attributes[0x31] != nil { childKnown = false }
            } else if node.tag != 0x11 {
                // No cross-CU key for lexical blocks, subprogram-local records,
                // nested records, anonymous scopes, or unsupported scope kinds.
                childKnown = false
            }
            if node.tag == 0x13 {
                if definitions.count < limits.maxDefinitions {
                    project(node, base: base, namespaces: namespaces, identityKnown: identityKnown)
                } else { note("Definition output bound reached; result is partial.") }
            }
            for child in node.children {
                guard work < limits.maxWork, nodes < limits.maxNodes else {
                    note("Traversal budget reached; result is partial."); break
                }
                walk(child, base: base, namespaces: childNamespace,
                     identityKnown: childKnown, depth: depth + 1)
            }
        }

        mutating func project(_ node: DWARFDIENode, base: DWARFRecordedProvenance,
                              namespaces: [String], identityKnown: Bool) {
            let name = text(node.attributes[0x03])
            let size = integer(node.attributes[0x0b])
            var unknown: [String] = ["Member type compatibility unknown; reference/form provenance unavailable."]
            if name == nil { unknown.append("Missing, anonymous, unresolved, or over-budget record name.") }
            if size == nil { unknown.append("Missing or unsupported direct byte size.") }
            if node.cuOffset == nil { unknown.append("Missing CU-relative DIE offset.") }
            var identity = identityKnown && name != nil
            if !identityKnown { unknown.append("Anonymous, local lexical, nested, or unsupported scope identity.") }
            if node.attributes[0x47] != nil || node.attributes[0x31] != nil {
                identity = false
                unknown.append("Specification/abstract-origin identity is unresolved.")
            }
            var complete = true
            if node.attributes[0x3c] != nil { // DW_AT_declaration; conservative even if malformed/zero
                complete = false
                unknown.append("Declaration-only or ambiguous declaration attribute.")
            }
            var members: [DWARFRecordedMember] = []
            var names = Set<String>()
            for child in node.children {
                guard spend() else { complete = false; unknown.append("Member work bound reached."); break }
                guard child.tag == 0x0d else {
                    complete = false
                    unknown.append("Unsupported non-member child in recorded structure.")
                    // One reason suffices, even for many unsupported children.
                    break
                }
                guard members.count < limits.maxMembers else {
                    complete = false; unknown.append("Member output bound reached."); break
                }
                let memberName = text(child.attributes[0x03])
                let offset = integer(child.attributes[0x38])
                var reasons: [String] = []
                if memberName == nil { reasons.append("Missing, unresolved, anonymous, or over-budget member name.") }
                if offset == nil { reasons.append("Missing or unsupported direct integer member offset.") }
                if let memberName, !names.insert(memberName).inserted { reasons.append("Duplicate member name.") }
                if child.attributes[0x0d] != nil || child.attributes[0x0c] != nil || child.attributes[0x6b] != nil {
                    reasons.append("Bit-field facts unsupported.")
                }
                if child.attributes[0x47] != nil || child.attributes[0x31] != nil || !child.children.isEmpty {
                    reasons.append("Indirect or nested member facts unsupported.")
                }
                if !reasons.isEmpty { complete = false }
                members.append(DWARFRecordedMember(provenance: provenance(base, child),
                    name: memberName, byteOffset: offset, unknownReasons: reasons))
            }
            definitions.append(DWARFRecordedDefinition(provenance: provenance(base, node),
                qualifiedName: identity ? namespaces + [name!] : nil, recordedName: name,
                byteSize: size, members: members, memberListComplete: complete, unknownReasons: unknown))
        }

        mutating func run(_ inputs: [DWARFRecordedDefinitionInput]) -> DWARFRecordedComparisonReport {
            // Hard ceilings also bound caller-supplied budgets and arithmetic.
            guard limits.maxNodes > 0, limits.maxNodes <= 65536,
                  limits.maxDepth >= 0, limits.maxDepth <= 128,
                  limits.maxWork > 0, limits.maxWork <= 1000000,
                  limits.maxDefinitions >= 0, limits.maxDefinitions <= 512,
                  limits.maxMembers >= 0, limits.maxMembers <= 512,
                  limits.maxFindings >= 0, limits.maxFindings <= 1024,
                  limits.maxStringBytes > 0, limits.maxStringBytes <= 1024 else {
                note("Invalid limits; no projection or comparison attempted.")
                return report([])
            }
            for (inputOrdinal, input) in inputs.enumerated() {
                guard spend() else { break }
                guard text(.string(input.collectionLabel)) != nil, text(.string(input.sourceLabel)) != nil else {
                    note("Empty or over-budget input label; input omitted without invented provenance."); continue
                }
                for (cu, root) in input.roots.enumerated() {
                    guard spend(), nodes < limits.maxNodes else { note("Traversal budget reached; result is partial."); break }
                    let base = DWARFRecordedProvenance(inputOrdinal: inputOrdinal,
                        collectionLabel: input.collectionLabel, sourceLabel: input.sourceLabel,
                        cuRootOrdinal: cu, cuRelativeDIEOffset: root.cuOffset)
                    walk(root, base: base, namespaces: [], identityKnown: root.tag == 0x11, depth: 0)
                }
            }
            // Ambiguous same-key definitions within one CU are never matched.
            // Bounded quadratic comparisons avoid hashing unbounded tree snapshots.
            var ambiguous = Set<Int>()
            for i in definitions.indices {
                for j in definitions.indices where j > i {
                    guard spend() else { return report([]) }
                    let a = definitions[i], b = definitions[j]
                    if let key = a.qualifiedName, key == b.qualifiedName,
                       sameCU(a, b) { ambiguous.insert(i); ambiguous.insert(j) }
                }
            }
            var findings: [DWARFRecordedFinding] = []
            for i in definitions.indices {
                for j in definitions.indices where j > i {
                    guard spend() else { return report(findings) }
                    let a = definitions[i], b = definitions[j]
                    guard let key = a.qualifiedName, key == b.qualifiedName, !sameCU(a, b) else { continue }
                    guard findings.count < limits.maxFindings else {
                        note("Finding output bound reached; result is partial."); return report(findings)
                    }
                    if ambiguous.contains(i) || ambiguous.contains(j) {
                        findings.append(DWARFRecordedFinding(left: a, right: b, differingFields: [],
                            directFieldsAgree: nil, unknownReasons: ["Ambiguous same-qualified-name definitions in a CU.", "Type compatibility unknown."]))
                        continue
                    }
                    var differences: [DWARFRecordedDifference] = []
                    if let x = a.byteSize, let y = b.byteSize, x != y {
                        differences.append(.init(field: "byteSize", leftRecordedValue: String(x), rightRecordedValue: String(y)))
                    }
                    let complete = a.memberListComplete && b.memberListComplete
                    if complete {
                        if a.members.count != b.members.count {
                            differences.append(.init(field: "memberCount", leftRecordedValue: String(a.members.count), rightRecordedValue: String(b.members.count)))
                        }
                        // Index means recorded child order only, never inferred layout order.
                        for k in 0..<min(a.members.count, b.members.count) {
                            guard spend() else { return report(findings) }
                            let x = a.members[k], y = b.members[k]
                            if let xn = x.name, let yn = y.name, xn != yn {
                                differences.append(.init(field: "member[\(k)].name", leftRecordedValue: xn, rightRecordedValue: yn))
                            }
                            if let xo = x.byteOffset, let yo = y.byteOffset, xo != yo {
                                differences.append(.init(field: "member[\(k)].byteOffset", leftRecordedValue: String(xo), rightRecordedValue: String(yo)))
                            }
                        }
                    }
                    findings.append(DWARFRecordedFinding(left: a, right: b, differingFields: differences,
                        directFieldsAgree: complete && a.byteSize != nil && b.byteSize != nil ? differences.isEmpty : nil,
                        unknownReasons: a.unknownReasons + b.unknownReasons +
                            (complete ? [] : ["Member lists incomplete or unsupported; member agreement unknown."])))
                }
            }
            return report(findings)
        }
        func sameCU(_ a: DWARFRecordedDefinition, _ b: DWARFRecordedDefinition) -> Bool {
            a.provenance.inputOrdinal == b.provenance.inputOrdinal && a.provenance.cuRootOrdinal == b.provenance.cuRootOrdinal
        }
        func report(_ findings: [DWARFRecordedFinding]) -> DWARFRecordedComparisonReport {
            let partial = limitations.count > 2
            let finalFindings = partial ? findings.map {
                DWARFRecordedFinding(left: $0.left, right: $0.right, differingFields: $0.differingFields,
                    directFieldsAgree: nil, unknownReasons: $0.unknownReasons + ["Partial collection/output coverage; only observed disagreements retained."])
            } : findings
            return .init(definitions: definitions, findings: finalFindings, limitations: limitations, visitedNodes: nodes, workUsed: work)
        }
    }
}
