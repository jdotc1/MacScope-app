import XCTest
@testable import MacScope

/// A fake verifier returning a scripted verdict (or throwing) so the gate's
/// decision logic is exercised without the live Security framework.
private final class FakeSignatureVerifier: PluginCodeSignatureVerifying {
    enum Outcome {
        case verdict(PluginCodeSignatureVerdict)
        case error(Error)
    }

    var outcome: Outcome
    private(set) var verifiedURLs: [URL] = []

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func verify(at url: URL) throws -> PluginCodeSignatureVerdict {
        verifiedURLs.append(url)
        switch outcome {
        case .verdict(let verdict):
            return verdict
        case .error(let error):
            throw error
        }
    }
}

final class PluginCodeSignatureTrustTests: XCTestCase {
    private let codeURL = URL(fileURLWithPath: "/tmp/plugin.bundle")

    private func signedIdentity(
        team: String? = "ABCDE12345",
        signing: String = "com.example.plugin"
    ) -> PluginSigningIdentity {
        PluginSigningIdentity(
            signingIdentifier: signing,
            teamIdentifier: team,
            certificateCommonName: "Developer ID Application: Example",
            isAdHoc: false
        )
    }

    // MARK: Verdict mapping through the fake

    func testSignedAndValidThirdPartyIsPermitted() throws {
        let gate = PluginCodeSignatureTrustGate(
            verifier: FakeSignatureVerifier(
                .verdict(.signedAndValid(signedIdentity()))
            ),
            policy: .strict
        )

        let verdict = try gate.evaluate(codeURL: codeURL, distribution: .thirdParty)
        XCTAssertTrue(verdict.isPermittedToLoad)
        XCTAssertNil(verdict.rejection)
        XCTAssertEqual(verdict.signatureVerdict.signingIdentity?.teamIdentifier, "ABCDE12345")
    }

    func testUnsignedThirdPartyIsRejectedUnderStrictPolicy() throws {
        let gate = PluginCodeSignatureTrustGate(
            verifier: FakeSignatureVerifier(.verdict(.unsigned)),
            policy: .strict
        )

        let verdict = try gate.evaluate(codeURL: codeURL, distribution: .thirdParty)
        XCTAssertFalse(verdict.isPermittedToLoad)
        XCTAssertEqual(
            verdict.rejection,
            .unsignedNotPermitted(distribution: .thirdParty)
        )
    }

    func testUnsignedBundledIsPermittedByDefault() throws {
        let gate = PluginCodeSignatureTrustGate(
            verifier: FakeSignatureVerifier(.verdict(.unsigned)),
            policy: .strict
        )

        let verdict = try gate.evaluate(codeURL: codeURL, distribution: .bundled)
        XCTAssertTrue(verdict.isPermittedToLoad)
    }

    func testUnsignedDeveloperRejectedUnlessPolicyAllows() throws {
        let strict = PluginCodeSignatureTrustGate(
            verifier: FakeSignatureVerifier(.verdict(.unsigned)),
            policy: .strict
        )
        XCTAssertFalse(
            try strict.evaluate(codeURL: codeURL, distribution: .developer).isPermittedToLoad
        )

        let relaxed = PluginCodeSignatureTrustGate(
            verifier: FakeSignatureVerifier(.verdict(.unsigned)),
            policy: .init(allowUnsignedDeveloper: true)
        )
        XCTAssertTrue(
            try relaxed.evaluate(codeURL: codeURL, distribution: .developer).isPermittedToLoad
        )
    }

    func testInvalidSignatureIsAlwaysRejected() throws {
        let gate = PluginCodeSignatureTrustGate(
            verifier: FakeSignatureVerifier(
                .verdict(.invalid(status: -67030, message: "code object is not signed at all"))
            ),
            policy: .init(allowUnsignedBundled: true)
        )

        // Even bundled distribution cannot rescue an *invalid* (tampered) signature.
        let verdict = try gate.evaluate(codeURL: codeURL, distribution: .bundled)
        XCTAssertFalse(verdict.isPermittedToLoad)
        if case .invalidSignature(let status, _)? = verdict.rejection {
            XCTAssertEqual(status, -67030)
        } else {
            XCTFail("expected invalidSignature rejection, got \(String(describing: verdict.rejection))")
        }
    }

    func testTeamIdentifierPinningRejectsWrongTeam() {
        let gate = PluginCodeSignatureTrustGate(
            verifier: FakeSignatureVerifier(
                .verdict(.signedAndValid(signedIdentity(team: "WRONG00000")))
            ),
            policy: .init(pinnedTeamIdentifiers: ["ABCDE12345"])
        )

        let verdict = gate.assess(
            signatureVerdict: .signedAndValid(signedIdentity(team: "WRONG00000")),
            distribution: .thirdParty
        )
        XCTAssertFalse(verdict.isPermittedToLoad)
        XCTAssertEqual(verdict.rejection, .teamIdentifierNotPinned(observed: "WRONG00000"))
    }

    func testTeamIdentifierPinningAcceptsAllowedTeam() {
        let gate = PluginCodeSignatureTrustGate(
            verifier: FakeSignatureVerifier(.verdict(.unsigned)),
            policy: .init(pinnedTeamIdentifiers: ["ABCDE12345"])
        )
        let verdict = gate.assess(
            signatureVerdict: .signedAndValid(signedIdentity(team: "ABCDE12345")),
            distribution: .thirdParty
        )
        XCTAssertTrue(verdict.isPermittedToLoad)
    }

    // MARK: gateLoading throws / returns identity

