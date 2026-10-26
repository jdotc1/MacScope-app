import Foundation

enum NativeDecompilerWireAuthoredValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion
    case tooManyNames
    case tooManySignatures
    case tooManyParameters
    case tooManyAppliedTypes
    case tooManyTypeDefinitions
    case tooManyAggregateMembers
    case fixedArrayElementCountOutOfRange
    case computedStorageTooLarge
    case semanticNameTooLong
    case catalogTextTooLong
    case invalidText
    case invalidNumericValue
    case unknownQualifierBits
    case authoredDepthExceeded
    case invalidTaggedPayload
    case invalidPointer
    case invalidFieldStorage
    case duplicateName
    case duplicateSignature
    case duplicateAppliedType
    case duplicateTypeDefinition
    case canonicalAuthoredInputTooLarge
}

enum NativeDecompilerWireAuthoredTypeTag: UInt8, Sendable, Equatable, Hashable, Codable {
    case qualifiedValue = 0
    case dataPointer = 1
}

enum NativeDecompilerWireAuthoredAtomTag: UInt8, Sendable, Equatable, Hashable, Codable {
    case void = 0
    case scalar = 1
    case darwinAlias = 2
    case named = 3
}

enum NativeDecompilerWireAuthoredScalarKind: UInt8, Sendable, Equatable, Hashable, Codable {
    case bool = 0
    case char = 1
    case signed8 = 2
    case unsigned8 = 3
    case signed16 = 4
    case unsigned16 = 5
    case signed32 = 6
    case unsigned32 = 7
    case signed64 = 8
    case unsigned64 = 9
    case float32 = 10
    case float64 = 11
}

enum NativeDecompilerWireAuthoredDarwinAliasKind: UInt8, Sendable, Equatable, Hashable, Codable {
    case sizeT = 0
    case ssizeT = 1
    case intptrT = 2
    case uintptrT = 3
    case ptrdiffT = 4
    case wcharT = 5
}

enum NativeDecompilerWireAuthoredNamedKind: UInt8, Sendable, Equatable, Hashable, Codable {
    case `struct` = 0
    case union = 1
    case `enum` = 2
    case typedef = 3
}

enum NativeDecompilerWireAuthoredTypeDefinitionKind: UInt8, Sendable, Equatable, Hashable, Codable {
    case recordStruct = 0
    case recordUnion = 1
    case enumeration = 2
    case typedef = 3
}

enum NativeDecompilerWireAuthoredNameSubjectKind: UInt8, Sendable, Equatable, Hashable, Codable {
    case function = 0
    case label = 1
    case data = 2
}

enum NativeDecompilerWireAppliedTypeSubjectKind: UInt8, Sendable, Equatable, Hashable, Codable {
    case memoryObject = 0
}

enum NativeDecompilerWireAuthoredParameterListState: UInt8, Sendable, Equatable, Hashable, Codable {
    case unspecified = 0
    case authoritative = 1
}

enum NativeDecompilerWireAuthoredVariadicState: UInt8, Sendable, Equatable, Hashable, Codable {
    case unspecified = 0
    case fixed = 1
    case variadic = 2
}

enum NativeDecompilerWireAuthoredNoReturnState: UInt8, Sendable, Equatable, Hashable, Codable {
    case unspecified = 0
    case returns = 1
    case noReturn = 2
}

enum NativeDecompilerWireAuthoredFieldStorageTag: UInt8, Sendable, Equatable, Hashable, Codable {
    case value = 0
    case fixedArray = 1
    case flexibleArray = 2
    case opaquePointerCarrier = 3
    case inlineAggregate = 4
}

enum NativeDecompilerWireAuthoredOpaquePointerCarrierKind: UInt8, Sendable, Equatable, Hashable, Codable {
    case functionPointer = 0
    case pointerToArray = 1
}

enum NativeDecompilerWireAuthoredEnumRepresentation: UInt8, Sendable, Equatable, Hashable, Codable {
    case signed32 = 0
}

struct NativeDecompilerWireAuthoredQualifiers: OptionSet, Sendable, Equatable, Hashable, Codable {
    let rawValue: UInt8

