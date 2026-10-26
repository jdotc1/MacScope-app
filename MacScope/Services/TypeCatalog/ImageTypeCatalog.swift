import Foundation

// RX-02a: the per-image Type Atlas engine seam.
//
// `ImageTypeCatalog` is a PURE projection over one image's `ImageAnalysis` (Objective-C classes,
// categories and adopted protocols; Swift nominal types and conformances; classref and selref
// xrefs) plus the workspace's user `TypeDefinition`s. It is derived and never saved.
//
// Caching follows `ImageConstantStringProvider` (#355): the image part is built once when the image
// is analysed, rehydrated, or decoded from a worker reply and stored on
// `ImageAnalysis.typeCatalog`; `WorkspaceSnapshot.typeCatalog(in:)` reads that stored value and
// only appends the (workspace-wide, user-editable) user types. Changing any input field of
// `ImageAnalysis` clears the stored value, and the accessor then projects on demand, so a stale
// catalog is never served.

/// What a Type Atlas entry is.
enum TypeAtlasKind: String, Hashable, Codable, Sendable, CaseIterable {
    case swiftClass
    case swiftStruct
    case swiftEnum
    case objcClass
    case objcCategory
    /// A protocol object, or a name-only external adoption.
    case objcProtocol
    case userType
    /// Immutable compiler-imported archive facts, separate from editable authored types.
    case importedType
}

/// Where a fact came from.
enum TypeAtlasEvidence: String, Hashable, Codable, Sendable {
    /// Read from compiler-emitted metadata (a Swift type descriptor, an ObjC `class_t`/`ivar_t`,
    /// a DWARF member offset). ObjC offsets and instance sizes describe the image at link time;
    /// the non-fragile runtime may slide them after loading.
    case descriptor
    /// Computed by static evaluation rather than directly read from a metadata record.
    case staticEvaluation
    /// Authored by the user (a `TypeDefinition` laid out by the C ABI rules).
    case authored
    /// Recorded by the archive compiler, never recomputed by the authored layout engine.
    case compilerImport
    /// Not known. A member with this evidence has a nil offset: "unknown layout", never a guess.
    case unknown
}

/// The stable identity of one entry: the image slot, the kind, and the metadata address when the
/// entry has one (Swift descriptor, ObjC `class_t`/`category_t`), otherwise the name.
struct TypeAtlasEntryID: Hashable, Codable, Sendable {
    enum Key: Hashable, Codable, Sendable {
        case address(UInt64)
        case name(String)
    }

    var slot: ImageSlot
    var kind: TypeAtlasKind
    var key: Key
}

/// One stored member: an ObjC ivar, a Swift stored property or enum case, or a user field.
struct TypeAtlasMember: Hashable, Codable, Sendable {
    var name: String
    var type: String?
    var offset: UInt64?
    var evidence: TypeAtlasEvidence
    /// Additive: the member's byte size when the metadata records it (ObjC `ivar_t.size`).
    var size: UInt64? = nil
    var imported: ImportedTypeMemberMetadata? = nil
}

/// One method: an ObjC selector (with its IMP) or a named method.
struct TypeAtlasMethod: Hashable, Codable, Sendable {
    /// The selector (ObjC) or method name.
    var name: String
    /// The implementation address (ObjC `method_t.imp`), when known.
    var implementation: UInt64?
    /// Additive: `+` class method (ObjC) rather than `-` instance method.
    var isClassMethod: Bool = false
    /// Additive: instructions that load a selector-reference slot naming this selector (`selref`
    /// xrefs). A selector is not unique to one class, so this is "may send", not "calls".
    var selectorUsers: [UInt64] = []
    /// Present for protocol requirements; nil for class/category methods.
    var isOptionalRequirement: Bool? = nil
    /// Swift table identity/flags; the name may be an explicit positional label, not a source name.
    var swiftMetadata: SwiftMetadataMethod? = nil
}

struct TypeAtlasConformanceMethods: Hashable, Codable, Sendable {
    var protocolName: String
    var descriptorAddress: UInt64?
    /// Nil means witness-table recovery was unavailable, rather than an empty known list.
    var methods: [TypeAtlasMethod]?
}

