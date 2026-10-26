import Foundation

/// A closed set of principals that may participate in Phase 2 workflows.
///
/// Participation is not authorization. Only ``app`` may authorize an R1 read or
/// accept its evidence.
enum Phase2Principal: Codable, Hashable, Sendable {
    case human
    case app
    case analysisWorker
    case aiWorker
    case model
    case mcp
    case cli
    case appleEvents
    case plugin(identity: String)
    case externalJobTool(identity: String)
    case debuggerAdapter
    case debugTarget
    case reportConsumer

    var validationIssues: [Phase2ReadValidationIssue] {
        switch self {
        case let .plugin(identity) where identity.isEmpty:
            return [.emptyPrincipalIdentity(principal: "plugin")]
        case let .externalJobTool(identity) where identity.isEmpty:
            return [.emptyPrincipalIdentity(principal: "external-job-tool")]
        default:
            return []
        }
    }
}

/// Explicit effect classes from the Phase 2 authority contract.
enum Phase2EffectClass: String, Codable, CaseIterable, Hashable, Sendable {
    case a0 = "A0"
    case a1 = "A1"
    case a2 = "A2"
    case a3 = "A3"
    case a4 = "A4"
    case a5 = "A5"
    case a6 = "A6"
    case a7 = "A7"
    case a8 = "A8"
    case a9 = "A9"

    var isPermittedInR1ReadRegistry: Bool {
        self == .a1 || self == .a2
    }
}

/// An operation identifier supplied to the app-owned R1 registry.
///
/// This is a raw-value wrapper rather than an enum so unknown untrusted input can
/// reach the registry and be rejected without being silently downgraded.
struct Phase2ReadOperationID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let workspaceSummary = Self(rawValue: "workspace.summary")
    static let selectionExplain = Self(rawValue: "selection.explain")
    static let functionReview = Self(rawValue: "function.review")
    static let functionCallSites = Self(rawValue: "function.callsites")
    /// Existing facet vocabulary; no new analysis or persistence authority.
    static let functionCallSiteFacets: [Phase2ReadFacet] = [
        .inputBytesAndSlice, .functionBoundaries, .xrefsAndCFG,
    ]
    static let applicationGraphSummary = Self(rawValue: "application.graph.summary")
    static let decompilerNativeResult = Self(rawValue: "decompiler.native.result")
    static let decompilerMacScopeResult = Self(rawValue: "decompiler.macscope.result")
    static let decompilerCompare = Self(rawValue: "decompiler.compare")
    static let reaResultsList = Self(rawValue: "rea.results.list")
    static let reaResultsGet = Self(rawValue: "rea.results.get")
    static let debuggerSummary = Self(rawValue: Phase2DebuggerReadOperationID.summary.rawValue)
    static let debuggerFrames = Self(rawValue: Phase2DebuggerReadOperationID.frames.rawValue)
    static let debuggerRegisters = Self(rawValue: Phase2DebuggerReadOperationID.registers.rawValue)
    static let debuggerVariables = Self(rawValue: Phase2DebuggerReadOperationID.variables.rawValue)
    static let debuggerMemory = Self(rawValue: Phase2DebuggerReadOperationID.memory.rawValue)

    static let allKnown: Set<Self> = [
        .reaResultsList,
        .reaResultsGet,
        .workspaceSummary,
        .selectionExplain,
        .functionReview,
        .functionCallSites,
        .applicationGraphSummary,
        .decompilerNativeResult,
        .decompilerMacScopeResult,
        .decompilerCompare,
    ]

    /// Provider-visible handle vocabulary. Debugger operations intentionally remain outside the
    /// frozen workspace `TypedReadRegistry`; they have their own stopped-coordinate authority.
    // Call sites are app-scheduled supplemental evidence, not a model tool handle.
    static let allProviderVisible: Set<Self> = allKnown.subtracting([.functionCallSites]).union([
        .debuggerSummary,
        .debuggerFrames,
        .debuggerRegisters,
        .debuggerVariables,
        .debuggerMemory,
    ])
}

/// Schema version of the app-owned R1 registry.
struct Phase2ReadRegistryVersion: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let v1 = Self(rawValue: 1)
}

