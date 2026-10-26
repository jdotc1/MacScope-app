import Foundation

// MARK: - MacIRNEONChannelTableComposition

/// Immutable exhaustive map for actual79 + actual27 with optional actual31 Q
/// inputs. Not a new arithmetic engine and not permission to skip preflight.
/// Frame-byte ordinals exclude Q inputs; global byte ordinals include them.
public struct MacIRNEONChannelTableComposition: Hashable, Sendable {
    public enum Family: Hashable, Sendable { case loadChannel, storeChannel, baseCommit, table, qLoad, nop, terminal }
    public struct Entry: Hashable, Sendable {
        public let family: Family
        public let rowOrdinal: Int
        public let effectSequence: Int
        public let identity: MacIRInstruction.Identity
        public let frameSequence: Int?
        public let firstFrameByteSequence: Int?
        public let firstGlobalByteSequence: Int?
        public let channelOrdinal: Int?
        public let activeBytes: Int?
        public let qSequence: Int?
        public init(family: Family, rowOrdinal: Int, effectSequence: Int, identity: MacIRInstruction.Identity,
                    frameSequence: Int? = nil, firstFrameByteSequence: Int? = nil, firstGlobalByteSequence: Int? = nil,
                    channelOrdinal: Int? = nil, activeBytes: Int? = nil, qSequence: Int? = nil) {
            self.family=family; self.rowOrdinal=rowOrdinal; self.effectSequence=effectSequence; self.identity=identity
            self.frameSequence=frameSequence; self.firstFrameByteSequence=firstFrameByteSequence
            self.firstGlobalByteSequence=firstGlobalByteSequence; self.channelOrdinal=channelOrdinal
            self.activeBytes=activeBytes; self.qSequence=qSequence
        }
    }
    public let entries: [Entry]
    public let rowCount: Int
    public let frameCount: Int
    public let frameByteCount: Int
    public let globalByteCount: Int
    public let qLoadCount: Int
    public var effectCount: Int { entries.count }
    public var baseCommitCount: Int { entries.filter { $0.family == .baseCommit }.count }
    public init?(entries: [Entry]) {
        guard (4...316).contains(entries.count) else { return nil }
        var p=0,row=0,frame=0,frameByte=0,globalByte=0,q=0,loads=0,stores=0,tables=0,previous:UInt64?
        while p < entries.count {
            let e=entries[p],pc=e.identity.sourceAddress
            guard e.rowOrdinal == row,e.effectSequence == p,pc.isMultiple(of:4),e.identity.effectOrdinal == 0 else { return nil }
            if let previous { guard previous <= UInt64.max-4,pc == previous+4 else { return nil } }; previous=pc
            switch e.family {
            case .loadChannel,.storeChannel:
                guard let active=e.activeBytes,[8,16].contains(active),p <= entries.count-4 else { return nil }
                for channel in 0..<4 {
                    let x=entries[p+channel]
                    guard x.family == e.family,x.rowOrdinal == row,x.effectSequence == p+channel,
                          x.identity == .init(sourceAddress:pc,effectOrdinal:channel),x.frameSequence == frame,
                          x.firstFrameByteSequence == frameByte,x.firstGlobalByteSequence == globalByte,
                          x.channelOrdinal == channel,x.activeBytes == active,x.qSequence == nil else { return nil }
                }
                p += 4
                if p < entries.count,entries[p].family == .baseCommit {
                    let x=entries[p]
                    guard x.rowOrdinal == row,x.effectSequence == p,x.identity == .init(sourceAddress:pc,effectOrdinal:4),
                          x.frameSequence == frame,x.firstFrameByteSequence == frameByte,x.firstGlobalByteSequence == globalByte,
                          x.channelOrdinal == nil,x.activeBytes == active,x.qSequence == nil else { return nil }
                    p += 1
                }
                if e.family == .loadChannel { loads += 1 } else { stores += 1 }
                frame += 1; frameByte += active*4; globalByte += active*4
            case .qLoad:
                guard e.frameSequence == nil,e.firstFrameByteSequence == nil,e.firstGlobalByteSequence == globalByte,
                      e.channelOrdinal == nil,e.activeBytes == 16,e.qSequence == q else { return nil }
                q += 1; globalByte += 16; p += 1
            case .table,.nop,.terminal:
                guard e.frameSequence == nil,e.firstFrameByteSequence == nil,e.firstGlobalByteSequence == nil,
                      e.channelOrdinal == nil,e.activeBytes == nil,e.qSequence == nil,
                      (e.family == .terminal) == (p == entries.count-1) else { return nil }
                if e.family == .table { tables += 1 }; p += 1
            case .baseCommit: return nil
            }
            row += 1
        }
        guard (3...64).contains(row),entries.last?.family == .terminal,loads > 0,stores > 0,tables > 0 else { return nil }
        self.entries=entries; rowCount=row; frameCount=frame; frameByteCount=frameByte; globalByteCount=globalByte; qLoadCount=q
    }
}

// MARK: - MacIRNEONFourChannelMemory

/// Byte-only decoded LD4/ST4 gather/scatter across exactly four consecutive
/// physical128 vectors. Byte-major memory offset is 4*lane+channel. The four
/// commit effects are NOT contiguous memory accesses. Explicit frame and byte
/// sequences remain distinct from commit ordinals and optional delayed base.
/// Source/payload staging is success-path semantics, never hardware atomicity.
public struct MacIRNEONFourChannelMemory: Hashable, Sendable {
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
    public let frameSequence: Int
    public let firstByteSequence: Int
    public var groupCount: Int { 4 }
    public var byteCount: Int { groupCount * activeBytes }
    public var effectCount: Int { groupCount + (baseDestination == nil ? 0 : 1) }
    public var fixedPostDelta: Int { baseDestination == nil ? 0 : byteCount }
    public var newBase: MacIRValue { .binaryExpression(op: "+", left: oldBase, right: .immediate(Int64(fixedPostDelta))) }
    public var orderedBytes: [ByteEffect] {
        (0..<byteCount).map { .init(sequence: firstByteSequence+$0, offset: $0, vector: $0%4, lane: $0/4) }
    }
    public func operation(_ ordinal: Int) -> MacIROperation {
        precondition((0..<effectCount).contains(ordinal))
        if ordinal == groupCount { return .assign(destination: baseDestination!, source: newBase) }
        return .intrinsic(destination: effect == .load ? vectors[ordinal] : nil,
            name: effect == .load ? "neon_gather4_bytes" : "neon_scatter4_bytes",
            arguments: effect == .load ? [oldBase] : [oldBase, vectors[ordinal]])
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
                 frameSequence: Int, firstByteSequence: Int) {
        guard [8,16].contains(activeBytes), vectors.count == 4,
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
        if let destination = baseDestination {
            guard case let .register(name, version) = destination, name == baseRegister, version > 0 else { return nil }
            switch oldBase {
            case let .register(_, previous): guard previous < Int.max, version == previous+1 else { return nil }
            case .argument: guard version == 1 else { return nil }
            default: return nil
            }
        }
        self.effect=effect; self.activeBytes=activeBytes; self.baseRegister=baseRegister
        self.oldBase=oldBase; self.vectors=vectors; self.baseDestination=baseDestination
        self.frameSequence=frameSequence; self.firstByteSequence=firstByteSequence
    }
}

