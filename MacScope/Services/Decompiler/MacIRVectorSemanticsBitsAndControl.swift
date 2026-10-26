import Foundation

// MARK: - MacIRNEONBitCount

/// Exact-width integer per-lane counts; no reduction or normalization inference.
public struct MacIRNEONBitCount: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case cnt, clz, cls }
    public let kind: Kind
    public let elementBytes: Int
    public let activeBytes: Int
    public init?(kind: Kind, elementBytes: Int, activeBytes: Int) {
        guard [8,16].contains(activeBytes), [1,2,4].contains(elementBytes),
              kind != .cnt || elementBytes == 1 else { return nil }
        self.kind = kind; self.elementBytes = elementBytes; self.activeBytes = activeBytes
    }
}

// MARK: - MacIRNEONBitView

/// Bounded integer-bit transfers. No FP operation, conversion, ABI or FPCR claim.
/// Every vector result defines one full physical 128-bit carrier; views are
/// carried by this descriptor, never inferred by the concrete consumer's spelling.
public struct MacIRNEONBitView: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case gprToScalar, scalarToGPR, duplicateGPR, duplicateElement, insertElement, insertGPR, unsignedMoveElement
    }
    public let kind: Kind
    public let elementBits: Int
    public let activeBytes: Int
    public let sourceLane: Int
    public let destinationLane: Int

    public init?(kind: Kind, elementBits: Int, activeBytes: Int = 16,
                 sourceLane: Int = 0, destinationLane: Int = 0) {
        guard [8, 16, 32, 64].contains(elementBits),
              (elementBits >= 32 || kind == .insertElement || kind == .insertGPR || kind == .unsignedMoveElement),
              activeBytes == 8 || activeBytes == 16,
              (0..<(128 / elementBits)).contains(sourceLane),
              (0..<(128 / elementBits)).contains(destinationLane) else { return nil }
        switch kind {
        case .gprToScalar, .scalarToGPR:
            guard activeBytes == 16, sourceLane == 0, destinationLane == 0 else { return nil }
        case .duplicateGPR:
            guard sourceLane == 0, destinationLane == 0,
                  elementBits != 64 || activeBytes == 16 else { return nil }
        case .duplicateElement:
            guard destinationLane == 0, elementBits != 64 || activeBytes == 16 else { return nil }
        case .insertElement:
            guard activeBytes == 16 else { return nil }
        case .insertGPR:
            guard activeBytes == 16, sourceLane == 0 else { return nil }
        case .unsignedMoveElement:
            guard activeBytes == 16, destinationLane == 0 else { return nil }
        }
        self.kind = kind; self.elementBits = elementBits; self.activeBytes = activeBytes
        self.sourceLane = sourceLane; self.destinationLane = destinationLane
    }
    public var intrinsicName: String { "neon_bitview_\(kind.rawValue)_\(elementBits)_\(activeBytes)_\(sourceLane)_\(destinationLane)" }
    public var readsOldDestination: Bool { kind == .insertElement || kind == .insertGPR }
    public var sourceIsGPR: Bool { kind == .gprToScalar || kind == .duplicateGPR || kind == .insertGPR }
    public var resultIsGPR: Bool { kind == .scalarToGPR || kind == .unsignedMoveElement }
    public var elementMask: UInt64 { elementBits == 64 ? .max : (UInt64(1) << elementBits) - 1 }

    public func selectedBits(low: UInt64, high: UInt64) -> UInt64 {
        let bit = sourceLane * elementBits
        return ((bit < 64 ? low : high) >> (bit % 64)) & elementMask
    }

    /// Full write semantics: FMOV into S/D zeros all higher physical bits;
    /// DUP Q0 zeros high64; INS preserves every non-selected destination bit.
    public func vectorBits(sourceLow: UInt64, sourceHigh: UInt64,
                           oldLow: UInt64 = 0, oldHigh: UInt64 = 0) -> (low: UInt64, high: UInt64) {
        let bits = selectedBits(low: sourceLow, high: sourceHigh)
        if kind == .gprToScalar { return (bits, 0) }
        if kind == .insertElement || kind == .insertGPR {
            let bit = destinationLane * elementBits, shift = bit % 64
            let mask = elementMask << shift
            if bit < 64 { return ((oldLow & ~mask) | (bits << shift), oldHigh) }
            return (oldLow, (oldHigh & ~mask) | (bits << shift))
        }
        // Only DUP callers consume this branch. GPR result uses selectedBits.
        let half = elementBits == 32 ? bits | (bits << 32) : bits
        return (half, activeBytes == 8 ? 0 : half)
    }
}

// MARK: - MacIRNEONBitmapDistanceScore

