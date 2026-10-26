import Foundation

extension WorkspaceScriptingAPI {
    /// Shared preflight for analysis that hands user types to the synchronous ABI layout engine.
    nonisolated static func validateSnapshotTypeDefinitions(
        _ definitions: [TypeDefinition], checkpoint: () throws -> Void = {}
    ) throws {
        var budget = AttachedTypeReadBudget()
        try budget.definitions(definitions, includeLayout: true, checkpoint: checkpoint)
    }

    /// Attached reads preflight all preparation inputs before invoking the shared catalog builder.
    /// Its caches and reply projection stay authoritative. Oversized work is refused, rather than
    /// constructing an unbounded catalog and applying a row prefix afterwards.
    nonisolated static func snapshotTypeListRead(
        _ command: String, arguments: ScriptValue, snapshot: WorkspaceSnapshot,
        checkpoint: () throws -> Void = {}
    ) throws -> ScriptValue {
        var budget = AttachedTypeReadBudget()
        try checkpoint()
        try budget.definitions(snapshot.typeDefinitions, includeLayout: command == "list-image-types",
                               checkpoint: checkpoint)
        if command == "list-types" {
            var rows: [ScriptValue] = []
            for definition in snapshot.typeDefinitions {
                try checkpoint()
                rows.append(.object([
                    "name": .string(definition.name), "kind": .string(definition.kind.rawValue),
                    "fields": .array(definition.fields.map {
                        .object(["name": .string($0.name), "type": .string($0.type)])
                    }),
                ]))
            }
            return .array(rows)
        }
        guard command == "list-image-types" else { throw ScriptingError.unknownCommand(command) }
        try budget.take(snapshot.binaries.count)
        let slot = try resolveImageSlot(arguments, snapshot: snapshot)
        let kind: TypeAtlasKind?
        if let text = arguments["kind"]?.stringValue {
            guard let parsed = TypeAtlasKind(rawValue: text) else {
                throw ScriptingError.invalidArgument(
                    "kind must be one of \(TypeAtlasKind.allCases.map(\.rawValue).joined(separator: "|"))")
            }
            kind = parsed
        } else { kind = nil }
        try budget.take(snapshot.addressOverrides.count)
        for override in snapshot.addressOverrides.values {
            try checkpoint()
            try budget.text(override.appliedTypeName)
        }
        if let analysis = snapshot.analysisBySlot[slot] {
            if let catalog = analysis.typeCatalog {
                try budget.entries(catalog.entries, checkpoint: checkpoint)
            } else {
                try budget.analysis(analysis, checkpoint: checkpoint)
            }
        }
        try checkpoint()
        let catalog = snapshot.typeCatalog(in: slot)
        try checkpoint()
        // Check derived fan-out (class/selector users and conformance reuse) before JSON rows.
        var outputBudget = AttachedTypeReadBudget()
        try outputBudget.entries(catalog.entries, checkpoint: checkpoint)
        let requested = arguments["limit"]?.intValue ?? 5_000
        let limit = Int(max(0, min(requested, 5_000)))
        var total = 0
        var rows: [ScriptValue] = []
        for entry in catalog.entries {
            try checkpoint()
            guard kind == nil || entry.kind == kind else { continue }
            total += 1
            if rows.count < limit { rows.append(typeAtlasEntryValue(entry)) }
        }
        var result = imageProvenanceFields(slot: slot, snapshot: snapshot)
        result["total"] = .count(UInt64(total))
        result["types"] = .array(rows)
        return .object(result)
    }
}

/// Aggregate bounds, including nested collections and strings, apply before allocation. The
/// shared builder's cross-products also consume work credit; a row cap alone is insufficient.
private struct AttachedTypeReadBudget {
    private var nodes = 4_096
    private var bytes = 262_144
    private var work = 1_000_000

    mutating func take(_ count: Int) throws {
        guard count >= 0, count <= nodes else { throw Self.refused }
        nodes -= count
    }

    mutating func charge(_ count: Int, times: Int = 1) throws {
        let (cost, overflow) = count.multipliedReportingOverflow(by: times)
        guard !overflow, cost >= 0, cost <= work else { throw Self.refused }
        work -= cost
    }

    mutating func text(_ value: String?) throws {
        guard let value else { return }
        // Bounded prefix counting avoids walking an arbitrarily large UTF-8 view.
        let count = value.utf8.prefix(2_049).count
        guard count <= 2_048, count <= bytes else { throw Self.refused }
        bytes -= count
    }

    mutating func texts(_ values: [String]) throws {
        try take(values.count)
        for value in values { try text(value) }
    }

    mutating func definitions(_ values: [TypeDefinition], includeLayout: Bool,
                              checkpoint: () throws -> Void) throws {
        try checkpoint()
        try take(values.count)
        for definition in values {
            try checkpoint()
            try text(definition.name)
            try fields(definition.fields, depth: 0, checkpoint: checkpoint)
        }
        guard includeLayout else { return }
        // ABI layout revisits nested aliases/aggregates. Charge a conservative expansion
        // estimate before the existing synchronous layout engine receives the definitions.
        for definition in values {
            try layout(definition.fields, catalog: values, visiting: [definition.name],
                       multiplier: 1, checkpoint: checkpoint)
        }
    }