public struct MacIRNEONFourChannelMemoryStep: Hashable, Sendable {
    public let frame: MacIRNEONFourChannelMemory
    public let ordinal: Int
    public init?(frame: MacIRNEONFourChannelMemory, ordinal: Int) {
        guard (0..<frame.effectCount).contains(ordinal) else { return nil }
        self.frame=frame; self.ordinal=ordinal
    }
    public func identity(sourceAddress: UInt64) -> MacIRInstruction.Identity {
        .init(sourceAddress: sourceAddress, effectOrdinal: ordinal)
    }
}

// MARK: - MacIRNEONMultiChannelLane

/// BYTE single-structure LD2/3/4 and ST2/3/4 selected-lane frame.
/// Q contributes to laneIndex, never to a vector width or high-half clear.
/// Immutable OLD full128 vectors and old base precede every payload definition.
public struct MacIRNEONMultiChannelLane: Hashable, Sendable {
    public struct ByteTransfer: Hashable, Sendable {
        public let sequence: Int
        public let offset: Int
        public let channel: Int
    }
    public let encodedWord: UInt32
    public let effect: MacIRNEONBufferMemory.Effect
    public let laneIndex: Int
    public let baseRegister: String
    public let oldBase: MacIRValue
    public let oldVectors: [MacIRValue]
    public let destinations: [MacIRValue]
    public let baseDestination: MacIRValue?
    public let frameSequence: Int
    public let firstByteSequence: Int
    public var channelCount: Int { oldVectors.count }
    public var byteCount: Int { channelCount }
    public var capturedVectorBytes: Int { 16 * channelCount }
    public var effectCount: Int { channelCount + (baseDestination == nil ? 0 : 1) }
    public var fixedPostDelta: Int { baseDestination == nil ? 0 : channelCount }
    public var preservedByteIndices: [Int] { (0..<16).filter { $0 != laneIndex } }
    public var newBase: MacIRValue { .binaryExpression(op:"+",left:oldBase,right:.immediate(Int64(fixedPostDelta))) }
    public var orderedTransfers: [ByteTransfer] {
        (0..<channelCount).map { .init(sequence:firstByteSequence+$0,offset:$0,channel:$0) }
    }
    public func operation(_ ordinal: Int) -> MacIROperation {
        precondition((0..<effectCount).contains(ordinal))
        if ordinal == channelCount { return .assign(destination:baseDestination!,source:newBase) }
        return .intrinsic(destination:effect == .load ? destinations[ordinal]:nil,
                          name:effect == .load ? "load_channel_byte_lane":"store_channel_byte_lane",
                          arguments:[oldBase,oldVectors[ordinal],.immediate(Int64(ordinal)),.immediate(Int64(laneIndex))])
    }
    public func matches(_ operation: MacIROperation, ordinal: Int) -> Bool {
        guard (0..<effectCount).contains(ordinal) else { return false }
        if ordinal == channelCount { return operation == self.operation(ordinal) }
        guard case let .intrinsic(d,_,a)=operation else { return false }
        return d == (effect == .load ? destinations[ordinal]:nil) &&
            a == [oldBase,oldVectors[ordinal],.immediate(Int64(ordinal)),.immediate(Int64(laneIndex))]
    }
    public init?(encodedWord: UInt32, effect: MacIRNEONBufferMemory.Effect, laneIndex: Int,
                 baseRegister: String, oldBase: MacIRValue, oldVectors: [MacIRValue],
                 destinations: [MacIRValue], baseDestination: MacIRValue?,
                 frameSequence: Int, firstByteSequence: Int) {
        guard (0..<16).contains(laneIndex), (2...4).contains(oldVectors.count),
              frameSequence >= 0, frameSequence < Int.max,
              firstByteSequence >= 0, firstByteSequence <= Int.max-oldVectors.count,
              let n=Int(baseRegister.dropFirst()),baseRegister == "x\(n)",(0...30).contains(n),
              destinations.count == (effect == .load ? oldVectors.count:0) else { return nil }
        switch oldBase {
        case let .register(name,version):guard name == baseRegister,version >= 0 else { return nil }
        case let .argument(binding):guard (0..<8).contains(n),binding.kind == .gpr,binding.value == n else { return nil }
        default:return nil
        }
        var indices:[Int]=[]
        for (channel,value) in oldVectors.enumerated() {
            guard case let .register(name,version)=value,let index=Int(name.dropFirst()),
                  name == "v\(index)",(0...31).contains(index),version >= 0 else { return nil }
            indices.append(index)
            if effect == .load {
                guard version < Int.max,destinations[channel] == .register(name:name,version:version+1) else { return nil }
            }
        }
        guard indices.enumerated().allSatisfy({ $0.element == (indices[0]+$0.offset)%32 }) else { return nil }
        if let destination=baseDestination {
            guard case let .register(name,version)=destination,name == baseRegister,version > 0 else { return nil }
            switch oldBase {
            case let .register(_,previous):guard previous < Int.max,version == previous+1 else { return nil }
            case .argument:guard version == 1 else { return nil }
            default:return nil
            }
        }
        let c=oldVectors.count-1
        let exact=UInt32(0x0d000000) | UInt32(c&1)<<21 | UInt32(c>>1)<<13
            | UInt32(laneIndex>>3)<<30 | UInt32((laneIndex>>2)&1)<<12 | UInt32(laneIndex&3)<<10
            | (effect == .load ? 0x00400000:0) | (baseDestination == nil ? 0:0x009f0000)
            | UInt32(n)<<5 | UInt32(indices[0])
        guard encodedWord == exact else { return nil }
        self.encodedWord=encodedWord;self.effect=effect;self.laneIndex=laneIndex
        self.baseRegister=baseRegister;self.oldBase=oldBase;self.oldVectors=oldVectors
        self.destinations=destinations;self.baseDestination=baseDestination
        self.frameSequence=frameSequence;self.firstByteSequence=firstByteSequence
    }
}
public struct MacIRNEONMultiChannelLaneStep: Hashable, Sendable {
    public let frame: MacIRNEONMultiChannelLane
    public let ordinal: Int
    public init?(frame: MacIRNEONMultiChannelLane, ordinal: Int) {
        guard (0..<frame.effectCount).contains(ordinal) else { return nil }
        self.frame=frame;self.ordinal=ordinal
    }
}
/// Produced only by the exhaustive full-list preflight before payloads.
public struct MacIRNEONMultiChannelLaneCertificate: Hashable, Sendable {
    public let rowCount: Int
    public let effectCount: Int
    public let frameCount: Int
    public let loadCount: Int
    public let storeCount: Int
    public let byteReadCount: Int
    public let byteWriteCount: Int
    public let qMemoryCount: Int
    public let identities: [MacIRInstruction.Identity]
}

