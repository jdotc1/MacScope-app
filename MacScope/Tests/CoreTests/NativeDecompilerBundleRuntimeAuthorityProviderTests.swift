import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacScope

final class NativeDecompilerBundleRuntimeAuthorityProviderTests: XCTestCase {
    func testAttestationAcceptsCurrentReleaseSourceBuiltEvidence() async throws {
        let fixture = try BundleAuthorityFixture(currentReleaseEvidence: true)
        defer { fixture.remove() }
        let provider = NativeDecompilerBundleRuntimeAuthorityProvider(
            appBundleURL: fixture.appURL,
            signatureValidator: fixture.validateSignature
        )
        let identity = try await provider.attestRuntimeAuthority()
        XCTAssertEqual(identity.packageManifestSHA256, fixture.manifestSHA256)
        XCTAssertEqual(identity.packageTreeSHA256, fixture.packageTreeSHA256)
        XCTAssertEqual(identity.backendID, "ghidra-native-decompiler")
    }

    func testCurrentReleaseRejectsUnknownMalformedAndUnboundEvidence() async throws {
        let mutations: [(String, Any)] = [
            ("unexpected_dependency", "untrusted"),
            ("ghostty_surface_archive_sha256", String(repeating: "A", count: 64)),
            ("ghostty_surface_external_io_abi_version", true),
            ("machokit_analysis_worker_executable_size", 0),
            ("sleigh_materialization_tree_sha256", String(repeating: "0", count: 64)),
            ("native_decompiler_embedded_service_executable_sha256", String(repeating: "0", count: 64)),
        ]
        for (key, value) in mutations {
            let fixture = try BundleAuthorityFixture(
                provenanceOverrides: [key: value], currentReleaseEvidence: true
            )
            defer { fixture.remove() }
            await assertAttestationError(.buildEvidenceInvalid, fixture: fixture, label: key)
        }
    }

    func testLegacyEvidenceRejectsResealedMalformedTargetTriple() async throws {
        for triple in ["arm64-apple-macosx27.2.0\n", "arm64-apple-macosx27.2.0suffix", "arm64-apple-macosx28.0.0"] {
            let fixture = try BundleAuthorityFixture(
                provenanceOverrides: ["swift_target_triple": triple],
                boundGoldenOverrides: ["swiftTargetTriple": triple]
            )
            defer { fixture.remove() }
            await assertAttestationError(.buildEvidenceInvalid, fixture: fixture, label: triple.debugDescription)
        }
    }

    func testSourceBuiltManifestRejectsResealedContractDrift() async throws {
        let mutations: [(String, Any)] = [
            ("unexpected_source", true),
            ("sourceManifestSha256", String(repeating: "0", count: 64)),
            ("buildOptions", ["FETCHCONTENT_FULLY_DISCONNECTED=OFF"]),
            ("toolchain", ["compiler": ["path": "relative", "version": "forged", "sha256": "x"]]),
        ]
        for (key, value) in mutations {
            let fixture = try BundleAuthorityFixture(
                currentReleaseEvidence: true, sourceBuildOverrides: [key: value]
            )
            defer { fixture.remove() }
            await assertAttestationError(.packageManifestInvalid, fixture: fixture, label: key)
        }
    }

    func testAttestationRejectsConsistentlyResealedMissingAppleSiliconResource() async throws {
        let omitted = BundleAuthorityFixture.appleSiliconCriticalPaths[1]
        let fixture = try BundleAuthorityFixture(omittedPackagePaths: [omitted])
        defer { fixture.remove() }

        await assertAttestationError(.packageTreeInvalid, fixture: fixture, label: omitted)
    }

    func testInstalledQualifiedReleaseAttestsExactRuntimeAuthority() async throws {
        let environment = ProcessInfo.processInfo.environment
        let optInSentinel = "/private/tmp/macoscope-f1a-run-installed-authority-test"
        guard environment["MACSCOPE_F1A_RUN_INSTALLED_AUTHORITY_TEST"] == "1"
                || FileManager.default.fileExists(atPath: optInSentinel) else {
            throw XCTSkip("Installed runtime-authority attestation requires explicit F1A opt-in")
        }
        let appURL = URL(
            fileURLWithPath: environment["MACSCOPE_F1A_INSTALLED_APP"] ?? "/Applications/MacScope.app",
            isDirectory: true
        )
        let provider = NativeDecompilerBundleRuntimeAuthorityProvider(appBundleURL: appURL)
        do {
            let identity = try await provider.attestRuntimeAuthority()
            XCTAssertEqual(identity.backendID, "ghidra-native-decompiler")
            XCTAssertEqual(identity.wrapperVersion, "dcp05c-v1")
            XCTAssertEqual(identity.languageID, "AARCH64:LE:64:AppleSilicon")
            XCTAssertEqual(identity.compilerSpecID, "default")
            XCTAssertEqual(identity.targetProfileID, "apple-aarch64-pac-visible-clobber-v1")
        } catch {
            XCTFail("Installed runtime-authority attestation failed: \(error)")
        }
    }

