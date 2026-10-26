import XCTest
@testable import MacScope

final class DebuggerMemoryInspectionModelTests: XCTestCase {
    func testMemoryInspectionValuesAreSendableAndHashable() {
        Self.assertSendableAndHashable(DebuggerMemoryRange.self)
        Self.assertSendableAndHashable(DebuggerVMRegionPermissions.self)
        Self.assertSendableAndHashable(DebuggerVMRegionInspection.self)
        Self.assertSendableAndHashable(DebuggerMemoryPreview.self)
        Self.assertSendableAndHashable(DebuggerMemoryWritePreviewAuthorization.self)
    }

    func testMemoryRangeRejectsEmptyAndOverflowingRanges() {
        XCTAssertNotNil(DebuggerMemoryRange(start: 0x1000, byteCount: 1))
        XCTAssertTrue(try XCTUnwrap(DebuggerMemoryRange(start: UInt64.max, byteCount: 1)).contains(UInt64.max))
        XCTAssertNil(DebuggerMemoryRange(start: 0x1000, byteCount: 0))
        XCTAssertNil(DebuggerMemoryRange(start: UInt64.max, byteCount: 2))
    }

    func testVMRegionRequiresPermissionsValidPathAndPairedModuleCorrelation() throws {
        let fixture = try Self.fixture()
        let range = try XCTUnwrap(DebuggerMemoryRange(start: 0x2_0000_0000, byteCount: 0x1000))

        XCTAssertNotNil(DebuggerVMRegionInspection(
            coordinate: fixture.coordinate,
            range: range,
            permissions: [.read, .write],
            mappedPath: "/usr/lib/libfixture.dylib",
            moduleInstanceID: fixture.moduleInstanceID,
            workspaceCoordinate: fixture.workspaceCoordinate
        ))
        XCTAssertNil(DebuggerVMRegionInspection(
            coordinate: fixture.coordinate,
            range: range,
            permissions: [],
            mappedPath: nil
        ))
        XCTAssertNil(DebuggerVMRegionInspection(
            coordinate: fixture.coordinate,
            range: range,
            permissions: [.read],
            mappedPath: "relative/path"
        ))
        XCTAssertNil(DebuggerVMRegionInspection(
            coordinate: fixture.coordinate,
            range: range,
            permissions: [.read],
            moduleInstanceID: fixture.moduleInstanceID,
            workspaceCoordinate: nil
        ))
    }

    func testMemoryPreviewBoundsBytesAndDiagnostics() throws {
        let fixture = try Self.fixture()
        let region = try fixture.region(permissions: [.read])
        let request = try XCTUnwrap(DebuggerMemoryRange(start: Self.regionStart, byteCount: 4))
        let preview = try XCTUnwrap(DebuggerMemoryInspectionPolicy.preview(
            coordinate: fixture.coordinate,
            requestedRange: request,
            bytes: [0xde, 0xad],
            in: region,
            faulted: true
        ))

        XCTAssertEqual(preview.actualRange.byteCount, 2)
        XCTAssertEqual(preview.previewText, "de ad")
        XCTAssertTrue(preview.diagnostics.contains(.truncated))
        XCTAssertTrue(preview.diagnostics.contains(.fault))
        XCTAssertTrue(preview.diagnostics.contains(.nonWritableRegion))
        XCTAssertNil(DebuggerMemoryInspectionPolicy.preview(
            coordinate: fixture.coordinate,
            requestedRange: try XCTUnwrap(DebuggerMemoryRange(start: 0x3_0000_0000, byteCount: 4)),
            bytes: [0xde],
            in: region
        ))
    }

