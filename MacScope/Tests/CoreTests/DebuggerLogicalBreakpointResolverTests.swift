import XCTest
@testable import MacScope

final class DebuggerLogicalBreakpointResolverTests: XCTestCase {
    func testSamePreferredVARequiresExactOwnerAndExecutableStaticEvidence() throws {
        let executableOwner = try makeOwner(binaryID: binaryA, slot: .primary, kind: .decodedExecutableInstruction)
        let dataOwner = try makeOwner(binaryID: binaryB, slot: ImageSlot(rawValue: 1), kind: .data)
        let specs = [
            try makeSpecification(id: logicalA, owner: seal(executableOwner), targetAddress: 0x1010),
            try makeSpecification(id: logicalB, owner: seal(dataOwner), targetAddress: 0x1010),
        ]
        let fixture = try makeFixture(owners: [executableOwner, dataOwner], specifications: specs)
        let projection = try makeProjection(
            owners: [executableOwner, dataOwner],
            permissions: [5, 3]
        )
        let results = DebuggerLogicalBreakpointResolver.resolve(
            catalog: fixture.logicalCatalog,
            coordinate: fixture.logicalCoordinate,
            resolutionCatalog: fixture.resolutionCatalog,
            requiringResolutionCoordinate: fixture.resolutionCatalog.coordinate,
            runtimeProjection: projection,
            requiringMappingKey: projection.key
        )

        guard case let .resolved(site, binding) = try XCTUnwrap(results.first { $0.logicalID == logicalA }).state else {
            return XCTFail("Executable owner must resolve")
        }
        XCTAssertEqual(site.coordinate.binaryID, binaryA)
        XCTAssertEqual(binding.runtimeAddress, 0x9010)
        XCTAssertEqual(
            try XCTUnwrap(results.first { $0.logicalID == logicalB }).state,
            .pending(.staticAddressNotExecutable)
        )
    }

    func testExactRawSymbolCardinalityNeverChoosesFirstAndAllMatchesExpandCanonically() throws {
        var owner = try makeOwner(binaryID: binaryA, slot: .primary, kind: .decodedExecutableInstruction)
        owner = DebuggerBreakpointResolutionOwnerIndex(
            coordinate: owner.coordinate,
            revision: owner.revision,
            segments: owner.segments,
            staticAddresses: [
                .init(preferredVA: 0x1010, segmentName: "__TEXT", kind: .decodedExecutableInstruction),
                .init(preferredVA: 0x1020, segmentName: "__TEXT", kind: .decodedExecutableInstruction),
            ],
            functions: [],
            hasCanonicalRawSymbolAuthority: true,
            rawSymbols: [
                .init(exactRawLinkageName: "_dup", kind: "function", libraryName: nil, preferredVA: 0x1020),
                .init(exactRawLinkageName: "_dup", kind: "function", libraryName: nil, preferredVA: 0x1010),
            ],
            hasExactSourceAuthority: false,
            sourceRows: []
        )
        let one = try makeSymbolSpecification(
            id: logicalA,
            owner: seal(owner),
            cardinality: .exactlyOne
        )
        let all = try makeSymbolSpecification(
            id: logicalB,
            owner: seal(owner),
            cardinality: .allExactMatches
        )
        let fixture = try makeFixture(owners: [owner], specifications: [one, all])
        let projection = try makeProjection(owners: [owner], permissions: [5])
        let results = DebuggerLogicalBreakpointResolver.resolve(
            catalog: fixture.logicalCatalog,
            coordinate: fixture.logicalCoordinate,
            resolutionCatalog: fixture.resolutionCatalog,
            requiringResolutionCoordinate: fixture.resolutionCatalog.coordinate,
            runtimeProjection: projection,
            requiringMappingKey: projection.key
        )

        XCTAssertEqual(
            try XCTUnwrap(results.first { $0.logicalID == logicalA }).state,
            .pending(.accidentalAmbiguity)
        )
        guard case let .resolvedMultiple(sites, bindings) = try XCTUnwrap(
            results.first { $0.logicalID == logicalB }
        ).state else {
            return XCTFail("Intentional multiplicity must preserve every exact match")
        }
        XCTAssertEqual(sites.map(\.imageAddress.address), [0x1010, 0x1020])
        XCTAssertEqual(bindings.map(\.runtimeAddress), [0x9010, 0x9020])
        XCTAssertEqual(sites.map(\.siteID.staticOrdinal), [0, 1])
    }

