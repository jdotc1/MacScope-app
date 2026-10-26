import Foundation

enum DebuggerLogicalBreakpointValidationError: Error, Equatable, LocalizedError {
    case invalidRevision
    case revisionExhausted
    case invalidImageSlot
    case invalidText(field: String)
    case invalidSourcePath
    case invalidSourceIdentity
    case invalidSourceLine
    case invalidSourceColumn
    case invalidHitPolicy
    case tooManyActions
    case tooManyLogInterpolations
    case payloadTooLarge
    case duplicateLogicalID
    case specificationRevisionExceedsCatalog
    case tooManySpecifications
    case noncanonicalPayload

    var errorDescription: String? {
        switch self {
        case .invalidRevision: "A logical-breakpoint revision must be in 1...Int64.max."
        case .revisionExhausted: "The logical-breakpoint revision is exhausted."
        case .invalidImageSlot: "A logical-breakpoint image slot must be nonnegative."
        case .invalidText(let field): "Logical-breakpoint \(field) text is invalid."
        case .invalidSourcePath: "The source table path does not match its identity form."
        case .invalidSourceIdentity: "The source debug-artifact identity is invalid."
        case .invalidSourceLine: "A source breakpoint line must be positive."
        case .invalidSourceColumn: "An exact source breakpoint column must be positive."
        case .invalidHitPolicy: "ignoreFirst(0) is noncanonical; use always."
        case .tooManyActions: "A logical breakpoint may contain at most 16 actions."
        case .tooManyLogInterpolations: "A log template may contain at most 32 interpolations."
        case .payloadTooLarge: "The logical-breakpoint payload exceeds its bounded size."
        case .duplicateLogicalID: "A logical-breakpoint catalog contains a duplicate ID."
        case .specificationRevisionExceedsCatalog:
            "A specification revision cannot exceed its catalog revision."
        case .tooManySpecifications: "A workspace may contain at most 4,096 logical breakpoints."
        case .noncanonicalPayload: "The logical-breakpoint payload is not canonical."
        }
    }
}

struct DebuggerLogicalBreakpointID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

