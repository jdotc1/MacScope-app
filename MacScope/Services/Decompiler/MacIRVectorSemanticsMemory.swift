import Foundation

// MARK: - MacIRNEONBroadcastMemory

/// One scalar memory transfer, independent of destination vector width. Global
/// `sequence` counts transfers alongside unchanged31 Q memory, NOT bytes (42).
/// One vector commit and optional delayed base commit share a genuine source PC.
/// Span validation and the scalar snapshot precede either commit. Successful
/// nonconcurrent model only; no fault, atomicity, alignment or loader guarantee.
public struct MacIRNEONBroadcastMemory: Hashable, Sendable {
    public let elementBytes: Int
    public let activeBytes: Int
    public let baseRegister: String
    public let oldBase: MacIRValue
    public let destination: MacIRValue
    public let baseDestination: MacIRValue?
    public let sequence: Int
    public var byteCount: Int { elementBytes }
    public var laneCount: Int { activeBytes / elementBytes }
    public var effectCount: Int { baseDestination == nil ? 1 : 2 }
    public var fixedPostDelta: Int { baseDestination == nil ? 0 : elementBytes }
    public var newBase: MacIRValue { .binaryExpression(op: "+", left: oldBase, right: .immediate(Int64(fixedPostDelta))) }
    public func operation(_ ordinal: Int) -> MacIROperation {
        precondition((0..<effectCount).contains(ordinal))
        if ordinal == 1 { return .assign(destination: baseDestination!, source: newBase) }
        return .intrinsic(destination: destination, name: "scalar_memory_broadcast", arguments: [oldBase])
    }
    public func matches(_ operation: MacIROperation, ordinal: Int) -> Bool {
        guard (0..<effectCount).contains(ordinal) else { return false }
        if ordinal == 1 { return operation == self.operation(ordinal) }
        guard case let .intrinsic(d, _, arguments) = operation else { return false }
        return d == destination && arguments == [oldBase]
    }
    public init?(elementBytes: Int, activeBytes: Int, baseRegister: String, oldBase: MacIRValue,
                 destination: MacIRValue, baseDestination: MacIRValue?, sequence: Int) {
        guard [1,2,4,8].contains(elementBytes), [8,16].contains(activeBytes),
              !(elementBytes == 8 && activeBytes == 8), sequence >= 0, sequence < Int.max,
              let n = Int(baseRegister.dropFirst()), baseRegister == "x\(n)", (0...30).contains(n),
              case let .register(v, version) = destination, let d = Int(v.dropFirst()),
              v == "v\(d)", (0...31).contains(d), version > 0 else { return nil }
        switch oldBase {
        case let .register(name, version): guard name == baseRegister, version >= 0 else { return nil }
        case let .argument(binding): guard n < 8, binding == .gpr(n) else { return nil }
        default: return nil
        }
        if let baseDestination {
            guard case let .register(name, version) = baseDestination, name == baseRegister, version > 0 else { return nil }
            switch oldBase {
            case let .register(_, old): guard old < Int.max, version == old + 1 else { return nil }
            case .argument: guard version == 1 else { return nil }
            default: return nil
            }
        }
        self.elementBytes = elementBytes; self.activeBytes = activeBytes; self.baseRegister = baseRegister
        self.oldBase = oldBase; self.destination = destination; self.baseDestination = baseDestination; self.sequence = sequence
    }
}
public struct MacIRNEONBroadcastMemoryStep: Hashable, Sendable {
    public let frame: MacIRNEONBroadcastMemory
    public let ordinal: Int
    public init?(frame: MacIRNEONBroadcastMemory, ordinal: Int) {
        guard (0..<frame.effectCount).contains(ordinal) else { return nil }
        self.frame = frame; self.ordinal = ordinal
    }
}

// MARK: - MacIRNEONContiguousGroup

