import Foundation

enum DebuggerRuntimeAddressTranslationFailure: Hashable, Sendable {
    case projectionUnavailable
    case projectionKeyMismatch
    case invalidProjection
    case unmapped
}

struct DebuggerResolvedStaticAddress: Hashable, Sendable {
    let projectionKey: DebuggerRuntimeMappingProjectionKey
    let moduleInstanceID: DebuggerRuntimeModuleInstanceID
    let workspaceCoordinate: DebuggerWorkspaceArtifactCoordinate
    let runtimeAddress: UInt64
    let imageAddress: ImageAddress
}

struct DebuggerResolvedRuntimeAddress: Hashable, Sendable {
    let projectionKey: DebuggerRuntimeMappingProjectionKey
    let moduleInstanceID: DebuggerRuntimeModuleInstanceID
    let workspaceCoordinate: DebuggerWorkspaceArtifactCoordinate
    let imageAddress: ImageAddress
    let runtimeAddress: UInt64
}

enum DebuggerRuntimeToStaticTranslation: Hashable, Sendable {
    case resolved(DebuggerResolvedStaticAddress)
    case unresolved(DebuggerRuntimeAddressTranslationFailure)
    case ambiguous([DebuggerResolvedStaticAddress])
}

enum DebuggerStaticToRuntimeTranslation: Hashable, Sendable {
    case resolved([DebuggerResolvedRuntimeAddress])
    case unresolved(DebuggerRuntimeAddressTranslationFailure)
}

enum DebuggerScalarRuntimeAddressTranslation: Hashable, Sendable {
    case resolved(DebuggerResolvedRuntimeAddress)
    case unresolved(DebuggerRuntimeAddressTranslationFailure)
    case ambiguous([DebuggerResolvedRuntimeAddress])
}

enum DebuggerRuntimeAddressDisplacement: Hashable, Sendable {
    case unchanged
    case runtimeAboveStatic(UInt64)
    case runtimeBelowStatic(UInt64)
}

enum DebuggerRuntimeAddressDisplacementSummary: Hashable, Sendable {
    case unavailable
    case uniform(DebuggerRuntimeAddressDisplacement)
    case nonuniform
}

/// Pure, fail-closed address translation over one immutable, correlation-complete projection.
/// Every query takes the caller's current expected key so stale stop, process, inventory, authority,
/// or workspace-catalog evidence cannot be reused after an unload, remap, or owner replacement.
enum DebuggerRuntimeAddressTranslator {
    static func staticAddress(
        forRuntimeAddress runtimeAddress: UInt64,
        in projection: DebuggerRuntimeMappingProjection,
        requiring expectedKey: DebuggerRuntimeMappingProjectionKey
    ) -> DebuggerRuntimeToStaticTranslation {
        guard projection.key == expectedKey else {
            return .unresolved(.projectionKeyMismatch)
        }
        guard isValid(projection) else {
            return .unresolved(.invalidProjection)
        }

        var distinct = Set<DebuggerResolvedStaticAddress>()
        for module in projection.modules {
            for range in module.mappedRanges where contains(
                runtimeAddress,
                start: range.runtimeStart,
                byteCount: range.byteCount
            ) {
                let offset = runtimeAddress - range.runtimeStart
                guard let staticAddress = checkedAdd(range.staticStart, offset),
                      contains(staticAddress, start: range.staticStart, byteCount: range.byteCount),
                      let reversedRuntime = checkedAdd(
                          range.runtimeStart,
                          staticAddress - range.staticStart
                      ),
                      reversedRuntime == runtimeAddress else {
                    return .unresolved(.invalidProjection)
                }
                distinct.insert(DebuggerResolvedStaticAddress(
                    projectionKey: projection.key,
                    moduleInstanceID: module.instanceID,
                    workspaceCoordinate: module.coordinate,
                    runtimeAddress: runtimeAddress,
                    imageAddress: ImageAddress(
                        slot: module.coordinate.slot,
                        address: staticAddress
                    )
                ))
            }
        }

        let ordered = distinct.sorted(by: staticResultPrecedes)
        switch ordered.count {
        case 0: return .unresolved(.unmapped)
        case 1: return .resolved(ordered[0])
        default: return .ambiguous(ordered)
        }
    }

