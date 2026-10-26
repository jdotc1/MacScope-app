import CryptoKit
import Foundation

struct DebuggerProcessStartIdentity: Hashable, Sendable {
    let seconds: UInt64
    let microseconds: UInt32

    init?(seconds: UInt64, microseconds: UInt32) {
        guard seconds > 0, microseconds < 1_000_000 else { return nil }
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

enum DebuggerLocalProcessArchitecture: Hashable, Sendable {
    case arm64
    case arm64e
}

struct DebuggerLocalCodeIdentity: Hashable, Sendable {
    let signingIdentifier: String?
    let teamIdentifier: String?
    let codeDirectorySHA256: String?
    let isPlatformBinary: Bool?
    let signingFlags: UInt32?

    init?(
        signingIdentifier: String?,
        teamIdentifier: String?,
        codeDirectorySHA256: String?,
        isPlatformBinary: Bool?,
        signingFlags: UInt32?
    ) {
        guard Self.isValidOptionalIdentifier(signingIdentifier, maximumUTF8Count: 1_024),
              Self.isValidOptionalIdentifier(teamIdentifier, maximumUTF8Count: 256),
              codeDirectorySHA256.map(DebuggerLocalProcessIdentity.isValidSHA256) ?? true,
              signingIdentifier != nil || teamIdentifier != nil || codeDirectorySHA256 != nil
                || isPlatformBinary != nil || signingFlags != nil else {
            return nil
        }
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.codeDirectorySHA256 = codeDirectorySHA256
        self.isPlatformBinary = isPlatformBinary
        self.signingFlags = signingFlags
    }

    private static func isValidOptionalIdentifier(
        _ value: String?,
        maximumUTF8Count: Int
    ) -> Bool {
        guard let value else { return true }
        return !value.isEmpty
            && value.utf8.count <= maximumUTF8Count
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

struct DebuggerLocalProcessIdentityDigest: Hashable, Sendable {
    let lowercaseHex: String

    fileprivate init(uncheckedLowercaseHex: String) {
        lowercaseHex = uncheckedLowercaseHex
    }
}

struct DebuggerLocalProcessIdentity: Hashable, Sendable {
    let processID: Int32
    let startTime: DebuggerProcessStartIdentity
    let realUserID: UInt32
    let effectiveUserID: UInt32
    let canonicalExecutablePath: String
    let executableDeviceID: UInt64
    let executableFileID: UInt64
    let executableByteCount: UInt64
    let executableSHA256: String
    let architecture: DebuggerLocalProcessArchitecture
    let machOUUID: UUID?
    let codeIdentity: DebuggerLocalCodeIdentity?

    init?(
        processID: Int32,
        startTime: DebuggerProcessStartIdentity,
        realUserID: UInt32,
        effectiveUserID: UInt32,
        canonicalExecutablePath: String,
        executableDeviceID: UInt64,
        executableFileID: UInt64,
        executableByteCount: UInt64,
        executableSHA256: String,
        architecture: DebuggerLocalProcessArchitecture,
        machOUUID: UUID?,
        codeIdentity: DebuggerLocalCodeIdentity?
    ) {
        guard processID > 0,
              Self.isValidCanonicalPath(canonicalExecutablePath),
              executableDeviceID > 0,
              executableFileID > 0,
              executableByteCount > 0,
              Self.isValidSHA256(executableSHA256) else {
            return nil
        }
        self.processID = processID
        self.startTime = startTime
        self.realUserID = realUserID
        self.effectiveUserID = effectiveUserID
        self.canonicalExecutablePath = canonicalExecutablePath
        self.executableDeviceID = executableDeviceID
        self.executableFileID = executableFileID
        self.executableByteCount = executableByteCount
        self.executableSHA256 = executableSHA256
        self.architecture = architecture
        self.machOUUID = machOUUID
        self.codeIdentity = codeIdentity
    }

    var identityDigest: DebuggerLocalProcessIdentityDigest {
        var material = Data()
        material.appendLengthFramed(String(processID))
        material.appendLengthFramed(String(startTime.seconds))
        material.appendLengthFramed(String(startTime.microseconds))
        material.appendLengthFramed(String(realUserID))
        material.appendLengthFramed(String(effectiveUserID))
        material.appendLengthFramed(canonicalExecutablePath)
        material.appendLengthFramed(String(executableDeviceID))
        material.appendLengthFramed(String(executableFileID))
        material.appendLengthFramed(String(executableByteCount))
        material.appendLengthFramed(executableSHA256)
        material.appendLengthFramed(architecture == .arm64 ? "arm64" : "arm64e")
        material.appendLengthFramed(machOUUID?.uuidString.lowercased() ?? "")
        material.appendOptionalLengthFramed(codeIdentity?.signingIdentifier)
        material.appendOptionalLengthFramed(codeIdentity?.teamIdentifier)
        material.appendOptionalLengthFramed(codeIdentity?.codeDirectorySHA256)
        material.appendOptionalLengthFramed(codeIdentity?.isPlatformBinary.map { $0 ? "1" : "0" })
        material.appendOptionalLengthFramed(codeIdentity?.signingFlags.map(String.init))
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return DebuggerLocalProcessIdentityDigest(uncheckedLowercaseHex: digest)
    }

    fileprivate static func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    fileprivate static func isValidCanonicalPath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value != "/", value.utf8.count <= 4_096,
              !value.hasSuffix("/"), !value.hasPrefix("//"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        return (value as NSString).standardizingPath == value
    }
}

struct DebuggerLocalProcessCatalogFingerprint: Hashable, Sendable {
    let processID: Int32
    let startTime: DebuggerProcessStartIdentity
    let realUserID: UInt32
    let effectiveUserID: UInt32
    let canonicalExecutablePath: String
    let executableDeviceID: UInt64
    let executableFileID: UInt64
    let executableByteCount: UInt64
    let executableChangeTimeNanoseconds: UInt64
    let architecture: DebuggerLocalProcessArchitecture
    let machOUUID: UUID?
    let codeIdentity: DebuggerLocalCodeIdentity?

    init?(
        processID: Int32,
        startTime: DebuggerProcessStartIdentity,
        realUserID: UInt32,
        effectiveUserID: UInt32,
        canonicalExecutablePath: String,
        executableDeviceID: UInt64,
        executableFileID: UInt64,
        executableByteCount: UInt64,
        executableChangeTimeNanoseconds: UInt64,
        architecture: DebuggerLocalProcessArchitecture,
        machOUUID: UUID?,
        codeIdentity: DebuggerLocalCodeIdentity?
    ) {
        guard processID > 0,
              DebuggerLocalProcessIdentity.isValidCanonicalPath(canonicalExecutablePath),
              executableDeviceID > 0, executableFileID > 0, executableByteCount > 0 else {
            return nil
        }
        self.processID = processID
        self.startTime = startTime
        self.realUserID = realUserID
        self.effectiveUserID = effectiveUserID
        self.canonicalExecutablePath = canonicalExecutablePath
        self.executableDeviceID = executableDeviceID
        self.executableFileID = executableFileID
        self.executableByteCount = executableByteCount
        self.executableChangeTimeNanoseconds = executableChangeTimeNanoseconds
        self.architecture = architecture
        self.machOUUID = machOUUID
        self.codeIdentity = codeIdentity
    }

    func matches(_ identity: DebuggerLocalProcessIdentity) -> Bool {
        processID == identity.processID
            && startTime == identity.startTime
            && realUserID == identity.realUserID
            && effectiveUserID == identity.effectiveUserID
            && canonicalExecutablePath == identity.canonicalExecutablePath
            && executableDeviceID == identity.executableDeviceID
            && executableFileID == identity.executableFileID
            && executableByteCount == identity.executableByteCount
            && architecture == identity.architecture
            && machOUUID == identity.machOUUID
            && codeIdentity == identity.codeIdentity
    }
}

struct DebuggerLocalProcessCatalogSelection: Hashable, Sendable {
    let discoveryGeneration: UInt64
    let fingerprint: DebuggerLocalProcessCatalogFingerprint

    init?(discoveryGeneration: UInt64, fingerprint: DebuggerLocalProcessCatalogFingerprint) {
        guard discoveryGeneration > 0 else { return nil }
        self.discoveryGeneration = discoveryGeneration
        self.fingerprint = fingerprint
    }
}

struct DebuggerLocalProcessAuthorizationGrant: Hashable, Sendable {
    let discoveryGeneration: UInt64
    let fingerprint: DebuggerLocalProcessCatalogFingerprint
    let identity: DebuggerLocalProcessIdentity

    init?(
        discoveryGeneration: UInt64,
        fingerprint: DebuggerLocalProcessCatalogFingerprint,
        authorizationFingerprint: DebuggerLocalProcessCatalogFingerprint,
        identity: DebuggerLocalProcessIdentity
    ) {
        guard discoveryGeneration > 0,
              fingerprint == authorizationFingerprint,
              authorizationFingerprint.matches(identity) else {
            return nil
        }
        self.discoveryGeneration = discoveryGeneration
        self.fingerprint = fingerprint
        self.identity = identity
    }
}

/// The sole immutable authority admitted to the attach transport boundary. Discovery generation,
/// catalog fingerprints, UI selection, and user-entered PID text deliberately do not cross it.
struct DebuggerLocalAttachRequest: Hashable, Sendable {
    let selectedIdentity: DebuggerLocalProcessIdentity

    init(selectedIdentity: DebuggerLocalProcessIdentity) {
        self.selectedIdentity = selectedIdentity
    }
}

enum DebuggerLocalAttachDenial: Hashable, Sendable {
    case disappeared
    case identityChanged
    case unstableSnapshot
    case metadataAccessDenied
    case selfOrOwnedInfrastructure
    case systemProcess
    case platformProtected
    case differentUser
    case privilegedIdentity
    case alreadyTraced
    case exiting
    case unsupportedArchitecture
    case translatedArchitecture
    case targetDisallowsDebugging
    case developerToolsAuthorizationRequired
    case authorizationDeniedUnclassified
    case observedPIDMissing
    case observedPIDMismatch
    case postAttachIdentityMismatch
    case timeout
    case adapterProtocolFailure
    case detachUnconfirmed
    case targetDispositionUnknown

    var displayReason: String {
        switch self {
        case .disappeared:
            "The process disappeared before it could be authorized."
        case .identityChanged:
            "The process identity changed during authorization."
        case .unstableSnapshot:
            "The process table was unstable; refresh and try again."
        case .metadataAccessDenied:
            "MacScope could not read enough process metadata to prove identity."
        case .selfOrOwnedInfrastructure:
            "MacScope will not attach to itself or one of its owned helper processes."
        case .systemProcess:
            "System processes are not attachable from this surface."
        case .platformProtected:
            "The process is protected by platform security policy."
        case .differentUser:
            "The process belongs to a different user."
        case .privilegedIdentity:
            "The process has a privileged user identity."
        case .alreadyTraced:
            "The process is already being traced."
        case .exiting:
            "The process is already exiting."
        case .unsupportedArchitecture:
            "Only native arm64 or arm64e processes are attachable."
        case .translatedArchitecture:
            "Translated processes are not attachable by this native debugger path."
        case .targetDisallowsDebugging:
            "The target disallows debugging."
        case .developerToolsAuthorizationRequired:
            "Developer Tools authorization is required before attaching."
        case .authorizationDeniedUnclassified:
            "macOS denied attach authorization."
        case .observedPIDMissing:
            "LLDB did not report an observed process ID."
        case .observedPIDMismatch:
            "LLDB observed a different process ID than the authorized target."
        case .postAttachIdentityMismatch:
            "The post-attach identity no longer matches the authorized process."
        case .timeout:
            "Authorization timed out."
        case .adapterProtocolFailure:
            "The LLDB adapter returned an invalid attach response."
        case .detachUnconfirmed:
            "Detach could not be confirmed."
        case .targetDispositionUnknown:
            "The target disposition is unknown."
        }
    }
}

enum DebuggerLocalProcessEligibility: Hashable, Sendable {
    case eligible
    case ineligible(DebuggerLocalAttachDenial)
    case unknown(DebuggerLocalAttachDenial)

    var isAttachable: Bool {
        if case .eligible = self { return true }
        return false
    }

    var denial: DebuggerLocalAttachDenial? {
        switch self {
        case .eligible: nil
        case let .ineligible(denial), let .unknown(denial): denial
        }
    }
}

struct DebuggerLocalProcessInstanceKey: Hashable, Sendable {
    let processID: Int32
    let startTime: DebuggerProcessStartIdentity

    init(identity: DebuggerLocalProcessIdentity) {
        processID = identity.processID
        startTime = identity.startTime
    }
}

struct DebuggerLaunchTargetAuthority: Hashable, Sendable {
    let identity: DebuggerLocalProcessIdentity

    var processID: Int32 { identity.processID }
    var identityDigest: DebuggerLocalProcessIdentityDigest { identity.identityDigest }

    init(identity: DebuggerLocalProcessIdentity) {
        self.identity = identity
    }
}

enum DebuggerSessionTargetOrigin: Hashable, Sendable {
    case launched(DebuggerLaunchTargetAuthority)
    case attached(DebuggerLocalProcessIdentity)
}

struct DebuggerSessionTargetAuthority: Hashable, Sendable {
    let origin: DebuggerSessionTargetOrigin
    let processID: Int32
    let identityDigest: DebuggerLocalProcessIdentityDigest

    init(origin: DebuggerSessionTargetOrigin) {
        self.origin = origin
        switch origin {
        case let .launched(authority):
            processID = authority.processID
            identityDigest = authority.identityDigest
        case let .attached(identity):
            processID = identity.processID
            identityDigest = identity.identityDigest
        }
    }
}

private extension Data {
    mutating func appendLengthFramed(_ value: String) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(bytes)
    }

    mutating func appendOptionalLengthFramed(_ value: String?) {
        append(value == nil ? 0 : 1)
        if let value { appendLengthFramed(value) }
    }
}