/// Byte-only LD1/ST1 multiple-structure group. Register block n occupies
/// [n*activeBytes, (n+1)*activeBytes), unlike interleaved LD2/ST2.
/// Frame sequence counts instructions; byte sequence counts memory bytes;
/// effect ordinal counts vector/memory commits plus one optional base commit.
/// Staging is an evaluator success-path rule, NOT hardware fault atomicity.
public struct MacIRNEONContiguousGroup: Hashable, Sendable {
    public struct ByteEffect: Hashable, Sendable {
        public let sequence: Int
        public let offset: Int
        public let vector: Int
        public let lane: Int
    }
    public let effect: MacIRNEONBufferMemory.Effect
    public let activeBytes: Int
    public let baseRegister: String
    public let oldBase: MacIRValue
    public let vectors: [MacIRValue]
    public let baseDestination: MacIRValue?
    /// DOT60 optional dynamic update; nil preserves actual55 fixed/no-offset.
    public let registerPost: MacIRNEONContiguousRegisterPost?
    public let frameSequence: Int
    public let firstByteSequence: Int
    public var groupCount: Int { vectors.count }
    public var byteCount: Int { groupCount * activeBytes }
    public var effectCount: Int { groupCount + (baseDestination == nil ? 0 : 1) }
    public var fixedPostDelta: Int { baseDestination == nil || registerPost != nil ? 0 : byteCount }
    public var newBase: MacIRValue { .binaryExpression(op: "+", left: oldBase, right: registerPost?.oldIncrement ?? .immediate(Int64(fixedPostDelta))) }
    public var orderedBytes: [ByteEffect] {
        (0..<byteCount).map { .init(sequence: firstByteSequence+$0, offset: $0, vector: $0/activeBytes, lane: $0%activeBytes) }
    }
    public func operation(_ ordinal: Int) -> MacIROperation {
        precondition((0..<effectCount).contains(ordinal))
        if ordinal == groupCount { return .assign(destination: baseDestination!, source: newBase) }
        let address = MacIRValue.binaryExpression(op: "+", left: oldBase, right: .immediate(Int64(ordinal*activeBytes)))
        return .intrinsic(destination: effect == .load ? vectors[ordinal] : nil,
            name: effect == .load ? "neon_load_contiguous_bytes" : "neon_store_contiguous_bytes",
            arguments: effect == .load ? [address] : [address, vectors[ordinal]])
    }
    /// Names/source diagnostics are not semantic authority.
    public func matches(_ operation: MacIROperation, ordinal: Int) -> Bool {
        guard (0..<effectCount).contains(ordinal) else { return false }
        if ordinal == groupCount { return operation == self.operation(ordinal) }
        guard case let .intrinsic(d, _, a) = operation,
              case let .intrinsic(expectedD, _, expectedA) = self.operation(ordinal) else { return false }
        return d == expectedD && a == expectedA
    }
    public init?(effect: MacIRNEONBufferMemory.Effect, activeBytes: Int, baseRegister: String,
                 oldBase: MacIRValue, vectors: [MacIRValue], baseDestination: MacIRValue?,
                 frameSequence: Int, firstByteSequence: Int, registerPost: MacIRNEONContiguousRegisterPost? = nil) {
        guard [8,16].contains(activeBytes), (1...4).contains(vectors.count),
              frameSequence >= 0, frameSequence < Int.max,
              firstByteSequence >= 0, firstByteSequence <= Int.max-vectors.count*activeBytes,
              let n = Int(baseRegister.dropFirst()), baseRegister == "x\(n)", (0...30).contains(n) else { return nil }
        switch oldBase {
        case let .register(name, version): guard name == baseRegister, version >= 0 else { return nil }
        case let .argument(binding): guard n < 8, binding.kind == .gpr, binding.value == n else { return nil }
        default: return nil
        }
        var indices: [Int] = []
        for value in vectors {
            guard case let .register(name, version) = value, let index = Int(name.dropFirst()),
                  name == "v\(index)", (0...31).contains(index), version >= (effect == .load ? 1 : 0) else { return nil }
            indices.append(index)
        }
        guard indices.enumerated().allSatisfy({ $0.element == (indices[0]+$0.offset)%32 }) else { return nil }
        if let post=registerPost {
            guard baseDestination != nil,post.incrementRegister != baseRegister || post.oldIncrement == oldBase else { return nil }
        }
        if let destination = baseDestination {
            guard case let .register(name, version) = destination, name == baseRegister, version > 0 else { return nil }
            switch oldBase {
            case let .register(_, previous): guard previous < Int.max, version == previous+1 else { return nil }
            case .argument: guard version == 1 else { return nil }
            default: return nil
            }
        }
        self.effect=effect; self.activeBytes=activeBytes; self.baseRegister=baseRegister
        self.oldBase=oldBase; self.vectors=vectors; self.baseDestination=baseDestination; self.registerPost=registerPost
        self.frameSequence=frameSequence; self.firstByteSequence=firstByteSequence
    }
}

