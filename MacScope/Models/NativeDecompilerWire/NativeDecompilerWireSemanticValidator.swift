import Foundation

enum NativeDecompilerWireSemanticValidationError: Error, Equatable, Sendable {
    case invalidResult
}

/// Fail-closed semantic validation for a decoded native-decompiler success.
///
/// This mirrors the native provider boundary's `validateStructuredResult` and
/// capability-truth checks. The request is required because output evidence is
/// valid only when it binds to the exact request identities and effective byte
/// view supplied by the caller.
struct NativeDecompilerWireSemanticValidator: Sendable {
    static func validate(
        request: NativeDecompilerWireRequest,
        schemaVersion: UInt32 = NativeDecompilerWireRequestEnvelope.currentSchemaVersion,
        operation: NativeDecompilerWireRequestOperation = .decompile,
        capabilities: NativeDecompilerWireBackendCapabilities,
        result: NativeDecompilerWireStructuredResult
    ) throws {
        let validator = Validator(request: request, schemaVersion: schemaVersion,
                                  capabilities: capabilities, result: result)
        if operation == .decompileDocument {
            try validator.validateDocumentOnly()
        } else {
            try validator.validate()
        }
    }
}

private struct NativeDecompilerWireSemanticRangeKey: Hashable, Comparable {
    let imageID: String
    let start: UInt64
    let end: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.imageID != rhs.imageID { return lhs.imageID < rhs.imageID }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.end < rhs.end
    }
}

private struct NativeDecompilerWireSemanticIncomingPath: Hashable {
    let sourceBlockID: String?
    let edgeID: String?
}

private struct NativeDecompilerWireSemanticDiagnosticKey: Hashable {
    let code: String
    let severity: String
    let message: String
    let ranges: [NativeDecompilerWireSemanticRangeKey]
}

private struct Validator {
    typealias Failure = NativeDecompilerWireSemanticValidationError

    let request: NativeDecompilerWireRequest
    let schemaVersion: UInt32
    let capabilities: NativeDecompilerWireBackendCapabilities
    let result: NativeDecompilerWireStructuredResult

    func validate() throws {
        guard result.requestID == request.requestID,
              result.requestSHA256 == request.requestSHA256,
              result.image == request.image,
              result.function == request.function
        else { throw Failure.invalidResult }

        try validateCanonicalOrder()

        let addressSpaceIDs = try uniqueIDs(result.addressSpaces.map(\.id))
        let typeIDs = try uniqueIDs(result.types.map(\.id))
        let instructionIDs = try uniqueIDs(result.instructions.map(\.id))
        let varnodeIDs = try uniqueIDs(result.varnodes.map(\.id))
        let operationIDs = try uniqueIDs(result.operations.map(\.id))
        let blockIDs = try uniqueIDs(result.blocks.map(\.id))
        let edgeIDs = try uniqueIDs(result.edges.map(\.id))
        let ssaValueIDs = try uniqueIDs(result.ssaValues.map(\.id))
        let phiIDs = try uniqueIDs(result.phis.map(\.id))
        let memoryVersionIDs = try uniqueIDs(result.memoryVersions.map(\.id))
        let memoryPhiIDs = try uniqueIDs(result.memoryPhis.map(\.id))
        _ = try uniqueIDs(result.memoryEffects.map(\.id))
        let variableIDs = try uniqueIDs(result.variables.map(\.id))
        let callIDs = try uniqueIDs(result.calls.map(\.id))
        let regionIDs = try uniqueIDs(result.regions.map(\.id))
        _ = try uniqueIDs(result.tokens.map(\.id))

        guard !result.instructions.isEmpty, !result.blocks.isEmpty else {
            throw Failure.invalidResult
        }

        try validateAddressSpaces()
        try validateTypes(typeIDs: typeIDs)

        let instructionState = try validateInstructions(operationIDs: operationIDs)
        try validateVarnodes(addressSpaceIDs: addressSpaceIDs, typeIDs: typeIDs)
        let operationsByID = try validateOperations(
            blockIDs: blockIDs,
            varnodeIDs: varnodeIDs,
            instructionsByID: instructionState.byID,
            instructionOwnerByOperation: instructionState.ownerByOperation
        )
        try validateInstructionOperationOrder(operationsByID: operationsByID)

        let blockState = try validateBlocks(
            operationIDs: operationIDs,
            edgeIDs: edgeIDs,
            operationsByID: operationsByID,
            instructionsByID: instructionState.byID,
            instructionOwnerByOperation: instructionState.ownerByOperation
        )
        let edgesByID = try validateEdges(
            blockIDs: blockIDs,
            operationIDs: operationIDs,
            blocksByID: blockState.byID,
            operationsByID: operationsByID
        )

        let expectedIncomingPaths: (String) -> Set<NativeDecompilerWireSemanticIncomingPath> = { blockID in
            guard let block = blockState.byID[blockID] else { return [] }
            var paths = Set<NativeDecompilerWireSemanticIncomingPath>()
            if isEntryBlock(blockID) {
                paths.insert(.init(sourceBlockID: nil, edgeID: nil))
            }
            for edgeID in block.predecessorEdgeIDs {
                if let edge = edgesByID[edgeID] {
                    paths.insert(.init(sourceBlockID: edge.sourceBlockID, edgeID: edgeID))
                }
            }
            return paths
        }

        let ssaValuesByID = try validateSSAValues(
            varnodeIDs: varnodeIDs,
            operationIDs: operationIDs,
            phiIDs: phiIDs
        )
        try validateSSABindingsAndPhis(
            operationIDs: operationIDs,
            varnodeIDs: varnodeIDs,
            blockIDs: blockIDs,
            edgeIDs: edgeIDs,
            ssaValueIDs: ssaValueIDs,
            operationsByID: operationsByID,
            blocksByID: blockState.byID,
            edgesByID: edgesByID,
            ssaValuesByID: ssaValuesByID,
            expectedIncomingPaths: expectedIncomingPaths
        )
        try validateMemorySSA(
            operationIDs: operationIDs,
            blockIDs: blockIDs,
            edgeIDs: edgeIDs,
            memoryVersionIDs: memoryVersionIDs,
            memoryPhiIDs: memoryPhiIDs,
            blocksByID: blockState.byID,
            edgesByID: edgesByID,
            expectedIncomingPaths: expectedIncomingPaths
        )
        try validateVariables(typeIDs: typeIDs, varnodeIDs: varnodeIDs)
        try validateCalls(
            operationIDs: operationIDs,
            typeIDs: typeIDs,
            variableIDs: variableIDs,
            operationsByID: operationsByID
        )
        try validateRegions(
            regionIDs: regionIDs,
            blockIDs: blockIDs,
            operationIDs: operationIDs
        )
        try validateTokens(
            instructionIDs: instructionIDs,
            typeIDs: typeIDs,
            varnodeIDs: varnodeIDs,
            operationIDs: operationIDs,
            blockIDs: blockIDs,
            variableIDs: variableIDs,
            callIDs: callIDs,
            regionIDs: regionIDs
        )
        try validatePseudocodeDocument()
        try validateDiagnostics()
        try validateAllSourceRanges()
        try validateCapabilityTruth()
        try validatePublicationBudgets()
    }
}

private extension Validator {
    struct InstructionState {
        let byID: [String: NativeDecompilerWireInstructionRecord]
        let ownerByOperation: [String: String]
    }

    struct BlockState {
        let byID: [String: NativeDecompilerWireBlockRecord]
    }

    func uniqueIDs(_ ids: [String]) throws -> Set<String> {
        var result = Set<String>()
        result.reserveCapacity(ids.count)
        for id in ids {
            try requireText(id, maximum: 1_024)
            guard result.insert(id).inserted else { throw Failure.invalidResult }
        }
        return result
    }

    func requireReference(_ ids: Set<String>, _ id: String) throws {
        try requireText(id, maximum: 1_024)
        guard ids.contains(id) else { throw Failure.invalidResult }
    }

    func requireText(
        _ value: String,
        maximum: Int = 1 << 20,
        allowEmpty: Bool = false,
        allowFormattingControls: Bool = false
    ) throws {
        let bytes = value.utf8
        guard (allowEmpty || !bytes.isEmpty), bytes.count <= maximum else {
            throw Failure.invalidResult
        }
        for byte in bytes {
            let formatting = allowFormattingControls && (byte == 0x09 || byte == 0x0a || byte == 0x0d)
            if (byte < 0x20 && !formatting) || byte == 0x7f {
                throw Failure.invalidResult
            }
        }
    }

    func checkedEnd(_ start: UInt64, byteCount: Int) throws -> UInt64 {
        guard byteCount >= 0,
              let count = UInt64(exactly: byteCount),
              start <= UInt64.max - count
        else { throw Failure.invalidResult }
        return start + count
    }

    func validateSourceRange(_ range: NativeDecompilerWireSourceRange) throws {
        guard range.imageID == request.image.imageID,
              range.startAddress.value < range.endAddressExclusive.value,
              range.startAddress.value >= request.function.entryAddress.value,
              range.endAddressExclusive.value <= request.function.endAddressExclusive.value
        else { throw Failure.invalidResult }
        if schemaVersion == NativeDecompilerWireRequestEnvelope.sparseCodeSchemaVersion {
            guard codeRangesCover(
                start: range.startAddress.value,
                end: range.endAddressExclusive.value
            ) else { throw Failure.invalidResult }
        }
    }

    func codeRangesCover(start: UInt64, end: UInt64) -> Bool {
        guard let ranges = request.function.codeRanges, start < end else { return false }
        var cursor = start
        for range in ranges {
            if range.endAddressExclusive.value <= cursor { continue }
            if range.startAddress.value > cursor { return false }
            cursor = min(end, range.endAddressExclusive.value)
            if cursor == end { return true }
        }
        return false
    }

    func validateSourceRanges(_ ranges: [NativeDecompilerWireSourceRange]) throws {
        var seen = Set<NativeDecompilerWireSemanticRangeKey>()
        for range in ranges {
            try validateSourceRange(range)
            guard seen.insert(rangeKey(range)).inserted else { throw Failure.invalidResult }
        }
    }

