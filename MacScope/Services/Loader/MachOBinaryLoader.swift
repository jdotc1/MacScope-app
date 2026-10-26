import CryptoKit
import Foundation

/// The Mach-O implementor of `BinaryLoader`: imports + parses a Mach-O via
/// `MachOImportService`, then projects the format-specific `MachOFile` down to the
/// neutral `LoadedBinary`. All the Mach-O→neutral translation lives here, so the
/// analysis pipeline stays format-agnostic.
struct MachOBinaryLoader: BinaryLoader {
    private let importer: MachOImportService
    /// For a fat/universal binary, the explicit slice index to load (the user's pick
    /// from the open-time loader-options dialog). `nil` applies the default selection
    /// rule (host arm64 → x86_64 → first). Ignored for thin binaries.
    private let requestedSliceIndex: Int?

    init(importer: MachOImportService = MachOImportService(), requestedSliceIndex: Int? = nil) {
        self.importer = importer
        self.requestedSliceIndex = requestedSliceIndex
    }

    func load(at url: URL) throws -> LoadedBinary {
        var options = MachOImportOptions.default
        options.parseOptions.requestedSliceIndex = requestedSliceIndex
        let imported = try importer.importBinary(at: url, options: options)
        return try project(imported)
    }

    /// The same parser and projection as file loading, over the worker's captured image bytes.
    func load(bytes: Data, sourceURL: URL) throws -> LoadedBinary {
        var options = MachOImportOptions.default
        options.parseOptions.requestedSliceIndex = requestedSliceIndex
        return try project(importer.importBinary(bytes: bytes, sourceURL: sourceURL, options: options))
    }

    enum RetainedInputError: Error, Equatable {
        case unverifiedIdentity, sliceExtentMismatch, cpuMismatch, layoutMismatch
    }

    /// Reuses admission evidence for an exact retained thin slice. The URL is
    /// descriptive only. No digest, byte attestation, or identity is minted here.
    func load(retainedBytes: Data, sourceURL: URL, verifiedIdentity: MachOSliceArtifactIdentity,
              layout: MachOPreferredSegmentLayout,
              integrity: MachOSliceArtifactIntegrityState) throws -> LoadedBinary {
        guard integrity == .verified else { throw RetainedInputError.unverifiedIdentity }
        guard retainedBytes.starts(with: [0xcf, 0xfa, 0xed, 0xfe]),
              UInt64(retainedBytes.count) == verifiedIdentity.selectedSliceByteCount else {
            throw RetainedInputError.sliceExtentMismatch
        }
        var options = MachOImportOptions.default
        options.parseOptions.requestedSliceIndex = nil
        let imported = try importer.importBinary(bytes: retainedBytes, sourceURL: sourceURL, options: options)
        return try project(imported, identitySource: .retained(verifiedIdentity, layout, integrity))
    }

    private enum IdentitySource {
        case compute
        case retained(MachOSliceArtifactIdentity, MachOPreferredSegmentLayout, MachOSliceArtifactIntegrityState)
    }