// MARK: - MacIRNEONMultiChannelReplicate

/// BYTE LD2R/LD3R/LD4R captures exactly one byte per channel, not an
/// activeBytes-sized block. Source bytes and the old base are captured before
/// any full128 destination or delayed base commit. Nonfaulting model only.
public struct MacIRNEONMultiChannelReplicate: Hashable, Sendable {
    public struct ByteRead: Hashable, Sendable {
        public let sequence: Int
        public let offset: Int
        public let channel: Int
    }
    public let encodedWord: UInt32
    public let activeBytes: Int
    public let baseRegister: String
    public let oldBase: MacIRValue
    public let vectors: [MacIRValue]
    public let baseDestination: MacIRValue?
    public let frameSequence: Int
    public let firstByteSequence: Int
    public var channelCount: Int { vectors.count }
    public var byteCount: Int { channelCount }
    public var vectorFootprint: Int { activeBytes * channelCount }
    public var effectCount: Int { channelCount + (baseDestination == nil ? 0 : 1) }
    public var fixedPostDelta: Int { baseDestination == nil ? 0 : channelCount }
    public var newBase: MacIRValue { .binaryExpression(op: "+", left: oldBase, right: .immediate(Int64(fixedPostDelta))) }
    public var orderedReads: [ByteRead] {
        (0..<channelCount).map { .init(sequence:firstByteSequence+$0, offset:$0, channel:$0) }
    }
    public func operation(_ ordinal: Int) -> MacIROperation {
        precondition((0..<effectCount).contains(ordinal))
        if ordinal == channelCount { return .assign(destination:baseDestination!, source:newBase) }
        return .intrinsic(destination:vectors[ordinal], name:"replicate_channel_byte", arguments:[oldBase, .immediate(Int64(ordinal))])
    }
    public func matches(_ operation: MacIROperation, ordinal: Int) -> Bool {
        guard (0..<effectCount).contains(ordinal) else { return false }
        if ordinal == channelCount { return operation == self.operation(ordinal) }
        guard case let .intrinsic(d, _, a)=operation else { return false }
        return d == vectors[ordinal] && a == [oldBase, .immediate(Int64(ordinal))]
    }
    public init?(encodedWord: UInt32, activeBytes: Int, baseRegister: String,
                 oldBase: MacIRValue, vectors: [MacIRValue], baseDestination: MacIRValue?,
                 frameSequence: Int, firstByteSequence: Int) {
        guard [8,16].contains(activeBytes), (2...4).contains(vectors.count),
              frameSequence >= 0, frameSequence < Int.max,
              firstByteSequence >= 0, firstByteSequence <= Int.max-vectors.count,
              let n=Int(baseRegister.dropFirst()), baseRegister == "x\(n)", (0...30).contains(n) else { return nil }
        switch oldBase {
        case let .register(name, version): guard name == baseRegister, version >= 0 else { return nil }
        case let .argument(binding): guard (0..<8).contains(n), binding.kind == .gpr, binding.value == n else { return nil }
        default: return nil
        }
        var indices:[Int]=[]
        for value in vectors {
            guard case let .register(name, version)=value, let index=Int(name.dropFirst()),
                  name == "v\(index)", (0...31).contains(index), version > 0 else { return nil }
            indices.append(index)
        }
        guard indices.enumerated().allSatisfy({ $0.element == (indices[0]+$0.offset)%32 }) else { return nil }
        if let destination=baseDestination {
            guard case let .register(name, version)=destination, name == baseRegister, version > 0 else { return nil }
            switch oldBase {
            case let .register(_, previous): guard previous < Int.max, version == previous+1 else { return nil }
            case .argument: guard version == 1 else { return nil }
            default: return nil
            }
        }
        let c=vectors.count-1
        let exact=UInt32(0x0d40c000) | UInt32(c&1)<<21 | UInt32(c>>1)<<13
            | (activeBytes == 16 ? 0x40000000:0) | (baseDestination == nil ? 0:0x009f0000)
            | UInt32(n)<<5 | UInt32(indices[0])
        guard encodedWord == exact else { return nil }
        self.encodedWord=encodedWord;self.activeBytes=activeBytes;self.baseRegister=baseRegister
        self.oldBase=oldBase;self.vectors=vectors;self.baseDestination=baseDestination
        self.frameSequence=frameSequence;self.firstByteSequence=firstByteSequence
    }
}
public struct MacIRNEONMultiChannelReplicateStep: Hashable, Sendable {
    public let frame: MacIRNEONMultiChannelReplicate
    public let ordinal: Int
    public init?(frame: MacIRNEONMultiChannelReplicate, ordinal: Int) {
        guard (0..<frame.effectCount).contains(ordinal) else { return nil }
        self.frame=frame;self.ordinal=ordinal
    }
}
/// Successful full-list preflight only; frame/read/Q/commit units are distinct.
public struct MacIRNEONMultiChannelReplicateCertificate: Hashable, Sendable {
    public let rowCount: Int
    public let effectCount: Int
    public let frameCount: Int
    public let byteReadCount: Int
    public let qStoreCount: Int
    public let identities: [MacIRInstruction.Identity]
}

// MARK: - MacIRNEONThreeChannelMemory

