import Foundation

// MARK: - MacIRNEONBufferMemory

/// Bounded fixed-Q transfer, carried alongside a real .load/.store operation.
/// The instruction array retains effects in program order; sequence is the
/// zero-based memory-effect ordinal, not a license to reorder or elide effects.
/// No alias, fault, alignment, tagging, image-byte or stack authority is added.
public struct MacIRNEONBufferMemory: Hashable, Sendable {
    public enum Effect: Hashable, Sendable { case load, store }
    public let effect: Effect
    public let base: MacIRValue
    public let byteOffset: UInt64
    public let sequence: Int
    public var byteWidth: Int { 16 }
    public var littleEndian: Bool { true }
    public var address: MacIRValue {
        byteOffset == 0 ? base : .binaryExpression(op: "+", left: base, right: .immediate(Int64(byteOffset)))
    }

    public init?(effect: Effect, base: MacIRValue, byteOffset: UInt64, sequence: Int) {
        guard byteOffset <= 65520, byteOffset.isMultiple(of: 16), sequence >= 0 else { return nil }
        self.effect = effect
        self.base = base
        self.byteOffset = byteOffset
        self.sequence = sequence
    }
}

// MARK: - MacIRNEONBufferSequence

/// DOT33 framing for ordered successful Q effects on the actual DOT31 carrier.
/// It is not an atomic/fault/partial-completion or concurrent-memory contract.
/// Every expanded effect retains the architectural source address. Instruction.id
/// combines that address with the ordinal; EffectIdentity carries the same provenance.
public struct MacIRNEONBufferSequence: Hashable, Sendable {
    public enum Mode: Hashable, Sendable { case offset, preIndex, postIndex }
    public struct EffectIdentity: Hashable, Sendable {
        public let sourceAddress: UInt64
        public let ordinal: Int
    }
    public let effect: MacIRNEONBufferMemory.Effect
    public let mode: Mode
    public let delta: Int64
    public let baseRegister: String
    public let oldBase: MacIRValue
    /// Load destinations or store source snapshots in architectural pair order.
    public let vectors: [MacIRValue]
    public let baseDestination: MacIRValue?
    public let firstMemorySequence: Int
    public var writesBase: Bool { mode != .offset }
    public var effectCount: Int { vectors.count + (writesBase ? 1 : 0) }
    public var newBase: MacIRValue { Self.add(oldBase, delta) }
    public var firstAddress: MacIRValue { mode == .postIndex ? oldBase : newBase }

    public static func add(_ base: MacIRValue, _ delta: Int64) -> MacIRValue {
        delta == 0 ? base : .binaryExpression(op: "+", left: base, right: .immediate(delta))
    }
    public func memory(_ index: Int) -> MacIRNEONBufferMemory {
        // Signed/modulo arithmetic lives in the exact address expression. The
        // unchanged31 descriptor still models exactly one unsigned-offset Q access.
        MacIRNEONBufferMemory(effect: effect, base: Self.add(firstAddress, Int64(index * 16)),
                             byteOffset: 0, sequence: firstMemorySequence + index)!
    }
    public func operation(_ index: Int) -> MacIROperation {
        if index == vectors.count { return .assign(destination: baseDestination!, source: newBase) }
        let address = memory(index).address
        return effect == .load ? .load(destination: vectors[index], address: address)
                               : .store(source: vectors[index], address: address)
    }
    public init?(effect: MacIRNEONBufferMemory.Effect, mode: Mode, delta: Int64,
                 baseRegister: String, oldBase: MacIRValue, vectors: [MacIRValue],
                 baseDestination: MacIRValue?, firstMemorySequence: Int) {
        guard let n = Int(baseRegister.dropFirst()), baseRegister == "x\(n)", (0...30).contains(n),
              firstMemorySequence >= 0, (1...2).contains(vectors.count),
              firstMemorySequence <= Int.max - vectors.count else { return nil }
        if vectors.count == 2 {
            guard (-1024...1008).contains(delta), delta.isMultiple(of: 16) else { return nil }
        } else {
            guard mode != .offset, (-256...255).contains(delta) else { return nil }
        }
        switch oldBase {
        case let .register(name, version): guard name == baseRegister, version >= 0 else { return nil }
        case let .argument(binding): guard binding == .gpr(n) else { return nil }
        default: return nil
        }
        var names: [String] = []
        for vector in vectors {
            guard case let .register(name, version) = vector,
                  let index = Int(name.dropFirst()), name == "v\(index)", (0...31).contains(index),
                  version >= (effect == .load ? 1 : 0) else { return nil }
            names.append(name)
        }
        if effect == .load, Set(names).count != names.count { return nil }
        if mode == .offset {
            guard baseDestination == nil else { return nil }
        } else {
            guard case let .register(name, version)? = baseDestination,
                  name == baseRegister, version > 0 else { return nil }
            if case let .register(_, oldVersion) = oldBase {
                guard oldVersion < Int.max, version == oldVersion + 1 else { return nil }
            }
            if case .argument = oldBase, version != 1 { return nil }
        }
        self.effect = effect; self.mode = mode; self.delta = delta
        self.baseRegister = baseRegister; self.oldBase = oldBase; self.vectors = vectors
        self.baseDestination = baseDestination; self.firstMemorySequence = firstMemorySequence
    }
}

