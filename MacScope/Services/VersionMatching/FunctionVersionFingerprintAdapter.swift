import Foundation

/// Thin projection from one image's `ImageAnalysis` to matcher input.
///
/// Every fact is derived only from evidence the analysis already holds. Where ownership or a
/// reference target is not provable (overlapping function ranges, a call to a non-function
/// address, a string reference without a literal) the corresponding fingerprint is nil rather
/// than partial, so the matcher can never compare an incomplete fact as if it were complete.
enum FunctionVersionFingerprintAdapter {
    static func fingerprints(from analysis: ImageAnalysis) -> [FunctionVersionFingerprint] {
        let functions = analysis.functions.sorted {
            if $0.startAddress != $1.startAddress { return $0.startAddress < $1.startAddress }
            if $0.endAddress != $1.endAddress { return $0.endAddress < $1.endAddress }
            return $0.id.uuidString < $1.id.uuidString
        }
        let instructions = analysis.instructions.sorted {
            if $0.address != $1.address { return $0.address < $1.address }
            if $0.mnemonic != $1.mnemonic { return $0.mnemonic < $1.mnemonic }
            return $0.operands < $1.operands
        }
        let exclusive = exclusiveFunctionIndices(functions)
        let owners = ExclusiveRangeIndex(ranges: functions.indices.compactMap { index in
            exclusive.contains(index) ? (functions[index].startAddress, functions[index].endAddress, index) : nil
        })

        // A call target is an in-image function only when exactly one function starts there.
        let functionStarts = Dictionary(grouping: functions.indices, by: { functions[$0].startAddress })
        let importNames = importNamesByAddress(analysis)
        var stringValues: [UInt64: Set<String>] = [:]
        for literal in analysis.stringLiterals { stringValues[literal.address, default: []].insert(literal.value) }

        var calleeIDs: [Int: [String]] = [:]
        var importedCallees: [Int: [String]] = [:]
        var strings: [Int: [String]] = [:]
        var unprovableCalls: Set<Int> = []
        var unprovableStrings: Set<Int> = []
        for xref in analysis.xrefs {
            guard let owner = owners.owner(at: xref.from) else { continue }
            switch xref.kind {
            case XRefKind.call:
                if let starts = functionStarts[xref.to], starts.count == 1 {
                    calleeIDs[owner, default: []].append(functions[starts[0]].id.uuidString)
                } else if functionStarts[xref.to] == nil, let name = importNames[xref.to] {
                    importedCallees[owner, default: []].append(name)
                } else {
                    unprovableCalls.insert(owner)
                }
            case XRefKind.string:
                if let values = stringValues[xref.to], values.count == 1, let value = values.first {
                    strings[owner, default: []].append(value)
                } else {
                    unprovableStrings.insert(owner)
                }
            default:
                continue
            }
        }

        let blocksByFunction = Dictionary(grouping: analysis.basicBlocks, by: \.functionID)
        var edgesByOwner: [Int: [ControlFlowEdge]] = [:]
        for edge in analysis.controlFlowEdges where edge.kind != "call" {
            guard let owner = owners.owner(at: edge.from) else { continue }
            edgesByOwner[owner, default: []].append(edge)
        }

        return functions.indices.map { index in
            let function = functions[index]
            let size = function.endAddress >= function.startAddress ? function.endAddress - function.startAddress : 0
            let name = FunctionVersionFingerprinting.isGeneratedName(function.name) ? nil : function.name
            guard exclusive.contains(index) else {
                return FunctionVersionFingerprint(id: function.id.uuidString, address: function.startAddress,
                                                  symbolName: name, size: size)
            }
            let body = bodyFacts(instructions, start: function.startAddress, end: function.endAddress)
            let cfg = controlFlowFacts(
                blocks: blocksByFunction[function.id] ?? [], edges: edgesByOwner[index] ?? [],
                start: function.startAddress, end: function.endAddress)
            let callFactsKnown = !unprovableCalls.contains(index)
            return FunctionVersionFingerprint(
                id: function.id.uuidString,
                address: function.startAddress,
                symbolName: name,
                size: size,
                basicBlockCount: cfg?.blockCount,
                edgeCount: cfg?.edgeCount,
                cfgShapeHash: cfg?.shapeHash,
                normalizedBodyHash: body?.hash,
                semanticBodyHash: body?.semanticHash,
                instructionCount: body?.count,
                calleeIDs: callFactsKnown ? calleeIDs[index] ?? [] : nil,
                importedCalleeNames: callFactsKnown ? importedCallees[index] ?? [] : nil,
                stringReferences: unprovableStrings.contains(index) ? nil : strings[index] ?? [])
        }
    }

    // MARK: - Per-function facts