/// Byte-only decoded LD3/ST3 gather/scatter across exactly three consecutive
/// physical128 vectors. Byte-major memory offset is 3*lane+channel. The three
/// commit effects are NOT contiguous memory accesses. Explicit frame and byte
/// sequences remain distinct from commit ordinals and optional delayed base.
/// Source/payload staging is success-path semantics, never hardware atomicity.
public struct MacIRNEONThreeChannelMemory: Hashable, Sendable {
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
    public let frameSequence: Int
    public let firstByteSequence: Int
    public var groupCount: Int { 3 }
    public var byteCount: Int { groupCount * activeBytes }
    public var effectCount: Int { groupCount + (baseDestination == nil ? 0 : 1) }
    public var fixedPostDelta: Int { baseDestination == nil ? 0 : byteCount }
    public var newBase: MacIRValue { .binaryExpression(op: "+", left: oldBase, right: .immediate(Int64(fixedPostDelta))) }
    public var orderedBytes: [ByteEffect] {
        (0..<byteCount).map { .init(sequence: firstByteSequence+$0, offset: $0, vector: $0%3, lane: $0/3) }
    }
    public func operation(_ ordinal: Int) -> MacIROperation {
        precondition((0..<effectCount).contains(ordinal))
        if ordinal == groupCount { return .assign(destination: baseDestination!, source: newBase) }
        return .intrinsic(destination: effect == .load ? vectors[ordinal] : nil,
            name: effect == .load ? "neon_gather3_bytes" : "neon_scatter3_bytes",
            arguments: effect == .load ? [oldBase] : [oldBase, vectors[ordinal]])
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
                 frameSequence: Int, firstByteSequence: Int) {
        guard [8,16].contains(activeBytes), vectors.count == 3,
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
        if let destination = baseDestination {
            guard case let .register(name, version) = destination, name == baseRegister, version > 0 else { return nil }
            switch oldBase {
            case let .register(_, previous): guard previous < Int.max, version == previous+1 else { return nil }
            case .argument: guard version == 1 else { return nil }
            default: return nil
            }
        }
        self.effect=effect; self.activeBytes=activeBytes; self.baseRegister=baseRegister
        self.oldBase=oldBase; self.vectors=vectors; self.baseDestination=baseDestination
        self.frameSequence=frameSequence; self.firstByteSequence=firstByteSequence
    }
}

public struct MacIRNEONThreeChannelMemoryStep: Hashable, Sendable {
    public let frame: MacIRNEONThreeChannelMemory
    public let ordinal: Int
    public init?(frame: MacIRNEONThreeChannelMemory, ordinal: Int) {
        guard (0..<frame.effectCount).contains(ordinal) else { return nil }
        self.frame=frame; self.ordinal=ordinal
    }
    public func identity(sourceAddress: UInt64) -> MacIRInstruction.Identity {
        .init(sourceAddress: sourceAddress, effectOrdinal: ordinal)
    }
}

// MARK: - MacIRNEONWiderChannelMemory

/// Decoded H/S and Q1 D MULTIPLE-structure interleaved memory. Each byte
/// transfer has its own width-1 typed payload effect; vector commits and the
/// delayed base update have no memory access. No fault/atomicity claims.
public struct MacIRNEONWiderChannelMemory: Hashable, Sendable {
    public struct ByteTransfer: Hashable, Sendable {
        public let sequence: Int
        public let offset: Int
        public let channel: Int
        public let lane: Int
        public let elementByte: Int
        public let vectorByte: Int
    }
    public let encodedWord: UInt32
    public let effect: MacIRNEONBufferMemory.Effect
    public let activeBytes: Int
    public let elementBytes: Int
    public let baseRegister: String
    public let oldBase: MacIRValue
    public let oldVectors: [MacIRValue]
    public let destinations: [MacIRValue]
    public let baseDestination: MacIRValue?
    public let frameSequence: Int
    public let firstByteSequence: Int
    public var channelCount: Int { oldVectors.count }
    public var laneCount: Int { activeBytes / elementBytes }
    public var byteCount: Int { channelCount * activeBytes }
    public var vectorCommitCount: Int { effect == .load ? channelCount : 0 }
    public var baseOrdinal: Int { byteCount + vectorCommitCount }
    public var effectCount: Int { baseOrdinal + (baseDestination == nil ? 0 : 1) }
    public var fixedPostDelta: Int { baseDestination == nil ? 0 : byteCount }
    public var newBase: MacIRValue { .binaryExpression(op:"+",left:oldBase,right:.immediate(Int64(fixedPostDelta))) }
    public var orderedTransfers: [ByteTransfer] {
        (0..<byteCount).map { offset in
            let element = offset / elementBytes
            let channel = element % channelCount, lane = element / channelCount, byte = offset % elementBytes
            return .init(sequence:firstByteSequence + offset,offset:offset,channel:channel,lane:lane,elementByte:byte,vectorByte:lane * elementBytes + byte)
        }
    }
    public func operation(_ ordinal: Int) -> MacIROperation {
        precondition((0..<effectCount).contains(ordinal))
        if ordinal == baseOrdinal { return .assign(destination:baseDestination!,source:newBase) }
        if ordinal < byteCount {
            let b=orderedTransfers[ordinal]
            return .intrinsic(destination:nil,name:effect == .load ? "read_interleaved_element_byte" : "write_interleaved_element_byte",
                arguments:[oldBase,oldVectors[b.channel],.immediate(Int64(b.offset)),.immediate(Int64(b.vectorByte))])
        }
        let channel=ordinal - byteCount
        return .intrinsic(destination:destinations[channel],name:"commit_interleaved_vector",arguments:[oldBase,oldVectors[channel],.immediate(Int64(channel))])
    }
    public func matches(_ operation: MacIROperation, ordinal: Int) -> Bool {
        guard (0..<effectCount).contains(ordinal) else { return false }
        if ordinal == baseOrdinal { return operation == self.operation(ordinal) }
        guard case let .intrinsic(d,_,a)=operation,case let .intrinsic(ed,_,ea)=self.operation(ordinal) else { return false }
        return d == ed && a == ea
    }
    public init?(encodedWord: UInt32,effect: MacIRNEONBufferMemory.Effect,activeBytes: Int,elementBytes: Int,
                 baseRegister: String,oldBase: MacIRValue,oldVectors: [MacIRValue],destinations: [MacIRValue],
                 baseDestination: MacIRValue?,frameSequence: Int,firstByteSequence: Int) {
        guard [8,16].contains(activeBytes),[2,4,8].contains(elementBytes),elementBytes != 8 || activeBytes == 16,
              (2...4).contains(oldVectors.count),destinations.count == (effect == .load ? oldVectors.count : 0),
              frameSequence >= 0,frameSequence < Int.max,firstByteSequence >= 0,
              firstByteSequence <= Int.max - oldVectors.count * activeBytes,
              let n=Int(baseRegister.dropFirst()),baseRegister == "x\(n)",(0...30).contains(n),
              !(baseRegister == "x30" && baseDestination != nil) else { return nil }
        switch oldBase {
        case let .register(name,version):guard name == baseRegister,version >= 0 else { return nil }
        case let .argument(binding):guard n < 8,binding.kind == .gpr,binding.value == n else { return nil }
        default:return nil
        }
        var indices:[Int]=[]
        for (channel,value) in oldVectors.enumerated() {
            guard case let .register(name,version)=value,let index=Int(name.dropFirst()),
                  name == "v\(index)",(0...31).contains(index),version >= 0 else { return nil }
            indices.append(index)
            if effect == .load { guard version < Int.max,destinations[channel] == .register(name:name,version:version + 1) else { return nil } }
        }
        guard indices.enumerated().allSatisfy({ $0.element == (indices[0] + $0.offset) % 32 }) else { return nil }
        if let destination=baseDestination {
            guard case let .register(name,version)=destination,name == baseRegister,version > 0 else { return nil }
            switch oldBase {
            case let .register(_,previous):guard previous < Int.max,version == previous + 1 else { return nil }
            case .argument:guard version == 1 else { return nil }
            default:return nil
            }
        }
        let opcode=oldVectors.count == 2 ? 8 : (oldVectors.count == 3 ? 4 : 0)
        let size=elementBytes == 2 ? 1 : (elementBytes == 4 ? 2 : 3)
        let exact=UInt32(0x0c000000) | (UInt32(opcode) << 12) | (UInt32(size) << 10)
            | (activeBytes == 16 ? 0x40000000 : 0) | (effect == .load ? 0x00400000 : 0)
            | (baseDestination == nil ? 0 : 0x009f0000) | (UInt32(n) << 5) | UInt32(indices[0])
        guard encodedWord == exact else { return nil }
        self.encodedWord=encodedWord;self.effect=effect;self.activeBytes=activeBytes;self.elementBytes=elementBytes
        self.baseRegister=baseRegister;self.oldBase=oldBase;self.oldVectors=oldVectors;self.destinations=destinations
        self.baseDestination=baseDestination;self.frameSequence=frameSequence;self.firstByteSequence=firstByteSequence
    }
}
public struct MacIRNEONWiderChannelMemoryStep: Hashable, Sendable {
    public let frame: MacIRNEONWiderChannelMemory
    public let ordinal: Int
    public init?(frame: MacIRNEONWiderChannelMemory,ordinal: Int) {
        guard (0..<frame.effectCount).contains(ordinal) else { return nil }
        self.frame=frame;self.ordinal=ordinal
    }
}
public struct MacIRNEONWiderChannelMemoryCertificate: Hashable, Sendable {
    public let rowCount: Int
    public let effectCount: Int
    public let frameCount: Int
    public let loadCount: Int
    public let storeCount: Int
    public let byteReadCount: Int
    public let byteWriteCount: Int
    public let vectorCommitCount: Int
    public let baseCommitCount: Int
    public let identities: [MacIRInstruction.Identity]
}

