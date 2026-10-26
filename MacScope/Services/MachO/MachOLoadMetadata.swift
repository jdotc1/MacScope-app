import Foundation

/// A value type that summarizes high‑level load metadata for a Mach‑O slice.
///
/// `MachOLoadMetadata` surfaces three broad categories of information that the
/// existing `MachOParser` computes then discards at the loader boundary:
///
/// 1. **Code signature** — basic properties of the embedded code directory
///    (team identifier, signing identifier, hash type and flags) along with
///    summary information about the entitlements blob.  If the binary
///    contains XML entitlements the raw plist text is exposed when
///    available; DER entitlements are noted but never decoded.
/// 2. **Imported symbols** — a merged view of imports recovered from the
///    classic symbol table and from dyld chained fixups.  When both sources
///    describe the same symbol, the fixups entry is preferred because it
///    carries an addend.
/// 3. **Dependent dylibs** — the load‑dylib commands reshaped into a
///    stable, value‑type representation.
///
/// Instances of this type are `Sendable` and `Hashable`, and the creation
/// functions are pure: there is no shared mutable state.  They can be
/// safely invoked from concurrent contexts.
struct MachOLoadMetadata: Hashable, Codable, Sendable {
    /// Information extracted from the code signature.
    struct CodeSignatureInfo: Hashable, Codable, Sendable {
        /// The team identifier recorded in the code directory, if present.
        var teamIdentifier: String?
        /// The signing identifier (CFBundle identifier) recorded in the code directory.
        var identifier: String?
        /// A human‑readable name for the hash function used by the code directory.
        var hashTypeName: String?
        /// The raw flags word of the code directory.
        var codeSignatureFlags: UInt32?
        /// The format of the entitlements blob: "XML" or "DER" when known.
        var entitlementsFormat: String?
        /// When the entitlements are XML and were successfully parsed, this holds
        /// the raw plist text.  Nil when the entitlements are DER, absent, or
        /// could not be recovered.
        var entitlementsXML: String?
        /// True when a DER entitlements blob was present.  DER entitlements are
        /// never decoded; this flag simply records their presence.
        var entitlementsDER: Bool
        /// The reported number of top–level entitlement keys, if parsed.
        var entitlementsKeyCount: Int?
        /// The list of top–level entitlement keys (sorted) recovered from the
        /// entitlements plist.  Empty when the entitlements could not be parsed.
        var entitlementsKeys: [String]
        /// Indicates whether the entitlements plist was parsed successfully.
        var entitlementsParsed: Bool

        init(
            teamIdentifier: String? = nil,
            identifier: String? = nil,
            hashTypeName: String? = nil,
            codeSignatureFlags: UInt32? = nil,
            entitlementsFormat: String? = nil,
            entitlementsXML: String? = nil,
            entitlementsDER: Bool = false,
            entitlementsKeyCount: Int? = nil,
            entitlementsKeys: [String] = [],
            entitlementsParsed: Bool = false
        ) {
            self.teamIdentifier = teamIdentifier
            self.identifier = identifier
            self.hashTypeName = hashTypeName
            self.codeSignatureFlags = codeSignatureFlags
            self.entitlementsFormat = entitlementsFormat
            self.entitlementsXML = entitlementsXML
            self.entitlementsDER = entitlementsDER
            self.entitlementsKeyCount = entitlementsKeyCount
            self.entitlementsKeys = entitlementsKeys
            self.entitlementsParsed = entitlementsParsed
        }
    }

    /// One imported symbol resolved from the Mach‑O slice.  Symbols are
    /// deduplicated by symbol name and library identity across the classic import
    /// table and dyld chained fixups. Chained fixups retain their encoded ordinal
    /// when no shared library ordinal exists; chained entries are preferred when
    /// both sources describe the same symbol.
    struct ImportedSymbol: Hashable, Codable, Sendable {
        /// The symbol name.
        var name: String
        /// The library ordinal from which the symbol is imported (1‑based into
        /// the dylib list) or a special ordinal (0xfe for dynamic lookup,
        /// 0xff for the main executable).  Nil when there is no encoded ordinal.
        var libraryOrdinal: Int?
        /// The resolved library name.  For special ordinals this is
        /// "dynamic lookup" or "main executable".  Nil when the ordinal could
        /// not be resolved.
        var libraryName: String?
        /// Whether the import is marked weak.
        var isWeak: Bool
        /// The addend carried by the dyld chained import, if present.
        var addend: Int64?
        /// A string describing the source of this entry (e.g. "dyld fixup" or
        /// "import table").
        var source: String

