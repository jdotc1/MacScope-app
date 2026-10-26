struct NativeAuthoredFieldPosition: Sendable {
    let ownerKind: TypeKind
    let index: Int
    let count: Int
}

struct NativeAuthoredFieldStorageParserV1 {
    private static let maximumDepth = 16
    private static let maximumArrayElementCount: UInt64 = 1_048_576

    static func parse(
        field: FieldDef,
        position: NativeAuthoredFieldPosition,
        catalog: NativeAuthoredCatalogIndex
    ) throws -> NativeDecompilerWireAuthoredFieldStorage {
        try validate(position)
        return try projectRecordField(
            field,
            position: position,
            catalog: catalog,
            depth: 0,
            ancestorPermitsFlexibleArray: true
        ).storage
    }

    private enum ArrayDimension {
        case fixed(UInt64)
        case flexible
    }

    private struct ArrayDeclarator {
        let base: String
        let dimensions: [ArrayDimension]
    }

    private static func projectRecordField(
        _ field: FieldDef,
        position: NativeAuthoredFieldPosition,
        catalog: NativeAuthoredCatalogIndex,
        depth: Int,
        ancestorPermitsFlexibleArray: Bool
    ) throws -> NativeDecompilerWireAuthoredRecordField {
        try validate(position)
        try requireDepth(depth)
        // Legacy authored wire storage cannot express these CP8 layout/ABI semantics.
        guard field.bitOffset == nil, field.isPacked != true,
              field.layoutIsUnknown != true, field.isAtomic != true else {
            throw NativeAuthoredProjectionDiagnostic.unsupported(id: .authoringInputUnsupported)
        }

        let permitsFlexibleArray = ancestorPermitsFlexibleArray
            && position.ownerKind == .struct
            && position.index == position.count - 1
        let storage = try parseStorage(
            field,
            catalog: catalog,
            depth: depth,
            permitsFlexibleArray: permitsFlexibleArray
        )
        let bitWidth = try wireBitWidth(field.bitWidth, name: field.name)
        let minimumAlignment = try wirePositive(field.minimumAlignment)
        let minimumAlignmentType = try parseMinimumAlignmentType(
            field.minimumAlignmentType,
            catalog: catalog,
            storageDepth: depth
        )

        try validateFieldShape(field, storage: storage, bitWidth: bitWidth)
        return .init(
            name: field.name,
            storage: storage,
            bitWidth: bitWidth,
            minimumAlignment: minimumAlignment,
            minimumAlignmentType: minimumAlignmentType,
            promotesInlineFields: field.promotesInlineFields
        )
    }

    private static func parseStorage(
        _ field: FieldDef,
        catalog: NativeAuthoredCatalogIndex,
        depth: Int,
        permitsFlexibleArray: Bool
    ) throws -> NativeDecompilerWireAuthoredFieldStorage {
        try requireDepth(depth)

        let hasInlineMetadata = field.inlineAggregateKind != nil
            || !field.inlineFields.isEmpty
            || field.inlineAggregateLayoutRules != .default
            || field.promotesInlineFields

        switch field.declaratorSemanticsV1 {
        case .ordinary:
            if let inlineKind = field.inlineAggregateKind {
                return try parseInlineAggregate(
                    field,
                    kind: inlineKind,
                    catalog: catalog,
                    depth: depth,
                    permitsFlexibleArray: permitsFlexibleArray
                )
            }
            guard !hasInlineMetadata else {
                throw invalid()
            }
            let declarator = try parseArrayDeclarator(field.type)
            return try wrap(
                declarator.dimensions,
                depth: depth,
                permitsFlexibleArray: permitsFlexibleArray
            ) { leafDepth in
                try valueStorage(
                    declarator.base,
                    catalog: catalog,
                    depth: leafDepth
                )
            }

        case .functionPointerCarrier:
            guard !hasInlineMetadata else {
                throw invalid()
            }
            return .opaquePointerCarrier(kind: .functionPointer)

        case .pointerToArrayCarrier:
            guard !hasInlineMetadata else {
                throw invalid()
            }
            return .opaquePointerCarrier(kind: .pointerToArray)

        case .arrayOfFunctionPointerCarrier:
            guard !hasInlineMetadata else {
                throw invalid()
            }
            let declarator = try parseArrayDeclarator(field.type)
            guard !declarator.dimensions.isEmpty,
                  declarator.dimensions.allSatisfy({ dimension in
                      if case .fixed = dimension { return true }
                      return false
                  })
            else {
                throw invalid()
            }
            return try wrap(
                declarator.dimensions,
                depth: depth,
                permitsFlexibleArray: false
            ) { _ in
                .opaquePointerCarrier(kind: .functionPointer)
            }

        case nil:
            guard !hasInlineMetadata else {
                throw NativeAuthoredProjectionDiagnostic.unsupported(id: .authoringInputUnsupported)
            }
            let declarator = try parseArrayDeclarator(field.type)
            guard !declarator.base.utf8.contains(0x2A) else {
                throw NativeAuthoredProjectionDiagnostic.unsupported(id: .authoringInputUnsupported)
            }
            return try wrap(
                declarator.dimensions,
                depth: depth,
                permitsFlexibleArray: permitsFlexibleArray
            ) { leafDepth in
                try valueStorage(
                    declarator.base,
                    catalog: catalog,
                    depth: leafDepth
                )
            }
        }
    }

