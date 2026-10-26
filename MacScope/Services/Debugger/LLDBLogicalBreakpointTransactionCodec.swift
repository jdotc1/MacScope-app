import CryptoKit
import Foundation

enum LLDBLogicalBreakpointTransactionCodecError: Error, Equatable, Sendable {
    case invalidAuthority
    case invalidCapability(String)
    case invalidBinding
    case invalidMapping
    case capacityExceeded
    case invalidToken
    case invalidResponse
    case incompleteReceipt
    case contradictoryReceipt
}

struct LLDBLogicalBreakpointPlanPage: Hashable, Sendable {
    let index: Int
    let payload: Data
    let payloadSHA256: Data

    var payloadBase64: String { payload.base64EncodedString() }
}

struct LLDBLogicalBreakpointWireBinding: Hashable, Sendable {
    let wireID: String
    let binding: DebuggerDesiredBreakpointBinding
    let expectedOwnedNameSHA256: Data
}

struct LLDBLogicalBreakpointPreparedTransaction: Hashable, Sendable {
    // 448 raw bytes expand to at most 600 Base64 characters and keep the complete twice-wrapped,
    // token-correlated persistent-adapter wire below its frozen 4 KiB ceiling with useful margin.
    // The frozen 8,192-page ceiling still spans the complete 2 MiB plan limit.
    static let rawPlanPageByteCount = 448

    let plan: DebuggerBreakpointBindingPlan
    let canonicalPlanBytes: Data
    let pages: [LLDBLogicalBreakpointPlanPage]
    let wireBindings: [LLDBLogicalBreakpointWireBinding]
    /// Frozen conservative reservation ceiling, not a prediction of the actual canonical receipt.
    /// It covers reducer-unknown prior owned state without importing another authority envelope.
    let receiptByteCountUpperBound: Int

    func beginCommand(
        token: Data,
        program: LLDBLogicalBreakpointProgram = .current
    ) throws -> String {
        try program.beginCommand(
            token: token,
            adapterGeneration: plan.adapterGeneration,
            expectedProcessID: plan.observedPID,
            expectedStopID: plan.observedStopID,
            pageCount: pages.count,
            planByteCount: canonicalPlanBytes.count,
            planSHA256: plan.canonicalPlanDigest.bytes
        )
    }

    func uploadCommands(
        token: Data,
        program: LLDBLogicalBreakpointProgram = .current
    ) throws -> [String] {
        try pages.map { page in
            try program.uploadPageCommand(
                token: token,
                pageIndex: page.index,
                pageCount: pages.count,
                payloadBase64: page.payloadBase64,
                payloadSHA256: page.payloadSHA256
            )
        }
    }
}

