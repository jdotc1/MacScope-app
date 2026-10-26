import CryptoKit
import Foundation

enum LLDBRunToCursorTransactionCodecError: Error, Equatable, Sendable {
    case invalidAuthority
    case invalidIdentity
    case invalidMapping
    case capacityExceeded
    case contradictoryReceipt
}

/// A private execution-control identity. It is intentionally unrelated to logical-breakpoint IDs
/// so a temporary Run to Cursor binding cannot enter the durable logical catalog by construction.
struct LLDBRunToCursorRunID: Hashable, Sendable {
    let rawValue: UUID

    init?(rawValue: UUID) {
        guard rawValue != Self.nilUUID else { return nil }
        self.rawValue = rawValue
    }

    private static let nilUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

/// Complete, immutable evidence for one private one-shot helper mutation. The helper command
/// builder is deliberately a later seam; this value freezes only its bounded canonical schema.
struct LLDBRunToCursorPreparedTransaction: Hashable, Sendable {
    static let rawPlanPageByteCount = 448
    static let maximumPlanBytes = 4 * 1_024
    static let maximumReceiptBytes = 4 * 1_024

    let resolvedAddress: DebuggerResolvedRuntimeAddress
    let observedStopID: UInt32
    let adapterGeneration: UInt64
    let observedPID: Int32
    let runID: LLDBRunToCursorRunID
    let ownerDigest: DebuggerBreakpointDigest
    let expectedNameOwnerDigest: DebuggerBreakpointDigest
    let canonicalPlanDigest: DebuggerBreakpointDigest
    let canonicalPlanBytes: Data
    let pages: [LLDBLogicalBreakpointPlanPage]
    let receiptByteCountUpperBound: Int
}

/// A receipt for one private Run to Cursor location. This type must never be converted into or
/// substituted for `DebuggerBreakpointBindingReceipt`, whose inventory belongs to the logical
/// breakpoint catalog and has different ownership and deletion semantics.
struct LLDBRunToCursorPrivateReceipt: Hashable, Sendable {
    let backendBreakpointID: UInt64
    let backendLocationID: UInt64
    let runtimeAddress: UInt64
    let nameOwnerDigest: DebuggerBreakpointDigest
    let canonicalPlanDigest: DebuggerBreakpointDigest
    let adapterGeneration: UInt64
    let observedPID: Int32
    let observedStopID: UInt32
    let runID: LLDBRunToCursorRunID
    let oneShot: Bool
}

/// Pure fail-closed conversion and receipt validation for Run to Cursor's private helper purpose.
struct LLDBRunToCursorTransactionCodec: Sendable {
    func prepare(
        resolvedAddress: DebuggerResolvedRuntimeAddress,
        observedStopID: UInt32,
        adapterGeneration: UInt64,
        runtimeInventory: DebuggerRuntimeModuleInventory,
        runID: LLDBRunToCursorRunID,
        ownerDigest: DebuggerBreakpointDigest
    ) throws -> LLDBRunToCursorPreparedTransaction {
        let key = resolvedAddress.projectionKey
        guard adapterGeneration > 0,
              observedStopID > 0,
              runtimeInventory.observedStopID == observedStopID,
              runtimeInventory.processID > 0,
              runtimeInventory.stop == key.stopCoordinate,
              runtimeInventory.processID == key.observedPID,
              runtimeInventory.revision == key.inventoryRevision,
              key.authorityRevision.rawValue > 0,
              key.inventoryRevision.rawValue > 0,
              key.workspaceCatalogRevision.rawValue > 0,
              resolvedAddress.moduleInstanceID.processID == runtimeInventory.processID,
              resolvedAddress.moduleInstanceID.stop == runtimeInventory.stop,
              resolvedAddress.moduleInstanceID.inventoryRevision == runtimeInventory.revision,
              resolvedAddress.imageAddress.slot == resolvedAddress.workspaceCoordinate.slot,
              resolvedAddress.workspaceCoordinate.slot.rawValue >= 0,
              resolvedAddress.workspaceCoordinate.binaryID != Self.nilUUID,
              resolvedAddress.workspaceCoordinate.ownerRevision.rawValue > 0 else {
            throw LLDBRunToCursorTransactionCodecError.invalidAuthority
        }

        let moduleMatches = runtimeInventory.modules.filter {
            $0.id == resolvedAddress.moduleInstanceID
        }
        guard moduleMatches.count == 1 else {
            throw LLDBRunToCursorTransactionCodecError.invalidMapping
        }
        let module = moduleMatches[0]
        guard module.observation.processID == runtimeInventory.processID,
              module.observation.observedStopID == observedStopID,
              let artifactUUID = resolvedAddress.workspaceCoordinate.artifactIdentity.uuid,
              artifactUUID != Self.nilUUID,
              module.observation.uuid == artifactUUID else {
            throw LLDBRunToCursorTransactionCodecError.invalidMapping
        }

        let mappedRanges = module.observation.mappedRanges.filter { range in
            guard range.permissions & Self.executePermission != 0,
                  Self.contains(
                    resolvedAddress.imageAddress.address,
                    start: range.staticStart,
                    byteCount: range.byteCount
                  ),
                  Self.contains(
                    resolvedAddress.runtimeAddress,
                    start: range.runtimeStart,
                    byteCount: range.byteCount
                  ) else {
                return false
            }
            return resolvedAddress.imageAddress.address - range.staticStart
                == resolvedAddress.runtimeAddress - range.runtimeStart
        }
        guard mappedRanges.count == 1 else {
            throw LLDBRunToCursorTransactionCodecError.invalidMapping
        }
        let mapping = mappedRanges[0]

        let ownedName = Self.ownedName(
            generation: adapterGeneration,
            ownerDigest: ownerDigest,
            runID: runID
        )
        let ownedNameBytes = Data(ownedName.utf8)
        guard !ownedNameBytes.isEmpty,
              ownedNameBytes.count <= Self.maximumOwnedNameBytes,
              let nameOwnerDigest = DebuggerBreakpointDigest(
                Data(SHA256.hash(data: ownedNameBytes))
              ) else {
            throw LLDBRunToCursorTransactionCodecError.invalidIdentity
        }

        let binding = Phase2ProductionJSONValue.object([
            "artifact_uuid": .string(artifactUUID.uuidString.lowercased()),
            "mapped_byte_count": .number(String(mapping.byteCount)),
            "mapped_runtime_start": .string(Self.address(mapping.runtimeStart)),
            "mapped_static_start": .string(Self.address(mapping.staticStart)),
            "module_ordinal": .number(String(resolvedAddress.moduleInstanceID.ordinal)),
            "name_owner_digest": .string(Self.hex(nameOwnerDigest.bytes)),
            "one_shot": .bool(true),
            "owned_name_b64": .string(ownedNameBytes.base64EncodedString()),
            "purpose": .string(Self.privatePurpose),
            "runtime_address": .string(Self.address(resolvedAddress.runtimeAddress)),
            "static_address": .string(Self.address(resolvedAddress.imageAddress.address)),
            "workspace_binary_id": .string(
                resolvedAddress.workspaceCoordinate.binaryID.uuidString.lowercased()
            ),
            "workspace_owner_revision": .number(String(
                resolvedAddress.workspaceCoordinate.ownerRevision.rawValue
            )),
            "workspace_slot": .number(String(resolvedAddress.workspaceCoordinate.slot.rawValue)),
        ])
        let root = Phase2ProductionJSONValue.object([
            "adapter_generation": .number(String(adapterGeneration)),
            "authority_revision": .number(String(key.authorityRevision.rawValue)),
            "binding": binding,
            "inventory_revision": .number(String(runtimeInventory.revision.rawValue)),
            "lifecycle_revision": .number(String(
                runtimeInventory.stop.session.lifecycleRevision.rawValue
            )),
            "observed_pid": .number(String(runtimeInventory.processID)),
            "observed_stop_id": .number(String(observedStopID)),
            "owner_digest": .string(Self.hex(ownerDigest.bytes)),
            "run_id": .string(runID.rawValue.uuidString.lowercased()),
            "schema": .number("1"),
            "session_epoch": .string(
                runtimeInventory.stop.session.epoch.rawValue.uuidString.lowercased()
            ),
            "stop_revision": .number(String(runtimeInventory.stop.stopRevision.rawValue)),
            "workspace_catalog_revision": .number(String(key.workspaceCatalogRevision.rawValue)),
        ])
        let bytes = root.canonicalJSONBytes()
        guard !bytes.isEmpty,
              bytes.count <= LLDBRunToCursorPreparedTransaction.maximumPlanBytes,
              let planDigest = DebuggerBreakpointDigest(Data(SHA256.hash(data: bytes))) else {
            throw LLDBRunToCursorTransactionCodecError.capacityExceeded
        }
        let pages = stride(
            from: 0,
            to: bytes.count,
            by: LLDBRunToCursorPreparedTransaction.rawPlanPageByteCount
        ).enumerated().map { index, offset in
            let page = bytes.subdata(
                in: offset..<min(
                    offset + LLDBRunToCursorPreparedTransaction.rawPlanPageByteCount,
                    bytes.count
                )
            )
            return LLDBLogicalBreakpointPlanPage(
                index: index,
                payload: page,
                payloadSHA256: Data(SHA256.hash(data: page))
            )
        }
        guard !pages.isEmpty,
              pages.count <= LLDBLogicalBreakpointProgram.maximumPlanPageCount,
              pages.allSatisfy({
                $0.payloadBase64.utf8.count
                    <= LLDBLogicalBreakpointProgram.maximumPlanPageBase64Characters
              }) else {
            throw LLDBRunToCursorTransactionCodecError.capacityExceeded
        }
        return LLDBRunToCursorPreparedTransaction(
            resolvedAddress: resolvedAddress,
            observedStopID: observedStopID,
            adapterGeneration: adapterGeneration,
            observedPID: runtimeInventory.processID,
            runID: runID,
            ownerDigest: ownerDigest,
            expectedNameOwnerDigest: nameOwnerDigest,
            canonicalPlanDigest: planDigest,
            canonicalPlanBytes: bytes,
            pages: pages,
            receiptByteCountUpperBound: LLDBRunToCursorPreparedTransaction.maximumReceiptBytes
        )
    }

