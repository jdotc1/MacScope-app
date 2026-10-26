import Foundation

// MARK: - MacIRNEONAbsoluteDifferencePairwise

/// Immutable source-bound closed composition; actual57/50/49/31 retain all engines.
/// Signed16 inputs widen BEFORE subtraction (-65535...65535); ABS magnitudes
/// are 0...65535 and adjacent sums 0...131070, without a new arithmetic engine.
public struct MacIRNEONAbsoluteDifferencePairwise: Hashable, Sendable {
    public let instructions: [MacIRInstruction]
    public let differenceCount: Int
    public let magnitudeCount: Int
    public let pairwiseCount: Int
    public let qTransferCount: Int
    public var rowCount: Int { instructions.count }
    public var memoryByteCount: Int { qTransferCount * 16 }
}

// MARK: - MacIRNEONByteDotProduct

/// Whole-vector SDOT/UDOT only; four byte products plus OLD32, modulo 2^32.
public struct MacIRNEONByteDotProduct: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case sdot, udot }
    public let kind: Kind
    public let activeBytes: Int
    public let groupBytes: Int = 4
    public init?(kind: Kind, activeBytes: Int) {
        guard activeBytes == 8 || activeBytes == 16 else { return nil }
        self.kind = kind; self.activeBytes = activeBytes
    }
    public var isSigned: Bool { kind == .sdot }
    public var laneCount: Int { activeBytes / groupBytes }
    public func evaluate(first: (low: UInt64, high: UInt64), second: (low: UInt64, high: UInt64), old: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64) {
        func byte(_ value: (low: UInt64, high: UInt64), _ index: Int) -> Int64 {
            let raw = Int64(((index < 8 ? value.low : value.high) >> ((index % 8) * 8)) & 255)
            return isSigned && raw >= 128 ? raw - 256 : raw
        }
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<laneCount {
            let offset = lane * 32, position = offset % 64
            let accumulator = Int64(((offset < 64 ? old.low : old.high) >> position) & 0xffff_ffff)
            var sum = accumulator
            for term in 0..<groupBytes {
                let index = lane * groupBytes + term
                sum += byte(first, index) * byte(second, index)
            }
            let result = UInt64(UInt32(truncatingIfNeeded: sum))
            if offset < 64 { low |= result << position } else { high |= result << position }
        }
        return (low, high) // Q0 clears high64; no OLD high-half leakage.
    }
}

// MARK: - MacIRNEONByteMatrixAccumulate

/// Actual i8mm 2x8 by 8x2 byte matrix accumulation. No general matrix engine.
/// Vn encodes two contiguous rows; Vm encodes two contiguous columns.
/// Result lanes are row-major [r0c0, r0c1, r1c0, r1c1].
public struct MacIRNEONByteMatrixAccumulate: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case smmla, ummla, usmmla }
    public enum ByteExtension: String, Hashable, Sendable { case signed, unsigned }
    public let kind: Kind
    public let firstExtension: ByteExtension
    public let secondExtension: ByteExtension
    public let inputBytes: Int = 16
    public let outputLaneBits: Int = 32
    public let laneCount: Int = 4
    public let termCount: Int = 8
    public init(kind: Kind) {
        self.kind = kind
        firstExtension = kind == .smmla ? .signed : .unsigned
        secondExtension = kind == .ummla ? .unsigned : .signed
    }
    /// Exactly 32 architectural products; roles cannot be transposed or grouped as dots.
    public func byteIndices(outputLane: Int, term: Int) -> (first: Int, second: Int)? {
        guard (0..<4).contains(outputLane), (0..<8).contains(term) else { return nil }
        return (8 * (outputLane / 2) + term, 8 * (outputLane % 2) + term)
    }
    public func evaluate(first: (low: UInt64, high: UInt64), second: (low: UInt64, high: UInt64), old: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64) {
        func byte(_ v: (low: UInt64, high: UInt64), _ index: Int, _ extensionKind: ByteExtension) -> Int64 {
            let raw = Int64(((index < 8 ? v.low : v.high) >> ((index % 8) * 8)) & 255)
            return extensionKind == .signed && raw >= 128 ? raw - 256 : raw
        }
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<laneCount {
            let shift = (lane % 2) * 32
            var sum = Int64(((lane < 2 ? old.low : old.high) >> shift) & 0xffff_ffff)
            for term in 0..<termCount {
                let indices = byteIndices(outputLane: lane, term: term)!
                sum += byte(first, indices.first, firstExtension) * byte(second, indices.second, secondExtension)
            }
            // Bound is OLD32 plus eight byte products, safely within Int64.
            // Truncation is independent per output: never carry between lanes.
            let result = UInt64(UInt32(truncatingIfNeeded: sum))
            if lane < 2 { low |= result << shift } else { high |= result << shift }
        }
        return (low, high)
    }
}

// MARK: - MacIRNEONBytePolynomialMultiply