struct DebuggerLogicalBreakpointRevision: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    static let maximum = UInt64(Int64.max)

    let rawValue: UInt64

    init(validating rawValue: UInt64) throws {
        guard (1...Self.maximum).contains(rawValue) else {
            throw DebuggerLogicalBreakpointValidationError.invalidRevision
        }
        self.rawValue = rawValue
    }

    init?(rawValue: UInt64) {
        guard (1...Self.maximum).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    func incremented() throws -> Self {
        guard rawValue < Self.maximum else {
            throw DebuggerLogicalBreakpointValidationError.revisionExhausted
        }
        return try Self(validating: rawValue + 1)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    init(from decoder: Decoder) throws {
        try self.init(validating: decoder.singleValueContainer().decode(UInt64.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct DebuggerLogicalBreakpointCatalogCoordinate: Codable, Hashable, Sendable {
    let workspaceID: UUID
    let catalogID: UUID
    let revision: UInt64

    init(workspaceID: UUID, catalogID: UUID, revision: UInt64) throws {
        _ = try DebuggerLogicalBreakpointRevision(validating: revision)
        self.workspaceID = workspaceID
        self.catalogID = catalogID
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case workspaceID, catalogID, revision }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            workspaceID: container.decode(UUID.self, forKey: .workspaceID),
            catalogID: container.decode(UUID.self, forKey: .catalogID),
            revision: container.decode(UInt64.self, forKey: .revision)
        )
    }
}

struct DebuggerWorkspaceImageOwnerSeal: Codable, Hashable, Sendable {
    let slot: ImageSlot
    let binaryID: UUID
    let artifactIdentity: MachOSliceArtifactIdentity?
}

enum DebuggerCanonicalSourceTablePath: Hashable, Sendable {
    case absoluteUTF8(String)
    case compilationDirectoryRelativeUTF8(String)
}

extension DebuggerCanonicalSourceTablePath {
    static func == (lhs: Self, rhs: Self) -> Bool {
        DebuggerLogicalBreakpointExactIdentity.equal(lhs, rhs)
    }

    func hash(into hasher: inout Hasher) {
        DebuggerLogicalBreakpointExactIdentity.hash(self, into: &hasher)
    }
}

extension DebuggerCanonicalSourceTablePath: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case absoluteUTF8, compilationDirectoryRelativeUTF8 }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .value)
        switch try container.decode(Kind.self, forKey: .type) {
        case .absoluteUTF8: self = .absoluteUTF8(value)
        case .compilationDirectoryRelativeUTF8: self = .compilationDirectoryRelativeUTF8(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absoluteUTF8(let value):
            try container.encode(Kind.absoluteUTF8, forKey: .type)
            try container.encode(value, forKey: .value)
        case .compilationDirectoryRelativeUTF8(let value):
            try container.encode(Kind.compilationDirectoryRelativeUTF8, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

struct DebuggerCanonicalSourceFileIdentity: Codable, Hashable, Sendable {
    let debugArtifactUUID: UUID
    let debugArtifactMachOSHA256: String
    let debugArtifactMachOByteCount: UInt64
    let lineProgramUnitOffset: UInt64
    let fileTableIndex: UInt32
    let tablePath: DebuggerCanonicalSourceTablePath

    init(
        debugArtifactUUID: UUID,
        debugArtifactMachOSHA256: String,
        debugArtifactMachOByteCount: UInt64,
        lineProgramUnitOffset: UInt64,
        fileTableIndex: UInt32,
        tablePath: DebuggerCanonicalSourceTablePath
    ) throws {
        guard DebuggerLogicalBreakpointText.isLowercaseSHA256(debugArtifactMachOSHA256),
              debugArtifactMachOByteCount > 0
        else { throw DebuggerLogicalBreakpointValidationError.invalidSourceIdentity }
        try DebuggerLogicalBreakpointText.validateSourcePath(tablePath)
        self.debugArtifactUUID = debugArtifactUUID
        self.debugArtifactMachOSHA256 = debugArtifactMachOSHA256
        self.debugArtifactMachOByteCount = debugArtifactMachOByteCount
        self.lineProgramUnitOffset = lineProgramUnitOffset
        self.fileTableIndex = fileTableIndex
        self.tablePath = tablePath
    }

    private enum CodingKeys: String, CodingKey {
        case debugArtifactUUID, debugArtifactMachOSHA256, debugArtifactMachOByteCount
        case lineProgramUnitOffset, fileTableIndex, tablePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            debugArtifactUUID: container.decode(UUID.self, forKey: .debugArtifactUUID),
            debugArtifactMachOSHA256: container.decode(String.self, forKey: .debugArtifactMachOSHA256),
            debugArtifactMachOByteCount: container.decode(UInt64.self, forKey: .debugArtifactMachOByteCount),
            lineProgramUnitOffset: container.decode(UInt64.self, forKey: .lineProgramUnitOffset),
            fileTableIndex: container.decode(UInt32.self, forKey: .fileTableIndex),
            tablePath: container.decode(DebuggerCanonicalSourceTablePath.self, forKey: .tablePath)
        )
    }
}

enum DebuggerSourceColumnPolicy: Hashable, Sendable {
    case any
    case exact(UInt32)
}

extension DebuggerSourceColumnPolicy: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case any, exact }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .any: self = .any
        case .exact: self = .exact(try container.decode(UInt32.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .any:
            try container.encode(Kind.any, forKey: .type)
        case .exact(let value):
            try container.encode(Kind.exact, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

enum DebuggerLogicalBreakpointCardinality: String, Codable, Hashable, Sendable {
    case exactlyOne
    case allExactMatches
}

enum DebuggerLogicalBreakpointTarget: Hashable, Sendable {
    case preferredAddress(owner: DebuggerWorkspaceImageOwnerSeal, preferredVA: UInt64)
    case imageOffset(
        owner: DebuggerWorkspaceImageOwnerSeal,
        segmentName: String,
        expectedSegmentPreferredStart: UInt64,
        offset: UInt64
    )
    case function(
        owner: DebuggerWorkspaceImageOwnerSeal,
        entryPreferredVA: UInt64,
        rawLinkageNameHint: String?
    )
    case symbol(
        owner: DebuggerWorkspaceImageOwnerSeal,
        exactRawLinkageName: String,
        kind: String?,
        libraryName: String?,
        cardinality: DebuggerLogicalBreakpointCardinality
    )
    case source(
        owner: DebuggerWorkspaceImageOwnerSeal,
        file: DebuggerCanonicalSourceFileIdentity,
        line: UInt32,
        columnPolicy: DebuggerSourceColumnPolicy,
        cardinality: DebuggerLogicalBreakpointCardinality
    )
}

extension DebuggerLogicalBreakpointTarget {
    static func == (lhs: Self, rhs: Self) -> Bool {
        DebuggerLogicalBreakpointExactIdentity.equal(lhs, rhs)
    }

    func hash(into hasher: inout Hasher) {
        DebuggerLogicalBreakpointExactIdentity.hash(self, into: &hasher)
    }
}

extension DebuggerLogicalBreakpointTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, owner, preferredVA, segmentName, expectedSegmentPreferredStart, offset
        case entryPreferredVA, rawLinkageNameHint, exactRawLinkageName, kind, libraryName
        case cardinality, file, line, columnPolicy
    }
    private enum Kind: String, Codable {
        case preferredAddress, imageOffset, function, symbol, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let owner = try c.decode(DebuggerWorkspaceImageOwnerSeal.self, forKey: .owner)
        switch try c.decode(Kind.self, forKey: .type) {
        case .preferredAddress:
            self = .preferredAddress(owner: owner, preferredVA: try c.decode(UInt64.self, forKey: .preferredVA))
        case .imageOffset:
            self = .imageOffset(
                owner: owner,
                segmentName: try c.decode(String.self, forKey: .segmentName),
                expectedSegmentPreferredStart: try c.decode(UInt64.self, forKey: .expectedSegmentPreferredStart),
                offset: try c.decode(UInt64.self, forKey: .offset)
            )
        case .function:
            self = .function(
                owner: owner,
                entryPreferredVA: try c.decode(UInt64.self, forKey: .entryPreferredVA),
                rawLinkageNameHint: try c.decodeIfPresent(String.self, forKey: .rawLinkageNameHint)
            )
        case .symbol:
            self = .symbol(
                owner: owner,
                exactRawLinkageName: try c.decode(String.self, forKey: .exactRawLinkageName),
                kind: try c.decodeIfPresent(String.self, forKey: .kind),
                libraryName: try c.decodeIfPresent(String.self, forKey: .libraryName),
                cardinality: try c.decode(DebuggerLogicalBreakpointCardinality.self, forKey: .cardinality)
            )
        case .source:
            self = .source(
                owner: owner,
                file: try c.decode(DebuggerCanonicalSourceFileIdentity.self, forKey: .file),
                line: try c.decode(UInt32.self, forKey: .line),
                columnPolicy: try c.decode(DebuggerSourceColumnPolicy.self, forKey: .columnPolicy),
                cardinality: try c.decode(DebuggerLogicalBreakpointCardinality.self, forKey: .cardinality)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preferredAddress(let owner, let preferredVA):
            try c.encode(Kind.preferredAddress, forKey: .type)
            try c.encode(owner, forKey: .owner)
            try c.encode(preferredVA, forKey: .preferredVA)
        case .imageOffset(let owner, let segmentName, let start, let offset):
            try c.encode(Kind.imageOffset, forKey: .type)
            try c.encode(owner, forKey: .owner)
            try c.encode(segmentName, forKey: .segmentName)
            try c.encode(start, forKey: .expectedSegmentPreferredStart)
            try c.encode(offset, forKey: .offset)
        case .function(let owner, let entry, let hint):
            try c.encode(Kind.function, forKey: .type)
            try c.encode(owner, forKey: .owner)
            try c.encode(entry, forKey: .entryPreferredVA)
            try c.encodeIfPresent(hint, forKey: .rawLinkageNameHint)
        case .symbol(let owner, let name, let kind, let library, let cardinality):
            try c.encode(Kind.symbol, forKey: .type)
            try c.encode(owner, forKey: .owner)
            try c.encode(name, forKey: .exactRawLinkageName)
            try c.encodeIfPresent(kind, forKey: .kind)
            try c.encodeIfPresent(library, forKey: .libraryName)
            try c.encode(cardinality, forKey: .cardinality)
        case .source(let owner, let file, let line, let column, let cardinality):
            try c.encode(Kind.source, forKey: .type)
            try c.encode(owner, forKey: .owner)
            try c.encode(file, forKey: .file)
            try c.encode(line, forKey: .line)
            try c.encode(column, forKey: .columnPolicy)
            try c.encode(cardinality, forKey: .cardinality)
        }
    }
}

enum DebuggerBreakpointHitPolicy: Hashable, Sendable {
    case always
    case ignoreFirst(UInt32)
}

extension DebuggerBreakpointHitPolicy: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case always, ignoreFirst }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .always: self = .always
        case .ignoreFirst: self = .ignoreFirst(try c.decode(UInt32.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .always: try c.encode(Kind.always, forKey: .type)
        case .ignoreFirst(let value):
            try c.encode(Kind.ignoreFirst, forKey: .type)
            try c.encode(value, forKey: .value)
        }
    }
}

struct DebuggerBreakpointExpressionCapture: Codable, Hashable, Sendable {
    let label: String
    let expression: String

    init(label: String, expression: String) throws {
        try DebuggerLogicalBreakpointText.validate(label, field: "expression label", maximumUTF8Bytes: 256)
        try DebuggerLogicalBreakpointText.validate(expression, field: "expression", maximumUTF8Bytes: 1_024)
        self.label = label
        self.expression = expression
    }

    private enum CodingKeys: String, CodingKey { case label, expression }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            label: c.decode(String.self, forKey: .label),
            expression: c.decode(String.self, forKey: .expression)
        )
    }
}