public struct MacIRNEONBufferSequenceStep: Hashable, Sendable {
    public let sequence: MacIRNEONBufferSequence
    public let ordinal: Int
    public init?(sequence: MacIRNEONBufferSequence, ordinal: Int) {
        guard (0..<sequence.effectCount).contains(ordinal) else { return nil }
        self.sequence = sequence; self.ordinal = ordinal
    }
    public func identity(sourceAddress: UInt64) -> MacIRNEONBufferSequence.EffectIdentity {
        .init(sourceAddress: sourceAddress, ordinal: ordinal)
    }
}

// MARK: - MacIRNEONCoefficientRoundedPack

/// Immutable row/effect/Q map for this outcome, not a new arithmetic engine.
/// Only exhaustive consumer preflight authorizes dispatch; constructing this
/// structural value does not authorize skipping any standalone validator.
public struct MacIRNEONCoefficientRoundedPack: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case accumulate, rounded, narrow, loadQ, storeQ, nop, terminal }
    public struct Entry: Hashable, Sendable {
        public let family: Family
        public let rowOrdinal: Int
        public let identity: MacIRInstruction.Identity
        public let qTransferOrdinal: Int?
        public let source: MacIRValue?
        public let coefficient: MacIRValue?
        public let old: MacIRValue?
        public let destination: MacIRValue?
        public let wideLaneBits: Int?
        public init(family: Family, rowOrdinal: Int, identity: MacIRInstruction.Identity,
                    qTransferOrdinal: Int? = nil, source: MacIRValue? = nil,
                    coefficient: MacIRValue? = nil, old: MacIRValue? = nil,
                    destination: MacIRValue? = nil, wideLaneBits: Int? = nil) {
            self.family = family; self.rowOrdinal = rowOrdinal; self.identity = identity
            self.qTransferOrdinal = qTransferOrdinal; self.source = source
            self.coefficient = coefficient; self.old = old; self.destination = destination
            self.wideLaneBits = wideLaneBits
        }
    }
    public let entries: [Entry]
    public var rowCount: Int { entries.count }
    public var effectCount: Int { entries.count }
    public var qTransferCount: Int { entries.filter { $0.qTransferOrdinal != nil }.count }
    public var memoryByteCount: Int { qTransferCount * 16 }
    public init?(entries: [Entry]) {
        guard (2...64).contains(entries.count) else { return nil }
        var accumulates = 0, rounds = 0, narrows = 0, loads = 0, stores = 0, q = 0
        var previousPC: UInt64?
        for (ordinal, e) in entries.enumerated() {
            let pc = e.identity.sourceAddress
            guard e.rowOrdinal == ordinal, e.identity.effectOrdinal == 0, pc.isMultiple(of: 4),
                  (e.family == .terminal) == (ordinal == entries.count - 1) else { return nil }
            if let previousPC { guard previousPC <= UInt64.max - 4, pc == previousPC + 4 else { return nil } }
            previousPC = pc
            switch e.family {
            case .loadQ, .storeQ:
                guard e.qTransferOrdinal == q, e.wideLaneBits == nil,
                      e.coefficient == nil, e.old == nil else { return nil }; q += 1
                if e.family == .loadQ { loads += 1 } else { stores += 1 }
            case .accumulate, .rounded, .narrow:
                guard e.qTransferOrdinal == nil, let width = e.wideLaneBits,
                      [32, 64].contains(width), e.source != nil, e.destination != nil else { return nil }
                if e.family == .accumulate {
                    guard e.coefficient != nil, e.old != nil else { return nil }; accumulates += 1
                } else {
                    guard e.coefficient == nil else { return nil }
                    if e.family == .rounded { guard e.old == nil else { return nil }; rounds += 1 }
                    else { narrows += 1 }
                }
            case .nop, .terminal:
                guard e.qTransferOrdinal == nil, e.wideLaneBits == nil, e.source == nil,
                      e.coefficient == nil, e.old == nil, e.destination == nil else { return nil }
            }
        }
        guard accumulates > 0, rounds > 0, narrows > 0, loads > 0, stores > 0 else { return nil }
        self.entries = entries
    }
}

