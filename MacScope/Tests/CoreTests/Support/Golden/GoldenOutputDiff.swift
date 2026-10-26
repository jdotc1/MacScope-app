import Foundation
@testable import MacScope

/// The structured result of comparing two normalized `GoldenOutput`s (MacScope's vs. an
/// authorized reference). A per-capability accounting of what MacScope produced that the
/// reference lacked (`onlyInActual`), what the reference had that MacScope missed
/// (`onlyInReference`), and entries present in both that DIFFER (`mismatched`).
///
/// The whole point is that *semantic* differences surface: `GoldenOutput` normalizes only
/// address/path/UUID nondeterminism, so anything this reports — a different mnemonic, a missing
/// symbol, an extra xref — is a real MacScope-vs-oracle divergence, never a formatting artifact.
struct GoldenDiff: Equatable {
    struct Capability: Equatable {
        var name: String
        var onlyInActual: [String]
        var onlyInReference: [String]
        var mismatched: [String]
        var matches: Bool { onlyInActual.isEmpty && onlyInReference.isEmpty && mismatched.isEmpty }
    }

    /// True when the schema versions differ — a stale reference must be re-captured rather than
    /// silently mis-compared.
    var schemaMismatch: Bool
    /// The `GoldenBinary` metadata fields whose values differ.
    var binaryFieldDifferences: [String]
    var capabilities: [Capability]

    var matches: Bool {
        !schemaMismatch && binaryFieldDifferences.isEmpty && capabilities.allSatisfy(\.matches)
    }

    func capability(named name: String) -> Capability? {
        capabilities.first { $0.name == name }
    }

    /// One readable line per divergence, for the differential report.
    var summaryLines: [String] {
        var lines: [String] = []
        if schemaMismatch { lines.append("schema: version mismatch (reference is stale)") }
        if !binaryFieldDifferences.isEmpty {
            lines.append("binary: fields differ — \(binaryFieldDifferences.joined(separator: ", "))")
        }
        for capability in capabilities where !capability.matches {
            // "reference" is oracle-agnostic on purpose: the same diff backs both oracle
            // differentials, and `GoldenDiff` does not carry the oracle's name. The caller
            // (the differential test) prefixes the report with which oracle it is.
            lines.append(
                "\(capability.name): "
                + "\(capability.onlyInActual.count) only-in-MacScope, "
                + "\(capability.onlyInReference.count) only-in-reference, "
                + "\(capability.mismatched.count) differing"
            )
        }
        return lines
    }
}

/// Compares two normalized golden models capability-by-capability. Pure; no I/O.
enum GoldenOutputDiff {
    static func compare(actual: GoldenOutput, reference: GoldenOutput) -> GoldenDiff {
        var capabilities: [GoldenDiff.Capability] = []

        func diff<T>(_ name: String, _ a: [T], _ b: [T],
                     key: (T) -> String, areEqual: (T, T) -> Bool) {
            let aMap = keyed(a, key)
            let bMap = keyed(b, key)
            let onlyActual = aMap.keys.filter { bMap[$0] == nil }.sorted()
            let onlyReference = bMap.keys.filter { aMap[$0] == nil }.sorted()
            let mismatched = aMap.keys.filter { key in
                guard let other = bMap[key], let mine = aMap[key] else { return false }
                return !areEqual(mine, other)
            }.sorted()
            capabilities.append(.init(name: name, onlyInActual: onlyActual,
                                      onlyInReference: onlyReference, mismatched: mismatched))
        }
        func diff<T: Equatable>(_ name: String, _ a: [T], _ b: [T], key: (T) -> String) {
            diff(name, a, b, key: key, areEqual: ==)
        }

        diff("sections", actual.sections, reference.sections) { "\($0.name)@\($0.address)" }
        diff("symbols", actual.symbols, reference.symbols) { "\($0.name)@\($0.address ?? "")" }
        diff("imports", actual.imports, reference.imports) { $0.name }
        diff("exports", actual.exports, reference.exports) { "\($0.name)@\($0.address ?? "")" }
        // Instructions compare SEMANTICALLY: same mnemonic + operand-equivalent (formatting
        // normalized). Bytes are redundant with the address (same binary), and the `comment` is
        // tool-specific commentary — both are excluded so only real decode divergences surface,
        // not each disassembler's pretty-printing (fp/lr vs x29/x30, #0x1 vs #1, comma spacing).
        diff("instructions", actual.instructions, reference.instructions, key: { $0.address }) {
            OperandNormalizer.canonicalMnemonic($0.mnemonic) == OperandNormalizer.canonicalMnemonic($1.mnemonic)
                && OperandNormalizer.equivalent($0.operands, $1.operands)
        }
        diff("procedures", actual.procedures, reference.procedures) { $0.startAddress }
        diff("basicBlocks", actual.basicBlocks, reference.basicBlocks) { $0.startAddress }
        diff("controlFlowEdges", actual.controlFlowEdges, reference.controlFlowEdges) { "\($0.from)->\($0.to):\($0.kind)" }
        diff("crossReferences", actual.crossReferences, reference.crossReferences) { "\($0.from)->\($0.to):\($0.kind)" }
        diff("demangledNames", actual.demangledNames, reference.demangledNames) { $0.mangled }
        diff("pseudocode", actual.pseudocode, reference.pseudocode) { $0.procedureStartAddress }

        return GoldenDiff(
            schemaMismatch: actual.schemaVersion != reference.schemaVersion,
            binaryFieldDifferences: binaryFieldDifferences(actual.binary, reference.binary),
            capabilities: capabilities
        )
    }