    mutating func fields(_ values: [FieldDef], depth: Int, checkpoint: () throws -> Void) throws {
        guard depth < 16 else { throw Self.refused }
        try take(values.count)
        for value in values {
            try checkpoint()
            try text(value.name); try text(value.type); try text(value.minimumAlignmentType)
            try fields(value.inlineFields, depth: depth + 1, checkpoint: checkpoint)
        }
    }

    mutating func layout(_ fields: [FieldDef], catalog: [TypeDefinition], visiting: Set<String>,
                         multiplier: Int, checkpoint: () throws -> Void) throws {
        // Layout asks for size, alignment, atomic/bitfield rules and promoted members separately.
        // 64 credits per expansion deliberately overestimates these bounded repeated visits.
        try charge(fields.count, times: multiplier)
        for field in fields {
            try checkpoint()
            let (next, overflow) = multiplier.multipliedReportingOverflow(by: 64)
            guard !overflow else { throw Self.refused }
            if !field.inlineFields.isEmpty {
                try layout(field.inlineFields, catalog: catalog, visiting: visiting,
                           multiplier: next, checkpoint: checkpoint)
            }
            for definition in catalog where !visiting.contains(definition.name) {
                try charge(1)
                // A conservative superset of the layout engine's exact aggregate/alias lookup.
                // False matches only refuse unusually complex input; no layout is fabricated.
                if field.type.contains(definition.name)
                    || field.minimumAlignmentType?.contains(definition.name) == true {
                    try layout(definition.fields, catalog: catalog, visiting: visiting.union([definition.name]),
                               multiplier: next, checkpoint: checkpoint)
                }
            }
        }
    }

    mutating func methods(_ values: [ObjCMethod]) throws {
        try take(values.count)
        for value in values { try text(value.selector) }
    }

    mutating func analysis(_ value: ImageAnalysis, checkpoint: () throws -> Void) throws {
        try take(value.objcClasses.count); try take(value.objcCategories.count)
        try take(value.objcProtocols.count); try take(value.swiftTypes.count)
        try take(value.swiftConformances.count); try take(value.xrefs.count)
        try take(value.objcSelectors.count); try take(value.objcClassReferences.count)
        var methodCount = 0
        for cls in value.objcClasses {
            try checkpoint()
            try text(cls.name); try text(cls.superclassName); try texts(cls.adoptedProtocols)
            try methods(cls.classMethods); try methods(cls.instanceMethods)
            methodCount += cls.classMethods.count + cls.instanceMethods.count
            try take(cls.ivars.count)
            for member in cls.ivars { try text(member.name); try text(member.typeEncoding) }
        }
        for category in value.objcCategories {
            try checkpoint()
            try text(category.name); try text(category.className); try texts(category.adoptedProtocols)
            try methods(category.classMethods); try methods(category.instanceMethods)
            methodCount += category.classMethods.count + category.instanceMethods.count
        }
        for proto in value.objcProtocols {
            try checkpoint()
            try text(proto.name); try texts(proto.adoptedProtocols)
            try methods(proto.requiredMethods); try methods(proto.optionalMethods)
            methodCount += proto.requiredMethods.count + proto.optionalMethods.count
            try take(proto.properties.count)
            for property in proto.properties { try text(property.name); try text(property.attributes) }
        }
        var conformanceMethods = 0
        for conformance in value.swiftConformances {
            try checkpoint()
            try text(conformance.typeName); try text(conformance.protocolName)
            try take(conformance.methods?.count ?? 0)
            conformanceMethods += conformance.methods?.count ?? 0
        }
        for type in value.swiftTypes {
            try checkpoint()
            try text(type.name); try text(type.qualifiedName); try text(type.superclass)
            try take(type.fields.count); try take(type.methods?.count ?? 0)
            for field in type.fields { try text(field.name); try text(field.typeName) }
        }
        for selector in value.objcSelectors.values { try checkpoint(); try text(selector) }
        for reference in value.objcClassReferences.values { try checkpoint(); try text(reference.name) }
        // Each method can inherit every selector user; each class can inherit every class user.
        try take((methodCount + value.objcClasses.count) * value.xrefs.count)
        try take(value.swiftTypes.count * (value.swiftConformances.count + conformanceMethods))
    }

    mutating func entries(_ values: [TypeAtlasEntry], checkpoint: () throws -> Void) throws {
        try take(values.count)
        for entry in values {
            try checkpoint()
            try text(entry.name); try text(entry.superclass)
            try WorkspaceScriptingAPI.visitImportedTypeText(in: entry) { try text($0) }
            try take(entry.members.count); try take(entry.users.count); try texts(entry.conformances)
            for member in entry.members { try text(member.name); try text(member.type) }
            try take(entry.methods.count)
            for method in entry.methods { try text(method.name); try take(method.selectorUsers.count) }
            // These cached fields are retained by catalog preparation even though the existing
            // JSON projection omits them; they still count toward request-owned nested work.
            try take(entry.declaredProperties?.count ?? 0)
            for property in entry.declaredProperties ?? [] { try text(property.name); try text(property.attributes) }
            try take(entry.swiftConformanceMethods?.count ?? 0)
            for conformance in entry.swiftConformanceMethods ?? [] {
                try text(conformance.protocolName)
                try take(conformance.methods?.count ?? 0)
                for method in conformance.methods ?? [] { try text(method.name); try take(method.selectorUsers.count) }
            }
        }
    }

    static var refused: ScriptingError {
        .invalidArgument("Type read exceeds the finite preparation or nested-result budget; narrow the workspace type catalog.")
    }
}