/// DOT85 certifies an exhaustive composition of existing23/44/39/32/31 operations.
/// It owns neither arithmetic nor a scalar-return ABI, and adds no metadata field.
public struct MacIRNEONBitmapDistanceScore: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case intersection16b, difference16b, count16b, unsignedSumH, extractH0, fmovHZeroComplement, loadQ, nop, terminal }
    public struct Entry: Hashable, Sendable {
        public let family: Family
        public let rowOrdinal: Int
        public let identity: MacIRInstruction.Identity
        public let qTransferOrdinal: Int?
        public let source: MacIRValue?
        public let secondarySource: MacIRValue?
        public let destination: MacIRValue?
        public init(family: Family, rowOrdinal: Int, identity: MacIRInstruction.Identity,
                    qTransferOrdinal: Int? = nil, source: MacIRValue? = nil, secondarySource: MacIRValue? = nil, destination: MacIRValue? = nil) {
            self.family = family; self.rowOrdinal = rowOrdinal; self.identity = identity
            self.qTransferOrdinal = qTransferOrdinal; self.source = source; self.secondarySource = secondarySource; self.destination = destination
        }
    }
    public let entries: [Entry]
    public var rowCount: Int { entries.count }
    public var effectCount: Int { entries.count }
    public var qTransferCount: Int { entries.filter { $0.qTransferOrdinal != nil }.count }
    public var explicitOutputs: [Entry] { entries.filter { e in
        guard e.family == .extractH0 || e.family == .fmovHZeroComplement, case let .register(name, _)? = e.destination else { return false }
        return name != "wzr"
    } }
    /// This is an outcome certificate, not new instruction metadata.
    /// Structural construction cannot itself authorize dispatch. Only the exact
    /// whole-list consumer preflight validates descriptors and current provenance.
    public init?(entries: [Entry]) {
        guard (2...64).contains(entries.count) else { return nil }
        var logicals = 0, counts = 0, sums = 0, outputs = 0, q = 0, outputPhase = false
        var previous: UInt64?
        for (ordinal, e) in entries.enumerated() {
            let pc = e.identity.sourceAddress
            guard e.rowOrdinal == ordinal, e.identity.effectOrdinal == 0, pc.isMultiple(of: 4),
                  (e.family == .terminal) == (ordinal == entries.count - 1) else { return nil }
            if let p = previous { guard p <= UInt64.max - 4, pc == p + 4 else { return nil } }
            previous = pc
            let logical = e.family == .intersection16b || e.family == .difference16b
            guard logical == (e.secondarySource != nil) else { return nil }
            switch e.family {
            case .extractH0, .fmovHZeroComplement:
                guard e.source != nil, case let .register(name, version)? = e.destination,
                      let n = MacIRBuilder.bitViewGPR(name, width: 32), n != 30,
                      n == 31 ? version == 0 : version > 0 else { return nil }
                outputPhase = true; if n != 31 { outputs += 1 }
            case .intersection16b, .difference16b, .count16b, .unsignedSumH:
                guard !outputPhase, e.source != nil, e.destination != nil else { return nil }
                if e.family == .count16b { counts += 1 } else if e.family == .unsignedSumH { sums += 1 } else { logicals += 1 }
            case .loadQ:
                guard !outputPhase, e.source == nil, e.destination == nil else { return nil }
            case .nop, .terminal:
                guard e.source == nil, e.destination == nil else { return nil }
            }
            if e.family == .loadQ { guard e.qTransferOrdinal == q else { return nil }; q += 1 }
            else { guard e.qTransferOrdinal == nil else { return nil } }
        }
        guard logicals > 0, counts > 0, sums > 0, outputs > 0 else { return nil }
        self.entries = entries
    }
}

// MARK: - MacIRNEONComparison

/// Register-register fixed-width integer comparison masks. No scalar or FP forms.
public struct MacIRNEONComparison: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case cmeq, cmgt, cmge, cmtst }
    public enum Arrangement: String, Hashable, Sendable {
        case b8 = "8b", b16 = "16b", h4 = "4h", h8 = "8h", s2 = "2s", s4 = "4s", d2 = "2d"
        public var laneBits: Int {
            switch self { case .b8, .b16: return 8; case .h4, .h8: return 16; case .s2, .s4: return 32; case .d2: return 64 }
        }
        public var vectorBits: Int {
            switch self { case .b8, .h4, .s2: return 64; default: return 128 }
        }
    }
    public let kind: Kind
    public let arrangement: Arrangement
    public init(kind: Kind, arrangement: Arrangement) { self.kind = kind; self.arrangement = arrangement }
    public var intrinsicName: String { "neon_\(kind.rawValue)_\(arrangement.rawValue)_mask_zero_upper" }
    public func evaluate(_ lhs: (low: UInt64, high: UInt64), _ rhs: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64) {
        let bits = arrangement.laneBits
        let mask: UInt64 = bits == 64 ? .max : (UInt64(1) << bits) - 1
        let sign = UInt64(1) << (bits - 1)
        var low: UInt64 = 0, high: UInt64 = 0
        for offset in stride(from: 0, to: arrangement.vectorBits, by: bits) {
            let shift = offset % 64
            let a = ((offset < 64 ? lhs.low : lhs.high) >> shift) & mask
            let b = ((offset < 64 ? rhs.low : rhs.high) >> shift) & mask
            let matches: Bool
            switch kind {
            case .cmeq: matches = a == b
            // Flipping the lane sign bit maps two's-complement signed ordering
            // to unsigned ordering, including 64-bit min/max without conversion.
            case .cmgt: matches = (a ^ sign) > (b ^ sign)
            case .cmge: matches = (a ^ sign) >= (b ^ sign)
            case .cmtst: matches = (a & b) != 0
            }
            let lane: UInt64 = matches ? mask : 0
            if offset < 64 { low |= lane << shift } else { high |= lane << shift }
        }
        // Q0 never visits high lanes, and therefore clears the entire upper half.
        return (low, high)
    }
}

// MARK: - MacIRNEONExtract

/// Fixed-width EXT. Byte 0 is the least-significant byte of the physical V register.
/// Invalid Q-dependent indices cannot construct a typed descriptor.
public struct MacIRNEONExtract: Hashable, Sendable {
    public enum Width: Int, Hashable, Sendable { case bytes8 = 8, bytes16 = 16 }
    public let width: Width
    public let byteOffset: Int
    public init?(width: Width, byteOffset: Int) {
        guard (0..<width.rawValue).contains(byteOffset) else { return nil }
        self.width = width
        self.byteOffset = byteOffset
    }
    public var intrinsicName: String { "neon_ext_\(width.rawValue)b_\(byteOffset)_zero_upper" }