    func testGateLoadingThrowsTypedErrorForUntrusted() {
        let gate = PluginCodeSignatureTrustGate(
            verifier: FakeSignatureVerifier(.verdict(.unsigned)),
            policy: .strict
        )

        XCTAssertThrowsError(
            try gate.gateLoading(
                codeURL: codeURL,
                identifier: "com.example.plugin",
                distribution: .thirdParty
            )
        ) { error in
            guard let trustError = error as? PluginCodeSignatureTrustError else {
                return XCTFail("expected PluginCodeSignatureTrustError, got \(error)")
            }
            XCTAssertEqual(trustError.identifier, "com.example.plugin")
            XCTAssertEqual(
                trustError.rejection,
                .unsignedNotPermitted(distribution: .thirdParty)
            )
        }
    }

    func testGateLoadingReturnsObservedIdentityWhenTrusted() throws {
        let gate = PluginCodeSignatureTrustGate(
            verifier: FakeSignatureVerifier(
                .verdict(.signedAndValid(signedIdentity()))
            ),
            policy: .strict
        )

        let identity = try gate.gateLoading(
            codeURL: codeURL,
            identifier: "com.example.plugin",
            distribution: .thirdParty
        )
        XCTAssertEqual(identity?.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(identity?.signingIdentifier, "com.example.plugin")
    }

    // MARK: Registry gating

    private func makeManifest(
        execution: PluginExecutionMode = .external,
        entryPoint: String?,
        distribution: PluginDistributionChannel = .thirdParty
    ) -> PluginManifest {
        PluginManifest(
            identifier: "com.example.plugin",
            displayName: "Example",
            version: "1.0.0",
            sdkVersion: "0.1",
            minHostVersion: "0.1.0",
            execution: execution,
            entryPoint: entryPoint,
            principalClass: nil,
            architectures: ["arm64"],
            capabilities: [.workspaceRead],
            permissions: .restricted,
            provenance: PluginProvenance(
                distribution: distribution,
                signatureState: .signed,
                teamIdentifier: "DECLARED99",
                signingIdentifier: "declared.id",
                source: "manifest"
            )
        )
    }

    func testRegistryRefusesToLoadUntrustedPlugin() {
        let registry = PluginRegistry()
        let gate = PluginCodeSignatureTrustGate(
            verifier: FakeSignatureVerifier(.verdict(.unsigned)),
            policy: .strict
        )
        let manifest = makeManifest(entryPoint: "/bin/cat")

        XCTAssertThrowsError(
            try registry.validateWithVerifiedSignature(
                manifest,
                codeURL: codeURL,
                trustGate: gate,
                trustDecision: .allowExternal
            )
        ) { error in
            XCTAssertTrue(error is PluginCodeSignatureTrustError, "got \(error)")
        }
    }

    func testRegistryFoldsObservedIdentityIntoProvenanceWhenTrusted() throws {
        let registry = PluginRegistry()
        let gate = PluginCodeSignatureTrustGate(
            verifier: FakeSignatureVerifier(
                .verdict(.signedAndValid(signedIdentity(team: "OBSERVED11", signing: "observed.id")))
            ),
            policy: .strict
        )
        let manifest = makeManifest(entryPoint: "/bin/cat")

        let descriptor = try registry.validateWithVerifiedSignature(
            manifest,
            codeURL: codeURL,
            trustGate: gate,
            trustDecision: .allowExternal
        )

        // The descriptor reflects the *observed* identity, overriding the manifest's claim.
        XCTAssertEqual(descriptor.manifest.provenance.teamIdentifier, "OBSERVED11")
        XCTAssertEqual(descriptor.manifest.provenance.signingIdentifier, "observed.id")
        XCTAssertEqual(descriptor.manifest.provenance.signatureState, .signed)
    }

    func testCodeURLResolvesAbsoluteAndRelativeEntryPoints() {
        let manifestURL = URL(fileURLWithPath: "/Plugins/example/manifest.json")

        let absolute = makeManifest(entryPoint: "/usr/local/bin/tool")
        XCTAssertEqual(
            PluginRegistry.codeURL(for: absolute, manifestURL: manifestURL)?.path,
            "/usr/local/bin/tool"
        )

        let relative = makeManifest(execution: .xpc, entryPoint: "Example.xpc")
        XCTAssertEqual(
            PluginRegistry.codeURL(for: relative, manifestURL: manifestURL)?.path,
            "/Plugins/example/Example.xpc"
        )

        let none = makeManifest(entryPoint: nil)
        XCTAssertNil(PluginRegistry.codeURL(for: none, manifestURL: manifestURL))
    }

    // MARK: Optional real Security-framework smoke check

    /// Runs the *live* verifier against a known-signed system binary if present.
    /// This is the one path that touches the real Security framework. It is
    /// tolerant of sandbox/CI environments where the binary or signature is
    /// unavailable.
    func testRealVerifierAgainstKnownSignedSystemBinary() throws {
        let candidates = [
            "/bin/ls",
            "/usr/bin/true",
            "/System/Library/CoreServices/Finder.app"
        ]
        guard let path = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) else {
            throw XCTSkip("No known-signed system binary available in this environment.")
        }

        let verifier = SecStaticCodePluginVerifier()
        let verdict: PluginCodeSignatureVerdict
        do {
            verdict = try verifier.verify(at: URL(fileURLWithPath: path))
        } catch {
            throw XCTSkip("Live code-signature verification unavailable: \(error)")
        }

        // macOS system binaries are signed by Apple; the verdict must be trusted,
        // and never .unsigned.
        switch verdict {
        case .signedAndValid:
            XCTAssertTrue(verdict.isTrusted)
        case .invalid, .unsigned:
            XCTFail("Expected a known-signed system binary to verify as signed-and-valid, got \(verdict)")
        }
    }
}