    static let constant = Self(rawValue: 0x01)
    static let volatile = Self(rawValue: 0x02)
    static let restrict = Self(rawValue: 0x04)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(UInt8.self)
        guard rawValue & ~UInt8(0x07) == 0 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown authored qualifier bits."
            )
        }
        self.init(rawValue: rawValue)
    }

    func encode(to encoder: Encoder) throws {
        guard rawValue & ~UInt8(0x07) == 0 else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unknown authored qualifier bits."
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct NativeDecompilerWireAuthoredInputs: Sendable, Equatable, Codable {
    static let empty = NativeDecompilerWireAuthoredInputs(
        schemaVersion: 1,
        names: [],
        signatures: [],
        appliedTypes: [],
        typeDefinitions: []
    )

    let schemaVersion: UInt32
    let names: [NativeDecompilerWireAuthoredName]
    let signatures: [NativeDecompilerWireAuthoredSignature]
    let appliedTypes: [NativeDecompilerWireAppliedType]
    let typeDefinitions: [NativeDecompilerWireAuthoredTypeDefinition]
    /// Schema v2 only (empty and never encoded in v1).
    let calleeSignatureHints: [NativeDecompilerWireCalleeSignatureHint]
    /// Schema v3 only (empty and never encoded in v1/v2).
    let localNames: [NativeDecompilerWireAuthoredLocalName]

    /// The authored-input schema that carries callee signature hints.
    static let calleeHintSchemaVersion: UInt32 = 2
    /// The authored-input schema that carries the function's local names (DP04 C1b).
    static let localNameSchemaVersion: UInt32 = 3

    init(
        schemaVersion: UInt32,
        names: [NativeDecompilerWireAuthoredName],
        signatures: [NativeDecompilerWireAuthoredSignature],
        appliedTypes: [NativeDecompilerWireAppliedType],
        typeDefinitions: [NativeDecompilerWireAuthoredTypeDefinition],
        calleeSignatureHints: [NativeDecompilerWireCalleeSignatureHint] = [],
        localNames: [NativeDecompilerWireAuthoredLocalName] = []
    ) {
        self.schemaVersion = schemaVersion
        self.names = names
        self.signatures = signatures
        self.appliedTypes = appliedTypes
        self.typeDefinitions = typeDefinitions
        self.calleeSignatureHints = calleeSignatureHints
        self.localNames = localNames
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, names, signatures, appliedTypes, typeDefinitions, calleeSignatureHints, localNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        var required: Set<String> = ["schemaVersion", "names", "signatures", "appliedTypes", "typeDefinitions"]
        if schemaVersion >= Self.calleeHintSchemaVersion { required.insert("calleeSignatureHints") }
        if schemaVersion >= Self.localNameSchemaVersion { required.insert("localNames") }
        try nativeDecompilerRequireKeys(decoder, required: required)
        names = try container.decode([NativeDecompilerWireAuthoredName].self, forKey: .names)
        signatures = try container.decode([NativeDecompilerWireAuthoredSignature].self, forKey: .signatures)
        appliedTypes = try container.decode([NativeDecompilerWireAppliedType].self, forKey: .appliedTypes)
        typeDefinitions = try container.decode(
            [NativeDecompilerWireAuthoredTypeDefinition].self,
            forKey: .typeDefinitions
        )
        calleeSignatureHints = schemaVersion >= Self.calleeHintSchemaVersion
            ? try container.decode([NativeDecompilerWireCalleeSignatureHint].self, forKey: .calleeSignatureHints)
            : []
        localNames = schemaVersion >= Self.localNameSchemaVersion
            ? try container.decode([NativeDecompilerWireAuthoredLocalName].self, forKey: .localNames)
            : []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(names, forKey: .names)
        try container.encode(signatures, forKey: .signatures)
        try container.encode(appliedTypes, forKey: .appliedTypes)
        try container.encode(typeDefinitions, forKey: .typeDefinitions)
        if schemaVersion >= Self.calleeHintSchemaVersion {
            try container.encode(calleeSignatureHints, forKey: .calleeSignatureHints)
        }
        if schemaVersion >= Self.localNameSchemaVersion {
            try container.encode(localNames, forKey: .localNames)
        }
    }
}

enum NativeDecompilerWireAuthoredLocalStorageKind: UInt8, Sendable, Equatable, Hashable, Codable {
    /// A stack slot at `stackOffset` bytes from SP at function entry, `byteSize` wide.
    case stack = 0
    /// Every variable the function keeps in 64-bit GPR `register` (x0…x30).
    case register = 1
}

/// Authored-input v3: a user-authored name (and optional type) for one of the decompiled
/// function's locals. The bridge installs a stack entry as a name-locked local symbol
/// (type-locked when typed) and renames register-held variables after decompilation.
struct NativeDecompilerWireAuthoredLocalName: Sendable, Equatable, Codable {
    let storageKind: NativeDecompilerWireAuthoredLocalStorageKind
    /// Entry-SP relative byte offset (stack only; 0 for a register).
    let stackOffset: Int32
    /// Stack slot width in bytes (stack only; 0 for a register).
    let byteSize: UInt32
    /// Lowercase `xN` (register only; empty for a stack slot).
    let register: String
    let name: String
    let type: NativeDecompilerWireAuthoredType?

    init(storageKind: NativeDecompilerWireAuthoredLocalStorageKind, stackOffset: Int32, byteSize: UInt32,
         register: String, name: String, type: NativeDecompilerWireAuthoredType?) {
        self.storageKind = storageKind
        self.stackOffset = stackOffset
        self.byteSize = byteSize
        self.register = register
        self.name = name
        self.type = type
    }

    private enum CodingKeys: String, CodingKey { case storageKind, stackOffset, byteSize, register, name, type }

    init(from decoder: Decoder) throws {
        try nativeDecompilerRequireKeys(decoder, required: ["storageKind", "stackOffset", "byteSize", "register", "name"],
                                        optional: ["type"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storageKind = try container.decode(NativeDecompilerWireAuthoredLocalStorageKind.self, forKey: .storageKind)
        stackOffset = try container.decode(Int32.self, forKey: .stackOffset)
        byteSize = try container.decode(UInt32.self, forKey: .byteSize)
        register = try container.decode(String.self, forKey: .register)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(NativeDecompilerWireAuthoredType.self, forKey: .type)
    }
}

enum NativeDecompilerWireCalleeSignatureHintSource: UInt8, Sendable, Equatable, Hashable, Codable {
    case debug = 0
    case authored = 1
    case sdk = 2
    /// MacScope's own parameter recovery on the callee body (lowest priority).
    case recovered = 3
    /// Convention and context registers decided from the callee's own Swift symbol.
    case swift = 4
}

/// A known prototype for a direct callee; the bridge installs it as the callee's
/// named, locked prototype so call sites carry typed arguments.
struct NativeDecompilerWireCalleeSignatureHint: Sendable, Equatable, Codable {
    let name: String
    let source: NativeDecompilerWireCalleeSignatureHintSource
    let signature: NativeDecompilerWireAuthoredSignature

    init(
        name: String,
        source: NativeDecompilerWireCalleeSignatureHintSource,
        signature: NativeDecompilerWireAuthoredSignature
    ) {
        self.name = name
        self.source = source
        self.signature = signature
    }

    private enum CodingKeys: String, CodingKey { case name, source, signature }

    init(from decoder: Decoder) throws {
        try nativeDecompilerRequireKeys(decoder, required: ["name", "source", "signature"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(NativeDecompilerWireCalleeSignatureHintSource.self, forKey: .source)
        signature = try container.decode(NativeDecompilerWireAuthoredSignature.self, forKey: .signature)
    }
}

struct NativeDecompilerWireAuthoredName: Sendable, Equatable, Codable {
    let address: NativeDecompilerWireUInt64
    let subjectKind: NativeDecompilerWireAuthoredNameSubjectKind
    let name: String

    init(
        address: NativeDecompilerWireUInt64,
        subjectKind: NativeDecompilerWireAuthoredNameSubjectKind,
        name: String
    ) {
        self.address = address
        self.subjectKind = subjectKind
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case address, subjectKind, name }

    init(from decoder: Decoder) throws {
        try nativeDecompilerRequireKeys(decoder, required: ["address", "subjectKind", "name"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decode(NativeDecompilerWireUInt64.self, forKey: .address)
        subjectKind = try container.decode(
            NativeDecompilerWireAuthoredNameSubjectKind.self,
            forKey: .subjectKind
        )
        name = try container.decode(String.self, forKey: .name)
    }
}

struct NativeDecompilerWireAuthoredSignature: Sendable, Equatable, Codable {
    let functionAddress: NativeDecompilerWireUInt64
    let returnType: NativeDecompilerWireAuthoredType?
    let parameterListState: NativeDecompilerWireAuthoredParameterListState
    let parameters: [NativeDecompilerWireAuthoredParameter]
    let variadicState: NativeDecompilerWireAuthoredVariadicState
    let noReturnState: NativeDecompilerWireAuthoredNoReturnState

    init(
        functionAddress: NativeDecompilerWireUInt64,
        returnType: NativeDecompilerWireAuthoredType?,
        parameterListState: NativeDecompilerWireAuthoredParameterListState,
        parameters: [NativeDecompilerWireAuthoredParameter],
        variadicState: NativeDecompilerWireAuthoredVariadicState,
        noReturnState: NativeDecompilerWireAuthoredNoReturnState
    ) {
        self.functionAddress = functionAddress
        self.returnType = returnType
        self.parameterListState = parameterListState
        self.parameters = parameters
        self.variadicState = variadicState
        self.noReturnState = noReturnState
    }

    private enum CodingKeys: String, CodingKey {
        case functionAddress, returnType, parameterListState, parameters, variadicState, noReturnState
    }

    init(from decoder: Decoder) throws {
        try nativeDecompilerRequireKeys(
            decoder,
            required: [
                "functionAddress", "parameterListState", "parameters", "variadicState",
                "noReturnState",
            ],
            optional: ["returnType"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        functionAddress = try container.decode(NativeDecompilerWireUInt64.self, forKey: .functionAddress)
        returnType = try container.decodeIfPresent(NativeDecompilerWireAuthoredType.self, forKey: .returnType)
        parameterListState = try container.decode(
            NativeDecompilerWireAuthoredParameterListState.self,
            forKey: .parameterListState
        )
        parameters = try container.decode([NativeDecompilerWireAuthoredParameter].self, forKey: .parameters)
        variadicState = try container.decode(
            NativeDecompilerWireAuthoredVariadicState.self,
            forKey: .variadicState
        )
        noReturnState = try container.decode(
            NativeDecompilerWireAuthoredNoReturnState.self,
            forKey: .noReturnState
        )
    }
}

struct NativeDecompilerWireAuthoredParameter: Sendable, Equatable, Codable {
    let name: String
    let type: NativeDecompilerWireAuthoredType
    let storageRegister: String?

    init(name: String, type: NativeDecompilerWireAuthoredType, storageRegister: String? = nil) {
        self.name = name
        self.type = type
        self.storageRegister = storageRegister
    }

    private enum CodingKeys: String, CodingKey { case name, type, storageRegister }

    init(from decoder: Decoder) throws {
        try nativeDecompilerRequireKeys(decoder, required: ["name", "type"], optional: ["storageRegister"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(NativeDecompilerWireAuthoredType.self, forKey: .type)
        storageRegister = try container.decodeIfPresent(String.self, forKey: .storageRegister)
    }
}

struct NativeDecompilerWireAppliedType: Sendable, Equatable, Codable {
    let address: NativeDecompilerWireUInt64
    let subjectKind: NativeDecompilerWireAppliedTypeSubjectKind
    let typeDefinitionName: String
    let byteCount: NativeDecompilerWireUInt64

    init(
        address: NativeDecompilerWireUInt64,
        subjectKind: NativeDecompilerWireAppliedTypeSubjectKind,
        typeDefinitionName: String,
        byteCount: NativeDecompilerWireUInt64
    ) {
        self.address = address
        self.subjectKind = subjectKind
        self.typeDefinitionName = typeDefinitionName
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case address, subjectKind, typeDefinitionName, byteCount
    }

    init(from decoder: Decoder) throws {
        try nativeDecompilerRequireKeys(
            decoder,
            required: ["address", "subjectKind", "typeDefinitionName", "byteCount"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decode(NativeDecompilerWireUInt64.self, forKey: .address)
        subjectKind = try container.decode(
            NativeDecompilerWireAppliedTypeSubjectKind.self,
            forKey: .subjectKind
        )
        typeDefinitionName = try container.decode(String.self, forKey: .typeDefinitionName)
        byteCount = try container.decode(NativeDecompilerWireUInt64.self, forKey: .byteCount)
    }
}

struct NativeDecompilerWireAuthoredLayoutRules: Sendable, Equatable, Codable {
    let isPacked: Bool
    let packAlignment: NativeDecompilerWireUInt64?
    let minimumAlignment: NativeDecompilerWireUInt64?

    init(
        isPacked: Bool,
        packAlignment: NativeDecompilerWireUInt64?,
        minimumAlignment: NativeDecompilerWireUInt64?
    ) {
        self.isPacked = isPacked
        self.packAlignment = packAlignment
        self.minimumAlignment = minimumAlignment
    }

    private enum CodingKeys: String, CodingKey {
        case isPacked, packAlignment, minimumAlignment
    }

    init(from decoder: Decoder) throws {
        try nativeDecompilerRequireKeys(
            decoder,
            required: ["isPacked"],
            optional: ["packAlignment", "minimumAlignment"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPacked = try container.decode(Bool.self, forKey: .isPacked)
        packAlignment = try container.decodeIfPresent(
            NativeDecompilerWireUInt64.self,
            forKey: .packAlignment
        )
        minimumAlignment = try container.decodeIfPresent(
            NativeDecompilerWireUInt64.self,
            forKey: .minimumAlignment
        )
    }
}

struct NativeDecompilerWireAuthoredRecordField: Sendable, Equatable, Codable {
    let name: String
    let storage: NativeDecompilerWireAuthoredFieldStorage
    let bitWidth: NativeDecompilerWireUInt64?
    let minimumAlignment: NativeDecompilerWireUInt64?
    let minimumAlignmentType: NativeDecompilerWireAuthoredType?
    let promotesInlineFields: Bool

    init(
        name: String,
        storage: NativeDecompilerWireAuthoredFieldStorage,
        bitWidth: NativeDecompilerWireUInt64?,
        minimumAlignment: NativeDecompilerWireUInt64?,
        minimumAlignmentType: NativeDecompilerWireAuthoredType?,
        promotesInlineFields: Bool
    ) {
        self.name = name
        self.storage = storage
        self.bitWidth = bitWidth
        self.minimumAlignment = minimumAlignment
        self.minimumAlignmentType = minimumAlignmentType
        self.promotesInlineFields = promotesInlineFields
    }

    private enum CodingKeys: String, CodingKey {
        case name, storage, bitWidth, minimumAlignment, minimumAlignmentType, promotesInlineFields
    }

    init(from decoder: Decoder) throws {
        try nativeDecompilerRequireKeys(
            decoder,
            required: ["name", "storage", "promotesInlineFields"],
            optional: ["bitWidth", "minimumAlignment", "minimumAlignmentType"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        storage = try container.decode(NativeDecompilerWireAuthoredFieldStorage.self, forKey: .storage)
        bitWidth = try container.decodeIfPresent(NativeDecompilerWireUInt64.self, forKey: .bitWidth)
        minimumAlignment = try container.decodeIfPresent(
            NativeDecompilerWireUInt64.self,
            forKey: .minimumAlignment
        )
        minimumAlignmentType = try container.decodeIfPresent(
            NativeDecompilerWireAuthoredType.self,
            forKey: .minimumAlignmentType
        )
        promotesInlineFields = try container.decode(Bool.self, forKey: .promotesInlineFields)
    }
}

struct NativeDecompilerWireAuthoredEnumCase: Sendable, Equatable, Codable {
    let name: String
    let value: Int32

    init(name: String, value: Int32) {
        self.name = name
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case name, value }

    init(from decoder: Decoder) throws {
        try nativeDecompilerRequireKeys(decoder, required: ["name", "value"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(Int32.self, forKey: .value)
    }
}

indirect enum NativeDecompilerWireAuthoredType: Sendable, Equatable, Codable {
    case qualifiedValue(
        atom: NativeDecompilerWireAuthoredAtom,
        qualifiers: NativeDecompilerWireAuthoredQualifiers
    )
    case dataPointer(
        pointee: NativeDecompilerWireAuthoredType,
        indirectionLevel: NativeDecompilerWireUInt64,
        pointerQualifiersByLevel: [NativeDecompilerWireAuthoredQualifiers]
    )

    var tag: NativeDecompilerWireAuthoredTypeTag {
        switch self {
        case .qualifiedValue: .qualifiedValue
        case .dataPointer: .dataPointer
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tag, atom, qualifiers, pointee, indirectionLevel, pointerQualifiersByLevel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(NativeDecompilerWireAuthoredTypeTag.self, forKey: .tag)
        switch tag {
        case .qualifiedValue:
            try nativeDecompilerRequireKeys(decoder, required: ["tag", "atom", "qualifiers"])
            self = .qualifiedValue(
                atom: try container.decode(NativeDecompilerWireAuthoredAtom.self, forKey: .atom),
                qualifiers: try container.decode(
                    NativeDecompilerWireAuthoredQualifiers.self,
                    forKey: .qualifiers
                )
            )
        case .dataPointer:
            try nativeDecompilerRequireKeys(
                decoder,
                required: ["tag", "pointee", "indirectionLevel", "pointerQualifiersByLevel"]
            )
            let pointee = try container.decode(
                NativeDecompilerWireAuthoredType.self,
                forKey: .pointee
            )
            let indirectionLevel = try container.decode(
                NativeDecompilerWireUInt64.self,
                forKey: .indirectionLevel
            )
            let pointerQualifiersByLevel = try container.decode(
                [NativeDecompilerWireAuthoredQualifiers].self,
                forKey: .pointerQualifiersByLevel
            )
            guard case .qualifiedValue = pointee,
                  (1...8).contains(indirectionLevel.value),
                  pointerQualifiersByLevel.count == Int(indirectionLevel.value)
            else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Authored data pointer shape is invalid."
                    )
                )
            }
            self = .dataPointer(
                pointee: pointee,
                indirectionLevel: indirectionLevel,
                pointerQualifiersByLevel: pointerQualifiersByLevel
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        switch self {
        case let .qualifiedValue(atom, qualifiers):
            try container.encode(atom, forKey: .atom)
            try container.encode(qualifiers, forKey: .qualifiers)
        case let .dataPointer(pointee, indirectionLevel, pointerQualifiersByLevel):
            guard case .qualifiedValue = pointee,
                  (1...8).contains(indirectionLevel.value),
                  pointerQualifiersByLevel.count == Int(indirectionLevel.value)
            else {
                throw EncodingError.invalidValue(
                    self,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "Authored data pointer shape is invalid."
                    )
                )
            }
            try container.encode(pointee, forKey: .pointee)
            try container.encode(indirectionLevel, forKey: .indirectionLevel)
            try container.encode(pointerQualifiersByLevel, forKey: .pointerQualifiersByLevel)
        }
    }
}

enum NativeDecompilerWireAuthoredAtom: Sendable, Equatable, Codable {
    case void
    case scalar(NativeDecompilerWireAuthoredScalarKind)
    case darwinAlias(NativeDecompilerWireAuthoredDarwinAliasKind)
    case named(kind: NativeDecompilerWireAuthoredNamedKind, name: String)

    var tag: NativeDecompilerWireAuthoredAtomTag {
        switch self {
        case .void: .void
        case .scalar: .scalar
        case .darwinAlias: .darwinAlias
        case .named: .named
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tag, scalarKind, darwinAliasKind, namedKind, name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(NativeDecompilerWireAuthoredAtomTag.self, forKey: .tag)
        switch tag {
        case .void:
            try nativeDecompilerRequireKeys(decoder, required: ["tag"])
            self = .void
        case .scalar:
            try nativeDecompilerRequireKeys(decoder, required: ["tag", "scalarKind"])
            self = .scalar(
                try container.decode(NativeDecompilerWireAuthoredScalarKind.self, forKey: .scalarKind)
            )
        case .darwinAlias:
            try nativeDecompilerRequireKeys(decoder, required: ["tag", "darwinAliasKind"])
            self = .darwinAlias(
                try container.decode(
                    NativeDecompilerWireAuthoredDarwinAliasKind.self,
                    forKey: .darwinAliasKind
                )
            )
        case .named:
            try nativeDecompilerRequireKeys(decoder, required: ["tag", "namedKind", "name"])
            self = .named(
                kind: try container.decode(
                    NativeDecompilerWireAuthoredNamedKind.self,
                    forKey: .namedKind
                ),
                name: try container.decode(String.self, forKey: .name)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        switch self {
        case .void:
            break
        case let .scalar(kind):
            try container.encode(kind, forKey: .scalarKind)
        case let .darwinAlias(kind):
            try container.encode(kind, forKey: .darwinAliasKind)
        case let .named(kind, name):
            try container.encode(kind, forKey: .namedKind)
            try container.encode(name, forKey: .name)
        }
    }
}

indirect enum NativeDecompilerWireAuthoredFieldStorage: Sendable, Equatable, Codable {
    case value(NativeDecompilerWireAuthoredType)
    case fixedArray(element: NativeDecompilerWireAuthoredFieldStorage, count: NativeDecompilerWireUInt64)
    case flexibleArray(element: NativeDecompilerWireAuthoredFieldStorage)
    case opaquePointerCarrier(kind: NativeDecompilerWireAuthoredOpaquePointerCarrierKind)
    case inlineAggregate(
        kind: NativeDecompilerWireAuthoredNamedKind,
        layoutRules: NativeDecompilerWireAuthoredLayoutRules,
        fields: [NativeDecompilerWireAuthoredRecordField]
    )

    var tag: NativeDecompilerWireAuthoredFieldStorageTag {
        switch self {
        case .value: .value
        case .fixedArray: .fixedArray
        case .flexibleArray: .flexibleArray
        case .opaquePointerCarrier: .opaquePointerCarrier
        case .inlineAggregate: .inlineAggregate
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tag, type, element, count, kind, layoutRules, fields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(NativeDecompilerWireAuthoredFieldStorageTag.self, forKey: .tag)
        switch tag {
        case .value:
            try nativeDecompilerRequireKeys(decoder, required: ["tag", "type"])
            self = .value(
                try container.decode(NativeDecompilerWireAuthoredType.self, forKey: .type)
            )
        case .fixedArray:
            try nativeDecompilerRequireKeys(decoder, required: ["tag", "element", "count"])
            self = .fixedArray(
                element: try container.decode(
                    NativeDecompilerWireAuthoredFieldStorage.self,
                    forKey: .element
                ),
                count: try container.decode(NativeDecompilerWireUInt64.self, forKey: .count)
            )
        case .flexibleArray:
            try nativeDecompilerRequireKeys(decoder, required: ["tag", "element"])
            self = .flexibleArray(
                element: try container.decode(
                    NativeDecompilerWireAuthoredFieldStorage.self,
                    forKey: .element
                )
            )
        case .opaquePointerCarrier:
            try nativeDecompilerRequireKeys(decoder, required: ["tag", "kind"])
            self = .opaquePointerCarrier(
                kind: try container.decode(
                    NativeDecompilerWireAuthoredOpaquePointerCarrierKind.self,
                    forKey: .kind
                )
            )
        case .inlineAggregate:
            try nativeDecompilerRequireKeys(
                decoder,
                required: ["tag", "kind", "layoutRules", "fields"]
            )
            let kind = try container.decode(
                NativeDecompilerWireAuthoredNamedKind.self,
                forKey: .kind
            )
            guard kind == .`struct` || kind == .union else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Inline aggregate kind must be struct or union."
                    )
                )
            }
            self = .inlineAggregate(
                kind: kind,
                layoutRules: try container.decode(
                    NativeDecompilerWireAuthoredLayoutRules.self,
                    forKey: .layoutRules
                ),
                fields: try container.decode(
                    [NativeDecompilerWireAuthoredRecordField].self,
                    forKey: .fields
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        switch self {
        case let .value(type):
            try container.encode(type, forKey: .type)
        case let .fixedArray(element, count):
            try container.encode(element, forKey: .element)
            try container.encode(count, forKey: .count)
        case let .flexibleArray(element):
            try container.encode(element, forKey: .element)
        case let .opaquePointerCarrier(kind):
            try container.encode(kind, forKey: .kind)
        case let .inlineAggregate(kind, layoutRules, fields):
            guard kind == .`struct` || kind == .union else {
                throw EncodingError.invalidValue(
                    self,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "Inline aggregate kind must be struct or union."
                    )
                )
            }
            try container.encode(kind, forKey: .kind)
            try container.encode(layoutRules, forKey: .layoutRules)
            try container.encode(fields, forKey: .fields)
        }
    }
}

enum NativeDecompilerWireAuthoredTypeDefinition: Sendable, Equatable, Codable {
    case record(
        kind: NativeDecompilerWireAuthoredNamedKind,
        name: String,
        layoutRules: NativeDecompilerWireAuthoredLayoutRules,
        fields: [NativeDecompilerWireAuthoredRecordField]
    )
    case enumeration(
        name: String,
        representation: NativeDecompilerWireAuthoredEnumRepresentation,
        cases: [NativeDecompilerWireAuthoredEnumCase]
    )
    case typedef(name: String, target: NativeDecompilerWireAuthoredFieldStorage)

    var kind: NativeDecompilerWireAuthoredTypeDefinitionKind {
        switch self {
        case let .record(kind, _, _, _):
            switch kind {
            case .`struct`: .recordStruct
            case .union: .recordUnion
            case .`enum`: .enumeration
            case .typedef: .typedef
            }
        case .enumeration:
            .enumeration
        case .typedef:
            .typedef
        }
    }

    var name: String {
        switch self {
        case let .record(_, name, _, _), let .enumeration(name, _, _), let .typedef(name, _):
            name
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, name, layoutRules, fields, representation, cases, target
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(NativeDecompilerWireAuthoredTypeDefinitionKind.self, forKey: .kind)
        switch kind {
        case .recordStruct, .recordUnion:
            try nativeDecompilerRequireKeys(
                decoder,
                required: ["kind", "name", "layoutRules", "fields"]
            )
            self = .record(
                kind: kind == .recordStruct ? .struct : .union,
                name: try container.decode(String.self, forKey: .name),
                layoutRules: try container.decode(
                    NativeDecompilerWireAuthoredLayoutRules.self,
                    forKey: .layoutRules
                ),
                fields: try container.decode(
                    [NativeDecompilerWireAuthoredRecordField].self,
                    forKey: .fields
                )
            )
        case .enumeration:
            try nativeDecompilerRequireKeys(
                decoder,
                required: ["kind", "name", "representation", "cases"]
            )
            self = .enumeration(
                name: try container.decode(String.self, forKey: .name),
                representation: try container.decode(
                    NativeDecompilerWireAuthoredEnumRepresentation.self,
                    forKey: .representation
                ),
                cases: try container.decode(
                    [NativeDecompilerWireAuthoredEnumCase].self,
                    forKey: .cases
                )
            )
        case .typedef:
            try nativeDecompilerRequireKeys(decoder, required: ["kind", "name", "target"])
            self = .typedef(
                name: try container.decode(String.self, forKey: .name),
                target: try container.decode(
                    NativeDecompilerWireAuthoredFieldStorage.self,
                    forKey: .target
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        if case let .record(recordKind, _, _, _) = self,
           recordKind != .`struct`, recordKind != .union {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Record definition kind must be struct or union."
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        switch self {
        case let .record(_, _, layoutRules, fields):
            try container.encode(layoutRules, forKey: .layoutRules)
            try container.encode(fields, forKey: .fields)
        case let .enumeration(_, representation, cases):
            try container.encode(representation, forKey: .representation)
            try container.encode(cases, forKey: .cases)
        case let .typedef(_, target):
            try container.encode(target, forKey: .target)
        }
    }
}

private struct NativeDecompilerWireAuthoredDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        self.intValue = intValue
        stringValue = String(intValue)
    }
}

private func nativeDecompilerRequireKeys(
    _ decoder: Decoder,
    required: Set<String>,
    optional: Set<String> = []
) throws {
    let container = try decoder.container(keyedBy: NativeDecompilerWireAuthoredDynamicCodingKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    let allowed = required.union(optional)
    guard required.isSubset(of: actual), actual.isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Authored wire value has missing or unknown keys."
            )
        )
    }
}
