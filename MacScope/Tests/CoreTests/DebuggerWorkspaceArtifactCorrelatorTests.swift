import XCTest
@testable import MacScope

final class DebuggerWorkspaceArtifactCorrelatorTests: XCTestCase {
    func testExactUUIDArchitectureAndSegmentContainmentProduceProjection() throws {
        let fixture = try Fixture()
        let catalog = DebuggerWorkspaceArtifactCatalog(
            revision: .init(rawValue: 9),
            artifacts: [fixture.entry()]
        )
        let projection = DebuggerWorkspaceArtifactCorrelator().correlate(
            inventory: fixture.inventory(),
            authorityRevision: .init(rawValue: 12),
            catalog: catalog
        )

        XCTAssertEqual(projection.key.workspaceCatalogRevision, .init(rawValue: 9))
        XCTAssertEqual(projection.modules.count, 1)
        XCTAssertEqual(projection.modules[0].coordinate.binaryID, fixture.binaryID)
        XCTAssertEqual(projection.modules[0].coordinate.slot, .primary)
        XCTAssertEqual(projection.modules[0].mappedRanges.count, 1)
        XCTAssertEqual(projection.modules[0].mappedRanges[0].segmentName, "__TEXT")
    }

    func testDuplicateExactArtifactsRemainAmbiguousAndDoNotProject() throws {
        let fixture = try Fixture()
        let second = fixture.entry(
            binaryID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            slot: ImageSlot(rawValue: 1),
            ownerRevision: .init(rawValue: 2)
        )
        let catalog = DebuggerWorkspaceArtifactCatalog(
            revision: .init(rawValue: 10),
            artifacts: [second, fixture.entry()]
        )
        let instance = fixture.inventory().modules[0]
        let result = DebuggerWorkspaceArtifactCorrelator().correlation(
            for: instance,
            catalog: catalog
        )

        guard case let .ambiguous(candidateIDs) = result else {
            return XCTFail("Expected exact duplicate artifacts to remain ambiguous")
        }
        XCTAssertEqual(candidateIDs, [fixture.binaryID, second.binaryID])
        XCTAssertTrue(DebuggerWorkspaceArtifactCorrelator().correlate(
            inventory: fixture.inventory(),
            authorityRevision: .init(rawValue: 1),
            catalog: catalog
        ).modules.isEmpty)
    }

