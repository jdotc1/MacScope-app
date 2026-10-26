import CryptoKit
import XCTest
@testable import MacScope

final class LLDBLogicalBreakpointTransactionCodecTests: XCTestCase {
    func testFrozenPlanPageAndCompleteWireGeometry() throws {
        let program = LLDBLogicalBreakpointProgram.current
        let rawPageByteCount = LLDBLogicalBreakpointPreparedTransaction.rawPlanPageByteCount
        XCTAssertEqual(rawPageByteCount, 448)
        XCTAssertEqual(LLDBLogicalBreakpointProgram.maximumPlanPageCount, 8_192)

        let fullPage = Data(repeating: 0xA5, count: rawPageByteCount)
        let payloadBase64 = fullPage.base64EncodedString()
        XCTAssertEqual(payloadBase64.utf8.count, 600)
        XCTAssertLessThanOrEqual(
            payloadBase64.utf8.count,
            LLDBLogicalBreakpointProgram.maximumPlanPageBase64Characters
        )

        let pagesForMaximumPlan = 1
            + ((LLDBLogicalBreakpointProgram.maximumPlanBytes - 1) / rawPageByteCount)
        XCTAssertEqual(pagesForMaximumPlan, 4_682)
        XCTAssertLessThanOrEqual(
            pagesForMaximumPlan,
            LLDBLogicalBreakpointProgram.maximumPlanPageCount
        )

        let command = try program.uploadPageCommand(
            token: Data(repeating: 0x11, count: 32),
            pageIndex: 0,
            pageCount: pagesForMaximumPlan,
            payloadBase64: payloadBase64,
            payloadSHA256: Data(SHA256.hash(data: fullPage))
        )
        XCTAssertLessThanOrEqual(
            try program.completeEncodedWireByteCount(for: command),
            LLDBLogicalBreakpointProgram.maximumEncodedWireBytes
        )
    }

