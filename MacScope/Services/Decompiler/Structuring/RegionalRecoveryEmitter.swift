import Foundation

/// Text construction for an already-certified decoded-state/control pair.
/// It never renders an old scalar operation or derives semantics from text.
/// The printer supplies exact original opaque payloads and validates the final
/// token/source preservation before the candidate can replace its fallback.
struct RegionalRecoveryEmitter {
    struct Fragment {
        let text: String
        let kind: PseudocodeLineKind
        let source: MacIRSourceSpan?
    }

    struct Emission {
        let fragments: [Fragment]
        let region: PseudocodeRegionNode
        let originalFragmentOffsets: [Int: Int]
        let ownedRows: Set<Int>
    }

    static func emit(
        function: MacIRFunction, state: RegionalPhysicalStatePlan,
        control: RegionTree.RecoveryRegion, cfg: CFG, originals: [Int: PseudocodeLine],
        depth: Int, lineOffset: Int,
        valueText: @escaping (MacIRValue) -> String,
        commentSuffix: @escaping (Int) -> String,
        cancelled: @escaping () -> Bool
    ) -> Emission? {
        guard state.matches(function: function, cfg: cfg),
              state.groups.count == function.instructions.count else { return nil }
        var writer = Writer(function: function, state: state, cfg: cfg, originals: originals,
                            baseDepth: depth, lineOffset: lineOffset,
                            valueText: valueText, commentSuffix: commentSuffix,
                            cancelled: cancelled)
        for declaration in state.declarations {
            let initializer = declaration.initializer.map { " = \(valueText($0))" } ?? ""
            writer.append("\(writer.indent(depth))\(declaration.type) \(valueText(declaration.storage))\(initializer);",
                          kind: .declaration)
        }
        guard let body = writer.region(control, depth: depth), !writer.failed,
              writer.ownedRows == Set(function.instructions.indices),
              Set(writer.originalFragmentOffsets.keys) == state.boundaries.originalRows,
              !cancelled() else { return nil }
        let root = PseudocodeRegionNode(kind: .sequence, startLine: lineOffset + 1,
                                       endLine: lineOffset + writer.fragments.count, children: [body])
        return Emission(fragments: writer.fragments, region: root,
                        originalFragmentOffsets: writer.originalFragmentOffsets,
                        ownedRows: writer.ownedRows)
    }

    private struct Writer {
        let function: MacIRFunction
        let state: RegionalPhysicalStatePlan
        let cfg: CFG
        let originals: [Int: PseudocodeLine]
        let baseDepth: Int
        let lineOffset: Int
        let valueText: (MacIRValue) -> String
        let commentSuffix: (Int) -> String
        let cancelled: () -> Bool
        var fragments: [Fragment] = []
        var originalFragmentOffsets: [Int: Int] = [:]
        var ownedRows: Set<Int> = []
        var ownedBlocks: Set<Int> = []
        var breaks: [Int: String] = [:]
        var continues: [Int: String] = [:]
        var allocator = PseudocodePrinter.RecoveryLabelAllocator()
        var remainingNodes = 8192
        var failed = false

