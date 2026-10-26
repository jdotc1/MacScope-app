import Foundation

/// Walks the Swift reflection metadata in a 64-bit Mach-O image to recover nominal types
/// (class/struct/enum) with their stored properties / enum cases:
/// `__swift5_types` → type context descriptor → `__swift5_fieldmd` field descriptor → records.
///
/// **Relative pointers.** Every cross-reference in Swift metadata is a 32-bit *self-relative*
/// pointer: the target VA is `fieldVA + Int32(value)` (value `0` means null). The parser works in
/// virtual-address space and maps VA→file-offset through the section table, exactly like
/// [[macscope-objc-class-parser]]. No chained-fixup resolution is needed for the direct pointers
/// Tier 1 follows; the `rebaseTargets` map is consulted only for *indirect* symbolic references.
///
/// **Correctness over coverage.** Field *names* are always clean C-strings. Field *types* are
/// decoded only when certain — common standard-library substitutions (`Si`→Int…) and single-hop
/// symbolic references resolve to a name; anything exotic yields `typeName == nil` rather than a
/// fabricated type. Every read is range-checked and every walk is bounded, since this parses
/// untrusted input (see [[macscope-parser-security-hardening]]).
struct SwiftMetadataParser {
    struct Section: Hashable, Sendable {
        var name: String
        var address: UInt64
        var fileOffset: UInt64
        var size: UInt64
        var isExecutable: Bool = false
        var isZeroFill: Bool = false
        var segmentName: String? = nil
    }

    let bytes: [UInt8]
    let sections: [Section]
    /// Indirect symbolic-reference GOT slots: location VA → resolved descriptor VA (chained-fixup REBASE).
    let rebaseTargets: [UInt64: UInt64]
    /// GOT slots bound to an EXTERNAL symbol (chained-fixup BIND): location VA → mangled symbol name,
    /// e.g. `_$sSQMp` (Swift.Equatable protocol descriptor). Used to name an external protocol/type a
    /// conformance references. Empty for Tier-1 callers.
    let bindNames: [UInt64: String]
    let metadataAddresses: [UInt64]

    var metadataByDescriptor: [UInt64: UInt64] = [:]
    private var methodLinks = SwiftMetadataFunctionExtractor.MethodLinks()

    init(data: Data, sections: [Section], rebaseTargets: [UInt64: UInt64] = [:], bindNames: [UInt64: String] = [:],
         metadataAddresses: [UInt64] = []) {
        self.bytes = [UInt8](data)
        self.sections = sections
        self.rebaseTargets = rebaseTargets
        self.bindNames = bindNames
        self.metadataAddresses = metadataAddresses
        methodLinks = SwiftMetadataFunctionExtractor.methodLinks(
            data: data, sections: sections, rebaseTargets: rebaseTargets, bindNames: bindNames
        )
        // Exact metadata symbols outrank the shape heuristic around descriptor-pointer fixups.
        // Keep conflicts at either priority unknown: address ordering is not layout evidence.
        let symbols = metadataCandidates(at: metadataAddresses.prefix(Limits.maxTypes))
        let heuristics = metadataCandidates(at: rebaseTargets.keys.lazy.filter { $0 >= 8 }.map { $0 - 8 })
        for (descriptor, addresses) in symbols where addresses.count == 1 {
            metadataByDescriptor[descriptor] = addresses.first
        }
        for (descriptor, addresses) in heuristics where symbols[descriptor] == nil && addresses.count == 1 {
            metadataByDescriptor[descriptor] = addresses.first
        }
    }

    /// Distinct candidate addresses for the same descriptor are ambiguous even if their vectors
    /// happen to agree. A symbol conflict also blocks fallback to weaker heuristic evidence.
    private func metadataCandidates<S: Sequence>(at addresses: S) -> [UInt64: Set<UInt64>] where S.Element == UInt64 {
        var candidates: [UInt64: Set<UInt64>] = [:]
        for address in addresses where address <= UInt64.max - 16 {
            guard readU64(atVA: address) == 0x200,
                  bindNames[address + 8] == nil,
                  let descriptor = rebaseTargets[address + 8] ?? readU64(atVA: address + 8) else { continue }
            candidates[descriptor, default: []].insert(address)
        }
        return candidates
    }

    // Defensive bounds for untrusted input.
    enum Limits {
        static let maxTypes = 200_000
        static let maxFieldsPerType = 65_536
        static let maxStringLength = 4_096
        /// Cap on a context-parent walk (leaf → … → module). Real nesting is a handful deep; the
        /// cap plus a visited set stops a crafted parent cycle or chain from walking forever.
        static let maxParentWalk = 64
    }

    /// `ContextDescriptorKind` is the low 5 bits of `Flags`; the common type-descriptor prefix is
    /// `Flags(u32) Parent(i32) Name(i32) AccessFunction(i32) Fields(i32)`.
    private enum Offset {
        static let parent = 4      // RelativeIndirectablePointer<ContextDescriptor>
        static let name = 8        // RelativeDirectPointer<CChar> to the type name
        static let fields = 16     // RelativeDirectPointer<FieldDescriptor> (0 if none)
        static let superclass = 20   // class descriptors only: RelativeDirectPointer<char> mangled name
        static let fieldRecordSize = 12
        static let fieldDescNumFields = 12
        static let fieldDescHeader = 16
        static let recordMangledType = 4
        static let recordFieldName = 8
    }

    enum ContextKind: UInt32 {
        case module = 0
        case opaque = 4
        case `protocol` = 3
        case `class` = 16
        case `struct` = 17
        case `enum` = 18

        init?(flags: UInt32) {
            self.init(rawValue: flags & 0x1f)
        }

        var mangledKind: UInt8? {
            switch self {
            case .class: return UInt8(ascii: "C")
            case .struct: return UInt8(ascii: "V")
            case .enum: return UInt8(ascii: "O")
            case .protocol: return UInt8(ascii: "P")
            case .module, .opaque: return nil
            }
        }
    }

    private struct DescriptorPath {
        struct Component {
            var name: String
            var kind: UInt8
        }

        var module: String
        var components: [Component]