    func testAttestationDerivesIdentityFromIndependentBundlePackageAndBuildEvidence() async throws {
        let fixture = try BundleAuthorityFixture()
        defer { fixture.remove() }
        let inspected = LockedBox<[URL]>([])
        let provider = NativeDecompilerBundleRuntimeAuthorityProvider(
            appBundleURL: fixture.appURL,
            signatureValidator: { serviceURL in
                try fixture.validateSignature(serviceURL)
                inspected.withValue { $0.append(serviceURL) }
            }
        )

        let manifestBytes = try Data(contentsOf: fixture.manifestURL)
        let manifestValue = try Phase2StrictJSONParser().parse(
            manifestBytes,
            limits: .init(
                maximumBytes: manifestBytes.count,
                maximumDepth: 8,
                maximumTokens: 2_048,
                maximumMembersAndElements: 1_024
            )
        )
        var expectedCanonicalManifest = manifestValue.canonicalJSONBytes()
        expectedCanonicalManifest.append(0x0A)
        if manifestBytes != expectedCanonicalManifest {
            let mismatch = zip(manifestBytes, expectedCanonicalManifest)
                .enumerated()
                .first(where: { $0.element.0 != $0.element.1 })?.offset
                ?? min(manifestBytes.count, expectedCanonicalManifest.count)
            XCTFail(
                "manifest canonical mismatch at byte \(mismatch): "
                    + "actual=\(manifestBytes[mismatch]) expected=\(expectedCanonicalManifest[mismatch])"
            )
        }
        let manifestObject = try XCTUnwrap(manifestValue.objectValue)
        let packageObject = try XCTUnwrap(manifestObject["package"]?.objectValue)
        let criticalObject = try XCTUnwrap(packageObject["criticalFileSha256"]?.objectValue)
        for relativePath in BundleAuthorityFixture.criticalPaths {
            let bytes = try Data(
                contentsOf: fixture.packageURL.appendingPathComponent(relativePath)
            )
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(criticalObject[relativePath]?.stringValue, actual, relativePath)
        }

        let identity: NativeDecompilerRuntimeIdentity
        do {
            identity = try await provider.attestRuntimeAuthority()
        } catch let error as NativeDecompilerRuntimeAuthorityAttestationError {
            return XCTFail("attestation failed at \(error)")
        }

        XCTAssertEqual(identity.backendID, "ghidra-native-decompiler")
        XCTAssertEqual(identity.engineVersion, "12.1.2")
        XCTAssertEqual(identity.engineRevision, fixture.engineRevision)
        XCTAssertEqual(identity.wrapperVersion, "dcp05c-v1")
        XCTAssertEqual(identity.wrapperRevision, fixture.wrapperRevision)
        XCTAssertEqual(identity.packageManifestSHA256, fixture.manifestSHA256)
        XCTAssertEqual(identity.packageTreeSHA256, fixture.packageTreeSHA256)
        XCTAssertEqual(identity.languageID, "AARCH64:LE:64:AppleSilicon")
        XCTAssertEqual(identity.compilerSpecID, "default")
        XCTAssertEqual(identity.targetProfileID, "apple-aarch64-pac-visible-clobber-v1")
        XCTAssertEqual(inspected.value, [fixture.serviceURL, fixture.serviceURL])
    }

    func testAttestationRejectsEveryMutatedIdentityFieldWithoutConsultingReply() async throws {
        let mutations: [(String, Any)] = [
            ("backendID", "forged-backend"),
            ("engineVersion", "12.1.3"),
            ("engineGitRevision", String(repeating: "1", count: 40)),
            ("wrapperVersion", "dcp05c-v2"),
            ("wrapperGitRevision", String(repeating: "2", count: 64)),
            ("materializationManifestSHA256", String(repeating: "3", count: 64)),
            ("materializationTreeSHA256", String(repeating: "4", count: 64)),
        ]
        for (key, value) in mutations {
            let fixture = try BundleAuthorityFixture(goldenOverrides: [key: value])
            defer { fixture.remove() }
            let provider = NativeDecompilerBundleRuntimeAuthorityProvider(
                appBundleURL: fixture.appURL,
                signatureValidator: fixture.validateSignature
            )
            do {
                _ = try await provider.attestRuntimeAuthority()
                XCTFail("mutated independent identity field must reject: \(key)")
            } catch let error as NativeDecompilerRuntimeAuthorityAttestationError {
                XCTAssertEqual(error, .buildEvidenceInvalid, key)
            } catch {
                XCTFail("unexpected error for \(key): \(error)")
            }
        }
    }