extension DebuggerBreakpointExpressionCapture {
    static func == (lhs: Self, rhs: Self) -> Bool {
        DebuggerLogicalBreakpointExactIdentity.equal(lhs, rhs)
    }

    func hash(into hasher: inout Hasher) {
        DebuggerLogicalBreakpointExactIdentity.hash(self, into: &hasher)
    }
}

enum DebuggerBreakpointLogTemplateFragment: Hashable, Sendable {
    case literal(String)
    case targetExpression(String)
}

extension DebuggerBreakpointLogTemplateFragment {
    static func == (lhs: Self, rhs: Self) -> Bool {
        DebuggerLogicalBreakpointExactIdentity.equal(lhs, rhs)
    }

    func hash(into hasher: inout Hasher) {
        DebuggerLogicalBreakpointExactIdentity.hash(self, into: &hasher)
    }
}

extension DebuggerBreakpointLogTemplateFragment: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case literal, targetExpression }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .value)
        switch try c.decode(Kind.self, forKey: .type) {
        case .literal: self = .literal(value)
        case .targetExpression: self = .targetExpression(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let value):
            try c.encode(Kind.literal, forKey: .type)
            try c.encode(value, forKey: .value)
        case .targetExpression(let value):
            try c.encode(Kind.targetExpression, forKey: .type)
            try c.encode(value, forKey: .value)
        }
    }
}

