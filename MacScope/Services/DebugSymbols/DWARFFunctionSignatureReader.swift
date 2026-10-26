import Foundation
import CryptoKit

/// Source-only attributes from a DWARF function declaration. Missing names and types stay
/// missing here even when the editable signature projection uses display placeholders.
struct DWARFFunctionDeclaration: Equatable, Sendable {
    struct Parameter: Equatable, Sendable {
        var name: String?
        var type: String?
        var isArtificial: Bool
    }

    var returnType: String?
    var parameters: [Parameter]
    var hasAuthoritativeParameterList: Bool
    var isVariadic: Bool
    var isObjectiveCDirect: Bool = false

    /// DWARF formal parameter order alone does not prove Objective-C implicit parameters.
    /// The two leading parameters must carry explicit artificial evidence.
    func explicitObjectiveCParameters(selectorArity: Int) -> [Parameter]? {
        guard selectorArity >= 0, selectorArity <= 64,
              hasAuthoritativeParameterList, !isVariadic, !isObjectiveCDirect,
              parameters.count == selectorArity + 2 else { return nil }
        let receiver = parameters[0]
        let selector = parameters[1]
        guard receiver.isArtificial, selector.isArtificial else {
            return nil
        }
        let explicit = Array(parameters.dropFirst(2))
        guard explicit.allSatisfy({ !$0.isArtificial }) else { return nil }
        return explicit
    }
}

/// Recovers function signatures from a decoded DWARF DIE tree and maps them to
/// function low_pc addresses. The reader is intentionally conservative: it only
/// follows CU-local type references that resolve to known, name-bearing type DIEs.
struct DWARFFunctionSignatureReader {
    private let sections: DWARFReader.Sections
    private let unresolvedParameterType = "undefined"
    /// DW_TAG_unspecified_parameters. The generic DIE tree preserves unknown tags,
    /// so detecting this standard tag does not require broadening the parser surface.
    private static let tagUnspecifiedParameters: UInt64 = 0x18
    /// DW_AT_artificial marks compiler-generated formal parameters.
    private static let atArtificial: UInt64 = 0x34

    init(sections: DWARFReader.Sections) {
        self.sections = sections
    }

    struct Recovery {
        var signatures: [UInt64: FunctionSignatureOverride] = [:]
        var declarations: [UInt64: DWARFFunctionDeclaration] = [:]
        /// Conflicting raw declarations; distinct from an address with no evidence.
        var refusedAddresses: Set<UInt64> = []
    }

    func recoverSignatures() -> [UInt64: FunctionSignatureOverride] {
        recoverSignaturesAndDeclarations().signatures
    }

    /// Keeps raw declaration attributes separate from the editable override projection.
    func recoverSignaturesAndDeclarations() -> Recovery {
        let roots = DWARFDIETree(sections: sections).parse()
        var recovery = Recovery()
        // Compare source evidence before projecting it: placeholders and omitted
        // artificial flags make the editable signature a lossy representation.
        // Include empty projections so incomplete evidence cannot be silently skipped.
        var observed: [UInt64: DWARFFunctionDeclaration] = [:]

        for root in roots {
            let offsetMap = Self.offsetMap(for: root)
            for subprogram in Self.nodes(withTag: DWARFConstants.tagSubprogram, under: root) {
                guard let address = subprogram.attributes[DWARFConstants.atLowPC]?.addressValue else { continue }
                guard !recovery.refusedAddresses.contains(address) else { continue }
                let declaration = declaration(for: subprogram, offsetMap: offsetMap)
                if let prior = observed[address] {
                    if prior != declaration {
                        observed.removeValue(forKey: address)
                        recovery.refusedAddresses.insert(address)
                    }
                } else {
                    observed[address] = declaration
                }
            }
        }

        // Publish only after every CU/DIE has participated. Refusal is sticky;
        // a later identical declaration cannot resurrect a conflicting address.
        for (address, declaration) in observed {
            let signature = signature(for: declaration, functionAddress: address)
            guard !signature.isEmpty else { continue }
            recovery.signatures[address] = signature
            recovery.declarations[address] = declaration
        }
        return recovery
    }