/// PMUL .8b/.16b: polynomial coefficients over GF(2), retain degrees 0...7.
/// This is neither integer multiplication nor reduction modulo an irreducible polynomial.
public struct MacIRNEONBytePolynomialMultiply: Hashable, Sendable {
    public enum CoefficientDomain: Hashable, Sendable { case gf2 }
    public enum ResultRule: Hashable, Sendable { case truncateLow8 }
    public let coefficientDomain: CoefficientDomain = .gf2
    public let resultRule: ResultRule = .truncateLow8
    public let elementBits: Int = 8
    public let activeBytes: Int
    public init?(activeBytes: Int) {
        guard activeBytes == 8 || activeBytes == 16 else { return nil }
        self.activeBytes = activeBytes
    }
    public func evaluate(first: (low: UInt64, high: UInt64), second: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64) {
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<activeBytes {
            let shift = (lane % 8) * 8
            let a = UInt16(((lane < 8 ? first.low : first.high) >> shift) & 255)
            let b = UInt16(((lane < 8 ? second.low : second.high) >> shift) & 255)
            var polynomial: UInt16 = 0
            for coefficient in 0..<8 where (b >> coefficient) & 1 != 0 {
                polynomial ^= a << coefficient
            }
            let result = UInt64(polynomial & 255)
            if lane < 8 { low |= result << shift } else { high |= result << shift }
        }
        return (low, high) // Q0 always clears high64, independently of source aliases.
    }
}

// MARK: - MacIRNEONIndexedByteDotProduct

/// Indexed SDOT/UDOT only; four byte products plus OLD32, modulo 2^32.
public struct MacIRNEONIndexedByteDotProduct: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case sdot, udot }
    public let kind: Kind
    public let selectedGroup: Int
    public let activeBytes: Int
    public let groupBytes: Int = 4
    public init?(kind: Kind, selectedGroup: Int, activeBytes: Int) {
        guard (0...3).contains(selectedGroup), activeBytes == 8 || activeBytes == 16 else { return nil }
        self.kind = kind; self.selectedGroup = selectedGroup; self.activeBytes = activeBytes
    }
    public var isSigned: Bool { kind == .sdot }
    public var laneCount: Int { activeBytes / groupBytes }
    public func evaluate(first: (low: UInt64, high: UInt64), second: (low: UInt64, high: UInt64), old: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64) {
        func byte(_ value: (low: UInt64, high: UInt64), _ index: Int) -> Int64 {
            let raw = Int64(((index < 8 ? value.low : value.high) >> ((index % 8) * 8)) & 255)
            return isSigned && raw >= 128 ? raw - 256 : raw
        }
        // One coefficient group from the complete physical128 Vm, independent of Q.
        let coefficient = (0..<groupBytes).map { byte(second, selectedGroup * groupBytes + $0) }
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<laneCount {
            let offset = lane * 32, position = offset % 64
            let accumulator = Int64(((offset < 64 ? old.low : old.high) >> position) & 0xffff_ffff)
            var sum = accumulator
            for term in 0..<groupBytes {
                let index = lane * groupBytes + term
                sum += byte(first, index) * coefficient[term]
            }
            let result = UInt64(UInt32(truncatingIfNeeded: sum))
            if offset < 64 { low |= result << position } else { high |= result << position }
        }
        return (low, high) // Q0 clears high64; no OLD high-half leakage.
    }
}

// MARK: - MacIRNEONIndexedDotScore

/// DOT84 is an exhaustive composition certificate, never a new arithmetic engine.
/// No instruction metadata field or public Identity/State redesign is required.
public struct MacIRNEONIndexedDotScore: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case indexedDot, indexedMixedDot, addv32, umov32, scalarToGPR, loadQ, nop, terminal }
    /// Captured typed operand roles, not diagnostic text or caller ABI.
    public struct DotProvenance: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable { case sdot, udot, usdot, sudot }
        public let kind: Kind
        public let selectedGroup: Int
        public let first: MacIRValue
        public let coefficient: MacIRValue
        public let old: MacIRValue
        public let destination: MacIRValue
        public let coefficientBytes: Int = 16
        public var firstSigned: Bool { kind == .sdot || kind == .sudot }
        public var coefficientSigned: Bool { kind == .sdot || kind == .usdot }
        public init?(kind: Kind, selectedGroup: Int, first: MacIRValue,
                     coefficient: MacIRValue, old: MacIRValue, destination: MacIRValue) {
            guard (0...3).contains(selectedGroup) else { return nil }
            self.kind = kind; self.selectedGroup = selectedGroup; self.first = first
            self.coefficient = coefficient; self.old = old; self.destination = destination
        }
    }
    public struct Entry: Hashable, Sendable {
        public let dot: DotProvenance?
        public let family: Family
        public let rowOrdinal: Int
        public let identity: MacIRInstruction.Identity
        public let qTransferOrdinal: Int?
        public let outputSource: MacIRValue?
        public let outputDestination: MacIRValue?
        public let outputBits: Int?
        public init(family: Family, dot: DotProvenance? = nil, rowOrdinal: Int, identity: MacIRInstruction.Identity,
                    qTransferOrdinal: Int? = nil, outputSource: MacIRValue? = nil,
                    outputDestination: MacIRValue? = nil, outputBits: Int? = nil) {
            self.dot = dot; self.family = family; self.rowOrdinal = rowOrdinal; self.identity = identity
            self.qTransferOrdinal = qTransferOrdinal; self.outputSource = outputSource
            self.outputDestination = outputDestination; self.outputBits = outputBits
        }
    }
    public let entries: [Entry]
    public var rowCount: Int { entries.count }
    public var effectCount: Int { entries.count }
    public var qTransferCount: Int { entries.filter { $0.qTransferOrdinal != nil }.count }
    public var explicitOutputs: [Entry] { entries.filter { e in
        guard case let .register(name, _)? = e.outputDestination else { return false }
        return name != "wzr" && name != "xzr"
    } }
    /// This structural constructor alone never authorizes dispatch. Only the
    /// consumer's exhaustive preflight of the actual complete list may do that.
    public init?(entries: [Entry]) {
        guard (2...64).contains(entries.count) else { return nil }
        var dots = 0, reductions = 0, outputs = 0, q = 0, outputPhase = false
        var previous: UInt64?
        for (ordinal, e) in entries.enumerated() {
            let isDot = e.family == .indexedDot || e.family == .indexedMixedDot
            guard isDot == (e.dot != nil) else { return nil }
            if let d = e.dot {
                let same = d.kind == .sdot || d.kind == .udot
                guard (e.family == .indexedDot) == same else { return nil }
            }
            let pc = e.identity.sourceAddress
            guard e.rowOrdinal == ordinal, e.identity.effectOrdinal == 0, pc.isMultiple(of: 4),
                  (e.family == .terminal) == (ordinal == entries.count - 1) else { return nil }
            if let p = previous { guard p <= UInt64.max-4, pc == p+4 else { return nil } }
            previous = pc
            if e.family == .umov32 || e.family == .scalarToGPR {
                guard e.outputSource != nil, e.outputDestination != nil,
                      e.outputBits == 32 || (e.family == .scalarToGPR && e.outputBits == 64) else { return nil }
                if case let .register(name, _)? = e.outputDestination, name != "wzr", name != "xzr" { outputs += 1 }
                outputPhase = true
            } else {
                guard e.outputSource == nil, e.outputDestination == nil, e.outputBits == nil,
                      !outputPhase || e.family == .nop || e.family == .terminal else { return nil }
            }
            if e.family == .loadQ { guard e.qTransferOrdinal == q else { return nil }; q += 1 }
            else { guard e.qTransferOrdinal == nil else { return nil } }
            if e.family == .indexedDot || e.family == .indexedMixedDot { dots += 1 }; if e.family == .addv32 { reductions += 1 }
        }
        guard dots > 0, reductions > 0, outputs > 0 else { return nil }
        self.entries = entries
    }
}