    static func runtimeAddresses(
        forStaticAddress imageAddress: ImageAddress,
        coordinate: DebuggerWorkspaceArtifactCoordinate,
        in projection: DebuggerRuntimeMappingProjection,
        requiring expectedKey: DebuggerRuntimeMappingProjectionKey
    ) -> DebuggerStaticToRuntimeTranslation {
        guard projection.key == expectedKey else {
            return .unresolved(.projectionKeyMismatch)
        }
        guard isValid(projection) else {
            return .unresolved(.invalidProjection)
        }
        guard imageAddress.slot == coordinate.slot else {
            return .unresolved(.unmapped)
        }

        var distinct = Set<DebuggerResolvedRuntimeAddress>()
        for module in projection.modules where module.coordinate == coordinate {
            for range in module.mappedRanges where contains(
                imageAddress.address,
                start: range.staticStart,
                byteCount: range.byteCount
            ) {
                let offset = imageAddress.address - range.staticStart
                guard let runtimeAddress = checkedAdd(range.runtimeStart, offset),
                      contains(runtimeAddress, start: range.runtimeStart, byteCount: range.byteCount),
                      let reversedStatic = checkedAdd(
                          range.staticStart,
                          runtimeAddress - range.runtimeStart
                      ),
                      reversedStatic == imageAddress.address else {
                    return .unresolved(.invalidProjection)
                }
                distinct.insert(DebuggerResolvedRuntimeAddress(
                    projectionKey: projection.key,
                    moduleInstanceID: module.instanceID,
                    workspaceCoordinate: module.coordinate,
                    imageAddress: imageAddress,
                    runtimeAddress: runtimeAddress
                ))
            }
        }

        let ordered = distinct.sorted(by: runtimeResultPrecedes)
        return ordered.isEmpty ? .unresolved(.unmapped) : .resolved(ordered)
    }

    static func scalarRuntimeAddress(
        forStaticAddress imageAddress: ImageAddress,
        coordinate: DebuggerWorkspaceArtifactCoordinate,
        in projection: DebuggerRuntimeMappingProjection,
        requiring expectedKey: DebuggerRuntimeMappingProjectionKey
    ) -> DebuggerScalarRuntimeAddressTranslation {
        switch runtimeAddresses(
            forStaticAddress: imageAddress,
            coordinate: coordinate,
            in: projection,
            requiring: expectedKey
        ) {
        case .unresolved(let failure):
            return .unresolved(failure)
        case .resolved(let results):
            if results.count == 1 {
                return .resolved(results[0])
            }
            return .ambiguous(results)
        }
    }

    static func displacementSummary(
        for moduleInstanceID: DebuggerRuntimeModuleInstanceID,
        in projection: DebuggerRuntimeMappingProjection,
        requiring expectedKey: DebuggerRuntimeMappingProjectionKey
    ) -> DebuggerRuntimeAddressDisplacementSummary {
        guard projection.key == expectedKey,
              isValid(projection) else {
            return .unavailable
        }
        let matchingModules = projection.modules.filter {
            $0.instanceID == moduleInstanceID
        }
        guard matchingModules.count == 1 else {
            return .unavailable
        }
        let module = matchingModules[0]
        let displacements = Set(module.mappedRanges.map { range in
            displacement(staticStart: range.staticStart, runtimeStart: range.runtimeStart)
        })
        guard displacements.count == 1 else {
            return displacements.isEmpty ? .unavailable : .nonuniform
        }
        return .uniform(Array(displacements)[0])
    }

