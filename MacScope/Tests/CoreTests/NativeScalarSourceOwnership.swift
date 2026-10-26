import Foundation
import CryptoKit
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Independent original-row inventory for the no-call slice. Does not accept
/// product CFG/RegionTree/projection certificates or interpret candidate names.
/// SOURCE ONLY / NOT RUN. This inventory alone grants no output ownership credit.
enum NativeScalarSourceOwnership {
    typealias C = OrdinaryC
    typealias L = OrdinaryCSourceEdgeLedger
    struct Inventory {
        let source: L.Source
        let reachableBlocks: Set<Int>
        let reachableRows: Set<Int>
        let memoryEffects: [Int: [C.MemoryEffect]]
        let flagWriters: [Int: Int] // Conditional consumer -> literal reaching writer.
    }

    static func make(_ capture: NativeScalarFixture.Capture) throws -> Inventory {
        try makeInventory(rows: capture.input_rows, frozen: capture.cfg_blocks)
    }
    private static func makeInventory(rows: [InstructionRow], frozen: [NativeScalarFixture.FrozenBlock]?) throws -> Inventory {
        guard let start = rows.first?.address, !rows.isEmpty,
              rows.enumerated().allSatisfy({ $0.element.address == start + UInt64($0.offset * 4) && $0.element.byteWidth == 4 }) else {
            throw C.Failure.invalidContract("noncontiguous original no-call source")
        }
        let positions = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.address, $0.offset) })
        var leaders: Set<Int> = [0], targets: [Int: Int] = [:], returns: Set<Int> = []
        var memory: [Int: [C.MemoryEffect]] = [:]
        let scalar = Set(["ldr", "ldrb", "ldrh", "ldur", "ldurb", "ldurh", "ldp",
                          "str", "strb", "strh", "stur", "sturb", "sturh", "stp",
                          "mov", "add", "sub", "subs", "cmp", "sxtw", "lsl", "lsr", "nop"])
        for (index, row) in rows.enumerated() {
            if conditional(row.mnemonic) || row.mnemonic == "b" {
                let address = try branchTarget(row)
                guard let target = positions[address] else { throw C.Failure.invalidContract("source branch leaves complete frozen body") }
                targets[index] = target; leaders.insert(target)
                if index + 1 < rows.count { leaders.insert(index + 1) }
            } else if row.mnemonic == "ret" {
                guard try word(row) == 0xd65f_03c0,
                      row.operands.isEmpty || row.operands == "x30" else {
                    throw C.Failure.invalidContract("only original default/x30 RET is supported")
                }
                returns.insert(index)
                if index + 1 < rows.count { leaders.insert(index + 1) }
            } else {
                guard scalar.contains(row.mnemonic) else { throw C.Failure.invalidContract("unsupported no-call source instruction: \(row.mnemonic)") }
            }
            if let effects = try memoryEffects(row) { memory[index] = effects }
        }
        guard returns.count == 1 else { throw C.Failure.invalidContract("no-call source must retain one actual terminal") }
        let starts = leaders.sorted()
        var ranges: [Range<Int>] = [], blockAt: [Int: Int] = [:]
        for (index, first) in starts.enumerated() {
            let range = first..<(index + 1 < starts.count ? starts[index + 1] : rows.count)
            ranges.append(range)
            for row in range { blockAt[row] = index }
        }
        var blocks: [L.Block] = [], origins: Set<L.Origin> = [], outgoing: [Int: [L.Origin]] = [:]
        for (index, range) in ranges.enumerated() {
            let last = range.upperBound - 1, mnemonic = rows[last].mnemonic
            let roles: [(L.Role, Int)]
            if conditional(mnemonic), let target = targets[last] {
                guard last + 1 < rows.count, target != last + 1 else {
                    throw C.Failure.invalidContract("conditional source falls out or has indistinguishable duplicate targets")
                }
                roles = [(.taken, target), (.notTaken, last + 1)]
            } else if mnemonic == "b", let target = targets[last] { roles = [(.unconditional, target)] }
            else if mnemonic == "ret" { roles = [] }
            else {
                guard last + 1 < rows.count else { throw C.Failure.invalidContract("source falls out of body") }
                roles = [(.fallthrough, last + 1)]
            }
            var successors: [Int] = []
            for (_, destination) in roles {
                guard let target = blockAt[destination] else { throw C.Failure.invalidContract("missing source destination block") }
                if !successors.contains(target) { successors.append(target) }
            }
            for (role, destination) in roles {
                let target = blockAt[destination]!, ordinal = successors.firstIndex(of: target)!
                let origin = L.Origin(edge: .init(fromBlock: index, toBlock: target, successorOrdinal: ordinal), row: last, role: role)
                origins.insert(origin); outgoing[index, default: []].append(origin)
            }
            blocks.append(.init(index: index, rows: range, successors: successors))
        }
        let predecessors = predecessors(of: blocks)
        let loops = naturalLoops(blocks: blocks, predecessors: predecessors)
        if let frozen {
            guard blocks.count == frozen.count else { throw C.Failure.invalidContract("literal/frozen block count disagrees") }
            for (block, frozen) in zip(blocks, frozen) {
                guard block.index == frozen.index, block.rows.lowerBound == frozen.start_index,
                      block.rows.upperBound == frozen.end_index_exclusive,
                      NativeScalarContext.hex(rows[block.rows.lowerBound].address) == frozen.start_address,
                      NativeScalarContext.hex(rows[block.rows.upperBound - 1].address) == frozen.last_source_address,
                      block.successors == frozen.successors,
                      predecessors[block.index, default: []] == Set(frozen.predecessors),
                      loops.keys.contains(where: { $0.toBlock == block.index }) == frozen.is_loop_header else {
                    throw C.Failure.invalidContract("literal direct-branch graph contradicts full frozen CFG at block \(block.index)")
                }
            }
        }
        let reachable = reachableBlocks(blocks)
        let source = L.Source(rows: rows, blocks: blocks, blockAtRow: blockAt, origins: origins, outgoing: outgoing,
            dispatches: [:], branchTargets: targets, returns: returns,
            backedges: Set(loops.keys), naturalLoops: loops)
        return .init(source: source, reachableBlocks: reachable,
            reachableRows: Set(reachable.flatMap { Array(blocks[$0].rows) }), memoryEffects: memory,
            flagWriters: try reachingFlagWriters(rows: rows, blocks: blocks, predecessors: predecessors, reachable: reachable))
    }

    static func conditional(_ mnemonic: String) -> Bool {
        mnemonic.hasPrefix("b.") || mnemonic == "cbz" || mnemonic == "cbnz"
    }
    private static func word(_ row: InstructionRow) throws -> UInt32 {
        let words = row.bytes.split(separator: " "), bytes = words.compactMap { UInt8($0, radix: 16) }
        guard words.count == 4, bytes.count == 4 else { throw C.Failure.invalidContract("missing exact original ARM64 word") }
        return bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
    }
    private static func branchTarget(_ row: InstructionRow) throws -> UInt64 {
        let value = try word(row)
        let raw: UInt32, bits: Int
        if row.mnemonic == "b" {
            guard value & 0xfc00_0000 == 0x1400_0000 else { throw C.Failure.invalidContract("literal B opcode mismatch") }
            raw = value & 0x03ff_ffff; bits = 26
        } else if row.mnemonic.hasPrefix("b.") {
            guard value & 0xff00_0010 == 0x5400_0000 else { throw C.Failure.invalidContract("literal B.cond opcode mismatch") }
            let names = ["eq", "ne", "hs", "lo", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le", "al", "nv"]
            guard row.mnemonic == "b." + names[Int(value & 15)] else { throw C.Failure.invalidContract("literal branch condition mismatch") }
            raw = (value >> 5) & 0x7ffff; bits = 19
        } else {
            guard value & 0x7e00_0000 == 0x3400_0000,
                  row.mnemonic == ((value & 0x0100_0000) == 0 ? "cbz" : "cbnz") else {
                throw C.Failure.invalidContract("literal compare-branch opcode mismatch")
            }
            raw = (value >> 5) & 0x7ffff; bits = 19
        }
        let sign = Int64(1) << (bits - 1)
        let signed = Int64(raw) >= sign ? Int64(raw) - (Int64(1) << bits) : Int64(raw)
        let displacement = signed * 4
        let result = displacement < 0 ? row.address.subtractingReportingOverflow(displacement.magnitude)
                                      : row.address.addingReportingOverflow(UInt64(displacement))
        guard !result.overflow,
              let literal = row.operands.split(separator: ",").last?.trimmingCharacters(in: .whitespaces),
              literal.hasPrefix("0x"), UInt64(literal.dropFirst(2), radix: 16) == result.partialValue,
              let envelope = row.structuredOperands, envelope.architecture == .arm64,
              envelope.schemaVersion == 1, envelope.coverage == .complete else {
            throw C.Failure.invalidContract("literal branch target/envelope disagreement")
        }
        let references = envelope.operands.compactMap { operand -> InstructionOperands.PCReference? in
            if case let .pcRelative(reference) = operand { return reference }; return nil
        }
        guard references.count == 1, let reference = references.first,
              reference.baseAddress == row.address, !reference.pageRelative,
              reference.displacement == displacement, reference.target == result.partialValue else {
            throw C.Failure.invalidContract("native PC-relative sidecar disagrees with exact original bytes")
        }
        if row.mnemonic == "cbz" || row.mnemonic == "cbnz" {
            let registers = envelope.operands.compactMap { operand -> InstructionOperands.Register? in
                if case let .register(register) = operand { return register }; return nil
            }
            let width = value & 0x8000_0000 == 0 ? 32 : 64
            let index = Int(value & 31)
            let literal = row.operands.split(separator: ",").first?.trimmingCharacters(in: .whitespaces)
            guard registers.count == 1, let register = registers.first,
                  register.bank == .general, register.role == .ordinary,
                  register.index == index, register.width == width, index < 31,
                  literal == "\(width == 32 ? "w" : "x")\(index)" else {
                throw C.Failure.invalidContract("CBZ/CBNZ encoded Rt/sf, literal and native register disagree")
            }
        }
        return result.partialValue
    }
    private static func memoryEffects(_ row: InstructionRow) throws -> [C.MemoryEffect]? {
        let loads = Set(["ldr", "ldrb", "ldrh", "ldur", "ldurb", "ldurh", "ldp"])
        let stores = Set(["str", "strb", "strh", "stur", "sturb", "sturh", "stp"])
        guard loads.contains(row.mnemonic) || stores.contains(row.mnemonic) else { return nil }
        let loading = loads.contains(row.mnemonic), pair = row.mnemonic == "ldp" || row.mnemonic == "stp"
        guard let envelope = row.structuredOperands, envelope.architecture == .arm64,
              envelope.schemaVersion == 1, envelope.coverage == .complete,
              let first = envelope.operands.first, case let .register(register) = first,
              register.bank == .general, [32, 64].contains(register.width) else {
            throw C.Failure.invalidContract("missing original unsigned scalar memory authority")
        }
        let dataRegisters = envelope.operands.compactMap { operand -> InstructionOperands.Register? in
            if case let .register(value) = operand { return value }; return nil
        }
        let memories = envelope.operands.compactMap { operand -> InstructionOperands.Memory? in
            if case let .memory(value) = operand { return value }; return nil
        }
        guard envelope.operands.count == (pair ? 3 : 2), dataRegisters.count == (pair ? 2 : 1), memories.count == 1,
              dataRegisters.allSatisfy({ value in
                value.bank == .general && value.role == .ordinary && value.width == register.width &&
                    value.arrangement == nil && value.lane == nil && (0...30).contains(value.index)
              }), !pair || Set(dataRegisters.map(\.index)).count == 2 else {
            throw C.Failure.invalidContract("original memory data operand count/width/role contradiction")
        }
        let width: Int
        if ["ldrb", "ldurb", "strb", "sturb"].contains(row.mnemonic) { width = 8 }
        else if ["ldrh", "ldurh", "strh", "sturh"].contains(row.mnemonic) { width = 16 }
        else { width = register.width }
        guard envelope.semantics?.memoryAccessWidth == width,
              envelope.semantics?.memoryAccess == (loading ? .read : .write) else {
            throw C.Failure.invalidContract("source memory width/direction contradiction")
        }
        return Array(repeating: .init(loading: loading, bytes: width / 8), count: pair ? 2 : 1)
    }
    private static func predecessors(of blocks: [L.Block]) -> [Int: Set<Int>] {
        var result: [Int: Set<Int>] = [:]
        for block in blocks { for successor in block.successors { result[successor, default: []].insert(block.index) } }
        return result
    }
    private static func reachableBlocks(_ blocks: [L.Block]) -> Set<Int> {
        var seen: Set<Int> = [], work = [0]
        while let block = work.popLast() {
            if seen.insert(block).inserted { work += blocks[block].successors }
        }
        return seen
    }
    private static func naturalLoops(blocks: [L.Block], predecessors: [Int: Set<Int>]) -> [C.SourceEdge: Set<Int>] {
        let reachable = reachableBlocks(blocks)
        var dominators = Dictionary(uniqueKeysWithValues: reachable.map { ($0, $0 == 0 ? Set([0]) : reachable) })
        var changed = true
        while changed {
            changed = false
            for block in reachable.sorted() where block != 0 {
                var common = reachable
                for predecessor in predecessors[block, default: []].intersection(reachable) {
                    common.formIntersection(dominators[predecessor, default: []])
                }
                common.insert(block)
                if common != dominators[block] { dominators[block] = common; changed = true }
            }
        }
        var loops: [C.SourceEdge: Set<Int>] = [:]
        for block in blocks where reachable.contains(block.index) {
            for (ordinal, target) in block.successors.enumerated() where dominators[block.index, default: []].contains(target) {
                var members: Set<Int> = [target, block.index], work = block.index == target ? [] : [block.index]
                while let current = work.popLast() {
                    for predecessor in predecessors[current, default: []].intersection(reachable) where members.insert(predecessor).inserted { work.append(predecessor) }
                }
                loops[.init(fromBlock: block.index, toBlock: target, successorOrdinal: ordinal)] = members
            }
        }
        return loops
    }
    private static func reachingFlagWriters(rows: [InstructionRow], blocks: [L.Block],
        predecessors: [Int: Set<Int>], reachable: Set<Int>) throws -> [Int: Int] {
        var exits: [Int: Set<Int>] = [:], changed = true
        while changed {
            changed = false
            for block in blocks where reachable.contains(block.index) {
                var writers = predecessors[block.index, default: []].reduce(into: Set<Int>()) { $0.formUnion(exits[$1, default: []]) }
                if block.index == 0 { writers.insert(-1) }
                for row in block.rows where ["cmp", "subs"].contains(rows[row].mnemonic) { writers = [row] }
                if exits[block.index] != writers { exits[block.index] = writers; changed = true }
            }
        }
        var result: [Int: Int] = [:]
        for block in blocks where reachable.contains(block.index) {
            var writers = predecessors[block.index, default: []].reduce(into: Set<Int>()) { $0.formUnion(exits[$1, default: []]) }
            if block.index == 0 { writers.insert(-1) }
            for row in block.rows {
                if rows[row].mnemonic.hasPrefix("b.") {
                    guard writers.count == 1, let writer = writers.first, writer >= 0 else {
                        throw C.Failure.invalidContract("ambiguous/uninitialized original flag writer at row \(row)")
                    }
                    result[row] = writer
                }
                if ["cmp", "subs"].contains(rows[row].mnemonic) { writers = [row] }
            }
        }
        return result
    }
}

