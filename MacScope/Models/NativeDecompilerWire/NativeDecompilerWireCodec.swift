import Foundation

enum NativeDecompilerWireCodecError: Error, Equatable, Sendable {
    case requestTooLarge
    case responseTooLarge
    case malformedPropertyList
    case invalidShape
    case invalidValue
    case unsupportedSchemaVersion
    case requestIDMismatch
    case requestBindingMismatch
    case successRequiresRequestBinding
    case unsupportedCompiler
}

struct NativeDecompilerWireCodec: Sendable {
    static let maximumRequestBytes = 32 * 1_024 * 1_024
    static let maximumResponseBytes = 64 * 1_024 * 1_024

    func encodeRequest(
        _ request: NativeDecompilerWireRequestEnvelope,
        matching expectedRequestID: UUID
    ) throws -> Data {
        try validate(request, matching: expectedRequestID)
        let data = try encode(request)
        guard data.count <= Self.maximumRequestBytes else {
            throw NativeDecompilerWireCodecError.requestTooLarge
        }
        return data
    }

    func decodeRequest(
        _ data: Data,
        matching expectedRequestID: UUID
    ) throws -> NativeDecompilerWireRequestEnvelope {
        guard data.count <= Self.maximumRequestBytes else {
            throw NativeDecompilerWireCodecError.requestTooLarge
        }
        let object = try propertyListObject(data)
        guard let dictionary = object as? [String: Any],
              let version = dictionary["schemaVersion"] as? NSNumber else {
            throw NativeDecompilerWireCodecError.invalidShape
        }
        switch version.uint64Value {
        case 3: try Self.requestShape.validate(object)
        case 4: try Self.sparseRequestShape.validate(object)
        default: throw NativeDecompilerWireCodecError.unsupportedSchemaVersion
        }
        try requireCanonicalUUIDs(in: object, paths: [
            ["requestID"], ["body", "requestID"], ["body", "image", "uuid"],
        ])
        let request: NativeDecompilerWireRequestEnvelope = try decode(data)
        guard try encode(request) == data else {
            throw NativeDecompilerWireCodecError.malformedPropertyList
        }
        try validate(request, matching: expectedRequestID)
        return request
    }

    func encodeReply(
        _ reply: NativeDecompilerWireReplyEnvelope,
        matching expectedRequestID: UUID
    ) throws -> Data {
        try validate(reply, matching: expectedRequestID, expectedBinding: nil)
        let data = try encode(reply)
        guard data.count <= Self.maximumResponseBytes else {
            throw NativeDecompilerWireCodecError.responseTooLarge
        }
        return data
    }

    func encodeReply(
        _ reply: NativeDecompilerWireReplyEnvelope,
        matching expectedBinding: NativeDecompilerWireExpectedRequestBinding
    ) throws -> Data {
        try validate(
            reply,
            matching: expectedBinding.requestID,
            expectedBinding: expectedBinding
        )
        let data = try encode(reply)
        guard data.count <= Self.maximumResponseBytes else {
            throw NativeDecompilerWireCodecError.responseTooLarge
        }
        return data
    }

    func decodeReply(
        _ data: Data,
        matching expectedRequestID: UUID
    ) throws -> NativeDecompilerWireReplyEnvelope {
        try decodeReply(data, expectedRequestID: expectedRequestID, expectedBinding: nil)
    }

    func decodeReply(
        _ data: Data,
        matching expectedBinding: NativeDecompilerWireExpectedRequestBinding
    ) throws -> NativeDecompilerWireReplyEnvelope {
        try decodeReply(
            data,
            expectedRequestID: expectedBinding.requestID,
            expectedBinding: expectedBinding
        )
    }

