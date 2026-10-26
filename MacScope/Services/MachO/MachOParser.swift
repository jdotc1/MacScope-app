import Foundation

enum MachOParserError: LocalizedError {
    case truncated(String)
    case unsupportedMagic(UInt32)
    case missingARM64Slice
    case invalidUniversalBinary(String)
    case invalidLoadCommand(index: Int, reason: String)
    case invalidSection(String, reason: String)

    var errorDescription: String? {
        switch self {
        case .truncated(let context):
            "The Mach-O file is truncated while reading \(context)."
        case .unsupportedMagic(let magic):
            String(format: "Unsupported Mach-O magic 0x%08x.", magic)
        case .missingARM64Slice:
            "The universal binary does not contain an arm64 Mach-O slice."
        case .invalidUniversalBinary(let reason):
            "The universal binary is invalid: \(reason)."
        case .invalidLoadCommand(let index, let reason):
            "Load command \(index) is invalid: \(reason)."
        case .invalidSection(let name, let reason):
            "Section \(name) is invalid: \(reason)."
        }
    }
}

struct MachOParser: Sendable {
    func parse(
        _ data: Data,
        options: MachOParseOptions = .default,
        objcCache: MachOObjCCacheContext? = nil
    ) throws -> MachOFile {
        let magic = try data.readUInt32BE(at: 0, context: "magic")

        switch magic {
        case MachOConstants.fatMagic:
            let selection = try selectedFatSlice(in: data, is64Bit: false, requestedSliceIndex: options.requestedSliceIndex)
            return try parseThin(
                data[selection.slice.range],
                sliceOffset: selection.slice.offset,
                universalBinary: selection.universalBinary,
                options: options,
                objcCache: objcCache
            )
        case MachOConstants.fatMagic64:
            let selection = try selectedFatSlice(in: data, is64Bit: true, requestedSliceIndex: options.requestedSliceIndex)
            return try parseThin(
                data[selection.slice.range],
                sliceOffset: selection.slice.offset,
                universalBinary: selection.universalBinary,
                options: options,
                objcCache: objcCache
            )
        default:
            return try parseThin(data, sliceOffset: 0, universalBinary: nil, options: options, objcCache: objcCache)
        }
    }

    private func parseThin(
        _ data: Data,
        sliceOffset: UInt64,
        universalBinary: MachOUniversalBinary?,
        options: MachOParseOptions,
        objcCache: MachOObjCCacheContext? = nil
    ) throws -> MachOFile {
        let magic = try data.readUInt32LE(at: 0, context: "Mach-O magic")
        guard magic == MachOConstants.machMagic64 else {
            throw MachOParserError.unsupportedMagic(magic)
        }

        let header = MachOHeader(
            magic: magic,
            cpuType: try data.readInt32LE(at: 4, context: "CPU type"),
            cpuSubtype: try data.readInt32LE(at: 8, context: "CPU subtype"),
            fileType: try data.readUInt32LE(at: 12, context: "file type"),
            loadCommandCount: try data.readUInt32LE(at: 16, context: "load command count"),
            loadCommandsSize: try data.readUInt32LE(at: 20, context: "load command size"),
            flags: try data.readUInt32LE(at: 24, context: "flags"),
            reserved: try data.readUInt32LE(at: 28, context: "reserved")
        )

        var loadCommands: [MachOLoadCommand] = []
        var segments: [MachOSegment] = []
        var sections: [MachOSection] = []
        var dylibs: [MachODylib] = []
        var rpaths: [MachORPath] = []
        var loaderFacts = MachOLoaderFacts(declaredPlatforms: [], installNames: [], dyldEnvironment: [])
        var symtabCommand: MachOSymtabCommand?
        var dysymtabCommand: MachODysymtabCommand?
        var dyldInfoCommand: MachODyldInfoCommand?
        var uuid: MachOUUID?
        var buildVersion: MachOBuildVersion?
        var buildVersions: [MachOBuildVersion] = []
        var sourceVersion: MachOSourceVersion?
        var legacyMinimumOSVersion: MachOMinimumOSVersion?
        var legacyMinimumOSVersions: [MachOMinimumOSVersion] = []
        var codeSignature: MachOCodeSignature?
        var dyldChainedFixups: MachODyldChainedFixups?
        var encryptionInfos: [MachOEncryptionInfo] = []
        var functionStartsCommand: MachOLinkeditDataCommand?
        var dataInCodeCommand: MachOLinkeditDataCommand?
        var exportsTrieCommand: MachOLinkeditDataCommand?
        var entryPointOffset: UInt64?
        var entryPointVirtualAddress: UInt64?

        var cursor = 32
        for index in 0..<Int(header.loadCommandCount) {
            guard cursor + 8 <= data.count else {
                throw MachOParserError.truncated("load command \(index)")
            }

            let command = try data.readUInt32LE(at: cursor, context: "load command")
            let commandSize = try data.readUInt32LE(at: cursor + 4, context: "load command size")
            guard commandSize >= 8 else {
                throw MachOParserError.invalidLoadCommand(index: index, reason: "command size is smaller than 8 bytes")
            }
            guard cursor + Int(commandSize) <= data.count else {
                throw MachOParserError.invalidLoadCommand(index: index, reason: "command extends beyond file size")
            }

            loadCommands.append(MachOLoadCommand(command: command, commandSize: commandSize, offset: UInt64(cursor)))

            switch command {
            case MachOConstants.loadCommandSymtab:
                symtabCommand = try parseSymtabCommand(in: data, at: cursor, commandSize: commandSize, index: index)
            case MachOConstants.loadCommandDysymtab:
                dysymtabCommand = try parseDysymtabCommand(in: data, at: cursor, commandSize: commandSize, index: index)
            case MachOConstants.loadCommandSegment64:
                let parsedSegment = try parseSegment64(in: data, at: cursor, commandSize: commandSize, index: index)
                segments.append(parsedSegment.segment)
                sections.append(contentsOf: parsedSegment.sections)
                // F3: aggregate section budget across ALL segments (the per-segment cap is in
                // parseSegment64) — bounds the total model size a crafted file can drive.
                guard sections.count <= MachORecoveryLimits.maximumSections else {
                    throw MachOParserError.invalidLoadCommand(index: index, reason: "aggregate section count exceeds the bounded parser limit")
                }
            case MachOConstants.loadCommandUUID:
                uuid = try parseUUIDCommand(in: data, at: cursor, commandSize: commandSize, index: index)
            case MachOConstants.loadCommandDyldInfo, MachOConstants.loadCommandDyldInfoOnly:
                dyldInfoCommand = try parseDyldInfoCommand(in: data, at: cursor, commandSize: commandSize, index: index)
            case MachOConstants.loadCommandBuildVersion:
                buildVersion = try parseBuildVersionCommand(in: data, at: cursor, commandSize: commandSize, index: index)
                if let buildVersion { buildVersions.append(buildVersion) }
                if let buildVersion { loaderFacts.declaredPlatforms.append(buildVersion.platform) }
            case MachOConstants.loadCommandSourceVersion:
                sourceVersion = try parseSourceVersionCommand(in: data, at: cursor, commandSize: commandSize, index: index)
            case MachOConstants.loadCommandVersionMinMacOSX,
                MachOConstants.loadCommandVersionMinIPhoneOS,
                MachOConstants.loadCommandVersionMinTVOS,
                MachOConstants.loadCommandVersionMinWatchOS:
                legacyMinimumOSVersion = try parseMinimumOSVersionCommand(
                    in: data,
                    at: cursor,
                    command: command,
                    commandSize: commandSize,
                    index: index
                )
                if let legacyMinimumOSVersion { legacyMinimumOSVersions.append(legacyMinimumOSVersion) }
                let platform: UInt32 = switch command {
                case MachOConstants.loadCommandVersionMinMacOSX: 1
                case MachOConstants.loadCommandVersionMinIPhoneOS: 2
                case MachOConstants.loadCommandVersionMinTVOS: 3
                default: 4
                }
                loaderFacts.declaredPlatforms.append(platform)
            case 0x0d: // LC_ID_DYLIB
                loaderFacts.installNames.append(try parseDylibCommand(in: data, at: cursor, command: command, commandSize: commandSize, index: index, ordinal: 0).name)
            case 0x27: // LC_DYLD_ENVIRONMENT (same lc_str layout as LC_RPATH)
                loaderFacts.dyldEnvironment.append(try parseRPathCommand(in: data, at: cursor, commandSize: commandSize, index: index).path)
            case MachOConstants.loadCommandLoadDylib,
                MachOConstants.loadCommandLoadWeakDylib,
                MachOConstants.loadCommandReexportDylib,
                MachOConstants.loadCommandLoadUpwardDylib,
                MachOConstants.loadCommandLazyLoadDylib:
                dylibs.append(try parseDylibCommand(
                    in: data,
                    at: cursor,
                    command: command,
                    commandSize: commandSize,
                    index: index,
                    ordinal: dylibs.count + 1
                ))
            case MachOConstants.loadCommandRPath:
                rpaths.append(try parseRPathCommand(in: data, at: cursor, commandSize: commandSize, index: index))
            case MachOConstants.loadCommandCodeSignature:
                if options.parseCodeSignature {
                    codeSignature = try parseCodeSignatureCommand(in: data, at: cursor, commandSize: commandSize, index: index)
                }
            case MachOConstants.loadCommandEncryptionInfo,
                 MachOConstants.loadCommandEncryptionInfo64:
                encryptionInfos.append(try parseEncryptionInfoCommand(
                    in: data,
                    at: cursor,
                    command: command,
                    commandSize: commandSize,
                    index: index
                ))
            case MachOConstants.loadCommandDyldChainedFixups:
                // Header-only here: the full imports + chain walk needs the complete
                // segment + dylib tables, so it runs after the load-command loop below.
                dyldChainedFixups = try parseDyldChainedFixupsCommand(
                    in: data,
                    at: cursor,
                    commandSize: commandSize,
                    index: index
                )
            case MachOConstants.loadCommandFunctionStarts:
                functionStartsCommand = try parseLinkeditDataCommand(
                    in: data,
                    at: cursor,
                    commandSize: commandSize,
                    index: index,
                    name: "LC_FUNCTION_STARTS"
                )
            case MachOConstants.loadCommandDataInCode:
                dataInCodeCommand = try parseLinkeditDataCommand(
                    in: data,
                    at: cursor,
                    commandSize: commandSize,
                    index: index,
                    name: "LC_DATA_IN_CODE"
                )
            case MachOConstants.loadCommandDyldExportsTrie:
                // Modern linkers emit LC_DYLD_EXPORTS_TRIE (a linkedit_data_command whose payload is
                // the export trie) in place of LC_DYLD_INFO. Captured here; the trie is parsed with
                // the rest of the symbol/export recovery below.
                exportsTrieCommand = try parseLinkeditDataCommand(
                    in: data,
                    at: cursor,
                    commandSize: commandSize,
                    index: index,
                    name: "LC_DYLD_EXPORTS_TRIE"
                )
            case MachOConstants.loadCommandMain:
                guard commandSize >= 24 else {
                    throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_MAIN is smaller than 24 bytes")
                }
                entryPointOffset = try data.readUInt64LE(at: cursor + 8, context: "LC_MAIN entryoff")
            case MachOConstants.loadCommandUnixThread, MachOConstants.loadCommandThread:
                // Only the FIRST thread command seeds the entry PC (mirrors LC_MAIN
                // winning once); a later one does not overwrite it.
                if entryPointVirtualAddress == nil {
                    entryPointVirtualAddress = try parseThreadEntryPoint(
                        in: data,
                        at: cursor,
                        commandSize: commandSize,
                        cpuType: header.cpuType,
                        index: index
                    )
                }
            default:
                break
            }

            cursor += Int(commandSize)
        }

        // Now that the segment + dylib tables are complete, walk the chained-fixups
        // imports table and per-page chains to resolve bind + rebase targets. The walk
        // is best-effort and self-contained: any malformed substructure degrades to an
        // empty result for that part rather than failing the whole parse.
        if let header = dyldChainedFixups {
            dyldChainedFixups = resolveDyldChainedFixups(
                in: data,
                header: header,
                segments: segments,
                dylibs: dylibs
            )
        }

        let symbolInformation = try parseSymbolInformation(
            in: data,
            symtab: symtabCommand,
            dysymtab: dysymtabCommand,
            dylibs: dylibs,
            dyldInfo: dyldInfoCommand,
            exportsTrie: exportsTrieCommand,
            imageBase: Self.preferredImageBase(segments: segments)
        )
        let indirectSymbols = try parseIndirectSymbols(
            in: data,
            dysymtab: dysymtabCommand,
            sections: sections,
            symbols: symbolInformation.symbols
        )
        let relocations = try parseRelocations(
            in: data,
            sections: sections,
            symbols: symbolInformation.symbols
        )
        let stringLiterals = options.recoverStringLiterals
            ? try parseCStringLiterals(in: data, sections: sections)
            : []
        var objectiveCMetadata = options.recoverObjectiveCMetadata
            ? try parseObjectiveCMetadata(
                in: data,
                sections: sections,
                symbols: symbolInformation.symbols,
                chainedFixups: dyldChainedFixups?.fixups ?? [],
                objcCache: objcCache
            )
            : .empty
        if options.recoverObjectiveCMetadata, objcCache == nil {
            objectiveCMetadata.diagnostics = Self.objectiveCSharedCacheExtractionDiagnostics(
                metadata: objectiveCMetadata,
                segments: segments
            )
        }
        let swiftMetadataSections = options.recoverSwiftMetadata
            ? parseSwiftMetadataSections(in: sections)
            : []
        let swiftMetadata = options.recoverSwiftMetadata
            ? parseSwiftTypes(
                in: data,
                sections: sections,
                chainedFixups: dyldChainedFixups?.fixups ?? [],
                classicFixups: dyldChainedFixups == nil ? dyldInfoCommand.map {
                    MachODyldInfoFixups.decode(
                        data: data,
                        streams: .init(
                            rebase: Int($0.rebaseOffset)..<(Int($0.rebaseOffset) + Int($0.rebaseSize)),
                            bind: Int($0.bindOffset)..<(Int($0.bindOffset) + Int($0.bindSize))
                        ),
                        segments: segments
                    )
                } : nil,
                symbols: symbolInformation.symbols
            )
            : (types: [SwiftTypeDescriptor](), conformances: [SwiftConformance](), protocols: [SwiftProtocolDescriptor](),
               diagnostics: [MetadataParseDiagnostic]())
        let exceptionMetadata = try parseExceptionMetadata(
            in: data,
            sections: sections,
            loadCommands: loadCommands,
            functionStartsCommand: functionStartsCommand
        )
        let functionStarts = try functionStartsCommand.map {
            try parseFunctionStarts(in: data, command: $0, segments: segments)
        } ?? []
        let dataInCodeEntries = try dataInCodeCommand.map {
            try parseDataInCodeEntries(in: data, command: $0, segments: segments)
        } ?? []

        // HS-12: LC_FUNCTION_STARTS vs __unwind_info cross-check. Evidence only (findings);
        // `functionStarts` above is returned unchanged.
        let functionStartsDiagnostics = MachOUnwindFunctionStarts.findings(
            in: data,
            sections: sections,
            segments: segments,
            functionStarts: functionStarts,
            hasFunctionStartsCommand: functionStartsCommand != nil
        )

        var machOFile = MachOFile(
            header: header,
            loadCommands: loadCommands,
            segments: segments,
            sections: sections,
            dylibs: dylibs,
            rpaths: rpaths,
            symbols: symbolInformation.symbols,
            imports: symbolInformation.imports,
            indirectSymbols: indirectSymbols,
            relocations: relocations,
            exports: symbolInformation.exports,
            exportRecoveryComplete: symbolInformation.complete,
            stringLiterals: stringLiterals,
            objectiveCMetadata: objectiveCMetadata,
            swiftMetadataSections: swiftMetadataSections,
            swiftTypes: swiftMetadata.types,
            swiftConformances: swiftMetadata.conformances,
            swiftProtocols: swiftMetadata.protocols,
            exceptionMetadata: exceptionMetadata,
            functionStarts: functionStarts,
            dataInCodeEntries: dataInCodeEntries,
            uuid: uuid,
            buildVersion: buildVersion,
            buildVersions: buildVersions,
            sourceVersion: sourceVersion,
            legacyMinimumOSVersion: legacyMinimumOSVersion,
            legacyMinimumOSVersions: legacyMinimumOSVersions,
            codeSignature: codeSignature,
            dyldChainedFixups: dyldChainedFixups,
            encryptionInfos: encryptionInfos,
            entryPointOffset: entryPointOffset,
            entryPointVirtualAddress: entryPointVirtualAddress,
            selectedSliceOffset: sliceOffset,
            universalBinary: universalBinary,
            loaderFacts: loaderFacts
        )
        machOFile.functionStartsDiagnostics = functionStartsDiagnostics
        machOFile.swiftMetadataDiagnostics = swiftMetadata.diagnostics
        machOFile.metadataParseFindings = MachOLoaderFinding.metadataParseFindings(
            swift: swiftMetadata.diagnostics,
            objectiveC: objectiveCMetadata.parseDiagnostics, objectiveCDropped: objectiveCMetadata.parseDiagnosticsDropped)
        return machOFile
    }

    /// Recovers the initial program counter (entry virtual address) from an
    /// LC_UNIXTHREAD / LC_THREAD command. The command body is a sequence of
    /// (flavor: u32, count: u32, state[count]: u32) tuples; we walk them, find the
    /// architecture's general thread-state flavor for the binary's cputype, and read
    /// the PC/RIP register out of the state block. Every read is bounds-checked against
    /// `commandSize`, so a truncated or bogus thread command degrades to `nil` (or a
    /// thrown truncation) instead of trapping. Returns `nil` if no matching flavor /
    /// PC word is present.
    private func parseThreadEntryPoint(
        in data: Data,
        at offset: Int,
        commandSize: UInt32,
        cpuType: Int32,
        index: Int
    ) throws -> UInt64? {
        // flavor (u32) + count (u32) must fit after the 8-byte load-command header.
        guard commandSize >= 16 else {
            throw MachOParserError.invalidLoadCommand(
                index: index,
                reason: "thread command is smaller than 16 bytes"
            )
        }

        let (wantedFlavor, pcWordIndex): (UInt32, Int)
        switch cpuType {
        case MachOConstants.cpuTypeARM64:
            (wantedFlavor, pcWordIndex) = (MachOConstants.armThreadState64Flavor, MachOConstants.armThreadState64PCWordIndex)
        case MachOConstants.cpuTypeX86_64:
            (wantedFlavor, pcWordIndex) = (MachOConstants.x86ThreadState64Flavor, MachOConstants.x86ThreadState64RIPWordIndex)
        default:
            return nil
        }

        let commandEnd = offset + Int(commandSize)
        var stateCursor = offset + 8
        // Cap the tuple walk so a malformed body can't spin: the smallest tuple is the
        // 8-byte (flavor,count) header, so commandSize/8 bounds the iteration count.
        let maximumTuples = Int(commandSize) / 8 + 1
        var iterations = 0

        while stateCursor + 8 <= commandEnd, iterations < maximumTuples {
            iterations += 1
            let flavor = try data.readUInt32LE(at: stateCursor, context: "thread state flavor")
            let wordCount = try data.readUInt32LE(at: stateCursor + 4, context: "thread state count")
            let stateStart = stateCursor + 8
            // count is a u32 word-count; bound it before turning it into a byte length.
            guard wordCount <= (commandSize / 4) else {
                throw MachOParserError.invalidLoadCommand(
                    index: index,
                    reason: "thread state word count exceeds the command size"
                )
            }
            let stateByteLength = Int(wordCount) * 4
            let nextCursor = stateStart + stateByteLength
            guard nextCursor <= commandEnd else {
                throw MachOParserError.invalidLoadCommand(
                    index: index,
                    reason: "thread state block extends beyond the command"
                )
            }

            if flavor == wantedFlavor {
                // PC is a u64 at word index `pcWordIndex` (two u32 words per register).
                let pcByteOffset = stateStart + pcWordIndex * 4
                guard Int(wordCount) >= pcWordIndex + 2, pcByteOffset + 8 <= commandEnd else {
                    return nil
                }
                return try data.readUInt64LE(at: pcByteOffset, context: "thread state PC")
            }

            stateCursor = nextCursor
        }

        return nil
    }

    private func parseSegment64(
        in data: Data,
        at offset: Int,
        commandSize: UInt32,
        index: Int
    ) throws -> (segment: MachOSegment, sections: [MachOSection]) {
        guard commandSize >= 72 else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_SEGMENT_64 is smaller than 72 bytes")
        }

