import XCTest
@testable import MacScope

final class DebuggerSourceInspectionModelTests: XCTestCase {
    func testSourceInspectionValuesAreSendableAndHashable() {
        Self.assertSendableAndHashable(DebuggerSourceDebugArtifactIdentity.self)
        Self.assertSendableAndHashable(DebuggerSourceFileInspectionIdentity.self)
        Self.assertSendableAndHashable(DebuggerSourceInspectionContext.self)
        Self.assertSendableAndHashable(DebuggerSourceInspectionResolution.self)
        Self.assertSendableAndHashable(DebuggerSourceInspectionFreshness.self)
    }

    func testSourceInspectionRejectsUnrepresentableDecodedCoordinates() throws {
        let fixture = try Self.fixture()
        for invalid in [-1, Int(UInt32.max) + 1, Int.max] {
            for keyPath in [\SourceLineEntry.line, \SourceLineEntry.column] {
                var row = fixture.sourceLine
                row[keyPath: keyPath] = invalid
                let decoded = try JSONDecoder().decode(
                    SourceLineEntry.self,
                    from: JSONEncoder().encode(row)
                )
                XCTAssertNil(
                    DebuggerSourceFileInspectionIdentity(sourceLine: decoded),
                    "Expected a rejected source coordinate for \(invalid)"
                )
            }
        }
    }

    func testSourceInspectionPreservesRepresentableCoordinateBoundaries() throws {
        let fixture = try Self.fixture()
        for boundary in [UInt32(0), UInt32.max] {
            var row = fixture.sourceLine
            row.line = Int(boundary)
            row.column = Int(boundary)
            let identity = try XCTUnwrap(
                DebuggerSourceFileInspectionIdentity(sourceLine: row)
            )
            XCTAssertEqual(identity.line, boundary)
            XCTAssertEqual(identity.column, boundary)
            XCTAssertEqual(identity.preferredVA, row.address)
        }
    }

    func testResolverBuildsExactSourceContextFromRuntimeStaticTranslationAndLineEvidence() throws {
        let fixture = try Self.fixture()

        let resolution = DebuggerSourceInspectionResolver.resolve(
            coordinate: fixture.coordinate,
            resolvedAddress: fixture.resolvedAddress,
            sourceLines: [fixture.sourceLine],
            focusedImageSlot: .primary
        )

        guard case .resolved(let context) = resolution else {
            return XCTFail("Expected resolved source context, got \(resolution)")
        }
        XCTAssertEqual(context.coordinate, fixture.coordinate)
        XCTAssertEqual(context.mappingKey, fixture.mappingKey)
        XCTAssertEqual(context.workspaceCoordinate, fixture.workspaceCoordinate)
        XCTAssertEqual(context.imageAddress, ImageAddress.primary(Self.staticAddress))
        XCTAssertEqual(context.runtimeAddress, Self.runtimeAddress)
        XCTAssertEqual(context.source.line, 42)
        XCTAssertEqual(context.source.column, 7)
        XCTAssertEqual(context.debugArtifact.uuid, Self.binaryUUID)
    }

    func testResolverRejectsRowsWithoutCompleteDebugArtifactSeal() throws {
        let fixture = try Self.fixture()
        var legacyRow = fixture.sourceLine
        legacyRow.debugArtifactUUID = nil

        XCTAssertEqual(
            DebuggerSourceInspectionResolver.resolve(
                coordinate: fixture.coordinate,
                resolvedAddress: fixture.resolvedAddress,
                sourceLines: [legacyRow]
            ),
            .unavailable(.noDebugArtifactSeal)
        )
    }

    func testResolverRejectsDebugArtifactUUIDMismatch() throws {
        let fixture = try Self.fixture()
        var wrongRow = fixture.sourceLine
        wrongRow.debugArtifactUUID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        XCTAssertEqual(
            DebuggerSourceInspectionResolver.resolve(
                coordinate: fixture.coordinate,
                resolvedAddress: fixture.resolvedAddress,
                sourceLines: [wrongRow]
            ),
            .unavailable(.debugArtifactMismatch)
        )
    }

