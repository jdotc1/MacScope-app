import Foundation

/// Represents a single expression node in a flattened operand tree for BinExport2.
/// Each node stores its kind, an optional symbol, an optional immediate value
/// (for integers only), and the index of its parent node within the same
/// operand's node array. A `parentIndex` of `nil` indicates a root node.
public struct ExprNode {
    public enum Kind: Int {
        case symbol = 1
        case immediateInt = 2
        case immediateFloat = 3
        case op = 4
        case register = 5
        case sizePrefix = 6
        case dereference = 7
    }

    public let kind: Kind
    public let symbol: String
    public let immediate: UInt64
    public var parentIndex: Int?

    public init(kind: Kind, symbol: String = "", immediate: UInt64 = 0, parentIndex: Int? = nil) {
        self.kind = kind
        self.symbol = symbol
        self.immediate = immediate
        self.parentIndex = parentIndex
    }
}

/// A pure parser that converts a textual operand into a flattened expression tree
/// suitable for emission in the BinExport2 format. The parser is architecture-
/// aware for memory addressing modes and supports ARM64, AArch64 and x86_64
/// operands. It also provides helpers for splitting operands and recognising
/// registers that are reused by the exporter.
public enum BinExport2OperandParser {
    /// Recognizes a register-name token so a bare identifier (e.g. a call target
    /// `printf`) is NOT mislabelled a register. Covers x86 AT&T `%`-prefixed
    /// registers and ARM64 bare spellings: `w`/`x` + number (or `zr`), the SIMD
    /// `b`/`h`/`s`/`d`/`q`/`v` + number forms, and the special names
    /// `sp`/`wsp`/`lr`/`fp`/`pc`. A vector token with an arrangement suffix
    /// (`v0.16b`) has a `.` and falls through to SYMBOL, which is acceptable.
    public static func isRegisterToken(_ token: String) -> Bool {
        if token.hasPrefix("%") { return true } // x86 AT&T register
        let s = token.lowercased()
        switch s {
        case "sp", "wsp", "lr", "fp", "pc", "xzr", "wzr": return true
        default: break
        }
        guard let first = s.first, "wxbhsdqv".contains(first) else { return false }
        let rest = s.dropFirst()
        return !rest.isEmpty && rest.allSatisfy { $0.isNumber }
    }

