import Foundation

enum DebuggerLaunchProfileValidationError: Error, Equatable, LocalizedError {
    case invalidRevision
    case invalidText(field: String)
    case invalidPath(field: String)
    case invalidExecutableSeal
    case invalidWorkspaceOwner
    case unsupportedArchitecture
    case tooManyArguments
    case tooManyEnvironmentEntries
    case duplicateEnvironmentKey
    case tooManyProfiles
    case duplicateProfileID
    case profileRevisionExceedsCatalog
    case selectedProfileMissing
    case payloadTooLarge
    case noncanonicalPayload

    var errorDescription: String? {
        switch self {
        case .invalidRevision:
            "A launch-profile revision must be in 1...Int64.max."
        case .invalidText(let field):
            "Launch-profile \(field) is empty, malformed, or outside its size bound."
        case .invalidPath(let field):
            "Launch-profile \(field) must be a canonical absolute path."
        case .invalidExecutableSeal:
            "The imported executable seal is incomplete or malformed."
        case .invalidWorkspaceOwner:
            "The workspace launch target does not carry an exact image owner and artifact seal."
        case .unsupportedArchitecture:
            "The launch profile supports only native arm64 or arm64e executables."
        case .tooManyArguments:
            "The launch profile contains too many arguments."
        case .tooManyEnvironmentEntries:
            "The launch profile contains too many environment entries."
        case .duplicateEnvironmentKey:
            "The launch profile contains a duplicate environment key."
        case .tooManyProfiles:
            "The launch-profile catalog contains too many profiles."
        case .duplicateProfileID:
            "The launch-profile catalog contains a duplicate profile identifier."
        case .profileRevisionExceedsCatalog:
            "A launch-profile revision exceeds its catalog revision."
        case .selectedProfileMissing:
            "The selected launch profile is not present in the catalog."
        case .payloadTooLarge:
            "The launch-profile payload exceeds its durable size bound."
        case .noncanonicalPayload:
            "The launch-profile payload is not canonical schema-v1 JSON."
        }
    }
}

struct DebuggerLaunchProfileID: Hashable, Sendable {
    let rawValue: UUID
}

enum DebuggerLaunchProfileArchitecture: String, Hashable, Sendable {
    case arm64
    case arm64e
}

enum DebuggerLaunchProfileStandardIOPolicy: String, Hashable, Sendable {
    /// WS-22 keeps the existing non-capturing launch boundary until the serialized current-Xcode
    /// feasibility gate proves a framed, non-interfering inferior-I/O mechanism.
    case inheritNoCapture
}

struct DebuggerLaunchProfileEnvironmentEntry: Hashable, Sendable {
    static let maximumKeyBytes = 128
    static let maximumValueBytes = 1_024

    let key: String
    let value: String

    init(key: String, value: String) throws {
        guard DebuggerLaunchProfileText.isValidEnvironmentKey(key),
              key.utf8.count <= Self.maximumKeyBytes else {
            throw DebuggerLaunchProfileValidationError.invalidText(field: "environment key")
        }
        try DebuggerLaunchProfileText.validate(
            value,
            field: "environment value",
            maximumUTF8Bytes: Self.maximumValueBytes,
            allowEmpty: true
        )
        self.key = key
        self.value = value
    }
}

extension DebuggerLaunchProfileEnvironmentEntry {
    static func == (lhs: Self, rhs: Self) -> Bool {
        DebuggerLaunchProfileExactUTF8.equal(lhs.key, rhs.key)
            && DebuggerLaunchProfileExactUTF8.equal(lhs.value, rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        DebuggerLaunchProfileExactUTF8.hash(key, into: &hasher)
        DebuggerLaunchProfileExactUTF8.hash(value, into: &hasher)
    }
}

struct DebuggerImportedExecutableSeal: Hashable, Sendable {
    static let maximumPathBytes = 1_024

    let canonicalPath: String
    let deviceID: UInt64
    let fileID: UInt64
    let byteCount: UInt64
    let sha256: String
    let architecture: DebuggerLaunchProfileArchitecture
    let machOUUID: UUID?

