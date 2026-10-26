import Foundation

/// Pure production header-import preparation, shared by the app and portable entry.
/// Store mutation, undo registration and invalidation remain with the caller.
enum HeaderImportCore {
    struct Result {
        var types: [TypeDefinition]
        var prototypes: [ImageAddress: FunctionSignatureOverride]
        var addedNames: [String]
        var diagnostics: [String]
        var importedPrototypeCount: Int
        var skippedPrototypeCount: Int
        /// Actual parsed declarations, never the merged or authored catalog.
        /// Consumers compare immutable value copies before granting layout authority.
        let headerLayoutDefinitions: [TypeDefinition]
    }

    static func prepare(source: String, typeDefinitions: [TypeDefinition],
                        exports: [ExportSummary], functions: [FunctionSummary],
                        importedPrototypes: [ImageAddress: FunctionSignatureOverride],
                        slot: ImageSlot) -> Result {
        let parsed = CTypeHeaderParser.parse(source)
        var types = typeDefinitions
        var existingNames = Set(types.map(\.name))
        var added: [String] = []
        var diagnostics = parsed.diagnostics
        for type in parsed.types {
            if existingNames.contains(type.name) {
                diagnostics.append("Skipped “\(type.name)”: a type with that name already exists in the catalog.")
                continue
            }
            existingNames.insert(type.name)
            types.append(type)
            added.append(type.name)
        }
        let conflictingTypeNames = Set(parsed.types.compactMap { type -> String? in
            guard let existing = typeDefinitions.first(where: { $0.name == type.name }) else { return nil }
            var comparable = type
            comparable.id = existing.id
            return comparable == existing ? nil : type.name
        })
        let binding = HeaderPrototypeBinding.bind(parsed.prototypes,
            exports: exports,
            functions: functions,
            existingSignatures: Dictionary(uniqueKeysWithValues: importedPrototypes.compactMap { key, value in
                key.slot == slot ? (key.address, value) : nil
            }),
            conflictingTypeNames: conflictingTypeNames)
        diagnostics.append(contentsOf: binding.diagnostics)
        var imported = importedPrototypes
        if !parsed.prototypes.isEmpty {
            let names = Set(parsed.prototypes.map { "_" + $0.name })
            let touchedAddresses = Set((exports)
                .filter { names.contains($0.name) }.compactMap(\.address))
            imported = imported.filter { $0.key.slot != slot || !touchedAddresses.contains($0.key.address) }
            for (address, signature) in binding.signatures {
                imported[ImageAddress(slot: slot, address: address)] = signature
            }
        }
        return Result(types: types, prototypes: imported, addedNames: added,
            diagnostics: diagnostics, importedPrototypeCount: binding.admittedCount,
            skippedPrototypeCount: parsed.skippedPrototypeCount + binding.refusedCount,
            headerLayoutDefinitions: parsed.types)
    }
}
