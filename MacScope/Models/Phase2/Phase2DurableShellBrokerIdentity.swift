import CryptoKit
import Foundation

struct Phase2DurableShellBrokerProcessIdentity: Codable, Equatable, Sendable {
    let processIdentifier: Int32
    let processStartTimeUnixNanoseconds: UInt64
    let executablePath: String
    let processGroupIdentifier: Int32

    var isStructurallyValid: Bool {
        processIdentifier > 1
            && processStartTimeUnixNanoseconds > 0
            && executablePath.hasPrefix("/")
            && !executablePath.contains("\0")
            && processGroupIdentifier > 1
    }
}

struct Phase2DurableShellBrokerLaunchRequest: Codable, Equatable, Sendable {
    let brokerIncarnationID: UUID
    let sessionID: UUID
    let capabilityID: UUID
    let requestID: UUID
    let executablePath: String
    let arguments: [String]
    let workingDirectoryPath: String?
    let createdAt: Date
    let expiresAt: Date

    var isStructurallyValid: Bool {
        executablePath.hasPrefix("/")
            && !executablePath.contains("\0")
            && !arguments.contains(where: { $0.contains("\0") })
            && (workingDirectoryPath == nil || (
                workingDirectoryPath?.hasPrefix("/") == true
                    && workingDirectoryPath?.contains("\0") == false
            ))
            && expiresAt > createdAt
    }
}

/// Persistable identity for a durable broker-owned PTY session.
///
/// `capabilityVerifierSHA256` is a one-way commitment to the private capability. It is safe to
/// persist, but cannot itself authenticate a request. The 32-byte secret is intentionally held by
/// the non-Codable `Phase2DurableShellBrokerCapabilitySecret` value below.
struct Phase2DurableShellBrokerIdentity: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let launchRequest: Phase2DurableShellBrokerLaunchRequest
    let processIdentity: Phase2DurableShellBrokerProcessIdentity
    let createdAt: Date
    let expiresAt: Date
    let nextTranscriptSequence: UInt64
    let capabilityVerifierSHA256: Data

    init(
        schemaVersion: Int = Self.schemaVersion,
        launchRequest: Phase2DurableShellBrokerLaunchRequest,
        processIdentity: Phase2DurableShellBrokerProcessIdentity,
        createdAt: Date,
        expiresAt: Date,
        nextTranscriptSequence: UInt64,
        capabilityVerifierSHA256: Data
    ) {
        self.schemaVersion = schemaVersion
        self.launchRequest = launchRequest
        self.processIdentity = processIdentity
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.nextTranscriptSequence = nextTranscriptSequence
        self.capabilityVerifierSHA256 = capabilityVerifierSHA256
    }

    var brokerIncarnationID: UUID { launchRequest.brokerIncarnationID }
    var sessionID: UUID { launchRequest.sessionID }
    var capabilityID: UUID { launchRequest.capabilityID }

    var isStructurallyValid: Bool {
        schemaVersion == Self.schemaVersion
            && launchRequest.isStructurallyValid
            && processIdentity.isStructurallyValid
            && launchRequest.executablePath == processIdentity.executablePath
            && createdAt >= launchRequest.createdAt
            && expiresAt <= launchRequest.expiresAt
            && expiresAt > createdAt
            && nextTranscriptSequence > 0
            && capabilityVerifierSHA256.count == SHA256.byteCount
    }
}

enum Phase2DurableShellBrokerCapabilitySecretError: Error, Equatable, Sendable {
    case invalidByteCount(actual: Int)
}