        let sectionCount = try data.readUInt32LE(at: offset + 64, context: "segment section count")
        // F3: reject an absurd per-segment section count BEFORE allocating the section array.
        guard sectionCount <= UInt32(MachORecoveryLimits.maximumSections) else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_SEGMENT_64 section count exceeds the bounded parser limit")
        }
        let expectedSize = 72 + Int(sectionCount) * 80
        guard Int(commandSize) >= expectedSize else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_SEGMENT_64 does not contain all section records")
        }

        let segment = MachOSegment(
            name: data.fixedCString(at: offset + 8, length: 16),
            vmAddress: try data.readUInt64LE(at: offset + 24, context: "segment vmaddr"),
            vmSize: try data.readUInt64LE(at: offset + 32, context: "segment vmsize"),
            fileOffset: try data.readUInt64LE(at: offset + 40, context: "segment fileoff"),
            fileSize: try data.readUInt64LE(at: offset + 48, context: "segment filesize"),
            maxProtection: try data.readInt32LE(at: offset + 56, context: "segment maxprot"),
            initialProtection: try data.readInt32LE(at: offset + 60, context: "segment initprot"),
            sectionCount: sectionCount,
            flags: try data.readUInt32LE(at: offset + 68, context: "segment flags")
        )

        var sections: [MachOSection] = []
        var sectionOffset = offset + 72
        for _ in 0..<sectionCount {
            sections.append(MachOSection(
                sectionName: data.fixedCString(at: sectionOffset, length: 16),
                segmentName: data.fixedCString(at: sectionOffset + 16, length: 16),
                address: try data.readUInt64LE(at: sectionOffset + 32, context: "section addr"),
                size: try data.readUInt64LE(at: sectionOffset + 40, context: "section size"),
                fileOffset: try data.readUInt32LE(at: sectionOffset + 48, context: "section offset"),
                alignment: try data.readUInt32LE(at: sectionOffset + 52, context: "section align"),
                relocationOffset: try data.readUInt32LE(at: sectionOffset + 56, context: "section reloff"),
                relocationCount: try data.readUInt32LE(at: sectionOffset + 60, context: "section nreloc"),
                flags: try data.readUInt32LE(at: sectionOffset + 64, context: "section flags"),
                reserved1: try data.readUInt32LE(at: sectionOffset + 68, context: "section reserved1"),
                reserved2: try data.readUInt32LE(at: sectionOffset + 72, context: "section reserved2"),
                reserved3: try data.readUInt32LE(at: sectionOffset + 76, context: "section reserved3")
            ))
            sectionOffset += 80
        }

        return (segment, sections)
    }

    private func parseUUIDCommand(
        in data: Data,
        at offset: Int,
        commandSize: UInt32,
        index: Int
    ) throws -> MachOUUID {
        guard commandSize >= 24 else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_UUID is smaller than 24 bytes")
        }

        let bytes = try (0..<16).map { byteIndex in
            try data.readUInt8(at: offset + 8 + byteIndex, context: "LC_UUID uuid")
        }
        return MachOUUID(bytes: bytes)
    }

    private func parseBuildVersionCommand(
        in data: Data,
        at offset: Int,
        commandSize: UInt32,
        index: Int
    ) throws -> MachOBuildVersion {
        guard commandSize >= 24 else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_BUILD_VERSION is smaller than 24 bytes")
        }

        let toolCount = try data.readUInt32LE(at: offset + 20, context: "LC_BUILD_VERSION ntools")
        let expectedSize = 24 + Int(toolCount) * 8
        guard Int(commandSize) >= expectedSize else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_BUILD_VERSION does not contain all tool records")
        }

        var tools: [MachOBuildToolVersion] = []
        var toolOffset = offset + 24
        for _ in 0..<toolCount {
            tools.append(MachOBuildToolVersion(
                tool: try data.readUInt32LE(at: toolOffset, context: "LC_BUILD_VERSION tool"),
                version: MachOVersion(
                    encodedValue: try data.readUInt32LE(at: toolOffset + 4, context: "LC_BUILD_VERSION tool version")
                )
            ))
            toolOffset += 8
        }

        return MachOBuildVersion(
            platform: try data.readUInt32LE(at: offset + 8, context: "LC_BUILD_VERSION platform"),
            minimumOSVersion: MachOVersion(
                encodedValue: try data.readUInt32LE(at: offset + 12, context: "LC_BUILD_VERSION minos")
            ),
            sdkVersion: MachOVersion(
                encodedValue: try data.readUInt32LE(at: offset + 16, context: "LC_BUILD_VERSION sdk")
            ),
            tools: tools
        )
    }

    private func parseMinimumOSVersionCommand(
        in data: Data,
        at offset: Int,
        command: UInt32,
        commandSize: UInt32,
        index: Int
    ) throws -> MachOMinimumOSVersion {
        guard commandSize >= 16 else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_VERSION_MIN command is smaller than 16 bytes")
        }

        return MachOMinimumOSVersion(
            command: command,
            minimumOSVersion: MachOVersion(
                encodedValue: try data.readUInt32LE(at: offset + 8, context: "LC_VERSION_MIN version")
            ),
            sdkVersion: MachOVersion(
                encodedValue: try data.readUInt32LE(at: offset + 12, context: "LC_VERSION_MIN sdk")
            )
        )
    }

    private func parseSourceVersionCommand(
        in data: Data,
        at offset: Int,
        commandSize: UInt32,
        index: Int
    ) throws -> MachOSourceVersion {
        guard commandSize >= 16 else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_SOURCE_VERSION is smaller than 16 bytes")
        }

        return MachOSourceVersion(
            encodedValue: try data.readUInt64LE(at: offset + 8, context: "LC_SOURCE_VERSION version")
        )
    }

    private func parseSymtabCommand(
        in data: Data,
        at offset: Int,
        commandSize: UInt32,
        index: Int
    ) throws -> MachOSymtabCommand {
        guard commandSize >= 24 else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_SYMTAB is smaller than 24 bytes")
        }

        return MachOSymtabCommand(
            index: index,
            symbolOffset: try data.readUInt32LE(at: offset + 8, context: "LC_SYMTAB symoff"),
            symbolCount: try data.readUInt32LE(at: offset + 12, context: "LC_SYMTAB nsyms"),
            stringOffset: try data.readUInt32LE(at: offset + 16, context: "LC_SYMTAB stroff"),
            stringSize: try data.readUInt32LE(at: offset + 20, context: "LC_SYMTAB strsize")
        )
    }

    private func parseDysymtabCommand(
        in data: Data,
        at offset: Int,
        commandSize: UInt32,
        index: Int
    ) throws -> MachODysymtabCommand {
        guard commandSize >= 80 else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_DYSYMTAB is smaller than 80 bytes")
        }

        return MachODysymtabCommand(
            index: index,
            localSymbolIndex: try data.readUInt32LE(at: offset + 8, context: "LC_DYSYMTAB ilocalsym"),
            localSymbolCount: try data.readUInt32LE(at: offset + 12, context: "LC_DYSYMTAB nlocalsym"),
            externalDefinedSymbolIndex: try data.readUInt32LE(at: offset + 16, context: "LC_DYSYMTAB iextdefsym"),
            externalDefinedSymbolCount: try data.readUInt32LE(at: offset + 20, context: "LC_DYSYMTAB nextdefsym"),
            undefinedSymbolIndex: try data.readUInt32LE(at: offset + 24, context: "LC_DYSYMTAB iundefsym"),
            undefinedSymbolCount: try data.readUInt32LE(at: offset + 28, context: "LC_DYSYMTAB nundefsym"),
            indirectSymbolOffset: try data.readUInt32LE(at: offset + 56, context: "LC_DYSYMTAB indirectsymoff"),
            indirectSymbolCount: try data.readUInt32LE(at: offset + 60, context: "LC_DYSYMTAB nindirectsyms")
        )
    }

    private func parseDyldInfoCommand(
        in data: Data,
        at offset: Int,
        commandSize: UInt32,
        index: Int
    ) throws -> MachODyldInfoCommand {
        guard commandSize >= 48 else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_DYLD_INFO is smaller than 48 bytes")
        }

        return MachODyldInfoCommand(
            index: index,
            rebaseOffset: try data.readUInt32LE(at: offset + 8, context: "LC_DYLD_INFO rebase_off"),
            rebaseSize: try data.readUInt32LE(at: offset + 12, context: "LC_DYLD_INFO rebase_size"),
            bindOffset: try data.readUInt32LE(at: offset + 16, context: "LC_DYLD_INFO bind_off"),
            bindSize: try data.readUInt32LE(at: offset + 20, context: "LC_DYLD_INFO bind_size"),
            exportOffset: try data.readUInt32LE(at: offset + 40, context: "LC_DYLD_INFO export_off"),
            exportSize: try data.readUInt32LE(at: offset + 44, context: "LC_DYLD_INFO export_size")
        )
    }

    private func parseEncryptionInfoCommand(
        in data: Data,
        at offset: Int,
        command: UInt32,
        commandSize: UInt32,
        index: Int
    ) throws -> MachOEncryptionInfo {
        let minimumSize: UInt32 = command == MachOConstants.loadCommandEncryptionInfo64 ? 24 : 20
        guard commandSize >= minimumSize else {
            let name = command == MachOConstants.loadCommandEncryptionInfo64
                ? "LC_ENCRYPTION_INFO_64"
                : "LC_ENCRYPTION_INFO"
            throw MachOParserError.invalidLoadCommand(
                index: index,
                reason: "\(name) is smaller than \(minimumSize) bytes"
            )
        }
        return MachOEncryptionInfo(
            command: command,
            cryptOffset: try data.readUInt32LE(at: offset + 8, context: "encryption cryptoff"),
            cryptSize: try data.readUInt32LE(at: offset + 12, context: "encryption cryptsize"),
            cryptID: try data.readUInt32LE(at: offset + 16, context: "encryption cryptid")
        )
    }

    private func parseDylibCommand(
        in data: Data,
        at offset: Int,
        command: UInt32,
        commandSize: UInt32,
        index: Int,
        ordinal: Int
    ) throws -> MachODylib {
        guard commandSize >= 24 else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "dylib load command is smaller than 24 bytes")
        }

        let nameOffset = try data.readUInt32LE(at: offset + 8, context: "dylib name offset")
        guard nameOffset >= 24, nameOffset < commandSize else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "dylib name offset points outside the load command string area")
        }

        let marker = try data.readUInt32LE(at: offset + 12, context: "dylib timestamp/marker")
        let alternate = (command == MachOConstants.loadCommandLoadDylib || command == MachOConstants.loadCommandLoadWeakDylib) && marker == 0x1a741800
        if alternate && (commandSize < 28 || nameOffset != 28) {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "invalid dylib_use_command layout")
        }
        let flags: UInt32? = alternate ? try data.readUInt32LE(at: offset + 24, context: "dylib use flags") : nil
        let nameStart = offset + Int(nameOffset)
        let nameLength = Int(commandSize - nameOffset)
        let name = data.fixedCString(at: nameStart, length: nameLength)
        return MachODylib(
            name: name,
            ordinal: ordinal,
            command: command,
            pathKind: MachORuntimePathKind(path: name),
            timestamp: try data.readUInt32LE(at: offset + 12, context: "dylib timestamp"),
            currentVersion: MachODylibVersion(
                encodedValue: try data.readUInt32LE(at: offset + 16, context: "dylib current version")
            ),
            compatibilityVersion: MachODylibVersion(
                encodedValue: try data.readUInt32LE(at: offset + 20, context: "dylib compatibility version")
            ),
            useFlags: flags
        )
    }

    private func parseRPathCommand(
        in data: Data,
        at offset: Int,
        commandSize: UInt32,
        index: Int
    ) throws -> MachORPath {
        guard commandSize >= 12 else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_RPATH is smaller than 12 bytes")
        }

        let pathOffset = try data.readUInt32LE(at: offset + 8, context: "LC_RPATH path offset")
        guard pathOffset >= 12, pathOffset < commandSize else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "LC_RPATH path offset points outside the load command")
        }

        let pathStart = offset + Int(pathOffset)
        let pathLength = Int(commandSize - pathOffset)
        let path = data.fixedCString(at: pathStart, length: pathLength)
        return MachORPath(
            path: path,
            command: MachOConstants.loadCommandRPath,
            pathKind: MachORuntimePathKind(path: path)
        )
    }

    private func parseCodeSignatureCommand(
        in data: Data,
        at offset: Int,
        commandSize: UInt32,
        index: Int
    ) throws -> MachOCodeSignature {
        let command = try parseLinkeditDataCommand(
            in: data,
            at: offset,
            commandSize: commandSize,
            index: index,
            name: "LC_CODE_SIGNATURE"
        )
        let superBlob = try parseCodeSignatureSuperBlob(in: data, command: command)
        return MachOCodeSignature(
            dataOffset: command.dataOffset,
            dataSize: command.dataSize,
            superBlob: superBlob
        )
    }

    private func parseCodeSignatureSuperBlob(
        in data: Data,
        command: MachOLinkeditDataCommand
    ) throws -> MachOCodeSignatureSuperBlob? {
        guard command.dataSize >= MachOConstants.codeSignatureSuperBlobHeaderSize else {
            return nil
        }

        let payloadOffset = Int(command.dataOffset)
        let magic = try data.readUInt32BE(at: payloadOffset, context: "CS_SuperBlob magic")
        guard magic == MachOConstants.codeSignatureEmbeddedSignatureMagic
            || magic == MachOConstants.codeSignatureDetachedSignatureMagic
        else {
            return nil
        }

        let length = try data.readUInt32BE(at: payloadOffset + 4, context: "CS_SuperBlob length")
        let blobCount = try data.readUInt32BE(at: payloadOffset + 8, context: "CS_SuperBlob count")
        guard length >= MachOConstants.codeSignatureSuperBlobHeaderSize else {
            throw MachOParserError.invalidLoadCommand(
                index: command.index,
                reason: "LC_CODE_SIGNATURE SuperBlob length is smaller than the header"
            )
        }
        guard length <= command.dataSize else {
            throw MachOParserError.invalidLoadCommand(
                index: command.index,
                reason: "LC_CODE_SIGNATURE SuperBlob length exceeds the command data size"
            )
        }
        guard blobCount <= MachORecoveryLimits.maximumCodeSignatureBlobs else {
            throw MachOParserError.invalidLoadCommand(
                index: command.index,
                reason: "LC_CODE_SIGNATURE SuperBlob index count exceeds the bounded parser limit"
            )
        }

        let indexTableSize = UInt64(MachOConstants.codeSignatureSuperBlobHeaderSize)
            + UInt64(blobCount) * 8
        guard indexTableSize <= UInt64(length) else {
            throw MachOParserError.invalidLoadCommand(
                index: command.index,
                reason: "LC_CODE_SIGNATURE SuperBlob index table exceeds the declared length"
            )
        }

        var blobs: [MachOCodeSignatureBlob] = []
        var indexOffset = payloadOffset + Int(MachOConstants.codeSignatureSuperBlobHeaderSize)
        for _ in 0..<Int(blobCount) {
            let type = try data.readUInt32BE(at: indexOffset, context: "CS_BlobIndex type")
            let relativeOffset = try data.readUInt32BE(at: indexOffset + 4, context: "CS_BlobIndex offset")
            guard UInt64(relativeOffset) >= indexTableSize else {
                throw MachOParserError.invalidLoadCommand(
                    index: command.index,
                    reason: "LC_CODE_SIGNATURE blob offset overlaps the SuperBlob index table"
                )
            }
            guard UInt64(relativeOffset) + UInt64(MachOConstants.codeSignatureBlobHeaderSize) <= UInt64(length) else {
                throw MachOParserError.invalidLoadCommand(
                    index: command.index,
                    reason: "LC_CODE_SIGNATURE blob offset points outside the SuperBlob"
                )
            }

            let blobOffset = payloadOffset + Int(relativeOffset)
            let blobMagic = try data.readUInt32BE(at: blobOffset, context: "CS_GenericBlob magic")
            let blobLength = try data.readUInt32BE(at: blobOffset + 4, context: "CS_GenericBlob length")
            guard blobLength >= MachOConstants.codeSignatureBlobHeaderSize else {
                throw MachOParserError.invalidLoadCommand(
                    index: command.index,
                    reason: "LC_CODE_SIGNATURE blob length is smaller than the blob header"
                )
            }
            guard UInt64(relativeOffset) + UInt64(blobLength) <= UInt64(length) else {
                throw MachOParserError.invalidLoadCommand(
                    index: command.index,
                    reason: "LC_CODE_SIGNATURE blob length extends outside the SuperBlob"
                )
            }
            let codeDirectory = try parseCodeDirectorySummary(
                in: data,
                blobOffset: blobOffset,
                blobLength: blobLength,
                commandIndex: command.index
            )
            let entitlements = parseCodeSignatureEntitlementsSummary(
                in: data,
                blobOffset: blobOffset,
                blobLength: blobLength,
                blobMagic: blobMagic
            )

            blobs.append(MachOCodeSignatureBlob(
                type: type,
                relativeOffset: relativeOffset,
                fileOffset: UInt64(command.dataOffset) + UInt64(relativeOffset),
                magic: blobMagic,
                length: blobLength,
                codeDirectory: codeDirectory,
                entitlements: entitlements
            ))
            indexOffset += 8
        }

        return MachOCodeSignatureSuperBlob(
            magic: magic,
            length: length,
            blobCount: blobCount,
            blobs: blobs
        )
    }

    private func parseCodeDirectorySummary(
        in data: Data,
        blobOffset: Int,
        blobLength: UInt32,
        commandIndex: Int
    ) throws -> MachOCodeDirectorySummary? {
        let magic = try data.readUInt32BE(at: blobOffset, context: "CS_CodeDirectory magic")
        guard magic == MachOConstants.codeSignatureCodeDirectoryMagic else {
            return nil
        }
        guard blobLength >= MachOConstants.codeSignatureCodeDirectoryHeaderSize else {
            throw MachOParserError.invalidLoadCommand(
                index: commandIndex,
                reason: "LC_CODE_SIGNATURE CodeDirectory is smaller than the bounded header parser"
            )
        }

        let version = try data.readUInt32BE(at: blobOffset + 8, context: "CS_CodeDirectory version")
        let flags = try data.readUInt32BE(at: blobOffset + 12, context: "CS_CodeDirectory flags")
        let hashOffset = try data.readUInt32BE(at: blobOffset + 16, context: "CS_CodeDirectory hashOffset")
        let identifierOffset = try data.readUInt32BE(at: blobOffset + 20, context: "CS_CodeDirectory identOffset")
        let specialSlotCount = try data.readUInt32BE(at: blobOffset + 24, context: "CS_CodeDirectory nSpecialSlots")
        let codeSlotCount = try data.readUInt32BE(at: blobOffset + 28, context: "CS_CodeDirectory nCodeSlots")
        let codeLimit = try data.readUInt32BE(at: blobOffset + 32, context: "CS_CodeDirectory codeLimit")
        let hashSize = try data.readUInt8(at: blobOffset + 36, context: "CS_CodeDirectory hashSize")
        let hashType = try data.readUInt8(at: blobOffset + 37, context: "CS_CodeDirectory hashType")
        let platform = try data.readUInt8(at: blobOffset + 38, context: "CS_CodeDirectory platform")
        let pageSize = try data.readUInt8(at: blobOffset + 39, context: "CS_CodeDirectory pageSize")

        guard hashOffset <= blobLength else {
            throw MachOParserError.invalidLoadCommand(
                index: commandIndex,
                reason: "LC_CODE_SIGNATURE CodeDirectory hash offset points outside the blob"
            )
        }

        let identifier = try codeSignatureCString(
            in: data,
            blobOffset: blobOffset,
            blobLength: blobLength,
            relativeOffset: identifierOffset,
            commandIndex: commandIndex,
            label: "identifier"
        )
        let teamOffset: UInt32? = if
            version >= MachOConstants.codeSignatureCodeDirectoryTeamOffsetVersion,
            UInt64(MachOConstants.codeSignatureCodeDirectoryHeaderSize) + 8 <= UInt64(blobLength)
        {
            try data.readUInt32BE(at: blobOffset + 48, context: "CS_CodeDirectory teamOffset")
        } else {
            nil
        }
        let teamIdentifier = try teamOffset.flatMap {
            try codeSignatureCString(
                in: data,
                blobOffset: blobOffset,
                blobLength: blobLength,
                relativeOffset: $0,
                commandIndex: commandIndex,
                label: "team identifier"
            )
        }

        return MachOCodeDirectorySummary(
            version: version,
            flags: flags,
            hashOffset: hashOffset,
            identifierOffset: identifierOffset,
            specialSlotCount: specialSlotCount,
            codeSlotCount: codeSlotCount,
            codeLimit: codeLimit,
            hashSize: hashSize,
            hashType: hashType,
            platform: platform,
            pageSize: pageSize,
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
    }

    private func codeSignatureCString(
        in data: Data,
        blobOffset: Int,
        blobLength: UInt32,
        relativeOffset: UInt32,
        commandIndex: Int,
        label: String
    ) throws -> String? {
        guard relativeOffset > 0 else { return nil }
        guard relativeOffset < blobLength else {
            throw MachOParserError.invalidLoadCommand(
                index: commandIndex,
                reason: "LC_CODE_SIGNATURE CodeDirectory \(label) offset points outside the blob"
            )
        }

        let stringOffset = blobOffset + Int(relativeOffset)
        let limit = blobOffset + Int(blobLength)
        guard let string = data.nullTerminatedString(at: stringOffset, limit: limit) else {
            throw MachOParserError.invalidLoadCommand(
                index: commandIndex,
                reason: "LC_CODE_SIGNATURE CodeDirectory \(label) string is unterminated"
            )
        }
        guard string.value.utf8.count <= MachORecoveryLimits.maximumCodeSignatureStringLength else {
            throw MachOParserError.invalidLoadCommand(
                index: commandIndex,
                reason: "LC_CODE_SIGNATURE CodeDirectory \(label) string exceeds the bounded parser limit"
            )
        }
        return string.value.isEmpty ? nil : string.value
    }

    private func parseCodeSignatureEntitlementsSummary(
        in data: Data,
        blobOffset: Int,
        blobLength: UInt32,
        blobMagic: UInt32
    ) -> MachOCodeSignatureEntitlementsSummary? {
        switch blobMagic {
        case MachOConstants.codeSignatureEmbeddedEntitlementsMagic:
            return parseXMLEntitlementsSummary(in: data, blobOffset: blobOffset, blobLength: blobLength)
        case MachOConstants.codeSignatureDerEntitlementsMagic:
            return MachOCodeSignatureEntitlementsSummary(
                format: .der,
                keyCount: nil,
                keys: [],
                isParsed: false
            )
        default:
            return nil
        }
    }

    private func parseXMLEntitlementsSummary(
        in data: Data,
        blobOffset: Int,
        blobLength: UInt32
    ) -> MachOCodeSignatureEntitlementsSummary {
        let payloadLength = Int(blobLength - MachOConstants.codeSignatureBlobHeaderSize)
        guard payloadLength <= MachORecoveryLimits.maximumEntitlementsPayloadBytes else {
            return MachOCodeSignatureEntitlementsSummary(format: .xml, keyCount: nil, keys: [], isParsed: false)
        }

        let payloadOffset = blobOffset + Int(MachOConstants.codeSignatureBlobHeaderSize)
        let payload = data[payloadOffset..<(payloadOffset + payloadLength)]
        guard
            let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil),
            let dictionary = plist as? [String: Any]
        else {
            return MachOCodeSignatureEntitlementsSummary(format: .xml, keyCount: nil, keys: [], isParsed: false)
        }

        let keys = Array(dictionary.keys.sorted().prefix(MachORecoveryLimits.maximumEntitlementKeys))
        return MachOCodeSignatureEntitlementsSummary(
            format: .xml,
            keyCount: dictionary.count,
            keys: keys,
            isParsed: true
        )
    }

    private func parseDyldChainedFixupsCommand(
        in data: Data,
        at offset: Int,
        commandSize: UInt32,
        index: Int
    ) throws -> MachODyldChainedFixups {
        let command = try parseLinkeditDataCommand(
            in: data,
            at: offset,
            commandSize: commandSize,
            index: index,
            name: "LC_DYLD_CHAINED_FIXUPS"
        )
        guard command.dataSize >= MachOConstants.dyldChainedFixupsHeaderSize else {
            throw MachOParserError.invalidLoadCommand(
                index: index,
                reason: "LC_DYLD_CHAINED_FIXUPS payload is smaller than dyld_chained_fixups_header"
            )
        }

        let payloadOffset = Int(command.dataOffset)
        let fixupsVersion = try data.readUInt32LE(at: payloadOffset, context: "dyld_chained_fixups_header fixups_version")
        let startsOffset = try data.readUInt32LE(at: payloadOffset + 4, context: "dyld_chained_fixups_header starts_offset")
        let importsOffset = try data.readUInt32LE(at: payloadOffset + 8, context: "dyld_chained_fixups_header imports_offset")
        let symbolsOffset = try data.readUInt32LE(at: payloadOffset + 12, context: "dyld_chained_fixups_header symbols_offset")
        let importsCount = try data.readUInt32LE(at: payloadOffset + 16, context: "dyld_chained_fixups_header imports_count")
        let importsFormat = try data.readUInt32LE(at: payloadOffset + 20, context: "dyld_chained_fixups_header imports_format")
        let symbolsFormat = try data.readUInt32LE(at: payloadOffset + 24, context: "dyld_chained_fixups_header symbols_format")

        // imports/symbols offsets are structural (needed to resolve bind targets), so an
        // out-of-range value is a hard error. starts_offset only drives the best-effort
        // chain WALK, which is independently range-checked and degrades to an empty walk
        // (`walkChainedFixups` uses `try?`), so a bad starts_offset must NOT abort the load.
        for (label, relativeOffset) in [
            ("imports_offset", importsOffset),
            ("symbols_offset", symbolsOffset)
        ] where relativeOffset > command.dataSize {
            throw MachOParserError.invalidLoadCommand(
                index: index,
                reason: "LC_DYLD_CHAINED_FIXUPS \(label) points outside the payload"
            )
        }

        return MachODyldChainedFixups(
            dataOffset: command.dataOffset,
            dataSize: command.dataSize,
            fixupsVersion: fixupsVersion,
            startsOffset: startsOffset,
            importsOffset: importsOffset,
            symbolsOffset: symbolsOffset,
            importsCount: importsCount,
            importsFormat: importsFormat,
            symbolsFormat: symbolsFormat
        )
    }

    // MARK: - dyld chained-fixups walk (bind + rebase resolution)

    /// Resolves the imports table and walks the per-page chains of an
    /// LC_DYLD_CHAINED_FIXUPS payload, returning the header enriched with the recovered
    /// imports + bind/rebase fixups. This parses untrusted bytes, so it is defensive:
    /// every offset/count is range-validated, the page/chain walk is bounded, there is
    /// no UInt64->Int trap, and unknown pointer formats are skipped — any malformed
    /// substructure degrades to an empty result for that part instead of throwing.
    private func resolveDyldChainedFixups(
        in data: Data,
        header: MachODyldChainedFixups,
        segments: [MachOSegment],
        dylibs: [MachODylib]
    ) -> MachODyldChainedFixups {
        var resolved = header

        // Map the payload window once; every sub-offset is validated against it.
        guard
            let payloadStart = intOffset(header.dataOffset),
            let payloadSize = intOffset(header.dataSize),
            payloadStart >= 0,
            payloadSize >= 0,
            payloadStart <= data.count,
            payloadSize <= data.count - payloadStart
        else {
            return resolved
        }
        let payloadEnd = payloadStart + payloadSize
        var log = MachOLoaderFindingLog()
        let imageBase = Self.preferredImageBase(segments: segments)

        // dyld refuses any fixups_version other than 0; so does MacScope, explicitly.
        guard header.fixupsVersion == 0 else {
            log.record(MachOLoaderFinding(
                kind: .chainedFixupsUnknownVersion,
                address: imageBase,
                value: UInt64(header.fixupsVersion),
                message: "Unsupported chained fixups version \(header.fixupsVersion); "
                    + "no rebases or binds were applied for this image."
            ))
            resolved.diagnostics = log.findings
            return resolved
        }

        let decodedImports = decodeChainedImports(
            in: data,
            header: header,
            payloadStart: payloadStart,
            payloadEnd: payloadEnd,
            dylibs: dylibs,
            anchor: imageBase,
            log: &log
        )
        resolved.imports = decodedImports.imports

        resolved.fixups = walkChainedFixups(
            in: data,
            header: header,
            payloadStart: payloadStart,
            payloadEnd: payloadEnd,
            segments: segments,
            imports: decodedImports.imports,
            importsRefused: decodedImports.refused,
            log: &log
        )
        resolved.diagnostics = log.findings
        return resolved
    }

    /// Decodes the imports table (`dyld_chained_import` / `_addend` / `_addend64`),
    /// resolving each entry's name out of the symbol pool and its library ordinal to a
    /// dylib name. Returns empty for an out-of-range table. An unknown imports_format or a
    /// non-zero symbols_format (1 = zlib-compressed names, which dyld itself rejects) is a typed
    /// refusal: no imports are produced rather than names decoded from compressed bytes.
    private func decodeChainedImports(
        in data: Data,
        header: MachODyldChainedFixups,
        payloadStart: Int,
        payloadEnd: Int,
        dylibs: [MachODylib],
        anchor: UInt64,
        log: inout MachOLoaderFindingLog
    ) -> (imports: [MachOChainedImport], refused: Bool) {
        let entrySize: Int
        switch header.importsFormat {
        case MachOConstants.dyldChainedImport: entrySize = 4
        case MachOConstants.dyldChainedImportAddend: entrySize = 8
        case MachOConstants.dyldChainedImportAddend64: entrySize = 16
        default:
            log.record(MachOLoaderFinding(
                kind: .chainedFixupsUnhandledImportFormat,
                address: anchor,
                value: UInt64(header.importsFormat),
                message: "Unhandled chained import format \(header.importsFormat); "
                    + "\(header.importsCount) imports were not decoded and binds stay unresolved."
            ))
            return ([], true)
        }
        switch header.symbolsFormat {
        case MachOConstants.dyldChainedSymbolsUncompressed:
            break
        case MachOConstants.dyldChainedSymbolsZlibCompressed:
            log.record(MachOLoaderFinding(
                kind: .chainedFixupsCompressedImportNames,
                address: anchor,
                value: UInt64(header.symbolsFormat),
                message: "Unsupported feature: zlib-compressed import names (dyld_chained_fixups_header "
                    + "symbols_format 1). ld64 never emits it and dyld rejects it, so MacScope does not decode "
                    + "it either; \(header.importsCount) imports were not decoded and binds stay unresolved."
            ))
            return ([], true)
        default:
            log.record(MachOLoaderFinding(
                kind: .chainedFixupsUnknownSymbolsFormat,
                address: anchor,
                value: UInt64(header.symbolsFormat),
                message: "Unknown chained fixups symbols format \(header.symbolsFormat); "
                    + "\(header.importsCount) imports were not decoded and binds stay unresolved."
            ))
            return ([], true)
        }

        guard
            let importsRel = intOffset(header.importsOffset),
            let symbolsRel = intOffset(header.symbolsOffset),
            let count = intOffset(header.importsCount),
            count >= 0,
            count <= MachOConstants.dyldChainedMaxFixups
        else {
            return ([], false)
        }
        let importsStart = payloadStart + importsRel
        let symbolsStart = payloadStart + symbolsRel
        guard
            importsStart >= payloadStart,
            symbolsStart >= payloadStart,
            symbolsStart <= payloadEnd,
            importsStart <= payloadEnd
        else {
            return ([], false)
        }
        // Whole imports table must fit inside the payload.
        let (tableBytes, tableOverflow) = count.multipliedReportingOverflow(by: entrySize)
        guard !tableOverflow, tableBytes <= payloadEnd - importsStart else {
            return ([], false)
        }

        var result: [MachOChainedImport] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let entryOffset = importsStart + i * entrySize
            // dyld sign-extends lib_ordinal values above 0xF0 (8-bit) / 0xFFF0 (16-bit) into
            // the negative BIND_SPECIAL_DYLIB_* ordinals.
            let libOrdinal: Int
            let isWeak: Bool
            let nameOffset: Int
            var addend: Int64 = 0

            switch header.importsFormat {
            case MachOConstants.dyldChainedImport:
                guard let raw = try? data.readUInt32LE(at: entryOffset, context: "dyld_chained_import") else { return (result, false) }
                libOrdinal = Self.signExtendedChainedLibraryOrdinal8(UInt8(truncatingIfNeeded: raw))
                isWeak = (raw & 0x100) != 0
                nameOffset = Int((raw >> 9) & 0x7f_ffff)
            case MachOConstants.dyldChainedImportAddend:
                guard let raw = try? data.readUInt32LE(at: entryOffset, context: "dyld_chained_import_addend"),
                      let addendRaw = try? data.readInt32LE(at: entryOffset + 4, context: "dyld_chained_import_addend addend")
                else { return (result, false) }
                libOrdinal = Self.signExtendedChainedLibraryOrdinal8(UInt8(truncatingIfNeeded: raw))
                isWeak = (raw & 0x100) != 0
                nameOffset = Int((raw >> 9) & 0x7f_ffff)
                addend = Int64(addendRaw)
            default: // dyldChainedImportAddend64
                guard let raw = try? data.readUInt64LE(at: entryOffset, context: "dyld_chained_import_addend64"),
                      let addendRaw = try? data.readUInt64LE(at: entryOffset + 8, context: "dyld_chained_import_addend64 addend")
                else { return (result, false) }
                let reserved = (raw >> 17) & 0x7fff
                guard reserved == 0 else {
                    log.record(MachOLoaderFinding(
                        kind: .chainedFixupsImportReservedBits,
                        address: anchor,
                        value: reserved,
                        message: "Chained import addend64 has nonzero reserved bits; "
                            + "imports were not decoded and binds stay unresolved."
                    ))
                    return ([], true)
                }
                let raw16 = UInt16(truncatingIfNeeded: raw)
                libOrdinal = raw16 > 0xfff0 ? Int(Int16(bitPattern: raw16)) : Int(raw16)
                isWeak = ((raw >> 16) & 0x1) != 0
                nameOffset = Int((raw >> 32) & 0xffff_ffff)
                addend = Int64(bitPattern: addendRaw)
            }

            let (ordinal, resolvedLibraryName) = Self.resolveChainedLibraryOrdinal(libOrdinal, dylibs: dylibs)
            let nameStart = symbolsStart + nameOffset
            guard nameStart >= symbolsStart, nameStart < payloadEnd else {
                log.record(MachOLoaderFinding(
                    kind: .chainedFixupsImportNameOutOfRange,
                    address: anchor,
                    value: UInt64(nameOffset),
                    message: "Chained import name offset is outside the symbol pool; "
                        + "imports were not decoded and binds stay unresolved."
                ))
                return ([], true)
            }
            guard let name = data.nullTerminatedString(at: nameStart, limit: payloadEnd)?.value else {
                log.record(MachOLoaderFinding(
                    kind: .chainedFixupsImportNameUnterminated,
                    address: anchor,
                    value: UInt64(nameOffset),
                    message: "Chained import name is not NUL-terminated inside the symbol pool; "
                        + "imports were not decoded and binds stay unresolved."
                ))
                return ([], true)
            }
            result.append(MachOChainedImport(
                index: i,
                name: name,
                libraryOrdinal: ordinal,
                libraryName: resolvedLibraryName,
                isWeakImport: isWeak,
                addend: addend,
                encodedLibraryOrdinal: libOrdinal
            ))
        }
        return (result, false)
    }

    private static func signExtendedChainedLibraryOrdinal8(_ raw: UInt8) -> Int {
        raw > 0xf0 ? Int(Int8(bitPattern: raw)) : Int(raw)
    }

    /// Maps a sign-extended chained-import ordinal onto the shared ordinal model. Special
    /// ordinals become their explicit encodings (0xff main executable, 0xfe flat lookup) or,
    /// where the model has none (self, weak lookup), a nil ordinal with an explicit name.
    /// Unknown negative specials and positive ordinals beyond the declared dylibs abstain
    /// (nil, nil) instead of aliasing a dylib or a nlist special value.
    private static func resolveChainedLibraryOrdinal(
        _ encoded: Int,
        dylibs: [MachODylib]
    ) -> (ordinal: Int?, name: String?) {
        if let special = MachOChainedSpecialLibraryOrdinal(rawValue: encoded) {
            switch special {
            case .mainExecutable: return (MachOConstants.executableLibraryOrdinal, special.displayName)
            case .flatLookup: return (MachOConstants.dynamicLookupLibraryOrdinal, special.displayName)
            case .selfImage, .weakLookup: return (nil, special.displayName)
            }
        }
        guard encoded >= 1, encoded <= dylibs.count else { return (nil, nil) }
        return (encoded, dylibs[encoded - 1].name)
    }

    /// The addend encoded inline in a chained BIND pointer (fixup-chains.h):
    /// `dyld_chained_ptr_64_bind.addend` is an unsigned 8-bit field at bit 24; the plain
    /// arm64e `bind` / `bind24` carry a signed 19-bit addend at bit 32 (sign-extended as
    /// dyld's `signExtendedAddend`); authenticated binds carry none.
    private static func chainedBindInlineAddend(raw: UInt64, pointerFormat: UInt16) -> Int64 {
        switch pointerFormat {
        case MachOConstants.dyldChainedPtr64, MachOConstants.dyldChainedPtr64Offset:
            return Int64((raw >> 24) & 0xff)
        case MachOConstants.dyldChainedPtrArm64e,
            MachOConstants.dyldChainedPtrArm64eUserland,
            MachOConstants.dyldChainedPtrArm64eUserland24:
            guard (raw >> 63) & 0x1 == 0 else { return 0 }
            let addend19 = (raw >> 32) & 0x7_ffff
            return addend19 & 0x4_0000 != 0
                ? Int64(bitPattern: addend19 | 0xffff_ffff_fff8_0000)
                : Int64(addend19)
        default:
            return 0
        }
    }

    /// Walks `dyld_chained_starts_in_image -> per-segment starts -> per-page chains`,
    /// decoding each entry's pointer format and following the `next` stride until 0,
    /// classifying every entry as a REBASE (in-image target VA) or a BIND (import
    /// ordinal -> resolved symbol). Bounded against cyclic/overlong chains. Every case the
    /// walker does not handle (pointer format, START_MULTI page, rebase shape, stride/delta
    /// inconsistency, out-of-range ordinal) is recorded in `log` instead of being misread.
    private func walkChainedFixups(
        in data: Data,
        header: MachODyldChainedFixups,
        payloadStart: Int,
        payloadEnd: Int,
        segments: [MachOSegment],
        imports: [MachOChainedImport],
        importsRefused: Bool,
        log: inout MachOLoaderFindingLog
    ) -> [MachOChainedFixup] {
        guard let startsRel = intOffset(header.startsOffset) else { return [] }
        let startsImageStart = payloadStart + startsRel
        guard startsImageStart >= payloadStart, startsImageStart + 4 <= payloadEnd else { return [] }
        guard let segCount = try? data.readUInt32LE(at: startsImageStart, context: "dyld_chained_starts_in_image seg_count") else { return [] }
        guard let segCountInt = intOffset(segCount), segCountInt >= 0, segCountInt <= segments.count + 1 else { return [] }
        // The seg_info_offset[] array must fit.
        guard segCountInt <= (payloadEnd - startsImageStart - 4) / 4 else { return [] }

        // Offset formats use the preferred image base; zero is valid for dylibs.
        let imageBase = Self.preferredImageBase(segments: segments)

        var fixups: [MachOChainedFixup] = []
        for segIndex in 0..<segCountInt {
            guard fixups.count < MachOConstants.dyldChainedMaxFixups else { break }
            guard let segInfoRel = try? data.readUInt32LE(at: startsImageStart + 4 + segIndex * 4, context: "seg_info_offset") else { continue }
            if segInfoRel == 0 { continue } // segment has no fixups
            guard let segInfoRelInt = intOffset(segInfoRel) else { continue }
            let segInfoStart = startsImageStart + segInfoRelInt
            guard segInfoStart >= payloadStart, segInfoStart + 24 <= payloadEnd else { continue }
            // Map to the actual segment so we can compute VAs (index aligns 1:1 with
            // the LC_SEGMENT order in a well-formed image).
            let segment = segIndex < segments.count ? segments[segIndex] : nil
            walkSegmentStarts(
                in: data,
                segInfoStart: segInfoStart,
                payloadEnd: payloadEnd,
                segment: segment,
                segmentIndex: segIndex,
                imageBase: imageBase,
                imports: imports,
                importsRefused: importsRefused,
                into: &fixups,
                log: &log
            )
        }
        return fixups
    }

    /// Parses one `dyld_chained_starts_in_segment` and walks each page's chain.
    private func walkSegmentStarts(
        in data: Data,
        segInfoStart: Int,
        payloadEnd: Int,
        segment: MachOSegment?,
        segmentIndex: Int,
        imageBase: UInt64,
        imports: [MachOChainedImport],
        importsRefused: Bool,
        into fixups: inout [MachOChainedFixup],
        log: inout MachOLoaderFindingLog
    ) {
        guard
            let size = try? data.readUInt32LE(at: segInfoStart, context: "starts_in_segment size"),
            let pageSize = try? data.readUInt16LE(at: segInfoStart + 4, context: "starts_in_segment page_size"),
            let pointerFormat = try? data.readUInt16LE(at: segInfoStart + 6, context: "starts_in_segment pointer_format"),
            let segmentOffset = try? data.readUInt64LE(at: segInfoStart + 8, context: "starts_in_segment segment_offset"),
            // max_valid_pointer is at +16 (u32); page_count at +20 (u16); page_start[] at +22.
            let pageCount = try? data.readUInt16LE(at: segInfoStart + 20, context: "starts_in_segment page_count")
        else { return }

        guard pageSize > 0 else { return }
        let segmentAnchor = segment?.vmAddress ?? imageBase
        let segmentScope = UInt64(segmentIndex)
        guard supportedPointerFormat(pointerFormat) else {
            log.record(MachOLoaderFinding(
                kind: .chainedFixupsUnhandledPointerFormat,
                address: segmentAnchor,
                value: UInt64(pointerFormat),
                message: "Unhandled chained pointer format \(pointerFormat) "
                    + "(\(MachOLoaderFinding.chainedPointerFormatName(pointerFormat))) in segment "
                    + "\(segment?.name ?? "#\(segmentIndex)"); its fixups were not applied."
            ), scope: segmentScope)
            return
        }
        let stride = pointerStride(for: pointerFormat)

        let pageStartArrayOffset = segInfoStart + 22
        let pageCountInt = Int(pageCount)
        guard pageStartArrayOffset + pageCountInt * 2 <= payloadEnd else { return }

        // The chain must stay inside the segment's file bytes when the segment resolved.
        let segmentFileEnd: UInt64? = segment.map { $0.fileOffset &+ $0.fileSize }

        func walkPageChain(pageStart: UInt16, page: Int, pageAnchor: UInt64) {
            guard pageStart < pageSize else {
                log.record(MachOLoaderFinding(
                    kind: .chainedFixupsChainDeltaMismatch,
                    address: pageAnchor,
                    value: UInt64(pageStart),
                    message: "Chained fixup page start \(pageStart) is beyond the page size \(pageSize) "
                        + "(segment \(segment?.name ?? "#\(segmentIndex)"), page \(page)); the chain was not walked."
                ), scope: segmentScope)
                return
            }

            // The chain entry's file offset is the segment's file base plus the in-segment page
            // offset (page index * page size + page_start). `segment_offset` from the starts
            // table is the segment's own offset and already equals the LC_SEGMENT file offset on
            // a real image, so adding both double-counts it — fatal, as the chain then lands past
            // the segment and the walk yields nothing. Use the LC_SEGMENT file offset when the
            // segment resolved; fall back to segment_offset only when it did not.
            guard let segFileOffset = intOffset(segment?.fileOffset ?? 0) else { return }
            let segmentFileBase: UInt64 = segment != nil ? UInt64(segFileOffset) : segmentOffset
            let (pageProduct, pageOverflow) = UInt64(page).multipliedReportingOverflow(by: UInt64(pageSize))
            guard !pageOverflow else { return }
            let (inPageOffset, pageStartOverflow) = pageProduct.addingReportingOverflow(UInt64(pageStart))
            guard !pageStartOverflow else { return }
            let (chainFileOffset64, baseOverflow) = segmentFileBase.addingReportingOverflow(inPageOffset)
            guard !baseOverflow, let chainFileOffset = intOffset(chainFileOffset64) else { return }
            // A chain never leaves its page: the next page has its own page_start.
            let (pageFileEnd64, pageEndOverflow) = segmentFileBase.addingReportingOverflow(pageProduct &+ UInt64(pageSize))
            let pageLimit = pageEndOverflow ? UInt64.max : pageFileEnd64
            let entryStartLimit = intOffset(min(pageLimit, segmentFileEnd ?? pageLimit)) ?? Int.max

            walkChain(
                in: data,
                chainFileOffset: chainFileOffset,
                entryStartLimit: entryStartLimit,
                entryEndLimit: segmentFileEnd.flatMap { intOffset($0) } ?? data.count,
                segmentFileOffset: segFileOffset,
                segment: segment,
                segmentIndex: segmentIndex,
                pointerFormat: pointerFormat,
                stride: stride,
                payloadDataCount: data.count,
                imageBase: imageBase,
                imports: imports,
                importsRefused: importsRefused,
                into: &fixups,
                log: &log
            )
        }

        for page in 0..<pageCountInt {
            guard fixups.count < MachOConstants.dyldChainedMaxFixups else { return }
            guard let pageStart = try? data.readUInt16LE(at: pageStartArrayOffset + page * 2, context: "page_start") else { return }
            if pageStart == MachOConstants.dyldChainedPtrStartNone { continue }
            let pageAnchor = segmentAnchor &+ UInt64(page) &* UInt64(pageSize)
            var chainStarts = [pageStart]
            if pageStart & MachOConstants.dyldChainedPtrStartMulti != 0 {
                // DYLD_CHAINED_PTR_START_MULTI (HS-4b): the low bits index page_start[] itself,
                // where a list of in-page chain starts follows the page_count entries; the last
                // start carries DYLD_CHAINED_PTR_START_LAST (dyld's walk). The list must stay
                // inside this starts_in_segment (its `size`) and terminate; otherwise the page is
                // refused with the finding naming the malformed list rather than misread.
                let segmentInfoEnd = min(payloadEnd, segInfoStart &+ Int(size))
                guard let starts = Self.chainedStartMultiList(
                    in: data,
                    pageStartArrayOffset: pageStartArrayOffset,
                    overflowIndex: Int(pageStart & ~MachOConstants.dyldChainedPtrStartMulti),
                    pageCount: pageCountInt,
                    segmentInfoEnd: segmentInfoEnd
                ) else {
                    log.record(MachOLoaderFinding(
                        kind: .chainedFixupsStartMultiUnhandled,
                        address: pageAnchor,
                        value: UInt64(pageStart),
                        message: "Malformed DYLD_CHAINED_PTR_START_MULTI start list (index "
                            + "\(pageStart & ~MachOConstants.dyldChainedPtrStartMulti) outside the overflow "
                            + "starts or not terminated by DYLD_CHAINED_PTR_START_LAST) in segment "
                            + "\(segment?.name ?? "#\(segmentIndex)"), page \(page); that page's fixups were not applied."
                    ), scope: segmentScope)
                    continue
                }
                chainStarts = starts
            }
            for chainStart in chainStarts {
                guard fixups.count < MachOConstants.dyldChainedMaxFixups else { return }
                walkPageChain(pageStart: chainStart, page: page, pageAnchor: pageAnchor)
            }
        }
    }

    /// HS-4b: the in-page chain starts of one DYLD_CHAINED_PTR_START_MULTI page, read from
    /// page_start[overflowIndex...] until an entry carries DYLD_CHAINED_PTR_START_LAST (0x8000),
    /// with that flag cleared. nil when the index points into the per-page entries, the list
    /// leaves the starts_in_segment, or it never terminates.
    static func chainedStartMultiList(
        in data: Data,
        pageStartArrayOffset: Int,
        overflowIndex: Int,
        pageCount: Int,
        segmentInfoEnd: Int
    ) -> [UInt16]? {
        guard overflowIndex >= pageCount else { return nil }
        var starts: [UInt16] = []
        var index = overflowIndex
        while true {
            let offset = pageStartArrayOffset + index * 2
            guard offset >= pageStartArrayOffset, offset + 2 <= segmentInfoEnd,
                  let raw = try? data.readUInt16LE(at: offset, context: "chain_starts")
            else { return nil }
            starts.append(raw & ~MachOConstants.dyldChainedPtrStartLast)
            if raw & MachOConstants.dyldChainedPtrStartLast != 0 { return starts }
            index += 1
        }
    }

    /// Follows one chain from `chainFileOffset` via each entry's `next` field until the
    /// next field is 0. Bounded by `dyldChainedMaxChainLength` so a cyclic/overlong
    /// chain can never infinite-loop on untrusted bytes. Stride/delta consistency is asserted
    /// on every step: an entry must start inside its page (`entryStartLimit`) and fit inside the
    /// segment (`entryEndLimit`), and must not revisit an earlier entry. A violation ends the
    /// chain with a typed `chainedFixupsChainDeltaMismatch` finding.
    private func walkChain(
        in data: Data,
        chainFileOffset: Int,
        entryStartLimit: Int,
        entryEndLimit: Int,
        segmentFileOffset: Int,
        segment: MachOSegment?,
        segmentIndex: Int,
        pointerFormat: UInt16,
        stride: Int,
        payloadDataCount: Int,
        imageBase: UInt64,
        imports: [MachOChainedImport],
        importsRefused: Bool,
        into fixups: inout [MachOChainedFixup],
        log: inout MachOLoaderFindingLog
    ) {
        var cursor = chainFileOffset
        var iterations = 0
        var visited = Set<Int>()
        var previousDelta: Int?
        let segmentScope = UInt64(segmentIndex)
        func endChain(_ reason: String) {
            let anchor = segmentAddress(segment: segment, segmentFileOffset: segmentFileOffset, fileOffset: max(cursor, 0))
            log.record(MachOLoaderFinding(
                kind: .chainedFixupsChainDeltaMismatch,
                address: anchor,
                value: previousDelta.map { UInt64($0) },
                message: "Chained fixup chain ended early in segment "
                    + "\(segment?.name ?? "#\(segmentIndex)"): \(reason). Later fixups on that page were not applied."
            ), scope: segmentScope)
        }
        while true {
            guard iterations < MachOConstants.dyldChainedMaxChainLength else {
                endChain("more than \(MachOConstants.dyldChainedMaxChainLength) entries")
                return
            }
            iterations += 1
            guard cursor >= 0, cursor < entryStartLimit, cursor + 8 <= entryEndLimit, cursor + 8 <= payloadDataCount else {
                endChain(previousDelta == nil
                    ? "the page start lies outside the segment"
                    : "next delta \(previousDelta ?? 0) bytes (stride \(stride)) leaves the page or segment")
                return
            }
            // Cycle guard: a `next` that revisits an offset (incl. self-loop) ends the walk.
            guard visited.insert(cursor).inserted else {
                endChain("next delta revisits an earlier entry")
                return
            }
            guard fixups.count < MachOConstants.dyldChainedMaxFixups else { return }

            guard let raw = try? data.readUInt64LE(at: cursor, context: "chained pointer") else { return }

            // Bit layout is format-dependent: arm64e packs auth:1 @63, bind:1 @62, next:11 @51;
            // the generic 64-bit format packs bind:1 @63, next:12 @51. Decoding arm64e with the
            // generic layout misreads `bind` (hits the auth bit) and over-reads `next`.
            let isArm64e = pointerFormatIsArm64e(pointerFormat)
            let isBind = isArm64e ? ((raw >> 62) & 0x1 == 1) : ((raw >> 63) & 0x1 == 1)
            let next = isArm64e ? Int((raw >> 51) & 0x7ff) : Int((raw >> 51) & 0xfff)

            let fileOffset = UInt64(cursor)
            let address = segmentAddress(segment: segment, segmentFileOffset: segmentFileOffset, fileOffset: cursor)

            if isBind {
                // USERLAND24 uses the wider ordinal in both authenticated and plain binds.
                let ordinalMask: UInt64 = isArm64e && pointerFormat != MachOConstants.dyldChainedPtrArm64eUserland24
                    ? 0xffff : 0xff_ffff
                let ordinalBits = Int(raw & ordinalMask)
                let importEntry = ordinalBits < imports.count ? imports[ordinalBits] : nil
                if importEntry == nil, !importsRefused {
                    log.record(MachOLoaderFinding(
                        kind: .chainedFixupsBindOrdinalOutOfRange,
                        address: address,
                        value: UInt64(ordinalBits),
                        message: "Chained bind uses import ordinal \(ordinalBits) but the image declares "
                            + "\(imports.count) imports; the bind stays unresolved."
                    ), scope: segmentScope)
                }
                // dyld: target = import target + import addend, then + the inline addend.
                let inlineAddend = Self.chainedBindInlineAddend(raw: raw, pointerFormat: pointerFormat)
                let addend = (importEntry?.addend ?? 0) &+ inlineAddend
                fixups.append(MachOChainedFixup(
                    fileOffset: fileOffset,
                    address: address,
                    pointerFormat: pointerFormat,
                    kind: .bind(importOrdinal: ordinalBits, symbolName: importEntry?.name, addend: addend)
                ))
            } else if let target = rebaseTargetAddress(raw: raw, pointerFormat: pointerFormat, imageBase: imageBase) {
                fixups.append(MachOChainedFixup(
                    fileOffset: fileOffset,
                    address: address,
                    pointerFormat: pointerFormat,
                    kind: .rebase(targetAddress: target)
                ))
            } else {
                log.record(MachOLoaderFinding(
                    kind: .chainedFixupsUnhandledRebase,
                    address: address,
                    value: UInt64(pointerFormat),
                    message: "Unhandled chained rebase in format "
                        + "\(MachOLoaderFinding.chainedPointerFormatName(pointerFormat)): the target "
                        + "does not fit the address space; the slot was left unresolved."
                ), scope: segmentScope)
            }

            if next == 0 { return } // end of chain
            let delta = next * stride
            previousDelta = delta
            cursor += delta
        }
    }

    /// HS-5: an image manually extracted from the dyld shared cache keeps selector/class
    /// reference slots that point into the cache's shared regions (selector pool, `__OBJC_RO`),
    /// i.e. outside every segment of the extracted image. When at least half of the resolvable
    /// references (bound imports excluded) land outside the image, ObjC results are not
    /// trustworthy and a typed diagnosis replaces silent empty or garbage results.
    static func objectiveCSharedCacheExtractionDiagnostics(
        metadata: MachOObjectiveCMetadata,
        segments: [MachOSegment]
    ) -> [MachOLoaderFinding] {
        let ranges: [Range<UInt64>] = segments.compactMap { segment in
            guard segment.vmSize > 0 else { return nil }
            let (end, overflow) = segment.vmAddress.addingReportingOverflow(segment.vmSize)
            return overflow ? nil : segment.vmAddress..<end
        }
        guard !ranges.isEmpty else { return [] }
        let references = metadata.selectorReferences + metadata.classReferences + metadata.superclassReferences
        let candidates = references.filter { $0.targetAddress != 0 }
        guard !candidates.isEmpty else { return [] }
        let outside = candidates.filter { reference in
            !ranges.contains { $0.contains(reference.targetAddress) }
        }
        guard let first = outside.first, outside.count * 2 >= candidates.count else { return [] }
        return [MachOLoaderFinding(
            kind: .objcMetadataFromSharedCacheExtraction,
            address: first.sourceAddress,
            value: UInt64(outside.count),
            message: "Objective-C metadata looks mangled: \(outside.count) of \(candidates.count) selector "
                + "and class references point outside this image. This looks like an image extracted "
                + "from the dyld shared cache; ObjC metadata unavailable without the cache. "
                + "Open the shared cache itself to analyze this image."
        )]
    }

    /// The header-bearing __TEXT segment establishes the preferred base, including zero.
    /// For images without __TEXT, exclude virtual-only segments such as __PAGEZERO.
    private static func preferredImageBase(segments: [MachOSegment]) -> UInt64 {
        if let text = segments.first(where: { $0.name == "__TEXT" }) { return text.vmAddress }
        return segments.filter { $0.fileSize > 0 }.map(\.vmAddress).min() ?? 0
    }

    /// In-image rebase target VM address; malformed offsets cannot wrap into another address.
    private func rebaseTargetAddress(raw: UInt64, pointerFormat: UInt16, imageBase: UInt64) -> UInt64? {
        switch pointerFormat {
        case MachOConstants.dyldChainedPtr64:
            // dyld_chained_ptr_64_rebase: target:36, high8:8 — an absolute unslid VM address.
            let target = raw & 0xf_ffff_ffff
            let high8 = (raw >> 36) & 0xff
            return target | (high8 << 56)
        case MachOConstants.dyldChainedPtr64Offset:
            // _64_OFFSET stores a runtime offset from the image base; dyld adds the base to
            // the unpacked target, which keeps high8 in the top byte.
            let (target, overflow) = imageBase.addingReportingOverflow(raw & 0xf_ffff_ffff)
            guard !overflow else { return nil }
            return Self.addingHigh8(target, high8: (raw >> 36) & 0xff)
        case MachOConstants.dyldChainedPtrArm64e where (raw >> 63) & 1 == 0:
            // Plain ARM64E (format 1) stores an unslid address, unlike USERLAND.
            let target = raw & 0x7ff_ffff_ffff
            let high8 = (raw >> 43) & 0xff
            return target | (high8 << 56)
        default:
            // Authenticated ARM64E rebases and USERLAND plain rebases use offsets. Only the
            // plain rebase carries high8 (bits 43..50); the auth rebase target is 32 bits.
            let isAuth = (raw >> 63) & 0x1 == 1
            let offset = isAuth ? (raw & 0xffff_ffff) : (raw & 0x7ff_ffff_ffff)
            let (target, overflow) = imageBase.addingReportingOverflow(offset)
            guard !overflow else { return nil }
            return isAuth ? target : Self.addingHigh8(target, high8: (raw >> 43) & 0xff)
        }
    }

    /// Adds a rebase's high8 byte into bits 56..63; nil instead of wrapping on overflow.
    private static func addingHigh8(_ target: UInt64, high8: UInt64) -> UInt64? {
        let (result, overflow) = target.addingReportingOverflow(high8 << 56)
        return overflow ? nil : result
    }

    private func supportedPointerFormat(_ format: UInt16) -> Bool {
        switch format {
        case MachOConstants.dyldChainedPtr64,
            MachOConstants.dyldChainedPtr64Offset,
            MachOConstants.dyldChainedPtrArm64e,
            MachOConstants.dyldChainedPtrArm64eUserland,
            MachOConstants.dyldChainedPtrArm64eUserland24:
            return true
        default:
            return false
        }
    }

    private func pointerFormatIsArm64e(_ format: UInt16) -> Bool {
        switch format {
        case MachOConstants.dyldChainedPtrArm64e,
            MachOConstants.dyldChainedPtrArm64eUserland,
            MachOConstants.dyldChainedPtrArm64eUserland24:
            return true
        default:
            return false
        }
    }

    /// Stride between chain entries in BYTES. The plain 64-bit formats stride by 4;
    /// the ARM64E formats stride by 8.
    private func pointerStride(for format: UInt16) -> Int {
        pointerFormatIsArm64e(format) ? 8 : 4
    }

    /// VM address of a patched pointer: segment VM base + (fileOffset - segment file base).
    private func segmentAddress(segment: MachOSegment?, segmentFileOffset: Int, fileOffset: Int) -> UInt64 {
        guard let segment else { return UInt64(fileOffset) }
        let delta = fileOffset - segmentFileOffset
        guard delta >= 0 else { return segment.vmAddress }
        return segment.vmAddress &+ UInt64(delta)
    }

    /// Safe UInt32/UInt64 -> Int with no trap: returns nil on overflow (64-bit Int can
    /// always hold a UInt32, so that path never overflows; UInt64 is range-checked).
    private func intOffset<T: BinaryInteger>(_ value: T) -> Int? {
        Int(exactly: value)
    }

    private func parseLinkeditDataCommand(
        in data: Data,
        at offset: Int,
        commandSize: UInt32,
        index: Int,
        name: String
    ) throws -> MachOLinkeditDataCommand {
        guard commandSize >= 16 else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "\(name) is smaller than 16 bytes")
        }

        let dataOffset = try data.readUInt32LE(at: offset + 8, context: "\(name) dataoff")
        let dataSize = try data.readUInt32LE(at: offset + 12, context: "\(name) datasize")
        let start = Int(dataOffset)
        let size = Int(dataSize)
        guard start <= data.count, size <= data.count - start else {
            throw MachOParserError.invalidLoadCommand(index: index, reason: "\(name) data range points outside the file")
        }

        return MachOLinkeditDataCommand(index: index, dataOffset: dataOffset, dataSize: dataSize)
    }

    private func parseFunctionStarts(
        in data: Data,
        command: MachOLinkeditDataCommand,
        segments: [MachOSegment]
    ) throws -> [MachOFunctionStart] {
        guard command.dataSize > 0 else { return [] }
        let preferredImageBase = segments.first(where: { $0.name == "__TEXT" })?.vmAddress
        let fallbackImageBase = segments.map(\.vmAddress).min()
        guard let imageBase = preferredImageBase ?? fallbackImageBase else {
            return []
        }

        var starts: [MachOFunctionStart] = []
        var accumulatedOffset: UInt64 = 0
        var cursor = Int(command.dataOffset)
        let limit = cursor + Int(command.dataSize)

        while cursor < limit, starts.count < MachORecoveryLimits.maximumFunctionStarts {
            let delta = try readULEB128(in: data, cursor: &cursor, limit: limit, context: "LC_FUNCTION_STARTS delta")
            guard delta != 0 else { break }
            guard UInt64.max - accumulatedOffset >= delta else {
                throw MachOParserError.invalidLoadCommand(index: command.index, reason: "LC_FUNCTION_STARTS delta overflows image offset")
            }
            accumulatedOffset += delta
            guard UInt64.max - imageBase >= accumulatedOffset else {
                throw MachOParserError.invalidLoadCommand(index: command.index, reason: "LC_FUNCTION_STARTS address overflows image base")
            }
            starts.append(MachOFunctionStart(
                offsetFromImageBase: accumulatedOffset,
                address: imageBase + accumulatedOffset
            ))
        }

        return starts
    }

    private func parseDataInCodeEntries(
        in data: Data,
        command: MachOLinkeditDataCommand,
        segments: [MachOSegment]
    ) throws -> [MachODataInCodeEntry] {
        guard command.dataSize > 0 else { return [] }
        // `data_in_code_entry` is fixed at 8 bytes. If the payload is malformed, abstain from
        // trusting any partial table rather than manufacturing an incomplete exclusion map.
        guard command.dataSize % 8 == 0 else { return [] }
        let declaredCount = Int(command.dataSize / 8)
        let count = min(declaredCount, MachORecoveryLimits.maximumDataInCodeEntries)
        var entries: [MachODataInCodeEntry] = []
        entries.reserveCapacity(count)
        var cursor = Int(command.dataOffset)
        for _ in 0..<count {
            let fileOffset = try data.readUInt32LE(at: cursor, context: "LC_DATA_IN_CODE offset")
            let length = try data.readUInt16LE(at: cursor + 4, context: "LC_DATA_IN_CODE length")
            let kind = try data.readUInt16LE(at: cursor + 6, context: "LC_DATA_IN_CODE kind")
            cursor += 8

            guard length > 0,
                  let address = virtualAddress(forFileOffset: UInt64(fileOffset), segments: segments),
                  UInt64.max - address >= UInt64(length) else {
                continue
            }
            entries.append(MachODataInCodeEntry(
                fileOffset: fileOffset,
                length: length,
                kind: kind,
                address: address
            ))
        }
        return entries
    }

    private func virtualAddress(forFileOffset fileOffset: UInt64, segments: [MachOSegment]) -> UInt64? {
        for segment in segments where segment.fileSize > 0 {
            let (fileEnd, endOverflow) = segment.fileOffset.addingReportingOverflow(segment.fileSize)
            guard !endOverflow, fileOffset >= segment.fileOffset, fileOffset < fileEnd else { continue }
            let (virtualAddress, vaOverflow) = segment.vmAddress.addingReportingOverflow(fileOffset - segment.fileOffset)
            guard !vaOverflow else { return nil }
            return virtualAddress
        }
        return nil
    }

    private func parseExceptionMetadata(
        in data: Data,
        sections: [MachOSection],
        loadCommands: [MachOLoadCommand],
        functionStartsCommand: MachOLinkeditDataCommand?
    ) throws -> MachOExceptionMetadata {
        var metadataSections: [MachOExceptionSection] = []

        for section in sections {
            guard metadataSections.count < MachORecoveryLimits.maximumExceptionMetadataSections else { break }
            guard let kind = exceptionSectionKind(for: section) else { continue }
            let entrySize = exceptionSectionEntrySize(for: kind)
            let entryCount = boundedEntryCount(sectionSize: section.size, entrySize: entrySize)
            let unwindInfoHeader = kind == .unwindInfo
                ? try parseUnwindInfoHeader(in: data, section: section)
                : nil

            metadataSections.append(MachOExceptionSection(
                kind: kind,
                sectionName: section.sectionName,
                segmentName: section.segmentName,
                address: section.address,
                size: section.size,
                fileOffset: section.fileOffset,
                entrySize: entrySize,
                entryCount: entryCount,
                unwindInfoHeader: unwindInfoHeader
            ))
        }

        let relatedLoadCommands = metadataSections.isEmpty
            ? []
            : loadCommands.compactMap { loadCommand -> MachOExceptionLoadCommand? in
                guard loadCommand.command == MachOConstants.loadCommandFunctionStarts else {
                    return nil
                }
                return MachOExceptionLoadCommand(
                    command: loadCommand.command,
                    name: loadCommand.name,
                    offset: loadCommand.offset,
                    dataOffset: functionStartsCommand?.dataOffset,
                    dataSize: functionStartsCommand?.dataSize
                )
            }

        return MachOExceptionMetadata(
            sections: metadataSections,
            relatedLoadCommands: relatedLoadCommands
        )
    }

    private func exceptionSectionKind(for section: MachOSection) -> MachOExceptionSectionKind? {
        switch section.sectionName {
        case "__unwind_info":
            return .unwindInfo
        case "__compact_unwind":
            return .compactUnwind
        case "__eh_frame":
            return .dwarfEHFrame
        case "__gcc_except_tab", "__objc_except_tab":
            return .languageSpecificData
        default:
            return nil
        }
    }

    private func exceptionSectionEntrySize(for kind: MachOExceptionSectionKind) -> Int? {
        switch kind {
        case .compactUnwind:
            return MachOConstants.compactUnwindEntrySize64
        case .unwindInfo, .dwarfEHFrame, .languageSpecificData:
            return nil
        }
    }

    private func parseUnwindInfoHeader(
        in data: Data,
        section: MachOSection
    ) throws -> MachOUnwindInfoHeader? {
        guard section.size >= UInt64(MachOConstants.unwindInfoHeaderSize) else {
            return nil
        }
        guard section.size <= UInt64(Int.max) else {
            throw MachOParserError.invalidSection(section.qualifiedName, reason: "section is too large to map on this host")
        }
        // A stripped section (e.g. a dSYM's __TEXT,__unwind_info) keeps its address+size but has
        // NO file content — its `fileOffset` is 0, which would otherwise make us read the Mach-O
        // header magic as a bogus unwind header and throw. A genuine __unwind_info never lives at
        // file offset 0 (it sits well inside __TEXT), so treat offset-0 as "header absent".
        guard section.fileOffset != 0 else {
            return nil
        }

        let sectionOffset = Int(section.fileOffset)
        let sectionSize = Int(section.size)
        guard sectionOffset <= data.count, sectionSize <= data.count - sectionOffset else {
            throw MachOParserError.invalidSection(section.qualifiedName, reason: "file range points outside the file")
        }

        let version = try data.readUInt32LE(at: sectionOffset, context: "\(section.qualifiedName) unwind header version")
        let commonEncodingsOffset = try data.readUInt32LE(
            at: sectionOffset + 4,
            context: "\(section.qualifiedName) unwind common encodings offset"
        )
        let commonEncodingsCount = try data.readUInt32LE(
            at: sectionOffset + 8,
            context: "\(section.qualifiedName) unwind common encodings count"
        )
        let personalityOffset = try data.readUInt32LE(
            at: sectionOffset + 12,
            context: "\(section.qualifiedName) unwind personality offset"
        )
        let personalityCount = try data.readUInt32LE(
            at: sectionOffset + 16,
            context: "\(section.qualifiedName) unwind personality count"
        )
        let indexOffset = try data.readUInt32LE(
            at: sectionOffset + 20,
            context: "\(section.qualifiedName) unwind index offset"
        )
        let indexCount = try data.readUInt32LE(
            at: sectionOffset + 24,
            context: "\(section.qualifiedName) unwind index count"
        )

        for (label, relativeOffset) in [
            ("commonEncodingsArraySectionOffset", commonEncodingsOffset),
            ("personalityArraySectionOffset", personalityOffset),
            ("indexSectionOffset", indexOffset)
        ] where UInt64(relativeOffset) > section.size {
            throw MachOParserError.invalidSection(
                section.qualifiedName,
                reason: "\(label) points outside the section"
            )
        }

        return MachOUnwindInfoHeader(
            version: version,
            commonEncodingsArraySectionOffset: commonEncodingsOffset,
            commonEncodingsArrayCount: min(commonEncodingsCount, MachORecoveryLimits.maximumUnwindInfoHeaderCount),
            personalityArraySectionOffset: personalityOffset,
            personalityArrayCount: min(personalityCount, MachORecoveryLimits.maximumUnwindInfoHeaderCount),
            indexSectionOffset: indexOffset,
            indexCount: min(indexCount, MachORecoveryLimits.maximumUnwindInfoHeaderCount)
        )
    }

    private func boundedEntryCount(sectionSize: UInt64, entrySize: Int?) -> Int? {
        guard let entrySize, entrySize > 0 else { return nil }
        let entrySize64 = UInt64(entrySize)
        guard sectionSize % entrySize64 == 0 else { return nil }
        let count = sectionSize / entrySize64
        return Int(min(count, UInt64(MachORecoveryLimits.maximumExceptionMetadataEntries)))
    }

    private func parseSymbolInformation(
        in data: Data,
        symtab: MachOSymtabCommand?,
        dysymtab: MachODysymtabCommand?,
        dylibs: [MachODylib],
        dyldInfo: MachODyldInfoCommand?,
        exportsTrie: MachOLinkeditDataCommand?,
        imageBase: UInt64
    ) throws -> (symbols: [MachOSymbol], imports: [MachOImport], exports: [MachOExport], complete: Bool) {
        var symbols: [MachOSymbol] = []
        var imports: [MachOImport] = []
        var exports: [MachOExport] = []
        var complete = true

        if let symtab {
            let parsed = try parseSymbols(in: data, symtab: symtab, dysymtab: dysymtab, dylibs: dylibs)
            symbols = parsed.symbols
            imports = parsed.imports
            exports = parsed.exports
            complete = parsed.complete
        }

        var trieExports: [MachOExport] = []
        if let dyldInfo {
            trieExports += try parseExportTrieTracking(
                in: data, exportOffset: dyldInfo.exportOffset, exportSize: dyldInfo.exportSize,
                commandIndex: dyldInfo.index, source: "LC_DYLD_INFO", imageBase: imageBase, complete: &complete
            )
        }

        // Modern dylibs emit LC_DYLD_EXPORTS_TRIE in place of LC_DYLD_INFO; its payload is the same
        // export-trie format, so recover from it the same way.
        if let exportsTrie {
            trieExports += try parseExportTrieTracking(
                in: data, exportOffset: exportsTrie.dataOffset, exportSize: exportsTrie.dataSize,
                commandIndex: exportsTrie.index, source: "LC_DYLD_EXPORTS_TRIE", imageBase: imageBase, complete: &complete
            )
        }

        // Trie terminals carry the binding kind and flags that nlist definitions lack.
        // Preserve all terminals, including duplicate names, so consumers can refuse
        // ambiguous bindings instead of accepting whichever definition was seen first.
        let trieNames = Set(trieExports.map(\.name))
        let trieAddresses = Set(trieExports.compactMap(\.address))
        if exports.contains(where: { trieNames.contains($0.name) && $0.address.map { !trieAddresses.contains($0) } == true }) {
            complete = false
        }
        exports.removeAll { trieNames.contains($0.name) }
        exports.append(contentsOf: trieExports)

        return (symbols, imports, exports, complete)
    }

    /// The nlist indices to recover. Within the recovery cap, imports (undefined symbols) and
    /// exported definitions come first and locals fill what is left: the table is ordered
    /// locals, external definitions, undefined, so a plain prefix of a large unstripped binary
    /// kept only locals and dropped every import (Acorn: all 1,892). Indices stay ascending.
    static func recoveredSymbolIndices(
        declaredCount: Int, readableCount: Int, dysymtab: MachODysymtabCommand?
    ) -> [Int] {
        let limit = MachORecoveryLimits.maximumSymbols
        let available = max(0, min(declaredCount, readableCount))
        guard available > limit, let dysymtab else { return Array(0..<min(available, limit)) }
        var selected = Set<Int>()
        func take(_ start: UInt32, _ count: UInt32) {
            let lower = min(Int(start), available)
            let upper = min(lower + Int(count), available)
            for index in lower..<upper {
                guard selected.count < limit else { return }
                selected.insert(index)
            }
        }
        take(dysymtab.undefinedSymbolIndex, dysymtab.undefinedSymbolCount)
        take(dysymtab.externalDefinedSymbolIndex, dysymtab.externalDefinedSymbolCount)
        take(dysymtab.localSymbolIndex, dysymtab.localSymbolCount)
        return selected.sorted()
    }

    private func parseSymbols(
        in data: Data,
        symtab: MachOSymtabCommand,
        dysymtab: MachODysymtabCommand?,
        dylibs: [MachODylib]
    ) throws -> (symbols: [MachOSymbol], imports: [MachOImport], exports: [MachOExport], complete: Bool) {
        let symbolOffset = Int(symtab.symbolOffset)
        let declaredSymbolCount = Int(symtab.symbolCount)
        let symbolCount = min(declaredSymbolCount, MachORecoveryLimits.maximumSymbols)
        let stringOffset = Int(symtab.stringOffset)
        let stringSize = Int(symtab.stringSize)

        guard symbolOffset >= 0, symbolOffset <= data.count, symbolCount <= (data.count - symbolOffset) / 16 else {
            throw MachOParserError.invalidLoadCommand(index: symtab.index, reason: "LC_SYMTAB symbol table points outside the file")
        }
        guard stringOffset >= 0, stringOffset <= data.count, stringSize <= data.count - stringOffset else {
            throw MachOParserError.invalidLoadCommand(index: symtab.index, reason: "LC_SYMTAB string table points outside the file")
        }

        var symbols: [MachOSymbol] = []
        var imports: [MachOImport] = []
        var exports: [MachOExport] = []
        var complete = declaredSymbolCount <= MachORecoveryLimits.maximumSymbols
            && declaredSymbolCount <= (data.count - symbolOffset) / 16

        for symbolIndex in Self.recoveredSymbolIndices(
            declaredCount: declaredSymbolCount,
            readableCount: (data.count - symbolOffset) / 16,
            dysymtab: dysymtab
        ) {
            let entryOffset = symbolOffset + symbolIndex * 16
            let stringIndex = try data.readUInt32LE(at: entryOffset, context: "nlist_64 n_strx")
            let type = try data.readUInt8(at: entryOffset + 4, context: "nlist_64 n_type")
            let sectionIndex = try data.readUInt8(at: entryOffset + 5, context: "nlist_64 n_sect")
            let description = try data.readUInt16LE(at: entryOffset + 6, context: "nlist_64 n_desc")
            let value = try data.readUInt64LE(at: entryOffset + 8, context: "nlist_64 n_value")

            guard type & MachOConstants.symbolDebugMask == 0 else {
                if type & MachOConstants.symbolExternal != 0 { complete = false }
                continue
            }
            let name = stringTableString(in: data, tableOffset: stringOffset, tableSize: stringSize, stringIndex: stringIndex)
            guard !name.isEmpty else {
                if type & MachOConstants.symbolExternal != 0 { complete = false }
                continue
            }

            let typeBits = type & MachOConstants.symbolTypeMask
            let isExternal = type & MachOConstants.symbolExternal != 0
            let kind = classifySymbol(
                index: symbolIndex,
                typeBits: typeBits,
                isExternal: isExternal,
                dysymtab: dysymtab
            )
            // `self.` disambiguates the methods from the locals shadowing them —
            // the Swift 6.2 frontend (Xcode 26.5) fails on the unqualified lookup.
            let libraryOrdinal = kind == .import ? self.libraryOrdinal(from: description) : nil
            let libraryName = libraryOrdinal.flatMap { self.libraryName(for: $0, dylibs: dylibs) }
            let address = typeBits == MachOConstants.symbolTypeUndefined ? nil : value

            let symbol = MachOSymbol(
                index: symbolIndex,
                name: name,
                address: address,
                kind: kind,
                isExternal: isExternal,
                sectionIndex: sectionIndex,
                type: type,
                description: description,
                libraryOrdinal: libraryOrdinal,
                libraryName: libraryName
            )
            symbols.append(symbol)

            if kind == .import {
                imports.append(MachOImport(
                    symbolIndex: symbolIndex,
                    name: name,
                    libraryOrdinal: libraryOrdinal,
                    libraryName: libraryName
                ))
            } else if kind == .export {
                exports.append(MachOExport(
                    symbolIndex: symbolIndex,
                    name: name,
                    address: address,
                    flags: nil,
                    source: "LC_SYMTAB"
                ))
            }
        }

        return (symbols, imports, exports, complete)
    }

    private func parseIndirectSymbols(
        in data: Data,
        dysymtab: MachODysymtabCommand?,
        sections: [MachOSection],
        symbols: [MachOSymbol]
    ) throws -> [MachOIndirectSymbol] {
        guard let dysymtab, dysymtab.indirectSymbolCount > 0 else { return [] }

        let tableOffset = Int(dysymtab.indirectSymbolOffset)
        let tableCount = Int(dysymtab.indirectSymbolCount)
        guard tableOffset >= 0, tableOffset <= data.count, tableCount <= (data.count - tableOffset) / 4 else {
            throw MachOParserError.invalidLoadCommand(index: dysymtab.index, reason: "LC_DYSYMTAB indirect symbol table points outside the file")
        }

        let symbolByIndex = Dictionary(
            symbols.map { ($0.index, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var recoveredSymbols: [MachOIndirectSymbol] = []

        for section in sections {
            guard recoveredSymbols.count < MachORecoveryLimits.maximumIndirectSymbols else { break }
            guard let kind = indirectSymbolKind(for: section) else { continue }
            guard let entrySize = indirectSymbolEntrySize(for: kind, section: section) else { continue }
            guard section.size <= UInt64(Int.max) else {
                throw MachOParserError.invalidSection(section.qualifiedName, reason: "section is too large to map on this host")
            }

            let sectionEntryCount = Int(section.size / UInt64(entrySize))
            guard sectionEntryCount > 0 else { continue }

            let firstTableIndex = Int(section.reserved1)
            guard firstTableIndex < tableCount else {
                continue
            }

            let availableTableEntries = tableCount - firstTableIndex
            let remainingBudget = MachORecoveryLimits.maximumIndirectSymbols - recoveredSymbols.count
            let entryCount = min(sectionEntryCount, availableTableEntries, remainingBudget)

            for entryIndex in 0..<entryCount {
                let tableIndex = firstTableIndex + entryIndex
                let rawSymbolIndex = try data.readUInt32LE(
                    at: tableOffset + tableIndex * 4,
                    context: "LC_DYSYMTAB indirect symbol"
                )
                let isLocal = rawSymbolIndex & MachOConstants.indirectSymbolLocal != 0
                let isAbsolute = rawSymbolIndex & MachOConstants.indirectSymbolAbsolute != 0
                let normalizedSymbolIndex = rawSymbolIndex & MachOConstants.indirectSymbolIndexMask
                let symbolIndex = isLocal || isAbsolute ? nil : Int(normalizedSymbolIndex)
                let symbol = symbolIndex.flatMap { symbolByIndex[$0] }

                // A hostile section.address can overflow the per-entry VA projection; skip the
                // unrepresentable entry rather than trapping (the product is bounded by the
                // Int.max-guarded section.size, so only the UInt64 add can overflow).
                let (entryAddress, addressOverflow) = section.address
                    .addingReportingOverflow(UInt64(entryIndex * Int(entrySize)))
                guard !addressOverflow else { continue }

                recoveredSymbols.append(MachOIndirectSymbol(
                    kind: kind,
                    segmentName: section.segmentName,
                    sectionName: section.sectionName,
                    address: entryAddress,
                    entrySize: entrySize,
                    tableIndex: UInt32(tableIndex),
                    rawSymbolIndex: rawSymbolIndex,
                    symbolIndex: symbolIndex,
                    symbolName: symbol?.name,
                    libraryOrdinal: symbol?.libraryOrdinal,
                    libraryName: symbol?.libraryName,
                    isLocal: isLocal,
                    isAbsolute: isAbsolute
                ))
            }
        }

        return recoveredSymbols
    }

    private func indirectSymbolKind(for section: MachOSection) -> MachOIndirectSymbolKind? {
        switch section.flags & MachOConstants.sectionTypeMask {
        case MachOConstants.sectionTypeSymbolStubs:
            return .symbolStub
        case MachOConstants.sectionTypeLazySymbolPointers:
            return .lazySymbolPointer
        case MachOConstants.sectionTypeNonLazySymbolPointers:
            return .nonLazySymbolPointer
        default:
            return nil
        }
    }

    private func indirectSymbolEntrySize(
        for kind: MachOIndirectSymbolKind,
        section: MachOSection
    ) -> UInt32? {
        switch kind {
        case .symbolStub:
            return section.reserved2 == 0 ? nil : section.reserved2
        case .lazySymbolPointer, .nonLazySymbolPointer:
            return 8
        }
    }

    private func parseRelocations(
        in data: Data,
        sections: [MachOSection],
        symbols: [MachOSymbol]
    ) throws -> [MachORelocation] {
        let symbolByIndex = Dictionary(
            symbols.map { ($0.index, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var relocations: [MachORelocation] = []

        for section in sections where section.relocationCount > 0 {
            guard relocations.count < MachORecoveryLimits.maximumRelocations else { break }

            let tableOffset = UInt64(section.relocationOffset)
            let tableByteCount = UInt64(section.relocationCount) * 8
            guard tableOffset <= UInt64(data.count), tableByteCount <= UInt64(data.count) - tableOffset else {
                throw MachOParserError.invalidSection(section.qualifiedName, reason: "relocation table points outside the file")
            }

            let baseOffset = Int(tableOffset)
            let remainingBudget = MachORecoveryLimits.maximumRelocations - relocations.count
            let entryCount = min(Int(section.relocationCount), remainingBudget)

            for entryIndex in 0..<entryCount {
                let entryOffset = baseOffset + entryIndex * 8
                let firstWord = try data.readUInt32LE(at: entryOffset, context: "\(section.qualifiedName) relocation r_address")
                let secondWord = try data.readUInt32LE(at: entryOffset + 4, context: "\(section.qualifiedName) relocation info")
                let isScattered = firstWord & MachOConstants.relocationScatteredMask != 0

                if isScattered {
                    let relocationAddress = firstWord & MachOConstants.scatteredRelocationAddressMask
                    relocations.append(MachORelocation(
                        segmentName: section.segmentName,
                        sectionName: section.sectionName,
                        entryIndex: entryIndex,
                        fileOffset: UInt64(entryOffset),
                        relocationAddress: relocationAddress,
                        resolvedAddress: UInt64(relocationAddress),
                        symbolNumber: nil,
                        symbolName: nil,
                        isPCRelative: firstWord & MachOConstants.scatteredRelocationPCRelativeMask != 0,
                        length: UInt8((firstWord >> 28) & 0x3),
                        isExternal: false,
                        type: UInt8((firstWord >> 24) & 0xf),
                        isScattered: true,
                        value: secondWord
                    ))
                } else {
                    let symbolNumber = secondWord & MachOConstants.relocationSymbolNumberMask
                    let relocationAddress = firstWord
                    let resolvedAddress: UInt64?
                    if
                        UInt64(relocationAddress) < section.size,
                        section.address <= UInt64.max - UInt64(relocationAddress)
                    {
                        resolvedAddress = section.address + UInt64(relocationAddress)
                    } else {
                        resolvedAddress = nil
                    }
                    let isExternal = secondWord & MachOConstants.relocationExternalMask != 0
                    relocations.append(MachORelocation(
                        segmentName: section.segmentName,
                        sectionName: section.sectionName,
                        entryIndex: entryIndex,
                        fileOffset: UInt64(entryOffset),
                        relocationAddress: relocationAddress,
                        resolvedAddress: resolvedAddress,
                        symbolNumber: symbolNumber,
                        symbolName: isExternal ? symbolByIndex[Int(symbolNumber)]?.name : nil,
                        isPCRelative: secondWord & MachOConstants.relocationPCRelativeMask != 0,
                        length: UInt8((secondWord >> 25) & 0x3),
                        isExternal: isExternal,
                        type: UInt8((secondWord >> 28) & 0xf),
                        isScattered: false,
                        value: nil
                    ))
                }
            }
        }

        return relocations
    }

    private func parseCStringLiterals(in data: Data, sections: [MachOSection]) throws -> [MachOStringLiteral] {
        var literals: [MachOStringLiteral] = []

        for section in sections where section.isCStringLiterals || objectiveCMetadataDescriptor(for: section)?.stringRole != nil {
            guard literals.count < MachORecoveryLimits.maximumStringLiterals else { break }
            let sectionStrings = try parseMetadataStrings(
                in: data,
                section: section,
                maximumCount: MachORecoveryLimits.maximumStringLiterals - literals.count
            )
            literals.append(contentsOf: sectionStrings.map {
                MachOStringLiteral(
                    value: $0.value,
                    address: $0.address,
                    sourceSection: $0.sourceSection,
                    byteLength: $0.byteLength
                )
            })
        }

        return literals
    }

    private func parseObjectiveCMetadata(
        in data: Data,
        sections: [MachOSection],
        symbols: [MachOSymbol],
        chainedFixups: [MachOChainedFixup],
        objcCache: MachOObjCCacheContext? = nil
    ) throws -> MachOObjectiveCMetadata {
        var metadataSections: [MachOMetadataSection] = []
        var selectorStrings: [MachOMetadataString] = []
        var classNameStrings: [MachOMetadataString] = []
        var methodTypeStrings: [MachOMetadataString] = []
        var descriptors: [(section: MachOSection, descriptor: ObjectiveCMetadataDescriptor)] = []

        for section in sections {
            guard let descriptor = objectiveCMetadataDescriptor(for: section) else { continue }
            descriptors.append((section, descriptor))
            var recoveredStrings: [MachOMetadataString] = []

            if descriptor.stringRole != nil {
                let remainingStringBudget = max(
                    0,
                    MachORecoveryLimits.maximumMetadataStrings
                        - selectorStrings.count
                        - classNameStrings.count
                        - methodTypeStrings.count
                )
                recoveredStrings = try parseMetadataStrings(
                    in: data,
                    section: section,
                    maximumCount: remainingStringBudget
                )
            }

            metadataSections.append(makeMetadataSection(
                from: section,
                kind: descriptor.kind,
                entrySize: descriptor.entrySize,
                stringEntryCount: descriptor.stringRole == nil ? nil : recoveredStrings.count
            ))

            switch descriptor.stringRole {
            case .selectors:
                selectorStrings.append(contentsOf: recoveredStrings)
            case .classNames:
                classNameStrings.append(contentsOf: recoveredStrings)
            case .methodTypes:
                methodTypeStrings.append(contentsOf: recoveredStrings)
            case nil:
                break
            }
        }

        let metadataStrings = selectorStrings + classNameStrings + methodTypeStrings
        let stringByAddress = Dictionary(
            metadataStrings.map { ($0.address, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let symbolNameByAddress = Dictionary(
            symbols.compactMap { symbol -> (UInt64, String)? in
                guard let address = symbol.address else { return nil }
                return (address, symbol.name)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Under LC_DYLD_CHAINED_FIXUPS a selref/classref/superref slot holds a chain entry
        // (next/target bit fields), not a VM address, so the decoded fixup map is authoritative
        // for every slot it covers. Raw reads remain only for slots no fixup covers.
        var chainedRebaseTargets: [UInt64: UInt64] = [:]
        var chainedBindNames: [UInt64: String] = [:]
        let chainedCoveredAddresses = Set(chainedFixups.map(\.address))
        for fixup in chainedFixups {
            if let target = fixup.rebaseTargetAddress {
                chainedRebaseTargets[fixup.address] = target
            } else if let name = fixup.exactBoundSymbolName, !name.isEmpty {
                chainedBindNames[fixup.address] = name
            }
        }
        var selectorReferences: [MachOObjectiveCReference] = []
        var classReferences: [MachOObjectiveCReference] = []
        var superclassReferences: [MachOObjectiveCReference] = []

        for (section, descriptor) in descriptors {
            guard let referenceRole = descriptor.referenceRole else { continue }
            let remainingReferenceBudget = max(
                0,
                MachORecoveryLimits.maximumObjectiveCReferences
                    - selectorReferences.count
                    - classReferences.count
                    - superclassReferences.count
            )
            let references = try parseObjectiveCReferences(
                in: data,
                section: section,
                role: referenceRole,
                stringByAddress: stringByAddress,
                symbolNameByAddress: symbolNameByAddress,
                chainedRebaseTargets: chainedRebaseTargets,
                chainedBindNames: chainedBindNames,
                chainedCoveredAddresses: chainedCoveredAddresses,
                objcCache: objcCache,
                stringSections: descriptors.compactMap { $0.descriptor.stringRole == nil ? nil : $0.section },
                maximumCount: remainingReferenceBudget
            )

            switch referenceRole {
            case .selectors:
                selectorReferences.append(contentsOf: references)
            case .classes:
                classReferences.append(contentsOf: references)
            case .superclasses:
                superclassReferences.append(contentsOf: references)
            }
        }

        let objc = parseObjectiveCClasses(in: data, sections: sections, chainedFixups: chainedFixups, objcCache: objcCache)

        return MachOObjectiveCMetadata(
            sections: metadataSections,
            selectorStrings: selectorStrings,
            classNameStrings: classNameStrings,
            methodTypeStrings: methodTypeStrings,
            selectorReferences: selectorReferences,
            classReferences: classReferences,
            superclassReferences: superclassReferences,
            classes: objc.classes,
            categories: objc.categories,
            protocols: objc.protocols,
            parseDiagnostics: objc.diagnostics,
            parseDiagnosticsDropped: objc.dropped
        )
    }

    /// Builds the chained-fixup pointer maps and runs `ObjCClassParser` to recover the class
    /// table. Pointer locations come from the resolved fixups (rebases → in-image targets,
    /// binds → external symbol names such as `_OBJC_CLASS_$_NSObject`); the walker falls back to
    /// raw little-endian reads for any slot a fixup did not cover.
    private func parseObjectiveCClasses(
        in data: Data,
        sections: [MachOSection],
        chainedFixups: [MachOChainedFixup],
        objcCache: MachOObjCCacheContext? = nil
    ) -> (classes: [ObjCClass], categories: [ObjCCategory], protocols: [ObjCProtocol], diagnostics: [MetadataParseDiagnostic], dropped: Int) {
        var rebaseTargets: [UInt64: UInt64] = [:]
        var bindNames: [UInt64: String] = [:]
        var abstainedSlots = Set<UInt64>()
        for fixup in chainedFixups {
            if let target = fixup.rebaseTargetAddress {
                rebaseTargets[fixup.address] = target
            } else if let name = fixup.exactBoundSymbolName {
                bindNames[fixup.address] = name
            } else if fixup.isBind {
                abstainedSlots.insert(fixup.address)
            }
        }
        let parserSections = sections.map {
            ObjCClassParser.Section(
                address: $0.address,
                fileOffset: UInt64($0.fileOffset),
                size: $0.size,
                name: $0.sectionName
            )
        }
        var parser = ObjCClassParser(
            data: data,
            sections: parserSections,
            rebaseTargets: rebaseTargets,
            bindNames: bindNames,
            cachePointerBase: objcCache?.pointerBase,
            cacheReadBytes: objcCache?.readBytes,
            // Bound the walk only for an untrusted CACHE image (the whole-cache reader removes the
            // file-size bound); ordinary on-disk Mach-O stays unbounded (nil) as before.
            parseBudget: objcCache != nil ? ObjCClassParser.ParseBudget(ObjCClassParser.cacheParseWorkCap) : nil,
            abstainedPointerSlots: abstainedSlots
        )
        let log = MetadataParseDiagnosticLog()
        parser.diagnosticLog = log
        let classes = parser.parseClasses()
        let categories = parser.parseCategories()
        return (classes, categories, parser.parseProtocols(), log.entries, log.droppedCount)
    }

    /// Decodes the Swift reflection metadata (`__swift5_types` → type context descriptors →
    /// `__swift5_fieldmd`) into nominal types with their stored fields. Self-relative pointers are
    /// resolved arithmetically; the chained-fixup REBASE map is supplied for the rare *indirect*
    /// symbolic references in field type names. Mirrors `parseObjectiveCClasses`.
    private func parseSwiftTypes(
        in data: Data,
        sections: [MachOSection],
        chainedFixups: [MachOChainedFixup],
        classicFixups: MachODyldInfoFixups? = nil,
        symbols: [MachOSymbol]
    ) -> (types: [SwiftTypeDescriptor], conformances: [SwiftConformance], protocols: [SwiftProtocolDescriptor],
          diagnostics: [MetadataParseDiagnostic]) {
        var rebaseTargets: [UInt64: UInt64] = classicFixups?.rebaseTargets ?? [:]
        var bindNames: [UInt64: String] = classicFixups?.bindNames ?? [:]
        for fixup in chainedFixups {
            if let target = fixup.rebaseTargetAddress {
                rebaseTargets[fixup.address] = target
            } else if let name = fixup.exactBoundSymbolName {
                bindNames[fixup.address] = name
            }
        }
        let parserSections = sections.map {
            SwiftMetadataParser.Section(
                name: $0.sectionName,
                address: $0.address,
                fileOffset: UInt64($0.fileOffset),
                size: $0.size,
                isExecutable: $0.isExecutableInstructions,
                isZeroFill: $0.isZeroFill,
                segmentName: $0.segmentName
            )
        }
        let parser = SwiftMetadataParser(
            data: data,
            sections: parserSections,
            rebaseTargets: rebaseTargets,
            bindNames: bindNames,
            metadataAddresses: symbols.compactMap {
                $0.name.hasPrefix("_$s") && $0.name.hasSuffix("N") ? $0.address : nil
            }
        )
        let types = parser.parseTypesReport()
        let conformances = parser.parseConformancesReport()
        return (types.types, conformances.conformances, parser.parseProtocols(),
                types.diagnostics + conformances.diagnostics)
    }

    private func parseSwiftMetadataSections(in sections: [MachOSection]) -> [MachOMetadataSection] {
        sections.compactMap { section in
            guard let descriptor = swiftMetadataDescriptor(for: section) else { return nil }
            return makeMetadataSection(
                from: section,
                kind: descriptor.kind,
                entrySize: descriptor.entrySize
            )
        }
    }

    private func parseMetadataStrings(
        in data: Data,
        section: MachOSection,
        maximumCount: Int
    ) throws -> [MachOMetadataString] {
        guard maximumCount > 0 else { return [] }
        guard section.size <= UInt64(Int.max) else {
            throw MachOParserError.invalidSection(section.qualifiedName, reason: "section is too large to map on this host")
        }

        let sectionOffset = Int(section.fileOffset)
        let sectionSize = Int(section.size)
        guard sectionOffset <= data.count, sectionSize <= data.count - sectionOffset else {
            throw MachOParserError.invalidSection(section.qualifiedName, reason: "file range points outside the file")
        }

        let sectionEnd = sectionOffset + sectionSize
        var cursor = sectionOffset
        var strings: [MachOMetadataString] = []

        while cursor < sectionEnd && strings.count < maximumCount {
            let stringStart = cursor
            var terminator = cursor
            while terminator < sectionEnd, data[terminator] != 0 {
                terminator += 1
            }

            guard terminator < sectionEnd else {
                break
            }

            cursor = terminator + 1
            let byteLength = terminator - stringStart
            guard byteLength > 0, byteLength <= MachORecoveryLimits.maximumStringLiteralLength else {
                continue
            }

            let stringData = data[stringStart..<terminator]
            guard isRecoverableCStringBytes(stringData) else { continue }
            guard let value = String(data: stringData, encoding: .utf8) else { continue }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            // A hostile section.address can overflow the per-string VA projection; drop the
            // unrepresentable string rather than trapping (cursor has already advanced, so the
            // scan continues safely).
            let (stringAddress, addressOverflow) = section.address
                .addingReportingOverflow(UInt64(stringStart - sectionOffset))
            guard !addressOverflow else { continue }

            strings.append(MachOMetadataString(
                value: value,
                address: stringAddress,
                sourceSection: section.qualifiedName,
                byteLength: byteLength
            ))
        }

        return strings
    }

    private func parseObjectiveCReferences(
        in data: Data,
        section: MachOSection,
        role: ObjectiveCReferenceRole,
        stringByAddress: [UInt64: String],
        symbolNameByAddress: [UInt64: String],
        chainedRebaseTargets: [UInt64: UInt64] = [:],
        chainedBindNames: [UInt64: String] = [:],
        chainedCoveredAddresses: Set<UInt64> = [],
        objcCache: MachOObjCCacheContext? = nil,
        stringSections: [MachOSection] = [],
        maximumCount: Int
    ) throws -> [MachOObjectiveCReference] {
        guard maximumCount > 0 else { return [] }
        guard section.size <= UInt64(Int.max) else {
            throw MachOParserError.invalidSection(section.qualifiedName, reason: "section is too large to map on this host")
        }

        let sectionOffset = Int(section.fileOffset)
        let sectionSize = Int(section.size)
        guard sectionOffset <= data.count, sectionSize <= data.count - sectionOffset else {
            throw MachOParserError.invalidSection(section.qualifiedName, reason: "file range points outside the file")
        }

        let entrySize = 8
        let entryCount = min(sectionSize / entrySize, maximumCount)
        var references: [MachOObjectiveCReference] = []

        for entryIndex in 0..<entryCount {
            let pointerOffset = sectionOffset + entryIndex * entrySize
            let rawValue = try data.readUInt64LE(at: pointerOffset, context: "\(section.qualifiedName) pointer")

            // A hostile section.address can overflow the per-entry source-VA projection; skip the
            // unrepresentable entry rather than trapping.
            let (sourceAddress, addressOverflow) = section.address
                .addingReportingOverflow(UInt64(entryIndex * entrySize))
            guard !addressOverflow else { continue }

            let targetAddress: UInt64
            var boundName: String?
            if let rebased = chainedRebaseTargets[sourceAddress] {
                targetAddress = rebased
            } else if let bound = chainedBindNames[sourceAddress] {
                // An imported class/superclass ref (e.g. `_OBJC_CLASS_$_NSObject`) has no in-image
                // target; the bound symbol is the identity.
                targetAddress = 0
                boundName = normalizedObjectiveCSymbolName(bound)
            } else if chainedCoveredAddresses.contains(sourceAddress) {
                // Coverage is authoritative even when a malformed import ordinal or missing
                // symbol prevents resolution. An encoded chain word is never a raw VM pointer.
                continue
            } else if let objcCache {
                // Same DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE decode as ObjCClassParser.resolvePointer.
                targetAddress = rawValue == 0 ? 0 : objcCache.pointerBase &+ (rawValue & 0x3_FFFF_FFFF)
            } else {
                targetAddress = rawValue
            }
            guard targetAddress != 0 || boundName != nil else { continue }

            var resolvedName = boundName ?? resolvedObjectiveCReferenceName(
                targetAddress: targetAddress,
                stringByAddress: stringByAddress,
                symbolNameByAddress: symbolNameByAddress
            )
            if resolvedName == nil, targetAddress != 0,
               let stringSection = stringSections.first(where: {
                   targetAddress >= $0.address && targetAddress - $0.address < $0.size
               }) {
                // The recovered-string table is capped (maximumMetadataStrings); a selector or class
                // name past that cap is still read directly from its own metadata string section.
                resolvedName = Self.metadataReferenceString(
                    in: data, section: stringSection, targetAddress: targetAddress
                )
            }
            if resolvedName == nil, case .selectors = role,
               let objcCache, let bytes = objcCache.readBytes(targetAddress, 1024) {
                // Cache image: selector strings live in the shared __OBJC_RO region, not locally.
                let scalars = bytes.prefix { $0 != 0 }
                if !scalars.isEmpty, scalars.count < bytes.count {
                    resolvedName = String(decoding: scalars, as: UTF8.self)
                }
            }

            references.append(MachOObjectiveCReference(
                kind: role.kind,
                sourceAddress: sourceAddress,
                targetAddress: targetAddress,
                sourceSection: section.qualifiedName,
                resolvedName: resolvedName
            ))
        }

        return references
    }

    private func resolvedObjectiveCReferenceName(
        targetAddress: UInt64,
        stringByAddress: [UInt64: String],
        symbolNameByAddress: [UInt64: String]
    ) -> String? {
        if let stringValue = stringByAddress[targetAddress] {
            return stringValue
        }
        guard let symbolName = symbolNameByAddress[targetAddress] else {
            return nil
        }
        return normalizedObjectiveCSymbolName(symbolName)
    }

    private func normalizedObjectiveCSymbolName(_ symbolName: String) -> String {
        let prefixes = [
            "_OBJC_CLASS_$_",
            "_OBJC_METACLASS_$_",
            ".objc_class_name_"
        ]
        for prefix in prefixes where symbolName.hasPrefix(prefix) {
            return String(symbolName.dropFirst(prefix.count))
        }
        return symbolName
    }

    private func makeMetadataSection(
        from section: MachOSection,
        kind: String,
        entrySize: Int?,
        stringEntryCount: Int? = nil
    ) -> MachOMetadataSection {
        MachOMetadataSection(
            kind: kind,
            sectionName: section.sectionName,
            segmentName: section.segmentName,
            address: section.address,
            size: section.size,
            fileOffset: section.fileOffset,
            entrySize: entrySize,
            entryCount: stringEntryCount ?? fixedEntryCount(sectionSize: section.size, entrySize: entrySize)
        )
    }

    /// Budget exhaustion skips bulk string recovery, so validate this section
    /// independently before using a reference to read its bytes.
    static func metadataReferenceString(
        in data: Data, section: MachOSection, targetAddress: UInt64
    ) -> String? {
        guard let offset = Int(exactly: section.fileOffset),
              let size = Int(exactly: section.size),
              offset <= data.count, size > 0, size <= data.count - offset,
              targetAddress >= section.address,
              let delta = Int(exactly: targetAddress - section.address), delta < size
        else { return nil }
        let start = offset + delta
        let remaining = min(size - delta, MachORecoveryLimits.maximumStringLiteralLength + 1)
        guard let string = data.nullTerminatedString(at: start, limit: start + remaining),
              !string.value.isEmpty else { return nil }
        return string.value
    }

    private func fixedEntryCount(sectionSize: UInt64, entrySize: Int?) -> Int? {
        guard let entrySize, entrySize > 0 else { return nil }
        let entrySize64 = UInt64(entrySize)
        guard sectionSize % entrySize64 == 0 else { return nil }
        let count = sectionSize / entrySize64
        guard count <= UInt64(Int.max) else { return nil }
        return Int(count)
    }

    private func objectiveCMetadataDescriptor(for section: MachOSection) -> ObjectiveCMetadataDescriptor? {
        switch section.sectionName {
        case "__objc_methname":
            return ObjectiveCMetadataDescriptor(kind: "Objective-C selector names", entrySize: nil, stringRole: .selectors)
        case "__objc_classname":
            return ObjectiveCMetadataDescriptor(kind: "Objective-C class names", entrySize: nil, stringRole: .classNames)
        case "__objc_methtype":
            return ObjectiveCMetadataDescriptor(kind: "Objective-C method type encodings", entrySize: nil, stringRole: .methodTypes)
        case "__objc_selrefs":
            return ObjectiveCMetadataDescriptor(
                kind: "Objective-C selector references",
                entrySize: 8,
                referenceRole: .selectors
            )
        case "__objc_classrefs":
            return ObjectiveCMetadataDescriptor(
                kind: "Objective-C class references",
                entrySize: 8,
                referenceRole: .classes
            )
        case "__objc_superrefs":
            return ObjectiveCMetadataDescriptor(
                kind: "Objective-C superclass references",
                entrySize: 8,
                referenceRole: .superclasses
            )
        case "__objc_classlist":
            return ObjectiveCMetadataDescriptor(kind: "Objective-C class list", entrySize: 8)
        case "__objc_catlist":
            return ObjectiveCMetadataDescriptor(kind: "Objective-C category list", entrySize: 8)
        case "__objc_protolist":
            return ObjectiveCMetadataDescriptor(kind: "Objective-C protocol list", entrySize: 8)
        case "__objc_protorefs":
            return ObjectiveCMetadataDescriptor(kind: "Objective-C protocol references", entrySize: 8)
        case "__objc_nlclslist":
            return ObjectiveCMetadataDescriptor(kind: "Objective-C non-lazy class list", entrySize: 8)
        case "__objc_nlcatlist":
            return ObjectiveCMetadataDescriptor(kind: "Objective-C non-lazy category list", entrySize: 8)
        case "__objc_const":
            return ObjectiveCMetadataDescriptor(kind: "Objective-C constant data", entrySize: nil)
        case "__objc_data":
            return ObjectiveCMetadataDescriptor(kind: "Objective-C class data", entrySize: nil)
        default:
            return nil
        }
    }

    private func swiftMetadataDescriptor(for section: MachOSection) -> (kind: String, entrySize: Int?)? {
        switch section.sectionName {
        case "__swift5_types":
            return ("Swift type descriptors", 4)
        case "__swift5_types2":
            return ("Swift secondary type descriptors", 4)
        case "__swift_as_entry":
            return ("Swift async function entries", 4)
        case "__swift_as_ret":
            return ("Swift async resume partials", 4)
        case "__swift_as_cont":
            return ("Swift async continuation partials", 4)
        case "__constg_swiftt":
            return ("Swift constant type metadata", nil)
        case "__swift5_proto":
            return ("Swift protocol descriptors", 4)
        case "__swift5_protos":
            return ("Swift protocol descriptors", 4)
        case "__swift5_typeref":
            return ("Swift type references", 4)
        case "__swift5_capture":
            return ("Swift capture descriptors", 4)
        case "__swift5_builtin":
            return ("Swift builtin type descriptors", 4)
        case "__swift5_assocty":
            return ("Swift associated type descriptors", 4)
        case "__swift5_mpenum":
            return ("Swift multi-payload enum descriptors", 4)
        case "__swift5_replace":
            return ("Swift replacement descriptors", 4)
        case "__swift5_replac2":
            return ("Swift replacement descriptors v2", 4)
        case "__swift5_acfuncs":
            return ("Swift accessible functions", 4)
        case "__swift5_fieldmd":
            return ("Swift field metadata", nil)
        case "__swift5_reflstr":
            return ("Swift reflection strings", nil)
        default:
            guard section.sectionName.hasPrefix("__swift") else { return nil }
            return ("Swift metadata", nil)
        }
    }

    private func isRecoverableCStringBytes(_ bytes: Data) -> Bool {
        for byte in bytes {
            switch byte {
            case 0x09, 0x0a, 0x0d:
                continue
            case 0x20...0xff:
                continue
            default:
                return false
            }
        }
        return true
    }

    func parseExportTrie(
        in data: Data, exportOffset: UInt32, exportSize: UInt32, commandIndex: Int, source: String,
        imageBase: UInt64, budget: MachOExportTrieBudget = .init()
    ) throws -> [MachOExport] {
        var complete = true
        return try parseExportTrieTracking(in: data, exportOffset: exportOffset, exportSize: exportSize,
            commandIndex: commandIndex, source: source, imageBase: imageBase, budget: budget, complete: &complete)
    }

    private func parseExportTrieTracking(
        in data: Data, exportOffset: UInt32, exportSize: UInt32, commandIndex: Int, source: String,
        imageBase: UInt64, budget: MachOExportTrieBudget = .init(), complete: inout Bool
    ) throws -> [MachOExport] {
        guard exportOffset > 0, exportSize > 0 else {
            if exportSize > 0 { complete = false }
            return []
        }

        let start = Int(exportOffset)
        let size = Int(exportSize)
        guard start >= 0, start <= data.count, size <= data.count - start else {
            throw MachOParserError.invalidLoadCommand(index: commandIndex, reason: "\(source) export trie points outside the file")
        }

        let end = start + size
        var stack: [(relativeOffset: Int, name: String, prefixByteCount: Int)] = [(0, "", 0)]
        var budget = budget
        var visitedOffsets: Set<Int> = []
        var exports: [MachOExport] = []

        while let node = stack.popLast() {
            guard exports.count < MachORecoveryLimits.maximumExports, visitedOffsets.count < MachORecoveryLimits.maximumExportTrieNodes else {
                complete = false
                break
            }
            guard node.relativeOffset >= 0, node.relativeOffset < size else {
                throw MachOParserError.invalidLoadCommand(index: commandIndex, reason: "export trie node offset points outside the trie")
            }
            guard visitedOffsets.insert(node.relativeOffset).inserted else {
                complete = false
                continue
            }

            var cursor = start + node.relativeOffset
            let terminalSize = try readULEB128(in: data, cursor: &cursor, limit: end, context: "export trie terminal size")
            guard terminalSize <= UInt64(end - cursor) else {
                throw MachOParserError.invalidLoadCommand(index: commandIndex, reason: "export trie terminal extends beyond the trie")
            }

            let terminalEnd = cursor + Int(terminalSize)
            if terminalSize > 0 {
                var terminalCursor = cursor
                let flags = try readULEB128(in: data, cursor: &terminalCursor, limit: terminalEnd, context: "export trie flags")
                var address: UInt64?

                if flags & MachOConstants.exportSymbolFlagsReexport != 0 {
                    _ = try readULEB128(in: data, cursor: &terminalCursor, limit: terminalEnd, context: "export trie reexport ordinal")
                    if let importedName = data.nullTerminatedString(at: terminalCursor, limit: terminalEnd), !importedName.value.isEmpty {
                        terminalCursor = importedName.nextOffset
                    }
                } else {
                    let value = try readULEB128(in: data, cursor: &terminalCursor, limit: terminalEnd, context: "export trie address")
                    // EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE values are already absolute.
                    // Regular and thread-local exports are offsets from the image header.
                    if flags & 0x3 == 0x2 {
                        address = value
                    } else {
                        let (target, overflow) = imageBase.addingReportingOverflow(value)
                        address = overflow ? nil : target
                        if overflow { complete = false }
                    }
                    if flags & MachOConstants.exportSymbolFlagsStubAndResolver != 0 {
                        _ = try readULEB128(in: data, cursor: &terminalCursor, limit: terminalEnd, context: "export trie resolver")
                    }
                }

                if node.name.isEmpty { complete = false }
                if !node.name.isEmpty {
                    exports.append(MachOExport(
                        symbolIndex: nil,
                        name: node.name,
                        address: address,
                        flags: flags,
                        source: source
                    ))
                }
            }

            cursor = terminalEnd
            guard cursor < end else { complete = false; continue }
            let childCount = Int(data[cursor])
            cursor += 1

            for _ in 0..<childCount {
                guard let edge = data.nullTerminatedString(at: cursor, limit: end) else {
                    throw MachOParserError.invalidLoadCommand(index: commandIndex, reason: "export trie child edge is unterminated")
                }
                cursor = edge.nextOffset
                let childOffset = try readULEB128(in: data, cursor: &cursor, limit: end, context: "export trie child offset")
                guard childOffset < UInt64(size) else {
                    throw MachOParserError.invalidLoadCommand(index: commandIndex, reason: "export trie child offset points outside the trie")
                }
                // Reserve an offset and its full prefix before allocating the concatenation.
                // An already scheduled node must not consume another queue slot or name copy.
                guard let prefixByteCount = try budget.reserve(
                    relativeOffset: Int(childOffset), pendingEntryCount: stack.count,
                    parentPrefixByteCount: node.prefixByteCount, edgeByteCount: edge.value.utf8.count,
                    commandIndex: commandIndex
                ) else { complete = false; continue }
                stack.append((Int(childOffset), node.name + edge.value, prefixByteCount))
            }
        }

        return exports.sorted { $0.name < $1.name }
    }

    private func classifySymbol(
        index: Int,
        typeBits: UInt8,
        isExternal: Bool,
        dysymtab: MachODysymtabCommand?
    ) -> MachOSymbolKind {
        if dysymtab?.containsUndefinedSymbol(index) == true {
            return .import
        }
        if dysymtab?.containsExternalDefinedSymbol(index) == true {
            return .export
        }

        switch typeBits {
        case MachOConstants.symbolTypeUndefined, MachOConstants.symbolTypePreboundUndefined:
            return isExternal ? .import : .undefined
        case MachOConstants.symbolTypeSection:
            return isExternal ? .export : .local
        case MachOConstants.symbolTypeAbsolute:
            return isExternal ? .export : .absolute
        case MachOConstants.symbolTypeIndirect:
            return .indirect
        default:
            return isExternal ? .export : .local
        }
    }

    private func stringTableString(in data: Data, tableOffset: Int, tableSize: Int, stringIndex: UInt32) -> String {
        guard stringIndex > 0 else { return "" }
        let relativeOffset = Int(stringIndex)
        guard relativeOffset >= 0, relativeOffset < tableSize else { return "" }
        return data.cString(at: tableOffset + relativeOffset, maxLength: tableSize - relativeOffset)
    }

    private func libraryOrdinal(from description: UInt16) -> Int? {
        let ordinal = Int((description >> 8) & 0xff)
        return ordinal == 0 ? nil : ordinal
    }

    private func libraryName(for ordinal: Int, dylibs: [MachODylib]) -> String? {
        switch ordinal {
        case MachOConstants.dynamicLookupLibraryOrdinal:
            return "dynamic lookup"
        case MachOConstants.executableLibraryOrdinal:
            return "main executable"
        default:
            // An explicit bounds guard, not `case 1...dylibs.count`: with zero
            // declared dylibs that pattern constructs the invalid range 1...0,
            // which traps on a crafted binary carrying a nonzero ordinal.
            guard ordinal >= 1, ordinal <= dylibs.count else { return nil }
            return dylibs[ordinal - 1].name
        }
    }

    private func readULEB128(in data: Data, cursor: inout Int, limit: Int, context: String) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while cursor < limit {
            let byte = data[cursor]
            cursor += 1

            guard shift < 64 else {
                throw MachOParserError.truncated(context)
            }

            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }

        throw MachOParserError.truncated(context)
    }

    /// Enumerates EVERY slice of a fat/fat64 container under a strict layout contract, for
    /// consumers that must choose a slice by content identity (LC_UUID) rather than by the
    /// loader's architecture preference — e.g. dSYM import, where several slices (arm64,
    /// arm64e, x86_64) share a container and only one corresponds to the loaded image.
    ///
    /// Returns nil when `data` does not begin with a fat magic (a thin Mach-O or anything
    /// else; the caller parses it directly). Beyond the loader's bounds checks (table within
    /// the file, every slice range inside the file without overflow, bounded count), this
    /// rejects: a slice overlapping the fat header/architecture table, two slices whose byte
    /// ranges overlap, an alignment exponent above `maximumFatSliceAlignmentExponent` or a
    /// slice offset not a multiple of its declared alignment, and two slices with the same
    /// CPU type + subtype (capability bits masked) — lipo never emits any of these, and each
    /// would make "the slice for this architecture/UUID" ambiguous or alias foreign bytes.
    /// The general loader path (`parse`) is intentionally unchanged.
    func strictUniversalSlices(in data: Data) throws -> [MachOUniversalSlice]? {
        guard data.count >= 4 else { return nil }
        let magic = try data.readUInt32BE(at: 0, context: "magic")
        let is64Bit: Bool
        switch magic {
        case MachOConstants.fatMagic: is64Bit = false
        case MachOConstants.fatMagic64: is64Bit = true
        default: return nil
        }
        let table = try fatSliceTable(in: data, is64Bit: is64Bit)
        let tableEnd = 8 + table.metadata.count * (is64Bit ? 32 : 20)

        var seenArchitectures = Set<FatArchitectureKey>()
        for slice in table.metadata {
            guard slice.offset >= UInt64(tableEnd) else {
                throw MachOParserError.invalidUniversalBinary("slice \(slice.index) overlaps the fat header")
            }
            guard slice.alignment <= MachORecoveryLimits.maximumFatSliceAlignmentExponent else {
                throw MachOParserError.invalidUniversalBinary(
                    "slice \(slice.index) alignment 2^\(slice.alignment) exceeds the supported maximum"
                )
            }
            let alignmentMask = (UInt64(1) << UInt64(slice.alignment)) - 1
            guard slice.offset & alignmentMask == 0 else {
                throw MachOParserError.invalidUniversalBinary(
                    "slice \(slice.index) offset is not aligned to 2^\(slice.alignment)"
                )
            }
            let key = FatArchitectureKey(
                cpuType: slice.cpuType,
                cpuSubtype: slice.cpuSubtype & ~MachOConstants.cpuSubtypeCapabilityMask
            )
            guard seenArchitectures.insert(key).inserted else {
                throw MachOParserError.invalidUniversalBinary(
                    "slice \(slice.index) duplicates the architecture of an earlier slice"
                )
            }
        }

        // Ranges were validated in-file and non-overflowing by `fatSliceTable`.
        let ordered = table.parsed.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (previous, next) in zip(ordered, ordered.dropFirst())
        where next.range.lowerBound < previous.range.upperBound {
            throw MachOParserError.invalidUniversalBinary(
                "slices \(previous.index) and \(next.index) overlap"
            )
        }
        return table.metadata
    }

    private func fatSliceTable(
        in data: Data,
        is64Bit: Bool
    ) throws -> (metadata: [MachOUniversalSlice], parsed: [ParsedFatSlice]) {
        let architectureCount = try data.readUInt32BE(at: 4, context: "fat architecture count")
        let recordSize = is64Bit ? 32 : 20
        let architectureCountInt = Int(architectureCount)

        guard architectureCountInt > 0 else {
            throw MachOParserError.missingARM64Slice
        }
        guard architectureCountInt <= MachORecoveryLimits.maximumFatArchitectures else {
            throw MachOParserError.invalidUniversalBinary("architecture count exceeds the bounded parser limit")
        }
        // Overflow-safe "table fits in the file" check. The count is already capped
        // at 32 and recordSize <= 32, so 8 + count*recordSize cannot overflow Int —
        // avoids the `data.count - 8` signed subtraction that would go negative for a
        // pathologically short buffer.
        guard 8 &+ architectureCountInt &* recordSize <= data.count else {
            throw MachOParserError.invalidUniversalBinary("architecture table extends beyond the file")
        }

        var metadataSlices: [MachOUniversalSlice] = []
        // Each slice's validated byte range, parallel to `metadataSlices` by index, so
        // the chosen slice (from `MachOSliceSelector`) maps back to the bytes to parse.
        var parsedSlices: [ParsedFatSlice] = []

        for index in 0..<architectureCountInt {
            let offset = 8 + index * recordSize
            let cpuType = try data.readInt32BE(at: offset, context: "fat CPU type")
            let cpuSubtype = try data.readInt32BE(at: offset + 4, context: "fat CPU subtype")
            let sliceOffset: UInt64
            let sliceSize: UInt64
            let alignment: UInt32

            if is64Bit {
                sliceOffset = try data.readUInt64BE(at: offset + 8, context: "fat64 slice offset")
                sliceSize = try data.readUInt64BE(at: offset + 16, context: "fat64 slice size")
                alignment = try data.readUInt32BE(at: offset + 24, context: "fat64 slice alignment")
            } else {
                sliceOffset = UInt64(try data.readUInt32BE(at: offset + 8, context: "fat slice offset"))
                sliceSize = UInt64(try data.readUInt32BE(at: offset + 12, context: "fat slice size"))
                alignment = try data.readUInt32BE(at: offset + 16, context: "fat slice alignment")
            }

            metadataSlices.append(MachOUniversalSlice(
                index: index,
                cpuType: cpuType,
                cpuSubtype: cpuSubtype,
                offset: sliceOffset,
                size: sliceSize,
                alignment: alignment
            ))

            guard sliceOffset <= UInt64(Int.max), sliceSize <= UInt64(Int.max) else {
                throw MachOParserError.invalidUniversalBinary("slice \(index) range is too large for this host")
            }
            guard sliceOffset <= UInt64(Int.max) - sliceSize else {
                throw MachOParserError.invalidUniversalBinary("slice \(index) range overflows")
            }
            let start = Int(sliceOffset)
            let end = start + Int(sliceSize)
            guard sliceSize > 0, start >= 0, end <= data.count else {
                throw MachOParserError.invalidUniversalBinary("slice \(index) range points outside the file")
            }

            parsedSlices.append(ParsedFatSlice(index: index, range: start..<end, offset: sliceOffset))
        }
        return (metadataSlices, parsedSlices)
    }

    private func selectedFatSlice(
        in data: Data,
        is64Bit: Bool,
        requestedSliceIndex: Int?
    ) throws -> FatSliceSelection {
        let (metadataSlices, parsedSlices) = try fatSliceTable(in: data, is64Bit: is64Bit)

        // Selection rule lives in the pure `MachOSliceSelector` (host arm64 → x86_64 →
        // first, unless the caller named an explicit, in-range index). An out-of-range
        // request is a hard error so a stale pick never silently loads another arch.
        let selectedIndex: Int
        do {
            selectedIndex = try MachOSliceSelector.selectedIndex(
                in: metadataSlices,
                requestedIndex: requestedSliceIndex
            )
        } catch MachOSliceSelector.SelectionError.requestedIndexOutOfRange(let badIndex) {
            throw MachOParserError.invalidUniversalBinary("requested slice index \(badIndex) is out of range")
        } catch MachOSliceSelector.SelectionError.noSlices {
            throw MachOParserError.missingARM64Slice
        }

        guard let selectedSlice = parsedSlices.first(where: { $0.index == selectedIndex }) else {
            throw MachOParserError.invalidUniversalBinary("selected slice index \(selectedIndex) is out of range")
        }
        let universalBinary = MachOUniversalBinary(
            is64Bit: is64Bit,
            slices: metadataSlices,
            selectedSliceIndex: selectedSlice.index
        )
        return FatSliceSelection(slice: selectedSlice, universalBinary: universalBinary)
    }
}

enum MachORecoveryLimits {
    static let maximumFatArchitectures = 32
    /// Largest fat slice alignment exponent accepted by the strict (UUID-directed) enumerator;
    /// matches cctools' MAXSECTALIGN (2^15). Real arm64 slices use 2^14.
    static let maximumFatSliceAlignmentExponent: UInt32 = 15
    static let maximumSymbols = 20_000
    static let maximumExports = 2_000
    static let maximumExportTrieNodes = 4_096
    static let maximumPendingExportTrieEntries = 65_536
    static let maximumExportTriePrefixBytes = 64 * 1_024 * 1_024
    static let maximumStringLiterals = 5_000
    static let maximumStringLiteralLength = 4_096
    static let maximumMetadataStrings = 5_000
    /// Each reference is an 8-byte slot already bounded by its section's file range; the cap only
    /// guards model amplification. AppKit-scale images carry tens of thousands of selrefs.
    static let maximumObjectiveCReferences = 1_000_000
    // Each entry costs at least one payload byte, bounding work by command data size; large Swift images exceed 50,000.
    static let maximumFunctionStarts = 1_000_000
    static let maximumDataInCodeEntries = 50_000
    static let maximumIndirectSymbols = 50_000
    static let maximumRelocations = 50_000
    /// Aggregate cap on parsed `MachOSection` records across all segments. Bounds the model
    /// amplification a crafted-but-structurally-valid large `LC_SEGMENT_64` (huge `nsects`) could
    /// otherwise drive — 64Ki is far above any real binary (typically tens of sections).
    static let maximumSections = 65_536
    static let maximumExceptionMetadataSections = 128
    static let maximumExceptionMetadataEntries = 50_000
    static let maximumUnwindInfoHeaderCount: UInt32 = 50_000
    static let maximumCodeSignatureBlobs = 256
    static let maximumCodeSignatureStringLength = 1_024
    static let maximumEntitlementsPayloadBytes = 262_144
    static let maximumEntitlementKeys = 256
}

/// Counts all admitted prefixes, including ones already popped, so traversal also bounds
/// cumulative copying and names retained by recovered exports. Root offset zero is reserved.
struct MachOExportTrieBudget {
    let maximumPendingEntries: Int
    let maximumPrefixBytes: Int
    private var scheduledOffsets: Set<Int> = [0]
    private var allocatedPrefixBytes = 0

    init(
        maximumPendingEntries: Int = MachORecoveryLimits.maximumPendingExportTrieEntries,
        maximumPrefixBytes: Int = MachORecoveryLimits.maximumExportTriePrefixBytes
    ) {
        self.maximumPendingEntries = maximumPendingEntries
        self.maximumPrefixBytes = maximumPrefixBytes
    }

    mutating func reserve(
        relativeOffset: Int, pendingEntryCount: Int, parentPrefixByteCount: Int,
        edgeByteCount: Int, commandIndex: Int
    ) throws -> Int? {
        guard !scheduledOffsets.contains(relativeOffset) else { return nil }
        guard pendingEntryCount < maximumPendingEntries else {
            throw MachOParserError.invalidLoadCommand(
                index: commandIndex, reason: "export trie pending entry budget exceeded"
            )
        }
        let remainingPrefixBytes = maximumPrefixBytes - allocatedPrefixBytes
        guard parentPrefixByteCount >= 0, edgeByteCount >= 0,
              parentPrefixByteCount <= remainingPrefixBytes,
              edgeByteCount <= remainingPrefixBytes - parentPrefixByteCount else {
            throw MachOParserError.invalidLoadCommand(
                index: commandIndex, reason: "export trie aggregate prefix byte budget exceeded"
            )
        }
        let prefixByteCount = parentPrefixByteCount + edgeByteCount
        allocatedPrefixBytes += prefixByteCount
        scheduledOffsets.insert(relativeOffset)
        return prefixByteCount
    }
}

private struct ObjectiveCMetadataDescriptor {
    var kind: String
    var entrySize: Int?
    var stringRole: ObjectiveCStringRole?
    var referenceRole: ObjectiveCReferenceRole?

    init(
        kind: String,
        entrySize: Int?,
        stringRole: ObjectiveCStringRole? = nil,
        referenceRole: ObjectiveCReferenceRole? = nil
    ) {
        self.kind = kind
        self.entrySize = entrySize
        self.stringRole = stringRole
        self.referenceRole = referenceRole
    }
}

private enum ObjectiveCStringRole {
    case selectors
    case classNames
    case methodTypes
}

private enum ObjectiveCReferenceRole {
    case selectors
    case classes
    case superclasses

    var kind: String {
        switch self {
        case .selectors:
            "selector"
        case .classes:
            "class"
        case .superclasses:
            "superclass"
        }
    }
}

private struct FatSliceSelection {
    var slice: ParsedFatSlice
    var universalBinary: MachOUniversalBinary
}

private struct FatArchitectureKey: Hashable {
    var cpuType: Int32
    var cpuSubtype: Int32
}

private struct ParsedFatSlice {
    var index: Int
    var range: Range<Int>
    var offset: UInt64
}

private struct MachOLinkeditDataCommand {
    var index: Int
    var dataOffset: UInt32
    var dataSize: UInt32
}

private struct MachOSymtabCommand {
    var index: Int
    var symbolOffset: UInt32
    var symbolCount: UInt32
    var stringOffset: UInt32
    var stringSize: UInt32
}

struct MachODysymtabCommand {
    var index: Int
    var localSymbolIndex: UInt32
    var localSymbolCount: UInt32
    var externalDefinedSymbolIndex: UInt32
    var externalDefinedSymbolCount: UInt32
    var undefinedSymbolIndex: UInt32
    var undefinedSymbolCount: UInt32
    var indirectSymbolOffset: UInt32
    var indirectSymbolCount: UInt32

    func containsExternalDefinedSymbol(_ index: Int) -> Bool {
        contains(index, start: externalDefinedSymbolIndex, count: externalDefinedSymbolCount)
    }

    func containsUndefinedSymbol(_ index: Int) -> Bool {
        contains(index, start: undefinedSymbolIndex, count: undefinedSymbolCount)
    }

    private func contains(_ index: Int, start: UInt32, count: UInt32) -> Bool {
        let lowerBound = Int(start)
        let upperBound = lowerBound + Int(count)
        return index >= lowerBound && index < upperBound
    }
}

private struct MachODyldInfoCommand {
    var index: Int
    var rebaseOffset: UInt32
    var rebaseSize: UInt32
    var bindOffset: UInt32
    var bindSize: UInt32
    var exportOffset: UInt32
    var exportSize: UInt32
}

private extension Data {
    subscript(range: Range<Int>) -> Data {
        subdata(in: range)
    }

    func readUInt8(at offset: Int, context: String) throws -> UInt8 {
        guard offset >= 0, offset + 1 <= count else {
            throw MachOParserError.truncated(context)
        }
        return self[offset]
    }

    func readUInt16LE(at offset: Int, context: String) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw MachOParserError.truncated(context)
        }
        return UInt16(self[offset])
            | UInt16(self[offset + 1]) << 8
    }

    func readUInt32LE(at offset: Int, context: String) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw MachOParserError.truncated(context)
        }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func readUInt32BE(at offset: Int, context: String) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw MachOParserError.truncated(context)
        }
        return UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }

    func readInt32LE(at offset: Int, context: String) throws -> Int32 {
        Int32(bitPattern: try readUInt32LE(at: offset, context: context))
    }

    func readInt32BE(at offset: Int, context: String) throws -> Int32 {
        Int32(bitPattern: try readUInt32BE(at: offset, context: context))
    }

    func readUInt64LE(at offset: Int, context: String) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= count else {
            throw MachOParserError.truncated(context)
        }
        // A loop instead of one eight-term shift/OR expression, which exceeds the type checker's budget.
        var value: UInt64 = 0
        for index in (0..<8).reversed() { value = value << 8 | UInt64(self[offset + index]) }
        return value
    }

    func readUInt64BE(at offset: Int, context: String) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= count else {
            throw MachOParserError.truncated(context)
        }
        var value: UInt64 = 0
        for index in 0..<8 { value = value << 8 | UInt64(self[offset + index]) }
        return value
    }

    func fixedCString(at offset: Int, length: Int) -> String {
        guard offset >= 0, offset + length <= count else { return "" }
        let bytes = self[offset..<(offset + length)]
        let terminator = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<terminator], as: UTF8.self)
    }

    func cString(at offset: Int, maxLength: Int) -> String {
        guard offset >= 0, maxLength >= 0, offset + maxLength <= count else { return "" }
        let bytes = self[offset..<(offset + maxLength)]
        let terminator = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<terminator], as: UTF8.self)
    }

    func nullTerminatedString(at offset: Int, limit: Int) -> (value: String, nextOffset: Int)? {
        guard offset >= 0, offset <= limit, limit <= count else { return nil }
        var cursor = offset
        while cursor < limit, self[cursor] != 0 {
            cursor += 1
        }
        guard cursor < limit else { return nil }
        let bytes = self[offset..<cursor]
        return (String(decoding: bytes, as: UTF8.self), cursor + 1)
    }
}

