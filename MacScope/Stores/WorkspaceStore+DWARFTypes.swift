import Foundation

/// Converts debug metadata into catalog types without inventing missing layout.
extension WorkspaceStore {
    static func typeDefinitions(from dwarfTypes: [DWARFType], existingTypeNames: Set<String>) -> [TypeDefinition] {
        var seenNames = existingTypeNames
        var definitions: [TypeDefinition] = []

        for dwarfType in dwarfTypes {
            guard let definition = typeDefinition(from: dwarfType),
                  !seenNames.contains(definition.name) else {
                continue
            }
            seenNames.insert(definition.name)
            definitions.append(definition)
        }

        return definitions
    }

    private static func typeDefinition(from dwarfType: DWARFType) -> TypeDefinition? {
        guard let name = normalizedOverrideText(dwarfType.name) else { return nil }

        switch TypeKind(rawValue: dwarfType.kind) {
        case .struct:
            let fields = fieldDefinitions(from: dwarfType.members)
            guard !fields.isEmpty, fields.count == dwarfType.members.count else { return nil }
            return TypeDefinition(kind: .struct, name: name, fields: fields)

        case .union:
            let fields = fieldDefinitions(from: dwarfType.members)
            guard !fields.isEmpty, fields.count == dwarfType.members.count else { return nil }
            return TypeDefinition(kind: .union, name: name, fields: fields)

        case .enum:
            var fields: [FieldDef] = []
            for enumerator in dwarfType.enumerators {
                guard let fieldName = normalizedOverrideText(enumerator.name),
                      let value = enumerator.value else {
                    return nil
                }
                fields.append(FieldDef(name: fieldName, type: String(value)))
            }
            guard !fields.isEmpty else { return nil }
            return TypeDefinition(kind: .enum, name: name, fields: fields)

        case .typedef, nil:
            return nil
        }
    }

    private static func fieldDefinitions(from members: [DWARFTypeMember]) -> [FieldDef] {
        members.compactMap { member in
            guard let name = normalizedOverrideText(member.name),
                  let type = normalizedOverrideText(member.typeName) else {
                return nil
            }
            // RX-02a: keep the dSYM's recorded member offset rather than only recomputing it.
            return FieldDef(name: name, type: type, byteOffset: member.byteOffset.flatMap { Int(exactly: $0) },
                            layoutSource: .dwarf)
        }
    }

}