public struct MacIRNEONContiguousGroupStep: Hashable, Sendable {
    public let frame: MacIRNEONContiguousGroup
    public let ordinal: Int
    public init?(frame: MacIRNEONContiguousGroup, ordinal: Int) {
        guard (0..<frame.effectCount).contains(ordinal) else { return nil }
        self.frame=frame; self.ordinal=ordinal
    }
    public func identity(sourceAddress: UInt64) -> MacIRInstruction.Identity {
        .init(sourceAddress: sourceAddress, effectOrdinal: ordinal)
    }
}

// MARK: - MacIRNEONContiguousRegisterPost

/// DOT60: an ordinary 64-bit X-register snapshot used ONLY after a complete
/// actual55 contiguous byte payload. This is not an address offset or footprint.
/// Rm31 is absent: that encoding belongs to actual55 fixed immediate post-index.
public struct MacIRNEONContiguousRegisterPost: Hashable, Sendable {
    public let incrementRegister: String
    public let oldIncrement: MacIRValue
    public var carrierWidth: Int { 64 }
    public init?(incrementRegister: String, oldIncrement: MacIRValue) {
        guard let n=Int(incrementRegister.dropFirst()), incrementRegister == "x\(n)",
              (0...30).contains(n) else { return nil }
        switch oldIncrement {
        case let .register(name,version):
            guard name == incrementRegister,version >= 0 else { return nil }
        case let .argument(binding):
            guard n < 8,binding.kind == .gpr,binding.value == n else { return nil }
        default: return nil
        }
        self.incrementRegister=incrementRegister;self.oldIncrement=oldIncrement
    }
}

// MARK: - MacIRNEONIndexedMemory