    private func project(_ imported: MachOImportResult,
                         identitySource: IdentitySource = .compute) throws -> LoadedBinary {
        let machO = imported.machO
        let selectedSliceBytes = try Self.selectedSliceBytes(from: imported)
        let selectedSliceFact: MachOSelectedSliceFact?
        let artifact: MachOSliceArtifactReconstruction?
        let identityEffectiveByteRanges: [IdentityEffectiveByteRangeAttestation]
        switch identitySource {
        case .compute:
            selectedSliceFact = try MachOSelectedSliceFact(
                containerKind: machO.universalBinary == nil ? .thin : .universal,
                sliceCount: machO.universalBinary?.slices.count ?? 1,
                selectedSliceIndex: machO.universalBinary?.selectedSliceIndex ?? 0,
                cpuType: machO.header.cpuType, cpuSubtype: machO.header.cpuSubtype)
            artifact = try MachOSliceArtifactReconstructor.reconstructOrMarkUnavailableForAnonymousObject(
                machO: machO, selectedSliceBytes: selectedSliceBytes)
            identityEffectiveByteRanges = Self.identityEffectiveByteRanges(
                in: machO, selectedSliceBytes: selectedSliceBytes, artifact: artifact)
        case let .retained(identity, layout, integrity):
            // A retained thin payload does not establish its original container kind or index.
            selectedSliceFact = nil
            guard integrity == .verified else { throw RetainedInputError.unverifiedIdentity }
            guard machO.selectedSliceOffset == 0, machO.universalBinary == nil,
                  selectedSliceBytes.count == imported.bytes.count,
                  UInt64(selectedSliceBytes.count) == identity.selectedSliceByteCount else {
                throw RetainedInputError.sliceExtentMismatch
            }
            guard machO.header.cpuType == identity.rawCPUType,
                  machO.header.cpuSubtype == identity.rawCPUSubtype else {
                throw RetainedInputError.cpuMismatch
            }
            let parsedLayout = try MachOPreferredSegmentLayout(records: machO.segments.map { segment in
                .init(name: segment.name, preferredVMStart: segment.vmAddress, preferredVMSize: segment.vmSize,
                      sliceRelativeFileOffset: segment.fileOffset, fileSize: segment.fileSize,
                      initialProtections: segment.initialProtection)
            }, selectedSliceByteCount: identity.selectedSliceByteCount)
            guard parsedLayout == layout else { throw RetainedInputError.layoutMismatch }
            artifact = .init(identity: identity, preferredSegmentLayout: layout)
            // Audit does not consume effective-byte attestations. Recomputing them
            // here would hash unchanged input and claim a fresh admission.
            identityEffectiveByteRanges = []
        }

        let metadata = BinaryMetadataSummary(
            uuid: machO.uuid?.stringValue,
            platformName: machO.buildVersion?.platformName ?? machO.legacyMinimumOSVersion?.platformName,
            minimumOSVersion: machO.buildVersion?.minimumOSVersion.stringValue
                ?? machO.legacyMinimumOSVersion?.minimumOSVersion.stringValue,
            sdkVersion: machO.buildVersion?.sdkVersion.stringValue
                ?? machO.legacyMinimumOSVersion?.sdkVersion.stringValue,
            buildTools: machO.buildVersion?.tools.map(\.displayName) ?? []
        )

        let symbols = machO.symbols.map { symbol in
            SymbolSummary(
                id: UUID(),
                name: symbol.name,
                address: symbol.address,
                kind: symbol.kind.rawValue,
                libraryName: symbol.libraryName,
                rawLinkageName: symbol.name
            )
        }
        let imports = machO.imports.map { importedSymbol in
            ImportSummary(
                id: UUID(),
                name: importedSymbol.name,
                libraryName: importedSymbol.libraryName,
                libraryOrdinal: importedSymbol.libraryOrdinal
            )
        }
        let indirectSymbols = machO.indirectSymbols.map { indirectSymbol in
            IndirectSymbolSummary(
                id: UUID(),
                kind: indirectSymbol.kind.rawValue,
                sourceSection: indirectSymbol.sourceSection,
                address: indirectSymbol.address,
                entrySize: indirectSymbol.entrySize,
                tableIndex: indirectSymbol.tableIndex,
                rawSymbolIndex: indirectSymbol.rawSymbolIndex,
                symbolIndex: indirectSymbol.symbolIndex,
                symbolName: indirectSymbol.symbolName,
                libraryOrdinal: indirectSymbol.libraryOrdinal,
                libraryName: indirectSymbol.libraryName,
                isLocal: indirectSymbol.isLocal,
                isAbsolute: indirectSymbol.isAbsolute
            )
        }
        let exports = machO.exports.map { exportedSymbol in
            ExportSummary(
                id: UUID(),
                name: exportedSymbol.name,
                address: exportedSymbol.address,
                source: exportedSymbol.source,
                terminalFlags: exportedSymbol.flags
            )
        }
        let stringLiterals = machO.stringLiterals.map { literal in
            StringLiteralSummary(
                id: UUID(),
                value: literal.value,
                address: literal.address,
                sourceSection: literal.sourceSection,
                byteLength: literal.byteLength
            )
        }

        var objcSelectors: [UInt64: String] = [:]
        for reference in machO.objectiveCMetadata.selectorReferences {
            guard let resolvedName = reference.resolvedName, !resolvedName.isEmpty else { continue }
            objcSelectors[reference.sourceAddress] = resolvedName
        }
        let objcClassReferences = ObjCClassReferenceTarget.projection(
            of: machO.objectiveCMetadata.classReferences + machO.objectiveCMetadata.superclassReferences
        )

        return LoadedBinary(
            name: imported.originalURL.lastPathComponent,
            path: imported.originalURL.path,
            isBundle: imported.isBundle,
            cpuType: machO.header.cpuType,
            cpuSubtype: machO.header.cpuSubtype,
            fileTypeName: machO.fileTypeName,
            architectureDisplayName: machO.architectureDisplayName,
            metadata: metadata,
            machOSelectedSliceFact: selectedSliceFact,
            artifactIdentity: artifact?.identity,
            preferredSegmentLayout: artifact?.preferredSegmentLayout,
            artifactIntegrityState: artifact == nil ? .unavailable : .verified,
            resolvedExecutablePath: imported.executableURL.path,
            bytes: imported.bytes,
            sliceOffset: machO.selectedSliceOffset,
            sliceSize: machO.universalBinary?.selectedSlice?.size,
            sections: machO.sections.map(Self.section),
            executableTextSection: machO.executableTextSection.map(Self.section),
            codeDataRanges: machO.dataInCodeEntries.map(Self.codeDataRange),
            entryPointAddress: machO.entryPointAddress,
            symbols: symbols,
            imports: imports,
            indirectSymbols: indirectSymbols,
            exports: exports,
            stringLiterals: stringLiterals,
            functionStarts: machO.functionStarts.map(\.address),
            objcSelectors: objcSelectors,
            objcClassReferences: objcClassReferences,
            constantCFStrings: ImageConstantStringProvider.cfStrings(
                in: machO, bytes: imported.bytes, sliceOffset: machO.selectedSliceOffset
            ),
            objcClasses: machO.objectiveCMetadata.classes,
            codePointerTargets: Self.codePointerTargets(in: machO),
            objcCategories: machO.objectiveCMetadata.categories,
            objcProtocols: machO.objectiveCMetadata.protocols,
            swiftTypes: machO.swiftTypes,
            swiftConformances: machO.swiftConformances,
            loaderFindings: machO.loaderFindings.map(Self.loaderFinding),
            machOMetadata: MachOLoadMetadata.from(machO),
            reaNativeImageFacts: REANativeApplicationProjection.sliceFacts(
                path: imported.executableURL.lastPathComponent, machO: machO,
                physicalFileSize: UInt64(imported.bytes.count),
                selectedSliceSize: machO.universalBinary?.selectedSlice?.size).facts,
            relocations: machO.relocations.map { Self.relocation($0, cpuType: machO.header.cpuType) },
            identityEffectiveByteRanges: identityEffectiveByteRanges,
            exceptionMetadataInput: Self.completeActiveEncryptionRanges(
                machO.encryptionInfos, selectedSliceByteCount: UInt64(selectedSliceBytes.count)
            ).map { ranges in
                BinaryExceptionMetadataInput(linkedMachOFileType: machO.header.fileType,
                    encryptedSliceRanges: ranges.map { $0.start..<$0.end })
            }
        )
    }