    private func declaration(
        for subprogram: DWARFDIENode,
        offsetMap: [Int: DWARFDIENode]
    ) -> DWARFFunctionDeclaration {
        let sources = signatureSources(for: subprogram, offsetMap: offsetMap)
        let returnType = firstAttribute(DWARFConstants.atType, in: sources)
            .flatMap { typeName(for: $0, offsetMap: offsetMap) }
        let parameterOwner = sources.dropFirst().first(where: { source in
            source.children.contains { $0.tag == DWARFConstants.tagFormalParameter }
        }) ?? sources.first(where: { source in
            source.children.contains { $0.tag == DWARFConstants.tagFormalParameter }
        })
        let parameters = (parameterOwner?.children ?? [])
            .filter { $0.tag == DWARFConstants.tagFormalParameter }
            .map { parameter in
                let parameterSources = signatureSources(
                    for: parameter,
                    expectedTag: DWARFConstants.tagFormalParameter,
                    offsetMap: offsetMap
                )
                return DWARFFunctionDeclaration.Parameter(
                    name: firstAttribute(DWARFConstants.atName, in: parameterSources)?.stringValue
                        .flatMap(Self.nonEmpty),
                    type: firstAttribute(DWARFConstants.atType, in: parameterSources)
                        .flatMap { typeName(for: $0, offsetMap: offsetMap) },
                    isArtificial: firstAttribute(Self.atArtificial, in: parameterSources)?.flagValue == true
                )
            }
        let isVariadic = sources.contains { source in
            source.children.contains { $0.tag == Self.tagUnspecifiedParameters }
        }
        let isPrototyped = sources.contains { source in
            source.attributes[DWARFConstants.atPrototyped]?.flagValue == true
        }
        return DWARFFunctionDeclaration(
            returnType: returnType,
            parameters: parameters,
            hasAuthoritativeParameterList: !parameters.isEmpty || isVariadic || isPrototyped,
            isVariadic: isVariadic,
            // A missing or false concrete attribute cannot erase inherited direct evidence.
            isObjectiveCDirect: sources.contains {
                $0.attributes[DWARFConstants.atAppleObjCDirect]?.flagValue == true
            }
        )
    }

    private func signature(
        for declaration: DWARFFunctionDeclaration,
        functionAddress: UInt64
    ) -> FunctionSignatureOverride {
        let args = declaration.parameters.enumerated().map { index, parameter in
            ArgOverride(
                rowToken: Self.parameterRowToken(functionAddress: functionAddress, ordinal: index),
                name: parameter.name ?? "arg\(index)",
                type: parameter.type ?? unresolvedParameterType,
                provenance: .debug
            )
        }
        let parameterList: FunctionSignatureOverride.ParameterListState = declaration.hasAuthoritativeParameterList
            ? .authoritative(args)
            : .unspecified
        let variadicState: FunctionSignatureOverride.VariadicState = declaration.isVariadic
            ? .variadic
            : (declaration.hasAuthoritativeParameterList ? .fixed : .unspecified)
        return FunctionSignatureOverride(
            returnType: declaration.returnType,
            parameterList: parameterList,
            variadicState: variadicState
        )
    }