    private static func bodyFacts(_ instructions: [InstructionRow], start: UInt64, end: UInt64) -> (hash: String, semanticHash: String, count: Int)? {
        let lower = lowerBound(instructions, start)
        let upper = lowerBound(instructions, end)
        guard lower < upper else { return nil }
        let lines = instructions[lower..<upper].map {
            FunctionVersionFingerprinting.normalizedInstruction(mnemonic: $0.mnemonic, operands: $0.operands)
        }
        let semanticLines = instructions[lower..<upper].map {
            FunctionVersionFingerprinting.semanticInstruction(mnemonic: $0.mnemonic, operands: $0.operands)
        }
        return (FunctionVersionFingerprinting.stableDigest(lines), FunctionVersionFingerprinting.stableDigest(semanticLines), lines.count)
    }

    /// Address-independent topology: blocks are numbered in address order; each edge is rendered
    /// as source index → target index (or `x` for a target outside the function) plus its kind.
    private static func controlFlowFacts(
        blocks: [BasicBlockSummary],
        edges: [ControlFlowEdge],
        start: UInt64,
        end: UInt64
    ) -> (blockCount: Int, edgeCount: Int, shapeHash: String)? {
        let ordered = blocks.filter { $0.startAddress >= start && $0.endAddress <= end && $0.startAddress < $0.endAddress }
            .sorted {
                if $0.startAddress != $1.startAddress { return $0.startAddress < $1.startAddress }
                return $0.endAddress < $1.endAddress
            }
        guard !ordered.isEmpty, ordered.count == blocks.count else { return nil }
        for index in ordered.indices.dropFirst() where ordered[index].startAddress < ordered[index - 1].endAddress {
            return nil   // overlapping blocks: block identity is not provable
        }
        func blockIndex(containing address: UInt64) -> Int? {
            var low = 0
            var high = ordered.count
            while low < high {
                let middle = low + (high - low) / 2
                if ordered[middle].startAddress <= address { low = middle + 1 } else { high = middle }
            }
            guard low > 0, address < ordered[low - 1].endAddress else { return nil }
            return low - 1
        }
        var rendered: [String] = []
        var internalEdges = 0
        for edge in edges {
            guard let source = blockIndex(containing: edge.from) else { return nil }
            if let target = blockIndex(containing: edge.to) {
                rendered.append("\(source)>\(target):\(edge.kind)")
                internalEdges += 1
            } else {
                rendered.append("\(source)>x:\(edge.kind)")
            }
        }
        let lines = ["blocks=\(ordered.count)"] + rendered.sorted()
        return (ordered.count, internalEdges, FunctionVersionFingerprinting.stableDigest(lines))
    }

    // MARK: - Ownership and imports

    /// Indices of functions with a non-empty range that overlaps no other function.
    private static func exclusiveFunctionIndices(_ functions: [FunctionSummary]) -> Set<Int> {
        var result: Set<Int> = []
        var maxPrecedingEnd: UInt64 = 0
        for index in functions.indices {
            let function = functions[index]
            let overlapsPrevious = index > 0 && maxPrecedingEnd > function.startAddress
            let overlapsNext = index + 1 < functions.count && functions[index + 1].startAddress < function.endAddress
            if function.endAddress > function.startAddress, !overlapsPrevious, !overlapsNext {
                result.insert(index)
            }
            maxPrecedingEnd = max(maxPrecedingEnd, function.endAddress)
        }
        return result
    }

    /// Loader-resolved linkage slots and derived stub symbols that name exactly one import.
    private static func importNamesByAddress(_ analysis: ImageAnalysis) -> [UInt64: String] {
        var candidates: [UInt64: Set<String>] = [:]
        for entry in analysis.indirectSymbols {
            let section = entry.sourceSection.split(separator: ",").last.map(String.init) ?? ""
            guard StubCallSymbolicator.linkageSections.contains(section),
                  !entry.isLocal, !entry.isAbsolute,
                  let name = entry.symbolName, !name.isEmpty else { continue }
            candidates[entry.address, default: []].insert(name)
        }
        for symbol in analysis.symbols where symbol.kind == "stub" {
            guard let address = symbol.address, !symbol.name.isEmpty else { continue }
            candidates[address, default: []].insert(symbol.name)
        }
        return candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    private static func lowerBound(_ instructions: [InstructionRow], _ address: UInt64) -> Int {
        var low = 0
        var high = instructions.count
        while low < high {
            let middle = low + (high - low) / 2
            if instructions[middle].address < address { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// Owner lookup over ranges already known not to overlap.
private struct ExclusiveRangeIndex {
    private let ranges: [(start: UInt64, end: UInt64, owner: Int)]

    init(ranges: [(UInt64, UInt64, Int)]) {
        self.ranges = ranges.map { (start: $0.0, end: $0.1, owner: $0.2) }.sorted { $0.start < $1.start }
    }

    func owner(at address: UInt64) -> Int? {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = low + (high - low) / 2
            if ranges[middle].start <= address { low = middle + 1 } else { high = middle }
        }
        guard low > 0, address < ranges[low - 1].end else { return nil }
        return ranges[low - 1].owner
    }
}