// MARK: - Declared-loader coverage (independent of best-effort parse output)

/// A certificate for declared loader inventories only. It is NOT an inventory of
/// every possible address use or every function. The ordinary parse is unchanged.
struct MachOFixupCoverage: Sendable {
    enum Refusal: String, Hashable, Sendable, Error {
        case missingDeclaration, ambiguousDeclaration, unsupportedImage, unsupportedLoadCommand
        case malformedLoadCommands, invalidMapping, malformedInventory, walkLimit
        case unsupportedRelocations, legacyDyldFixups, unsupportedFixup, ambiguousBind
        case skippedSymbol, unsupportedExport, incompleteFunctionStarts, incompleteDataInCode
    }
    var refusalReasons: Set<Refusal> = []
    var fixupRefusalReasons: Set<Refusal> = [.missingDeclaration]
    var symbolInventoryRefusalReasons: Set<Refusal> = [.missingDeclaration]
    var exportInventoryRefusalReasons: Set<Refusal> = [.missingDeclaration]
    var functionStartsInventoryRefusalReasons: Set<Refusal> = [.missingDeclaration]
    var dataInCodeInventoryRefusalReasons: Set<Refusal> = [.missingDeclaration]
    var decodedChainedFixupCount = 0
    var declaredSymbolCount = 0
    var decodedSymbolCount = 0
    var visitedExportTrieNodeCount = 0
    var decodedFunctionStartCount = 0
    var declaredDataInCodeCount = 0
    var decodedDataInCodeCount = 0
    var isComplete: Bool { refusalReasons.isEmpty && fixupRefusalReasons.isEmpty }
    var symbolInventoryIsComplete: Bool { refusalReasons.isEmpty && symbolInventoryRefusalReasons.isEmpty }
    var exportInventoryIsComplete: Bool { refusalReasons.isEmpty && exportInventoryRefusalReasons.isEmpty }
    var functionStartsInventoryIsComplete: Bool { refusalReasons.isEmpty && functionStartsInventoryRefusalReasons.isEmpty }
    var dataInCodeInventoryIsComplete: Bool { refusalReasons.isEmpty && dataInCodeInventoryRefusalReasons.isEmpty }
}