    private func decodeReply(
        _ data: Data,
        expectedRequestID: UUID,
        expectedBinding: NativeDecompilerWireExpectedRequestBinding?
    ) throws -> NativeDecompilerWireReplyEnvelope {
        guard data.count <= Self.maximumResponseBytes else {
            throw NativeDecompilerWireCodecError.responseTooLarge
        }
        let object = try propertyListObject(data)
        guard let dictionary = object as? [String: Any],
              let outcome = dictionary["outcome"] as? String
        else {
            throw NativeDecompilerWireCodecError.invalidShape
        }
        guard let version = dictionary["schemaVersion"] as? NSNumber,
              version.uint64Value == 3 || version.uint64Value == 4 else {
            throw NativeDecompilerWireCodecError.unsupportedSchemaVersion
        }
        switch outcome {
        case NativeDecompilerWireReplyOutcome.success.rawValue:
            if expectedBinding?.schemaVersion == NativeDecompilerWireRequestEnvelope.sparseCodeSchemaVersion {
                try Self.sparseSuccessReplyShape.validate(object)
            } else {
                try Self.successReplyShape.validate(object)
            }
        case NativeDecompilerWireReplyOutcome.failure.rawValue:
            try Self.failureReplyShape.validate(object)
        default:
            throw NativeDecompilerWireCodecError.invalidValue
        }
        var uuidPaths = [["requestID"]]
        if outcome == NativeDecompilerWireReplyOutcome.success.rawValue {
            uuidPaths.append(["success", "result", "requestID"])
            uuidPaths.append(["success", "result", "image", "uuid"])
        }
        try requireCanonicalUUIDs(in: object, paths: uuidPaths)
        let reply: NativeDecompilerWireReplyEnvelope = try decode(data)
        let swiftCanonical = try encode(reply)
        if swiftCanonical != data {
            let foundationCanonical = try? PropertyListSerialization.data(
                fromPropertyList: object,
                format: .binary,
                options: 0
            )
            guard foundationCanonical == data else {
                throw NativeDecompilerWireCodecError.malformedPropertyList
            }
        }
        try validate(reply, matching: expectedRequestID, expectedBinding: expectedBinding)
        return reply
    }
}