    func testAttestationRejectsSymlinkHardlinkTopologyAndMetadataRace() async throws {
        let symlinkFixture = try BundleAuthorityFixture()
        defer { symlinkFixture.remove() }
        let original = symlinkFixture.packageURL.appendingPathComponent("lib/libdecomp.a")
        let replacement = symlinkFixture.root.appendingPathComponent("replacement")
        try Data("replacement".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: replacement)
        await assertAttestationError(.bundleTopologyInvalid, fixture: symlinkFixture)

        let hardlinkFixture = try BundleAuthorityFixture()
        defer { hardlinkFixture.remove() }
        let hardlinkSource = hardlinkFixture.packageURL.appendingPathComponent("lib/libsla.a")
        let hardlink = hardlinkFixture.root.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: hardlinkSource, to: hardlink)
        await assertAttestationError(.bundleTopologyInvalid, fixture: hardlinkFixture)
    }

    func testAttestationRejectsPeerRequirementManifestTreeAndCriticalResourceMismatch() async throws {
        let peerFixture = try BundleAuthorityFixture()
        defer { peerFixture.remove() }
        let peerProvider = NativeDecompilerBundleRuntimeAuthorityProvider(
            appBundleURL: peerFixture.appURL,
            signatureValidator: { _ in throw TestError.rejected }
        )
        do {
            _ = try await peerProvider.attestRuntimeAuthority()
            XCTFail("rejected peer requirement must fail closed")
        } catch let error as NativeDecompilerRuntimeAuthorityAttestationError {
            XCTAssertEqual(error, .peerRequirementRejected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let manifestFixture = try BundleAuthorityFixture()
        defer { manifestFixture.remove() }
        var bytes = try Data(contentsOf: manifestFixture.manifestURL)
        bytes.insert(0x20, at: 0)
        try bytes.write(to: manifestFixture.manifestURL)
        await assertAttestationError(.packageManifestInvalid, fixture: manifestFixture)

        let criticalFixture = try BundleAuthorityFixture()
        defer { criticalFixture.remove() }
        try Data("mutated".utf8).write(
            to: criticalFixture.packageURL.appendingPathComponent(
                BundleAuthorityFixture.criticalPaths[0]
            )
        )
        await assertAttestationError(.packageTreeInvalid, fixture: criticalFixture)
    }

    func testAttestationRejectsConsistentlyResealedFalseCriticalDigestClaim() async throws {
        let path = BundleAuthorityFixture.appleSiliconCriticalPaths[0]
        let fixture = try BundleAuthorityFixture(
            criticalDigestOverrides: [path: String(repeating: "0", count: 64)]
        )
        defer { fixture.remove() }

        await assertAttestationError(.packageTreeInvalid, fixture: fixture, label: path)
    }

    func testAttestationAcceptsBoundDebugAndRejectsMutatedProvenanceBindings() async throws {
        let debugFixture = try BundleAuthorityFixture(ineligibleDebugProvenance: true)
        defer { debugFixture.remove() }
        let debugProvider = NativeDecompilerBundleRuntimeAuthorityProvider(
            appBundleURL: debugFixture.appURL,
            signatureValidator: debugFixture.validateSignature
        )
        _ = try await debugProvider.attestRuntimeAuthority()

        let mutations: [(String, Any)] = [
            ("dependency_root_authority", "fixture-self-report"),
            ("ghostty_source_dir_sha256", String(repeating: "0", count: 63)),
            ("sleigh_materialization_root_sha256", String(repeating: "A", count: 64)),
            ("native_decompiler_golden_result", NSNull()),
            ("native_decompiler_golden_result_sha256", String(repeating: "0", count: 64)),
            ("native_decompiler_embedded_manifest_sha256", String(repeating: "1", count: 64)),
            ("native_decompiler_embedded_tree_sha256", String(repeating: "2", count: 64)),
            ("native_decompiler_embedded_decompiler_archive_sha256", String(repeating: "3", count: 64)),
            ("native_decompiler_embedded_sleigh_archive_sha256", String(repeating: "4", count: 64)),
            ("native_decompiler_embedded_service_bundle_identifier", "com.example.forged"),
            ("native_decompiler_embedded_service_info_plist_sha256", String(repeating: "5", count: 64)),
            ("native_decompiler_embedded_service_executable_sha256", String(repeating: "6", count: 64)),
            ("native_decompiler_embedded_service_code_resources_sha256", String(repeating: "7", count: 64)),
        ]
        for (key, value) in mutations {
            let fixture = try BundleAuthorityFixture(provenanceOverrides: [key: value])
            defer { fixture.remove() }
            await assertAttestationError(.buildEvidenceInvalid, fixture: fixture, label: key)
        }
    }

    func testDebugAttestationAcceptsCompleteSourceIdentityWithoutReleaseEligibility() async throws {
        let fixture = try BundleAuthorityFixture(provenanceOverrides: [
            "git_head_commit": String(repeating: "1", count: 40),
            "git_head_tree": String(repeating: "2", count: 40),
            "selected_build_inputs_sha256": String(repeating: "3", count: 64),
        ], ineligibleDebugProvenance: true)
        defer { fixture.remove() }
        let identity = try await NativeDecompilerBundleRuntimeAuthorityProvider(
            appBundleURL: fixture.appURL, signatureValidator: fixture.validateSignature
        ).attestRuntimeAuthority()
        XCTAssertEqual(identity.packageManifestSHA256, fixture.manifestSHA256)
        XCTAssertEqual(identity.packageTreeSHA256, fixture.packageTreeSHA256)
    }

    func testDebugAttestationRejectsPartialMalformedAndReleaseQualificationSourceEvidence() async throws {
        let keys = ["git_head_commit", "git_head_tree", "selected_build_inputs_sha256"]
        let values = [String(repeating: "1", count: 40), String(repeating: "2", count: 40),
            String(repeating: "3", count: 64)]
        var mutations: [[String: Any]] = []
        for mask in 1...6 {
            var partial: [String: Any] = [:]
            for index in keys.indices where mask & (1 << index) != 0 {
                partial[keys[index]] = values[index]
            }
            mutations.append(partial)
        }
        let complete: [String: Any] = Dictionary(uniqueKeysWithValues: zip(keys, values).map { entry in
            (entry.0, entry.1 as Any)
        })
        for (key, malformed) in [(keys[0], "not-a-git-id"), (keys[1], String(repeating: "A", count: 40)),
            (keys[2], String(repeating: "0", count: 63))] {
            var changed = complete
            changed[key] = malformed
            mutations.append(changed)
        }
        for key in ["project_yml_sha256", "third_party_manifest_sha256", "third_party_notices_sha256",
            "qualification_eligible", "repository_clean"] {
            var changed = complete
            changed[key] = key.hasSuffix("sha256") ? String(repeating: "4", count: 64) as Any : true as Any
            mutations.append(changed)
        }
        for (index, overrides) in mutations.enumerated() {
            let fixture = try BundleAuthorityFixture(provenanceOverrides: overrides, ineligibleDebugProvenance: true)
            defer { fixture.remove() }
            await assertAttestationError(.buildEvidenceInvalid, fixture: fixture, label: "Debug identity mutation \(index)")
        }
    }

    func testAttestationRejectsMutatedServiceEvidenceAgainstProvenance() async throws {
        let paths: [(String, @Sendable (BundleAuthorityFixture) -> URL)] = [
            ("Info.plist", { $0.infoURL }),
            ("executable", { $0.executableURL }),
            ("CodeResources", { $0.codeResourcesURL }),
        ]
        for (label, pathForFixture) in paths {
            let fixture = try BundleAuthorityFixture()
            defer { fixture.remove() }
            try Data("forged-\(label)".utf8).write(to: pathForFixture(fixture))
            await assertAttestationError(.buildEvidenceInvalid, fixture: fixture, label: label)
        }
    }

    func testAttestationRejectsIntermediateSymlinkAndObserverGatedServiceSwap() async throws {
        let symlinkFixture = try BundleAuthorityFixture()
        defer { symlinkFixture.remove() }
        let xpcServices = symlinkFixture.appURL.appendingPathComponent("Contents/XPCServices")
        let retained = symlinkFixture.root.appendingPathComponent("XPCServices-retained")
        try FileManager.default.moveItem(at: xpcServices, to: retained)
        try FileManager.default.createSymbolicLink(at: xpcServices, withDestinationURL: retained)
        await assertAttestationError(.bundleTopologyInvalid, fixture: symlinkFixture)

        let swapFixture = try BundleAuthorityFixture()
        defer { swapFixture.remove() }
        let mutationError = LockedBox<Swift.Error?>(nil)
        let provider = NativeDecompilerBundleRuntimeAuthorityProvider(
            appBundleURL: swapFixture.appURL,
            signatureValidator: { _ in },
            attestationObserver: { gate in
                guard case .packageHashed = gate else { return }
                do {
                    let retainedService = swapFixture.root.appendingPathComponent("service-retained")
                    try FileManager.default.moveItem(at: swapFixture.serviceURL, to: retainedService)
                    try FileManager.default.copyItem(at: retainedService, to: swapFixture.serviceURL)
                } catch {
                    mutationError.withValue { $0 = error }
                }
            }
        )
        await assertAttestationError(
            .bundleTopologyInvalid,
            provider: provider,
            label: "observer-gated service swap"
        )
        XCTAssertNil(mutationError.value)
    }

    func testAttestationRejectsObserverGatedEvidenceAndPackageRaces() async throws {
        let evidencePaths: [(String, @Sendable (BundleAuthorityFixture) -> URL)] = [
            ("golden", { $0.goldenURL }),
            ("manifest", { $0.manifestURL }),
            ("provenance", { $0.provenanceURL }),
            ("Info.plist", { $0.infoURL }),
            ("executable", { $0.executableURL }),
            ("CodeResources", { $0.codeResourcesURL }),
        ]
        for (label, pathForFixture) in evidencePaths {
            let fixture = try BundleAuthorityFixture()
            defer { fixture.remove() }
            let mutationError = LockedBox<Swift.Error?>(nil)
            let provider = NativeDecompilerBundleRuntimeAuthorityProvider(
                appBundleURL: fixture.appURL,
                signatureValidator: { _ in },
                attestationObserver: { gate in
                    guard case .evidenceRead = gate else { return }
                    do {
                        try overwritePrefix(of: pathForFixture(fixture), with: Data("race".utf8))
                    } catch {
                        mutationError.withValue { $0 = error }
                    }
                }
            )
            await assertAttestationError(.bundleTopologyInvalid, provider: provider, label: label)
            XCTAssertNil(mutationError.value, label)
        }

        let packageMutations: [(String, @Sendable (BundleAuthorityFixture) throws -> Void)] = [
            ("in-place", { fixture in
                let path = fixture.packageURL.appendingPathComponent("lib/libdecomp.a")
                try overwritePrefix(of: path, with: Data("race".utf8))
            }),
            ("add", { fixture in
                try Data("added".utf8).write(to: fixture.packageURL.appendingPathComponent("added"))
            }),
            ("remove", { fixture in
                try FileManager.default.removeItem(
                    at: fixture.packageURL.appendingPathComponent("include/sleigh/ghidra/funcdata.hh")
                )
            }),
        ]
        for (label, mutation) in packageMutations {
            let fixture = try BundleAuthorityFixture()
            defer { fixture.remove() }
            let mutationError = LockedBox<Swift.Error?>(nil)
            let provider = NativeDecompilerBundleRuntimeAuthorityProvider(
                appBundleURL: fixture.appURL,
                signatureValidator: { _ in },
                attestationObserver: { gate in
                    guard case .packageHashed = gate else { return }
                    do { try mutation(fixture) } catch {
                        mutationError.withValue { $0 = error }
                    }
                }
            )
            await assertAttestationError(.bundleTopologyInvalid, provider: provider, label: label)
            XCTAssertNil(mutationError.value, label)
        }
    }

    func testCallerCancellationReachesDetachedAttestationWorker() async throws {
        let fixture = try BundleAuthorityFixture()
        defer { fixture.remove() }
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let provider = NativeDecompilerBundleRuntimeAuthorityProvider(
            appBundleURL: fixture.appURL,
            signatureValidator: { _ in },
            attestationObserver: { gate in
                guard case .packageHashed = gate else { return }
                entered.signal()
                _ = resume.wait(timeout: .now() + 5)
            }
        )
        let operation = Task { try await provider.attestRuntimeAuthority() }
        let reachedGate = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
        XCTAssertTrue(reachedGate)
        operation.cancel()
        resume.signal()
        do {
            _ = try await operation.value
            XCTFail("cancelled caller must not receive runtime authority")
        } catch is CancellationError {
            // Expected: the cancellation handler cancels the detached I/O worker.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    private func assertAttestationError(
        _ expected: NativeDecompilerRuntimeAuthorityAttestationError,
        fixture: BundleAuthorityFixture,
        label: String = "fixture"
    ) async {
        let provider = NativeDecompilerBundleRuntimeAuthorityProvider(
            appBundleURL: fixture.appURL,
            signatureValidator: { _ in }
        )
        await assertAttestationError(expected, provider: provider, label: label)
    }

    private func assertAttestationError(
        _ expected: NativeDecompilerRuntimeAuthorityAttestationError,
        provider: NativeDecompilerBundleRuntimeAuthorityProvider,
        label: String
    ) async {
        do {
            _ = try await provider.attestRuntimeAuthority()
            XCTFail("attestation should fail with \(expected): \(label)")
        } catch let error as NativeDecompilerRuntimeAuthorityAttestationError {
            XCTAssertEqual(error, expected, label)
        } catch {
            XCTFail("unexpected error for \(label): \(error)")
        }
    }
}

private enum TestError: Error { case rejected }

private func overwritePrefix(of url: URL, with bytes: Data) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.write(contentsOf: bytes)
    try handle.synchronize()
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func withValue(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

private final class BundleAuthorityFixture: @unchecked Sendable {
    static let appleSiliconCriticalPaths = [
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AppleSilicon.ldefs",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_AppleSilicon.sla",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.pspec",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_apple.cspec",
    ]
    static let criticalPaths = [
        "include/sleigh/ghidra/funcdata.hh",
        "include/sleigh/ghidra/heritage.hh",
        "include/sleigh/ghidra/libdecomp.hh",
        "include/sleigh/ghidra/loadimage.hh",
        "include/sleigh/ghidra/prettyprint.hh",
        "include/sleigh/ghidra/printc.hh",
        "include/sleigh/ghidra/sleigh_arch.hh",
        "include/sleigh/ghidra/varnode.hh",
        "lib/cmake/sleigh/modules/sleighCompile.cmake",
        "lib/cmake/sleigh/sleighConfig.cmake",
        "lib/cmake/sleigh/sleighConfigVersion.cmake",
        "lib/cmake/sleigh/sleighTargets.cmake",
        "lib/cmake/sleigh/specfiles.cmake",
        "lib/libdecomp.a",
        "lib/libsla.a",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.cspec",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.ldefs",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.sla",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AppleSilicon.ldefs",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_AppleSilicon.sla",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.pspec",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_apple.cspec",
    ]

    let root: URL
    let appURL: URL
    let serviceURL: URL
    let packageURL: URL
    let manifestURL: URL
    let goldenURL: URL
    let provenanceURL: URL
    let infoURL: URL
    let executableURL: URL
    let codeResourcesURL: URL
    let engineRevision = "c0f584bf229fffba61b36431f3ce30c0c3e4e682"
    let wrapperRevision = String(repeating: "b", count: 64)
    let sealedGoldenSHA256: String
    private(set) var manifestSHA256 = ""
    private(set) var packageTreeSHA256 = ""

    init(
        goldenOverrides: [String: Any] = [:],
        provenanceOverrides: [String: Any] = [:],
        criticalDigestOverrides: [String: String] = [:],
        ineligibleDebugProvenance: Bool = false,
        omittedPackagePaths: Set<String> = [],
        currentReleaseEvidence: Bool = false,
        boundGoldenOverrides: [String: Any] = [:],
        sourceBuildOverrides: [String: Any] = [:]
    ) throws {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard temporaryPath.withCString({ realpath($0, &resolvedPath) }) != nil else {
            throw CocoaError(.fileReadUnknown)
        }
        let resolvedBytes = resolvedPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        root = URL(
            fileURLWithPath: String(decoding: resolvedBytes, as: UTF8.self),
            isDirectory: true
        )
            .appendingPathComponent(
                "MacScope-BundleAuthority-\(UUID().uuidString)",
                isDirectory: true
            )
        appURL = root.appendingPathComponent("MacScope.app", isDirectory: true)
        serviceURL = appURL.appendingPathComponent(
            "Contents/XPCServices/NativeDecompilerXPCService.xpc",
            isDirectory: true
        )
        packageURL = serviceURL.appendingPathComponent(
            "Contents/Resources/NativeDecompilerPackage/package",
            isDirectory: true
        )
        manifestURL = serviceURL.appendingPathComponent(
            "Contents/Resources/NativeDecompilerPackage/MATERIALIZATION.json"
        )
        goldenURL = serviceURL.appendingPathComponent(
            "Contents/Resources/NativeDecompilerBridgeGolden.json"
        )
        provenanceURL = appURL.appendingPathComponent("Contents/Resources/MacScopeBuildProvenance.json")
        infoURL = serviceURL.appendingPathComponent("Contents/Info.plist")
        executableURL = serviceURL.appendingPathComponent("Contents/MacOS/NativeDecompilerXPCService")
        codeResourcesURL = serviceURL.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        var files: [String: Data] = [
            "lib/libdecomp.a": Data("decompiler".utf8),
            "lib/libsla.a": Data("sleigh".utf8),
        ]
        for path in Self.criticalPaths where files[path] == nil && !omittedPackagePaths.contains(path) {
            files[path] = Data("fixture:\(path)".utf8)
        }
        for (path, bytes) in files {
            let url = packageURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: url)
        }
        let tree = try Self.treeEvidence(root: packageURL)
        packageTreeSHA256 = tree.digest
        var critical: [String: String] = Dictionary(
            uniqueKeysWithValues: Self.criticalPaths.compactMap {
                guard let bytes = files[$0] else { return nil }
                return ($0, Self.sha256(bytes))
            }
        )
        criticalDigestOverrides.forEach { critical[$0.key] = $0.value }
        var manifest: [String: Any] = [
            "artifact": [
                "filename": "macOS-sleigh-12.1.2-1.arm64.tar.gz",
                "platform": "macos-arm64",
                "sha256": "e1391c811de7b2d79c9e8a1f6f74cd9ade23baf55deebd75c626a3152e5e451a",
                "url": "https://github.com/lifting-bits/sleigh/releases/download/v12.1.2/macOS-sleigh-12.1.2-1.arm64.tar.gz",
            ],
            "componentId": "sleigh-native-dcp03b4",
            "ghidraGitRevision": engineRevision,
            "ghidraVersion": "12.1.2",
            "package": [
                "cmakeConfigRelativePath": "lib/cmake/sleigh/sleighConfig.cmake",
                "criticalFileSha256": critical,
                "decompilerLibraryRelativePath": "lib/libdecomp.a",
                "fileCount": tree.fileCount,
                "processorSpecRelativeRoot": "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages",
                "relativeRoot": "package",
                "sleighLibraryRelativePath": "lib/libsla.a",
                "totalBytes": tree.totalBytes,
                "treeSha256": tree.digest,
            ],
            "schemaVersion": 1,
            "sleighGitRevision": "bfd38a983b4aa53dd386365e1df5ed5499b7e2fb",
            "sleighVersion": "12.1.2",
        ]
        if currentReleaseEvidence {
            manifest.removeValue(forKey: "artifact")
            manifest["schemaVersion"] = 2
            manifest["componentId"] = "sleigh-native-source-dcp03b4"
            var sourceBuild = Self.sourceBuildEvidence
            sourceBuildOverrides.forEach { sourceBuild[$0.key] = $0.value }
            manifest["sourceBuild"] = sourceBuild
        }
        let manifestBytes = try Self.canonical(manifest)
        try manifestBytes.write(to: manifestURL)
        manifestSHA256 = Self.sha256(manifestBytes)

        var golden: [String: Any] = [
            "architecture": "arm64",
            "backendID": "ghidra-native-decompiler",
            "contractArchiveSHA256": String(repeating: "1", count: 64),
            "contractBuildIdentitySHA256": String(repeating: "2", count: 64),
            "decompilerArchiveSHA256": Self.sha256(files["lib/libdecomp.a"]!),
            "deploymentTarget": "27.0",
            "engineGitRevision": engineRevision,
            "engineVersion": "12.1.2",
            "goldenSourceSHA256": String(repeating: "3", count: 64),
            "materializationManifestSHA256": manifestSHA256,
            "materializationTreeSHA256": tree.digest,
            "objcMappingSHA256": String(repeating: "4", count: 64),
            "objcReplySHA256": String(repeating: "5", count: 64),
            "objcRequestSHA256": String(repeating: "6", count: 64),
            "packageBackedReplySHA256": String(repeating: "7", count: 64),
            "packageBackedRequestSHA256": String(repeating: "8", count: 64),
            "packageBackedSwiftReplySHA256": String(repeating: "9", count: 64),
            "passed": true,
            "schemaVersion": 1,
            "sdkBuild": "fixture",
            "sdkName": currentReleaseEvidence ? "macosx27.2" : "macosx",
            "sdkVersion": currentReleaseEvidence ? "27.2" : "27.0",
            "sleighArchiveSHA256": Self.sha256(files["lib/libsla.a"]!),
            "stageStampSHA256": String(repeating: "a", count: 64),
            "swiftCompilerVersion": currentReleaseEvidence ? "6.4" : "fixture",
            "swiftReplySHA256": String(repeating: "b", count: 64),
            "swiftTargetTriple": currentReleaseEvidence ? "arm64-apple-macosx27.2.0" : "arm64-apple-macosx27.0.0",
            "wrapperGitRevision": wrapperRevision,
            "wrapperVersion": "dcp05c-v1",
            "xcodeBuild": "fixture",
            "xcodeVersion": "27.0",
        ]
        boundGoldenOverrides.forEach { golden[$0.key] = $0.value }
        let expectedGolden = golden
        let expectedGoldenBytes = try Self.canonical(expectedGolden)
        goldenOverrides.forEach { golden[$0.key] = $0.value }
        let goldenBytes = try Self.canonical(golden)
        sealedGoldenSHA256 = Self.sha256(goldenBytes)
        try goldenBytes.write(to: goldenURL)

        let serviceContents = serviceURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codeResourcesURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("fixture-info".utf8).write(to: infoURL)
        try Data("fixture-executable".utf8).write(to: executableURL)
        try Data("fixture-code-resources".utf8).write(to: codeResourcesURL)

        let appResources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: appResources, withIntermediateDirectories: true)
        var provenance: [String: Any] = [
            "schema_version": 1,
            "qualification_eligible": true,
            "configuration": "Release",
            "git_head_commit": String(repeating: "1", count: 40),
            "git_head_tree": String(repeating: "2", count: 40),
            "repository_clean": true,
            "selected_build_inputs_sha256": String(repeating: "c", count: 64),
            "project_yml_sha256": String(repeating: "d", count: 64),
            "third_party_manifest_sha256": String(repeating: "e", count: 64),
            "third_party_notices_sha256": String(repeating: "f", count: 64),
            "third_party_component_ids": ["ghostty-vt", "sleigh-native"],
            "third_party_component_count": 2,
            "third_party_distribution_status": "private-product-only",
            "third_party_public_distribution_approved": false,
            "xcodegen_version": "2.46.0", "xcode_version": "27.0", "xcode_build": "fixture",
            "swift_compiler_version": "fixture", "swift_target_triple": "arm64-apple-macosx27.0.0",
            "sdk_name": "macosx27.0", "sdk_version": "27.0", "sdk_build": "fixture",
            "swift_language_version": "6.0", "architecture": "arm64",
            "deployment_target": "27.0", "app_bundle_identifier": "org.macscope.app",
            "ai_worker_bundle_identifier": "org.macscope.app.AIAgentWorker",
            "native_decompiler_golden_result": expectedGolden,
            "native_decompiler_golden_result_sha256": Self.sha256(expectedGoldenBytes),
            "native_decompiler_embedded_manifest_sha256": manifestSHA256,
            "native_decompiler_embedded_tree_sha256": tree.digest,
            "native_decompiler_embedded_decompiler_archive_sha256": Self.sha256(files["lib/libdecomp.a"]!),
            "native_decompiler_embedded_sleigh_archive_sha256": Self.sha256(files["lib/libsla.a"]!),
            "native_decompiler_embedded_service_bundle_identifier": "org.macscope.app.NativeDecompiler",
            "native_decompiler_embedded_service_info_plist_sha256": Self.sha256(Data("fixture-info".utf8)),
            "native_decompiler_embedded_service_executable_sha256": Self.sha256(Data("fixture-executable".utf8)),
            "native_decompiler_embedded_service_code_resources_sha256": Self.sha256(Data("fixture-code-resources".utf8)),
        ]
        if !ineligibleDebugProvenance {
            provenance["dependency_root_authority"] = "xcode-resolved-build-settings"
            provenance["ghostty_source_dir_sha256"] = String(repeating: "1", count: 64)
            provenance["sleigh_materialization_root_sha256"] = String(repeating: "2", count: 64)
        }
        if currentReleaseEvidence {
            provenance["swift_compiler_version"] = "6.4"
            provenance["swift_target_triple"] = "arm64-apple-macosx27.2.0"
            provenance["sdk_name"] = "macosx27.2"
            provenance["sdk_version"] = "27.2"
            provenance["third_party_distribution_status"] = "private-development-only"
            provenance.merge(Self.currentDependencyEvidence) { _, current in current }
            provenance["sleigh_materialization_manifest_sha256"] = manifestSHA256
            provenance["sleigh_materialization_tree_sha256"] = tree.digest
        }
        if ineligibleDebugProvenance {
            provenance["qualification_eligible"] = false
            provenance["configuration"] = "Debug"
            provenance["git_head_commit"] = NSNull()
            provenance["git_head_tree"] = NSNull()
            provenance["repository_clean"] = false
            provenance["selected_build_inputs_sha256"] = NSNull()
            provenance["project_yml_sha256"] = NSNull()
            provenance["third_party_manifest_sha256"] = NSNull()
            provenance["third_party_notices_sha256"] = NSNull()
            provenance["third_party_component_ids"] = [Any]()
            provenance["third_party_component_count"] = 0
            provenance["third_party_distribution_status"] = NSNull()
            provenance["third_party_public_distribution_approved"] = false
            provenance["xcodegen_version"] = NSNull()
        }
        provenanceOverrides.forEach { provenance[$0.key] = $0.value }
        try Self.canonical(provenance).write(
            to: provenanceURL
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    // Hand-authored current emitter shape, independent of the parser's accepted-key tables.
    private static var currentDependencyEvidence: [String: Any] {
        let sha = String(repeating: "a", count: 64)
        let revision = String(repeating: "b", count: 40)
        return [
            "ghostty_surface_archive_relative_path": "libghostty-internal.a",
            "ghostty_surface_archive_sha256": sha,
            "ghostty_surface_build_profile_sha256": sha,
            "ghostty_surface_compilation_condition": "MACSCOPE_FULL_GHOSTTY_SURFACE",
            "ghostty_surface_external_io_abi_version": 1,
            "ghostty_surface_header_relative_path": "Headers/ghostty.h",
            "ghostty_surface_header_sha256": sha,
            "ghostty_surface_module_map_relative_path": "Headers/module.modulemap",
            "ghostty_surface_module_map_sha256": sha,
            "ghostty_surface_source_manifest_sha256": sha,
            "ghostty_surface_source_revision": revision,
            "ghostty_surface_source_sha256": sha,
            "ghostty_surface_source_tree": revision,
            "ghostty_surface_staged_descriptor_relative_path": "STAGED_GHOSTTY_SURFACE.json",
            "ghostty_surface_staged_descriptor_sha256": sha,
            "ghostty_surface_staged_tree_sha256": sha,
            "machokit_analysis_worker_compiled_identity": [
                "schema": "macscope-machokit-compiled-identity-v1",
                "revision": revision, "governed_source_identity": sha,
            ],
            "machokit_analysis_worker_executable_sha256": sha,
            "machokit_analysis_worker_executable_size": 128,
            "machokit_governed_source_identity": sha,
            "machokit_materialization_manifest_sha256": sha,
            "machokit_materialization_root_sha256": sha,
            "machokit_materialization_tree_sha256": sha,
            "machokit_revision": revision,
            "machokit_source_archive_sha256": sha,
            "machokit_upstream_tree_sha256": sha,
            "machokit_version": "0.52.2",
            "sleigh_materialization_component_id": "sleigh-native-source-dcp03b4",
            "sleigh_materialization_schema_version": 2,
        ]
    }

    private static var sourceBuildEvidence: [String: Any] {
        [
            "sourceManifestSha256": "e5525e857e0a3f88aa7f8550e0d6b1a72ef232eedb61e6b31d24c350420ff1d8",
            "sleighGitTree": "20043e94b5933466b0861ad68f07f591f70c0050",
            "sleighTreeSha256": "2af879c8587ba6b0913ee53b220f1580c92dd521de7671dc3ece8a750b47e622",
            "ghidraGitTree": "2dfe30eddeefcd3efc9e49ea58bd725de5bbc4bb",
            "ghidraTreeSha256": "fdcb64b623e3c881a95f16a29750e83fd124cc08149c347d3e56f58352cbe321",
            "patches": [
                ["path": "0001-Fix-UBSAN-errors-in-decompiler.patch", "sha256": "7f83a4bd158490c5aa58d789b6f655ced6a9b309f4e43a4870cd893b3d36f2e5"],
                ["path": "0002-Use-stroull-instead-of-stroul-to-parse-address-offse.patch", "sha256": "8c5ca9c13c87ca4bd456643912205efb26684ccb19055ac60ebe742300a68f39"],
                ["path": "0003-Ignore-floating-point-test-due-to-compilation-differ.patch", "sha256": "b4dddb53f41fda93ae9acc633ce1886d2eaa4e8a5328361064633b6733a42a99"],
                ["path": "0004-Allow-positive-or-negative-NAN-in-decompiler-floatin.patch", "sha256": "ea78812681b8f1dbede305cc7bde716b7cee16a30005bc90e8304fbfb3df80dd"],
                ["path": "0005-decompiler-Fix-strict-weak-ordering-TypePartialEnum.patch", "sha256": "9dbe5ffc7a105e6c199f4027087b553e619691e2402f43a9357ffdec7f55fc11"],
                ["path": "0006-decompiler-Fix-strict-weak-ordering-PullRecord.patch", "sha256": "fe52595fc8a2843006f771880e3d49782564770295b4b0a7475ab7d1be435731"],
                ["path": "0007-decompiler-Fix-strict-weak-ordering-compareFinalOrde.patch", "sha256": "e4b5581e4513e6a76f1ac07999d5c5e42343e125efdbdc753afbda11d1f13c3f"],
                ["path": "0008-Fix-UBSAN-signed-left-shift-errors.patch", "sha256": "2b8a93f1dbf25c9855a85807e0d0c2cd0836789118e3a2a154e24d4a9c20426d"],
            ],
            "buildOptions": [
                "ZERO_AR_DATE=1", "SOURCE_DATE_EPOCH=946684800", "LC_ALL=C", "TZ=UTC",
                "CMAKE_BUILD_TYPE=Release", "CMAKE_OSX_ARCHITECTURES=arm64",
                "CMAKE_OSX_DEPLOYMENT_TARGET=27.0", "BUILD_SHARED_LIBS=OFF",
                "sleigh_DEVELOPER_MODE=OFF", "sleigh_BUILD_TOOLS=OFF",
                "sleigh_BUILD_SLEIGHSPECS=OFF", "sleigh_BUILD_SUPPORT=OFF",
                "sleigh_BUILD_EXTRATOOLS=OFF", "sleigh_BUILD_EXAMPLE=OFF",
                "FETCHCONTENT_SOURCE_DIR_GHIDRASOURCE=<verified-external-source-copy>",
                "FETCHCONTENT_FULLY_DISCONNECTED=ON", "FETCHCONTENT_UPDATES_DISCONNECTED=ON",
                "FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER",
                "CMAKE_FIND_USE_PACKAGE_REGISTRY=FALSE", "CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=FALSE",
            ],
            "toolchain": [
                "compiler": ["path": "/fixture/clang", "sha256": String(repeating: "c", count: 64), "version": "Apple clang version 21.0.0"],
                "cmake": ["path": "/fixture/cmake", "sha256": String(repeating: "d", count: 64), "version": "cmake version 4.4.4"],
                "ninja": ["path": "/fixture/ninja", "sha256": String(repeating: "e", count: 64), "version": "1.13.2"],
            ],
        ]
    }

    func validateSignature(_ inspectedServiceURL: URL) throws {
        guard inspectedServiceURL == serviceURL,
              Self.sha256(try Data(contentsOf: goldenURL)) == sealedGoldenSHA256
        else { throw TestError.rejected }
    }

    private static func canonical(_ object: Any) throws -> Data {
        var data = try canonicalValue(object).canonicalJSONBytes()
        data.append(0x0A)
        return data
    }

    private static func canonicalValue(_ value: Any) throws -> Phase2ProductionJSONValue {
        switch value {
        case let value as Bool:
            return .bool(value)
        case let value as String:
            return .string(value)
        case let value as Int:
            return .number(String(value))
        case let value as UInt64:
            return .number(String(value))
        case let value as [Any]:
            return .array(try value.map(canonicalValue))
        case let value as [String: Any]:
            return .object(try value.mapValues(canonicalValue))
        case _ as NSNull:
            return .null
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }

    private static func treeEvidence(
        root: URL
    ) throws -> (digest: String, fileCount: Int, totalBytes: UInt64) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { throw CocoaError(.fileReadUnknown) }
        var files: [(path: String, bytes: Data)] = []
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            else { throw CocoaError(.fileNoSuchFile) }
            guard !isDirectory.boolValue else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            files.append((relative, try Data(contentsOf: url)))
        }
        files.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        var treeHasher = SHA256()
        var totalBytes: UInt64 = 0
        for (path, bytes) in files {
            let digest = sha256(bytes)
            totalBytes += UInt64(bytes.count)
            treeHasher.update(data: Data(path.utf8)); treeHasher.update(data: Data([0]))
            treeHasher.update(data: Data(String(bytes.count).utf8)); treeHasher.update(data: Data([0]))
            treeHasher.update(data: Data(digest.utf8)); treeHasher.update(data: Data([0]))
        }
        return (hex(treeHasher.finalize()), files.count, totalBytes)
    }

    private static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