// MARK: - MacIRNEONGroupWidenNarrow

/// A whole-list structural certificate, never another memory or arithmetic engine.
/// Row, group-frame, payload-byte and commit ordinals have deliberately distinct
/// units. Simple31 Q transfers are excluded rather than renumbered as group blocks.
public struct MacIRNEONGroupWidenNarrow: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case loadGroup, storeGroup, widening, narrow, nop, terminal }
    public struct Entry: Hashable, Sendable {
        public let family: Family
        public let rowOrdinal: Int
        public let startEffect: Int
        public let identities: [MacIRInstruction.Identity]
        public let frameSequence: Int?
        public let firstByteSequence: Int?
        public let activeBytes: Int?
        public let memoryBlockCount: Int
        public let baseCommitOrdinal: Int?
        public var effectCount: Int { identities.count }
        public var byteCount: Int { memoryBlockCount * (activeBytes ?? 0) }
        public init(family: Family, rowOrdinal: Int, startEffect: Int,
                    identities: [MacIRInstruction.Identity], frameSequence: Int? = nil,
                    firstByteSequence: Int? = nil, activeBytes: Int? = nil,
                    memoryBlockCount: Int = 0, baseCommitOrdinal: Int? = nil) {
            self.family=family; self.rowOrdinal=rowOrdinal; self.startEffect=startEffect
            self.identities=identities; self.frameSequence=frameSequence
            self.firstByteSequence=firstByteSequence; self.activeBytes=activeBytes
            self.memoryBlockCount=memoryBlockCount; self.baseCommitOrdinal=baseCommitOrdinal
        }
    }
    public let entries: [Entry]
    public let effectCount: Int
    public var rowCount: Int { entries.count }
    public var groupFrames: Int { entries.filter { $0.frameSequence != nil }.count }
    public var payloadBytes: Int { entries.reduce(0) { $0 + $1.byteCount } }
    public var memoryBlocks: Int { entries.reduce(0) { $0 + $1.memoryBlockCount } }
    public var delayedBaseCommits: Int { entries.filter { $0.baseCommitOrdinal != nil }.count }
    /// Structural map validation complements, but cannot replace, the consumer's
    /// EVERY-interior typed/SSA preflight. Delayed base commits consume no bytes.
    public init?(entries: [Entry], effectCount: Int) {
        guard (4...64).contains(entries.count), effectCount >= entries.count, effectCount <= 316 else { return nil }
        var nextEffect=0, frame=0, bytes=0, loads=0, stores=0, transforms=0
        var previousPC: UInt64?
        for (row,e) in entries.enumerated() {
            guard e.rowOrdinal == row, e.startEffect == nextEffect, (1...5).contains(e.effectCount),
                  e.effectCount <= effectCount-nextEffect, let first=e.identities.first,
                  first.sourceAddress.isMultiple(of:4),
                  e.identities.enumerated().allSatisfy({ $0.element == .init(sourceAddress:first.sourceAddress,effectOrdinal:$0.offset) }) else { return nil }
            if let pc=previousPC { guard pc <= UInt64.max-4, first.sourceAddress == pc+4 else { return nil } }
            previousPC=first.sourceAddress
            switch e.family {
            case .loadGroup, .storeGroup:
                guard row < entries.count-1, e.frameSequence == frame, e.firstByteSequence == bytes,
                      e.activeBytes == 8 || e.activeBytes == 16, (1...4).contains(e.memoryBlockCount),
                      e.baseCommitOrdinal == nil || e.baseCommitOrdinal == e.memoryBlockCount,
                      e.effectCount == e.memoryBlockCount+(e.baseCommitOrdinal == nil ? 0:1) else { return nil }
                frame += 1; bytes += e.byteCount
                if e.family == .loadGroup { loads += 1 } else { stores += 1 }
            case .widening, .narrow, .nop, .terminal:
                guard e.effectCount == 1, e.frameSequence == nil, e.firstByteSequence == nil,
                      e.activeBytes == nil, e.memoryBlockCount == 0, e.baseCommitOrdinal == nil,
                      (e.family == .terminal) == (row == entries.count-1) else { return nil }
                if e.family == .widening || e.family == .narrow { transforms += 1 }
            }
            nextEffect += e.effectCount
        }
        guard nextEffect == effectCount, loads > 0, stores > 0, transforms > 0 else { return nil }
        self.entries=entries;self.effectCount=effectCount
    }
}