    private struct RelocationEntryKey: Hashable {
        let segmentName: String
        let sectionName: String
        let entryIndex: Int
        let fileOffset: UInt64
    }

    private struct MutationRange {
        let start: UInt64
        let end: UInt64
    }

    /// Emits readable identity authority only for the immutable, file-backed subset whose complete
    /// mutation evidence is available. Non-executable ranges permit data reads, never code authority.
    /// Chained fixup starts are independently bounded below; affected segments and later ranges
    /// are withheld. Classic dyld streams and dynamic relocation tables expose no patch locations,
    /// so evidence of those mechanisms abstains globally. Section relocations are accepted only
    /// when every declared entry was recovered.
    private static func identityEffectiveByteRanges(
        in machO: MachOFile,
        selectedSliceBytes: Data,
        artifact: MachOSliceArtifactReconstruction?
    ) -> [IdentityEffectiveByteRangeAttestation] {
        guard let artifact,
              let chainedMutationSegments = completeChainedFixupMutationSegments(
                  loadCommands: machO.loadCommands,
                  segments: machO.segments,
                  selectedSliceBytes: selectedSliceBytes
              ),
              hasNoUnlocatedLoaderMutationEvidence(
                  loadCommands: machO.loadCommands,
                  selectedSliceBytes: selectedSliceBytes
              ),
              let encryptedFileRanges = completeActiveEncryptionRanges(
                  machO.encryptionInfos,
                  selectedSliceByteCount: UInt64(selectedSliceBytes.count)
              ),
              let mutationRanges = completeSectionRelocationRanges(
                  sections: machO.sections,
                  relocations: machO.relocations,
                  selectedSliceByteCount: UInt64(selectedSliceBytes.count)
              ) else {
            return []
        }

        let records = artifact.preferredSegmentLayout.records
        guard records.count == machO.segments.count else { return [] }
        var attestations: [IdentityEffectiveByteRangeAttestation] = []
        for (index, record) in records.enumerated() {
            guard chainedMutationSegments.allSatisfy({ mutationIndex in
                guard mutationIndex != index else { return false }
                let mutationRecord = records[mutationIndex]
                let candidateFileEnd = record.sliceRelativeFileOffset.addingReportingOverflow(record.fileSize)
                let candidateVMEnd = record.preferredVMStart.addingReportingOverflow(record.preferredVMSize)
                let mutationFileEnd = mutationRecord.sliceRelativeFileOffset.addingReportingOverflow(mutationRecord.fileSize)
                let mutationVMEnd = mutationRecord.preferredVMStart.addingReportingOverflow(mutationRecord.preferredVMSize)
                guard !candidateFileEnd.overflow, !candidateVMEnd.overflow,
                      !mutationFileEnd.overflow, !mutationVMEnd.overflow else { return false }
                return candidateFileEnd.partialValue <= mutationRecord.sliceRelativeFileOffset
                    && candidateVMEnd.partialValue <= mutationRecord.preferredVMStart
            }) else { continue }
            guard record.fileSize > 0,
                  record.fileSize <= record.preferredVMSize,
                  record.initialProtections & 1 != 0,
                  record.initialProtections & 2 == 0,
                  record.initialProtections & ~7 == 0,
                  machO.segments[index].flags & MachOConstants.segmentFlagProtectedVersion1 == 0 else {
                continue
            }
            let virtualEnd = record.preferredVMStart.addingReportingOverflow(record.fileSize)
            let fileEnd = record.sliceRelativeFileOffset.addingReportingOverflow(record.fileSize)
            guard !virtualEnd.overflow,
                  !fileEnd.overflow,
                  fileEnd.partialValue <= UInt64(selectedSliceBytes.count),
                  !encryptedFileRanges.contains(where: {
                      rangesOverlap(
                          record.sliceRelativeFileOffset,
                          fileEnd.partialValue,
                          $0.start,
                          $0.end
                      )
                  }),
                  !mutationRanges.contains(where: {
                      rangesOverlap(
                          record.preferredVMStart,
                          virtualEnd.partialValue,
                          $0.start,
                          $0.end
                      )
                  }),
                  records.enumerated().allSatisfy({ otherIndex, other in
                      guard otherIndex != index else { return true }
                      let otherVMEnd = other.preferredVMStart.addingReportingOverflow(other.preferredVMSize)
                      let otherFileEnd = other.sliceRelativeFileOffset.addingReportingOverflow(other.fileSize)
                      guard !otherVMEnd.overflow, !otherFileEnd.overflow else { return false }
                      // A file-only record has no virtual extent. Its vmaddr can lie
                      // inside this mapped range without contradicting effective-byte authority.
                      // Its file span remains subject to the independent overlap check below.
                      let virtualOverlap = other.preferredVMSize > 0 && rangesOverlap(
                          record.preferredVMStart,
                          virtualEnd.partialValue,
                          other.preferredVMStart,
                          otherVMEnd.partialValue
                      )
                      let fileOverlap = other.fileSize > 0 && rangesOverlap(
                          record.sliceRelativeFileOffset,
                          fileEnd.partialValue,
                          other.sliceRelativeFileOffset,
                          otherFileEnd.partialValue
                      )
                      return !virtualOverlap && !fileOverlap
                  }),
                  let lower = Int(exactly: record.sliceRelativeFileOffset),
                  let upper = Int(exactly: fileEnd.partialValue) else {
                continue
            }
            let rangeBytes = selectedSliceBytes.subdata(in: lower..<upper)
            guard let attestation = try? IdentityEffectiveByteRangeAttestation(
                artifactIdentity: artifact.identity,
                segmentName: record.name,
                startAddress: record.preferredVMStart,
                endAddressExclusive: virtualEnd.partialValue,
                sliceRelativeFileOffset: record.sliceRelativeFileOffset,
                byteCount: record.fileSize,
                initialProtections: record.initialProtections,
                rawBytesSHA256: sha256Hex(rangeBytes)
            ) else {
                continue
            }
            attestations.append(attestation)
        }
        return attestations.sorted { ($0.startAddress, $0.segmentName) < ($1.startAddress, $1.segmentName) }
    }