    /// Concatenate active Vn bytes then active Vm bytes, never their inactive halves.
    /// The returned physical register always has 16 bytes; Q0 clears bytes 8...15.
    public func evaluate(nLow: UInt64, nHigh: UInt64, mLow: UInt64, mHigh: UInt64) -> (low: UInt64, high: UInt64) {
        func byte(_ position: Int) -> UInt64 {
            let sourceIndex = byteOffset + position
            let within = sourceIndex % width.rawValue
            let low = sourceIndex < width.rawValue ? nLow : mLow
            let high = sourceIndex < width.rawValue ? nHigh : mHigh
            return ((within < 8 ? low : high) >> ((within % 8) * 8)) & 0xff
        }
        var low: UInt64 = 0, high: UInt64 = 0
        for i in 0..<width.rawValue {
            if i < 8 { low |= byte(i) << (i * 8) }
            else { high |= byte(i) << ((i - 8) * 8) }
        }
        return (low, high)
    }
}

// MARK: - MacIRNEONFullWidthShift

/// Actual TwoRegMisc SHLL/SHLL2 endpoint only, not SSHLL/USHLL shift-immediate.
/// Q selects a source half. Both forms replace all128 destination bits.
public struct MacIRNEONFullWidthShift: Hashable, Sendable {
    public let narrowBits: Int
    public let sourceHighHalf: Bool
    public var sourceBits: Int { 128 }
    public var outputBits: Int { 128 }
    public var outputLaneBits: Int { narrowBits * 2 }
    public var laneCount: Int { 64 / narrowBits }
    public var shift: Int { narrowBits }
    public init?(narrowBits: Int, sourceHighHalf: Bool) {
        guard [8, 16, 32].contains(narrowBits) else { return nil }
        self.narrowBits = narrowBits
        self.sourceHighHalf = sourceHighHalf
    }
}

// MARK: - MacIRNEONImmediate

/// Exact decoded integer modified-immediate subset. Both halves are immutable
/// typed producer data; diagnostic intrinsic names carry no semantics.
public struct MacIRNEONImmediate: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case movi, mvni }
    public let kind: Kind
    public let laneBits: Int
    public let activeBytes: Int
    public let immediate: UInt64
    public let shift: Int
    public let shiftingOnes: Bool
    public let low: UInt64
    public let high: UInt64
    public init?(kind: Kind, laneBits: Int, activeBytes: Int, immediate: UInt64, shift: Int, shiftingOnes: Bool = false) {
        // MSL fills the vacated low bits before MVNI complements the lane.
        // Arm AdvSIMDExpandImm cmode=110x admits only 32-bit lanes and #8/#16.
        guard !shiftingOnes || (laneBits == 32 && [8, 16].contains(shift)) else { return nil }
        guard [8, 16].contains(activeBytes), [8,16,32,64].contains(laneBits) else { return nil }
        let lane: UInt64
        if laneBits == 64 {
            guard kind == .movi, activeBytes == 16, shift == 0,
                  (0..<8).allSatisfy({ let b = (immediate >> ($0 * 8)) & 255; return b == 0 || b == 255 }) else { return nil }
            lane = immediate
        } else {
            guard immediate <= 255, shift >= 0, shift < laneBits, shift.isMultiple(of: 8),
                  laneBits != 8 || (kind == .movi && shift == 0) else { return nil }
            let mask = (UInt64(1) << laneBits) - 1
            let shifted = (immediate << shift) | (shiftingOnes ? (UInt64(1) << shift) - 1 : 0)
            lane = kind == .mvni ? (~shifted & mask) : shifted
        }
        var half: UInt64 = 0
        for offset in stride(from: 0, to: 64, by: laneBits) { half |= lane << offset }
        self.kind = kind; self.laneBits = laneBits; self.activeBytes = activeBytes
        self.immediate = immediate; self.shift = shift; self.shiftingOnes = shiftingOnes; low = half; high = activeBytes == 16 ? half : 0
    }
}

// MARK: - MacIRNEONLeadingCountBitwise

/// Whole-list certificate only. Existing actual44 and actual40 typed engines
/// retain arithmetic authority. No instruction metadata or recovered ABI.
public struct MacIRNEONLeadingCountBitwise: Hashable, Sendable {
    public let rowCount: Int
    public let countCount: Int
    public let packingCount: Int
    public let logicalCount: Int
    public let qTransferCount: Int
    public let outputCount: Int
    public var effectCount: Int { rowCount }
    init(rowCount: Int, countCount: Int, packingCount: Int, logicalCount: Int, qTransferCount: Int, outputCount: Int) {
        self.rowCount = rowCount; self.countCount = countCount
        self.packingCount = packingCount; self.logicalCount = logicalCount; self.qTransferCount = qTransferCount
        self.outputCount = outputCount
    }
}

// MARK: - MacIRNEONLeadingCountPacking

/// Whole-list certificate only. Existing actual44 and actual40 typed engines
/// retain arithmetic authority. No instruction metadata or recovered ABI.
public struct MacIRNEONLeadingCountPacking: Hashable, Sendable {
    public let rowCount: Int
    public let countCount: Int
    public let packingCount: Int
    public let qTransferCount: Int
    public let outputCount: Int
    public var effectCount: Int { rowCount }
    init(rowCount: Int, countCount: Int, packingCount: Int, qTransferCount: Int, outputCount: Int) {
        self.rowCount = rowCount; self.countCount = countCount
        self.packingCount = packingCount; self.qTransferCount = qTransferCount
        self.outputCount = outputCount
    }
}

// MARK: - MacIRNEONLeadingCountScalarScore