    private static func parseInlineAggregate(
        _ field: FieldDef,
        kind: TypeKind,
        catalog: NativeAuthoredCatalogIndex,
        depth: Int,
        permitsFlexibleArray: Bool
    ) throws -> NativeDecompilerWireAuthoredFieldStorage {
        let wireKind: NativeDecompilerWireAuthoredNamedKind
        switch kind {
        case .struct:
            wireKind = .struct
        case .union:
            wireKind = .union
        case .enum, .typedef:
            throw invalid()
        }

        let layoutRules = try wireLayoutRules(field.inlineAggregateLayoutRules)
        var projectedFields: [NativeDecompilerWireAuthoredRecordField] = []
        projectedFields.reserveCapacity(field.inlineFields.count)
        for (index, nested) in field.inlineFields.enumerated() {
            try requireDepth(depth + 1)
            projectedFields.append(
                try projectRecordField(
                    nested,
                    position: .init(
                        ownerKind: kind,
                        index: index,
                        count: field.inlineFields.count
                    ),
                    catalog: catalog,
                    depth: depth + 1,
                    ancestorPermitsFlexibleArray: permitsFlexibleArray
                )
            )
        }

        return .inlineAggregate(
            kind: wireKind,
            layoutRules: layoutRules,
            fields: projectedFields
        )
    }

    private static func wrap(
        _ dimensions: [ArrayDimension],
        at index: Int = 0,
        depth: Int,
        permitsFlexibleArray: Bool,
        leaf: (Int) throws -> NativeDecompilerWireAuthoredFieldStorage
    ) throws -> NativeDecompilerWireAuthoredFieldStorage {
        guard index < dimensions.count else {
            return try leaf(depth)
        }
        try requireDepth(depth + 1)

        switch dimensions[index] {
        case let .fixed(count):
            return .fixedArray(
                element: try wrap(
                    dimensions,
                    at: index + 1,
                    depth: depth + 1,
                    permitsFlexibleArray: false,
                    leaf: leaf
                ),
                count: .init(count)
            )
        case .flexible:
            guard permitsFlexibleArray else {
                throw invalid()
            }
            return .flexibleArray(
                element: try wrap(
                    dimensions,
                    at: index + 1,
                    depth: depth + 1,
                    permitsFlexibleArray: false,
                    leaf: leaf
                )
            )
        }
    }

    private static func valueStorage(
        _ source: String,
        catalog: NativeAuthoredCatalogIndex,
        depth: Int
    ) throws -> NativeDecompilerWireAuthoredFieldStorage {
        let type = try NativeAuthoredTypeParserV1.parse(
            source,
            role: .recordField,
            catalog: catalog
        )
        try requireDepth(depth + authoredTypeDepth(type))
        return .value(type)
    }

    private static func parseMinimumAlignmentType(
        _ source: String?,
        catalog: NativeAuthoredCatalogIndex,
        storageDepth: Int
    ) throws -> NativeDecompilerWireAuthoredType? {
        guard let source else { return nil }
        let type = try NativeAuthoredTypeParserV1.parse(
            source,
            role: .minimumAlignmentType,
            catalog: catalog
        )
        try requireDepth(storageDepth + 1 + authoredTypeDepth(type))
        return type
    }

    private static func authoredTypeDepth(_ type: NativeDecompilerWireAuthoredType) -> Int {
        switch type {
        case .qualifiedValue: 0
        case .dataPointer: 1
        }
    }

