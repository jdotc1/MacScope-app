import Foundation

/// Where an analysis-recovered no-return fact came from (HOP-1). Distinct from a user
/// `FunctionSignatureOverride.noReturnState`, which always wins over these.
enum AnalysisNoReturnProvenance: String, Codable, Hashable, Sendable {
    /// The function itself carries a `NoReturnCatalog` name (e.g. a statically linked `_abort`).
    case catalog
    /// The function itself carries a name the shipped SDK signature pack (HOP-5) marks
    /// `noReturn` and `NoReturnCatalog` does not list. The catalog keeps precedence.
    case sdkPack
    /// Every reachable exit of the function halts: a trap, or a call/tail call to a
    /// no-return target. Derived by fixed-point propagation over the discovered functions.
    case propagated
}

/// HOP-1: no-return knowledge for function discovery. Pure and image-local.
enum NoReturnAnalysis {
    static let maximumPropagationRounds = 64

    /// Addresses whose symbol, or whose import stub / GOT slot, names a `NoReturnCatalog`
    /// entry. Only header-confirmed entries are used: a false no-return deletes a real
    /// fall-through edge, so the extended-reference-only names stay out of discovery.
    static func catalogTargets(
        symbols: [SymbolSummary],
        stubNamesByAddress: [UInt64: String]
    ) -> Set<UInt64> {
        var targets = Set<UInt64>()
        for symbol in symbols {
            guard let address = symbol.address else { continue }
            let name = symbol.rawLinkageName ?? symbol.name
            if NoReturnCatalog.isNoReturn(name, includingExtendedReference: false) {
                targets.insert(address)
            }
        }
        for (address, name) in stubNamesByAddress
        where NoReturnCatalog.isNoReturn(name, includingExtendedReference: false) {
            targets.insert(address)
        }
        return targets
    }

    /// Addresses whose symbol, or whose import stub / GOT slot, names a `noReturn` entry of the
    /// shipped SDK pack (`noReturnNames` are `NoReturnCatalog.canonicalName` keys). Callers
    /// subtract `catalogTargets` so the catalog's provenance wins where both know a name.
    static func sdkPackTargets(
        symbols: [SymbolSummary],
        stubNamesByAddress: [UInt64: String],
        noReturnNames: Set<String> = CallSignaturePack.bundledNoReturnCanonicalNames
    ) -> Set<UInt64> {
        guard !noReturnNames.isEmpty else { return [] }
        var targets = Set<UInt64>()
        for symbol in symbols {
            guard let address = symbol.address else { continue }
            if noReturnNames.contains(NoReturnCatalog.canonicalName(for: symbol.rawLinkageName ?? symbol.name)) {
                targets.insert(address)
            }
        }
        for (address, name) in stubNamesByAddress
        where noReturnNames.contains(NoReturnCatalog.canonicalName(for: name)) {
            targets.insert(address)
        }
        return targets
    }

    /// True when `instruction` is a direct call whose target never returns.
    static func isNoReturnCall(_ instruction: DecodedInstruction, targets: Set<UInt64>) -> Bool {
        guard !targets.isEmpty, instruction.flow == .call, let target = instruction.branchTarget else {
            return false
        }
        return targets.contains(target)
    }

    /// Fixed point: a function whose every reachable exit halts becomes a no-return target,
    /// which can in turn make its callers no-return. `instructions` must be sorted ascending
    /// by address. Returns the starts of the functions derived no-return (excluding `known`).
    static func propagate(
        functions: [FunctionSummary],
        instructions: [DecodedInstruction],
        known: Set<UInt64>
    ) -> Set<UInt64> {
        guard !functions.isEmpty, !instructions.isEmpty else { return [] }
        var indexByAddress: [UInt64: Int] = [:]
        indexByAddress.reserveCapacity(instructions.count)
        for (index, instruction) in instructions.enumerated() where indexByAddress[instruction.address] == nil {
            indexByAddress[instruction.address] = index
        }
        var noReturn = known
        var derived = Set<UInt64>()
        var changed = true
        var rounds = 0
        // Each productive round adds at least one function; real no-return chains are short, so
        // a fixed cap keeps a pathological binary linear instead of quadratic.
        while changed && rounds < min(functions.count + 1, maximumPropagationRounds) {
            changed = false
            rounds += 1
            for function in functions where !noReturn.contains(function.startAddress) {
                if everyExitHalts(function, instructions: instructions,
                                  indexByAddress: indexByAddress, noReturn: noReturn) {
                    noReturn.insert(function.startAddress)
                    derived.insert(function.startAddress)
                    changed = true
                }
            }
        }
        return derived
    }

    /// Walks the function's intra-procedural successors from its entry. Any path that can
    /// return (a `ret`, an indirect jump, a branch or fall-through leaving the function to a
    /// target not known to halt, or an undecoded gap) makes it returning. At least one
    /// halting instruction must be reachable, so a bare infinite loop is not promoted.
    static func everyExitHalts(
        _ function: FunctionSummary,
        instructions: [DecodedInstruction],
        indexByAddress: [UInt64: Int],
        noReturn: Set<UInt64>
    ) -> Bool {
        let start = function.startAddress
        let end = function.endAddress
        guard end > start, let entry = indexByAddress[start] else { return false }
        var visited = Set<Int>()
        var worklist = [entry]
        var sawHalt = false

        func inside(_ address: UInt64) -> Bool { address >= start && address < end }

        func followFallThrough(from index: Int) -> Bool {
            let instruction = instructions[index]
            let next = index + 1
            guard next < instructions.count,
                  AnalysisEngine.isPhysicallyAdjacent(instruction, instructions[next].address),
                  inside(instructions[next].address) else { return false }
            worklist.append(next)
            return true
        }

        func followBranch(to target: UInt64) -> Bool {
            if inside(target) {
                guard let index = indexByAddress[target] else { return false }
                worklist.append(index)
                return true
            }
            // A tail branch out of the function halts only when its target does.
            if noReturn.contains(target) { sawHalt = true; return true }
            return false
        }

        while let index = worklist.popLast() {
            guard visited.insert(index).inserted else { continue }
            let instruction = instructions[index]
            switch instruction.flow {
            case .trap:
                sawHalt = true
            case .return, .indirectJump:
                return false
            case .jump:
                guard let target = instruction.branchTarget, followBranch(to: target) else { return false }
            case .conditionalJump:
                guard let target = instruction.branchTarget, followBranch(to: target) else { return false }
                guard followFallThrough(from: index) else { return false }
            case .call:
                if isNoReturnCall(instruction, targets: noReturn) {
                    sawHalt = true
                } else if !followFallThrough(from: index) {
                    return false
                }
            case .normal, .indirectCall:
                guard followFallThrough(from: index) else { return false }
            }
        }
        return sawHalt
    }
}