/// One Type Atlas row. FROZEN shape (RX-02a): fields may be added, never changed or removed.
struct TypeAtlasEntry: Hashable, Codable, Sendable, Identifiable {
    var id: TypeAtlasEntryID
    var kind: TypeAtlasKind
    var name: String
    var superclass: String?
    var members: [TypeAtlasMember]
    var conformances: [String]
    var methods: [TypeAtlasMethod]
    /// Instruction addresses that use the type: for an ObjC class, `classref` xref sources plus
    /// direct `data` references to its `class_t`; for a user type, the addresses the user applied
    /// it to. Sorted, unique.
    var users: [UInt64]
    var evidence: TypeAtlasEvidence
    /// Additive: the instance size in bytes when the metadata records it (ObjC
    /// `class_ro_t.instanceSize`).
    var instanceSize: UInt64? = nil
    /// Declared properties are requirements, not stored members or inferred ivars.
    var declaredProperties: [ObjCProperty]? = nil
    var swiftConformanceMethods: [TypeAtlasConformanceMethods]? = nil
    /// Nil on legacy/non-Swift rows; false when the Swift class table could not be resolved.
    var swiftMethodTableResolved: Bool? = nil
    var imported: ImportedTypeLayoutMetadata? = nil
    /// Additive, Swift rows only: `Module.Outer.Inner` from the descriptor's parent walk. nil when
    /// the walk could not reach a module; never a guessed module.
    var qualifiedName: String? = nil
    /// Additive, Swift class rows only: the superclass as the metadata records it (a mangled-name
    /// string). It is kept apart from `superclass`, which the Inspector and Navigator treat as the
    /// name of a catalog entry to link to.
    var swiftSuperclass: String? = nil
    /// Additive, Swift rows only: the context descriptor's generic flag; nil when not recorded.
    var isGeneric: Bool? = nil
    /// Additive, Swift rows only: an anonymous (private or local) context is in the parent chain.
    var isPrivateOrLocal: Bool? = nil
    /// Additive, Swift rows only: the parent chain ends at the `__C` module (a Clang-imported type).
    var isImportedCType: Bool? = nil
}

/// The Type Atlas of one image.
struct ImageTypeCatalog: Hashable, Sendable {
    var slot: ImageSlot
    var entries: [TypeAtlasEntry]

    static func empty(in slot: ImageSlot) -> ImageTypeCatalog { ImageTypeCatalog(slot: slot, entries: []) }

    func entry(id: TypeAtlasEntryID) -> TypeAtlasEntry? { entries.first { $0.id == id } }
    func entries(of kind: TypeAtlasKind) -> [TypeAtlasEntry] { entries.filter { $0.kind == kind } }
    func entries(named name: String) -> [TypeAtlasEntry] { entries.filter { $0.name == name } }

    /// An explicit, ephemeral injection seam for an archive catalog. Keep every
    /// image/authored row and replace only an already projected identical import.
    func including(importedTypes: ImportedTypeLayoutProvider) -> ImageTypeCatalog {
        var result = self
        let imported = importedTypes.entries(in: slot)
        let identities = Set(imported.map(\.id))
        result.entries.removeAll { $0.kind == .importedType && identities.contains($0.id) }
        result.entries += imported
        return result
    }

    /// The same catalog stamped with another slot (the cached image part is built slot-agnostic
    /// at `.primary`; a multi-image splice can move it).
    func restamped(to slot: ImageSlot) -> ImageTypeCatalog {
        guard slot != self.slot else { return self }
        return ImageTypeCatalog(slot: slot, entries: entries.map { entry in
            var copy = entry
            copy.id.slot = slot
            return copy
        })
    }
}

// MARK: - Builder

enum ImageTypeCatalogBuilder {
    /// The image part: everything derived from the image's own metadata and xrefs.
    static func build(analysis: ImageAnalysis, slot: ImageSlot = .primary) -> ImageTypeCatalog {
        build(
            slot: slot,
            objcClasses: analysis.objcClasses,
            objcCategories: analysis.objcCategories,
            objcProtocols: analysis.objcProtocols,
            swiftTypes: analysis.swiftTypes,
            swiftConformances: analysis.swiftConformances,
            xrefs: analysis.xrefs,
            objcSelectors: analysis.objcSelectors,
            objcClassReferences: analysis.objcClassReferences
        )
    }