// MARK: - MacIRNEONLaneBroadcastBuffer

/// Structural framing only, never a second transfer or lane implementation.
/// Entries preserve the descriptors' ORIGINAL units:
/// -47 `sequence` and31 Q `sequence` count the scalar+Q projection, as in47.
/// -48 `frameSequence` and `firstByteSequence` count lane frames/lane bytes only.
/// `transferOrdinal` orders ALL memory transfers; `qOrdinal` explicitly records
/// the Q-only projection without replacing/renumbering the retained31 descriptor.
/// `firstPayloadByte` sums actual footprints (scalar/lane1,2,4,8 or Q16).
/// Delayed base commits consume no transfer or byte ordinal.
public struct MacIRNEONLaneBroadcastBuffer: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case broadcast, lane, q }
    public struct Entry: Hashable, Sendable {
        public let family: Family
        public let startEffect: Int
        public let identities: [MacIRInstruction.Identity]
        public let transferOrdinal: Int
        public let firstPayloadByte: Int
        public let byteCount: Int
        public let scalarQSequence: Int?
        public let laneFrameSequence: Int?
        public let laneFirstByteSequence: Int?
        public let qOrdinal: Int?
        public var effectCount: Int { identities.count }
        public init(family: Family, startEffect: Int, identities: [MacIRInstruction.Identity],
                    transferOrdinal: Int, firstPayloadByte: Int, byteCount: Int,
                    scalarQSequence: Int?, laneFrameSequence: Int?, laneFirstByteSequence: Int?, qOrdinal: Int?) {
            self.family = family; self.startEffect = startEffect; self.identities = identities
            self.transferOrdinal = transferOrdinal; self.firstPayloadByte = firstPayloadByte; self.byteCount = byteCount
            self.scalarQSequence = scalarQSequence; self.laneFrameSequence = laneFrameSequence
            self.laneFirstByteSequence = laneFirstByteSequence; self.qOrdinal = qOrdinal
        }
    }
    public let entries: [Entry]
    public let effectCount: Int
    public let rowCount: Int
    public var scalarQTransfers: Int { entries.filter { $0.scalarQSequence != nil }.count }
    public var laneFrames: Int { entries.filter { $0.family == .lane }.count }
    public var laneBytes: Int { entries.filter { $0.family == .lane }.reduce(0) { $0 + $1.byteCount } }
    public var qTransfers: Int { entries.filter { $0.family == .q }.count }
    /// This validates the map itself; the consumer additionally validates EVERY
    /// typed effect, current source, access and exact shape before constructing it.
    public init?(entries: [Entry], effectCount: Int, rowCount: Int) {
        guard (3...64).contains(rowCount), effectCount >= rowCount, effectCount <= 127,
              entries.count >= 2, entries.count < rowCount else { return nil }
        var scalarQ = 0, lanes = 0, laneBytes = 0, q = 0, bytes = 0, end = 0, broadcasts = 0
        var previousPC: UInt64?
        for (ordinal,e) in entries.enumerated() {
            guard e.transferOrdinal == ordinal, e.firstPayloadByte == bytes,
                  e.startEffect >= end, (1...2).contains(e.effectCount),
                  e.startEffect <= effectCount-1-e.effectCount,
                  let first = e.identities.first, first.sourceAddress.isMultiple(of: 4),
                  previousPC == nil || first.sourceAddress > previousPC!,
                  e.identities.enumerated().allSatisfy({ $0.element == .init(sourceAddress:first.sourceAddress,effectOrdinal:$0.offset) }) else { return nil }
            switch e.family {
            case .broadcast:
                guard [1,2,4,8].contains(e.byteCount), e.scalarQSequence == scalarQ,
                      e.laneFrameSequence == nil, e.laneFirstByteSequence == nil, e.qOrdinal == nil else { return nil }
                scalarQ += 1; broadcasts += 1
            case .lane:
                guard [1,2,4,8].contains(e.byteCount), e.scalarQSequence == nil, e.qOrdinal == nil,
                      e.laneFrameSequence == lanes, e.laneFirstByteSequence == laneBytes else { return nil }
                lanes += 1; laneBytes += e.byteCount
            case .q:
                guard e.byteCount == 16, e.effectCount == 1, e.scalarQSequence == scalarQ,
                      e.qOrdinal == q, e.laneFrameSequence == nil, e.laneFirstByteSequence == nil else { return nil }
                scalarQ += 1; q += 1
            }
            bytes += e.byteCount; end = e.startEffect+e.effectCount; previousPC = first.sourceAddress
        }
        guard broadcasts > 0, lanes > 0 else { return nil }
        self.entries = entries; self.effectCount = effectCount; self.rowCount = rowCount
    }
}

