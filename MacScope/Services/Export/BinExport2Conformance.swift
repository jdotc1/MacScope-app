import Foundation

/// One field of the vendored upstream `binexport2.proto`, as derived by
/// `Scripts/dependencies/generate_binexport2_schema.py` into `BinExport2Schema`.
struct BinExport2SchemaField: Equatable {
    enum Wire: Equatable { case varint, fixed64, lengthDelimited, fixed32 }
    let name: String
    let repeated: Bool
    let wire: Wire
    /// Full name of the nested message type, or nil for scalars, strings, bytes and enums.
    let message: String?
}

/// Checks exported BinExport2 bytes against the vendored upstream schema and the
/// requirements BinDiff enforces beyond proto2 defaults (RX-04). The app runs it on every
/// export before writing a file, so a file BinDiff would reject is never written.
///
/// BinDiff requirements checked:
///  * every function-entry instruction carries an explicit `address`;
///  * no basic block is empty, and every index range lies inside the instruction table;
///  * basic blocks of a flow graph and call-graph vertices are sorted ascending;
///  * every flow graph has `entry_basic_block_index`, naming one of its own blocks;
///  * every non-root expression of an operand has `parent_index`, naming an earlier
///    expression of the same operand tree.
enum BinExport2Conformance {
    enum Rule: String, Equatable {
        case wireFormat
        case unknownField
        case wireType
        case functionEntryAddress
        case emptyBasicBlock
        case basicBlockRange
        case basicBlockOrder
        case entryBasicBlockIndex
        case callGraphVertexAddress
        case callGraphVertexOrder
        case callGraphEdgeIndex
        case flowGraphEdgeIndex
        case parentIndex
    }

    struct Violation: Equatable, CustomStringConvertible {
        let rule: Rule
        let detail: String
        var description: String { "\(rule.rawValue): \(detail)" }
    }

    struct Failure: LocalizedError, Equatable {
        let violations: [Violation]
        var errorDescription: String? {
            let shown = violations.prefix(5).map(\.description).joined(separator: "; ")
            let more = violations.count > 5 ? " (+\(violations.count - 5) more)" : ""
            return "The BinExport2 export does not meet BinDiff's requirements: \(shown)\(more)"
        }
    }

    /// Returns every violation found; an empty array means the bytes conform.
    static func validate(_ data: Data) -> [Violation] {
        var violations: [Violation] = []
        guard let root = Message.decode([UInt8](data), type: "BinExport2", path: "BinExport2", violations: &violations) else {
            return violations
        }
        checkSemantics(root, &violations)
        return violations
    }

    static func requireConformance(_ data: Data) throws {
        let violations = validate(data)
        guard violations.isEmpty else { throw Failure(violations: violations) }
    }

    // MARK: - Wire decoding against the schema

    fileprivate enum Value {
        case varint(UInt64)
        case bytes([UInt8])
        case message(Message)
        case fixed(UInt64)
    }

