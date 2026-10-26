import Foundation

extension MacIRBuilder {
    private struct SSAReturnProducerPoint: Hashable {
        var definition: Int
        var width: Int
        var permitsExactCompareSet: Bool
    }

    /// The instruction-only return policy consumes the already completed SSA
    /// graph. Call-result origins remain separate contract evidence.
    /// Phis grouped by destination: build once per plan, not per query.
    static func ssaPhiGroups(_ plan: MacIRSSA.Plan) -> [Int: [MacIRSSA.Phi]] {
        Dictionary(grouping: plan.phis, by: \.destination)
    }

    static func ssaReturnProducerProof(
        plan: MacIRSSA.Plan,
        sources: [MacIRSourceSpan],
        cfg: MacIRCFG,
        phiGroups suppliedPhiGroups: [Int: [MacIRSSA.Phi]]? = nil
    ) -> Bool {
        guard !sources.isEmpty, plan.rowReadBindings.count == sources.count else { return false }
        let sourceGroups = Dictionary(grouping: sources.indices, by: { sources[$0].address })
        guard sourceGroups.values.allSatisfy({ $0.count == 1 }) else { return false }
        let rowByAddress = sourceGroups.compactMapValues(\.first)
        let unreachable = Set(cfg.unreachable)
        let reachableRows = Set(cfg.blocks.filter { !unreachable.contains($0.index) }
            .flatMap { Array($0.instructionRange) })
        let returns: Set<String> = ["ret", "retaa", "retab", "retaasppc", "retabsppc", "retaasppcr", "retabsppcr"]
        let noReturnRows = Set(cfg.blocks.compactMap { block -> Int? in
            guard cfg.terminators.indices.contains(block.index),
                  case .call(_, returns: false) = cfg.terminators[block.index] else { return nil }
            return block.instructionRange.upperBound - 1
        })
        func targetAddress(_ text: String) -> UInt64? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
        }
        var work: [SSAReturnProducerPoint] = []
        for row in sources.indices where reachableRows.contains(row) {
            guard !Task.isCancelled else { return false }
            let source = sources[row]
            let mnemonic = source.mnemonic.lowercased()
            let operands = splitOperands(source.operands)
            if !returns.contains(mnemonic) {
                // The contract requires every reachable instruction and exit to
                // be covered by the retained proof, even if that row does not
                // contribute to the local RET's reaching definition. In particular,
                // a missing branch target cannot disappear from the contract when
                // the SSA graph preserves only its in-function successor.
                var successors: [UInt64] = []
                switch mnemonic {
                case "b":
                    guard operands.count == 1, let target = targetAddress(operands[0]) else { return false }
                    successors = [target]
                case "cbz", "cbnz", "tbz", "tbnz":
                    guard operands.count == (mnemonic.hasPrefix("tb") ? 3 : 2),
                          let targetText = operands.last, let target = targetAddress(targetText),
                          let next = source.address.addressAfter() else { return false }
                    successors = [target, next]
                case "bl", "blr":
                    guard operands.count == 1 else { return false }
                    if mnemonic == "bl", noReturnRows.contains(row) { continue }
                    if mnemonic == "blr" {
                        let register = operands[0].lowercased()
                        guard ["fp", "lr"].contains(register) || integerRegisterView(register) != nil else {
                            return false
                        }
                    }
                    guard let next = source.address.addressAfter() else { return false }
                    successors = [next]
                default:
                    if mnemonic.hasPrefix("b.") || mnemonic.hasPrefix("bc.") {
                        let suffix = String(mnemonic.split(separator: ".").last ?? "")
                        guard branchCondition(for: suffix) != nil, operands.count == 1,
                              let target = targetAddress(operands[0]),
                              let next = source.address.addressAfter() else { return false }
                        successors = [target, next]
                    } else {
                        guard BuilderState.returnProducerWrites(mnemonic: mnemonic, operands: operands) != nil,
                              let next = source.address.addressAfter() else { return false }
                        successors = [next]
                    }
                }
                guard successors.allSatisfy({ rowByAddress[$0] != nil }) else { return false }
                continue
            }
            guard operands.isEmpty || mnemonic == "ret" && operands.count == 1
                && ["x30", "lr"].contains(operands[0].lowercased()),
                  let definition = plan.rowReadBindings[row][0] else { return false }
            work.append(.init(definition: definition, width: 64, permitsExactCompareSet: true))
        }
        guard !work.isEmpty else { return false }
        let phiGroups = suppliedPhiGroups ?? ssaPhiGroups(plan)
        guard phiGroups.values.allSatisfy({ $0.count == 1 }) else { return false }
        let phis = phiGroups.compactMapValues(\.first)
        var seen: Set<SSAReturnProducerPoint> = []
        var kinds: Set<BuilderState.ReturnProducerKind> = []
        while var point = work.popLast() {
            guard !Task.isCancelled else { return false }
            point.definition = plan.canonicalID(point.definition)
            guard seen.insert(point).inserted else { continue }
            guard plan.definitions.indices.contains(point.definition) else { return false }
            let definition = plan.definitions[point.definition]
            switch definition.origin {
            case .entry, .callResult, .callClobber, .refusal:
                return false
            case .phi:
                guard let phi = phis[definition.id], !phi.incoming.isEmpty else { return false }
                for incoming in phi.incoming {
                    work.append(.init(definition: incoming.definition, width: point.width,
                                      permitsExactCompareSet: point.permitsExactCompareSet))
                }
            case let .instruction(address):
                guard let row = rowByAddress[address],
                      let writes = BuilderState.returnProducerWrites(
                        mnemonic: sources[row].mnemonic.lowercased(),
                        operands: splitOperands(sources[row].operands)),
                      let producer = writes[definition.cell] else { return false }
                switch producer {
                case let .constant(value):
                    kinds.insert(.constant(point.width == 32 ? value & 0xffff_ffff : value))
                case .load:
                    kinds.insert(.load)
                case .arithmetic:
                    kinds.insert(.arithmetic)
                case .compareSet:
                    kinds.insert(point.permitsExactCompareSet && definition.cell == 0 ? .exactCompareSet : .arithmetic)
                case let .copy(index, sourceWidth):
                    guard let incoming = plan.rowReadBindings[row][index] else { return false }
                    work.append(.init(definition: incoming, width: min(point.width, sourceWidth),
                                      permitsExactCompareSet: false))
                case .unknown:
                    return false
                }
            }
        }
        return BuilderState.admitsReturnProducerKinds(kinds)
    }

    /// Dataflow provenance only: this says a phi contains a real write, not
    /// that the function has a value-returning contract.
    static func ssaHasInstructionProducer(forDefinition initial: Int, plan: MacIRSSA.Plan,
                                       phiGroups suppliedPhiGroups: [Int: [MacIRSSA.Phi]]? = nil) -> Bool {
        let phis = suppliedPhiGroups ?? ssaPhiGroups(plan)
        var pending = [initial]
        var seen: Set<Int> = []
        while let raw = pending.popLast() {
            let id = plan.canonicalID(raw)
            guard seen.insert(id).inserted, plan.definitions.indices.contains(id) else { continue }
            switch plan.definitions[id].origin {
            case .instruction, .callResult:
                return true
            case .phi:
                pending.append(contentsOf: phis[id]?.first?.incoming.map(\.definition) ?? [])
            default:
                break
            }
        }
        return false
    }

    /// A phi's refusal is attached to the exact reaching definition. Cycles
    /// terminate through definition IDs; call clobbers are a distinct origin.
    static func ssaRefusalReason(forDefinition initial: Int, plan: MacIRSSA.Plan,
                                    phiGroups suppliedPhiGroups: [Int: [MacIRSSA.Phi]]? = nil) -> String? {
        let phiGroups = suppliedPhiGroups ?? ssaPhiGroups(plan)
        var pending = [initial]
        var seen: Set<Int> = []
        while let raw = pending.popLast() {
            if Task.isCancelled { return MacIRRefusal.Reason.cancelled.rawValue }
            let id = plan.canonicalID(raw)
            guard seen.insert(id).inserted, plan.definitions.indices.contains(id) else { continue }
            switch plan.definitions[id].origin {
            case let .refusal(reason, _):
                return reason.rawValue
            case .phi:
                // Reverse stack insertion preserves the persisted predecessor order.
                if let phi = phiGroups[id]?.first {
                    pending.append(contentsOf: phi.incoming.reversed().map(\.definition))
                }
            default:
                break
            }
        }
        return nil
    }
}