// NEW reconstruction from retained source evidence, not recovered lost bytes.
// Historical operands are source-envelope evidence only, never fresh context
// authority. This API is sealed to seven literal streams and known relocations.
extension NativeScalarSourceOwnership {
    enum HistoricalSeed: String {
        case planar, planar8, rgbToPlanes8, bgrToPlanes8, bgrToPlanes16, planesToBGR8, planesToBGR16
    }
    struct HistoricalSource {
        fileprivate let seed: HistoricalSeed
        fileprivate let rows: [InstructionRow]
        fileprivate init(seed: HistoricalSeed, rows: [InstructionRow]) {
            self.seed = seed; self.rows = rows
        }
    }
    private struct HistoricalPin {
        let originalBase: UInt64
        let allowedBases: Set<UInt64>
        let rows: Int
        let blocks: Int
        let bytesSHA256: String
        let textSHA256: String
        let witnessesSHA256: String?
    }
    private static func historicalHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func historicalPin(_ seed: HistoricalSeed) -> HistoricalPin {
        switch seed {
        case .planar: return .init(originalBase: 0x3704, allowedBases: [0x3704, 0x913804, 0x3a704, 0x4b704], rows: 84, blocks: 24,
            bytesSHA256: "01b2ede48249160ae0bb2397ec861599a8c26b32b9c1c742423a539cb126e161",
            textSHA256: "c697c0201529a465c5ce8ce7c7118c5c2766e28c80bc65ca51b2022c00066d16",
            witnessesSHA256: nil)
        case .planar8: return .init(originalBase: 0x27b30, allowedBases: [0x27b30], rows: 84, blocks: 24,
            bytesSHA256: "04c65b68258e95928c9e0479a1f16fe39b92f8016a4e01a2495aa478cefd2a40",
            textSHA256: "e5c23ce62343957942063dc0ec7ce1f75f62b96e30172838f87f84b02952b55f",
            witnessesSHA256: "5ccfb8df14953651e9c4a7bb710d3d3b4e56cacc228ac4e34da69b2651aeec1d")
        case .rgbToPlanes8: return .init(originalBase: 0x3854, allowedBases: [0x3854], rows: 26, blocks: 7,
            bytesSHA256: "5ec350ffd70d93a29f4b3f136953fa621abb1cdd4b0a7a9e3a50715a84672a66",
            textSHA256: "63eb89678b2b431a339ad49f19380634eb33f7bf6c7eb6acff1e3466c8f4558a",
            witnessesSHA256: "9458fdd63fe6aa9d875e0e13a1f05e89b9af2c025a697d414a4855ece78b89cb")
        case .bgrToPlanes8: return .init(originalBase: 0x3924, allowedBases: [0x3924], rows: 27, blocks: 7,
            bytesSHA256: "c6b835adeb38378e1eb848c48b19b2b09c3bf08f33830dc8938f426773d3b6aa",
            textSHA256: "51bc82b68e08aa661c1b2f45d55aa0f6ed4037dfe63070162ae7c209a3e46161",
            witnessesSHA256: "4115d66de4be6ee1046e69f1b347f59db1a21cd202bc9c64e1cb99429f26f77a")
        case .bgrToPlanes16: return .init(originalBase: 0x4e84, allowedBases: [0x4e84], rows: 27, blocks: 7,
            bytesSHA256: "0759ca1642f541645306f4f41da6ba64a2fb6433f98c136ae02fcc4be7554b66",
            textSHA256: "42db588907144f4970dd13ef7a1625af6cac39a510cd31f039e890d786aeb2cc",
            witnessesSHA256: "c51098b4fe3e3a6acb0b9454067c5ece5b195844e9fe8c8528205a43d96d39cb")
        case .planesToBGR8: return .init(originalBase: 0x27d58, allowedBases: [0x27d58], rows: 27, blocks: 7,
            bytesSHA256: "405aaf78f6a203cc8df663862efd3622a9e6b50767a72b24ff1d37b42c165f33",
            textSHA256: "1fd5f27b101337fcc13898e8075c803512f15b6c45d1585ed655c42953791500",
            witnessesSHA256: "e27869baaf5da660c116ece222b4569ee82cf9957856d9994e2c120fffd843be")
        case .planesToBGR16: return .init(originalBase: 0x29a70, allowedBases: [0x29a70], rows: 27, blocks: 7,
            bytesSHA256: "d8c4c7bc376bca371d43cd0695b6c2157e6f61d80742dd1039c301a6d30bead5",
            textSHA256: "01f242808cf63b8cfac234fdd67a31c1f601105c0314f02bc7e5a62eeeb1ba27",
            witnessesSHA256: "3fa2e917150e62718f692f962c2c3734cd636af6656f28ed38fbaf6549d117b6")
        }
    }
    private struct HistoricalPlanarResource: Decodable {
        struct Record: Decodable { let start: String; let input_rows: [InstructionRow] }
        let fixture_schema_version: Int
        let source_main: String
        let records: [Record]
    }
    private static func historicalPlanarRows() throws -> [InstructionRow] {
        let url = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NativeScalar/first-three-current-main.json")
        let data = try Data(contentsOf: url)
        guard historicalHash(data) == "85992590a366a5404aca71f0c91d08404945571994d00de4f9bb7c454bec2d4b" else {
            throw C.Failure.invalidContract("historical planar complete-envelope resource changed or is unavailable")
        }
        let resource = try JSONDecoder().decode(HistoricalPlanarResource.self, from: data)
        let selected = resource.records.filter { $0.start == "0x3704" }
        guard resource.fixture_schema_version == 1,
              resource.source_main == "9a9b5613904a8cb632ca41fa65a39dbafb01571a",
              selected.count == 1, selected[0].input_rows.count == 84 else {
            throw C.Failure.invalidContract("historical planar resource is not the retained original source envelope")
        }
        return selected[0].input_rows
    }
    /// Compare complete envelopes, changing ONLY PCReference.baseAddress by a
    /// checked original-row relocation. Never replace the producer's sidecar.
    private static func historicalRebasedEnvelope(_ row: InstructionRow, at address: UInt64,
        originalBase: UInt64, count: Int) throws -> InstructionOperands {
        guard let old = row.structuredOperands else { throw C.Failure.invalidContract("missing retained complete planar envelope") }
        let operands = try old.operands.map { operand -> InstructionOperands.Operand in
            guard case let .pcRelative(pc) = operand else { return operand }
            guard pc.baseAddress == row.address, !pc.pageRelative, let target = pc.target,
                  target >= originalBase, target < originalBase + UInt64(count * 4),
                  (target - originalBase).isMultiple(of: 4) else {
                throw C.Failure.invalidContract("historical planar PC reference leaves the exact stream")
            }
            let next = InstructionOperands.PCReference(baseAddress: address, displacement: pc.displacement,
                pageRelative: pc.pageRelative, format: pc.format)
            guard next.target != nil else { throw C.Failure.invalidContract("historical planar relocation overflows") }
            return .pcRelative(next)
        }
        return .init(architecture: old.architecture, schemaVersion: old.schemaVersion,
            coverage: old.coverage, opcodeClass: old.opcodeClass, operands: operands,
            presentation: old.presentation, semantics: old.semantics, legacyText: old.legacyText)
    }
    static func bindHistoricalScalar(_ seed: HistoricalSeed, rows: [InstructionRow],
        literalBytes: [UInt8], literalText: [String], operandWitnesses: [UInt64]?) throws -> HistoricalSource {
        let pin = historicalPin(seed)
        guard let base = rows.first?.address, pin.allowedBases.contains(base), rows.count == pin.rows,
              literalBytes.count == pin.rows * 4, literalText.count == pin.rows,
              historicalHash(Data(literalBytes)) == pin.bytesSHA256,
              historicalHash(Data(literalText.joined(separator: "\n").utf8)) == pin.textSHA256,
              !base.addingReportingOverflow(UInt64(pin.rows * 4)).overflow else {
            throw C.Failure.invalidContract("not one of the seven exact historical scalar inputs")
        }
        let planar: [InstructionRow]?
        if seed == .planar {
            guard operandWitnesses == nil else { throw C.Failure.invalidContract("planar uses retained full envelopes, not substituted witnesses") }
            planar = try historicalPlanarRows()
        } else {
            guard let witnesses = operandWitnesses, witnesses.count == pin.rows,
                  historicalHash(Data(witnesses.map { String($0) }.joined(separator: ",").utf8)) == pin.witnessesSHA256 else {
                throw C.Failure.invalidContract("historical full-operand witness array changed")
            }
            planar = nil
        }
        for (index, row) in rows.enumerated() {
            let expectedBytes = literalBytes[(index * 4)..<(index * 4 + 4)].map { String(format: "%02x", $0) }.joined(separator: " ")
            let pieces = literalText[index].split(separator: " ", maxSplits: 1).map(String.init)
            guard let mnemonic = pieces.first else { throw C.Failure.invalidContract("empty historical text row") }
            var operands = pieces.count == 2 ? pieces[1] : ""
            if conditional(mnemonic) || mnemonic == "b" {
                guard let last = operands.split(separator: ",").last?.trimmingCharacters(in: .whitespaces),
                      last.hasPrefix("0x"), let originalTarget = UInt64(last.dropFirst(2), radix: 16),
                      originalTarget >= pin.originalBase, originalTarget < pin.originalBase + UInt64(pin.rows * 4) else {
                    throw C.Failure.invalidContract("literal historical branch leaves pinned body")
                }
                let rebased = base.addingReportingOverflow(originalTarget - pin.originalBase)
                guard !rebased.overflow, operands.hasSuffix(last) else { throw C.Failure.invalidContract("historical branch relocation overflows") }
                operands = String(operands.dropLast(last.count)) + String(format: "0x%016llx", rebased.partialValue)
            }
            guard row.address == base + UInt64(index * 4), row.bytes == expectedBytes,
                  row.mnemonic == mnemonic, row.operands == operands, !row.hasBreakpoint,
                  row.comment == "decoded_cfg_effect_\(index)_end", row.structuredOperands != nil else {
                throw C.Failure.invalidContract("historical producer row differs from exact original/relocation input")
            }
            if let planar {
                let frozen = planar[index]
                guard frozen.address == pin.originalBase + UInt64(index * 4), frozen.bytes == expectedBytes,
                      (frozen.operands.isEmpty ? frozen.mnemonic : frozen.mnemonic + " " + frozen.operands) == literalText[index],
                      row.structuredOperands == (try historicalRebasedEnvelope(frozen, at: row.address,
                        originalBase: pin.originalBase, count: pin.rows)) else {
                    throw C.Failure.invalidContract("complete planar envelope changed beyond checked PC rebasing")
                }
            } else {
                let shape = String(reflecting: row.structuredOperands)
                    .replacingOccurrences(of: "MacScopeAnalysisCore.", with: "")
                    .replacingOccurrences(of: "MacScope.", with: "")
                    .replacingOccurrences(of: "RenderAll.", with: "")
                let witness = shape.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
                guard witness == operandWitnesses![index] else { throw C.Failure.invalidContract("complete original operand envelope changed") }
            }
        }
        return .init(seed: seed, rows: rows)
    }
    static func makeHistoricalScalar(_ source: HistoricalSource) throws -> Inventory {
        let inventory = try makeInventory(rows: source.rows, frozen: nil)
        guard inventory.source.blocks.count == historicalPin(source.seed).blocks,
              inventory.source.returns == [source.rows.count - 1] else {
            throw C.Failure.invalidContract("historical literal topology differs from pinned source")
        }
        return inventory
    }