    func rangeKey(_ range: NativeDecompilerWireSourceRange) -> NativeDecompilerWireSemanticRangeKey {
        .init(
            imageID: range.imageID,
            start: range.startAddress.value,
            end: range.endAddressExclusive.value
        )
    }

    func effectiveBytes(at start: UInt64, count: Int) throws -> Data {
        let end = try checkedEnd(start, byteCount: count)
        var cursor = start
        var output = Data()
        output.reserveCapacity(count)
        let regions = request.memoryRegions.sorted {
            if $0.startAddress.value != $1.startAddress.value {
                return $0.startAddress.value < $1.startAddress.value
            }
            return $0.name < $1.name
        }
        for region in regions {
            let regionStart = region.startAddress.value
            let regionEnd = try checkedEnd(regionStart, byteCount: region.effectiveBytes.count)
            if regionEnd <= cursor { continue }
            if regionStart > cursor { break }
            guard region.permissions.rawValue.first == "r" else { throw Failure.invalidResult }
            let takeEnd = min(end, regionEnd)
            let offset = Int(cursor - regionStart)
            let takeCount = Int(takeEnd - cursor)
            output.append(region.effectiveBytes.subdata(in: offset..<(offset + takeCount)))
            cursor = takeEnd
            if cursor == end { return output }
        }
        throw Failure.invalidResult
    }

    func rangesOverlap(_ lhsStart: UInt64, _ lhsEnd: UInt64, _ rhsStart: UInt64, _ rhsEnd: UInt64) -> Bool {
        lhsStart < rhsEnd && rhsStart < lhsEnd
    }

    func instructionLess(
        _ lhs: NativeDecompilerWireInstructionRecord,
        _ rhs: NativeDecompilerWireInstructionRecord
    ) -> Bool {
        if lhs.address.value != rhs.address.value { return lhs.address.value < rhs.address.value }
        return lhs.id < rhs.id
    }
}

private extension Validator {
    func validateCanonicalOrder() throws {
        guard isSorted(result.addressSpaces, by: { $0.id < $1.id }),
              isSorted(result.types, by: { $0.id < $1.id }),
              isSorted(result.instructions, by: instructionLess),
              isSorted(result.varnodes, by: { $0.id < $1.id }),
              isSorted(result.operations, by: operationLess),
              isSorted(result.blocks, by: blockLess),
              isSorted(result.edges, by: { $0.id < $1.id }),
              isSorted(result.ssaValues, by: { $0.id < $1.id }),
              isSorted(result.ssaBindings, by: { $0.operationID < $1.operationID }),
              isSorted(result.phis, by: { $0.id < $1.id }),
              isSorted(result.memoryVersions, by: { $0.id < $1.id }),
              isSorted(result.memoryPhis, by: { $0.id < $1.id }),
              isSorted(result.memoryEffects, by: { $0.id < $1.id }),
              isSorted(result.variables, by: { $0.id < $1.id }),
              isSorted(result.calls, by: { $0.id < $1.id }),
              isSorted(result.regions, by: { $0.id < $1.id }),
              isSorted(result.tokens, by: tokenLess),
              isSorted(result.warnings, by: diagnosticLess)
        else { throw Failure.invalidResult }

        for type in result.types where !isSorted(type.fields, by: typeFieldLess) {
            throw Failure.invalidResult
        }
        for instruction in result.instructions where !isSorted(instruction.sourceRanges, by: sourceRangeLess) {
            throw Failure.invalidResult
        }
        for operation in result.operations where !isSorted(operation.sourceRanges, by: sourceRangeLess) {
            throw Failure.invalidResult
        }
        for block in result.blocks {
            guard isSorted(block.predecessorEdgeIDs, by: <),
                  isSorted(block.successorEdgeIDs, by: <)
            else { throw Failure.invalidResult }
        }
        // Phi input order is native MULTIEQUAL predecessor-slot evidence.
        for phi in result.memoryPhis where !isSorted(phi.incoming, by: memoryPhiIncomingLess) {
            throw Failure.invalidResult
        }
        for variable in result.variables {
            guard isSorted(variable.storageVarnodeIDs, by: <),
                  isSorted(variable.liveRanges, by: sourceRangeLess)
            else { throw Failure.invalidResult }
        }
        for call in result.calls where !isSorted(call.sourceRanges, by: sourceRangeLess) {
            throw Failure.invalidResult
        }
        for region in result.regions {
            guard isSorted(region.blockIDs, by: <),
                  isSorted(region.sourceRanges, by: sourceRangeLess)
            else { throw Failure.invalidResult }
        }
        for token in result.tokens {
            guard isSorted(token.sourceRanges, by: sourceRangeLess),
                  isSorted(token.entityReferences, by: tokenReferenceLess)
            else { throw Failure.invalidResult }
        }
        for warning in result.warnings where !isSorted(warning.sourceRanges, by: sourceRangeLess) {
            throw Failure.invalidResult
        }
    }

    func isSorted<Element>(_ values: [Element], by less: (Element, Element) -> Bool) -> Bool {
        for index in values.indices.dropFirst() where less(values[index], values[index - 1]) {
            return false
        }
        return true
    }

    func operationLess(
        _ lhs: NativeDecompilerWireOperationRecord,
        _ rhs: NativeDecompilerWireOperationRecord
    ) -> Bool {
        if lhs.blockID != rhs.blockID { return lhs.blockID < rhs.blockID }
        if lhs.sequence.value != rhs.sequence.value { return lhs.sequence.value < rhs.sequence.value }
        return lhs.id < rhs.id
    }

    func blockLess(_ lhs: NativeDecompilerWireBlockRecord, _ rhs: NativeDecompilerWireBlockRecord) -> Bool {
        if lhs.startAddress.value != rhs.startAddress.value {
            return lhs.startAddress.value < rhs.startAddress.value
        }
        return lhs.id < rhs.id
    }

    func typeFieldLess(
        _ lhs: NativeDecompilerWireTypeFieldRecord,
        _ rhs: NativeDecompilerWireTypeFieldRecord
    ) -> Bool {
        if lhs.bitOffset.value != rhs.bitOffset.value { return lhs.bitOffset.value < rhs.bitOffset.value }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        if lhs.typeID != rhs.typeID { return lhs.typeID < rhs.typeID }
        return lhs.bitSize.value < rhs.bitSize.value
    }

    func sourceRangeLess(
        _ lhs: NativeDecompilerWireSourceRange,
        _ rhs: NativeDecompilerWireSourceRange
    ) -> Bool {
        rangeKey(lhs) < rangeKey(rhs)
    }

    func optionalStringLess(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, .some): return true
        case (.some, nil), (nil, nil): return false
        case let (.some(lhs), .some(rhs)): return lhs < rhs
        }
    }

    func memoryPhiIncomingLess(
        _ lhs: NativeDecompilerWireMemoryPhiIncomingRecord,
        _ rhs: NativeDecompilerWireMemoryPhiIncomingRecord
    ) -> Bool {
        if lhs.sourceBlockID != rhs.sourceBlockID {
            return optionalStringLess(lhs.sourceBlockID, rhs.sourceBlockID)
        }
        if lhs.edgeID != rhs.edgeID { return optionalStringLess(lhs.edgeID, rhs.edgeID) }
        return lhs.memoryVersionID < rhs.memoryVersionID
    }

    func tokenReferenceLess(
        _ lhs: NativeDecompilerWireTokenEntityReference,
        _ rhs: NativeDecompilerWireTokenEntityReference
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id < rhs.id
    }

    func tokenLess(
        _ lhs: NativeDecompilerWirePseudocodeTokenRecord,
        _ rhs: NativeDecompilerWirePseudocodeTokenRecord
    ) -> Bool {
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        if lhs.column != rhs.column { return lhs.column < rhs.column }
        return lhs.id < rhs.id
    }

    func diagnosticLess(
        _ lhs: NativeDecompilerWireDiagnosticRecord,
        _ rhs: NativeDecompilerWireDiagnosticRecord
    ) -> Bool {
        if lhs.severity.rawValue != rhs.severity.rawValue {
            return lhs.severity.rawValue < rhs.severity.rawValue
        }
        if lhs.code != rhs.code { return lhs.code < rhs.code }
        if lhs.message != rhs.message { return lhs.message < rhs.message }
        return lexicographicallyLess(lhs.sourceRanges.map(rangeKey), rhs.sourceRanges.map(rangeKey))
    }

    func lexicographicallyLess<Element: Comparable>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
        for index in 0..<min(lhs.count, rhs.count) {
            if lhs[index] != rhs[index] { return lhs[index] < rhs[index] }
        }
        return lhs.count < rhs.count
    }
}

private extension Validator {
    func validateAddressSpaces() throws {
        for space in result.addressSpaces {
            try requireText(space.name, maximum: 256)
            // The enum is the closed wire representation of the native kind.
            guard space.addressSizeBytes > 0, space.addressSizeBytes <= 32 else {
                throw Failure.invalidResult
            }
        }
    }

    func validateTypes(typeIDs: Set<String>) throws {
        for type in result.types {
            try requireText(type.name, maximum: 4_096)
            try requireText(type.provenance, maximum: 4_096)
            if let byteSize = type.byteSize?.value {
                guard byteSize > 0 else { throw Failure.invalidResult }
            }
            if let pointee = type.pointeeTypeID { try requireReference(typeIDs, pointee) }
            var fieldKeys = Set<String>()
            for field in type.fields {
                try requireReference(typeIDs, field.typeID)
                try requireText(field.name, maximum: 1_024)
                guard field.bitSize.value > 0 else { throw Failure.invalidResult }
                let key = "\(field.name.utf8.count):\(field.name)\u{1f}\(field.typeID.utf8.count):\(field.typeID)\u{1f}\(field.bitOffset.hex)\u{1f}\(field.bitSize.hex)"
                guard fieldKeys.insert(key).inserted else { throw Failure.invalidResult }
                if let byteSize = type.byteSize?.value {
                    guard byteSize <= UInt64.max / 8 else { throw Failure.invalidResult }
                    let bits = byteSize * 8
                    guard field.bitOffset.value <= bits,
                          field.bitSize.value <= bits - field.bitOffset.value
                    else { throw Failure.invalidResult }
                }
            }
            if let returnType = type.returnTypeID { try requireReference(typeIDs, returnType) }
            for parameter in type.parameterTypeIDs { try requireReference(typeIDs, parameter) }
        }
    }