    private static func keyed<T>(_ items: [T], _ key: (T) -> String) -> [String: T] {
        Dictionary(items.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func binaryFieldDifferences(_ a: GoldenBinary, _ b: GoldenBinary) -> [String] {
        var fields: [String] = []
        if a.name != b.name { fields.append("name") }
        if a.pathBasename != b.pathBasename { fields.append("pathBasename") }
        if a.kind != b.kind { fields.append("kind") }
        if a.architecture != b.architecture { fields.append("architecture") }
        if a.hasEmbeddedUUID != b.hasEmbeddedUUID { fields.append("hasEmbeddedUUID") }
        if a.platformName != b.platformName { fields.append("platformName") }
        if a.minimumOSVersion != b.minimumOSVersion { fields.append("minimumOSVersion") }
        if a.sdkVersion != b.sdkVersion { fields.append("sdkVersion") }
        if a.buildTools != b.buildTools { fields.append("buildTools") }
        return fields
    }
}

/// Canonicalizes ARM64 operand text for SEMANTIC comparison across disassemblers, collapsing
/// surface-syntax differences that are NOT real divergences — register aliases (`fp`/`lr` ↔
/// `x29`/`x30`), immediate radix/sign/width (`#1`↔`#0x1`, `#-0x1`↔`#0xffffffff`), address
/// zero-padding and a leading `#`, and whitespace/comma spacing. It is CONSERVATIVE: it equates
/// only provably-equal values, so a different register, a different immediate VALUE, or different
/// operand structure still compares as unequal. The differential needs this because each oracle
/// pretty-prints differently (the reference `mov fp, sp`, reference output `w0,#0x1`) — matching one would diverge
/// from the other, so the comparison normalizes rather than imposing one tool's conventions.
enum OperandNormalizer {
    static func equivalent(_ a: String, _ b: String) -> Bool { canonical(a) == canonical(b) }

    /// Canonicalizes a mnemonic for comparison: ARM condition synonyms (HS≡CS, LO≡CC are defined
    /// identical) collapse to the HS/LO form, so `b.cc` and `b.lo` compare equal.
    static func canonicalMnemonic(_ mnemonic: String) -> String {
        var t = mnemonic.lowercased()
        t = replacingWholeWord(t, "cc", with: "lo")
        t = replacingWholeWord(t, "cs", with: "hs")
        return t
    }

    static func canonical(_ operands: String) -> String {
        var t = operands.lowercased()
        // fp/lr are the conventional names for x29/x30; sp is universal already.
        t = replacingWholeWord(t, "fp", with: "x29")
        t = replacingWholeWord(t, "lr", with: "x30")
        // Condition-code synonyms in operand position (csel/ccmp/…): HS≡CS, LO≡CC.
        t = replacingWholeWord(t, "cc", with: "lo")
        t = replacingWholeWord(t, "cs", with: "hs")
        // Sign-extension width for a negative immediate: a 32-bit op (a w-register and no
        // x-register or sp) makes `#-0x1` == `#0xffffffff`; otherwise it is 64-bit.
        let is32 = hasRegister(t, "w") && !hasRegister(t, "x") && !containsWholeWord(t, "sp")
        t = canonicalizeNumbers(in: t, is32: is32)
        t = t.filter { !$0.isWhitespace } // whitespace/comma spacing is never semantic
        // Fold an immediate shift: `0xM,lsl0xN` == `0x(M<<N)` (e.g. `#0x6, lsl #12` == `#0x6000`).
        // Only an IMMEDIATE (0x…) before `lsl` folds — a register shift (`x2, lsl #3`) has a
        // register, not `0x…`, before `lsl`, so it is left intact.
        t = replacingMatches(in: t, pattern: "0x([0-9a-f]+),lsl0x([0-9a-f]+)") { token in
            let parts = token.dropFirst(2).components(separatedBy: ",lsl0x")
            guard parts.count == 2, let base = UInt64(parts[0], radix: 16),
                  let shift = UInt64(parts[1], radix: 16), shift < 64 else { return token }
            return "0x" + String(base << shift, radix: 16)
        }
        // Strip an explicit zero/empty shift on a register offset: `,lsl0x0` / a bare `,lsl`
        // (reference output emits both) == no shift.
        t = replacingMatches(in: t, pattern: ",lsl(0x0)?(?=[\\],]|$)") { _ in "" }
        // Reconcile addressing-mode offsets rendered at different sign/width: the reference prints a
        // NEGATIVE pre/post-index offset as a width-masked UNSIGNED hex (`[sp, #-0x10]!` →
        // `[sp, #0xfff0]!`, a 16-bit mask), while MacScope and reference output print it signed. Inside each
        // `[...]`, reinterpret every hex token as a two's-complement value at its PRINTED bit-width
        // (hex-digit count × 4) and re-emit it sign-extended to a canonical 64-bit hex, so the same
        // offset collapses regardless of how wide each tool rendered it. Applied ONLY inside
        // brackets — branch/`adr` targets outside are real absolute addresses and must never be
        // sign-folded. Symmetric, so two genuinely-different offsets still compare unequal.
        t = replacingMatches(in: t, pattern: "\\[[^\\]]*\\]") { group in
            replacingMatches(in: group, pattern: "0x[0-9a-f]+") { token in
                let digits = token.dropFirst(2)
                guard !digits.isEmpty, digits.count <= 16,
                      let raw = UInt64(digits, radix: 16) else { return token }
                let bits = digits.count * 4
                let signed: UInt64 = (bits < 64 && raw & (UInt64(1) << (bits - 1)) != 0)
                    ? raw | (~UInt64(0) << bits)   // top printed bit set → sign-extend to 64
                    : raw
                return "0x" + String(signed, radix: 16)
            }
        }
        return t
    }

    private static func canonicalizeNumbers(in s: String, is32: Bool) -> String {
        // `#`/`-` optional so this also catches a bare `0x…` address (adrp) and a `#0x…`/`#12`.
        // Registers (x29, w0, v0.2d) are never matched: the alternatives require a `#` or a `0x`.
        replacingMatches(in: s, pattern: "#?-?0x[0-9a-f]+|#-?[0-9]+") { token in
            var t = token
            if t.hasPrefix("#") { t.removeFirst() }
            let negative = t.hasPrefix("-")
            if negative { t.removeFirst() }
            let magnitude = t.hasPrefix("0x") ? (UInt64(t.dropFirst(2), radix: 16) ?? 0) : (UInt64(t) ?? 0)
            var value = negative ? (0 &- magnitude) : magnitude // two's complement for a negative
            if is32 { value &= 0xffff_ffff }
            return "0x" + String(value, radix: 16)
        }
    }

    private static func hasRegister(_ s: String, _ prefix: String) -> Bool {
        firstMatch(in: s, pattern: "\\b\(prefix)([0-9]+|zr|sp)\\b")
    }
    private static func containsWholeWord(_ s: String, _ word: String) -> Bool {
        firstMatch(in: s, pattern: "\\b\(word)\\b")
    }
    private static func replacingWholeWord(_ s: String, _ word: String, with replacement: String) -> String {
        replacingMatches(in: s, pattern: "\\b\(word)\\b") { _ in replacement }
    }

    private static func firstMatch(in s: String, pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    private static func replacingMatches(in s: String, pattern: String, _ transform: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += transform(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
