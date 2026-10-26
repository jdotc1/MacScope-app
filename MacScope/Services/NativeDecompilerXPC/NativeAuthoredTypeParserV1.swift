struct NativeAuthoredTypeParserV1 {
    static func parse(
        _ source: String,
        role: NativeAuthoredTypeRole,
        catalog: NativeAuthoredCatalogIndex
    ) throws -> NativeDecompilerWireAuthoredType {
        guard source.utf8.count <= 4_096 else {
            throw NativeAuthoredProjectionDiagnostic.bounds(id: .authoredTypeSourceBytes)
        }

        let tokens = try tokenize(source)
        guard !tokens.isEmpty else {
            throw NativeAuthoredProjectionDiagnostic.invalid(id: .authoredTypeGrammar)
        }

        let firstPointer = tokens.firstIndex(of: "*") ?? tokens.endIndex
        let baseTokens = Array(tokens[..<firstPointer])
        guard !baseTokens.isEmpty else {
            throw NativeAuthoredProjectionDiagnostic.invalid(id: .authoredTypeGrammar)
        }

        let base = try parseBase(baseTokens, catalog: catalog)
        let pointerLevels = try parsePointerLevels(Array(tokens[firstPointer...]))

        if pointerLevels.isEmpty {
            if base.atom == .void, role != .returnType {
                throw NativeAuthoredProjectionDiagnostic.invalid(id: .authoredTypeGrammar)
            }
            return .qualifiedValue(atom: base.atom, qualifiers: base.qualifiers)
        }

        return .dataPointer(
            pointee: .qualifiedValue(atom: base.atom, qualifiers: base.qualifiers),
            indirectionLevel: .init(UInt64(pointerLevels.count)),
            pointerQualifiersByLevel: pointerLevels
        )
    }

    private struct ParsedBase {
        let atom: NativeDecompilerWireAuthoredAtom
        let qualifiers: NativeDecompilerWireAuthoredQualifiers
    }

    private static func tokenize(_ source: String) throws -> [String] {
        var result: [String] = []
        var current: [UInt8] = []

        func finishToken() {
            guard !current.isEmpty else { return }
            result.append(String(decoding: current, as: UTF8.self))
            current.removeAll(keepingCapacity: true)
        }

        for byte in source.utf8 {
            switch byte {
            case 0x09...0x0D, 0x20:
                finishToken()
            case 0x2A:
                finishToken()
                result.append("*")
            case 0x21...0x7E:
                current.append(byte)
            default:
                throw NativeAuthoredProjectionDiagnostic.invalid(id: .authoredTypeGrammar)
            }
        }
        finishToken()
        return result
    }

    private static func parseBase(
        _ tokens: [String],
        catalog: NativeAuthoredCatalogIndex
    ) throws -> ParsedBase {
        var lowerBound = 0
        var upperBound = tokens.count
        var qualifiers: NativeDecompilerWireAuthoredQualifiers = []

        while lowerBound < upperBound, let qualifier = baseQualifier(tokens[lowerBound]) {
            try insert(qualifier, into: &qualifiers)
            lowerBound += 1
        }
        while lowerBound < upperBound, let qualifier = baseQualifier(tokens[upperBound - 1]) {
            try insert(qualifier, into: &qualifiers)
            upperBound -= 1
        }

        guard lowerBound < upperBound else {
            throw NativeAuthoredProjectionDiagnostic.invalid(id: .authoredTypeGrammar)
        }
        let atomTokens = Array(tokens[lowerBound..<upperBound])
        let atom = try parseAtom(atomTokens, catalog: catalog)
        return ParsedBase(atom: atom, qualifiers: qualifiers)
    }

    private static func parsePointerLevels(
        _ tokens: [String]
    ) throws -> [NativeDecompilerWireAuthoredQualifiers] {
        guard !tokens.isEmpty else { return [] }

        var levels: [NativeDecompilerWireAuthoredQualifiers] = []
        var index = 0
        while index < tokens.count {
            guard tokens[index] == "*", levels.count < 8 else {
                throw NativeAuthoredProjectionDiagnostic.invalid(id: .authoredTypeGrammar)
            }
            index += 1

            var qualifiers: NativeDecompilerWireAuthoredQualifiers = []
            while index < tokens.count, tokens[index] != "*" {
                guard let qualifier = pointerQualifier(tokens[index]) else {
                    throw NativeAuthoredProjectionDiagnostic.invalid(id: .authoredTypeGrammar)
                }
                try insert(qualifier, into: &qualifiers)
                index += 1
            }
            levels.append(qualifiers)
        }
        return levels
    }

    private static func parseAtom(
        _ tokens: [String],
        catalog: NativeAuthoredCatalogIndex
    ) throws -> NativeDecompilerWireAuthoredAtom {
        let spelling = tokens.joined(separator: " ")
        if spelling == "void" {
            return .void
        }
        if let kind = scalarSpellings[spelling] {
            return .scalar(kind)
        }
        if let alias = darwinAliases[spelling] {
            return .darwinAlias(alias)
        }

        if tokens.count == 2, let taggedKind = taggedKind(tokens[0]), isIdentifier(tokens[1]) {
            let definition = try catalog.resolveTaggedName(tokens[1], kind: taggedKind)
            return .named(kind: wireKind(definition.kind), name: definition.name)
        }

        if tokens.count == 1, isIdentifier(tokens[0]) {
            let definition = try catalog.resolveBareName(tokens[0])
            return .named(kind: wireKind(definition.kind), name: definition.name)
        }

        throw NativeAuthoredProjectionDiagnostic.invalid(id: .authoredTypeGrammar)
    }

    private static func insert(
        _ qualifier: NativeDecompilerWireAuthoredQualifiers,
        into qualifiers: inout NativeDecompilerWireAuthoredQualifiers
    ) throws {
        guard qualifiers.intersection(qualifier).isEmpty else {
            throw NativeAuthoredProjectionDiagnostic.invalid(id: .authoredTypeGrammar)
        }
        qualifiers.formUnion(qualifier)
    }

    private static func baseQualifier(
        _ token: String
    ) -> NativeDecompilerWireAuthoredQualifiers? {
        switch token {
        case "const": .constant
        case "volatile": .volatile
        default: nil
        }
    }

    private static func pointerQualifier(
        _ token: String
    ) -> NativeDecompilerWireAuthoredQualifiers? {
        if let qualifier = baseQualifier(token) {
            return qualifier
        }
        switch token {
        case "restrict", "__restrict", "__restrict__":
            return .restrict
        default:
            return nil
        }
    }

    private static func taggedKind(_ token: String) -> TypeKind? {
        switch token {
        case "struct": .struct
        case "union": .union
        case "enum": .enum
        default: nil
        }
    }

    private static func wireKind(_ kind: TypeKind) -> NativeDecompilerWireAuthoredNamedKind {
        switch kind {
        case .struct: .struct
        case .union: .union
        case .enum: .enum
        case .typedef: .typedef
        }
    }

    private static func isIdentifier(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard let first = bytes.first, isIdentifierHead(first) else { return false }
        return bytes.dropFirst().allSatisfy(isIdentifierBody)
    }

    private static func isIdentifierHead(_ byte: UInt8) -> Bool {
        byte == 0x5F || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isIdentifierBody(_ byte: UInt8) -> Bool {
        isIdentifierHead(byte) || (0x30...0x39).contains(byte)
    }

    private static let scalarSpellings: [String: NativeDecompilerWireAuthoredScalarKind] = [
        "_Bool": .bool,
        "bool": .bool,
        "char": .char,
        "signed char": .signed8,
        "int8_t": .signed8,
        "unsigned char": .unsigned8,
        "uint8_t": .unsigned8,
        "short": .signed16,
        "short int": .signed16,
        "signed short": .signed16,
        "signed short int": .signed16,
        "int16_t": .signed16,
        "unsigned short": .unsigned16,
        "unsigned short int": .unsigned16,
        "uint16_t": .unsigned16,
        "int": .signed32,
        "signed": .signed32,
        "signed int": .signed32,
        "int32_t": .signed32,
        "unsigned": .unsigned32,
        "unsigned int": .unsigned32,
        "uint32_t": .unsigned32,
        "long": .signed64,
        "long int": .signed64,
        "signed long": .signed64,
        "signed long int": .signed64,
        "long long": .signed64,
        "long long int": .signed64,
        "signed long long": .signed64,
        "signed long long int": .signed64,
        "int64_t": .signed64,
        "unsigned long": .unsigned64,
        "unsigned long int": .unsigned64,
        "unsigned long long": .unsigned64,
        "unsigned long long int": .unsigned64,
        "uint64_t": .unsigned64,
        "float": .float32,
        "double": .float64,
        "long double": .float64,
    ]

    private static let darwinAliases: [String: NativeDecompilerWireAuthoredDarwinAliasKind] = [
        "size_t": .sizeT,
        "ssize_t": .ssizeT,
        "intptr_t": .intptrT,
        "uintptr_t": .uintptrT,
        "ptrdiff_t": .ptrdiffT,
        "wchar_t": .wcharT,
    ]
}