    func testResolverReportsAmbiguousExactSourceEvidence() throws {
        let fixture = try Self.fixture()
        var second = fixture.sourceLine
        second.lineProgramUnitOffset = 99

        let resolution = DebuggerSourceInspectionResolver.resolve(
            coordinate: fixture.coordinate,
            resolvedAddress: fixture.resolvedAddress,
            sourceLines: [fixture.sourceLine, second]
        )

        guard case .ambiguous(let candidates) = resolution else {
            return XCTFail("Expected ambiguous source evidence, got \(resolution)")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    func testResolverRejectsFocusDebuggedImageMismatch() throws {
        let fixture = try Self.fixture()

        XCTAssertEqual(
            DebuggerSourceInspectionResolver.resolve(
                coordinate: fixture.coordinate,
                resolvedAddress: fixture.resolvedAddress,
                sourceLines: [fixture.sourceLine],
                focusedImageSlot: ImageSlot(rawValue: 9)
            ),
            .unavailable(.focusDebuggedImageMismatch)
        )
    }

    func testSourceFreshnessRejectsStopMappingWorkspaceAndFocusDrift() throws {
        let fixture = try Self.fixture()
        let context = try fixture.resolvedContext()

        XCTAssertEqual(
            DebuggerSourceInspectionFreshnessPolicy.evaluate(
                cached: context,
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.runtimeAddress)),
                currentMappingKey: fixture.mappingKey,
                currentWorkspaceCoordinate: fixture.workspaceCoordinate,
                focusedImageSlot: .primary
            ),
            .fresh(context)
        )
        XCTAssertEqual(
            DebuggerSourceInspectionFreshnessPolicy.evaluate(
                cached: context,
                currentStop: Self.stop(stopRevision: 2),
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.runtimeAddress)),
                currentMappingKey: fixture.mappingKey,
                currentWorkspaceCoordinate: fixture.workspaceCoordinate,
                focusedImageSlot: .primary
            ),
            .stale(.stopChanged)
        )
        XCTAssertEqual(
            DebuggerSourceInspectionFreshnessPolicy.evaluate(
                cached: context,
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.runtimeAddress)),
                currentMappingKey: Self.mappingKey(stop: fixture.stop, inventoryRevision: 44),
                currentWorkspaceCoordinate: fixture.workspaceCoordinate,
                focusedImageSlot: .primary
            ),
            .stale(.runtimeModuleEvidenceChanged)
        )
        XCTAssertEqual(
            DebuggerSourceInspectionFreshnessPolicy.evaluate(
                cached: context,
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.runtimeAddress)),
                currentMappingKey: fixture.mappingKey,
                currentWorkspaceCoordinate: nil,
                focusedImageSlot: .primary
            ),
            .stale(.debugArtifactEvidenceChanged)
        )
        XCTAssertEqual(
            DebuggerSourceInspectionFreshnessPolicy.evaluate(
                cached: context,
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.runtimeAddress)),
                currentMappingKey: fixture.mappingKey,
                currentWorkspaceCoordinate: fixture.workspaceCoordinate,
                focusedImageSlot: ImageSlot(rawValue: 4)
            ),
            .unavailable(.focusDebuggedImageMismatch)
        )
    }

    private struct Fixture {
        let stop: DebuggerStopCoordinate
        let authority: DebuggerSessionTargetAuthority
        let thread: DebuggerThreadIdentity
        let frame: DebuggerFrameIdentity
        let coordinate: DebuggerInspectionCoordinate
        let mappingKey: DebuggerRuntimeMappingProjectionKey
        let moduleInstanceID: DebuggerRuntimeModuleInstanceID
        let workspaceCoordinate: DebuggerWorkspaceArtifactCoordinate
        let resolvedAddress: DebuggerResolvedStaticAddress
        let sourceLine: SourceLineEntry

        func resolvedContext() throws -> DebuggerSourceInspectionContext {
            let resolution = DebuggerSourceInspectionResolver.resolve(
                coordinate: coordinate,
                resolvedAddress: resolvedAddress,
                sourceLines: [sourceLine],
                focusedImageSlot: .primary
            )
            guard case .resolved(let context) = resolution else {
                throw XCTSkip("source context did not resolve")
            }
            return context
        }
    }

    private static let binaryUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private static let binaryID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
    private static let staticAddress: UInt64 = 0x1_0000_1000
    private static let runtimeAddress: UInt64 = 0x2_0000_1000
    private static let artifactSHA = String(repeating: "a", count: 64)
    private static let debugArtifactSHA = String(repeating: "b", count: 64)

    private static func fixture() throws -> Fixture {
        let stop = Self.stop()
        let authority = try Self.authority(processID: 123)
        let thread = try XCTUnwrap(DebuggerThreadIdentity(index: 1, tid: 0xabc))
        let frame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: thread,
            frameIndex: 0,
            programCounter: Self.runtimeAddress,
            canonicalFunctionName: "main"
        ))
        let coordinate = try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: authority,
            thread: thread,
            frame: frame
        ))
        let mappingKey = Self.mappingKey(stop: stop)
        let moduleInstanceID = DebuggerRuntimeModuleInstanceID(
            processID: 123,
            stop: stop,
            inventoryRevision: mappingKey.inventoryRevision,
            ordinal: 0
        )
        let workspaceCoordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: Self.binaryID,
            slot: .primary,
            artifactIdentity: try Self.artifactIdentity(),
            ownerRevision: DebuggerWorkspaceArtifactOwnerRevision(rawValue: 5)
        )
        let resolvedAddress = DebuggerResolvedStaticAddress(
            projectionKey: mappingKey,
            moduleInstanceID: moduleInstanceID,
            workspaceCoordinate: workspaceCoordinate,
            runtimeAddress: Self.runtimeAddress,
            imageAddress: ImageAddress.primary(Self.staticAddress)
        )
        let sourceLine = SourceLineEntry(
            address: Self.staticAddress,
            file: "/src/main.c",
            line: 42,
            column: 7,
            endSequence: false,
            debugArtifactUUID: Self.binaryUUID,
            debugArtifactMachOSHA256: Self.debugArtifactSHA,
            debugArtifactMachOByteCount: 8_192,
            lineProgramUnitOffset: 12,
            fileTableIndex: 1,
            tablePath: .absoluteUTF8("/src/main.c")
        )
        return Fixture(
            stop: stop,
            authority: authority,
            thread: thread,
            frame: frame,
            coordinate: coordinate,
            mappingKey: mappingKey,
            moduleInstanceID: moduleInstanceID,
            workspaceCoordinate: workspaceCoordinate,
            resolvedAddress: resolvedAddress,
            sourceLine: sourceLine
        )
    }

    private static func mappingKey(
        stop: DebuggerStopCoordinate,
        inventoryRevision: UInt64 = 7
    ) -> DebuggerRuntimeMappingProjectionKey {
        DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: stop,
            observedPID: 123,
            authorityRevision: DebuggerRuntimeModuleAuthorityRevision(rawValue: 3),
            inventoryRevision: DebuggerRuntimeModuleInventoryRevision(rawValue: inventoryRevision),
            workspaceCatalogRevision: DebuggerWorkspaceArtifactCatalogRevision(rawValue: 11)
        )
    }

    private static func artifactIdentity() throws -> MachOSliceArtifactIdentity {
        try MachOSliceArtifactIdentity(
            uuid: Self.binaryUUID,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: Self.artifactSHA,
            selectedSliceByteCount: 16_384
        )
    }

    private static func stop(stopRevision: UInt64 = 1) -> DebuggerStopCoordinate {
        let epoch = DebuggerSessionEpoch(
            rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let session = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 3)
        )
        return DebuggerStopCoordinate(
            session: session,
            stopRevision: DebuggerStopRevision(rawValue: stopRevision)
        )
    }

    private static func authority(
        processID: Int32,
        executableSHA256: String = String(repeating: "a", count: 64)
    ) throws -> DebuggerSessionTargetAuthority {
        try DebuggerSessionTargetAuthority(origin: .attached(identity(
            processID: processID,
            executableSHA256: executableSHA256
        )))
    }

    private static func identity(
        processID: Int32,
        executableSHA256: String = String(repeating: "a", count: 64)
    ) throws -> DebuggerLocalProcessIdentity {
        let start = try XCTUnwrap(DebuggerProcessStartIdentity(seconds: 1_700_000_000, microseconds: 42))
        return try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: start,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture",
            executableDeviceID: 10,
            executableFileID: UInt64(processID) + 1_000,
            executableByteCount: 4096,
            executableSHA256: executableSHA256,
            architecture: .arm64,
            machOUUID: Self.binaryUUID,
            codeIdentity: nil
        ))
    }

    private static func assertSendableAndHashable<T: Sendable & Hashable>(_ type: T.Type) {}
}