    func testMemoryPreviewFreshnessUsesInspectionCoordinate() throws {
        let fixture = try Self.fixture()
        let preview = try fixture.preview()

        XCTAssertEqual(
            preview.freshness(
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.regionStart))
            ),
            .fresh(fixture.coordinate)
        )
        XCTAssertEqual(
            preview.freshness(
                currentStop: Self.stop(stopRevision: 2),
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.regionStart))
            ),
            .stale(reason: .stopChanged)
        )
    }

    func testWriteAuthorizationRejectsStaleOutsideAndNonWritablePreview() throws {
        let fixture = try Self.fixture()
        let writable = try fixture.preview(permissions: [.read, .write])
        let readOnly = try fixture.preview(permissions: [.read])

        XCTAssertEqual(
            DebuggerMemoryInspectionPolicy.authorizeWrite(
                from: writable,
                writeStart: Self.regionStart,
                byteCount: 2,
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.regionStart))
            ),
            .authorized(writable)
        )
        XCTAssertEqual(
            DebuggerMemoryInspectionPolicy.authorizeWrite(
                from: writable,
                writeStart: Self.regionStart,
                byteCount: 2,
                currentStop: Self.stop(stopRevision: 2),
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.regionStart))
            ),
            .rejected(.stalePreview)
        )
        XCTAssertEqual(
            DebuggerMemoryInspectionPolicy.authorizeWrite(
                from: readOnly,
                writeStart: Self.regionStart,
                byteCount: 2,
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.regionStart))
            ),
            .rejected(.nonWritableRegion)
        )
        XCTAssertEqual(
            DebuggerMemoryInspectionPolicy.authorizeWrite(
                from: writable,
                writeStart: Self.regionStart + 10,
                byteCount: 2,
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.regionStart))
            ),
            .rejected(.outsidePreview)
        )
    }

    private struct Fixture {
        let stop: DebuggerStopCoordinate
        let authority: DebuggerSessionTargetAuthority
        let thread: DebuggerThreadIdentity
        let frame: DebuggerFrameIdentity
        let coordinate: DebuggerInspectionCoordinate
        let moduleInstanceID: DebuggerRuntimeModuleInstanceID
        let workspaceCoordinate: DebuggerWorkspaceArtifactCoordinate

        func region(
            permissions: DebuggerVMRegionPermissions
        ) throws -> DebuggerVMRegionInspection {
            try XCTUnwrap(DebuggerVMRegionInspection(
                coordinate: coordinate,
                range: try XCTUnwrap(DebuggerMemoryRange(start: DebuggerMemoryInspectionModelTests.regionStart, byteCount: 0x1000)),
                permissions: permissions,
                mappedPath: "/Applications/Fixture.app/Contents/MacOS/Fixture",
                moduleInstanceID: moduleInstanceID,
                workspaceCoordinate: workspaceCoordinate
            ))
        }

        func preview(
            permissions: DebuggerVMRegionPermissions = [.read, .write]
        ) throws -> DebuggerMemoryPreview {
            let request = try XCTUnwrap(DebuggerMemoryRange(
                start: DebuggerMemoryInspectionModelTests.regionStart,
                byteCount: 4
            ))
            return try XCTUnwrap(DebuggerMemoryInspectionPolicy.preview(
                coordinate: coordinate,
                requestedRange: request,
                bytes: [0xde, 0xad, 0xbe, 0xef],
                in: try region(permissions: permissions)
            ))
        }
    }

    private static let binaryUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private static let binaryID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
    private static let regionStart: UInt64 = 0x2_0000_1000
    private static let artifactSHA = String(repeating: "a", count: 64)

    private static func fixture() throws -> Fixture {
        let stop = Self.stop()
        let authority = try Self.authority(processID: 123)
        let thread = try XCTUnwrap(DebuggerThreadIdentity(index: 1, tid: 0xabc))
        let frame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: thread,
            frameIndex: 0,
            programCounter: Self.regionStart,
            canonicalFunctionName: "main"
        ))
        let coordinate = try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: authority,
            thread: thread,
            frame: frame
        ))
        let moduleInstanceID = DebuggerRuntimeModuleInstanceID(
            processID: 123,
            stop: stop,
            inventoryRevision: DebuggerRuntimeModuleInventoryRevision(rawValue: 7),
            ordinal: 0
        )
        let workspaceCoordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: Self.binaryID,
            slot: .primary,
            artifactIdentity: try Self.artifactIdentity(),
            ownerRevision: DebuggerWorkspaceArtifactOwnerRevision(rawValue: 5)
        )
        return Fixture(
            stop: stop,
            authority: authority,
            thread: thread,
            frame: frame,
            coordinate: coordinate,
            moduleInstanceID: moduleInstanceID,
            workspaceCoordinate: workspaceCoordinate
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