struct DebuggerBreakpointLogTemplate: Codable, Hashable, Sendable {
    let fragments: [DebuggerBreakpointLogTemplateFragment]

    init(fragments: [DebuggerBreakpointLogTemplateFragment]) throws {
        guard !fragments.isEmpty else {
            throw DebuggerLogicalBreakpointValidationError.invalidText(field: "log template")
        }
        var totalBytes = 0
        var interpolationCount = 0
        for fragment in fragments {
            let value: String
            switch fragment {
            case .literal(let text):
                value = text
                try DebuggerLogicalBreakpointText.validate(
                    text,
                    field: "log literal",
                    maximumUTF8Bytes: 4_096
                )
            case .targetExpression(let expression):
                value = expression
                interpolationCount += 1
                guard interpolationCount <= 32 else {
                    throw DebuggerLogicalBreakpointValidationError.tooManyLogInterpolations
                }
                try DebuggerLogicalBreakpointText.validate(
                    expression,
                    field: "log expression",
                    maximumUTF8Bytes: 1_024
                )
            }
            let addition = totalBytes.addingReportingOverflow(value.utf8.count)
            guard !addition.overflow, addition.partialValue <= 4_096 else {
                throw DebuggerLogicalBreakpointValidationError.payloadTooLarge
            }
            totalBytes = addition.partialValue
        }
        self.fragments = fragments
    }