// MARK: - MacIRNEONIndexedMixedByteDotProduct

/// Indexed USDOT/SUDOT only; four byte products plus OLD32, modulo 2^32.
public struct MacIRNEONIndexedMixedByteDotProduct: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case usdot, sudot }
    public let kind: Kind
    public enum ByteRole: String, Hashable, Sendable { case signed, unsigned }
    public let firstRole: ByteRole
    public let coefficientRole: ByteRole
    public let coefficientBytes: Int = 16
    public let selectedGroup: Int
    public let activeBytes: Int
    public let groupBytes: Int = 4
    public init?(kind: Kind, selectedGroup: Int, activeBytes: Int) {
        guard (0...3).contains(selectedGroup), activeBytes == 8 || activeBytes == 16 else { return nil }
        self.firstRole = kind == .usdot ? .unsigned : .signed
        self.coefficientRole = kind == .usdot ? .signed : .unsigned
        self.kind = kind; self.selectedGroup = selectedGroup; self.activeBytes = activeBytes
    }
    public var laneCount: Int { activeBytes / groupBytes }
    public func evaluate(first: (low: UInt64, high: UInt64), second: (low: UInt64, high: UInt64), old: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64) {
        func byte(_ value: (low: UInt64, high: UInt64), _ index: Int, _ role: ByteRole) -> Int64 {
            let raw = Int64(((index < 8 ? value.low : value.high) >> ((index % 8) * 8)) & 255)
            return role == .signed && raw >= 128 ? raw - 256 : raw
        }
        // One coefficient group from the complete physical128 Vm, independent of Q.
        let coefficient = (0..<groupBytes).map { byte(second, selectedGroup * groupBytes + $0, coefficientRole) }
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<laneCount {
            let offset = lane * 32, position = offset % 64
            let accumulator = Int64(((offset < 64 ? old.low : old.high) >> position) & 0xffff_ffff)
            var sum = accumulator
            for term in 0..<groupBytes {
                let index = lane * groupBytes + term
                sum += byte(first, index, firstRole) * coefficient[term]
            }
            let result = UInt64(UInt32(truncatingIfNeeded: sum))
            if offset < 64 { low |= result << position } else { high |= result << position }
        }
        return (low, high) // Q0 clears high64; no OLD high-half leakage.
    }
}

// MARK: - MacIRNEONIndexedProductPairwise

/// Immutable receipt of a whole source-bound, ordinary-Q indexed H→S→ADDP graph.
/// No arithmetic semantics or persistent instruction metadata are added.
public struct MacIRNEONIndexedProductPairwise: Hashable, Sendable {
    public let rowCount: Int
    public let productCount: Int
    public let pairwiseCount: Int
    public let qTransferCount: Int
    init(rowCount: Int, productCount: Int, pairwiseCount: Int, qTransferCount: Int) {
        self.rowCount = rowCount; self.productCount = productCount
        self.pairwiseCount = pairwiseCount; self.qTransferCount = qTransferCount
    }
}

// MARK: - MacIRNEONMagnitudeClamp

