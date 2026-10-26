import CryptoKit
import Foundation

/// Pure, synchronous resolution from durable logical intent through exact static evidence and the
/// current WS-20 vector mapping projection. It never selects a first match to break ambiguity.
enum DebuggerLogicalBreakpointResolver {
    static func resolve(
        catalog logicalCatalog: DebuggerLogicalBreakpointCatalog,
        coordinate logicalCoordinate: DebuggerLogicalBreakpointCatalogCoordinate,
        resolutionCatalog: DebuggerBreakpointResolutionCatalog,
        requiringResolutionCoordinate expectedResolutionCoordinate: DebuggerBreakpointResolutionCatalogCoordinate,
        runtimeProjection: DebuggerRuntimeMappingProjection?,
        requiringMappingKey expectedMappingKey: DebuggerRuntimeMappingProjectionKey?
    ) -> [DebuggerLogicalBreakpointResolution] {
        guard logicalCoordinate.catalogID == logicalCatalog.catalogID,
              logicalCoordinate.revision == logicalCatalog.revision else {
            return logicalCatalog.specifications.map {
                resolution(for: $0, state: .pending(.newerCatalogAwaitingConvergence))
            }
        }
        guard resolutionCatalog.coordinate == expectedResolutionCoordinate else {
            return logicalCatalog.specifications.map {
                resolution(for: $0, state: .pending(.resolutionCatalogStale))
            }
        }
        guard resolutionCatalog.isStructurallyValid else {
            return logicalCatalog.specifications.map {
                resolution(for: $0, state: .invalid(.invalidResolutionCatalog))
            }
        }
        guard resolutionCatalog.coordinate.workspaceID == logicalCoordinate.workspaceID else {
            return logicalCatalog.specifications.map {
                resolution(for: $0, state: .pending(.resolutionCatalogStale))
            }
        }

        let initiallyResolved = logicalCatalog.specifications.map { specification in
            resolve(
                specification,
                catalog: resolutionCatalog,
                runtimeProjection: runtimeProjection,
                expectedMappingKey: expectedMappingKey
            )
        }
        return rejectCrossSpecificationRuntimeCollisions(initiallyResolved)
    }

