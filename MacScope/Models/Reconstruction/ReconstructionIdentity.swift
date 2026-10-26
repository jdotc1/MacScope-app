import Foundation

enum ReconstructionValidationError: Error, Equatable, LocalizedError {
    case invalidSchemaVersion
    case invalidSHA256(field: String)
    case invalidByteCount(field: String)
    case invalidRange(field: String)
    case invalidString(field: String)
    case duplicateValue(field: String)
    case invalidReference(field: String)
    case forbiddenTransientIdentity(field: String)

    var errorDescription: String? {
        switch self {
        case .invalidSchemaVersion:
            "A reconstruction schema version must be positive."
        case .invalidSHA256(let field):
            "\(field) must be a canonical lowercase SHA-256 digest."
        case .invalidByteCount(let field):
            "\(field) must be positive."
        case .invalidRange(let field):
            "\(field) must be a nonempty, nonoverflowing half-open range."
        case .invalidString(let field):
            "\(field) is empty or contains prohibited text."
        case .duplicateValue(let field):
            "\(field) contains duplicate values."
        case .invalidReference(let field):
            "\(field) contains an invalid reference combination."
        case .forbiddenTransientIdentity(let field):
            "\(field) contains transient or private identity data."
        }
    }
}

enum ReconstructionValidation {
    static func requireSchemaVersion(_ value: Int) throws {
        guard value > 0 else { throw ReconstructionValidationError.invalidSchemaVersion }
    }

    static func requireSHA256(_ value: String, field: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw ReconstructionValidationError.invalidSHA256(field: field)
        }
    }

    static func requireNonempty(_ value: String, field: String) throws {
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw ReconstructionValidationError.invalidString(field: field)
        }
    }

    static func requireUnique<T: Hashable>(_ values: [T], field: String) throws {
        guard Set(values).count == values.count else {
            throw ReconstructionValidationError.duplicateValue(field: field)
        }
    }

    static func sortedUUIDs(_ values: [UUID]) -> [UUID] {
        values.sorted { $0.uuidString < $1.uuidString }
    }
}

struct ReconstructionArtifactOccurrenceID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

struct ReconstructionContentIdentity: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    enum Algorithm: String, Codable, Sendable {
        case sha256
    }

    let algorithm: Algorithm
    let digest: String
    let byteCount: UInt64

    init(algorithm: Algorithm, digest: String, byteCount: UInt64) throws {
        try ReconstructionValidation.requireSHA256(digest, field: "content digest")
        guard byteCount > 0 else {
            throw ReconstructionValidationError.invalidByteCount(field: "content byte count")
        }
        self.algorithm = algorithm
        self.digest = digest
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case algorithm, digest, byteCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            algorithm: container.decode(Algorithm.self, forKey: .algorithm),
            digest: container.decode(String.self, forKey: .digest),
            byteCount: container.decode(UInt64.self, forKey: .byteCount)
        )
    }
}

struct ReconstructionArtifactCoordinate: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let occurrenceID: ReconstructionArtifactOccurrenceID
    let contentIdentity: ReconstructionContentIdentity
}

enum ReconstructionArchitecture: String, Codable, Hashable, Sendable {
    case arm64
    case arm64e
    case x86_64
    case x86_64h
    case unknown
}

struct ReconstructionImageBinding: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let binaryID: UUID
    let imageSlot: ImageSlot
    let selectedSliceIndex: Int?
    let architecture: ReconstructionArchitecture
    let machOIdentity: MachOSliceArtifactIdentity?

    init(
        binaryID: UUID,
        imageSlot: ImageSlot,
        selectedSliceIndex: Int?,
        architecture: ReconstructionArchitecture,
        machOIdentity: MachOSliceArtifactIdentity?
    ) {
        self.binaryID = binaryID
        self.imageSlot = imageSlot
        self.selectedSliceIndex = selectedSliceIndex
        self.architecture = architecture
        self.machOIdentity = machOIdentity
    }
}

struct ReconstructionImageCoordinate: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let artifact: ReconstructionArtifactCoordinate
    let image: ReconstructionImageBinding
    let analysisFingerprintSHA256: String

    init(
        artifact: ReconstructionArtifactCoordinate,
        image: ReconstructionImageBinding,
        analysisFingerprintSHA256: String
    ) throws {
        try ReconstructionValidation.requireSHA256(
            analysisFingerprintSHA256,
            field: "analysis fingerprint"
        )
        self.artifact = artifact
        self.image = image
        self.analysisFingerprintSHA256 = analysisFingerprintSHA256
    }
}