    func validateInstructions(operationIDs: Set<String>) throws -> InstructionState {
        var byID = [String: NativeDecompilerWireInstructionRecord]()
        var ownerByOperation = [String: String]()
        var extents = [(UInt64, UInt64)]()
        for instruction in result.instructions {
            byID[instruction.id] = instruction
            try requireText(instruction.mnemonic, maximum: 256)
            try requireText(
                instruction.body,
                maximum: 4_096,
                allowEmpty: true,
                allowFormattingControls: true
            )
            guard !instruction.bytes.isEmpty, instruction.bytes.count <= 32 else {
                throw Failure.invalidResult
            }
            let end = try checkedEnd(instruction.address.value, byteCount: instruction.bytes.count)
            guard instruction.address.value >= request.function.entryAddress.value,
                  end <= request.function.endAddressExclusive.value,
                  (schemaVersion != NativeDecompilerWireRequestEnvelope.sparseCodeSchemaVersion ||
                    request.function.codeRanges?.contains(where: {
                        instruction.address.value >= $0.startAddress.value &&
                            end <= $0.endAddressExclusive.value
                    }) == true),
                  try effectiveBytes(at: instruction.address.value, count: instruction.bytes.count) == instruction.bytes,
                  !instruction.sourceRanges.isEmpty
            else { throw Failure.invalidResult }
            extents.append((instruction.address.value, end))
            var hasExactRange = false
            var localOperations = Set<String>()
            for range in instruction.sourceRanges {
                try validateSourceRange(range)
                if range.startAddress.value == instruction.address.value,
                   range.endAddressExclusive.value == end {
                    hasExactRange = true
                }
            }
            guard hasExactRange else { throw Failure.invalidResult }
            for operationID in instruction.operationIDs {
                try requireReference(operationIDs, operationID)
                guard localOperations.insert(operationID).inserted,
                      ownerByOperation.updateValue(instruction.id, forKey: operationID) == nil
                else { throw Failure.invalidResult }
            }
        }
        guard ownerByOperation.count == result.operations.count else { throw Failure.invalidResult }
        extents.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        if schemaVersion == NativeDecompilerWireRequestEnvelope.sparseCodeSchemaVersion {
            guard let ranges = request.function.codeRanges, !ranges.isEmpty else {
                throw Failure.invalidResult
            }
            var extentIndex = 0
            for range in ranges {
                var cursor = range.startAddress.value
                while extentIndex < extents.count && extents[extentIndex].0 < range.endAddressExclusive.value {
                    let extent = extents[extentIndex]
                    guard extent.0 == cursor,
                          extent.1 <= range.endAddressExclusive.value else {
                        throw Failure.invalidResult
                    }
                    cursor = extent.1
                    extentIndex += 1
                }
                guard cursor == range.endAddressExclusive.value else {
                    throw Failure.invalidResult
                }
            }
            guard extentIndex == extents.count else { throw Failure.invalidResult }
        } else {
            guard let first = extents.first, let last = extents.last,
                  first.0 == request.function.entryAddress.value,
                  last.1 == request.function.endAddressExclusive.value
            else { throw Failure.invalidResult }
            for index in extents.indices.dropFirst() where extents[index].0 != extents[index - 1].1 {
                throw Failure.invalidResult
            }
        }
        return InstructionState(byID: byID, ownerByOperation: ownerByOperation)
    }

    func validateVarnodes(addressSpaceIDs: Set<String>, typeIDs: Set<String>) throws {
        // A constant-space offset is the constant's value and spacebase (stack)
        // offsets wrap, so neither has a storage extent that can overflow
        // (`sub x9, x9, #8` carries 0xfffffffffffffff8; saved x30 sits at -8).
        let wrappingOffsetSpaceIDs = Set(result.addressSpaces.lazy
            .filter { $0.kind == .constant || $0.kind == .spacebase }
            .map(\.id))
        for varnode in result.varnodes {
            try requireReference(addressSpaceIDs, varnode.addressSpaceID)
            guard varnode.sizeBytes > 0, varnode.sizeBytes <= 4_096 else {
                throw Failure.invalidResult
            }
            if !wrappingOffsetSpaceIDs.contains(varnode.addressSpaceID) {
                _ = try checkedEnd(varnode.offset.value, byteCount: Int(varnode.sizeBytes))
            }
            if let typeID = varnode.typeID { try requireReference(typeIDs, typeID) }
            if let registerName = varnode.registerName { try requireText(registerName, maximum: 256) }
        }
    }

    func validateOperations(
        blockIDs: Set<String>,
        varnodeIDs: Set<String>,
        instructionsByID: [String: NativeDecompilerWireInstructionRecord],
        instructionOwnerByOperation: [String: String]
    ) throws -> [String: NativeDecompilerWireOperationRecord] {
        var byID = [String: NativeDecompilerWireOperationRecord]()
        var sequenceOwners = Set<String>()
        for operation in result.operations {
            byID[operation.id] = operation
            let isCallOther = operation.opcode == .callother
            guard isCallOther == (operation.userOperationName != nil) else { throw Failure.invalidResult }
            if let name = operation.userOperationName { try requireText(name, maximum: 256) }
            let effect = operation.authenticationEffect
            let pacNames: Set<String> = ["AuthIA", "AuthIB", "AuthDA", "AuthDB", "pacia", "pacib",
                "pacda", "pacdb", "paciza", "pacizb", "pacdza", "pacdzb", "pacga", "xpac"]
            let isPAC = operation.userOperationName.map { pacNames.contains($0) } ?? false
            guard isPAC == (effect.kind != .none) else { throw Failure.invalidResult }
            switch effect.kind {
            case .none:
                guard effect.outputSSAValueID == nil else { throw Failure.invalidResult }
            case .transformedOutput:
                guard isCallOther, operation.outputVarnodeID != nil,
                      let output = effect.outputSSAValueID else { throw Failure.invalidResult }
                try requireText(output, maximum: 1_024)
            case .authenticatedMemoryAccessWithoutTransformedAddress:
                guard ["AuthDA", "AuthDB"].contains(operation.userOperationName ?? ""),
                      operation.outputVarnodeID == nil, effect.outputSSAValueID == nil else {
                    throw Failure.invalidResult
                }
            case .authenticatedControlTransferWithoutTransformedTarget:
                guard ["AuthIA", "AuthIB", "AuthDA", "AuthDB"].contains(operation.userOperationName ?? ""),
                      operation.outputVarnodeID == nil, effect.outputSSAValueID == nil else {
                    throw Failure.invalidResult
                }
            case .standaloneAuthenticationWithoutTransformedOutput:
                guard isCallOther, operation.userOperationName == "AuthIB",
                      operation.inputVarnodeIDs.count == 3, operation.outputVarnodeID == nil,
                      effect.outputSSAValueID == nil,
                      let instructionID = instructionOwnerByOperation[operation.id],
                      let instruction = instructionsByID[instructionID], instruction.mnemonic == "autibsp",
                      instruction.bytes == Data([0xff, 0x23, 0x03, 0xd5])
                else { throw Failure.invalidResult }
            }
            try requireReference(blockIDs, operation.blockID)
            let sequenceKey = "\(operation.blockID.utf8.count):\(operation.blockID)\u{1f}\(operation.sequence.hex)"
            guard sequenceOwners.insert(sequenceKey).inserted else { throw Failure.invalidResult }
            if let output = operation.outputVarnodeID { try requireReference(varnodeIDs, output) }
            for input in operation.inputVarnodeIDs { try requireReference(varnodeIDs, input) }
            guard !operation.sourceRanges.isEmpty,
                  let instructionID = instructionOwnerByOperation[operation.id],
                  let instruction = instructionsByID[instructionID]
            else { throw Failure.invalidResult }
            let instructionEnd = try checkedEnd(instruction.address.value, byteCount: instruction.bytes.count)
            var associated = false
            for range in operation.sourceRanges {
                try validateSourceRange(range)
                associated = associated || rangesOverlap(
                    range.startAddress.value,
                    range.endAddressExclusive.value,
                    instruction.address.value,
                    instructionEnd
                )
            }
            guard associated else { throw Failure.invalidResult }
        }
        return byID
    }

    func validateInstructionOperationOrder(
        operationsByID: [String: NativeDecompilerWireOperationRecord]
    ) throws {
        guard result.blockPartition == nil else { return }
        for instruction in result.instructions {
            var blockID: String?
            var previousSequence: UInt64?
            for operationID in instruction.operationIDs {
                guard let operation = operationsByID[operationID] else { throw Failure.invalidResult }
                if let blockID, blockID != operation.blockID { throw Failure.invalidResult }
                if let previousSequence, operation.sequence.value <= previousSequence {
                    throw Failure.invalidResult
                }
                blockID = operation.blockID
                previousSequence = operation.sequence.value
            }
        }
    }
}