    func testRawSymbolNameKindAndLibraryUseExactUTF8Bytes() throws {
        var owner = try makeOwner(
            binaryID: binaryA,
            slot: .primary,
            kind: .decodedExecutableInstruction
        )
        owner = DebuggerBreakpointResolutionOwnerIndex(
            coordinate: owner.coordinate,
            revision: owner.revision,
            segments: owner.segments,
            staticAddresses: [
                .init(preferredVA: 0x1010, segmentName: "__TEXT", kind: .decodedExecutableInstruction),
                .init(preferredVA: 0x1020, segmentName: "__TEXT", kind: .decodedExecutableInstruction),
            ],
            functions: [],
            hasCanonicalRawSymbolAuthority: true,
            rawSymbols: [
                .init(
                    exactRawLinkageName: "_caf\u{00E9}",
                    kind: "func\u{00E9}",
                    libraryName: "lib\u{00E9}",
                    preferredVA: 0x1010
                ),
                .init(
                    exactRawLinkageName: "_cafe\u{0301}",
                    kind: "funce\u{0301}",
                    libraryName: "libe\u{0301}",
                    preferredVA: 0x1020
                ),
            ],
            hasExactSourceAuthority: false,
            sourceRows: []
        )
        let specification = try makeSymbolSpecification(
            id: logicalA,
            owner: seal(owner),
            exactName: "_caf\u{00E9}",
            kind: "func\u{00E9}",
            libraryName: "lib\u{00E9}",
            cardinality: .exactlyOne
        )
        let fixture = try makeFixture(owners: [owner], specifications: [specification])
        let projection = try makeProjection(owners: [owner], permissions: [5])

        let result = try XCTUnwrap(DebuggerLogicalBreakpointResolver.resolve(
            catalog: fixture.logicalCatalog,
            coordinate: fixture.logicalCoordinate,
            resolutionCatalog: fixture.resolutionCatalog,
            requiringResolutionCoordinate: fixture.resolutionCatalog.coordinate,
            runtimeProjection: projection,
            requiringMappingKey: projection.key
        ).first)
        guard case let .resolved(site, binding) = result.state else {
            return XCTFail("Canonical-equivalent but byte-distinct names must not collide")
        }
        XCTAssertEqual(site.imageAddress.address, 0x1010)
        XCTAssertEqual(binding.runtimeAddress, 0x9010)
    }

    func testResolutionEvidenceEqualityDetectsNFCNFDOnlyChanges() throws {
        let precomposed = DebuggerBreakpointRawSymbolEvidence(
            exactRawLinkageName: "_caf\u{00E9}",
            kind: "func\u{00E9}",
            libraryName: "lib\u{00E9}",
            preferredVA: 0x1010
        )
        let decomposed = DebuggerBreakpointRawSymbolEvidence(
            exactRawLinkageName: "_cafe\u{0301}",
            kind: "funce\u{0301}",
            libraryName: "libe\u{0301}",
            preferredVA: 0x1010
        )
        XCTAssertNotEqual(precomposed, decomposed)
        XCTAssertEqual(Set([precomposed, decomposed]).count, 2)

        let base = try makeOwner(
            binaryID: binaryA,
            slot: .primary,
            kind: .decodedExecutableInstruction
        )
        let nfcOwner = DebuggerBreakpointResolutionOwnerIndex(
            coordinate: base.coordinate,
            revision: base.revision,
            segments: base.segments,
            staticAddresses: base.staticAddresses,
            functions: [],
            hasCanonicalRawSymbolAuthority: true,
            rawSymbols: [precomposed],
            hasExactSourceAuthority: false,
            sourceRows: []
        )
        let nfdOwner = DebuggerBreakpointResolutionOwnerIndex(
            coordinate: base.coordinate,
            revision: base.revision,
            segments: base.segments,
            staticAddresses: base.staticAddresses,
            functions: [],
            hasCanonicalRawSymbolAuthority: true,
            rawSymbols: [decomposed],
            hasExactSourceAuthority: false,
            sourceRows: []
        )
        XCTAssertNotEqual(nfcOwner, nfdOwner)
    }