/// Trusted conversion from a complete reducer-qualified resolution observation to the helper's
/// closed, token-independent canonical plan schema. Authored strings are always Base64 data.
struct LLDBLogicalBreakpointTransactionCodec: Sendable {
    func prepare(
        request: DebuggerLogicalBreakpointReconcileRequest,
        transactionID: DebuggerBreakpointBindingTransactionID,
        adapterGeneration: UInt64,
        runtimeInventory: DebuggerRuntimeModuleInventory,
        ownershipTagDigest: DebuggerBreakpointDigest
    ) throws -> LLDBLogicalBreakpointPreparedTransaction {
        let observation = request.observation
        guard adapterGeneration > 0,
              runtimeInventory.stop == observation.mappingKey.stopCoordinate,
              runtimeInventory.processID == observation.mappingKey.observedPID,
              runtimeInventory.observedStopID > 0,
              runtimeInventory.revision == observation.mappingKey.inventoryRevision,
              observation.logicalCatalogCoordinate.catalogID == request.catalog.catalogID,
              observation.logicalCatalogCoordinate.revision == request.catalog.revision else {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidAuthority
        }

        let specifications = Dictionary(uniqueKeysWithValues: request.catalog.specifications.map {
            ($0.id, $0)
        })
        var bindings: [DebuggerDesiredBreakpointBinding] = []
        for result in observation.results {
            guard let specification = specifications[result.logicalID],
                  specification.revision == result.specificationRevision else {
                throw LLDBLogicalBreakpointTransactionCodecError.invalidAuthority
            }
            if specification.enabled {
                try requireCapabilities(for: specification)
            }
            switch result.state {
            case .disabled:
                guard !specification.enabled else {
                    throw LLDBLogicalBreakpointTransactionCodecError.invalidAuthority
                }
            case .resolved(_, let binding):
                guard specification.enabled else {
                    throw LLDBLogicalBreakpointTransactionCodecError.invalidAuthority
                }
                bindings.append(binding)
            case .resolvedMultiple(_, let resolvedBindings):
                guard specification.enabled else {
                    throw LLDBLogicalBreakpointTransactionCodecError.invalidAuthority
                }
                bindings.append(contentsOf: resolvedBindings)
            case .pending, .invalid:
                guard specification.enabled else {
                    throw LLDBLogicalBreakpointTransactionCodecError.invalidAuthority
                }
            }
        }
        guard bindings.count <= 4_096,
              Set(bindings.map(\.id)).count == bindings.count,
              Set(bindings.map(\.runtimeAddress)).count == bindings.count else {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidBinding
        }
        bindings.sort(by: bindingPrecedes)

        var wireBindings: [LLDBLogicalBreakpointWireBinding] = []
        var wireObjects: [Phase2ProductionJSONValue] = []
        for binding in bindings {
            guard let specification = specifications[binding.id.logicalID] else {
                throw LLDBLogicalBreakpointTransactionCodecError.invalidAuthority
            }
            let canonicalSpecification = try DebuggerLogicalBreakpointCanonicalCodec
                .encodeSpecification(specification)
            let expectedPolicyDigest = Data(SHA256.hash(data: canonicalSpecification))
            guard binding.policyActionDigest.bytes == expectedPolicyDigest,
                  binding.issuanceDigest.bytes == issuanceDigest(
                    policyDigest: expectedPolicyDigest,
                    binding: binding
                  ),
                  binding.mappingKey == observation.mappingKey,
                  binding.site.logicalID == specification.id,
                  binding.site.specificationRevision == specification.revision,
                  owner(of: specification.target) == binding.site.owner,
                  binding.site.owner.artifactIdentity == binding.site.coordinate.artifactIdentity,
                  binding.id.siteID == binding.site.siteID else {
                throw LLDBLogicalBreakpointTransactionCodecError.invalidBinding
            }
            let evidence = try exactMapping(
                for: binding,
                inventory: runtimeInventory
            )
            let wireID = "b1." + hex(Data(SHA256.hash(data: bindingIdentity(binding))))
            let object = try bindingObject(
                binding,
                specification: specification,
                wireID: wireID,
                mapping: evidence,
                artifactUUID: evidence.artifactUUID,
                ownerTagDigest: ownershipTagDigest
            )
            let name = ownedName(
                generation: adapterGeneration,
                ownerTagDigest: ownershipTagDigest,
                wireID: wireID,
                policyDigest: binding.policyActionDigest,
                issuanceDigest: binding.issuanceDigest
            )
            guard name.utf8.count <= 256,
                  name.utf8.allSatisfy({
                      (0x30...0x39).contains($0)
                          || (0x41...0x5A).contains($0)
                          || (0x61...0x7A).contains($0)
                          || $0 == 0x5F
                  }) else {
                throw LLDBLogicalBreakpointTransactionCodecError.invalidBinding
            }
            wireBindings.append(LLDBLogicalBreakpointWireBinding(
                wireID: wireID,
                binding: binding,
                expectedOwnedNameSHA256: Data(SHA256.hash(data: Data(name.utf8)))
            ))
            wireObjects.append(object)
        }
        guard Set(wireBindings.map(\.wireID)).count == wireBindings.count else {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidBinding
        }

        let root = Phase2ProductionJSONValue.object([
            "adapter_generation": .number(String(adapterGeneration)),
            "bindings": .array(wireObjects),
            "observed_pid": .number(String(runtimeInventory.processID)),
            "observed_stop_id": .number(String(runtimeInventory.observedStopID)),
            "owner_tag_digest": .string(hex(ownershipTagDigest.bytes)),
            "purpose": .string("logical"),
            "schema": .number("1"),
            "session_epoch": .string(
                observation.mappingKey.stopCoordinate.session.epoch.rawValue.uuidString.lowercased()
            ),
            "transaction_id": .string(transactionID.rawValue.uuidString.lowercased()),
        ])
        let bytes = root.canonicalJSONBytes()
        guard !bytes.isEmpty, bytes.count <= LLDBLogicalBreakpointProgram.maximumPlanBytes else {
            throw LLDBLogicalBreakpointTransactionCodecError.capacityExceeded
        }
        let digestBytes = Data(SHA256.hash(data: bytes))
        guard let digest = DebuggerBreakpointDigest(digestBytes),
              let plan = DebuggerBreakpointBindingPlan(
                transactionID: transactionID,
                sessionEpoch: observation.mappingKey.stopCoordinate.session.epoch,
                adapterGeneration: adapterGeneration,
                stopCoordinate: observation.mappingKey.stopCoordinate,
                observedPID: runtimeInventory.processID,
                observedStopID: runtimeInventory.observedStopID,
                logicalCatalogCoordinate: observation.logicalCatalogCoordinate,
                resolutionCatalogCoordinate: observation.resolutionCatalogCoordinate,
                resolutionObservationDigest: observation.canonicalDigest,
                mappingKey: observation.mappingKey,
                bindings: bindings,
                ownershipTagDigest: ownershipTagDigest,
                canonicalPlanDigest: digest
              ) else {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidAuthority
        }
        let pages = stride(from: 0, to: bytes.count, by: Self.pageByteCount).enumerated().map {
            index, offset in
            let page = bytes.subdata(in: offset..<min(offset + Self.pageByteCount, bytes.count))
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
            throw LLDBLogicalBreakpointTransactionCodecError.capacityExceeded
        }
        return LLDBLogicalBreakpointPreparedTransaction(
            plan: plan,
            canonicalPlanBytes: bytes,
            pages: pages,
            wireBindings: wireBindings,
            receiptByteCountUpperBound: LLDBLogicalBreakpointProgram.maximumReceiptBytes
        )
    }