    private static func resolve(
        _ specification: DebuggerLogicalBreakpointSpecification,
        catalog: DebuggerBreakpointResolutionCatalog,
        runtimeProjection: DebuggerRuntimeMappingProjection?,
        expectedMappingKey: DebuggerRuntimeMappingProjectionKey?
    ) -> DebuggerLogicalBreakpointResolution {
        guard specification.enabled else {
            return resolution(for: specification, state: .disabled)
        }

        let ownerSeal = owner(of: specification.target)
        let matchingOwners = catalog.owners.filter {
            $0.coordinate.slot == ownerSeal.slot && $0.coordinate.binaryID == ownerSeal.binaryID
        }
        guard matchingOwners.count <= 1 else {
            return resolution(for: specification, state: .pending(.ownerAmbiguous))
        }
        guard let owner = matchingOwners.first else {
            return resolution(for: specification, state: .pending(.ownerUnavailable))
        }
        if let sealedArtifact = ownerSeal.artifactIdentity,
           sealedArtifact != owner.coordinate.artifactIdentity {
            return resolution(for: specification, state: .pending(.ownerSealMismatch))
        }

        let staticResult = staticCandidates(for: specification.target, in: owner)
        let candidates: [StaticCandidate]
        switch staticResult {
        case .pending(let reason):
            return resolution(for: specification, state: .pending(reason))
        case .invalid(let reason):
            return resolution(for: specification, state: .invalid(reason))
        case .resolved(let value):
            candidates = value
        }

        guard candidates.count <= 256 else {
            return resolution(for: specification, state: .pending(.capacityExceeded))
        }
        guard let runtimeProjection else {
            return resolution(for: specification, state: .pending(.noSession))
        }
        guard let expectedMappingKey,
              runtimeProjection.key == expectedMappingKey else {
            return resolution(for: specification, state: .pending(.runtimeProjectionStale))
        }
        guard runtimeProjection.key.workspaceCatalogRevision
                == catalog.coordinate.workspaceArtifactCatalogRevision else {
            return resolution(for: specification, state: .pending(.artifactCatalogStale))
        }

        var sites: [DebuggerResolvedLogicalBreakpointSite] = []
        for (index, candidate) in candidates.enumerated() {
            let imageAddress = ImageAddress(
                slot: owner.coordinate.slot,
                address: candidate.preferredVA
            )
            let siteID = DebuggerLogicalBreakpointSiteID(
                logicalID: specification.id,
                specificationRevision: specification.revision,
                imageAddress: imageAddress,
                staticOrdinal: UInt32(index)
            )
            guard let site = DebuggerResolvedLogicalBreakpointSite(
                logicalID: specification.id,
                specificationRevision: specification.revision,
                siteID: siteID,
                owner: ownerSeal,
                coordinate: owner.coordinate,
                imageAddress: imageAddress,
                provenance: candidate.provenance
            ) else {
                return resolution(
                    for: specification,
                    state: .invalid(.duplicateStaticSiteIdentity)
                )
            }
            sites.append(site)
        }

        guard let policyActionDigest = policyActionDigest(for: specification) else {
            return resolution(for: specification, state: .invalid(.contradictoryStaticEvidence))
        }

        var bindings: [DebuggerDesiredBreakpointBinding] = []
        for site in sites {
            switch DebuggerRuntimeAddressTranslator.runtimeAddresses(
                forStaticAddress: site.imageAddress,
                coordinate: site.coordinate,
                in: runtimeProjection,
                requiring: expectedMappingKey
            ) {
            case .unresolved(.projectionKeyMismatch):
                return resolution(for: specification, state: .pending(.runtimeProjectionStale))
            case .unresolved(.invalidProjection):
                return resolution(for: specification, state: .invalid(.invalidRuntimeProjection))
            case .unresolved(.projectionUnavailable):
                return resolution(for: specification, state: .pending(.awaitingRuntimeInventory))
            case .unresolved(.unmapped):
                return resolution(for: specification, state: .pending(.moduleUnloaded))
            case .resolved(let translated):
                for runtime in translated {
                    guard hasExactExecutableMapping(
                        runtime,
                        site: site,
                        in: runtimeProjection
                    ) else {
                        return resolution(
                            for: specification,
                            state: .pending(.runtimeAddressNotExecutable)
                        )
                    }
                    guard let bindingID = DebuggerTransientBreakpointBindingID(
                        logicalID: specification.id,
                        siteID: site.siteID,
                        moduleInstanceID: runtime.moduleInstanceID
                    ),
                    let issuanceDigest = issuanceDigest(
                        policyActionDigest: policyActionDigest,
                        site: site,
                        runtime: runtime
                    ) else {
                        return resolution(for: specification, state: .invalid(.invalidRuntimeProjection))
                    }
                    guard let binding = DebuggerDesiredBreakpointBinding(
                        id: bindingID,
                        site: site,
                        mappingKey: runtimeProjection.key,
                        runtimeAddress: runtime.runtimeAddress,
                        policyActionDigest: policyActionDigest,
                        issuanceDigest: issuanceDigest
                    ) else {
                        return resolution(for: specification, state: .invalid(.invalidRuntimeProjection))
                    }
                    bindings.append(binding)
                }
            }
        }

        bindings = Array(Set(bindings)).sorted(by: bindingPrecedes)
        guard bindings.count <= 4_096 else {
            return resolution(for: specification, state: .pending(.capacityExceeded))
        }
        guard !bindings.isEmpty else {
            return resolution(for: specification, state: .pending(.moduleUnloaded))
        }
        if hasRuntimeCollision(bindings) {
            return resolution(for: specification, state: .pending(.runtimeAddressCollision))
        }
        if sites.count == 1, bindings.count == 1 {
            return resolution(
                for: specification,
                state: .resolved(site: sites[0], binding: bindings[0])
            )
        }
        return resolution(
            for: specification,
            state: .resolvedMultiple(sites: sites, bindings: bindings)
        )
    }

    private enum StaticResult {
        case resolved([StaticCandidate])
        case pending(DebuggerLogicalBreakpointPendingReason)
        case invalid(DebuggerLogicalBreakpointInvalidReason)
    }

    private struct StaticCandidate: Hashable {
        let preferredVA: UInt64
        let provenance: DebuggerLogicalBreakpointSiteProvenance
    }