    init(
        canonicalPath: String,
        deviceID: UInt64,
        fileID: UInt64,
        byteCount: UInt64,
        sha256: String,
        architecture: DebuggerLaunchProfileArchitecture,
        machOUUID: UUID?
    ) throws {
        try DebuggerLaunchProfileText.validateCanonicalAbsolutePath(
            canonicalPath,
            field: "imported executable path",
            maximumUTF8Bytes: Self.maximumPathBytes
        )
        guard deviceID > 0,
              fileID > 0,
              byteCount > 0,
              DebuggerLaunchProfileText.isLowercaseSHA256(sha256) else {
            throw DebuggerLaunchProfileValidationError.invalidExecutableSeal
        }
        self.canonicalPath = canonicalPath
        self.deviceID = deviceID
        self.fileID = fileID
        self.byteCount = byteCount
        self.sha256 = sha256
        self.architecture = architecture
        self.machOUUID = machOUUID
    }
}

extension DebuggerImportedExecutableSeal {
    static func == (lhs: Self, rhs: Self) -> Bool {
        DebuggerLaunchProfileExactUTF8.equal(lhs.canonicalPath, rhs.canonicalPath)
            && lhs.deviceID == rhs.deviceID
            && lhs.fileID == rhs.fileID
            && lhs.byteCount == rhs.byteCount
            && DebuggerLaunchProfileExactUTF8.equal(lhs.sha256, rhs.sha256)
            && lhs.architecture == rhs.architecture
            && lhs.machOUUID == rhs.machOUUID
    }

    func hash(into hasher: inout Hasher) {
        DebuggerLaunchProfileExactUTF8.hash(canonicalPath, into: &hasher)
        hasher.combine(deviceID)
        hasher.combine(fileID)
        hasher.combine(byteCount)
        DebuggerLaunchProfileExactUTF8.hash(sha256, into: &hasher)
        hasher.combine(architecture)
        hasher.combine(machOUUID)
    }
}

enum DebuggerLaunchProfileTarget: Hashable, Sendable {
    case workspaceImage(DebuggerWorkspaceImageOwnerSeal)
    case importedExecutable(DebuggerImportedExecutableSeal)
}

struct DebuggerLaunchProfile: Hashable, Sendable {
    static let schemaVersion = 1
    static let maximumRevision = UInt64(Int64.max)
    static let maximumNameBytes = 256
    static let maximumArgumentCount = 128
    static let maximumArgumentBytes = 1_024
    static let maximumEnvironmentEntryCount = 128
    static let maximumWorkingDirectoryBytes = 1_024

    let id: DebuggerLaunchProfileID
    let revision: UInt64
    let name: String
    let target: DebuggerLaunchProfileTarget
    let arguments: [String]
    let environment: [DebuggerLaunchProfileEnvironmentEntry]
    let workingDirectory: String?
    let standardIOPolicy: DebuggerLaunchProfileStandardIOPolicy

    init(
        id: DebuggerLaunchProfileID,
        revision: UInt64,
        name: String,
        target: DebuggerLaunchProfileTarget,
        arguments: [String],
        environment: [DebuggerLaunchProfileEnvironmentEntry],
        workingDirectory: String?,
        standardIOPolicy: DebuggerLaunchProfileStandardIOPolicy
    ) throws {
        guard revision > 0, revision <= Self.maximumRevision else {
            throw DebuggerLaunchProfileValidationError.invalidRevision
        }
        try DebuggerLaunchProfileText.validate(
            name,
            field: "name",
            maximumUTF8Bytes: Self.maximumNameBytes
        )
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw DebuggerLaunchProfileValidationError.invalidText(field: "name")
        }
        try Self.validate(target: target)
        guard arguments.count <= Self.maximumArgumentCount else {
            throw DebuggerLaunchProfileValidationError.tooManyArguments
        }
        for argument in arguments {
            try DebuggerLaunchProfileText.validate(
                argument,
                field: "argument",
                maximumUTF8Bytes: Self.maximumArgumentBytes,
                allowEmpty: true
            )
        }
        guard environment.count <= Self.maximumEnvironmentEntryCount else {
            throw DebuggerLaunchProfileValidationError.tooManyEnvironmentEntries
        }
        let orderedEnvironment = environment.sorted { lhs, rhs in
            lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
        }
        guard zip(orderedEnvironment, orderedEnvironment.dropFirst()).allSatisfy({ pair in
            pair.0.key != pair.1.key
        }) else {
            throw DebuggerLaunchProfileValidationError.duplicateEnvironmentKey
        }
        if let workingDirectory {
            try DebuggerLaunchProfileText.validateCanonicalAbsolutePath(
                workingDirectory,
                field: "working directory",
                maximumUTF8Bytes: Self.maximumWorkingDirectoryBytes
            )
        }