    private static func isValid(_ projection: DebuggerRuntimeMappingProjection) -> Bool {
        guard projection.key.observedPID > 0 else { return false }
        var instanceIDs = Set<DebuggerRuntimeModuleInstanceID>()
        for module in projection.modules {
            guard instanceIDs.insert(module.instanceID).inserted,
                  module.instanceID.processID == projection.key.observedPID,
                  module.instanceID.stop == projection.key.stopCoordinate,
                  module.instanceID.inventoryRevision == projection.key.inventoryRevision,
                  module.coordinate.slot.rawValue >= 0,
                  !module.mappedRanges.isEmpty else {
                return false
            }
            for range in module.mappedRanges {
                guard range.moduleInstanceID == module.instanceID,
                      !range.segmentName.isEmpty,
                      range.segmentName.utf8.count <= 16,
                      range.permissions <= 7,
                      hasRepresentableLastByte(
                          start: range.staticStart,
                          byteCount: range.byteCount
                      ),
                      hasRepresentableLastByte(
                          start: range.runtimeStart,
                          byteCount: range.byteCount
                      ) else {
                    return false
                }
            }
        }
        return true
    }

    private static func contains(
        _ address: UInt64,
        start: UInt64,
        byteCount: UInt64
    ) -> Bool {
        guard byteCount > 0, address >= start else { return false }
        return address - start < byteCount
    }

    private static func hasRepresentableLastByte(
        start: UInt64,
        byteCount: UInt64
    ) -> Bool {
        guard byteCount > 0 else { return false }
        let lastOffset = byteCount - 1
        return !start.addingReportingOverflow(lastOffset).overflow
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func displacement(
        staticStart: UInt64,
        runtimeStart: UInt64
    ) -> DebuggerRuntimeAddressDisplacement {
        if runtimeStart == staticStart { return .unchanged }
        if runtimeStart > staticStart {
            return .runtimeAboveStatic(runtimeStart - staticStart)
        }
        return .runtimeBelowStatic(staticStart - runtimeStart)
    }

    private static func staticResultPrecedes(
        _ lhs: DebuggerResolvedStaticAddress,
        _ rhs: DebuggerResolvedStaticAddress
    ) -> Bool {
        if lhs.moduleInstanceID.ordinal != rhs.moduleInstanceID.ordinal {
            return lhs.moduleInstanceID.ordinal < rhs.moduleInstanceID.ordinal
        }
        if lhs.imageAddress.address != rhs.imageAddress.address {
            return lhs.imageAddress.address < rhs.imageAddress.address
        }
        if lhs.imageAddress.slot != rhs.imageAddress.slot {
            return lhs.imageAddress.slot < rhs.imageAddress.slot
        }
        return lhs.workspaceCoordinate.binaryID.uuidString
            < rhs.workspaceCoordinate.binaryID.uuidString
    }

    private static func runtimeResultPrecedes(
        _ lhs: DebuggerResolvedRuntimeAddress,
        _ rhs: DebuggerResolvedRuntimeAddress
    ) -> Bool {
        if lhs.moduleInstanceID.ordinal != rhs.moduleInstanceID.ordinal {
            return lhs.moduleInstanceID.ordinal < rhs.moduleInstanceID.ordinal
        }
        if lhs.runtimeAddress != rhs.runtimeAddress {
            return lhs.runtimeAddress < rhs.runtimeAddress
        }
        return lhs.workspaceCoordinate.binaryID.uuidString
            < rhs.workspaceCoordinate.binaryID.uuidString
    }
}

// MARK: - Static-to-debugger evidence trail

enum DebuggerSecurityEvidenceLabel: String, Codable, Hashable, Sendable {
    case staticInference = "static-inference"
    case observedRuntimeBehavior = "observed-runtime-behavior"
    case unresolvedQuestion = "unresolved-question"
}

enum DebuggerSecurityRuntimeObservationSource: String, Codable, Hashable, Sendable {
    case selectedStoppedFrame = "selected-stopped-frame"
}

enum DebuggerSecurityStaticObservationSource: String, Codable, Hashable, Sendable {
    case securityTriage = "security-triage"
}

enum DebuggerSecurityAddressDisplacement: Codable, Hashable, Sendable {
    case unchanged
    case runtimeAboveStatic(UInt64)
    case runtimeBelowStatic(UInt64)
}

enum DebuggerSecurityModuleSlideSummary: Codable, Hashable, Sendable {
    case unchanged
    case runtimeAboveStatic(UInt64)
    case runtimeBelowStatic(UInt64)
    case nonuniform
}

struct DebuggerSecurityEvidenceImageIdentity: Codable, Hashable, Sendable {
    let workspaceBinaryID: UUID
    let slot: ImageSlot
    let artifactIdentity: MachOSliceArtifactIdentity
    let ownerRevision: UInt64