/// Non-persistable bearer capability. Deliberately does not conform to Codable or expose bytes.
struct Phase2DurableShellBrokerCapabilitySecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let byteCount = 32

    private let bytes: Data

    init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw Phase2DurableShellBrokerCapabilitySecretError.invalidByteCount(actual: bytes.count)
        }
        self.bytes = bytes
    }

    var description: String { "<redacted ShellBroker capability secret>" }
    var debugDescription: String { description }

    /// Provides scoped access for local secret storage without making the bearer value Codable.
    func withKeychainBytes<Result>(_ body: (Data) throws -> Result) rethrows -> Result {
        try body(bytes)
    }

    func verifier(
        launchRequest: Phase2DurableShellBrokerLaunchRequest,
        processIdentity: Phase2DurableShellBrokerProcessIdentity
    ) -> Data {
        var material = Data("org.macscope.app.phase2.durable-shell-capability-verifier.v1\0".utf8)
        Self.append(launchRequest.brokerIncarnationID.uuidString, to: &material)
        Self.append(launchRequest.sessionID.uuidString, to: &material)
        Self.append(launchRequest.capabilityID.uuidString, to: &material)
        Self.append(launchRequest.requestID.uuidString, to: &material)
        Self.append(processIdentity.processIdentifier, to: &material)
        Self.append(processIdentity.processStartTimeUnixNanoseconds, to: &material)
        Self.append(processIdentity.executablePath, to: &material)
        Self.append(processIdentity.processGroupIdentifier, to: &material)
        Self.append(bytes, to: &material)
        return Data(SHA256.hash(data: material))
    }

    func authenticationRequest(for identity: Phase2DurableShellBrokerIdentity) -> Phase2DurableShellBrokerAuthenticationRequest {
        Phase2DurableShellBrokerAuthenticationRequest(
            brokerIncarnationID: identity.brokerIncarnationID,
            sessionID: identity.sessionID,
            capabilityID: identity.capabilityID,
            capabilitySecret: self
        )
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: String, to data: inout Data) {
        append(Data(value.utf8), to: &data)
    }

    private static func append(_ value: Data, to data: inout Data) {
        append(UInt64(value.count), to: &data)
        data.append(value)
    }
}

/// Ephemeral authentication input. Its lack of Codable conformance prevents accidental persistence.
struct Phase2DurableShellBrokerAuthenticationRequest: Equatable, Sendable {
    let brokerIncarnationID: UUID
    let sessionID: UUID
    let capabilityID: UUID
    let capabilitySecret: Phase2DurableShellBrokerCapabilitySecret
}

enum Phase2DurableShellBrokerAuthenticationIssue: Equatable, Sendable {
    case invalidIdentity
    case brokerIncarnationMismatch
    case sessionMismatch
    case capabilityMismatch
    case expired
    case capabilityVerifierMismatch
}

struct Phase2DurableShellBrokerAuthenticationResult: Equatable, Sendable {
    let issues: [Phase2DurableShellBrokerAuthenticationIssue]

    var isAuthenticated: Bool { issues.isEmpty }
}

enum Phase2DurableShellBrokerAuthenticator {
    static func validate(
        _ request: Phase2DurableShellBrokerAuthenticationRequest,
        identity: Phase2DurableShellBrokerIdentity,
        now: Date
    ) -> Phase2DurableShellBrokerAuthenticationResult {
        var issues: [Phase2DurableShellBrokerAuthenticationIssue] = []
        if !identity.isStructurallyValid { issues.append(.invalidIdentity) }
        if request.brokerIncarnationID != identity.brokerIncarnationID { issues.append(.brokerIncarnationMismatch) }
        if request.sessionID != identity.sessionID { issues.append(.sessionMismatch) }
        if request.capabilityID != identity.capabilityID { issues.append(.capabilityMismatch) }
        if now >= identity.expiresAt { issues.append(.expired) }

        let candidate = request.capabilitySecret.verifier(
            launchRequest: identity.launchRequest,
            processIdentity: identity.processIdentity
        )
        if !constantTimeEqual(candidate, identity.capabilityVerifierSHA256) {
            issues.append(.capabilityVerifierMismatch)
        }
        return Phase2DurableShellBrokerAuthenticationResult(issues: issues)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let maximumCount = max(lhs.count, rhs.count)
        var difference = UInt64(lhs.count ^ rhs.count)
        for index in 0..<maximumCount {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= UInt64(left ^ right)
        }
        return difference == 0
    }
}