    /// Resolves signature evidence through CU-local inheritance only. Concrete
    /// definitions may inherit declarations from `DW_AT_abstract_origin` or
    /// `DW_AT_specification`; cycles, cross-tag references, and missing offsets
    /// fail closed by ending the chain.
    private func signatureSources(
        for node: DWARFDIENode,
        expectedTag: UInt64 = DWARFConstants.tagSubprogram,
        offsetMap: [Int: DWARFDIENode]
    ) -> [DWARFDIENode] {
        guard node.tag == expectedTag else { return [] }
        var result: [DWARFDIENode] = []
        var visited = Set<Int>()

        func append(_ candidate: DWARFDIENode) {
            guard candidate.tag == expectedTag else { return }
            if let offset = candidate.cuOffset {
                guard visited.insert(offset).inserted else { return }
            }
            result.append(candidate)

            for attribute in [DWARFConstants.atAbstractOrigin, DWARFConstants.atSpecification] {
                guard let reference = candidate.attributes[attribute]?.cuReferenceOffset,
                      !visited.contains(reference),
                      let referenced = offsetMap[reference],
                      referenced.tag == expectedTag else {
                    continue
                }
                append(referenced)
            }
        }

        append(node)
        return result
    }

    private func firstAttribute(
        _ attribute: UInt64,
        in sources: [DWARFDIENode]
    ) -> DWARFAttributeValue? {
        sources.lazy.compactMap { $0.attributes[attribute] }.first
    }

    /// Derives stable opaque identity solely from the function address and the
    /// parameter's source-order ordinal. Names and types are intentionally absent,
    /// so a metadata spelling improvement does not transfer identity to another row.
    private static func parameterRowToken(functionAddress: UInt64, ordinal: Int) -> String {
        let address = String(format: "%016llx", functionAddress)
        let evidence = "dwarf-parameter-row-v1|\(address)|\(ordinal)"
        let digest = SHA256.hash(data: Data(evidence.utf8))
        let suffix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "debug-\(suffix)"
    }

    private func typeName(
        for value: DWARFAttributeValue,
        offsetMap: [Int: DWARFDIENode]
    ) -> String? {
        guard let offset = value.cuReferenceOffset else { return nil }
        return typeName(forOffset: offset, offsetMap: offsetMap, visited: [])
    }

    private func typeName(
        forOffset offset: Int,
        offsetMap: [Int: DWARFDIENode],
        visited: Set<Int>
    ) -> String? {
        guard !visited.contains(offset), let node = offsetMap[offset] else { return nil }
        var visited = visited
        visited.insert(offset)

        switch node.tag {
        case DWARFConstants.tagBaseType,
             DWARFConstants.tagTypedef,
             DWARFConstants.tagStructureType,
             DWARFConstants.tagUnionType,
             DWARFConstants.tagEnumerationType,
             DWARFConstants.tagClassType:
            // Name-bearing types resolve to their DW_AT_name (e.g. "int", "Point", "Color").
            // An anonymous composite has no name to recover, so it honestly stays unresolved
            // (nil -> "undefined") rather than inventing one.
            return node.attributes[DWARFConstants.atName]?.stringValue.flatMap(Self.nonEmpty)
        case DWARFConstants.tagPointerType:
            guard let pointee = node.attributes[DWARFConstants.atType] else { return nil }
            return typeName(for: pointee, offsetMap: offsetMap, visited: visited).map { "\($0)*" }
        case DWARFConstants.tagConstType:
            return qualifiedTypeName("const", of: node, offsetMap: offsetMap, visited: visited)
        case DWARFConstants.tagVolatileType:
            return qualifiedTypeName("volatile", of: node, offsetMap: offsetMap, visited: visited)
        case DWARFConstants.tagRestrictType:
            return qualifiedTypeName("restrict", of: node, offsetMap: offsetMap, visited: visited)
        case DWARFConstants.tagArrayType:
            // Resolve the element type and append the recovered dimension. Simple suffix
            // composition means a pointer-to-array reads as "int[10]*", not the canonical C
            // declarator — but the element type and bound are faithfully recovered.
            guard let element = node.attributes[DWARFConstants.atType] else { return nil }
            return typeName(for: element, offsetMap: offsetMap, visited: visited)
                .map { "\($0)\(Self.arrayDimension(of: node))" }
        default:
            return nil
        }
    }