    init(_ coordinate: DebuggerWorkspaceArtifactCoordinate) {
        workspaceBinaryID = coordinate.binaryID
        slot = coordinate.slot
        artifactIdentity = coordinate.artifactIdentity
        ownerRevision = coordinate.ownerRevision.rawValue
    }

    func matches(_ coordinate: DebuggerWorkspaceArtifactCoordinate) -> Bool {
        self == Self(coordinate)
    }
}

struct DebuggerSecurityEvidenceProcessIdentity: Codable, Hashable, Sendable {
    let sessionEpoch: UUID
    let lifecycleRevision: UInt64
    let stopRevision: UInt64
    let observedProcessID: Int32
    let authorityRevision: UInt64
    let inventoryRevision: UInt64
    let workspaceCatalogRevision: UInt64

    init(_ key: DebuggerRuntimeMappingProjectionKey) {
        sessionEpoch = key.stopCoordinate.session.epoch.rawValue
        lifecycleRevision = key.stopCoordinate.session.lifecycleRevision.rawValue
        stopRevision = key.stopCoordinate.stopRevision.rawValue
        observedProcessID = key.observedPID
        authorityRevision = key.authorityRevision.rawValue
        inventoryRevision = key.inventoryRevision.rawValue
        workspaceCatalogRevision = key.workspaceCatalogRevision.rawValue
    }

    func matches(_ key: DebuggerRuntimeMappingProjectionKey) -> Bool {
        self == Self(key)
    }
}

struct DebuggerSecurityStaticEvidence: Codable, Equatable, Sendable {
    let label: DebuggerSecurityEvidenceLabel
    let recordedAtUnixNanoseconds: UInt64
    let rule: SecurityTriageRule
    let confidence: SecurityTriageConfidence
    let cwe: [String]
    let reason: String
    let functionName: String
    let functionStartAddress: UInt64
    let callSiteAddress: UInt64
    let image: DebuggerSecurityEvidenceImageIdentity
    let source: DebuggerSecurityStaticObservationSource
}

struct DebuggerSecurityRuntimeEvidence: Codable, Equatable, Sendable {
    let label: DebuggerSecurityEvidenceLabel
    let source: DebuggerSecurityRuntimeObservationSource
    let observedAtUnixNanoseconds: UInt64
    let process: DebuggerSecurityEvidenceProcessIdentity
    let image: DebuggerSecurityEvidenceImageIdentity
    let moduleInstanceOrdinal: UInt32
    let frameIndex: Int
    let frameFunctionName: String
    let frameModuleName: String?
    let frameSourceLocation: String?
    let runtimeAddress: UInt64
    let staticAddress: UInt64
    let addressDisplacement: DebuggerSecurityAddressDisplacement
    let moduleSlide: DebuggerSecurityModuleSlideSummary
}

struct DebuggerSecurityUnresolvedQuestion: Codable, Equatable, Sendable {
    let label: DebuggerSecurityEvidenceLabel
    let question: String