/// Exact Q register-offset access. Register identity and captured typed values
/// are distinct: a GPR argument/projection is not an arbitrary address expression.
public struct MacIRNEONIndexedMemory: Hashable, Sendable {
    public enum IndexExtension: Int, Hashable, Sendable { case uxtw = 2, lsl = 3, sxtw = 6, sxtx = 7
        public var width: Int { self == .uxtw || self == .sxtw ? 32 : 64 }
    }
    public let effect: MacIRNEONBufferMemory.Effect
    public let baseRegister: String
    public let indexRegister: String
    public let base: MacIRValue
    public let index: MacIRValue
    public let indexExtension: IndexExtension
    public let shift: Int
    public let sequence: Int
    public var byteWidth: Int { 16 }
    public var address: MacIRValue {
        let masked: MacIRValue = indexExtension.width == 32 ? .unary(op:"(uint32_t)",value:index) : index
        let extended: MacIRValue = indexExtension == .sxtw
            ? .unary(op:"(uint64_t)",value:.unary(op:"(int64_t)",value:.unary(op:"(int32_t)",value:masked)))
            : .unary(op:"(uint64_t)",value:masked)
        let scaled: MacIRValue = shift == 0 ? extended : .binaryExpression(op:"<<",left:extended,right:.immediate(Int64(shift)))
        return .binaryExpression(op:"+",left:.unary(op:"(uint64_t)",value:base),right:scaled)
    }
    public init?(effect: MacIRNEONBufferMemory.Effect, baseRegister: String, indexRegister: String,
                 base: MacIRValue, index: MacIRValue, indexExtension: IndexExtension, shift: Int, sequence: Int) {
        func ordinary(_ name: String, _ prefix: Character) -> Bool {
            guard name.first == prefix, let n = Int(name.dropFirst()), (0...30).contains(n) else { return false }
            return name == "\(prefix)\(n)"
        }
        let prefix: Character = indexExtension.width == 32 ? "w" : "x"
        guard ordinary(baseRegister,"x"), ordinary(indexRegister,prefix) || indexRegister == "\(prefix)zr",
              shift == 0 || shift == 4, sequence >= 0,
              Self.capturedGPR(base, physical: baseRegister), Self.capturedGPR(index, physical: indexRegister) else { return nil }
        if indexRegister.hasSuffix("zr"), index != .register(name:indexRegister,version:0) { return nil }
        self.effect=effect;self.baseRegister=baseRegister;self.indexRegister=indexRegister
        self.base=base;self.index=index;self.indexExtension=indexExtension;self.shift=shift;self.sequence=sequence
    }
    /// Only the existing register/argument and integer width-projection grammar.
    /// No symbol, immediate address, stack, temporary or general binary tree.
    private static func capturedGPR(_ value: MacIRValue, physical: String, depth: Int = 0) -> Bool {
        guard depth <= 2 else { return false }
        switch value {
        case let .register(name,version):
            guard version >= 0 else { return false }
            if name == "xzr" || name == "wzr" { return version == 0 && name == physical }
            guard name.first == "x" || name.first == "w", let n=Int(name.dropFirst()), (0...30).contains(n) else { return false }
            return name == "\(name.first!)\(n)" && String(name.dropFirst()) == String(physical.dropFirst())
        case .argument: return true
        case let .unary(op,inner): return ["(uint32_t)","(uint64_t)","(int32_t)","(int64_t)"].contains(op) && capturedGPR(inner, physical: physical, depth: depth + 1)
        default:return false
        }
    }
}

// MARK: - MacIRNEONInterleavedMemory