// MARK: - MacIRNEONWiderChannelPacking

/// An exhaustive immutable composition map; it adds no instruction metadata or
/// arithmetic engine. Byte ordinals belong to actual86, packing ordinals to40.
public struct MacIRNEONWiderChannelPacking: Hashable, Sendable {
    public enum Payload: Hashable, Sendable {
        case frame(MacIRNEONWiderChannelMemoryStep)
        case packing(MacIRNEONPacking, ordinal: Int)
        case nop
        case terminal
    }
    public struct Entry: Hashable, Sendable {
        public let rowOrdinal: Int
        public let effectSequence: Int
        public let identity: MacIRInstruction.Identity
        public let payload: Payload
        public init(rowOrdinal:Int,effectSequence:Int,identity:MacIRInstruction.Identity,payload:Payload) {
            self.rowOrdinal=rowOrdinal;self.effectSequence=effectSequence;self.identity=identity;self.payload=payload
        }
    }
    public let entries:[Entry]
    public let rowCount:Int
    public let frameCount:Int
    public let byteCount:Int
    public let packingCount:Int
    public let loadCount:Int
    public let storeCount:Int
    public let baseCommitCount:Int
    public let vectorCommitCount:Int
    public var effectCount:Int { entries.count }
    public init?(entries:[Entry]) {
        guard (3...4348).contains(entries.count) else { return nil }
        var p=0,row=0,frames=0,bytes=0,packs=0,loads=0,stores=0,bases=0,commits=0,previous:UInt64?
        while p < entries.count {
            let e=entries[p],pc=e.identity.sourceAddress
            guard e.rowOrdinal == row,e.effectSequence == p,pc.isMultiple(of:4),e.identity.effectOrdinal == 0 else { return nil }
            if let previous { guard previous <= UInt64.max-4,pc == previous+4 else { return nil } };previous=pc
            switch e.payload {
            case let .frame(step):
                let f=step.frame
                guard step.ordinal == 0,f.frameSequence == frames,f.firstByteSequence == bytes,f.effectCount <= entries.count-p else { return nil }
                for ordinal in 0..<f.effectCount {
                    let x=entries[p+ordinal]
                    guard x.rowOrdinal == row,x.effectSequence == p+ordinal,x.identity == .init(sourceAddress:pc,effectOrdinal:ordinal),
                          x.payload == .frame(.init(frame:f,ordinal:ordinal)!) else { return nil }
                }
                frames += 1;bytes += f.byteCount;bases += f.baseDestination == nil ? 0:1;commits += f.vectorCommitCount
                if f.effect == .load { loads += 1 } else { stores += 1 };p += f.effectCount
            case let .packing(d,ordinal):
                guard [16,32].contains(d.narrowBits),ordinal == packs,p != entries.count-1 else { return nil }
                packs += 1;p += 1
            case .nop:guard p != entries.count-1 else { return nil };p += 1
            case .terminal:guard p == entries.count-1 else { return nil };p += 1
            }
            row += 1
        }
        guard (3...64).contains(row),loads > 0,stores > 0,packs > 0,entries.last?.payload == .terminal else { return nil }
        self.entries=entries;rowCount=row;frameCount=frames;byteCount=bytes;packingCount=packs
        loadCount=loads;storeCount=stores;baseCommitCount=bases;vectorCommitCount=commits
    }
}