    static func build(
        slot: ImageSlot,
        objcClasses: [ObjCClass],
        objcCategories: [ObjCCategory],
        objcProtocols: [ObjCProtocol] = [],
        swiftTypes: [SwiftTypeDescriptor],
        swiftConformances: [SwiftConformance],
        xrefs: [XRef],
        objcSelectors: [UInt64: String],
        objcClassReferences: [UInt64: ObjCClassReferenceTarget]
    ) -> ImageTypeCatalog {
        // classref users, indexed by the class address and by the class name the slot names.
        var classUsersByAddress: [UInt64: Set<UInt64>] = [:]
        var classUsersByName: [String: Set<UInt64>] = [:]
        // selref users by selector string.
        var selectorUsers: [String: Set<UInt64>] = [:]
        // A same-image class is usually referenced DIRECTLY (`adrp`+`add` to its `class_t`, e.g.
        // `objc_opt_new(Widget)`), not through a classref slot: that is a `data` xref whose
        // target is exactly the class address.
        let classAddresses = Set(objcClasses.compactMap(\.address))
        for xref in xrefs {
            switch xref.kind {
            case XRefKind.data where classAddresses.contains(xref.to):
                classUsersByAddress[xref.to, default: []].insert(xref.from)
            case XRefKind.classref:
                guard let target = objcClassReferences[xref.to] else { continue }
                if let address = target.classAddress { classUsersByAddress[address, default: []].insert(xref.from) }
                if let name = target.name { classUsersByName[name, default: []].insert(xref.from) }
            case XRefKind.selref:
                guard let selector = objcSelectors[xref.to] else { continue }
                selectorUsers[selector, default: []].insert(xref.from)
            default:
                continue
            }
        }

        func methods(_ list: [ObjCMethod]) -> [TypeAtlasMethod] {
            list.map { method in
                TypeAtlasMethod(
                    name: method.selector,
                    implementation: method.implementation,
                    isClassMethod: method.isClassMethod,
                    selectorUsers: (selectorUsers[method.selector] ?? []).sorted()
                )
            }
        }

        var entries: [TypeAtlasEntry] = []
        entries.reserveCapacity(objcClasses.count + objcCategories.count + swiftTypes.count)

        for cls in objcClasses {
            var users = classUsersByName[cls.name] ?? []
            if let address = cls.address { users.formUnion(classUsersByAddress[address] ?? []) }
            entries.append(TypeAtlasEntry(
                id: TypeAtlasEntryID(slot: slot, kind: .objcClass, key: cls.address.map { .address($0) } ?? .name(cls.name)),
                kind: .objcClass,
                name: cls.name,
                superclass: cls.superclassName,
                members: cls.ivars.map { ivar in
                    TypeAtlasMember(
                        name: ivar.name,
                        type: ivar.typeEncoding.map(ObjCTypeEncoding.decode),
                        offset: ivar.offset,
                        evidence: ivar.offset == nil ? .unknown : .descriptor,
                        size: ivar.size
                    )
                },
                conformances: cls.adoptedProtocols,
                methods: methods(cls.instanceMethods) + methods(cls.classMethods),
                users: users.sorted(),
                evidence: .descriptor,
                instanceSize: cls.instanceSize
            ))
        }

        for category in objcCategories {
            entries.append(TypeAtlasEntry(
                id: TypeAtlasEntryID(
                    slot: slot, kind: .objcCategory,
                    key: category.address.map { .address($0) } ?? .name("\(category.className)(\(category.name))")
                ),
                kind: .objcCategory,
                name: "\(category.className) (\(category.name))",
                // The class the category extends.
                superclass: category.className,
                members: [],
                conformances: category.adoptedProtocols,
                methods: methods(category.instanceMethods) + methods(category.classMethods),
                users: [],
                evidence: .descriptor
            ))
        }

        // Prefer protocol objects; external adoptions retain name-only unknown rows.
        var protocolNames: [String] = []
        var seenProtocols: Set<String> = []
        for proto in objcProtocols where seenProtocols.insert(proto.name).inserted {
            let required = methods(proto.requiredMethods).map { method in
                var copy = method; copy.isOptionalRequirement = false; return copy
            }
            let optional = methods(proto.optionalMethods).map { method in
                var copy = method; copy.isOptionalRequirement = true; return copy
            }
            entries.append(TypeAtlasEntry(
                id: TypeAtlasEntryID(slot: slot, kind: .objcProtocol, key: .address(proto.address)),
                kind: .objcProtocol, name: proto.name, superclass: nil, members: [],
                conformances: proto.adoptedProtocols, methods: required + optional,
                users: [], evidence: .descriptor, declaredProperties: proto.properties
            ))
        }
        for name in objcClasses.flatMap(\.adoptedProtocols) + objcCategories.flatMap(\.adoptedProtocols) + objcProtocols.flatMap(\.adoptedProtocols)
            where seenProtocols.insert(name).inserted {
            protocolNames.append(name)
        }
        for name in protocolNames.sorted() {
            entries.append(TypeAtlasEntry(
                id: TypeAtlasEntryID(slot: slot, kind: .objcProtocol, key: .name(name)),
                kind: .objcProtocol,
                name: name,
                superclass: nil,
                members: [],
                conformances: [],
                methods: [],
                users: [],
                evidence: .unknown
            ))
        }

        var conformancesByType: [String: [String]] = [:]
        var conformanceMethodsByDescriptor: [UInt64: [TypeAtlasConformanceMethods]] = [:]
        func swiftMethods(_ methods: [SwiftMetadataMethod]) -> [TypeAtlasMethod] {
            methods.map {
                TypeAtlasMethod(name: $0.label, implementation: $0.implementation,
                                isClassMethod: $0.isInstance == false, swiftMetadata: $0)
            }
        }
        for conformance in swiftConformances {
            conformancesByType[conformance.typeName, default: []].append(conformance.protocolName)
            if let descriptor = conformance.typeDescriptorAddress {
                conformanceMethodsByDescriptor[descriptor, default: []].append(TypeAtlasConformanceMethods(
                    protocolName: conformance.protocolName, descriptorAddress: conformance.descriptorAddress,
                    methods: conformance.methods.map(swiftMethods)
                ))
            }
        }
        for type in swiftTypes {
            let kind: TypeAtlasKind
            switch type.kind {
            case .class: kind = .swiftClass
            case .struct: kind = .swiftStruct
            case .enum: kind = .swiftEnum
            case .unknown: continue // an unmodelled descriptor kind has no Atlas row
            }
            entries.append(TypeAtlasEntry(
                id: TypeAtlasEntryID(slot: slot, kind: kind, key: type.descriptorAddress.map { .address($0) } ?? .name(type.name)),
                kind: kind,
                name: type.name,
                superclass: nil,
                // Only metadata-recorded offsets are known.
                members: type.fields.map { field in
                    TypeAtlasMember(name: field.name, type: field.typeName, offset: field.byteOffset,
                                    evidence: field.byteOffset == nil ? .unknown : .descriptor)
                },
                conformances: conformancesByType[type.name] ?? [],
                methods: swiftMethods(type.methods ?? []),
                users: [],
                evidence: .descriptor,
                swiftConformanceMethods: type.descriptorAddress.flatMap { conformanceMethodsByDescriptor[$0] },
                swiftMethodTableResolved: type.kind == .class ? type.methods != nil : nil,
                qualifiedName: type.qualifiedName,
                swiftSuperclass: type.kind == .class ? type.superclass : nil,
                isGeneric: type.isGeneric,
                isPrivateOrLocal: type.isPrivateOrLocal,
                isImportedCType: type.isImportedCType
            ))
        }
        return ImageTypeCatalog(slot: slot, entries: entries)
    }