/// A successful, nonconcurrent LD1–LD4/ST1–ST4 multiple-structure frame.
/// Each vector is one commit, not a separate contiguous memory transfer.
/// LD1 lists are contiguous; LD2–LD4 interleave complete elements, preserving
/// each element's little-endian byte order. All bytes and payloads are staged;
/// post-index writes the base once after every vector commit. No fault,
/// atomicity, partial-completion, alignment, tag or concurrency claim is made.
public struct MacIRNEONInterleavedMemory: Hashable, Sendable {
    public struct ByteEffect: Hashable, Sendable {
        public let sequence: Int
        public let offset: Int
        public let vector: Int
        public let lane: Int
    }
    public let effect: MacIRNEONBufferMemory.Effect
    public let activeBytes: Int
    public let elementBytes: Int
    public let structureCount: Int
    public let baseRegister: String
    public let oldBase: MacIRValue
    public let vectors: [MacIRValue]
    public let baseDestination: MacIRValue?
    /// Captured before any writeback, including when Rm and Rn are the same.
    public let registerPost: MacIRNEONContiguousRegisterPost?
    public let firstByteSequence: Int
    public var groupCount: Int { vectors.count }
    public var byteCount: Int { activeBytes * groupCount }
    public var effectCount: Int { groupCount + (baseDestination == nil ? 0 : 1) }
    public var fixedPostDelta: Int { baseDestination == nil || registerPost != nil ? 0 : byteCount }
    public var newBase: MacIRValue {
        .binaryExpression(op: "+", left: oldBase, right: registerPost?.oldIncrement ?? .immediate(Int64(fixedPostDelta)))
    }
    public var orderedBytes: [ByteEffect] {
        (0..<byteCount).map { offset in
            let vector: Int
            let lane: Int
            if structureCount == 1 {
                vector = offset / activeBytes
                lane = offset % activeBytes
            } else {
                let element = offset / elementBytes
                vector = element % structureCount
                lane = (element / structureCount) * elementBytes + offset % elementBytes
            }
            return .init(sequence: firstByteSequence + offset, offset: offset, vector: vector, lane: lane)
        }
    }
    public func operation(_ ordinal: Int) -> MacIROperation {
        precondition((0..<effectCount).contains(ordinal))
        if ordinal == groupCount { return .assign(destination: baseDestination!, source: newBase) }
        return .intrinsic(destination: effect == .load ? vectors[ordinal] : nil,
            name: effect == .load ? "neon_structure_load" : "neon_structure_store",
            arguments: effect == .load ? [oldBase] : [oldBase, vectors[ordinal]])
    }
    /// Intrinsic names are diagnostic; typed metadata supplies the semantics.
    public func matches(_ operation: MacIROperation, ordinal: Int) -> Bool {
        guard (0..<effectCount).contains(ordinal) else { return false }
        if ordinal == groupCount { return operation == self.operation(ordinal) }
        guard case let .intrinsic(destination, _, arguments) = operation else { return false }
        return destination == (effect == .load ? vectors[ordinal] : nil)
            && arguments == (effect == .load ? [oldBase] : [oldBase, vectors[ordinal]])
    }
    public init?(effect: MacIRNEONBufferMemory.Effect, activeBytes: Int, baseRegister: String,
                 oldBase: MacIRValue, vectors: [MacIRValue], baseDestination: MacIRValue?,
                 firstByteSequence: Int, structureCount: Int = 2, elementBytes: Int = 1,
                 registerPost: MacIRNEONContiguousRegisterPost? = nil) {
        guard [8,16].contains(activeBytes), [1,2,4,8].contains(elementBytes),
              activeBytes % elementBytes == 0, (1...4).contains(vectors.count),
              (structureCount == 1 || structureCount == vectors.count),
              (1...4).contains(structureCount),
              !(structureCount > 1 && activeBytes == 8 && elementBytes == 8),
              firstByteSequence >= 0, firstByteSequence <= Int.max - activeBytes * vectors.count,
              baseRegister == "sp" || Self.isOrdinaryX(baseRegister) else { return nil }
        switch oldBase {
        case let .register(name, version): guard name == baseRegister, version >= 0 else { return nil }
        case let .argument(binding):
            guard let n = Int(baseRegister.dropFirst()), binding == .gpr(n) else { return nil }
        default: return nil
        }
        var indices: [Int] = []
        for v in vectors {
            guard case let .register(name, version) = v, let index = Int(name.dropFirst()),
                  name == "v\(index)", (0...31).contains(index), version >= (effect == .load ? 1 : 0) else { return nil }
            indices.append(index)
        }
        guard indices.enumerated().allSatisfy({ $0.element == (indices[0] + $0.offset) % 32 }) else { return nil }
        if let registerPost {
            guard baseDestination != nil,
                  registerPost.incrementRegister != baseRegister || registerPost.oldIncrement == oldBase else { return nil }
        }
        if let destination = baseDestination {
            guard case let .register(name, version) = destination, name == baseRegister, version > 0 else { return nil }
            switch oldBase {
            // CFG block version floors reserve gaps between definitions. The
            // architectural writeback requires a newer SSA identity, not
            // numerically adjacent versions.
            case let .register(_, oldVersion): guard version > oldVersion else { return nil }
            case .argument: break
            default: return nil
            }
        }
        self.effect = effect; self.activeBytes = activeBytes
        self.elementBytes = elementBytes; self.structureCount = structureCount; self.baseRegister = baseRegister
        self.oldBase = oldBase; self.vectors = vectors; self.baseDestination = baseDestination
        self.registerPost = registerPost
        self.firstByteSequence = firstByteSequence
    }
    private static func isOrdinaryX(_ name: String) -> Bool {
        guard let n = Int(name.dropFirst()) else { return false }
        return name == "x\(n)" && (0...30).contains(n)
    }
}

public struct MacIRNEONInterleavedMemoryStep: Hashable, Sendable {
    public let frame: MacIRNEONInterleavedMemory
    public let ordinal: Int
    public init?(frame: MacIRNEONInterleavedMemory, ordinal: Int) {
        guard (0..<frame.effectCount).contains(ordinal) else { return nil }
        self.frame = frame; self.ordinal = ordinal
    }
    /// Genuine architectural PC plus frame commit ordinal; no fabricated PC.
    public func identity(sourceAddress: UInt64) -> MacIRInstruction.Identity {
        .init(sourceAddress: sourceAddress, effectOrdinal: ordinal)
    }
}