/// Non-saturating lane magnitude and same-width extrema only. No QC or FP.
public struct MacIRNEONMagnitudeClamp: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case abs, neg, smin, smax, umin, umax }
    public let kind: Kind
    public let elementBytes: Int
    public let activeBytes: Int
    public var arity: Int { kind == .abs || kind == .neg ? 1 : 2 }
    public var laneCount: Int { activeBytes / elementBytes }
    public init?(kind: Kind, elementBytes: Int, activeBytes: Int) {
        guard [8,16].contains(activeBytes), [1,2,4,8].contains(elementBytes),
              elementBytes != 8 || (activeBytes == 16 && (kind == .abs || kind == .neg)) else { return nil }
        self.kind = kind; self.elementBytes = elementBytes; self.activeBytes = activeBytes
    }
}

// MARK: - MacIRNEONMatrixPackedOutput

/// An immutable exhaustive row/effect map, not an arithmetic or memory engine.
/// DOT81 exact one76 matrix → one63 rounded32 → one54 narrow16.
/// This certificate introduces no numerical engine and no instruction metadata.
/// Each admitted original row has exactly one effect. Q transfer ordinals count
/// only LDR/STR, independently of original rows and rounded/narrowing operations.
public struct MacIRNEONMatrixPackedOutput: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case matrix, rounded, narrow, loadQ, storeQ, nop, terminal }
    public struct Entry: Hashable, Sendable {
        public let family: Family
        public let rowOrdinal: Int
        public let identity: MacIRInstruction.Identity
        public let qTransferOrdinal: Int?
        public init(family: Family, rowOrdinal: Int, identity: MacIRInstruction.Identity, qTransferOrdinal: Int? = nil) {
            self.family = family; self.rowOrdinal = rowOrdinal
            self.identity = identity; self.qTransferOrdinal = qTransferOrdinal
        }
    }
    public let entries: [Entry]
    public var rowCount: Int { entries.count }
    public var effectCount: Int { entries.count }
    public var qTransferCount: Int { entries.filter { $0.qTransferOrdinal != nil }.count }
    public var memoryByteCount: Int { qTransferCount * 16 }
    /// A structural certificate is issued only after exhaustive consumer preflight.
    /// The public structural constructor cannot authorize dispatch on its own.
    public init?(entries: [Entry]) {
        guard (2...64).contains(entries.count) else { return nil }
        var matrices = 0, rounds = 0, narrows = 0, loads = 0, stores = 0, q = 0
        var previousPC: UInt64?
        for (ordinal, entry) in entries.enumerated() {
            let pc = entry.identity.sourceAddress
            guard entry.rowOrdinal == ordinal, entry.identity.effectOrdinal == 0,
                  pc.isMultiple(of: 4),
                  (entry.family == .terminal) == (ordinal == entries.count - 1) else { return nil }
            if let previous = previousPC { guard previous <= UInt64.max - 4, pc == previous + 4 else { return nil } }
            previousPC = pc
            switch entry.family {
            case .loadQ, .storeQ:
                guard entry.qTransferOrdinal == q else { return nil }; q += 1
                if entry.family == .loadQ { loads += 1 } else { stores += 1 }
            case .matrix, .rounded, .narrow, .nop, .terminal:
                guard entry.qTransferOrdinal == nil else { return nil }
                if entry.family == .matrix { guard rounds == 0 && narrows == 0 else { return nil }; matrices += 1 }
                if entry.family == .rounded { guard matrices == 1 && narrows == 0 else { return nil }; rounds += 1 }
                if entry.family == .narrow { guard matrices == 1 && rounds == 1 else { return nil }; narrows += 1 }
            }
        }
        guard matrices == 1, rounds == 1, narrows == 1, loads > 0 && stores > 0 else { return nil }
        self.entries = entries
    }
}

// MARK: - MacIRNEONMixedByteDotProduct

/// Actual whole-vector USDOT only: unsigned first bytes × signed second bytes + OLD32.
/// The fixed roles are part of the immutable semantic descriptor, not mnemonic inference.
public struct MacIRNEONMixedByteDotProduct: Hashable, Sendable {
    public enum ByteSignedness: String, Hashable, Sendable { case unsigned, signed }
    public let firstSignedness: ByteSignedness = .unsigned
    public let secondSignedness: ByteSignedness = .signed
    public let activeBytes: Int
    public let groupBytes: Int = 4
    public init?(activeBytes: Int) {
        guard activeBytes == 8 || activeBytes == 16 else { return nil }
        self.activeBytes = activeBytes
    }
    public var laneCount: Int { activeBytes / groupBytes }
    public func evaluate(firstUnsigned: (low: UInt64, high: UInt64), secondSigned: (low: UInt64, high: UInt64), old: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64) {
        func rawByte(_ value: (low: UInt64, high: UInt64), _ index: Int) -> Int64 {
            Int64(((index < 8 ? value.low : value.high) >> ((index % 8) * 8)) & 255)
        }
        var low: UInt64 = 0, high: UInt64 = 0
        for lane in 0..<laneCount {
            let offset = lane * 32, position = offset % 64
            var sum = Int64(((offset < 64 ? old.low : old.high) >> position) & 0xffff_ffff)
            for term in 0..<groupBytes {
                let index = lane * groupBytes + term
                let unsigned = rawByte(firstUnsigned, index)
                let rawSigned = rawByte(secondSigned, index)
                let signed = rawSigned < 128 ? rawSigned : rawSigned - 256
                sum += unsigned * signed // Bounded Int64; conversion precedes multiplication.
            }
            let result = UInt64(UInt32(truncatingIfNeeded: sum))
            if offset < 64 { low |= result << position } else { high |= result << position }
        }
        return (low, high) // Each lane modulo32 independently; Q0 clears high64.
    }
}