    private static let pageByteCount = LLDBLogicalBreakpointPreparedTransaction.rawPlanPageByteCount

    private struct MappingEvidence {
        let staticStart: UInt64
        let runtimeStart: UInt64
        let byteCount: UInt64
        let artifactUUID: UUID
    }

    private func exactMapping(
        for binding: DebuggerDesiredBreakpointBinding,
        inventory: DebuggerRuntimeModuleInventory
    ) throws -> MappingEvidence {
        let instanceMatches = inventory.modules.filter { $0.id == binding.id.moduleInstanceID }
        guard instanceMatches.count == 1,
              instanceMatches[0].observation.processID == inventory.processID,
              instanceMatches[0].observation.observedStopID == inventory.observedStopID,
              let artifactUUID = binding.site.coordinate.artifactIdentity.uuid,
              instanceMatches[0].observation.uuid == artifactUUID else {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidMapping
        }
        let ranges = instanceMatches[0].observation.mappedRanges.filter { range in
            guard range.permissions & 4 != 0,
                  contains(binding.site.imageAddress.address, in: range.staticStart, count: range.byteCount),
                  contains(binding.runtimeAddress, in: range.runtimeStart, count: range.byteCount) else {
                return false
            }
            return binding.site.imageAddress.address - range.staticStart
                == binding.runtimeAddress - range.runtimeStart
        }
        guard ranges.count == 1 else {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidMapping
        }
        return MappingEvidence(
            staticStart: ranges[0].staticStart,
            runtimeStart: ranges[0].runtimeStart,
            byteCount: ranges[0].byteCount,
            artifactUUID: artifactUUID
        )
    }