// MARK: - MacIRNEONStructureLaneMemory

/// LD2–LD4/ST1–ST4 selected-element transfer. Each structure member occupies
/// one consecutive element in memory. Loads replace only the selected lane of
/// each physical 128-bit vector; all other bytes retain their old value.
/// Payload and post-index inputs are snapshots before any vector/base commit.
/// This success-path model makes no fault-atomicity or concurrency claim.
public struct MacIRNEONStructureLaneMemory: Hashable, Sendable {
    public struct ByteEffect: Hashable, Sendable {
        public let sequence: Int
        public let offset: Int
        public let vector: Int
        public let lane: Int
    }
    public let effect: MacIRNEONBufferMemory.Effect
    public let elementBytes: Int
    public let laneIndex: Int
    public let structureCount: Int
    public let baseRegister: String
    public let oldBase: MacIRValue
    public let oldVectors: [MacIRValue]
    /// One new SSA value per member for loads; empty for stores.
    public let destinations: [MacIRValue]
    public let baseDestination: MacIRValue?
    public let frameSequence: Int
    public let firstByteSequence: Int
    public let registerPost: MacIRNEONContiguousRegisterPost?
    public var byteCount: Int { structureCount * elementBytes }
    public var effectCount: Int { structureCount + (baseDestination == nil ? 0 : 1) }
    public var fixedPostDelta: Int { baseDestination == nil || registerPost != nil ? 0 : byteCount }
    public var vectorByteOffset: Int { laneIndex * elementBytes }
    public var preservedVectorBytes: [Int] {
        (0..<16).filter { !(vectorByteOffset..<vectorByteOffset + elementBytes).contains($0) }
    }
    public var newBase: MacIRValue {
        .binaryExpression(op: "+", left: oldBase, right: registerPost?.oldIncrement ?? .immediate(Int64(fixedPostDelta)))
    }
    public var orderedBytes: [ByteEffect] {
        (0..<byteCount).map { offset in
            .init(sequence: firstByteSequence + offset, offset: offset,
                  vector: offset / elementBytes, lane: vectorByteOffset + offset % elementBytes)
        }
    }
    public func operation(_ ordinal: Int) -> MacIROperation {
        precondition((0..<effectCount).contains(ordinal))
        if ordinal == structureCount { return .assign(destination: baseDestination!, source: newBase) }
        return .intrinsic(destination: effect == .load ? destinations[ordinal] : nil,
                          name: effect == .load ? "neon_structure_lane_load" : "neon_structure_lane_store",
                          arguments: [oldBase, oldVectors[ordinal]])
    }
    public func matches(_ operation: MacIROperation, ordinal: Int) -> Bool {
        guard (0..<effectCount).contains(ordinal) else { return false }
        if ordinal == structureCount { return operation == self.operation(ordinal) }
        guard case let .intrinsic(destination, _, arguments) = operation else { return false }
        return destination == (effect == .load ? destinations[ordinal] : nil)
            && arguments == [oldBase, oldVectors[ordinal]]
    }
    public init?(effect: MacIRNEONBufferMemory.Effect, elementBytes: Int, laneIndex: Int,
                 structureCount: Int, baseRegister: String, oldBase: MacIRValue,
                 oldVectors: [MacIRValue], destinations: [MacIRValue],
                 baseDestination: MacIRValue?, frameSequence: Int, firstByteSequence: Int,
                 registerPost: MacIRNEONContiguousRegisterPost? = nil) {
        guard [1,2,4,8].contains(elementBytes), (0..<16/elementBytes).contains(laneIndex),
              (1...4).contains(structureCount),
              // A singleton load owns only one H lane and an ordinary X base.
              // The existing frame retains all other bytes and snapshots Rm.
              (effect == .store || structureCount > 1
                || (structureCount == 1 && elementBytes == 2 && Self.isOrdinaryX(baseRegister))),
              oldVectors.count == structureCount,
              destinations.count == (effect == .load ? structureCount : 0),
              frameSequence >= 0, frameSequence < Int.max,
              firstByteSequence >= 0, firstByteSequence <= Int.max - structureCount * elementBytes,
              baseRegister == "sp" || Self.isOrdinaryX(baseRegister) else { return nil }
        switch oldBase {
        case let .register(name, version): guard name == baseRegister, version >= 0 else { return nil }
        case let .argument(binding):
            guard let n = Int(baseRegister.dropFirst()), binding == .gpr(n) else { return nil }
        default: return nil
        }
        var indices: [Int] = []
        for (offset, value) in oldVectors.enumerated() {
            guard case let .register(name, oldVersion) = value,
                  let index = Int(name.dropFirst()), name == "v\(index)",
                  (0...31).contains(index), oldVersion >= 0 else { return nil }
            indices.append(index)
            if effect == .load {
                guard case let .register(newName, newVersion) = destinations[offset],
                      newName == name, newVersion > oldVersion else { return nil }
            }
        }
        guard indices.enumerated().allSatisfy({ $0.element == (indices[0] + $0.offset) % 32 }) else { return nil }
        if let registerPost {
            guard baseDestination != nil,
                  registerPost.incrementRegister != baseRegister || registerPost.oldIncrement == oldBase else { return nil }
        }
        if let baseDestination {
            guard case let .register(name, version) = baseDestination,
                  name == baseRegister, version > 0 else { return nil }
            switch oldBase {
            case let .register(_, oldVersion): guard version > oldVersion else { return nil }
            case .argument: break
            default: return nil
            }
        }
        self.effect = effect; self.elementBytes = elementBytes; self.laneIndex = laneIndex
        self.structureCount = structureCount; self.baseRegister = baseRegister; self.oldBase = oldBase
        self.oldVectors = oldVectors; self.destinations = destinations; self.baseDestination = baseDestination
        self.frameSequence = frameSequence; self.firstByteSequence = firstByteSequence
        self.registerPost = registerPost
    }
    private static func isOrdinaryX(_ name: String) -> Bool {
        guard let n = Int(name.dropFirst()) else { return false }
        return name == "x\(n)" && (0...30).contains(n)
    }
}