    private static func staticCandidates(
        for target: DebuggerLogicalBreakpointTarget,
        in owner: DebuggerBreakpointResolutionOwnerIndex
    ) -> StaticResult {
        switch target {
        case .preferredAddress(_, let preferredVA):
            return singleExecutableCandidate(
                preferredVA: preferredVA,
                provenance: .preferredAddress,
                owner: owner,
                absentReason: .staticAddressUnavailable
            )

        case .imageOffset(_, let segmentName, let expectedStart, let offset):
            let segments = owner.segments.filter {
                utf8Equals($0.name, segmentName) && $0.preferredStart == expectedStart
            }
            guard segments.count == 1, let segment = segments.first else {
                return .pending(.segmentUnavailable)
            }
            let address = expectedStart.addingReportingOverflow(offset)
            guard !address.overflow else { return .pending(.addressOverflow) }
            guard segment.contains(address.partialValue), segment.isExecutable else {
                return .pending(.staticAddressNotExecutable)
            }
            return singleExecutableCandidate(
                preferredVA: address.partialValue,
                provenance: .imageOffset(
                    segmentName: segmentName,
                    segmentPreferredStart: expectedStart,
                    offset: offset
                ),
                owner: owner,
                requiredSegmentName: segmentName,
                absentReason: .staticAddressUnavailable
            )

        case .function(_, let entryPreferredVA, let rawLinkageNameHint):
            let exactFunctions = uniqueByExactBytes(owner.functions.filter {
                $0.entryPreferredVA == entryPreferredVA
            }, key: functionEvidenceBytes)
            guard exactFunctions.count == 1, let function = exactFunctions.first else {
                return exactFunctions.isEmpty
                    ? .pending(.functionUnavailable)
                    : .invalid(.contradictoryStaticEvidence)
            }
            if let hint = rawLinkageNameHint {
                guard let current = function.rawLinkageName,
                      utf8Equals(hint, current) else {
                    return .pending(.functionCorroborationMismatch)
                }
            }
            return singleExecutableCandidate(
                preferredVA: entryPreferredVA,
                provenance: .function(
                    entryPreferredVA: entryPreferredVA,
                    rawLinkageName: function.rawLinkageName
                ),
                owner: owner,
                absentReason: .staticAddressNotExecutable
            )

        case .symbol(_, let exactName, let kind, let libraryName, let cardinality):
            guard owner.hasCanonicalRawSymbolAuthority else {
                return .pending(.rawSymbolAuthorityUnavailable)
            }
            let matches = uniqueByExactBytes(owner.rawSymbols.filter {
                utf8Equals($0.exactRawLinkageName, exactName)
                    && (kind == nil || optionalUTF8Equals($0.kind, kind))
                    && (libraryName == nil || optionalUTF8Equals($0.libraryName, libraryName))
            }, key: rawSymbolEvidenceBytes)
            return multipleCandidates(
                candidates: matches.enumerated().map { ordinal, match in
                    StaticCandidate(
                        preferredVA: match.preferredVA,
                        provenance: .symbol(
                            exactRawLinkageName: match.exactRawLinkageName,
                            kind: match.kind,
                            libraryName: match.libraryName,
                            staticOrdinal: UInt32(ordinal)
                        )
                    )
                },
                cardinality: cardinality,
                owner: owner,
                unavailable: .symbolUnavailable
            )

        case .source(_, let file, let line, let columnPolicy, let cardinality):
            guard owner.hasExactSourceAuthority else {
                return .pending(.sourceAuthorityUnavailable)
            }
            let matches = uniqueByExactBytes(owner.sourceRows.filter { row in
                guard !row.isEndSequence,
                      sourceFileBytes(row.file) == sourceFileBytes(file),
                      row.line == line else {
                    return false
                }
                switch columnPolicy {
                case .any: return true
                case .exact(let column): return row.column == column
                }
            }, key: sourceEvidenceBytes)
            return multipleCandidates(
                candidates: matches.enumerated().map { ordinal, row in
                    StaticCandidate(
                        preferredVA: row.preferredVA,
                        provenance: .source(
                            file: row.file,
                            line: row.line,
                            column: row.column,
                            staticOrdinal: UInt32(ordinal)
                        )
                    )
                },
                cardinality: cardinality,
                owner: owner,
                unavailable: .sourceUnavailable
            )
        }
    }