/// Per-lane ancestry is independent of physical register aliases and numerical
/// values. An absent lane is not silently promoted from a Q0 zero complement.
struct NEONWiderChannelPackingAncestry {
    struct Lane: Hashable {
        let frame:Int
        let channel:Int
        let lane:Int
        let transformed:Bool
        var packed:Lane { .init(frame:frame,channel:channel,lane:lane,transformed:true) }
    }
    struct Shape { let bits:Int;let lanes:[Lane] }
    var values:[MacIRValue:Shape]=[:]
    mutating func loaded(_ frame:MacIRNEONWiderChannelMemory) {
        for (channel,value) in frame.destinations.enumerated() {
            values[value] = .init(bits:frame.elementBytes*8,lanes:(0..<frame.laneCount).map {
                .init(frame:frame.frameSequence,channel:channel,lane:$0,transformed:false)
            })
        }
    }
    mutating func packed(_ d:MacIRNEONPacking,source:MacIRValue,old:MacIRValue?,destination:MacIRValue)->Bool {
        guard [16,32].contains(d.narrowBits),let input=values[source],input.bits == d.sourceLaneBits else { return false }
        let start=d.sourceHighHalf ? 64/d.sourceLaneBits:0,count=d.laneCount
        guard input.lanes.count >= start+count else { return false }
        var lanes=Array(input.lanes[start..<start+count]).map(\.packed)
        if d.readsDestination {
            guard let old,let previous=values[old],previous.bits == d.destinationLaneBits,previous.lanes.count >= count else { return false }
            lanes=Array(previous.lanes.prefix(count))+lanes
        }
        values[destination] = .init(bits:d.destinationLaneBits,lanes:lanes)
        return true
    }
    func stored(_ frame:MacIRNEONWiderChannelMemory)->Bool {
        frame.oldVectors.allSatisfy { value in
            guard let shape=values[value],shape.bits == frame.elementBytes*8,shape.lanes.count >= frame.laneCount else { return false }
            return shape.lanes.prefix(frame.laneCount).allSatisfy(\.transformed)
        }
    }
}

// MARK: - MacIRNEONWiderLanePacking

/// An exhaustive immutable composition map; it adds no instruction metadata or
/// arithmetic engine. Byte ordinals belong to actual90, packing ordinals to40.
public struct MacIRNEONWiderLanePacking: Hashable, Sendable {
    public enum Payload: Hashable, Sendable {
        case frame(MacIRNEONWiderMultiChannelLaneStep)
        case packing(MacIRNEONPacking, ordinal: Int)
        case q(MacIRNEONBufferMemory)
        case nop
        case terminal
    }
    public struct Entry: Hashable, Sendable {
        public let rowOrdinal: Int
        public let effectSequence: Int
        public let identity: MacIRInstruction.Identity
        public let payload: Payload
        public init(rowOrdinal:Int,effectSequence:Int,identity:MacIRInstruction.Identity,payload:Payload) {
            self.rowOrdinal=rowOrdinal;self.effectSequence=effectSequence;self.identity=identity;self.payload=payload
        }
    }
    public let entries:[Entry]
    public let rowCount:Int
    public let frameCount:Int
    public let byteCount:Int
    public let qMemoryCount:Int
    public let packingCount:Int
    public let loadCount:Int
    public let storeCount:Int
    public let baseCommitCount:Int
    public let vectorCommitCount:Int
    public var effectCount:Int { entries.count }
    public init?(entries:[Entry]) {
        guard (3...316).contains(entries.count) else { return nil }
        var p=0,row=0,frames=0,bytes=0,packs=0,qs=0,loads=0,stores=0,bases=0,commits=0,previous:UInt64?
        while p < entries.count {
            let e=entries[p],pc=e.identity.sourceAddress
            guard e.rowOrdinal == row,e.effectSequence == p,pc.isMultiple(of:4),e.identity.effectOrdinal == 0 else { return nil }
            if let previous { guard previous <= UInt64.max-4,pc == previous+4 else { return nil } };previous=pc
            switch e.payload {
            case let .frame(step):
                let f=step.frame
                guard step.ordinal == 0,f.frameSequence == frames,f.firstByteSequence == bytes,f.effectCount <= entries.count-p else { return nil }
                for ordinal in 0..<f.effectCount {
                    let x=entries[p+ordinal]
                    guard x.rowOrdinal == row,x.effectSequence == p+ordinal,x.identity == .init(sourceAddress:pc,effectOrdinal:ordinal),
                          x.payload == .frame(.init(frame:f,ordinal:ordinal)!) else { return nil }
                }
                frames += 1;bytes += f.byteCount;bases += f.baseDestination == nil ? 0:1;commits += f.destinations.count
                if f.effect == .load { loads += 1 } else { stores += 1 };p += f.effectCount
            case let .packing(d,ordinal):
                guard [16,32].contains(d.narrowBits),ordinal == packs,p != entries.count-1 else { return nil }
                packs += 1;p += 1
            case let .q(q): guard q.sequence == qs,p != entries.count-1 else { return nil };qs += 1;p += 1
            case .nop:guard p != entries.count-1 else { return nil };p += 1
            case .terminal:guard p == entries.count-1 else { return nil };p += 1
            }
            row += 1
        }
        guard (3...64).contains(row),loads > 0,stores > 0,packs > 0,entries.last?.payload == .terminal else { return nil }
        self.entries=entries;rowCount=row;frameCount=frames;byteCount=bytes;packingCount=packs
        qMemoryCount=qs;loadCount=loads;storeCount=stores;baseCommitCount=bases;vectorCommitCount=commits
    }
}

/// Exact bit ancestry, not whole-vector or element taint. nil means constant or
/// unrelated OLD bits. An origin identifies the actual inserted input bit.
struct NEONWiderLanePackingAncestry {
    struct Bit: Hashable { let frame:Int; let channel:Int; let inputBit:Int; let laneBits:Int; let transformed:Bool
        func packed(_ width:Int)->Bit { .init(frame:frame,channel:channel,inputBit:inputBit,laneBits:width,transformed:true) }
    }
    var values:[MacIRValue:[Bit?]]=[:]
    mutating func loaded(_ f:MacIRNEONWiderMultiChannelLane) {
        for (c,destination) in f.destinations.enumerated() {
            var bits=values[f.oldVectors[c]] ?? Array(repeating:nil,count:128)
            for b in 0..<f.elementBytes*8 {
                bits[f.laneIndex*f.elementBytes*8+b] = .init(frame:f.frameSequence,channel:c,inputBit:b,laneBits:f.elementBytes*8,transformed:false)
            }
            values[destination]=bits
        }
    }
    mutating func packed(_ d:MacIRNEONPacking,source:MacIRValue,old:MacIRValue?,destination:MacIRValue)->Bool {
        guard [16,32].contains(d.narrowBits) else { return false }
        let sourceBits=values[source] ?? Array(repeating:nil,count:128)
        var output:[Bit?]=Array(repeating:nil,count:128)
        if d.readsDestination,let old,let previous=values[old] { output.replaceSubrange(0..<64,with:previous[0..<64]) }
        var consumes=false
        for lane in 0..<d.laneCount {
            let input=(d.sourceHighHalf ? 64:0)+lane*d.sourceLaneBits
            let out=(d.destinationHighHalf ? 64:0)+lane*d.destinationLaneBits
            for b in 0..<d.destinationLaneBits {
                let sourceBit:Int?
                if d.kind == .narrow { sourceBit=b }
                else if b < d.shift { sourceBit=nil }
                else if b-d.shift < d.sourceLaneBits { sourceBit=b-d.shift }
                else { sourceBit=d.kind == .signedWiden ? d.sourceLaneBits-1:nil }
                if let sourceBit,let origin=sourceBits[input+sourceBit],origin.laneBits == d.sourceLaneBits {
                    output[out+b]=origin.packed(d.destinationLaneBits);consumes=true
                }
            }
        }
        guard consumes else { return false }
        values[destination]=output;return true
    }
    func stored(_ f:MacIRNEONWiderMultiChannelLane)->Bool {
        f.oldVectors.allSatisfy { value in
            guard let bits=values[value] else { return false }
            let start=f.laneIndex*f.elementBytes*8
            return bits[start..<start+f.elementBytes*8].contains { $0?.transformed == true && $0?.laneBits == f.elementBytes*8 }
        }
    }
    func observes(_ value:MacIRValue)->Bool { values[value]?.contains { $0 != nil } == true }
}