private extension Validator {
    func validateBlocks(
        operationIDs: Set<String>,
        edgeIDs: Set<String>,
        operationsByID: [String: NativeDecompilerWireOperationRecord],
        instructionsByID: [String: NativeDecompilerWireInstructionRecord],
        instructionOwnerByOperation: [String: String]
    ) throws -> BlockState {
        if result.blockPartition != nil {
            try validateFinalBlockPartition()
            return BlockState(byID: Dictionary(uniqueKeysWithValues: result.blocks.map { ($0.id, $0) }))
        }
        var instructionBoundaries: Set<UInt64> = [request.function.endAddressExclusive.value]
        for instruction in result.instructions { instructionBoundaries.insert(instruction.address.value) }

        var byID = [String: NativeDecompilerWireBlockRecord]()
        var operationOwner = [String: String]()
        var extents = [(UInt64, UInt64)]()
        var hasEntryBlock = false
        for block in result.blocks {
            byID[block.id] = block
            let start = block.startAddress.value
            let end = block.endAddressExclusive.value
            guard !block.operationIDs.isEmpty, block.terminatorKind != .splice, start < end,
                  start >= request.function.entryAddress.value,
                  end <= request.function.endAddressExclusive.value,
                  instructionBoundaries.contains(start),
                  instructionBoundaries.contains(end)
            else { throw Failure.invalidResult }
            hasEntryBlock = hasEntryBlock || start == request.function.entryAddress.value
            extents.append((start, end))
            var previousSequence: UInt64?
            for operationID in block.operationIDs {
                try requireReference(operationIDs, operationID)
                guard let operation = operationsByID[operationID],
                      operation.blockID == block.id,
                      operationOwner.updateValue(block.id, forKey: operationID) == nil,
                      let instructionID = instructionOwnerByOperation[operationID],
                      let instruction = instructionsByID[instructionID]
                else { throw Failure.invalidResult }
                let instructionEnd = try checkedEnd(
                    instruction.address.value,
                    byteCount: instruction.bytes.count
                )
                guard instruction.address.value >= start, instructionEnd <= end else {
                    throw Failure.invalidResult
                }
                if let previousSequence, operation.sequence.value <= previousSequence {
                    throw Failure.invalidResult
                }
                previousSequence = operation.sequence.value
            }
            for edgeID in block.predecessorEdgeIDs { try requireReference(edgeIDs, edgeID) }
            for edgeID in block.successorEdgeIDs { try requireReference(edgeIDs, edgeID) }
        }
        guard hasEntryBlock, operationOwner.count == result.operations.count else {
            throw Failure.invalidResult
        }
        for operation in result.operations {
            guard let instructionID = instructionOwnerByOperation[operation.id],
                  let instruction = instructionsByID[instructionID],
                  let block = byID[operation.blockID]
            else { throw Failure.invalidResult }
            let instructionEnd = try checkedEnd(instruction.address.value, byteCount: instruction.bytes.count)
            guard instruction.address.value >= block.startAddress.value,
                  instructionEnd <= block.endAddressExclusive.value
            else { throw Failure.invalidResult }
        }
        extents.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        for index in extents.indices.dropFirst() where extents[index].0 < extents[index - 1].1 {
            throw Failure.invalidResult
        }

        let blocksByAddress = result.blocks.sorted {
            if $0.startAddress.value != $1.startAddress.value {
                return $0.startAddress.value < $1.startAddress.value
            }
            return $0.id < $1.id
        }
        var instructionCountByBlock = [String: Int]()
        var expectedOperationsByBlock = [String: [String]]()
        var blockIndex = 0
        for instruction in result.instructions.sorted(by: instructionLess) {
            let instructionEnd = try checkedEnd(instruction.address.value, byteCount: instruction.bytes.count)
            while blockIndex < blocksByAddress.count,
                  blocksByAddress[blockIndex].endAddressExclusive.value <= instruction.address.value {
                blockIndex += 1
            }
            guard blockIndex < blocksByAddress.count else { throw Failure.invalidResult }
            let block = blocksByAddress[blockIndex]
            guard instruction.address.value >= block.startAddress.value,
                  instructionEnd <= block.endAddressExclusive.value
            else { throw Failure.invalidResult }
            instructionCountByBlock[block.id, default: 0] += 1
            expectedOperationsByBlock[block.id, default: []].append(contentsOf: instruction.operationIDs)
        }
        for block in result.blocks {
            guard instructionCountByBlock[block.id] != nil,
                  expectedOperationsByBlock[block.id, default: []] == block.operationIDs
            else { throw Failure.invalidResult }
        }
        return BlockState(byID: byID)
    }

    func validateEdges(
        blockIDs: Set<String>,
        operationIDs: Set<String>,
        blocksByID: [String: NativeDecompilerWireBlockRecord],
        operationsByID: [String: NativeDecompilerWireOperationRecord]
    ) throws -> [String: NativeDecompilerWireEdgeRecord] {
        var byID = [String: NativeDecompilerWireEdgeRecord]()
        for edge in result.edges {
            byID[edge.id] = edge
            guard result.blockPartition != nil || edge.kind != .splice else { throw Failure.invalidResult }
            try requireReference(blockIDs, edge.sourceBlockID)
            if let targetBlockID = edge.targetBlockID {
                try requireReference(blockIDs, targetBlockID)
                guard result.blockPartition != nil || blocksByID[targetBlockID]?.startAddress.value == edge.targetAddress.value else {
                    throw Failure.invalidResult
                }
            } else if edge.targetAddress.value >= request.function.entryAddress.value,
                      edge.targetAddress.value < request.function.endAddressExclusive.value {
                throw Failure.invalidResult
            }
            if let operationID = edge.operationID {
                try requireReference(operationIDs, operationID)
                guard let sourceBlock = blocksByID[edge.sourceBlockID],
                      operationsByID[operationID]?.blockID == edge.sourceBlockID,
                      sourceBlock.operationIDs.last == operationID
                else { throw Failure.invalidResult }
            }
        }
        for block in result.blocks {
            guard Set(block.predecessorEdgeIDs).count == block.predecessorEdgeIDs.count,
                  Set(block.successorEdgeIDs).count == block.successorEdgeIDs.count
            else { throw Failure.invalidResult }
            for edgeID in block.predecessorEdgeIDs {
                guard byID[edgeID]?.targetBlockID == block.id else { throw Failure.invalidResult }
            }
            for edgeID in block.successorEdgeIDs {
                guard byID[edgeID]?.sourceBlockID == block.id else { throw Failure.invalidResult }
            }
        }
        for edge in result.edges {
            guard blocksByID[edge.sourceBlockID]?.successorEdgeIDs.contains(edge.id) == true else {
                throw Failure.invalidResult
            }
            if let targetBlockID = edge.targetBlockID {
                guard blocksByID[targetBlockID]?.predecessorEdgeIDs.contains(edge.id) == true else {
                    throw Failure.invalidResult
                }
            }
        }
        return byID
    }

    func validateSSAValues(
        varnodeIDs: Set<String>,
        operationIDs: Set<String>,
        phiIDs: Set<String>
    ) throws -> [String: NativeDecompilerWireSSAValueRecord] {
        var byID = [String: NativeDecompilerWireSSAValueRecord]()
        for value in result.ssaValues {
            byID[value.id] = value
            try requireReference(varnodeIDs, value.varnodeID)
            guard !(value.definingOperationID != nil && value.definingPhiID != nil) else {
                throw Failure.invalidResult
            }
            if let operationID = value.definingOperationID { try requireReference(operationIDs, operationID) }
            if let phiID = value.definingPhiID { try requireReference(phiIDs, phiID) }
        }
        return byID
    }

    func validateSSABindingsAndPhis(
        operationIDs: Set<String>,
        varnodeIDs: Set<String>,
        blockIDs: Set<String>,
        edgeIDs: Set<String>,
        ssaValueIDs: Set<String>,
        operationsByID: [String: NativeDecompilerWireOperationRecord],
        blocksByID: [String: NativeDecompilerWireBlockRecord],
        edgesByID: [String: NativeDecompilerWireEdgeRecord],
        ssaValuesByID: [String: NativeDecompilerWireSSAValueRecord],
        expectedIncomingPaths: (String) -> Set<NativeDecompilerWireSemanticIncomingPath>
    ) throws {
        var bindingOperations = Set<String>()
        var definedValueIDs = Set<String>()
        var matchedPhiIDs = Set<String>()
        let phisByID = Dictionary(uniqueKeysWithValues: result.phis.map { ($0.id, $0) })
        for binding in result.ssaBindings {
            try requireReference(operationIDs, binding.operationID)
            guard bindingOperations.insert(binding.operationID).inserted,
                  let operation = operationsByID[binding.operationID],
                  binding.inputSSAValueIDs.count == operation.inputVarnodeIDs.count
            else { throw Failure.invalidResult }
            for index in binding.inputSSAValueIDs.indices {
                let valueID = binding.inputSSAValueIDs[index]
                try requireReference(ssaValueIDs, valueID)
                guard ssaValuesByID[valueID]?.varnodeID == operation.inputVarnodeIDs[index] else {
                    throw Failure.invalidResult
                }
            }
            if let outputID = binding.outputSSAValueID {
                try requireReference(ssaValueIDs, outputID)
                guard let value = ssaValuesByID[outputID],
                      let outputVarnodeID = operation.outputVarnodeID,
                      value.varnodeID == outputVarnodeID
                else { throw Failure.invalidResult }
                if operation.opcode == .multiequal {
                    guard value.definingOperationID == nil,
                          let phiID = value.definingPhiID,
                          let phi = phisByID[phiID],
                          phi.outputSSAValueID == outputID,
                          phi.blockID == operation.blockID,
                          phi.varnodeID == outputVarnodeID,
                          phi.incoming.map(\.ssaValueID) == binding.inputSSAValueIDs,
                          matchedPhiIDs.insert(phiID).inserted
                    else { throw Failure.invalidResult }
                } else {
                    guard value.definingOperationID == binding.operationID,
                          value.definingPhiID == nil,
                          definedValueIDs.insert(outputID).inserted
                    else { throw Failure.invalidResult }
                }
            } else if operation.outputVarnodeID != nil {
                throw Failure.invalidResult
            }
            if operation.authenticationEffect.kind == .transformedOutput,
               operation.authenticationEffect.outputSSAValueID != binding.outputSSAValueID {
                throw Failure.invalidResult
            }
        }
        guard bindingOperations.count == result.operations.count else { throw Failure.invalidResult }

        for phi in result.phis {
            try requireReference(blockIDs, phi.blockID)
            try requireReference(varnodeIDs, phi.varnodeID)
            try requireReference(ssaValueIDs, phi.outputSSAValueID)
            guard let output = ssaValuesByID[phi.outputSSAValueID],
                  output.varnodeID == phi.varnodeID,
                  output.definingPhiID == phi.id,
                  definedValueIDs.insert(phi.outputSSAValueID).inserted,
                  phi.incoming.count >= 2
            else { throw Failure.invalidResult }
            var paths = Set<NativeDecompilerWireSemanticIncomingPath>()
            for incoming in phi.incoming {
                try requireReference(ssaValueIDs, incoming.ssaValueID)
                guard (incoming.sourceBlockID == nil) == (incoming.edgeID == nil)
                else { throw Failure.invalidResult }
                if let sourceBlockID = incoming.sourceBlockID, let edgeID = incoming.edgeID {
                    try requireReference(blockIDs, sourceBlockID)
                    try requireReference(edgeIDs, edgeID)
                    guard let edge = edgesByID[edgeID],
                          edge.sourceBlockID == sourceBlockID,
                          edge.targetBlockID == phi.blockID
                    else { throw Failure.invalidResult }
                } else if !isEntryBlock(phi.blockID) {
                    throw Failure.invalidResult
                }
                guard paths.insert(.init(
                    sourceBlockID: incoming.sourceBlockID,
                    edgeID: incoming.edgeID
                )).inserted else { throw Failure.invalidResult }
            }
            guard paths == expectedIncomingPaths(phi.blockID) else { throw Failure.invalidResult }
        }
        for value in result.ssaValues where value.definingOperationID != nil || value.definingPhiID != nil {
            guard definedValueIDs.contains(value.id) else { throw Failure.invalidResult }
        }
    }
}