extension MachOParser {
    /// Reuses the shipped decoded results, then audits their declared coverage.
    /// No target is synthesized by the auditor and no ordinary parse result changes.
    func parseWithFixupCoverage(_ data: Data, options: MachOParseOptions = .default,
                               objcCache: MachOObjCCacheContext? = nil) throws
        -> (file: MachOFile, coverage: MachOFixupCoverage) {
        let file = try parse(data, options: options, objcCache: objcCache)
        var coverage = MachOFixupCoverage()
        guard file.universalBinary == nil, file.selectedSliceOffset == 0, objcCache == nil else {
            coverage.refusalReasons.insert(.unsupportedImage)
            return (file, coverage)
        }
        do { try auditLoaderLayout(data, file: file) }
        catch {
            coverage.refusalReasons.insert((error as? MachOFixupCoverage.Refusal) ?? .malformedLoadCommands)
            return (file, coverage)
        }
        do {
            try auditFixupInventory(data, file: file)
            coverage.fixupRefusalReasons = []
        } catch { coverage.fixupRefusalReasons = [(error as? MachOFixupCoverage.Refusal) ?? .malformedInventory] }
        coverage.decodedChainedFixupCount = file.dyldChainedFixups?.fixups.count ?? 0
        do {
            coverage.declaredSymbolCount = try auditSymbolInventory(data, file: file)
            coverage.symbolInventoryRefusalReasons = []
        } catch { coverage.symbolInventoryRefusalReasons = [(error as? MachOFixupCoverage.Refusal) ?? .malformedInventory] }
        coverage.decodedSymbolCount = file.symbols.count
        do {
            coverage.visitedExportTrieNodeCount = try auditExportInventory(data, file: file)
            coverage.exportInventoryRefusalReasons = []
        } catch { coverage.exportInventoryRefusalReasons = [(error as? MachOFixupCoverage.Refusal) ?? .malformedInventory] }
        do {
            try auditFunctionStartInventory(data, file: file)
            coverage.functionStartsInventoryRefusalReasons = []
        } catch { coverage.functionStartsInventoryRefusalReasons = [(error as? MachOFixupCoverage.Refusal) ?? .incompleteFunctionStarts] }
        coverage.decodedFunctionStartCount = file.functionStarts.count
        do {
            coverage.declaredDataInCodeCount = try auditDataInCodeInventory(data, file: file)
            coverage.dataInCodeInventoryRefusalReasons = []
        } catch { coverage.dataInCodeInventoryRefusalReasons = [(error as? MachOFixupCoverage.Refusal) ?? .incompleteDataInCode] }
        coverage.decodedDataInCodeCount = file.dataInCodeEntries.count
        return (file, coverage)
    }

