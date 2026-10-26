import Foundation
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Opt-in scalar57 AST/source-slot classification. This is a topology prerequisite,
/// not a numerical or alias-safety certificate. It never reads a production plan.
/// Entry5's initialized transport prelude belongs to its separate exact oracle.
enum NativeScalarSourceAnchors {
    typealias C = OrdinaryC
    typealias L = OrdinaryCSourceEdgeLedger
    enum Kind: Equatable { case scalarDefinition, load, store, writeback, condition, terminal }
    struct Operation: Equatable {
        let row: Int
        let ordinal: Int
        let kind: Kind
    }
    struct Certificate {
        let candidate: C.Program
        let inventory: NativeScalarSourceOwnership.Inventory
        let operations: [Int: Operation]
        let administrativeCopies: Set<Int>
        var anchorRows: [Int: Int] { operations.mapValues(\.row) }
        // No caller can manufacture a PC map or substitute another parsed program.
        fileprivate init(candidate: C.Program, inventory: NativeScalarSourceOwnership.Inventory,
                         operations: [Int: Operation], administrativeCopies: Set<Int>) {
            self.candidate = candidate; self.inventory = inventory
            self.operations = operations; self.administrativeCopies = administrativeCopies
        }
    }

    static func make(candidate: C.Program, inventory: NativeScalarSourceOwnership.Inventory) throws -> Certificate {
        let source = inventory.source
        guard candidate.contract.rowsByAddress.count == source.rows.count,
              source.rows.enumerated().allSatisfy({ candidate.contract.rowsByAddress[$0.element.address] == $0.offset }) else {
            throw C.Failure.invalidContract("source-slot classifier has a different complete source identity")
        }
        var assignments: [Int: [Int]] = [:], conditions: [Int: [Int]] = [:], terminals: [Int: [Int]] = [:]
        for (pc, instruction) in candidate.code.enumerated() {
            switch instruction.node {
            case .assign:
                let row = try candidate.row(at: instruction.span)
                guard inventory.reachableRows.contains(row) else { throw C.Failure.invalidContract("effect attributed to unreachable source row") }
                assignments[row, default: []].append(pc)
            case let .branch(expression, _, _):
                // A literal while(1) is only grammar scaffolding, never a source
                // branch or a witness for a loop. Its actual jumps stay in routes.
                if closed(expression) { continue }
                let row = try candidate.row(at: expression.span)
                guard inventory.reachableRows.contains(row), NativeScalarSourceOwnership.conditional(source.rows[row].mnemonic) else {
                    throw C.Failure.invalidContract("nonliteral candidate predicate has no original conditional row")
                }
                try pure(expression)
                conditions[row, default: []].append(pc)
            case .returned, .unavailableReturn:
                let row = try candidate.row(at: instruction.span)
                guard source.returns.contains(row), inventory.reachableRows.contains(row) else {
                    throw C.Failure.invalidContract("candidate terminal is not the reachable original terminal")
                }
                terminals[row, default: []].append(pc)
            case let .declaration(_, initial):
                guard initial == nil, (try? candidate.row(at: instruction.span)) == nil else {
                    throw C.Failure.invalidContract("scalar57 topology refuses initialized or source-tagged declarations; entry transport needs its exact oracle")
                }
            case .nop, .jump: break
            case .call, .update, .unresolved:
                throw C.Failure.invalidContract("unsupported effect in scalar57 ownership slice")
            }
        }
        var operations: [Int: Operation] = [:], copies: Set<Int> = []
        for row in inventory.reachableRows.sorted() {
            let original = source.rows[row], mnemonic = original.mnemonic
            let pcs = assignments[row, default: []]
            var kinds: [Kind] = []
            if let memory = inventory.memoryEffects[row] {
                kinds = memory.map { $0.loading ? .load : .store }
                let operands = original.structuredOperands?.operands ?? []
                for operand in operands {
                    if case let .memory(memory) = operand, memory.indexing == .preIndex {
                        throw C.Failure.invalidContract("pre-index timing requires a separate source-slot proof")
                    }
                }
                let writeback = operands.contains { operand in
                    if case let .memory(memory) = operand { return memory.writeback }; return false
                }
                if writeback { kinds.append(.writeback) }
            } else if ["mov", "add", "sub", "subs", "sxtw", "lsl", "lsr"].contains(mnemonic) {
                kinds = [.scalarDefinition]
            } else if mnemonic != "cmp" && mnemonic != "nop" && mnemonic != "b" && mnemonic != "ret" && !NativeScalarSourceOwnership.conditional(mnemonic) {
                throw C.Failure.invalidContract("source row has no bounded semantic-slot classification")
            }
            guard pcs.count >= kinds.count else { throw C.Failure.invalidContract("missing original semantic write/effect at row \(row)") }
            for (ordinal, kind) in kinds.enumerated() {
                let pc = pcs[ordinal]
                try semantic(candidate.code[pc], kind: kind, mnemonic: mnemonic, row: row, ordinal: ordinal, candidate: candidate)
                operations[pc] = .init(row: row, ordinal: ordinal, kind: kind)
            }
            for pc in pcs.dropFirst(kinds.count) {
                guard let block = source.blockAtRow[row], source.blocks[block].rows.upperBound - 1 == row else {
                    throw C.Failure.invalidContract("extra assignment is not at the final original predecessor row")
                }
                let edges = source.outgoing[block, default: []]
                let branchOnly = mnemonic == "b" || NativeScalarSourceOwnership.conditional(mnemonic)
                let separatedFallthrough = edges.count == 1 && edges.first?.role == .fallthrough && !kinds.isEmpty &&
                    pcs.prefix(kinds.count).allSatisfy { !transportShape(candidate.code[$0], candidate: candidate) }
                guard branchOnly || separatedFallthrough else {
                    throw C.Failure.invalidContract("payload/copy partition is ambiguous or lacks one exact fallthrough edge")
                }
                try transport(candidate.code[pc], candidate: candidate)
                if case let .assign(_, right) = candidate.code[pc].node,
                   case .cast = right[0].node,
                   cyclic(block, source: source) {
                    throw C.Failure.invalidContract("signed ABI representation transport is not on an acyclic entry edge")
                }
                copies.insert(pc)
            }
            let branchPCs = conditions[row, default: []]
            if NativeScalarSourceOwnership.conditional(mnemonic) {
                guard branchPCs.count == 1 else { throw C.Failure.invalidContract("original conditional row does not own exactly one actual predicate") }
                operations[branchPCs[0]] = .init(row: row, ordinal: 0, kind: .condition)
            } else if !branchPCs.isEmpty { throw C.Failure.invalidContract("predicate appears at nonconditional original row") }
            let terminalPCs = terminals[row, default: []]
            if mnemonic == "ret" {
                guard terminalPCs.count == 1 else { throw C.Failure.invalidContract("original terminal does not own exactly one actual return") }
                operations[terminalPCs[0]] = .init(row: row, ordinal: 0, kind: .terminal)
            } else if !terminalPCs.isEmpty { throw C.Failure.invalidContract("terminal appears at a nonterminal original row") }
        }
        // Exact source-effect order is independently fixed by the immutable row,
        // not by LHS spelling or a product DefinitionID. Every extra assignment
        // is a pure same-type transport or an explicit same-width signed-ABI
        // representation conversion, and remains in actual route execution.
        return .init(candidate: candidate, inventory: inventory, operations: operations, administrativeCopies: copies)
    }

