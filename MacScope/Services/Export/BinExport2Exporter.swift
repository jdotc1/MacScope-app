import Foundation

/// A minimal encoder for the protobuf binary wire format of the proto2 BinExport2 schema
/// (`ThirdParty/BinExport/binexport2.proto`). Only varint and length-delimited fields are
/// supported. This writer accumulates bytes in memory; callers can extract the encoded data via
/// the `data` property. Wire types supported:
/// * Varint (wire type 0) for integers (UInt64)
/// * Length-delimited (wire type 2) for strings, bytes, and nested messages
///
/// proto2 has explicit field presence. `writeUInt64Field` omits a zero value, which a reader sees
/// as "absent"; that is only correct where absence and the schema default mean the same thing.
/// Fields BinDiff requires to be PRESENT (instruction and vertex `address`,
/// `entry_basic_block_index`, `parent_index`) use `writePresentVarintField`.
fileprivate struct ProtoWriter {
    private var buffer: Data = Data()

    /// Returns the encoded bytes accumulated so far.
    var data: Data { buffer }

    /// Encodes and writes a varint field with the given field number and value. A
    /// zero value is omitted per proto3 default rules.
    mutating func writeUInt64Field(_ value: UInt64, fieldNumber: Int) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: 0)
        writeVarint(value)
    }

    /// Writes ONE element of a REPEATED varint field. Unlike `writeUInt64Field`, this never
    /// omits a zero: every element of a repeated scalar occupies a list position, so dropping a
    /// 0 element would SHORTEN the list. Zero-omission applies only to SINGULAR scalar fields.
    mutating func writeRepeatedVarintElement(_ value: UInt64, fieldNumber: Int) {
        writeTag(fieldNumber: fieldNumber, wireType: 0)
        writeVarint(value)
    }

    /// Writes a SINGULAR varint field with explicit proto2 presence: a zero value is written,
    /// never omitted. Same wire bytes as one repeated element.
    mutating func writePresentVarintField(_ value: UInt64, fieldNumber: Int) {
        writeRepeatedVarintElement(value, fieldNumber: fieldNumber)
    }

    /// Encodes and writes a string field with the given field number. An empty
    /// string is omitted.
    mutating func writeStringField(_ value: String, fieldNumber: Int) {
        guard !value.isEmpty else { return }
        writeTag(fieldNumber: fieldNumber, wireType: 2)
        let utf8Data = Data(value.utf8)
        writeLengthDelimited(utf8Data)
    }

    /// Encodes and writes a bytes field with the given field number. An empty
    /// byte array is omitted.
    mutating func writeBytesField(_ value: Data, fieldNumber: Int) {
        guard !value.isEmpty else { return }
        writeTag(fieldNumber: fieldNumber, wireType: 2)
        writeLengthDelimited(value)
    }

    /// Encodes and writes a nested message field. The provided closure receives a
    /// new `ProtoWriter` to encode the nested message into. If the nested message
    /// ends up empty, nothing is written.
    mutating func writeMessageField(fieldNumber: Int, _ body: (inout ProtoWriter) -> Void) {
        var nested = ProtoWriter()
        body(&nested)
        let nestedData = nested.data
        guard !nestedData.isEmpty else { return }
        writeTag(fieldNumber: fieldNumber, wireType: 2)
        writeLengthDelimited(nestedData)
    }

    // MARK: - Internal encoding helpers

    /// Writes a field tag for the given field number and wire type.
    private mutating func writeTag(fieldNumber: Int, wireType: Int) {
        let key = UInt64(fieldNumber << 3 | wireType)
        writeVarint(key)
    }

    /// Writes a varint-encoded integer (UInt64) to the buffer.
    private mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            buffer.append(UInt8(v & 0x7F | 0x80))
            v >>= 7
        }
        buffer.append(UInt8(v))
    }

    /// Writes a length-delimited field: first writes the length as a varint, then the bytes.
    private mutating func writeLengthDelimited(_ data: Data) {
        writeVarint(UInt64(data.count))
        buffer.append(data)
    }
}

/// Exports a `WorkspaceSnapshot` into Google's BinExport2 protobuf format (the wire contract
/// BinDiff consumes). The export uses a minimal, dependency-free encoder and produces
/// DETERMINISTIC binary output: the same analysis content yields identical bytes. The field
/// numbers match the upstream `binexport2.proto` (google/binexport) so the output is readable
/// by BinDiff and other BinExport2-compatible tooling.
///
/// Populated subset: meta information, the mnemonic table, the instruction table (address,
/// raw bytes, mnemonic index), basic blocks (instruction index ranges), per-function flow
/// graphs (block index lists + intra-function edges), and the call graph (vertices for
/// functions plus extent-validated executable linkage stubs — `S_SYMBOL_STUBS` imports as
/// IMPORTED, Objective-C selector stubs as THUNK — and one edge per distinct uniquely owned
/// caller/callee pair in ascending order). GOT and other data-pointer slots are never vertices.
/// A function vertex is THUNK only when proven: it is one `__objc_stubs` entry (whatever its
/// symbol origin), or every decoded instruction of its exact extent only forwards control
/// (`ForwardingThunkProof`) to one resolved vertex, which becomes its single call edge.
/// The operand/expression tables now include full
/// expression trees with parent links for memory and shifted operands.
struct BinExport2Exporter {
    /// Serializes the given snapshot into BinExport2 format. The returned data
    /// contains a complete, valid BinExport2 protobuf message. The export is pure
    /// and does not perform any file I/O.
    init() {}

    /// Exports and checks the bytes against the vendored upstream schema and BinDiff's
    /// requirements (`BinExport2Conformance`). The app writes only bytes that pass.
    func exportForBinDiff(_ snapshot: WorkspaceSnapshot, in slot: ImageSlot? = nil) throws -> Data {
        let data = export(snapshot, in: slot)
        try BinExport2Conformance.requireConformance(data)
        return data
    }

