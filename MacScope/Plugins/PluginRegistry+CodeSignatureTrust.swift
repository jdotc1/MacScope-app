import Foundation

/// Verified-trust loading for the plugin registry.
///
/// `PluginRegistry.validate(...)` historically consumed only the manifest's
/// *declared* `PluginProvenance` and a host-supplied `PluginTrustDecision`. The
/// signing state in the manifest was never checked against the on-disk code
/// signature. These APIs add a real cryptographic gate: before producing a
/// descriptor, the registry runs the executable through a
/// `PluginCodeSignatureTrustGate` and refuses to produce a launch-ready
/// descriptor when the verified signature is untrusted.
extension PluginRegistry {
    /// Validate a manifest AND gate it on the cryptographic code signature of its
    /// executable. On success the returned descriptor's provenance is updated to
    /// reflect the *observed* signing identity (not merely the declared one).
    ///
    /// - Throws: `PluginCodeSignatureTrustError` if the signature is untrusted,
    ///   or any error from `validate(_:)`.
    func validateWithVerifiedSignature(
        _ manifest: PluginManifest,
        codeURL: URL,
        trustGate: PluginCodeSignatureTrustGate,
        manifestURL: URL = URL(fileURLWithPath: "/dev/null"),
        trustDecision: PluginTrustDecision,
        manifestHash: String? = nil
    ) throws -> PluginDescriptor {
        let observedIdentity = try trustGate.gateLoading(
            codeURL: codeURL,
            identifier: manifest.identifier,
            distribution: manifest.provenance.distribution
        )

        var verifiedManifest = manifest
        if let observedIdentity {
            verifiedManifest.provenance = Self.fold(
                identity: observedIdentity,
                into: manifest.provenance
            )
        }

        return try validate(
            verifiedManifest,
            manifestURL: manifestURL,
            trustDecision: trustDecision,
            manifestHash: manifestHash
        )
    }

    /// Resolve the executable URL the registry should verify for `manifest`.
    /// External plugins point at an absolute `entryPoint`; bundle-relative
    /// XPC/in-process plugins resolve relative to the manifest directory.
    static func codeURL(
        for manifest: PluginManifest,
        manifestURL: URL
    ) -> URL? {
        guard let entryPoint = manifest.entryPoint, !entryPoint.isEmpty else {
            return nil
        }

        if entryPoint.hasPrefix("/") {
            return URL(fileURLWithPath: entryPoint).standardizedFileURL
        }

        return manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(entryPoint)
            .standardizedFileURL
    }

    /// Fold an observed signing identity into a declared provenance so the rest
    /// of the registry sees the cryptographically-verified state rather than the
    /// manifest's claim. Declared distribution is preserved; signature state and
    /// signing identifiers are overwritten with the observed values.
    static func fold(
        identity: PluginSigningIdentity,
        into provenance: PluginProvenance
    ) -> PluginProvenance {
        var updated = provenance
        updated.signatureState = identity.observedSignatureState
        if let team = identity.teamIdentifier, !team.isEmpty {
            updated.teamIdentifier = team
        }
        if let signing = identity.signingIdentifier, !signing.isEmpty {
            updated.signingIdentifier = signing
        }
        return updated
    }
}
