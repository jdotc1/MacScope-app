import Foundation
import XCTest
@testable import MacScope

/// Address-bound producer properties shared by the two lifter modes' tests.
enum SSAPropertyAssertions {
    static var enabled: Bool {
        MacIRConfiguration.ssaEnabled
    }

    enum CellZeroOrigin: Hashable {
        case entryX0
        case instruction(UInt64)
        case callResult(UInt64)
    }

    /// Expand phi cycles by identity while keeping the incoming parameter
    /// distinct from instruction addresses and unavailable definitions.
    static func cellZeroOrigins(_ initial: Int, info: MacIRSSAInfo,
                                file: StaticString = #filePath, line: UInt = #line) -> Set<CellZeroOrigin> {
        var pending = [initial], visited: Set<Int> = [], result: Set<CellZeroOrigin> = []
        while let raw = pending.popLast() {
            let id = info.plan.canonicalID(raw)
            guard visited.insert(id).inserted else { continue }
            guard info.plan.definitions.indices.contains(id) else {
                XCTFail("missing cell-0 definition", file: file, line: line)
                continue
            }
            let definition = info.plan.definitions[id]
            XCTAssertEqual(definition.cell, 0, file: file, line: line)
            switch definition.origin {
            case .entry:
                result.insert(.entryX0)
                guard case .argument = info.values[id] else {
                    XCTFail("entry X0 must retain the incoming parameter", file: file, line: line)
                    continue
                }
            case let .instruction(address): result.insert(.instruction(address))
            case .callResult:
                let rows = info.plan.rowWriteBindings.indices.filter {
                    info.plan.rowWriteBindings[$0][0].map(info.plan.canonicalID) == id
                }
                XCTAssertEqual(rows.count, 1, "call result must name one producer row", file: file, line: line)
                for row in rows { result.insert(.callResult(info.sourceAddresses[row])) }
            case .phi:
                let phis = info.plan.phis.filter { info.plan.canonicalID($0.destination) == id }
                XCTAssertEqual(phis.count, 1, "phi origin must have one definition", file: file, line: line)
                for phi in phis { pending.append(contentsOf: phi.incoming.map(\.definition)) }
            case .callClobber, .refusal:
                XCTFail("unexpected unavailable cell-0 origin: \(definition.origin)", file: file, line: line)
            }
        }
        return result
    }

    static func physicalCell(_ value: MacIRValue) -> Int? {
        guard case let .register(name, _) = value else { return nil }
        if name == "sp" || name == "wsp" { return 31 }
        guard let prefix = name.first, let index = Int(name.dropFirst()) else { return nil }
        switch prefix {
        case "x", "w": return (0..<31).contains(index) ? index : nil
        case "d", "s", "v", "q": return (0..<32).contains(index) ? 32 + index : nil
        default: return nil
        }
    }

    static func definitions(_ operation: MacIROperation) -> [MacIRValue] {
        switch operation {
        case let .assign(destination, _), let .binary(destination, _, _, _),
             let .load(destination, _), let .select(destination, _, _, _, _, _),
             let .compareToBool(destination, _, _, _), let .stackSlotRead(destination, _, _):
            return [destination]
        case let .loadWriteback(destination, base, _, _, _): return [destination, base]
        case let .storeWriteback(_, base, _, _, _): return [base]
        case let .stackSlotPairRead(first, _, _, second, _, _): return [first, second]
        case let .call(_, destination), let .intrinsic(destination, _, _),
             let .unknown(destination, _, _, _): return destination.map { [$0] } ?? []
        default: return []
        }
    }