private extension NativeDecompilerWireCodec {
    func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            return try encoder.encode(value)
        } catch {
            throw NativeDecompilerWireCodecError.invalidValue
        }
    }

    func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try PropertyListDecoder().decode(Value.self, from: data)
        } catch {
            throw NativeDecompilerWireCodecError.invalidValue
        }
    }

    func propertyListObject(_ data: Data) throws -> Any {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let object: Any
        do {
            try NativeDecompilerWireBinaryPropertyListValidator.validate(data)
            object = try PropertyListSerialization.propertyList(
                from: data, options: [], format: &format
            )
        } catch {
            throw NativeDecompilerWireCodecError.malformedPropertyList
        }
        guard format == .binary else {
            throw NativeDecompilerWireCodecError.malformedPropertyList
        }
        return object
    }

    func validate(
        _ envelope: NativeDecompilerWireRequestEnvelope,
        matching expectedRequestID: UUID
    ) throws {
        guard envelope.schemaVersion == NativeDecompilerWireRequestEnvelope.currentSchemaVersion ||
              envelope.schemaVersion == NativeDecompilerWireRequestEnvelope.sparseCodeSchemaVersion else {
            throw NativeDecompilerWireCodecError.unsupportedSchemaVersion
        }
        guard envelope.requestID == expectedRequestID,
              envelope.body.requestID == expectedRequestID
        else {
            throw NativeDecompilerWireCodecError.requestIDMismatch
        }
        let request = envelope.body
        guard let rawCPUType = UInt32(request.target.rawCPUType, radix: 16),
              let rawCPUSubtype = UInt32(request.target.rawCPUSubtype, radix: 16),
              let sealedTarget = try? NativeDecompilerSealedTargetProfile.normalizedTarget(
                  rawCPUType: rawCPUType,
                  rawCPUSubtype: rawCPUSubtype,
                  selectedSliceSHA256: request.target.selectedSliceSHA256,
                  selectedSliceByteCount: request.target.selectedSliceByteCount.value,
                  allowDisabledProfiles: true
              ),
              sealedTarget == request.target,
              NativeDecompilerProductBudgetProfile.sealed(request.budgets) != nil,
              (try? NativeDecompilerWireCanonicalRequest.canonicalAuthoredInputBytes(
                  request.authoredInputs
              )) != nil
        else {
            throw NativeDecompilerWireCodecError.invalidValue
        }
        guard Self.isSHA256(request.requestSHA256),
              Self.isText(request.image.imageID, maximum: 256),
              Self.isText(request.function.functionID, maximum: 256),
              Self.isText(request.function.name, maximum: 1_024),
              request.function.entryAddress.value < request.function.endAddressExclusive.value,
              !request.memoryRegions.isEmpty,
              request.memoryRegions.count <= 256,
              request.symbols.count <= 100_000,
              request.budgets.maxCodeBytes > 0,
              request.budgets.maxInstructions > 0,
              request.budgets.maxOperations > 0,
              request.budgets.maxOutputBytes > 0,
              request.budgets.maxOutputBytes <= UInt32(Self.maximumResponseBytes),
              request.budgets.maxWallTimeMilliseconds.value > 0
        else {
            throw NativeDecompilerWireCodecError.invalidValue
        }

        let codeRanges: [NativeDecompilerWireCodeRange]
        if envelope.schemaVersion == NativeDecompilerWireRequestEnvelope.currentSchemaVersion {
            guard request.function.codeRanges == nil else {
                throw NativeDecompilerWireCodecError.invalidShape
            }
            let functionSize = request.function.endAddressExclusive.value
                - request.function.entryAddress.value
            guard functionSize <= UInt64(request.budgets.maxCodeBytes) else {
                throw NativeDecompilerWireCodecError.invalidValue
            }
            codeRanges = [.init(
                startAddress: request.function.entryAddress,
                endAddressExclusive: request.function.endAddressExclusive
            )]
        } else {
            guard let ranges = request.function.codeRanges,
                  !ranges.isEmpty, ranges.count <= 64,
                  ranges.first?.startAddress == request.function.entryAddress,
                  ranges.last?.endAddressExclusive == request.function.endAddressExclusive
            else { throw NativeDecompilerWireCodecError.invalidShape }
            var priorEnd: UInt64?
            var coveredBytes: UInt64 = 0
            let codeAlignment: UInt64 = request.target.normalizedVariant == .x86_64 ? 1 : 4
            for range in ranges {
                let start = range.startAddress.value
                let end = range.endAddressExclusive.value
                guard start < end, start % codeAlignment == 0, end % codeAlignment == 0,
                      priorEnd.map({ start >= $0 }) ?? true,
                      end - start <= UInt64(request.budgets.maxCodeBytes) - coveredBytes
                else { throw NativeDecompilerWireCodecError.invalidValue }
                coveredBytes += end - start
                priorEnd = end
            }
            codeRanges = ranges
        }

        let sortedRegions = request.memoryRegions.sorted {
            if $0.startAddress.value != $1.startAddress.value {
                return $0.startAddress.value < $1.startAddress.value
            }
            return $0.name < $1.name
        }
        var priorEnd: UInt64?
        var totalRegionBytes = 0
        var patchIDs = Set<String>()
        for region in sortedRegions {
            guard Self.isText(region.name, maximum: 256),
                  !region.rawBytes.isEmpty,
                  region.rawBytes.count == region.effectiveBytes.count,
                  region.rawBytes.count <= (64 * 1_024 * 1_024) - totalRegionBytes,
                  region.startAddress.value <= UInt64.max - UInt64(region.rawBytes.count)
            else {
                throw NativeDecompilerWireCodecError.invalidValue
            }
            totalRegionBytes += region.rawBytes.count
            let end = region.startAddress.value + UInt64(region.rawBytes.count)
            if let priorEnd, region.startAddress.value < priorEnd {
                throw NativeDecompilerWireCodecError.invalidValue
            }
            priorEnd = end
            var priorPatchID: String?
            for patchID in region.appliedPatchIDs {
                guard Self.isCanonicalPatchID(patchID),
                      priorPatchID.map({ $0 < patchID }) ?? true,
                      patchIDs.insert(patchID).inserted
                else {
                    throw NativeDecompilerWireCodecError.invalidValue
                }
                priorPatchID = patchID
            }
        }

        for range in codeRanges {
            var coverageCursor = range.startAddress.value
            for region in sortedRegions {
                let regionEnd = region.startAddress.value + UInt64(region.rawBytes.count)
                if regionEnd <= coverageCursor { continue }
                if region.startAddress.value > coverageCursor { break }
                guard region.permissions.rawValue.first == "r",
                      region.permissions.rawValue.last == "x"
                else { throw NativeDecompilerWireCodecError.invalidValue }
                coverageCursor = min(range.endAddressExclusive.value, regionEnd)
                if coverageCursor == range.endAddressExclusive.value { break }
            }
            guard coverageCursor == range.endAddressExclusive.value else {
                throw NativeDecompilerWireCodecError.invalidValue
            }
        }

        let sortedSymbols = request.symbols.sorted(by: Self.symbolLess)
        for symbol in sortedSymbols {
            guard Self.isText(symbol.imageID, maximum: 256),
                  symbol.imageID == request.image.imageID,
                  Self.isText(symbol.name, maximum: 1_024),
                  Self.isText(symbol.kind.rawValue, maximum: 256)
            else { throw NativeDecompilerWireCodecError.invalidValue }
        }
        for index in sortedSymbols.indices.dropFirst() where
            Self.symbolsEqual(sortedSymbols[index - 1], sortedSymbols[index]) {
            throw NativeDecompilerWireCodecError.invalidValue
        }

        let canonicalRequestSHA256 = try? NativeDecompilerWireCanonicalRequest.sha256(
            schemaVersion: envelope.schemaVersion,
            operation: envelope.operation,
            target: request.target,
            image: request.image,
            function: request.function,
            memoryRegions: request.memoryRegions,
            symbols: request.symbols,
            authoredInputs: request.authoredInputs,
            budgets: NativeDecompilerProductBudgetProfile.sealed(request.budgets)
                ?? NativeDecompilerProductBudgetProfile.v1
        )
        guard canonicalRequestSHA256 == request.requestSHA256 else {
            throw NativeDecompilerWireCodecError.requestBindingMismatch
        }

    }

    func validate(
        _ envelope: NativeDecompilerWireReplyEnvelope,
        matching expectedRequestID: UUID,
        expectedBinding: NativeDecompilerWireExpectedRequestBinding?
    ) throws {
        guard envelope.schemaVersion == NativeDecompilerWireReplyEnvelope.legacySchemaVersion ||
              envelope.schemaVersion == NativeDecompilerWireReplyEnvelope.currentSchemaVersion else {
            throw NativeDecompilerWireCodecError.unsupportedSchemaVersion
        }
        guard envelope.requestID == expectedRequestID else {
            throw NativeDecompilerWireCodecError.requestIDMismatch
        }
        switch envelope.outcome {
        case .success:
            guard let success = envelope.success, envelope.failure == nil else {
                throw NativeDecompilerWireCodecError.invalidShape
            }
            guard envelope.schemaVersion >= success.result.requiredReplySchemaVersion else {
                throw NativeDecompilerWireCodecError.unsupportedSchemaVersion
            }
            guard let expectedBinding else {
                throw NativeDecompilerWireCodecError.successRequiresRequestBinding
            }
            guard envelope.schemaVersion >= expectedBinding.schemaVersion else {
                throw NativeDecompilerWireCodecError.unsupportedSchemaVersion
            }
            try validate(success, matching: expectedBinding)
        case .failure:
            guard envelope.success == nil, let failure = envelope.failure else {
                throw NativeDecompilerWireCodecError.invalidShape
            }
            if let detail = failure.detail {
                guard Self.isSanitizedDetail(detail) else {
                    throw NativeDecompilerWireCodecError.invalidValue
                }
            }
        }
    }

    func validate(
        _ success: NativeDecompilerWireSuccess,
        matching expectedBinding: NativeDecompilerWireExpectedRequestBinding
    ) throws {
        let availability = success.availability
        let identity = availability.runtimeIdentity
        guard availability.available,
              availability.reasonCode.isEmpty,
              Self.isText(identity.backendID, maximum: 1_024),
              Self.isText(identity.engineVersion, maximum: 1_024),
              Self.isRevision(identity.engineRevision),
              Self.isText(identity.wrapperVersion, maximum: 1_024),
              Self.isRevision(identity.wrapperRevision),
              Self.isSHA256(identity.packageManifestSHA256),
              Self.isSHA256(identity.packageTreeSHA256),
              identity.languageID == expectedBinding.analysisRequest.target.languageID,
              identity.compilerSpecID == expectedBinding.analysisRequest.target.compilerSpecID,
              identity.targetProfileID == expectedBinding.analysisRequest.target.profileID,
              identity.contextProfileSHA256 ==
                expectedBinding.analysisRequest.target.contextProfileSHA256,
              availability.capabilities.nativeDecompilerHeritage,
              availability.capabilities.imageQualifiedSourceRanges
        else {
            throw NativeDecompilerWireCodecError.invalidValue
        }
        let request = expectedBinding.analysisRequest
        guard request.requestID == expectedBinding.requestID,
              request.requestSHA256 == expectedBinding.requestSHA256,
              request.image == expectedBinding.image,
              request.function == expectedBinding.function
        else {
            throw NativeDecompilerWireCodecError.requestBindingMismatch
        }
        try validate(
            NativeDecompilerWireRequestEnvelope(
                schemaVersion: expectedBinding.schemaVersion,
                requestID: expectedBinding.requestID,
                operation: expectedBinding.operation,
                body: request
            ),
            matching: expectedBinding.requestID
        )

        let result = success.result
        guard result.requestID == expectedBinding.requestID,
              result.requestSHA256 == expectedBinding.requestSHA256,
              result.image == expectedBinding.image,
              result.function == expectedBinding.function
        else {
            throw NativeDecompilerWireCodecError.requestBindingMismatch
        }

        do {
            try NativeDecompilerWireSemanticValidator.validate(
                request: request,
                schemaVersion: expectedBinding.schemaVersion,
                operation: expectedBinding.operation,
                capabilities: availability.capabilities,
                result: result
            )
        } catch {
            throw NativeDecompilerWireCodecError.invalidValue
        }
    }

    static func isText(_ value: String, maximum: Int) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= maximum
            && !bytes.contains(where: { $0 < 0x20 || $0 == 0x7F })
    }

    static func isSanitizedDetail(_ value: String) -> Bool {
        isText(value, maximum: 1_024)
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("0x")
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(Self.isLowerHex)
    }

    static func isRevision(_ value: String) -> Bool {
        (value.utf8.count == 40 || value.utf8.count == 64)
            && value.utf8.allSatisfy(Self.isLowerHex)
    }

    static func isLowerHex(_ value: UInt8) -> Bool {
        (value >= 48 && value <= 57) || (value >= 97 && value <= 102)
    }

    static func isCanonicalPatchID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.hasPrefix("patch")
            && value.utf8.dropFirst(5).allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    static func symbolLess(
        _ lhs: NativeDecompilerWireSymbolRecord,
        _ rhs: NativeDecompilerWireSymbolRecord
    ) -> Bool {
        if lhs.address.value != rhs.address.value { return lhs.address.value < rhs.address.value }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.imageID < rhs.imageID
    }

    static func symbolsEqual(
        _ lhs: NativeDecompilerWireSymbolRecord,
        _ rhs: NativeDecompilerWireSymbolRecord
    ) -> Bool {
        lhs.address == rhs.address && lhs.kind == rhs.kind && lhs.name == rhs.name
            && lhs.imageID == rhs.imageID
    }

    static func typeHintLess(
        _ lhs: NativeDecompilerWireTypeHintRecord,
        _ rhs: NativeDecompilerWireTypeHintRecord
    ) -> Bool {
        if lhs.address.value != rhs.address.value { return lhs.address.value < rhs.address.value }
        if lhs.subjectKind.rawValue != rhs.subjectKind.rawValue {
            return lhs.subjectKind.rawValue < rhs.subjectKind.rawValue
        }
        if lhs.typeName != rhs.typeName { return lhs.typeName < rhs.typeName }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        return lhs.confidence.rawValue < rhs.confidence.rawValue
    }

    static func typeHintsEqual(
        _ lhs: NativeDecompilerWireTypeHintRecord,
        _ rhs: NativeDecompilerWireTypeHintRecord
    ) -> Bool {
        lhs.address == rhs.address && lhs.subjectKind == rhs.subjectKind
            && lhs.typeName == rhs.typeName && lhs.source == rhs.source
            && lhs.confidence == rhs.confidence
    }

    func requireCanonicalUUIDs(in object: Any, paths: [[String]]) throws {
        for path in paths {
            var cursor: Any = object
            for component in path {
                guard let dictionary = cursor as? [String: Any], let next = dictionary[component] else {
                    throw NativeDecompilerWireCodecError.invalidShape
                }
                cursor = next
            }
            guard let string = cursor as? String,
                  let uuid = UUID(uuidString: string),
                  uuid.uuidString == string
            else {
                throw NativeDecompilerWireCodecError.invalidValue
            }
        }
    }
}