    private static func hasNoUnlocatedLoaderMutationEvidence(
        loadCommands: [MachOLoadCommand],
        selectedSliceBytes: Data
    ) -> Bool {
        for command in loadCommands {
            switch command.command {
            case MachOConstants.loadCommandDyldChainedFixups:
                // Independently attested by completeChainedFixupMutationSegments.
                continue
            case MachOConstants.loadCommandDyldInfo, MachOConstants.loadCommandDyldInfoOnly:
                guard command.commandSize >= 48,
                      [8, 12, 16, 20, 24, 28, 32, 36].allSatisfy({ fieldOffset in
                          readUInt32LE(
                              in: selectedSliceBytes,
                              at: command.offset + UInt64(fieldOffset)
                          ) == 0
                      }) else {
                    return false
                }
            case MachOConstants.loadCommandDysymtab:
                guard command.commandSize >= 80,
                      [64, 68, 72, 76].allSatisfy({ fieldOffset in
                          readUInt32LE(
                              in: selectedSliceBytes,
                              at: command.offset + UInt64(fieldOffset)
                          ) == 0
                      }) else {
                    return false
                }
            default:
                continue
            }
        }
        return true
    }

    /// Reads the raw starts-in-image structure independently of the parser's best-effort
    /// fixup walk. A segment is withheld whenever its metadata declares any chain start;
    /// candidates are eligible only if they precede every affected segment in both VM and file
    /// order. This suffix denial also contains malformed forward chain links.
    private static func completeChainedFixupMutationSegments(
        loadCommands: [MachOLoadCommand],
        segments: [MachOSegment],
        selectedSliceBytes: Data
    ) -> Set<Int>? {
        let commands = loadCommands.filter { $0.command == MachOConstants.loadCommandDyldChainedFixups }
        guard commands.count <= 1 else { return nil }
        guard let command = commands.first else { return [] }
        guard command.commandSize >= 16,
              let commandOffset = Int(exactly: command.offset),
              commandOffset >= 0,
              commandOffset <= selectedSliceBytes.count,
              16 <= selectedSliceBytes.count - commandOffset,
              readUInt32LE(in: selectedSliceBytes, at: command.offset) == command.command,
              readUInt32LE(in: selectedSliceBytes, at: command.offset + 4) == command.commandSize else {
            return nil
        }
        guard let dataOffset = readUInt32LE(in: selectedSliceBytes, at: command.offset + 8),
              let dataSize = readUInt32LE(in: selectedSliceBytes, at: command.offset + 12),
              let payloadStart = Int(exactly: dataOffset),
              let payloadSize = Int(exactly: dataSize),
              payloadStart <= selectedSliceBytes.count,
              payloadSize <= selectedSliceBytes.count - payloadStart,
              payloadSize >= 28,
              readUInt32LE(in: selectedSliceBytes, at: UInt64(payloadStart)) == 0 else {
            return nil
        }
        let startsOffset = readUInt32LE(in: selectedSliceBytes, at: UInt64(payloadStart + 4))
        guard let startsOffset, let startsRelative = Int(exactly: startsOffset),
              startsRelative >= 28, startsRelative <= payloadSize,
              4 <= payloadSize - startsRelative else { return nil }
        guard let importsOffset = readUInt32LE(in: selectedSliceBytes, at: UInt64(payloadStart + 8)),
              let symbolsOffset = readUInt32LE(in: selectedSliceBytes, at: UInt64(payloadStart + 12)),
              let importsRelative = Int(exactly: importsOffset),
              let symbolsRelative = Int(exactly: symbolsOffset),
              importsRelative >= startsRelative,
              symbolsRelative >= importsRelative,
              symbolsRelative <= payloadSize else { return nil }
        let starts = payloadStart + startsRelative
        guard let segmentCountRaw = readUInt32LE(in: selectedSliceBytes, at: UInt64(starts)),
              let segmentCount = Int(exactly: segmentCountRaw),
              segmentCount == segments.count,
              segmentCount <= (importsRelative - startsRelative - 4) / 4 else { return nil }
        let startsTableEnd = startsRelative + 4 + segmentCount * 4
        guard importsRelative >= startsTableEnd else { return nil }

        var mutations = Set<Int>()
        var startsRecordRanges: [Range<Int>] = []
        let offsetsStart = starts + 4
        for index in 0..<segmentCount {
            guard let relative = readUInt32LE(
                in: selectedSliceBytes,
                at: UInt64(offsetsStart + index * 4)
            ) else { return nil }
            if relative == 0 { continue }
            guard let relativeInt = Int(exactly: relative),
                  relativeInt >= 4 + segmentCount * 4,
                  relativeInt <= importsRelative - startsRelative,
                  22 <= importsRelative - startsRelative - relativeInt else { return nil }
            let info = starts + relativeInt
            guard let declaredSizeRaw = readUInt32LE(in: selectedSliceBytes, at: UInt64(info)),
                  let declaredSize = Int(exactly: declaredSizeRaw),
                  declaredSize >= 22,
                  declaredSize <= importsRelative - startsRelative - relativeInt,
                  let pageSize = readUInt16LE(in: selectedSliceBytes, at: UInt64(info + 4)),
                  [0x1000, 0x4000].contains(pageSize),
                  let pointerFormat = readUInt16LE(in: selectedSliceBytes, at: UInt64(info + 6)),
                  [MachOConstants.dyldChainedPtr64, MachOConstants.dyldChainedPtr64Offset,
                   MachOConstants.dyldChainedPtrArm64e, MachOConstants.dyldChainedPtrArm64eUserland,
                   MachOConstants.dyldChainedPtrArm64eUserland24].contains(pointerFormat),
                  let segmentOffset = readUInt64LE(in: selectedSliceBytes, at: UInt64(info + 8)),
                  let pageCount = readUInt16LE(in: selectedSliceBytes, at: UInt64(info + 20)) else {
                return nil
            }
            let segment = segments[index]
            let imageBase = segments.first(where: { $0.name == "__TEXT" })?.vmAddress
                ?? segments.filter { $0.fileSize > 0 }.map(\.vmAddress).min() ?? 0
            guard segment.vmAddress >= imageBase,
                  segmentOffset == segment.vmAddress - imageBase else { return nil }
            let segmentVMEnd = segment.vmAddress.addingReportingOverflow(segment.vmSize)
            let segmentFileEnd = segment.fileOffset.addingReportingOverflow(segment.fileSize)
            guard !segmentVMEnd.overflow, !segmentFileEnd.overflow,
                  segmentFileEnd.partialValue <= UInt64(selectedSliceBytes.count),
                  pageCount == 0 || UInt64(pageCount - 1) * UInt64(pageSize) < segment.vmSize else {
                return nil
            }
            let pageArrayBytes = Int(pageCount) * 2
            guard declaredSize == 22 + pageArrayBytes else { return nil }
            let recordRange = relativeInt..<(relativeInt + declaredSize)
            guard startsRecordRanges.allSatisfy({ !recordRange.overlaps($0) }) else { return nil }
            startsRecordRanges.append(recordRange)
            // MULTI page starts require parsing an overflow array. This narrow attestor
            // deliberately rejects them rather than infer segment coverage from a prefix.
            for page in 0..<Int(pageCount) {
                guard let start = readUInt16LE(
                    in: selectedSliceBytes,
                    at: UInt64(info + 22 + page * 2)
                ), start == MachOConstants.dyldChainedPtrStartNone || start & 0x8000 == 0 else {
                    return nil
                }
                if start != MachOConstants.dyldChainedPtrStartNone {
                    let pointerWidth: UInt64 = 8
                    let pageOffset = UInt64(page) * UInt64(pageSize)
                    let startOffset = pageOffset.addingReportingOverflow(UInt64(start))
                    let wordEnd = startOffset.partialValue.addingReportingOverflow(pointerWidth)
                    let stride: UInt64 = pointerFormat == MachOConstants.dyldChainedPtr64
                        || pointerFormat == MachOConstants.dyldChainedPtr64Offset ? 4 : 8
                    guard !startOffset.overflow, !wordEnd.overflow,
                          UInt64(start) + pointerWidth <= UInt64(pageSize),
                          UInt64(start) < UInt64(pageSize),
                          UInt64(start) % stride == 0,
                          wordEnd.partialValue <= segment.vmSize,
                          wordEnd.partialValue <= segment.fileSize else { return nil }
                    mutations.insert(index)
                }
            }
        }
        return mutations
    }

