import Foundation

/// Archive-qualified facts added to an Atlas row. This is a display projection,
/// not a mutable authored definition or a workspace persistence record.
struct ImportedTypeLayoutMetadata: Hashable, Codable, Sendable {
    let identity: ImportedTypeIdentity
    let configurationID: String
    let targetTriple: String
    let sdkIdentity: String
    let compiler: String
    let compilerVersion: String
    let libclangVersion: String
    let language: String
    let extractorVersion: String
    let input: String
    let sourceHeader: String?
    let sourceLine: UInt32?
    let sourceColumn: UInt32?
    let typeKind: String
    let recordKind: String?
    let layoutStatus: String
    let layoutReason: String?
    let alignmentBytes: UInt64?
}

/// Keep bit precision separately from the legacy byte-offset column. A bitfield's
/// declared carrier does not establish an allocation unit, and a flexible array
/// has no known extent even when the enclosing record is complete.
struct ImportedTypeMemberMetadata: Hashable, Codable, Sendable {
    let fieldID: String
    let typeIdentity: ImportedTypeIdentity
    let absoluteBitOffset: UInt64?
    let bitWidth: UInt64?
    let flexibleArray: Bool
    let anonymous: Bool
}

/// Pure, immutable, in-memory projection of already admitted archives. No Clang
/// invocation, digest re-verification, name-based lookup, or Swift C-ABI relayout.
struct ImportedTypeLayoutProvider: Sendable {
    enum ProjectionError: Error, Equatable { case targetMismatch }

    private let projectedEntries: [TypeAtlasEntry]
    private let indexByIdentity: [ImportedTypeIdentity: Int]

    init(archives: [SDKTypeArchive], expectedTarget: String) throws {
        var entries: [TypeAtlasEntry] = []
        var index: [ImportedTypeIdentity: Int] = [:]
        var seenArchives = Set<String>()
        for archive in archives {
            guard archive.document.provenance.targetTriple == expectedTarget else {
                throw ProjectionError.targetMismatch
            }
            guard seenArchives.insert(archive.contentSHA256).inserted else { continue }
            let types = Dictionary(uniqueKeysWithValues: archive.document.types.map { ($0.id, $0) })
            let provenance = archive.document.provenance
            for node in archive.document.types {
                let identity = ImportedTypeIdentity(archiveSHA256: archive.contentSHA256, declarationID: node.id)
                let metadata = ImportedTypeLayoutMetadata(
                    identity: identity,
                    configurationID: archive.document.configurationID,
                    targetTriple: provenance.targetTriple,
                    sdkIdentity: provenance.sdkIdentity,
                    compiler: provenance.compiler,
                    compilerVersion: provenance.compilerVersion,
                    libclangVersion: provenance.libclangVersion,
                    language: provenance.language,
                    extractorVersion: provenance.extractorVersion,
                    input: provenance.input,
                    sourceHeader: node.origin?.header,
                    sourceLine: node.origin?.line,
                    sourceColumn: node.origin?.column,
                    typeKind: node.kind.rawValue,
                    recordKind: node.recordKind?.rawValue,
                    layoutStatus: node.layout.status.rawValue,
                    layoutReason: node.layout.reason,
                    alignmentBytes: node.layout.alignmentBytes
                )
                let members = node.fields.map { field in
                    TypeAtlasMember(
                        name: field.name,
                        type: types[field.typeID]?.spelling,
                        offset: field.bitOffset.map { $0 / 8 },
                        evidence: .compilerImport,
                        size: field.flexibleArray || field.bitWidth != nil ? nil : types[field.typeID]?.layout.sizeBytes,
                        imported: ImportedTypeMemberMetadata(
                            fieldID: field.id,
                            typeIdentity: ImportedTypeIdentity(archiveSHA256: archive.contentSHA256, declarationID: field.typeID),
                            absoluteBitOffset: field.bitOffset,
                            bitWidth: field.bitWidth,
                            flexibleArray: field.flexibleArray,
                            anonymous: field.anonymous
                        )
                    )
                }
                index[identity] = entries.count
                entries.append(TypeAtlasEntry(
                    // The digest has a fixed length; the remainder is the complete local
                    // declaration key. Same-spelled declarations never share this identity.
                    id: TypeAtlasEntryID(slot: .primary, kind: .importedType,
                                         key: .name("\(identity.archiveSHA256):\(identity.declarationID)")),
                    kind: .importedType, name: node.spelling, superclass: nil,
                    members: members, conformances: [], methods: [], users: [],
                    evidence: .compilerImport, instanceSize: node.layout.sizeBytes,
                    imported: metadata
                ))
            }
        }
        projectedEntries = entries
        indexByIdentity = index
    }

    func entries(in slot: ImageSlot) -> [TypeAtlasEntry] {
        projectedEntries.map { entry in
            var copy = entry
            copy.id.slot = slot
            return copy
        }
    }

    func entry(for identity: ImportedTypeIdentity, in slot: ImageSlot = .primary) -> TypeAtlasEntry? {
        guard let index = indexByIdentity[identity] else { return nil }
        var entry = projectedEntries[index]
        entry.id.slot = slot
        return entry
    }
}