/// Exact closed outcome, not instruction metadata or recovered scalar-return ABI.
/// CLZ lanes are 0...32; CLS lanes are 0...31. UMAXV selects their unsigned
/// maximum and clears bits127:32. This is NOT a safe global-shift bound.
public struct MacIRNEONLeadingCountScalarScore: Hashable, Sendable {
    public let rowCount: Int
    public let countCount: Int
    public let reductionCount: Int
    public let qTransferCount: Int
    public let explicitOutputs: [MacIRValue]
    public var effectCount: Int { rowCount }
    // Only the exhaustive source-bound consumer constructs this certificate.
    init(rowCount: Int, countCount: Int, reductionCount: Int,
         qTransferCount: Int, explicitOutputs: [MacIRValue]) {
        self.rowCount = rowCount; self.countCount = countCount
        self.reductionCount = reductionCount; self.qTransferCount = qTransferCount
        self.explicitOutputs = explicitOutputs
    }
}

// MARK: - MacIRNEONLogical

/// Integer bit patterns only. Q=0 defines all 128 physical bits, clearing high64.
public struct MacIRNEONLogical: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case and, bic, orr, orn, eor, bsl, bit, bif }
    public enum Width: Int, Hashable, Sendable { case bytes8 = 8, bytes16 = 16 }
    public let kind: Kind
    public let width: Width
    public init(kind: Kind, width: Width) { self.kind = kind; self.width = width }
    public var readsDestination: Bool { [.bsl, .bit, .bif].contains(kind) }
    public var intrinsicName: String { "neon_\(kind.rawValue)_\(width.rawValue)b_zero_upper" }

    /// Arguments always mean Vn, Vm, and (when used) OLD Vd. This is the typed
    /// evaluator, not parsing an intrinsic spelling. Callers snapshot before write.
    public func evaluateHalf(n: UInt64, m: UInt64, oldDestination d: UInt64) -> UInt64 {
        switch kind {
        case .and: return n & m
        case .bic: return n & ~m
        case .orr: return n | m
        case .orn: return n | ~m
        case .eor: return n ^ m
        case .bsl: return (d & n) | (~d & m)
        case .bit: return (m & n) | (~m & d)
        case .bif: return (~m & n) | (m & d)
        }
    }
}

// MARK: - MacIRNEONOrderConversion

/// Exact integer SIMD unary conversion. REV reverses elements, not the bytes
/// inside each element, within a fixed-size group; RBIT never moves bytes.
public struct MacIRNEONOrderConversion: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case rev16, rev32, rev64, rbit }
    public let kind: Kind
    public let elementBytes: Int
    public let activeBytes: Int
    public var groupBytes: Int { kind == .rev16 ? 2 : kind == .rev32 ? 4 : kind == .rev64 ? 8 : 1 }
    public init?(kind: Kind, elementBytes: Int, activeBytes: Int) {
        guard [8,16].contains(activeBytes), [1,2,4].contains(elementBytes) else { return nil }
        switch kind {
        case .rev16, .rbit: guard elementBytes == 1 else { return nil }
        case .rev32: guard elementBytes <= 2 else { return nil }
        case .rev64: break
        }
        self.kind = kind; self.elementBytes = elementBytes; self.activeBytes = activeBytes
    }
}

// MARK: - MacIRNEONPacking

/// Non-saturating unpack/pack only. The two half selectors have different roles.
public struct MacIRNEONPacking: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case signedWiden, unsignedWiden, narrow }
    public let kind: Kind
    public let narrowBits: Int
    public let sourceHighHalf: Bool
    public let destinationHighHalf: Bool
    public let shift: Int
    public var sourceLaneBits: Int { kind == .narrow ? narrowBits * 2 : narrowBits }
    public var destinationLaneBits: Int { kind == .narrow ? narrowBits : narrowBits * 2 }
    public var laneCount: Int { 64 / narrowBits }
    public var readsDestination: Bool { kind == .narrow && destinationHighHalf }
    public init?(kind: Kind, narrowBits: Int, sourceHighHalf: Bool = false,
                 destinationHighHalf: Bool = false, shift: Int = 0) {
        guard [8,16,32].contains(narrowBits) else { return nil }
        if kind == .narrow {
            guard !sourceHighHalf, shift == 0 else { return nil }
        } else {
            guard !destinationHighHalf, (0..<narrowBits).contains(shift) else { return nil }
        }
        self.kind = kind; self.narrowBits = narrowBits; self.sourceHighHalf = sourceHighHalf
        self.destinationHighHalf = destinationHighHalf; self.shift = shift
    }
    public func evaluate(source: (low: UInt64, high: UInt64), oldDestination: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64) {
        func mask(_ bits: Int) -> UInt64 { bits == 64 ? .max : (UInt64(1) << bits) - 1 }
        var low: UInt64 = readsDestination ? oldDestination.low : 0, high: UInt64 = 0
        for lane in 0..<laneCount {
            let inputOffset = (sourceHighHalf ? 64 : 0) + lane * sourceLaneBits
            let raw = ((inputOffset < 64 ? source.low : source.high) >> (inputOffset % 64)) & mask(sourceLaneBits)
            let value: UInt64
            if kind == .narrow { value = raw & mask(narrowBits) }
            else {
                // Explicit two's-complement extension. No signed host overflow.
                let extended = kind == .signedWiden && raw & (UInt64(1) << (narrowBits-1)) != 0
                    ? raw | (mask(destinationLaneBits) ^ mask(narrowBits)) : raw
                value = (extended << shift) & mask(destinationLaneBits)
            }
            let outputOffset = (destinationHighHalf ? 64 : 0) + lane * destinationLaneBits
            if outputOffset < 64 { low |= value << (outputOffset % 64) }
            else { high |= value << (outputOffset % 64) }
        }
        return (low, high)
    }
}

// MARK: - MacIRNEONPopulationCountFMOV