        var mangledType: String {
            var bytes: [UInt8] = []
            Self.appendMangledIdentifier(module, to: &bytes)
            for component in components {
                Self.appendMangledIdentifier(component.name, to: &bytes)
                bytes.append(component.kind)
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        var unqualifiedName: String {
            components.map(\.name).joined(separator: ".")
        }

        private static func appendMangledIdentifier(_ identifier: String, to bytes: inout [UInt8]) {
            bytes.append(contentsOf: Array(String(identifier.utf8.count).utf8))
            bytes.append(contentsOf: Array(identifier.utf8))
        }
    }

    private struct SplicedFieldMangling {
        var mangled: String
        var modules: Set<String>
        var allowedLocalQualifiedNames: Set<String>
    }

    /// What a symbolic reference points at: a mangled nominal type (module + path, with kind letters)
    /// plus the module and dotted path the demangler will print for it.
    private struct SymbolicTarget {
        var mangled: String
        var module: String
        var unqualifiedName: String
    }

    func parseTypes() -> [SwiftTypeDescriptor] {
        parseTypesReport().types
    }

    /// `parseTypes()` plus the graded failures met on the way (see `MetadataParseDiagnostic`):
    /// an unreadable type descriptor abandons the rest of `__swift5_types`; an unreadable name
    /// or field record skips that one item; an unmodelled descriptor kind is kept with a label;
    /// a context-parent walk that hits the cap or a cycle stops and says so.
    func parseTypesReport() -> (types: [SwiftTypeDescriptor], diagnostics: [MetadataParseDiagnostic]) {
        guard let typesSection = sections.first(where: { $0.name == "__swift5_types" }) else { return ([], []) }
        let count = min(Int(typesSection.size / 4), Limits.maxTypes)
        var result: [SwiftTypeDescriptor] = []
        var diagnostics: [MetadataParseDiagnostic] = []
        for index in 0..<count {
            let entryVA = typesSection.address &+ UInt64(index * 4)
            guard let descriptorVA = resolveRelativePointer(at: entryVA) else {
                diagnostics.append(.init(grade: .skippedItem, address: entryVA,
                                         message: "Null or unreadable __swift5_types entry at \(Self.hex(entryVA))"))
                continue
            }
            guard let flags = readU32(atVA: descriptorVA) else {
                diagnostics.append(.init(grade: .abandonedList, address: descriptorVA,
                                         message: "Cannot read Swift type descriptor at \(Self.hex(descriptorVA)); "
                                             + "abandoned the remaining \(count - index) __swift5_types entries"))
                break
            }
            guard let type = parseTypeDescriptor(at: descriptorVA, flags: flags, diagnostics: &diagnostics) else { continue }
            result.append(type)
        }
        return (result, diagnostics)
    }

    private static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

    /// Walks `__swift5_protos` (relative-indirectable pointers) to the in-image protocol descriptors.
    /// An external (bound) or unnameable entry is skipped, never guessed.
    func parseProtocols() -> [SwiftProtocolDescriptor] {
        guard let section = sections.first(where: { $0.name == "__swift5_protos" }) else { return [] }
        let count = min(Int(section.size / 4), Limits.maxTypes)
        var result: [SwiftProtocolDescriptor] = []
        for index in 0..<count {
            let entryVA = section.address &+ UInt64(index * 4)
            guard let descriptorVA = resolveRelativeIndirectablePointer(at: entryVA),
                  let flags = readU32(atVA: descriptorVA), ContextKind(flags: flags) == .protocol,
                  let name = descriptorName(at: descriptorVA) else { continue }
            result.append(SwiftProtocolDescriptor(name: name, descriptorAddress: descriptorVA))
        }
        return result
    }

    /// 64-bit `ProtocolConformanceDescriptor` field offsets (protocol@0, typeRef@4, witness@8,
    /// flags@12). The trailing context/conditional data is not needed for the (type, protocol) pair.
    private enum ConformanceOffset {
        static let protocolField: UInt64 = 0
        static let typeRef: UInt64 = 4
        static let flags: UInt64 = 12
    }

    /// Walks `__swift5_proto` → `ProtocolConformanceDescriptor`, recovering `(conforming type,
    /// protocol)` pairs. Tier-1: a conformance is surfaced only when BOTH names resolve in-image —
    /// an external (bound) protocol or an unhandled type-reference kind is skipped, never guessed.
    func parseConformances() -> [SwiftConformance] {
        parseConformancesReport().conformances
    }

    /// `parseConformances()` plus graded failures: an unreadable conformance descriptor abandons
    /// the rest of `__swift5_proto`; an unnameable (external or unhandled) one is skipped as before.
    func parseConformancesReport() -> (conformances: [SwiftConformance], diagnostics: [MetadataParseDiagnostic]) {
        guard let section = sections.first(where: { $0.name == "__swift5_proto" }) else { return ([], []) }
        let count = min(Int(section.size / 4), Limits.maxTypes)
        var result: [SwiftConformance] = []
        var diagnostics: [MetadataParseDiagnostic] = []
        for index in 0..<count {
            let entryVA = section.address &+ UInt64(index * 4)
            guard let descriptorVA = resolveRelativePointer(at: entryVA) else { continue }
            guard readU32(atVA: descriptorVA &+ ConformanceOffset.flags) != nil else {
                diagnostics.append(.init(grade: .abandonedList, address: descriptorVA,
                                         message: "Cannot read protocol conformance descriptor at \(Self.hex(descriptorVA)); "
                                             + "abandoned the remaining \(count - index) __swift5_proto entries"))
                break
            }
            guard let conformance = parseConformance(at: descriptorVA) else { continue }
            result.append(conformance)
        }
        return (result, diagnostics)
    }

    private func parseConformance(at descriptorVA: UInt64) -> SwiftConformance? {
        guard let flags = readU32(atVA: descriptorVA &+ ConformanceOffset.flags),
              let typeName = conformingTypeName(descriptorVA: descriptorVA, flags: flags),
              let protocolName = conformanceProtocolName(descriptorVA: descriptorVA) else { return nil }
        let typeRef = resolveRelativePointer(at: descriptorVA &+ ConformanceOffset.typeRef)
        let typeDescriptor: UInt64?
        switch (flags >> 3) & 0x7 {
        case 0: typeDescriptor = typeRef
        case 1: typeDescriptor = typeRef.flatMap { bindNames[$0] == nil ? rebaseTargets[$0] : nil }
        default: typeDescriptor = nil
        }
        return SwiftConformance(typeName: typeName, protocolName: protocolName,
                                descriptorAddress: descriptorVA, typeDescriptorAddress: typeDescriptor,
                                methods: methodLinks.conformances[descriptorVA],
                                typeQualifiedName: conformingTypeQualifiedName(descriptorVA: descriptorVA, flags: flags),
                                protocolQualifiedName: conformanceProtocolQualifiedName(descriptorVA: descriptorVA))
    }

    /// The conforming type, from `typeRef`@4 interpreted by the `TypeReferenceKind` in `flags`
    /// (bits 3–5). Kind 0 = a direct relative pointer to the type's nominal context descriptor;
    /// kind 1 = the same via a GOT slot (rebase-resolved); kind 2 = a direct ObjC class-name string.
    /// Indirect-ObjC (3) and any other kind are not resolved this tier.
    private func conformingTypeName(descriptorVA: UInt64, flags: UInt32) -> String? {
        let typeRefFieldVA = descriptorVA &+ ConformanceOffset.typeRef
        switch (flags >> 3) & 0x7 {
        case 0:
            return resolveRelativePointer(at: typeRefFieldVA).flatMap { nominalName(atDescriptor: $0) }
        case 1:
            guard let gotVA = resolveRelativePointer(at: typeRefFieldVA) else { return nil }
            if let inImage = rebaseTargets[gotVA] { return nominalName(atDescriptor: inImage) }
            if let bound = bindNames[gotVA] { return nominalName(fromBoundSymbol: bound, suffix: "Mn") }
            return nil
        case 2:
            return resolveRelativePointer(at: typeRefFieldVA).flatMap { readCString(atVA: $0) }
                .flatMap { $0.isEmpty ? nil : $0 }
        default:
            return nil
        }
    }

    /// The conformed-to protocol name. `protocol`@0 is a `RelativeIndirectablePointer`: the low bit
    /// marks indirection (the target is a GOT slot holding the real pointer). A direct target is the
    /// in-image `ProtocolDescriptor`; an indirect target resolves through a rebase to an in-image
    /// descriptor. A bound (external) protocol has no in-image descriptor here → nil (Tier-2).
    private func conformanceProtocolName(descriptorVA: UInt64) -> String? {
        let fieldVA = descriptorVA &+ ConformanceOffset.protocolField
        guard let raw = readI32(atVA: fieldVA), raw != 0 else { return nil }
        let targetVA = UInt64(bitPattern: Int64(bitPattern: fieldVA) &+ Int64(raw & ~1))
        guard raw & 1 == 1 else { return nominalName(atDescriptor: targetVA) }
        // Indirect: targetVA is a GOT slot — in-image → rebase to the ProtocolDescriptor; EXTERNAL →
        // a bind to the protocol's `…Mp` symbol (Tier-2, e.g. `_$sSQMp` = Swift.Equatable).
        if let inImage = rebaseTargets[targetVA] { return nominalName(atDescriptor: inImage) }
        if let bound = bindNames[targetVA] { return nominalName(fromBoundSymbol: bound, suffix: "Mp") }
        return nil
    }

    private func conformingTypeQualifiedName(descriptorVA: UInt64, flags: UInt32) -> String? {
        let typeRefFieldVA = descriptorVA &+ ConformanceOffset.typeRef
        switch (flags >> 3) & 0x7 {
        case 0:
            return resolveRelativePointer(at: typeRefFieldVA).flatMap { qualifiedName(atDescriptor: $0) }
        case 1:
            guard let gotVA = resolveRelativePointer(at: typeRefFieldVA) else { return nil }
            if let inImage = rebaseTargets[gotVA] { return qualifiedName(atDescriptor: inImage) }
            return bindNames[gotVA].flatMap { Self._qualifiedBoundSymbolName($0, suffix: "Mn") }
        default:
            return nil
        }
    }

    private func conformanceProtocolQualifiedName(descriptorVA: UInt64) -> String? {
        let fieldVA = descriptorVA &+ ConformanceOffset.protocolField
        guard let raw = readI32(atVA: fieldVA), raw != 0 else { return nil }
        let targetVA = UInt64(bitPattern: Int64(bitPattern: fieldVA) &+ Int64(raw & ~1))
        guard raw & 1 == 1 else { return qualifiedName(atDescriptor: targetVA) }
        if let inImage = rebaseTargets[targetVA] { return qualifiedName(atDescriptor: inImage) }
        return bindNames[targetVA].flatMap { Self._qualifiedBoundSymbolName($0, suffix: "Mp") }
    }

    /// `Module.Outer.Inner` for a context descriptor, walking leaf → parent → … → module. Anonymous
    /// contexts add nothing; an extension contributes the type it extends (a local descriptor, or an
    /// unmangled stdlib substitution), else a `<ext:mangled>` marker. A parent bound to an external
    /// symbol is named from that symbol. nil if no module is reached, never a guessed one.
    func qualifiedName(atDescriptor descriptorVA: UInt64, depth: Int = 0) -> String? {
        guard depth <= 4 else { return nil }
        var parts: [String] = []   // leaf first
        var currentVA = descriptorVA
        var visited: Set<UInt64> = []
        func joined(_ prefix: String) -> String { ([prefix] + parts.reversed()).joined(separator: ".") }
        for _ in 0..<Limits.maxParentWalk {
            guard visited.insert(currentVA).inserted, let flags = readU32(atVA: currentVA) else { return nil }
            switch flags & 0x1f {
            case 0:
                return descriptorName(at: currentVA).map(joined)
            case 1:
                guard let extended = extendedTypeQualifiedName(ofExtension: currentVA, depth: depth) else {
                    guard let marker = extensionMarker(ofExtension: currentVA) else { return nil }
                    parts.append(marker)
                    break
                }
                return joined(extended)
            case 2:
                break
            case 3, 16, 17, 18:
                guard let name = descriptorName(at: currentVA) else { return nil }
                parts.append(name)
            default:
                return nil
            }
            let parentField = currentVA &+ UInt64(Offset.parent)
            guard let raw = readI32(atVA: parentField), raw != 0 else { return nil }
            let target = UInt64(bitPattern: Int64(bitPattern: parentField) &+ Int64(raw & ~1))
            if raw & 1 == 0 { currentVA = target; continue }
            if let inImage = rebaseTargets[target] { currentVA = inImage; continue }
            guard let bound = bindNames[target] else { return nil }
            let external = Self._qualifiedBoundSymbolName(bound, suffix: "Mn")
                ?? Self._qualifiedBoundSymbolName(bound, suffix: "Mm")
            return external.map(joined)
        }
        return nil
    }

    /// An extension descriptor's name field (+8) is the mangled extended type. Only an exact
    /// symbolic reference to a local nominal, or a whole-string stdlib substitution, is named.
    private func extendedTypeQualifiedName(ofExtension descriptorVA: UInt64, depth: Int) -> String? {
        guard let mangledVA = resolveRelativePointer(at: descriptorVA &+ UInt64(Offset.name)),
              let raw = readMangledBytes(atVA: mangledVA, requiresTerminator: true), let control = raw.first else { return nil }
        if control == 0x01, raw.count >= 5 {
            let refField = mangledVA &+ 1
            guard let rel = readI32(atVA: refField) else { return nil }
            let target = UInt64(bitPattern: Int64(bitPattern: refField) &+ Int64(rel))
            return qualifiedName(atDescriptor: target, depth: depth + 1)
        }
        if control == 0x02, raw.count >= 5 {
            let refField = mangledVA &+ 1
            guard let rel = readI32(atVA: refField) else { return nil }
            let slot = UInt64(bitPattern: Int64(bitPattern: refField) &+ Int64(rel))
            if let inImage = rebaseTargets[slot] { return qualifiedName(atDescriptor: inImage, depth: depth + 1) }
            return bindNames[slot].flatMap { Self._qualifiedBoundSymbolName($0, suffix: "Mn") }
        }
        guard raw.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        let text = String(decoding: raw, as: UTF8.self)
        return Self.standardMetadataSubstitution(text, suffix: "Mn").map { "Swift." + $0 }
    }

    private func extensionMarker(ofExtension descriptorVA: UInt64) -> String? {
        guard let mangledVA = resolveRelativePointer(at: descriptorVA &+ UInt64(Offset.name)),
              let raw = readMangledBytes(atVA: mangledVA, requiresTerminator: true) else { return nil }
        return "<ext:\(sanitizedMangled(raw))>"
    }

    /// `Module.Name` for an EXTERNAL descriptor symbol, only when the whole symbol body parses as
    /// `<len><module><len><name>…` (optionally `s` for Swift, kind letters between) or is a known
    /// stdlib substitution (→ `Swift.<name>`). Anything else is nil: the module is never guessed.
    static func _qualifiedBoundSymbolName(_ symbol: String, suffix: String) -> String? {
        var s = symbol
        if s.hasPrefix("_") { s.removeFirst() }
        guard !suffix.isEmpty, s.hasPrefix("$s"), s.hasSuffix(suffix), s.count > 2 + suffix.count else { return nil }
        let body = Array(s.dropFirst(2).dropLast(suffix.count))
        if let simple = standardMetadataSubstitution(String(body), suffix: suffix) { return "Swift." + simple }
        var identifiers: [String] = []
        var words: [String] = []
        var i = 0
        if body.first == "s", body.count > 1, body[1].isNumber { identifiers.append("Swift"); i = 1 }
        while i < body.count {
            guard let identifier = decodeManglingIdentifier(body, index: &i, words: &words) else { return nil }
            identifiers.append(identifier)
            if i < body.count, "CVOP".contains(body[i]) { i += 1 }
        }
        return identifiers.count >= 2 || (suffix == "Mm" && identifiers.count == 1) ? identifiers.joined(separator: ".") : nil
    }

    /// A context descriptor's name is a relative direct pointer at `Offset.name` (+8) — shared by
    /// nominal type descriptors and protocol descriptors (both are `ContextDescriptor`s).
    private func nominalName(atDescriptor descriptorVA: UInt64) -> String? {
        guard let nameVA = resolveRelativePointer(at: descriptorVA &+ UInt64(Offset.name)),
              let name = readCString(atVA: nameVA), !name.isEmpty else { return nil }
        return name
    }

    /// Extracts the simple nominal name from an EXTERNAL Swift metadata-descriptor symbol
    /// `_$s<X><suffix>` (suffix `Mp` = protocol descriptor, `Mn` = nominal type descriptor): a known
    /// standard-library substitution (e.g. `SQ` → Equatable), else the last length-prefixed identifier
    /// in `<X>` (e.g. `s23CustomStringConvertible` → CustomStringConvertible, `8MyMod8MyProto` →
    /// MyProto). nil when it can't be parsed confidently — never a fabricated name.
    private func nominalName(fromBoundSymbol symbol: String, suffix: String) -> String? {
        Self._extractBoundSymbolName(symbol, suffix: suffix)
    }

    static func _extractBoundSymbolName(_ symbol: String, suffix: String) -> String? {
        var s = symbol
        if s.hasPrefix("_") { s.removeFirst() }
        guard !suffix.isEmpty,
              s.hasPrefix("$s"), s.hasSuffix(suffix), s.count > 2 + suffix.count else { return nil }
        let body = String(s.dropFirst(2).dropLast(suffix.count))
        return Self.standardMetadataSubstitution(body, suffix: suffix) ?? Self.lastManglingIdentifier(in: body)
    }

    /// Two-character standard-library metadata substitutions, derived from `xcrun swift-demangle`.
    /// The tables are suffix-keyed: protocol descriptors (`Mp`) and nominal type descriptors (`Mn`)
    /// accept different `S?` code sets, and an unverified form stays nil rather than fabricating.
    private static func standardMetadataSubstitution(_ body: String, suffix: String) -> String? {
        switch suffix {
        case "Mp":
            switch body {
            case "Se": return "Decodable"
            case "Sj": return "Numeric"
            case "Sk": return "RandomAccessCollection"
            case "Sl": return "Collection"
            case "Sm": return "RangeReplaceableCollection"
            case "St": return "IteratorProtocol"
            case "Sx": return "Strideable"
            case "Sy": return "StringProtocol"
            case "Sz": return "BinaryInteger"
            case "SB": return "BinaryFloatingPoint"
            case "SE": return "Encodable"
            case "SF": return "FloatingPoint"
            case "SG": return "RandomNumberGenerator"
            case "SH": return "Hashable"
            case "SK": return "BidirectionalCollection"
            case "SL": return "Comparable"
            case "SM": return "MutableCollection"
            case "SQ": return "Equatable"
            case "ST": return "Sequence"
            case "SU": return "UnsignedInteger"
            case "SX": return "RangeExpression"
            case "SY": return "RawRepresentable"
            case "SZ": return "SignedInteger"
            default: return nil
            }
        case "Mn":
            switch body {
            case "Sa": return "Array"
            case "Sb": return "Bool"
            case "Sd": return "Double"
            case "Sf": return "Float"
            case "Sh": return "Set"
            case "Si": return "Int"
            case "Sn": return "Range"
            case "Sp": return "UnsafeMutablePointer"
            case "Sq": return "Optional"
            case "Sr": return "UnsafeMutableBufferPointer"
            case "Ss": return "Substring"
            case "Su": return "UInt"
            case "Sv": return "UnsafeMutableRawPointer"
            case "Sw": return "UnsafeMutableRawBufferPointer"
            case "SA": return "AutoreleasingUnsafeMutablePointer"
            case "SD": return "Dictionary"
            case "SI": return "DefaultIndices"
            case "SJ": return "Character"
            case "SN": return "ClosedRange"
            case "SO": return "ObjectIdentifier"
            case "SP": return "UnsafePointer"
            case "SR": return "UnsafeBufferPointer"
            case "SS": return "String"
            case "SV": return "UnsafeRawPointer"
            case "SW": return "UnsafeRawBufferPointer"
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Parses a mangled nominal `<module><name>` (length-prefixed `<len><identifier>` runs, with an
    /// optional single-char module substitution like `s` for the Swift stdlib) and returns the LAST
    /// identifier. A bare protocol/type descriptor mangling carries no generic suffix, so the final
    /// length-prefixed run is the name.
    private static func lastManglingIdentifier(in mangled: String) -> String? {
        let chars = Array(mangled)
        var i = 0
        var words: [String] = []
        var last: String?
        var firstIdentifier: String?
        var identifierEnd = 0
        while i < chars.count {
            // Local declaration contexts have a rendered signature, not a simple dotted path.
            if chars[i] == "L", i + 1 < chars.count, chars[i + 1] == "_" { return nil }
            guard chars[i].isASCII && chars[i].isNumber else { i += 1; continue }
            guard let identifier = decodeManglingIdentifier(chars, index: &i, words: &words) else { return nil }
            if firstIdentifier == nil { firstIdentifier = identifier }
            last = identifier
            identifierEnd = i
        }
        // A discriminator or an unparsed function/generic trailer is not a nominal name.
        let trailer = String(chars[identifierEnd...])
        // AA refers to the first identifier; retain this existing simple-name case.
        if chars.first?.isASCII == true, chars.first?.isNumber == true,
           ["AAC", "AAV", "AAO"].contains(String(trailer.suffix(3))),
           ["", "LLC", "LLV", "LLO"].contains(String(trailer.dropLast(3))) {
            return firstIdentifier
        }
        guard ["", "C", "V", "O", "P", "a"].contains(trailer) else { return nil }
        return last
    }

    /// Decode one ASCII identifier; its word table belongs to the entire symbol.
    /// Swift ABI Mangling.rst, Identifiers; Demangler.cpp, demangleIdentifier().
    /// Punycode and general substitutions remain unsupported here.
    private static func decodeManglingIdentifier(_ chars: [Character], index: inout Int,
                                                 words: inout [String]) -> String? {
        func ascii(_ c: Character) -> UInt8? { c.asciiValue }
        func digit(_ c: Character) -> Bool { ascii(c).map { (48...57).contains($0) } ?? false }
        func lower(_ c: Character) -> Bool { ascii(c).map { (97...122).contains($0) } ?? false }
        func upper(_ c: Character) -> Bool { ascii(c).map { (65...90).contains($0) } ?? false }
        guard index < chars.count, digit(chars[index]) else { return nil }
        var compressed = chars[index] == "0"
        if compressed {
            index += 1
            guard index < chars.count, chars[index] != "0" else { return nil }
        }
        var result = ""
        repeat {
            while compressed && index < chars.count && (lower(chars[index]) || upper(chars[index])) {
                let marker = chars[index]
                let wordIndex = Int(ascii(marker)!) - (lower(marker) ? 97 : 65)
                guard wordIndex < words.count else { return nil }
                result += words[wordIndex]
                index += 1
                if upper(marker) { compressed = false }
            }
            if index < chars.count, chars[index] == "0" {
                index += 1
                break
            }
            var length = 0
            var hasDigits = false
            while index < chars.count, digit(chars[index]) {
                let value = Int(ascii(chars[index])! - 48)
                guard length <= (Int.max - value) / 10 else { return nil }
                length = length * 10 + value
                hasDigits = true
                index += 1
            }
            guard hasDigits, length > 0, length <= chars.count - index else { return nil }
            let literal = Array(chars[index..<(index + length)])
            // Non-ASCII identifiers require the separate Punycode production.
            guard literal.allSatisfy({ $0.isASCII }) else { return nil }
            result += String(literal)
            var start: Int?
            for offset in 0...literal.count {
                let current: Character = offset < literal.count ? literal[offset] : "\0"
                if let begin = start,
                   current == "\0" || current == "_" || (upper(current) && !upper(literal[offset - 1])) {
                    if offset - begin >= 2, words.count < 26 {
                        words.append(String(literal[begin..<offset]))
                    }
                    start = nil
                }
                if start == nil, !digit(current), current != "_", current != "\0" { start = offset }
            }
            index += length
        } while compressed
        return result.isEmpty ? nil : result
    }

    private func parseTypeDescriptor(at descriptorVA: UInt64,
                                     flags: UInt32,
                                     diagnostics: inout [MetadataParseDiagnostic]) -> SwiftTypeDescriptor? {
        guard let nameVA = resolveRelativePointer(at: descriptorVA &+ UInt64(Offset.name)),
              let name = readCString(atVA: nameVA), !name.isEmpty else {
            diagnostics.append(.init(grade: .skippedItem, address: descriptorVA,
                                     message: "Cannot read the name of the Swift type descriptor at \(Self.hex(descriptorVA))"))
            return nil
        }
        guard let kind = SwiftTypeKind(contextDescriptorKind: flags) else {
            // Unmodelled kind: keep the type, labelled, with no fields — the field-descriptor
            // offset is only known for the modelled class/struct/enum layouts.
            let rawKind = flags & 0x1f
            diagnostics.append(.init(grade: .labelledUnknownKind, address: descriptorVA,
                                     message: "Unknown type kind \(rawKind) at \(Self.hex(descriptorVA))"))
            return SwiftTypeDescriptor(kind: .unknown, name: name, rawKind: rawKind, descriptorAddress: descriptorVA)
        }

        var fields: [SwiftField] = []
        if let fieldDescVA = resolveRelativePointer(at: descriptorVA &+ UInt64(Offset.fields)) {
            fields = parseFieldDescriptor(at: fieldDescVA, diagnostics: &diagnostics)
        }
        // Struct vectors contain uint32 offsets, indexed by a pointer-sized word offset.
        // Generic and singleton/foreign-initialized metadata are incomplete until runtime.
        if kind == .struct, flags & 0x80 == 0, (flags >> 16) & 3 == 0,
           descriptorVA <= UInt64.max - 28,
           let count = readU32(atVA: descriptorVA + 20), Int(count) == fields.count,
           let words = readU32(atVA: descriptorVA + 24), words >= 2,
           let metadata = metadataByDescriptor[descriptorVA] {
            let (vector, overflow) = metadata.addingReportingOverflow(UInt64(words) * 8)
            if !overflow {
                for index in fields.indices {
                    let (slot, overflow) = vector.addingReportingOverflow(UInt64(index) * 4)
                    if !overflow { fields[index].byteOffset = readU32(atVA: slot).map(UInt64.init) }
                }
            }
        }
        let context = parentChainFacts(of: descriptorVA)
        // ClassDescriptor.SuperclassType@20 follows the 20-byte TypeContextDescriptor prefix (Metadata.h);
        // null for a root class. Keep unresolved manglings as diagnostics with their reason.
        var superclass: String?
        var superclassUnresolvedReason: String?
        if kind == .class,
           let superclassVA = resolveRelativePointer(at: descriptorVA &+ UInt64(Offset.superclass)) {
            let decoded = decodeFieldType(at: superclassVA, diagnostics: &diagnostics)
            superclass = decoded.typeName ?? decoded.mangled
            superclassUnresolvedReason = decoded.typeName == nil ? (decoded.reason ?? "unreadableType") : nil
        }
        return SwiftTypeDescriptor(kind: kind, name: name, fields: fields, descriptorAddress: descriptorVA,
                                   methods: methodLinks.types[descriptorVA],
                                   qualifiedName: qualifiedName(atDescriptor: descriptorVA), superclass: superclass,
                                   superclassUnresolvedReason: superclassUnresolvedReason,
                                   isGeneric: flags & 0x80 != 0, isPrivateOrLocal: context.hasAnonymous,
                                   isImportedCType: context.module == "__C")
    }

    /// Walks leaf → parent → … → module once: whether an anonymous context (kind 2) sits in the chain,
    /// and the root module's name. Bounded and cycle-safe like `descriptorPath`; an unresolvable parent
    /// (external or unreadable) ends the walk with whatever was seen, and `module` stays nil.
    private func parentChainFacts(of descriptorVA: UInt64) -> (hasAnonymous: Bool, module: String?) {
        var current = descriptorVA
        var visited: Set<UInt64> = [descriptorVA]
        var hasAnonymous = false
        for _ in 0..<Limits.maxParentWalk {
            guard let parent = resolveRelativeIndirectablePointer(at: current &+ UInt64(Offset.parent)),
                  visited.insert(parent).inserted, let flags = readU32(atVA: parent) else { break }
            switch flags & 0x1f {
            case ContextKind.module.rawValue: return (hasAnonymous, descriptorName(at: parent))
            case 2: hasAnonymous = true
            default: break
            }
            current = parent
        }
        return (hasAnonymous, nil)
    }

    private func parseFieldDescriptor(at fieldDescVA: UInt64,
                                      diagnostics: inout [MetadataParseDiagnostic]) -> [SwiftField] {
        guard let recordSize = readU16(atVA: fieldDescVA &+ 10),
              Int(recordSize) == Offset.fieldRecordSize,   // bail on an unexpected record stride
              let numFields = readU32(atVA: fieldDescVA &+ UInt64(Offset.fieldDescNumFields)) else { return [] }
        let recordCount = min(Int(numFields), Limits.maxFieldsPerType)

        var fields: [SwiftField] = []
        fields.reserveCapacity(recordCount)
        for record in 0..<recordCount {
            let recordVA = fieldDescVA &+ UInt64(Offset.fieldDescHeader + record * Offset.fieldRecordSize)
            guard let recordFlags = readU32(atVA: recordVA) else {
                // Past the mapped end: every later record is unreadable too, so stop here.
                diagnostics.append(.init(grade: .skippedItem, address: recordVA,
                                         message: "Cannot read field records from \(Self.hex(recordVA)) "
                                             + "(\(recordCount - record) of \(recordCount) skipped)"))
                break
            }
            let nameVA = resolveRelativePointer(at: recordVA &+ UInt64(Offset.recordFieldName))
            guard let fieldName = nameVA.flatMap({ readCString(atVA: $0) }), !fieldName.isEmpty else {
                diagnostics.append(.init(grade: .skippedItem, address: recordVA,
                                         message: "Cannot read field record at \(Self.hex(recordVA))"))
                continue
            }

            let mangledVA = resolveRelativePointer(at: recordVA &+ UInt64(Offset.recordMangledType))
            let decoded = decodeFieldType(at: mangledVA, diagnostics: &diagnostics)
            // FieldRecordFlags: IsIndirectCase = 0x1, IsVar = 0x2.
            let isIndirectCase = (recordFlags & 0x1) != 0
            let isVar = (recordFlags & 0x2) != 0
            fields.append(SwiftField(name: fieldName,
                                     typeName: decoded.typeName,
                                     mangledTypeName: decoded.mangled,
                                     isVar: isVar,
                                     isIndirectCase: isIndirectCase,
                                     unresolvedReason: decoded.typeName == nil && decoded.mangled != nil ? decoded.reason : nil))
        }
        return fields
    }

    // MARK: - Field-type decoding (best effort, never fabricated)

    func decodeFieldType(at mangledVA: UInt64?,
                                 diagnostics: inout [MetadataParseDiagnostic]) -> (typeName: String?, mangled: String?, reason: String?) {
        guard let mangledVA, let raw = readMangledBytes(atVA: mangledVA), !raw.isEmpty else {
            return (nil, nil, nil)
        }
        if raw.contains(where: { Self.symbolicReferencePayloadWidth($0) != nil }) {
            var reason = "unnameableShape"
            let resolved = splicedFieldMangling(from: raw, baseVA: mangledVA, reason: &reason, diagnostics: &diagnostics).flatMap { spliced -> String? in
                guard let demangled = SwiftDemangler.demangleType(spliced.mangled) else { return nil }
                return Self.fieldTypeName(fromDemangled: demangled,
                                          modules: spliced.modules,
                                          allowedLocalQualifiedNames: spliced.allowedLocalQualifiedNames)
            }
            let printable = sanitizedMangled(raw)
            return (resolved, printable.isEmpty ? nil : printable, resolved == nil ? reason : nil)
        }
        let mangled = String(decoding: raw, as: UTF8.self)
        if let std = standardLibraryType(forMangled: mangled) {
            return (std, mangled, nil)
        }
        // The control-byte guard above means this point is symbolic-reference-free. The demangler
        // route is accepted only when stripping Swift. leaves no foreign-module qualifier.
        if let demangled = SwiftDemangler.demangleType(mangled),
           let stdlib = Self.pureSwiftStdlibName(demangled) {
            return (stdlib, mangled, nil)
        }
        return (nil, mangled, "unnameableShape")
    }

    /// A printable diagnostic form of a mangled type name: each symbolic-reference unit is collapsed
    /// to a single `…` placeholder so
    /// raw little-endian pointer bytes never leak into the string, while the surrounding structural
    /// operators (`Say…G`, `…Sg`, …) are preserved as a hint.
    func sanitizedMangled(_ raw: [UInt8]) -> String {
        var out: [UInt8] = []
        var index = 0
        while index < raw.count {
            let byte = raw[index]
            if let payloadWidth = Self.symbolicReferencePayloadWidth(byte) {
                out.append(contentsOf: Array("…".utf8))
                index += 1 + payloadWidth
            } else {
                out.append(byte)
                index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Rewrites every embedded symbolic reference into the referenced descriptor's textual Swift
    /// mangling. Each descriptor must be in-image and must walk through nominal parents to a module
    /// context; otherwise the field stays unresolved rather than falling back to a leaf name.
    private func splicedFieldMangling(from raw: [UInt8],
                                      baseVA: UInt64,
                                      reason: inout String,
                                      diagnostics: inout [MetadataParseDiagnostic]) -> SplicedFieldMangling? {
        var out: [UInt8] = []
        var index = 0
        var modules: Set<String> = []
        var allowedLocalQualifiedNames: Set<String> = []

        while index < raw.count {
            let byte = raw[index]
            guard let payloadWidth = Self.symbolicReferencePayloadWidth(byte) else {
                out.append(byte)
                index += 1
                continue
            }

            guard payloadWidth == 4, raw[index] == 0x01 || raw[index] == 0x02 else {
                reason = "unsupportedReference"
                return nil
            }
            guard let target = resolveSymbolicReferencePath(in: raw, at: index, baseVA: baseVA,
                                                            reason: &reason, diagnostics: &diagnostics) else {
                return nil
            }
            modules.insert(target.module)
            allowedLocalQualifiedNames.insert(target.unqualifiedName)
            out.append(contentsOf: Array(target.mangled.utf8))
            index += 1 + payloadWidth
        }

        guard !modules.isEmpty else { return nil }
        return SplicedFieldMangling(mangled: String(decoding: out, as: UTF8.self),
                                    modules: modules,
                                    allowedLocalQualifiedNames: allowedLocalQualifiedNames)
    }

    /// Resolves one symbolic reference to the referenced context descriptor path.
    /// `0x01` = direct relative pointer to the context descriptor; `0x02` = indirect (the relative
    /// pointer targets a GOT slot whose chained-fixup REBASE gives the descriptor VA, or whose BIND
    /// names an external descriptor symbol). A slot with neither fixup entry stays `needsFixup`.
    private func resolveSymbolicReferencePath(in raw: [UInt8],
                                              at index: Int,
                                              baseVA: UInt64,
                                              reason: inout String,
                                              diagnostics: inout [MetadataParseDiagnostic]) -> SymbolicTarget? {
        let control = raw[index]
        guard control == 0x01 || control == 0x02, index + 4 < raw.count else {
            reason = "unsupportedReference"
            return nil
        }
        let relOffset = Int(Int32(bitPattern:
            UInt32(raw[index + 1]) | UInt32(raw[index + 2]) << 8
            | UInt32(raw[index + 3]) << 16 | UInt32(raw[index + 4]) << 24))
        let pointerVA = baseVA &+ UInt64(index + 1)
        let targetVA = UInt64(bitPattern: Int64(bitPattern: pointerVA) &+ Int64(relOffset))
        let descriptorVA: UInt64
        if control == 0x01 {
            descriptorVA = targetVA
        } else if let rebased = rebaseTargets[targetVA] {
            descriptorVA = rebased
        } else if let symbol = bindNames[targetVA] {
            if let external = externalTarget(forSymbol: symbol) { return external }
            reason = "unresolvedDescriptor"
            return nil
        } else {
            reason = "needsFixup"
            return nil
        }
        guard let path = descriptorPath(at: descriptorVA, diagnostics: &diagnostics) else {
            reason = "unresolvedDescriptor"
            return nil
        }
        return SymbolicTarget(mangled: path.mangledType, module: path.module, unqualifiedName: path.unqualifiedName)
    }

    /// An external nominal-type or protocol descriptor symbol (`_$s10Foundation3URLVMn`, `$sSQMp`):
    /// An Mn body is a complete type mangling. An Mp body omits the protocol kind letter P,
    /// except for complete stdlib substitutions. Restore it before demangling and splicing.
    private func externalTarget(forSymbol symbol: String) -> SymbolicTarget? {
        var name = Substring(symbol)
        if name.hasPrefix("_") { name = name.dropFirst() }
        guard name.hasPrefix("$s"), name.hasSuffix("Mn") || name.hasSuffix("Mp") else { return nil }
        var inner = String(name.dropFirst(2).dropLast(2))
        guard !inner.isEmpty else { return nil }
        if name.hasSuffix("Mp") {
            // Second-level standard protocol substitutions are complete protocol types,
            // not context/name bodies needing a trailing P. Swift 6.3:
            // include/swift/Demangling/StandardTypesMangling.def, Protocol entries.
            let concurrencyProtocol: String?
            switch inner {
            case "ScA": concurrencyProtocol = "Actor"
            case "ScF": concurrencyProtocol = "Executor"
            case "Scf": concurrencyProtocol = "SerialExecutor"
            case "Sch": concurrencyProtocol = "TaskExecutor"
            case "ScI": concurrencyProtocol = "AsyncIteratorProtocol"
            case "Sci": concurrencyProtocol = "AsyncSequence"
            default: concurrencyProtocol = nil
            }
            if let concurrencyProtocol {
                // The field consumer reparses this type. Use the equivalent explicit
                // Swift protocol spelling, including for substitutions it cannot decode.
                let mangled = "s\(concurrencyProtocol.utf8.count)\(concurrencyProtocol)P"
                return SymbolicTarget(mangled: mangled, module: "Swift",
                                      unqualifiedName: concurrencyProtocol)
            }
            if Self.standardMetadataSubstitution(inner, suffix: "Mp") == nil {
                inner += "P"
            }
        }
        guard !inner.utf8.contains(where: { $0 < 0x20 }),
              let demangled = SwiftDemangler.demangleType(inner),
              let dot = demangled.firstIndex(of: "."), dot != demangled.startIndex,
              !demangled.contains(where: { "<>()[]?, ".contains($0) }) else { return nil }
        return SymbolicTarget(mangled: inner,
                              module: String(demangled[..<dot]),
                              unqualifiedName: String(demangled[demangled.index(after: dot)...]))
    }

    /// Walks leaf → parent → … → module. Bounded by `Limits.maxParentWalk` and a visited set:
    /// a cycle or an over-long chain stops the walk with a `walkCapped` diagnostic and yields nil
    /// (the field stays unresolved) instead of looping or guessing a partial path.
    private func descriptorPath(at descriptorVA: UInt64,
                                diagnostics: inout [MetadataParseDiagnostic]) -> DescriptorPath? {
        guard let flags = readU32(atVA: descriptorVA),
              let leafKind = ContextKind(flags: flags),
              let leafMangledKind = leafKind.mangledKind,
              let leafName = descriptorName(at: descriptorVA) else { return nil }

        var components = [DescriptorPath.Component(name: leafName, kind: leafMangledKind)]
        var currentVA = descriptorVA
        var visited: Set<UInt64> = [descriptorVA]

        for _ in 0..<Limits.maxParentWalk {
            guard let parentVA = resolveRelativeIndirectablePointer(at: currentVA &+ UInt64(Offset.parent)) else { return nil }
            guard !visited.contains(parentVA) else {
                diagnostics.append(.init(grade: .walkCapped, address: parentVA,
                                         message: "Context-parent cycle at \(Self.hex(parentVA)); "
                                             + "stopped walking from \(Self.hex(descriptorVA))"))
                return nil
            }
            guard let parentFlags = readU32(atVA: parentVA),
                  let parentKind = ContextKind(flags: parentFlags) else { return nil }
            visited.insert(parentVA)

            if parentKind == .module {
                guard let moduleName = descriptorName(at: parentVA) else { return nil }
                return DescriptorPath(module: moduleName, components: Array(components.reversed()))
            }

            guard let parentMangledKind = parentKind.mangledKind,
                  let parentName = descriptorName(at: parentVA) else { return nil }
            components.append(DescriptorPath.Component(name: parentName, kind: parentMangledKind))
            currentVA = parentVA
        }

        diagnostics.append(.init(grade: .walkCapped, address: currentVA,
                                 message: "Way too many parents (> \(Limits.maxParentWalk)), stopping at \(Self.hex(currentVA))"))
        return nil
    }

    func descriptorName(at descriptorVA: UInt64) -> String? {
        guard let nameVA = resolveRelativePointer(at: descriptorVA &+ UInt64(Offset.name)),
              let name = readCString(atVA: nameVA), !name.isEmpty else { return nil }
        return name
    }

    func resolveRelativeIndirectablePointer(at fieldVA: UInt64) -> UInt64? {
        guard let raw = readI32(atVA: fieldVA), raw != 0 else { return nil }
        let targetVA = UInt64(bitPattern: Int64(bitPattern: fieldVA) &+ Int64(raw & ~1))
        guard raw & 1 == 1 else { return targetVA }
        return rebaseTargets[targetVA]
    }

    /// The common standard-library substitutions that appear as bare stored-property types. Only an
    /// exact whole-string match decodes; partial/generic manglings (e.g. `SaySiG`) stay `nil`.
    private func standardLibraryType(forMangled mangled: String) -> String? {
        switch mangled {
        case "Si": return "Int"
        case "Su": return "UInt"
        case "Sb": return "Bool"
        case "Sd": return "Double"
        case "Sf": return "Float"
        case "SS": return "String"
        case "Ss": return "Substring"
        default: return nil
        }
    }

    static func pureSwiftStdlibName(_ qualified: String) -> String? {
        let stripped = stripSwiftModuleQualifiers(from: qualified)
        // A residual module qualifier (`__C.`, `Foundation.`, a custom module) → not a nameable
        // stdlib type.
        guard !stripped.contains(".") else { return nil }
        // A bare generic parameter / archetype renders as a lone uppercase letter (`A`, `A?`,
        // `Set<A>`, `[A]`) — it names no concrete type, so it must NOT be fabricated as one.
        guard !containsArchetypeToken(stripped) else { return nil }
        return stripped
    }

    private static func fieldTypeName(fromDemangled qualified: String,
                                      modules: Set<String>,
                                      allowedLocalQualifiedNames: Set<String>) -> String? {
        let stripped = stripModuleQualifiers(from: qualified, modules: modules.union(["Swift"]))
        guard !containsArchetypeToken(stripped),
              !containsDisallowedQualifiedName(in: stripped,
                                               allowedLocalQualifiedNames: allowedLocalQualifiedNames) else {
            return nil
        }
        return stripped
    }

    /// True if any identifier token in `s` is archetype-shaped — a single uppercase ASCII letter
    /// optionally followed by digits (`A`, `B`, `A1`). Concrete stdlib type names (`Int`, `Set`,
    /// `UInt`, `String`) never match, since after the leading uppercase they carry lowercase letters.
    private static func containsArchetypeToken(_ s: String) -> Bool {
        var token = ""
        func isIdentifierScalar(_ c: Character) -> Bool {
            c == "_" || (c.isASCII && (c.isLetter || c.isNumber))
        }
        func tokenIsArchetype() -> Bool {
            defer { token = "" }
            guard let first = token.first, first.isASCII, first.isUppercase else { return false }
            return token.dropFirst().allSatisfy { $0.isNumber }
        }
        for character in s {
            if isIdentifierScalar(character) {
                token.append(character)
            } else if tokenIsArchetype() {
                return true
            }
        }
        return tokenIsArchetype()
    }

    private static func stripSwiftModuleQualifiers(from qualified: String) -> String {
        stripModuleQualifiers(from: qualified, modules: ["Swift"])
    }

    private static func stripModuleQualifiers(from qualified: String, modules: Set<String>) -> String {
        var result = ""
        var index = qualified.startIndex
        let sortedModules = modules.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        while index < qualified.endIndex {
            var matchedModule = false
            for module in sortedModules {
                let prefix = module + "."
                if qualified[index...].hasPrefix(prefix),
                   (index == qualified.startIndex || !isIdentifierContinuation(qualified[qualified.index(before: index)])) {
                    index = qualified.index(index, offsetBy: prefix.count)
                    matchedModule = true
                    break
                }
            }
            guard !matchedModule else { continue }
            result.append(qualified[index])
            index = qualified.index(after: index)
        }
        return result
    }

    private static func containsDisallowedQualifiedName(in text: String,
                                                        allowedLocalQualifiedNames: Set<String>) -> Bool {
        var index = text.startIndex
        while index < text.endIndex {
            guard isIdentifierContinuation(text[index]) else {
                index = text.index(after: index)
                continue
            }

            var parts: [String] = []
            var cursor = index
            while cursor < text.endIndex {
                let partStart = cursor
                while cursor < text.endIndex, isIdentifierContinuation(text[cursor]) {
                    cursor = text.index(after: cursor)
                }
                parts.append(String(text[partStart..<cursor]))

                guard cursor < text.endIndex,
                      text[cursor] == ".",
                      text.index(after: cursor) < text.endIndex,
                      isIdentifierContinuation(text[text.index(after: cursor)]) else {
                    break
                }
                cursor = text.index(after: cursor)
            }

            if parts.count >= 2,
               !allowedLocalQualifiedNames.contains(parts.joined(separator: ".")) {
                return true
            }
            index = cursor
        }
        return false
    }

    private static func isIdentifierContinuation(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        return scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    static func symbolicReferencePayloadWidth(_ control: UInt8) -> Int? {
        guard control >= 0x01, control <= 0x1f else { return nil }
        return control >= 0x18 ? 8 : 4
    }

    // MARK: - Bounds-checked primitives

    /// File offset for a virtual address, or nil if no mapped section covers it.
    func fileOffset(forVA va: UInt64) -> Int? {
        for section in sections where section.size > 0 {
            if va >= section.address, va < section.address &+ section.size {
                let delta = va - section.address
                let offset = section.fileOffset &+ delta
                guard offset <= UInt64(Int.max) else { return nil }
                return Int(offset)
            }
        }
        return nil
    }

    /// Reads a 32-bit self-relative pointer at `fieldVA`; returns the target VA (`fieldVA + value`)
    /// or nil if the slot is unmapped or the value is 0 (null).
    func resolveRelativePointer(at fieldVA: UInt64) -> UInt64? {
        guard let raw = readI32(atVA: fieldVA), raw != 0 else { return nil }
        return UInt64(bitPattern: Int64(bitPattern: fieldVA) &+ Int64(raw))
    }

    func readU64(atVA va: UInt64) -> UInt64? {
        guard va <= UInt64.max - 4, let low = readU32(atVA: va), let high = readU32(atVA: va + 4) else { return nil }
        return UInt64(low) | UInt64(high) << 32
    }

    func readU32(atVA va: UInt64) -> UInt32? {
        // Subtract, never add: `off + 4` would trap on Int overflow if `off` is near Int.max (a
        // crafted section with a huge `size` can drive fileOffset(forVA:) there). `off < bytes.count`
        // makes `bytes.count - off` a positive in-range value, so the width check cannot overflow.
        guard let off = fileOffset(forVA: va), off >= 0, off < bytes.count, bytes.count - off >= 4 else { return nil }
        return UInt32(bytes[off]) | UInt32(bytes[off + 1]) << 8
            | UInt32(bytes[off + 2]) << 16 | UInt32(bytes[off + 3]) << 24
    }

    func readI32(atVA va: UInt64) -> Int32? {
        readU32(atVA: va).map { Int32(bitPattern: $0) }
    }

    func readU16(atVA va: UInt64) -> UInt16? {
        guard let off = fileOffset(forVA: va), off >= 0, off < bytes.count, bytes.count - off >= 2 else { return nil }
        return UInt16(bytes[off]) | UInt16(bytes[off + 1]) << 8
    }

    func readCString(atVA va: UInt64) -> String? {
        guard let start = fileOffset(forVA: va), start >= 0, start < bytes.count else { return nil }
        var end = start
        let limit = min(bytes.count, start + Limits.maxStringLength)
        while end < limit, bytes[end] != 0 { end += 1 }
        guard end < limit else { return nil }   // unterminated within the cap → reject
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// Reads a (possibly symbolic-reference-bearing) mangled type name: bytes up to NUL, where bytes
    /// 0x01...0x1F are *not* terminators (they introduce symbolic-reference payloads).
    /// Extension names require a terminator; field decoding retains partial bytes for diagnostics.
    func readMangledBytes(atVA va: UInt64, requiresTerminator: Bool = false) -> [UInt8]? {
        guard let start = fileOffset(forVA: va), start >= 0, start < bytes.count else { return nil }
        var cursor = start
        let limit = min(bytes.count, start + Limits.maxStringLength)
        var out: [UInt8] = []
        while cursor < limit {
            let byte = bytes[cursor]
            if byte == 0 { return out }
            out.append(byte)
            // Skip the payload of a symbolic reference so its bytes don't terminate the scan.
            if let payloadWidth = Self.symbolicReferencePayloadWidth(byte) {
                guard cursor + payloadWidth < limit else { return requiresTerminator ? nil : out }
                for offset in 1...payloadWidth { out.append(bytes[cursor + offset]) }
                cursor += 1 + payloadWidth
            } else {
                cursor += 1
            }
        }
        return requiresTerminator ? nil : out
    }
}