    func testCanonicalPlanIsTokenIndependentBoundedAndMatchesClosedHelperSchema() throws {
        let fixture = try makeFixture()
        let prepared = try prepare(fixture)
        let value = try Phase2StrictJSONParser().parse(prepared.canonicalPlanBytes)
        let object = try XCTUnwrap(value.objectValue)

        XCTAssertEqual(value.canonicalJSONBytes(), prepared.canonicalPlanBytes)
        XCTAssertEqual(Set(object.keys), [
            "adapter_generation", "bindings", "observed_pid", "observed_stop_id",
            "owner_tag_digest", "purpose", "schema", "session_epoch", "transaction_id",
        ])
        XCTAssertEqual(object["purpose"]?.stringValue, "logical")
        XCTAssertNil(object["token"])
        let bindingObject = try XCTUnwrap(object["bindings"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(Set(bindingObject.keys), [
            "actions", "artifact_uuid", "binding_id", "condition_b64", "disposition",
            "hit_policy", "issuance_digest", "logical_id", "mapped_byte_count",
            "mapped_runtime_start", "mapped_static_start", "owner_tag_digest",
            "policy_action_digest", "runtime_address", "specification_revision",
            "static_address",
        ])
        XCTAssertEqual(
            prepared.plan.canonicalPlanDigest.bytes,
            Data(SHA256.hash(data: prepared.canonicalPlanBytes))
        )
        XCTAssertEqual(prepared.pages.map(\.payload).reduce(Data(), +), prepared.canonicalPlanBytes)
        XCTAssertTrue(prepared.pages.allSatisfy {
            $0.payload.count <= LLDBLogicalBreakpointPreparedTransaction.rawPlanPageByteCount
                && $0.payloadBase64.utf8.count
                    <= LLDBLogicalBreakpointProgram.maximumPlanPageBase64Characters
                && $0.payloadSHA256 == Data(SHA256.hash(data: $0.payload))
        })
        XCTAssertEqual(
            prepared.receiptByteCountUpperBound,
            LLDBLogicalBreakpointProgram.maximumReceiptBytes
        )
        let wire = try XCTUnwrap(prepared.wireBindings.first)
        let nameAuthority = Data(
            (wire.wireID
                + hex(wire.binding.policyActionDigest.bytes)
                + hex(wire.binding.issuanceDigest.bytes)).utf8
        )
        let ownedName = "macscope_logical_g7_\(hex(ownerDigest.bytes))_"
            + hex(Data(SHA256.hash(data: nameAuthority)))
        XCTAssertLessThanOrEqual(ownedName.utf8.count, 256)
        XCTAssertTrue(ownedName.utf8.allSatisfy {
            (0x30...0x39).contains($0)
                || (0x41...0x5A).contains($0)
                || (0x61...0x7A).contains($0)
                || $0 == 0x5F
        })
        XCTAssertEqual(
            wire.expectedOwnedNameSHA256,
            Data(SHA256.hash(data: Data(ownedName.utf8)))
        )

        let firstToken = Data(repeating: 0x11, count: 32)
        let secondToken = Data(repeating: 0x22, count: 32)
        XCTAssertNotEqual(
            try prepared.beginCommand(token: firstToken),
            try prepared.beginCommand(token: secondToken)
        )
        XCTAssertNotEqual(
            try prepared.uploadCommands(token: firstToken),
            try prepared.uploadCommands(token: secondToken)
        )
        XCTAssertEqual(
            prepared.plan.canonicalPlanDigest,
            try prepare(fixture).plan.canonicalPlanDigest
        )
    }

    func testConditionAndIgnoreFirstPolicyUseExactBase64ThroughLiveProvenCapabilities() throws {
        let plain = try makeFixture()
        let prepared = try prepare(plain)
        let root = try XCTUnwrap(
            try Phase2StrictJSONParser().parse(prepared.canonicalPlanBytes).objectValue
        )
        let binding = try XCTUnwrap(root["bindings"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(binding["condition_b64"], .null)
        XCTAssertEqual(binding["actions"], .array([]))
        XCTAssertEqual(
            binding["hit_policy"],
            .object(["count": .null, "kind": .string("always")])
        )
        XCTAssertEqual(binding["disposition"], .string("stop"))

        let conditioned = try makeFixture(condition: "x == 1")
        let conditionedRoot = try XCTUnwrap(
            try Phase2StrictJSONParser().parse(
                try prepare(conditioned).canonicalPlanBytes
            ).objectValue
        )
        let conditionedBinding = try XCTUnwrap(
            conditionedRoot["bindings"]?.arrayValue?.first?.objectValue
        )
        XCTAssertEqual(
            conditionedBinding["condition_b64"],
            .string(Data("x == 1".utf8).base64EncodedString())
        )

        let ignored = try makeFixture(hitPolicy: .ignoreFirst(1))
        let ignoredRoot = try XCTUnwrap(
            try Phase2StrictJSONParser().parse(
                try prepare(ignored).canonicalPlanBytes
            ).objectValue
        )
        let ignoredBinding = try XCTUnwrap(
            ignoredRoot["bindings"]?.arrayValue?.first?.objectValue
        )
        XCTAssertEqual(
            ignoredBinding["hit_policy"],
            .object(["count": .number("1"), "kind": .string("ignore_first")])
        )
    }

    func testProjectionInventoryAndIssuanceEvidenceAreRevalidated() throws {
        let fixture = try makeFixture()
        let unmappedObservation = try XCTUnwrap(DebuggerRuntimeModuleObservation(
            uuid: binaryID,
            processID: fixture.inventory.processID,
            observedStopID: fixture.inventory.observedStopID,
            mappedRanges: [],
            fullPath: "/tmp/fixture",
            normalizedArchitectureTriple: "arm64-apple-macosx",
            displayIndex: 0,
            fingerprintSHA256: Data(repeating: 0x99, count: 32)
        ))
        let unmappedInventory = DebuggerRuntimeModuleInventory(
            revision: fixture.inventory.revision,
            stop: fixture.inventory.stop,
            processID: fixture.inventory.processID,
            observedStopID: fixture.inventory.observedStopID,
            modules: [.init(id: fixture.inventory.modules[0].id, observation: unmappedObservation)]
        )
        XCTAssertThrowsError(try LLDBLogicalBreakpointTransactionCodec().prepare(
            request: fixture.request,
            transactionID: transactionID,
            adapterGeneration: 7,
            runtimeInventory: unmappedInventory,
            ownershipTagDigest: ownerDigest
        )) { error in
            XCTAssertEqual(
                error as? LLDBLogicalBreakpointTransactionCodecError,
                .invalidMapping
            )
        }

        let ambiguousRange = try XCTUnwrap(DebuggerRuntimeModuleMappedRangeObservation(
            sectionOrdinal: 1,
            sectionName: "__TEXT_ALT",
            staticStart: 0x1000,
            runtimeStart: 0x9000,
            byteCount: 0x100,
            permissions: 5
        ))
        let originalModule = fixture.inventory.modules[0]
        let ambiguousObservation = try XCTUnwrap(DebuggerRuntimeModuleObservation(
            uuid: originalModule.observation.uuid,
            processID: originalModule.observation.processID,
            observedStopID: originalModule.observation.observedStopID,
            mappedRanges: originalModule.observation.mappedRanges + [ambiguousRange],
            fullPath: originalModule.observation.fullPath,
            normalizedArchitectureTriple: originalModule.observation.normalizedArchitectureTriple,
            displayIndex: originalModule.observation.displayIndex,
            fingerprintSHA256: Data(repeating: 0x9A, count: 32)
        ))
        let ambiguousInventory = DebuggerRuntimeModuleInventory(
            revision: fixture.inventory.revision,
            stop: fixture.inventory.stop,
            processID: fixture.inventory.processID,
            observedStopID: fixture.inventory.observedStopID,
            modules: [.init(id: originalModule.id, observation: ambiguousObservation)]
        )
        XCTAssertThrowsError(try LLDBLogicalBreakpointTransactionCodec().prepare(
            request: fixture.request,
            transactionID: transactionID,
            adapterGeneration: 7,
            runtimeInventory: ambiguousInventory,
            ownershipTagDigest: ownerDigest
        )) { error in
            XCTAssertEqual(
                error as? LLDBLogicalBreakpointTransactionCodecError,
                .invalidMapping
            )
        }

        let staleInventory = DebuggerRuntimeModuleInventory(
            revision: .init(rawValue: fixture.inventory.revision.rawValue + 1),
            stop: fixture.inventory.stop,
            processID: fixture.inventory.processID,
            observedStopID: fixture.inventory.observedStopID,
            modules: fixture.inventory.modules
        )
        XCTAssertThrowsError(try LLDBLogicalBreakpointTransactionCodec().prepare(
            request: fixture.request,
            transactionID: transactionID,
            adapterGeneration: 7,
            runtimeInventory: staleInventory,
            ownershipTagDigest: ownerDigest
        ))
    }

    func testStrictReceiptAssemblerProducesReducerReceiptAndRejectsNoncanonicalBytes() throws {
        let fixture = try makeFixture()
        let prepared = try prepare(fixture)
        let token = Data(repeating: 0x33, count: 32)
        let receiptBytes = try makeReceipt(prepared: prepared, token: token)
        let receiptDigest = Data(SHA256.hash(data: receiptBytes))
        var assembler = try LLDBLogicalBreakpointReceiptAssembler(
            prepared: prepared,
            token: token,
            appliedResponse: .applied(
                token: token,
                locationCount: 1,
                receiptSHA256: receiptDigest
            )
        )
        try assembler.append(.receiptPage(
            token: token,
            cursor: 0,
            nextCursor: receiptBytes.count,
            isFinal: true,
            receiptSHA256: receiptDigest,
            payload: receiptBytes
        ))
        let receipt = try assembler.finish()
        XCTAssertEqual(receipt.canonicalPlanDigest, prepared.plan.canonicalPlanDigest)
        XCTAssertTrue(receipt.didWriteBackend)
        XCTAssertEqual(receipt.completeOwnedInventory.count, 1)
        XCTAssertEqual(
            receipt.completeOwnedInventory.first?.bindingID,
            prepared.wireBindings.first?.binding.id
        )

        var noncanonical = receiptBytes
        noncanonical.insert(0x20, at: 0)
        let noncanonicalDigest = Data(SHA256.hash(data: noncanonical))
        var rejected = try LLDBLogicalBreakpointReceiptAssembler(
            prepared: prepared,
            token: token,
            appliedResponse: .applied(
                token: token,
                locationCount: 1,
                receiptSHA256: noncanonicalDigest
            )
        )
        try rejected.append(.receiptPage(
            token: token,
            cursor: 0,
            nextCursor: noncanonical.count,
            isFinal: true,
            receiptSHA256: noncanonicalDigest,
            payload: noncanonical
        ))
        XCTAssertThrowsError(try rejected.finish())
    }

    func testReceiptPagingRequiresContiguousFullNonfinalPagesAndExactDigest() throws {
        let fixture = try makeFixture()
        let prepared = try prepare(fixture)
        let token = Data(repeating: 0x44, count: 32)
        let digest = Data(repeating: 0x55, count: 32)
        var assembler = try LLDBLogicalBreakpointReceiptAssembler(
            prepared: prepared,
            token: token,
            appliedResponse: .applied(token: token, locationCount: 1, receiptSHA256: digest)
        )
        XCTAssertThrowsError(try assembler.append(.receiptPage(
            token: token,
            cursor: 1,
            nextCursor: 2,
            isFinal: false,
            receiptSHA256: digest,
            payload: Data([0])
        )))
        XCTAssertThrowsError(try assembler.append(.receiptPage(
            token: token,
            cursor: .max,
            nextCursor: .max,
            isFinal: true,
            receiptSHA256: digest,
            payload: Data([0])
        )))
        XCTAssertThrowsError(try assembler.finish())
    }

    private struct Fixture {
        let request: DebuggerLogicalBreakpointReconcileRequest
        let inventory: DebuggerRuntimeModuleInventory
    }

    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let catalogID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let logicalID = DebuggerLogicalBreakpointID(
        rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    )
    private let binaryID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    )
    private let transactionID = DebuggerBreakpointBindingTransactionID(
        rawValue: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    )
    private let ownerDigest = DebuggerBreakpointDigest(Data(repeating: 0x77, count: 32))!

    private func prepare(
        _ fixture: Fixture
    ) throws -> LLDBLogicalBreakpointPreparedTransaction {
        try LLDBLogicalBreakpointTransactionCodec().prepare(
            request: fixture.request,
            transactionID: transactionID,
            adapterGeneration: 7,
            runtimeInventory: fixture.inventory,
            ownershipTagDigest: ownerDigest
        )
    }

    private func makeFixture(
        condition: String? = nil,
        hitPolicy: DebuggerBreakpointHitPolicy = .always
    ) throws -> Fixture {
        let artifact = try MachOSliceArtifactIdentity(
            uuid: binaryID,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "a", count: 64),
            selectedSliceByteCount: 0x10_000
        )
        let coordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: binaryID,
            slot: .primary,
            artifactIdentity: artifact,
            ownerRevision: .init(rawValue: 2)
        )
        let owner = DebuggerWorkspaceImageOwnerSeal(
            slot: .primary,
            binaryID: binaryID,
            artifactIdentity: artifact
        )
        let specification = try DebuggerLogicalBreakpointSpecification(
            id: logicalID,
            revision: try .init(validating: 1),
            enabled: true,
            target: .preferredAddress(owner: owner, preferredVA: 0x1010),
            condition: condition,
            hitPolicy: hitPolicy,
            actions: [],
            disposition: .stop
        )
        let catalog = try DebuggerLogicalBreakpointCatalog(
            catalogID: catalogID,
            revision: 1,
            specifications: [specification]
        )
        let stop = DebuggerStopCoordinate(
            session: .init(epoch: epoch, lifecycleRevision: .init(rawValue: 2)),
            stopRevision: .init(rawValue: 3)
        )
        let mappingKey = DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: stop,
            observedPID: 42,
            authorityRevision: .init(rawValue: 5),
            inventoryRevision: .init(rawValue: 6),
            workspaceCatalogRevision: .init(rawValue: 9)
        )
        let instanceID = DebuggerRuntimeModuleInstanceID(
            processID: 42,
            stop: stop,
            inventoryRevision: mappingKey.inventoryRevision,
            ordinal: 0
        )
        let imageAddress = ImageAddress.primary(0x1010)
        let siteID = DebuggerLogicalBreakpointSiteID(
            logicalID: logicalID,
            specificationRevision: specification.revision,
            imageAddress: imageAddress,
            staticOrdinal: 0
        )
        let site = try XCTUnwrap(DebuggerResolvedLogicalBreakpointSite(
            logicalID: logicalID,
            specificationRevision: specification.revision,
            siteID: siteID,
            owner: owner,
            coordinate: coordinate,
            imageAddress: imageAddress,
            provenance: .preferredAddress
        ))
        let policy = Data(SHA256.hash(
            data: try DebuggerLogicalBreakpointCanonicalCodec.encodeSpecification(specification)
        ))
        var issuanceMaterial = policy
        issuanceMaterial.append(contentsOf: logicalID.rawValue.uuidString.utf8)
        issuanceMaterial.append(contentsOf: "1".utf8)
        issuanceMaterial.append(contentsOf: "0".utf8)
        issuanceMaterial.append(contentsOf: "0".utf8)
        issuanceMaterial.append(contentsOf: String(0x1010).utf8)
        issuanceMaterial.append(contentsOf: String(0x9010).utf8)
        issuanceMaterial.append(contentsOf: "0".utf8)
        issuanceMaterial.append(contentsOf: "6".utf8)
        let bindingID = try XCTUnwrap(DebuggerTransientBreakpointBindingID(
            logicalID: logicalID,
            siteID: siteID,
            moduleInstanceID: instanceID
        ))
        let binding = try XCTUnwrap(DebuggerDesiredBreakpointBinding(
            id: bindingID,
            site: site,
            mappingKey: mappingKey,
            runtimeAddress: 0x9010,
            policyActionDigest: DebuggerBreakpointDigest(policy)!,
            issuanceDigest: DebuggerBreakpointDigest(
                Data(SHA256.hash(data: issuanceMaterial))
            )!
        ))
        let result = DebuggerLogicalBreakpointResolution(
            logicalID: logicalID,
            specificationRevision: specification.revision,
            state: .resolved(site: site, binding: binding)
        )
        let logicalCoordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: workspaceID,
            catalogID: catalogID,
            revision: 1
        )
        let resolutionCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: workspaceID,
            revision: .init(rawValue: 8),
            workspaceArtifactCatalogRevision: mappingKey.workspaceCatalogRevision
        )
        let observation = try XCTUnwrap(DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: logicalCoordinate,
            resolutionCatalogCoordinate: resolutionCoordinate,
            mappingKey: mappingKey,
            expectedSpecifications: [
                .init(logicalID: logicalID, specificationRevision: specification.revision)
            ],
            results: [result]
        ))
        let request = try DebuggerLogicalBreakpointReconcileRequest(
            catalogAvailability: .available,
            catalog: catalog,
            observation: observation
        )
        let observedRange = try XCTUnwrap(DebuggerRuntimeModuleMappedRangeObservation(
            sectionOrdinal: 0,
            sectionName: "__TEXT",
            staticStart: 0x1000,
            runtimeStart: 0x9000,
            byteCount: 0x100,
            permissions: 5
        ))
        let moduleObservation = try XCTUnwrap(DebuggerRuntimeModuleObservation(
            uuid: binaryID,
            processID: 42,
            observedStopID: 12,
            mappedRanges: [observedRange],
            fullPath: "/tmp/fixture",
            normalizedArchitectureTriple: "arm64-apple-macosx",
            displayIndex: 0,
            fingerprintSHA256: Data(repeating: 0x88, count: 32)
        ))
        let inventory = DebuggerRuntimeModuleInventory(
            revision: mappingKey.inventoryRevision,
            stop: stop,
            processID: 42,
            observedStopID: 12,
            modules: [.init(id: instanceID, observation: moduleObservation)]
        )
        return Fixture(request: request, inventory: inventory)
    }

    private func makeReceipt(
        prepared: LLDBLogicalBreakpointPreparedTransaction,
        token: Data
    ) throws -> Data {
        let wire = try XCTUnwrap(prepared.wireBindings.first)
        let location: Phase2ProductionJSONValue = .object([
            "auto_continue": .bool(false),
            "backend_breakpoint_id": .number("101"),
            "backend_location_id": .number("1"),
            "binding_id": .string(wire.wireID),
            "enabled": .bool(true),
            "issuance_digest": .string(hex(wire.binding.issuanceDigest.bytes)),
            "logical_id": .string(logicalID.rawValue.uuidString.lowercased()),
            "name_sha256": .string(hex(wire.expectedOwnedNameSHA256)),
            "one_shot": .bool(false),
            "owner_tag_digest": .string(hex(ownerDigest.bytes)),
            "policy_action_digest": .string(hex(wire.binding.policyActionDigest.bytes)),
            "runtime_address": .string("0000000000009010"),
            "specification_revision": .number("1"),
        ])
        return Phase2ProductionJSONValue.object([
            "adapter_generation": .number("7"),
            "deleted_backend_ids": .array([]),
            "did_write_backend": .bool(true),
            "locations": .array([location]),
            "observed_pid": .number("42"),
            "observed_stop_id": .number("12"),
            "ok": .bool(true),
            "plan_digest": .string(hex(prepared.plan.canonicalPlanDigest.bytes)),
            "pre_state": .array([]),
            "schema": .number("1"),
            "session_epoch": .string(epoch.rawValue.uuidString.lowercased()),
            "token": .string(hex(token)),
            "transaction_id": .string(transactionID.rawValue.uuidString.lowercased()),
        ]).canonicalJSONBytes()
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