        self.id = id
        self.revision = revision
        self.name = name
        self.target = target
        self.arguments = arguments
        self.environment = orderedEnvironment
        self.workingDirectory = workingDirectory
        self.standardIOPolicy = standardIOPolicy

        guard try DebuggerLaunchProfileCanonicalCodec.encodeProfileUnchecked(self).count
            <= DebuggerLaunchProfileCanonicalCodec.maximumProfileBytes else {
            throw DebuggerLaunchProfileValidationError.payloadTooLarge
        }
    }

    private static func validate(target: DebuggerLaunchProfileTarget) throws {
        switch target {
        case .workspaceImage(let owner):
            guard owner.slot.rawValue >= 0, let artifact = owner.artifactIdentity else {
                throw DebuggerLaunchProfileValidationError.invalidWorkspaceOwner
            }
            guard artifact.architectureVariant == .arm64
                    || artifact.architectureVariant == .arm64e else {
                throw DebuggerLaunchProfileValidationError.unsupportedArchitecture
            }
        case .importedExecutable:
            break
        }
    }
}

extension DebuggerLaunchProfile {
    static func == (lhs: Self, rhs: Self) -> Bool {
        DebuggerLaunchProfileExactIdentity.equal(lhs, rhs)
    }

    func hash(into hasher: inout Hasher) {
        DebuggerLaunchProfileExactIdentity.hash(self, into: &hasher)
    }
}

struct DebuggerLaunchProfileCatalog: Hashable, Sendable {
    static let schemaVersion = 1
    static let maximumRevision = UInt64(Int64.max)
    static let maximumProfileCount = 256

    let catalogID: UUID
    let revision: UInt64
    let profiles: [DebuggerLaunchProfile]
    let selectedProfileID: DebuggerLaunchProfileID?

    init(
        catalogID: UUID,
        revision: UInt64,
        profiles: [DebuggerLaunchProfile],
        selectedProfileID: DebuggerLaunchProfileID?
    ) throws {
        guard revision > 0, revision <= Self.maximumRevision else {
            throw DebuggerLaunchProfileValidationError.invalidRevision
        }
        guard profiles.count <= Self.maximumProfileCount else {
            throw DebuggerLaunchProfileValidationError.tooManyProfiles
        }
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw DebuggerLaunchProfileValidationError.duplicateProfileID
        }
        guard profiles.allSatisfy({ $0.revision <= revision }) else {
            throw DebuggerLaunchProfileValidationError.profileRevisionExceedsCatalog
        }
        if let selectedProfileID,
           !profiles.contains(where: { $0.id == selectedProfileID }) {
            throw DebuggerLaunchProfileValidationError.selectedProfileMissing
        }

        self.catalogID = catalogID
        self.revision = revision
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID

        guard try DebuggerLaunchProfileCanonicalCodec.encodeCatalogUnchecked(self).count
            <= DebuggerLaunchProfileCanonicalCodec.maximumCatalogBytes else {
            throw DebuggerLaunchProfileValidationError.payloadTooLarge
        }
    }

    static func freshPristine(catalogID: UUID = UUID()) -> Self {
        try! Self(
            catalogID: catalogID,
            revision: 1,
            profiles: [],
            selectedProfileID: nil
        )
    }

    var isPristine: Bool {
        revision == 1 && profiles.isEmpty && selectedProfileID == nil
    }

    func profile(id: DebuggerLaunchProfileID) -> DebuggerLaunchProfile? {
        profiles.first { $0.id == id }
    }

}