struct ReconstructionFunctionCoordinate: Codable, Sendable {
    static let schemaVersion = 1

    let artifact: ReconstructionArtifactCoordinate
    let image: ReconstructionImageBinding
    let analysisFingerprintSHA256: String
    let startAddress: UInt64
    let endAddressExclusive: UInt64
    let boundarySchemaVersion: Int
    let functionUUIDHint: UUID?
    let symbolHint: String?

    init(
        artifact: ReconstructionArtifactCoordinate,
        image: ReconstructionImageBinding,
        analysisFingerprintSHA256: String,
        startAddress: UInt64,
        endAddressExclusive: UInt64,
        boundarySchemaVersion: Int,
        functionUUIDHint: UUID?,
        symbolHint: String?
    ) throws {
        try ReconstructionValidation.requireSHA256(
            analysisFingerprintSHA256,
            field: "analysis fingerprint"
        )
        guard startAddress < endAddressExclusive else {
            throw ReconstructionValidationError.invalidRange(field: "function address range")
        }
        try ReconstructionValidation.requireSchemaVersion(boundarySchemaVersion)
        if let symbolHint {
            try ReconstructionValidation.requireNonempty(symbolHint, field: "function symbol hint")
        }
        self.artifact = artifact
        self.image = image
        self.analysisFingerprintSHA256 = analysisFingerprintSHA256
        self.startAddress = startAddress
        self.endAddressExclusive = endAddressExclusive
        self.boundarySchemaVersion = boundarySchemaVersion
        self.functionUUIDHint = functionUUIDHint
        self.symbolHint = symbolHint
    }

    private enum CodingKeys: String, CodingKey {
        case artifact, image, analysisFingerprintSHA256
        case startAddress, endAddressExclusive, boundarySchemaVersion
        case functionUUIDHint, symbolHint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            artifact: container.decode(ReconstructionArtifactCoordinate.self, forKey: .artifact),
            image: container.decode(ReconstructionImageBinding.self, forKey: .image),
            analysisFingerprintSHA256: container.decode(String.self, forKey: .analysisFingerprintSHA256),
            startAddress: container.decode(UInt64.self, forKey: .startAddress),
            endAddressExclusive: container.decode(UInt64.self, forKey: .endAddressExclusive),
            boundarySchemaVersion: container.decode(Int.self, forKey: .boundarySchemaVersion),
            functionUUIDHint: container.decodeIfPresent(UUID.self, forKey: .functionUUIDHint),
            symbolHint: container.decodeIfPresent(String.self, forKey: .symbolHint)
        )
    }
}

extension ReconstructionFunctionCoordinate: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.artifact == rhs.artifact
            && lhs.image == rhs.image
            && lhs.analysisFingerprintSHA256 == rhs.analysisFingerprintSHA256
            && lhs.startAddress == rhs.startAddress
            && lhs.endAddressExclusive == rhs.endAddressExclusive
            && lhs.boundarySchemaVersion == rhs.boundarySchemaVersion
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(artifact)
        hasher.combine(image)
        hasher.combine(analysisFingerprintSHA256)
        hasher.combine(startAddress)
        hasher.combine(endAddressExclusive)
        hasher.combine(boundarySchemaVersion)
    }
}

enum ReconstructionSubjectCoordinate: Hashable, Codable, Sendable {
    case artifact(ReconstructionArtifactCoordinate)
    case image(ReconstructionImageCoordinate)
    case function(ReconstructionFunctionCoordinate)
}

struct ReconstructionDiagnostic: Hashable, Codable, Sendable {
    static let schemaVersion = 1
    static let defaultMaxUTF8Bytes = 1_024

    let text: String

    private init(validatedText: String) {
        text = validatedText
    }

    static func sanitizing(
        _ source: String,
        maxUTF8Bytes: Int = defaultMaxUTF8Bytes
    ) -> ReconstructionDiagnostic {
        guard maxUTF8Bytes > 0 else { return .init(validatedText: "") }
        var result = ""
        var usedBytes = 0
        for character in source where !character.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7f
        }) {
            let count = String(character).utf8.count
            guard usedBytes + count <= maxUTF8Bytes else { break }
            result.append(character)
            usedBytes += count
        }
        return .init(validatedText: result)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode(String.self)
        let sanitized = Self.sanitizing(decoded)
        guard sanitized.text == decoded else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Reconstruction diagnostic is not canonical bounded text."
            )
        }
        text = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}