    static func phi(_ function: MacIRFunction, block: UInt64, cell: Int, width: Int,
                    incoming: [(predecessor: UInt64, producer: UInt64)],
                    refusalProducers: Set<UInt64> = [],
                    file: StaticString = #filePath, line: UInt = #line) -> MacIRPhi? {
        let matches = function.phis.filter { $0.blockAddress == block && physicalCell($0.destination) == cell }
        XCTAssertEqual(matches.count, 1, "expected one phi for cell \(cell) at \(String(block, radix: 16))", file: file, line: line)
        guard matches.count == 1, let phi = matches.first else { return nil }
        XCTAssertEqual(phi.bitWidth, width, file: file, line: line)
        XCTAssertEqual(phi.incoming.map(\.machineAddress), incoming.map { Optional.some($0.predecessor) }, file: file, line: line)
        for (actual, expected) in zip(phi.incoming, incoming) {
            let producerRows = function.instructions.filter { $0.source.address == expected.producer }
            if refusalProducers.contains(expected.producer) {
                XCTAssertTrue(producerRows.contains { if case .unknown = $0.operation { return true }; return false },
                              "refusal producer must retain its unknown operation", file: file, line: line)
                XCTAssertTrue(function.refusals.contains { refusal in
                    refusal.scope == .row(expected.producer) || refusal.scope == .cell(cell, expected.producer)
                }, "refusal incoming requires row or cell attribution", file: file, line: line)
                if let info = function.ssaInfo,
                   let graphBlock = function.cfg?.blocks.first(where: { $0.startAddress == block }),
                   let plannedPhi = info.plan.phis.first(where: { $0.block == graphBlock.index && $0.cell == cell }),
                   let plannedIncoming = plannedPhi.incoming.first(where: { $0.machineAddress == expected.predecessor }) {
                    let definition = info.plan.definitions[info.plan.canonicalID(plannedIncoming.definition)]
                    guard case let .refusal(reason, address) = definition.origin else {
                        XCTFail("the named predecessor must carry a refusal-origin definition", file: file, line: line)
                        continue
                    }
                    XCTAssertEqual(address, expected.producer, file: file, line: line)
                    XCTAssertEqual(definition.cell, cell, file: file, line: line)
                    XCTAssertTrue(function.refusals.contains {
                        $0.reason == reason && ($0.scope == .row(address) || $0.scope == .cell(cell, address))
                    }, "the bound definition and scoped refusal must agree", file: file, line: line)
                } else {
                    XCTFail("refusal provenance requires the persisted predecessor binding", file: file, line: line)
                }
                let destinations = producerRows.flatMap { definitions($0.operation) }
                XCTAssertTrue(destinations.contains(actual.value) || isUnknown(actual.value),
                              "refused incoming must retain its unavailable definition", file: file, line: line)
                continue
            }
            let rowDefinitions = producerRows.flatMap { definitions($0.operation) }
                .filter { physicalCell($0) == cell }
            let phiDefinitions = function.phis.filter {
                $0.blockAddress == expected.producer && physicalCell($0.destination) == cell
            }
            let candidates = rowDefinitions + phiDefinitions.map(\.destination)
            XCTAssertEqual(candidates.count, 1, "producer address must identify one cell definition", file: file, line: line)
            guard candidates.count == 1, let producer = candidates.first else { continue }
            let producerWidth: Int
            if let sourcePhi = phiDefinitions.first {
                producerWidth = sourcePhi.bitWidth
            } else if case let .register(name, _) = producer, name.hasPrefix("w") || name.hasPrefix("s") {
                producerWidth = 32
            } else {
                producerWidth = 64
            }
            let expectedValue: MacIRValue = producerWidth == 32 && width == 64
                ? .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: producer))
                : producer
            XCTAssertEqual(actual.value, expectedValue, "incoming from \(String(expected.predecessor, radix: 16))", file: file, line: line)
        }
        return phi
    }

    static func assertView(_ value: MacIRValue?, of phi: MacIRPhi, width: Int,
                           file: StaticString = #filePath, line: UInt = #line) {
        let expected: MacIRValue
        if width == phi.bitWidth {
            expected = phi.destination
        } else if width == 32 {
            expected = .unary(op: "(uint32_t)", value: phi.destination)
        } else {
            expected = .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: phi.destination))
        }
        XCTAssertEqual(value, expected, "use must consume the phi's architectural view", file: file, line: line)
    }

    private static func isUnknown(_ value: MacIRValue) -> Bool {
        if case .unknown = value { return true }
        if case let .unary(_, inner) = value { return isUnknown(inner) }
        return false
    }

    static func assertOrdinaryUsesDominated(_ function: MacIRFunction,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let blockByRow = Dictionary(uniqueKeysWithValues: cfg.blocks.flatMap { block in
            block.instructionRange.map { ($0, block.index) }
        })
        for (row, instruction) in function.instructions.enumerated() {
            guard let useBlock = blockByRow[row], let values = RegionalBoundaryPlan.values(instruction.operation) else { continue }
            let destinations = Set(definitions(instruction.operation))
            var atoms: Set<MacIRValue> = []
            for value in values where !destinations.contains(value) {
                RegionalBoundaryPlan.collectAtoms(value, into: &atoms)
            }
            for atom in atoms {
                let producers = function.instructions.indices.filter { definitions(function.instructions[$0].operation).contains(atom) }
                for producer in producers {
                    guard let definitionBlock = blockByRow[producer] else { continue }
                    XCTAssertTrue(definitionBlock == useBlock ? producer < row
                        : MacIRCFGAlgorithms.dominates(definitionBlock, useBlock, domTree: cfg.domTree),
                        "ordinary use at \(String(instruction.source.address, radix: 16)) has a non-dominating producer", file: file, line: line)
                }
                for phi in function.phis where phi.destination == atom {
                    guard let phiRow = function.instructions.firstIndex(where: { $0.source.address == phi.blockAddress }),
                          let definitionBlock = blockByRow[phiRow] else {
                        XCTFail("phi must identify a CFG block", file: file, line: line)
                        continue
                    }
                    XCTAssertTrue(MacIRCFGAlgorithms.dominates(definitionBlock, useBlock, domTree: cfg.domTree),
                                  "phi must dominate its ordinary use", file: file, line: line)
                }
            }
        }
    }
}