private extension Validator {
    func validateMemorySSA(
        operationIDs: Set<String>,
        blockIDs: Set<String>,
        edgeIDs: Set<String>,
        memoryVersionIDs: Set<String>,
        memoryPhiIDs: Set<String>,
        blocksByID: [String: NativeDecompilerWireBlockRecord],
        edgesByID: [String: NativeDecompilerWireEdgeRecord],
        expectedIncomingPaths: (String) -> Set<NativeDecompilerWireSemanticIncomingPath>
    ) throws {
        var versionsByID = [String: NativeDecompilerWireMemoryVersionRecord]()
        for version in result.memoryVersions {
            versionsByID[version.id] = version
            try requireText(version.partition, maximum: 256)
            guard !(version.definingOperationID != nil && version.definingMemoryPhiID != nil) else {
                throw Failure.invalidResult
            }
            if let operationID = version.definingOperationID { try requireReference(operationIDs, operationID) }
            if let phiID = version.definingMemoryPhiID { try requireReference(memoryPhiIDs, phiID) }
        }

        var definedVersionIDs = Set<String>()
        for phi in result.memoryPhis {
            try requireReference(blockIDs, phi.blockID)
            try requireReference(memoryVersionIDs, phi.outputMemoryVersionID)
            try requireText(phi.partition, maximum: 256)
            guard let output = versionsByID[phi.outputMemoryVersionID],
                  output.partition == phi.partition,
                  output.definingMemoryPhiID == phi.id,
                  definedVersionIDs.insert(phi.outputMemoryVersionID).inserted,
                  phi.incoming.count >= 2
            else { throw Failure.invalidResult }
            var paths = Set<NativeDecompilerWireSemanticIncomingPath>()
            for incoming in phi.incoming {
                try requireReference(memoryVersionIDs, incoming.memoryVersionID)
                guard versionsByID[incoming.memoryVersionID]?.partition == phi.partition,
                      (incoming.sourceBlockID == nil) == (incoming.edgeID == nil)
                else { throw Failure.invalidResult }
                if let sourceBlockID = incoming.sourceBlockID, let edgeID = incoming.edgeID {
                    try requireReference(blockIDs, sourceBlockID)
                    try requireReference(edgeIDs, edgeID)
                    guard let edge = edgesByID[edgeID],
                          edge.sourceBlockID == sourceBlockID,
                          edge.targetBlockID == phi.blockID
                    else { throw Failure.invalidResult }
                } else if !isEntryBlock(phi.blockID) {
                    throw Failure.invalidResult
                }
                guard paths.insert(.init(
                    sourceBlockID: incoming.sourceBlockID,
                    edgeID: incoming.edgeID
                )).inserted else { throw Failure.invalidResult }
            }
            guard paths == expectedIncomingPaths(phi.blockID) else { throw Failure.invalidResult }
        }

        for effect in result.memoryEffects {
            try requireReference(operationIDs, effect.operationID)
            try requireText(effect.partition, maximum: 256)
            if let inputID = effect.inputMemoryVersionID {
                try requireReference(memoryVersionIDs, inputID)
                guard versionsByID[inputID]?.partition == effect.partition else {
                    throw Failure.invalidResult
                }
            }
            if let outputID = effect.outputMemoryVersionID {
                try requireReference(memoryVersionIDs, outputID)
                guard definedVersionIDs.insert(outputID).inserted,
                      let output = versionsByID[outputID],
                      output.partition == effect.partition,
                      output.definingOperationID == effect.operationID
                else { throw Failure.invalidResult }
            }
            guard effect.inputMemoryVersionID != nil || effect.outputMemoryVersionID != nil else {
                throw Failure.invalidResult
            }
        }
        for version in result.memoryVersions
        where version.definingOperationID != nil || version.definingMemoryPhiID != nil {
            guard definedVersionIDs.contains(version.id) else { throw Failure.invalidResult }
        }
    }

    func validateVariables(typeIDs: Set<String>, varnodeIDs: Set<String>) throws {
        for variable in result.variables {
            try requireText(variable.name, maximum: 1_024)
            try requireText(variable.provenance, maximum: 4_096)
            if let typeID = variable.typeID { try requireReference(typeIDs, typeID) }
            var storageIDs = Set<String>()
            for varnodeID in variable.storageVarnodeIDs {
                try requireReference(varnodeIDs, varnodeID)
                guard storageIDs.insert(varnodeID).inserted else { throw Failure.invalidResult }
            }
        }
    }

    func validateCalls(
        operationIDs: Set<String>,
        typeIDs: Set<String>,
        variableIDs: Set<String>,
        operationsByID: [String: NativeDecompilerWireOperationRecord]
    ) throws {
        var callCountByOperation = [String: Int]()
        for call in result.calls {
            try requireReference(operationIDs, call.operationID)
            guard let operation = operationsByID[call.operationID],
                  operation.opcode == .call || operation.opcode == .callind
            else { throw Failure.invalidResult }
            callCountByOperation[call.operationID, default: 0] += 1
            guard callCountByOperation[call.operationID] == 1 else { throw Failure.invalidResult }
            if let directTarget = operation.directTargetAddress {
                guard call.targetAddress == directTarget else { throw Failure.invalidResult }
            }
            if let targetSymbol = call.targetSymbol { try requireText(targetSymbol, maximum: 4_096) }
            if let prototype = call.prototypeTypeID { try requireReference(typeIDs, prototype) }
            for variableID in call.argumentVariableIDs { try requireReference(variableIDs, variableID) }
            if let variableID = call.resultVariableID { try requireReference(variableIDs, variableID) }
        }
        for operation in result.operations
        where operation.opcode == .call || operation.opcode == .callind {
            guard callCountByOperation[operation.id] == 1 else { throw Failure.invalidResult }
        }
    }

    func validateRegions(
        regionIDs: Set<String>,
        blockIDs: Set<String>,
        operationIDs: Set<String>
    ) throws {
        let regionsByID = Dictionary(uniqueKeysWithValues: result.regions.map { ($0.id, $0) })
        for region in result.regions {
            if let parent = region.parentRegionID { try requireReference(regionIDs, parent) }
            var childIDs = Set<String>()
            for childID in region.childRegionIDs {
                try requireReference(regionIDs, childID)
                guard childIDs.insert(childID).inserted else { throw Failure.invalidResult }
            }
            var ownedBlockIDs = Set<String>()
            for blockID in region.blockIDs {
                try requireReference(blockIDs, blockID)
                guard ownedBlockIDs.insert(blockID).inserted else { throw Failure.invalidResult }
            }
            if let condition = region.conditionOperationID { try requireReference(operationIDs, condition) }
        }
        for region in result.regions {
            for childID in region.childRegionIDs {
                guard regionsByID[childID]?.parentRegionID == region.id else {
                    throw Failure.invalidResult
                }
            }
            if let parentID = region.parentRegionID {
                guard regionsByID[parentID]?.childRegionIDs.contains(region.id) == true else {
                    throw Failure.invalidResult
                }
            }
            var ancestry = Set<String>()
            var cursor = region
            while let parentID = cursor.parentRegionID {
                guard ancestry.insert(cursor.id).inserted,
                      let parent = regionsByID[parentID]
                else { throw Failure.invalidResult }
                cursor = parent
            }
        }
    }

    func validateTokens(
        instructionIDs: Set<String>,
        typeIDs: Set<String>,
        varnodeIDs: Set<String>,
        operationIDs: Set<String>,
        blockIDs: Set<String>,
        variableIDs: Set<String>,
        callIDs: Set<String>,
        regionIDs: Set<String>
    ) throws {
        for token in result.tokens {
            try requireText(
                token.text,
                maximum: 65_536,
                allowFormattingControls: true
            )
            guard token.line > 0, token.column > 0 else { throw Failure.invalidResult }
            var references = Set<String>()
            for reference in token.entityReferences {
                let key = "\(reference.kind.rawValue.utf8.count):\(reference.kind.rawValue)\u{1f}\(reference.id)"
                guard references.insert(key).inserted else { throw Failure.invalidResult }
                let ids: Set<String>
                switch reference.kind {
                case .type: ids = typeIDs
                case .varnode: ids = varnodeIDs
                case .operation: ids = operationIDs
                case .block: ids = blockIDs
                case .variable: ids = variableIDs
                case .call: ids = callIDs
                case .region: ids = regionIDs
                case .instruction: ids = instructionIDs
                }
                try requireReference(ids, reference.id)
            }
        }
    }

    func validateDiagnostics() throws {
        var keys = Set<NativeDecompilerWireSemanticDiagnosticKey>()
        for warning in result.warnings {
            try requireText(warning.code, maximum: 256)
            try requireText(
                warning.message,
                maximum: 65_536,
                allowFormattingControls: true
            )
            let ranges = warning.sourceRanges.map(rangeKey).sorted()
            guard keys.insert(.init(
                code: warning.code,
                severity: warning.severity.rawValue,
                message: warning.message,
                ranges: ranges
            )).inserted else { throw Failure.invalidResult }
        }
    }