        func indent(_ depth: Int) -> String { String(repeating: "    ", count: depth + 1) }
        mutating func append(_ text: String, kind: PseudocodeLineKind = .instruction,
                             source: MacIRSourceSpan? = nil) {
            guard !failed, !cancelled(), fragments.count < 100_000 else { failed = true; return }
            fragments.append(Fragment(text: text, kind: kind, source: source))
        }
        mutating func own(_ row: Int) -> Bool {
            guard function.instructions.indices.contains(row), ownedRows.insert(row).inserted else {
                failed = true; return false
            }
            return true
        }
        mutating func label(_ prefix: String, target: Int, cfg: CFG) -> String? {
            guard cfg.blocks.indices.contains(target),
                  function.instructions.indices.contains(cfg.blocks[target].startIndex) else {
                failed = true; return nil
            }
            return allocator.label(prefix: prefix,
                                   address: function.instructions[cfg.blocks[target].startIndex].source.address)
        }
        mutating func effects(_ group: [RegionalPhysicalStatePlan.Effect], row: Int,
                              depth: Int, suffix: inout String) {
            guard depth - baseDepth <= 128 else { failed = true; return }
            let source = function.instructions[row].source
            for effect in group {
                guard !failed else { return }
                switch effect {
                case let .assign(destination, value):
                    append("\(indent(depth))\(valueText(destination)) = \(valueText(value));\(suffix)", source: source)
                    suffix = ""
                case let .load(destination, address, width):
                    guard [1, 2, 4, 8].contains(width) else { failed = true; return }
                    append("\(indent(depth))\(valueText(destination)) = *(uint\(width * 8)_t *)(\(valueText(address)));\(suffix)", source: source)
                    suffix = ""
                case let .store(value, address, width):
                    guard [1, 2, 4, 8].contains(width) else { failed = true; return }
                    append("\(indent(depth))*(uint\(width * 8)_t *)(\(valueText(address))) = \(valueText(value));\(suffix)", source: source)
                    suffix = ""
                case let .conditional(predicate, thenEffects, otherwise):
                    append("\(indent(depth))if (\(valueText(predicate))) {\(suffix)", source: source)
                    suffix = ""
                    effects(thenEffects, row: row, depth: depth + 1, suffix: &suffix)
                    append("\(indent(depth))} else {", source: source)
                    effects(otherwise, row: row, depth: depth + 1, suffix: &suffix)
                    append("\(indent(depth))}", source: source)
                case let .original(originalRow):
                    guard originalRow == row, state.boundaries.originalRows.contains(row),
                          originalFragmentOffsets[row] == nil,
                          let original = originals[row], original.source == source else {
                        failed = true; return
                    }
                    originalFragmentOffsets[row] = fragments.count
                    let text: String
                    if state.boundaries.callRows.contains(row) {
                        text = indent(depth) + String(original.text.drop(while: { $0 == " " }))
                    } else {
                        // Preserve the original exterior/terminal observation
                        // exactly, not a freshly rendered or reindented proxy.
                        text = original.text
                    }
                    append(text, kind: original.kind, source: original.source)
                }
            }
        }
        mutating func row(_ index: Int, depth: Int) {
            guard own(index), state.groups.indices.contains(index) else { failed = true; return }
            let group = state.groups[index]
            if group.isEmpty {
                guard case .intrinsic(nil, "branch", _) = function.instructions[index].operation else {
                    failed = true; return
                }
                append("\(indent(depth))// continuation edge\(commentSuffix(index))",
                       kind: .metadata, source: function.instructions[index].source)
                return
            }
            var suffix = state.boundaries.originalRows.contains(index) ? "" : commentSuffix(index)
            effects(group, row: index, depth: depth, suffix: &suffix)
        }
        private struct SwitchGroup {
            var values: [Int64]
            let exitIndex: Int
        }