    private static func singleExecutableCandidate(
        preferredVA: UInt64,
        provenance: DebuggerLogicalBreakpointSiteProvenance,
        owner: DebuggerBreakpointResolutionOwnerIndex,
        requiredSegmentName: String? = nil,
        absentReason: DebuggerLogicalBreakpointPendingReason
    ) -> StaticResult {
        let evidence = owner.staticAddresses.filter { evidence in
            evidence.preferredVA == preferredVA
                && (requiredSegmentName.map {
                    utf8Equals(evidence.segmentName, $0)
                } ?? true)
        }
        let executableEvidence = Set(evidence.filter {
            $0.kind == .decodedExecutableInstruction
                && isExecutableSegment($0.segmentName, containing: preferredVA, in: owner)
        })
        if executableEvidence.count == 1 {
            return .resolved([StaticCandidate(preferredVA: preferredVA, provenance: provenance)])
        }
        if executableEvidence.count > 1 { return .invalid(.contradictoryStaticEvidence) }
        if evidence.contains(where: { $0.kind == .data }) {
            return .pending(.staticAddressNotExecutable)
        }
        return .pending(absentReason)
    }

    private static func multipleCandidates(
        candidates: [StaticCandidate],
        cardinality: DebuggerLogicalBreakpointCardinality,
        owner: DebuggerBreakpointResolutionOwnerIndex,
        unavailable: DebuggerLogicalBreakpointPendingReason
    ) -> StaticResult {
        let ordered = candidates.sorted(by: candidatePrecedes)
        guard !ordered.isEmpty else { return .pending(unavailable) }
        if cardinality == .exactlyOne, ordered.count != 1 {
            return .pending(.accidentalAmbiguity)
        }
        guard ordered.count <= 256 else { return .pending(.capacityExceeded) }
        for candidate in ordered {
            let address = candidate.preferredVA
            let executable = owner.staticAddresses.filter {
                $0.preferredVA == address
                    && $0.kind == .decodedExecutableInstruction
                    && isExecutableSegment($0.segmentName, containing: address, in: owner)
            }
            guard Set(executable).count == 1 else {
                return executable.isEmpty
                    ? .pending(.staticAddressNotExecutable)
                    : .invalid(.contradictoryStaticEvidence)
            }
        }
        return .resolved(ordered)
    }

    private static func isExecutableSegment(
        _ name: String,
        containing address: UInt64,
        in owner: DebuggerBreakpointResolutionOwnerIndex
    ) -> Bool {
        let segments = owner.segments.filter {
            utf8Equals($0.name, name) && $0.isExecutable && $0.contains(address)
        }
        return segments.count == 1
    }

    private static func hasExactExecutableMapping(
        _ runtime: DebuggerResolvedRuntimeAddress,
        site: DebuggerResolvedLogicalBreakpointSite,
        in projection: DebuggerRuntimeMappingProjection
    ) -> Bool {
        let modules = projection.modules.filter {
            $0.instanceID == runtime.moduleInstanceID && $0.coordinate == site.coordinate
        }
        guard modules.count == 1, let module = modules.first else { return false }
        let ranges = module.mappedRanges.filter { range in
            guard range.permissions & 4 == 4,
                  site.imageAddress.address >= range.staticStart,
                  runtime.runtimeAddress >= range.runtimeStart,
                  site.imageAddress.address - range.staticStart < range.byteCount,
                  runtime.runtimeAddress - range.runtimeStart < range.byteCount else {
                return false
            }
            return site.imageAddress.address - range.staticStart
                == runtime.runtimeAddress - range.runtimeStart
        }
        return ranges.count == 1
    }

    private static func owner(
        of target: DebuggerLogicalBreakpointTarget
    ) -> DebuggerWorkspaceImageOwnerSeal {
        switch target {
        case .preferredAddress(let owner, _),
             .imageOffset(let owner, _, _, _),
             .function(let owner, _, _),
             .symbol(let owner, _, _, _, _),
             .source(let owner, _, _, _, _):
            return owner
        }
    }

