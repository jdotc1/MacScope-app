import CryptoKit
import Foundation

/// MacScope-owned, analysis-model-independent facts about one function in one binary version,
/// used as the sole input to `FunctionVersionMatcher`.
///
/// Every optional fact means "not known". The matcher never treats an unknown fact as equal to
/// (or different from) anything: a missing fingerprint can only withhold evidence, never create it.
struct FunctionVersionFingerprint: Hashable, Codable, Sendable {
    /// Identity that is unique within this version's input set (not across versions).
    let id: String
    /// Image-local start address. Used for deterministic ordering only, never as match evidence,
    /// because addresses shift between versions.
    let address: UInt64
    /// A real (non-generated) symbol name, or nil when stripped/unknown. Generated fallbacks such
    /// as `sub_<hex>` must be passed as nil; the matcher also rejects them defensively.
    let symbolName: String?
    /// Byte length of the function's address range.
    let size: UInt64
    let basicBlockCount: Int?
    /// Intra-function control-flow edge count (calls excluded).
    let edgeCount: Int?
    /// Digest of the address-independent CFG topology (block order, edge endpoints and kinds).
    let cfgShapeHash: String?
    /// Digest of the instruction stream with addresses and immediates masked.
    let normalizedBodyHash: String?
    /// Digest of the instruction stream with addresses and generated labels masked, while
    /// preserving numeric immediates so semantic constant changes remain visible.
    let semanticBodyHash: String?
    let instructionCount: Int?
    /// Ids (in this same version) of in-image functions this function calls directly, or nil when
    /// call facts are unavailable. An empty array means "known to call no in-image function".
    let calleeIDs: [String]?
    /// Names of imported functions this function calls directly, or nil when unknown.
    let importedCalleeNames: [String]?
    /// Values of string literals this function references, or nil when unknown.
    let stringReferences: [String]?

    init(
        id: String,
        address: UInt64,
        symbolName: String?,
        size: UInt64,
        basicBlockCount: Int? = nil,
        edgeCount: Int? = nil,
        cfgShapeHash: String? = nil,
        normalizedBodyHash: String? = nil,
        semanticBodyHash: String? = nil,
        instructionCount: Int? = nil,
        calleeIDs: [String]? = nil,
        importedCalleeNames: [String]? = nil,
        stringReferences: [String]? = nil
    ) {
        self.id = id
        self.address = address
        self.symbolName = symbolName
        self.size = size
        self.basicBlockCount = basicBlockCount
        self.edgeCount = edgeCount
        self.cfgShapeHash = cfgShapeHash
        self.normalizedBodyHash = normalizedBodyHash
        self.semanticBodyHash = semanticBodyHash
        self.instructionCount = instructionCount
        // Canonicalize sets so equality and digests never depend on caller order.
        self.calleeIDs = calleeIDs.map { Array(Set($0)).sorted() }
        self.importedCalleeNames = importedCalleeNames.map { Array(Set($0)).sorted() }
        self.stringReferences = stringReferences.map { Array(Set($0)).sorted() }
    }
}

/// Pure helpers that turn raw analysis text into address-independent fingerprint material.
enum FunctionVersionFingerprinting {
    /// True for names MacScope (or common tooling) synthesizes when no symbol exists. Such names
    /// encode an address, so equal spellings across versions are coincidence, not identity.
    static func isGeneratedName(_ name: String) -> Bool {
        if name.isEmpty || name == "_entry" || name == "__text" { return true }
        for prefix in ["sub_", "loc_", "unk_", "off_", "nullsub_"] where name.hasPrefix(prefix) {
            // MacScope spells its fallback names `sub_0x<16 hex digits>` (`UInt64.hexAddress`);
            // other tools omit the `0x`. Both encode an address.
            var rest = name.dropFirst(prefix.count)
            if rest.hasPrefix("0x") || rest.hasPrefix("0X") { rest = rest.dropFirst(2) }
            if !rest.isEmpty, rest.allSatisfy(\.isHexDigit) { return true }
        }
        return false
    }

    /// One normalized instruction line: lowercased mnemonic plus operands with every numeric
    /// literal (addresses, offsets, immediates) and every generated address label masked.
    /// Register names (`x0`, `w12`, `v3.4s`) are preserved.
    static func normalizedInstruction(mnemonic: String, operands: String) -> String {
        let masked = maskOperands(operands)
        let op = mnemonic.lowercased()
        return masked.isEmpty ? op : op + " " + masked
    }

    /// Instruction line for change detection. Numeric immediates remain intact, while obvious
    /// absolute-address operands are normalized so relocation does not look like a code change.
    static func semanticInstruction(mnemonic: String, operands: String) -> String {
        let op = mnemonic.lowercased()
        // The PAuth_LR label forms (`autiasppc`/`retaasppc` …) carry the absolute address of
        // their signing instruction, so they relocate like branch targets.
        let addressBearingMnemonic = ["adr", "adrp", "b", "bl", "br", "blr", "cbz", "cbnz",
                                      "tbz", "tbnz", "call", "jmp", "lea", "ldr", "ldrsw",
                                      "autiasppc", "autibsppc", "retaasppc", "retabsppc"]
            .contains(op)
            // Conditional branches (`b.ne`, `bc.eq`) carry absolute targets exactly like `b`.
            || op.hasPrefix("b.") || op.hasPrefix("bc.")
        let scalars = Array(operands.lowercased().unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard isWordScalar(scalar) else {
                if !(scalar == " " && (output.last == " " || output.isEmpty)) { output.append(scalar) }
                index += 1
                continue
            }
            var end = index
            while end < scalars.count, isWordScalar(scalars[end]) { end += 1 }
            let token = String(String.UnicodeScalarView(scalars[index..<end]))
            let previous = output.last
            let addressLiteral = addressBearingMnemonic && previous != "#"
                && token.hasPrefix("0x")
            output.append(contentsOf: (isGeneratedName(token) || addressLiteral ? "label" : token).unicodeScalars)
            index = end
        }
        let operands = String(output).trimmingCharacters(in: .whitespaces)
        return operands.isEmpty ? op : op + " " + operands
    }

    static func maskOperands(_ operands: String) -> String {
        let scalars = Array(operands.lowercased().unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard isWordScalar(scalar) else {
                if !(scalar == " " && (output.last == " " || output.isEmpty)) {
                    output.append(scalar)
                }
                index += 1
                continue
            }
            var end = index
            while end < scalars.count, isWordScalar(scalars[end]) { end += 1 }
            var token = String.UnicodeScalarView()
            token.append(contentsOf: scalars[index..<end])
            let text = String(token)
            if let first = text.unicodeScalars.first, ("0"..."9").contains(first) {
                output.append(contentsOf: "imm".unicodeScalars)
            } else if isGeneratedName(text) {
                output.append(contentsOf: "label".unicodeScalars)
            } else {
                output.append(contentsOf: token)
            }
            index = end
        }
        return String(output).trimmingCharacters(in: .whitespaces)
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_", ".", "$": return true
        default: return false
        }
    }

    /// Stable (process-independent) hex SHA-256 of newline-joined lines. Swift's `Hasher` is
    /// randomly seeded per process and must never be used for persisted or compared digests.
    static func stableDigest(_ lines: [String]) -> String {
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