    init?(_ question: String) {
        let normalized = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 4_096,
              normalized.unicodeScalars.allSatisfy({
                  $0.properties.generalCategory != .control
                      || $0.value == 0x0A
                      || $0.value == 0x09
              }) else {
            return nil
        }
        label = .unresolvedQuestion
        self.question = normalized
    }
}

struct DebuggerSecurityEvidenceTrail: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let staticEvidence: DebuggerSecurityStaticEvidence
    let runtimeEvidence: DebuggerSecurityRuntimeEvidence?
    let unresolvedQuestions: [DebuggerSecurityUnresolvedQuestion]

    init(
        staticEvidence: DebuggerSecurityStaticEvidence,
        runtimeEvidence: DebuggerSecurityRuntimeEvidence? = nil,
        unresolvedQuestions: [DebuggerSecurityUnresolvedQuestion] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.staticEvidence = staticEvidence
        self.runtimeEvidence = runtimeEvidence
        self.unresolvedQuestions = unresolvedQuestions
    }
}

enum DebuggerSecurityEvidenceFailure: Error, Equatable, Sendable {
    case findingNotInFunctionReport
    case callSiteNotInFinding
    case invalidFunctionIdentity
    case projectionKeyMismatch
    case invalidProjection
    case runtimeAddressUnmapped
    case runtimeAddressAmbiguous
    case imageIdentityMismatch
    case staticAddressMismatch
    case reverseTranslationMismatch
    case processIdentityMismatch
    case runtimeObservationMissing
    case runtimeObservationAlreadyPresent
    case unsupportedSchemaVersion(Int)
    case malformedExport
}

