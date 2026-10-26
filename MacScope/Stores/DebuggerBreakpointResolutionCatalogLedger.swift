import Foundation

private struct OwnerEvidence: Sendable {
    let coordinate: DebuggerWorkspaceArtifactCoordinate
    let segments: [DebuggerBreakpointResolutionSegment]
    let staticAddresses: [DebuggerBreakpointStaticAddressEvidence]
    let functions: [DebuggerBreakpointFunctionEvidence]
    let hasCanonicalRawSymbolAuthority: Bool
    let rawSymbols: [DebuggerBreakpointRawSymbolEvidence]
    let hasExactSourceAuthority: Bool
    let sourceRows: [DebuggerBreakpointSourceEvidence]
    let exactDigest: Data

    func owner(revision: UInt64) -> DebuggerBreakpointResolutionOwnerIndex {
        DebuggerBreakpointResolutionOwnerIndex(
            coordinate: coordinate,
            revision: revision,
            segments: segments,
            staticAddresses: staticAddresses,
            functions: functions,
            hasCanonicalRawSymbolAuthority: hasCanonicalRawSymbolAuthority,
            rawSymbols: rawSymbols,
            hasExactSourceAuthority: hasExactSourceAuthority,
            sourceRows: sourceRows
        )
    }

    func hasSameResolverEvidence(as other: Self) -> Bool {
        coordinate == other.coordinate && exactDigest == other.exactDigest
    }
}


@MainActor
/// Store-owned immutable static-evidence ledger for logical-breakpoint resolution. Only exact
/// owner/artifact and resolver-visible analysis evidence participates in its revisions; focus,
/// selection, display-only analysis, and authored logical-breakpoint fields are excluded.
struct DebuggerBreakpointResolutionCatalogLedger {
    private(set) var catalog: DebuggerBreakpointResolutionCatalog
    private(set) var isExhausted = false
    private var evidenceByBinaryID: [UUID: OwnerEvidence]
    private var ownerRevisionByBinaryID: [UUID: UInt64]
    private var ownerHighWaterByBinaryID: [UUID: UInt64]
    private var ownerHighWaterBySlot: [ImageSlot: UInt64]

    init(
        snapshot: WorkspaceSnapshot,
        workspaceID: UUID,
        artifactCatalog: DebuggerWorkspaceArtifactCatalog
    ) {
        let evidence = Self.makeEvidence(snapshot: snapshot, artifactCatalog: artifactCatalog)
        let revisions = Dictionary(uniqueKeysWithValues: evidence.keys.map { ($0, UInt64(1)) })
        self.evidenceByBinaryID = evidence
        self.ownerRevisionByBinaryID = revisions
        self.ownerHighWaterByBinaryID = revisions
        self.ownerHighWaterBySlot = Dictionary(
            uniqueKeysWithValues: evidence.values.map { ($0.coordinate.slot, UInt64(1)) }
        )
        self.catalog = Self.makeCatalog(
            workspaceID: workspaceID,
            revision: .init(rawValue: 1),
            artifactCatalogRevision: artifactCatalog.revision,
            evidence: evidence,
            ownerRevisions: revisions
        )
    }