    func testSameAddressDistinctFullSymbolEvidenceIsNotCollapsed() throws {
        var owner = try makeOwner(
            binaryID: binaryA,
            slot: .primary,
            kind: .decodedExecutableInstruction
        )
        owner = DebuggerBreakpointResolutionOwnerIndex(
            coordinate: owner.coordinate,
            revision: owner.revision,
            segments: owner.segments,
            staticAddresses: owner.staticAddresses,
            functions: [],
            hasCanonicalRawSymbolAuthority: true,
            rawSymbols: [
                .init(exactRawLinkageName: "_dup", kind: "code", libraryName: "A", preferredVA: 0x1010),
                .init(exactRawLinkageName: "_dup", kind: "resolver", libraryName: "B", preferredVA: 0x1010),
            ],
            hasExactSourceAuthority: false,
            sourceRows: []
        )
        let specification = try makeSymbolSpecification(
            id: logicalA,
            owner: seal(owner),
            exactName: "_dup",
            kind: nil,
            libraryName: nil,
            cardinality: .allExactMatches
        )
        let fixture = try makeFixture(owners: [owner], specifications: [specification])
        let projection = try makeProjection(owners: [owner], permissions: [5])

        XCTAssertEqual(
            DebuggerLogicalBreakpointResolver.resolve(
                catalog: fixture.logicalCatalog,
                coordinate: fixture.logicalCoordinate,
                resolutionCatalog: fixture.resolutionCatalog,
                requiringResolutionCoordinate: fixture.resolutionCatalog.coordinate,
                runtimeProjection: projection,
                requiringMappingKey: projection.key
            ).first?.state,
            .pending(.runtimeAddressCollision)
        )
    }

    func testSameAddressDistinctFullSourceEvidenceIsNotCollapsed() throws {
        var owner = try makeOwner(
            binaryID: binaryA,
            slot: .primary,
            kind: .decodedExecutableInstruction
        )
        let file = try makeSourceFile()
        owner = DebuggerBreakpointResolutionOwnerIndex(
            coordinate: owner.coordinate,
            revision: owner.revision,
            segments: owner.segments,
            staticAddresses: owner.staticAddresses,
            functions: [],
            hasCanonicalRawSymbolAuthority: false,
            rawSymbols: [],
            hasExactSourceAuthority: true,
            sourceRows: [
                .init(file: file, line: 12, column: 1, preferredVA: 0x1010, isEndSequence: false),
                .init(file: file, line: 12, column: 2, preferredVA: 0x1010, isEndSequence: false),
            ]
        )
        let specification = try makeSourceSpecification(
            owner: seal(owner),
            file: file,
            cardinality: .allExactMatches
        )
        let fixture = try makeFixture(owners: [owner], specifications: [specification])
        let projection = try makeProjection(owners: [owner], permissions: [5])

        XCTAssertEqual(
            DebuggerLogicalBreakpointResolver.resolve(
                catalog: fixture.logicalCatalog,
                coordinate: fixture.logicalCoordinate,
                resolutionCatalog: fixture.resolutionCatalog,
                requiringResolutionCoordinate: fixture.resolutionCatalog.coordinate,
                runtimeProjection: projection,
                requiringMappingKey: projection.key
            ).first?.state,
            .pending(.runtimeAddressCollision)
        )
    }