    private static func policyActionDigest(
        for specification: DebuggerLogicalBreakpointSpecification
    ) -> DebuggerBreakpointDigest? {
        guard let encoded = try? DebuggerLogicalBreakpointCanonicalCodec
            .encodeSpecification(specification) else {
            return nil
        }
        return DebuggerBreakpointDigest(Data(SHA256.hash(data: encoded)))
    }

    private static func issuanceDigest(
        policyActionDigest: DebuggerBreakpointDigest,
        site: DebuggerResolvedLogicalBreakpointSite,
        runtime: DebuggerResolvedRuntimeAddress
    ) -> DebuggerBreakpointDigest? {
        var material = policyActionDigest.bytes
        material.append(contentsOf: site.logicalID.rawValue.uuidString.utf8)
        material.append(contentsOf: String(site.specificationRevision.rawValue).utf8)
        material.append(contentsOf: String(site.siteID.staticOrdinal).utf8)
        material.append(contentsOf: String(site.imageAddress.slot.rawValue).utf8)
        material.append(contentsOf: String(site.imageAddress.address).utf8)
        material.append(contentsOf: String(runtime.runtimeAddress).utf8)
        material.append(contentsOf: String(runtime.moduleInstanceID.ordinal).utf8)
        material.append(contentsOf: String(runtime.projectionKey.inventoryRevision.rawValue).utf8)
        return DebuggerBreakpointDigest(Data(SHA256.hash(data: material)))
    }

    private static func uniqueByExactBytes<Value>(
        _ values: [Value],
        key: (Value) -> Data
    ) -> [Value] {
        var seen = Set<Data>()
        return values.filter { seen.insert(key($0)).inserted }
    }

