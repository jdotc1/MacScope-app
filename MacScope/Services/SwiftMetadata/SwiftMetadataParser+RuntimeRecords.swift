import Foundation

extension SwiftMetadataParser {
    /// The three runtime arrays are independent; their order provides no ownership relation.
    func parseAsyncFunctions() -> SwiftAsyncMetadata { parseAsyncFunctionsReport().records }

    func parseAsyncFunctionsReport() -> (records: SwiftAsyncMetadata, diagnostics: [MetadataParseDiagnostic]) {
        var diagnostics: [MetadataParseDiagnostic] = []
        let entries = runtimeAsyncTargets("__swift_as_entry", diagnostics: &diagnostics)
        let resumes = runtimeAsyncTargets("__swift_as_ret", diagnostics: &diagnostics)
        let continuations = runtimeAsyncTargets("__swift_as_cont", diagnostics: &diagnostics)
        let targets = Set(entries)
        var pointers: [UInt64: [SwiftAsyncFunctionPointerRecord]] = [:]
        for section in sections where section.name == "__const" && (section.segmentName == nil || section.segmentName == "__TEXT") && !targets.isEmpty {
            let slots = section.size >= 8 ? (section.size - 8) / 4 + 1 : 0
            let count = min(slots, UInt64(Limits.maxTypes))
            if slots > count {
                diagnostics.append(runtimeDiagnostic(section.address, "Async pointer scan reached record cap"))
            }
            for index in 0..<count {
                guard let address = runtimeAdding(section.address, index * 4),
                      runtimeContains(address, width: 8),
                      let target = resolveRelativePointer(at: address), targets.contains(target),
                      let context = readU32(atVA: address + 4) else { continue }
                pointers[target, default: []].append(.init(address: address, expectedContextSize: context))
                if context == 0 || context % 16 != 0 {
                    diagnostics.append(runtimeDiagnostic(address, "Async pointer context size is zero or not a multiple of 16"))
                }
            }
        }
        let multiplicities = Dictionary(grouping: entries, by: { $0 }).mapValues(\.count)
        for entry in multiplicities.keys.sorted() {
            let count = multiplicities[entry] ?? 0
            let matches = pointers[entry] ?? []
            if matches.count != count {
                diagnostics.append(runtimeDiagnostic(entry,
                    "Async target has \(matches.count) candidate pointer records for \(count) array entries; ownership unresolved"))
            }
        }
        let functions = entries.map { entry in
            SwiftAsyncFunctionRecord(entryAddress: entry, pointerRecords: pointers[entry] ?? [])
        }
        return (.init(entries: functions, resumePartialAddresses: resumes,
                      continuationPartialAddresses: continuations), diagnostics)
    }

    private func runtimeAsyncTargets(_ name: String, diagnostics: inout [MetadataParseDiagnostic]) -> [UInt64] {
        var result: [UInt64] = []
        for section in sections where section.name == name {
            let count = min(section.size / 4, UInt64(Limits.maxTypes))
            if section.size % 4 != 0 {
                diagnostics.append(runtimeDiagnostic(section.address, "Truncated \(name) relative-pointer array"))
            }
            if section.size / 4 > count {
                diagnostics.append(runtimeDiagnostic(section.address, "\(name) reached record cap"))
            }
            for index in 0..<count {
                guard let address = runtimeAdding(section.address, index * 4),
                      runtimeContains(address, width: 4),
                      let target = resolveRelativePointer(at: address),
                      sections.contains(where: { $0.name == "__text" && ($0.segmentName == nil || $0.segmentName == "__TEXT") && !$0.isZeroFill && target >= $0.address && target - $0.address < $0.size }) else {
                    diagnostics.append(runtimeDiagnostic(runtimeAdding(section.address, index * 4) ?? section.address,
                                                         "Unreadable \(name) entry or target outside __text"))
                    continue
                }
                result.append(target)
            }
        }
        return result
    }

    func parseValueWitnessSummaries() -> [SwiftValueWitnessSummary] { parseValueWitnessSummariesReport().records }