    /// Produces exact active encryption file ranges. Any active declaration whose range cannot be
    /// proven complete invalidates identity authority globally rather than being treated as empty.
    private static func completeActiveEncryptionRanges(
        _ encryptionInfos: [MachOEncryptionInfo],
        selectedSliceByteCount: UInt64
    ) -> [MutationRange]? {
        var ranges: [MutationRange] = []
        for encryptionInfo in encryptionInfos where encryptionInfo.isActive {
            let start = UInt64(encryptionInfo.cryptOffset)
            let end = start.addingReportingOverflow(UInt64(encryptionInfo.cryptSize))
            guard encryptionInfo.cryptSize > 0,
                  !end.overflow,
                  end.partialValue <= selectedSliceByteCount else {
                return nil
            }
            ranges.append(MutationRange(start: start, end: end.partialValue))
        }
        return ranges
    }

    private static func completeSectionRelocationRanges(
        sections: [MachOSection],
        relocations: [MachORelocation],
        selectedSliceByteCount: UInt64
    ) -> [MutationRange]? {
        var expectedEntries = Set<RelocationEntryKey>()
        var declaredCount = 0
        for section in sections where section.relocationCount > 0 {
            let nextDeclaredCount = declaredCount.addingReportingOverflow(Int(section.relocationCount))
            guard !nextDeclaredCount.overflow,
                  nextDeclaredCount.partialValue <= relocations.count else {
                // The parser caps recovery; never enumerate a declared table beyond what it proved.
                return nil
            }
            let tableStart = UInt64(section.relocationOffset)
            let tableByteCount = UInt64(section.relocationCount) * 8
            let tableEnd = tableStart.addingReportingOverflow(tableByteCount)
            guard !tableEnd.overflow, tableEnd.partialValue <= selectedSliceByteCount else { return nil }
            for entryIndex in 0..<Int(section.relocationCount) {
                let fileOffset = tableStart + UInt64(entryIndex) * 8
                expectedEntries.insert(RelocationEntryKey(
                    segmentName: section.segmentName,
                    sectionName: section.sectionName,
                    entryIndex: entryIndex,
                    fileOffset: fileOffset
                ))
            }
            declaredCount = nextDeclaredCount.partialValue
        }
        guard declaredCount == expectedEntries.count,
              declaredCount == relocations.count else {
            return nil
        }
        let actualEntries = Set(relocations.map {
            RelocationEntryKey(
                segmentName: $0.segmentName,
                sectionName: $0.sectionName,
                entryIndex: $0.entryIndex,
                fileOffset: $0.fileOffset
            )
        })
        guard actualEntries == expectedEntries else { return nil }

        var ranges: [MutationRange] = []
        for relocation in relocations {
            guard !relocation.isScattered,
                  let start = relocation.resolvedAddress else {
                return nil
            }
            let end = start.addingReportingOverflow(UInt64(relocation.widthInBytes))
            guard relocation.widthInBytes > 0, !end.overflow else { return nil }
            ranges.append(MutationRange(start: start, end: end.partialValue))
        }
        return ranges
    }