    private func bindingObject(
        _ binding: DebuggerDesiredBreakpointBinding,
        specification: DebuggerLogicalBreakpointSpecification,
        wireID: String,
        mapping: MappingEvidence,
        artifactUUID: UUID,
        ownerTagDigest: DebuggerBreakpointDigest
    ) throws -> Phase2ProductionJSONValue {
        .object([
            "actions": try actions(specification.actions),
            "artifact_uuid": .string(artifactUUID.uuidString.lowercased()),
            "binding_id": .string(wireID),
            "condition_b64": specification.condition.map(base64) ?? .null,
            "disposition": .string(disposition(specification.disposition)),
            "hit_policy": hitPolicy(specification.hitPolicy),
            "issuance_digest": .string(hex(binding.issuanceDigest.bytes)),
            "logical_id": .string(specification.id.rawValue.uuidString.lowercased()),
            "mapped_byte_count": .number(String(mapping.byteCount)),
            "mapped_runtime_start": .string(address(mapping.runtimeStart)),
            "mapped_static_start": .string(address(mapping.staticStart)),
            "owner_tag_digest": .string(hex(ownerTagDigest.bytes)),
            "policy_action_digest": .string(hex(binding.policyActionDigest.bytes)),
            "runtime_address": .string(address(binding.runtimeAddress)),
            "specification_revision": .number(String(specification.revision.rawValue)),
            "static_address": .string(address(binding.site.imageAddress.address)),
        ])
    }

    private func requireCapabilities(
        for specification: DebuggerLogicalBreakpointSpecification
    ) throws {
        let availableCapabilities = LLDBLogicalBreakpointProgram.liveProvenCapabilities
        if specification.condition != nil,
           !availableCapabilities.contains(.condition) {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidCapability("condition")
        }
        if case .ignoreFirst = specification.hitPolicy,
           !availableCapabilities.contains(.ignoreFirst) {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidCapability("ignoreFirst")
        }
        if !specification.actions.isEmpty,
           !availableCapabilities.contains(.actions) {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidCapability("actions")
        }
        let needsExpression = specification.actions.contains { action in
            switch action {
            case .evaluateTargetExpression: true
            case .log(let template): template.fragments.contains {
                if case .targetExpression = $0 { true } else { false }
            }
            }
        }
        if needsExpression,
           !availableCapabilities.contains(.targetExpression) {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidCapability("targetExpression")
        }
        if specification.disposition == .continueAfterSuccessfulActions,
           !availableCapabilities.contains(.continueAfterSuccessfulActions) {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidCapability(
                "continueAfterSuccessfulActions"
            )
        }
    }

    private func owner(
        of target: DebuggerLogicalBreakpointTarget
    ) -> DebuggerWorkspaceImageOwnerSeal {
        switch target {
        case .preferredAddress(let owner, _),
             .imageOffset(let owner, _, _, _),
             .function(let owner, _, _),
             .symbol(let owner, _, _, _, _),
             .source(let owner, _, _, _, _):
            owner
        }
    }

    private func actions(
        _ values: [DebuggerBreakpointAction]
    ) throws -> Phase2ProductionJSONValue {
        var combinedBytes = 0
        let encoded: [Phase2ProductionJSONValue] = try values.map { action in
            switch action {
            case .evaluateTargetExpression(let capture):
                combinedBytes += capture.label.utf8.count + capture.expression.utf8.count
                return .object([
                    "expression_b64": base64(capture.expression),
                    "kind": .string("evaluate_target_expression"),
                    "label_b64": base64(capture.label),
                ])
            case .log(let template):
                guard template.fragments.count <= 32 else {
                    throw LLDBLogicalBreakpointTransactionCodecError.capacityExceeded
                }
                let fragments: [Phase2ProductionJSONValue] = template.fragments.map { fragment in
                    let kind: String
                    let value: String
                    switch fragment {
                    case .literal(let text): kind = "literal"; value = text
                    case .targetExpression(let expression):
                        kind = "target_expression"; value = expression
                    }
                    combinedBytes += value.utf8.count
                    return .object([
                        "kind": .string(kind),
                        "value_b64": base64(value),
                    ])
                }
                return .object(["fragments": .array(fragments), "kind": .string("log")])
            }
        }
        guard combinedBytes <= 16 * 1_024 else {
            throw LLDBLogicalBreakpointTransactionCodecError.capacityExceeded
        }
        return .array(encoded)
    }