/// Version of one operation's typed request and result contract.
struct Phase2ReadOperationVersion: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let v1 = Self(rawValue: 1)
}

/// The authority-bearing metadata for one registered operation.
struct Phase2ReadOperationDescriptor: Codable, Hashable, Sendable {
    let registryVersion: Phase2ReadRegistryVersion
    let id: Phase2ReadOperationID
    let operationVersion: Phase2ReadOperationVersion
    let effects: Set<Phase2EffectClass>
    let executorPrincipal: Phase2Principal

    init(
        registryVersion: Phase2ReadRegistryVersion,
        id: Phase2ReadOperationID,
        operationVersion: Phase2ReadOperationVersion,
        effects: Set<Phase2EffectClass>,
        executorPrincipal: Phase2Principal = .app
    ) {
        self.registryVersion = registryVersion
        self.id = id
        self.operationVersion = operationVersion
        self.effects = effects
        self.executorPrincipal = executorPrincipal
    }

    private enum CodingKeys: String, CodingKey {
        case registryVersion
        case id
        case operationVersion
        case effects
        case executorPrincipal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        registryVersion = try container.decode(
            Phase2ReadRegistryVersion.self,
            forKey: .registryVersion
        )
        id = try container.decode(Phase2ReadOperationID.self, forKey: .id)
        operationVersion = try container.decode(
            Phase2ReadOperationVersion.self,
            forKey: .operationVersion
        )
        let encodedEffects = try container.decode(
            [Phase2EffectClass].self,
            forKey: .effects
        )
        effects = Set(encodedEffects)
        guard effects.count == encodedEffects.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .effects,
                in: container,
                debugDescription: "Duplicate effect classes are not canonical"
            )
        }
        executorPrincipal = try container.decode(
            Phase2Principal.self,
            forKey: .executorPrincipal
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(registryVersion, forKey: .registryVersion)
        try container.encode(id, forKey: .id)
        try container.encode(operationVersion, forKey: .operationVersion)
        try container.encode(
            effects.sorted { $0.rawValue < $1.rawValue },
            forKey: .effects
        )
        try container.encode(executorPrincipal, forKey: .executorPrincipal)
    }

    var validationIssues: [Phase2ReadValidationIssue] {
        var issues: [Phase2ReadValidationIssue] = []

        if registryVersion != .v1 {
            issues.append(.unsupportedRegistryVersion(registryVersion.rawValue))
        }
        if !Phase2ReadOperationID.allKnown.contains(id) {
            issues.append(.unsupportedOperation(id.rawValue))
        }
        if operationVersion != .v1 {
            issues.append(.unsupportedOperationVersion(operationVersion.rawValue))
        }

        let expectedEffects: Set<Phase2EffectClass>?
        switch id {
        case .reaResultsList, .reaResultsGet, .workspaceSummary, .selectionExplain, .functionCallSites, .applicationGraphSummary,
             .decompilerNativeResult, .decompilerMacScopeResult, .decompilerCompare:
            expectedEffects = [.a1]
        case .functionReview:
            expectedEffects = [.a1, .a2]
        default:
            expectedEffects = nil
        }

        if let expectedEffects, effects != expectedEffects {
            issues.append(
                .effectMismatch(
                    operation: id,
                    expected: expectedEffects,
                    actual: effects
                )
            )
        }
        for effect in effects.sorted(by: { $0.rawValue < $1.rawValue })
            where !effect.isPermittedInR1ReadRegistry
        {
            issues.append(.forbiddenEffect(effect))
        }
        if executorPrincipal != .app {
            issues.append(.executorMismatch(
                operation: id,
                expected: .app,
                actual: executorPrincipal
            ))
        }

        return issues
    }

    var isValid: Bool {
        validationIssues.isEmpty
    }
}

enum Phase2ReadLimitField: String, Codable, CaseIterable, Hashable, Sendable {
    case encodedRequestBytes
    case encodedResultBytes
    case structuralNesting
    case objectMembers
    case arrayItems
    case stringBytes
    case pageItems
}

/// App-enforced inclusive limits for one typed read.
struct Phase2ReadLimits: Codable, Hashable, Sendable {
    let encodedRequestBytes: Int
    let encodedResultBytes: Int
    let structuralNesting: Int
    let objectMembers: Int
    let arrayItems: Int
    let stringBytes: Int
    let pageItems: Int

