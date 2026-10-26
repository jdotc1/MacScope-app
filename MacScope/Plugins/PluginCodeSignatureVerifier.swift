import Foundation
import Security

/// The outcome of cryptographically verifying a plugin bundle/executable's code
/// signature. This replaces the previous metadata-asserted trust model where
/// `PluginProvenance` simply *declared* a signing state that was never checked
/// against the on-disk Mach-O signature.
///
/// The verdict is deliberately a small, exhaustive enum so the trust-decision
/// logic in the registry can switch on it without consulting the live Security
/// framework. The Security-framework calls live behind
/// `PluginCodeSignatureVerifying` so the decision logic stays unit-testable with
/// a fake.
enum PluginCodeSignatureVerdict: Hashable {
    /// The code is signed and `SecStaticCodeCheckValidity` succeeded. The
    /// extracted signing identity is carried alongside so the registry can apply
    /// team-identifier / signing-identifier policy.
    case signedAndValid(PluginSigningIdentity)
    /// The code carries no signature at all (`errSecCSUnsigned`).
    case unsigned
    /// The code is signed but failed validity (revoked, tampered, expired,
    /// requirement mismatch, ...). `status` is the raw `OSStatus` and `message`
    /// a human-readable description for audit logging.
    case invalid(status: OSStatus, message: String)

    var isTrusted: Bool {
        if case .signedAndValid = self { return true }
        return false
    }

    /// The signing identity when the verdict is `signedAndValid`, else `nil`.
    var signingIdentity: PluginSigningIdentity? {
        if case .signedAndValid(let identity) = self { return identity }
        return nil
    }
}

/// The signing identity extracted from a valid signature via
/// `SecCodeCopySigningInformation`. All fields are optional because ad-hoc and
/// self-signed code can be valid yet lack a team identifier or a certificate
/// chain.
struct PluginSigningIdentity: Hashable {
    /// The designated requirement / signing identifier (`kSecCodeInfoIdentifier`).
    var signingIdentifier: String?
    /// The Apple team identifier (`kSecCodeInfoTeamIdentifier`).
    var teamIdentifier: String?
    /// The leaf certificate common name, when a certificate chain is present.
    var certificateCommonName: String?
    /// Whether the signature is ad-hoc (no signing identity / certificate chain).
    var isAdHoc: Bool

    static let unknown = PluginSigningIdentity(
        signingIdentifier: nil,
        teamIdentifier: nil,
        certificateCommonName: nil,
        isAdHoc: false
    )

    /// Maps the cryptographically-observed identity onto the manifest-facing
    /// `PluginSignatureState` so the rest of the registry (which already speaks
    /// that vocabulary) can consume it without a new type everywhere.
    var observedSignatureState: PluginSignatureState {
        if isAdHoc {
            return .adHoc
        }
        if teamIdentifier?.isEmpty == false || certificateCommonName?.isEmpty == false {
            return .signed
        }
        return .signed
    }
}

/// A small protocol wrapping the live Security-framework verification so the
/// registry's trust-decision logic can be exercised with a fake verifier.
protocol PluginCodeSignatureVerifying {
    /// Verify the code signature of the bundle or executable at `url` and return
    /// a typed verdict. Implementations MUST NOT throw for an unsigned or invalid
    /// signature — those are normal verdicts, not errors. Throwing is reserved
    /// for situations where verification could not even be attempted (e.g. the
    /// path does not exist).
    func verify(at url: URL) throws -> PluginCodeSignatureVerdict
}

/// Errors that prevent a verification *attempt* from being made at all. A failed
/// or absent signature is NOT one of these — those are returned as verdicts.
enum PluginCodeSignatureVerificationError: Error, Equatable, LocalizedError {
    case staticCodeCreationFailed(status: OSStatus)
    case pathDoesNotExist(String)

    var errorDescription: String? {
        switch self {
        case .staticCodeCreationFailed(let status):
            "Could not create a SecStaticCode object for the plugin (OSStatus \(status))."
        case .pathDoesNotExist(let path):
            "Plugin code-signature target does not exist: \(path)"
        }
    }
}

/// The production verifier. Uses `SecStaticCodeCreateWithPath` +
/// `SecStaticCodeCheckValidity` to validate the signature, and
/// `SecCodeCopySigningInformation` to extract the signing identity.
///
/// Note: this object touches the live Security framework, so it has no unit
/// tests of its own beyond an optional "known-signed system binary" smoke check.
/// The decision logic that *consumes* its verdicts is tested with the fake.
struct SecStaticCodePluginVerifier: PluginCodeSignatureVerifying {
    /// The validity flags passed to `SecStaticCodeCheckValidity`. Defaults to a
    /// strict check; callers can relax (e.g. for development) by constructing
    /// with a different flag set.
    var validityFlags: SecCSFlags

    init(validityFlags: SecCSFlags = []) {
        self.validityFlags = validityFlags
    }

    func verify(at url: URL) throws -> PluginCodeSignatureVerdict {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PluginCodeSignatureVerificationError.pathDoesNotExist(url.path)
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let code = staticCode else {
            throw PluginCodeSignatureVerificationError.staticCodeCreationFailed(
                status: createStatus
            )
        }

        let validity = SecStaticCodeCheckValidity(code, validityFlags, nil)
        switch validity {
        case errSecSuccess:
            let identity = Self.signingIdentity(for: code)
            return .signedAndValid(identity)
        case errSecCSUnsigned:
            return .unsigned
        default:
            let message = SecCopyErrorMessageString(validity, nil) as String?
            return .invalid(
                status: validity,
                message: message ?? "Code signature is invalid (OSStatus \(validity))."
            )
        }
    }

    /// Extract the signing identity from a verified `SecStaticCode` via
    /// `SecCodeCopySigningInformation`. Best-effort: any missing field degrades
    /// to `nil` rather than throwing.
    static func signingIdentity(for code: SecStaticCode) -> PluginSigningIdentity {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        let status = SecCodeCopySigningInformation(code, flags, &information)
        guard status == errSecSuccess,
              let info = information as? [String: Any] else {
            return .unknown
        }

        let signingIdentifier = info[kSecCodeInfoIdentifier as String] as? String
        let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String

        // `kSecCodeInfoFlags` carries the ad-hoc bit. The CSCommon constant
        // `kSecCodeSignatureAdhoc` (0x0002) is a CF_OPTIONS member that is not
        // surfaced into Swift scope, so we reference its documented raw value.
        // The flags value bridges from a CFNumber to NSNumber.
        let adHocFlag: UInt32 = 0x0002 // kSecCodeSignatureAdhoc
        var isAdHoc = false
        if let flagsNumber = info[kSecCodeInfoFlags as String] as? NSNumber {
            let rawFlags = flagsNumber.uint32Value
            isAdHoc = (rawFlags & adHocFlag) != 0
        }

        var certificateCommonName: String?
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first {
            var commonName: CFString?
            if SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess {
                certificateCommonName = commonName as String?
            }
        }

        return PluginSigningIdentity(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            certificateCommonName: certificateCommonName,
            isAdHoc: isAdHoc
        )
    }
}