    /// The user-type part for `slot`: every workspace `TypeDefinition`, with the addresses in
    /// `slot` the user applied it to. Offsets: a DWARF-imported member keeps its recorded
    /// `byteOffset` (descriptor), or stays unknown if absent. Authored fields use C ABI layout
    /// for the members before
    /// and including the first one whose size does not resolve, and unknown after it.
    static func userTypeEntries(
        typeDefinitions: [TypeDefinition],
        addressOverrides: [ImageAddress: AddressOverride],
        slot: ImageSlot
    ) -> [TypeAtlasEntry] {
        guard !typeDefinitions.isEmpty else { return [] }
        var usersByType: [String: [UInt64]] = [:]
        for (key, override) in addressOverrides where key.slot == slot {
            if let name = override.appliedTypeName { usersByType[name, default: []].append(key.address) }
        }
        let catalog = Dictionary(typeDefinitions.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return typeDefinitions.map { definition in
            TypeAtlasEntry(
                id: TypeAtlasEntryID(slot: slot, kind: .userType, key: .name(definition.name)),
                kind: .userType,
                name: definition.name,
                superclass: nil,
                members: userMembers(definition, catalog: catalog),
                conformances: [],
                methods: [],
                users: Array(Set(usersByType[definition.name] ?? [])).sorted(),
                evidence: .authored
            )
        }
    }

    private static func userMembers(_ definition: TypeDefinition, catalog: [String: TypeDefinition]) -> [TypeAtlasMember] {
        switch definition.kind {
        case .enum, .typedef:
            return definition.fields.map {
                TypeAtlasMember(name: $0.name, type: $0.type, offset: nil, evidence: .authored)
            }
        case .struct, .union:
            // A legacy recorded offset also identifies a descriptor layout. Missing siblings
            // must not be filled with ABI guesses when only part of that layout was recovered.
            let descriptorLayout = definition.fields.contains { $0.layoutSource != nil || $0.byteOffset != nil }
            let layout = descriptorLayout ? [] : definition.memberLayout(in: catalog)
            return definition.fields.enumerated().map { index, field in
                if let recorded = field.byteOffset, recorded >= 0 {
                    return TypeAtlasMember(name: field.name, type: field.type, offset: UInt64(recorded), evidence: .descriptor)
                }
                guard !descriptorLayout, layout.count <= definition.fields.count else {
                    return TypeAtlasMember(name: field.name, type: field.type, offset: nil, evidence: .unknown)
                }
                if index < layout.count {
                    let offset = layout[index].offset
                    return TypeAtlasMember(name: field.name, type: field.type,
                                           offset: offset >= 0 ? UInt64(offset) : nil,
                                           evidence: offset >= 0 ? .authored : .unknown)
                }
                let resolves = field.inlineAggregateKind != nil
                    || TypeDefinition.size(ofType: field.type, in: catalog) != nil
                if index == layout.count, !resolves {
                    // The member is declared, but its start is unproven because its alignment is unknown.
                    return TypeAtlasMember(name: field.name, type: field.type, offset: nil, evidence: .authored)
                }
                return TypeAtlasMember(name: field.name, type: field.type, offset: nil, evidence: .unknown)
            }
        }
    }
}

extension WorkspaceSnapshot {
    /// RX-02a: the Type Atlas of the image in `slot` — its ObjC classes, categories and protocols,
    /// its Swift types, and the workspace user types — or an empty catalog for an unknown slot.
    /// The image part is the value stored when the image was analysed; it is projected here only
    /// when that value was invalidated by a later change to its inputs.
    func typeCatalog(in slot: ImageSlot, importedTypes: ImportedTypeLayoutProvider? = nil) -> ImageTypeCatalog {
        guard binary(in: slot) != nil || analysisBySlot[slot] != nil else { return .empty(in: slot) }
        var catalog: ImageTypeCatalog
        if let analysis = analysisBySlot[slot] {
            catalog = (analysis.typeCatalog ?? ImageTypeCatalogBuilder.build(analysis: analysis, slot: slot))
                .restamped(to: slot)
        } else {
            catalog = .empty(in: slot)
        }
        catalog.entries += ImageTypeCatalogBuilder.userTypeEntries(
            typeDefinitions: typeDefinitions, addressOverrides: addressOverrides, slot: slot
        )
        if let importedTypes { catalog = catalog.including(importedTypes: importedTypes) }
        return catalog
    }
}