    private func hitPolicy(_ value: DebuggerBreakpointHitPolicy) -> Phase2ProductionJSONValue {
        switch value {
        case .always: .object(["count": .null, "kind": .string("always")])
        case .ignoreFirst(let count):
            .object(["count": .number(String(count)), "kind": .string("ignore_first")])
        }
    }

    private func disposition(_ value: DebuggerBreakpointDisposition) -> String {
        switch value {
        case .stop: "stop"
        case .continueAfterSuccessfulActions: "continue_after_successful_actions"
        }
    }

    private func bindingIdentity(_ binding: DebuggerDesiredBreakpointBinding) -> Data {
        Phase2ProductionJSONValue.array([
            .string(binding.id.logicalID.rawValue.uuidString.lowercased()),
            .number(String(binding.id.siteID.specificationRevision.rawValue)),
            .number(String(binding.id.siteID.imageAddress.slot.rawValue)),
            .string(address(binding.id.siteID.imageAddress.address)),
            .number(String(binding.id.siteID.staticOrdinal)),
            .string(binding.id.moduleInstanceID.stop.session.epoch.rawValue.uuidString.lowercased()),
            .number(String(binding.id.moduleInstanceID.stop.session.lifecycleRevision.rawValue)),
            .number(String(binding.id.moduleInstanceID.stop.stopRevision.rawValue)),
            .number(String(binding.id.moduleInstanceID.inventoryRevision.rawValue)),
            .number(String(binding.id.moduleInstanceID.ordinal)),
        ]).canonicalJSONBytes()
    }

    private func issuanceDigest(
        policyDigest: Data,
        binding: DebuggerDesiredBreakpointBinding
    ) -> Data {
        var material = policyDigest
        material.append(contentsOf: binding.site.logicalID.rawValue.uuidString.utf8)
        material.append(contentsOf: String(binding.site.specificationRevision.rawValue).utf8)
        material.append(contentsOf: String(binding.site.siteID.staticOrdinal).utf8)
        material.append(contentsOf: String(binding.site.imageAddress.slot.rawValue).utf8)
        material.append(contentsOf: String(binding.site.imageAddress.address).utf8)
        material.append(contentsOf: String(binding.runtimeAddress).utf8)
        material.append(contentsOf: String(binding.id.moduleInstanceID.ordinal).utf8)
        material.append(contentsOf: String(binding.mappingKey.inventoryRevision.rawValue).utf8)
        return Data(SHA256.hash(data: material))
    }

    private func bindingPrecedes(
        _ lhs: DebuggerDesiredBreakpointBinding,
        _ rhs: DebuggerDesiredBreakpointBinding
    ) -> Bool {
        if lhs.runtimeAddress != rhs.runtimeAddress { return lhs.runtimeAddress < rhs.runtimeAddress }
        return bindingIdentity(lhs).lexicographicallyPrecedes(bindingIdentity(rhs))
    }
}

struct LLDBLogicalBreakpointReceiptAssembler: Sendable {
    private let prepared: LLDBLogicalBreakpointPreparedTransaction
    private let token: Data
    private let expectedReceiptSHA256: Data
    private let expectedLocationCount: Int
    private var bytes = Data()
    private var isFinal = false

    init(
        prepared: LLDBLogicalBreakpointPreparedTransaction,
        token: Data,
        appliedResponse: LLDBLogicalBreakpointResponse
    ) throws {
        guard token.count == 32,
              case .applied(let responseToken, let count, let digest) = appliedResponse,
              responseToken == token,
              count == prepared.wireBindings.count,
              digest.count == 32 else {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidResponse
        }
        self.prepared = prepared
        self.token = token
        expectedReceiptSHA256 = digest
        expectedLocationCount = count
    }