/// DOT94 certifies an exhaustive composition of existing44/39/32/31 operations.
/// It owns neither arithmetic nor a scalar-return ABI, and adds no metadata field.
public struct MacIRNEONPopulationCountFMOV: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case count16b, unsignedSumH, fmovHZeroComplement, loadQ, nop, terminal }
    public struct Entry: Hashable, Sendable {
        public let family: Family
        public let rowOrdinal: Int
        public let identity: MacIRInstruction.Identity
        public let qTransferOrdinal: Int?
        public let source: MacIRValue?
        public let secondarySource: MacIRValue?
        public let destination: MacIRValue?
        public init(family: Family, rowOrdinal: Int, identity: MacIRInstruction.Identity,
                    qTransferOrdinal: Int? = nil, source: MacIRValue? = nil, secondarySource: MacIRValue? = nil, destination: MacIRValue? = nil) {
            self.family = family; self.rowOrdinal = rowOrdinal; self.identity = identity
            self.qTransferOrdinal = qTransferOrdinal; self.source = source; self.secondarySource = secondarySource; self.destination = destination
        }
    }
    public let entries: [Entry]
    public var rowCount: Int { entries.count }
    public var effectCount: Int { entries.count }
    public var qTransferCount: Int { entries.filter { $0.qTransferOrdinal != nil }.count }
    public var explicitOutputs: [Entry] { entries.filter { e in
        guard e.family == .fmovHZeroComplement, case let .register(name, _)? = e.destination else { return false }
        return name != "wzr"
    } }
    /// This is an outcome certificate, not new instruction metadata.
    /// Structural construction cannot itself authorize dispatch. Only the exact
    /// whole-list consumer preflight validates descriptors and current provenance.
    public init?(entries: [Entry]) {
        guard entries.map(\.family) == [.loadQ, .count16b, .unsignedSumH, .fmovHZeroComplement, .terminal] else { return nil }
        var counts = 0, sums = 0, outputs = 0, q = 0, outputPhase = false
        var previous: UInt64?
        for (ordinal, e) in entries.enumerated() {
            let pc = e.identity.sourceAddress
            guard e.rowOrdinal == ordinal, e.identity.effectOrdinal == 0, pc.isMultiple(of: 4),
                  (e.family == .terminal) == (ordinal == entries.count - 1) else { return nil }
            if let p = previous { guard p <= UInt64.max - 4, pc == p + 4 else { return nil } }
            previous = pc
            guard e.secondarySource == nil else { return nil }
            switch e.family {
            case .fmovHZeroComplement:
                guard e.source != nil, case let .register(name, version)? = e.destination,
                      let n = MacIRBuilder.bitViewGPR(name, width: 32), n != 30,
                      n == 31 ? version == 0 : version > 0 else { return nil }
                outputPhase = true; if n != 31 { outputs += 1 }
            case .count16b, .unsignedSumH:
                guard !outputPhase, e.source != nil, e.destination != nil else { return nil }
                if e.family == .count16b { counts += 1 } else if e.family == .unsignedSumH { sums += 1 }
            case .loadQ:
                guard !outputPhase, e.source == nil, e.destination == nil else { return nil }
            case .nop, .terminal:
                guard e.source == nil, e.destination == nil else { return nil }
            }
            if e.family == .loadQ { guard e.qTransferOrdinal == q else { return nil }; q += 1 }
            else { guard e.qTransferOrdinal == nil else { return nil } }
        }
        guard counts == 1, sums == 1, outputs == 1, q == 1 else { return nil }
        self.entries = entries
    }
}

// MARK: - MacIRNEONPopulationCountScore

/// DOT78 certifies an exhaustive composition of existing44/39/31 operations.
/// It owns neither arithmetic nor a scalar-return ABI, and adds no metadata field.
public struct MacIRNEONPopulationCountScore: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case count16b, unsignedSumH, extractH0, loadQ, nop, terminal }
    public struct Entry: Hashable, Sendable {
        public let family: Family
        public let rowOrdinal: Int
        public let identity: MacIRInstruction.Identity
        public let qTransferOrdinal: Int?
        public let source: MacIRValue?
        public let destination: MacIRValue?
        public init(family: Family, rowOrdinal: Int, identity: MacIRInstruction.Identity,
                    qTransferOrdinal: Int? = nil, source: MacIRValue? = nil, destination: MacIRValue? = nil) {
            self.family = family; self.rowOrdinal = rowOrdinal; self.identity = identity
            self.qTransferOrdinal = qTransferOrdinal; self.source = source; self.destination = destination
        }
    }
    public let entries: [Entry]
    public var rowCount: Int { entries.count }
    public var effectCount: Int { entries.count }
    public var qTransferCount: Int { entries.filter { $0.qTransferOrdinal != nil }.count }
    public var explicitOutputs: [Entry] { entries.filter { e in
        guard e.family == .extractH0, case let .register(name, _)? = e.destination else { return false }
        return name != "wzr"
    } }
    /// Structural construction cannot itself authorize dispatch. Only the exact
    /// whole-list consumer preflight validates descriptors and current provenance.
    public init?(entries: [Entry]) {
        guard (2...64).contains(entries.count) else { return nil }
        var counts = 0, sums = 0, outputs = 0, q = 0, outputPhase = false
        var previous: UInt64?
        for (ordinal, e) in entries.enumerated() {
            let pc = e.identity.sourceAddress
            guard e.rowOrdinal == ordinal, e.identity.effectOrdinal == 0, pc.isMultiple(of: 4),
                  (e.family == .terminal) == (ordinal == entries.count - 1) else { return nil }
            if let p = previous { guard p <= UInt64.max - 4, pc == p + 4 else { return nil } }
            previous = pc
            switch e.family {
            case .extractH0:
                guard e.source != nil, case let .register(name, version)? = e.destination,
                      let n = MacIRBuilder.bitViewGPR(name, width: 32), n != 30,
                      n == 31 ? version == 0 : version > 0 else { return nil }
                outputPhase = true; if n != 31 { outputs += 1 }
            case .count16b, .unsignedSumH:
                guard !outputPhase, e.source != nil, e.destination != nil else { return nil }
                if e.family == .count16b { counts += 1 } else { sums += 1 }
            case .loadQ:
                guard !outputPhase, e.source == nil, e.destination == nil else { return nil }
            case .nop, .terminal:
                guard e.source == nil, e.destination == nil else { return nil }
            }
            if e.family == .loadQ { guard e.qTransferOrdinal == q else { return nil }; q += 1 }
            else { guard e.qTransferOrdinal == nil else { return nil } }
        }
        guard counts > 0, sums > 0, outputs > 0 else { return nil }
        self.entries = entries
    }
}