// MARK: - MacIRNEONProductPairwiseBuffer

/// An immutable exhaustive row/effect map, not an arithmetic or memory engine.
/// Each admitted original row has exactly one effect. Q transfer ordinals count
/// only LDR/STR, independently of original rows and product/pairwise operations.
public struct MacIRNEONProductPairwiseBuffer: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case product, signedPairwise, loadQ, storeQ, nop, terminal }
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
        var products = 0, pairs = 0, loads = 0, stores = 0, q = 0
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
            case .product, .signedPairwise, .nop, .terminal:
                guard entry.qTransferOrdinal == nil else { return nil }
                if entry.family == .product { products += 1 }
                if entry.family == .signedPairwise { pairs += 1 }
            }
        }
        guard products > 0, pairs > 0, q == 0 || (loads > 0 && stores > 0) else { return nil }
        self.entries = entries
    }
}

// MARK: - MacIRNEONRGBLogicalBuffer

/// Exhaustive composition map only. Payload semantics remain actual59/23.
/// Row, effect, frame, byte-access and optional base-commit ordinals are distinct.
/// A caller-created structural value never authorizes skipping standalone checks.
public struct MacIRNEONRGBLogicalBuffer: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case loadChannel, storeChannel, baseCommit, logical, nop, terminal }
    public struct Entry: Hashable, Sendable {
        public let family: Family
        public let rowOrdinal: Int
        public let effectSequence: Int
        public let identity: MacIRInstruction.Identity
        public let frameSequence: Int?
        public let firstByteSequence: Int?
        public let channelOrdinal: Int?
        public let activeBytes: Int?
        public init(family: Family, rowOrdinal: Int, effectSequence: Int, identity: MacIRInstruction.Identity,
                    frameSequence: Int? = nil, firstByteSequence: Int? = nil, channelOrdinal: Int? = nil, activeBytes: Int? = nil) {
            self.family=family;self.rowOrdinal=rowOrdinal;self.effectSequence=effectSequence;self.identity=identity
            self.frameSequence=frameSequence;self.firstByteSequence=firstByteSequence;self.channelOrdinal=channelOrdinal;self.activeBytes=activeBytes
        }
    }
    public let entries: [Entry]
    public let rowCount: Int
    public let frameCount: Int
    public let memoryByteCount: Int
    public var effectCount: Int { entries.count }
    public var baseCommitCount: Int { entries.filter { $0.family == .baseCommit }.count }
    public init?(entries: [Entry]) {
        guard (4...253).contains(entries.count) else { return nil }
        var p=0,row=0,frame=0,byte=0,loads=0,stores=0,logical=0,previous:UInt64?
        while p < entries.count {
            let e=entries[p],pc=e.identity.sourceAddress
            guard e.rowOrdinal == row,e.effectSequence == p,pc.isMultiple(of:4),e.identity.effectOrdinal == 0 else { return nil }
            if let previous { guard previous <= UInt64.max-4,pc == previous+4 else { return nil } };previous=pc
            switch e.family {
            case .loadChannel,.storeChannel:
                guard let active=e.activeBytes,[8,16].contains(active),p <= entries.count-3 else { return nil }
                for channel in 0..<3 {
                    let x=entries[p+channel]
                    guard x.family == e.family,x.rowOrdinal == row,x.effectSequence == p+channel,
                          x.identity == .init(sourceAddress:pc,effectOrdinal:channel),x.frameSequence == frame,
                          x.firstByteSequence == byte,x.channelOrdinal == channel,x.activeBytes == active else { return nil }
                }
                p += 3
                if p < entries.count,entries[p].family == .baseCommit {
                    let x=entries[p]
                    guard x.rowOrdinal == row,x.effectSequence == p,x.identity == .init(sourceAddress:pc,effectOrdinal:3),
                          x.frameSequence == frame,x.firstByteSequence == byte,x.channelOrdinal == nil,x.activeBytes == active else { return nil }
                    p += 1
                }
                if e.family == .loadChannel { loads += 1 } else { stores += 1 }
                frame += 1;byte += active*3
            case .logical,.nop,.terminal:
                guard e.frameSequence == nil,e.firstByteSequence == nil,e.channelOrdinal == nil,e.activeBytes == nil,
                      (e.family == .terminal) == (p == entries.count-1) else { return nil }
                if e.family == .logical { logical += 1 };p += 1
            case .baseCommit: return nil
            }
            row += 1
        }
        guard (3...64).contains(row),entries.last?.family == .terminal,loads > 0,stores > 0,logical > 0 else { return nil }
        self.entries=entries;rowCount=row;frameCount=frame;memoryByteCount=byte
    }
}

// MARK: - MacIRNEONRoundedNarrowBuffer

/// An immutable exhaustive row/effect map, not an arithmetic or memory engine.
/// Each admitted original row has exactly one effect. Q transfer ordinals count
/// only LDR/STR, independently of original rows and rounded/narrowing operations.
public struct MacIRNEONRoundedNarrowBuffer: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case rounded, narrow, loadQ, storeQ, nop, terminal }
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
        var rounds = 0, narrows = 0, loads = 0, stores = 0, q = 0
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
            case .rounded, .narrow, .nop, .terminal:
                guard entry.qTransferOrdinal == nil else { return nil }
                if entry.family == .rounded { rounds += 1 }
                if entry.family == .narrow { narrows += 1 }
            }
        }
        guard rounds > 0, narrows > 0, q == 0 || (loads > 0 && stores > 0) else { return nil }
        self.entries = entries
    }
}