extension DebuggerLaunchProfileCatalog {
    static func == (lhs: Self, rhs: Self) -> Bool {
        DebuggerLaunchProfileExactIdentity.equal(lhs, rhs)
    }

    func hash(into hasher: inout Hasher) {
        DebuggerLaunchProfileExactIdentity.hash(self, into: &hasher)
    }
}

/// The sole durable byte boundary for launch profiles. Persistence stores the raw bytes produced
/// here and reconstructs values only through these exact-canonical decoders; the durable model
/// types intentionally do not conform to `Decodable` or `Codable`.
enum DebuggerLaunchProfileCanonicalCodec {
    static let maximumProfileBytes = 256 * 1_024
    static let maximumCatalogBytes = 8 * 1_024 * 1_024

    static func encodeProfile(_ value: DebuggerLaunchProfile) throws -> Data {
        try encodeProfileUnchecked(value)
    }

    static func decodeProfile(_ data: Data) throws -> DebuggerLaunchProfile {
        guard data.count <= maximumProfileBytes else {
            throw DebuggerLaunchProfileValidationError.payloadTooLarge
        }
        do {
            let wire = try JSONDecoder().decode(DebuggerLaunchProfileWire.self, from: data)
            let value = try wire.validatedValue()
            guard try encodeProfileUnchecked(value) == data else {
                throw DebuggerLaunchProfileValidationError.noncanonicalPayload
            }
            return value
        } catch let error as DebuggerLaunchProfileValidationError {
            throw error
        } catch {
            throw DebuggerLaunchProfileValidationError.noncanonicalPayload
        }
    }

    static func encodeCatalog(_ value: DebuggerLaunchProfileCatalog) throws -> Data {
        let data = try encodeCatalogUnchecked(value)
        guard data.count <= maximumCatalogBytes else {
            throw DebuggerLaunchProfileValidationError.payloadTooLarge
        }
        return data
    }

    static func decodeCatalog(_ data: Data) throws -> DebuggerLaunchProfileCatalog {
        guard data.count <= maximumCatalogBytes else {
            throw DebuggerLaunchProfileValidationError.payloadTooLarge
        }
        do {
            let wire = try JSONDecoder().decode(DebuggerLaunchProfileCatalogWire.self, from: data)
            let value = try wire.validatedValue()
            guard try encodeCatalog(value) == data else {
                throw DebuggerLaunchProfileValidationError.noncanonicalPayload
            }
            return value
        } catch let error as DebuggerLaunchProfileValidationError {
            throw error
        } catch {
            throw DebuggerLaunchProfileValidationError.noncanonicalPayload
        }
    }

    fileprivate static func encodeProfileUnchecked(
        _ value: DebuggerLaunchProfile
    ) throws -> Data {
        try encoder().encode(DebuggerLaunchProfileWire(value))
    }