    private enum CodingKeys: String, CodingKey { case fragments }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(fragments: c.decode([DebuggerBreakpointLogTemplateFragment].self, forKey: .fragments))
    }
}

enum DebuggerBreakpointAction: Hashable, Sendable {
    case log(DebuggerBreakpointLogTemplate)
    case evaluateTargetExpression(DebuggerBreakpointExpressionCapture)
}

extension DebuggerBreakpointAction: Codable {
    private enum CodingKeys: String, CodingKey { case type, log, expression }
    private enum Kind: String, Codable { case log, evaluateTargetExpression }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .log: self = .log(try c.decode(DebuggerBreakpointLogTemplate.self, forKey: .log))
        case .evaluateTargetExpression:
            self = .evaluateTargetExpression(
                try c.decode(DebuggerBreakpointExpressionCapture.self, forKey: .expression)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .log(let template):
            try c.encode(Kind.log, forKey: .type)
            try c.encode(template, forKey: .log)
        case .evaluateTargetExpression(let capture):
            try c.encode(Kind.evaluateTargetExpression, forKey: .type)
            try c.encode(capture, forKey: .expression)
        }
    }
}

enum DebuggerBreakpointDisposition: String, Codable, Hashable, Sendable {
    case stop
    case continueAfterSuccessfulActions
}

struct DebuggerLogicalBreakpointSpecification: Codable, Hashable, Sendable {
    static let schemaVersion = 1

    let id: DebuggerLogicalBreakpointID
    let revision: DebuggerLogicalBreakpointRevision
    let enabled: Bool
    let target: DebuggerLogicalBreakpointTarget
    let condition: String?
    let hitPolicy: DebuggerBreakpointHitPolicy
    let actions: [DebuggerBreakpointAction]
    let disposition: DebuggerBreakpointDisposition

    init(
        id: DebuggerLogicalBreakpointID,
        revision: DebuggerLogicalBreakpointRevision,
        enabled: Bool,
        target: DebuggerLogicalBreakpointTarget,
        condition: String?,
        hitPolicy: DebuggerBreakpointHitPolicy,
        actions: [DebuggerBreakpointAction],
        disposition: DebuggerBreakpointDisposition
    ) throws {
        try Self.validate(target)
        if let condition {
            try DebuggerLogicalBreakpointText.validate(
                condition,
                field: "condition",
                maximumUTF8Bytes: 1_024
            )
        }
        if case .ignoreFirst(0) = hitPolicy {
            throw DebuggerLogicalBreakpointValidationError.invalidHitPolicy
        }
        guard actions.count <= 16 else {
            throw DebuggerLogicalBreakpointValidationError.tooManyActions
        }
        self.id = id
        self.revision = revision
        self.enabled = enabled
        self.target = target
        self.condition = condition
        self.hitPolicy = hitPolicy
        self.actions = actions
        self.disposition = disposition
        let encoded = try DebuggerLogicalBreakpointCanonicalCodec.encodeSpecificationUnchecked(self)
        guard encoded.count <= 16 * 1_024 else {
            throw DebuggerLogicalBreakpointValidationError.payloadTooLarge
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, revision, enabled, target, condition, hitPolicy, actions, disposition
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload
        }
        try self.init(
            id: c.decode(DebuggerLogicalBreakpointID.self, forKey: .id),
            revision: c.decode(DebuggerLogicalBreakpointRevision.self, forKey: .revision),
            enabled: c.decode(Bool.self, forKey: .enabled),
            target: c.decode(DebuggerLogicalBreakpointTarget.self, forKey: .target),
            condition: c.decodeIfPresent(String.self, forKey: .condition),
            hitPolicy: c.decode(DebuggerBreakpointHitPolicy.self, forKey: .hitPolicy),
            actions: c.decode([DebuggerBreakpointAction].self, forKey: .actions),
            disposition: c.decode(DebuggerBreakpointDisposition.self, forKey: .disposition)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(revision, forKey: .revision)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(target, forKey: .target)
        try c.encodeIfPresent(condition, forKey: .condition)
        try c.encode(hitPolicy, forKey: .hitPolicy)
        try c.encode(actions, forKey: .actions)
        try c.encode(disposition, forKey: .disposition)
    }

    private static func validate(_ target: DebuggerLogicalBreakpointTarget) throws {
        let owner: DebuggerWorkspaceImageOwnerSeal
        switch target {
        case .preferredAddress(let value, _): owner = value
        case .imageOffset(let value, let segment, _, _):
            owner = value
            try DebuggerLogicalBreakpointText.validate(segment, field: "segment", maximumUTF8Bytes: 16)
        case .function(let value, _, let hint):
            owner = value
            if let hint {
                try DebuggerLogicalBreakpointText.validate(hint, field: "function name", maximumUTF8Bytes: 1_024)
            }
        case .symbol(let value, let name, let kind, let library, _):
            owner = value
            try DebuggerLogicalBreakpointText.validate(name, field: "symbol", maximumUTF8Bytes: 4_096)
            if let kind {
                try DebuggerLogicalBreakpointText.validate(kind, field: "symbol kind", maximumUTF8Bytes: 256)
            }
            if let library {
                try DebuggerLogicalBreakpointText.validate(library, field: "library", maximumUTF8Bytes: 256)
            }
        case .source(let value, _, let line, let column, _):
            owner = value
            guard line > 0 else { throw DebuggerLogicalBreakpointValidationError.invalidSourceLine }
            if case .exact(0) = column {
                throw DebuggerLogicalBreakpointValidationError.invalidSourceColumn
            }
        }
        guard owner.slot.rawValue >= 0 else {
            throw DebuggerLogicalBreakpointValidationError.invalidImageSlot
        }
    }
}

extension DebuggerLogicalBreakpointSpecification {
    static func == (lhs: Self, rhs: Self) -> Bool {
        DebuggerLogicalBreakpointExactIdentity.equal(lhs, rhs)
    }