    /// `decompile-document` replies: identity-bound, the document and warnings only.
    func validateDocumentOnly() throws {
        guard result.requestID == request.requestID,
              result.requestSHA256 == request.requestSHA256,
              result.image == request.image,
              result.function == request.function,
              result.pseudocodeDocument != nil,
              result.addressSpaces.isEmpty, result.types.isEmpty, result.instructions.isEmpty,
              result.varnodes.isEmpty, result.operations.isEmpty, result.blocks.isEmpty,
              result.edges.isEmpty, result.ssaValues.isEmpty, result.ssaBindings.isEmpty,
              result.phis.isEmpty, result.memoryVersions.isEmpty, result.memoryPhis.isEmpty,
              result.memoryEffects.isEmpty, result.variables.isEmpty, result.calls.isEmpty,
              result.regions.isEmpty, result.tokens.isEmpty, result.blockPartition == nil
        else { throw Failure.invalidResult }
        try validateCanonicalOrder()
        try validatePseudocodeDocument()
        try validateDiagnostics()
        for warning in result.warnings { try validateSourceRanges(warning.sourceRanges) }
    }

    func validatePseudocodeDocument() throws {
        guard let document = result.pseudocodeDocument else { return }
        try requireText(
            document.text,
            maximum: 1 << 20,
            allowFormattingControls: true
        )
        guard !document.text.utf8.contains(0x0d),
              document.language == "c",
              document.isComplete != document.isTruncated
        else { throw Failure.invalidResult }
    }

    func validateAllSourceRanges() throws {
        for instruction in result.instructions { try validateSourceRanges(instruction.sourceRanges) }
        for operation in result.operations { try validateSourceRanges(operation.sourceRanges) }
        for variable in result.variables { try validateSourceRanges(variable.liveRanges) }
        for call in result.calls { try validateSourceRanges(call.sourceRanges) }
        for region in result.regions { try validateSourceRanges(region.sourceRanges) }
        for token in result.tokens { try validateSourceRanges(token.sourceRanges) }
        for warning in result.warnings { try validateSourceRanges(warning.sourceRanges) }
    }

    func validateCapabilityTruth() throws {
        guard capabilities.nativeDecompilerHeritage,
              capabilities.imageQualifiedSourceRanges,
              !result.instructions.isEmpty,
              !result.addressSpaces.isEmpty,
              !result.varnodes.isEmpty,
              !result.operations.isEmpty,
              !result.blocks.isEmpty
        else { throw Failure.invalidResult }

        if capabilities.completeRegisterSSA {
            // Mirrors the native contract (Backend.cpp validateCapabilityTruth): register SSA
            // needs SSA values and one binding per operation, not a register-named varnode. A
            // function whose register effects are all dead (a void return after a dead store)
            // legitimately publishes only constant varnodes.
            guard !result.ssaValues.isEmpty,
                  result.ssaBindings.count == result.operations.count
            else { throw Failure.invalidResult }
        }
        if capabilities.memorySSA {
            guard !result.memoryVersions.isEmpty else { throw Failure.invalidResult }
        } else if !result.memoryVersions.isEmpty || !result.memoryPhis.isEmpty || !result.memoryEffects.isEmpty {
            throw Failure.invalidResult
        }
        if !capabilities.recoveredVariables {
            guard result.variables.isEmpty,
                  result.calls.allSatisfy({ $0.argumentVariableIDs.isEmpty && $0.resultVariableID == nil })
            else { throw Failure.invalidResult }
        }
        if capabilities.recoveredTypes {
            guard !result.types.isEmpty else { throw Failure.invalidResult }
        } else {
            guard result.types.isEmpty,
                  result.varnodes.allSatisfy({ $0.typeID == nil }),
                  result.variables.allSatisfy({ $0.typeID == nil }),
                  result.calls.allSatisfy({ $0.prototypeTypeID == nil })
            else { throw Failure.invalidResult }
        }
        if capabilities.structuredControlFlow {
            guard !result.regions.isEmpty else { throw Failure.invalidResult }
        } else if !result.regions.isEmpty {
            throw Failure.invalidResult
        }
        if capabilities.tokenizedPseudocode {
            // Tokens may be omitted only with the bridge's explicit warning (output bounds).
            guard !result.tokens.isEmpty
                || result.warnings.contains(where: { $0.code == "native-pseudocode-token-metadata-omitted" })
            else { throw Failure.invalidResult }
        } else if !result.tokens.isEmpty {
            throw Failure.invalidResult
        }

        guard result.instructions.allSatisfy({ !$0.sourceRanges.isEmpty }),
              result.operations.allSatisfy({ !$0.sourceRanges.isEmpty }),
              result.variables.allSatisfy({ !$0.liveRanges.isEmpty }),
              result.calls.allSatisfy({ !$0.sourceRanges.isEmpty }),
              result.regions.allSatisfy({ !$0.sourceRanges.isEmpty }),
              result.tokens.allSatisfy({ !$0.sourceRanges.isEmpty })
        else { throw Failure.invalidResult }
    }

    func validatePublicationBudgets() throws {
        guard result.instructions.count <= Int(request.budgets.maxInstructions),
              result.operations.count <= Int(request.budgets.maxOperations),
              estimatedStructuredResultBytes() <= UInt64(request.budgets.maxOutputBytes)
        else { throw Failure.invalidResult }
    }

    func estimatedStructuredResultBytes() -> UInt64 {
        semanticEstimatedStructuredResultBytes(result, legacyV1TextModel: false)
    }
}

private func semanticEstimatedStructuredResultBytes(
    _ result: NativeDecompilerWireStructuredResult,
    legacyV1TextModel: Bool
) -> UInt64 {
        var size = SemanticSizeEstimator(legacyV1TextModel: legacyV1TextModel)
        size.addText(result.requestID.uuidString)
        size.addText(result.requestSHA256)
        size.addText(result.image.imageID)
        size.addText(result.image.uuid.uuidString)
        size.addScalar()
        size.addText(result.function.functionID)
        size.addText(result.function.name)
        size.addScalar(); size.addScalar()

        size.addRange(result.addressSpaces) { size, value in
            size.addText(value.id); size.addText(value.name); size.addText(value.kind.rawValue)
            size.addScalar(); size.addScalar()
        }
        size.addRange(result.types) { size, value in
            size.addText(value.id); size.addText(value.kind.nativeSemanticText); size.addText(value.name)
            size.addScalar(); size.addScalar()
            if let pointee = value.pointeeTypeID { size.addText(pointee) }
            if let returnType = value.returnTypeID { size.addText(returnType) }
            size.addText(value.confidence.rawValue); size.addText(value.provenance)
            for parameter in value.parameterTypeIDs { size.addText(parameter) }
            for field in value.fields {
                size.addContainer()
                size.addText(field.name); size.addText(field.typeID)
                size.addScalar(); size.addScalar()
            }
        }
        size.addRange(result.instructions) { size, value in
            size.addText(value.id); size.addScalar()
            size.addProduct(value.bytes.count, 5)
            size.addText(value.mnemonic); size.addText(value.body)
            for id in value.operationIDs { size.addText(id) }
            size.addSourceRanges(value.sourceRanges)
        }
        size.addRange(result.varnodes) { size, value in
            size.addText(value.id); size.addText(value.addressSpaceID); size.addScalar(); size.addScalar()
            size.addText(value.role.wireSemanticText)
            if let typeID = value.typeID { size.addText(typeID) }
            if let registerName = value.registerName { size.addText(registerName) }
        }
        size.addRange(result.operations) { size, value in
            size.addText(value.id); size.addText(value.blockID); size.addScalar()
            size.addText(value.opcode.nativeSemanticText)
            if let output = value.outputVarnodeID { size.addText(output) }
            for input in value.inputVarnodeIDs { size.addText(input) }
            size.addScalar()
            size.addSourceRanges(value.sourceRanges)
            size.addScalar()
            if let name = value.userOperationName { size.addText(name) }
            size.addScalar(); size.addScalar()
            if let output = value.authenticationEffect.outputSSAValueID { size.addText(output) }
        }
        size.addRange(result.blocks) { size, value in
            size.addText(value.id); size.addScalar(); size.addScalar()
            for id in value.operationIDs { size.addText(id) }
            for id in value.predecessorEdgeIDs { size.addText(id) }
            for id in value.successorEdgeIDs { size.addText(id) }
            size.addText(value.terminatorKind.rawValue)
        }
        size.addRange(result.edges) { size, value in
            size.addText(value.id); size.addText(value.sourceBlockID)
            if let target = value.targetBlockID { size.addText(target) }
            size.addScalar(); size.addText(value.kind.nativeSemanticText)
            if let operation = value.operationID { size.addText(operation) }
        }
        size.addRange(result.ssaValues) { size, value in
            size.addText(value.id); size.addText(value.varnodeID); size.addText(value.kind.nativeSemanticText)
            if let operation = value.definingOperationID { size.addText(operation) }
            if let phi = value.definingPhiID { size.addText(phi) }
        }
        size.addRange(result.ssaBindings) { size, value in
            size.addText(value.operationID)
            for id in value.inputSSAValueIDs { size.addText(id) }
            if let output = value.outputSSAValueID { size.addText(output) }
        }
        size.addRange(result.phis) { size, value in
            size.addText(value.id); size.addText(value.blockID); size.addText(value.varnodeID)
            size.addText(value.outputSSAValueID)
            for incoming in value.incoming {
                size.addContainer()
                if let source = incoming.sourceBlockID { size.addText(source) }
                if let edge = incoming.edgeID { size.addText(edge) }
                size.addText(incoming.ssaValueID)
            }
        }
        size.addRange(result.memoryVersions) { size, value in
            size.addText(value.id); size.addText(value.partition); size.addText(value.kind.nativeSemanticText)
            if let operation = value.definingOperationID { size.addText(operation) }
            if let phi = value.definingMemoryPhiID { size.addText(phi) }
        }
        size.addRange(result.memoryPhis) { size, value in
            size.addText(value.id); size.addText(value.blockID); size.addText(value.partition)
            size.addText(value.outputMemoryVersionID)
            for incoming in value.incoming {
                size.addContainer()
                if let source = incoming.sourceBlockID { size.addText(source) }
                if let edge = incoming.edgeID { size.addText(edge) }
                size.addText(incoming.memoryVersionID)
            }
        }
        size.addRange(result.memoryEffects) { size, value in
            size.addText(value.id); size.addText(value.operationID); size.addText(value.kind.nativeSemanticText)
            size.addText(value.partition)
            if let input = value.inputMemoryVersionID { size.addText(input) }
            if let output = value.outputMemoryVersionID { size.addText(output) }
        }
        size.addRange(result.variables) { size, value in
            size.addText(value.id); size.addText(value.name); size.addText(value.role.nativeSemanticText)
            if let typeID = value.typeID { size.addText(typeID) }
            for id in value.storageVarnodeIDs { size.addText(id) }
            size.addSourceRanges(value.liveRanges)
            size.addText(value.confidence.rawValue); size.addText(value.provenance)
        }
        size.addRange(result.calls) { size, value in
            size.addText(value.id); size.addText(value.operationID); size.addText(value.kind.rawValue)
            size.addScalar()
            if let symbol = value.targetSymbol { size.addText(symbol) }
            if let prototype = value.prototypeTypeID { size.addText(prototype) }
            for id in value.argumentVariableIDs { size.addText(id) }
            if let result = value.resultVariableID { size.addText(result) }
            size.addSourceRanges(value.sourceRanges)
        }
        size.addRange(result.regions) { size, value in
            size.addText(value.id); size.addText(value.kind.nativeSemanticText)
            if let parent = value.parentRegionID { size.addText(parent) }
            for id in value.childRegionIDs { size.addText(id) }
            for id in value.blockIDs { size.addText(id) }
            if let condition = value.conditionOperationID { size.addText(condition) }
            size.addSourceRanges(value.sourceRanges)
        }
        size.addRange(result.tokens) { size, value in
            size.addText(value.id); size.addText(value.text); size.addText(value.kind.nativeSemanticText)
            size.addPosition(value.line); size.addPosition(value.column)
            size.addSourceRanges(value.sourceRanges)
            for reference in value.entityReferences {
                size.addContainer()
                size.addText(reference.kind.rawValue); size.addText(reference.id)
            }
        }
        size.addScalar()
        if let document = result.pseudocodeDocument {
            size.addUniqueText(document.text)
            size.addUniqueText(document.language)
            size.addScalar()
            size.addScalar()
        }
        size.addRange(result.warnings) { size, value in
            size.addText(value.code); size.addText(value.severity.rawValue); size.addText(value.message)
            size.addSourceRanges(value.sourceRanges)
        }
        if let partition = result.blockPartition {
            size.add(legacyV1TextModel ? 64 : 48); size.addScalar(); size.addText(partition.entryBlockID)
            size.addRange(partition.blocks) { size, block in
                size.addText(block.blockID); size.addScalar(); size.addScalar()
                size.addSourceRanges(block.sourceRanges)
            }
            size.addRange(partition.instructions) { size, instruction in
                size.addText(instruction.instructionID); size.addText(instruction.disposition.rawValue)
                size.addRange(instruction.spans) { size, span in
                    size.addText(span.blockID); size.addScalar(); size.addScalar()
                }
            }
            size.addRange(partition.edges) { size, edge in
                size.addText(edge.edgeID); size.addScalar(); size.addScalar(); size.addText(edge.transferKind.rawValue)
            }
        }
        return size.total
    }