private indirect enum NativeDecompilerWireShape: Sendable {
    case unrestricted
    case scalar
    case array(NativeDecompilerWireShape)
    case object(required: [String: NativeDecompilerWireShape], optional: [String: NativeDecompilerWireShape] = [:])

    func validate(_ value: Any) throws {
        switch self {
        case .unrestricted:
            return
        case .scalar:
            guard value is String || value is Data || value is NSNumber else {
                throw NativeDecompilerWireCodecError.invalidShape
            }
        case .array(let element):
            guard let array = value as? [Any] else {
                throw NativeDecompilerWireCodecError.invalidShape
            }
            for value in array { try element.validate(value) }
        case .object(let required, let optional):
            guard let dictionary = value as? [String: Any] else {
                throw NativeDecompilerWireCodecError.invalidShape
            }
            let keys = Set(dictionary.keys)
            guard keys.isSubset(of: Set(required.keys).union(optional.keys)),
                  keys.isSuperset(of: required.keys)
            else {
                throw NativeDecompilerWireCodecError.invalidShape
            }
            for (key, shape) in required { try shape.validate(dictionary[key]!) }
            for (key, shape) in optional where dictionary[key] != nil {
                try shape.validate(dictionary[key]!)
            }
        }
    }
}

private extension NativeDecompilerWireCodec {
    static let scalar = NativeDecompilerWireShape.scalar
    static let unrestricted = NativeDecompilerWireShape.unrestricted
    static func array(_ element: NativeDecompilerWireShape = .scalar) -> NativeDecompilerWireShape { .array(element) }
    static func object(
        _ required: [String: NativeDecompilerWireShape],
        optional: [String: NativeDecompilerWireShape] = [:]
    ) -> NativeDecompilerWireShape { .object(required: required, optional: optional) }