// MARK: - MacIRNEONPredicate

/// Fixed-width unsigned register masks and integer literal-zero masks only.
/// Existing30 signed/equality/test REGISTER comparisons remain separately owned.
public struct MacIRNEONPredicate: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case cmhi, cmhs, cmgt, cmge, cmeq, cmle, cmlt }
    public let kind: Kind
    public let elementBytes: Int
    public let activeBytes: Int
    public var laneCount: Int { activeBytes / elementBytes }
    public var comparesZero: Bool { kind != .cmhi && kind != .cmhs }
    public var arity: Int { comparesZero ? 1 : 2 }
    public init?(kind: Kind, elementBytes: Int, activeBytes: Int) {
        guard [1, 2, 4, 8].contains(elementBytes), [8, 16].contains(activeBytes),
              elementBytes != 8 || activeBytes == 16 else { return nil }
        self.kind = kind; self.elementBytes = elementBytes; self.activeBytes = activeBytes
    }
}

// MARK: - MacIRNEONReduction

/// DOT39's local integer output contract, not a general scalar-view lattice.
public struct MacIRNEONReduction: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case addv, sminv, uminv, smaxv, umaxv, saddlv, uaddlv, umov, smov
    }
    public let kind: Kind
    public let elementBits: Int
    public let activeBytes: Int
    public let lane: Int
    public let gprBits: Int
    public var isExtraction: Bool { kind == .umov || kind == .smov }
    public var inputLanes: Int { activeBytes * 8 / elementBits }
    public var outputBits: Int { isExtraction ? gprBits : (kind == .saddlv || kind == .uaddlv ? elementBits * 2 : elementBits) }
    public init?(kind: Kind, elementBits: Int, activeBytes: Int, lane: Int = 0, gprBits: Int = 0) {
        guard [8,16,32,64].contains(elementBits) else { return nil }
        if kind == .umov || kind == .smov {
            guard activeBytes == 16, (0..<(128/elementBits)).contains(lane), [32,64].contains(gprBits) else { return nil }
            if kind == .umov { guard (gprBits == 64) == (elementBits == 64) else { return nil } }
            else { guard elementBits < gprBits, elementBits <= 32 else { return nil } }
        } else {
            guard [8,16].contains(activeBytes), elementBits <= 32,
                  elementBits != 32 || activeBytes == 16, lane == 0, gprBits == 0 else { return nil }
        }
        self.kind = kind; self.elementBits = elementBits; self.activeBytes = activeBytes
        self.lane = lane; self.gprBits = gprBits
    }
}

// MARK: - MacIRNEONRoundedShift

/// Non-saturating same-width vector rounding. This is neither DOT34 nor SHRN.
public struct MacIRNEONRoundedShift: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case srshr, urshr }
    public let kind: Kind
    public let elementBits: Int
    public let shift: Int
    public let activeBytes: Int
    public init?(kind: Kind, elementBits: Int, shift: Int, activeBytes: Int) {
        guard [8, 16, 32, 64].contains(elementBits), [8, 16].contains(activeBytes),
              !(elementBits == 64 && activeBytes == 8), (1...elementBits).contains(shift) else { return nil }
        self.kind = kind; self.elementBits = elementBits; self.shift = shift; self.activeBytes = activeBytes
    }
    public var isSigned: Bool { kind == .srshr }
    public var laneCount: Int { activeBytes * 8 / elementBits }
    public func evaluate(source: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64) {
        let mask = elementBits == 64 ? UInt64.max : (UInt64(1) << elementBits)-1
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<laneCount {
            let offset = lane * elementBits, position = offset % 64
            let bits = ((offset < 64 ? source.low : source.high) >> position) & mask
            let result: UInt64
            if shift == elementBits {
                // In extended precision every signed lane rounds to zero here;
                // unsigned lanes yield their top bit. Never shift UInt64 by 64.
                result = isSigned ? 0 : bits >> (elementBits-1)
            } else {
                // floor(x / 2^s) + bit(s-1) equals floor((x + 2^(s-1)) / 2^s)
                // in mathematical precision, including unsigned64 carry. Signed
                // negative ties round toward +infinity, not away from zero.
                let fill = isSigned && bits & (UInt64(1) << (elementBits-1)) != 0 ? mask ^ (mask >> shift) : 0
                let quotient = (bits >> shift) | fill
                result = (quotient &+ ((bits >> (shift-1)) & 1)) & mask
            }
            if offset < 64 { low |= result << position } else { high |= result << position }
        }
        return (low, high) // Q0 high64 stays zero, even with an aliased source.
    }
}

// MARK: - MacIRNEONScalarIntegerComparison