    /// A transparent cv/restrict qualifier (const/volatile/restrict): resolve the underlying
    /// type and prefix `keyword`. Returns nil when the qualified type is itself unresolvable,
    /// so a qualifier never fabricates a name.
    private func qualifiedTypeName(
        _ keyword: String,
        of node: DWARFDIENode,
        offsetMap: [Int: DWARFDIENode],
        visited: Set<Int>
    ) -> String? {
        guard let base = node.attributes[DWARFConstants.atType] else { return nil }
        return typeName(for: base, offsetMap: offsetMap, visited: visited).map { "\(keyword) \($0)" }
    }

    private func typeName(
        for value: DWARFAttributeValue,
        offsetMap: [Int: DWARFDIENode],
        visited: Set<Int>
    ) -> String? {
        guard let offset = value.cuReferenceOffset else { return nil }
        return typeName(forOffset: offset, offsetMap: offsetMap, visited: visited)
    }

    private static func offsetMap(for root: DWARFDIENode) -> [Int: DWARFDIENode] {
        var map: [Int: DWARFDIENode] = [:]
        collectOffsets(from: root, into: &map)
        return map
    }

    private static func collectOffsets(from node: DWARFDIENode, into map: inout [Int: DWARFDIENode]) {
        if let cuOffset = node.cuOffset {
            map[cuOffset] = node
        }
        for child in node.children {
            collectOffsets(from: child, into: &map)
        }
    }

    private static func nodes(withTag tag: UInt64, under root: DWARFDIENode) -> [DWARFDIENode] {
        var result: [DWARFDIENode] = []
        collectNodes(withTag: tag, from: root, into: &result)
        return result
    }

    private static func collectNodes(withTag tag: UInt64, from node: DWARFDIENode, into result: inout [DWARFDIENode]) {
        if node.tag == tag {
            result.append(node)
        }
        for child in node.children {
            collectNodes(withTag: tag, from: child, into: &result)
        }
    }

    /// Recovers an array's dimension from its first `DW_TAG_subrange_type` child: DWARF carries
    /// the length as `DW_AT_count`, or as `DW_AT_upper_bound` (count = upper + 1). When neither
    /// is present (an incomplete `T[]`), the bound is left unspecified.
    private static func arrayDimension(of node: DWARFDIENode) -> String {
        guard let subrange = node.children.first(where: { $0.tag == DWARFConstants.tagSubrangeType }) else {
            return "[]"
        }
        if let count = subrange.attributes[DWARFConstants.atCount]?.unsignedValue {
            return "[\(count)]"
        }
        if let upper = subrange.attributes[DWARFConstants.atUpperBound]?.unsignedValue {
            // `DW_AT_upper_bound` is attacker-controlled; `upper + 1` traps at
            // UInt64.max. An unrepresentable count degrades to the unspecified
            // dimension rather than aborting the dSYM import.
            let (count, overflow) = upper.addingReportingOverflow(1)
            return overflow ? "[]" : "[\(count)]"
        }
        return "[]"
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

private extension DWARFAttributeValue {
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var addressValue: UInt64? {
        if case let .address(value) = self { return value }
        return nil
    }

    var cuReferenceOffset: Int? {
        guard case let .uint(value) = self else { return nil }
        return Int(exactly: value)
    }

    var flagValue: Bool? {
        switch self {
        case let .uint(value): value != 0
        case let .sint(value): value != 0
        default: nil
        }
    }

    /// A non-negative integer attribute (e.g. `DW_AT_count`/`DW_AT_upper_bound` carried as
    /// data/sdata/addr forms). A negative signed value (an unknown/flexible bound) is nil.
    var unsignedValue: UInt64? {
        switch self {
        case let .uint(value): return value
        case let .sint(value): return value >= 0 ? UInt64(value) : nil
        case let .address(value): return value
        default: return nil
        }
    }
}
