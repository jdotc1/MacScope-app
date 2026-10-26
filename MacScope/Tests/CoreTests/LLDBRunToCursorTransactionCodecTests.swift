import CryptoKit
import XCTest
@testable import MacScope

final class LLDBRunToCursorTransactionCodecTests: XCTestCase {
    func testPreparedPlanIsCanonicalBoundedAndNamesExactlyOnePrivateOneShotBinding() throws {
        let fixture = try makeFixture()
        let prepared = try prepare(fixture)
        let value = try Phase2StrictJSONParser().parse(prepared.canonicalPlanBytes)
        let object = try XCTUnwrap(value.objectValue)

        XCTAssertEqual(value.canonicalJSONBytes(), prepared.canonicalPlanBytes)
        XCTAssertLessThanOrEqual(
            prepared.canonicalPlanBytes.count,
            LLDBRunToCursorPreparedTransaction.maximumPlanBytes
        )
        XCTAssertEqual(Set(object.keys), [
            "adapter_generation", "authority_revision", "binding", "inventory_revision",
            "lifecycle_revision", "observed_pid", "observed_stop_id", "owner_digest",
            "run_id", "schema", "session_epoch", "stop_revision",
            "workspace_catalog_revision",
        ])
        XCTAssertEqual(object["schema"], .number("1"))
        XCTAssertEqual(object["run_id"]?.stringValue, runID.rawValue.uuidString.lowercased())
        XCTAssertEqual(object["observed_pid"], .number("42"))
        XCTAssertEqual(object["observed_stop_id"], .number("12"))

        let binding = try XCTUnwrap(object["binding"]?.objectValue)
        XCTAssertEqual(Set(binding.keys), [
            "artifact_uuid", "mapped_byte_count", "mapped_runtime_start",
            "mapped_static_start", "module_ordinal", "name_owner_digest", "one_shot",
            "owned_name_b64", "purpose", "runtime_address", "static_address",
            "workspace_binary_id", "workspace_owner_revision", "workspace_slot",
        ])
        XCTAssertEqual(binding["purpose"], .string("run_to_cursor"))
        XCTAssertEqual(binding["one_shot"], .bool(true))
        XCTAssertEqual(binding["runtime_address"], .string("0000000000009010"))
        XCTAssertEqual(binding["static_address"], .string("0000000000001010"))
        XCTAssertEqual(binding["mapped_runtime_start"], .string("0000000000009000"))
        XCTAssertEqual(binding["mapped_static_start"], .string("0000000000001000"))
        XCTAssertEqual(binding["mapped_byte_count"], .number("256"))
        XCTAssertEqual(
            binding["name_owner_digest"]?.stringValue,
            hex(prepared.expectedNameOwnerDigest.bytes)
        )
        let encodedName = try XCTUnwrap(binding["owned_name_b64"]?.stringValue)
        let ownedNameBytes = try XCTUnwrap(Data(base64Encoded: encodedName))
        let ownedName = try XCTUnwrap(String(data: ownedNameBytes, encoding: .utf8))
        XCTAssertEqual(
            ownedName,
            "macscope_private_run_to_cursor_g7_\(hex(ownerDigest.bytes))_"
                + runID.rawValue.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        )
        XCTAssertLessThanOrEqual(ownedNameBytes.count, 256)
        XCTAssertTrue(ownedName.utf8.allSatisfy {
            (0x30...0x39).contains($0)
                || (0x41...0x5A).contains($0)
                || (0x61...0x7A).contains($0)
                || $0 == 0x5F
        })
        XCTAssertEqual(
            Data(SHA256.hash(data: ownedNameBytes)),
            prepared.expectedNameOwnerDigest.bytes
        )
        XCTAssertEqual(
            prepared.canonicalPlanDigest.bytes,
            Data(SHA256.hash(data: prepared.canonicalPlanBytes))
        )
        XCTAssertEqual(
            prepared.pages.map(\.payload).reduce(Data(), +),
            prepared.canonicalPlanBytes
        )
        XCTAssertTrue(prepared.pages.enumerated().allSatisfy { index, page in
            page.index == index
                && page.payload.count <= LLDBRunToCursorPreparedTransaction.rawPlanPageByteCount
                && page.payloadBase64.utf8.count
                    <= LLDBLogicalBreakpointProgram.maximumPlanPageBase64Characters
                && page.payloadSHA256 == Data(SHA256.hash(data: page.payload))
        })
        XCTAssertEqual(
            LLDBRunToCursorPreparedTransaction.rawPlanPageByteCount,
            LLDBLogicalBreakpointPreparedTransaction.rawPlanPageByteCount
        )
        XCTAssertEqual(
            prepared.receiptByteCountUpperBound,
            LLDBRunToCursorPreparedTransaction.maximumReceiptBytes
        )
        XCTAssertEqual(prepared.resolvedAddress, fixture.resolved)
    }