    func hash(into hasher: inout Hasher) {
        DebuggerLogicalBreakpointExactIdentity.hash(self, into: &hasher)
    }
}

struct DebuggerLogicalBreakpointCatalog: Codable, Hashable, Sendable {
    static let schemaVersion = 1

    let catalogID: UUID
    let revision: UInt64
    let specifications: [DebuggerLogicalBreakpointSpecification]

    init(
        catalogID: UUID,
        revision: UInt64,
        specifications: [DebuggerLogicalBreakpointSpecification]
    ) throws {
        _ = try DebuggerLogicalBreakpointRevision(validating: revision)
        guard specifications.count <= 4_096 else {
            throw DebuggerLogicalBreakpointValidationError.tooManySpecifications
        }
        let ordered = specifications.sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        guard Set(ordered.map(\.id)).count == ordered.count else {
            throw DebuggerLogicalBreakpointValidationError.duplicateLogicalID
        }
        guard ordered.allSatisfy({ $0.revision.rawValue <= revision }) else {
            throw DebuggerLogicalBreakpointValidationError.specificationRevisionExceedsCatalog
        }
        var total = 0
        for specification in ordered {
            let count = try DebuggerLogicalBreakpointCanonicalCodec
                .encodeSpecificationUnchecked(specification).count
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow, sum.partialValue <= 8 * 1_024 * 1_024 else {
                throw DebuggerLogicalBreakpointValidationError.payloadTooLarge
            }
            total = sum.partialValue
        }
        self.catalogID = catalogID
        self.revision = revision
        self.specifications = ordered
    }

    static func freshPristine(catalogID: UUID = UUID()) -> Self {
        // The literal revision and empty set are valid by construction.
        try! Self(catalogID: catalogID, revision: 1, specifications: [])
    }

    var isPristine: Bool { revision == 1 && specifications.isEmpty }

    private enum CodingKeys: String, CodingKey { case schemaVersion, catalogID, revision, specifications }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload
        }
        try self.init(
            catalogID: c.decode(UUID.self, forKey: .catalogID),
            revision: c.decode(UInt64.self, forKey: .revision),
            specifications: c.decode([DebuggerLogicalBreakpointSpecification].self, forKey: .specifications)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .schemaVersion)
        try c.encode(catalogID, forKey: .catalogID)
        try c.encode(revision, forKey: .revision)
        try c.encode(specifications, forKey: .specifications)
    }
}