    private func auditCommand(_ kinds: Set<UInt32>, file: MachOFile) throws -> MachOLoadCommand {
        let commands = file.loadCommands.filter { kinds.contains($0.command) }
        guard !commands.isEmpty else { throw MachOFixupCoverage.Refusal.missingDeclaration }
        guard commands.count == 1 else { throw MachOFixupCoverage.Refusal.ambiguousDeclaration }
        return commands[0]
    }
    private func auditPayload(_ data: Data, command: MachOLoadCommand) throws -> Range<Int> {
        guard command.commandSize >= 16 else { throw MachOFixupCoverage.Refusal.malformedInventory }
        let start = Int(try data.readUInt32LE(at: Int(command.offset) + 8, context: "coverage payload"))
        let count = Int(try data.readUInt32LE(at: Int(command.offset) + 12, context: "coverage size"))
        guard start <= data.count, count <= data.count - start else { throw MachOFixupCoverage.Refusal.malformedInventory }
        return start..<(start + count)
    }
    private func auditULEB(_ data: Data, cursor: inout Int, end: Int) throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard cursor < end else { throw MachOFixupCoverage.Refusal.malformedInventory }
            let byte = data[cursor]; cursor += 1
            guard index != 9 || byte & 0xfe == 0 else { throw MachOFixupCoverage.Refusal.malformedInventory }
            result |= UInt64(byte & 0x7f) << (index * 7)
            if byte & 0x80 == 0 { return result }
        }
        throw MachOFixupCoverage.Refusal.malformedInventory
    }
    private func auditCString(_ data: Data, cursor: inout Int, end: Int) throws -> String {
        let start = cursor
        while cursor < end, data[cursor] != 0 { cursor += 1 }
        guard cursor < end, let value = String(data: data.subdata(in: start..<cursor), encoding: .utf8) else {
            throw MachOFixupCoverage.Refusal.malformedInventory
        }
        cursor += 1
        return value
    }
    private func auditLoaderLayout(_ data: Data, file: MachOFile) throws {
        guard file.header.cpuType == MachOConstants.cpuTypeARM64,
              [UInt32(2), 6, 8].contains(file.header.fileType),
              !file.encryptionInfos.contains(where: \.isActive) else { throw MachOFixupCoverage.Refusal.unsupportedImage }
        let allowed: Set<UInt32> = [2, 0xb, 0xc, 0xd, 0x19, 0x1b, 0x1d, 0x21, 0x22, 0x24, 0x25,
            0x26, 0x29, 0x2a, 0x2c, 0x2f, 0x30, 0x32, 0x80000018, 0x8000001c,
            0x8000001f, 0x80000022, 0x80000023, 0x80000028, 0x80000033, 0x80000034]
        guard file.loadCommands.allSatisfy({ allowed.contains($0.command) }) else {
            throw MachOFixupCoverage.Refusal.unsupportedLoadCommand
        }
        guard file.loadCommands.count == Int(file.header.loadCommandCount),
              file.loadCommands.reduce(UInt64(0), { $0 + UInt64($1.commandSize) }) == UInt64(file.header.loadCommandsSize),
              UInt64(file.header.loadCommandsSize) + 32 <= UInt64(data.count),
              file.loadCommands.allSatisfy({ $0.commandSize % 8 == 0 }) else {
            throw MachOFixupCoverage.Refusal.malformedLoadCommands
        }
        var vm: [Range<UInt64>] = [], disk: [Range<UInt64>] = []
        // SG_READ_ONLY changes permissions after fixups, not the file/VM map.
        // Mapping-changing, protected and unknown segment flags remain unsupported.
        let supportedSegmentFlags: UInt32 = 0x10
        for segment in file.segments {
            guard segment.vmSize <= UInt64.max - segment.vmAddress,
                  segment.fileOffset <= UInt64(data.count), segment.fileSize <= UInt64(data.count) - segment.fileOffset,
                  segment.fileSize <= segment.vmSize, segment.flags & ~supportedSegmentFlags == 0,
                  segment.initialProtection & ~7 == 0 else { throw MachOFixupCoverage.Refusal.invalidMapping }
            let span = segment.vmAddress..<(segment.vmAddress + segment.vmSize)
            let stored = segment.fileOffset..<(segment.fileOffset + segment.fileSize)
            guard !vm.contains(where: { $0.overlaps(span) }), !disk.contains(where: { $0.overlaps(stored) }) else {
                throw MachOFixupCoverage.Refusal.invalidMapping
            }
            if !span.isEmpty { vm.append(span) }; if !stored.isEmpty { disk.append(stored) }
        }
        var sectionVM: [Range<UInt64>] = [], sectionDisk: [Range<UInt64>] = []
        for section in file.sections where section.size > 0 {
            guard section.size <= UInt64.max - section.address else { throw MachOFixupCoverage.Refusal.invalidMapping }
            let span = section.address..<(section.address + section.size)
            guard !sectionVM.contains(where: { $0.overlaps(span) }) else { throw MachOFixupCoverage.Refusal.invalidMapping }
            sectionVM.append(span)
            let owners = file.segments.filter { segment in
                section.segmentName == segment.name && section.address >= segment.vmAddress
                    && section.address + section.size <= segment.vmAddress + segment.vmSize
            }
            guard owners.count == 1 else { throw MachOFixupCoverage.Refusal.invalidMapping }
            if !section.isZeroFill {
                let offset = UInt64(section.fileOffset), owner = owners[0]
                guard offset >= owner.fileOffset, section.size <= owner.fileSize,
                      offset - owner.fileOffset <= owner.fileSize - section.size,
                      offset - owner.fileOffset == section.address - owner.vmAddress else {
                    throw MachOFixupCoverage.Refusal.invalidMapping
                }
                let stored = offset..<(offset + section.size)
                guard !sectionDisk.contains(where: { $0.overlaps(stored) }) else { throw MachOFixupCoverage.Refusal.invalidMapping }
                sectionDisk.append(stored)
            }
        }
    }

    private func auditSymbolInventory(_ data: Data, file: MachOFile) throws -> Int {
        let command = try auditCommand([2], file: file), at = Int(command.offset)
        guard command.commandSize >= 24 else { throw MachOFixupCoverage.Refusal.malformedInventory }
        let offset = Int(try data.readUInt32LE(at: at + 8, context: "coverage symbols"))
        let count = Int(try data.readUInt32LE(at: at + 12, context: "coverage symbol count"))
        let strings = Int(try data.readUInt32LE(at: at + 16, context: "coverage strings"))
        let size = Int(try data.readUInt32LE(at: at + 20, context: "coverage string size"))
        guard count <= MachORecoveryLimits.maximumSymbols else { throw MachOFixupCoverage.Refusal.walkLimit }
        guard offset <= data.count, count <= (data.count - offset) / 16,
              strings <= data.count, size <= data.count - strings, file.symbols.count == count else {
            throw MachOFixupCoverage.Refusal.skippedSymbol
        }
        for index in 0..<count {
            let entry = offset + index * 16
            let nameOffset = Int(try data.readUInt32LE(at: entry, context: "coverage symbol name"))
            let type = data[entry + 4]
            guard type & 0xe0 == 0, [UInt8(0), 2, 0xe].contains(type & 0xe), nameOffset < size else {
                throw MachOFixupCoverage.Refusal.skippedSymbol
            }
            var cursor = strings + nameOffset
            let name = try auditCString(data, cursor: &cursor, end: strings + size)
            guard !name.isEmpty, file.symbols[index].index == index, file.symbols[index].name == name else {
                throw MachOFixupCoverage.Refusal.skippedSymbol
            }
        }
        return count
    }

    private func auditExportInventory(_ data: Data, file: MachOFile) throws -> Int {
        let command = try auditCommand([0x22, 0x80000022, 0x80000033], file: file)
        let range: Range<Int>
        if command.command == 0x80000033 { range = try auditPayload(data, command: command) }
        else {
            guard command.commandSize >= 48 else { throw MachOFixupCoverage.Refusal.malformedInventory }
            let at = Int(command.offset)
            let start = Int(try data.readUInt32LE(at: at + 40, context: "coverage exports"))
            let count = Int(try data.readUInt32LE(at: at + 44, context: "coverage export size"))
            guard start <= data.count, count <= data.count - start else { throw MachOFixupCoverage.Refusal.malformedInventory }
            range = start..<(start + count)
        }
        guard !range.isEmpty else { throw MachOFixupCoverage.Refusal.missingDeclaration }
        var pending: [(Int, String)] = [(range.lowerBound, "")], seen: Set<Int> = [], spans: [Range<Int>] = []
        var terminals = 0
        while let (start, name) = pending.popLast() {
            guard seen.count < MachORecoveryLimits.maximumExportTrieNodes,
                  terminals < MachORecoveryLimits.maximumExports else { throw MachOFixupCoverage.Refusal.walkLimit }
            guard range.contains(start), seen.insert(start).inserted else { throw MachOFixupCoverage.Refusal.malformedInventory }
            var cursor = start
            let size = try auditULEB(data, cursor: &cursor, end: range.upperBound)
            guard size <= UInt64(range.upperBound - cursor) else { throw MachOFixupCoverage.Refusal.malformedInventory }
            let terminalEnd = cursor + Int(size)
            if size > 0 {
                let flags = try auditULEB(data, cursor: &cursor, end: terminalEnd)
                guard flags & ~UInt64(7) == 0, flags & 3 != 3, !name.isEmpty else {
                    throw MachOFixupCoverage.Refusal.unsupportedExport
                }
                let value = try auditULEB(data, cursor: &cursor, end: terminalEnd)
                let base = flags & 3 == 2 ? 0 : Self.preferredImageBase(segments: file.segments)
                guard value <= UInt64.max - base, cursor == terminalEnd,
                      file.exports.contains(where: { $0.name == name && $0.flags == flags && $0.address == base + value }) else {
                    throw MachOFixupCoverage.Refusal.unsupportedExport
                }
                terminals += 1
            }
            cursor = terminalEnd
            guard cursor < range.upperBound else { throw MachOFixupCoverage.Refusal.malformedInventory }
            let children = Int(data[cursor]); cursor += 1
            for _ in 0..<children {
                let edge = try auditCString(data, cursor: &cursor, end: range.upperBound)
                let offset = try auditULEB(data, cursor: &cursor, end: range.upperBound)
                guard !edge.isEmpty, name.utf8.count + edge.utf8.count <= 4096,
                      offset < UInt64(range.count) else { throw MachOFixupCoverage.Refusal.malformedInventory }
                pending.append((range.lowerBound + Int(offset), name + edge))
            }
            let span = start..<cursor
            guard !spans.contains(where: { $0.overlaps(span) }) else { throw MachOFixupCoverage.Refusal.malformedInventory }
            spans.append(span)
        }
        return seen.count
    }

    private func auditFunctionStartInventory(_ data: Data, file: MachOFile) throws {
        let range = try auditPayload(data, command: auditCommand([0x26], file: file))
        guard !range.isEmpty else { throw MachOFixupCoverage.Refusal.incompleteFunctionStarts }
        var cursor = range.lowerBound, count = 0
        while cursor < range.upperBound {
            let delta = try auditULEB(data, cursor: &cursor, end: range.upperBound)
            if delta == 0 {
                guard data[cursor..<range.upperBound].allSatisfy({ $0 == 0 }), count == file.functionStarts.count else {
                    throw MachOFixupCoverage.Refusal.incompleteFunctionStarts
                }
                return
            }
            count += 1
            guard count <= MachORecoveryLimits.maximumFunctionStarts else { throw MachOFixupCoverage.Refusal.walkLimit }
        }
        throw MachOFixupCoverage.Refusal.incompleteFunctionStarts
    }

    private func auditDataInCodeInventory(_ data: Data, file: MachOFile) throws -> Int {
        let commands = file.loadCommands.filter { $0.command == 0x29 }
        // An absent optional command declares no inline data, not no relative
        // pointers. The caller must still independently account all code bytes.
        if commands.isEmpty { return 0 }
        let range = try auditPayload(data, command: auditCommand([0x29], file: file))
        guard range.count % 8 == 0 else { throw MachOFixupCoverage.Refusal.incompleteDataInCode }
        let count = range.count / 8
        guard count <= MachORecoveryLimits.maximumDataInCodeEntries else { throw MachOFixupCoverage.Refusal.walkLimit }
        guard file.dataInCodeEntries.count == count else { throw MachOFixupCoverage.Refusal.incompleteDataInCode }
        var spans: [Range<UInt64>] = []
        for entry in file.dataInCodeEntries {
            guard (1...5).contains(entry.kind), entry.length > 0 else { throw MachOFixupCoverage.Refusal.incompleteDataInCode }
            let size = UInt64(entry.length), offset = UInt64(entry.fileOffset)
            let owners = file.sections.filter { section in
                section.isExecutableInstructions && !section.isZeroFill && offset >= UInt64(section.fileOffset)
                    && size <= section.size && offset - UInt64(section.fileOffset) <= section.size - size
                    && section.address + (offset - UInt64(section.fileOffset)) == entry.address
            }
            guard owners.count == 1, entry.address <= UInt64.max - size else { throw MachOFixupCoverage.Refusal.incompleteDataInCode }
            let span = entry.address..<(entry.address + size)
            guard !spans.contains(where: { $0.overlaps(span) }) else { throw MachOFixupCoverage.Refusal.incompleteDataInCode }
            spans.append(span)
        }
        return count
    }

    private func auditFixupInventory(_ data: Data, file: MachOFile) throws {
        _ = try auditCommand([0x80000034], file: file)
        guard let fixups = file.dyldChainedFixups, fixups.fixupsVersion == 0,
              fixups.symbolsFormat == 0, [UInt32(1), 2, 3].contains(fixups.importsFormat),
              fixups.diagnostics.isEmpty else { throw MachOFixupCoverage.Refusal.unsupportedFixup }
        guard file.sections.allSatisfy({ $0.relocationCount == 0 }) else { throw MachOFixupCoverage.Refusal.unsupportedRelocations }
        for command in file.loadCommands {
            let at = Int(command.offset)
            if command.command == 0xb {
                guard command.commandSize >= 80,
                      try data.readUInt32LE(at: at + 68, context: "coverage external relocations") == 0,
                      try data.readUInt32LE(at: at + 76, context: "coverage local relocations") == 0 else {
                    throw MachOFixupCoverage.Refusal.unsupportedRelocations
                }
            }
            if command.command == 0x22 || command.command == 0x80000022 {
                guard command.commandSize >= 48 else { throw MachOFixupCoverage.Refusal.malformedInventory }
                for sizeOffset in [12, 20, 28, 36] {
                    guard try data.readUInt32LE(at: at + sizeOffset, context: "coverage legacy fixups") == 0 else {
                        throw MachOFixupCoverage.Refusal.legacyDyldFixups
                    }
                }
            }
        }
        guard fixups.imports.count == Int(fixups.importsCount),
              fixups.imports.count <= MachOConstants.dyldChainedMaxFixups,
              file.header.flags & 0x100 == 0 else { throw MachOFixupCoverage.Refusal.ambiguousBind }
        for item in fixups.imports {
            guard !item.isWeakImport, let ordinal = item.encodedLibraryOrdinal,
                  ordinal > 0, ordinal <= file.dylibs.count, item.addend == 0,
                  file.dylibs[ordinal - 1].command == MachOConstants.loadCommandLoadDylib,
                  file.dylibs[ordinal - 1].useFlags == nil || file.dylibs[ordinal - 1].useFlags == 0,
                  !item.name.isEmpty else {
                throw MachOFixupCoverage.Refusal.ambiguousBind
            }
        }
        let payload = Int(fixups.dataOffset)..<Int(fixups.endOffset)
        guard payload.upperBound <= data.count, payload.count >= 28,
              Int(fixups.startsOffset) >= 28, Int(fixups.startsOffset) <= payload.count - 4 else {
            throw MachOFixupCoverage.Refusal.malformedInventory
        }
        let importWidth = fixups.importsFormat == 1 ? 4 : (fixups.importsFormat == 2 ? 8 : 16)
        guard Int(fixups.importsOffset) >= 28, Int(fixups.importsOffset) <= payload.count,
              Int(fixups.symbolsOffset) >= Int(fixups.importsOffset), Int(fixups.symbolsOffset) <= payload.count,
              Int(fixups.importsCount) <= (Int(fixups.symbolsOffset) - Int(fixups.importsOffset)) / importWidth else {
            throw MachOFixupCoverage.Refusal.malformedInventory
        }
        // The shipped decoder uses replacement UTF-8 for import names. A
        // certificate requires the declared string itself to be well formed.
        for index in fixups.imports.indices {
            let at = payload.lowerBound + Int(fixups.importsOffset) + index * importWidth
            let nameOffset: UInt64
            if fixups.importsFormat == 3 {
                nameOffset = try data.readUInt64LE(at: at, context: "coverage import name") >> 32
            } else {
                nameOffset = UInt64(try data.readUInt32LE(at: at, context: "coverage import name") >> 9)
            }
            let symbols = payload.lowerBound + Int(fixups.symbolsOffset)
            guard nameOffset < UInt64(payload.upperBound - symbols) else { throw MachOFixupCoverage.Refusal.malformedInventory }
            var cursor = symbols + Int(nameOffset)
            guard try auditCString(data, cursor: &cursor, end: payload.upperBound) == fixups.imports[index].name else {
                throw MachOFixupCoverage.Refusal.malformedInventory
            }
        }
        let start = payload.lowerBound + Int(fixups.startsOffset)
        let segmentCount = Int(try data.readUInt32LE(at: start, context: "coverage starts count"))
        guard segmentCount == file.segments.count, segmentCount <= (payload.upperBound - start - 4) / 4,
              start + 4 + segmentCount * 4 <= payload.lowerBound + Int(fixups.importsOffset) else {
            throw MachOFixupCoverage.Refusal.malformedInventory
        }
        let decoded = Dictionary(grouping: fixups.fixups, by: \.fileOffset)
        guard decoded.values.allSatisfy({ $0.count == 1 }) else { throw MachOFixupCoverage.Refusal.malformedInventory }
        var visited: Set<UInt64> = [], metadataSpans: [Range<Int>] = [start..<(start + 4 + segmentCount * 4)]
        let imageBase = Self.preferredImageBase(segments: file.segments)
        for index in 0..<segmentCount {
            let relative = Int(try data.readUInt32LE(at: start + 4 + index * 4, context: "coverage segment starts"))
            if relative == 0 { continue }
            guard relative >= 4 + segmentCount * 4, relative <= payload.upperBound - start - 22 else {
                throw MachOFixupCoverage.Refusal.malformedInventory
            }
            let at = start + relative
            let size = Int(try data.readUInt32LE(at: at, context: "coverage segment size"))
            let pageSize = Int(try data.readUInt16LE(at: at + 4, context: "coverage page size"))
            let format = try data.readUInt16LE(at: at + 6, context: "coverage pointer format")
            let segmentOffset = try data.readUInt64LE(at: at + 8, context: "coverage segment offset")
            let pageCount = Int(try data.readUInt16LE(at: at + 20, context: "coverage page count"))
            let segment = file.segments[index]
            guard [4096, 16384].contains(pageSize), supportedPointerFormat(format), size >= 22 + pageCount * 2,
                  size <= payload.upperBound - at, at + size <= payload.lowerBound + Int(fixups.importsOffset),
                  segment.vmAddress >= imageBase,
                  segmentOffset == segment.vmAddress - imageBase,
                  try data.readUInt32LE(at: at + 16, context: "coverage max pointer") == 0,
                  UInt64(pageCount) == segment.vmSize / UInt64(pageSize) + (segment.vmSize % UInt64(pageSize) == 0 ? 0 : 1) else {
                throw MachOFixupCoverage.Refusal.unsupportedFixup
            }
            let span = at..<(at + size)
            guard !metadataSpans.contains(where: { $0.overlaps(span) }) else { throw MachOFixupCoverage.Refusal.malformedInventory }
            metadataSpans.append(span)
            for page in 0..<pageCount {
                let first = try data.readUInt16LE(at: at + 22 + page * 2, context: "coverage page start")
                if first == 0xffff { continue }
                // Multi starts remain a reported unsupported class, never a partial certificate.
                guard first & 0x8000 == 0, Int(first) < pageSize else { throw MachOFixupCoverage.Refusal.unsupportedFixup }
                let pageOffset = UInt64(page * pageSize)
                guard pageOffset <= segment.fileSize, UInt64(first) <= segment.fileSize - pageOffset else {
                    throw MachOFixupCoverage.Refusal.invalidMapping
                }
                var cursor = segment.fileOffset + pageOffset + UInt64(first), chainCount = 0
                let end = segment.fileOffset + min(segment.fileSize, pageOffset + UInt64(pageSize))
                while true {
                    guard chainCount < MachOConstants.dyldChainedMaxChainLength,
                          visited.count < MachOConstants.dyldChainedMaxFixups else { throw MachOFixupCoverage.Refusal.walkLimit }
                    guard cursor <= end, end - cursor >= 8, cursor <= UInt64(data.count), UInt64(data.count) - cursor >= 8,
                          visited.insert(cursor).inserted, let item = decoded[cursor]?.first,
                          item.pointerFormat == format, item.address == segment.vmAddress + (cursor - segment.fileOffset) else {
                        throw MachOFixupCoverage.Refusal.malformedInventory
                    }
                    chainCount += 1
                    let raw = try data.readUInt64LE(at: Int(cursor), context: "coverage chain link")
                    let arm = pointerFormatIsArm64e(format)
                    let bind = arm ? raw & (1 << 62) != 0 : raw & (1 << 63) != 0
                    if bind {
                        guard item.isBind, item.boundSymbolName != nil, item.boundAddend == 0 else { throw MachOFixupCoverage.Refusal.ambiguousBind }
                        if arm {
                            let ordinalBits = format == MachOConstants.dyldChainedPtrArm64eUserland24 ? 24 : 16
                            guard (raw >> ordinalBits) & ((UInt64(1) << (32 - ordinalBits)) - 1) == 0 else {
                                throw MachOFixupCoverage.Refusal.unsupportedFixup
                            }
                        } else if (raw >> 32) & 0x7ffff != 0 { throw MachOFixupCoverage.Refusal.unsupportedFixup }
                    } else {
                        guard item.isRebase else { throw MachOFixupCoverage.Refusal.unsupportedFixup }
                        // Tagged/high-eight pointers are not ordinary entry-address evidence.
                        if arm {
                            if raw >> 63 == 0, (raw >> 43) & 0xff != 0 { throw MachOFixupCoverage.Refusal.unsupportedFixup }
                        } else if (raw >> 36) & 0x7fff != 0 { throw MachOFixupCoverage.Refusal.unsupportedFixup }
                    }
                    let next = arm ? (raw >> 51) & 0x7ff : (raw >> 51) & 0xfff
                    if next == 0 { break }
                    let delta = next * UInt64(pointerStride(for: format))
                    guard delta >= 8, delta <= end - cursor else { throw MachOFixupCoverage.Refusal.malformedInventory }
                    cursor += delta
                }
            }
        }
        guard visited.count == fixups.fixups.count else { throw MachOFixupCoverage.Refusal.malformedInventory }
    }
}