/// Behavioral checks over source-linked statements and unchanged decoded captures.
enum RenderProperties {
    struct Statement: Equatable {
        let sourceRow: Int?
        let text: String
        let kind: PseudocodeLineKind
    }
    enum Relaxation: Hashable { case labelSpelling, flatIf, compareToBool, branchSpelling }
    struct Shape {
        var `if` = 0, `while` = 0, `do` = 0, `for` = 0, `goto` = 0, `return` = 0, label = 0
    }
    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func label(_ text: String) -> String? {
        let text = text.hasSuffix(":;") ? String(text.dropLast()) : text
        let prefix = text.hasPrefix("loc_") ? 4 : (text.hasPrefix("L_") ? 2 : 0)
        guard prefix > 0, text.hasSuffix(":"),
              !text.dropFirst(prefix).dropLast().isEmpty,
              text.dropFirst(prefix).dropLast().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return String(text.dropLast())
    }
    private static func normalized(_ statement: Statement, allowing: Set<Relaxation>) -> Statement? {
        var text = trim(statement.text)
        guard !text.isEmpty, text != "{", text != "}" else { return nil }
        if allowing.contains(.labelSpelling) {
            if label(text) != nil { return nil }
            text = text.replacingOccurrences(of: #"\bgoto (?:loc_|L_)([0-9a-f]+)(?=;)"#,
                with: "goto 0x$1", options: .regularExpression)
        }
        return Statement(sourceRow: statement.sourceRow, text: text, kind: statement.kind)
    }
    static func normalize(_ document: PseudocodeDocument, rows: [InstructionRow]?,
                          allowing: Set<Relaxation>) -> [Statement] {
        let indices = rows.map { Dictionary(uniqueKeysWithValues: $0.enumerated().map { ($1.address, $0) }) }
        var splitEdges: [String: [MacIRPhiEdgeIdentity]] = [:]
        if allowing.contains(.labelSpelling) {
            for line in document.lines {
                let text = trim(line.text)
                guard let edge = line.syntheticPhiEdge,
                      text.range(of: #"^L_edge_[0-9]+_[0-9]+:$"#, options: .regularExpression) != nil else { continue }
                splitEdges[String(text.dropLast()), default: []].append(edge)
            }
        }
        let statements = document.lines.map { line in
            let row = line.sourceAddress.flatMap { address -> Int? in
                if let indices { return indices[address] }
                guard address >= document.entryAddress, (address - document.entryAddress) % 4 == 0 else { return nil }
                return Int((address - document.entryAddress) / 4)
            }
            var text = line.text
            // A split edge keeps its original predecessor's branch statement.
            // Normalize only a unique edge label bound to that same source PC;
            // the ordinary statement comparison still checks the exact target.
            if let address = line.sourceAddress {
                for (label, edges) in splitEdges where edges.count == 1 {
                    guard let edge = edges.first, edge.machineAddress == address else { continue }
                    text = text.replacingOccurrences(of: "goto \(label);",
                        with: "goto 0x\(String(edge.blockAddress, radix: 16));")
                }
            }
            return Statement(sourceRow: row, text: text, kind: line.kind)
        }
        return relaxedIfs(statements, allowing: allowing).compactMap { normalized($0, allowing: allowing) }
    }
    static func normalize(_ text: String, allowing: Set<Relaxation>) -> [Statement] {
        let statements = text.components(separatedBy: "\n").enumerated().map { index, text in
            Statement(sourceRow: nil, text: text,
                kind: index == 0 ? .signature : (trim(text).hasPrefix("//") ? .metadata : .instruction))
        }
        return relaxedIfs(statements, allowing: allowing).compactMap { normalized($0, allowing: allowing) }
    }
    /// Only a single forward guard and its uniquely targeted end label can stand for an if arm.
    private static func relaxedIfs(_ input: [Statement], allowing: Set<Relaxation>) -> [Statement] {
        guard allowing.contains(.flatIf) else { return input }
        var result = input
        func replaced(_ index: Int, _ text: String, closing: Bool = false) {
            result[index] = Statement(sourceRow: closing ? nil : input[index].sourceRow,
                                      text: text, kind: .instruction)
        }
        func identifier(_ value: String) -> Bool {
            value.range(of: #"^[A-Za-z_][A-Za-z_0-9]*$"#, options: .regularExpression) != nil
        }
        func boolean(_ condition: String) -> String {
            let value = trim(condition)
            if value.hasSuffix(" != 0x0"), identifier(String(value.dropLast(7))) { return String(value.dropLast(7)) }
            if value.hasSuffix(" == 0x0"), identifier(String(value.dropLast(7))) { return "!" + String(value.dropLast(7)) }
            return value
        }
        func inverse(_ condition: String) -> String {
            let value = boolean(condition)
            if value.hasPrefix("!"), identifier(String(value.dropFirst())) { return String(value.dropFirst()) }
            if identifier(value) { return "!" + value }
            let pairs = [(" == ", " != "), (" != ", " == "), (" >= ", " < "),
                         (" <= ", " > "), (" > ", " <= "), (" < ", " >= ")]
            for (op, opposite) in pairs {
                let parts = value.components(separatedBy: op)
                if parts.count == 2, !value.contains("&&"), !value.contains("||"),
                   parts[0].filter({ $0 == "(" }).count == parts[0].filter({ $0 == ")" }).count {
                    return boolean(parts.joined(separator: opposite))
                }
            }
            return "!(" + value + ")"
        }
        for index in input.indices {
            let parts = trim(input[index].text).components(separatedBy: "//")
            let code = trim(parts[0]), comment = parts.count > 1 ? " //" + parts.dropFirst().joined(separator: "//") : ""
            guard code.hasPrefix("if (") else { continue }
            if code.hasSuffix(") {") {
                var depth = 1, end: Int?
                for next in (index + 1)..<input.count {
                    let body = trim(input[next].text.components(separatedBy: "//")[0])
                    if body.hasPrefix("}") { depth -= 1 }
                    if depth == 0 { if body == "}" { end = next }; break }
                    if body.hasSuffix("{") { depth += 1 }
                }
                guard let end else { continue }
                replaced(index, "__if(" + boolean(String(code.dropFirst(4).dropLast(3))) + ")" + comment)
                replaced(end, "__end_if", closing: true)
            } else if let split = code.range(of: ") goto "), code.hasSuffix(";") {
                let target = String(code[split.upperBound...].dropLast())
                guard target.hasPrefix("loc_") || target.hasPrefix("L_"),
                      input.filter({ $0.text.contains("goto " + target + ";") }).count == 1,
                      let end = input.indices.dropFirst(index + 1).first(where: { [target + ":", target + ":;"].contains(trim(input[$0].text)) }) else { continue }
                let condition = String(code[code.index(code.startIndex, offsetBy: 4)..<split.lowerBound])
                replaced(index, "__if(" + inverse(condition) + ")" + comment)
                replaced(end, "__end_if", closing: true)
            }
        }
        return result
    }
    private static func branch(_ text: String) -> (target: UInt64, comment: String, intrinsic: Bool)? {
        let parts = text.components(separatedBy: "//"), code = trim(parts[0])
        let intrinsic = code.hasPrefix("__branch(0x") && code.hasSuffix(");")
        let digits: String
        if intrinsic { digits = String(code.dropFirst(11).dropLast(2)) }
        else if code.hasPrefix("goto 0x"), code.hasSuffix(";") { digits = String(code.dropFirst(7).dropLast()) }
        else if code.hasPrefix("goto loc_"), code.hasSuffix(";") { digits = String(code.dropFirst(9).dropLast()) }
        else if code.hasPrefix("goto L_"), code.hasSuffix(";") { digits = String(code.dropFirst(7).dropLast()) }
        else { return nil }
        guard !digits.isEmpty, digits.allSatisfy({ "0123456789abcdef".contains($0) }),
              let target = UInt64(digits, radix: 16) else { return nil }
        return (target, parts.dropFirst().joined(separator: "//"), intrinsic)
    }
    private static func comparisonFailure(_ actual: [Statement], _ expected: [Statement], allowing: Set<Relaxation>,
                                addresses: Set<UInt64>, message: String = "") -> String? {
        if allowing.contains(.compareToBool), abs(actual.count - expected.count) == 1 {
            let longer = actual.count > expected.count ? actual : expected
            let shorter = actual.count > expected.count ? expected : actual
            let difference = longer.indices.first { $0 >= shorter.count || longer[$0] != shorter[$0] }
            if let difference, longer[difference].text.hasPrefix("__compare("),
               longer[difference].text.hasSuffix("); // sets condition flags") {
                var reduced = longer
                reduced.remove(at: difference)
                return comparisonFailure(actual.count > expected.count ? reduced : actual,
                        actual.count > expected.count ? expected : reduced,
                        allowing: allowing.subtracting([.compareToBool]), addresses: addresses,
                        message: message)
            }
        }
        for index in 0..<max(actual.count, expected.count) {
            let lhs = index < actual.count ? actual[index] : nil
            let rhs = index < expected.count ? expected[index] : nil
            if lhs == rhs { continue }
            if allowing.contains(.branchSpelling), let lhs, let rhs, lhs.sourceRow == rhs.sourceRow,
               lhs.kind == rhs.kind, let a = branch(lhs.text), let b = branch(rhs.text),
               a.intrinsic != b.intrinsic, a.target == b.target, a.comment == b.comment,
               addresses.contains(a.target) { continue }
            return "\(message) statement \(index), row \(lhs?.sourceRow ?? rhs?.sourceRow ?? -1): actual [\(lhs?.text ?? "<missing>")] expected [\(rhs?.text ?? "<missing>")]"
        }
        return nil
    }
    private static func compare(_ actual: [Statement], _ expected: [Statement], allowing: Set<Relaxation>,
                                addresses: Set<UInt64>, message: String = "", file: StaticString, line: UInt) {
        if let failure = comparisonFailure(actual, expected, allowing: allowing,
                                           addresses: addresses, message: message) {
            XCTFail(failure, file: file, line: line)
        }
    }
    static func assertSameStatements(_ actual: PseudocodeDocument, _ expected: PseudocodeDocument,
                                     allowing: Set<Relaxation> = [], _ message: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
        compare(normalize(actual, rows: nil, allowing: allowing), normalize(expected, rows: nil, allowing: allowing),
                allowing: allowing, addresses: Set(actual.lines.compactMap(\.sourceAddress))
                    .intersection(expected.lines.compactMap(\.sourceAddress)), message: message, file: file, line: line)
    }
    /// The capture supplies row order, not the output being checked. Unsupported rows fail closed.
    private static func capturedStatements(_ baseline: String) -> (statements: [Statement], addresses: Set<UInt64>)? {
        for seed in [RegionalTerminalSeed.finishDecompress, .skipVariable] where baseline == seed.baselineText {
            let records = seed.sourceRecord.split(separator: "\n").map { $0.split(separator: "|", omittingEmptySubsequences: false) }
            let rows = records.indices.filter { records[$0][2] != "cmp" }
            let lines = baseline.components(separatedBy: "\n").dropFirst(2).dropLast().map(trim)
            guard rows.count == lines.count else { return nil }
            return (zip(rows, lines).map { Statement(sourceRow: $0, text: $1, kind: .instruction) },
                    Set(records.compactMap { UInt64($0[0], radix: 16) }))
        }
        let seed = RegionalCallSeed.j16init
        guard baseline == seed.baselineText else { return nil }
        let records = seed.sourceRecord.split(separator: "\n").map { $0.split(separator: "|", omittingEmptySubsequences: false) }
        let lines = baseline.components(separatedBy: "\n").map(trim)
        let calls = lines.filter { $0.hasSuffix("// call") }
        guard calls.count == seed.callRows.count, lines.last == "}" else { return nil }
        let suffix = Array(seed.suffixStart..<seed.rowCount)
        let tail = lines.dropLast().suffix(suffix.count)
        let statements = zip(seed.callRows, calls).map { Statement(sourceRow: $0, text: $1, kind: .instruction) }
            + zip(suffix, tail).map { Statement(sourceRow: $0, text: $1, kind: .instruction) }
        return (statements.sorted { ($0.sourceRow ?? -1) < ($1.sourceRow ?? -1) },
                Set(records.compactMap { UInt64($0[0], radix: 16) }))
    }
    static func capturedStatementFailure(_ actual: PseudocodeDocument, baseline: String, rows: Set<Int>,
                                     expectedTextByRow: [Int: String] = [:],
                                     allowing: Set<Relaxation> = []) -> String? {
        guard let capture = capturedStatements(baseline) else {
            return "rows \(rows.sorted()): actual document vs expected capture has no independent source-row mapping"
        }
        guard capture.addresses.min() == actual.entryAddress else {
            return "actual entry \(actual.entryAddress) vs expected captured entry \(String(describing: capture.addresses.min()))"
        }
        // Overrides change expected text only AFTER the immutable capture maps rows.
        // Reject ignored or ambiguous overrides rather than silently weakening coverage.
        guard Set(expectedTextByRow.keys).isSubset(of: rows),
              expectedTextByRow.keys.allSatisfy({ row in
                  capture.statements.filter { $0.sourceRow == row }.count == 1
              }) else {
            return "expected text override requires one captured statement in each requested row"
        }
        let expected = capture.statements.filter { rows.contains($0.sourceRow ?? -1) }
            .map { statement in
                Statement(sourceRow: statement.sourceRow,
                    text: statement.sourceRow.flatMap { expectedTextByRow[$0] } ?? statement.text,
                    kind: statement.kind)
            }
            .compactMap { normalized($0, allowing: allowing) }
        let found = Set(expected.compactMap(\.sourceRow))
        let capturedElisions: Set<Int> = baseline == RegionalTerminalSeed.finishDecompress.baselineText ? [6, 10, 12, 24]
            : baseline == RegionalTerminalSeed.skipVariable.baselineText ? [42] : []
        guard found.union(rows.intersection(capturedElisions)) == rows else {
            return "actual requested rows \(rows.sorted()) vs expected captured rows \(found.sorted())"
        }
        return comparisonFailure(normalize(actual, rows: nil, allowing: allowing).filter { rows.contains($0.sourceRow ?? -1) },
                expected, allowing: allowing, addresses: capture.addresses)
    }
    static func assertSameStatements(_ actual: PseudocodeDocument, baseline: String, rows: Set<Int>,
                                     expectedTextByRow: [Int: String] = [:],
                                     allowing: Set<Relaxation> = [], file: StaticString = #filePath, line: UInt = #line) {
        if let failure = capturedStatementFailure(actual, baseline: baseline, rows: rows,
                                                  expectedTextByRow: expectedTextByRow, allowing: allowing) {
            XCTFail(failure, file: file, line: line)
        }
    }
    static func assertDeterministic(_ render: () throws -> PseudocodeDocument,
                                    file: StaticString = #filePath, line: UInt = #line) rethrows {
        let first = try render(), second = try render()
        assertSameStatements(second, first, file: file, line: line)
        XCTAssertEqual(second.text, first.text, "second render vs first render", file: file, line: line)
    }
    static func assertDeterministic(_ build: () throws -> MacIRFunction,
                                    file: StaticString = #filePath, line: UInt = #line) rethrows {
        let first = try build(), second = try build()
        XCTAssertEqual(second, first, "second lift vs first lift from the same decoded input", file: file, line: line)
    }
    static func assertNoMarkers(_ document: PseudocodeDocument, rows: Set<Int>,
                                file: StaticString = #filePath, line: UInt = #line) {
        let statements = normalize(document, rows: nil, allowing: []).filter { rows.contains($0.sourceRow ?? -1) }
        for row in rows.sorted() {
            XCTAssertTrue(statements.contains { $0.sourceRow == row }, "row \(row): actual missing vs expected resolved statement", file: file, line: line)
        }
        for statement in statements {
            XCTAssertFalse(["unresolved_", "unavailable_", "unbound_"].contains { statement.text.contains($0) },
                "row \(statement.sourceRow ?? -1): actual [\(statement.text)] vs expected no unresolved marker", file: file, line: line)
        }
    }
    private static func definitions(_ operation: MacIROperation) -> [MacIRValue] {
        switch operation {
        case let .assign(destination, _), let .binary(destination, _, _, _), let .load(destination, _),
             let .select(destination, _, _, _, _, _), let .compareToBool(destination, _, _, _),
             let .stackSlotRead(destination, _, _): return [destination]
        case let .loadWriteback(destination, base, _, _, _): return [destination, base]
        case let .storeWriteback(_, base, _, _, _): return [base]
        case let .stackSlotPairRead(first, _, _, second, _, _): return [first, second]
        case let .call(_, destination), let .intrinsic(destination, _, _), let .unknown(destination, _, _, _):
            return destination.map { [$0] } ?? []
        default: return []
        }
    }
    static func assertSingleReturnProducer(_ function: MacIRFunction, row: Int, alias: MacIRValue,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard case .register = alias else { XCTFail("row \(row): actual alias \(alias) vs expected concrete register", file: file, line: line); return }
        XCTAssertEqual(function.returnValue, alias, "row \(row): actual return value vs expected alias", file: file, line: line)
        let producers = function.instructions.indices.filter { definitions(function.instructions[$0].operation).contains(alias) }
        XCTAssertEqual(producers, [row], "alias \(alias): actual producer rows vs expected sole row \(row)", file: file, line: line)
        XCTAssertFalse(function.phis.contains { $0.destination == alias }, "row \(row): actual phi producer vs expected instruction-only producer", file: file, line: line)
    }
    static func assertSourceCoverage(_ document: PseudocodeDocument, rows: [InstructionRow], required: Set<Int>,
                                     file: StaticString = #filePath, line: UInt = #line) {
        for row in required.sorted() {
            guard rows.indices.contains(row) else { XCTFail("row \(row): actual absent vs expected decoded row", file: file, line: line); continue }
            XCTAssertFalse(document.lines(sourcedAt: rows[row].address).isEmpty,
                "row \(row): actual no sourced lines vs expected source coverage", file: file, line: line)
        }
    }
    static func assertCallShape(_ function: MacIRFunction, callRows: [Int], decoded: [InstructionRow],
                                baselineCallLines: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(baselineCallLines.count, callRows.count, "actual captured call lines vs expected decoded call rows", file: file, line: line)
        guard baselineCallLines.count == callRows.count else { return }
        for (ordinal, row) in callRows.enumerated() {
            guard function.instructions.indices.contains(row), decoded.indices.contains(row),
                  case let .call(frame, result) = function.instructions[row].operation else {
                XCTFail("row \(row): actual missing/non-call operation vs expected captured [\(baselineCallLines[ordinal])]", file: file, line: line); continue
            }
            XCTAssertEqual(frame.controlInputs.indirectTarget != nil, decoded[row].mnemonic == "blr",
                "row \(row): actual indirect target \(String(describing: frame.controlInputs.indirectTarget)) vs decoded \(decoded[row].mnemonic)", file: file, line: line)
            let code = baselineCallLines[ordinal].components(separatedBy: "//")[0]
            let assignment = code.range(of: " = ")
            let call = code.firstIndex(of: "(")
            let hasResult = assignment.map { assignmentRange in call.map { $0 > assignmentRange.lowerBound } ?? false } ?? false
            XCTAssertEqual(result != nil, hasResult,
                "row \(row): actual result \(String(describing: result)) vs captured [\(baselineCallLines[ordinal])]", file: file, line: line)
        }
    }
    static func assertReturnShape(_ function: MacIRFunction, returnRow: Int,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard function.instructions.indices.contains(returnRow) else { XCTFail("row \(returnRow): actual missing vs expected returnValue", file: file, line: line); return }
        guard case .returnValue = function.instructions[returnRow].operation else {
            XCTFail("row \(returnRow): actual \(function.instructions[returnRow].operation) vs expected returnValue", file: file, line: line); return
        }
    }
    static func assertSuccessorCounts(_ cfg: CFG, rows: [Int: Int], file: StaticString = #filePath, line: UInt = #line) {
        for row in rows.keys.sorted() {
            let blocks = cfg.blocks.filter { $0.instructionRange.contains(row) }
            XCTAssertEqual(blocks.count, 1, "row \(row): actual containing blocks vs expected exactly one", file: file, line: line)
            XCTAssertEqual(blocks.first?.successors.count, rows[row], "row \(row): actual successor count vs captured expected count", file: file, line: line)
        }
    }
    static func returnRow(decoded rows: [InstructionRow], file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let returns = rows.indices.filter { rows[$0].mnemonic == "ret" }
        XCTAssertEqual(returns.count, 1, "actual decoded ret rows \(returns) vs expected unique ret", file: file, line: line)
        guard returns.count == 1 else { throw CaptureError.nonUniqueReturn }
        return try XCTUnwrap(returns.first, file: file, line: line)
    }
    private enum CaptureError: Error { case nonUniqueReturn }
    static func shape(_ document: PseudocodeDocument) -> Shape {
        var result = Shape()
        for line in document.lines {
            let text = trim(line.text)
            if text.hasPrefix("if (") { result.if += 1 }
            if text.hasPrefix("while (") { result.while += 1 }
            if text == "do {" { result.do += 1 }
            if text.hasPrefix("for (") { result.for += 1 }
            if text.contains("goto ") || text.hasPrefix("__branch(") { result.goto += 1 }
            if text == "return;" || text.hasPrefix("return ") || text.hasPrefix("return;") { result.return += 1 }
            if label(text) != nil { result.label += 1 }
        }
        return result
    }
    static func assertWellFormedStructure(_ document: PseudocodeDocument,
                                          file: StaticString = #filePath, line: UInt = #line) {
        var path: [Int] = [], labels: [String: [Int]] = [:], jumps: [(String, [Int], Int)] = []
        for (index, lineValue) in document.lines.enumerated() {
            let text = trim(lineValue.text.components(separatedBy: "//")[0])
            if text.hasPrefix("}") {
                XCTAssertFalse(path.isEmpty, "line \(index): actual unmatched close vs expected open scope", file: file, line: line)
                if !path.isEmpty { path.removeLast() }
            }
            if let name = label(text) { labels[name] = path }
            if let range = text.range(of: "goto "), let end = text[range.upperBound...].firstIndex(of: ";") {
                jumps.append((String(text[range.upperBound..<end]), path, index))
            }
            if text.hasSuffix("{") {
                if document.regionTree == nil {
                    XCTAssertTrue(path.isEmpty, "line \(index): actual nested scope vs expected flat fallback", file: file, line: line)
                }
                path.append(index)
            }
        }
        XCTAssertTrue(path.isEmpty, "actual unclosed scopes \(path) vs expected balanced structure", file: file, line: line)
        for (target, origin, row) in jumps {
            guard let targetPath = labels[target] else { XCTFail("line \(row): actual goto \(target) vs expected emitted target", file: file, line: line); continue }
            XCTAssertEqual(Array(origin.prefix(targetPath.count)), targetPath,
                "line \(row): actual goto \(target) enters another scope vs expected same/enclosing scope", file: file, line: line)
        }
        for target in labels.keys {
            XCTAssertTrue(jumps.contains { $0.0 == target }, "actual label \(target) vs expected targeted label", file: file, line: line)
        }
    }
    static func assertHeaderArity(_ document: PseudocodeDocument, headers: [String: Int],
                                  file: StaticString = #filePath, line: UInt = #line) {
        for statement in normalize(document, rows: nil, allowing: []) where statement.text.hasSuffix("// call") {
            for (target, arity) in headers {
                guard let start = statement.text.range(of: target + "(") else { continue }
                var depth = 0, commas = 0, payload = "", closed = false
                for character in statement.text[start.upperBound...] {
                    if character == ")", depth == 0 { closed = true; break }
                    if character == "(" { depth += 1 }
                    if character == ")" { depth -= 1 }
                    if character == ",", depth == 0 { commas += 1 }
                    payload.append(character)
                }
                XCTAssertTrue(closed, "row \(statement.sourceRow ?? -1): actual [\(statement.text)] vs expected closed call", file: file, line: line)
                let count = trim(payload).isEmpty ? 0 : commas + 1
                let variadic = document.callSignatures.first { $0.target == target }?.isVariadic == true
                XCTAssertTrue(variadic ? count >= arity : count == arity,
                    "row \(statement.sourceRow ?? -1): actual [\(statement.text)] has \(count) arguments vs expected \(target) \(variadic ? "minimum" : "exact") arity \(arity)", file: file, line: line)
            }
        }
    }
    static func assertVoidCalleesHaveNoResult(_ function: MacIRFunction, voidTargets: Set<String>,
                                             file: StaticString = #filePath, line: UInt = #line) {
        for (row, instruction) in function.instructions.enumerated() {
            guard case let .call(frame, result) = instruction.operation, voidTargets.contains(frame.target) else { continue }
            XCTAssertNil(result, "row \(row): actual result \(String(describing: result)) vs expected void call to \(frame.target)", file: file, line: line)
        }
    }
}