    private static func readUInt32LE(in data: Data, at offset: UInt64) -> UInt32? {
        guard let lower = Int(exactly: offset), lower >= 0, lower <= data.count - 4 else { return nil }
        return data[lower..<(lower + 4)].enumerated().reduce(into: UInt32(0)) { value, pair in
            value |= UInt32(pair.element) << UInt32(pair.offset * 8)
        }
    }

    private static func readUInt16LE(in data: Data, at offset: UInt64) -> UInt16? {
        guard let start = Int(exactly: offset), start >= 0, start <= data.count - 2 else { return nil }
        return UInt16(data[start]) | (UInt16(data[start + 1]) << 8)
    }

    private static func readUInt64LE(in data: Data, at offset: UInt64) -> UInt64? {
        guard let start = Int(exactly: offset), start >= 0, start <= data.count - 8 else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 | (UInt64(data[start + $1]) << UInt64($1 * 8)) }
    }

    private static func rangesOverlap(_ firstStart: UInt64, _ firstEnd: UInt64,
                                      _ secondStart: UInt64, _ secondEnd: UInt64) -> Bool {
        firstStart < secondEnd && secondStart < firstEnd
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func selectedSliceBytes(from imported: MachOImportResult) throws -> Data {
        let start = imported.machO.selectedSliceOffset
        let declaredSize = imported.machO.universalBinary?.selectedSlice?.size
            ?? UInt64(imported.bytes.count)
        let end = start.addingReportingOverflow(declaredSize)
        guard !end.overflow,
              start <= UInt64(Int.max),
              end.partialValue <= UInt64(imported.bytes.count),
              let lower = Int(exactly: start),
              let upper = Int(exactly: end.partialValue),
              upper > lower else {
            throw MachOSliceArtifactValidationError.invalidByteCount
        }
        return imported.bytes.subdata(in: lower..<upper)
    }

    /// The rebase/fixup-pointer targets that land inside an executable-text section — pointers
    /// stored in data that reference code (function-pointer tables, vtables, dispatch tables).
    /// These are candidate function starts reached only indirectly. In a position-independent
    /// binary every absolute in-image pointer is a rebase, so this captures the whole set; a
    /// position-dependent binary (or one without chained fixups) yields none.
    private static func codePointerTargets(in machO: MachOFile) -> [UInt64] {
        guard let fixups = machO.dyldChainedFixups else { return [] }
        let executableRanges: [Range<UInt64>] = machO.sections.compactMap { section in
            guard section.isExecutableInstructions, section.size > 0 else { return nil }
            let (end, overflow) = section.address.addingReportingOverflow(section.size)
            return overflow ? nil : section.address ..< end
        }
        guard !executableRanges.isEmpty else { return [] }
        var targets = Set<UInt64>()
        for fixup in fixups.fixups {
            guard let target = fixup.rebaseTargetAddress,
                  executableRanges.contains(where: { $0.contains(target) }) else { continue }
            targets.insert(target)
        }
        return Array(targets)
    }

    /// Projects a typed Mach-O loader finding into the format-neutral diagnostics input.
    static func loaderFinding(_ finding: MachOLoaderFinding) -> LoaderFinding {
        let category: LoaderFinding.Category = if finding.kind.isChainedFixups {
            .unsupportedFixup
        } else if finding.kind == .unwindFunctionStartNotInFunctionStarts {
            .functionStartsDisagreement
        } else if finding.kind.isMetadataParse {
            .metadataParseIssue
        } else {
            .objcMetadataUnavailable
        }
        return LoaderFinding(
            category: category,
            code: finding.kind.rawValue,
            address: finding.address,
            message: finding.message
        )
    }

    private static func section(_ section: MachOSection) -> BinarySection {
        BinarySection(
            name: section.qualifiedName,
            address: section.address,
            size: section.size,
            fileOffset: UInt64(section.fileOffset),
            isExecutable: section.isExecutableInstructions,
            isZeroFill: section.isZeroFill
        )
    }

    private static func codeDataRange(_ entry: MachODataInCodeEntry) -> BinaryCodeDataRange {
        BinaryCodeDataRange(
            address: entry.address,
            size: UInt64(entry.length),
            kind: entry.kindName
        )
    }

    /// Projects a Mach-O relocation onto the format-neutral `RelocationSummary`. The parser already
    /// resolves external symbol names, so those carry through directly.
    private static func relocation(_ reloc: MachORelocation, cpuType: Int32) -> RelocationSummary {
        RelocationSummary(
            id: UUID(),
            address: reloc.resolvedAddress ?? UInt64(reloc.relocationAddress),
            sectionName: reloc.sourceSection,
            typeCode: UInt32(reloc.type),
            typeName: machoRelocationTypeName(reloc.type, cpuType: cpuType),
            symbolName: reloc.symbolName,
            symbolIndex: reloc.symbolNumber,
            addend: nil,
            isPCRelative: reloc.isPCRelative,
            widthInBytes: reloc.widthInBytes
        )
    }
}