    static let imageShape = object([
        "imageID": scalar, "uuid": scalar, "preferredLoadAddress": scalar,
    ])
    static let functionShape = object([
        "functionID": scalar, "name": scalar, "entryAddress": scalar,
        "endAddressExclusive": scalar,
    ])
    static let sparseFunctionShape = object([
        "functionID": scalar, "name": scalar, "entryAddress": scalar,
        "endAddressExclusive": scalar,
        "codeRanges": array(object([
        "startAddress": scalar, "endAddressExclusive": scalar,
        ])),
    ])
    static let sourceRangeShape = object([
        "imageID": scalar, "startAddress": scalar, "endAddressExclusive": scalar,
    ])
    static func makeRequestShape(function: NativeDecompilerWireShape) -> NativeDecompilerWireShape { object([
        "schemaVersion": scalar, "requestID": scalar, "operation": scalar,
        "body": object([
            "requestID": scalar, "requestSHA256": scalar,
            "target": object([
                "rawCPUType": scalar, "rawCPUSubtype": scalar,
                "normalizedVariant": scalar, "recognizedCapabilityBits": scalar,
                "selectedSliceSHA256": scalar, "selectedSliceByteCount": scalar,
                "profileID": scalar, "languageID": scalar, "compilerSpecID": scalar,
                "contextProfileSHA256": scalar,
                "context": array(object(["name": scalar, "value": scalar])),
            ], optional: ["pointerAuthABIVersion": scalar]),
            "image": imageShape, "function": function,
            "memoryRegions": array(object([
                "name": scalar, "startAddress": scalar, "permissions": scalar,
                "rawBytes": scalar, "effectiveBytes": scalar, "appliedPatchIDs": array(),
            ])),
            "symbols": array(object([
                "imageID": scalar, "address": scalar, "name": scalar, "kind": scalar,
            ])),
            "authoredInputs": unrestricted,
            "budgets": object([
                "profileID": scalar,
                "maxCodeBytes": scalar, "maxInstructions": scalar, "maxOperations": scalar,
                "maxOutputBytes": scalar, "maxWallTimeMilliseconds": scalar,
            ]),
        ]),
    ]) }
    static let requestShape = makeRequestShape(function: functionShape)
    static let sparseRequestShape = makeRequestShape(function: sparseFunctionShape)

