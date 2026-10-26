import Foundation

/// Shared local/XPC caller postprocessing. Binary parsing remains in the worker.
/// Works on a private value copy: cancellation never publishes partial derived products.
enum RehydrationDerivedProducts {
    static func rebuild(persisted: ImageAnalysis, loader: RehydrationLoaderProducts,
                        imageBytes: Data, overrides: [UInt64: AddressOverride] = [:],
                        cancellation: AnalysisCancellationToken) throws -> ImageAnalysis {
        try cancellation.check(.rehydrate)
        try loader.validate(imageByteCount: imageBytes.count)
        let overlay = try BytePatchOverlay(patches: overrides.compactMapValues { $0.patch },
                                           mappings: loader.mappings)
        try cancellation.check(.rehydrate)
        var result = persisted
        result.sections = loader.sections
        result.codeDataRanges = loader.codeDataRanges
        result.relocations = loader.relocations
        result.identityEffectiveByteRanges = loader.identityEffectiveByteRanges
        result.machOMetadata = loader.machOMetadata
        result.objcClasses = loader.objcClasses
        result.objcCategories = loader.objcCategories
        result.objcProtocols = loader.objcProtocols
        result.swiftTypes = loader.swiftTypes
        result.swiftConformances = loader.swiftConformances
        result.objcSelectors = loader.objcSelectors
        result.constantStrings = ImageConstantStringProvider.build(
            stringLiterals: persisted.stringLiterals,
            cfStrings: ImageConstantStringProvider.cfStrings(in: persisted.constantStrings)
                .merging(loader.constantCFStrings) { _, loaded in loaded })
        result.objcClassReferences = loader.objcClassReferences
        try cancellation.check(.rehydrate)
        result.jumpTables = try resolveJumpTables(instructionRows: persisted.instructions,
            imageBytes: imageBytes, loader: loader, functions: persisted.functions,
            patchOverlay: overlay, byteMappings: loader.mappings, cancellation: cancellation)
        try cancellation.check(.rehydrate)
        result.diagnostics = AnalysisDiagnosticsCollector().collect(.init(
            instructions: result.instructions, controlFlowEdges: result.controlFlowEdges,
            xrefs: result.xrefs, sections: result.sections,
            loaderTruncations: loader.loaderTruncations,
            parserDisagreements: loader.parserDisagreements,
            parserCrossCheckSkip: loader.parserCrossCheckSkip, loaderFindings: loader.loaderFindings))
        try cancellation.check(.rehydrate)
        result.refreshTypeCatalog()
        try cancellation.check(.rehydrate)
        return result
    }

    static func mappedBytes(in bytes: Data, sliceOffset: UInt64, at address: UInt64,
                            count: Int, mappings: [FileAddressMapping]) -> Data? {
        guard let range = FileAddressMapping.resolvedFileRange(
            forVirtualAddress: address, count: count, in: mappings),
            let sliceStart = Int(exactly: sliceOffset), sliceStart <= bytes.count,
            range.upperBound <= bytes.count - sliceStart else { return nil }
        let start = bytes.startIndex + sliceStart + range.lowerBound
        return bytes.subdata(in: start..<(start + count))
    }