        init(
            name: String,
            libraryOrdinal: Int?,
            libraryName: String?,
            isWeak: Bool,
            addend: Int64?,
            source: String
        ) {
            self.name = name
            self.libraryOrdinal = libraryOrdinal
            self.libraryName = libraryName
            self.isWeak = isWeak
            self.addend = addend
            self.source = source
        }
    }

    /// One dependent dylib referenced by the Mach‑O slice.  This is a
    /// re‑shaping of `MachODylib` into a stable value type for UI consumption.
    struct DependentDylib: Hashable, Codable, Sendable {
        /// The library path as recorded in the load command.
        var path: String
        /// The load kind: required, weak, reexport, upward or lazy.
        var kind: String
        /// The current version of the dylib as a human readable string.
        var currentVersion: String
        /// The compatibility version of the dylib as a human readable string.
        var compatibilityVersion: String
        /// The ordinal assigned to this dylib (1‑based).
        var ordinal: Int

        init(
            path: String,
            kind: String,
            currentVersion: String,
            compatibilityVersion: String,
            ordinal: Int
        ) {
            self.path = path
            self.kind = kind
            self.currentVersion = currentVersion
            self.compatibilityVersion = compatibilityVersion
            self.ordinal = ordinal
        }
    }

    /// The extracted code signature information, if present.
    var codeSignature: CodeSignatureInfo?
    /// The merged list of imported symbols recovered from the import table and
    /// chained fixups.
    var importedSymbols: [ImportedSymbol]
    /// The list of dependent dylibs as described by the load commands.
    var dependentDylibs: [DependentDylib]

    init(
        codeSignature: CodeSignatureInfo?,
        importedSymbols: [ImportedSymbol],
        dependentDylibs: [DependentDylib]
    ) {
        self.codeSignature = codeSignature
        self.importedSymbols = importedSymbols
        self.dependentDylibs = dependentDylibs
    }

    // MARK: - Projection from a parsed MachOFile

    /// Projects the metadata from an already parsed `MachOFile` into a
    /// `MachOLoadMetadata` instance.  This function does not perform any
    /// additional parsing beyond what `MachOParser` already provides; it
    /// reshapes and merges data for consumption by higher levels.  The raw
    /// entitlements plist is not available through this API; call
    /// ``parse(slice:loadCommands:)`` when you need to extract the actual XML.
    static func from(_ machO: MachOFile) -> MachOLoadMetadata {
        // Extract code signature summary.
        var csInfo: CodeSignatureInfo? = nil
        if let codeSignature = machO.codeSignature, let superBlob = codeSignature.superBlob {
            var info = CodeSignatureInfo()
            if let codeDirectory = superBlob.codeDirectories.first {
                info.teamIdentifier = codeDirectory.teamIdentifier
                info.identifier = codeDirectory.identifier
                info.hashTypeName = codeDirectory.hashTypeName
                info.codeSignatureFlags = codeDirectory.flags
            }
            if let entitlements = superBlob.entitlementSummaries.first {
                info.entitlementsFormat = entitlements.format.rawValue
                info.entitlementsKeyCount = entitlements.keyCount
                info.entitlementsKeys = entitlements.keys
                info.entitlementsParsed = entitlements.isParsed
                if entitlements.format == .der {
                    info.entitlementsDER = true
                }
            }
            csInfo = info
        }

        // Merge imported symbols.
        var importedSymbols: [ImportedSymbol] = []
        // Most imports share the nlist-style library ordinal, so use it to match
        // chained fixups against classic imports. Chained special ordinals that
        // have no nlist-style representation (for example self and weak lookup)
        // retain their exact encoded identity so they cannot collapse together.
        // A control-character separator cannot appear in a symbol name.
        var seenKeys = Set<String>()
        func importKey(name: String, libraryOrdinal: Int?, encodedLibraryOrdinal: Int? = nil) -> String {
            let identity: String
            if let libraryOrdinal {
                identity = "ordinal:\(libraryOrdinal)"
            } else if let encodedLibraryOrdinal {
                identity = "encoded:\(encodedLibraryOrdinal)"
            } else {
                identity = "nil"
            }
            return "\(identity)\u{1}\(name)"
        }
        // Helper to resolve the library name from an ordinal using the same
        // semantics as the parser.  Special ordinals map to descriptive
        // strings and out–of–range values return nil.
        func libraryName(for ordinal: Int?) -> String? {
            guard let ordinal = ordinal else { return nil }
            switch ordinal {
            case MachOConstants.dynamicLookupLibraryOrdinal:
                return "dynamic lookup"
            case MachOConstants.executableLibraryOrdinal:
                return "main executable"
            default:
                // An explicit bounds guard, not `case 1...dylibs.count`: with
                // zero declared dylibs that pattern constructs the invalid
                // range 1...0, which traps on a crafted binary carrying a
                // nonzero ordinal.
                guard ordinal >= 1, ordinal <= machO.dylibs.count else { return nil }
                return machO.dylibs[ordinal - 1].name
            }
        }
        // Preferred imports from dyld chained fixups.
        if let fixups = machO.dyldChainedFixups {
            for imp in fixups.imports {
                let key = importKey(
                    name: imp.name,
                    libraryOrdinal: imp.libraryOrdinal,
                    encodedLibraryOrdinal: imp.encodedLibraryOrdinal
                )
                if !seenKeys.contains(key) {
                    seenKeys.insert(key)
                    // The parser already resolved chained ordinals (incl. sign-extended
                    // specials) against the dylib list; re-deriving from the shared Int model
                    // would alias a real ordinal 254/255 to the nlist specials.
                    let libName = imp.libraryName ?? libraryName(for: imp.libraryOrdinal)
                    let symbol = ImportedSymbol(
                        name: imp.name,
                        libraryOrdinal: imp.libraryOrdinal,
                        libraryName: libName,
                        isWeak: imp.isWeakImport,
                        addend: imp.addend,
                        source: "dyld fixup"
                    )
                    importedSymbols.append(symbol)
                }
            }
        }
        // Fallback imports from the classic import table.
        for imp in machO.imports {
            let key = importKey(name: imp.name, libraryOrdinal: imp.libraryOrdinal)
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                let libName = libraryName(for: imp.libraryOrdinal) ?? imp.libraryName
                let symbol = ImportedSymbol(
                    name: imp.name,
                    libraryOrdinal: imp.libraryOrdinal,
                    libraryName: libName,
                    isWeak: false,
                    addend: nil,
                    source: "import table"
                )
                importedSymbols.append(symbol)
            }
        }