    init(
        encodedRequestBytes: Int,
        encodedResultBytes: Int,
        structuralNesting: Int,
        objectMembers: Int,
        arrayItems: Int,
        stringBytes: Int,
        pageItems: Int
    ) {
        self.encodedRequestBytes = encodedRequestBytes
        self.encodedResultBytes = encodedResultBytes
        self.structuralNesting = structuralNesting
        self.objectMembers = objectMembers
        self.arrayItems = arrayItems
        self.stringBytes = stringBytes
        self.pageItems = pageItems
    }

    static let maximum = Self(
        encodedRequestBytes: 65_536,
        encodedResultBytes: 1_048_576,
        structuralNesting: 12,
        objectMembers: 64,
        arrayItems: 1_024,
        stringBytes: 65_536,
        pageItems: 256
    )

    var validationIssues: [Phase2ReadValidationIssue] {
        let values: [(Phase2ReadLimitField, Int, Int)] = [
            (.encodedRequestBytes, encodedRequestBytes, Self.maximum.encodedRequestBytes),
            (.encodedResultBytes, encodedResultBytes, Self.maximum.encodedResultBytes),
            (.structuralNesting, structuralNesting, Self.maximum.structuralNesting),
            (.objectMembers, objectMembers, Self.maximum.objectMembers),
            (.arrayItems, arrayItems, Self.maximum.arrayItems),
            (.stringBytes, stringBytes, Self.maximum.stringBytes),
            (.pageItems, pageItems, Self.maximum.pageItems),
        ]

        return values.compactMap { field, value, maximum in
            if value <= 0 {
                return .nonPositiveLimit(field: field, value: value)
            }
            if value > maximum {
                return .limitExceedsMaximum(field: field, value: value, maximum: maximum)
            }
            return nil
        }
    }

    var isValid: Bool {
        validationIssues.isEmpty
    }
}

/// A proposed typed read. Authorization remains a separate app-only decision.
struct Phase2ReadRequest: Codable, Hashable, Sendable {
    let requestID: UUID
    let invocationID: UUID
    let sequence: UInt64
    let proposingPrincipal: Phase2Principal
    let descriptor: Phase2ReadOperationDescriptor
    let subject: Phase2ReadSubject
    let precondition: Phase2ReadPrecondition
    let limits: Phase2ReadLimits
    let reaResultRead: REAResultReadSelector?

    init(
        requestID: UUID,
        invocationID: UUID,
        sequence: UInt64,
        proposingPrincipal: Phase2Principal,
        descriptor: Phase2ReadOperationDescriptor,
        subject: Phase2ReadSubject,
        precondition: Phase2ReadPrecondition,
        limits: Phase2ReadLimits,
        reaResultRead: REAResultReadSelector? = nil
    ) {
        self.requestID = requestID
        self.invocationID = invocationID
        self.sequence = sequence
        self.proposingPrincipal = proposingPrincipal
        self.descriptor = descriptor
        self.subject = subject
        self.precondition = precondition
        self.limits = limits
        self.reaResultRead = reaResultRead
    }

    var validationIssues: [Phase2ReadValidationIssue] {
        proposingPrincipal.validationIssues
            + descriptor.validationIssues
            + subject.validationIssues(for: descriptor.id, precondition: precondition)
            + limits.validationIssues
            + (validREASelector ? [] : [.subjectMismatch(operation: descriptor.id)])
            + (validFunctionCallSiteDependencies ? [] : [.subjectMismatch(operation: descriptor.id)])
    }

    /// Require the complete image-scoped dependency set even for a manually
    /// constructed proposal; the app coordinator supplies the actual revisions.
    private var validFunctionCallSiteDependencies: Bool {
        guard descriptor.id == .functionCallSites else { return true }
        guard let image = precondition.image else { return false }
        let required = Set(Phase2ReadOperationID.functionCallSiteFacets)
        return precondition.dependencies.count == required.count
            && Set(precondition.dependencies.map(\.facet)) == required
            && precondition.dependencies.allSatisfy { $0.scope == .image(image.owner) }
    }