enum DebuggerLogicalBreakpointCanonicalCodec {
    private static let maximumSpecificationBytes = 16 * 1_024
    private static let maximumCatalogBytes = 8 * 1_024 * 1_024 + 8 * 1_024

    static func encodeSpecification(_ value: DebuggerLogicalBreakpointSpecification) throws -> Data {
        try encodeSpecificationUnchecked(value)
    }

    static func decodeSpecification(_ data: Data) throws -> DebuggerLogicalBreakpointSpecification {
        guard data.count <= maximumSpecificationBytes else {
            throw DebuggerLogicalBreakpointValidationError.payloadTooLarge
        }
        let value = try JSONDecoder().decode(DebuggerLogicalBreakpointSpecification.self, from: data)
        guard try encodeSpecificationUnchecked(value) == data else {
            throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload
        }
        return value
    }

    static func encodeCatalog(_ value: DebuggerLogicalBreakpointCatalog) throws -> Data {
        try encoder().encode(value)
    }

    static func decodeCatalog(_ data: Data) throws -> DebuggerLogicalBreakpointCatalog {
        guard data.count <= maximumCatalogBytes else {
            throw DebuggerLogicalBreakpointValidationError.payloadTooLarge
        }
        let value = try JSONDecoder().decode(DebuggerLogicalBreakpointCatalog.self, from: data)
        guard try encodeCatalog(value) == data else {
            throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload
        }
        return value
    }

    fileprivate static func encodeSpecificationUnchecked(
        _ value: DebuggerLogicalBreakpointSpecification
    ) throws -> Data {
        try encoder().encode(value)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// Swift `String` equality intentionally uses Unicode canonical equivalence. Breakpoint authored
/// identity instead follows the frozen on-disk contract: exact validated UTF-8 bytes. Encoding the
/// bounded value with the same deterministic JSON settings gives every semantic string field one
/// byte-exact Equatable/Hashable implementation without changing its serialized string shape.
private enum DebuggerLogicalBreakpointExactIdentity {
    static func equal<Value: Encodable>(_ lhs: Value, _ rhs: Value) -> Bool {
        encode(lhs) == encode(rhs)
    }

    static func hash<Value: Encodable>(_ value: Value, into hasher: inout Hasher) {
        hasher.combine(encode(value))
    }

    private static func encode<Value: Encodable>(_ value: Value) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // All participating model values encode only bounded Foundation primitives and explicit
        // case tags, so encoding cannot fail after successful model construction/decoding.
        return try! encoder.encode(value)
    }
}

private enum DebuggerLogicalBreakpointText {
    static func validate(
        _ value: String,
        field: String,
        maximumUTF8Bytes: Int,
        allowEmpty: Bool = false
    ) throws {
        guard (allowEmpty || !value.isEmpty), value.utf8.count <= maximumUTF8Bytes else {
            throw DebuggerLogicalBreakpointValidationError.invalidText(field: field)
        }
        for scalar in value.unicodeScalars {
            if scalar.value == 0x2028 || scalar.value == 0x2029 {
                throw DebuggerLogicalBreakpointValidationError.invalidText(field: field)
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned:
                throw DebuggerLogicalBreakpointValidationError.invalidText(field: field)
            default:
                break
            }
        }
    }

    static func validateSourcePath(_ path: DebuggerCanonicalSourceTablePath) throws {
        let value: String
        switch path {
        case .absoluteUTF8(let candidate):
            value = candidate
            guard candidate.hasPrefix("/") else {
                throw DebuggerLogicalBreakpointValidationError.invalidSourcePath
            }
        case .compilationDirectoryRelativeUTF8(let candidate):
            value = candidate
            guard !candidate.hasPrefix("/") else {
                throw DebuggerLogicalBreakpointValidationError.invalidSourcePath
            }
        }
        do {
            try validate(value, field: "source path", maximumUTF8Bytes: 4_096)
        } catch {
            throw DebuggerLogicalBreakpointValidationError.invalidSourcePath
        }
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }
}