enum DebuggerSecurityEvidenceTrailBuilder {
    static func staticTrail(
        function: SecurityTriageFunctionReport,
        finding: SecurityTriageFinding,
        callSiteAddress: UInt64,
        coordinate: DebuggerWorkspaceArtifactCoordinate,
        recordedAtUnixNanoseconds: UInt64,
        unresolvedQuestions: [DebuggerSecurityUnresolvedQuestion] = []
    ) -> Result<DebuggerSecurityEvidenceTrail, DebuggerSecurityEvidenceFailure> {
        guard function.findings.contains(finding) else {
            return .failure(.findingNotInFunctionReport)
        }
        guard finding.evidenceAddresses.contains(callSiteAddress) else {
            return .failure(.callSiteNotInFinding)
        }
        guard !function.functionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidFunctionIdentity)
        }
        return .success(DebuggerSecurityEvidenceTrail(
            staticEvidence: DebuggerSecurityStaticEvidence(
                label: .staticInference,
                recordedAtUnixNanoseconds: recordedAtUnixNanoseconds,
                rule: finding.rule,
                confidence: finding.confidence,
                cwe: finding.cwe,
                reason: finding.reason,
                functionName: function.functionName,
                functionStartAddress: function.functionStartAddress,
                callSiteAddress: callSiteAddress,
                image: DebuggerSecurityEvidenceImageIdentity(coordinate),
                source: .securityTriage
            ),
            unresolvedQuestions: unresolvedQuestions
        ))
    }

    static func observingSelectedStoppedFrame(
        _ frame: DebuggerStoppedFrame,
        at observedAtUnixNanoseconds: UInt64,
        in projection: DebuggerRuntimeMappingProjection,
        requiring expectedKey: DebuggerRuntimeMappingProjectionKey,
        appendingTo trail: DebuggerSecurityEvidenceTrail
    ) -> Result<DebuggerSecurityEvidenceTrail, DebuggerSecurityEvidenceFailure> {
        guard projection.key == expectedKey else {
            return .failure(.projectionKeyMismatch)
        }
        guard trail.runtimeEvidence == nil else {
            return .failure(.runtimeObservationAlreadyPresent)
        }

        let resolved: DebuggerResolvedStaticAddress
        switch DebuggerRuntimeAddressTranslator.staticAddress(
            forRuntimeAddress: frame.address,
            in: projection,
            requiring: expectedKey
        ) {
        case .resolved(let result):
            resolved = result
        case .ambiguous:
            return .failure(.runtimeAddressAmbiguous)
        case .unresolved(.projectionKeyMismatch):
            return .failure(.projectionKeyMismatch)
        case .unresolved(.invalidProjection):
            return .failure(.invalidProjection)
        case .unresolved(.projectionUnavailable), .unresolved(.unmapped):
            return .failure(.runtimeAddressUnmapped)
        }

        guard trail.staticEvidence.image.matches(resolved.workspaceCoordinate) else {
            return .failure(.imageIdentityMismatch)
        }
        guard trail.staticEvidence.callSiteAddress == resolved.imageAddress.address else {
            return .failure(.staticAddressMismatch)
        }
        guard reverseTranslationContains(resolved, in: projection, requiring: expectedKey) else {
            return .failure(.reverseTranslationMismatch)
        }
        guard let moduleSlide = moduleSlide(
            for: resolved.moduleInstanceID,
            in: projection,
            requiring: expectedKey
        ) else {
            return .failure(.invalidProjection)
        }

        let runtimeEvidence = DebuggerSecurityRuntimeEvidence(
            label: .observedRuntimeBehavior,
            source: .selectedStoppedFrame,
            observedAtUnixNanoseconds: observedAtUnixNanoseconds,
            process: DebuggerSecurityEvidenceProcessIdentity(expectedKey),
            image: DebuggerSecurityEvidenceImageIdentity(resolved.workspaceCoordinate),
            moduleInstanceOrdinal: resolved.moduleInstanceID.ordinal,
            frameIndex: frame.identifier,
            frameFunctionName: frame.functionName,
            frameModuleName: frame.moduleName,
            frameSourceLocation: frame.sourceLocation,
            runtimeAddress: resolved.runtimeAddress,
            staticAddress: resolved.imageAddress.address,
            addressDisplacement: displacement(
                staticAddress: resolved.imageAddress.address,
                runtimeAddress: resolved.runtimeAddress
            ),
            moduleSlide: moduleSlide
        )
        return .success(DebuggerSecurityEvidenceTrail(
            staticEvidence: trail.staticEvidence,
            runtimeEvidence: runtimeEvidence,
            unresolvedQuestions: trail.unresolvedQuestions
        ))
    }

    private static func reverseTranslationContains(
        _ resolved: DebuggerResolvedStaticAddress,
        in projection: DebuggerRuntimeMappingProjection,
        requiring expectedKey: DebuggerRuntimeMappingProjectionKey
    ) -> Bool {
        switch DebuggerRuntimeAddressTranslator.runtimeAddresses(
            forStaticAddress: resolved.imageAddress,
            coordinate: resolved.workspaceCoordinate,
            in: projection,
            requiring: expectedKey
        ) {
        case .resolved(let results):
            return results.contains {
                $0.moduleInstanceID == resolved.moduleInstanceID
                    && $0.runtimeAddress == resolved.runtimeAddress
                    && $0.workspaceCoordinate == resolved.workspaceCoordinate
            }
        case .unresolved:
            return false
        }
    }

    private static func displacement(
        staticAddress: UInt64,
        runtimeAddress: UInt64
    ) -> DebuggerSecurityAddressDisplacement {
        if staticAddress == runtimeAddress { return .unchanged }
        if runtimeAddress > staticAddress {
            return .runtimeAboveStatic(runtimeAddress - staticAddress)
        }
        return .runtimeBelowStatic(staticAddress - runtimeAddress)
    }

    private static func moduleSlide(
        for instanceID: DebuggerRuntimeModuleInstanceID,
        in projection: DebuggerRuntimeMappingProjection,
        requiring expectedKey: DebuggerRuntimeMappingProjectionKey
    ) -> DebuggerSecurityModuleSlideSummary? {
        switch DebuggerRuntimeAddressTranslator.displacementSummary(
            for: instanceID,
            in: projection,
            requiring: expectedKey
        ) {
        case .unavailable:
            return nil
        case .nonuniform:
            return .nonuniform
        case .uniform(.unchanged):
            return .unchanged
        case .uniform(.runtimeAboveStatic(let magnitude)):
            return .runtimeAboveStatic(magnitude)
        case .uniform(.runtimeBelowStatic(let magnitude)):
            return .runtimeBelowStatic(magnitude)
        }
    }
}