        // Dependent dylibs.
        var dependents: [DependentDylib] = []
        for dylib in machO.dylibs {
            let currentVersion = dylib.currentVersion.stringValue
            let compatibilityVersion = dylib.compatibilityVersion.stringValue
            let entry = DependentDylib(
                path: dylib.name,
                kind: dylib.loadKind,
                currentVersion: currentVersion,
                compatibilityVersion: compatibilityVersion,
                ordinal: dylib.ordinal
            )
            dependents.append(entry)
        }
        return MachOLoadMetadata(codeSignature: csInfo, importedSymbols: importedSymbols, dependentDylibs: dependents)
    }

    // MARK: - Parsing directly from bytes

    /// Parses load metadata directly from a raw Mach‑O slice.  This method
    /// requires the caller to supply the raw slice `Data` and the array of
    /// already parsed load commands.  It returns a best‑effort summary of
    /// the code signature; imported symbols and dylibs are left empty.  The
    /// function never throws for structural oddities in the code signature —
    /// instead it degrades gracefully, populating only what could be recovered.
    static func parse(
        slice: Data,
        loadCommands: [MachOLoadCommand]
    ) -> MachOLoadMetadata {
        var csInfo: CodeSignatureInfo? = nil

        // Find any LC_CODE_SIGNATURE load command and extract its payload.
        for command in loadCommands where command.command == MachOConstants.loadCommandCodeSignature {
            let cmdOffset = Int(command.offset)
            // Each LC_CODE_SIGNATURE is at least 16 bytes: 8‑byte header plus
            // two UInt32 fields (dataOffset and dataSize).  Bounds check before
            // reading.
            guard cmdOffset >= 0, cmdOffset + 16 <= slice.count else { continue }
            // Read the little‑endian dataOffset and dataSize fields.
            let dataOffsetLE = slice.readUInt32LE(at: cmdOffset + 8)
            let dataSizeLE = slice.readUInt32LE(at: cmdOffset + 12)
            guard let dataOffset = dataOffsetLE, let dataSize = dataSizeLE else { continue }
            let start = Int(dataOffset)
            let end = start + Int(dataSize)
            guard start >= 0, end <= slice.count else { continue }
            let csData = slice.subdata(in: start..<end)
            let info = parseCodeSignature(from: csData)
            csInfo = info
            break
        }

        return MachOLoadMetadata(codeSignature: csInfo, importedSymbols: [], dependentDylibs: [])
    }

    // MARK: - Private helpers

    /// Parses a code signature SuperBlob and extracts code signature info.  Only
    /// entitlements information is recovered; the code directory is ignored.
    /// Degrades gracefully on malformed input: returns a `CodeSignatureInfo`
    /// containing only what could be recovered.  The raw entitlements plist
    /// extraction is capped at 256 KiB.
    private static func parseCodeSignature(from data: Data) -> CodeSignatureInfo? {
        let maxPayload: Int = 262_144
        var result = CodeSignatureInfo()
        // The SuperBlob header is 12 bytes: magic, length, blobCount.
        guard data.count >= 12 else { return nil }
        guard let magic = data.readUInt32BE(at: 0), magic == MachOConstants.codeSignatureEmbeddedSignatureMagic || magic == MachOConstants.codeSignatureDetachedSignatureMagic else {
            return nil
        }
        guard let length = data.readUInt32BE(at: 4), Int(length) <= data.count else { return nil }
        guard let blobCount = data.readUInt32BE(at: 8) else { return nil }
        // Ensure the index table fits within the reported length.
        let indexTableSize = Int(blobCount) * 8
        let headerSize = Int(MachOConstants.codeSignatureSuperBlobHeaderSize)
        guard headerSize + indexTableSize <= Int(length) else { return result }
        // Iterate over each blob entry.  We care about XML or DER entitlements.
        for i in 0..<Int(blobCount) {
            let entryOffset = headerSize + i * 8
            guard
                data.readUInt32BE(at: entryOffset) != nil, // blob type — bounds-check only; the blob magic determines kind
                let offset = data.readUInt32BE(at: entryOffset + 4)
            else { continue }
            let blobStart = Int(offset)
            // Each blob has at least an 8‑byte header (magic, length).
            guard blobStart >= 0, blobStart + 8 <= Int(length) else { continue }
            guard let blobMagic = data.readUInt32BE(at: blobStart), let blobLength = data.readUInt32BE(at: blobStart + 4) else { continue }
            // blobLength includes the 8‑byte header.  Ensure it fits within the SuperBlob.
            guard blobLength >= MachOConstants.codeSignatureBlobHeaderSize else { continue }
            let blobEnd = blobStart + Int(blobLength)
            guard blobEnd <= Int(length) else { continue }
            let payloadLength = Int(blobLength) - Int(MachOConstants.codeSignatureBlobHeaderSize)
            let payloadStart = blobStart + Int(MachOConstants.codeSignatureBlobHeaderSize)
            // Only process entitlements blobs.
            if blobMagic == MachOConstants.codeSignatureEmbeddedEntitlementsMagic {
                result.entitlementsFormat = MachOCodeSignatureEntitlementsFormat.xml.rawValue
                result.entitlementsDER = false
                let cappedLength = min(payloadLength, maxPayload)
                guard cappedLength >= 0, payloadStart + cappedLength <= data.count else { continue }
                let payload = data.subdata(in: payloadStart..<(payloadStart + cappedLength))
                // Attempt to decode as UTF‑8 to a string.  If decoding fails the
                // entitlements plist cannot be parsed.
                if let xmlString = String(data: payload, encoding: .utf8) {
                    result.entitlementsXML = xmlString
                    // Attempt to parse keys from the plist.  This may fail on
                    // malformed input, which is allowed.
                    if let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil), let dict = plist as? [String: Any] {
                        let keys = dict.keys.sorted()
                        result.entitlementsKeyCount = dict.count
                        // Hard cap the number of surfaced keys to 256, matching the
                        // parser’s recovery limit.  Exceeding keys are silently
                        // dropped.
                        let maximumKeys = 256
                        result.entitlementsKeys = Array(keys.prefix(maximumKeys))
                        result.entitlementsParsed = true
                    }
                }
            } else if blobMagic == MachOConstants.codeSignatureDerEntitlementsMagic {
                result.entitlementsFormat = MachOCodeSignatureEntitlementsFormat.der.rawValue
                result.entitlementsDER = true
                result.entitlementsParsed = false
            }
        }
        return result
    }
}

// MARK: - Local data reading helpers

fileprivate extension Data {
    /// Reads a 32‑bit unsigned integer in big‑endian from the given offset.
    /// Returns nil on out‑of‑bounds access.
    func readUInt32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        // Index relative to startIndex: a re-sliced Data (startIndex != 0) would otherwise trap on
        // an absolute subscript, an uncatchable process abort.
        let i = startIndex + offset
        let b0 = UInt32(self[i]) << 24
        let b1 = UInt32(self[i + 1]) << 16
        let b2 = UInt32(self[i + 2]) << 8
        let b3 = UInt32(self[i + 3])
        return b0 | b1 | b2 | b3
    }

    /// Reads a 32‑bit unsigned integer in little‑endian from the given offset.
    /// Returns nil on out‑of‑bounds access.
    func readUInt32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let i = startIndex + offset
        let b0 = UInt32(self[i])
        let b1 = UInt32(self[i + 1]) << 8
        let b2 = UInt32(self[i + 2]) << 16
        let b3 = UInt32(self[i + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}
