import Foundation

/// N1: projects `SwiftMetadataParser` output onto navigator-engine contract v1 facts and frontier
/// items (`docs/contracts/navigator-engine/v1`). Resolved metadata facts are authoritative;
/// unresolved superclass diagnostics have unknown status and a frontier item, never a guessed name.
///
/// Subjects are type descriptors by address (`type`, ref `0x…`): names are module-qualified where the
/// parent walk resolves (`Mod.Outer.Inner`, `Swift.Equatable`) and simple otherwise, but the
/// descriptor, not the name, is the identity. A conformance whose
/// conforming type has no in-image descriptor is keyed by its simple name and flagged on the frontier.
///
/// Every subject ref is built by `NavigatorSubjectRef` (the spellings are the ones this projection
/// always wrote, so subject JSON is unchanged). Rule version 2: the projection is now run by the
/// workspace producer and stamps the caller's `generation` / `dependsOn` on every record.
enum SwiftMetadataFactProjection {
    static let rule = "macscope.swift-metadata-parser"
    static let ruleVersion = "2"

    struct Output: Sendable {
        var facts: [NavigatorFact] = []
        var frontier: [NavigatorFrontierItem] = []
        /// Records the contract refused (should stay empty; reported rather than dropped silently).
        var refused: [String] = []
    }