// MARK: - MacIRNEONModular

/// Fixed-vector ADD/SUB. Unsigned wrapping implements either signedness modulo each lane.
public struct MacIRNEONModular: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case add, sub }
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
    public var intrinsicName: String { "neon_\(kind.rawValue)_\(arrangement.rawValue)_modular_zero_upper" }
    public func evaluate(_ lhs: (low: UInt64, high: UInt64), _ rhs: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64) {
        let bits = arrangement.laneBits
        // The 64-bit case never forms 1 << 64; additions/subtractions never trap.
        let mask: UInt64 = bits == 64 ? .max : (UInt64(1) << bits) - 1
        var low: UInt64 = 0, high: UInt64 = 0
        for offset in stride(from: 0, to: arrangement.vectorBits, by: bits) {
            let shift = offset % 64
            let a = ((offset < 64 ? lhs.low : lhs.high) >> shift) & mask
            let b = ((offset < 64 ? rhs.low : rhs.high) >> shift) & mask
            let lane = (kind == .add ? a &+ b : a &- b) & mask
            if offset < 64 { low |= lane << shift } else { high |= lane << shift }
        }
        return (low, high)
    }
}

// MARK: - MacIRNEONMultiply

/// Fixed-width, non-saturating integer products only. No widening, FP or flags.
public struct MacIRNEONMultiply: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case mul, mla, mls
        public var readsDestination: Bool { self != .mul }
    }
    public enum Arrangement: String, Hashable, Sendable {
        case b8 = "8b", b16 = "16b", h4 = "4h", h8 = "8h", s2 = "2s", s4 = "4s"
        public var laneBits: Int {
            switch self { case .b8, .b16: return 8; case .h4, .h8: return 16; case .s2, .s4: return 32 }
        }
        public var vectorBits: Int {
            switch self { case .b8, .h4, .s2: return 64; default: return 128 }
        }
    }
    public let kind: Kind
    public let arrangement: Arrangement
    /// nil means ordinary three-register MUL; otherwise one full source lane.
    public let selectedLane: Int?
    public init?(kind: Kind, arrangement: Arrangement, selectedLane: Int?) {
        if let index = selectedLane {
            guard arrangement.laneBits != 8, (0..<(128 / arrangement.laneBits)).contains(index) else { return nil }
        } else if kind != .mul { return nil }
        self.kind = kind; self.arrangement = arrangement; self.selectedLane = selectedLane
    }
    public var intrinsicName: String { "neon_\(kind.rawValue)_\(arrangement.rawValue)_\(selectedLane.map(String.init) ?? "vector")_zero_upper" }
    public func evaluate(lhs: (low: UInt64, high: UInt64), rhs: (low: UInt64, high: UInt64), oldDestination: (low: UInt64, high: UInt64)) -> (low: UInt64, high: UInt64) {
        let bits = arrangement.laneBits, mask = (UInt64(1) << arrangement.laneBits) - 1
        func lane(_ value: (low: UInt64, high: UInt64), _ index: Int) -> UInt64 {
            let offset = index * bits
            return ((offset < 64 ? value.low : value.high) >> (offset % 64)) & mask
        }
        var low: UInt64 = 0, high: UInt64 = 0
        for index in 0..<(arrangement.vectorBits / bits) {
            // At most32-bit operands; wrapping operators explicitly forbid host
            // overflow traps and final masks isolate each lane independently.
            let product = (lane(lhs, index) &* lane(rhs, selectedLane ?? index)) & mask
            let result: UInt64
            switch kind {
            case .mul: result = product
            case .mla: result = (lane(oldDestination, index) &+ product) & mask
            case .mls: result = (lane(oldDestination, index) &- product) & mask
            }
            let offset = index * bits
            if offset < 64 { low |= result << offset } else { high |= result << (offset - 64) }
        }
        return (low, high)
    }
}

// MARK: - MacIRNEONPairwise

/// Two-source integer adjacent-pair producer, not an across-lane reduction.
public struct MacIRNEONPairwise: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case addp, sminp, smaxp, uminp, umaxp }
    public let kind: Kind
    public let elementBytes: Int
    public let activeBytes: Int
    public var laneCount: Int { activeBytes / elementBytes }
    public init?(kind: Kind, elementBytes: Int, activeBytes: Int) {
        guard [1,2,4,8].contains(elementBytes), [8,16].contains(activeBytes),
              elementBytes != 8 || (activeBytes == 16 && kind == .addp) else { return nil }
        self.kind = kind; self.elementBytes = elementBytes; self.activeBytes = activeBytes
    }
}

// MARK: - MacIRNEONPeakLongProductMagnitude

/// Exact closed outcome, not instruction metadata or recovered scalar-return ABI.
/// Whole signed16 products widen first into signed32 [-1073709056,1073741824].
/// Modular ABS.S feeds unsigned UMAXV.S with exact upper96 zero complement.
/// This range follows only from the certified loaded H inputs. Exact raw S projection;
/// no saturation, FP, global range guarantee or recovered scalar return ABI.
public struct MacIRNEONPeakLongProductMagnitude: Hashable, Sendable {
    public let rowCount: Int
    public let productCount: Int
    public let magnitudeCount: Int
    public let reductionCount: Int
    public let qTransferCount: Int
    public let explicitOutputs: [MacIRValue]
    public var effectCount: Int { rowCount }
    // Only the exhaustive source-bound consumer constructs this certificate.
    init(rowCount: Int, productCount: Int, magnitudeCount: Int, reductionCount: Int,
         qTransferCount: Int, explicitOutputs: [MacIRValue]) {
        self.rowCount = rowCount; self.productCount = productCount; self.magnitudeCount = magnitudeCount
        self.reductionCount = reductionCount; self.qTransferCount = qTransferCount
        self.explicitOutputs = explicitOutputs
    }
}