    static let backendIdentityShape = object([
        "backendID": scalar, "engineVersion": scalar, "engineRevision": scalar,
        "wrapperVersion": scalar, "wrapperRevision": scalar,
        "packageManifestSHA256": scalar, "packageTreeSHA256": scalar,
        "languageID": scalar, "compilerSpecID": scalar, "targetProfileID": scalar,
        "contextProfileSHA256": scalar,
    ])
    static let capabilitiesShape = object([
        "nativeDecompilerHeritage": scalar, "completeRegisterSSA": scalar,
        "memorySSA": scalar, "recoveredVariables": scalar, "recoveredTypes": scalar,
        "structuredControlFlow": scalar, "tokenizedPseudocode": scalar,
        "imageQualifiedSourceRanges": scalar,
    ])
    static let availabilityShape = object([
        "available": scalar, "reasonCode": scalar, "runtimeIdentity": backendIdentityShape,
        "capabilities": capabilitiesShape,
    ])
    static let typeFieldShape = object([
        "name": scalar, "typeID": scalar, "bitOffset": scalar, "bitSize": scalar,
    ])
    static let typeShape = object([
        "id": scalar, "kind": scalar, "name": scalar, "fields": array(typeFieldShape),
        "confidence": scalar, "provenance": scalar, "parameterTypeIDs": array(),
    ], optional: [
        "byteSize": scalar, "isSigned": scalar, "pointeeTypeID": scalar,
        "returnTypeID": scalar,
    ])
    static let instructionShape = object([
        "id": scalar, "address": scalar, "bytes": scalar, "mnemonic": scalar, "body": scalar,
        "operationIDs": array(), "sourceRanges": array(sourceRangeShape),
    ])
    static let varnodeShape = object([
        "id": scalar, "addressSpaceID": scalar, "offset": scalar, "sizeBytes": scalar,
        "role": scalar,
    ], optional: ["typeID": scalar, "registerName": scalar])
    static let operationShape = object([
        "id": scalar, "blockID": scalar, "sequence": scalar, "opcode": scalar,
        "inputVarnodeIDs": array(), "sourceRanges": array(sourceRangeShape),
        "authenticationEffect": object(["kind": scalar], optional: ["outputSSAValueID": scalar]),
    ], optional: ["outputVarnodeID": scalar, "directTargetAddress": scalar, "userOperationName": scalar])
    static let blockShape = object([
        "id": scalar, "startAddress": scalar, "endAddressExclusive": scalar,
        "operationIDs": array(), "predecessorEdgeIDs": array(), "successorEdgeIDs": array(),
        "terminatorKind": scalar,
    ])
    static let edgeShape = object([
        "id": scalar, "sourceBlockID": scalar, "targetAddress": scalar, "kind": scalar,
    ], optional: ["targetBlockID": scalar, "operationID": scalar])
    static let ssaValueShape = object([
        "id": scalar, "varnodeID": scalar, "kind": scalar,
    ], optional: ["definingOperationID": scalar, "definingPhiID": scalar])
    static let ssaBindingShape = object([
        "operationID": scalar, "inputSSAValueIDs": array(),
    ], optional: ["outputSSAValueID": scalar])
    static let phiIncomingShape = object([
        "ssaValueID": scalar,
    ], optional: ["sourceBlockID": scalar, "edgeID": scalar])
    static let phiShape = object([
        "id": scalar, "blockID": scalar, "varnodeID": scalar, "outputSSAValueID": scalar,
        "incoming": array(phiIncomingShape),
    ])
    static let memoryVersionShape = object([
        "id": scalar, "partition": scalar, "kind": scalar,
    ], optional: ["definingOperationID": scalar, "definingMemoryPhiID": scalar])
    static let memoryPhiIncomingShape = object([
        "memoryVersionID": scalar,
    ], optional: ["sourceBlockID": scalar, "edgeID": scalar])
    static let memoryPhiShape = object([
        "id": scalar, "blockID": scalar, "partition": scalar,
        "outputMemoryVersionID": scalar, "incoming": array(memoryPhiIncomingShape),
    ])
    static let memoryEffectShape = object([
        "id": scalar, "operationID": scalar, "kind": scalar, "partition": scalar,
    ], optional: ["inputMemoryVersionID": scalar, "outputMemoryVersionID": scalar])
    static let variableShape = object([
        "id": scalar, "name": scalar, "role": scalar, "storageVarnodeIDs": array(),
        "liveRanges": array(sourceRangeShape), "confidence": scalar, "provenance": scalar,
    ], optional: ["typeID": scalar])
    static let callShape = object([
        "id": scalar, "operationID": scalar, "kind": scalar,
        "argumentVariableIDs": array(), "sourceRanges": array(sourceRangeShape),
    ], optional: [
        "targetAddress": scalar, "targetSymbol": scalar, "prototypeTypeID": scalar,
        "resultVariableID": scalar,
    ])
    static let regionShape = object([
        "id": scalar, "kind": scalar, "childRegionIDs": array(), "blockIDs": array(),
        "sourceRanges": array(sourceRangeShape),
    ], optional: ["parentRegionID": scalar, "conditionOperationID": scalar])
    static let entityReferenceShape = object(["kind": scalar, "id": scalar])
    static let tokenShape = object([
        "id": scalar, "text": scalar, "kind": scalar, "line": scalar, "column": scalar,
        "sourceRanges": array(sourceRangeShape), "entityReferences": array(entityReferenceShape),
    ])
    static let pseudocodeDocumentShape = object([
        "text": scalar, "language": scalar, "isComplete": scalar, "isTruncated": scalar,
    ])
    static let diagnosticShape = object([
        "code": scalar, "severity": scalar, "message": scalar,
        "sourceRanges": array(sourceRangeShape),
    ])
    static let blockPartitionShape = object([
        "version": scalar, "entryBlockID": scalar,
        "blocks": array(object([
            "blockID": scalar, "ordinal": scalar, "entryAddress": scalar,
            "sourceRanges": array(sourceRangeShape),
        ])),
        "instructions": array(object([
            "instructionID": scalar, "disposition": scalar,
            "spans": array(object([
                "blockID": scalar, "firstOperationIndex": scalar, "operationCount": scalar,
            ])),
        ])),
        "edges": array(object([
            "edgeID": scalar, "sourceSlot": scalar, "targetSlot": scalar, "transferKind": scalar,
        ])),
    ])
    static func makeStructuredResultShape(function: NativeDecompilerWireShape) -> NativeDecompilerWireShape { object([
        "requestID": scalar, "requestSHA256": scalar, "image": imageShape,
        "function": function,
        "addressSpaces": array(object([
            "id": scalar, "name": scalar, "kind": scalar, "addressSizeBytes": scalar,
            "isProcessorSpace": scalar,
        ])),
        "types": array(typeShape), "instructions": array(instructionShape),
        "varnodes": array(varnodeShape), "operations": array(operationShape),
        "blocks": array(blockShape), "edges": array(edgeShape),
        "ssaValues": array(ssaValueShape), "ssaBindings": array(ssaBindingShape),
        "phis": array(phiShape), "memoryVersions": array(memoryVersionShape),
        "memoryPhis": array(memoryPhiShape), "memoryEffects": array(memoryEffectShape),
        "variables": array(variableShape), "calls": array(callShape),
        "regions": array(regionShape), "tokens": array(tokenShape),
        "warnings": array(diagnosticShape),
    ], optional: ["pseudocodeDocument": pseudocodeDocumentShape, "blockPartition": blockPartitionShape]) }
    static func makeSuccessReplyShape(function: NativeDecompilerWireShape) -> NativeDecompilerWireShape { object([
        "schemaVersion": scalar, "requestID": scalar, "outcome": scalar,
        "success": object([
            "availability": availabilityShape,
            "result": makeStructuredResultShape(function: function),
        ]),
    ]) }
    static let successReplyShape = makeSuccessReplyShape(function: functionShape)
    static let sparseSuccessReplyShape = makeSuccessReplyShape(function: sparseFunctionShape)
    static let failureReplyShape = object([
        "schemaVersion": scalar, "requestID": scalar, "outcome": scalar,
        "failure": object(["code": scalar], optional: ["detail": scalar]),
    ])
}