// MARK: - MacIRNEONWiderMultiChannelLane

/// H/S/D single-structure LD2/3/4 and ST2/3/4 selected-lane frame.
/// Q contributes to laneIndex, never to a vector width or high-half clear.
/// Immutable OLD full128 vectors and old base precede every payload definition.
public struct MacIRNEONWiderMultiChannelLane: Hashable, Sendable {
    public struct ByteTransfer: Hashable, Sendable {
        public let sequence: Int
        public let offset: Int
        public let channel: Int
    }
    public let encodedWord: UInt32
    public let effect: MacIRNEONBufferMemory.Effect
    public let laneIndex: Int
    public let elementBytes: Int
    public let baseRegister: String
    public let oldBase: MacIRValue
    public let oldVectors: [MacIRValue]
    public let destinations: [MacIRValue]
    public let baseDestination: MacIRValue?
    public let frameSequence: Int
    public let firstByteSequence: Int
    public var channelCount: Int { oldVectors.count }
    public var byteCount: Int { channelCount * elementBytes }
    public var capturedVectorBytes: Int { 16 * channelCount }
    public var effectCount: Int { channelCount + (baseDestination == nil ? 0 : 1) }
    public var fixedPostDelta: Int { baseDestination == nil ? 0 : byteCount }
    public var preservedByteIndices: [Int] { (0..<16).filter { !(laneIndex*elementBytes..<(laneIndex+1)*elementBytes).contains($0) } }
    public var newBase: MacIRValue { .binaryExpression(op:"+",left:oldBase,right:.immediate(Int64(fixedPostDelta))) }
    public var orderedTransfers: [ByteTransfer] {
        (0..<byteCount).map { .init(sequence:firstByteSequence+$0,offset:$0,channel:$0/elementBytes) }
    }
    public func operation(_ ordinal: Int) -> MacIROperation {
        precondition((0..<effectCount).contains(ordinal))
        if ordinal == channelCount { return .assign(destination:baseDestination!,source:newBase) }
        return .intrinsic(destination:effect == .load ? destinations[ordinal]:nil,
                          name:effect == .load ? "load_channel_wider_lane":"store_channel_wider_lane",
                          arguments:[oldBase,oldVectors[ordinal],.immediate(Int64(ordinal)),.immediate(Int64(laneIndex)),.immediate(Int64(elementBytes))])
    }
    public func matches(_ operation: MacIROperation, ordinal: Int) -> Bool {
        guard (0..<effectCount).contains(ordinal) else { return false }
        if ordinal == channelCount { return operation == self.operation(ordinal) }
        guard case let .intrinsic(d,_,a)=operation else { return false }
        return d == (effect == .load ? destinations[ordinal]:nil) &&
            a == [oldBase,oldVectors[ordinal],.immediate(Int64(ordinal)),.immediate(Int64(laneIndex)),.immediate(Int64(elementBytes))]
    }
    public init?(encodedWord: UInt32, effect: MacIRNEONBufferMemory.Effect, laneIndex: Int, elementBytes: Int,
                 baseRegister: String, oldBase: MacIRValue, oldVectors: [MacIRValue],
                 destinations: [MacIRValue], baseDestination: MacIRValue?,
                 frameSequence: Int, firstByteSequence: Int) {
        guard [2,4,8].contains(elementBytes), (0..<16/elementBytes).contains(laneIndex), (2...4).contains(oldVectors.count),
              frameSequence >= 0, frameSequence < Int.max,
              firstByteSequence >= 0, firstByteSequence <= Int.max-oldVectors.count*elementBytes,
              let n=Int(baseRegister.dropFirst()),baseRegister == "x\(n)",(0...30).contains(n),
              destinations.count == (effect == .load ? oldVectors.count:0) else { return nil }
        switch oldBase {
        case let .register(name,version):guard name == baseRegister,version >= 0 else { return nil }
        case let .argument(binding):guard (0..<8).contains(n),binding.kind == .gpr,binding.value == n else { return nil }
        default:return nil
        }
        var indices:[Int]=[]
        for (channel,value) in oldVectors.enumerated() {
            guard case let .register(name,version)=value,let index=Int(name.dropFirst()),
                  name == "v\(index)",(0...31).contains(index),version >= 0 else { return nil }
            indices.append(index)
            if effect == .load {
                guard version < Int.max,destinations[channel] == .register(name:name,version:version+1) else { return nil }
            }
        }
        guard indices.enumerated().allSatisfy({ $0.element == (indices[0]+$0.offset)%32 }) else { return nil }
        if let destination=baseDestination {
            guard case let .register(name,version)=destination,name == baseRegister,version > 0 else { return nil }
            switch oldBase {
            case let .register(_,previous):guard previous < Int.max,version == previous+1 else { return nil }
            case .argument:guard version == 1 else { return nil }
            default:return nil
            }
        }
        let c=oldVectors.count-1
        let laneBits: UInt32
        switch elementBytes {
        case 2: laneBits = 0x4000 | UInt32(laneIndex>>2)<<30 | UInt32((laneIndex>>1)&1)<<12 | UInt32(laneIndex&1)<<11
        case 4: laneBits = 0x8000 | UInt32(laneIndex>>1)<<30 | UInt32(laneIndex&1)<<12
        case 8: laneBits = 0x8400 | UInt32(laneIndex)<<30
        default: return nil
        }
        let exact=UInt32(0x0d000000) | UInt32(c&1)<<21 | UInt32(c>>1)<<13 | laneBits
            | (effect == .load ? 0x00400000:0) | (baseDestination == nil ? 0:0x009f0000)
            | UInt32(n)<<5 | UInt32(indices[0])
        guard encodedWord == exact else { return nil }
        self.encodedWord=encodedWord;self.effect=effect;self.laneIndex=laneIndex;self.elementBytes=elementBytes
        self.baseRegister=baseRegister;self.oldBase=oldBase;self.oldVectors=oldVectors
        self.destinations=destinations;self.baseDestination=baseDestination
        self.frameSequence=frameSequence;self.firstByteSequence=firstByteSequence
    }
}
public struct MacIRNEONWiderMultiChannelLaneStep: Hashable, Sendable {
    public let frame: MacIRNEONWiderMultiChannelLane
    public let ordinal: Int
    public init?(frame: MacIRNEONWiderMultiChannelLane, ordinal: Int) {
        guard (0..<frame.effectCount).contains(ordinal) else { return nil }
        self.frame=frame;self.ordinal=ordinal
    }
}
/// Produced only by the exhaustive full-list preflight before payloads.
public struct MacIRNEONWiderMultiChannelLaneCertificate: Hashable, Sendable {
    public let rowCount: Int
    public let effectCount: Int
    public let frameCount: Int
    public let loadCount: Int
    public let storeCount: Int
    public let byteReadCount: Int
    public let byteWriteCount: Int
    public let qMemoryCount: Int
    public let identities: [MacIRInstruction.Identity]
}