// MARK: - MacIRNEONPeakMagnitudeScalarScore

/// Exact closed outcome, not instruction metadata or recovered scalar-return ABI.
/// Signed ABS wraps modulo H/S width, including INT_MIN. UMAXV interprets
/// those bits unsigned and clears upper112/96. Exact raw S projection only;
/// no saturation, FP, global range guarantee or recovered scalar return ABI.
public struct MacIRNEONPeakMagnitudeScalarScore: Hashable, Sendable {
    public let rowCount: Int
    public let magnitudeCount: Int
    public let reductionCount: Int
    public let qTransferCount: Int
    public let explicitOutputs: [MacIRValue]
    public var effectCount: Int { rowCount }
    // Only the exhaustive source-bound consumer constructs this certificate.
    init(rowCount: Int, magnitudeCount: Int, reductionCount: Int,
         qTransferCount: Int, explicitOutputs: [MacIRValue]) {
        self.rowCount = rowCount; self.magnitudeCount = magnitudeCount
        self.reductionCount = reductionCount; self.qTransferCount = qTransferCount
        self.explicitOutputs = explicitOutputs
    }
}

// MARK: - MacIRNEONPeakMagnitudeThreshold

/// Exact closed outcome, not instruction metadata or recovered scalar-return ABI.
/// Signed ABS wraps modulo H/S width, including INT_MIN. UMAXV interprets
/// those bits unsigned and clears upper112/96. Scalar D comparisons produce low64 allones/zero and high64zero.
/// Raw W projection preserves 0xffffffff/0 masks, never 1/0;
/// no saturation, FP, global range guarantee or recovered scalar return ABI.
public struct MacIRNEONPeakMagnitudeThreshold: Hashable, Sendable {
    public let rowCount: Int
    public let magnitudeCount: Int
    public let reductionCount: Int
    public let comparisonCount: Int
    public let qTransferCount: Int
    public let explicitOutputs: [MacIRValue]
    public var effectCount: Int { rowCount }
    // Only the exhaustive source-bound consumer constructs this certificate.
    init(rowCount: Int, magnitudeCount: Int, reductionCount: Int,
         comparisonCount: Int, qTransferCount: Int, explicitOutputs: [MacIRValue]) {
        self.rowCount = rowCount; self.magnitudeCount = magnitudeCount
        self.reductionCount = reductionCount; self.comparisonCount = comparisonCount; self.qTransferCount = qTransferCount
        self.explicitOutputs = explicitOutputs
    }
}

// MARK: - MacIRNEONReplicatedIndexedProduct

/// Marks every effect in one closed replicated H/S coefficient product route.
/// Payload semantics remain in actual89, actual67/64 and actual31 descriptors.
public struct MacIRNEONReplicatedIndexedProduct: Hashable, Sendable {
    public let ordinal: Int
    public init?(ordinal: Int) {
        guard ordinal >= 0, ordinal < 316 else { return nil }
        self.ordinal = ordinal
    }
}
/// Issued only after exhaustive original-row, effect, physical-SSA and use checks.
public struct MacIRNEONReplicatedIndexedProductCertificate: Hashable, Sendable {
    public let rowCount: Int
    public let effectCount: Int
    public let frameCount: Int
    public let byteReadCount: Int
    public let productCount: Int
    public let qLoadCount: Int
    public let qStoreCount: Int
    public let identities: [MacIRInstruction.Identity]
}

// MARK: - MacIRNEONScalarDotScore