    func testPreparationIndependentlyRejectsAuthorityUUIDRangeOffsetAndExecuteDrift() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(try prepare(try makeFixture(observedStopID: 13))) { error in
            XCTAssertEqual(error as? LLDBRunToCursorTransactionCodecError, .invalidAuthority)
        }
        XCTAssertThrowsError(try prepare(try makeFixture(moduleUUID: otherUUID))) { error in
            XCTAssertEqual(error as? LLDBRunToCursorTransactionCodecError, .invalidMapping)
        }
        XCTAssertThrowsError(try prepare(try makeFixture(permissions: 3))) { error in
            XCTAssertEqual(error as? LLDBRunToCursorTransactionCodecError, .invalidMapping)
        }
        XCTAssertThrowsError(try prepare(try makeFixture(runtimeStart: 0x8fff))) { error in
            XCTAssertEqual(error as? LLDBRunToCursorTransactionCodecError, .invalidMapping)
        }

        let staleInventory = DebuggerRuntimeModuleInventory(
            revision: .init(rawValue: fixture.inventory.revision.rawValue + 1),
            stop: fixture.inventory.stop,
            processID: fixture.inventory.processID,
            observedStopID: fixture.inventory.observedStopID,
            modules: fixture.inventory.modules
        )
        XCTAssertThrowsError(try LLDBRunToCursorTransactionCodec().prepare(
            resolvedAddress: fixture.resolved,
            observedStopID: fixture.inventory.observedStopID,
            adapterGeneration: 7,
            runtimeInventory: staleInventory,
            runID: runID,
            ownerDigest: ownerDigest
        )) { error in
            XCTAssertEqual(error as? LLDBRunToCursorTransactionCodecError, .invalidAuthority)
        }
    }

    func testStrictPrivateReceiptDecodesOnlyThePreparedRunAuthority() throws {
        let prepared = try prepare(try makeFixture())
        let bytes = receiptBytes(for: prepared)
        let receipt = try LLDBRunToCursorTransactionCodec().decodeReceipt(
            bytes,
            for: prepared
        )

        XCTAssertEqual(receipt.backendBreakpointID, 101)
        XCTAssertEqual(receipt.backendLocationID, 1)
        XCTAssertEqual(receipt.runtimeAddress, 0x9010)
        XCTAssertEqual(receipt.nameOwnerDigest, prepared.expectedNameOwnerDigest)
        XCTAssertEqual(receipt.canonicalPlanDigest, prepared.canonicalPlanDigest)
        XCTAssertEqual(receipt.adapterGeneration, 7)
        XCTAssertEqual(receipt.observedPID, 42)
        XCTAssertEqual(receipt.observedStopID, 12)
        XCTAssertEqual(receipt.runID, runID)
        XCTAssertTrue(receipt.oneShot)

        var noncanonical = bytes
        noncanonical.insert(0x20, at: 0)
        XCTAssertThrowsError(try LLDBRunToCursorTransactionCodec().decodeReceipt(
            noncanonical,
            for: prepared
        )) { error in
            XCTAssertEqual(error as? LLDBRunToCursorTransactionCodecError, .contradictoryReceipt)
        }
    }

    func testPrivateReceiptRejectsLogicalShapeExtraKeysAndCrossRunReplay() throws {
        let prepared = try prepare(try makeFixture())
        let logicalShape = Phase2ProductionJSONValue.object([
            "adapter_generation": .number("7"),
            "did_write_backend": .bool(true),
            "locations": .array([]),
            "observed_pid": .number("42"),
            "observed_stop_id": .number("12"),
            "ok": .bool(true),
            "schema": .number("1"),
        ]).canonicalJSONBytes()
        XCTAssertThrowsError(try LLDBRunToCursorTransactionCodec().decodeReceipt(
            logicalShape,
            for: prepared
        ))

        var extra = try XCTUnwrap(
            try Phase2StrictJSONParser().parse(receiptBytes(for: prepared)).objectValue
        )
        extra["logical_id"] = .string(otherUUID.uuidString.lowercased())
        XCTAssertThrowsError(try LLDBRunToCursorTransactionCodec().decodeReceipt(
            Phase2ProductionJSONValue.object(extra).canonicalJSONBytes(),
            for: prepared
        ))

        let anotherRun = try XCTUnwrap(LLDBRunToCursorRunID(
            rawValue: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        ))
        var replay = try XCTUnwrap(
            try Phase2StrictJSONParser().parse(receiptBytes(for: prepared)).objectValue
        )
        replay["run_id"] = .string(anotherRun.rawValue.uuidString.lowercased())
        XCTAssertThrowsError(try LLDBRunToCursorTransactionCodec().decodeReceipt(
            Phase2ProductionJSONValue.object(replay).canonicalJSONBytes(),
            for: prepared
        ))
    }

    func testRunIdentityRejectsTheNilUUID() {
        XCTAssertNil(LLDBRunToCursorRunID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        ))
    }

    private struct Fixture {
        let resolved: DebuggerResolvedRuntimeAddress
        let inventory: DebuggerRuntimeModuleInventory
    }

    private let binaryID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let otherUUID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    )
    private let runID = LLDBRunToCursorRunID(
        rawValue: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    )!
    private let ownerDigest = DebuggerBreakpointDigest(Data(repeating: 0x66, count: 32))!

    private func prepare(_ fixture: Fixture) throws -> LLDBRunToCursorPreparedTransaction {
        try LLDBRunToCursorTransactionCodec().prepare(
            resolvedAddress: fixture.resolved,
            observedStopID: 12,
            adapterGeneration: 7,
            runtimeInventory: fixture.inventory,
            runID: runID,
            ownerDigest: ownerDigest
        )
    }

    private func makeFixture(
        observedStopID: UInt32 = 12,
        moduleUUID: UUID? = nil,
        permissions: UInt8 = 5,
        runtimeStart: UInt64 = 0x9000
    ) throws -> Fixture {
        let artifact = try MachOSliceArtifactIdentity(
            uuid: binaryID,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "a", count: 64),
            selectedSliceByteCount: 0x10_000
        )
        let stop = DebuggerStopCoordinate(
            session: .init(epoch: epoch, lifecycleRevision: .init(rawValue: 2)),
            stopRevision: .init(rawValue: 3)
        )
        let revision = DebuggerRuntimeModuleInventoryRevision(rawValue: 6)
        let instanceID = DebuggerRuntimeModuleInstanceID(
            processID: 42,
            stop: stop,
            inventoryRevision: revision,
            ordinal: 0
        )
        let coordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: binaryID,
            slot: .primary,
            artifactIdentity: artifact,
            ownerRevision: .init(rawValue: 2)
        )
        let key = DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: stop,
            observedPID: 42,
            authorityRevision: .init(rawValue: 5),
            inventoryRevision: revision,
            workspaceCatalogRevision: .init(rawValue: 9)
        )
        let resolved = DebuggerResolvedRuntimeAddress(
            projectionKey: key,
            moduleInstanceID: instanceID,
            workspaceCoordinate: coordinate,
            imageAddress: .primary(0x1010),
            runtimeAddress: 0x9010
        )
        let range = try XCTUnwrap(DebuggerRuntimeModuleMappedRangeObservation(
            sectionOrdinal: 0,
            sectionName: "__TEXT",
            staticStart: 0x1000,
            runtimeStart: runtimeStart,
            byteCount: 0x100,
            permissions: permissions
        ))
        let observation = try XCTUnwrap(DebuggerRuntimeModuleObservation(
            uuid: moduleUUID ?? binaryID,
            processID: 42,
            observedStopID: observedStopID,
            mappedRanges: [range],
            fullPath: "/tmp/run-to-cursor-fixture",
            normalizedArchitectureTriple: "arm64-apple-macosx",
            displayIndex: 0,
            fingerprintSHA256: Data(repeating: 0x88, count: 32)
        ))
        let inventory = DebuggerRuntimeModuleInventory(
            revision: revision,
            stop: stop,
            processID: 42,
            observedStopID: observedStopID,
            modules: [.init(id: instanceID, observation: observation)]
        )
        return Fixture(resolved: resolved, inventory: inventory)
    }

    private func receiptBytes(
        for prepared: LLDBRunToCursorPreparedTransaction
    ) -> Data {
        Phase2ProductionJSONValue.object([
            "adapter_generation": .number(String(prepared.adapterGeneration)),
            "backend_breakpoint_id": .number("101"),
            "backend_location_id": .number("1"),
            "name_owner_digest": .string(hex(prepared.expectedNameOwnerDigest.bytes)),
            "observed_pid": .number(String(prepared.observedPID)),
            "observed_stop_id": .number(String(prepared.observedStopID)),
            "ok": .bool(true),
            "one_shot": .bool(true),
            "plan_digest": .string(hex(prepared.canonicalPlanDigest.bytes)),
            "purpose": .string("run_to_cursor"),
            "run_id": .string(prepared.runID.rawValue.uuidString.lowercased()),
            "runtime_address": .string("0000000000009010"),
            "schema": .number("1"),
        ]).canonicalJSONBytes()
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