extension NativeDecompilerWireSemanticValidator {
    /// Output-size estimate of a structured result, the value the output
    /// budget is checked against. `legacyV1TextModel` reproduces the pre-v2
    /// per-occurrence text charge (32 + 6 per UTF-8 byte) for diagnostics only.
    static func estimatedStructuredResultBytes(
        _ result: NativeDecompilerWireStructuredResult,
        legacyV1TextModel: Bool = false
    ) -> UInt64 {
        semanticEstimatedStructuredResultBytes(result, legacyV1TextModel: legacyV1TextModel)
    }
}

private struct SemanticSizeEstimator {
    var total: UInt64
    var legacyV1TextModel: Bool
    var seenTexts = Set<[UInt8]>()
    var seenPositions = Set<UInt32>()

    init(legacyV1TextModel: Bool = false) {
        self.legacyV1TextModel = legacyV1TextModel
        total = legacyV1TextModel ? 256 : 16_384
    }

    mutating func add(_ value: UInt64) {
        total = total.addingReportingOverflow(value).overflow ? UInt64.max : total + value
    }

    // Model v3: each dictionary key/value pair needs at most two four-byte
    // object references. Distinct primitive payloads are charged separately;
    // record/container charges cover their headers, offsets and array links.
    mutating func addText(_ value: String) {
        if legacyV1TextModel {
            add(32)
            addProduct(value.utf8.count, 6)
            return
        }
        add(8)
        let bytes = Array(value.utf8)
        guard seenTexts.insert(bytes).inserted else { return }
        addTextObject(bytes)
    }

    mutating func addUniqueText(_ value: String) {
        if legacyV1TextModel { return addText(value) }
        add(8)
        addTextObject(Array(value.utf8))
    }

    private mutating func addTextObject(_ bytes: [UInt8]) {
        add(16)
        addProduct(bytes.count, bytes.allSatisfy { $0 < 0x80 } ? 1 : 2)
    }

    mutating func addPosition(_ value: UInt32) {
        if legacyV1TextModel { return addScalar() }
        add(8)
        // The native codec canonicalizes exact integer objects as well as
        // strings. Both positions are boxed UInt32, with no numeric coercion.
        if seenPositions.insert(value).inserted { add(16) }
    }

    mutating func addContainer() { if !legacyV1TextModel { add(16) } }

    mutating func addProduct(_ count: Int, _ width: UInt64) {
        guard let count = UInt64(exactly: count) else { total = UInt64.max; return }
        let product = count.multipliedReportingOverflow(by: width)
        add(product.overflow ? UInt64.max : product.partialValue)
    }

    mutating func addScalar() { add(32) }

    mutating func addSourceRanges(_ ranges: [NativeDecompilerWireSourceRange]) {
        addProduct(ranges.count, legacyV1TextModel ? 32 : 16)
        for range in ranges {
            addText(range.imageID)
            if legacyV1TextModel {
                addScalar(); addScalar()
            } else {
                addText(String(format: "%016llx", range.startAddress.value))
                addText(String(format: "%016llx", range.endAddressExclusive.value))
            }
        }
    }

    mutating func addRange<Element>(
        _ values: [Element],
        _ body: (inout SemanticSizeEstimator, Element) -> Void
    ) {
        addProduct(values.count, legacyV1TextModel ? 64 : 48)
        for value in values { body(&self, value) }
    }
}

private extension NativeDecompilerWireVarnodeRole {
    var wireSemanticText: String { self == .internalValue ? "internal" : rawValue }
}

private extension NativeDecompilerWireOpcode {
    var nativeSemanticText: String { rawValue.uppercased() }
}

private extension NativeDecompilerWireEdgeKind {
    var nativeSemanticText: String {
        switch self {
        case .falseBranch: "false"
        case .trueBranch: "true"
        case .switchCase: "switchCase"
        case .switchDefault: "switchDefault"
        default: rawValue
        }
    }
}

private extension NativeDecompilerWireSSAValueKind {
    var nativeSemanticText: String {
        switch self {
        case .functionEntry: "functionEntry"
        case .operationResult: "operationResult"
        case .phiResult: "phiResult"
        default: rawValue
        }
    }
}

private extension NativeDecompilerWireMemoryVersionKind {
    var nativeSemanticText: String {
        switch self {
        case .functionEntry: "functionEntry"
        case .operationResult: "operationResult"
        case .phiResult: "phiResult"
        }
    }
}

private extension NativeDecompilerWireMemoryEffectKind {
    var nativeSemanticText: String { self == .readWrite ? "readWrite" : rawValue }
}

private extension NativeDecompilerWireVariableRole {
    var nativeSemanticText: String { rawValue }
}

private extension NativeDecompilerWireTypeKind {
    var nativeSemanticText: String { self == .floatingPoint ? "floatingPoint" : rawValue }
}

private extension NativeDecompilerWireRegionKind {
    var nativeSemanticText: String {
        switch self {
        case .doWhile: "doWhile"
        case .infiniteLoop: "infiniteLoop"
        case .multiGoto: "multiGoto"
        default: rawValue
        }
    }
}

private extension NativeDecompilerWireTokenKind {
    var nativeSemanticText: String {
        switch self {
        case .literal: "integerLiteral"
        default: rawValue
        }
    }
}

// CP4 version-1 final-CFG contract. Keep synchronized with BlockPartition.cpp
// and the normative native-wire document; no address-envelope ownership fallback.
private extension Validator {
    func isEntryBlock(_ blockID: String) -> Bool {
        if let partition = result.blockPartition { return blockID == partition.entryBlockID }
        return result.blocks.first { $0.id == blockID }?.startAddress == request.function.entryAddress
    }