    static func resolveJumpTables(
        instructionRows: [InstructionRow],
        imageBytes: Data,
        loader: RehydrationLoaderProducts,
        functions: [FunctionSummary],
        patchOverlay: BytePatchOverlay,
        byteMappings: [FileAddressMapping],
        cancellation: AnalysisCancellationToken
    ) throws -> [UInt64: [UInt64]] {

        // Automatic tables use exactly the same whole-range mapping authority
        // as manual hints. A section cannot read a neighbor's bytes or an alias.
        let readBytes: JumpTableResolver.ByteReader = { virtualAddress, count in
            guard let raw = Self.mappedBytes(in: imageBytes, sliceOffset: loader.sliceOffset, at: virtualAddress,
                                             count: count, mappings: byteMappings) else { return nil }
            guard !cancellation.isCancelled else { return nil }
            return patchOverlay.applying(to: raw, at: virtualAddress)
        }

        // Checked span: a malformed section whose address + size overflows cannot
        // bound jump-table resolution — omit resolution entirely rather than trap
        // or hand the resolver a wrapped range. (A zero-size section previously
        // produced an empty range that resolved nothing; returning [:] is the same.)
        var result: [UInt64: [UInt64]] = [:]
        let sections = executableCodeSections(sections: loader.sections, layout: loader.preferredSegmentLayout, mappings: byteMappings)
        let sortedFunctions = functions.sorted { $0.startAddress < $1.startAddress }
        var previousEnd: UInt64 = 0
        for (index, function) in sortedFunctions.enumerated() {
            try cancellation.check()
            let overlapBefore = previousEnd > function.startAddress
            previousEnd = max(previousEnd, function.endAddress)
            guard function.startAddress < function.endAddress, !overlapBefore,
                  index + 1 == sortedFunctions.count || sortedFunctions[index + 1].startAddress >= function.endAddress,
                  let section = sections.first(where: {
                      function.startAddress >= $0.address && function.endAddress <= $0.address + $0.size
                  }) else { continue }
            let rows = Array(instructionRows[Self.addressIndex(function.startAddress, in: instructionRows, address: \.address)
                ..< Self.addressIndex(function.endAddress, in: instructionRows, address: \.address)])
            let recovered = JumpTableResolver().resolve(instructions: rows, readBytes: readBytes,
                codeRange: .init(lowerBound: function.startAddress, upperBound: min(function.endAddress, section.address + section.size)))
            let decodedTargets = Set(rows.filter { !$0.bytes.isEmpty }.map(\.address))
            for (site, targets) in recovered where targets.allSatisfy({ decodedTargets.contains($0) }) {
                result[site] = targets
            }
        }
        try cancellation.check()
        return result
    }

    static func executableCodeSections(sections: [SectionSummary], layout: MachOPreferredSegmentLayout?,
                                       mappings: [FileAddressMapping]) -> [SectionSummary] {
        let candidates = sections.filter { $0.isExecutable && !$0.isZeroFill }
        guard candidates.count <= 256 else { return [] }
        return candidates.compactMap { section in
            let size = min(section.size, section.fileSize ?? section.size)
            guard size > 0, let count = Int(exactly: size),
                  let span = checkedSpan(start: section.address, size: size),
                  let file = FileAddressMapping.resolvedFileRange(forVirtualAddress: section.address, count: count, in: mappings),
                  UInt64(file.lowerBound) == section.fileOffset else { return nil }
            guard sections.filter({ other in
                guard let otherSpan = checkedSpan(start: other.address, size: other.size) else { return false }
                return otherSpan.overlaps(span)
            }).count == 1 else { return nil }
            if let layout = layout {
                let owners = layout.records.filter { record in
                    guard let end = checkedSpan(start: record.preferredVMStart,
                                                          size: min(record.preferredVMSize, record.fileSize)) else { return false }
                    return span.lowerBound >= end.lowerBound && span.upperBound <= end.upperBound
                        && record.sliceRelativeFileOffset <= section.fileOffset
                        && section.fileOffset - record.sliceRelativeFileOffset == section.address - record.preferredVMStart
                }
                guard owners.count == 1, let owner = owners.first,
                      owner.initialProtections & 4 != 0 else { return nil }
            }
            var bounded = section
            bounded.size = size
            bounded.fileSize = size
            return bounded
        }.sorted { $0.address < $1.address }
    }

    // Same nonempty, nonwrapping half-open span required at the original engine seam.
    private static func checkedSpan(start: UInt64, size: UInt64) -> Range<UInt64>? {
        let end = start.addingReportingOverflow(size)
        guard size > 0, !end.overflow else { return nil }
        return start..<end.partialValue
    }

    private static func addressIndex<Element>(_ value: UInt64, in rows: [Element],
                                               address: KeyPath<Element, UInt64>) -> Int {
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if rows[middle][keyPath: address] < value { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

}