    fileprivate static func encodeCatalogUnchecked(
        _ value: DebuggerLaunchProfileCatalog
    ) throws -> Data {
        try encoder().encode(DebuggerLaunchProfileCatalogWire(value))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private enum DebuggerLaunchProfileExactIdentity {
    static func equal(_ lhs: DebuggerLaunchProfile, _ rhs: DebuggerLaunchProfile) -> Bool {
        try! DebuggerLaunchProfileCanonicalCodec.encodeProfile(lhs)
            == DebuggerLaunchProfileCanonicalCodec.encodeProfile(rhs)
    }

    static func hash(_ value: DebuggerLaunchProfile, into hasher: inout Hasher) {
        hasher.combine(try! DebuggerLaunchProfileCanonicalCodec.encodeProfile(value))
    }

    static func equal(
        _ lhs: DebuggerLaunchProfileCatalog,
        _ rhs: DebuggerLaunchProfileCatalog
    ) -> Bool {
        try! DebuggerLaunchProfileCanonicalCodec.encodeCatalog(lhs)
            == DebuggerLaunchProfileCanonicalCodec.encodeCatalog(rhs)
    }

    static func hash(_ value: DebuggerLaunchProfileCatalog, into hasher: inout Hasher) {
        hasher.combine(try! DebuggerLaunchProfileCanonicalCodec.encodeCatalog(value))
    }
}

private enum DebuggerLaunchProfileExactUTF8 {
    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func hash(_ value: String, into hasher: inout Hasher) {
        hasher.combine(value.utf8.count)
        for byte in value.utf8 {
            hasher.combine(byte)
        }
    }
}

private struct DebuggerLaunchProfileIDWire: Codable {
    let rawValue: UUID

    init(_ value: DebuggerLaunchProfileID) {
        rawValue = value.rawValue
    }

    var value: DebuggerLaunchProfileID {
        DebuggerLaunchProfileID(rawValue: rawValue)
    }
}

private struct DebuggerLaunchProfileEnvironmentEntryWire: Codable {
    let key: String
    let value: String

    init(_ value: DebuggerLaunchProfileEnvironmentEntry) {
        key = value.key
        self.value = value.value
    }

    func validatedValue() throws -> DebuggerLaunchProfileEnvironmentEntry {
        try DebuggerLaunchProfileEnvironmentEntry(key: key, value: value)
    }
}

private struct DebuggerImportedExecutableSealWire: Codable {
    let canonicalPath: String
    let deviceID: UInt64
    let fileID: UInt64
    let byteCount: UInt64
    let sha256: String
    let architecture: String
    let machOUUID: UUID?

    init(_ value: DebuggerImportedExecutableSeal) {
        canonicalPath = value.canonicalPath
        deviceID = value.deviceID
        fileID = value.fileID
        byteCount = value.byteCount
        sha256 = value.sha256
        architecture = value.architecture.rawValue
        machOUUID = value.machOUUID
    }

    func validatedValue() throws -> DebuggerImportedExecutableSeal {
        guard let architecture = DebuggerLaunchProfileArchitecture(rawValue: architecture) else {
            throw DebuggerLaunchProfileValidationError.noncanonicalPayload
        }
        return try DebuggerImportedExecutableSeal(
            canonicalPath: canonicalPath,
            deviceID: deviceID,
            fileID: fileID,
            byteCount: byteCount,
            sha256: sha256,
            architecture: architecture,
            machOUUID: machOUUID
        )
    }
}

private enum DebuggerLaunchProfileTargetWire: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, workspaceImage, importedExecutable
    }

    private enum Kind: String, Codable {
        case workspaceImage
        case importedExecutable
    }

    case workspaceImage(DebuggerWorkspaceImageOwnerSeal)
    case importedExecutable(DebuggerImportedExecutableSealWire)