/// DOT74 is an exhaustive composition certificate, never a new arithmetic engine.
/// No instruction metadata field or public Identity/State redesign is required.
public struct MacIRNEONScalarDotScore: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case dot, addv32, umov32, scalarToGPR, loadQ, nop, terminal }
    public struct Entry: Hashable, Sendable {
        public let family: Family
        public let rowOrdinal: Int
        public let identity: MacIRInstruction.Identity
        public let qTransferOrdinal: Int?
        public let outputSource: MacIRValue?
        public let outputDestination: MacIRValue?
        public let outputBits: Int?
        public init(family: Family, rowOrdinal: Int, identity: MacIRInstruction.Identity,
                    qTransferOrdinal: Int? = nil, outputSource: MacIRValue? = nil,
                    outputDestination: MacIRValue? = nil, outputBits: Int? = nil) {
            self.family = family; self.rowOrdinal = rowOrdinal; self.identity = identity
            self.qTransferOrdinal = qTransferOrdinal; self.outputSource = outputSource
            self.outputDestination = outputDestination; self.outputBits = outputBits
        }
    }
    public let entries: [Entry]
    public var rowCount: Int { entries.count }
    public var effectCount: Int { entries.count }
    public var qTransferCount: Int { entries.filter { $0.qTransferOrdinal != nil }.count }
    public var explicitOutputs: [Entry] { entries.filter { e in
        guard case let .register(name, _)? = e.outputDestination else { return false }
        return name != "wzr" && name != "xzr"
    } }
    /// This structural constructor alone never authorizes dispatch. Only the
    /// consumer's exhaustive preflight of the actual complete list may do that.
    public init?(entries: [Entry]) {
        guard (2...64).contains(entries.count) else { return nil }
        var dots = 0, reductions = 0, outputs = 0, q = 0, outputPhase = false
        var previous: UInt64?
        for (ordinal, e) in entries.enumerated() {
            let pc = e.identity.sourceAddress
            guard e.rowOrdinal == ordinal, e.identity.effectOrdinal == 0, pc.isMultiple(of: 4),
                  (e.family == .terminal) == (ordinal == entries.count - 1) else { return nil }
            if let p = previous { guard p <= UInt64.max-4, pc == p+4 else { return nil } }
            previous = pc
            if e.family == .umov32 || e.family == .scalarToGPR {
                guard e.outputSource != nil, e.outputDestination != nil,
                      e.outputBits == 32 || (e.family == .scalarToGPR && e.outputBits == 64) else { return nil }
                if case let .register(name, _)? = e.outputDestination, name != "wzr", name != "xzr" { outputs += 1 }
                outputPhase = true
            } else {
                guard e.outputSource == nil, e.outputDestination == nil, e.outputBits == nil,
                      !outputPhase || e.family == .nop || e.family == .terminal else { return nil }
            }
            if e.family == .loadQ { guard e.qTransferOrdinal == q else { return nil }; q += 1 }
            else { guard e.qTransferOrdinal == nil else { return nil } }
            if e.family == .dot { dots += 1 }; if e.family == .addv32 { reductions += 1 }
        }
        guard dots > 0, reductions > 0, outputs > 0 else { return nil }
        self.entries = entries
    }
}

// MARK: - MacIRNEONScaledWideningDifference

/// Complete closed function certificate. No new instruction metadata or ABI.
public struct MacIRNEONScaledWideningDifference: Hashable, Sendable {
    public enum Graph: String, Hashable, Sendable { case shiftNarrow, arithmeticThenNarrow }
    public let graph: Graph
    public let rowCount: Int
    public let differenceCount: Int
    public let narrowCount: Int
    public let qTransferCount: Int
    init(graph: Graph, rowCount: Int, differenceCount: Int, narrowCount: Int, qTransferCount: Int) {
        self.graph = graph; self.rowCount = rowCount; self.differenceCount = differenceCount
        self.narrowCount = narrowCount; self.qTransferCount = qTransferCount
    }
}

// MARK: - MacIRNEONSelectedSignedMultiply

/// Current decoded signed SMULL/SMULL2 vector-by-element H/S products only.
/// Q selects the FIRST source half; coefficient index always addresses full128.
public struct MacIRNEONSelectedSignedMultiply: Hashable, Sendable {
    public struct SourceRole: Hashable, Sendable {
        public let laneBits: Int
        public let signed: Bool
        public let highHalf: Bool
    }
    public struct SelectedLaneRole: Hashable, Sendable {
        public let laneBits: Int
        public let signed: Bool
        public let index: Int
    }
    public let narrowBits: Int
    public let sourceHighHalf: Bool
    public let selectedLane: Int
    public var outputLaneBits: Int { narrowBits * 2 }
    public var laneCount: Int { 128 / outputLaneBits }
    public var firstSource: SourceRole {
        .init(laneBits: narrowBits, signed: true, highHalf: sourceHighHalf)
    }
    public var coefficient: SelectedLaneRole {
        .init(laneBits: narrowBits, signed: true, index: selectedLane)
    }
    public init?(narrowBits: Int, sourceHighHalf: Bool, selectedLane: Int) {
        guard [16, 32].contains(narrowBits), (0..<(128 / narrowBits)).contains(selectedLane) else { return nil }
        self.narrowBits = narrowBits
        self.sourceHighHalf = sourceHighHalf
        self.selectedLane = selectedLane
    }
}

// MARK: - MacIRNEONSelectedUnsignedMultiply

/// Current decoded unsigned UMULL/UMULL2 vector-by-element H/S products only.
/// Q selects the FIRST source half; coefficient index always addresses full128.
public struct MacIRNEONSelectedUnsignedMultiply: Hashable, Sendable {
    public struct SourceRole: Hashable, Sendable {
        public let laneBits: Int
        public let signed: Bool
        public let highHalf: Bool
    }
    public struct SelectedLaneRole: Hashable, Sendable {
        public let laneBits: Int
        public let signed: Bool
        public let index: Int
    }
    public let narrowBits: Int
    public let sourceHighHalf: Bool
    public let selectedLane: Int
    public var outputLaneBits: Int { narrowBits * 2 }
    public var laneCount: Int { 128 / outputLaneBits }
    public var firstSource: SourceRole {
        .init(laneBits: narrowBits, signed: false, highHalf: sourceHighHalf)
    }
    public var coefficient: SelectedLaneRole {
        .init(laneBits: narrowBits, signed: false, index: selectedLane)
    }
    public init?(narrowBits: Int, sourceHighHalf: Bool, selectedLane: Int) {
        guard [16, 32].contains(narrowBits), (0..<(128 / narrowBits)).contains(selectedLane) else { return nil }
        self.narrowBits = narrowBits
        self.sourceHighHalf = sourceHighHalf
        self.selectedLane = selectedLane
    }
}