    private var validREASelector: Bool {
        switch descriptor.id {
        case .reaResultsList: return reaResultRead?.isValidList ?? true
        case .reaResultsGet: return reaResultRead?.isValidGet == true
        default: return reaResultRead == nil
        }
    }

    var isValid: Bool {
        validationIssues.isEmpty
    }
}

/// The complete app-owned authority granted to one exact typed-read request.
///
/// Execution must consume this value rather than reconstructing authorization from
/// an operation identifier or a Boolean approval flag.
struct Phase2ReadAuthorization: Codable, Hashable, Sendable {
    let request: Phase2ReadRequest
    let canonicalDescriptor: Phase2ReadOperationDescriptor
    let authorizingPrincipal: Phase2Principal
    let approvedLimits: Phase2ReadLimits

    init(
        request: Phase2ReadRequest,
        canonicalDescriptor: Phase2ReadOperationDescriptor,
        authorizingPrincipal: Phase2Principal,
        approvedLimits: Phase2ReadLimits
    ) {
        self.request = request
        self.canonicalDescriptor = canonicalDescriptor
        self.authorizingPrincipal = authorizingPrincipal
        self.approvedLimits = approvedLimits
    }

    var validationIssues: [Phase2ReadValidationIssue] {
        var issues = request.validationIssues
        issues.append(contentsOf: canonicalDescriptor.validationIssues)
        issues.append(contentsOf: approvedLimits.validationIssues)

        if authorizingPrincipal != .app {
            issues.append(.unauthorizedAuthorizingPrincipal(authorizingPrincipal))
        }
        if request.descriptor != canonicalDescriptor {
            issues.append(
                .canonicalDescriptorMismatch(
                    requested: request.descriptor,
                    canonical: canonicalDescriptor
                )
            )
        }

        issues.append(contentsOf: approvedLimitOverages)
        return issues
    }

    var isValid: Bool {
        validationIssues.isEmpty
    }

    private var approvedLimitOverages: [Phase2ReadValidationIssue] {
        let values: [(Phase2ReadLimitField, Int, Int)] = [
            (
                .encodedRequestBytes,
                approvedLimits.encodedRequestBytes,
                request.limits.encodedRequestBytes
            ),
            (
                .encodedResultBytes,
                approvedLimits.encodedResultBytes,
                request.limits.encodedResultBytes
            ),
            (
                .structuralNesting,
                approvedLimits.structuralNesting,
                request.limits.structuralNesting
            ),
            (.objectMembers, approvedLimits.objectMembers, request.limits.objectMembers),
            (.arrayItems, approvedLimits.arrayItems, request.limits.arrayItems),
            (.stringBytes, approvedLimits.stringBytes, request.limits.stringBytes),
            (.pageItems, approvedLimits.pageItems, request.limits.pageItems),
        ]

        return values.compactMap { field, approved, requested in
            guard approved > requested else { return nil }
            return .approvedLimitExceedsRequest(
                field: field,
                approved: approved,
                requested: requested
            )
        }
    }
}

/// The closed output of the app authorization boundary.
enum Phase2ReadAuthorizationDecision: Codable, Hashable, Sendable {
    case authorized(Phase2ReadAuthorization)
    case rejected(Phase2ReadDisposition)
}

/// An exact function identity based on an image owner and a structural range.
struct Phase2ReadFunctionRange: Codable, Hashable, Sendable {
    let image: Phase2ReadImageIdentity
    let start: UInt64
    let endExclusive: UInt64

    init(image: Phase2ReadImageIdentity, start: UInt64, endExclusive: UInt64) {
        self.image = image
        self.start = start
        self.endExclusive = endExclusive
    }

    var isValid: Bool {
        start < endExclusive
    }
}

/// The exact native subject selected by the app before a typed read is authorized.
enum Phase2ReadSubject: Codable, Hashable, Sendable {
    case workspace(Phase2ReadWorkspaceIdentity)
    case staticLocation(Phase2ReadStaticLocation)
    case functionRange(Phase2ReadFunctionRange)

