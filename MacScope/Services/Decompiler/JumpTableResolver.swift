import Foundation

/// Recovers ARM64 jump-table case targets from a function's decoded
/// instructions plus a byte reader backed by section data.
///
/// The resolver is intentionally PURE and conservative: it never depends on a
/// Mach-O object, it only reads bytes through the supplied `ByteReader`, and it
/// emits a site ONLY when the full dispatch idiom is unambiguous AND every
/// recovered target lands inside the executable text range. On any ambiguity it
/// drops the whole site (a single bad entry never yields a partial table), so a
/// `br` whose table cannot be resolved stays opaque downstream.
///
/// Output is `[brAddress: [absoluteTarget]]` with index `i` mapped to case
/// value `i`, which is exactly the contract the committed
/// `MacIRBuilder.recoverSwitchDispatches` seam consumes.
public struct JumpTableResolver: Sendable {
    /// Reads `count` bytes at the given virtual address, or nil if the bytes are
    /// not available (out of section, overflow, etc.).
    public typealias ByteReader = (_ virtualAddress: UInt64, _ count: Int) -> Data?

    /// Inclusive lower / exclusive upper bound of the executable text section.
    /// Every resolved target must satisfy `lowerBound <= target < upperBound`.
    public struct CodeRange: Sendable, Hashable {
        public var lowerBound: UInt64
        public var upperBound: UInt64

        public init(lowerBound: UInt64, upperBound: UInt64) {
            self.lowerBound = lowerBound
            self.upperBound = upperBound
        }

        func contains(_ address: UInt64) -> Bool {
            address >= lowerBound && address < upperBound
        }
    }

    public init() {}

    /// The boundary of a certificate over supplied direct branches and decoded
    /// targets of every candidate table in the function. Other unresolved indirect
    /// destinations are outside this certificate, not assumed safe or absent.
    public struct PathCertificate: Sendable, Equatable {
        public let protectedStartAddress: UInt64
        public let protectedEndAddress: UInt64
        /// Earlier W definition needed by an X-view load. Direct entries are
        /// checked by the existing closed-run proof; known table entries may not
        /// bypass this definition, even when they land exactly at the compare.
        public let zeroExtensionDefinitionAddress: UInt64?
        /// Zero closes the supplied BR-family indirect-branch domain. A nonzero count means
        /// the certificate does not cover those other indirect destinations.
        public let otherUnresolvedIndirectBranchCount: Int
    }

    public struct Resolution: Sendable {
        public let targets: [UInt64: [UInt64]]
        public let certificates: [UInt64: PathCertificate]
    }

    private struct Candidate {
        let targets: [UInt64]
        let protectedStartAddress: UInt64
        let protectedEndAddress: UInt64
        let zeroExtensionDefinitionAddress: UInt64?
    }

    // Preserve the existing selector proof's shape and Equatable behavior.
    private struct SelectorCertificate {
        let proof: JumpTableSelectorProof
        let zeroExtensionDefinitionAddress: UInt64?
    }

    /// Compatibility projection containing targets only. This deliberately drops
    /// the boundary metadata returned by `resolveWithCertificates`; existing app,
    /// payload and census consumers do not thereby persist certificate counts.
    /// Use the detailed API when the unresolved-indirect boundary matters.
    public func resolve<Row: DecompilerInstructionRow>(
        instructions rows: [Row],
        readBytes: ByteReader,
        codeRange: CodeRange
    ) -> [UInt64: [UInt64]] {
        resolveWithCertificates(instructions: rows, readBytes: readBytes, codeRange: codeRange).targets
    }

    /// Resolves tables with explicit certificate boundaries, without mutable caches.
    /// Rows must describe the supplied function. Certificates cover every supplied
    /// direct branch and decoded candidate-table target, not unknown destinations
    /// of other unresolved indirect branches (reported separately per certificate).
    public func resolveWithCertificates<Row: DecompilerInstructionRow>(
        instructions rows: [Row],
        readBytes: ByteReader,
        codeRange: CodeRange
    ) -> Resolution {
        guard codeRange.lowerBound < codeRange.upperBound else {
            return Resolution(targets: [:], certificates: [:])
        }

        var candidates: [UInt64: Candidate] = [:]
        for (index, row) in rows.enumerated() where row.mnemonic.lowercased() == "br" {
            let operands = Self.splitOperands(row.operands)
            guard operands.count == 1 else { continue }
            let brRegister = operands[0].lowercased()
            guard Self.isRegister(brRegister) else { continue }

            // Shape recognition alone does not establish that an X index carries
            // the bounded W value. Keep the selector and range gates independent
            // of the subsequent function-wide table-edge certificate.
            if let selector = Self.proveSelectorCertificate(rows: rows, dispatchIndex: index),
               let candidate = resolveSite(dispatchIndex: index, brRegister: brRegister,
                rows: rows, readBytes: readBytes, codeRange: codeRange,
                zeroExtensionDefinitionAddress: selector.zeroExtensionDefinitionAddress),
               selector.proof.caseCount == candidate.targets.count {
                candidates[row.address] = candidate
            } else if let proof = JumpTableRangeAnalysis.prove(rows: rows, dispatchIndex: index, jumpTables: [:]),
                      let candidate = resolveSite(dispatchIndex: index, brRegister: brRegister, rows: rows,
                          readBytes: readBytes, codeRange: codeRange, rangeProof: proof),
                      let checked = JumpTableRangeAnalysis.prove(rows: rows, dispatchIndex: index,
                          jumpTables: [row.address: candidate.targets]), checked.caseCount == candidate.targets.count {
                candidates[row.address] = candidate
            }
        }

        // Freeze all decoded candidate edges before filtering any candidate. This
        // includes the current table and every other table, is order-independent,
        // and conservatively retains known edges even if their source is refused.
        let decodedTableTargets = candidates.values.flatMap { $0.targets }
        let accepted = candidates.filter { _, candidate in
            Self.directAndResolvedTablePathsReachLoad(rows: rows,
                protectedStart: candidate.protectedStartAddress,
                protectedEnd: candidate.protectedEndAddress,
                resolvedTableTargets: decodedTableTargets,
                zeroExtensionDefinitionAddress: candidate.zeroExtensionDefinitionAddress)
        }
        let unresolvedIndirectCount = rows.filter {
            Self.isIndirectBranchMnemonic($0.mnemonic.lowercased()) && accepted[$0.address] == nil
        }.count
        return Resolution(targets: accepted.mapValues { $0.targets },
            certificates: accepted.mapValues { candidate in
                PathCertificate(protectedStartAddress: candidate.protectedStartAddress,
                    protectedEndAddress: candidate.protectedEndAddress,
                    zeroExtensionDefinitionAddress: candidate.zeroExtensionDefinitionAddress,
                    otherUnresolvedIndirectBranchCount: unresolvedIndirectCount)
            })
    }

    // Conservative product limit for this local idiom recognizer. Larger tables
    // remain opaque rather than allowing an instruction immediate to authorize an
    // unbounded allocation or read loop. This is not an architectural ISA limit.
    private static let maximumRecoveredCaseCount = 4_096

    // Only adjacent cmp/bounds-branch pairs qualify. Nonadjacent forms need proof
    // that intervening instructions preserve NZCV before this can be broadened.
    private static func entryCount(bound: Int64, branchMnemonic: String) -> Int? {
        guard bound >= 0, let value = Int(exactly: bound) else { return nil }
        let count: Int
        switch branchMnemonic {
        case "b.hi":
            let incremented = value.addingReportingOverflow(1)
            guard !incremented.overflow else { return nil }
            count = incremented.partialValue
        case "b.hs", "b.cs":
            count = value
        default:
            return nil
        }
        return count > 0 && count <= maximumRecoveredCaseCount ? count : nil
    }

    // MARK: - Per-site resolution

