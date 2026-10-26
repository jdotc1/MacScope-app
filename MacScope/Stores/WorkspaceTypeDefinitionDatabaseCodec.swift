import Foundation

enum WorkspaceTypeCatalogLoadDiagnostic: Equatable, Sendable {
    case legacyDefaultLayoutSubstitution(typeName: String)
}

enum WorkspaceTypeDefinitionDatabaseCodec {
    private static let maximumAlignment = 1_048_576
    private static let maximumBitWidth = 1_048_576

    static func encodeFields(_ fields: [FieldDef]) throws -> String {
        let encoded = try encode(fields.map(PersistedField.init))
        _ = try decodeFields(encoded)
        return encoded
    }

    static func decodeFields(_ json: String) throws -> [FieldDef] {
        let records = try decode([PersistedField].self, from: json)
        return try records.map { try $0.field() }
    }

    static func encodeLayoutRules(_ rules: AggregateLayoutRules) throws -> String {
        try validate(rules)
        return try encode(PersistedLayoutRules(rules))
    }

    static func decodeLayoutRules(_ json: String) throws -> AggregateLayoutRules {
        try decode(PersistedLayoutRules.self, from: json).layoutRules()
    }

    // Type-level ABI metadata shares the existing layout_rules_json envelope.
    // Old rows retain the three required layout keys and omit these additions.
    static func encodeTypeLayout(_ type: TypeDefinition) throws -> String {
        try validate(type.layoutRules)
        return try encode(PersistedLayoutRules(
            type.layoutRules,
            vectorByteSize: type.vectorByteSize,
            enumValuesIncomplete: type.enumValuesIncomplete,
            inferenceProvenance: type.inferenceProvenance
        ))
    }

    static func decodeTypeLayout(_ json: String) throws -> (
        rules: AggregateLayoutRules, vectorByteSize: Int?, enumValuesIncomplete: Bool?
    ) {
        let record = try decode(PersistedLayoutRules.self, from: json)
        return (try record.layoutRules(), record.vectorByteSize, record.enumValuesIncomplete)
    }