    static func project(types: [SwiftTypeDescriptor], conformances: [SwiftConformance],
                        diagnostics: [MetadataParseDiagnostic], protocols: [SwiftProtocolDescriptor] = [],
                        image: String, toolchain: String, generation: NavigatorGeneration? = nil,
                        dependsOn: [String]? = nil) -> Output {
        var output = Output()
        var seen = Set<String>()

        /// Type and protocol subject refs: the descriptor address, else the `name:` form, else the
        /// raw `name:` spelling for a name the grammar refuses (empty, or with a control character).
        func typeRef(descriptor: UInt64?, name: String) -> String {
            if let descriptor { return NavigatorSubjectRef.type(descriptor: descriptor) }
            return NavigatorSubjectRef.named(kind: "type", qualifiedName: name) ?? "name:\(name)"
        }
        func protocolRef(name: String) -> String {
            NavigatorSubjectRef.named(kind: "protocol", qualifiedName: name) ?? "name:\(name)"
        }
        func add(_ make: () throws -> NavigatorFact) {
            do {
                let fact = try make()
                if seen.insert(fact.id).inserted { output.facts.append(fact) }
            } catch {
                output.refused.append("\(error)")
            }
        }
        func gap(_ make: () throws -> NavigatorFrontierItem) {
            do {
                let item = try make()
                if seen.insert(item.id).inserted { output.frontier.append(item) }
            } catch {
                output.refused.append("\(error)")
            }
        }
        func provenance(_ ref: String) -> [NavigatorProvenance] {
            [NavigatorProvenance(kind: "metadataRecord", ref: ref, rule: rule, ruleVersion: ruleVersion)]
        }

        for type in types {
            let ref = typeRef(descriptor: type.descriptorAddress, name: type.name)
            let subject = NavigatorSubject(kind: "type", ref: ref, image: image)
            let evidence = provenance("__swift5_types descriptor \(ref)")
            if type.kind == .unknown {
                gap { try NavigatorFrontierItem.make(subject: subject, gap: "unknownContext",
                                                     detail: "context kind \(type.rawKind.map(String.init) ?? "?")", toolchain: toolchain,
                                                     missingEvidence: [ref], generation: generation, dependsOn: dependsOn) }
                continue
            }
            add { try NavigatorFact.make(subject: subject, predicate: "hasName", value: .string(type.qualifiedName ?? type.name),
                                         status: "authoritative", provenance: evidence, toolchain: toolchain,
                                         generation: generation, dependsOn: dependsOn) }
            add { try NavigatorFact.make(subject: subject, predicate: "nominalKind", value: .string(type.kind.rawValue),
                                         status: "authoritative", provenance: evidence, toolchain: toolchain,
                                         generation: generation, dependsOn: dependsOn) }
            if let isGeneric = type.isGeneric {
                add { try NavigatorFact.make(subject: subject, predicate: "isGeneric", value: .bool(isGeneric),
                                             status: "authoritative", provenance: evidence, toolchain: toolchain,
                                             generation: generation, dependsOn: dependsOn) }
            }
            // Positive-only: absence of these two is the default, not a recorded negative.
            if type.isPrivateOrLocal == true {
                add { try NavigatorFact.make(subject: subject, predicate: "isPrivateOrLocal", value: .bool(true),
                                             status: "authoritative", provenance: evidence, toolchain: toolchain,
                                             generation: generation, dependsOn: dependsOn) }
            }
            if type.isImportedCType == true {
                add { try NavigatorFact.make(subject: subject, predicate: "isImportedCType", value: .bool(true),
                                             status: "authoritative", provenance: evidence, toolchain: toolchain,
                                             generation: generation, dependsOn: dependsOn) }
            }
            if let superclass = type.superclass {
                add { try NavigatorFact.make(subject: subject, predicate: "superclass",
                                             value: type.superclassUnresolvedReason == nil ? .string(superclass) : .null,
                                             status: type.superclassUnresolvedReason == nil ? "authoritative" : "unknown",
                                             provenance: evidence, toolchain: toolchain,
                                             generation: generation, dependsOn: dependsOn) }
            }
            if let reason = type.superclassUnresolvedReason {
                gap { try NavigatorFrontierItem.make(
                    subject: subject, gap: "unknownType",
                    detail: "superclass" + (type.superclass.map { "; mangled \($0)" } ?? "") + "; reason \(reason)",
                    toolchain: toolchain, missingEvidence: [ref],
                    primitives: [NavigatorPrimitiveRef(name: "swiftMetadata.resolveSymbolicReference", preconditions: [])],
                    generation: generation, dependsOn: dependsOn) }
            }
            for field in type.fields {
                let member: NavigatorJSONValue
                let predicate: String
                if type.kind == .enum {
                    predicate = "enumCase"
                    member = .object(["name": .string(field.name), "payload": field.typeName.map { .string($0) } ?? .null,
                                      "mangled": field.mangledTypeName.map { .string($0) } ?? .null,
                                      "indirect": .bool(field.isIndirectCase)])
                } else {
                    predicate = "storedField"
                    member = .object(["name": .string(field.name), "type": field.typeName.map { .string($0) } ?? .null,
                                      "mangled": field.mangledTypeName.map { .string($0) } ?? .null,
                                      "var": .bool(field.isVar)])
                }
                add { try NavigatorFact.make(subject: subject, predicate: predicate, value: member, status: "authoritative",
                                             provenance: evidence, toolchain: toolchain,
                                             generation: generation, dependsOn: dependsOn) }
                // A case with no payload has no type by design; anything else unnamed is a gap.
                if field.typeName == nil, field.mangledTypeName != nil {
                    let fieldRef = NavigatorSubjectRef.field(typeRef: ref, name: field.name) ?? "\(ref).\(field.name)"
                    gap { try NavigatorFrontierItem.make(
                        subject: NavigatorSubject(kind: "field", ref: fieldRef, image: image), gap: "unknownType",
                        detail: "mangled \(field.mangledTypeName!)" + (field.unresolvedReason.map { "; reason \($0)" } ?? ""), toolchain: toolchain, missingEvidence: [ref],
                        primitives: [NavigatorPrimitiveRef(name: "swiftMetadata.resolveSymbolicReference", preconditions: [])],
                        generation: generation, dependsOn: dependsOn) }
                }
            }
        }

        for descriptor in protocols {
            let ref = NavigatorSubjectRef.protocol(descriptor: descriptor.descriptorAddress)
            let subject = NavigatorSubject(kind: "protocol", ref: ref, image: image)
            let evidence = provenance("__swift5_protos descriptor \(ref)")
            add { try NavigatorFact.make(subject: subject, predicate: "hasName", value: .string(descriptor.name),
                                         status: "authoritative", provenance: evidence, toolchain: toolchain,
                                         generation: generation, dependsOn: dependsOn) }
            add { try NavigatorFact.make(subject: subject, predicate: "isProtocol", value: .bool(true),
                                         status: "authoritative", provenance: evidence, toolchain: toolchain,
                                         generation: generation, dependsOn: dependsOn) }
        }

        for conformance in conformances {
            let subject = NavigatorSubject(kind: "type", ref: typeRef(descriptor: conformance.typeDescriptorAddress,
                                                                      name: conformance.typeName), image: image)
            if conformance.typeDescriptorAddress == nil {
                gap { try NavigatorFrontierItem.make(subject: subject, gap: "unresolvedTypeReference",
                                                     detail: "conforming type has no in-image descriptor", toolchain: toolchain,
                                                     generation: generation, dependsOn: dependsOn) }
            }
            let ref = conformance.descriptorAddress.map(NavigatorSubjectRef.address) ?? "?"
            if conformance.protocolQualifiedName == nil {
                // An unresolved reference keeps its simple name; the module is never guessed.
                gap { try NavigatorFrontierItem.make(
                    subject: NavigatorSubject(kind: "protocol", ref: protocolRef(name: conformance.protocolName), image: image),
                    gap: "unresolvedProtocol", detail: "protocol reference has no module-qualified name",
                    toolchain: toolchain, generation: generation, dependsOn: dependsOn) }
            }
            add { try NavigatorFact.make(subject: subject, predicate: "conformsTo",
                                         value: .string(conformance.protocolQualifiedName ?? conformance.protocolName),
                                         status: "authoritative", provenance: provenance("__swift5_proto descriptor \(ref)"),
                                         toolchain: toolchain, generation: generation, dependsOn: dependsOn) }
        }

        for diagnostic in diagnostics {
            let gapName: String
            switch diagnostic.grade {
            case .labelledUnknownKind, .walkCapped: gapName = "unknownContext"
            case .skippedItem, .abandonedList: gapName = "malformedFieldDescriptor"
            }
            // The diagnostic carries no section name, so the ref stays the bare address this projection
            // always wrote (the canonical `<section>@<address>` form needs the section).
            gap { try NavigatorFrontierItem.make(
                subject: NavigatorSubject(kind: "metadataRecord", ref: NavigatorSubjectRef.address(diagnostic.address), image: image),
                gap: gapName, detail: "\(diagnostic.grade.rawValue): \(diagnostic.message)", toolchain: toolchain,
                generation: generation, dependsOn: dependsOn) }
        }
        return output
    }
}