    func testTwoModuleInstancesCollapsingToOneRuntimeAddressRemainPending() throws {
        let owner = try makeOwner(binaryID: binaryA, slot: .primary, kind: .decodedExecutableInstruction)
        let specification = try makeSpecification(
            id: logicalA,
            owner: seal(owner),
            targetAddress: 0x1010
        )
        let fixture = try makeFixture(owners: [owner], specifications: [specification])
        let key = makeMappingKey()
        let firstID = makeInstanceID(key: key, ordinal: 0)
        let secondID = makeInstanceID(key: key, ordinal: 1)
        let projection = DebuggerRuntimeMappingProjection(
            key: key,
            modules: [
                try makeRuntimeModule(owner: owner, id: firstID, runtimeStart: 0x9000, permissions: 5),
                try makeRuntimeModule(owner: owner, id: secondID, runtimeStart: 0x9000, permissions: 5),
            ]
        )

        let result = try XCTUnwrap(DebuggerLogicalBreakpointResolver.resolve(
            catalog: fixture.logicalCatalog,
            coordinate: fixture.logicalCoordinate,
            resolutionCatalog: fixture.resolutionCatalog,
            requiringResolutionCoordinate: fixture.resolutionCatalog.coordinate,
            runtimeProjection: projection,
            requiringMappingKey: projection.key
        ).first)
        XCTAssertEqual(result.state, .pending(.runtimeAddressCollision))
    }

    func testOverlappingExecutableRangesRemainPendingBeforeIssuance() throws {
        let owner = try makeOwner(
            binaryID: binaryA,
            slot: .primary,
            kind: .decodedExecutableInstruction
        )
        let specification = try makeSpecification(
            id: logicalA,
            owner: seal(owner),
            targetAddress: 0x1010
        )
        let fixture = try makeFixture(owners: [owner], specifications: [specification])
        let key = makeMappingKey()
        let instanceID = makeInstanceID(key: key, ordinal: 0)
        let primary = try makeRuntimeModule(
            owner: owner,
            id: instanceID,
            runtimeStart: 0x9000,
            permissions: 5
        )
        let overlapping = try XCTUnwrap(DebuggerRuntimeMappedRange(
            moduleInstanceID: instanceID,
            sourceSectionOrdinal: 1,
            segmentName: "__TEXT",
            staticStart: 0x1008,
            runtimeStart: 0x9008,
            byteCount: 0x80,
            permissions: 5
        ))
        let projection = DebuggerRuntimeMappingProjection(
            key: key,
            modules: [DebuggerCorrelatedRuntimeModule(
                instanceID: instanceID,
                coordinate: owner.coordinate,
                mappedRanges: primary.mappedRanges + [overlapping]
            )]
        )

        let result = try XCTUnwrap(DebuggerLogicalBreakpointResolver.resolve(
            catalog: fixture.logicalCatalog,
            coordinate: fixture.logicalCoordinate,
            resolutionCatalog: fixture.resolutionCatalog,
            requiringResolutionCoordinate: fixture.resolutionCatalog.coordinate,
            runtimeProjection: projection,
            requiringMappingKey: projection.key
        ).first)

        XCTAssertEqual(result.state, .pending(.runtimeAddressNotExecutable))
    }