    func validationIssues(
        for operation: Phase2ReadOperationID,
        precondition: Phase2ReadPrecondition
    ) -> [Phase2ReadValidationIssue] {
        let matches: Bool
        switch (operation, self) {
        case let (.workspaceSummary, .workspace(workspace)),
             let (.applicationGraphSummary, .workspace(workspace)),
             let (.reaResultsList, .workspace(workspace)),
             let (.reaResultsGet, .workspace(workspace)):
            matches = workspace == precondition.workspace
        case let (.selectionExplain, .staticLocation(location)):
            matches = location.image == precondition.image
        case let (.functionReview, .functionRange(range)),
             let (.functionCallSites, .functionRange(range)),
             let (.decompilerNativeResult, .functionRange(range)),
             let (.decompilerMacScopeResult, .functionRange(range)),
             let (.decompilerCompare, .functionRange(range)):
            matches = range.isValid && range.image == precondition.image
        default:
            matches = false
        }
        return matches ? [] : [.subjectMismatch(operation: operation)]
    }
}

/// Closed citation targets. No case permits rebinding by display name or bare address.
enum Phase2ReadCitationTarget: Codable, Hashable, Sendable {
    case workspace(Phase2ReadWorkspaceIdentity)
    case image(Phase2ReadImageIdentity)
    case staticLocation(Phase2ReadStaticLocation)
    case functionRange(Phase2ReadFunctionRange)
}

/// An owner- and dependency-qualified reference to native evidence.
struct Phase2ReadCitation: Codable, Hashable, Sendable {
    let id: UUID
    let target: Phase2ReadCitationTarget
    let dependencies: [Phase2ReadFacetDependency]

    init(
        id: UUID,
        target: Phase2ReadCitationTarget,
        dependencies: [Phase2ReadFacetDependency]
    ) {
        self.id = id
        self.target = target
        self.dependencies = dependencies
    }
}

/// One named field in a deterministic typed evidence object.
struct Phase2ReadFactField: Codable, Hashable, Sendable {
    let name: String
    let value: Phase2ReadFactValue

    init(name: String, value: Phase2ReadFactValue) {
        self.name = name
        self.value = value
    }
}

/// Inert typed fact data. It has no executable, approval, or authority-bearing case.
indirect enum Phase2ReadFactValue: Codable, Hashable, Sendable {
    case boolean(Bool)
    case signedInteger(Int64)
    case unsignedInteger(UInt64)
    case text(String)
    case staticLocation(Phase2ReadStaticLocation)
    case list([Phase2ReadFactValue])
    case object([Phase2ReadFactField])
}

enum Phase2ReadUnavailableReason: String, Codable, Hashable, Sendable {
    case unresolvedOwner
    case noSelection
    case notFound
    case ambiguous
    case unavailable
    case notImplemented
}

/// One attributable side of a contradictory current evidence set.
struct Phase2ReadConflictClaim: Codable, Hashable, Sendable {
    let claimID: UUID
    let producingPrincipal: Phase2Principal
    let value: Phase2ReadFactValue
    let citations: [Phase2ReadCitation]
    let contentDigest: String

    init(
        claimID: UUID,
        producingPrincipal: Phase2Principal,
        value: Phase2ReadFactValue,
        citations: [Phase2ReadCitation],
        contentDigest: String
    ) {
        self.claimID = claimID
        self.producingPrincipal = producingPrincipal
        self.value = value
        self.citations = citations
        self.contentDigest = contentDigest
    }
}

/// A preserved contradiction. No claim is silently promoted over another.
struct Phase2ReadConflict: Codable, Hashable, Sendable {
    let conflictID: UUID
    let claims: [Phase2ReadConflictClaim]

    init(conflictID: UUID, claims: [Phase2ReadConflictClaim]) {
        self.conflictID = conflictID
        self.claims = claims
    }

    var isValid: Bool {
        claims.count >= 2 && Set(claims.map(\.claimID)).count == claims.count
    }
}

/// The closed payload state of one evidence candidate.
enum Phase2ReadCandidateData: Codable, Hashable, Sendable {
    case value(Phase2ReadFactValue)
    case unavailable(Phase2ReadUnavailableReason)
    case conflict(Phase2ReadConflict)
}

