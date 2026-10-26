import Foundation

/// DP04 C1b, authored-input v3: the user's stack local and register names for the
/// selected function reach the native decompiler. A function with no such edit keeps
/// its v1/v2 request bytes.
extension NativeDecompilerSnapshotBuilder {
    static func withAuthoredLocalNames(
        _ inputs: NativeDecompilerWireAuthoredInputs,
        stackLocals: [String: StackLocalOverride],
        registerNames: [String: String],
        liveStackStorage: [MacIRStackStorage] = [],
        catalogDefinitions: [TypeDefinition] = []
    ) -> NativeDecompilerWireAuthoredInputs {
        // Named types resolve only against definitions this request already carries.
        let carried = Set(inputs.typeDefinitions.map { definition -> String in
            switch definition {
            case let .record(_, name, _, _): name
            case let .enumeration(name, _, _): name
            case let .typedef(name, _): name
            }
        })
        let types = try? NativeAuthoredCatalogIndex(definitions: catalogDefinitions.filter { carried.contains($0.name) })
        // Persisted edits include intentionally retained orphans. A native binding
        // needs exactly one current storage range and no overlapping live local,
        // including unedited locals. Never resolve a collision by choosing a width.
        let admittedKeys = unambiguousStackKeys(liveStackStorage)
        var locals: [NativeDecompilerWireAuthoredLocalName] = []
        for (key, edit) in stackLocals.sorted(by: { $0.key < $1.key }) {
            guard admittedKeys.contains(key),
                  let range = MacIRStackStorage.entryRange(forAuthoringKey: key),
                  let offset = Int32(exactly: range.lowerBound) else { continue }
            // Scalars, pointers, and catalog types the request carries (an accepted struct);
            // anything else keeps the native type and still carries the name.
            let type = edit.normalized.typeName.flatMap { text in
                types.flatMap { try? NativeAuthoredTypeParserV1.parse(text, role: .parameter, catalog: $0) }
            }
            let name: String
            if let authored = edit.normalized.name {
                guard isWireText(authored, maximum: 1_024), PseudocodePrinter.isCIdentifier(authored) else { continue }
                name = authored
            } else if type != nil, offset < 0 {
                // A type-only edit (e.g. an accepted struct pointer) keeps Ghidra's own
                // default name for the slot, local_<-offset>.
                name = "local_" + String(-Int64(offset), radix: 16)
            } else {
                continue
            }
            locals.append(.init(storageKind: .stack, stackOffset: offset, byteSize: UInt32(range.count),
                                register: "", name: name, type: type))
        }
        for (register, name) in registerNames.sorted(by: { $0.key < $1.key }) {
            let key = register.lowercased()
            let canonical = key.hasPrefix("w") ? "x" + key.dropFirst() : key
            guard NativeDecompilerWireCanonicalRequest.isAuthoredLocalRegister(canonical),
                  isWireText(name, maximum: 1_024), PseudocodePrinter.isCIdentifier(name),
                  !locals.contains(where: { $0.register == canonical }) else { continue }
            locals.append(.init(storageKind: .register, stackOffset: 0, byteSize: 0,
                                register: canonical, name: name, type: nil))
        }
        guard !locals.isEmpty else { return inputs }
        return NativeDecompilerWireAuthoredInputs(
            schemaVersion: NativeDecompilerWireAuthoredInputs.localNameSchemaVersion,
            names: inputs.names,
            signatures: inputs.signatures,
            appliedTypes: inputs.appliedTypes,
            typeDefinitions: inputs.typeDefinitions,
            calleeSignatureHints: inputs.calleeSignatureHints,
            localNames: locals
        )
    }

    private static func unambiguousStackKeys(_ storage: [MacIRStackStorage]) -> Set<String> {
        let ordered = storage.sorted {
            ($0.entryRange.lowerBound, $0.entryRange.upperBound, $0.identity)
                < ($1.entryRange.lowerBound, $1.entryRange.upperBound, $1.identity)
        }
        var result = Set<String>()
        var precedingEnd: Int64?
        for (index, local) in ordered.enumerated() {
            let range = local.entryRange
            let overlapsBefore = precedingEnd.map { $0 > range.lowerBound } ?? false
            let overlapsAfter = index + 1 < ordered.count
                && ordered[index + 1].entryRange.lowerBound < range.upperBound
            if !overlapsBefore && !overlapsAfter { result.insert(local.authoringKey) }
            precedingEnd = max(precedingEnd ?? range.upperBound, range.upperBound)
        }
        return result
    }

    /// Recover from the exact bytes native will consume, including patch overlays.
    /// Incomplete coverage or decode refuses stack bindings without touching edits.
    static func recoveredStackStorage(
        functionRegions: [NativeDecompilerWireMemoryRegion],
        functionRange: Range<UInt64>,
        maximumInstructions: UInt32
    ) -> [MacIRStackStorage] {
        let byteCount = functionRange.upperBound - functionRange.lowerBound
        guard functionRange.lowerBound.isMultiple(of: 4),
              byteCount > 0, byteCount.isMultiple(of: 4),
              byteCount / 4 <= UInt64(maximumInstructions) else { return [] }
        var bytes = Data()
        var cursor = functionRange.lowerBound
        for region in functionRegions {
            let start = region.startAddress.value
            let (end, overflow) = start.addingReportingOverflow(UInt64(region.effectiveBytes.count))
            guard !overflow else { return [] }
            let lower = max(start, cursor)
            let upper = min(end, functionRange.upperBound)
            guard lower < upper else { continue }
            guard lower == cursor else { return [] }
            bytes.append(region.effectiveBytes.subdata(in: Int(lower - start)..<Int(upper - start)))
            cursor = upper
            if cursor == functionRange.upperBound { break }
        }
        guard cursor == functionRange.upperBound else { return [] }
        let rows = ARM64Decoder().decode(bytes, baseAddress: functionRange.lowerBound,
                                         maxInstructionCount: Int(maximumInstructions))
            .map { InstructionRow(decoded: $0) }
        guard rows.count == Int(byteCount / 4),
              !rows.contains(where: { $0.mnemonic == "unknown" || $0.mnemonic == "unavailable" }) else { return [] }
        return MacIRBuilder().buildFunction(name: "", startAddress: functionRange.lowerBound,
                                            instructions: rows).localVariables.compactMap(\.stackStorage)
    }

}