    func parseValueWitnessSummariesReport() -> (records: [SwiftValueWitnessSummary], diagnostics: [MetadataParseDiagnostic]) {
        var diagnostics: [MetadataParseDiagnostic] = []
        if metadataAddresses.count > Limits.maxTypes || rebaseTargets.count > Limits.maxTypes {
            diagnostics.append(runtimeDiagnostic(0, "Value-witness candidate discovery reached record cap"))
        }
        var candidates = metadataByDescriptor.mapValues { Set([$0]) }
        // Keep this discovery separate from nominal parsing and its metadata-candidate heuristic.
        let sortedSlots = rebaseTargets.keys.sorted()
        if metadataAddresses.count > Limits.maxTypes || sortedSlots.count > Limits.maxTypes {
            diagnostics.append(.init(grade: .walkCapped, address: 0,
                                     message: "Value-witness metadata discovery reached record cap"))
        }
        let addresses = Set(metadataAddresses.sorted().prefix(Limits.maxTypes)).union(
            sortedSlots.lazy.filter { $0 >= 8 }.prefix(Limits.maxTypes).map { $0 - 8 }).union(
                sortedSlots.lazy.filter { $0 >= 64 }.prefix(Limits.maxTypes).map { $0 - 64 })
        for metadata in addresses {
            guard let kind = readU64(atVA: metadata) else { continue }
            let descriptorOffset: UInt64
            let expectedKind: UInt32
            if kind == 0x201 || kind == 0x202 {
                descriptorOffset = 8
                expectedKind = 18
            } else if kind == 0 || kind > 0x7ff {
                // Darwin class metadata includes the Objective-C-compatible five-word prefix.
                descriptorOffset = 64
                expectedKind = 16
            } else { continue }
            guard let field = runtimeAdding(metadata, descriptorOffset),
                  let descriptor = runtimePointer(field), let flags = readU32(atVA: descriptor),
                  flags & 0x1f == expectedKind, flags & 0x80 == 0 else { continue }
            candidates[descriptor, default: []].insert(metadata)
        }
        var result: [SwiftValueWitnessSummary] = []
        for descriptor in candidates.keys.sorted() {
            guard let options = candidates[descriptor], options.count == 1, let metadata = options.first else {
                diagnostics.append(runtimeDiagnostic(descriptor, "Ambiguous value-witness metadata address"))
                continue
            }
            guard let descriptorFlags = readU32(atVA: descriptor), descriptorFlags & 0x80 == 0 else {
                diagnostics.append(runtimeDiagnostic(descriptor, "Generic or unreadable value-witness descriptor"))
                continue
            }
            guard metadata >= 8, let table = runtimePointer(metadata - 8),
                  runtimeContains(table, width: 88),
                  let size = readU64(atVA: table + 64), let stride = readU64(atVA: table + 72),
                  let flags = readU32(atVA: table + 80), let extra = readU32(atVA: table + 84),
                  let name = descriptorName(at: descriptor) else {
                diagnostics.append(runtimeDiagnostic(descriptor, "Unreadable value-witness table or type name"))
                continue
            }
            if flags & 0x00200000 != 0 && !runtimeContains(table, width: 112) {
                diagnostics.append(runtimeDiagnostic(descriptor, "Truncated enum value-witness entries"))
                continue
            }
            result.append(.init(descriptorAddress: descriptor, typeName: name, size: size, stride: stride,
                                alignment: UInt64(flags & 0xff) + 1, extraInhabitantCount: extra,
                                isPOD: flags & 0x00010000 == 0, isBitwiseTakable: flags & 0x00100000 == 0,
                                hasEnumWitnesses: flags & 0x00200000 != 0, isIncomplete: flags & 0x00400000 != 0,
                                flags: flags, metadataAddress: metadata, tableAddress: table))
        }
        return (result, diagnostics)
    }

    private func runtimePointer(_ address: UInt64) -> UInt64? {
        guard bindNames[address] == nil else { return nil }
        if let target = rebaseTargets[address] { return target }
        guard let target = readU64(atVA: address), target != 0 else { return nil }
        return target
    }

    private func runtimeContains(_ address: UInt64, width: UInt64) -> Bool {
        guard width > 0, address <= UInt64.max - (width - 1) else { return false }
        return sections.contains { section in
            guard !section.isZeroFill, address >= section.address else { return false }
            let delta = address - section.address
            guard delta < section.size, width <= section.size - delta,
                  let fileStart = runtimeAdding(section.fileOffset, delta),
                  fileStart <= UInt64(bytes.count) else { return false }
            return width <= UInt64(bytes.count) - fileStart
        }
    }

    private func runtimeAdding(_ address: UInt64, _ offset: UInt64) -> UInt64? {
        let (value, overflow) = address.addingReportingOverflow(offset)
        return overflow ? nil : value
    }

    private func runtimeDiagnostic(_ address: UInt64, _ message: String) -> MetadataParseDiagnostic {
        .init(grade: .skippedItem, address: address, message: message)
    }
}