/// Only actual scalar ThreeSame size3 two-source integer comparisons.
/// The immutable word records operand identity as well as all reserved bits.
public struct MacIRNEONScalarIntegerComparison: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case cmeq, cmgt, cmge, cmhi, cmhs, cmtst }
    public let kind: Kind
    public let encodedWord: UInt32
    public let destination: Int
    public let lhs: Int
    public let rhs: Int
    public var sourceBits: Int { 128 }
    public var outputBits: Int { 128 }
    public init?(encodedWord word: UInt32) {
        guard word & 0xdf200400 == 0x5e200400, (word >> 22) & 3 == 3 else { return nil }
        let u = (word >> 29) & 1, opcode = (word >> 11) & 31
        switch (u, opcode) {
        case (0, 6): kind = .cmgt
        case (1, 6): kind = .cmhi
        case (0, 7): kind = .cmge
        case (1, 7): kind = .cmhs
        case (0, 17): kind = .cmtst
        case (1, 17): kind = .cmeq
        default: return nil
        }
        destination = Int(word & 31); lhs = Int((word >> 5) & 31); rhs = Int((word >> 16) & 31)
        let exact = UInt32(0x5ee00400) | u << 29 | opcode << 11 | UInt32(rhs) << 16 | UInt32(lhs) << 5 | UInt32(destination)
        guard word == exact else { return nil }
        encodedWord = word
    }
    public func evaluate(_ a: UInt64, _ b: UInt64) -> (low: UInt64, high: UInt64) {
        let matches: Bool
        switch kind {
        case .cmeq: matches = a == b
        case .cmgt: matches = (a ^ (1 << 63)) > (b ^ (1 << 63))
        case .cmge: matches = (a ^ (1 << 63)) >= (b ^ (1 << 63))
        case .cmhi: matches = a > b
        case .cmhs: matches = a >= b
        case .cmtst: matches = (a & b) != 0
        }
        return (matches ? .max : 0, 0)
    }
}

// MARK: - MacIRNEONScalarMaskSelection

/// Linear marker for one complete scalar-D mask → .8b selection buffer route.
/// No numeric engine is added: actual95, actual23 and actual31 own payloads.
public struct MacIRNEONScalarMaskSelection: Hashable, Sendable {
    public let ordinal: Int
    public init?(ordinal: Int) {
        guard (0..<64).contains(ordinal) else { return nil }
        self.ordinal = ordinal
    }
}

/// Immutable evidence bound to the entire current DTO, not merely matching bits.
/// Only the exhaustive source-bound preflight constructs this certificate.
public struct MacIRNEONScalarMaskSelectionCertificate: Hashable, Sendable {
    public let instructions: [MacIRInstruction]
    public let maskCount: Int
    public let selectionCount: Int
    public let qLoadCount: Int
    public let qStoreCount: Int
}

// MARK: - MacIRNEONScalarShiftCompilerComposition

/// A bounded compiler pipeline marker, not a scalar/FP/constant value lattice.
/// One marker per original row; architectural effect ordinal remains zero.
public struct MacIRNEONScalarShiftCompilerComposition: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case load, zero, shift, transfer, insert, store, terminal }
    public let kind: Kind
    public let ordinal: Int
    public let rowCount: Int
    init(kind: Kind, ordinal: Int, rowCount: Int) {
        self.kind = kind; self.ordinal = ordinal; self.rowCount = rowCount
    }
}

public struct MacIRNEONScalarShiftCompilerCompositionCertificate: Hashable, Sendable {
    public let rowCount: Int
    public let shiftCount: Int
    public let qMemoryCount: Int
    public let observedShiftStores: Int
    init(rowCount: Int, shiftCount: Int, qMemoryCount: Int, observedShiftStores: Int) {
        self.rowCount = rowCount; self.shiftCount = shiftCount
        self.qMemoryCount = qMemoryCount; self.observedShiftStores = observedShiftStores
    }
}

// MARK: - MacIRNEONScalarVariableShift

/// Scalar D only. Count is signed LOW BYTE, never signed64 or modulo64.
/// Physical sources are captured as 128 bits; every result clears high64.
public struct MacIRNEONScalarVariableShift: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case sshl, ushl, srshl, urshl }
    public let kind: Kind
    public let destination: Int
    public let source: Int
    public let count: Int
    public init?(kind: Kind, destination: Int, source: Int, count: Int) {
        guard (0..<32).contains(destination), (0..<32).contains(source), (0..<32).contains(count) else { return nil }
        self.kind = kind; self.destination = destination; self.source = source; self.count = count
    }
    public var isSigned: Bool { kind == .sshl || kind == .srshl }
    public var isRounded: Bool { kind == .srshl || kind == .urshl }
    public var encodedWord: UInt32 {
        0x5ee04400 | (isSigned ? 0 : 0x20000000) | (isRounded ? 0x1000 : 0) |
        UInt32(count) << 16 | UInt32(source) << 5 | UInt32(destination)
    }
    public var rawOperands: String { "d\(destination), d\(source), d\(count)" }
    public func evaluate(value: UInt64, countBits: UInt64) -> (low: UInt64, high: UInt64) {
        let count = Int(Int8(bitPattern: UInt8(truncatingIfNeeded: countBits)))
        if count >= 0 { return (count >= 64 ? 0 : value << count, 0) }
        let right = -count
        if right >= 64 {
            if isRounded { return (right == 64 && !isSigned ? value >> 63 : 0, 0) }
            return (isSigned && value & 0x8000000000000000 != 0 ? .max : 0, 0)
        }
        let quotient = isSigned ? UInt64(bitPattern: Int64(bitPattern: value) >> right) : value >> right
        // Mathematical precision addition expressed as quotient plus round bit.
        return (quotient &+ (isRounded ? (value >> (right - 1)) & 1 : 0), 0)
    }
}

