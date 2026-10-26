import Foundation

/// Canonical constructors for `NavigatorSubject.ref` and `NavigatorSubject.image` (contract v1.1
/// proposal, `docs/contracts/navigator-engine/v1/README.md` §8 and `subjectRefGrammar` in
/// `vocabulary.v1.1-proposed.json`).
///
/// Every builder renders one canonical spelling and `parse(_:kind:)` accepts exactly that spelling,
/// so `parse(ref, kind:)?.ref == ref` for every ref a builder returns. A ref that does not match the
/// grammar parses to nil; the parser never guesses or normalises.
///
/// | kind             | grammar                                             |
/// |------------------|-----------------------------------------------------|
/// | `image`          | `<uuid>/<sliceSHA256 prefix 16>` (`nouuid` if none) |
/// | `address`        | `0x<lowercase hex, no leading zeros>`               |
/// | `range`          | `<address>..<<address>`                             |
/// | `function`       | `<address of entry>`                                |
/// | `type`           | `<descriptor address>` or `name:<qualified name>`   |
/// | `protocol`       | `<descriptor address>` or `name:<qualified name>`   |
/// | `metadataRecord` | `<section>@<address>`                               |
/// | `selector`       | `<selector string>`                                 |
/// | `viewBody`       | `<address of body getter>`                          |
/// | `field`          | `<type ref>#<field index>` or `<type ref>.<field name>` |
enum NavigatorSubjectRef {
    /// Subject kinds whose ref may take the `name:<qualified name>` form. The Swift metadata
    /// projection emits it for a conforming type or a protocol whose descriptor is not in the image.
    static let namedKinds = ["type", "protocol"]
    static let namePrefix = "name:"
    /// Image-ref placeholder for a slice without `LC_UUID`.
    static let noUUID = "nouuid"
    /// Number of leading selected-slice SHA-256 hex digits kept in an image ref.
    static let slicePrefixLength = 16
    static let rangeSeparator = "..<"

    /// A ref decomposed by `parse(_:kind:)`. `ref` renders it back to the canonical spelling and
    /// `kind` names the subject kind it was parsed as.
    enum Parsed: Hashable, Sendable {
        case image(uuid: String?, slicePrefix: String)
        case address(UInt64)
        case range(lower: UInt64, upper: UInt64)
        case function(entry: UInt64)
        case type(descriptor: UInt64)
        case protocolDescriptor(UInt64)
        case metadataRecord(section: String, address: UInt64)
        case selector(String)
        case fieldIndex(typeRef: String, index: Int)
        case fieldName(typeRef: String, name: String)
        case viewBody(getter: UInt64)
        case named(kind: String, qualifiedName: String)

        var kind: String {
            switch self {
            case .image: "image"
            case .address: "address"
            case .range: "range"
            case .function: "function"
            case .type: "type"
            case .protocolDescriptor: "protocol"
            case .metadataRecord: "metadataRecord"
            case .selector: "selector"
            case .fieldIndex, .fieldName: "field"
            case .viewBody: "viewBody"
            case .named(let kind, _): kind
            }
        }

        var ref: String {
            switch self {
            case .image(let uuid, let slicePrefix):
                "\(uuid ?? NavigatorSubjectRef.noUUID)/\(slicePrefix)"
            case .address(let va):
                NavigatorSubjectRef.address(va)
            case .range(let lower, let upper):
                NavigatorSubjectRef.address(lower) + NavigatorSubjectRef.rangeSeparator + NavigatorSubjectRef.address(upper)
            case .function(let entry):
                NavigatorSubjectRef.address(entry)
            case .type(let descriptor):
                NavigatorSubjectRef.address(descriptor)
            case .protocolDescriptor(let descriptor):
                NavigatorSubjectRef.address(descriptor)
            case .metadataRecord(let section, let address):
                "\(section)@\(NavigatorSubjectRef.address(address))"
            case .selector(let name):
                name
            case .fieldIndex(let typeRef, let index):
                "\(typeRef)#\(index)"
            case .fieldName(let typeRef, let name):
                "\(typeRef).\(name)"
            case .viewBody(let getter):
                NavigatorSubjectRef.address(getter)
            case .named(_, let qualifiedName):
                NavigatorSubjectRef.namePrefix + qualifiedName
            }
        }
    }