    mutating func reconcile(
        snapshot: WorkspaceSnapshot,
        workspaceID: UUID,
        artifactCatalog: DebuggerWorkspaceArtifactCatalog,
        fullWorkspaceReplacement: Bool = false
    ) -> DebuggerBreakpointResolutionCatalog {
        guard !isExhausted else { return catalog }
        let nextEvidence = Self.makeEvidence(snapshot: snapshot, artifactCatalog: artifactCatalog)
        let evidenceChanged = !Self.hasSameEvidence(nextEvidence, evidenceByBinaryID)
        let artifactCoordinateChanged =
            catalog.coordinate.workspaceArtifactCatalogRevision != artifactCatalog.revision
        guard fullWorkspaceReplacement || evidenceChanged || artifactCoordinateChanged else {
            return catalog
        }
        guard let nextRevision = catalog.coordinate.revision.incremented(),
              nextRevision.rawValue != .max else {
            return failClosed(workspaceID: workspaceID, artifactCatalogRevision: artifactCatalog.revision)
        }

        var nextOwnerRevisions: [UUID: UInt64] = [:]
        nextOwnerRevisions.reserveCapacity(nextEvidence.count)
        for evidence in nextEvidence.values {
            let prior = evidenceByBinaryID[evidence.coordinate.binaryID]
            let current = ownerRevisionByBinaryID[evidence.coordinate.binaryID]
            let ownerRevision: UInt64
            if !fullWorkspaceReplacement,
               let prior,
               let current,
               prior.hasSameResolverEvidence(as: evidence) {
                ownerRevision = current
            } else {
                let highWater = [
                    current,
                    ownerHighWaterByBinaryID[evidence.coordinate.binaryID],
                    ownerHighWaterBySlot[evidence.coordinate.slot],
                ].compactMap { $0 }.max() ?? 0
                guard highWater < .max else {
                    return failClosed(
                        workspaceID: workspaceID,
                        artifactCatalogRevision: artifactCatalog.revision
                    )
                }
                ownerRevision = highWater + 1
            }
            nextOwnerRevisions[evidence.coordinate.binaryID] = ownerRevision
            ownerHighWaterByBinaryID[evidence.coordinate.binaryID] = max(
                ownerHighWaterByBinaryID[evidence.coordinate.binaryID] ?? 0,
                ownerRevision
            )
            ownerHighWaterBySlot[evidence.coordinate.slot] = max(
                ownerHighWaterBySlot[evidence.coordinate.slot] ?? 0,
                ownerRevision
            )
        }

        evidenceByBinaryID = nextEvidence
        ownerRevisionByBinaryID = nextOwnerRevisions
        catalog = Self.makeCatalog(
            workspaceID: workspaceID,
            revision: nextRevision,
            artifactCatalogRevision: artifactCatalog.revision,
            evidence: nextEvidence,
            ownerRevisions: nextOwnerRevisions
        )
        return catalog
    }

    private mutating func failClosed(
        workspaceID: UUID,
        artifactCatalogRevision: DebuggerWorkspaceArtifactCatalogRevision
    ) -> DebuggerBreakpointResolutionCatalog {
        isExhausted = true
        evidenceByBinaryID.removeAll()
        ownerRevisionByBinaryID.removeAll()
        catalog = DebuggerBreakpointResolutionCatalog(
            coordinate: .init(
                workspaceID: workspaceID,
                revision: .init(rawValue: .max),
                workspaceArtifactCatalogRevision: artifactCatalogRevision
            ),
            owners: []
        )
        return catalog
    }

    private static func hasSameEvidence(
        _ lhs: [UUID: OwnerEvidence],
        _ rhs: [UUID: OwnerEvidence]
    ) -> Bool {
        guard Set(lhs.keys) == Set(rhs.keys) else { return false }
        return lhs.allSatisfy { binaryID, evidence in
            guard let other = rhs[binaryID] else { return false }
            return evidence.hasSameResolverEvidence(as: other)
        }
    }