/// Created only after complete-list validation; frame, Q-effect and byte units differ.
public struct MacIRNEONScalarVariableShiftCertificate: Hashable, Sendable {
    public let rowCount: Int
    public let shiftCount: Int
    public let qMemoryCount: Int
    public let observedShiftStores: Int
    init(rowCount: Int, shiftCount: Int, qMemoryCount: Int, observedShiftStores: Int) {
        self.rowCount = rowCount; self.shiftCount = shiftCount
        self.qMemoryCount = qMemoryCount; self.observedShiftStores = observedShiftStores
    }
}

// MARK: - MacIRNEONShiftInsert

/// Exact fixed-vector immediate lane shifts. No rounding, saturation or flags.
public struct MacIRNEONShiftInsert: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case shl, ushr, sshr, sli, sri
        public var readsDestination: Bool { self == .sli || self == .sri }
        public var isLeft: Bool { self == .shl || self == .sli }
    }
    public enum Arrangement: String, Hashable, Sendable {
        case b8 = "8b", b16 = "16b", h4 = "4h", h8 = "8h", s2 = "2s", s4 = "4s", d2 = "2d"
        public var laneBits: Int {
            switch self { case .b8, .b16: return 8; case .h4, .h8: return 16; case .s2, .s4: return 32; case .d2: return 64 }
        }
        public var vectorBits: Int {
            switch self { case .b8, .h4, .s2: return 64; default: return 128 }
        }
    }
    public let kind: Kind
    public let arrangement: Arrangement
    public let shift: Int
    public init?(kind: Kind, arrangement: Arrangement, shift: Int) {
        guard kind.isLeft ? (0..<arrangement.laneBits).contains(shift)
            : (1...arrangement.laneBits).contains(shift) else { return nil }
        self.kind = kind; self.arrangement = arrangement; self.shift = shift
    }
    public var intrinsicName: String { "neon_\(kind.rawValue)_\(arrangement.rawValue)_\(shift)_zero_upper" }
    public func evaluate(source: (low: UInt64, high: UInt64), oldDestination: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64) {
        let bits = arrangement.laneBits
        let mask: UInt64 = bits == 64 ? .max : (UInt64(1) << bits) - 1
        var low: UInt64 = 0, high: UInt64 = 0
        for offset in stride(from: 0, to: arrangement.vectorBits, by: bits) {
            let position = offset % 64
            let n = ((offset < 64 ? source.low : source.high) >> position) & mask
            let d = ((offset < 64 ? oldDestination.low : oldDestination.high) >> position) & mask
            let lane: UInt64
            switch kind {
            case .shl: lane = (n << shift) & mask
            case .sli:
                let preserved = shift == 0 ? 0 : (UInt64(1) << shift) - 1
                lane = (d & preserved) | ((n << shift) & mask)
            case .ushr: lane = shift == bits ? 0 : n >> shift
            case .sshr:
                let negative = n & (UInt64(1) << (bits - 1)) != 0
                if shift == bits { lane = negative ? mask : 0 }
                else {
                    // Explicit two's-complement sign fill, never a host signed shift.
                    let fill = negative ? (mask ^ (mask >> shift)) : 0
                    lane = (n >> shift) | fill
                }
            case .sri:
                // Full-width right insert preserves every old lane bit. Branch
                // before either shift so UInt64 is never shifted by 64.
                if shift == bits { lane = d }
                else { lane = (d & (mask ^ (mask >> shift))) | (n >> shift) }
            }
            if offset < 64 { low |= lane << position } else { high |= lane << position }
        }
        return (low, high) // Q0 intentionally never writes any high-half bit.
    }
}

// MARK: - MacIRNEONShiftNarrow

/// Non-rounding logical right shift of full128 wide lanes, then truncation.
/// Q selects the destination half, never a source half or source vector width.
public struct MacIRNEONShiftNarrow: Hashable, Sendable {
    public let narrowBits: Int
    public let shift: Int
    public let destinationHighHalf: Bool
    public var sourceLaneBits: Int { narrowBits * 2 }
    public var laneCount: Int { 64 / narrowBits }
    public var arity: Int { destinationHighHalf ? 2 : 1 }
    public init?(narrowBits: Int, shift: Int, destinationHighHalf: Bool) {
        guard [8, 16, 32].contains(narrowBits), (1...narrowBits).contains(shift) else { return nil }
        self.narrowBits = narrowBits; self.shift = shift
        self.destinationHighHalf = destinationHighHalf
    }
}

// MARK: - MacIRNEONTableLookup

/// Typed fixed-width register table lookup. Table extent is always count * 16.
public struct MacIRNEONTableLookup: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case tbl, tbx }
    public enum Width: Int, Hashable, Sendable { case bytes8 = 8, bytes16 = 16 }
    public let kind: Kind
    public let width: Width
    public let tableCount: Int
    public init?(kind: Kind, width: Width, tableCount: Int) {
        guard (1...4).contains(tableCount) else { return nil }
        self.kind = kind; self.width = width; self.tableCount = tableCount
    }
    public var intrinsicName: String { "neon_\(kind)_\(tableCount)_\(width.rawValue)b_zero_upper" }
    public func evaluate(tables: [(low: UInt64, high: UInt64)], index: (low: UInt64, high: UInt64), old: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64)? {
        guard tables.count == tableCount else { return nil }
        func byte(_ v: (low: UInt64, high: UInt64), _ i: Int) -> UInt64 {
            ((i < 8 ? v.low : v.high) >> ((i % 8) * 8)) & 255
        }
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<width.rawValue {
            let selected = Int(byte(index, lane))
            let value = selected < tableCount * 16 ? byte(tables[selected / 16], selected % 16) : (kind == .tbx ? byte(old, lane) : 0)
            if lane < 8 { low |= value << (lane * 8) } else { high |= value << ((lane - 8) * 8) }
        }
        return (low, high)
    }
}