    // MARK: - Builders

    /// `<uuid>/<sliceSHA256 prefix 16>`: the lowercase `LC_UUID` (or `nouuid`) and the first 16 hex
    /// digits of the selected slice's SHA-256, which the identity type already holds in canonical
    /// lowercase form.
    static func imageRef(_ identity: MachOSliceArtifactIdentity) -> String {
        let uuid = identity.uuid.map { $0.uuidString.lowercased() } ?? noUUID
        return "\(uuid)/\(identity.selectedSliceSHA256.prefix(slicePrefixLength))"
    }

    /// `0x` followed by lowercase hexadecimal with no leading zeros (`0x0` for zero).
    static func address(_ va: UInt64) -> String {
        "0x" + String(va, radix: 16, uppercase: false)
    }

    /// Half-open `lo..<hi`; nil when `hi < lo`.
    static func range(_ lo: UInt64, _ hi: UInt64) -> String? {
        guard lo <= hi else { return nil }
        return address(lo) + rangeSeparator + address(hi)
    }

    static func function(entry: UInt64) -> String { address(entry) }

    static func type(descriptor: UInt64) -> String { address(descriptor) }

    static func `protocol`(descriptor: UInt64) -> String { address(descriptor) }

    static func viewBody(getter: UInt64) -> String { address(getter) }

    /// `<section>@<address>`; nil when the section name is empty, contains `@`, or contains a
    /// space or control character.
    static func metadataRecord(section: String, address va: UInt64) -> String? {
        guard isSectionName(section) else { return nil }
        return "\(section)@\(address(va))"
    }

    /// The selector string itself; nil when it is empty or contains whitespace or a control character.
    static func selector(_ name: String) -> String? {
        isSelector(name) ? name : nil
    }

    /// `<type ref>#<field index>`; nil when `typeRef` is not a type ref or `index` is negative.
    static func field(typeRef: String, index: Int) -> String? {
        guard index >= 0, parseTypeRef(typeRef) else { return nil }
        return "\(typeRef)#\(index)"
    }

    /// Legacy `<type ref>.<field name>` form (Swift metadata projection, stored fields and enum cases).
    /// nil when `typeRef` is not a type ref or the name is empty or contains `.`, `#` or a control character.
    static func field(typeRef: String, name: String) -> String? {
        guard parseTypeRef(typeRef), isFieldName(name) else { return nil }
        let ref = "\(typeRef).\(name)"
        guard parse(ref, kind: "field") == .fieldName(typeRef: typeRef, name: name) else { return nil }
        return ref
    }

    /// Legacy `name:<qualified name>` form for a `type` or `protocol` whose descriptor is not in the
    /// image. nil for any other kind, or for an empty name or one with a control character.
    static func named(kind: String, qualifiedName: String) -> String? {
        guard namedKinds.containsExactly(kind), isQualifiedName(qualifiedName) else { return nil }
        let ref = namePrefix + qualifiedName
        guard parse(ref, kind: kind) == .named(kind: kind, qualifiedName: qualifiedName) else { return nil }
        return ref
    }

    /// A subject whose `image` is the image ref of `identity` (nil identity leaves `image` unset).
    static func subject(kind: String, ref: String, identity: MachOSliceArtifactIdentity?) -> NavigatorSubject {
        NavigatorSubject(kind: kind, ref: ref, image: identity.map(imageRef))
    }

    /// The `image`-kind subject of a slice; its ref is the image ref, so it carries no separate `image`.
    static func imageSubject(_ identity: MachOSliceArtifactIdentity) -> NavigatorSubject {
        NavigatorSubject(kind: "image", ref: imageRef(identity))
    }