    func testMissingOrZeroRuntimeUUIDNeverFallsBackToPathNameOrIndex() throws {
        let fixture = try Fixture()
        let catalog = DebuggerWorkspaceArtifactCatalog(
            revision: .init(rawValue: 1),
            artifacts: [fixture.entry(sourcePathHint: "/same/MacScope", executablePathHint: "/same/MacScope")]
        )
        let instances = [
            fixture.instance(useMissingUUID: true),
            fixture.instance(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        ]
        for instance in instances {
            let result = DebuggerWorkspaceArtifactCorrelator().correlation(for: instance, catalog: catalog)
            XCTAssertEqual(result, .unresolved(reason: .missingRuntimeUUID))
        }
        XCTAssertEqual(DebuggerWorkspaceArtifactCorrelator().correlation(
            for: fixture.instance(uuid: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")),
            catalog: catalog
        ), .unresolved(reason: .noCompatibleWorkspaceArtifact))
    }

    func testCatalogNormalizesBoundedAbsolutePathHintsWithoutUsingThemAsAuthority() throws {
        let fixture = try Fixture()
        let entry = fixture.entry(
            sourcePathHint: "/tmp/one/../MacScope",
            executablePathHint: "relative/MacScope"
        )
        XCTAssertEqual(entry.sourcePathHint, "/tmp/MacScope")
        XCTAssertNil(entry.executablePathHint)
    }

    func testArchitectureMatchingIsExactAndAppleMacOSOnly() throws {
        let arm64 = try Fixture(variant: .arm64)
        let arm64e = try Fixture(variant: .arm64e)
        let correlator = DebuggerWorkspaceArtifactCorrelator()

        XCTAssertMatched(correlator.correlation(
            for: arm64.instance(triple: "arm64-apple-macosx27.0.0"),
            catalog: .init(revision: .init(rawValue: 1), artifacts: [arm64.entry()])
        ))
        XCTAssertMatched(correlator.correlation(
            for: arm64e.instance(triple: "arm64e-apple-macosx27.1"),
            catalog: .init(revision: .init(rawValue: 1), artifacts: [arm64e.entry()])
        ))
        XCTAssertEqual(correlator.correlation(
            for: arm64.instance(triple: "arm64e-apple-macosx27.0"),
            catalog: .init(revision: .init(rawValue: 1), artifacts: [arm64.entry()])
        ), .unresolved(reason: .noCompatibleWorkspaceArtifact))
        XCTAssertEqual(correlator.correlation(
            for: arm64.instance(triple: "arm64-unknown-macosx27.0"),
            catalog: .init(revision: .init(rawValue: 1), artifacts: [arm64.entry()])
        ), .unresolved(reason: .unsupportedRuntimeArchitecture))
        for malformed in [
            "arm64-apple-macosxevil",
            "arm64-apple-macosx27..0",
            "arm64-apple-macosx27.0-simulator"
        ] {
            XCTAssertEqual(correlator.correlation(
                for: arm64.instance(triple: malformed),
                catalog: .init(revision: .init(rawValue: 1), artifacts: [arm64.entry()])
            ), .unresolved(reason: .unsupportedRuntimeArchitecture))
        }
    }

    func testEveryRangeRequiresUniqueSameNamePreferredSegmentContainment() throws {
        let fixture = try Fixture()
        let correlator = DebuggerWorkspaceArtifactCorrelator()
        let missingNameLayout = try MachOPreferredSegmentLayout(
            records: [fixture.segment(name: "__DATA")],
            selectedSliceByteCount: 0x4000
        )
        let overlappingLayout = try MachOPreferredSegmentLayout(
            records: [fixture.segment(), fixture.segment(start: 0x0fff_f800)],
            selectedSliceByteCount: 0x4000
        )

        for entry in [
            fixture.entry(includeLayout: false),
            fixture.entry(layout: missingNameLayout),
            fixture.entry(layout: overlappingLayout)
        ] {
            XCTAssertEqual(correlator.correlation(
                for: fixture.inventory().modules[0],
                catalog: .init(revision: .init(rawValue: 1), artifacts: [entry])
            ), .unresolved(reason: .noCompatibleWorkspaceArtifact))
        }
    }

    func testNoMappedRangesOrOneIncompatibleRangeMakesWholeModuleUnresolved() throws {
        let fixture = try Fixture()
        let catalog = DebuggerWorkspaceArtifactCatalog(
            revision: .init(rawValue: 1),
            artifacts: [fixture.entry()]
        )
        let correlator = DebuggerWorkspaceArtifactCorrelator()
        XCTAssertEqual(correlator.correlation(
            for: fixture.instance(mappedRanges: []),
            catalog: catalog
        ), .unresolved(reason: .noMappedRanges))

        XCTAssertEqual(correlator.correlation(
            for: fixture.instance(mappedRanges: [
                fixture.observedRange(),
                fixture.observedRange(name: "__DATA", staticStart: 0x1000_0200)
            ]),
            catalog: catalog
        ), .unresolved(reason: .noCompatibleWorkspaceArtifact))
    }

    func testProjectionRejectsModuleCoordinatesThatDoNotBelongToInventory() throws {
        let fixture = try Fixture()
        let mismatched = fixture.inventory(modules: [fixture.instance(instanceProcessID: 45)])
        XCTAssertTrue(DebuggerWorkspaceArtifactCorrelator().correlate(
            inventory: mismatched,
            authorityRevision: .init(rawValue: 1),
            catalog: .init(revision: .init(rawValue: 1), artifacts: [fixture.entry()])
        ).modules.isEmpty)
    }

    func testCatalogAndOwnerRevisionsIncrementWithoutWrapping() {
        XCTAssertEqual(
            DebuggerWorkspaceArtifactCatalogRevision(rawValue: 3).incremented(),
            .init(rawValue: 4)
        )
        XCTAssertEqual(
            DebuggerWorkspaceArtifactOwnerRevision(rawValue: 5).incremented(),
            .init(rawValue: 6)
        )
        XCTAssertNil(DebuggerWorkspaceArtifactCatalogRevision(rawValue: .max).incremented())
        XCTAssertNil(DebuggerWorkspaceArtifactOwnerRevision(rawValue: .max).incremented())
    }

    func testMissingWorkspaceUUIDCannotUseOtherwiseMatchingEvidence() throws {
        let fixture = try Fixture()
        XCTAssertEqual(DebuggerWorkspaceArtifactCorrelator().correlation(
            for: fixture.inventory().modules[0],
            catalog: .init(
                revision: .init(rawValue: 1),
                artifacts: [fixture.entry(includeIdentity: false)]
            )
        ), .unresolved(reason: .noCompatibleWorkspaceArtifact))
    }

    func testOnlyVerifiedEvidenceCanCorrelate() throws {
        let fixture = try Fixture()
        let correlator = DebuggerWorkspaceArtifactCorrelator()
        for state in [MachOSliceArtifactIntegrityState.unavailable, .contradictoryEvidence(diagnostic: "bounded")] {
            XCTAssertEqual(correlator.correlation(
                for: fixture.inventory().modules[0],
                catalog: .init(revision: .init(rawValue: 1), artifacts: [fixture.entry(integrity: state)])
            ), .unresolved(reason: .noCompatibleWorkspaceArtifact))
        }
    }

    func testOwnerAndCatalogRevisionsArePartOfProjectionIdentity() throws {
        let fixture = try Fixture()
        let first = DebuggerWorkspaceArtifactCorrelator().correlate(
            inventory: fixture.inventory(),
            authorityRevision: .init(rawValue: 4),
            catalog: .init(revision: .init(rawValue: 7), artifacts: [fixture.entry(ownerRevision: .init(rawValue: 2))])
        )
        let ownerReplacement = DebuggerWorkspaceArtifactCorrelator().correlate(
            inventory: fixture.inventory(),
            authorityRevision: .init(rawValue: 4),
            catalog: .init(revision: .init(rawValue: 7), artifacts: [fixture.entry(
                ownerRevision: .init(rawValue: 3)
            )])
        )
        let catalogReplacement = DebuggerWorkspaceArtifactCorrelator().correlate(
            inventory: fixture.inventory(),
            authorityRevision: .init(rawValue: 4),
            catalog: .init(revision: .init(rawValue: 8), artifacts: [fixture.entry(
                ownerRevision: .init(rawValue: 2)
            )])
        )

        XCTAssertEqual(first.key, ownerReplacement.key)
        XCTAssertNotEqual(first.modules[0].coordinate, ownerReplacement.modules[0].coordinate)
        XCTAssertNotEqual(first.key, catalogReplacement.key)
        XCTAssertEqual(first.modules[0].coordinate, catalogReplacement.modules[0].coordinate)
    }

    private func XCTAssertMatched(
        _ result: DebuggerWorkspaceArtifactCorrelation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .matched = result else {
            return XCTFail("Expected a match, got \(result)", file: file, line: line)
        }
    }
}

private struct Fixture {
    let uuid = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let binaryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let variant: MachOSliceArchitectureVariant
    let identity: MachOSliceArtifactIdentity
    let layout: MachOPreferredSegmentLayout
    let stop = DebuggerStopCoordinate(
        session: .init(
            epoch: .init(rawValue: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!),
            lifecycleRevision: .init(rawValue: 2)
        ),
        stopRevision: .init(rawValue: 3)
    )

    init(variant: MachOSliceArchitectureVariant = .arm64) throws {
        self.variant = variant
        let subtype: Int32 = variant == .arm64e ? 2 : 0
        identity = try MachOSliceArtifactIdentity(
            uuid: uuid,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: subtype,
            selectedSliceSHA256: String(repeating: "a", count: 64),
            selectedSliceByteCount: 0x4000
        )
        layout = try MachOPreferredSegmentLayout(
            records: [Self.makeSegment()],
            selectedSliceByteCount: 0x4000
        )
    }

    func segment(name: String = "__TEXT", start: UInt64 = 0x1000_0000) -> MachOPreferredSegmentLayout.Record {
        Self.makeSegment(name: name, start: start)
    }

    private static func makeSegment(name: String = "__TEXT", start: UInt64 = 0x1000_0000) -> MachOPreferredSegmentLayout.Record {
        .init(
            name: name,
            preferredVMStart: start,
            preferredVMSize: 0x2000,
            sliceRelativeFileOffset: 0,
            fileSize: 0x2000,
            initialProtections: 5
        )
    }

    func entry(
        binaryID: UUID? = nil,
        slot: ImageSlot = .primary,
        ownerRevision: DebuggerWorkspaceArtifactOwnerRevision = .init(rawValue: 1),
        layout: MachOPreferredSegmentLayout? = nil,
        includeIdentity: Bool = true,
        includeLayout: Bool = true,
        integrity: MachOSliceArtifactIntegrityState = .verified,
        sourcePathHint: String? = nil,
        executablePathHint: String? = nil
    ) -> DebuggerWorkspaceArtifactCatalogEntry {
        .init(
            binaryID: binaryID ?? self.binaryID,
            slot: slot,
            ownerRevision: ownerRevision,
            artifactIdentity: includeIdentity ? identity : nil,
            preferredSegmentLayout: includeLayout ? (layout ?? self.layout) : nil,
            artifactIntegrityState: integrity,
            sourcePathHint: sourcePathHint,
            executablePathHint: executablePathHint
        )
    }

    func inventory(modules: [DebuggerRuntimeModuleInstance]? = nil) -> DebuggerRuntimeModuleInventory {
        .init(
            revision: .init(rawValue: 5),
            stop: stop,
            processID: 44,
            observedStopID: 8,
            modules: modules ?? [instance()]
        )
    }

    func observedRange(
        name: String = "__TEXT",
        staticStart: UInt64 = 0x1000_0100,
        runtimeStart: UInt64 = 0x2000_0100
    ) -> DebuggerRuntimeModuleMappedRangeObservation {
        .init(
            sectionOrdinal: name == "__TEXT" ? 0 : 1,
            sectionName: name,
            staticStart: staticStart,
            runtimeStart: runtimeStart,
            byteCount: 0x100,
            permissions: 5
        )!
    }

    func instance(
        uuid: UUID? = nil,
        triple: String? = nil,
        useMissingUUID: Bool = false,
        mappedRanges: [DebuggerRuntimeModuleMappedRangeObservation]? = nil,
        instanceProcessID: Int32 = 44
    ) -> DebuggerRuntimeModuleInstance {
        let actualUUID: UUID? = useMissingUUID ? nil : (uuid ?? self.uuid)
        let observation = DebuggerRuntimeModuleObservation(
            uuid: actualUUID,
            processID: 44,
            observedStopID: 8,
            mappedRanges: mappedRanges ?? [observedRange()],
            fullPath: "/same/MacScope",
            normalizedArchitectureTriple: triple ?? (variant == .arm64e ? "arm64e-apple-macosx27.0" : "arm64-apple-macosx27.0"),
            displayIndex: 0,
            fingerprintSHA256: Data(repeating: 7, count: 32)
        )!
        return .init(
            id: .init(processID: instanceProcessID, stop: stop, inventoryRevision: .init(rawValue: 5), ordinal: 0),
            observation: observation
        )
    }
}