/// Best-effort human label for the common arm64 / x86-64 Mach-O relocation types; nil for the long
/// tail. Correctness-over-coverage — only well-known codes.
private func machoRelocationTypeName(_ type: UInt8, cpuType: Int32) -> String? {
    switch cpuType {
    case MachOConstants.cpuTypeARM64:
        switch type {
        case 0: return "ARM64_RELOC_UNSIGNED";            case 1: return "ARM64_RELOC_SUBTRACTOR"
        case 2: return "ARM64_RELOC_BRANCH26";            case 3: return "ARM64_RELOC_PAGE21"
        case 4: return "ARM64_RELOC_PAGEOFF12";           case 5: return "ARM64_RELOC_GOT_LOAD_PAGE21"
        case 6: return "ARM64_RELOC_GOT_LOAD_PAGEOFF12";  case 7: return "ARM64_RELOC_POINTER_TO_GOT"
        case 8: return "ARM64_RELOC_TLVP_LOAD_PAGE21";    case 9: return "ARM64_RELOC_TLVP_LOAD_PAGEOFF12"
        case 10: return "ARM64_RELOC_ADDEND";             default: return nil
        }
    case MachOConstants.cpuTypeX86_64:
        switch type {
        case 0: return "X86_64_RELOC_UNSIGNED";  case 1: return "X86_64_RELOC_SIGNED"
        case 2: return "X86_64_RELOC_BRANCH";    case 3: return "X86_64_RELOC_GOT_LOAD"
        case 4: return "X86_64_RELOC_GOT";       case 5: return "X86_64_RELOC_SUBTRACTOR"
        case 6: return "X86_64_RELOC_SIGNED_1";  case 7: return "X86_64_RELOC_SIGNED_2"
        case 8: return "X86_64_RELOC_SIGNED_4";  case 9: return "X86_64_RELOC_TLV"
        default: return nil
        }
    default:
        return nil
    }
}