    private func resolveSite<Row: DecompilerInstructionRow>(
        dispatchIndex: Int,
        brRegister: String,
        rows: [Row],
        readBytes: ByteReader,
        codeRange: CodeRange,
        rangeProof: JumpTableSelectorProof? = nil,
        zeroExtensionDefinitionAddress: UInt64? = nil
    ) -> Candidate? {
        // Backward straight-line scan, capped and stopping at the first
        // control-flow boundary that is not the bounds branch.
        var baseRegister: String?
        var tableBase: UInt64?
        var loadDestination: String?
        var loadBaseRegister: String?
        var indexRegister: String?
        // The kind of encoding observed. For new compact encodings we delay
        // formation of a full Encoding value until the anchor and scale are
        // known.
        var encodingKind: EncodingKind?
        var addBackConfirmed = false
        var pendingAddBackBase: String?
        var pendingAddBackOffset: String?
        var entryCount: Int? = rangeProof?.caseCount
        // Anchor information for compact encodings.
        var anchorRegister: String?
        var anchor: UInt64?
        // The pending anchor-add instruction collects the right-hand operand and
        // shift until the matching `adr` is seen.
        var pendingAnchorAddDest: String?
        var pendingAnchorAddRight: String?
        var pendingAnchorAddShift: Int?
        // Positions of the instructions that play a recognized role in the idiom.
        // Every other instruction between the guard and the dispatch must leave the
        // index, base, loaded value and dispatch registers untouched (checked below).
        var roles: Set<Int> = []
        var guardIndex: Int?
        var loadIndex: Int?
        var adrpIndex: Int?
        var tableADRIndex: Int?
        var adrIndex: Int?
        var indexAliases: [String] = []
        var baseAddIndices: [Int] = []
        var addBackIndex: Int?
        var anchorAddIndex: Int?

        var scan = dispatchIndex - 1
        var steps = 0
        while scan >= 0, steps < 24 {
            defer { scan -= 1; steps += 1 }
            let candidate = rows[scan]
            let mnemonic = candidate.mnemonic.lowercased()
            let operands = Self.splitOperands(candidate.operands)

            switch mnemonic {
            case "add":
                // There are three forms we care about here:
                // 1. add Rd, Rd, #imm         -> base formation
                // 2. add Rbr, Rbase, Rt       -> add-back for signedOffset32
                // 3. add Ranchor, Ranchor, Rt, lsl #k -> anchor-add for compact encodings
                if operands.count == 4 {
                    // Anchor-add detection: add Ranchor, Ranchor, Rt, lsl #k
                    let addDest = operands[0].lowercased()
                    let addLeft = operands[1].lowercased()
                    let addRight = operands[2].lowercased()
                    let shiftToken = operands[3].lowercased()
                    let shiftParts = shiftToken.split(separator: " ").map(String.init)
                    if shiftParts.count == 2,
                       shiftParts[0] == "lsl",
                       let sh = Self.parseImmediate(shiftParts[1]) {
                        // The anchor-add must operate on the same architectural
                        // register as the branch (brRegister) and the left-hand
                        // operand must match the destination. We record the
                        // operands here unconditionally (gated only on shape):
                        // because we scan backward, the indexed load that defines
                        // `loadDestination` is seen AFTER this add, so we cannot
                        // match `addRight` against the load dest yet. The final
                        // validation cross-checks `pendingAnchorAddRight` against
                        // the load dest and `pendingAnchorAddDest` against the
                        // anchor register, so deferring is sound.
                        if Self.sameArchitecturalRegister(addDest, brRegister),
                           addDest == addLeft {
                            guard anchorAddIndex == nil else { return nil }
                            anchorAddIndex = scan
                            pendingAnchorAddDest = addDest
                            pendingAnchorAddRight = addRight
                            pendingAnchorAddShift = Int(sh)
                            roles.insert(scan)
                        }
                    }
                    continue
                }

                guard operands.count == 3 else { continue }
                let addDest = operands[0].lowercased()
                let addLeft = operands[1].lowercased()
                let addRight = operands[2].lowercased()

                if let lo12Operand = operands.last, Self.parseImmediate(lo12Operand) != nil {
                    // Base formation: add Rbase, Rbase, #imm. Defer matching the
                    // base register to the adrp leg; here we just record the
                    // pending base register and fold the numeric lo12. A symbolic
                    // @PAGEOFF operand has no immediate and is handled as an
                    // unresolved base when the adrp leg is reached.
                    if addDest == addLeft {
                        let lo12 = Self.parseImmediate(lo12Operand)!
                        if baseRegister == nil {
                            baseRegister = addDest
                        }
                        if addDest == baseRegister {
                            // Once the nearest ADRP has defined the load base,
                            // older additions belong to a killed definition.
                            // Do not fold them or exempt them as idiom roles.
                            if adrpIndex != nil { continue }
                            baseAddIndices.append(scan)
                            tableBase = (tableBase ?? 0) &+ UInt64(bitPattern: lo12)
                            roles.insert(scan)
                        }
                    }
                    continue
                }

                // Add-back: add Rbr, Rbase, Rt confirms the loaded offset is
                // relative to the table base (the signed-offset encoding).
                if addDest == brRegister {
                    guard addBackIndex == nil else { return nil }
                    addBackIndex = scan
                    roles.insert(scan)
                    if let dest = loadDestination {
                        if addRight == dest {
                            loadBaseRegister = addLeft
                            addBackConfirmed = true
                        }
                    } else {
                        // The ldrsw has not been scanned yet (it precedes this
                        // add in program order). Remember the operands; the
                        // ldrsw leg confirms the chain once seen.
                        pendingAddBackBase = addLeft
                        pendingAddBackOffset = addRight
                    }
                }
                continue

            case "adrp":
                guard operands.count == 2 else { continue }
                // Only the base register we are tracking matters. The decoder
                // resolves adrp/adr to the full page/target address.
                let reg = operands[0].lowercased()
                if baseRegister == nil || baseRegister == reg {
                    // The first ADRP encountered backward is the lexical candidate.
                    // Ordering and direct/resolved-table entry checks below must
                    // validate it before older definitions can be treated as dead.
                    if adrpIndex != nil { continue }
                    guard tableADRIndex == nil else { return nil }
                    // adrp gives the page base; a following (earlier-scanned) add
                    // already folded its lo12 into tableBase if present. Because
                    // we scan backward, adrp is seen AFTER its paired add, so add
                    // tableBase to the adrp page rather than overwrite.
                    guard let page = Self.parseAddress(operands[1]) else {
                        // Symbolic adrp (e.g. _jt@PAGE) is unresolved: bail.
                        if baseRegister == reg { return nil }
                        continue
                    }
                    baseRegister = reg
                    tableBase = (tableBase ?? 0) &+ page
                    roles.insert(scan)
                    adrpIndex = scan
                }

            case "adr":
                guard operands.count == 2 else { continue }
                let reg = operands[0].lowercased()
                // LLVM's ELF tiny code model forms the table base with ADR,
                // separately from the compact-entry code anchor. Distinguish
                // those reaching definitions by the indexed load's base, not
                // by which ADR happens to be encountered first in this scan.
                if let loadAt = loadIndex, scan < loadAt, reg == loadBaseRegister {
                    guard tableADRIndex == nil, adrpIndex == nil,
                          baseAddIndices.isEmpty, Self.is64BitRegister(reg),
                          let address = Self.parseAddress(operands[1]) else { return nil }
                    baseRegister = reg
                    tableBase = address
                    tableADRIndex = scan
                    roles.insert(scan)
                    continue
                }
                // PC-relative code anchor used for compact encodings.
                guard adrIndex == nil else { return nil }
                // Parse as absolute or PC-relative offset.
                if let abs = Self.parseAddress(operands[1]) {
                    // A literal absolute address.
                    anchorRegister = reg
                    anchor = abs
                } else if let imm = Self.parseImmediate(operands[1]) {
                    // PC-relative: anchor = current instruction address + imm.
                    anchorRegister = reg
                    // The candidate.address is the address of the adr instruction.
                    anchor = candidate.address &+ UInt64(bitPattern: imm)
                } else {
                    // Unresolved adr target (symbolic) -> bail.
                    return nil
                }
                // If an anchor-add was seen earlier it must match this dest.
                if let dest = pendingAnchorAddDest {
                    guard Self.sameArchitecturalRegister(dest, reg) else { return nil }
                }
                roles.insert(scan)
                adrIndex = scan

            case "ldrsw":
                // A load before the guard cannot be the dispatch load.
                if guardIndex != nil { continue }
                // Encoding A: 4-byte signed offset, [base, index, lsl #2].
                guard operands.count == 2 else { continue }
                guard let mem = Self.parseIndexedMemory(operands[1]), mem.shift == 2 else { continue }
                let dest = operands[0].lowercased()
                loadDestination = dest
                loadBaseRegister = mem.base
                indexRegister = mem.index
                encodingKind = .signedOffset32
                if loadIndex != nil { return nil } // two indexed loads: ambiguous
                loadIndex = scan
                roles.insert(scan)
                indexAliases = [indexRegister ?? ""]
                // Confirm a previously-seen add-back now that the load dest is
                // known: the add-back must add this load's result to the table
                // base register that the load itself indexes.
                // The add-back's base is checked at validation: it is either the table
                // base or an `adr` anchor (LLVM's 4-byte form and arm64e).
                if let pendingOffset = pendingAddBackOffset, pendingOffset == dest {
                    addBackConfirmed = true
                }

            case "ldr":
                // A load before the guard cannot be the dispatch load.
                if guardIndex != nil { continue }
                // Encoding B: either 8-byte absolute ([base, index, lsl #3]) into x,
                // or 4-byte relative ([base, index, lsl #2]) into w for adrRelative32.
                guard operands.count == 2 else { continue }
                guard let mem = Self.parseIndexedMemory(operands[1]) else { continue }
                let dest = operands[0]
                if Self.is64BitRegister(dest) {
                    // Absolute64 encoding requires lsl #3 and a 64-bit dest.
                    guard mem.shift == 3 else { continue }
                    loadDestination = dest.lowercased()
                    loadBaseRegister = mem.base
                    indexRegister = mem.index
                    encodingKind = .absolute64
                    if loadIndex != nil { return nil } // two indexed loads: ambiguous
                    loadIndex = scan
                    roles.insert(scan)
                    indexAliases = [indexRegister ?? ""]
                } else {
                    // adrRelative32: dest is 32-bit (w), mem.shift must be 2.
                    guard mem.shift == 2 else { continue }
                    loadDestination = dest.lowercased()
                    loadBaseRegister = mem.base
                    indexRegister = mem.index
                    encodingKind = .adrRelative32
                    if loadIndex != nil { return nil } // two indexed loads: ambiguous
                    loadIndex = scan
                    roles.insert(scan)
                    indexAliases = [indexRegister ?? ""]
                }

            case "ldrb":
                // A load before the guard cannot be the dispatch load.
                if guardIndex != nil { continue }
                // Unsigned byte offset: mem operand may omit the shift (two parts).
                guard operands.count == 2 else { continue }
                let dest = operands[0].lowercased()
                var base: String?
                var idx: String?
                let memOp = operands[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if let mem = Self.parseIndexedMemory(memOp) {
                    // For ldrb tables the index shift must be zero.
                    guard mem.shift == 0 else { continue }
                    base = mem.base
                    idx = mem.index
                } else {
                    // Handle the 2-part form [base, index].
                    var normalized = memOp
                    guard normalized.hasPrefix("["), normalized.hasSuffix("]") else { continue }
                    normalized.removeFirst()
                    normalized.removeLast()
                    let partsMem = Self.splitOperands(normalized)
                    guard partsMem.count == 2 else { continue }
                    let b = partsMem[0].lowercased()
                    let i = partsMem[1].lowercased()
                    guard Self.isRegister(b), Self.isRegister(i) else { continue }
                    base = b
                    idx = i
                }
                guard let b = base, let i = idx else { continue }
                loadDestination = dest
                loadBaseRegister = b
                indexRegister = i
                encodingKind = .unsignedByteOffset
                if loadIndex != nil { return nil } // two indexed loads: ambiguous
                loadIndex = scan
                roles.insert(scan)
                indexAliases = [indexRegister ?? ""]

            case "ldrh":
                // A load before the guard cannot be the dispatch load.
                if guardIndex != nil { continue }
                // Unsigned halfword offset: requires lsl #1.
                guard operands.count == 2 else { continue }
                guard let mem = Self.parseIndexedMemory(operands[1]), mem.shift == 1 else { continue }
                let dest = operands[0].lowercased()
                loadDestination = dest
                loadBaseRegister = mem.base
                indexRegister = mem.index
                encodingKind = .unsignedHalfOffset
                if loadIndex != nil { return nil } // two indexed loads: ambiguous
                loadIndex = scan
                roles.insert(scan)
                indexAliases = [indexRegister ?? ""]

            case "cmp":
                // b.hi admits indices 0...N; b.hs/b.cs admit indices 0..<N.
                // Inspect every matching bound in this scan. Conflicting counts
                // need dataflow reasoning that this local recognizer does not have.
                guard operands.count == 2 else { continue }
                // The compared register and the load's index register name the
                // same architectural register; the bounds check may use the 32-bit
                // (w) view while the load uses the 64-bit (x) view, so compare by
                // register number, not by the literal w/x spelling.
                guard let idx = indexRegister,
                      Self.sameArchitecturalRegister(operands[0], idx) else { continue }
                let nextAddress = candidate.address.addingReportingOverflow(4)
                guard scan + 1 < dispatchIndex,
                      !nextAddress.overflow,
                      rows[scan + 1].address == nextAddress.partialValue
                else { return nil }
                let boundsBranch = rows[scan + 1]
                // arm64e hardened tables clamp instead of branching:
                //   cmp x16, #N ; csel x16, x16, xzr, ls   (ls → 0...N, lo → 0..<N)
                // An out-of-range index becomes 0, so the clamp alone bounds the read.
                if boundsBranch.mnemonic.lowercased() == "csel" {
                    let selectOperands = Self.splitOperands(boundsBranch.operands)
                    guard selectOperands.count == 4,
                          Self.sameArchitecturalRegister(selectOperands[0], idx),
                          Self.sameArchitecturalRegister(selectOperands[1], idx),
                          ["xzr", "wzr"].contains(selectOperands[2].lowercased()),
                          let bound = Self.parseImmediate(operands[1]),
                          let count = Self.entryCount(
                              bound: bound,
                              branchMnemonic: selectOperands[3].lowercased() == "ls" ? "b.hi"
                                  : selectOperands[3].lowercased() == "lo" ? "b.hs" : ""
                          ) else { return nil }
                    if let existing = entryCount, existing != count { return nil }
                    entryCount = count
                    if guardIndex == nil { guardIndex = scan }
                    roles.insert(scan)
                    roles.insert(scan + 1)
                    continue
                }
                let branchOperands = Self.splitOperands(boundsBranch.operands)
                guard branchOperands.count == 1,
                      let branchTarget = Self.parseAddress(branchOperands[0]),
                      !(candidate.address < branchTarget &&
                        branchTarget <= rows[dispatchIndex].address),
                      let bound = Self.parseImmediate(operands[1]),
                      let count = Self.entryCount(
                          bound: bound,
                          branchMnemonic: boundsBranch.mnemonic.lowercased()
                      ) else { return nil }
                // A target within the protected sequence can reach dispatch even
                // when the bound fails. A tighter earlier guard also must not be
                // overwritten by a later, looser guard: decline differing counts.
                if let existing = entryCount, existing != count { return nil }
                entryCount = count
                if guardIndex == nil { guardIndex = scan }
                roles.insert(scan)

            case "mov":
                // Register-move alias tracking. clang -O2/-Os routinely aliases the switch index
                // between the bounds check and the indexed load: `cmp w0, #N` / `mov w8, w0` /
                // `ldrb [.., x8]`. The load's index register (x8) is therefore NOT the bounds
                // register (w0). When this mov writes the current index register, follow the alias
                // backward — the real index is the SOURCE register, so the earlier-scanned `cmp`
                // (on that source) can tie the bounds to the index. Guarded to a register source
                // (not `mov Wd, #imm`) that writes the tracked index register, so it can't mis-fire.
                guard operands.count == 2,
                      Self.isRegister(operands[1]),
                      let loadAt = loadIndex, scan < loadAt,
                      let idx = indexRegister,
                      Self.sameArchitecturalRegister(operands[0], idx) else { continue }
                indexRegister = operands[1].lowercased()
                indexAliases.append(operands[1].lowercased())
                roles.insert(scan)

            default:
                if Self.isControlFlowBoundary(mnemonic) {
                    // The bounds branch (b.hi/b.cs/b.hs) is allowed inside the
                    // straight-line window; any other transfer ends it. We STOP
                    // (not bail): the idiom assembled so far is validated below,
                    // so a preceding unrelated `ret`/`br` simply bounds the scan
                    // rather than rejecting an otherwise-complete dispatch.
                    if mnemonic.hasPrefix("b."),
                       ["hi", "cs", "hs"].contains(String(mnemonic.dropFirst(2))) {
                        continue
                    }
                    scan = -1
                    continue
                }
            }
        }

        // Validate the recovered idiom shape and build a full Encoding value.
        guard let encodingKind,
              let tableBase,
              let count = entryCount, count > 0,
              let loadBase = loadBaseRegister,
              let dest = loadDestination else {
            return nil
        }
        // The load base must be the formed table base register.
        guard let formedBase = baseRegister, loadBase == formedBase else { return nil }

        var finalEncoding: Encoding
        switch encodingKind {
        case .signedOffset32:
            // The add-back (add Rbr, Rbase, Rt) must connect the loaded offset to
            // the dispatched register; otherwise the offset semantics are unproven.
            guard addBackConfirmed, let loadAt = loadIndex,
                  let addBackBase = pendingAddBackBase ?? loadBaseRegister else { return nil }
            if let adrAt = adrIndex, let anchorRegister, let anchor,
               Self.sameArchitecturalRegister(anchorRegister, addBackBase) {
                guard let addAt = addBackIndex, adrAt < addAt else { return nil }
                // Entries are relative to an `adr` anchor:
                //   LLVM 4-byte form: adr x10, L; ldrsw x11, [x9, x8, lsl #2]; add x10, x10, x11
                //   arm64e hardened:  ldrsw x16, [x17, x16, lsl #2]; adr x17, L; add x16, x17, x16
                // When the anchor reuses the table-base register it must be defined after the
                // load, or it replaced the base the load read from.
                if Self.sameArchitecturalRegister(anchorRegister, formedBase), adrAt < loadAt { return nil }
                finalEncoding = .adrRelative32(anchor: anchor, scale: 0)
            } else {
                // Base-relative: the add-back adds to the table base itself, and no adr after
                // the load may have re-pointed that register.
                guard Self.sameArchitecturalRegister(addBackBase, formedBase) else { return nil }
                if let adrAt = adrIndex, adrAt > loadAt, let anchorRegister,
                   Self.sameArchitecturalRegister(anchorRegister, formedBase) { return nil }
                finalEncoding = .signedOffset32
            }
        case .absolute64:
            // The loaded value is dispatched directly: br must use the load dest.
            guard Self.sameArchitecturalRegister(dest, brRegister) else { return nil }
            finalEncoding = .absolute64
        case .unsignedByteOffset, .unsignedHalfOffset, .adrRelative32:
            // For compact encodings, an adr anchor and an anchor-add must have been seen.
            guard let aReg = anchorRegister,
                  let aVal = anchor,
                  let scale = pendingAnchorAddShift,
                  let pendingDest = pendingAnchorAddDest,
                  let pendingRight = pendingAnchorAddRight else { return nil }
            // Ensure the anchor-add operands match the load dest and the anchor register.
            guard Self.sameArchitecturalRegister(pendingRight, dest),
                  Self.sameArchitecturalRegister(pendingDest, aReg) else { return nil }
            // The branch must dispatch via the anchor register.
            guard Self.sameArchitecturalRegister(aReg, brRegister) else { return nil }
            switch encodingKind {
            case .unsignedByteOffset:
                finalEncoding = .unsignedByteOffset(anchor: aVal, scale: scale)
            case .unsignedHalfOffset:
                finalEncoding = .unsignedHalfOffset(anchor: aVal, scale: scale)
            case .adrRelative32:
                finalEncoding = .adrRelative32(anchor: aVal, scale: scale)
            default:
                // Should never happen.
                return nil
            }
        }

        if guardIndex == nil, rangeProof != nil {
            guardIndex = [adrpIndex, adrIndex, tableADRIndex].compactMap { $0 }.min()
        }
        guard let guardAt = guardIndex, let loadAt = loadIndex, guardAt < loadAt else { return nil }
        if let tableAt = tableADRIndex {
            func isGPR(_ register: String, prefix: Character) -> Bool {
                guard register.first == prefix, let number = Int(register.dropFirst()),
                      (0...30).contains(number) else { return false }
                return register == String(prefix) + String(number)
            }
            func isReachableADR(_ target: UInt64, at address: UInt64) -> Bool {
                target >= address ? target - address < 1_048_576 : address - target <= 1_048_576
            }
            // Deliberately bounded first ADR-base family: byte entries scaled by
            // four, separate 64-bit base/anchor/entry registers, and no hidden
            // side effects in the protected run. Other ADR encodings remain opaque.
            guard case .unsignedByteOffset(_, let scale) = finalEncoding, scale == 2,
                  adrpIndex == nil, baseAddIndices.isEmpty, addBackIndex == nil,
                  indexAliases.allSatisfy({ isGPR($0, prefix: "w") || isGPR($0, prefix: "x") }),
                  guardAt < tableAt, tableAt < loadAt,
                  let anchorAt = adrIndex, guardAt < anchorAt, anchorAt < loadAt,
                  let aReg = anchorRegister, let aVal = anchor,
                  isGPR(formedBase, prefix: "x"), isGPR(aReg, prefix: "x"),
                  brRegister == aReg, isGPR(dest, prefix: "w"),
                  Self.splitOperands(rows[anchorAt].operands).count == 2,
                  Self.parseAddress(Self.splitOperands(rows[anchorAt].operands)[1]) == aVal,
                  isReachableADR(tableBase, at: rows[tableAt].address),
                  isReachableADR(aVal, at: rows[anchorAt].address),
                  pendingAnchorAddRight == "x" + dest.dropFirst(),
                  !Self.sameArchitecturalRegister(formedBase, aReg),
                  !Self.sameArchitecturalRegister(formedBase, dest),
                  !Self.sameArchitecturalRegister(aReg, dest),
                  !indexAliases.contains(where: {
                      Self.sameArchitecturalRegister($0, formedBase)
                          || Self.sameArchitecturalRegister($0, aReg)
                  }),
                  aVal <= UInt64.max - (255 * 4),
                  let selector = Self.proveSelector(rows: rows, dispatchIndex: dispatchIndex),
                  selector.caseCount == count,
                  case .boundsBranch = selector.guardKind else { return nil }
            // Roles are only exempted after their exact shape has been proven.
            // A store or unfamiliar instruction is not assumed harmless here.
            for position in guardAt..<dispatchIndex {
                let next = rows[position].address.addingReportingOverflow(4)
                guard !next.overflow, next.partialValue == rows[position + 1].address,
                      roles.contains(position) || position == guardAt + 1
                        || (rows[position].mnemonic.lowercased() == "nop"
                            && Self.splitOperands(rows[position].operands).isEmpty)
                else { return nil }
            }
        }
        // A recognized shape is not a reaching definition. Base additions must
        // precede the load, while additions consuming its result must follow it.
        // Multiple definitions remain opaque rather than being summed backward.
        guard adrpIndex.map({ $0 < loadAt }) ?? true,
              tableADRIndex.map({ $0 < loadAt }) ?? true,
              baseAddIndices.allSatisfy({ position in
            position < loadAt && adrpIndex.map { $0 < position } == true
        }), addBackIndex.map({ $0 > loadAt }) ?? true,
            anchorAddIndex.map({ addAt in
                addAt > loadAt && adrIndex.map { $0 < addAt } == true
            }) ?? true
        else { return nil }
        // The bound proves a range for the GUARDED value only. Any write between the
        // guard and the dispatch to the index (or an alias the scan followed), the table
        // base, the loaded entry or the dispatch register breaks that proof, e.g.
        // `cmp w0, #2; b.hi d; add w0, w0, #1; ...; ldr x9, [x8, x0, lsl #3]` loads
        // entries 1...3, not 0...2. Abstain rather than fabricate cases.
        let scanStart = min(guardAt, adrpIndex ?? guardAt, adrIndex ?? guardAt) + 1
        if scanStart < dispatchIndex {
            for position in scanStart..<dispatchIndex where !roles.contains(position) {
                let written = Self.writtenRegisters(rows[position])
                guard !written.isEmpty else { continue }
                func clobbers(_ register: String?) -> Bool {
                    guard let register, !register.isEmpty else { return false }
                    return written.contains { Self.sameArchitecturalRegister($0, register) }
                }
                if position > guardAt, position < loadAt, indexAliases.contains(where: clobbers) { return nil }
                if let adrpAt = adrpIndex, position > adrpAt, position < loadAt, clobbers(formedBase) { return nil }
                if position > loadAt, clobbers(dest) || clobbers(brRegister) { return nil }
                if let addAt = addBackIndex, position > loadAt, position < addAt,
                   clobbers(pendingAddBackBase) { return nil }
                if let adrAt = adrIndex, position > adrAt, clobbers(anchorRegister) { return nil }
            }
        }
        // The selector guard and each selected base/add/anchor are distinct
        // obligations. Protect the earliest required definition through dispatch,
        // including the load, with no exemption for sources inside the scan.
        // A target at the first definition executes it; a target after it does not.
        let definitions = [guardAt] + [adrpIndex, tableADRIndex, adrIndex].compactMap { $0 }
            + baseAddIndices
        let protectedStart = rows[definitions.min()!].address
        let protectedEnd = rows[dispatchIndex].address
        guard Self.directAndResolvedTablePathsReachLoad(rows: rows,
            protectedStart: protectedStart, protectedEnd: protectedEnd),
              let targets = readTargets(tableBase: tableBase, count: count,
                encoding: finalEncoding, readBytes: readBytes, codeRange: codeRange)
        else { return nil }
        // The caller closes this candidate over all decoded table edges before
        // publication; a local selector proof alone cannot grant that certificate.
        return Candidate(targets: targets, protectedStartAddress: protectedStart,
            protectedEndAddress: protectedEnd,
            zeroExtensionDefinitionAddress: zeroExtensionDefinitionAddress)
    }

    private func readTargets(
        tableBase: UInt64,
        count: Int,
        encoding: Encoding,
        readBytes: ByteReader,
        codeRange: CodeRange
    ) -> [UInt64]? {
        guard count > 0, count <= Self.maximumRecoveredCaseCount else { return nil }
        let stride = encoding.stride
        var targets: [UInt64] = []
        targets.reserveCapacity(count)

        for i in 0..<count {
            // Checked arithmetic: a table near the top of the address space must not wrap
            // around and read low memory as case entries.
            let offset = UInt64(i).multipliedReportingOverflow(by: UInt64(stride))
            guard !offset.overflow else { return nil }
            let sum = tableBase.addingReportingOverflow(offset.partialValue)
            guard !sum.overflow else { return nil }
            let entryAddress = sum.partialValue
            guard let data = readBytes(entryAddress, stride), data.count == stride else {
                return nil
            }
            let bytes = [UInt8](data)
            let target: UInt64
            switch encoding {
            case .signedOffset32:
                let raw = Int32(
                    bitPattern: UInt32(bytes[0])
                        | (UInt32(bytes[1]) << 8)
                        | (UInt32(bytes[2]) << 16)
                        | (UInt32(bytes[3]) << 24)
                )
                target = UInt64(bitPattern: Int64(bitPattern: tableBase) &+ Int64(raw))
            case .absolute64:
                var value: UInt64 = 0
                for byteIndex in 0..<8 {
                    value |= UInt64(bytes[byteIndex]) << (8 * byteIndex)
                }
                target = value
            case .unsignedByteOffset(let anchor, let scale):
                let value = UInt64(bytes[0])
                let offset = value << UInt64(scale)
                target = anchor &+ offset
            case .unsignedHalfOffset(let anchor, let scale):
                let value = UInt64(bytes[0]) | (UInt64(bytes[1]) << 8)
                let offset = value << UInt64(scale)
                target = anchor &+ offset
            case .adrRelative32(let anchor, let scale):
                let raw = Int32(
                    bitPattern: UInt32(bytes[0])
                        | (UInt32(bytes[1]) << 8)
                        | (UInt32(bytes[2]) << 16)
                        | (UInt32(bytes[3]) << 24)
                )
                let offset = Int64(raw) << scale
                target = UInt64(bitPattern: Int64(bitPattern: anchor) &+ offset)
            }

            // ARM64 instructions are word-aligned, and every target must land in
            // the executable text range. Any failure drops the whole site.
            guard target % 4 == 0, codeRange.contains(target) else { return nil }
            targets.append(target)
        }

        return targets
    }

    // MARK: - Encoding

    /// The kind of encoding observed during the backward scan, before the
    /// anchor/scale needed for a full `Encoding` value are known.
    private enum EncodingKind {
        case signedOffset32
        case absolute64
        case unsignedByteOffset
        case unsignedHalfOffset
        case adrRelative32
    }

    private enum Encoding: Sendable, Equatable {
        case signedOffset32
        case absolute64
        /// A dense unsigned byte offset table. Each entry is zero-extended from a
        /// single byte, left-shifted by `scale`, and then added to an `adr`
        /// anchor to form the absolute target.
        case unsignedByteOffset(anchor: UInt64, scale: Int)
        /// A dense unsigned halfword (16-bit) offset table. Each entry is
        /// zero-extended from two bytes, left-shifted by `scale`, and then
        /// added to the `adr` anchor to form the absolute target.
        case unsignedHalfOffset(anchor: UInt64, scale: Int)
        /// A 32-bit relative offset table measured from an `adr` anchor. Each
        /// 4‑byte entry is sign-extended, left-shifted by `scale`, and then
        /// added to the anchor.
        case adrRelative32(anchor: UInt64, scale: Int)

        var stride: Int {
            switch self {
            case .signedOffset32: return 4
            case .absolute64: return 8
            case .unsignedByteOffset: return 1
            case .unsignedHalfOffset: return 2
            case .adrRelative32: return 4
            }
        }
    }

    // MARK: - Operand parsing (value-flow-neutral, mirrors MacIRBuilder syntax)

    private struct IndexedMemory {
        var base: String
        var index: String
        var shift: Int
    }

    /// Parses `[base, index, lsl #k]` into its components. Returns nil for any
    /// other shape (no index, missing shift, non-register parts).
    private static func parseIndexedMemory(_ operand: String) -> IndexedMemory? {
        var normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("["), normalized.hasSuffix("]") else { return nil }
        normalized.removeFirst()
        normalized.removeLast()
        let parts = splitOperands(normalized)
        guard parts.count == 3 else { return nil }

        let base = parts[0].lowercased()
        let index = parts[1].lowercased()
        guard isRegister(base), isRegister(index) else { return nil }

        // Third part must be "lsl #k".
        let shiftTokens = parts[2].lowercased().split(separator: " ").map(String.init)
        guard shiftTokens.count == 2, shiftTokens[0] == "lsl" else { return nil }
        guard let shift = parseImmediate(shiftTokens[1]), shift >= 0 else { return nil }
        return IndexedMemory(base: base, index: index, shift: Int(shift))
    }

    /// Parses an absolute address operand (decimal or hex). Symbolic operands
    /// such as `_jt@PAGE` return nil so the caller bails.
    private static func parseAddress(_ operand: String) -> UInt64? {
        let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("0x") {
            return UInt64(normalized.dropFirst(2), radix: 16)
        }
        if normalized.allSatisfy(\.isNumber), !normalized.isEmpty {
            return UInt64(normalized)
        }
        return nil
    }

    private static func parseImmediate(_ operand: String) -> Int64? {
        var normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("#") {
            normalized.removeFirst()
        }
        let sign: Int64
        if normalized.hasPrefix("-") {
            sign = -1
            normalized.removeFirst()
        } else {
            sign = 1
        }
        if normalized.hasPrefix("0x") {
            return Int64(normalized.dropFirst(2), radix: 16).map { sign * $0 }
        }
        return Int64(normalized).map { sign * $0 }
    }

    private static func splitOperands(_ text: String) -> [String] {
        var operands: [String] = []
        var current = ""
        var bracketDepth = 0
        for character in text {
            switch character {
            case "[":
                bracketDepth += 1
                current.append(character)
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
            case "," where bracketDepth == 0:
                operands.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll(keepingCapacity: true)
            default:
                current.append(character)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            operands.append(tail)
        }
        return operands
    }

    private static func isRegister(_ operand: String) -> Bool {
        guard let first = operand.first else { return false }
        guard ["x", "w", "s", "d", "q", "v"].contains(first)
            || operand == "sp" || operand == "fp" || operand == "lr" else {
            return false
        }
        return operand.dropFirst().allSatisfy(\.isNumber) || ["sp", "fp", "lr"].contains(operand)
    }

    private static func is64BitRegister(_ operand: String) -> Bool {
        operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().first == "x"
    }

    /// True when two general-purpose register operands refer to the same
    /// architectural register regardless of the 32-bit (w) / 64-bit (x) view,
    /// e.g. `w0` and `x0`.
    private static func sameArchitecturalRegister(_ lhs: String, _ rhs: String) -> Bool {
        func number(_ operand: String) -> String? {
            let normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let first = normalized.first, first == "x" || first == "w" else { return nil }
            let digits = normalized.dropFirst()
            return digits.allSatisfy(\.isNumber) && !digits.isEmpty ? String(digits) : nil
        }
        guard let lhsNumber = number(lhs), let rhsNumber = number(rhs) else {
            return lhs.lowercased() == rhs.lowercased()
        }
        return lhsNumber == rhsNumber
    }

    /// General-purpose registers an instruction writes, conservatively: the first operand
    /// of any non-store, non-compare instruction, both destinations of a load pair, the
    /// base of a pre/post-indexed (writeback) memory operand, a bare `xN!` writeback
    /// register (MOPS), and the explicit write sets of `ARM64ExplicitRegisterWrites`.
    private static func writtenRegisters<Row: DecompilerInstructionRow>(_ row: Row) -> [String] {
        let mnemonic = row.mnemonic.lowercased()
        let operands = splitOperands(row.operands).map { $0.lowercased() }
        var written: [String] = []
        for (position, operand) in operands.enumerated() {
            if operand.hasPrefix("[") {
                let base = String(operand.dropFirst().prefix { $0 != "," && $0 != "]" })
                    .trimmingCharacters(in: .whitespaces)
                let preIndexed = operand.hasSuffix("]!")
                let postIndexed = operand.hasSuffix("]") && !operand.contains(",") && position + 1 < operands.count
                if preIndexed || postIndexed { written.append(base) }
            } else if operand.hasSuffix("!"), isRegister(String(operand.dropLast())) {
                written.append(String(operand.dropLast()))
            }
        }
        if isControlFlowBoundary(mnemonic) { return written }
        if let explicit = ARM64ExplicitRegisterWrites.writes(mnemonic: mnemonic, operands: operands) {
            return written + explicit
        }
        let noDestination: Set<String> = [
            "cmp", "cmn", "tst", "ccmp", "ccmn", "fcmp", "fcmpe", "fccmp", "fccmpe", "nop",
            "prfm", "prfum", "dmb", "dsb", "isb", "hint", "bti", "yield", "msr", "sev", "sevl",
            "wfe", "wfi", "clrex", "brk", "hlt", "udf", "svc",
        ]
        if noDestination.contains(mnemonic) { return written }
        // Stores write memory, not their first operand, except the exclusive-store status register.
        if mnemonic.hasPrefix("st"), !mnemonic.hasPrefix("stx"), !mnemonic.hasPrefix("stlx") {
            return written
        }
        if ["ldp", "ldnp", "ldpsw", "ldxp", "ldaxp"].contains(mnemonic), operands.count >= 2 {
            return written + operands.prefix(2)
        }
        if let first = operands.first, isRegister(first) { written.append(first) }
        return written
    }

    private static func isDirectBranchMnemonic(_ mnemonic: String) -> Bool {
        ["b", "bl", "cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic)
            || mnemonic.hasPrefix("b.") || mnemonic.hasPrefix("bc.")
    }

    private static func isIndirectBranchMnemonic(_ mnemonic: String) -> Bool {
        ["br", "braa", "brab", "braaz", "brabz"].contains(mnemonic)
    }

    /// One entry predicate for selector, selected definitions and decoded table
    /// edges. It deliberately refuses internal back-edges too: this local proof
    /// does not establish a closed, non-clobbering loop around the definitions.
    /// Unknown indirect destinations are outside the certificate and counted by
    /// `resolveWithCertificates`; an unparseable direct destination fails closed.
    private static func directAndResolvedTablePathsReachLoad<Row: DecompilerInstructionRow>(
        rows: [Row], protectedStart: UInt64, protectedEnd: UInt64,
        resolvedTableTargets: [UInt64] = [], zeroExtensionDefinitionAddress: UInt64? = nil
    ) -> Bool {
        func bypasses(_ target: UInt64, after start: UInt64) -> Bool {
            target > start && target <= protectedEnd
        }
        for row in rows where isDirectBranchMnemonic(row.mnemonic.lowercased()) {
            guard let target = directBranchTarget(row), !bypasses(target, after: protectedStart)
            else { return false }
        }
        // Existing direct closed-run reasoning separately protects W zero extension.
        // Do not extend that exception to newly decoded table edges: they must also
        // execute the earlier W definition before a load using its X view.
        let tableStart = min(protectedStart, zeroExtensionDefinitionAddress ?? protectedStart)
        return !resolvedTableTargets.contains { bypasses($0, after: tableStart) }
    }

    private static func directBranchTarget<Row: DecompilerInstructionRow>(_ row: Row) -> UInt64? {
        let mnemonic = row.mnemonic.lowercased()
        guard isDirectBranchMnemonic(mnemonic) else { return nil }
        let operands = splitOperands(row.operands)
        guard mnemonic == "bl" else { return operands.last.flatMap(parseAddress) }
        guard operands.count == 1 else { return nil }
        let textualTarget = parseAddress(operands[0])
        // Rendering symbolizes direct calls while retaining their instruction
        // bytes. A symbol (including a displayed addend) is not address authority:
        // the exact BL word supplies the target. Numeric text must agree with it.
        // Preserve existing numeric, bytes-empty fixtures; symbolic or malformed
        // bytes never gain that compatibility exemption.
        if row.bytes.isEmpty { return textualTarget }
        guard let encodedTarget = encodedBLTarget(row),
              textualTarget == nil || textualTarget == encodedTarget else { return nil }
        return encodedTarget
    }

    private static func encodedBLTarget<Row: DecompilerInstructionRow>(_ row: Row) -> UInt64? {
        let tokens = row.bytes.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 4, row.address % 4 == 0 else { return nil }
        var word: UInt32 = 0
        for (index, token) in tokens.enumerated() {
            guard token.utf8.count == 2,
                  token.utf8.allSatisfy({ (0x30...0x39).contains($0) ||
                      (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }),
                  let byte = UInt8(token, radix: 16) else { return nil }
            word |= UInt32(byte) << (index * 8)
        }
        guard word & 0xfc00_0000 == 0x9400_0000 else { return nil }
        let immediate = Int64(word & 0x03ff_ffff)
        let signedImmediate = immediate & 0x0200_0000 == 0 ? immediate : immediate - 0x0400_0000
        let displacement = signedImmediate * 4
        // Decline address wrap rather than model modulo-2^64 machine addresses.
        if displacement >= 0 {
            let target = row.address.addingReportingOverflow(UInt64(displacement))
            return target.overflow ? nil : target.partialValue
        }
        let target = row.address.subtractingReportingOverflow(UInt64(-displacement))
        return target.overflow ? nil : target.partialValue
    }

    private static func isControlFlowBoundary(_ mnemonic: String) -> Bool {
        switch mnemonic {
        case "b", "bl", "blr", "br", "ret", "cbz", "cbnz", "tbz", "tbnz":
            return true
        default:
            return mnemonic.hasPrefix("b.")
        }
    }
}

// MARK: - Switch selector proof

/// The proven identity of the value a recovered jump-table switch dispatches on.
///
/// Table targets alone prove only the switch's DESTINATIONS. Naming the switch's
/// selector additionally requires proof that a specific SSA definition is the value
/// that indexes the table, so the lowering can reference that exact definition
/// instead of whatever the register happens to hold at the `br` (compilers routinely
/// reuse the index register for the loaded entry or the computed target).
///
/// This is the single selector model for jump-table dispatch: the resolver's idiom
/// knowledge (adjacent bounds pairs, `xzr` clamps, register write sets, guard-bypass
/// rejection) proves it, and `MacIRBuilder` consumes it when it lowers a `br` with
/// supplied table targets. When no proof exists the lowering keeps the proven case
/// edges but abstains from naming a selector.
struct JumpTableSelectorProof: Sendable, Equatable {
    enum Guard: Sendable, Equatable {
        /// `cmp R, #N` immediately followed by `b.hi`/`b.hs`/`b.cs default`. The
        /// selector is `R` as read by the `cmp`; out-of-range values leave through
        /// `defaultTarget` (nil when the branch target is not a numeric address).
        case boundsBranch(defaultTarget: UInt64?)
        /// `cmp R, #N` immediately followed by `csel R, R, xzr|wzr, ls|lo` with no
        /// bounds branch. The selector is the CLAMPED `R` written by the `csel`;
        /// every value of it is an in-range case, so there is no default exit.
        case clamp
        /// A CFG interval fixpoint proves the index immediately before its load.
        case boundedRange
    }

    /// The instruction after whose lifting `register` holds the selector value: the
    /// `cmp` of a bounds branch (which writes no register) or the clamping `csel`.
    var definitionAddress: UInt64
    /// The register (as spelled at the definition) that holds the selector.
    var register: String
    /// The number of in-range cases the guard admits (indices `0..<caseCount`).
    var caseCount: Int
    var guardKind: Guard
}

extension JumpTableResolver {
    /// Proves which value indexes the jump table dispatched by the `br` at
    /// `dispatchIndex`, or returns nil when that cannot be shown locally.
    ///
    /// The proof requires, inside the straight-line run that ends at the `br`:
    /// 1. one guard — an adjacent `cmp R, #N` + bounds branch, or (absent a bounds
    ///    branch) exactly one adjacent `cmp R, #N` + `csel R, R, zr, ls|lo` clamp;
    /// 2. exactly one register-indexed load after the guard, whose index register
    ///    still carries the guarded value — directly or through register `mov`s —
    ///    with no intervening write to it (a later clamp that admits at least the
    ///    guarded range is the identity on that range and preserves the value);
    /// 3. no direct branch from elsewhere landing after the guard and at or before
    ///    the dispatch (which would reach the load with an unguarded index).
    ///
    /// Writes AFTER the indexed load (for example `ldrsw x8, [x9, x8, lsl #2]`
    /// reusing the index register) do not invalidate the proof: the lowering
    /// references the SSA definition at `definitionAddress`, not the register's
    /// value at the dispatch.
    static func proveSelector<Row: DecompilerInstructionRow>(
        rows: [Row],
        dispatchIndex: Int,
        resolvedTableTargets: [UInt64] = []
    ) -> JumpTableSelectorProof? {
        proveSelectorCertificate(rows: rows, dispatchIndex: dispatchIndex,
            resolvedTableTargets: resolvedTableTargets)?.proof
    }

    private static func proveSelectorCertificate<Row: DecompilerInstructionRow>(
        rows: [Row], dispatchIndex: Int, resolvedTableTargets: [UInt64] = []
    ) -> SelectorCertificate? {
        guard dispatchIndex > 0, dispatchIndex < rows.count else { return nil }

        func isAdjacent(_ first: Int, _ second: Int) -> Bool {
            let next = rows[first].address.addingReportingOverflow(4)
            return !next.overflow && rows[second].address == next.partialValue
        }
        // `cmp R, #N` at `cmpAt` immediately followed by `csel R, R, zr, ls|lo`:
        // returns the clamped register and the admitted case count.
        func clamp(at cmpAt: Int) -> (register: String, count: Int)? {
            guard cmpAt + 1 < dispatchIndex,
                  rows[cmpAt].mnemonic.lowercased() == "cmp",
                  rows[cmpAt + 1].mnemonic.lowercased() == "csel",
                  isAdjacent(cmpAt, cmpAt + 1) else { return nil }
            let compare = splitOperands(rows[cmpAt].operands)
            let select = splitOperands(rows[cmpAt + 1].operands)
            guard compare.count == 2, select.count == 4,
                  isRegister(compare[0].lowercased()),
                  sameArchitecturalRegister(select[0], compare[0]),
                  sameArchitecturalRegister(select[1], compare[0]),
                  compare[0].lowercased() == select[0].lowercased(),
                  select[0].lowercased() == select[1].lowercased(),
                  ["xzr", "wzr"].contains(select[2].lowercased()),
                  let bound = parseImmediate(compare[1]) else { return nil }
            let condition = select[3].lowercased()
            let branchEquivalent = condition == "ls" ? "b.hi" : condition == "lo" ? "b.hs" : ""
            guard let count = entryCount(bound: bound, branchMnemonic: branchEquivalent) else { return nil }
            return (select[0].lowercased(), count)
        }

        // Straight-line window ending at the dispatch, bounded like the resolver's scan.
        var windowStart = dispatchIndex
        var boundary: Int?
        var steps = 0
        while windowStart > 0, steps < 24 {
            let candidate = windowStart - 1
            let mnemonic = rows[candidate].mnemonic.lowercased()
            // Also stop at the arm64e authenticated forms and any other branch/return
            // family member the resolver's narrower boundary set does not name.
            if isControlFlowBoundary(mnemonic) || mnemonic.hasPrefix("br") || mnemonic.hasPrefix("bl")
                || mnemonic.hasPrefix("ret") || mnemonic.hasPrefix("eret") {
                boundary = candidate
                break
            }
            windowStart = candidate
            steps += 1
        }

        let guardAt: Int
        let trackingStart: Int
        let bypassExemption: Int?
        let proof: JumpTableSelectorProof
        if let boundary,
           ["b.hi", "b.hs", "b.cs"].contains(rows[boundary].mnemonic.lowercased()),
           boundary > 0,
           rows[boundary - 1].mnemonic.lowercased() == "cmp",
           isAdjacent(boundary - 1, boundary) {
            let compare = splitOperands(rows[boundary - 1].operands)
            guard compare.count == 2,
                  isRegister(compare[0].lowercased()),
                  let bound = parseImmediate(compare[1]),
                  let count = entryCount(bound: bound, branchMnemonic: rows[boundary].mnemonic.lowercased())
            else { return nil }
            let branchOperands = splitOperands(rows[boundary].operands)
            let defaultTarget = branchOperands.count == 1 ? parseAddress(branchOperands[0]) : nil
            // A default exit that lands inside the protected run would reach the
            // dispatch with an unguarded index.
            if let defaultTarget,
               defaultTarget > rows[boundary - 1].address,
               defaultTarget <= rows[dispatchIndex].address { return nil }
            guardAt = boundary - 1
            trackingStart = boundary + 1
            bypassExemption = boundary
            proof = JumpTableSelectorProof(
                definitionAddress: rows[guardAt].address,
                register: compare[0].lowercased(),
                caseCount: count,
                guardKind: .boundsBranch(defaultTarget: defaultTarget)
            )
        } else {
            let clamps = (windowStart..<dispatchIndex).compactMap { position in
                clamp(at: position).map { (position, $0) }
            }
            guard clamps.count == 1, let only = clamps.first else { return nil }
            let cmpAt = only.0
            let clamped = only.1
            guardAt = cmpAt
            bypassExemption = nil
            trackingStart = cmpAt + 2
            proof = JumpTableSelectorProof(
                definitionAddress: rows[cmpAt + 1].address,
                register: clamped.register,
                caseCount: clamped.count,
                guardKind: .clamp
            )
        }

        // A W-register write zero-extends into the architectural X register, but
        // comparing Wn alone does not prove anything about the existing upper half
        // of Xn. Preserve that distinction while tracking selector aliases. Returns the
        // straight-line W definition that zero-extends Xn, or nil.
        func zeroExtendingDefinition(_ register: String, before end: Int) -> Int? {
            guard register.first == "w", let architectural = Int(register.dropFirst()) else { return nil }
            guard end > 0 else { return nil }
            var cursor = end - 1
            var inspected = 0
            while cursor >= 0, inspected < 24 {
                let row = rows[cursor]
                let mnemonic = row.mnemonic.lowercased()
                if isControlFlowBoundary(mnemonic) || mnemonic.hasPrefix("br") || mnemonic.hasPrefix("bl")
                    || mnemonic.hasPrefix("ret") || mnemonic.hasPrefix("eret") { return nil }
                let writes = writtenRegisters(row)
                if let definition = writes.first(where: { sameArchitecturalRegister($0, register) }) {
                    guard definition.first == "w",
                          Int(definition.dropFirst()) == architectural else { return nil }
                    return cursor
                }
                cursor -= 1
                inspected += 1
            }
            return nil
        }
        let zeroExtension = zeroExtendingDefinition(proof.register, before: guardAt)

        // Forward value tracking from the guard to the single indexed load.
        var carriers: [(register: String, zeroExtended: Bool)] = [
            (
                register: proof.register,
                zeroExtended: zeroExtension != nil
            )
        ]
        func carries(_ register: String) -> Bool {
            carriers.contains { carrier in
                carrier.register == register
                    || (sameArchitecturalRegister(carrier.register, register)
                        && (register.first == "w" || carrier.zeroExtended))
            }
        }
        var loadIndexIsSelector: Bool?
        var position = trackingStart
        while position < dispatchIndex {
            defer { position += 1 }
            let row = rows[position]
            let mnemonic = row.mnemonic.lowercased()
            let operands = splitOperands(row.operands).map { $0.lowercased() }

            if mnemonic.hasPrefix("ldr"), operands.count == 2,
               let index = registerIndexOfMemoryOperand(operands[1]) {
                // Two indexed loads: which one indexes the table is ambiguous.
                guard loadIndexIsSelector == nil else { return nil }
                loadIndexIsSelector = carries(index)
            }
            // Only the path from the guard to the load matters for the selector.
            guard loadIndexIsSelector == nil else { continue }

            if mnemonic == "mov", operands.count == 2,
               isRegister(operands[0]), isRegister(operands[1]) {
                let source = operands[1]
                let destination = operands[0]
                let sourceCarrier = carriers.first { carries(source) && $0.register == source }
                let carried = sourceCarrier != nil
                carriers.removeAll { sameArchitecturalRegister($0.register, operands[0]) }
                if carried {
                    carriers.append((
                        register: destination,
                        zeroExtended: destination.first == "w" || sourceCarrier!.zeroExtended
                    ))
                }
                continue
            }
            // A clamp of a carrier that admits at least the guarded range is the
            // identity on the guarded value (arm64e hardened dispatch).
            if mnemonic == "cmp", let reclamp = clamp(at: position), carries(reclamp.register) {
                guard reclamp.count >= proof.caseCount else { return nil }
                position += 1 // skip the csel; its write preserves the carried value
                continue
            }
            let written = writtenRegisters(row)
            carriers.removeAll { carrier in
                written.contains { sameArchitecturalRegister($0, carrier.register) }
            }
        }
        guard loadIndexIsSelector == true else { return nil }

        // A direct branch from elsewhere that lands after the guard and at or before
        // the dispatch reaches the indexed load without the guard (guard bypass). When
        // the upper bits rest on an earlier W definition, an entry after it, including
        // one exactly at the compare, bypasses that definition too (#672).
        // This call proves only the selector's entry obligation, using any known
        // table edges supplied by its caller. The resolver's early call is provisional:
        // it later protects selected definitions against every decoded table edge.
        guard directAndResolvedTablePathsReachLoad(rows: rows,
            protectedStart: rows[guardAt].address, protectedEnd: rows[dispatchIndex].address,
            resolvedTableTargets: resolvedTableTargets,
            zeroExtensionDefinitionAddress: zeroExtension.map { rows[$0].address })
        else { return nil }
        if let definition = zeroExtension,
           !zeroExtensionReachesCompare(rows: rows, definition: definition, compare: guardAt,
                                        register: proof.register, exempt: bypassExemption) {
            return nil
        }
        return SelectorCertificate(proof: proof,
            zeroExtensionDefinitionAddress: zeroExtension.map { rows[$0].address })
    }

    /// #672: entries that land after the zero-extending W definition and at or before the
    /// compare must not bypass it. Such an entry is admitted only from inside a closed run
    /// `[definition, source]` (a loop back-edge): nothing outside the run enters it and
    /// nothing in it calls or writes the register's X view without re-zeroing it.
    private static func zeroExtensionReachesCompare<Row: DecompilerInstructionRow>(
        rows: [Row], definition: Int, compare: Int, register: String, exempt: Int?
    ) -> Bool {
        let start = rows[definition].address
        let compareAddress = rows[compare].address
        var end = definition
        var changed = true
        while changed {
            changed = false
            for (index, row) in rows.enumerated() where index != exempt {
                guard let target = directBranchTarget(row) else { continue }
                let entersCompareWindow = target > start && target <= compareAddress
                let entersRun = target > start && target <= rows[end].address
                guard entersCompareWindow || entersRun else { continue }
                // An entry from before the definition (or outside the function order) bypasses it.
                guard index > definition else { return false }
                if index > end { end = index; changed = true }
            }
        }
        guard end > definition else { return true }
        for index in (definition + 1)...end {
            let written = writtenRegisters(rows[index])
            if written.contains(where: { sameArchitecturalRegister($0, register) && $0.first != "w" }) {
                return false
            }
            // A call in the run may clobber the register on the back-edge path.
            if rows[index].mnemonic.lowercased().hasPrefix("bl") { return false }
        }
        return true
    }

    /// The index register of a register-offset memory operand (`[base, index]`,
    /// `[base, index, lsl #k]`, `[base, windex, uxtw #k]`), or nil for any other form.
    private static func registerIndexOfMemoryOperand(_ operand: String) -> String? {
        var normalized = operand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("["), normalized.hasSuffix("]") else { return nil }
        normalized.removeFirst()
        normalized.removeLast()
        let parts = splitOperands(normalized).map { $0.lowercased() }
        guard parts.count == 2 || parts.count == 3,
              isRegister(parts[0]), isRegister(parts[1]),
              parts[1].first == "x" || parts[1].first == "w" else { return nil }
        return parts[1]
    }
}

extension JumpTableResolver {
    static func rangeWrittenRegisters<Row: DecompilerInstructionRow>(_ row: Row) -> [String] {
        writtenRegisters(row)
    }
    static func proveRegionSelector<Row: DecompilerInstructionRow>(rows: [Row], dispatchIndex: Int,
        jumpTables: [UInt64: [UInt64]]) -> JumpTableSelectorProof? {
        proveSelector(rows: rows, dispatchIndex: dispatchIndex,
            resolvedTableTargets: jumpTables.values.flatMap { $0 })
            ?? JumpTableRangeAnalysis.prove(rows: rows, dispatchIndex: dispatchIndex, jumpTables: jumpTables)
    }
}