// MARK: - MacIRNEONSelectedWideningAccumulate

/// Current decoded indexed SMLAL/SMLSL/UMLAL/UMLSL H/S only.
/// Q selects the FIRST source half; coefficient index always addresses full128.
public struct MacIRNEONSelectedWideningAccumulate: Hashable, Sendable {
    public enum Signedness: String, Hashable, Sendable { case signed, unsigned }
    public enum Kind: String, Hashable, Sendable { case add, subtract }
    public let signedness: Signedness
    public let kind: Kind
    public struct SourceRole: Hashable, Sendable {
        public let laneBits: Int
        public let signed: Bool
        public let highHalf: Bool
    }
    public struct SelectedLaneRole: Hashable, Sendable {
        public let laneBits: Int
        public let signed: Bool
        public let index: Int
    }
    public let narrowBits: Int
    public let sourceHighHalf: Bool
    public let selectedLane: Int
    public var outputLaneBits: Int { narrowBits * 2 }
    public var laneCount: Int { 128 / outputLaneBits }
    public var firstSource: SourceRole {
        .init(laneBits: narrowBits, signed: signedness == .signed, highHalf: sourceHighHalf)
    }
    public var coefficient: SelectedLaneRole {
        .init(laneBits: narrowBits, signed: signedness == .signed, index: selectedLane)
    }
    public init?(signedness: Signedness, kind: Kind, narrowBits: Int, sourceHighHalf: Bool, selectedLane: Int) {
        guard [16, 32].contains(narrowBits), (0..<(128 / narrowBits)).contains(selectedLane) else { return nil }
        self.signedness = signedness
        self.kind = kind
        self.narrowBits = narrowBits
        self.sourceHighHalf = sourceHighHalf
        self.selectedLane = selectedLane
    }
}

// MARK: - MacIRNEONSignedLongMultiply

/// Only whole-vector SMULL/SMULL2 emitted by the existing decoder.
/// Q selects low/high64 from BOTH signed narrow sources; result is always128.
public struct MacIRNEONSignedLongMultiply: Hashable, Sendable {
    public struct SourceRole: Hashable, Sendable {
        public let laneBits: Int
        public let signed: Bool
        public let highHalf: Bool
    }
    public let narrowBits: Int
    public let sourceHighHalf: Bool
    public var outputLaneBits: Int { narrowBits * 2 }
    public var laneCount: Int { 128 / outputLaneBits }
    public var firstSource: SourceRole {
        .init(laneBits: narrowBits, signed: true, highHalf: sourceHighHalf)
    }
    public var secondSource: SourceRole { firstSource }
    public init?(narrowBits: Int, sourceHighHalf: Bool) {
        guard [8, 16, 32].contains(narrowBits) else { return nil }
        self.narrowBits = narrowBits; self.sourceHighHalf = sourceHighHalf
    }
}

// MARK: - MacIRNEONWideningAddSubtract

/// Exactly the signed-long and unsigned-wide forms emitted by the current decoder.
/// Every argument and result is physical128. Q selects narrow SOURCE halves only.
public struct MacIRNEONWideningAddSubtract: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case saddl, ssubl, uaddw }
    public struct SourceRole: Hashable, Sendable {
        public let laneBits: Int
        public let signed: Bool
        public let highHalf: Bool
    }
    public let kind: Kind
    public let narrowBits: Int
    public let sourceHighHalf: Bool
    public var outputLaneBits: Int { narrowBits * 2 }
    public var laneCount: Int { 128 / outputLaneBits }
    public var firstSource: SourceRole {
        .init(laneBits: kind == .uaddw ? outputLaneBits : narrowBits,
              signed: kind != .uaddw, highHalf: kind != .uaddw && sourceHighHalf)
    }
    public var secondSource: SourceRole {
        .init(laneBits: narrowBits, signed: kind != .uaddw, highHalf: sourceHighHalf)
    }
    public init?(kind: Kind, narrowBits: Int, sourceHighHalf: Bool) {
        guard [8, 16, 32].contains(narrowBits) else { return nil }
        self.kind = kind; self.narrowBits = narrowBits; self.sourceHighHalf = sourceHighHalf
    }
}

// MARK: - MacIRNEONWideningPairwise

/// Adjacent pairs from ONE narrow source. This is neither49 same-width two-source
/// pairwise nor39 across-lane reduction, and has no40 source-high-half role.
public struct MacIRNEONWideningPairwise: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case saddlp, uaddlp, sadalp, uadalp }
    public let kind: Kind
    public let sourceElementBytes: Int
    public let activeBytes: Int
    public var destinationElementBytes: Int { sourceElementBytes * 2 }
    public var sourceLaneCount: Int { activeBytes / sourceElementBytes }
    public var destinationLaneCount: Int { sourceLaneCount / 2 }
    public var isSigned: Bool { kind == .saddlp || kind == .sadalp }
    public var accumulates: Bool { kind == .sadalp || kind == .uadalp }
    public var arity: Int { accumulates ? 2 : 1 }
    public init?(kind: Kind, sourceElementBytes: Int, activeBytes: Int) {
        guard [1, 2, 4].contains(sourceElementBytes), [8, 16].contains(activeBytes) else { return nil }
        self.kind = kind; self.sourceElementBytes = sourceElementBytes; self.activeBytes = activeBytes
    }
}