    mutating func append(_ response: LLDBLogicalBreakpointResponse) throws {
        guard !isFinal,
              case .receiptPage(
                let responseToken, let cursor, let next, let final, let digest, let payload
              ) = response else {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidResponse
        }
        let nextCursor = cursor.addingReportingOverflow(payload.count)
        let totalBytes = bytes.count.addingReportingOverflow(payload.count)
        guard !nextCursor.overflow,
              !totalBytes.overflow,
              responseToken == token,
              cursor == bytes.count,
              next == nextCursor.partialValue,
              digest == expectedReceiptSHA256,
              !payload.isEmpty,
              payload.count
                <= LLDBLogicalBreakpointTransactionReservation.receiptPagePayloadByteCount,
              totalBytes.partialValue <= prepared.receiptByteCountUpperBound,
              final || payload.count
                == LLDBLogicalBreakpointTransactionReservation.receiptPagePayloadByteCount else {
            throw LLDBLogicalBreakpointTransactionCodecError.invalidResponse
        }
        bytes.append(payload)
        isFinal = final
    }

    func finish() throws -> DebuggerBreakpointBindingReceipt {
        guard isFinal, !bytes.isEmpty else {
            throw LLDBLogicalBreakpointTransactionCodecError.incompleteReceipt
        }
        guard Data(SHA256.hash(data: bytes)) == expectedReceiptSHA256 else {
            throw LLDBLogicalBreakpointTransactionCodecError.contradictoryReceipt
        }
        let limits = Phase2StrictJSONLimits(
            maximumBytes: prepared.receiptByteCountUpperBound,
            maximumDepth: 8,
            maximumTokens: 250_000,
            maximumMembersAndElements: 100_000
        )
        let value: Phase2ProductionJSONValue
        do {
            value = try Phase2StrictJSONParser().parse(bytes, limits: limits)
        } catch {
            throw LLDBLogicalBreakpointTransactionCodecError.contradictoryReceipt
        }
        guard value.canonicalJSONBytes() == bytes, let object = value.objectValue else {
            throw LLDBLogicalBreakpointTransactionCodecError.contradictoryReceipt
        }
        return try decodeReceipt(object)
    }

    private func decodeReceipt(
        _ object: [String: Phase2ProductionJSONValue]
    ) throws -> DebuggerBreakpointBindingReceipt {
        let keys: Set<String> = [
            "adapter_generation", "deleted_backend_ids", "did_write_backend", "locations",
            "observed_pid", "observed_stop_id", "ok", "plan_digest", "pre_state", "schema",
            "session_epoch", "token", "transaction_id",
        ]
        guard Set(object.keys) == keys,
              uint(object["schema"]) == 1,
              object["ok"]?.boolValue == true,
              uint(object["adapter_generation"]) == prepared.plan.adapterGeneration,
              uint(object["observed_pid"]) == UInt64(prepared.plan.observedPID),
              uint(object["observed_stop_id"]) == UInt64(prepared.plan.observedStopID),
              object["plan_digest"]?.stringValue == hex(prepared.plan.canonicalPlanDigest.bytes),
              object["session_epoch"]?.stringValue
                == prepared.plan.sessionEpoch.rawValue.uuidString.lowercased(),
              object["transaction_id"]?.stringValue
                == prepared.plan.transactionID.rawValue.uuidString.lowercased(),
              object["token"]?.stringValue == hex(token),
              let didWrite = object["did_write_backend"]?.boolValue,
              let deletedValues = object["deleted_backend_ids"]?.arrayValue,
              let preValues = object["pre_state"]?.arrayValue,
              let locationValues = object["locations"]?.arrayValue,
              locationValues.count == expectedLocationCount else {
            throw LLDBLogicalBreakpointTransactionCodecError.contradictoryReceipt
        }
        let deleted = try deletedValues.map { try requiredPositive($0) }
        let pre = try preValues.map { try decodePreState($0) }
        let locations = try locationValues.map { try decodeLocation($0) }
        guard Set(deleted).count == deleted.count,
              Set(pre.map(\.backendID)).count == pre.count,
              Set(locations.map(\.backendBreakpointID)).count == locations.count,
              Set(locations.map(\.bindingID)).count == locations.count else {
            throw LLDBLogicalBreakpointTransactionCodecError.contradictoryReceipt
        }
        if didWrite {
            guard Set(deleted) == Set(pre.map(\.backendID)),
                  Set(deleted).isDisjoint(with: Set(locations.map(\.backendBreakpointID))) else {
                throw LLDBLogicalBreakpointTransactionCodecError.contradictoryReceipt
            }
        } else {
            guard deleted.isEmpty,
                  Set(pre.map(\.canonicalIdentity)) == Set(locations.map(preIdentity)) else {
                throw LLDBLogicalBreakpointTransactionCodecError.contradictoryReceipt
            }
        }
        guard let receipt = DebuggerBreakpointBindingReceipt(
            transactionID: prepared.plan.transactionID,
            sessionEpoch: prepared.plan.sessionEpoch,
            adapterGeneration: prepared.plan.adapterGeneration,
            stopCoordinate: prepared.plan.stopCoordinate,
            observedPID: prepared.plan.observedPID,
            observedStopID: prepared.plan.observedStopID,
            canonicalPlanDigest: prepared.plan.canonicalPlanDigest,
            didWriteBackend: didWrite,
            completeOwnedInventory: locations
        ) else {
            throw LLDBLogicalBreakpointTransactionCodecError.contradictoryReceipt
        }
        return receipt
    }