    func export(_ snapshot: WorkspaceSnapshot, in slot: ImageSlot? = nil) -> Data {
        // BinExport has no image qualifier on an address. Export exactly one
        // image bucket, never join equal addresses from different loaded images.
        let slot = slot ?? snapshot.primarySlot
        let analysis = snapshot.analysis(in: slot) ?? ImageAnalysis()
        let binary = snapshot.binary(in: slot)
        var writer = ProtoWriter()

        // Meta information (field 1): name, a STABLE id, architecture, timestamp.
        writer.writeMessageField(fieldNumber: 1) { metaWriter in
            if let image = binary {
                metaWriter.writeStringField(image.name, fieldNumber: 1)
                // executable_id must be deterministic for the byte-identity contract: use the
                // binary's embedded Mach-O LC_UUID (content-derived), NOT image.id, which is a
                // fresh random UUID minted per analysis (so the same binary would export
                // different bytes). Absent => omitted (empty string).
                metaWriter.writeStringField(image.metadata.uuid ?? "", fieldNumber: 2)
                metaWriter.writeStringField(image.architecture, fieldNumber: 3)
            }
            // Timestamp (field 4): omit dynamic time to preserve determinism (stays 0).
            metaWriter.writeUInt64Field(0, fieldNumber: 4)
        }

        // Mnemonic table (field 4): de-duplicated mnemonic strings, sorted for stability.
        let sortedMnemonics = analysis.instructions.map { $0.mnemonic }.reduce(into: Set<String>()) { $0.insert($1) }.sorted()
        var mnemonicIndex: [String: Int32] = [:]
        for (idx, name) in sortedMnemonics.enumerated() {
            mnemonicIndex[name] = Int32(idx)
            writer.writeMessageField(fieldNumber: 4) { mnemonicWriter in
                mnemonicWriter.writeStringField(name, fieldNumber: 1)
            }
        }

        // Instruction table (field 5). Deduplicate by content; reference by index elsewhere.
        struct EncodedInstruction: Hashable {
            let address: UInt64
            let rawBytes: Data
            let mnemonic: String
            let operands: String
            let structuredOperands: InstructionOperands?
        }
        var instructionSet: Set<EncodedInstruction> = []
        var instructionList: [EncodedInstruction] = []
        for row in analysis.instructions {
            let encoded = EncodedInstruction(
                address: row.address,
                rawBytes: Self.decodeHexBytes(row.bytes),
                mnemonic: row.mnemonic,
                operands: row.operands,
                structuredOperands: row.structuredOperands
            )
            if instructionSet.insert(encoded).inserted {
                instructionList.append(encoded)
            }
        }
        // Total order (not just by address): two distinct instructions sharing an address must
        // still order deterministically, since Swift's sort is not guaranteed stable.
        instructionList.sort {
            if $0.address != $1.address { return $0.address < $1.address }
            if $0.mnemonic != $1.mnemonic { return $0.mnemonic < $1.mnemonic }
            if $0.operands != $1.operands { return $0.operands < $1.operands }
            return $0.rawBytes.lexicographicallyPrecedes($1.rawBytes)
        }
        // Build expression and operand tables for full operand support.
        // Each operand in an instruction is represented by a list of ExpressionKeys.
        // Expressions are deduplicated globally and sorted deterministically with parent
        // relationships preserved, then operands reference their constituent expressions by
        // index, and instructions reference their operands by index.
        // Define the BinExport2 Expression type enumeration for clarity.
        enum BinExport2ExpressionType: Int {
            case symbol = 1
            case immediateInt = 2
            case immediateFloat = 3
            case op = 4
            case register = 5
            case sizePrefix = 6
            case dereference = 7
        }
        // A key used to uniquely identify an expression. An ExpressionKey encodes
        // the expression's kind (type), its optional symbol and immediate, and the
        // expression key of its parent. Two ExpressionKeys are equal only if all
        // these components are equal, so expressions in different contexts (e.g.
        // register `x1` as a root vs `x1` as a child of a dereference) remain distinct.
        final class ExpressionKey: Hashable {
            let type: Int
            let symbol: String
            let immediate: UInt64
            let parent: ExpressionKey?

            init(type: Int, symbol: String, immediate: UInt64, parent: ExpressionKey?) {
                self.type = type
                self.symbol = symbol
                self.immediate = immediate
                self.parent = parent
            }

            // Custom hash / equality to include parent key in the identity.
            func hash(into hasher: inout Hasher) {
                hasher.combine(type)
                hasher.combine(symbol)
                hasher.combine(immediate)
                if let p = parent {
                    hasher.combine(p)
                } else {
                    hasher.combine(0 as Int)
                }
            }
            static func == (lhs: ExpressionKey, rhs: ExpressionKey) -> Bool {
                return lhs.type == rhs.type && lhs.symbol == rhs.symbol && lhs.immediate == rhs.immediate && lhs.parent == rhs.parent
            }
        }

        // Helper to compute a lexicographically comparable path for an expression key.
        func path(for key: ExpressionKey) -> [(Int, String, UInt64)] {
            var elements: [(Int, String, UInt64)] = []
            var current: ExpressionKey? = key
            while let k = current {
                elements.insert((k.type, k.symbol, k.immediate), at: 0)
                current = k.parent
            }
            return elements
        }

        // Parse each instruction's operand string into a list of operand expression keys.
        var instrOperandExprKeyLists: [[[ExpressionKey]]] = []
        instrOperandExprKeyLists.reserveCapacity(instructionList.count)
        // Determine architecture from the first binary; default to empty string.
        let arch = binary?.architecture ?? ""
        // Converts one operand's ExprNode list into ExpressionKeys, keeping parent links.
        func expressionKeys(_ nodes: [ExprNode]) -> [ExpressionKey] {
            var localKeys: [ExpressionKey] = []
            localKeys.reserveCapacity(nodes.count)
            for node in nodes {
                let parentKey: ExpressionKey? = {
                    if let p = node.parentIndex, p >= 0, p < localKeys.count { return localKeys[p] }
                    return nil
                }()
                localKeys.append(ExpressionKey(type: node.kind.rawValue, symbol: node.symbol,
                                               immediate: node.immediate, parent: parentKey))
            }
            return localKeys
        }
        for instr in instructionList {
            // DP04 A3: a complete typed sidecar that renders to this row's text
            // supplies the trees; otherwise parse the text as before.
            if let trees = BinExport2OperandParser.structuredOperandTrees(
                instr.structuredOperands, mnemonic: instr.mnemonic, operands: instr.operands) {
                instrOperandExprKeyLists.append(trees.map(expressionKeys).filter { !$0.isEmpty })
                continue
            }
            let opsString = instr.operands
            // Split on top-level commas using the parser's helper.
            let rawTokens = BinExport2OperandParser.splitTopLevelOperands(opsString)
            // Group shift/extend modifiers: tokens like "lsl #2" or "uxtw" that belong
            // with the preceding register.
            var grouped: [String] = []
            var i = 0
            while i < rawTokens.count {
                let tok = rawTokens[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if tok.isEmpty { i += 1; continue }
                if i + 1 < rawTokens.count {
                    let next = rawTokens[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    // Lowercase next token for modifier detection.
                    let lowerNext = next.lowercased()
                    // Known shift/extend prefixes. See parser for full list.
                    let shiftPrefixes: Set<String> = ["lsl", "lsr", "asr", "ror", "rrx", "uxtw", "uxtx", "uxtb", "uxth", "sxtw", "sxtx", "sxtb", "sxth"]
                    // Extract first word of next token.
                    let firstWord: String
                    if let spaceIdx = lowerNext.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                        firstWord = String(lowerNext[..<spaceIdx])
                    } else if let commaIdx = lowerNext.firstIndex(of: ",") {
                        firstWord = String(lowerNext[..<commaIdx])
                    } else {
                        firstWord = lowerNext
                    }
                    if shiftPrefixes.contains(firstWord) {
                        grouped.append(tok + ", " + next)
                        i += 2
                        continue
                    }
                }
                grouped.append(tok)
                i += 1
            }
            var operandExprs: [[ExpressionKey]] = []
            operandExprs.reserveCapacity(grouped.count)
            for operand in grouped {
                let trimmed = operand.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                // Parse operand into ExprNode list.
                let nodes = BinExport2OperandParser.parseOperandTree(trimmed, arch: arch)
                // Convert nodes into ExpressionKeys, capturing parent relationships.
                var localKeys: [ExpressionKey] = []
                localKeys.reserveCapacity(nodes.count)
                for node in nodes {
                    let parentIndex = node.parentIndex
                    let parentKey: ExpressionKey? = {
                        if let p = parentIndex, p >= 0, p < localKeys.count {
                            return localKeys[p]
                        } else {
                            return nil
                        }
                    }()
                    let key = ExpressionKey(
                        type: node.kind.rawValue,
                        symbol: node.symbol,
                        immediate: node.immediate,
                        parent: parentKey
                    )
                    localKeys.append(key)
                }
                if !localKeys.isEmpty {
                    operandExprs.append(localKeys)
                }
            }
            instrOperandExprKeyLists.append(operandExprs)
        }

        // Collect all unique expressions across all operands.
        var exprKeySet = Set<ExpressionKey>()
        for operandExprs in instrOperandExprKeyLists {
            for exprList in operandExprs {
                for key in exprList {
                    exprKeySet.insert(key)
                }
            }
        }
        // Sort expressions deterministically. Parent path determines order: parents come
        // before children because a parent's path is a strict prefix of the child's
        // path. Lexicographically sorting the paths enforces this ordering.
        let sortedExprKeys = exprKeySet.sorted { a, b in
            let pa = path(for: a)
            let pb = path(for: b)
            let minCount = min(pa.count, pb.count)
            for i in 0..<minCount {
                let (ta, sa, ia) = pa[i]
                let (tb, sb, ib) = pb[i]
                if ta != tb { return ta < tb }
                if sa != sb { return sa < sb }
                if ia != ib { return ia < ib }
            }
            // If one path is a prefix of the other, shorter comes first.
            return pa.count < pb.count
        }
        // Map expressions to indices.
        var exprIndexMap: [ExpressionKey: Int32] = [:]
        for (idx, key) in sortedExprKeys.enumerated() {
            exprIndexMap[key] = Int32(idx)
        }
        // Emit expression table (field 2).
        for key in sortedExprKeys {
            writer.writeMessageField(fieldNumber: 2) { exprWriter in
                exprWriter.writeUInt64Field(UInt64(key.type), fieldNumber: 1)
                if !key.symbol.isEmpty {
                    exprWriter.writeStringField(key.symbol, fieldNumber: 2)
                }
                // Only IMMEDIATE_INT uses field 3.
                if key.type == BinExport2ExpressionType.immediateInt.rawValue {
                    exprWriter.writeUInt64Field(key.immediate, fieldNumber: 3)
                }
                // parent_index (field 4) must be emitted even when zero; use repeated
                // writer to avoid zero-suppression by writeUInt64Field.
                if let parentKey = key.parent, let parentIndex = exprIndexMap[parentKey] {
                    exprWriter.writePresentVarintField(UInt64(Int64(parentIndex)), fieldNumber: 4)
                }
            }
        }
        // Map each instruction's operand expression keys to expression indices.
        var instrOperandExprIndexLists: [[[Int32]]] = []
        instrOperandExprIndexLists.reserveCapacity(instrOperandExprKeyLists.count)
        for operandExprs in instrOperandExprKeyLists {
            var operandExprIndices: [[Int32]] = []
            operandExprIndices.reserveCapacity(operandExprs.count)
            for exprList in operandExprs {
                var indices: [Int32] = []
                indices.reserveCapacity(exprList.count)
                for key in exprList {
                    if let idx = exprIndexMap[key] {
                        indices.append(idx)
                    }
                }
                operandExprIndices.append(indices)
            }
            instrOperandExprIndexLists.append(operandExprIndices)
        }
        // Collect unique operands (each operand is a list of expression indices).
        var operandSet = Set<[Int32]>()
        for operandExprIndices in instrOperandExprIndexLists {
            for exprIndices in operandExprIndices {
                operandSet.insert(exprIndices)
            }
        }
        // Sort operands lexicographically for deterministic ordering.
        let sortedOperands = operandSet.sorted { a, b in
            if a.count != b.count { return a.count < b.count }
            for (x, y) in zip(a, b) {
                if x != y { return x < y }
            }
            return false
        }
        // Map operand lists to indices.
        var operandIndexMap: [[Int32]: Int32] = [:]
        for (idx, exprList) in sortedOperands.enumerated() {
            operandIndexMap[exprList] = Int32(idx)
        }
        // Emit operand table (field 3).
        for exprList in sortedOperands {
            writer.writeMessageField(fieldNumber: 3) { operandWriter in
                for exprIndex in exprList {
                    operandWriter.writeRepeatedVarintElement(UInt64(Int64(exprIndex)), fieldNumber: 1)
                }
            }
        }
        // Build each instruction's operand index list referencing the operand table.
        var instrOperandIndexLists: [[Int32]] = []
        instrOperandIndexLists.reserveCapacity(instrOperandExprIndexLists.count)
        for operandExprIndices in instrOperandExprIndexLists {
            var opIdxList: [Int32] = []
            opIdxList.reserveCapacity(operandExprIndices.count)
            for exprIndices in operandExprIndices {
                if let opIdx = operandIndexMap[exprIndices] {
                    opIdxList.append(opIdx)
                }
            }
            instrOperandIndexLists.append(opIdxList)
        }
        // Emit instruction table (field 5), including operand_index references.
        for (i, instr) in instructionList.enumerated() {
            writer.writeMessageField(fieldNumber: 5) { instrWriter in
                // address: explicit for every instruction, so each function-entry
                // instruction carries one (BinDiff requirement), even at address 0.
                instrWriter.writePresentVarintField(instr.address, fieldNumber: 1)
                if let mIndex = mnemonicIndex[instr.mnemonic] {
                    instrWriter.writeUInt64Field(UInt64(Int64(mIndex)), fieldNumber: 3) // mnemonic_index
                }
                // operand_index (field 4) references operand table indices
                let opIndices = instrOperandIndexLists[i]
                for opIdx in opIndices {
                    instrWriter.writeRepeatedVarintElement(UInt64(Int64(opIdx)), fieldNumber: 4)
                }
                instrWriter.writeBytesField(instr.rawBytes, fieldNumber: 5)        // raw_bytes
            }
        }

        // Basic block table (field 6). Compute each block's instruction index range FIRST and
        // drop blocks with no instructions, THEN assign indices over the survivors — so the
        // assigned index always equals the emitted position. (writeMessageField skips an empty
        // nested message, so emitting indices before filtering would shift every later block's
        // position and corrupt all downstream basic_block_index / edge references.)
        // Total order (start, then end, then id) so two blocks sharing a start address can't reorder
        // across runs and break byte-identity — mirroring the instruction comparator above.
        let sortedBlocks = analysis.basicBlocks.sorted {
            if $0.startAddress != $1.startAddress { return $0.startAddress < $1.startAddress }
            if $0.endAddress != $1.endAddress { return $0.endAddress < $1.endAddress }
            return $0.id.uuidString < $1.id.uuidString
        }
        var blockRanges: [(id: UUID, begin: Int32, end: Int32)] = []
        func instructionLowerBound(_ address: UInt64) -> Int {
            var low = 0
            var high = instructionList.count
            while low < high {
                let middle = low + (high - low) / 2
                if instructionList[middle].address < address { low = middle + 1 }
                else { high = middle }
            }
            return low
        }
        for block in sortedBlocks {
            guard block.endAddress > block.startAddress else { continue }
            let begin = instructionLowerBound(block.startAddress)
            let end = instructionLowerBound(block.endAddress)
            if begin < end {
                blockRanges.append((block.id, Int32(begin), Int32(end)))
            }
        }
        var basicBlockIndex: [UUID: Int32] = [:]
        for (idx, range) in blockRanges.enumerated() {
            basicBlockIndex[range.id] = Int32(idx)
            writer.writeMessageField(fieldNumber: 6) { blockWriter in
                blockWriter.writeMessageField(fieldNumber: 1) { rangeWriter in   // instruction_index (IndexRange)
                    rangeWriter.writeUInt64Field(UInt64(Int64(range.begin)), fieldNumber: 1) // begin_index
                    rangeWriter.writeUInt64Field(UInt64(Int64(range.end)), fieldNumber: 2)   // end_index
                }
            }
        }

        // Flow graphs (field 7): one per function, sorted by start address.
        // Total order so two functions sharing a start address can't reorder across runs.
        let sortedFunctions = analysis.functions.sorted {
            if $0.startAddress != $1.startAddress { return $0.startAddress < $1.startAddress }
            if $0.endAddress != $1.endAddress { return $0.endAddress < $1.endAddress }
            return $0.id.uuidString < $1.id.uuidString
        }
        let blocksByFunction = Dictionary(grouping: sortedBlocks, by: \.functionID)
        let blockOwners = AddressOwnerIndex(ranges: sortedBlocks.enumerated().map {
            ($0.element.startAddress, $0.element.endAddress, $0.offset)
        })
        var edgesByFunction: [UUID: [(ControlFlowEdge, Int32, Int32)]] = [:]
        for edge in analysis.controlFlowEdges where edge.kind != "call" {
            guard let source = blockOwners.owner(at: edge.from),
                  let target = blockOwners.owner(at: edge.to),
                  sortedBlocks[source].functionID == sortedBlocks[target].functionID,
                  let sourceIndex = basicBlockIndex[sortedBlocks[source].id],
                  let targetIndex = basicBlockIndex[sortedBlocks[target].id] else { continue }
            edgesByFunction[sortedBlocks[source].functionID, default: []].append((edge, sourceIndex, targetIndex))
        }
        let edgeKindsBySource = Dictionary(grouping: analysis.controlFlowEdges, by: \.from)
            .mapValues { Set($0.map(\.kind)) }
        let conditionalSources = Set(edgeKindsBySource.compactMap { source, kinds in
            kinds.contains("branch") && kinds.contains("fallthrough") ? source : nil
        })
        for function in sortedFunctions {
            let blocksInFunction = blocksByFunction[function.id] ?? []
            // BinDiff requires every flow graph to name its entry block. A function whose
            // start is not the start of an exported (non-empty) block has no flow graph; it
            // stays a call-graph vertex.
            guard let entryIndex = blocksInFunction.lazy
                .filter({ $0.startAddress == function.startAddress })
                .compactMap({ basicBlockIndex[$0.id] }).first else { continue }
            writer.writeMessageField(fieldNumber: 7) { fgWriter in
                let sortedBlockIndices = blocksInFunction.compactMap { basicBlockIndex[$0.id] }.sorted()
                // basic_block_index (field 1, repeated int32): each element MUST be written,
                // including index 0 — use the repeated-element writer, not the zero-omitting one.
                for index in sortedBlockIndices {
                    fgWriter.writeRepeatedVarintElement(UInt64(Int64(index)), fieldNumber: 1)
                }
                // entry_basic_block_index (field 3): the block whose start == function start.
                // Explicit presence: BinDiff rejects a flow graph without it, and the
                // zero-omitting writer used to drop entry block 0.
                fgWriter.writePresentVarintField(UInt64(Int64(entryIndex)), fieldNumber: 3)
                // edge (field 2): intra-function control-flow edges, both endpoints in-function.
                for (edge, sIndex, tIndex) in edgesByFunction[function.id] ?? [] {
                    if function.startAddress <= edge.from, edge.from < function.endAddress,
                       function.startAddress <= edge.to, edge.to < function.endAddress {
                        fgWriter.writeMessageField(fieldNumber: 2) { edgeWriter in
                            edgeWriter.writeUInt64Field(UInt64(Int64(sIndex)), fieldNumber: 1) // source_basic_block_index
                            edgeWriter.writeUInt64Field(UInt64(Int64(tIndex)), fieldNumber: 2) // target_basic_block_index
                            // The schema defaults to UNCONDITIONAL (=3); every type is
                            // written explicitly.
                            let type = BinExport2EdgeType(edge: edge, conditionalSources: conditionalSources)
                            edgeWriter.writeRepeatedVarintElement(UInt64(type.rawValue), fieldNumber: 3)
                        }
                    }
                }
            }
        }

        let functionOwners = AddressOwnerIndex(ranges: sortedFunctions.enumerated().map {
            ($0.element.startAddress, $0.element.endAddress, $0.offset)
        })
        // Imports have no address themselves. Only loader-resolved linkage rows or
        // derived stub symbols supply an in-image address identity, and only an
        // EXECUTABLE stub/thunk is a callable vertex. A GOT / lazy / non-lazy pointer
        // slot is data holding an address; its name never becomes forwarding code.
        typealias SlotClass = StubCallSymbolicator.LinkageSlotClass
        struct ImportIdentity: Hashable {
            let name: String
            let library: String?
            let ordinal: Int?
        }
        let extent = LinkageExtentValidator(sections: analysis.sections, imageByteCount: analysis.imageBytes.count)
        // Every address any linkage evidence names. A call into one of these
        // addresses resolves only to an admitted linkage vertex, never to a
        // function-range fallback.
        var linkageAddresses: Set<UInt64> = []
        var linkageNames: [UInt64: Set<String>] = [:]
        var indirectIdentities: [UInt64: Set<ImportIdentity>] = [:]
        var slotClasses: [UInt64: Set<SlotClass>] = [:]
        // Contradictory classification or failed section/file extent: abstain.
        var rejectedLinkage: Set<UInt64> = []
        for entry in analysis.indirectSymbols {
            guard StubCallSymbolicator.linkageSlotClass(sectionName: entry.sourceSection) != nil else { continue }
            linkageAddresses.insert(entry.address)
            guard !entry.isLocal, !entry.isAbsolute,
                  let name = entry.symbolName, !name.isEmpty else { continue }
            linkageNames[entry.address, default: []].insert(name)
            indirectIdentities[entry.address, default: []].insert(
                ImportIdentity(name: name, library: entry.libraryName, ordinal: entry.libraryOrdinal)
            )
            guard let slotClass = StubCallSymbolicator.linkageSlotClass(for: entry) else {
                rejectedLinkage.insert(entry.address)
                continue
            }
            slotClasses[entry.address, default: []].insert(slotClass)
            if slotClass == .executableImportStub,
               extent.executableSection(containing: entry.address, size: UInt64(entry.entrySize),
                                        declaredSection: entry.sourceSection) == nil {
                rejectedLinkage.insert(entry.address)
            }
        }
        for symbol in analysis.symbols {
            guard let address = symbol.address, !symbol.name.isEmpty else { continue }
            // A derived stub label is linkage evidence wherever it lies. A real
            // (unstripped) symbol is linkage evidence only through membership in
            // `__objc_stubs`: what the slot IS follows from its section, not from
            // whether the name was derived or carried by the binary. Only symbols
            // that DEFINE an in-image address qualify (absolute/undefined/import
            // values are not code addresses).
            if symbol.kind != "stub" {
                guard symbol.kind == MachOSymbolKind.local.rawValue || symbol.kind == MachOSymbolKind.export.rawValue,
                      let sectionName = extent.uniqueSectionName(containing: address),
                      StubCallSymbolicator.linkageSlotClass(sectionName: sectionName) == .objcSelectorStub else { continue }
            }
            linkageAddresses.insert(address)
            linkageNames[address, default: []].insert(symbol.name)
            // A derived stub label carries no section; its containing section
            // declares what the slot is.
            guard let sectionName = extent.uniqueSectionName(containing: address),
                  let slotClass = StubCallSymbolicator.linkageSlotClass(sectionName: sectionName) else {
                rejectedLinkage.insert(address)
                continue
            }
            slotClasses[address, default: []].insert(slotClass)
            // A selector stub has no indirect row and no declared entry size; it
            // must at least hold one whole instruction in executable file bytes.
            if slotClass == .objcSelectorStub,
               extent.executableSection(containing: address, size: 4, declaredSection: sectionName) == nil {
                rejectedLinkage.insert(address)
            }
        }
        // Admit only an unambiguous, extent-validated callable linkage endpoint:
        // an S_SYMBOL_STUBS import stub is IMPORTED with its unique import identity;
        // an Objective-C selector stub forwards to objc_msgSend inside this image,
        // so it is a THUNK, never an imported library function. Data pointers and
        // anything contradictory abstain.
        var linkageVertices: [UInt64: (name: String, type: BinExport2VertexType)] = [:]
        for (address, names) in linkageNames {
            guard !rejectedLinkage.contains(address),
                  names.count == 1, let name = names.first,
                  let classes = slotClasses[address], classes.count == 1,
                  let slotClass = classes.first else { continue }
            let identities = indirectIdentities[address]?.count ?? 0
            switch slotClass {
            case .executableImportStub:
                guard identities == 1, !name.hasPrefix("_objc_msgSend$") else { continue }
                linkageVertices[address] = (name: name, type: .imported)
            case .objcSelectorStub:
                guard identities == 0 else { continue }
                linkageVertices[address] = (name: name, type: .thunk)
            case .dataPointer:
                continue
            }
        }
        let functionStarts = Dictionary(grouping: sortedFunctions.indices, by: { sortedFunctions[$0].startAddress })
        // BinExport indexes the complete vertex array, which must ascend by
        // address even when imported entries precede or interleave functions.
        // Keep function ownership in its original index space and map both
        // call endpoints to the final emitted positions.
        struct CallGraphVertex {
            let address: UInt64
            let functionIndex: Int?
        }
        var vertices = sortedFunctions.enumerated().map {
            CallGraphVertex(address: $0.element.startAddress, functionIndex: $0.offset)
        }
        vertices += linkageVertices.keys.filter { functionStarts[$0] == nil }.map {
            CallGraphVertex(address: $0, functionIndex: nil)
        }
        vertices.sort {
            if $0.address != $1.address { return $0.address < $1.address }
            // Equal-address functions retain the existing deterministic order.
            return ($0.functionIndex ?? Int.max) < ($1.functionIndex ?? Int.max)
        }
        var functionVertexIndex: [Int32] = Array(repeating: 0, count: sortedFunctions.count)
        var linkageVertexIndex: [UInt64: Int32] = [:]
        for (index, vertex) in vertices.enumerated() {
            if let functionIndex = vertex.functionIndex {
                functionVertexIndex[functionIndex] = Int32(index)
            }
            if linkageVertices[vertex.address] != nil,
               vertex.functionIndex == nil || functionStarts[vertex.address]?.count == 1 {
                linkageVertexIndex[vertex.address] = Int32(index)
            }
        }

        // Call relations: one edge per distinct (source, target) vertex pair, in
        // ascending (source, target) order, independent of xref order or count.
        // Unknown targets and overlapping function ranges abstain; nearest-preceding
        // is navigation convenience, not evidence of a callee.
        struct CallEdge: Hashable {
            let source: Int32
            let target: Int32
        }
        var callEdges: Set<CallEdge> = []
        for xref in analysis.xrefs where xref.kind == XRefKind.call {
            guard let source = functionOwners.owner(at: xref.from) else { continue }
            let target: Int32?
            if linkageAddresses.contains(xref.to) {
                target = linkageVertexIndex[xref.to]
            } else {
                target = functionOwners.owner(at: xref.to).map { functionVertexIndex[$0] }
            }
            guard let tIndex = target else { continue }
            callEdges.insert(CallEdge(source: functionVertexIndex[source], target: tIndex))
        }

        // THUNK functions. A function vertex is a THUNK only when proven:
        // (1) its whole extent (at most one 32-byte entry) lies in one validated
        //     executable `__objc_stubs` section: a selector stub, whatever its
        //     symbol origin; or
        // (2) every decoded instruction of its exact extent is in the
        //     forwarding allow-list (`ForwardingThunkProof`) and the single
        //     forwarding target resolves to exactly one vertex outside it. That
        //     forwarding relation is its one call edge. Anything else is NORMAL.
        var thunkFunctions: Set<Int> = []
        let callTargetsBySource = Dictionary(grouping: callEdges, by: \.source).mapValues { Set($0.map(\.target)) }
        // Admitted IMPORTED vertices by their unique import identity, for
        // trampolines that load a GOT slot naming the same import.
        var importVerticesByIdentity: [ImportIdentity: [Int32]] = [:]
        for (address, vertex) in linkageVertices where vertex.type == .imported {
            guard let identities = indirectIdentities[address], identities.count == 1,
                  let identity = identities.first, let index = linkageVertexIndex[address] else { continue }
            importVerticesByIdentity[identity, default: []].append(index)
        }
        func forwardingVertex(direct target: UInt64) -> Int32? {
            if linkageAddresses.contains(target) { return linkageVertexIndex[target] }
            guard let starts = functionStarts[target], starts.count == 1 else { return nil }
            return functionVertexIndex[starts[0]]
        }
        func forwardingVertex(pointerSlot slot: UInt64) -> Int32? {
            guard linkageAddresses.contains(slot), !rejectedLinkage.contains(slot),
                  slotClasses[slot] == Set<SlotClass>([.dataPointer]),
                  extent.fileBackedSection(containing: slot, size: 8) != nil,
                  let sectionName = extent.uniqueSectionName(containing: slot),
                  StubCallSymbolicator.linkageSlotClass(sectionName: sectionName) == .dataPointer,
                  linkageNames[slot]?.count == 1,
                  let identities = indirectIdentities[slot], identities.count == 1,
                  let identity = identities.first,
                  let candidates = importVerticesByIdentity[identity], candidates.count == 1 else { return nil }
            return candidates[0]
        }
        for (functionIndex, function) in sortedFunctions.enumerated() {
            let start = function.startAddress
            let end = function.endAddress
            guard start < end, functionStarts[start]?.count == 1,
                  linkageVertices[start] == nil else { continue }
            // One selector stub is at most 32 bytes (`objc_stubs_fast`); a longer
            // extent spans several entries and is not one proven stub.
            if !rejectedLinkage.contains(start), end - start <= 32,
               extent.executableSection(containing: start, size: end - start, declaredSection: "__objc_stubs") != nil {
                thunkFunctions.insert(functionIndex)
                continue
            }
            guard !linkageAddresses.contains(start),
                  end - start <= UInt64(ForwardingThunkProof.maximumInstructionCount * 4),
                  (end - start) % 4 == 0 else { continue }
            let first = instructionLowerBound(start)
            let last = instructionLowerBound(end)
            let count = Int((end - start) / 4)
            // Exactly one 4-byte row per word of the extent, uniquely owned by this function.
            guard last - first == count else { continue }
            var rows: [(address: UInt64, bytes: Data, mnemonic: String)] = []
            var expected = start
            for row in instructionList[first..<last] {
                guard row.address == expected, functionOwners.owner(at: row.address) == functionIndex else { break }
                rows.append((address: row.address, bytes: row.rawBytes, mnemonic: row.mnemonic))
                expected += 4
            }
            guard rows.count == count,
                  let forward = ForwardingThunkProof.target(of: rows) else { continue }
            let target: Int32?
            switch forward {
            case .direct(let address):
                guard address < start || address >= end else { continue }
                target = forwardingVertex(direct: address)
            case .pointerSlot(let slot):
                target = forwardingVertex(pointerSlot: slot)
            }
            let source = functionVertexIndex[functionIndex]
            guard let tIndex = target, tIndex != source else { continue }
            // Exactly one successor: no other call relation may leave the thunk.
            guard (callTargetsBySource[source] ?? []).isSubset(of: Set([tIndex])) else { continue }
            thunkFunctions.insert(functionIndex)
            callEdges.insert(CallEdge(source: source, target: tIndex))
        }
        let sortedCallEdges = callEdges.sorted {
            $0.source != $1.source ? $0.source < $1.source : $0.target < $1.target
        }

        // Call graph (field 8): function vertices plus admitted linkage vertices.
        writer.writeMessageField(fieldNumber: 8) { callGraphWriter in
            for vertex in vertices {
                callGraphWriter.writeMessageField(fieldNumber: 1) { vertexWriter in
                    vertexWriter.writePresentVarintField(vertex.address, fieldNumber: 1) // address
                    let linkage = linkageVertices[vertex.address]
                    let functionType: BinExport2VertexType? = vertex.functionIndex.flatMap {
                        thunkFunctions.contains($0) ? .thunk : nil
                    }
                    vertexWriter.writeUInt64Field(UInt64((linkage?.type ?? functionType ?? .normal).rawValue), fieldNumber: 2)
                    let functionName = vertex.functionIndex.map { sortedFunctions[$0].name } ?? ""
                    let displayName = snapshot.displayName(at: vertex.address, in: slot, default: linkage?.name ?? functionName)
                    vertexWriter.writeStringField(displayName, fieldNumber: 3) // mangled_name
                    vertexWriter.writeStringField(displayName, fieldNumber: 4) // demangled_name
                }
            }
            for edge in sortedCallEdges {
                callGraphWriter.writeMessageField(fieldNumber: 2) { edgeWriter in
                    // Keep a recursive edge at vertex zero from becoming an empty
                    // message and disappearing from the call graph.
                    edgeWriter.writeRepeatedVarintElement(UInt64(Int64(edge.source)), fieldNumber: 1)
                    edgeWriter.writeRepeatedVarintElement(UInt64(Int64(edge.target)), fieldNumber: 2)
                }
            }
        }
        return writer.data
    }

    // MARK: - Helpers

    /// Admits a linkage endpoint only when it lies wholly inside ONE executable,
    /// file-backed section of the exported image and inside that section's file
    /// bytes (`SectionSummary.fileOffset` is slice-relative and indexes
    /// `ImageAnalysis.imageBytes`). Missing sections or bytes, overlapping section
    /// declarations, zero-fill and arithmetic overflow all abstain.
    private struct LinkageExtentValidator {
        let sections: [SectionSummary]
        let imageByteCount: Int

        private static func bareName(_ name: String) -> String {
            name.split(separator: ",").last.map(String.init) ?? name
        }

        private func uniqueSection(containing address: UInt64) -> SectionSummary? {
            var found: SectionSummary?
            for section in sections where section.size > 0 && section.address <= address
                && address - section.address < section.size {
                guard found == nil else { return nil }
                found = section
            }
            return found
        }

        /// The bare name of the unique section containing `address`, or nil.
        func uniqueSectionName(containing address: UInt64) -> String? {
            uniqueSection(containing: address).map { Self.bareName($0.name) }
        }

        /// The bare name of the executable section that wholly holds
        /// `[address, address + size)` in file bytes and matches `declaredSection`
        /// (qualified names compare exactly, bare names by section component).
        func fileBackedSection(containing address: UInt64, size: UInt64) -> SectionSummary? {
            guard size > 0, imageByteCount > 0,
                  let section = uniqueSection(containing: address), !section.isZeroFill else { return nil }
            let offset = address - section.address
            let fileSpan = min(section.size, section.fileSize ?? section.size)
            guard offset <= fileSpan, size <= fileSpan - offset else { return nil }
            let intersectingSections = sections.filter { candidate in
                guard candidate.size > 0 else { return false }
                if candidate.address <= address {
                    return address - candidate.address < candidate.size
                }
                return candidate.address - address < size
            }
            guard intersectingSections.count == 1 else { return nil }
            let (fileStart, startOverflow) = section.fileOffset.addingReportingOverflow(offset)
            let (fileEnd, endOverflow) = fileStart.addingReportingOverflow(size)
            guard !startOverflow, !endOverflow, fileEnd <= UInt64(imageByteCount) else { return nil }
            return section
        }

        func executableSection(containing address: UInt64, size: UInt64, declaredSection: String) -> String? {
            guard let section = fileBackedSection(containing: address, size: size),
                  section.isExecutable else { return nil }
            let matchesDeclaration = declaredSection.contains(",")
                ? section.name == declaredSection
                : Self.bareName(section.name) == declaredSection
            guard matchesDeclaration else { return nil }
            return Self.bareName(section.name)
        }
    }

    /// Proves that a function body does nothing but forward control to one other
    /// address, from the raw 32-bit AArch64 encodings of its exact extent (the
    /// row mnemonic must agree with the encoding, otherwise the row is
    /// inconsistent and the proof abstains). Allow-list, in order:
    ///
    /// * any number of architectural no-ops: `nop` and the BTI landing-pad hints;
    /// * address materialisation into the intra-procedure-call scratch registers
    ///   x16/x17 only (which the AAPCS64 lets any veneer clobber): `adrp`,
    ///   `add Xd, Xn, #imm` (no flags) on an already materialised address, and
    ///   `ldr Xt, [Xn, #uimm]` (64-bit) of a pointer slot at a materialised address;
    /// * exactly one terminal branch: `b <imm>`; `br Xn` on a materialised address
    ///   or a loaded slot; `braaz`/`brabz Xn` on a loaded slot; `braa`/`brab Xn, Xm`
    ///   on a loaded slot whose modifier register holds that slot's address.
    ///
    /// Every other instruction, register, stack/flag effect, store or earlier
    /// branch rejects the proof: NORMAL.
    private enum ForwardingThunkProof {
        static let maximumInstructionCount = 16

        enum Target: Equatable {
            /// Control transfers to this code address.
            case direct(UInt64)
            /// Control transfers through the pointer stored at this slot address.
            case pointerSlot(UInt64)
        }

        private enum Value: Equatable {
            case address(UInt64)
            case loaded(slot: UInt64)
        }

        static func target(of rows: [(address: UInt64, bytes: Data, mnemonic: String)]) -> Target? {
            guard !rows.isEmpty, rows.count <= maximumInstructionCount else { return nil }
            var registers: [Int: Value] = [:]
            for (position, row) in rows.enumerated() {
                guard row.bytes.count == 4 else { return nil }
                let b = [UInt8](row.bytes)
                let word = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                let mnemonic = row.mnemonic.lowercased()
                let isLast = position == rows.count - 1
                let rd = Int(word & 0x1f)
                let rn = Int((word >> 5) & 0x1f)
                func writable(_ register: Int) -> Bool { register == 16 || register == 17 }

                // NOP / BTI {c, j, jc}: HINT #0, #32, #34, #36, #38.
                if word & 0xffff_f01f == 0xd503_201f {
                    let hint = (word >> 5) & 0x7f
                    guard !isLast, hint == 0 || [32, 34, 36, 38].contains(hint),
                          mnemonic == (hint == 0 ? "nop" : "hint") || (hint != 0 && mnemonic == "bti") else { return nil }
                    continue
                }
                // B <imm26>.
                if word & 0xfc00_0000 == 0x1400_0000 {
                    guard isLast, mnemonic == "b" else { return nil }
                    let offset = Int64(Int32(bitPattern: (word & 0x03ff_ffff) << 6) >> 6) * 4
                    return add(offset, to: row.address).map(Target.direct)
                }
                // ADRP Xd, <page>.
                if word & 0x9f00_0000 == 0x9000_0000 {
                    guard !isLast, mnemonic == "adrp", writable(rd) else { return nil }
                    let immediate = ((word >> 5) & 0x7ffff) << 2 | (word >> 29) & 0x3
                    let pages = Int64(Int32(bitPattern: immediate << 11) >> 11)
                    guard let page = add(pages * 4096, to: row.address & ~0xfff) else { return nil }
                    registers[rd] = .address(page)
                    continue
                }
                // ADD Xd, Xn, #imm{, lsl #12} (64-bit, no flags; SP excluded by writable()).
                if word & 0xff80_0000 == 0x9100_0000 {
                    guard !isLast, mnemonic == "add", writable(rd),
                          case .address(let base)? = registers[rn] else { return nil }
                    let shift: UInt64 = (word >> 22) & 1 == 1 ? 12 : 0
                    let (value, overflow) = base.addingReportingOverflow(UInt64((word >> 10) & 0xfff) << shift)
                    guard !overflow else { return nil }
                    registers[rd] = .address(value)
                    continue
                }
                // LDR Xt, [Xn, #uimm12 * 8] (64-bit unsigned offset).
                if word & 0xffc0_0000 == 0xf940_0000 {
                    guard !isLast, mnemonic == "ldr", writable(rd),
                          case .address(let base)? = registers[rn] else { return nil }
                    let (slot, overflow) = base.addingReportingOverflow(UInt64((word >> 10) & 0xfff) * 8)
                    guard !overflow else { return nil }
                    registers[rd] = .loaded(slot: slot)
                    continue
                }
                // BR Xn.
                if word & 0xffff_fc1f == 0xd61f_0000 {
                    guard isLast, mnemonic == "br" else { return nil }
                    switch registers[rn] {
                    case .address(let address)?: return .direct(address)
                    case .loaded(slot: let slot)?: return .pointerSlot(slot)
                    case nil: return nil
                    }
                }
                // BRAAZ / BRABZ Xn.
                if word & 0xffff_f81f == 0xd61f_081f {
                    guard isLast, mnemonic == ((word >> 10) & 1 == 0 ? "braaz" : "brabz"),
                          case .loaded(slot: let slot)? = registers[rn] else { return nil }
                    return .pointerSlot(slot)
                }
                // BRAA / BRAB Xn, Xm: the modifier must be the slot's own address.
                if word & 0xffff_f800 == 0xd71f_0800 {
                    guard isLast, mnemonic == ((word >> 10) & 1 == 0 ? "braa" : "brab"),
                          case .loaded(slot: let slot)? = registers[rn],
                          registers[rd] == .address(slot) else { return nil }
                    return .pointerSlot(slot)
                }
                return nil
            }
            return nil
        }

        private static func add(_ offset: Int64, to address: UInt64) -> UInt64? {
            if offset >= 0 {
                let (value, overflow) = address.addingReportingOverflow(UInt64(offset))
                return overflow ? nil : value
            }
            let magnitude = offset.magnitude
            return address >= magnitude ? address - magnitude : nil
        }
    }

    /// Precompute non-overlapping ownership spans in O(n log n). An address in
    /// overlapping ranges is deliberately unowned, rather than selecting an
    /// arbitrary function/block. Each subsequent lookup is O(log n).
    private struct AddressOwnerIndex {
        private struct Span {
            let start: UInt64
            let end: UInt64
            let owner: Int
        }
        private let spans: [Span]

        init(ranges: [(UInt64, UInt64, Int)]) {
            var events: [(address: UInt64, owner: Int, starts: Bool)] = []
            for (start, end, owner) in ranges where start < end {
                events.append((start, owner, true))
                events.append((end, owner, false))
            }
            events.sort { $0.address < $1.address }
            var active: Set<Int> = []
            var spans: [Span] = []
            var previous: UInt64?
            var position = 0
            while position < events.count {
                let address = events[position].address
                if let previous, previous < address, active.count == 1, let owner = active.first {
                    spans.append(Span(start: previous, end: address, owner: owner))
                }
                while position < events.count, events[position].address == address {
                    let event = events[position]
                    if event.starts { active.insert(event.owner) }
                    else { active.remove(event.owner) }
                    position += 1
                }
                previous = address
            }
            self.spans = spans
        }

        func owner(at address: UInt64) -> Int? {
            var low = 0
            var high = spans.count
            while low < high {
                let middle = low + (high - low) / 2
                if spans[middle].start <= address { low = middle + 1 }
                else { high = middle }
            }
            guard low > 0, address < spans[low - 1].end else { return nil }
            return spans[low - 1].owner
        }
    }

    /// Decodes a space-separated hex string into raw bytes. Invalid bytes are dropped.
    private static func decodeHexBytes(_ hex: String) -> Data {
        let tokens = hex.split(whereSeparator: { $0 == " " || $0 == "\t" })
        var bytes: [UInt8] = []
        bytes.reserveCapacity(tokens.count)
        for token in tokens {
            if let value = UInt8(token, radix: 16) {
                bytes.append(value)
            }
        }
        return Data(bytes)
    }

    /// Edge types for FlowGraph.Edge.Type enum.
    /// Numbering from binexport2.proto (FlowGraph.Edge.Type); 0 is not a valid value.
    private enum BinExport2EdgeType: Int {
        case conditionTrue = 1
        case conditionFalse = 2
        case unconditional = 3
        case `switch` = 4

        init(edge: ControlFlowEdge, conditionalSources: Set<UInt64>) {
            switch edge.kind {
            case "switch": self = .switch
            case "branch" where conditionalSources.contains(edge.from): self = .conditionTrue
            case "fallthrough" where conditionalSources.contains(edge.from): self = .conditionFalse
            default: self = .unconditional
            }
        }
    }

    /// Vertex types for CallGraph.Vertex.Type enum.
    private enum BinExport2VertexType: Int {
        case normal = 0
        case library = 1
        case imported = 2
        case thunk = 3
        case invalid = 4
    }
}