    /// DP04 D2: the accepted-from-evidence record carried in the same envelope (nil for old rows).
    static func decodeInferenceProvenance(_ json: String) throws -> TypeInferenceProvenance? {
        try decode(PersistedLayoutRules.self, from: json).inferenceProvenance
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodecError.invalidUTF8
        }
        return string
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from json: String
    ) throws -> Value {
        guard let data = json.data(using: .utf8) else {
            throw CodecError.invalidUTF8
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func validate(_ rules: AggregateLayoutRules) throws {
        try validateAlignment(rules.packAlignment)
        try validateAlignment(rules.minimumAlignment)
    }

    private static func validateAlignment(_ alignment: Int?) throws {
        guard let alignment else { return }
        guard (1...maximumAlignment).contains(alignment) else {
            throw CodecError.invalidAlignment
        }
    }

    private static func validateString(_ string: String) throws {
        guard !containsControlCharacter(string) else {
            throw CodecError.controlCharacter
        }
    }

    private static func containsControlCharacter(_ string: String) -> Bool {
        string.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    private enum CodecError: Error {
        case controlCharacter
        case invalidAlignment
        case invalidBitWidth
        case invalidUTF8
        case unknownKey
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    private struct PersistedLayoutRules: Codable {
        let isPacked: Bool
        let minimumAlignment: Int?
        let packAlignment: Int?
        let vectorByteSize: Int?
        let enumValuesIncomplete: Bool?
        let inferenceProvenance: TypeInferenceProvenance?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case isPacked
            case minimumAlignment
            case packAlignment
            case vectorByteSize
            case enumValuesIncomplete
            case inferenceProvenance
        }

        init(_ rules: AggregateLayoutRules, vectorByteSize: Int? = nil, enumValuesIncomplete: Bool? = nil,
             inferenceProvenance: TypeInferenceProvenance? = nil) {
            isPacked = rules.isPacked
            minimumAlignment = rules.minimumAlignment
            packAlignment = rules.packAlignment
            self.vectorByteSize = vectorByteSize
            self.enumValuesIncomplete = enumValuesIncomplete
            self.inferenceProvenance = inferenceProvenance
        }

        init(from decoder: Decoder) throws {
            let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
            let expected = Set(CodingKeys.allCases.map(\.rawValue))
            let actual = Set(dynamic.allKeys.map(\.stringValue))
            let required: Set<String> = ["isPacked", "minimumAlignment", "packAlignment"]
            guard required.isSubset(of: actual), actual.isSubset(of: expected) else {
                throw CodecError.unknownKey
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isPacked = try container.decode(Bool.self, forKey: .isPacked)
            minimumAlignment = try container.decodeIfPresent(Int.self, forKey: .minimumAlignment)
            packAlignment = try container.decodeIfPresent(Int.self, forKey: .packAlignment)
            vectorByteSize = try container.decodeIfPresent(Int.self, forKey: .vectorByteSize)
            enumValuesIncomplete = try container.decodeIfPresent(Bool.self, forKey: .enumValuesIncomplete)
            inferenceProvenance = try container.decodeIfPresent(TypeInferenceProvenance.self, forKey: .inferenceProvenance)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(isPacked, forKey: .isPacked)
            try container.encode(minimumAlignment, forKey: .minimumAlignment)
            try container.encode(packAlignment, forKey: .packAlignment)
            try container.encodeIfPresent(vectorByteSize, forKey: .vectorByteSize)
            try container.encodeIfPresent(enumValuesIncomplete, forKey: .enumValuesIncomplete)
            try container.encodeIfPresent(inferenceProvenance, forKey: .inferenceProvenance)
        }

        func layoutRules() throws -> AggregateLayoutRules {
            try WorkspaceTypeDefinitionDatabaseCodec.validateAlignment(packAlignment)
            try WorkspaceTypeDefinitionDatabaseCodec.validateAlignment(minimumAlignment)
            return AggregateLayoutRules(
                isPacked: isPacked,
                packAlignment: packAlignment,
                minimumAlignment: minimumAlignment
            )
        }
    }

    private struct PersistedField: Codable {
        let name: String
        let type: String
        let declaratorSemanticsV1: FieldDef.DeclaratorSemanticsV1?
        let functionPointerSignatureV1: FunctionPointerSignatureV1?
        let bitOffset: Int?
        let isPacked: Bool?
        let layoutIsUnknown: Bool?
        let isAtomic: Bool?
        let bitWidth: Int?
        let byteOffset: Int?
        let layoutSource: FieldDef.LayoutSource?
        let minimumAlignment: Int?
        let minimumAlignmentType: String?
        let inlineAggregateKind: TypeKind?
        let inlineFields: [PersistedField]
        let inlineAggregateLayoutRules: PersistedLayoutRules
        let promotesInlineFields: Bool

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case name
            case type
            case declaratorSemanticsV1
            case functionPointerSignatureV1
            case bitOffset
            case isPacked
            case layoutIsUnknown
            case isAtomic
            case bitWidth
            case byteOffset
            case layoutSource
            case minimumAlignment
            case minimumAlignmentType
            case inlineAggregateKind
            case inlineFields
            case inlineAggregateLayoutRules
            case promotesInlineFields
        }

        init(_ field: FieldDef) {
            name = field.name
            type = field.type
            declaratorSemanticsV1 = field.declaratorSemanticsV1
            functionPointerSignatureV1 = field.functionPointerSignatureV1
            bitOffset = field.bitOffset
            isPacked = field.isPacked
            layoutIsUnknown = field.layoutIsUnknown
            isAtomic = field.isAtomic
            bitWidth = field.bitWidth
            byteOffset = field.byteOffset
            layoutSource = field.layoutSource
            minimumAlignment = field.minimumAlignment
            minimumAlignmentType = field.minimumAlignmentType
            inlineAggregateKind = field.inlineAggregateKind
            inlineFields = field.inlineFields.map(PersistedField.init)
            inlineAggregateLayoutRules = PersistedLayoutRules(field.inlineAggregateLayoutRules)
            promotesInlineFields = field.promotesInlineFields
        }

        init(from decoder: Decoder) throws {
            let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
            let expected = Set(CodingKeys.allCases.map(\.rawValue))
            guard dynamic.allKeys.allSatisfy({ expected.contains($0.stringValue) }) else {
                throw CodecError.unknownKey
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decode(String.self, forKey: .type)
            declaratorSemanticsV1 = try container.decodeIfPresent(
                FieldDef.DeclaratorSemanticsV1.self,
                forKey: .declaratorSemanticsV1
            )
            functionPointerSignatureV1 = try container.decodeIfPresent(
                FunctionPointerSignatureV1.self,
                forKey: .functionPointerSignatureV1
            )
            bitOffset = try container.decodeIfPresent(Int.self, forKey: .bitOffset)
            isPacked = try container.decodeIfPresent(Bool.self, forKey: .isPacked)
            layoutIsUnknown = try container.decodeIfPresent(Bool.self, forKey: .layoutIsUnknown)
            isAtomic = try container.decodeIfPresent(Bool.self, forKey: .isAtomic)
            bitWidth = try container.decodeIfPresent(Int.self, forKey: .bitWidth)
            byteOffset = try container.decodeIfPresent(Int.self, forKey: .byteOffset)
            layoutSource = try container.decodeIfPresent(FieldDef.LayoutSource.self, forKey: .layoutSource)
            minimumAlignment = try container.decodeIfPresent(Int.self, forKey: .minimumAlignment)
            minimumAlignmentType = try container.decodeIfPresent(String.self, forKey: .minimumAlignmentType)
            inlineAggregateKind = try container.decodeIfPresent(TypeKind.self, forKey: .inlineAggregateKind)
            inlineFields = try container.contains(.inlineFields)
                ? container.decode([PersistedField].self, forKey: .inlineFields)
                : []
            inlineAggregateLayoutRules = try container.contains(.inlineAggregateLayoutRules)
                ? container.decode(PersistedLayoutRules.self, forKey: .inlineAggregateLayoutRules)
                : PersistedLayoutRules(.default)
            promotesInlineFields = try container.decodeIfPresent(Bool.self, forKey: .promotesInlineFields) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(declaratorSemanticsV1, forKey: .declaratorSemanticsV1)
            try container.encodeIfPresent(functionPointerSignatureV1, forKey: .functionPointerSignatureV1)
            try container.encodeIfPresent(bitOffset, forKey: .bitOffset)
            try container.encodeIfPresent(isPacked, forKey: .isPacked)
            try container.encodeIfPresent(layoutIsUnknown, forKey: .layoutIsUnknown)
            try container.encodeIfPresent(isAtomic, forKey: .isAtomic)
            try container.encodeIfPresent(bitWidth, forKey: .bitWidth)
            try container.encodeIfPresent(byteOffset, forKey: .byteOffset)
            try container.encodeIfPresent(layoutSource, forKey: .layoutSource)
            try container.encodeIfPresent(minimumAlignment, forKey: .minimumAlignment)
            try container.encodeIfPresent(minimumAlignmentType, forKey: .minimumAlignmentType)
            try container.encodeIfPresent(inlineAggregateKind, forKey: .inlineAggregateKind)
            if !inlineFields.isEmpty {
                try container.encode(inlineFields, forKey: .inlineFields)
            }
            if try inlineAggregateLayoutRules.layoutRules() != .default {
                try container.encode(inlineAggregateLayoutRules, forKey: .inlineAggregateLayoutRules)
            }
            if promotesInlineFields {
                try container.encode(promotesInlineFields, forKey: .promotesInlineFields)
            }
        }

        func field() throws -> FieldDef {
            try WorkspaceTypeDefinitionDatabaseCodec.validateString(name)
            try WorkspaceTypeDefinitionDatabaseCodec.validateString(type)
            if let minimumAlignmentType {
                try WorkspaceTypeDefinitionDatabaseCodec.validateString(minimumAlignmentType)
            }
            if let bitWidth, !(0...WorkspaceTypeDefinitionDatabaseCodec.maximumBitWidth).contains(bitWidth) {
                throw CodecError.invalidBitWidth
            }
            try WorkspaceTypeDefinitionDatabaseCodec.validateAlignment(minimumAlignment)
            let layoutRules = try inlineAggregateLayoutRules.layoutRules()
            return FieldDef(
                name: name,
                type: type,
                declaratorSemanticsV1: declaratorSemanticsV1,
                functionPointerSignatureV1: functionPointerSignatureV1,
                bitWidth: bitWidth,
                bitOffset: bitOffset,
                isPacked: isPacked,
                layoutIsUnknown: layoutIsUnknown,
                isAtomic: isAtomic,
                minimumAlignment: minimumAlignment,
                minimumAlignmentType: minimumAlignmentType,
                inlineAggregateKind: inlineAggregateKind,
                inlineFields: try inlineFields.map { try $0.field() },
                inlineAggregateLayoutRules: layoutRules,
                promotesInlineFields: promotesInlineFields,
                byteOffset: byteOffset,
                layoutSource: layoutSource
            )
        }
    }
}