public struct MacIRNEONStructureLaneMemoryStep: Hashable, Sendable {
    public let frame: MacIRNEONStructureLaneMemory
    public let ordinal: Int
    public init?(frame: MacIRNEONStructureLaneMemory, ordinal: Int) {
        guard (0..<frame.effectCount).contains(ordinal) else { return nil }
        self.frame = frame; self.ordinal = ordinal
    }
    public func identity(sourceAddress: UInt64) -> MacIRInstruction.Identity {
        .init(sourceAddress: sourceAddress, effectOrdinal: ordinal)
    }
}

// MARK: - MacIRNEONLaneCoefficientProduct

/// Marks every effect in one closed lane-loaded H/S coefficient product route.
/// Payload semantics remain in actual90, actual67/64 and actual31 descriptors.
public struct MacIRNEONLaneCoefficientProduct: Hashable, Sendable {
    public let ordinal: Int
    public init?(ordinal: Int) {
        guard ordinal >= 0, ordinal < 316 else { return nil }
        self.ordinal = ordinal
    }
}
/// Issued only after exhaustive original-row, effect, physical-SSA and use checks.
public struct MacIRNEONLaneCoefficientProductCertificate: Hashable, Sendable {
    public let rowCount: Int
    public let effectCount: Int
    public let frameCount: Int
    public let byteReadCount: Int
    public let productCount: Int
    public let qLoadCount: Int
    public let qStoreCount: Int
    public let identities: [MacIRInstruction.Identity]
}

// MARK: - MacIRNEONLaneMemory