    /// A syntactically plausible copy is not ignored until complete routes place
    /// it after the exact original branch decision on one unique outgoing edge.
    /// Every source payload slot must occur, in order, on every route of its block.
    static func requireRoutes(_ report: L.Report, certificate: Certificate) throws {
        try report.requireCompleteTopology()
        let candidate = certificate.candidate, source = certificate.inventory.source
        var expected: [Int: [Operation]] = [:]
        for operation in certificate.operations.values {
            guard let block = source.blockAtRow[operation.row] else { throw C.Failure.invalidContract("lost original source-slot block") }
            expected[block, default: []].append(operation)
        }
        for block in expected.keys {
            expected[block]!.sort { $0.row == $1.row ? $0.ordinal < $1.ordinal : $0.row < $1.row }
        }
        var representedPCs: Set<Int> = []
        for route in report.routes {
            let pcs = route.executedPCs.filter { certificate.operations[$0] != nil }
            let operations = pcs.compactMap { certificate.operations[$0] }
            guard operations == expected[route.fromBlock, default: []] else {
                throw C.Failure.invalidContract("actual outgoing route omits, repeats or reorders original source slots in block \(route.fromBlock)")
            }
            representedPCs.formUnion(pcs)
        }
        for (pc, operation) in certificate.operations where operation.kind == .terminal {
            guard let block = source.blockAtRow[operation.row], source.outgoing[block, default: []].isEmpty,
                  expected[block] == [operation], report.entries[block] == [pc] else {
                throw C.Failure.invalidContract("terminal-only block is not entered at its unique original RET slot")
            }
            representedPCs.insert(pc)
        }
        guard representedPCs == Set(certificate.operations.keys) else {
            throw C.Failure.invalidContract("original source slot has no complete mapped candidate route")
        }
        for pc in certificate.administrativeCopies {
            let row = try candidate.row(at: candidate.code[pc].span)
            guard let block = source.blockAtRow[row] else { throw C.Failure.invalidContract("lost administrative-copy source predecessor") }
            let routes = report.routes.filter { $0.executedPCs.contains(pc) }
            guard !routes.isEmpty else { throw C.Failure.invalidContract("unreachable or unmapped administrative copy") }
            var edges: Set<C.SourceEdge> = []
            for route in routes {
                let owned = route.origins.filter { $0.edge.fromBlock == block && $0.row == row }
                guard owned.count == 1, let edge = owned.first?.edge else {
                    throw C.Failure.invalidContract("administrative copy has no exact predecessor-edge slot")
                }
                edges.insert(edge)
                if NativeScalarSourceOwnership.conditional(source.rows[row].mnemonic) {
                    guard let branch = route.executedPCs.firstIndex(where: { certificate.operations[$0]?.row == row && certificate.operations[$0]?.kind == .condition }),
                          let copy = route.executedPCs.firstIndex(of: pc), branch < copy else {
                        throw C.Failure.invalidContract("edge copy executes before its original branch decision")
                    }
                }
                else if source.rows[row].mnemonic != "b" {
                    guard let lastPayload = route.executedPCs.lastIndex(where: { certificate.operations[$0]?.row == row }),
                          let copy = route.executedPCs.firstIndex(of: pc), lastPayload < copy else {
                        throw C.Failure.invalidContract("fallthrough copy precedes a required original payload slot")
                    }
                }
            }
            guard edges.count == 1 else { throw C.Failure.invalidContract("administrative copy is not owned by one exact original edge") }
        }
    }

