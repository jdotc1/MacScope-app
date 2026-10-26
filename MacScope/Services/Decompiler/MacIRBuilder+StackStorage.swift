import Foundation

extension MacIRBuilder {
    /// DP04 B2 (slice 2): give each recovered local the B1/B2 storage region and
    /// lifetime identity it occupies. Only an exact match attaches: the local's
    /// defining row must hold a frame access with the local's exact entry-SP extent,
    /// and the region must have exactly one lifetime. Lowering and the offset APIs are
    /// unchanged; anything unproven keeps `stackStorage == nil`.
    static func attachingStackStorage<Row: DecompilerInstructionRow>(to function: MacIRFunction,
                                                                     rows: [Row]) -> MacIRFunction {
        guard function.localVariables.contains(where: { $0.definingAddress != nil }) else { return function }
        let frame = MacIRFrameAnalysis.analyze(rows: rows, instructions: function.instructions)
        let analysis = MacIRStackRegionAnalysis.analyze(functionStart: function.startAddress, rows: rows,
                                                        instructions: function.instructions, frame: frame)
        guard analysis.isComplete else { return function }
        let accessesByAddress = Dictionary(grouping: frame.accesses, by: \.address)
        // Each promoted local remembers its exact memory-transfer element.
        // The set of newly defined locals can omit an already-promoted pair
        // element, so its minimum cannot establish a coordinate translation.
        var function = function
        function.localVariables = function.localVariables.map { local in
            var local = local
            guard let address = local.definingAddress, let index = local.definingAccessIndex,
                  let accesses = accessesByAddress[address], accesses.indices.contains(index) else { return local }
            let range = accesses[index].range
            guard range.count == local.byteWidth,
                  let region = analysis.regions.first(where: { $0.range.contains(range.lowerBound) }),
                  range.upperBound <= region.range.upperBound else { return local }
            // One builder local per offset: a region with several proven lifetimes
            // would need one local each, so it stays unattached until locals split.
            guard region.lifetimes.count == 1, let lifetime = region.lifetimes.first else { return local }
            let role: MacIRStackStorage.Role = switch region.role {
            case .incomingArgument: .incomingArgument
            case .savedRegister: .savedRegister
            case .candidateLocal: .candidateLocal
            }
            local.stackStorage = MacIRStackStorage(identity: lifetime.identity, entryRange: range,
                                                   regionRange: region.range, role: role, escapes: region.escapes)
            return local
        }
        return function
    }
}