// MARK: - MacIRNEONWiderMultiChannelReplicate

/// H/S/D LD2R/LD3R/LD4R captures one little-endian element per channel,
/// independent of vector width. All source bytes and the old base are captured before
/// any full128 destination or delayed base commit. Nonfaulting model only.
public struct MacIRNEONWiderMultiChannelReplicate: Hashable, Sendable {
    public struct ByteRead: Hashable, Sendable {
        public let sequence: Int
        public let offset: Int
        public let channel: Int
    }
    public let encodedWord: UInt32
    public let elementBytes: Int
    public let activeBytes: Int
    public let baseRegister: String
    public let oldBase: MacIRValue
    public let vectors: [MacIRValue]
    public let baseDestination: MacIRValue?
    public let frameSequence: Int
    public let firstByteSequence: Int
    public var channelCount: Int { vectors.count }
    public var byteCount: Int { channelCount * elementBytes }
    public var vectorFootprint: Int { activeBytes * channelCount }
    public var effectCount: Int { channelCount + (baseDestination == nil ? 0 : 1) }
    public var fixedPostDelta: Int { baseDestination == nil ? 0 : byteCount }
    public var newBase: MacIRValue { .binaryExpression(op: "+", left: oldBase, right: .immediate(Int64(fixedPostDelta))) }
    public var orderedReads: [ByteRead] {
        (0..<byteCount).map { .init(sequence:firstByteSequence+$0, offset:$0, channel:$0/elementBytes) }
    }
    public func operation(_ ordinal: Int) -> MacIROperation {
        precondition((0..<effectCount).contains(ordinal))
        if ordinal == channelCount { return .assign(destination:baseDestination!, source:newBase) }
        return .intrinsic(destination:vectors[ordinal], name:"replicate_channel_element", arguments:[oldBase, .immediate(Int64(ordinal))])
    }
    public func matches(_ operation: MacIROperation, ordinal: Int) -> Bool {
        guard (0..<effectCount).contains(ordinal) else { return false }
        if ordinal == channelCount { return operation == self.operation(ordinal) }
        guard case let .intrinsic(d, _, a)=operation else { return false }
        return d == vectors[ordinal] && a == [oldBase, .immediate(Int64(ordinal))]
    }
    public init?(encodedWord: UInt32, elementBytes: Int, activeBytes: Int, baseRegister: String,
                 oldBase: MacIRValue, vectors: [MacIRValue], baseDestination: MacIRValue?,
                 frameSequence: Int, firstByteSequence: Int) {
        guard [2,4,8].contains(elementBytes), [8,16].contains(activeBytes), (2...4).contains(vectors.count),
              frameSequence >= 0, frameSequence < Int.max,
              firstByteSequence >= 0, firstByteSequence <= Int.max-vectors.count*elementBytes,
              let n=Int(baseRegister.dropFirst()), baseRegister == "x\(n)", (0...30).contains(n) else { return nil }
        switch oldBase {
        case let .register(name, version): guard name == baseRegister, version >= 0 else { return nil }
        case let .argument(binding): guard (0..<8).contains(n), binding.kind == .gpr, binding.value == n else { return nil }
        default: return nil
        }
        var indices:[Int]=[]
        for value in vectors {
            guard case let .register(name, version)=value, let index=Int(name.dropFirst()),
                  name == "v\(index)", (0...31).contains(index), version > 0 else { return nil }
            indices.append(index)
        }
        guard indices.enumerated().allSatisfy({ $0.element == (indices[0]+$0.offset)%32 }) else { return nil }
        if let destination=baseDestination {
            guard case let .register(name, version)=destination, name == baseRegister, version > 0 else { return nil }
            switch oldBase {
            case let .register(_, previous): guard previous < Int.max, version == previous+1 else { return nil }
            case .argument: guard version == 1 else { return nil }
            default: return nil
            }
        }
        let size = elementBytes == 2 ? 1 : elementBytes == 4 ? 2 : 3
        let c=vectors.count-1
        let exact=UInt32(0x0d40c000) | UInt32(size)<<10 | UInt32(c&1)<<21 | UInt32(c>>1)<<13
            | (activeBytes == 16 ? 0x40000000:0) | (baseDestination == nil ? 0:0x009f0000)
            | UInt32(n)<<5 | UInt32(indices[0])
        guard encodedWord == exact else { return nil }
        self.elementBytes=elementBytes;self.encodedWord=encodedWord;self.activeBytes=activeBytes;self.baseRegister=baseRegister
        self.oldBase=oldBase;self.vectors=vectors;self.baseDestination=baseDestination
        self.frameSequence=frameSequence;self.firstByteSequence=firstByteSequence
    }
}
public struct MacIRNEONWiderMultiChannelReplicateStep: Hashable, Sendable {
    public let frame: MacIRNEONWiderMultiChannelReplicate
    public let ordinal: Int
    public init?(frame: MacIRNEONWiderMultiChannelReplicate, ordinal: Int) {
        guard (0..<frame.effectCount).contains(ordinal) else { return nil }
        self.frame=frame;self.ordinal=ordinal
    }
}
/// Successful full-list preflight only; frame/read/Q/commit units are distinct.
public struct MacIRNEONWiderMultiChannelReplicateCertificate: Hashable, Sendable {
    public let rowCount: Int
    public let effectCount: Int
    public let frameCount: Int
    public let byteReadCount: Int
    public let qStoreCount: Int
    public let identities: [MacIRInstruction.Identity]
}