    init(_ value: DebuggerLaunchProfileTarget) {
        switch value {
        case .workspaceImage(let owner):
            self = .workspaceImage(owner)
        case .importedExecutable(let seal):
            self = .importedExecutable(DebuggerImportedExecutableSealWire(seal))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .workspaceImage:
            self = .workspaceImage(
                try container.decode(DebuggerWorkspaceImageOwnerSeal.self, forKey: .workspaceImage)
            )
        case .importedExecutable:
            self = .importedExecutable(
                try container.decode(
                    DebuggerImportedExecutableSealWire.self,
                    forKey: .importedExecutable
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workspaceImage(let owner):
            try container.encode(Kind.workspaceImage, forKey: .type)
            try container.encode(owner, forKey: .workspaceImage)
        case .importedExecutable(let seal):
            try container.encode(Kind.importedExecutable, forKey: .type)
            try container.encode(seal, forKey: .importedExecutable)
        }
    }

    func validatedValue() throws -> DebuggerLaunchProfileTarget {
        switch self {
        case .workspaceImage(let owner):
            return .workspaceImage(owner)
        case .importedExecutable(let seal):
            return .importedExecutable(try seal.validatedValue())
        }
    }
}

private struct DebuggerLaunchProfileWire: Codable {
    let schemaVersion: Int
    let id: DebuggerLaunchProfileIDWire
    let revision: UInt64
    let name: String
    let target: DebuggerLaunchProfileTargetWire
    let arguments: [String]
    let environment: [DebuggerLaunchProfileEnvironmentEntryWire]
    let workingDirectory: String?
    let standardIOPolicy: String

    init(_ value: DebuggerLaunchProfile) {
        schemaVersion = DebuggerLaunchProfile.schemaVersion
        id = DebuggerLaunchProfileIDWire(value.id)
        revision = value.revision
        name = value.name
        target = DebuggerLaunchProfileTargetWire(value.target)
        arguments = value.arguments
        environment = value.environment.map(DebuggerLaunchProfileEnvironmentEntryWire.init)
        workingDirectory = value.workingDirectory
        standardIOPolicy = value.standardIOPolicy.rawValue
    }

    func validatedValue() throws -> DebuggerLaunchProfile {
        guard schemaVersion == DebuggerLaunchProfile.schemaVersion,
              let standardIOPolicy = DebuggerLaunchProfileStandardIOPolicy(
                  rawValue: standardIOPolicy
              ) else {
            throw DebuggerLaunchProfileValidationError.noncanonicalPayload
        }
        return try DebuggerLaunchProfile(
            id: id.value,
            revision: revision,
            name: name,
            target: target.validatedValue(),
            arguments: arguments,
            environment: environment.map { try $0.validatedValue() },
            workingDirectory: workingDirectory,
            standardIOPolicy: standardIOPolicy
        )
    }
}

private struct DebuggerLaunchProfileCatalogWire: Codable {
    let schemaVersion: Int
    let catalogID: UUID
    let revision: UInt64
    let profiles: [DebuggerLaunchProfileWire]
    let selectedProfileID: DebuggerLaunchProfileIDWire?

    init(_ value: DebuggerLaunchProfileCatalog) {
        schemaVersion = DebuggerLaunchProfileCatalog.schemaVersion
        catalogID = value.catalogID
        revision = value.revision
        profiles = value.profiles.map(DebuggerLaunchProfileWire.init)
        selectedProfileID = value.selectedProfileID.map(DebuggerLaunchProfileIDWire.init)
    }

    func validatedValue() throws -> DebuggerLaunchProfileCatalog {
        guard schemaVersion == DebuggerLaunchProfileCatalog.schemaVersion else {
            throw DebuggerLaunchProfileValidationError.noncanonicalPayload
        }
        return try DebuggerLaunchProfileCatalog(
            catalogID: catalogID,
            revision: revision,
            profiles: profiles.map { try $0.validatedValue() },
            selectedProfileID: selectedProfileID?.value
        )
    }
}

private enum DebuggerLaunchProfileText {
    static func validate(
        _ value: String,
        field: String,
        maximumUTF8Bytes: Int,
        allowEmpty: Bool = false
    ) throws {
        guard (allowEmpty || !value.isEmpty), value.utf8.count <= maximumUTF8Bytes else {
            throw DebuggerLaunchProfileValidationError.invalidText(field: field)
        }
        for scalar in value.unicodeScalars {
            if scalar.value == 0x2028 || scalar.value == 0x2029 {
                throw DebuggerLaunchProfileValidationError.invalidText(field: field)
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned:
                throw DebuggerLaunchProfileValidationError.invalidText(field: field)
            default:
                break
            }
        }
    }

    static func validateCanonicalAbsolutePath(
        _ value: String,
        field: String,
        maximumUTF8Bytes: Int
    ) throws {
        try validate(value, field: field, maximumUTF8Bytes: maximumUTF8Bytes)
        guard value.hasPrefix("/"),
              (value as NSString).standardizingPath == value else {
            throw DebuggerLaunchProfileValidationError.invalidPath(field: field)
        }
    }

    static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.utf8.first,
              isASCIIAlpha(first) || first == 0x5F else {
            return false
        }
        return key.utf8.dropFirst().allSatisfy { byte in
            isASCIIAlpha(byte) || (0x30...0x39).contains(byte) || byte == 0x5F
        }
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}