    private struct PreState {
        let backendID: UInt64
        let locationID: UInt64
        let runtimeAddress: UInt64
        let enabled: Bool
        let oneShot: Bool
        let autoContinue: Bool
        let nameSHA256: Data

        var canonicalIdentity: Data {
            Phase2ProductionJSONValue.array([
                .number(String(backendID)), .number(String(locationID)),
                .string(address(runtimeAddress)), .bool(enabled), .bool(oneShot),
                .bool(autoContinue), .string(hex(nameSHA256)),
            ]).canonicalJSONBytes()
        }
    }

    private func decodePreState(_ value: Phase2ProductionJSONValue) throws -> PreState {
        guard let object = value.objectValue,
              Set(object.keys) == [
                "auto_continue", "backend_breakpoint_id", "backend_location_id", "enabled",
                "name_sha256", "one_shot", "runtime_address",
              ],
              let enabled = object["enabled"]?.boolValue,
              let oneShot = object["one_shot"]?.boolValue,
              let autoContinue = object["auto_continue"]?.boolValue,
              let runtimeAddress = fixedAddress(object["runtime_address"]),
              let nameDigest = fixedDigest(object["name_sha256"]) else {
            throw LLDBLogicalBreakpointTransactionCodecError.contradictoryReceipt
        }
        return PreState(
            backendID: try requiredPositive(value: object["backend_breakpoint_id"]),
            locationID: try requiredPositive(value: object["backend_location_id"]),
            runtimeAddress: runtimeAddress,
            enabled: enabled,
            oneShot: oneShot,
            autoContinue: autoContinue,
            nameSHA256: nameDigest
        )
    }