        /// Retain label order separately from CFG's ordered-distinct edges.
        private func switchGroups(_ dispatch: RegionalPhysicalStatePlan.SwitchDispatch,
                                  block: BasicBlock) -> ([SwitchGroup], Int)? {
            let last = block.endIndex - 1
            guard dispatch.originalOperation == function.instructions[last].operation,
                  dispatch.successorBlocks == block.successors,
                  case let .switchDispatch(_, cases, defaultTarget) = dispatch.originalOperation,
                  !cases.isEmpty, cases.count <= 512, let defaultTarget,
                  Set(cases.map(\.value)).count == cases.count,
                  cases.allSatisfy({ $0.value >= 0 && $0.value <= Int64(UInt32.max) }) else { return nil }
            var exitByAddress: [UInt64: Int] = [:]
            for (exit, target) in block.successors.enumerated() {
                guard cfg.blocks.indices.contains(target),
                      function.instructions.indices.contains(cfg.blocks[target].startIndex),
                      exitByAddress.updateValue(exit, forKey:
                        function.instructions[cfg.blocks[target].startIndex].source.address) == nil else { return nil }
            }
            func exit(_ target: MacIRValue) -> Int? {
                CFGBuilder.address(of: target).flatMap { exitByAddress[$0] }
            }
            var groups: [SwitchGroup] = [], order: [Int] = []
            for item in cases {
                guard let target = exit(item.target) else { return nil }
                if let group = groups.firstIndex(where: { $0.exitIndex == target }) {
                    groups[group].values.append(item.value)
                } else {
                    groups.append(SwitchGroup(values: [item.value], exitIndex: target))
                    order.append(target)
                }
            }
            guard let defaultExit = exit(defaultTarget), groups.count <= 128 else { return nil }
            if !order.contains(defaultExit) { order.append(defaultExit) }
            guard order == Array(block.successors.indices) else { return nil }
            return (groups, defaultExit)
        }

        private func switchTransferOnly(_ route: RegionTree.RecoveryRegion) -> Bool {
            switch route {
            case .breakTo, .continueAt: return true
            case let .sequence(parts): return parts.isEmpty
            case .block, .scope, .loop: return false
            }
        }

        /// A repeated target repeats only this bound transfer, never its payload.
        private mutating func switchLadder(
            _ groups: [SwitchGroup], at index: Int, defaultExit: Int,
            exits: [RegionTree.RecoveryRegion], selector: MacIRValue, row: Int, depth: Int
        ) -> PseudocodeRegionNode? {
            remainingNodes -= 1
            guard remainingNodes >= 0, depth - baseDepth + index <= 128,
                  !failed, !cancelled() else { failed = true; return nil }
            let start = lineOffset + fragments.count + 1
            let source = function.instructions[row].source
            let group = groups[index]
            let predicate = group.values.map {
                "(\(valueText(selector))) == (\(valueText(.immediate($0))))"
            }.joined(separator: " || ")
            let prefix = index == 0 ? "if" : "} else if"
            let suffix = index == 0 ? commentSuffix(row) : ""
            append("\(indent(depth))\(prefix) (\(predicate)) {\(suffix)", source: source)
            var children: [PseudocodeRegionNode] = []
            if let child = region(exits[group.exitIndex], depth: depth + 1) { children.append(child) }
            if index + 1 < groups.count {
                if let child = switchLadder(groups, at: index + 1, defaultExit: defaultExit,
                    exits: exits, selector: selector, row: row, depth: depth) { children.append(child) }
            } else {
                append("\(indent(depth))} else {")
                if let child = region(exits[defaultExit], depth: depth + 1) { children.append(child) }
                append("\(indent(depth))}")
            }
            guard !failed else { return nil }
            return PseudocodeRegionNode(kind: .ifThenElse, startLine: start,
                endLine: lineOffset + fragments.count, condition: predicate,
                conditionSourceAddress: source.address, children: children)
        }