    func validateFinalBlockPartition() throws {
        guard let partition = result.blockPartition else { return }
        guard partition.version == 1, !result.blocks.isEmpty,
              result.blocks.count <= Int(UInt32.max), result.edges.count <= Int(UInt32.max),
              result.instructions.count <= Int(UInt32.max), result.operations.count <= Int(UInt32.max),
              partition.blocks.count == result.blocks.count,
              partition.instructions.count == result.instructions.count,
              partition.edges.count == result.edges.count,
              estimatedStructuredResultBytes() <= UInt64(request.budgets.maxOutputBytes)
        else { throw Failure.invalidResult }
        // These IDs were checked for uniqueness by the ordinary validator.
        let blocks = Dictionary(uniqueKeysWithValues: result.blocks.map { ($0.id, $0) })
        let operations = Dictionary(uniqueKeysWithValues: result.operations.map { ($0.id, $0) })
        let edges = Dictionary(uniqueKeysWithValues: result.edges.map { ($0.id, $0) })
        let varnodes = Dictionary(uniqueKeysWithValues: result.varnodes.map { ($0.id, $0) })
        let spaces = Dictionary(uniqueKeysWithValues: result.addressSpaces.map { ($0.id, $0) })
        var descriptors = [String: NativeDecompilerWireBlockPartitionBlock]()
        for (ordinal, descriptor) in partition.blocks.enumerated() {
            let suffix = String(ordinal, radix: 16)
            let expectedID = "block:cfg:" + String(repeating: "0", count: 16 - suffix.count) + suffix
            guard descriptor.ordinal == ordinal, descriptor.blockID == expectedID,
                  blocks[descriptor.blockID] != nil,
                  descriptors.updateValue(descriptor, forKey: descriptor.blockID) == nil
            else { throw Failure.invalidResult }
        }
        guard partition.entryBlockID == partition.blocks.first?.blockID,
              partition.blocks.first?.entryAddress == request.function.entryAddress
        else { throw Failure.invalidResult }

        var members = [String: [NativeDecompilerWireInstructionRecord]]()
        var instructionBlocks = [String: Set<String>]()
        var operationInstructions = [String: String]()
        var boundaries = Set<UInt64>()
        for (index, instruction) in result.instructions.enumerated() {
            let ownership = partition.instructions[index]
            guard ownership.instructionID == instruction.id,
                  index == 0 || result.instructions[index - 1].address.value < instruction.address.value
            else { throw Failure.invalidResult }
            boundaries.insert(instruction.address.value)
            for id in instruction.operationIDs { operationInstructions[id] = instruction.id }
            if ownership.disposition == .eliminated {
                guard ownership.spans.isEmpty, instruction.operationIDs.isEmpty else { throw Failure.invalidResult }
                continue
            }
            guard !ownership.spans.isEmpty, ownership.spans.count <= partition.blocks.count else {
                throw Failure.invalidResult
            }
            var cursor = 0
            var previousOrdinal: UInt32?
            for span in ownership.spans {
                guard let descriptor = descriptors[span.blockID],
                      previousOrdinal.map({ $0 < descriptor.ordinal }) ?? true,
                      Int(span.firstOperationIndex) == cursor, cursor <= instruction.operationIDs.count,
                      Int(span.operationCount) <= instruction.operationIDs.count - cursor
                else { throw Failure.invalidResult }
                previousOrdinal = descriptor.ordinal
                var previousSequence: UInt64?
                for offset in 0..<Int(span.operationCount) {
                    guard let operation = operations[instruction.operationIDs[cursor + offset]],
                          operation.blockID == span.blockID,
                          previousSequence.map({ $0 < operation.sequence.value }) ?? true
                    else { throw Failure.invalidResult }
                    previousSequence = operation.sequence.value
                }
                cursor += Int(span.operationCount)
                members[span.blockID, default: []].append(instruction)
                instructionBlocks[instruction.id, default: []].insert(span.blockID)
            }
            guard cursor == instruction.operationIDs.count else { throw Failure.invalidResult }
        }
        var ownedOperations = Set<String>()
        for block in result.blocks {
            guard let descriptor = descriptors[block.id] else { throw Failure.invalidResult }
            var ranges = [NativeDecompilerWireSourceRange]()
            for instruction in members[block.id, default: []] {
                let end = try checkedEnd(instruction.address.value, byteCount: instruction.bytes.count)
                if let last = ranges.last, last.endAddressExclusive == instruction.address {
                    ranges[ranges.count - 1] = .init(imageID: last.imageID, startAddress: last.startAddress,
                        endAddressExclusive: .init(end))
                } else {
                    ranges.append(.init(imageID: request.image.imageID, startAddress: instruction.address,
                        endAddressExclusive: .init(end)))
                }
            }
            guard !ranges.isEmpty, descriptor.sourceRanges == ranges,
                  block.startAddress == ranges.first?.startAddress,
                  block.endAddressExclusive == ranges.last?.endAddressExclusive,
                  boundaries.contains(descriptor.entryAddress.value),
                  ranges.contains(where: { descriptor.entryAddress.value >= $0.startAddress.value &&
                      descriptor.entryAddress.value < $0.endAddressExclusive.value })
            else { throw Failure.invalidResult }
            for (sequence, id) in block.operationIDs.enumerated() {
                guard let operation = operations[id], operation.blockID == block.id,
                      operation.sequence.value == UInt64(sequence), ownedOperations.insert(id).inserted
                else { throw Failure.invalidResult }
            }
        }
        guard ownedOperations.count == result.operations.count else { throw Failure.invalidResult }

        var metadataByEdge = [String: NativeDecompilerWireBlockPartitionEdge]()
        var outgoing = [String: [UInt32: NativeDecompilerWireEdgeRecord]]()
        var incoming = [String: [UInt32: NativeDecompilerWireEdgeRecord]]()
        for (index, metadata) in partition.edges.enumerated() {
            guard let edge = edges[metadata.edgeID],
                  index == 0 || partition.edges[index - 1].edgeID < metadata.edgeID,
                  metadataByEdge.updateValue(metadata, forKey: metadata.edgeID) == nil,
                  let source = blocks[edge.sourceBlockID], let targetID = edge.targetBlockID,
                  let target = blocks[targetID], edge.targetAddress == descriptors[targetID]?.entryAddress,
                  Int(metadata.sourceSlot) < source.successorEdgeIDs.count,
                  Int(metadata.targetSlot) < target.predecessorEdgeIDs.count,
                  outgoing[edge.sourceBlockID, default: [:]].updateValue(edge, forKey: metadata.sourceSlot) == nil,
                  incoming[targetID, default: [:]].updateValue(edge, forKey: metadata.targetSlot) == nil
            else { throw Failure.invalidResult }
        }
        for block in result.blocks {
            let outs = outgoing[block.id, default: [:]]
            let ins = incoming[block.id, default: [:]]
            guard outs.count == block.successorEdgeIDs.count, ins.count == block.predecessorEdgeIDs.count,
                  Set(outs.values.map(\.id)) == Set(block.successorEdgeIDs),
                  Set(ins.values.map(\.id)) == Set(block.predecessorEdgeIDs)
            else { throw Failure.invalidResult }
        }
        guard incoming[partition.entryBlockID, default: [:]].isEmpty else { throw Failure.invalidResult }
        var traversal = [partition.entryBlockID]
        var visited: Set<String> = [partition.entryBlockID]
        var cursor = 0
        while cursor < traversal.count {
            let blockID = traversal[cursor]
            guard descriptors[blockID]?.ordinal == UInt32(cursor) else { throw Failure.invalidResult }
            let successors = outgoing[blockID, default: [:]]
            for slot in 0..<successors.count {
                guard let targetID = successors[UInt32(slot)]?.targetBlockID else { throw Failure.invalidResult }
                if visited.insert(targetID).inserted { traversal.append(targetID) }
            }
            cursor += 1
        }
        guard traversal.count == blocks.count else { throw Failure.invalidResult }

        for block in result.blocks {
            let successors = outgoing[block.id, default: [:]]
            let last = block.operationIDs.last.flatMap { operations[$0] }
            func checkEdge(_ edge: NativeDecompilerWireEdgeRecord,
                           kind: NativeDecompilerWireEdgeKind,
                           transfer: NativeDecompilerWireTransferKind,
                           operationRequired: Bool) throws {
                guard edge.kind == kind, metadataByEdge[edge.id]?.transferKind == transfer,
                      operationRequired ? (last != nil && edge.operationID == last?.id) : edge.operationID == nil
                else { throw Failure.invalidResult }
            }
            func checkDirect(_ edge: NativeDecompilerWireEdgeRecord) throws {
                guard let last, edge.operationID == last.id, let operandID = last.inputVarnodeIDs.first,
                      let metadata = metadataByEdge[edge.id] else { throw Failure.invalidResult }
                if metadata.transferKind == .intraInstruction || metadata.transferKind == .rewrittenIntraInstruction {
                    guard last.directTargetAddress == nil, let operand = varnodes[operandID],
                          spaces[operand.addressSpaceID]?.kind == .constant,
                          let instructionID = operationInstructions[last.id], let targetID = edge.targetBlockID,
                          instructionBlocks[instructionID]?.contains(targetID) == (metadata.transferKind == .intraInstruction)
                    else { throw Failure.invalidResult }
                } else {
                    guard let target = last.directTargetAddress, boundaries.contains(target.value),
                          (metadata.transferKind == .direct && target == edge.targetAddress) ||
                          (metadata.transferKind == .rewrittenDirect && target != edge.targetAddress)
                    else { throw Failure.invalidResult }
                }
            }
            guard let last else {
                guard (successors.isEmpty && block.terminatorKind == .exit) ||
                      (successors.count == 1 && block.terminatorKind == .splice)
                else { throw Failure.invalidResult }
                for edge in successors.values { try checkEdge(edge, kind: .splice, transfer: .splice, operationRequired: false) }
                continue
            }
            switch last.opcode {
            case .return:
                guard successors.isEmpty, block.terminatorKind == .return else { throw Failure.invalidResult }
            case .branch:
                guard successors.count == 1, block.terminatorKind == .branch,
                      let edge = successors[0], edge.kind == .branch else { throw Failure.invalidResult }
                try checkDirect(edge)
            case .cbranch:
                guard successors.count == 2, block.terminatorKind == .conditional,
                      successors[0]?.kind == .falseBranch, successors[1]?.kind == .trueBranch
                else { throw Failure.invalidResult }
                var fallthroughCount = 0
                for edge in successors.values {
                    guard edge.operationID == last.id else { throw Failure.invalidResult }
                    if metadataByEdge[edge.id]?.transferKind == .fallthrough { fallthroughCount += 1 }
                    else { try checkDirect(edge) }
                }
                guard fallthroughCount == 1 else { throw Failure.invalidResult }
            case .branchind:
                guard !successors.isEmpty, block.terminatorKind == .switch else { throw Failure.invalidResult }
                var defaults = 0
                for edge in successors.values {
                    guard edge.kind == .switchCase || edge.kind == .switchDefault else { throw Failure.invalidResult }
                    if edge.kind == .switchDefault { defaults += 1 }
                    try checkEdge(edge, kind: edge.kind, transfer: .indirect, operationRequired: true)
                }
                guard defaults == 1 else { throw Failure.invalidResult }
            default:
                guard (successors.isEmpty && block.terminatorKind == .exit) ||
                      (successors.count == 1 && block.terminatorKind == .fallthrough)
                else { throw Failure.invalidResult }
                for edge in successors.values { try checkEdge(edge, kind: .fallthrough, transfer: .fallthrough, operationRequired: false) }
            }
        }
        for phi in result.phis {
            let predecessors = incoming[phi.blockID, default: [:]]
            guard blocks[phi.blockID] != nil, phi.incoming.count == predecessors.count else { throw Failure.invalidResult }
            for (slot, value) in phi.incoming.enumerated() {
                guard let edge = predecessors[UInt32(slot)], value.edgeID == edge.id,
                      value.sourceBlockID == edge.sourceBlockID else { throw Failure.invalidResult }
            }
        }
    }
}