    // MARK: - Parsing

    /// Decomposes `ref` as a ref of subject kind `kind`; nil when it is not in the canonical grammar.
    static func parse(_ ref: String, kind: String) -> Parsed? {
        switch kind {
        case "image":
            return parseImage(ref)
        case "address":
            return parseAddress(ref).map { .address($0) }
        case "range":
            guard let separator = ref.range(of: rangeSeparator),
                  let lower = parseAddress(String(ref[..<separator.lowerBound])),
                  let upper = parseAddress(String(ref[separator.upperBound...])),
                  lower <= upper else { return nil }
            return .range(lower: lower, upper: upper)
        case "function":
            return parseAddress(ref).map { .function(entry: $0) }
        case "type":
            if let named = parseNamed(ref, kind: kind) { return named }
            return parseAddress(ref).map { .type(descriptor: $0) }
        case "protocol":
            if let named = parseNamed(ref, kind: kind) { return named }
            return parseAddress(ref).map { .protocolDescriptor($0) }
        case "metadataRecord":
            guard let at = ref.lastIndex(of: "@") else { return nil }
            let section = String(ref[..<at])
            guard isSectionName(section), let address = parseAddress(String(ref[ref.index(after: at)...])) else {
                return nil
            }
            return .metadataRecord(section: section, address: address)
        case "selector":
            return isSelector(ref) ? .selector(ref) : nil
        case "field":
            return parseField(ref)
        case "viewBody":
            return parseAddress(ref).map { .viewBody(getter: $0) }
        default:
            return nil
        }
    }

    /// True when `ref` is in the canonical grammar for `kind`.
    static func isCanonical(_ ref: String, kind: String) -> Bool {
        guard let parsed = parse(ref, kind: kind) else { return false }
        return parsed.ref == ref
    }

    /// Strict address: `0x`, 1–16 lowercase hex digits, no leading zero except `0x0`.
    static func parseAddress(_ text: String) -> UInt64? {
        guard text.hasPrefix("0x") else { return nil }
        let digits = text.utf8.dropFirst(2)
        guard (1 ... 16).contains(digits.count),
              digits.allSatisfy({ (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }) else { return nil }
        if digits.count > 1, digits.first == UInt8(ascii: "0") { return nil }
        return UInt64(String(decoding: digits, as: UTF8.self), radix: 16)
    }

    private static func parseImage(_ ref: String) -> Parsed? {
        let parts = ref.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let uuidText = String(parts[0])
        let slicePrefix = String(parts[1])
        guard slicePrefix.utf8.count == slicePrefixLength,
              slicePrefix.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }) else {
            return nil
        }
        if uuidText == noUUID { return .image(uuid: nil, slicePrefix: slicePrefix) }
        guard let uuid = UUID(uuidString: uuidText), uuid.uuidString.lowercased() == uuidText else { return nil }
        return .image(uuid: uuidText, slicePrefix: slicePrefix)
    }

    private static func parseNamed(_ ref: String, kind: String) -> Parsed? {
        guard ref.hasPrefix(namePrefix) else { return nil }
        let qualifiedName = String(ref.dropFirst(namePrefix.count))
        guard namedKinds.containsExactly(kind), isQualifiedName(qualifiedName) else { return nil }
        return .named(kind: kind, qualifiedName: qualifiedName)
    }

    /// A type ref inside a field ref: a descriptor address or the `name:` form.
    private static func parseTypeRef(_ text: String) -> Bool {
        parseAddress(text) != nil || parseNamed(text, kind: "type") != nil
    }

    private static func parseField(_ ref: String) -> Parsed? {
        if let hash = ref.lastIndex(of: "#") {
            let typeRef = String(ref[..<hash])
            let indexText = String(ref[ref.index(after: hash)...])
            if let index = parseCanonicalIndex(indexText), parseTypeRef(typeRef) {
                return .fieldIndex(typeRef: typeRef, index: index)
            }
        }
        guard let dot = ref.lastIndex(of: ".") else { return nil }
        let typeRef = String(ref[..<dot])
        let name = String(ref[ref.index(after: dot)...])
        guard parseTypeRef(typeRef), isFieldName(name) else { return nil }
        return .fieldName(typeRef: typeRef, name: name)
    }

    /// `0` or a decimal without leading zeros that fits `Int`.
    private static func parseCanonicalIndex(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }) else { return nil }
        if text.utf8.count > 1, text.utf8.first == UInt8(ascii: "0") { return nil }
        return Int(text)
    }

    private static func hasNoControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0x80 ... 0x9F).contains($0.value) }
    }

    private static func isQualifiedName(_ text: String) -> Bool {
        !text.isEmpty && hasNoControlCharacters(text)
    }

    private static func isFieldName(_ text: String) -> Bool {
        !text.isEmpty && hasNoControlCharacters(text) && !text.contains(".") && !text.contains("#")
    }

    private static func isSectionName(_ text: String) -> Bool {
        !text.isEmpty && !text.contains("@") && text.unicodeScalars.allSatisfy { (0x21 ... 0x7E).contains($0.value) }
    }

    private static func isSelector(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value != 0x7F && !(0x80 ... 0x9F).contains($0.value)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}