    fileprivate struct Message {
        var fields: [(number: Int, value: Value)] = []

        func all(_ number: Int) -> [Value] { fields.filter { $0.number == number }.map(\.value) }
        func has(_ number: Int) -> Bool { fields.contains { $0.number == number } }
        func messages(_ number: Int) -> [Message] {
            all(number).compactMap { if case .message(let m) = $0 { return m } else { return nil } }
        }
        /// Singular scalar: last occurrence wins (proto semantics).
        func scalar(_ number: Int) -> UInt64? {
            for value in all(number).reversed() { if case .varint(let v) = value { return v } }
            return nil
        }
        /// Repeated varint, accepting packed and unpacked encodings.
        func repeatedVarints(_ number: Int) -> [UInt64] {
            var result: [UInt64] = []
            for value in all(number) {
                switch value {
                case .varint(let v): result.append(v)
                case .bytes(let packed):
                    var offset = 0
                    while offset < packed.count, let v = readVarint(packed, &offset) { result.append(v) }
                default: break
                }
            }
            return result
        }

        static func decode(_ bytes: [UInt8], type: String, path: String, violations: inout [Violation]) -> Message? {
            guard let schema = BinExport2Schema.messages[type] else {
                violations.append(Violation(rule: .unknownField, detail: "\(path): message type \(type) not in schema"))
                return nil
            }
            var message = Message()
            var offset = 0
            while offset < bytes.count {
                guard let tag = readVarint(bytes, &offset), tag >> 3 > 0, tag >> 3 <= UInt64(Int32.max) else {
                    violations.append(Violation(rule: .wireFormat, detail: "\(path): malformed tag at byte \(offset)"))
                    return nil
                }
                let number = Int(tag >> 3)
                let wire = Int(tag & 7)
                let value: Value
                switch wire {
                case 0:
                    guard let v = readVarint(bytes, &offset) else {
                        violations.append(Violation(rule: .wireFormat, detail: "\(path).\(number): truncated varint"))
                        return nil
                    }
                    value = .varint(v)
                case 1, 5:
                    let width = wire == 1 ? 8 : 4
                    guard bytes.count - offset >= width else {
                        violations.append(Violation(rule: .wireFormat, detail: "\(path).\(number): truncated fixed field"))
                        return nil
                    }
                    var v: UInt64 = 0
                    for index in 0..<width { v |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
                    offset += width
                    value = .fixed(v)
                case 2:
                    guard let length = readVarint(bytes, &offset), length <= UInt64(bytes.count - offset) else {
                        violations.append(Violation(rule: .wireFormat, detail: "\(path).\(number): truncated length-delimited field"))
                        return nil
                    }
                    let payload = Array(bytes[offset..<(offset + Int(length))])
                    offset += Int(length)
                    value = .bytes(payload)
                default:
                    violations.append(Violation(rule: .wireFormat, detail: "\(path).\(number): unsupported wire type \(wire)"))
                    return nil
                }
                guard let field = schema[number] else {
                    violations.append(Violation(rule: .unknownField, detail: "\(path): field \(number) is not in binexport2.proto"))
                    continue
                }
                let fieldPath = "\(path).\(field.name)"
                switch (field.wire, value) {
                case (.lengthDelimited, .bytes(let payload)):
                    if let nested = field.message {
                        guard let child = decode(payload, type: nested, path: fieldPath, violations: &violations) else { return nil }
                        message.fields.append((number, .message(child)))
                    } else {
                        message.fields.append((number, value))
                    }
                case (.varint, .varint), (.fixed64, .fixed), (.fixed32, .fixed):
                    message.fields.append((number, value))
                case (.varint, .bytes) where field.repeated:
                    message.fields.append((number, value)) // packed repeated scalar
                default:
                    violations.append(Violation(rule: .wireType, detail: "\(fieldPath): wire type \(wire) does not match the schema"))
                }
            }
            return message
        }
    }

    fileprivate static func readVarint(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count, shift < 64 {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    /// proto int32 values travel as sign-extended 64-bit varints.
    private static func int32(_ value: UInt64) -> Int64 { Int64(Int32(truncatingIfNeeded: value)) }

    // MARK: - BinDiff requirements

    private static func checkSemantics(_ root: Message, _ violations: inout [Violation]) {
        // Instructions: explicit address presence and resolved addresses (implicit address =
        // previous address + previous raw_bytes length, as BinExport defines it).
        let instructions = root.messages(5)
        var explicitAddress: [Bool] = []
        var addresses: [UInt64] = []
        var next: UInt64 = 0
        for instruction in instructions {
            let explicit = instruction.scalar(1)
            explicitAddress.append(explicit != nil)
            let address = explicit ?? next
            addresses.append(address)
            var size: UInt64 = 0
            if case .bytes(let raw)? = instruction.all(5).last { size = UInt64(raw.count) }
            next = address &+ size
        }

        // Basic blocks: non-empty, in-range ranges.
        let blocks = root.messages(6)
        var firstInstruction: [Int?] = []
        for (index, block) in blocks.enumerated() {
            let ranges = block.messages(1)
            guard !ranges.isEmpty else {
                violations.append(Violation(rule: .emptyBasicBlock, detail: "basic_block[\(index)] has no instruction range"))
                firstInstruction.append(nil)
                continue
            }
            var first: Int?
            for range in ranges {
                let begin = int32(range.scalar(1) ?? 0)
                let end = range.scalar(2).map(int32) ?? begin + 1
                if end <= begin {
                    violations.append(Violation(rule: .emptyBasicBlock, detail: "basic_block[\(index)] range [\(begin), \(end)) is empty"))
                } else if begin < 0 || end > Int64(instructions.count) {
                    violations.append(Violation(rule: .basicBlockRange, detail: "basic_block[\(index)] range [\(begin), \(end)) exceeds \(instructions.count) instructions"))
                } else if first == nil {
                    first = Int(begin)
                }
            }
            firstInstruction.append(first)
        }

        // Flow graphs: entry present and owned, blocks ascending, edges in range.
        for (index, graph) in root.messages(7).enumerated() {
            let members = graph.repeatedVarints(1).map(int32)
            if members.contains(where: { $0 < 0 || $0 >= Int64(blocks.count) }) {
                violations.append(Violation(rule: .basicBlockRange, detail: "flow_graph[\(index)] names a basic block outside the table"))
                continue
            }
            if zip(members, members.dropFirst()).contains(where: { $0 >= $1 }) {
                violations.append(Violation(rule: .basicBlockOrder, detail: "flow_graph[\(index)] basic_block_index is not strictly ascending"))
            }
            let starts = members.compactMap { firstInstruction[Int($0)].map { addresses[$0] } }
            if zip(starts, starts.dropFirst()).contains(where: { $0 >= $1 }) {
                violations.append(Violation(rule: .basicBlockOrder, detail: "flow_graph[\(index)] basic blocks are not in ascending address order"))
            }
            guard let entryValue = graph.scalar(3) else {
                violations.append(Violation(rule: .entryBasicBlockIndex, detail: "flow_graph[\(index)] has no entry_basic_block_index"))
                continue
            }
            let entry = int32(entryValue)
            guard members.contains(entry) else {
                violations.append(Violation(rule: .entryBasicBlockIndex, detail: "flow_graph[\(index)] entry block \(entry) is not one of its blocks"))
                continue
            }
            if let instruction = firstInstruction[Int(entry)], !explicitAddress[instruction] {
                violations.append(Violation(rule: .functionEntryAddress, detail: "flow_graph[\(index)] entry instruction \(instruction) has no explicit address"))
            }
            let memberSet = Set(members)
            for edge in graph.messages(2) {
                let source = int32(edge.scalar(1) ?? 0)
                let target = int32(edge.scalar(2) ?? 0)
                if !memberSet.contains(source) || !memberSet.contains(target) {
                    violations.append(Violation(rule: .flowGraphEdgeIndex, detail: "flow_graph[\(index)] edge \(source)->\(target) leaves the function"))
                }
            }
        }

        // Call graph: every vertex addressed, strictly ascending; edges in range.
        if let callGraph = root.messages(8).last {
            let vertices = callGraph.messages(1)
            var previous: UInt64?
            for (index, vertex) in vertices.enumerated() {
                guard let address = vertex.scalar(1) else {
                    violations.append(Violation(rule: .callGraphVertexAddress, detail: "call_graph.vertex[\(index)] has no explicit address"))
                    continue
                }
                if let previous, address <= previous {
                    violations.append(Violation(rule: .callGraphVertexOrder, detail: "call_graph.vertex[\(index)] address 0x\(String(address, radix: 16)) is not ascending"))
                }
                previous = address
            }
            for (index, edge) in callGraph.messages(2).enumerated() {
                let source = int32(edge.scalar(1) ?? 0)
                let target = int32(edge.scalar(2) ?? 0)
                if source < 0 || target < 0 || source >= Int64(vertices.count) || target >= Int64(vertices.count) {
                    violations.append(Violation(rule: .callGraphEdgeIndex, detail: "call_graph.edge[\(index)] \(source)->\(target) is outside \(vertices.count) vertices"))
                }
            }
        }

        // Expressions: every non-root expression of an operand tree has a parent in the tree.
        let expressions = root.messages(2)
        for (index, operand) in root.messages(3).enumerated() {
            let tree = operand.repeatedVarints(1).map(int32)
            guard !tree.contains(where: { $0 < 0 || $0 >= Int64(expressions.count) }) else {
                violations.append(Violation(rule: .parentIndex, detail: "operand[\(index)] names an expression outside the table"))
                continue
            }
            for (position, expression) in tree.enumerated() where position > 0 {
                guard let parentValue = expressions[Int(expression)].scalar(4) else {
                    violations.append(Violation(rule: .parentIndex, detail: "operand[\(index)] expression \(expression) has no parent_index"))
                    continue
                }
                if !tree[..<position].contains(int32(parentValue)) {
                    violations.append(Violation(rule: .parentIndex, detail: "operand[\(index)] expression \(expression) parent \(int32(parentValue)) is not an earlier node of its tree"))
                }
            }
        }
    }
}