    private func decodeLocation(
        _ value: Phase2ProductionJSONValue
    ) throws -> DebuggerOwnedBackendBreakpointLocation {
        guard let object = value.objectValue,
              Set(object.keys) == [
                "auto_continue", "backend_breakpoint_id", "backend_location_id", "binding_id",
                "enabled", "issuance_digest", "logical_id", "name_sha256", "one_shot",
                "owner_tag_digest", "policy_action_digest", "runtime_address",
                "specification_revision",
              ],
              object["enabled"]?.boolValue == true,
              object["one_shot"]?.boolValue == false,
              object["auto_continue"]?.boolValue == false,
              let wireID = object["binding_id"]?.stringValue,
              let ledger = prepared.wireBindings.first(where: { $0.wireID == wireID }),
              object["logical_id"]?.stringValue
                == ledger.binding.id.logicalID.rawValue.uuidString.lowercased(),
              uint(object["specification_revision"])
                == ledger.binding.id.siteID.specificationRevision.rawValue,
              object["owner_tag_digest"]?.stringValue
                == hex(prepared.plan.ownershipTagDigest.bytes),
              object["policy_action_digest"]?.stringValue
                == hex(ledger.binding.policyActionDigest.bytes),
              object["issuance_digest"]?.stringValue
                == hex(ledger.binding.issuanceDigest.bytes),
              object["name_sha256"]?.stringValue == hex(ledger.expectedOwnedNameSHA256),
              fixedAddress(object["runtime_address"]) == ledger.binding.runtimeAddress else {
            throw LLDBLogicalBreakpointTransactionCodecError.contradictoryReceipt
        }
        let backendID = try requiredPositive(value: object["backend_breakpoint_id"])
        let locationID = try requiredPositive(value: object["backend_location_id"])
        guard let location = DebuggerOwnedBackendBreakpointLocation(
            bindingID: ledger.binding.id,
            backendBreakpointID: backendID,
            backendLocationID: locationID,
            runtimeAddress: ledger.binding.runtimeAddress,
            ownershipTagDigest: prepared.plan.ownershipTagDigest,
            policyActionDigest: ledger.binding.policyActionDigest,
            issuanceDigest: ledger.binding.issuanceDigest
        ) else {
            throw LLDBLogicalBreakpointTransactionCodecError.contradictoryReceipt
        }
        return location
    }

    private func preIdentity(_ location: DebuggerOwnedBackendBreakpointLocation) -> Data {
        guard let wire = prepared.wireBindings.first(where: { $0.binding.id == location.bindingID })
        else { return Data() }
        return Phase2ProductionJSONValue.array([
            .number(String(location.backendBreakpointID)),
            .number(String(location.backendLocationID)),
            .string(address(location.runtimeAddress)), .bool(true), .bool(false), .bool(false),
            .string(hex(wire.expectedOwnedNameSHA256)),
        ]).canonicalJSONBytes()
    }

    private func requiredPositive(_ value: Phase2ProductionJSONValue) throws -> UInt64 {
        try requiredPositive(value: value)
    }

    private func requiredPositive(value: Phase2ProductionJSONValue?) throws -> UInt64 {
        guard let result = uint(value), result > 0 else {
            throw LLDBLogicalBreakpointTransactionCodecError.contradictoryReceipt
        }
        return result
    }
}

private func contains(_ address: UInt64, in start: UInt64, count: UInt64) -> Bool {
    address >= start && address - start < count
}

private func base64(_ value: String) -> Phase2ProductionJSONValue {
    .string(Data(value.utf8).base64EncodedString())
}

private func address(_ value: UInt64) -> String { String(format: "%016llx", value) }

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func uint(_ value: Phase2ProductionJSONValue?) -> UInt64? {
    guard let text = value.flatMap({
        if case .number(let value) = $0 { value } else { nil }
    }), !text.isEmpty, text == "0" || !text.hasPrefix("0") else { return nil }
    return UInt64(text)
}

private func fixedAddress(_ value: Phase2ProductionJSONValue?) -> UInt64? {
    guard let text = value?.stringValue,
          text.utf8.count == 16,
          text.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
        return nil
    }
    return UInt64(text, radix: 16)
}

private func fixedDigest(_ value: Phase2ProductionJSONValue?) -> Data? {
    guard let text = value?.stringValue,
          text.utf8.count == 64,
          text.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
        return nil
    }
    var bytes = Data(capacity: 32)
    var index = text.startIndex
    for _ in 0..<32 {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return bytes
}

private func ownedName(
    generation: UInt64,
    ownerTagDigest: DebuggerBreakpointDigest,
    wireID: String,
    policyDigest: DebuggerBreakpointDigest,
    issuanceDigest: DebuggerBreakpointDigest
) -> String {
    let authority = Data(
        (wireID + hex(policyDigest.bytes) + hex(issuanceDigest.bytes)).utf8
    )
    return "macscope_logical_g\(generation)_\(hex(ownerTagDigest.bytes))_"
        + hex(Data(SHA256.hash(data: authority)))
}