    private static func parseArrayDeclarator(_ source: String) throws -> ArrayDeclarator {
        guard source.utf8.count <= 4_096 else {
            throw NativeAuthoredProjectionDiagnostic.bounds(id: .authoredTypeSourceBytes)
        }

        var bytes = Array(source.utf8)
        guard bytes.allSatisfy(isAllowedSourceByte) else {
            throw invalid()
        }
        trimASCIIWhitespace(&bytes)

        var reversedDimensions: [ArrayDimension] = []
        while bytes.last == 0x5D {
            bytes.removeLast()
            trimASCIIWhitespace(&bytes)

            guard let openingIndex = bytes.lastIndex(of: 0x5B) else {
                throw invalid()
            }
            let content = Array(bytes[(openingIndex + 1)...])
            bytes.removeSubrange(openingIndex...)
            trimASCIIWhitespace(&bytes)
            reversedDimensions.append(try parseDimension(content))
        }

        guard !bytes.contains(0x5B), !bytes.contains(0x5D), !bytes.isEmpty else {
            throw invalid()
        }
        return ArrayDeclarator(
            base: String(decoding: bytes, as: UTF8.self),
            dimensions: reversedDimensions.reversed()
        )
    }

    private static func parseDimension(_ untrimmed: [UInt8]) throws -> ArrayDimension {
        var bytes = untrimmed
        trimASCIIWhitespace(&bytes)
        guard !bytes.isEmpty else { return .flexible }
        guard bytes.allSatisfy({ (0x30...0x39).contains($0) }) else {
            throw invalid()
        }

        let text = String(decoding: bytes, as: UTF8.self)
        guard let count = UInt64(text) else {
            throw invalid()
        }
        guard count > 0 else {
            throw invalid()
        }
        guard count <= maximumArrayElementCount else {
            throw bounds()
        }
        return .fixed(count)
    }

    private static func validate(_ position: NativeAuthoredFieldPosition) throws {
        guard position.index >= 0,
              position.count > 0,
              position.index < position.count
        else {
            throw invalid()
        }
        switch position.ownerKind {
        case .struct, .union:
            break
        case .typedef:
            guard position.index == 0, position.count == 1 else {
                throw invalid()
            }
        case .enum:
            throw invalid()
        }
    }

    private static func validateFieldShape(
        _ field: FieldDef,
        storage: NativeDecompilerWireAuthoredFieldStorage,
        bitWidth: NativeDecompilerWireUInt64?
    ) throws {
        if field.promotesInlineFields {
            guard field.name.isEmpty,
                  bitWidth == nil,
                  case let .inlineAggregate(kind, _, _) = storage,
                  kind == .struct || kind == .union
            else {
                throw invalid()
            }
        } else if field.name.isEmpty {
            guard bitWidth != nil, case .value = storage else {
                throw invalid()
            }
        }

        if let bitWidth {
            guard case .value = storage else {
                throw invalid()
            }
            guard bitWidth.value != 0 || field.name.isEmpty else {
                throw invalid()
            }
        }
    }

    private static func wireBitWidth(
        _ value: Int?,
        name: String
    ) throws -> NativeDecompilerWireUInt64? {
        guard let value else { return nil }
        guard value >= 0, let converted = UInt64(exactly: value) else {
            throw invalid()
        }
        if converted == 0, !name.isEmpty {
            throw invalid()
        }
        return .init(converted)
    }

    private static func wirePositive(_ value: Int?) throws -> NativeDecompilerWireUInt64? {
        guard let value else { return nil }
        guard value > 0, let converted = UInt64(exactly: value) else {
            throw invalid()
        }
        return .init(converted)
    }

    private static func wireLayoutRules(
        _ rules: AggregateLayoutRules
    ) throws -> NativeDecompilerWireAuthoredLayoutRules {
        .init(
            isPacked: rules.isPacked,
            packAlignment: try wirePositive(rules.packAlignment),
            minimumAlignment: try wirePositive(rules.minimumAlignment)
        )
    }

    private static func requireDepth(_ depth: Int) throws {
        guard depth <= maximumDepth else {
            throw bounds()
        }
    }

    private static func isAllowedSourceByte(_ byte: UInt8) -> Bool {
        isASCIIWhitespace(byte) || (0x21...0x7E).contains(byte)
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        (0x09...0x0D).contains(byte) || byte == 0x20
    }

    private static func trimASCIIWhitespace(_ bytes: inout [UInt8]) {
        while let first = bytes.first, isASCIIWhitespace(first) {
            bytes.removeFirst()
        }
        while let last = bytes.last, isASCIIWhitespace(last) {
            bytes.removeLast()
        }
    }

    private static func invalid() -> NativeAuthoredProjectionDiagnostic {
        .invalid(id: .authoredFieldStorage)
    }

    private static func bounds() -> NativeAuthoredProjectionDiagnostic {
        .bounds(id: .authoredFieldStorageBounds)
    }
}