    func testStaleCoordinatesAndUnsealedSourceAuthorityStayPending() throws {
        let owner = try makeOwner(binaryID: binaryA, slot: .primary, kind: .decodedExecutableInstruction)
        let source = try makeSourceSpecification(owner: seal(owner))
        let fixture = try makeFixture(owners: [owner], specifications: [source])
        let projection = try makeProjection(owners: [owner], permissions: [5])
        let stale = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: workspaceID,
            revision: .init(rawValue: 99),
            workspaceArtifactCatalogRevision: .init(rawValue: 9)
        )
        XCTAssertEqual(
            DebuggerLogicalBreakpointResolver.resolve(
                catalog: fixture.logicalCatalog,
                coordinate: fixture.logicalCoordinate,
                resolutionCatalog: fixture.resolutionCatalog,
                requiringResolutionCoordinate: stale,
                runtimeProjection: projection,
                requiringMappingKey: projection.key
            ).first?.state,
            .pending(.resolutionCatalogStale)
        )
        XCTAssertEqual(
            DebuggerLogicalBreakpointResolver.resolve(
                catalog: fixture.logicalCatalog,
                coordinate: fixture.logicalCoordinate,
                resolutionCatalog: fixture.resolutionCatalog,
                requiringResolutionCoordinate: fixture.resolutionCatalog.coordinate,
                runtimeProjection: projection,
                requiringMappingKey: projection.key
            ).first?.state,
            .pending(.sourceAuthorityUnavailable)
        )
    }

    private struct Fixture {
        let logicalCatalog: DebuggerLogicalBreakpointCatalog
        let logicalCoordinate: DebuggerLogicalBreakpointCatalogCoordinate
        let resolutionCatalog: DebuggerBreakpointResolutionCatalog
    }

    private let workspaceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let catalogID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let logicalA = DebuggerLogicalBreakpointID(
        rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )
    private let logicalB = DebuggerLogicalBreakpointID(
        rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    )
    private let binaryA = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let binaryB = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func makeFixture(
        owners: [DebuggerBreakpointResolutionOwnerIndex],
        specifications: [DebuggerLogicalBreakpointSpecification]
    ) throws -> Fixture {
        let logicalCatalog = try DebuggerLogicalBreakpointCatalog(
            catalogID: catalogID,
            revision: 1,
            specifications: specifications
        )
        let coordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: workspaceID,
            catalogID: catalogID,
            revision: 1
        )
        let resolutionCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: workspaceID,
            revision: .init(rawValue: 7),
            workspaceArtifactCatalogRevision: .init(rawValue: 9)
        )
        return Fixture(
            logicalCatalog: logicalCatalog,
            logicalCoordinate: coordinate,
            resolutionCatalog: DebuggerBreakpointResolutionCatalog(
                coordinate: resolutionCoordinate,
                owners: owners
            )
        )
    }

    private func makeOwner(
        binaryID: UUID,
        slot: ImageSlot,
        kind: DebuggerBreakpointStaticAddressKind
    ) throws -> DebuggerBreakpointResolutionOwnerIndex {
        let coordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: binaryID,
            slot: slot,
            artifactIdentity: try makeArtifactIdentity(binaryID: binaryID),
            ownerRevision: .init(rawValue: 3)
        )
        return DebuggerBreakpointResolutionOwnerIndex(
            coordinate: coordinate,
            revision: 4,
            segments: [try XCTUnwrap(DebuggerBreakpointResolutionSegment(
                name: kind == .data ? "__DATA" : "__TEXT",
                preferredStart: 0x1000,
                byteCount: 0x100,
                isExecutable: kind != .data
            ))],
            staticAddresses: [.init(
                preferredVA: 0x1010,
                segmentName: kind == .data ? "__DATA" : "__TEXT",
                kind: kind
            )],
            functions: [],
            hasCanonicalRawSymbolAuthority: false,
            rawSymbols: [],
            hasExactSourceAuthority: false,
            sourceRows: []
        )
    }

    private func makeArtifactIdentity(binaryID: UUID) throws -> MachOSliceArtifactIdentity {
        try MachOSliceArtifactIdentity(
            uuid: binaryID,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: binaryID == binaryA
                ? String(repeating: "a", count: 64)
                : String(repeating: "b", count: 64),
            selectedSliceByteCount: 0x10_000
        )
    }

    private func seal(
        _ owner: DebuggerBreakpointResolutionOwnerIndex
    ) -> DebuggerWorkspaceImageOwnerSeal {
        DebuggerWorkspaceImageOwnerSeal(
            slot: owner.coordinate.slot,
            binaryID: owner.coordinate.binaryID,
            artifactIdentity: owner.coordinate.artifactIdentity
        )
    }

    private func makeSpecification(
        id: DebuggerLogicalBreakpointID,
        owner: DebuggerWorkspaceImageOwnerSeal,
        targetAddress: UInt64
    ) throws -> DebuggerLogicalBreakpointSpecification {
        try DebuggerLogicalBreakpointSpecification(
            id: id,
            revision: try .init(validating: 1),
            enabled: true,
            target: .preferredAddress(owner: owner, preferredVA: targetAddress),
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
    }

    private func makeSymbolSpecification(
        id: DebuggerLogicalBreakpointID,
        owner: DebuggerWorkspaceImageOwnerSeal,
        exactName: String = "_dup",
        kind: String? = "function",
        libraryName: String? = nil,
        cardinality: DebuggerLogicalBreakpointCardinality
    ) throws -> DebuggerLogicalBreakpointSpecification {
        try DebuggerLogicalBreakpointSpecification(
            id: id,
            revision: try .init(validating: 1),
            enabled: true,
            target: .symbol(
                owner: owner,
                exactRawLinkageName: exactName,
                kind: kind,
                libraryName: libraryName,
                cardinality: cardinality
            ),
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
    }

    private func makeSourceSpecification(
        owner: DebuggerWorkspaceImageOwnerSeal,
        file: DebuggerCanonicalSourceFileIdentity? = nil,
        cardinality: DebuggerLogicalBreakpointCardinality = .exactlyOne
    ) throws -> DebuggerLogicalBreakpointSpecification {
        let file = try file ?? makeSourceFile()
        return try DebuggerLogicalBreakpointSpecification(
            id: logicalA,
            revision: try .init(validating: 1),
            enabled: true,
            target: .source(
                owner: owner,
                file: file,
                line: 12,
                columnPolicy: .any,
                cardinality: cardinality
            ),
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
    }

    private func makeSourceFile() throws -> DebuggerCanonicalSourceFileIdentity {
        try DebuggerCanonicalSourceFileIdentity(
            debugArtifactUUID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            debugArtifactMachOSHA256: String(repeating: "c", count: 64),
            debugArtifactMachOByteCount: 1024,
            lineProgramUnitOffset: 32,
            fileTableIndex: 1,
            tablePath: .absoluteUTF8("/src/main.c")
        )
    }

    private func makeMappingKey() -> DebuggerRuntimeMappingProjectionKey {
        DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: DebuggerStopCoordinate(
                session: DebuggerSessionCoordinate(
                    epoch: .init(rawValue: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!),
                    lifecycleRevision: .init(rawValue: 2)
                ),
                stopRevision: .init(rawValue: 3)
            ),
            observedPID: 42,
            authorityRevision: .init(rawValue: 5),
            inventoryRevision: .init(rawValue: 6),
            workspaceCatalogRevision: .init(rawValue: 9)
        )
    }

    private func makeInstanceID(
        key: DebuggerRuntimeMappingProjectionKey,
        ordinal: UInt32
    ) -> DebuggerRuntimeModuleInstanceID {
        DebuggerRuntimeModuleInstanceID(
            processID: key.observedPID,
            stop: key.stopCoordinate,
            inventoryRevision: key.inventoryRevision,
            ordinal: ordinal
        )
    }

    private func makeProjection(
        owners: [DebuggerBreakpointResolutionOwnerIndex],
        permissions: [UInt8]
    ) throws -> DebuggerRuntimeMappingProjection {
        let key = makeMappingKey()
        return DebuggerRuntimeMappingProjection(
            key: key,
            modules: try zip(owners, permissions).enumerated().map { index, pair in
                try makeRuntimeModule(
                    owner: pair.0,
                    id: makeInstanceID(key: key, ordinal: UInt32(index)),
                    runtimeStart: 0x9000 + UInt64(index) * 0x1000,
                    permissions: pair.1
                )
            }
        )
    }

    private func makeRuntimeModule(
        owner: DebuggerBreakpointResolutionOwnerIndex,
        id: DebuggerRuntimeModuleInstanceID,
        runtimeStart: UInt64,
        permissions: UInt8
    ) throws -> DebuggerCorrelatedRuntimeModule {
        let segment = try XCTUnwrap(owner.segments.first)
        let range = try XCTUnwrap(DebuggerRuntimeMappedRange(
            moduleInstanceID: id,
            sourceSectionOrdinal: 0,
            segmentName: segment.name,
            staticStart: segment.preferredStart,
            runtimeStart: runtimeStart,
            byteCount: segment.byteCount,
            permissions: permissions
        ))
        return DebuggerCorrelatedRuntimeModule(
            instanceID: id,
            coordinate: owner.coordinate,
            mappedRanges: [range]
        )
    }
}