    func decodeReceipt(
        _ bytes: Data,
        for prepared: LLDBRunToCursorPreparedTransaction
    ) throws -> LLDBRunToCursorPrivateReceipt {
        guard !bytes.isEmpty,
              bytes.count <= LLDBRunToCursorPreparedTransaction.maximumReceiptBytes else {
            throw LLDBRunToCursorTransactionCodecError.contradictoryReceipt
        }
        let value: Phase2ProductionJSONValue
        do {
            value = try Phase2StrictJSONParser().parse(
                bytes,
                limits: Phase2StrictJSONLimits(
                    maximumBytes: LLDBRunToCursorPreparedTransaction.maximumReceiptBytes,
                    maximumDepth: 4,
                    maximumTokens: 64,
                    maximumMembersAndElements: 32
                )
            )
        } catch {
            throw LLDBRunToCursorTransactionCodecError.contradictoryReceipt
        }
        let expectedKeys: Set<String> = [
            "adapter_generation", "backend_breakpoint_id", "backend_location_id",
            "name_owner_digest", "observed_pid", "observed_stop_id", "ok", "one_shot",
            "plan_digest", "purpose", "run_id", "runtime_address", "schema",
        ]
        guard value.canonicalJSONBytes() == bytes,
              let object = value.objectValue,
              Set(object.keys) == expectedKeys,
              Self.uint(object["schema"]) == 1,
              object["ok"]?.boolValue == true,
              object["one_shot"]?.boolValue == true,
              object["purpose"]?.stringValue == Self.privatePurpose,
              Self.uint(object["adapter_generation"]) == prepared.adapterGeneration,
              Self.uint(object["observed_pid"]) == UInt64(prepared.observedPID),
              Self.uint(object["observed_stop_id"]) == UInt64(prepared.observedStopID),
              object["run_id"]?.stringValue
                == prepared.runID.rawValue.uuidString.lowercased(),
              Self.fixedAddress(object["runtime_address"])
                == prepared.resolvedAddress.runtimeAddress,
              object["name_owner_digest"]?.stringValue
                == Self.hex(prepared.expectedNameOwnerDigest.bytes),
              object["plan_digest"]?.stringValue
                == Self.hex(prepared.canonicalPlanDigest.bytes),
              let backendBreakpointID = Self.uint(object["backend_breakpoint_id"]),
              backendBreakpointID > 0,
              backendBreakpointID <= UInt64(Int32.max),
              let backendLocationID = Self.uint(object["backend_location_id"]),
              backendLocationID > 0,
              backendLocationID <= UInt64(Int32.max) else {
            throw LLDBRunToCursorTransactionCodecError.contradictoryReceipt
        }
        return LLDBRunToCursorPrivateReceipt(
            backendBreakpointID: backendBreakpointID,
            backendLocationID: backendLocationID,
            runtimeAddress: prepared.resolvedAddress.runtimeAddress,
            nameOwnerDigest: prepared.expectedNameOwnerDigest,
            canonicalPlanDigest: prepared.canonicalPlanDigest,
            adapterGeneration: prepared.adapterGeneration,
            observedPID: prepared.observedPID,
            observedStopID: prepared.observedStopID,
            runID: prepared.runID,
            oneShot: true
        )
    }

    private static let executePermission: UInt8 = 4
    private static let maximumOwnedNameBytes = 256
    private static let privatePurpose = "run_to_cursor"
    private static let nilUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    private static func ownedName(
        generation: UInt64,
        ownerDigest: DebuggerBreakpointDigest,
        runID: LLDBRunToCursorRunID
    ) -> String {
        "macscope_private_run_to_cursor_g\(generation)_\(hex(ownerDigest.bytes))_"
            + runID.rawValue.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    private static func contains(
        _ address: UInt64,
        start: UInt64,
        byteCount: UInt64
    ) -> Bool {
        address >= start && address - start < byteCount
    }

    private static func address(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func uint(_ value: Phase2ProductionJSONValue?) -> UInt64? {
        guard let text = value.flatMap({
            if case .number(let text) = $0 { text } else { nil }
        }), !text.isEmpty, text == "0" || !text.hasPrefix("0") else {
            return nil
        }
        return UInt64(text)
    }

    private static func fixedAddress(_ value: Phase2ProductionJSONValue?) -> UInt64? {
        guard let text = value?.stringValue,
              text.utf8.count == 16,
              text.utf8.allSatisfy({ byte in
                (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
              }) else {
            return nil
        }
        return UInt64(text, radix: 16)
    }
}