enum DebuggerSecurityEvidenceNavigator {
    static func staticTarget(
        for trail: DebuggerSecurityEvidenceTrail,
        requiring coordinate: DebuggerWorkspaceArtifactCoordinate
    ) -> Result<ImageAddress, DebuggerSecurityEvidenceFailure> {
        guard trail.staticEvidence.image.matches(coordinate) else {
            return .failure(.imageIdentityMismatch)
        }
        return .success(ImageAddress(
            slot: coordinate.slot,
            address: trail.staticEvidence.callSiteAddress
        ))
    }

    static func currentRuntimeTarget(
        for trail: DebuggerSecurityEvidenceTrail,
        in projection: DebuggerRuntimeMappingProjection,
        requiring expectedKey: DebuggerRuntimeMappingProjectionKey
    ) -> Result<UInt64, DebuggerSecurityEvidenceFailure> {
        guard let runtime = trail.runtimeEvidence else {
            return .failure(.runtimeObservationMissing)
        }
        guard runtime.process.matches(expectedKey), projection.key == expectedKey else {
            return .failure(.processIdentityMismatch)
        }
        guard let module = projection.modules.first(where: {
            $0.instanceID.ordinal == runtime.moduleInstanceOrdinal
                && runtime.image.matches($0.coordinate)
        }) else {
            return .failure(.imageIdentityMismatch)
        }
        switch DebuggerRuntimeAddressTranslator.runtimeAddresses(
            forStaticAddress: ImageAddress(
                slot: runtime.image.slot,
                address: runtime.staticAddress
            ),
            coordinate: module.coordinate,
            in: projection,
            requiring: expectedKey
        ) {
        case .resolved(let results):
            guard results.contains(where: {
                $0.moduleInstanceID == module.instanceID
                    && $0.runtimeAddress == runtime.runtimeAddress
            }) else {
                return .failure(.reverseTranslationMismatch)
            }
            return .success(runtime.runtimeAddress)
        case .unresolved(.projectionKeyMismatch):
            return .failure(.projectionKeyMismatch)
        case .unresolved(.invalidProjection):
            return .failure(.invalidProjection)
        case .unresolved(.projectionUnavailable), .unresolved(.unmapped):
            return .failure(.runtimeAddressUnmapped)
        }
    }
}

enum DebuggerSecurityEvidenceExport {
    static func encode(_ trail: DebuggerSecurityEvidenceTrail) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(trail)
    }

    static func decode(_ data: Data) -> Result<DebuggerSecurityEvidenceTrail, DebuggerSecurityEvidenceFailure> {
        guard let trail = try? JSONDecoder().decode(DebuggerSecurityEvidenceTrail.self, from: data) else {
            return .failure(.malformedExport)
        }
        guard trail.schemaVersion == DebuggerSecurityEvidenceTrail.currentSchemaVersion else {
            return .failure(.unsupportedSchemaVersion(trail.schemaVersion))
        }
        guard trail.staticEvidence.label == .staticInference,
              trail.staticEvidence.source == .securityTriage,
              trail.unresolvedQuestions.allSatisfy({ $0.label == .unresolvedQuestion }) else {
            return .failure(.malformedExport)
        }
        if let runtime = trail.runtimeEvidence {
            guard runtime.label == .observedRuntimeBehavior,
                  runtime.process.observedProcessID > 0,
                  runtime.image == trail.staticEvidence.image,
                  runtime.staticAddress == trail.staticEvidence.callSiteAddress else {
                return .failure(.malformedExport)
            }
        }
        return .success(trail)
    }
}