    /// Splits an operand string on TOP-LEVEL commas only — commas nested inside
    /// brackets, braces, or parentheses (e.g. a memory operand `[x1, #8]`) stay
    /// within their operand rather than shredding it. Whitespace is trimmed per
    /// piece; empty pieces are dropped.
    public static func splitTopLevelOperands(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        for ch in s {
            switch ch {
            case "[", "{", "(":
                depth += 1
                current.append(ch)
            case "]", "}", ")":
                depth = max(0, depth - 1)
                current.append(ch)
            case "," where depth == 0:
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { result.append(piece) }
                current = ""
            default:
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { result.append(last) }
        return result
    }

    /// Parses a single operand string into a flat array of `ExprNode`s. The
    /// returned array is ordered such that parents precede their children and
    /// each node's `parentIndex` refers to the index of its parent within the
    /// returned array. `arch` is the architecture name (case-insensitive) used
    /// to disambiguate addressing modes.
    public static func parseOperandTree(_ operand: String, arch: String) -> [ExprNode] {
        let trimmed = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        // Detect size prefix (e.g. "byte ptr [rax]", "dword ptr [rbx]"). If present,
        // parse the underlying memory and wrap it in a SIZE_PREFIX node.
        if let sizePrefixed = parseSizePrefix(trimmed, arch: arch) {
            return sizePrefixed
        }

        // Memory operand in square brackets for ARM and Intel syntax.
        if trimmed.first == "[", let closing = trimmed.lastIndex(of: "]") {
            // Remove surrounding brackets and an optional trailing '!'
            var inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            if inner.hasSuffix("!") {
                inner.removeLast()
            }
            return parseBracketMemory(inner, arch: arch)
        }

        // AT&T syntax uses displacement(base,index,scale)
        if let openIndex = trimmed.firstIndex(of: "("), let closeIndex = trimmed.lastIndex(of: ")"), openIndex < closeIndex {
            return parseParenMemory(trimmed, arch: arch)
        }

        // Shifted register or extension modifier (e.g. "x1, lsl #2" or "w0, uxtw").
        // Detect a comma outside of brackets/parentheses and treat it as a shift/extend
        // modifier if the right-hand side begins with a known shift/extend op.
        if let commaIndex = topLevelCommaIndex(trimmed), commaIndex > trimmed.startIndex {
            let lhs = String(trimmed[..<commaIndex])
            let rhsStart = trimmed.index(after: commaIndex)
            let rhs = String(trimmed[rhsStart...])
            let rhsTrim = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
            if let shiftNodes = parseShiftOrExtend(lhs: lhs, rhs: rhsTrim, arch: arch) {
                return shiftNodes
            }
        }

        // If the operand begins with '#', parse an immediate.
        if trimmed.hasPrefix("#") {
            let immediatePart = String(trimmed.dropFirst())
            if let imm = parseImmediate(immediatePart) {
                return [ExprNode(kind: .immediateInt, symbol: "", immediate: imm, parentIndex: nil)]
            }
        }

        // Try parsing as a register for both ARM and x86 contexts. For x86 Intel
        // syntax, registers do not start with '%', so this helper catches only
        // ARM names and AT&T-style x86. We'll supplement with a broader x86
        // detection below when necessary.
        if isRegisterToken(trimmed) {
            return [ExprNode(kind: .register, symbol: trimmed, immediate: 0, parentIndex: nil)]
        }

        // If the operand looks like a bare number (decimal or hex), treat it as
        // an immediate. Do not misclassify register names that happen to look
        // numeric (e.g. ARM64 b0/d0/s0/h0).
        if let imm = parseImmediate(trimmed) {
            return [ExprNode(kind: .immediateInt, symbol: "", immediate: imm, parentIndex: nil)]
        }

        // Fallback: treat as a symbol. This covers bare call-target identifiers
        // like `printf` and unknown patterns that we intentionally leave as a
        // single leaf to avoid corrupting BinDiff.
        return [ExprNode(kind: .symbol, symbol: trimmed, immediate: 0, parentIndex: nil)]
    }

    // MARK: - Internal helpers

    /// Returns the index of a comma at top level (depth==0) within the operand
    /// string, or nil if none exists. Brackets and parentheses maintain depth.
    private static func topLevelCommaIndex(_ s: String) -> String.Index? {
        var depth = 0
        for (idx, ch) in s.enumerated() {
            switch ch {
            case "[", "{", "(":
                depth += 1
            case "]", "}", ")":
                depth = max(0, depth - 1)
            case "," where depth == 0:
                return s.index(s.startIndex, offsetBy: idx)
            default:
                continue
            }
        }
        return nil
    }

    /// Parses an ARM64 or Intel-style memory operand inside square brackets (e.g.
    /// `x1`, `x1, #8`, `rax + rcx*4 + 0x10`). Returns a flattened expression tree
    /// rooted at a DEREFERENCE node.
    private static func parseBracketMemory(_ inner: String, arch: String) -> [ExprNode] {
        // Split components on '+' or ',' depending on architecture. For ARM the
        // separator is a comma. For Intel the separator is a '+', but ARM may
        // also permit plus signs in AT&T names, so we treat both.
        // We'll scan the string to collect tokens separated by '+' or ',' while
        // respecting nested parentheses (which shouldn't occur here).
        var tokens: [String] = []
        var current = ""
        var depth = 0
        var signStack: [Int] = [1] // track sign for each token (+1 or -1)
        var signs: [Int] = []
        for ch in inner {
            switch ch {
            case "[", "{", "(":
                depth += 1
                current.append(ch)
            case "]", "}", ")":
                depth = max(0, depth - 1)
                current.append(ch)
            case "+" where depth == 0:
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                // A '+'/'-' following only an immediate-prefix '#' (or nothing) is the SIGN of the
                // upcoming immediate, not an operand separator. Keep the accumulator so `#+16`/`#-16`
                // parse as a single signed IMMEDIATE_INT instead of flushing a bare '#' that fails to
                // parse and leaks a stray SYMBOL "#" node into the tree.
                if piece.isEmpty || piece == "#" {
                    signStack[signStack.count - 1] = 1
                } else {
                    tokens.append(piece)
                    signs.append(signStack.last ?? 1)
                    current = ""
                    signStack[signStack.count - 1] = 1
                }
            case "," where depth == 0:
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    tokens.append(piece)
                    signs.append(signStack.last ?? 1)
                }
                current = ""
                signStack[signStack.count - 1] = 1
            case "-" where depth == 0:
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                // See the '+' case: a '-' after only '#'/empty is the immediate's sign, not a
                // separator — keep the accumulator so the following digits form one signed immediate.
                if piece.isEmpty || piece == "#" {
                    signStack[signStack.count - 1] = -1
                } else {
                    tokens.append(piece)
                    signs.append(signStack.last ?? 1)
                    current = ""
                    signStack[signStack.count - 1] = -1
                }
            default:
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty {
            tokens.append(last)
            signs.append(signStack.last ?? 1)
        }

        // Special-case: if no separators were found, treat as a single base (register or symbol).
        if tokens.count == 1 {
            let base = tokens[0]
            // Recognize register or immediate within memory brackets.
            if isRegisterToken(base) || isX86RegisterName(base) {
                let deref = ExprNode(kind: .dereference, symbol: "", immediate: 0, parentIndex: nil)
                let reg = ExprNode(kind: .register, symbol: base, immediate: 0, parentIndex: 0)
                return [deref, reg]
            }
            // Immediate memory access like [0x1000]
            if let imm = parseImmediate(base) {
                let deref = ExprNode(kind: .dereference, symbol: "", immediate: 0, parentIndex: nil)
                let immNode = ExprNode(kind: .immediateInt, symbol: "", immediate: imm, parentIndex: 0)
                return [deref, immNode]
            }
            // Otherwise treat as symbol within brackets.
            let deref = ExprNode(kind: .dereference, symbol: "", immediate: 0, parentIndex: nil)
            let sym = ExprNode(kind: .symbol, symbol: base, immediate: 0, parentIndex: 0)
            return [deref, sym]
        }

        // Build a DEREFERENCE → OPERATOR '+' tree. Root dereference (index 0), plus operator (index 1), children at subsequent indices.
        var nodes: [ExprNode] = []
        let deref = ExprNode(kind: .dereference, symbol: "", immediate: 0, parentIndex: nil)
        nodes.append(deref)
        let plus = ExprNode(kind: .op, symbol: "+", immediate: 0, parentIndex: 0)
        nodes.append(plus)
        // Track the index of the plus node for children parent indices.
        let plusIndex = 1
        // For each token, generate its subtree and append to nodes, adjusting parent indices.
        for (tok, sign) in zip(tokens, signs) {
            let t = tok.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            // Scaled index: form "reg*scale" or "reg* scale".
            if let starIndex = t.firstIndex(of: "*") {
                let lhs = String(t[..<starIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rhs = String(t[t.index(after: starIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                // Multiply operator.
                let mulIndex = nodes.count
                nodes.append(ExprNode(kind: .op, symbol: "*", immediate: 0, parentIndex: plusIndex))
                // Left child: register.
                if isRegisterToken(lhs) || isX86RegisterName(lhs) {
                    nodes.append(ExprNode(kind: .register, symbol: lhs, immediate: 0, parentIndex: mulIndex))
                } else if let imm = parseImmediate(lhs) {
                    nodes.append(ExprNode(kind: .immediateInt, symbol: "", immediate: imm, parentIndex: mulIndex))
                } else {
                    nodes.append(ExprNode(kind: .symbol, symbol: lhs, immediate: 0, parentIndex: mulIndex))
                }
                // Right child: scale immediate.
                if let imm = parseImmediate(rhs) {
                    nodes.append(ExprNode(kind: .immediateInt, symbol: "", immediate: imm, parentIndex: mulIndex))
                } else {
                    nodes.append(ExprNode(kind: .symbol, symbol: rhs, immediate: 0, parentIndex: mulIndex))
                }
            } else {
                // If token is a register.
                if isRegisterToken(t) || isX86RegisterName(t) {
                    nodes.append(ExprNode(kind: .register, symbol: t, immediate: 0, parentIndex: plusIndex))
                } else if let imm = parseImmediate(t) {
                    // Apply sign to immediate; negative immediates use two's complement.
                    let adjusted: UInt64
                    if sign < 0 {
                        // Wrapping two's-complement negation: -Int64.min traps.
                        adjusted = 0 &- imm
                    } else {
                        adjusted = imm
                    }
                    nodes.append(ExprNode(kind: .immediateInt, symbol: "", immediate: adjusted, parentIndex: plusIndex))
                } else {
                    // Unknown token: treat as symbol.
                    nodes.append(ExprNode(kind: .symbol, symbol: t, immediate: 0, parentIndex: plusIndex))
                }
            }
        }
        return nodes
    }

    /// Parses a memory operand in the AT&T syntax `disp(base,index,scale)`.
    private static func parseParenMemory(_ operand: String, arch: String) -> [ExprNode] {
        // Split into displacement and the parenthesised part.
        guard let openIndex = operand.firstIndex(of: "("), let closeIndex = operand.lastIndex(of: ")"), openIndex < closeIndex else {
            return parseBracketMemory(operand, arch: arch)
        }
        let dispPart = operand[..<openIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let inside = operand[operand.index(after: openIndex)..<closeIndex]
        let inner = inside.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split inside on commas.
        let regs = inner.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        var baseReg: String? = nil
        var indexReg: String? = nil
        var scaleStr: String? = nil
        if regs.count > 0 { baseReg = regs[0].isEmpty ? nil : regs[0] }
        if regs.count > 1 { indexReg = regs[1].isEmpty ? nil : regs[1] }
        if regs.count > 2 { scaleStr = regs[2].isEmpty ? nil : regs[2] }
        var displacement: UInt64? = nil
        var dispSign: Int = 1
        if !dispPart.isEmpty {
            var part = dispPart
            if part.hasPrefix("+") { part.removeFirst(); dispSign = 1 }
            else if part.hasPrefix("-") { part.removeFirst(); dispSign = -1 }
            if let imm = parseImmediate(part) {
                if dispSign < 0 {
                    displacement = 0 &- imm
                } else {
                    displacement = imm
                }
            }
        }
        var nodes: [ExprNode] = []
        let deref = ExprNode(kind: .dereference, symbol: "", immediate: 0, parentIndex: nil)
        nodes.append(deref)
        // Determine if we need a plus node. We need it if more than one component exists.
        var childrenCount = 0
        if baseReg != nil { childrenCount += 1 }
        if indexReg != nil { childrenCount += 1 }
        if displacement != nil { childrenCount += 1 }
        let plusIndex: Int?
        if childrenCount > 1 {
            plusIndex = nodes.count
            nodes.append(ExprNode(kind: .op, symbol: "+", immediate: 0, parentIndex: 0))
        } else {
            plusIndex = nil
        }
        // Append base register
        if let br = baseReg, !br.isEmpty {
            let idx = plusIndex ?? 0
            nodes.append(ExprNode(kind: .register, symbol: br, immediate: 0, parentIndex: idx))
        }
        // Append index*scale
        if let ir = indexReg, !ir.isEmpty {
            let mulIndex = nodes.count
            let parentOfMul = plusIndex ?? 0
            nodes.append(ExprNode(kind: .op, symbol: "*", immediate: 0, parentIndex: parentOfMul))
            // index register child
            nodes.append(ExprNode(kind: .register, symbol: ir, immediate: 0, parentIndex: mulIndex))
            // scale (default 1 if missing)
            if let s = scaleStr, let imm = parseImmediate(s) {
                nodes.append(ExprNode(kind: .immediateInt, symbol: "", immediate: imm, parentIndex: mulIndex))
            } else {
                // Default scale of 1
                nodes.append(ExprNode(kind: .immediateInt, symbol: "", immediate: 1, parentIndex: mulIndex))
            }
        }
        // Append displacement
        if let disp = displacement {
            let idx = plusIndex ?? 0
            nodes.append(ExprNode(kind: .immediateInt, symbol: "", immediate: disp, parentIndex: idx))
        }
        return nodes
    }

    /// Parses a shift or extend modifier such as `x1, lsl #2` or `w0, uxtw`. Returns
    /// nil if the rhs does not begin with a known modifier. If recognised, the
    /// returned nodes form an operator tree (Kind.op) with the base operand and
    /// an immediate (when present) as children.
    private static func parseShiftOrExtend(lhs: String, rhs: String, arch: String) -> [ExprNode]? {
        let lowerRhs = rhs.lowercased()
        // List of known shift/extend modifiers. Extend variants may or may not have
        // an immediate operand. For example, `lsl #2`, `lsr #1`, `asr #3`, `ror #4`,
        // `rrx`, `uxtw`, `sxtx`, `uxtb`, `uxtw`, `uxth`, etc.
        let shiftPrefixes = ["lsl", "lsr", "asr", "ror", "rrx", "uxtw", "uxtx", "uxtb", "uxth", "uxtb", "sxtw", "sxtx", "sxtb", "sxth"]
        // Extract the leading word from rhs (until whitespace or '#').
        var modifier: String = ""
        var remainder: String = ""
        if let spaceIdx = lowerRhs.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            modifier = String(lowerRhs[..<spaceIdx])
            remainder = String(lowerRhs[lowerRhs.index(after: spaceIdx)...])
        } else {
            // No whitespace; the entire rhs is the modifier or modifier+immediate
            modifier = lowerRhs
            remainder = ""
        }
        // If modifier includes '#' (e.g. "lsl #2"), strip after space search.
        // Remove trailing punctuation (comma, etc.)
        modifier = modifier.trimmingCharacters(in: CharacterSet(charactersIn: ","))
        if !shiftPrefixes.contains(modifier) {
            return nil
        }
        var immValue: UInt64? = nil
        // If there's an explicit '#' in the rhs, parse the immediate following it.
        if let hashIndex = rhs.firstIndex(of: "#") {
            let immStr = rhs[rhs.index(after: hashIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let imm = parseImmediate(String(immStr)) {
                immValue = imm
            }
        } else {
            // The remainder after the modifier may contain the immediate.
            let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                let dropHash = String(trimmed.dropFirst())
                if let imm = parseImmediate(dropHash) {
                    immValue = imm
                }
            } else if !trimmed.isEmpty {
                if let imm = parseImmediate(trimmed) {
                    immValue = imm
                }
            }
        }
        // Build the base operand tree.
        var baseNodes = parseOperandTree(lhs, arch: arch)
        // Create operator node at index 0.
        var nodes: [ExprNode] = []
        let opNode = ExprNode(kind: .op, symbol: modifier, immediate: 0, parentIndex: nil)
        nodes.append(opNode)
        // Adjust baseNodes parent indices: their root(s) attach under opNode.
        for i in 0..<baseNodes.count {
            var node = baseNodes[i]
            if let p = node.parentIndex {
                node.parentIndex = p + 1
            } else {
                node.parentIndex = 0
            }
            baseNodes[i] = node
        }
        nodes.append(contentsOf: baseNodes)
        // Append immediate child if present.
        if let imm = immValue {
            nodes.append(ExprNode(kind: .immediateInt, symbol: "", immediate: imm, parentIndex: 0))
        }
        return nodes
    }

    /// Parses and attaches a size prefix (e.g. `dword ptr [rax]`) as a SIZE_PREFIX
    /// node above the underlying memory dereference. Returns nil if no size
    /// prefix is found.
    private static func parseSizePrefix(_ operand: String, arch: String) -> [ExprNode]? {
        let lower = operand.lowercased()
        // Detect patterns like "byte ptr", "word ptr", "dword ptr", "qword ptr".
        let sizePrefixes = ["byte ptr", "word ptr", "dword ptr", "qword ptr", "xword ptr", "hword ptr"]
        for pref in sizePrefixes {
            if lower.hasPrefix(pref) {
                // Drop the prefix length from the original operand to obtain the remaining text.
                // Using pref.endIndex (which belongs to the pref string) to slice operand is
                // invalid because indices are not interchangeable between strings. Instead,
                // derive the suffix by dropping the number of characters equal to pref.count.
                let suffixStart = operand.index(operand.startIndex, offsetBy: pref.count)
                let suffix = String(operand[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                var childNodes = parseOperandTree(suffix, arch: arch)
                // Create SIZE_PREFIX node at index 0.
                var nodes: [ExprNode] = []
                let prefixParts = pref.split(separator: " ")
                let prefixName = String(prefixParts[0])
                nodes.append(ExprNode(kind: .sizePrefix, symbol: prefixName, immediate: 0, parentIndex: nil))
                // Adjust child nodes' parent indices: their root attaches under size prefix.
                for i in 0..<childNodes.count {
                    var node = childNodes[i]
                    if let p = node.parentIndex {
                        node.parentIndex = p + 1
                    } else {
                        node.parentIndex = 0
                    }
                    childNodes[i] = node
                }
                nodes.append(contentsOf: childNodes)
                return nodes
            }
        }
        return nil
    }

    /// Returns true if the given token looks like an x86 register in Intel syntax
    /// (e.g. `rax`, `rcx`, `r10`, `eax`, `edx`, `ax`, `al`). ARM64 register
    /// detection is handled by `isRegisterToken`.
    private static func isX86RegisterName(_ token: String) -> Bool {
        let s = token.lowercased()
        // 64-bit registers
        let x86Regs: Set<String> = [
            "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp",
            "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
            "rip"
        ]
        // 32-bit
        let x86Regs32: Set<String> = [
            "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp",
            "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d"
        ]
        // 16-bit
        let x86Regs16: Set<String> = [
            "ax", "bx", "cx", "dx", "si", "di", "bp", "sp",
            "r8w", "r9w", "r10w", "r11w", "r12w", "r13w", "r14w", "r15w"
        ]
        // 8-bit
        let x86Regs8: Set<String> = [
            "al", "bl", "cl", "dl", "sil", "dil", "spl", "bpl",
            "ah", "bh", "ch", "dh",
            "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b"
        ]
        return x86Regs.contains(s) || x86Regs32.contains(s) || x86Regs16.contains(s) || x86Regs8.contains(s)
    }

    /// Parses an immediate from a string. Accepts optional sign and radix prefixes
    /// (`0x` for hex). Returns nil if the string is not a valid integer.
    private static func parseImmediate(_ s: String) -> UInt64? {
        var str = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.isEmpty { return nil }
        // ARM immediates are written with a leading '#' (e.g. `#8`, `#-4`). Strip it so a
        // memory-offset token like `#8` inside `[x1, #8]` parses as the integer 8 rather than
        // falling through to a SYMBOL. (Top-level `#imm` operands already strip '#' before
        // calling here, but bracket/scale/displacement tokens reach this path with '#' intact.)
        if str.hasPrefix("#") {
            str.removeFirst()
            str = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if str.isEmpty { return nil }
        }
        var isNegative = false
        if str.hasPrefix("-") {
            isNegative = true
            str.removeFirst()
        } else if str.hasPrefix("+") {
            str.removeFirst()
        }
        var value: UInt64? = nil
        if str.lowercased().hasPrefix("0x") {
            let hexPart = String(str.dropFirst(2))
            value = UInt64(hexPart, radix: 16)
        } else if str.lowercased().hasPrefix("0b") {
            let binPart = String(str.dropFirst(2))
            value = UInt64(binPart, radix: 2)
        } else {
            value = UInt64(str)
        }
        guard let v = value else { return nil }
        if isNegative {
            return 0 &- v
        }
        return v
    }
}