    /// A distinct architectural ByteMap64 interpretation. This is NOT C
    /// definedness, an alternate access-width contract, or a refusal fallback.
    /// A wrapper is constructed for every prepared historical stream, but only
    /// the two retained halfword wrap-scenario identities can enable that model.
    struct HistoricalByteMapProgram {
        let program: C.Program
        fileprivate let seed: HistoricalSeed
        fileprivate init(program: C.Program, seed: HistoricalSeed) {
            self.program = program; self.seed = seed
        }
        func requireRetainedScenario(_ scenario: C.Scenario) throws {
            guard seed == .bgrToPlanes16 || seed == .planesToBGR16,
                  scenario.responses.isEmpty else {
                throw C.Failure.invalidContract("ByteMap64 is limited to the two retained halfword sources")
            }
            let outgoing = seed == .planesToBGR16
            let expected: [UInt64] = outgoing
                ? [0x1_0000_1000, 0x3_0000_3000, 0xffff_ffff, 0x2_0000_2000, 2]
                : [0x1_0000_1000, 0x2_0000_2000, 0x3_0000_3000, 0xffff_ffff, 2]
            guard Set(scenario.inputs.keys) == Set((0..<5).map { "arg\($0)" }),
                  expected.enumerated().allSatisfy({ scenario.inputs["arg\($0.offset)"]?.bits == $0.element }) else {
                throw C.Failure.invalidContract("ByteMap64 input roles differ from retained width3/rows2/index-max scenarios")
            }
            func read(_ address: UInt64, _ bytes: Int) throws -> UInt64 {
                guard address <= UInt64.max - UInt64(bytes - 1) else { throw C.Failure.invalidContract("wrapped scenario permission metadata") }
                var result: UInt64 = 0
                for offset in 0..<bytes {
                    guard let byte = scenario.memory[address + UInt64(offset)] else { throw C.Failure.invalidContract("missing retained scenario permission bytes") }
                    result |= UInt64(byte) << (offset * 8)
                }
                return result
            }
            guard try read(0x1_0000_1000 + (outgoing ? 0x88 : 0x30), 4) == 3,
                  try read(0x1_0000_1038, 4) == 3 else { throw C.Failure.invalidContract("ByteMap64 scenario width/components changed") }
            let interleaved = try read(0x2_0000_2000, 8)
            let firstTable = try read(0x3_0000_3000, 8)
            guard firstTable == 0x4_0000_0000 else { throw C.Failure.invalidContract("ByteMap64 retained first table changed") }
            let firstPlane = try read(firstTable + (UInt64(UInt32.max) << 3), 8)
            let dataWrap = outgoing ? (interleaved == 0x6_0000_0000 && firstPlane == UInt64.max - 2)
                                    : (interleaved == UInt64.max - 8 && firstPlane == 0x5_0000_0000)
            let destinationWrap = outgoing ? (interleaved == UInt64.max - 2 && firstPlane == 0x5_0000_0000)
                                           : (interleaved == 0x6_0000_0000 && firstPlane == UInt64.max - 2)
            guard dataWrap || destinationWrap else { throw C.Failure.invalidContract("not a retained halfword data/destination-wrap input") }
        }
    }
    static func historicalByteMapProgram(source: HistoricalSource, candidate: C.Program) throws -> HistoricalByteMapProgram {
        let inventory = try makeHistoricalScalar(source), c = candidate.contract
        let expectedRows = Dictionary(uniqueKeysWithValues: source.rows.enumerated().map { ($0.element.address, $0.offset) })
        let expectedLabels = Set(inventory.source.blocks.map { "L_" + String(source.rows[$0.rows.lowerBound].address, radix: 16) })
        let types: [C.CType] = [.i64, .i64,
            [.planar8, .planesToBGR8, .planesToBGR16].contains(source.seed) ? .i32 : .i64,
            [.planar8, .planesToBGR8, .planesToBGR16].contains(source.seed) ? .i64 : .i32, .i32]
        guard c.rowsByAddress == expectedRows, c.allowedLabels == expectedLabels,
              c.memoryEffects.count == inventory.memoryEffects.count,
              c.memoryEffects.allSatisfy({ row, actual in
                  guard let expected = inventory.memoryEffects[row], actual.count == expected.count else { return false }
                  return zip(actual, expected).allSatisfy { $0.0.loading == $0.1.loading && $0.0.bytes == $0.1.bytes }
              }), c.fields.isEmpty, c.calls.isEmpty, c.exterior.isEmpty, c.helpers.isEmpty,
              c.deadResults.isEmpty, c.permissions.isEmpty,
              c.terminalRow == source.rows.count - 1, c.terminalName == nil, c.returnType == nil,
              c.noCallUnavailableTerminal,
              try C.lex(c.terminalPayload).map(\.text) == ["return", "unresolved_return_contract", ";"],
              c.inputs.count == 5,
              c.inputs.enumerated().allSatisfy({ index, value in
                  value.name == "arg\(index)" && value.type == types[index] && value.entrySlot == index
              }) else {
            throw C.Failure.invalidContract("historical byte-map program lost complete original effect/input/terminal/empty-field identity")
        }
        // Exact protected terminal payload, full raw envelope, and source row
        // are checked against the same immutable parsed Program. No text-keyed
        // cache can reuse a token after any contract field changes.
        try c.validateEnvelope(lines: candidate.lines, tokens: candidate.tokens)
        // The sealed token owns this proof; a caller's earlier route check is
        // not authority for a different or merely shape-matching Program.
        let anchors = try NativeScalarSourceAnchors.make(candidate: candidate, inventory: inventory)
        let topology = try OrdinaryCSourceEdgeLedger.analyzeNativeScalar(anchors)
        try topology.requireCompleteTopology()
        return .init(program: candidate, seed: source.seed)
    }
}
