import Foundation

/// RX-02a: the JSON shape `list-image-types` returns for one Type Atlas entry. This is U7's
/// headless oracle, so it mirrors `TypeAtlasEntry` field for field (addresses as hex strings).
/// Every row carries `imageSlot` (the same value as `id.slot`), so a row read on its own still names
/// its image. Swift rows also carry `qualifiedName`, `isGeneric`, `isPrivateOrLocal` and
/// `isImportedCType`; each is null when the descriptor walk did not record it.
extension WorkspaceScriptingAPI {
    nonisolated static func typeAtlasEntryValue(_ entry: TypeAtlasEntry) -> ScriptValue {
        var id: [String: ScriptValue] = [
            "slot": .int(Int64(entry.id.slot.rawValue)),
            "kind": .string(entry.id.kind.rawValue),
        ]
        switch entry.id.key {
        case .address(let address): id["address"] = .hex(address)
        case .name(let name): id["name"] = .string(name)
        }
        var fields: [String: ScriptValue] = [
            "id": .object(id),
            "imageSlot": .int(Int64(entry.id.slot.rawValue)),
            "kind": .string(entry.kind.rawValue),
            "name": .string(entry.name),
            "superclass": entry.superclass.map(ScriptValue.string) ?? .null,
            "members": .array(entry.members.map { member in
                var value: [String: ScriptValue] = [
                    "name": .string(member.name),
                    "type": member.type.map(ScriptValue.string) ?? .null,
                    "offset": member.offset.map { ScriptValue.count($0) } ?? .null,
                    "evidence": .string(member.evidence.rawValue),
                ]
                if let size = member.size { value["size"] = .count(size) }
                if let imported = member.imported {
                    value["absoluteBitOffset"] = imported.absoluteBitOffset.map(importedLayoutInteger) ?? .null
                    value["bitWidth"] = imported.bitWidth.map(importedLayoutInteger) ?? .null
                    value["flexibleArray"] = .bool(imported.flexibleArray)
                    if imported.flexibleArray { value["extent"] = .string("unknown") }
                    value["imported"] = .object([
                        "archiveSHA256": .string(imported.typeIdentity.archiveSHA256),
                        "typeDeclarationID": .string(imported.typeIdentity.declarationID),
                        "fieldID": .string(imported.fieldID),
                        "anonymous": .bool(imported.anonymous),
                    ])
                }
                return .object(value)
            }),
            "conformances": .array(entry.conformances.map(ScriptValue.string)),
            "methods": .array(entry.methods.map { method in
                .object([
                    "name": .string(method.name),
                    "implementation": method.implementation.map { ScriptValue.hex($0) } ?? .null,
                    "isClassMethod": .bool(method.isClassMethod),
                    "selectorUsers": .array(method.selectorUsers.map { ScriptValue.hex($0) }),
                ])
            }),
            "users": .array(entry.users.map { ScriptValue.hex($0) }),
            "evidence": .string(entry.evidence.rawValue),
        ]
        if let instanceSize = entry.instanceSize { fields["instanceSize"] = .count(instanceSize) }
        switch entry.kind {
        case .swiftClass, .swiftStruct, .swiftEnum:
            fields["qualifiedName"] = entry.qualifiedName.map(ScriptValue.string) ?? .null
            fields["swiftSuperclass"] = entry.swiftSuperclass.map(ScriptValue.string) ?? .null
            fields["isGeneric"] = entry.isGeneric.map(ScriptValue.bool) ?? .null
            fields["isPrivateOrLocal"] = entry.isPrivateOrLocal.map(ScriptValue.bool) ?? .null
            fields["isImportedCType"] = entry.isImportedCType.map(ScriptValue.bool) ?? .null
        case .objcClass, .objcCategory, .objcProtocol, .userType, .importedType:
            break
        }
        if let imported = entry.imported {
            fields["imported"] = .object([
                "archiveSHA256": .string(imported.identity.archiveSHA256),
                "declarationID": .string(imported.identity.declarationID),
                "configurationID": .string(imported.configurationID),
                "targetTriple": .string(imported.targetTriple),
                "sdkIdentity": .string(imported.sdkIdentity),
                "compiler": .string(imported.compiler),
                "compilerVersion": .string(imported.compilerVersion),
                "libclangVersion": .string(imported.libclangVersion),
                "language": .string(imported.language),
                "extractorVersion": .string(imported.extractorVersion),
                "input": .string(imported.input),
                "sourceHeader": imported.sourceHeader.map(ScriptValue.string) ?? .null,
                "sourceLine": imported.sourceLine.map { .int(Int64($0)) } ?? .null,
                "sourceColumn": imported.sourceColumn.map { .int(Int64($0)) } ?? .null,
                "typeKind": .string(imported.typeKind),
                "recordKind": imported.recordKind.map(ScriptValue.string) ?? .null,
                "layoutStatus": .string(imported.layoutStatus),
                "layoutReason": imported.layoutReason.map(ScriptValue.string) ?? .null,
                "alignmentBytes": imported.alignmentBytes.map(importedLayoutInteger) ?? .null,
            ])
        }
        return .object(fields)
    }

    /// Include additive archive text in the same finite budget as legacy fields.
    nonisolated static func visitImportedTypeText(
        in entry: TypeAtlasEntry, _ visit: (String?) throws -> Void
    ) rethrows {
        try visit(entry.qualifiedName)
        try visit(entry.swiftSuperclass)
        if let imported = entry.imported {
            if case .name(let name) = entry.id.key { try visit(name) }
            try visit(imported.identity.archiveSHA256)
            try visit(imported.identity.declarationID)
            try visit(imported.configurationID)
            try visit(imported.targetTriple)
            try visit(imported.sdkIdentity)
            try visit(imported.compiler)
            try visit(imported.compilerVersion)
            try visit(imported.libclangVersion)
            try visit(imported.language)
            try visit(imported.extractorVersion)
            try visit(imported.input)
            try visit(imported.sourceHeader)
            try visit(imported.typeKind)
            try visit(imported.recordKind)
            try visit(imported.layoutStatus)
            try visit(imported.layoutReason)
        }
        for member in entry.members {
            guard let imported = member.imported else { continue }
            try visit(imported.typeIdentity.archiveSHA256)
            try visit(imported.typeIdentity.declarationID)
            try visit(imported.fieldID)
        }
    }

    /// Archive bit positions may exceed Int64. Preserve those exact values as
    /// decimal text rather than rounding through Double; legacy fields are unchanged.
    nonisolated private static func importedLayoutInteger(_ value: UInt64) -> ScriptValue {
        value <= UInt64(Int64.max) ? .int(Int64(value)) : .string(String(value))
    }
}