/// Exact selected-element footprint in a physical128 vector. Q is NOT a
/// vector-width/zeroing flag here. One frame commits one partial memory effect
/// and optionally one delayed base definition, under the genuine source PC.
/// `frameSequence` counts transfers; `firstByteSequence` counts only actual
/// element bytes. Neither is a contiguous-Q or broadcast memory descriptor.
public struct MacIRNEONLaneMemory: Hashable, Sendable {
    public let effect: MacIRNEONBufferMemory.Effect
    public let elementBytes: Int
    public let laneIndex: Int
    public let baseRegister: String
    public let oldBase: MacIRValue
    public let oldVector: MacIRValue
    public let destination: MacIRValue?
    public let baseDestination: MacIRValue?
    public let frameSequence: Int
    public let firstByteSequence: Int
    public var byteCount: Int { elementBytes }
    public var vectorByteOffset: Int { elementBytes * laneIndex }
    public var effectCount: Int { baseDestination == nil ? 1 : 2 }
    public var fixedPostDelta: Int { baseDestination == nil ? 0 : elementBytes }
    public var preservedVectorBytes: [Int] { (0..<16).filter { !(vectorByteOffset..<vectorByteOffset+elementBytes).contains($0) } }
    public var newBase: MacIRValue { .binaryExpression(op: "+", left: oldBase, right: .immediate(Int64(fixedPostDelta))) }
    public func operation(_ ordinal: Int) -> MacIROperation {
        precondition((0..<effectCount).contains(ordinal))
        if ordinal == 1 { return .assign(destination: baseDestination!, source: newBase) }
        return .intrinsic(destination: destination, name: effect == .load ? "selected_lane_load" : "selected_lane_store", arguments: [oldBase, oldVector])
    }
    public func matches(_ operation: MacIROperation, ordinal: Int) -> Bool {
        guard (0..<effectCount).contains(ordinal) else { return false }
        if ordinal == 1 { return operation == self.operation(ordinal) }
        guard case let .intrinsic(d, _, args) = operation else { return false }
        return d == destination && args == [oldBase, oldVector]
    }
    public init?(effect: MacIRNEONBufferMemory.Effect, elementBytes: Int, laneIndex: Int,
                 baseRegister: String, oldBase: MacIRValue, oldVector: MacIRValue,
                 destination: MacIRValue?, baseDestination: MacIRValue?, frameSequence: Int, firstByteSequence: Int) {
        guard [1,2,4,8].contains(elementBytes), (0..<16/elementBytes).contains(laneIndex),
              frameSequence >= 0, frameSequence < Int.max, firstByteSequence >= 0,
              firstByteSequence <= Int.max-elementBytes,
              let n = Int(baseRegister.dropFirst()), baseRegister == "x\(n)", (0...30).contains(n),
              case let .register(v, oldVersion) = oldVector, let vn = Int(v.dropFirst()),
              v == "v\(vn)", (0...31).contains(vn), oldVersion >= 0 else { return nil }
        switch oldBase {
        case let .register(name, version): guard name == baseRegister, version >= 0 else { return nil }
        case let .argument(binding): guard n < 8, binding == .gpr(n) else { return nil }
        default: return nil
        }
        if effect == .load {
            guard case let .register(name, version)? = destination, name == v,
                  oldVersion < Int.max, version == oldVersion+1 else { return nil }
        } else if destination != nil { return nil }
        if let baseDestination {
            guard case let .register(name, version) = baseDestination, name == baseRegister, version > 0 else { return nil }
            switch oldBase {
            case let .register(_, old): guard old < Int.max, version == old+1 else { return nil }
            case .argument: guard version == 1 else { return nil }
            default: return nil
            }
        }
        self.effect = effect; self.elementBytes = elementBytes; self.laneIndex = laneIndex
        self.baseRegister = baseRegister; self.oldBase = oldBase; self.oldVector = oldVector
        self.destination = destination; self.baseDestination = baseDestination
        self.frameSequence = frameSequence; self.firstByteSequence = firstByteSequence
    }
}
public struct MacIRNEONLaneMemoryStep: Hashable, Sendable {
    public let frame: MacIRNEONLaneMemory
    public let ordinal: Int
    public init?(frame: MacIRNEONLaneMemory, ordinal: Int) {
        guard (0..<frame.effectCount).contains(ordinal) else { return nil }
        self.frame = frame; self.ordinal = ordinal
    }
}
