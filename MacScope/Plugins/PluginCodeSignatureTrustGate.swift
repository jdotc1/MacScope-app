import Foundation
import Security

/// Bridges a cryptographic `PluginCodeSignatureVerdict` into the registry's
/// existing `PluginTrustDecision` model and gates loading on the verdict.
///
/// Previously the plugin registry trusted whatever `PluginProvenance` the
/// manifest *declared* (its `signatureState` / `teamIdentifier`) — i.e. trust
/// was metadata-asserted and never cryptographically verified. This gate makes
/// the on-disk code signature the source of truth: an untrusted verdict yields a
/// typed error and the plugin does not load, regardless of what the manifest
/// claims.
struct PluginCodeSignatureTrustGate {
    /// Policy controlling which verdicts are permitted to load. Mirrors the
    /// existing `PluginProvenancePolicy` philosophy (bundled/development relaxations).
    struct Policy: Hashable {
        /// Require a cryptographically valid signature for third-party plugins.
        var requireValidSignatureForThirdParty: Bool
        /// Allow unsigned plugins whose declared distribution is `bundled`.
        var allowUnsignedBundled: Bool
        /// Allow unsigned plugins whose declared distribution is `developer`.
        var allowUnsignedDeveloper: Bool
        /// When set, the verified team identifier must be in this allow-list for
        /// the plugin to be trusted. Empty set means "no team pinning".
        var pinnedTeamIdentifiers: Set<String>

        static let strict = Policy(
            requireValidSignatureForThirdParty: true,
            allowUnsignedBundled: true,
            allowUnsignedDeveloper: false,
            pinnedTeamIdentifiers: []
        )

        init(
            requireValidSignatureForThirdParty: Bool = true,
            allowUnsignedBundled: Bool = true,
            allowUnsignedDeveloper: Bool = false,
            pinnedTeamIdentifiers: Set<String> = []
        ) {
            self.requireValidSignatureForThirdParty = requireValidSignatureForThirdParty
            self.allowUnsignedBundled = allowUnsignedBundled
            self.allowUnsignedDeveloper = allowUnsignedDeveloper
            self.pinnedTeamIdentifiers = pinnedTeamIdentifiers
        }
    }

    var verifier: PluginCodeSignatureVerifying
    var policy: Policy

    init(
        verifier: PluginCodeSignatureVerifying,
        policy: Policy = .strict
    ) {
        self.verifier = verifier
        self.policy = policy
    }

    /// Evaluate the code signature at `codeURL` for a plugin whose manifest
    /// declares `distribution`, and produce a typed verdict assessment.
    ///
    /// Returns a `PluginCodeSignatureTrustVerdict` carrying both the raw
    /// signature verdict and whether the gate permits loading. This is the
    /// non-throwing surface used for diagnostics/UI.
    func evaluate(
        codeURL: URL,
        distribution: PluginDistributionChannel
    ) throws -> PluginCodeSignatureTrustVerdict {
        let signatureVerdict = try verifier.verify(at: codeURL)
        return assess(
            signatureVerdict: signatureVerdict,
            distribution: distribution
        )
    }

    /// Pure decision logic over an already-computed signature verdict — fully
    /// unit-testable without the live Security framework.
    func assess(
        signatureVerdict: PluginCodeSignatureVerdict,
        distribution: PluginDistributionChannel
    ) -> PluginCodeSignatureTrustVerdict {
        switch signatureVerdict {
        case .invalid(let status, let message):
            return PluginCodeSignatureTrustVerdict(
                signatureVerdict: signatureVerdict,
                isPermittedToLoad: false,
                rejection: .invalidSignature(status: status, message: message)
            )

        case .unsigned:
            let allowed: Bool
            switch distribution {
            case .bundled:
                allowed = policy.allowUnsignedBundled
            case .developer:
                allowed = policy.allowUnsignedDeveloper
            case .thirdParty:
                allowed = !policy.requireValidSignatureForThirdParty
            case .unknown:
                allowed = false
            }
            return PluginCodeSignatureTrustVerdict(
                signatureVerdict: signatureVerdict,
                isPermittedToLoad: allowed,
                rejection: allowed ? nil : .unsignedNotPermitted(distribution: distribution)
            )

        case .signedAndValid(let identity):
            if !policy.pinnedTeamIdentifiers.isEmpty {
                guard let team = identity.teamIdentifier,
                      policy.pinnedTeamIdentifiers.contains(team) else {
                    return PluginCodeSignatureTrustVerdict(
                        signatureVerdict: signatureVerdict,
                        isPermittedToLoad: false,
                        rejection: .teamIdentifierNotPinned(
                            observed: identity.teamIdentifier
                        )
                    )
                }
            }
            return PluginCodeSignatureTrustVerdict(
                signatureVerdict: signatureVerdict,
                isPermittedToLoad: true,
                rejection: nil
            )
        }
    }

    /// Gate loading: throws `PluginCodeSignatureTrustError` if the verified
    /// signature is not permitted to load. On success returns the verified
    /// signing identity (if any) so the caller can fold it into provenance.
    func gateLoading(
        codeURL: URL,
        identifier: String,
        distribution: PluginDistributionChannel
    ) throws -> PluginSigningIdentity? {
        let verdict = try evaluate(codeURL: codeURL, distribution: distribution)
        guard verdict.isPermittedToLoad else {
            throw PluginCodeSignatureTrustError(
                identifier: identifier,
                rejection: verdict.rejection ?? .unsignedNotPermitted(distribution: distribution)
            )
        }
        return verdict.signatureVerdict.signingIdentity
    }
}

/// The result of gating a plugin's code signature: the raw verdict plus whether
/// the policy permits loading and, if not, why.
struct PluginCodeSignatureTrustVerdict: Hashable {
    var signatureVerdict: PluginCodeSignatureVerdict
    var isPermittedToLoad: Bool
    var rejection: PluginCodeSignatureRejection?
}

/// Why a verified signature was rejected by the trust gate.
enum PluginCodeSignatureRejection: Hashable {
    case invalidSignature(status: OSStatus, message: String)
    case unsignedNotPermitted(distribution: PluginDistributionChannel)
    case teamIdentifierNotPinned(observed: String?)

    var auditMessage: String {
        switch self {
        case .invalidSignature(let status, let message):
            "code signature is invalid (OSStatus \(status)): \(message)"
        case .unsignedNotPermitted(let distribution):
            "plugin is unsigned and \(distribution.rawValue) distribution does not permit unsigned code"
        case .teamIdentifierNotPinned(let observed):
            "plugin team identifier \(observed ?? "<none>") is not in the pinned allow-list"
        }
    }
}

/// Typed error raised when the trust gate refuses to load a plugin because of
/// its code signature.
struct PluginCodeSignatureTrustError: Error, Equatable, LocalizedError {
    var identifier: String
    var rejection: PluginCodeSignatureRejection

    var errorDescription: String? {
        "Plugin \(identifier) failed code-signature trust: \(rejection.auditMessage)"
    }
}