/// Typed output awaiting app-side freshness and terminal-state acceptance.
struct Phase2ReadEvidenceCandidate: Codable, Hashable, Sendable {
    /// Correlation identity for an unaccepted candidate. Only the app acceptance boundary may mint
    /// a canonical evidence identity after validation and freshness checks succeed.
    let candidateID: UUID
    let invocationID: UUID
    let sequence: UInt64
    let registryVersion: Phase2ReadRegistryVersion
    let operationID: Phase2ReadOperationID
    let operationVersion: Phase2ReadOperationVersion
    let producingPrincipal: Phase2Principal
    let precondition: Phase2ReadPrecondition
    let citations: [Phase2ReadCitation]
    let data: Phase2ReadCandidateData
    let cancelled: Bool

    init(
        candidateID: UUID,
        invocationID: UUID,
        sequence: UInt64,
        registryVersion: Phase2ReadRegistryVersion,
        operationID: Phase2ReadOperationID,
        operationVersion: Phase2ReadOperationVersion,
        producingPrincipal: Phase2Principal,
        precondition: Phase2ReadPrecondition,
        citations: [Phase2ReadCitation],
        data: Phase2ReadCandidateData,
        cancelled: Bool
    ) {
        self.candidateID = candidateID
        self.invocationID = invocationID
        self.sequence = sequence
        self.registryVersion = registryVersion
        self.operationID = operationID
        self.operationVersion = operationVersion
        self.producingPrincipal = producingPrincipal
        self.precondition = precondition
        self.citations = citations
        self.data = data
        self.cancelled = cancelled
    }
}

/// Final app acceptance result for a candidate or invocation.
enum Phase2ReadDisposition: String, Codable, Hashable, Sendable {
    case accepted
    case stale
    case cancelled
    case duplicate
    case unauthorized
    case unsupported
    case limitExceeded
    case ownerMismatch
    case conflict
}

/// Exactly one terminal record may exist for an invocation.
struct Phase2ReadTerminalOutcome: Codable, Hashable, Sendable {
    let invocationID: UUID
    let sequence: UInt64
    let disposition: Phase2ReadDisposition
    let evidenceIDs: [UUID]
    let conflicts: [Phase2ReadConflict]

    init(
        invocationID: UUID,
        sequence: UInt64,
        disposition: Phase2ReadDisposition,
        evidenceIDs: [UUID] = [],
        conflicts: [Phase2ReadConflict] = []
    ) {
        self.invocationID = invocationID
        self.sequence = sequence
        self.disposition = disposition
        self.evidenceIDs = evidenceIDs
        self.conflicts = conflicts
    }
}

/// Structural validation failures that can be reported without executing a read.
enum Phase2ReadValidationIssue: Hashable, Sendable {
    case unsupportedRegistryVersion(Int)
    case unsupportedOperation(String)
    case unsupportedOperationVersion(Int)
    case emptyPrincipalIdentity(principal: String)
    case effectMismatch(
        operation: Phase2ReadOperationID,
        expected: Set<Phase2EffectClass>,
        actual: Set<Phase2EffectClass>
    )
    case executorMismatch(
        operation: Phase2ReadOperationID,
        expected: Phase2Principal,
        actual: Phase2Principal
    )
    case forbiddenEffect(Phase2EffectClass)
    case unauthorizedAuthorizingPrincipal(Phase2Principal)
    case canonicalDescriptorMismatch(
        requested: Phase2ReadOperationDescriptor,
        canonical: Phase2ReadOperationDescriptor
    )
    case subjectMismatch(operation: Phase2ReadOperationID)
    case nonPositiveLimit(field: Phase2ReadLimitField, value: Int)
    case limitExceedsMaximum(field: Phase2ReadLimitField, value: Int, maximum: Int)
    case approvedLimitExceedsRequest(
        field: Phase2ReadLimitField,
        approved: Int,
        requested: Int
    )
}

/// Exact operation arguments participate in the app authorization's request identity.
struct REAResultReadSelector: Codable, Hashable, Sendable {
    let offset: Int
    let evidenceID: UUID?
    let responseSHA256: String?
    init(offset: Int = 0, evidenceID: UUID? = nil, responseSHA256: String? = nil) {
        self.offset = offset; self.evidenceID = evidenceID; self.responseSHA256 = responseSHA256
    }
    var isValidList: Bool { offset >= 0 && evidenceID == nil && responseSHA256 == nil }
    var isValidGet: Bool { offset >= 0 && evidenceID != nil && responseSHA256.map { $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } == true }
}