        mutating func region(_ region: RegionTree.RecoveryRegion, depth: Int) -> PseudocodeRegionNode? {
            remainingNodes -= 1
            guard !failed, remainingNodes >= 0, depth - baseDepth <= 128, !cancelled() else {
                failed = true; return nil
            }
            let start = lineOffset + fragments.count + 1
            var kind: PseudocodeRegionNode.Kind = .sequence
            var children: [PseudocodeRegionNode] = []
            var condition: String?
            let conditionAddress: UInt64? = nil
            switch region {
            case let .sequence(parts):
                for part in parts {
                    if let child = self.region(part, depth: depth) { children.append(child) }
                }
            case let .scope(target, body):
                guard breaks[target] == nil, let name = label("rgn_exit", target: target, cfg: cfg) else {
                    failed = true; return nil
                }
                breaks[target] = name
                append("\(indent(depth))\(name): {")
                if let child = self.region(body, depth: depth + 1) { children.append(child) }
                append("\(indent(depth))}")
                breaks.removeValue(forKey: target)
            case let .loop(header, body):
                guard continues[header] == nil, let name = label("rgn_loop", target: header, cfg: cfg) else {
                    failed = true; return nil
                }
                kind = .whileLoop; condition = "true"
                continues[header] = name
                append("\(indent(depth))\(name): while (true) {")
                if let child = self.region(body, depth: depth + 1) { children.append(child) }
                append("\(indent(depth))}")
                continues.removeValue(forKey: header)
            case let .breakTo(target):
                guard let name = breaks[target] else { failed = true; return nil }
                append("\(indent(depth))break \(name);")
            case let .continueAt(header):
                guard let name = continues[header] else { failed = true; return nil }
                append("\(indent(depth))continue \(name);")
            case let .block(index, exits):
                return blockRegion(index, exits: exits, depth: depth, start: start)
            }
            guard !failed, start <= lineOffset + fragments.count else { return nil }
            return PseudocodeRegionNode(kind: kind, startLine: start,
                endLine: lineOffset + fragments.count, condition: condition,
                conditionSourceAddress: conditionAddress, children: children)
        }

        // Keep block payloads and instruction temporaries out of the recursive
        // sequence/scope frame; deep recovery trees otherwise reserve them at
        // every level even when no block is being emitted.
        @inline(never)
        private mutating func blockRegion(
            _ index: Int, exits: [RegionTree.RecoveryRegion], depth: Int, start: Int
        ) -> PseudocodeRegionNode? {
            var kind: PseudocodeRegionNode.Kind = .block
            var children: [PseudocodeRegionNode] = []
            var condition: String?
            var conditionAddress: UInt64?
            guard cfg.blocks.indices.contains(index), ownedBlocks.insert(index).inserted else {
                failed = true; return nil
            }
            let block = cfg.blocks[index], last = cfg.blocks[index].endIndex - 1
            guard !block.instructionRange.isEmpty,
                  exits.count == block.successors.count else { failed = true; return nil }
            if let dispatch = state.switches[last] {
                guard let (groups, defaultExit) = switchGroups(dispatch, block: block),
                      exits.allSatisfy(switchTransferOnly) else { failed = true; return nil }
                for index in block.instructionRange.dropLast() { row(index, depth: depth) }
                guard own(last), state.groups[last].isEmpty else { failed = true; return nil }
                if let child = switchLadder(groups, at: 0, defaultExit: defaultExit,
                    exits: exits, selector: dispatch.selector, row: last, depth: depth) {
                    children.append(child)
                }
            } else if exits.count == 2 {
                for index in block.instructionRange.dropLast() { row(index, depth: depth) }
                guard own(last), state.groups[last].isEmpty,
                      let branch = state.branchConditions[last], branch.branchIndex == last,
                      branch.compareIndex == nil, branch.continuationGotoTargets.isEmpty else {
                    failed = true; return nil
                }
                let text = "(\(valueText(branch.left))) \(branch.condition) (\(valueText(branch.right)))"
                kind = .ifThenElse; condition = text
                conditionAddress = function.instructions[last].source.address
                append("\(indent(depth))if (\(text)) {\(commentSuffix(last))",
                       source: function.instructions[last].source)
                if let child = self.region(exits[0], depth: depth + 1) { children.append(child) }
                append("\(indent(depth))} else {")
                if let child = self.region(exits[1], depth: depth + 1) { children.append(child) }
                append("\(indent(depth))}")
            } else {
                for index in block.instructionRange { row(index, depth: depth) }
                if let exit = exits.first, let child = self.region(exit, depth: depth) { children.append(child) }
            }
            guard !failed, start <= lineOffset + fragments.count else { return nil }
            return PseudocodeRegionNode(kind: kind, startLine: start,
                endLine: lineOffset + fragments.count, condition: condition,
                conditionSourceAddress: conditionAddress, children: children)
        }
    }
}