    // init/reconcile remain MainActor-isolated. These value-only loops are deliberately
    // nonisolated so their per-row closures do not inherit executor assertions.
    nonisolated private static func makeEvidence(
        snapshot: WorkspaceSnapshot,
        artifactCatalog: DebuggerWorkspaceArtifactCatalog
    ) -> [UUID: OwnerEvidence] {
        let entries = artifactCatalog.artifacts.compactMap { entry -> OwnerEvidence? in
            guard entry.artifactIntegrityState == .verified,
                  let artifactIdentity = entry.artifactIdentity,
                  let preferredLayout = entry.preferredSegmentLayout,
                  snapshot.binary(in: entry.slot)?.id == entry.binaryID else {
                return nil
            }
            let coordinate = DebuggerWorkspaceArtifactCoordinate(
                binaryID: entry.binaryID,
                slot: entry.slot,
                artifactIdentity: artifactIdentity,
                ownerRevision: entry.ownerRevision
            )
            let analysis = snapshot.analysis(in: entry.slot) ?? ImageAnalysis()
            let segments: [DebuggerBreakpointResolutionSegment] =
                preferredLayout.records.compactMap {
                    record -> DebuggerBreakpointResolutionSegment? in
                    DebuggerBreakpointResolutionSegment(
                        name: record.name,
                        preferredStart: record.preferredVMStart,
                        byteCount: record.preferredVMSize,
                        isExecutable: record.initialProtections & 4 != 0
                    )
                }
            let staticAddresses: [DebuggerBreakpointStaticAddressEvidence] =
                analysis.instructions.compactMap {
                    instruction -> DebuggerBreakpointStaticAddressEvidence? in
                    let matches = segments.filter { $0.contains(instruction.address) }
                    guard matches.count == 1, let segment = matches.first else { return nil }
                    let kind: DebuggerBreakpointStaticAddressKind =
                        snapshot.isData(at: instruction.address, in: entry.slot)
                            || snapshot.isUndefined(at: instruction.address, in: entry.slot)
                        ? .data
                        : (segment.isExecutable ? .decodedExecutableInstruction : .data)
                    return DebuggerBreakpointStaticAddressEvidence(
                        preferredVA: instruction.address,
                        segmentName: segment.name,
                        kind: kind
                    )
                }
            let exactAddressedSymbols = analysis.symbols.compactMap {
                symbol -> (
                    bytes: Data,
                    raw: String,
                    address: UInt64,
                    kind: String,
                    libraryName: String?
                )? in
                guard let raw = symbol.rawLinkageName, let address = symbol.address else { return nil }
                return (Data(raw.utf8), raw, address, symbol.kind, symbol.libraryName)
            }
            let functions = analysis.functions.map { function in
                let matches = exactAddressedSymbols.filter {
                    $0.address == function.startAddress
                }
                let uniqueBytes = Set(matches.map(\.bytes))
                let rawName = uniqueBytes.count == 1 ? matches.first?.raw : nil
                return DebuggerBreakpointFunctionEvidence(
                    entryPreferredVA: function.startAddress,
                    rawLinkageName: rawName
                )
            }
            let hasCanonicalRawSymbolAuthority = !analysis.symbols.isEmpty
                && analysis.symbols.allSatisfy { $0.rawLinkageName != nil }
            let rawSymbols = exactAddressedSymbols.map { item in
                return DebuggerBreakpointRawSymbolEvidence(
                    exactRawLinkageName: item.raw,
                    kind: item.kind,
                    libraryName: item.libraryName,
                    preferredVA: item.address
                )
            }
            let exactSourceRows = analysis.sourceLines.compactMap(Self.makeExactSourceEvidence)
            let hasExactSourceAuthority = !analysis.sourceLines.isEmpty
                && exactSourceRows.count == analysis.sourceLines.count
            let sourceRows = hasExactSourceAuthority ? exactSourceRows : []
            let provisional = DebuggerBreakpointResolutionOwnerIndex(
                coordinate: coordinate,
                revision: 1,
                segments: segments,
                staticAddresses: staticAddresses,
                functions: functions,
                hasCanonicalRawSymbolAuthority: hasCanonicalRawSymbolAuthority,
                rawSymbols: rawSymbols,
                hasExactSourceAuthority: hasExactSourceAuthority,
                sourceRows: sourceRows
            )
            return OwnerEvidence(
                coordinate: coordinate,
                segments: provisional.segments,
                staticAddresses: provisional.staticAddresses,
                functions: provisional.functions,
                hasCanonicalRawSymbolAuthority: provisional.hasCanonicalRawSymbolAuthority,
                rawSymbols: provisional.rawSymbols,
                hasExactSourceAuthority: provisional.hasExactSourceAuthority,
                sourceRows: provisional.sourceRows,
                exactDigest: exactDigest(of: provisional)
            )
        }
        guard Set(entries.map { $0.coordinate.binaryID }).count == entries.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.coordinate.binaryID, $0) })
    }

    nonisolated private static func makeExactSourceEvidence(
        _ row: SourceLineEntry
    ) -> DebuggerBreakpointSourceEvidence? {
        guard let uuid = row.debugArtifactUUID,
              let sha256 = row.debugArtifactMachOSHA256,
              let byteCount = row.debugArtifactMachOByteCount,
              let unitOffset = row.lineProgramUnitOffset,
              let fileIndex = row.fileTableIndex,
              let tablePath = row.tablePath,
              let line = UInt32(exactly: row.line),
              let column = UInt32(exactly: row.column),
              let file = try? DebuggerCanonicalSourceFileIdentity(
                  debugArtifactUUID: uuid,
                  debugArtifactMachOSHA256: sha256,
                  debugArtifactMachOByteCount: byteCount,
                  lineProgramUnitOffset: unitOffset,
                  fileTableIndex: fileIndex,
                  tablePath: tablePath
              ) else {
            return nil
        }
        return DebuggerBreakpointSourceEvidence(
            file: file,
            line: line,
            column: column,
            preferredVA: row.address,
            isEndSequence: row.endSequence
        )
    }

    /// Length-prefix every textual field so synthesized Unicode equality can never collapse two
    /// canonically-equivalent but byte-distinct raw linkage names or source paths.
    // Internal for byte-for-byte comparison with the retained pre-optimization encoder.
    // Despite the historical name, this is canonical evidence bytes, not a cryptographic hash.
    nonisolated static func exactDigest(
        of owner: DebuggerBreakpointResolutionOwnerIndex
    ) -> Data {
        // The instruction-address table dominates ordinary catalogs. Reserve a bounded
        // estimate once; Data grows normally for larger names/other evidence collections.
        var data = Data(capacity: 42 + min(owner.staticAddresses.count, 1_000_000) * 32)
        func appendByte(_ value: UInt8) { data.append(value) }
        func appendUInt64(_ value: UInt64) {
            var encoded = value.bigEndian
            withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ value: UInt32) { appendUInt64(UInt64(value)) }
        func appendString(_ value: String) {
            appendUInt64(UInt64(value.utf8.count))
            data.append(contentsOf: value.utf8)
        }
        func appendOptionalString(_ value: String?) {
            guard let value else { appendByte(0); return }
            appendByte(1); appendString(value)
        }
        func appendUUID(_ value: UUID) {
            withUnsafeBytes(of: value.uuid) { bytes in
                appendUInt64(UInt64(bytes.count))
                data.append(contentsOf: bytes)
            }
        }
        func appendSourceFile(_ file: DebuggerCanonicalSourceFileIdentity) {
            appendUUID(file.debugArtifactUUID)
            appendString(file.debugArtifactMachOSHA256)
            appendUInt64(file.debugArtifactMachOByteCount)
            appendUInt64(file.lineProgramUnitOffset)
            appendUInt32(file.fileTableIndex)
            switch file.tablePath {
            case .absoluteUTF8(let path): appendByte(0); appendString(path)
            case .compilationDirectoryRelativeUTF8(let path): appendByte(1); appendString(path)
            }
        }
        appendUInt64(UInt64(owner.segments.count))
        for segment in owner.segments {
            appendString(segment.name); appendUInt64(segment.preferredStart)
            appendUInt64(segment.byteCount); appendByte(segment.isExecutable ? 1 : 0)
        }
        appendUInt64(UInt64(owner.staticAddresses.count))
        for address in owner.staticAddresses {
            appendUInt64(address.preferredVA); appendString(address.segmentName)
            appendByte(address.kind == .decodedExecutableInstruction ? 0 : 1)
        }
        appendUInt64(UInt64(owner.functions.count))
        for function in owner.functions {
            appendUInt64(function.entryPreferredVA); appendOptionalString(function.rawLinkageName)
        }
        appendByte(owner.hasCanonicalRawSymbolAuthority ? 1 : 0)
        appendUInt64(UInt64(owner.rawSymbols.count))
        for symbol in owner.rawSymbols {
            appendString(symbol.exactRawLinkageName); appendOptionalString(symbol.kind)
            appendOptionalString(symbol.libraryName); appendUInt64(symbol.preferredVA)
        }
        appendByte(owner.hasExactSourceAuthority ? 1 : 0)
        appendUInt64(UInt64(owner.sourceRows.count))
        for row in owner.sourceRows {
            appendSourceFile(row.file); appendUInt32(row.line); appendUInt32(row.column)
            appendUInt64(row.preferredVA); appendByte(row.isEndSequence ? 1 : 0)
        }
        return data
    }

    private static func makeCatalog(
        workspaceID: UUID,
        revision: DebuggerBreakpointResolutionCatalogRevision,
        artifactCatalogRevision: DebuggerWorkspaceArtifactCatalogRevision,
        evidence: [UUID: OwnerEvidence],
        ownerRevisions: [UUID: UInt64]
    ) -> DebuggerBreakpointResolutionCatalog {
        DebuggerBreakpointResolutionCatalog(
            coordinate: .init(
                workspaceID: workspaceID,
                revision: revision,
                workspaceArtifactCatalogRevision: artifactCatalogRevision
            ),
            owners: evidence.values.compactMap { item in
                guard let revision = ownerRevisions[item.coordinate.binaryID] else { return nil }
                return item.owner(revision: revision)
            }
        )
    }
}