    private static func utf8Equals(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8) == Data(rhs.utf8)
    }

    private static func optionalUTF8Equals(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return utf8Equals(lhs, rhs)
    }

    private static func candidatePrecedes(
        _ lhs: StaticCandidate,
        _ rhs: StaticCandidate
    ) -> Bool {
        if lhs.preferredVA != rhs.preferredVA { return lhs.preferredVA < rhs.preferredVA }
        return provenanceBytes(lhs.provenance).lexicographicallyPrecedes(
            provenanceBytes(rhs.provenance)
        )
    }

    private static func provenanceBytes(
        _ provenance: DebuggerLogicalBreakpointSiteProvenance
    ) -> Data {
        var value = Data()
        func append(_ text: String) {
            value.append(contentsOf: String(text.utf8.count).utf8)
            value.append(0)
            value.append(contentsOf: text.utf8)
            value.append(0)
        }
        func appendOptional(_ text: String?) {
            guard let text else { append("nil"); return }
            append("some")
            append(text)
        }
        switch provenance {
        case .preferredAddress:
            append("preferredAddress")
        case .imageOffset(let name, let start, let offset):
            append("imageOffset"); append(name); append(String(start)); append(String(offset))
        case .function(let address, let name):
            append("function"); append(String(address)); appendOptional(name)
        case .symbol(let name, let kind, let libraryName, let ordinal):
            append("symbol")
            append(name)
            appendOptional(kind)
            appendOptional(libraryName)
            append(String(ordinal))
        case .source(let file, let line, let column, let ordinal):
            append("source")
            append(file.debugArtifactUUID.uuidString)
            append(file.debugArtifactMachOSHA256)
            append(String(file.debugArtifactMachOByteCount))
            append(String(file.lineProgramUnitOffset))
            append(String(file.fileTableIndex))
            switch file.tablePath {
            case .absoluteUTF8(let path): append("absolute"); append(path)
            case .compilationDirectoryRelativeUTF8(let path):
                append("compilationDirectoryRelative"); append(path)
            }
            append(String(line)); append(String(column ?? 0)); append(String(ordinal))
        }
        return value
    }

    private static func sourceFileBytes(
        _ file: DebuggerCanonicalSourceFileIdentity
    ) -> Data {
        var value = Data()
        func append(_ text: String) {
            value.append(contentsOf: String(text.utf8.count).utf8)
            value.append(0)
            value.append(contentsOf: text.utf8)
            value.append(0)
        }
        append(file.debugArtifactUUID.uuidString)
        append(file.debugArtifactMachOSHA256)
        append(String(file.debugArtifactMachOByteCount))
        append(String(file.lineProgramUnitOffset))
        append(String(file.fileTableIndex))
        switch file.tablePath {
        case .absoluteUTF8(let path): append("absolute"); append(path)
        case .compilationDirectoryRelativeUTF8(let path):
            append("compilationDirectoryRelative"); append(path)
        }
        return value
    }

    private static func functionEvidenceBytes(
        _ evidence: DebuggerBreakpointFunctionEvidence
    ) -> Data {
        exactFields([
            String(evidence.entryPreferredVA),
            evidence.rawLinkageName == nil ? "nil" : "some",
            evidence.rawLinkageName ?? "",
        ])
    }

    private static func rawSymbolEvidenceBytes(
        _ evidence: DebuggerBreakpointRawSymbolEvidence
    ) -> Data {
        exactFields([
            evidence.exactRawLinkageName,
            evidence.kind == nil ? "nil" : "some",
            evidence.kind ?? "",
            evidence.libraryName == nil ? "nil" : "some",
            evidence.libraryName ?? "",
            String(evidence.preferredVA),
        ])
    }

    private static func sourceEvidenceBytes(
        _ evidence: DebuggerBreakpointSourceEvidence
    ) -> Data {
        var value = sourceFileBytes(evidence.file)
        value.append(exactFields([
            String(evidence.line),
            String(evidence.column),
            String(evidence.preferredVA),
            evidence.isEndSequence ? "end" : "row",
        ]))
        return value
    }

    private static func exactFields(_ fields: [String]) -> Data {
        var value = Data()
        for field in fields {
            value.append(contentsOf: String(field.utf8.count).utf8)
            value.append(0)
            value.append(contentsOf: field.utf8)
            value.append(0)
        }
        return value
    }

    private static func hasRuntimeCollision(
        _ bindings: [DebuggerDesiredBreakpointBinding]
    ) -> Bool {
        Dictionary(grouping: bindings, by: \.runtimeAddress).values.contains { group in
            Set(group.map(\.id)).count > 1
        }
    }

    private static func rejectCrossSpecificationRuntimeCollisions(
        _ resolutions: [DebuggerLogicalBreakpointResolution]
    ) -> [DebuggerLogicalBreakpointResolution] {
        let allBindings = resolutions.flatMap(bindings(in:))
        let collidingAddresses = Set(
            Dictionary(grouping: allBindings, by: \.runtimeAddress).compactMap { address, group in
                Set(group.map(\.id)).count > 1 ? address : nil
            }
        )
        guard !collidingAddresses.isEmpty else { return resolutions }
        return resolutions.map { item in
            let collides = bindings(in: item).contains {
                collidingAddresses.contains($0.runtimeAddress)
            }
            return collides
                ? DebuggerLogicalBreakpointResolution(
                    logicalID: item.logicalID,
                    specificationRevision: item.specificationRevision,
                    state: .pending(.runtimeAddressCollision)
                )
                : item
        }
    }

    private static func bindings(
        in resolution: DebuggerLogicalBreakpointResolution
    ) -> [DebuggerDesiredBreakpointBinding] {
        switch resolution.state {
        case .resolved(_, let binding): [binding]
        case .resolvedMultiple(_, let bindings): bindings
        default: []
        }
    }

    private static func resolution(
        for specification: DebuggerLogicalBreakpointSpecification,
        state: DebuggerLogicalBreakpointResolutionState
    ) -> DebuggerLogicalBreakpointResolution {
        DebuggerLogicalBreakpointResolution(
            logicalID: specification.id,
            specificationRevision: specification.revision,
            state: state
        )
    }

    private static func bindingPrecedes(
        _ lhs: DebuggerDesiredBreakpointBinding,
        _ rhs: DebuggerDesiredBreakpointBinding
    ) -> Bool {
        if lhs.runtimeAddress != rhs.runtimeAddress { return lhs.runtimeAddress < rhs.runtimeAddress }
        if lhs.id.siteID.staticOrdinal != rhs.id.siteID.staticOrdinal {
            return lhs.id.siteID.staticOrdinal < rhs.id.siteID.staticOrdinal
        }
        return lhs.id.moduleInstanceID.ordinal < rhs.id.moduleInstanceID.ordinal
    }
}