extension NavigatorContractValidator {
    /// Full validation of one record: the contract rules refuse, the canonical-ref check only warns.
    /// The ref check runs only on a structurally valid record, so its typed reads are safe.
    static func validate(_ record: JSON) -> Report {
        let reasons = validateRecord(record)
        guard reasons.isEmpty else { return Report(reasons: reasons, warnings: []) }
        // `validateCanonicalRefs` is the canonical subject-ref check declared beside `NavigatorSubjectRef`.
        return Report(reasons: [], warnings: validateCanonicalRefs(record))
    }

    /// Opt-in check that every subject ref (and image ref) in `record` is in the canonical v1.1
    /// grammar of `NavigatorSubjectRef`. Not part of `validateRecord`: v1 records keep any non-empty
    /// ref, and a non-empty result here is advisory. Accepts the same record kinds as `validateRecord`.
    static func validateCanonicalRefs(_ record: JSON) -> [String] {
        switch record["kind"]?.stringValue {
        case "NavigatorEngineState":
            var reasons: [String] = []
            for name in ["facts", "frontier", "annotations"] {
                for (offset, item) in (record[name]?.arrayValue ?? []).enumerated() {
                    reasons += canonicalSubjectReasons(item["subject"], "state.\(name)[\(offset)].subject")
                }
            }
            return reasons
        case "PrimitiveResult":
            var reasons = canonicalSubjectReasons(record["subject"], "$.subject")
            for name in ["facts", "frontier"] {
                for (offset, item) in (record[name]?.arrayValue ?? []).enumerated() {
                    reasons += canonicalSubjectReasons(item["subject"], "$.\(name)[\(offset)].subject")
                }
            }
            return reasons
        case "Fact", "FrontierItem", "Annotation":
            return canonicalSubjectReasons(record["subject"], "$.subject")
        default:
            return ["$: unknown record kind"]
        }
    }

    /// Canonical-grammar reasons for one subject object; empty when its ref and image are canonical.
    static func canonicalSubjectReasons(_ subject: JSON?, _ at: String) -> [String] {
        guard let kind = subject?["kind"]?.stringValue, let ref = subject?["ref"]?.stringValue else {
            return ["\(at): expected subject with string kind and ref"]
        }
        var reasons: [String] = []
        if !NavigatorSubjectRef.isCanonical(ref, kind: kind) {
            reasons.append("\(at).ref: not canonical for kind \(kind)")
        }
        if let image = subject?["image"] {
            let canonical = image.stringValue.map { NavigatorSubjectRef.isCanonical($0, kind: "image") } ?? false
            if !canonical { reasons.append("\(at).image: not a canonical image ref") }
        }
        return reasons
    }
}
