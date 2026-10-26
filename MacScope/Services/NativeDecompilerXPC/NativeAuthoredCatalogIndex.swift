import Foundation

enum NativeAuthoredProjectionDiagnostic: Error, Equatable, Sendable {
    case unsupported(id: Identity)
    case invalid(id: Identity)
    case bounds(id: Identity)

    struct Identity: Hashable, Codable, Sendable {
        let code: String
        let imageSlot: ImageSlot?
        let subject: String
    }
}

enum NativeAuthoredTypeRole: Sendable {
    case returnType
    case parameter
    case recordField
    case typedefTarget
    case minimumAlignmentType
}

struct NativeAuthoredCatalogIndex: Sendable {
    private let definitionsByName: [ExactUTF8Key: TypeDefinition]

    init(definitions: [TypeDefinition]) throws {
        var checked: [ExactUTF8Key: TypeDefinition] = [:]
        checked.reserveCapacity(definitions.count)

        for definition in definitions {
            let name = ExactUTF8Key(definition.name)
            guard !Self.reservedNames.contains(name),
                  checked[name] == nil
            else {
                throw NativeAuthoredProjectionDiagnostic.invalid(id: .authoredCatalogDefinition)
            }
            checked[name] = definition
        }

        definitionsByName = checked
    }

    func resolveBareName(_ name: String) throws -> TypeDefinition {
        guard let definition = definitionsByName[ExactUTF8Key(name)] else {
            throw NativeAuthoredProjectionDiagnostic.invalid(id: .authoredTypeGrammar)
        }
        return definition
    }

    func resolveTaggedName(_ name: String, kind: TypeKind) throws -> TypeDefinition {
        let definition = try resolveBareName(name)
        guard definition.kind == kind else {
            throw NativeAuthoredProjectionDiagnostic.invalid(id: .authoredTypeGrammar)
        }
        return definition
    }

    private static let reservedNames: Set<ExactUTF8Key> = Set([
        "void", "const", "volatile", "restrict", "__restrict", "__restrict__",
        "struct", "union", "enum", "typedef",
        "_Bool", "bool", "char", "signed char", "int8_t", "unsigned char", "uint8_t",
        "short", "short int", "signed short", "signed short int", "int16_t",
        "unsigned short", "unsigned short int", "uint16_t",
        "int", "signed", "signed int", "int32_t",
        "unsigned", "unsigned int", "uint32_t",
        "long", "long int", "signed long", "signed long int", "long long", "long long int",
        "signed long long", "signed long long int", "int64_t",
        "unsigned long", "unsigned long int", "unsigned long long", "unsigned long long int",
        "uint64_t", "float", "double", "long double",
        "size_t", "ssize_t", "intptr_t", "uintptr_t", "ptrdiff_t", "wchar_t",
    ].map(ExactUTF8Key.init))
}

private struct ExactUTF8Key: Hashable, Sendable {
    let bytes: [UInt8]

    init(_ value: String) {
        bytes = Array(value.utf8)
    }
}

extension NativeAuthoredProjectionDiagnostic.Identity {
    static let authoredCatalogDefinition = Self(
        code: "authored-catalog-definition",
        imageSlot: nil,
        subject: "type-catalog"
    )

    static let authoredTypeGrammar = Self(
        code: "authored-type-grammar",
        imageSlot: nil,
        subject: "authored-type"
    )

    static let authoredTypeSourceBytes = Self(
        code: "authored-type-source-bytes",
        imageSlot: nil,
        subject: "authored-type"
    )

    static let authoredFieldStorage = Self(
        code: "authored-field-storage",
        imageSlot: nil,
        subject: "record-field"
    )

    static let authoredFieldStorageBounds = Self(
        code: "authored-field-storage-bounds",
        imageSlot: nil,
        subject: "record-field"
    )

    static let authoringInputUnsupported = Self(
        code: "authoring-input-unsupported",
        imageSlot: nil,
        subject: "record-field"
    )
}