    private static func semantic(_ instruction: C.Instruction, kind: Kind, mnemonic: String,
                                 row: Int, ordinal: Int, candidate: C.Program) throws {
        guard case let .assign(left, right) = instruction.node, left.count == 1, right.count == 1 else {
            throw C.Failure.invalidContract("source semantic slot requires one ordinary C assignment")
        }
        try pure(left[0])
        let sites = candidate.memorySites.filter { contains(instruction.span, $0.key) }
        if mnemonic == "sxtw", kind == .scalarDefinition {
            guard case let .name(destination) = left[0].node, sites.isEmpty,
                  candidate.symbols[destination]?.type == .u64,
                  signedExtension(right[0], candidate: candidate) else { throw shape(row) }
            return
        }
        try pure(right[0])
        switch kind {
        case .load:
            guard case .name = left[0].node, case .load = stripped(right[0]).node,
                  sites.count == 1, sites.first?.value == C.SourceSite(row: row, effectOrdinal: ordinal) else {
                throw C.Failure.invalidContract("original ordered load is not one actual memory assignment")
            }
        case .store:
            guard case .load = left[0].node, sites.count == 1,
                  sites.first?.value == C.SourceSite(row: row, effectOrdinal: ordinal) else {
                throw C.Failure.invalidContract("original ordered store is not one actual memory assignment")
            }
        case .scalarDefinition, .writeback:
            guard case .name = left[0].node, sites.isEmpty else { throw C.Failure.invalidContract("scalar source write contains a memory effect") }
            let expression = stripped(right[0])
            if kind == .writeback {
                guard case .binary("+", _, _) = expression.node else { throw C.Failure.invalidContract("writeback slot is not explicit pointer addition") }
            } else {
                switch mnemonic {
                case "add": guard case .binary("+", _, _) = expression.node else { throw shape(row) }
                case "sub", "subs": guard case .binary("-", _, _) = expression.node else { throw shape(row) }
                case "lsl": guard case .binary("<<", _, _) = expression.node else { throw shape(row) }
                case "lsr": guard case .binary(">>", _, _) = expression.node else { throw shape(row) }
                case "mov", "sxtw":
                    switch expression.node { case .name, .literal: break; default: throw shape(row) }
                default: throw shape(row)
                }
            }
        case .condition, .terminal: throw C.Failure.invalidContract("nonassignment source kind passed to assignment classifier")
        }
    }
    /// Exact unsigned32-to-unsigned64 sign extension. No general ternary
    /// admission: all three low-word uses must be the identical typed projection.
    private static func signedExtension(_ expression: C.Expression, candidate: C.Program) -> Bool {
        guard candidate.expressionTypes[expression.span] == .u64,
              case let .select(condition, positive, negative) = expression.node,
              case let .binary("==", tested, zero) = condition.node, literal(zero, equals: 0),
              case let .binary("&", low, sign) = tested.node,
              case let .cast(signType, signValue) = sign.node, signType == .u32, literal(signValue, equals: 0x8000_0000),
              case let .cast(positiveType, positiveLow) = positive.node, positiveType == .u64,
              case let .binary("|", negativeLow, highMask) = negative.node,
              case let .cast(negativeType, negativeProjection) = negativeLow.node, negativeType == .u64,
              case let .unary("~", mask) = highMask.node,
              case let .cast(maskType, maskValue) = mask.node, maskType == .u64, literal(maskValue, equals: 0xffff_ffff),
              let key = lowProjection(low, candidate: candidate),
              lowProjection(positiveLow, candidate: candidate) == key,
              lowProjection(negativeProjection, candidate: candidate) == key else { return false }
        return true
    }
    private static func literal(_ expression: C.Expression, equals bits: UInt64) -> Bool {
        if case let .literal(value) = expression.node { return value.bits == bits }; return false
    }
    private static func lowProjection(_ expression: C.Expression, candidate: C.Program) -> String? {
        guard candidate.expressionTypes[expression.span] == .u32 else { return nil }
        switch expression.node {
        case let .name(name): return "u32-name:" + name
        case let .cast(type, value) where type == .u32:
            guard case let .name(name) = value.node else { return nil }
            return "u32-cast:" + name
        default: return nil
        }
    }
    private static func shape(_ row: Int) -> C.Failure { .invalidContract("scalar operation shape differs at original row \(row)") }
    private static func transport(_ instruction: C.Instruction, candidate: C.Program) throws {
        guard transportShape(instruction, candidate: candidate) else {
            throw C.Failure.invalidContract("administrative edge operation is not one pure exact-type name transport")
        }
    }
    private static func transportShape(_ instruction: C.Instruction, candidate: C.Program) -> Bool {
        guard case let .assign(left, right) = instruction.node, left.count == 1, right.count == 1,
              case let .name(destination) = left[0].node,
              let destinationType = candidate.symbols[destination]?.type,
              !candidate.protectedNames.contains(destination) else { return false }
        if case let .name(source) = right[0].node {
            return candidate.symbols[source]?.type == destinationType
        }
        // The real scalar entry edges initialize unsigned carriers from signed
        // ABI formals. This one explicit equal-width conversion preserves their
        // complete representation by C's modulo conversion rule. It is not a
        // general cast-stripping rule: local values, nested casts, arithmetic,
        // pointers and width changes remain outside this transport certificate.
        guard case let .cast(type, child) = right[0].node,
              case let .name(source) = child.node,
              let symbol = candidate.symbols[source], symbol.external,
              !symbol.type.pointer, !symbol.type.unsigned,
              !type.pointer, type.unsigned, type == destinationType,
              [32, 64].contains(type.width), type.width == symbol.type.width else { return false }
        return true
    }
    private static func cyclic(_ block: Int, source: L.Source) -> Bool {
        var work = source.outgoing[block, default: []].map { $0.edge.toBlock }
        var seen: Set<Int> = []
        while let next = work.popLast() {
            if next == block { return true }
            if seen.insert(next).inserted {
                work.append(contentsOf: source.outgoing[next, default: []].map { $0.edge.toBlock })
            }
        }
        return false
    }
    private static func stripped(_ expression: C.Expression) -> C.Expression {
        if case let .cast(_, child) = expression.node { return stripped(child) }; return expression
    }
    private static func closed(_ expression: C.Expression) -> Bool {
        switch expression.node {
        case .literal: return true
        case let .cast(_, child), let .unary("!", child): return closed(child)
        default: return false
        }
    }
    private static func pure(_ expression: C.Expression) throws {
        switch expression.node {
        case .name, .literal: break
        case let .cast(_, child), let .unary(_, child), let .load(_, child): try pure(child)
        case let .binary(_, left, right): try pure(left); try pure(right)
        case .select, .field, .helper, .update:
            throw C.Failure.invalidContract("expression has effects or syntax outside the source-slot slice")
        }
    }
    private static func contains(_ outer: C.Span, _ inner: C.Span) -> Bool { outer.first <= inner.first && outer.last >= inner.last }
}
