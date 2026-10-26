import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import MacScope

final class Phase2QualificationGateBuildAuthorityTests: XCTestCase {
    func testCurrentEmitterProvenanceParsesWithoutDroppingApprovedFields() throws {
        let data = try canonicalJSON(currentEmitterProvenanceObject())
        let parsed = try Phase2QualificationGateBuildProvenance.parseCanonical(data)
        XCTAssertEqual(parsed.canonicalBytes, data)
        XCTAssertEqual(parsed.gitHeadCommit, String(repeating: "a", count: 40))
    }

    func testCurrentEmitterProvenanceRejectsMissingUnknownAndMistypedEvidence() throws {
        let original = try currentEmitterProvenanceObject()
        let legacyKeys = Set(canonicalProvenanceObject().keys)
        for key in original.keys where !legacyKeys.contains(key) {
            var missing = original
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(
                try canonicalJSON(missing)), "Missing \(key)")
            var mistyped = original
            mistyped[key] = NSNull()
            XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(
                try canonicalJSON(mistyped)), "Null \(key)")
        }
        let mutations: [(String, Any)] = [
            ("unknown_extension", "not allowed"),
            ("ghostty_surface_archive_sha256", String(repeating: "A", count: 64)),
            ("ghostty_surface_archive_relative_path", "../outside.a"),
            ("ghostty_surface_external_io_abi_version", true),
            ("machokit_analysis_worker_executable_size", true),
            ("machokit_analysis_worker_executable_size", 1.5),
            ("sleigh_materialization_schema_version", true),
            ("native_decompiler_golden_result_sha256", String(repeating: "0", count: 64)),
        ]
        for (key, value) in mutations {
            var changed = original
            changed[key] = value
            XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(
                try canonicalJSON(changed)), "Invalid \(key): \(value)")
        }
        for nestedKey in ["native_decompiler_golden_result", "machokit_analysis_worker_compiled_identity"] {
            var changed = original
            var nested = try XCTUnwrap(changed[nestedKey] as? [String: Any])
            nested["unknown"] = "not allowed"
            changed[nestedKey] = nested
            XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(
                try canonicalJSON(changed)), "Unknown nested key in \(nestedKey)")
        }
        var changed = original
        var identity = try XCTUnwrap(changed["machokit_analysis_worker_compiled_identity"] as? [String: Any])
        identity["revision"] = String(repeating: "b", count: 40)
        changed["machokit_analysis_worker_compiled_identity"] = identity
        XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(
            try canonicalJSON(changed)))
        let canonical = try canonicalJSON(original)
        for (key, value) in [("sdkBuild", "OTHER" as Any), ("passed", 1 as Any)] {
            var changed = original
            var golden = try XCTUnwrap(changed["native_decompiler_golden_result"] as? [String: Any])
            golden[key] = value
            changed["native_decompiler_golden_result"] = golden
            // Refresh the digest so the cross-field/type check, not a stale hash, must reject it.
            changed["native_decompiler_golden_result_sha256"] = SHA256.hash(data: try canonicalJSON(golden))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(
                try canonicalJSON(changed)), "Invalid golden \(key)")
        }
        let duplicate = Data("{\"schema_version\":1,".utf8) + canonical.dropFirst()
        XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(duplicate))
    }

    /// Synthetic instance of the current 71-field Release emitter schema, with no machine paths.
    private func currentEmitterProvenanceObject() throws -> [String: Any] {
        let data = Data(#"""
        {
          "ai_worker_bundle_identifier": "org.macscope.app.AIAgentWorker",
          "app_bundle_identifier": "org.macscope.app",
          "architecture": "arm64",
          "configuration": "Release",
          "dependency_root_authority": "xcode-resolved-build-settings",
          "deployment_target": "27.0",
          "ghostty_source_dir_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "ghostty_surface_archive_relative_path": "libghostty-internal.a",
          "ghostty_surface_archive_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "ghostty_surface_build_profile_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "ghostty_surface_compilation_condition": "MACSCOPE_FULL_GHOSTTY_SURFACE",
          "ghostty_surface_external_io_abi_version": 1,
          "ghostty_surface_header_relative_path": "Headers/ghostty.h",
          "ghostty_surface_header_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "ghostty_surface_module_map_relative_path": "Headers/module.modulemap",
          "ghostty_surface_module_map_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "ghostty_surface_source_manifest_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "ghostty_surface_source_revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "ghostty_surface_source_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "ghostty_surface_source_tree": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "ghostty_surface_staged_descriptor_relative_path": "STAGED_GHOSTTY_SURFACE.json",
          "ghostty_surface_staged_descriptor_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "ghostty_surface_staged_tree_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "git_head_commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "git_head_tree": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "machokit_analysis_worker_compiled_identity": {
            "governed_source_identity": "1111111111111111111111111111111111111111111111111111111111111111",
            "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "schema": "macscope-machokit-compiled-identity-v1"
          },
          "machokit_analysis_worker_executable_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "machokit_analysis_worker_executable_size": 12524976,
          "machokit_governed_source_identity": "1111111111111111111111111111111111111111111111111111111111111111",
          "machokit_materialization_manifest_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "machokit_materialization_root_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "machokit_materialization_tree_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "machokit_revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "machokit_source_archive_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "machokit_upstream_tree_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "machokit_version": "0.52.2",
          "native_decompiler_embedded_decompiler_archive_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "native_decompiler_embedded_manifest_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "native_decompiler_embedded_service_bundle_identifier": "org.macscope.app.NativeDecompiler",
          "native_decompiler_embedded_service_code_resources_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "native_decompiler_embedded_service_executable_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "native_decompiler_embedded_service_info_plist_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "native_decompiler_embedded_sleigh_archive_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "native_decompiler_embedded_tree_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "native_decompiler_golden_result": {
            "architecture": "arm64",
            "backendID": "ghidra-native-decompiler",
            "contractArchiveSHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "contractBuildIdentitySHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "decompilerArchiveSHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "deploymentTarget": "27.0",
            "engineGitRevision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "engineVersion": "12.1.2",
            "goldenSourceSHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "materializationManifestSHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "materializationTreeSHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "objcMappingSHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "objcReplySHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "objcRequestSHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "packageBackedReplySHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "packageBackedRequestSHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "packageBackedSwiftReplySHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "passed": true,
            "schemaVersion": 1,
            "sdkBuild": "26B5086k",
            "sdkName": "macosx27.2",
            "sdkVersion": "27.2",
            "sleighArchiveSHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "stageStampSHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "swiftCompilerVersion": "6.4",
            "swiftReplySHA256": "1111111111111111111111111111111111111111111111111111111111111111",
            "swiftTargetTriple": "arm64-apple-macosx27.2.0",
            "wrapperGitRevision": "1111111111111111111111111111111111111111111111111111111111111111",
            "wrapperVersion": "dcp05c-v1",
            "xcodeBuild": "27B5019j",
            "xcodeVersion": "27.2"
          },
          "native_decompiler_golden_result_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "project_yml_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "qualification_eligible": true,
          "repository_clean": true,
          "schema_version": 1,
          "sdk_build": "26B5086k",
          "sdk_name": "macosx27.2",
          "sdk_version": "27.2",
          "selected_build_inputs_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "sleigh_materialization_component_id": "sleigh-native-source-dcp03b4",
          "sleigh_materialization_manifest_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "sleigh_materialization_root_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "sleigh_materialization_schema_version": 2,
          "sleigh_materialization_tree_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "swift_compiler_version": "6.4",
          "swift_language_version": "6.0",
          "swift_target_triple": "arm64-apple-macosx27.2.0",
          "third_party_component_count": 10,
          "third_party_component_ids": [
            "compiler-rt-signature-corpus",
            "ghostty-surface",
            "ghostty-vt",
            "libghidra-dcp03b3-pilot",
            "machokit-v2",
            "pypcode-dcp03-proof",
            "sleigh-native-dcp03b4",
            "swift-assembly-vendor",
            "xcodegen-tool",
            "zig-toolchain"
          ],
          "third_party_distribution_status": "private-development-only",
          "third_party_manifest_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "third_party_notices_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
          "third_party_public_distribution_approved": false,
          "xcode_build": "27B5019j",
          "xcode_version": "27.2",
          "xcodegen_version": "2.46.0"
        }
        """#.utf8)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let golden = try XCTUnwrap(object["native_decompiler_golden_result"] as? [String: Any])
        object["native_decompiler_golden_result_sha256"] = SHA256.hash(data: try canonicalJSON(golden))
            .map { String(format: "%02x", $0) }.joined()
        return object
    }


    func testCanonicalEligibleReleaseProvenanceParsesExactly() throws {
        let data = try canonicalProvenanceData()

        let value = try Phase2QualificationGateBuildProvenance.parseCanonical(data)

        XCTAssertEqual(value.schemaVersion, 1)
        XCTAssertTrue(value.qualificationEligible)
        XCTAssertEqual(value.configuration, "Release")
        XCTAssertTrue(value.repositoryClean)
        XCTAssertEqual(value.gitHeadCommit, String(repeating: "a", count: 40))
        XCTAssertEqual(value.gitHeadTree, String(repeating: "b", count: 40))
        XCTAssertEqual(value.selectedBuildInputsSHA256, String(repeating: "c", count: 64))
        XCTAssertEqual(value.projectYAMLSHA256, String(repeating: "d", count: 64))
        XCTAssertEqual(value.dependencyRootAuthority, "xcode-resolved-build-settings")
        XCTAssertEqual(value.ghosttySourceDirectorySHA256, String(repeating: "1", count: 64))
        XCTAssertEqual(value.sleighMaterializationRootSHA256, String(repeating: "2", count: 64))
        XCTAssertEqual(value.thirdPartyManifestSHA256, String(repeating: "e", count: 64))
        XCTAssertEqual(value.thirdPartyNoticesSHA256, String(repeating: "f", count: 64))
        XCTAssertEqual(value.thirdPartyComponentIDs, ["ghostty-vt", "zig-toolchain"])
        XCTAssertEqual(value.thirdPartyComponentCount, 2)
        XCTAssertEqual(value.thirdPartyDistributionStatus, "private-development-only")
        XCTAssertFalse(value.thirdPartyPublicDistributionApproved)
        XCTAssertEqual(value.architecture, "arm64")
        XCTAssertEqual(value.deploymentTarget, "27.0")
        XCTAssertEqual(value.swiftLanguageVersion, "6.0")
        XCTAssertEqual(value.appBundleIdentifier, "org.macscope.app")
        XCTAssertEqual(
            value.aiWorkerBundleIdentifier,
            "org.macscope.app.AIAgentWorker"
        )
        XCTAssertEqual(value.canonicalBytes, data)
    }

    func testProvenanceRejectsNoncanonicalUnknownIneligibleAndMalformedValues() throws {
        let canonical = try canonicalProvenanceData()
        var prettyObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        prettyObject["unknown"] = "field"
        let unknown = try canonicalJSON(prettyObject)
        XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(unknown))

        var ineligible = canonicalProvenanceObject()
        ineligible["qualification_eligible"] = false
        XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(
            try canonicalJSON(ineligible)
        ))

        var debug = canonicalProvenanceObject()
        debug["configuration"] = "Debug"
        XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(
            try canonicalJSON(debug)
        ))

        var dirty = canonicalProvenanceObject()
        dirty["repository_clean"] = false
        XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(
            try canonicalJSON(dirty)
        ))

        var invalidCommit = canonicalProvenanceObject()
        invalidCommit["git_head_commit"] = String(repeating: "A", count: 40)
        XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(
            try canonicalJSON(invalidCommit)
        ))

        let withoutTerminalNewline = Data(canonical.dropLast())
        XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(
            withoutTerminalNewline
        ))

        let oversized = Data(repeating: 0x20, count: 16 * 1_024 + 1)
        XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(oversized))
    }

    func testProvenanceRejectsDuplicateKeysEvenWhenDecodedValueWouldMatch() {
        let duplicate = Data("""
        {"schema_version":1,"schema_version":1}

        """.utf8)
        XCTAssertThrowsError(try Phase2QualificationGateBuildProvenance.parseCanonical(duplicate))
    }

    func testProvenanceRejectsInvalidThirdPartyEvidenceCombinations() throws {
        let invalidCases: [(String, (inout [String: Any]) -> Void)] = [
            ("unrecognized dependency-root authority", {
                $0["dependency_root_authority"] = "fixture-self-report"
            }),
            ("malformed Ghostty-root digest", {
                $0["ghostty_source_dir_sha256"] = String(repeating: "1", count: 63)
            }),
            ("malformed SLEIGH-root digest", {
                $0["sleigh_materialization_root_sha256"] = String(repeating: "A", count: 64)
            }),
            ("uppercase manifest digest", {
                $0["third_party_manifest_sha256"] = String(repeating: "E", count: 64)
            }),
            ("short notices digest", {
                $0["third_party_notices_sha256"] = String(repeating: "f", count: 63)
            }),
            ("empty component IDs", {
                $0["third_party_component_ids"] = []
                $0["third_party_component_count"] = 0
            }),
            ("component count below lower bound", {
                $0["third_party_component_count"] = 0
            }),
            ("component count above upper bound", {
                $0["third_party_component_count"] = 513
            }),
            ("component count differs from IDs", {
                $0["third_party_component_count"] = 1
            }),
            ("component IDs unsorted", {
                $0["third_party_component_ids"] = ["zig-toolchain", "ghostty-vt"]
            }),
            ("component IDs duplicate", {
                $0["third_party_component_ids"] = ["ghostty-vt", "ghostty-vt"]
            }),
            ("component ID has an invalid prefix", {
                $0["third_party_component_ids"] = ["-ghostty", "zig-toolchain"]
            }),
            ("component ID has an invalid character", {
                $0["third_party_component_ids"] = ["ghostty_vt", "zig-toolchain"]
            }),
            ("component ID exceeds maximum length", {
                $0["third_party_component_ids"] = [String(repeating: "a", count: 65), "zig-toolchain"]
            }),
            ("unrecognized distribution status", {
                $0["third_party_distribution_status"] = "review-pending"
            }),
            ("private distribution marked public", {
                $0["third_party_public_distribution_approved"] = true
            }),
            ("approved distribution marked private", {
                $0["third_party_distribution_status"] = "distribution-approved"
            }),
        ]

        for (name, mutate) in invalidCases {
            var object = canonicalProvenanceObject()
            mutate(&object)
            XCTAssertThrowsError(
                try Phase2QualificationGateBuildProvenance.parseCanonical(
                    try canonicalJSON(object)
                ),
                "Expected rejection for \(name)"
            )
        }
    }

    func testCodeIdentityPolicyRequiresExactIdentifierTeamRuntimeCertificateAndLocalDevelopmentEntitlements() {
        let app = validCodeIdentity(
            identifier: "org.macscope.app",
            canonicalPath: "/tmp/Release/MacScope.app"
        )
        XCTAssertTrue(Phase2QualificationGateCodeIdentityPolicy.accepts(app, role: .app))

        XCTAssertFalse(Phase2QualificationGateCodeIdentityPolicy.accepts(
            app.replacing(teamIdentifier: "OTHERTEAM"),
            role: .app
        ))
        XCTAssertFalse(Phase2QualificationGateCodeIdentityPolicy.accepts(
            app.replacing(signatureFlags: 0),
            role: .app
        ))
        XCTAssertFalse(Phase2QualificationGateCodeIdentityPolicy.accepts(
            app.replacing(signatureFlags: 0x10002),
            role: .app
        ))
        XCTAssertFalse(Phase2QualificationGateCodeIdentityPolicy.accepts(
            app.replacing(runtimeVersion: 0),
            role: .app
        ))
        XCTAssertFalse(Phase2QualificationGateCodeIdentityPolicy.accepts(
            app.replacing(leafCertificateCommonName: "Apple Development: Someone Else"),
            role: .app
        ))
        XCTAssertFalse(Phase2QualificationGateCodeIdentityPolicy.accepts(
            app.replacing(certificateCount: 0),
            role: .app
        ))
        XCTAssertFalse(Phase2QualificationGateCodeIdentityPolicy.accepts(
            app.replacing(entitlementsMatchLocalDevelopmentPolicy: false),
            role: .app
        ))
        XCTAssertFalse(Phase2QualificationGateCodeIdentityPolicy.accepts(
            app.replacing(identifier: "org.macscope.app.unstable"),
            role: .app
        ))
    }

    func testCodeIdentityPolicySeparatesAppWorkerAndGateRoles() {
        let app = validCodeIdentity(
            identifier: "org.macscope.app",
            canonicalPath: "/tmp/Release/MacScope.app"
        )
        let worker = validCodeIdentity(
            identifier: "org.macscope.app.AIAgentWorker",
            canonicalPath: "/tmp/Release/MacScope.app/Contents/XPCServices/AIAgentWorkerXPCService.xpc"
        )

        XCTAssertTrue(Phase2QualificationGateCodeIdentityPolicy.accepts(worker, role: .worker))
        XCTAssertFalse(Phase2QualificationGateCodeIdentityPolicy.accepts(worker, role: .app))
        XCTAssertTrue(Phase2QualificationGateCodeIdentityPolicy.accepts(app, role: .gateRunner))
        XCTAssertFalse(Phase2QualificationGateCodeIdentityPolicy.accepts(app, role: .worker))
    }

    func testCandidateAndInstalledSealsMustBeByteIdentical() {
        let candidate = bundleSeal()
        XCTAssertTrue(candidate.isByteIdentical(to: candidate))
        XCTAssertFalse(candidate.isByteIdentical(to: candidate.replacing(
            appExecutableSHA256: String(repeating: "1", count: 64)
        )))
        XCTAssertFalse(candidate.isByteIdentical(to: candidate.replacing(
            appResourceSealSHA256: String(repeating: "2", count: 64)
        )))
        XCTAssertFalse(candidate.isByteIdentical(to: candidate.replacing(
            workerExecutableSHA256: String(repeating: "3", count: 64)
        )))
        XCTAssertFalse(candidate.isByteIdentical(to: candidate.replacing(
            workerResourceSealSHA256: String(repeating: "4", count: 64)
        )))
        XCTAssertFalse(candidate.isByteIdentical(to: candidate.replacing(
            provenanceSHA256: String(repeating: "5", count: 64)
        )))
        XCTAssertFalse(candidate.isByteIdentical(to: candidate.replacing(
            wholeBundleManifestSHA256: String(repeating: "6", count: 64)
        )))
        XCTAssertFalse(candidate.isByteIdentical(to: candidate.replacing(appCDHash: "01")))
        XCTAssertFalse(candidate.isByteIdentical(to: candidate.replacing(workerCDHash: "02")))
    }

    func testWholeBundleIdentityDetectsAnalysisWorkerResourceAndInfoPlistMutations() throws {
        let candidate = try makeBundleTreeFixture(named: "candidate")
        let baseline = try Phase2QualificationGateBundleTreeIdentity.capture(at: candidate)
        let mutations = [
            "Contents/XPCServices/AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService",
            "Contents/Resources/QualificationFixture.json",
            "Contents/Info.plist",
        ]

        for (index, relativePath) in mutations.enumerated() {
            let installed = try copyBundleTreeFixture(
                candidate,
                named: "installed-content-\(index)"
            )
            let target = installed.appendingPathComponent(relativePath)
            try Data("mutated-\(index)".utf8).write(to: target)

            XCTAssertNotEqual(
                baseline,
                try Phase2QualificationGateBundleTreeIdentity.capture(at: installed),
                "Mutation must change whole-bundle identity: \(relativePath)"
            )
        }
    }

    func testWholeBundleIdentityAcceptsCopyWithDifferentDirectoryAllocationMetadata() throws {
        let candidate = try makeBundleTreeFixture(named: "candidate-copy")
        let installed = try copyBundleTreeFixture(candidate, named: "installed-copy")
        let resources = installed.appendingPathComponent("Contents/Resources")
        for index in 0..<64 {
            let temporary = resources.appendingPathComponent("removed-\(index)")
            try Data("transient".utf8).write(to: temporary)
            try FileManager.default.removeItem(at: temporary)
        }

        let candidateIdentity = try Phase2QualificationGateBundleTreeIdentity.capture(
            at: candidate
        )
        let installedIdentity = try Phase2QualificationGateBundleTreeIdentity.capture(
            at: installed
        )

        XCTAssertTrue(candidateIdentity.isByteIdentical(to: installedIdentity))
        XCTAssertEqual(
            candidateIdentity.entries.filter { $0.objectType == .directory }
                .map(\.size),
            Array(
                repeating: 0,
                count: candidateIdentity.entries.filter {
                    $0.objectType == .directory
                }.count
            )
        )
    }

    func testWholeBundleIdentityDetectsModeExtraAndMissingPathMutations() throws {
        let candidate = try makeBundleTreeFixture(named: "candidate-structure")
        let baseline = try Phase2QualificationGateBundleTreeIdentity.capture(at: candidate)

        let modeChanged = try copyBundleTreeFixture(candidate, named: "installed-mode")
        let modeTarget = modeChanged.appendingPathComponent(
            "Contents/Resources/QualificationFixture.json"
        )
        XCTAssertEqual(Darwin.chmod(modeTarget.path, 0o600), 0)
        XCTAssertNotEqual(
            baseline,
            try Phase2QualificationGateBundleTreeIdentity.capture(at: modeChanged)
        )

        let extra = try copyBundleTreeFixture(candidate, named: "installed-extra")
        try Data("extra".utf8).write(
            to: extra.appendingPathComponent("Contents/Resources/Unexpected.dat")
        )
        XCTAssertNotEqual(
            baseline,
            try Phase2QualificationGateBundleTreeIdentity.capture(at: extra)
        )

        let missing = try copyBundleTreeFixture(candidate, named: "installed-missing")
        try FileManager.default.removeItem(
            at: missing.appendingPathComponent("Contents/Resources/QualificationFixture.json")
        )
        XCTAssertNotEqual(
            baseline,
            try Phase2QualificationGateBundleTreeIdentity.capture(at: missing)
        )
    }

    func testWholeBundleIdentityRejectsSymlinksAndHardlinkAmbiguity() throws {
        let candidate = try makeBundleTreeFixture(named: "candidate-links")
        let resource = candidate.appendingPathComponent(
            "Contents/Resources/QualificationFixture.json"
        )
        let symlink = candidate.appendingPathComponent("Contents/Resources/Alias.json")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: resource
        )
        XCTAssertThrowsError(
            try Phase2QualificationGateBundleTreeIdentity.capture(at: candidate)
        ) { error in
            XCTAssertEqual(
                error as? Phase2QualificationGateBuildAuthorityError,
                .resourceSealInvalid
            )
        }

        try FileManager.default.removeItem(at: symlink)
        let hardlink = candidate.appendingPathComponent("Contents/Resources/Hardlink.json")
        try FileManager.default.linkItem(at: resource, to: hardlink)
        XCTAssertThrowsError(
            try Phase2QualificationGateBundleTreeIdentity.capture(at: candidate)
        ) { error in
            XCTAssertEqual(
                error as? Phase2QualificationGateBuildAuthorityError,
                .resourceSealInvalid
            )
        }
    }

    func testSecurityValidationFlagsArePartitionedBySecurityAPICall() {
        let policy = Phase2QualificationGateSecurityValidationFlags.self
        XCTAssertEqual(policy.considerExpiration, 0x8000_0000)
        XCTAssertEqual(policy.noNetworkAccess, 0x2000_0000)
        XCTAssertEqual(policy.checkTrustedAnchors, 0x0800_0000)
        XCTAssertEqual(policy.matchGuestRequirementInKernel, 0x0080_0000)

        let shared = policy.considerExpiration
            | policy.noNetworkAccess
        XCTAssertEqual(policy.sharedStrictFlags, shared)
        XCTAssertEqual(policy.staticValidity.rawValue & shared, shared)
        XCTAssertEqual(
            policy.staticValidity.rawValue & policy.checkTrustedAnchors,
            0,
            "Xcode 27 Security rejects trusted-anchor policy on static code validation"
        )
        let supportedDynamic = policy.considerExpiration | policy.noNetworkAccess
        XCTAssertEqual(
            policy.dynamicValidity.rawValue & supportedDynamic,
            supportedDynamic
        )
        XCTAssertEqual(
            policy.dynamicValidity.rawValue & policy.checkTrustedAnchors,
            0,
            "Xcode 27 Security rejects trusted-anchor policy on live SecCode validation"
        )
        XCTAssertEqual(
            policy.dynamicValidity.rawValue & policy.matchGuestRequirementInKernel,
            0,
            "Xcode 27 Security rejects kernel-match policy for live SecCode validation"
        )
        XCTAssertEqual(policy.guestLookup.rawValue, 0)
        XCTAssertNotEqual(
            policy.staticValidity.rawValue & UInt32(kSecCSRestrictSymlinks),
            0
        )
        XCTAssertNotEqual(
            policy.staticValidity.rawValue & UInt32(kSecCSRestrictSidebandData),
            0
        )
    }

    func testAuthorityErrorsExposeStableNonSensitiveTerminalCodes() {
        let cases: [(Phase2QualificationGateBuildAuthorityError, String)] = [
            (.debugBuild, "debug-build"),
            (.provenanceUnavailable, "provenance-unavailable"),
            (.provenanceMalformed, "provenance-malformed"),
            (.provenanceNoncanonical, "provenance-noncanonical"),
            (.provenanceIneligible, "provenance-ineligible"),
            (.codeUnavailable, "code-unavailable"),
            (.codeInvalid(-1), "code-invalid"),
            (.codeIdentityInvalid, "code-identity-invalid"),
            (.resourceSealInvalid, "resource-seal-invalid"),
            (.installationMismatch, "installation-mismatch"),
            (.gateRunnerInvalid, "gate-runner-invalid"),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(error.terminalCaseCode, expected)
        }
        XCTAssertEqual(
            Phase2QualificationGateBuildAuthorityError.codeInvalid(-67070)
                .terminalCaseCode,
            "code-invalid"
        )
    }

    func testProviderCodeIdentityRequiresExactExecutableAndDeveloperIDIdentity() {
        let identity = validProviderCodeIdentity()

        XCTAssertTrue(Phase2QualificationGateProviderCodeIdentityPolicy.accepts(identity))
        XCTAssertFalse(Phase2QualificationGateProviderCodeIdentityPolicy.accepts(
            identity.replacing(executableSHA256: String(repeating: "0", count: 64))
        ))
        XCTAssertFalse(Phase2QualificationGateProviderCodeIdentityPolicy.accepts(
            identity.replacing(cdHash: String(repeating: "0", count: 40))
        ))
        XCTAssertFalse(Phase2QualificationGateProviderCodeIdentityPolicy.accepts(
            identity.replacing(teamIdentifier: "OTHERTEAM")
        ))
        XCTAssertFalse(Phase2QualificationGateProviderCodeIdentityPolicy.accepts(
            identity.replacing(canonicalBundlePath: "/tmp/LM Studio.app")
        ))
        XCTAssertFalse(Phase2QualificationGateProviderCodeIdentityPolicy.accepts(
            identity.replacing(signatureFlags: 0x10002)
        ))
    }

    func testProviderCodeAuthorityIsProcessBoundAndNetworkFree() throws {
        let source = try String(
            contentsOf: qualificationGateSource("Phase2QualificationGateRuntimeCollector.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("SecCodeCopyGuestWithAttributes("))
        XCTAssertTrue(source.contains("kSecGuestAttributePid"))
        XCTAssertTrue(source.contains(
            "Phase2QualificationGateSecurityValidationFlags.dynamicValidity"
        ))
        XCTAssertFalse(source.contains("kSecCSMatchGuestRequirementInKernel"))
        XCTAssertFalse(source.contains("kSecCSNoNetworkAccess"))
        XCTAssertTrue(source.contains(
            "Phase2QualificationGateProviderCodeAuthority.accepts(process)"
        ))
    }

    func testProviderCodeAuthorityPartitionsGuestLookupFromDynamicValidationFlags() throws {
        let source = try String(
            contentsOf: qualificationGateSource("Phase2QualificationGateRuntimeCollector.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "private static let guestLookupFlags =\n"
                + "        Phase2QualificationGateSecurityValidationFlags.guestLookup"
        ))
        XCTAssertTrue(source.contains(
            "private static let dynamicValidityFlags =\n"
                + "        Phase2QualificationGateSecurityValidationFlags.dynamicValidity"
        ))
        XCTAssertTrue(source.contains(
            "SecCodeCopyGuestWithAttributes(\n"
                + "            nil,\n"
                + "            attributes,\n"
                + "            guestLookupFlags,"
        ))
        XCTAssertTrue(source.contains(
            "SecCodeCheckValidityWithErrors(\n"
                + "                  dynamicCode,\n"
                + "                  dynamicValidityFlags,"
        ))
        XCTAssertFalse(source.contains(
            "attributes,\n"
                + "            dynamicValidityFlags,"
        ))
    }

    func testRuntimeCollectorUsesCheckedTimespecConversionAndMainActorProviderCollection() throws {
        let source = try String(
            contentsOf: qualificationGateSource("Phase2QualificationGateRuntimeCollector.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(source.components(separatedBy: "Int64(exactly:").count - 1, 4)
        XCTAssertTrue(source.contains(
            "@MainActor\nprivate enum Phase2QualificationGateProviderCollector"
        ))
    }

    private func qualificationGateSource(_ name: String) -> URL {
        TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Services/Phase2/QualificationGate", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func canonicalProvenanceData() throws -> Data {
        try canonicalJSON(canonicalProvenanceObject())
    }

    private func canonicalProvenanceObject() -> [String: Any] {
        [
            "ai_worker_bundle_identifier": "org.macscope.app.AIAgentWorker",
            "app_bundle_identifier": "org.macscope.app",
            "architecture": "arm64",
            "configuration": "Release",
            "deployment_target": "27.0",
            "dependency_root_authority": "xcode-resolved-build-settings",
            "git_head_commit": String(repeating: "a", count: 40),
            "git_head_tree": String(repeating: "b", count: 40),
            "ghostty_source_dir_sha256": String(repeating: "1", count: 64),
            "project_yml_sha256": String(repeating: "d", count: 64),
            "qualification_eligible": true,
            "repository_clean": true,
            "schema_version": 1,
            "sdk_build": "27A123",
            "sdk_name": "macosx27.0",
            "sdk_version": "27.0",
            "selected_build_inputs_sha256": String(repeating: "c", count: 64),
            "sleigh_materialization_root_sha256": String(repeating: "2", count: 64),
            "swift_compiler_version": "6.4",
            "swift_language_version": "6.0",
            "swift_target_triple": "arm64-apple-macosx27.0",
            "third_party_component_count": 2,
            "third_party_component_ids": ["ghostty-vt", "zig-toolchain"],
            "third_party_distribution_status": "private-development-only",
            "third_party_manifest_sha256": String(repeating: "e", count: 64),
            "third_party_notices_sha256": String(repeating: "f", count: 64),
            "third_party_public_distribution_approved": false,
            "xcode_build": "27A123",
            "xcode_version": "27.0",
            "xcodegen_version": "2.45.4",
        ]
    }

    private func canonicalJSON(_ object: [String: Any]) throws -> Data {
        var value = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        value.append(0x0A)
        return value
    }

    private func validCodeIdentity(
        identifier: String,
        canonicalPath: String
    ) -> Phase2QualificationGateCodeIdentity {
        .init(
            identifier: identifier,
            teamIdentifier: "TEAM000000",
            signatureFlags: 0x10000,
            runtimeVersion: 27,
            leafCertificateCommonName:
                "Apple Development: MacScope Developer (CERT000000)",
            certificateCount: 2,
            entitlementsMatchLocalDevelopmentPolicy: true,
            cdHash: "00112233445566778899aabbccddeeff00112233",
            canonicalPath: canonicalPath
        )
    }

    private func makeBundleTreeFixture(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-BuildAuthority-\(UUID().uuidString)")
            .appendingPathComponent("\(name).app", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: root.deletingLastPathComponent()
            )
        }
        let files: [(String, String)] = [
            ("Contents/Info.plist", "plist"),
            ("Contents/MacOS/MacScope", "app-executable"),
            ("Contents/Resources/QualificationFixture.json", "resource"),
            ("Contents/_CodeSignature/CodeResources", "app-seal"),
            (
                "Contents/XPCServices/AnalysisWorkerXPCService.xpc/Contents/Info.plist",
                "analysis-plist"
            ),
            (
                "Contents/XPCServices/AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService",
                "analysis-executable"
            ),
            (
                "Contents/XPCServices/AIAgentWorkerXPCService.xpc/Contents/MacOS/AIAgentWorkerXPCService",
                "ai-executable"
            ),
            (
                "Contents/XPCServices/AIAgentWorkerXPCService.xpc/Contents/_CodeSignature/CodeResources",
                "ai-seal"
            ),
        ]
        for (relativePath, contents) in files {
            let file = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func copyBundleTreeFixture(_ source: URL, named name: String) throws -> URL {
        let destination = source.deletingLastPathComponent()
            .appendingPathComponent("\(name).app", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination.resolvingSymlinksInPath().standardizedFileURL
    }

    private func bundleSeal() -> Phase2QualificationGateBundleSeal {
        .init(
            appExecutableSHA256: String(repeating: "a", count: 64),
            appResourceSealSHA256: String(repeating: "b", count: 64),
            workerExecutableSHA256: String(repeating: "c", count: 64),
            workerResourceSealSHA256: String(repeating: "d", count: 64),
            provenanceSHA256: String(repeating: "e", count: 64),
            wholeBundleManifestSHA256: String(repeating: "f", count: 64),
            appCDHash: "00112233445566778899aabbccddeeff00112233",
            workerCDHash: "ffeeddccbbaa99887766554433221100ffeeddcc"
        )
    }

    private func validProviderCodeIdentity() -> Phase2QualificationGateProviderCodeIdentity {
        .init(
            identifier: "ai.elementlabs.lmstudio",
            teamIdentifier: "D65G88RHWN",
            signatureFlags: 0x10000,
            runtimeVersion: 0x1A0000,
            leafCertificateCommonName:
                "Developer ID Application: Element Labs Inc (D65G88RHWN)",
            certificateCount: 3,
            cdHash: "c67b3400427d8fdbb4bf8680546426c7740ac3dc",
            canonicalBundlePath: "/Applications/LM Studio.app",
            executableSHA256:
                "b24d25bcf1d2eac3456d6fb67a8aee6f0ea9cb037a5a812d68ab739d666a0168"
        )
    }
}

final class Phase2QualificationGateInstallationAdjudicatorTests: XCTestCase {
    func testRefusesWhenGateProcessBundleIsNotTheCandidateApp() {
        var fixture = installationFixture()
        fixture.gateProcessAppURL = URL(fileURLWithPath: "/tmp/Other.app")

        assertRefusal(.gateRunnerInvalid, fixture: fixture)
    }

    func testRefusesWhenInstalledPathResolvesThroughASymlink() {
        var fixture = installationFixture()
        fixture.resolvedInstalledAppURL = URL(fileURLWithPath: "/private/tmp/MacScope.app")

        assertRefusal(.installationMismatch, fixture: fixture)
    }

    func testRefusesWhenCandidateAndInstalledAreTheSameBundle() {
        var fixture = installationFixture()
        fixture.useSameBundleAsCandidate(at: fixture.resolvedInstalledAppURL)

        assertRefusal(.installationMismatch, fixture: fixture)
    }

    func testInstalledCanaryAcceptsExactInstalledBundle() throws {
        var fixture = installationFixture()
        fixture.useSameBundleAsCandidate(at: fixture.resolvedInstalledAppURL)

        try fixture.adjudicate(installationMode: .installedCanary)
    }

    func testInstalledCanaryRefusesSameBundleOutsideExactInstalledPath() {
        var fixture = installationFixture()
        fixture.useSameBundleAsCandidate(at: URL(fileURLWithPath: "/tmp/MacScope.app"))

        assertRefusal(
            .installationMismatch,
            fixture: fixture,
            installationMode: .installedCanary
        )
    }

    func testRefusesWhenSignedCodeDoesNotResolveToTheExactInstalledBundle() {
        var fixture = installationFixture()
        fixture.installedCodeAppURL = URL(fileURLWithPath: "/tmp/Decoy.app")

        assertRefusal(.installationMismatch, fixture: fixture)
    }

    func testRefusesOnProvenanceSealTreeOrCDHashDrift() {
        let mutations: [(String, (inout InstallationFixture) -> Void)] = [
            ("provenance", { $0.installedProvenance = makeProvenance(commit: "b") }),
            ("seal bytes", {
                $0.installedSeal = $0.installedSeal.replacing(
                    appExecutableSHA256: String(repeating: "1", count: 64)
                )
            }),
            ("malformed seal", {
                $0.installedSeal = $0.installedSeal.replacing(appCDHash: "not-a-cdhash")
            }),
            ("tree identity", {
                $0.installedTreeIdentity = makeTreeIdentity(digestCharacter: "2")
            }),
            ("app cdHash", {
                $0.installedAppIdentity = $0.installedAppIdentity.replacing(
                    cdHash: String(repeating: "3", count: 40)
                )
            }),
            ("worker cdHash", {
                $0.installedWorkerIdentity = $0.installedWorkerIdentity.replacing(
                    cdHash: String(repeating: "4", count: 40)
                )
            }),
        ]

        for (name, mutation) in mutations {
            var fixture = installationFixture()
            mutation(&fixture)
            assertRefusal(.installationMismatch, fixture: fixture, name: name)
        }
    }

    func testRefusesWhenGateIdentityFailsGateRunnerRolePolicy() {
        var fixture = installationFixture()
        fixture.gateIdentity = fixture.gateIdentity.replacing(
            identifier: "org.macscope.app.untrusted"
        )

        assertRefusal(.gateRunnerInvalid, fixture: fixture)
    }

    func testAcceptsCanonicalMatchedInstallation() throws {
        try installationFixture().adjudicate()
    }

    private func assertRefusal(
        _ expected: Phase2QualificationGateBuildAuthorityError,
        fixture: InstallationFixture,
        installationMode: Phase2QualificationGateInstallationMode = .stagedCandidate,
        name: String = #function
    ) {
        XCTAssertThrowsError(
            try fixture.adjudicate(installationMode: installationMode),
            name
        ) { error in
            XCTAssertEqual(error as? Phase2QualificationGateBuildAuthorityError, expected, name)
        }
    }
}

private struct InstallationFixture {
    var gateProcessAppURL: URL
    var candidateAppURL: URL
    var installedAppURL: URL
    var resolvedInstalledAppURL: URL
    var installedCodeAppURL: URL
    var candidateProvenance: Phase2QualificationGateBuildProvenance
    var installedProvenance: Phase2QualificationGateBuildProvenance
    var candidateSeal: Phase2QualificationGateBundleSeal
    var installedSeal: Phase2QualificationGateBundleSeal
    var candidateTreeIdentity: Phase2QualificationGateBundleTreeIdentity
    var installedTreeIdentity: Phase2QualificationGateBundleTreeIdentity
    var candidateAppIdentity: Phase2QualificationGateCodeIdentity
    var installedAppIdentity: Phase2QualificationGateCodeIdentity
    var candidateWorkerIdentity: Phase2QualificationGateCodeIdentity
    var installedWorkerIdentity: Phase2QualificationGateCodeIdentity
    var gateIdentity: Phase2QualificationGateCodeIdentity

    func adjudicate(
        installationMode: Phase2QualificationGateInstallationMode = .stagedCandidate
    ) throws {
        try Phase2QualificationGateInstallationAdjudicator.adjudicate(
            installationMode: installationMode,
            gateProcessAppURL: gateProcessAppURL,
            candidateAppURL: candidateAppURL,
            installedAppURL: installedAppURL,
            resolvedInstalledAppURL: resolvedInstalledAppURL,
            installedCodeAppURL: installedCodeAppURL,
            candidateProvenance: candidateProvenance,
            installedProvenance: installedProvenance,
            candidateSeal: candidateSeal,
            installedSeal: installedSeal,
            candidateTreeIdentity: candidateTreeIdentity,
            installedTreeIdentity: installedTreeIdentity,
            candidateAppIdentity: candidateAppIdentity,
            installedAppIdentity: installedAppIdentity,
            candidateWorkerIdentity: candidateWorkerIdentity,
            installedWorkerIdentity: installedWorkerIdentity,
            gateIdentity: gateIdentity
        )
    }

    mutating func useSameBundleAsCandidate(at url: URL) {
        let appIdentity = installedAppIdentity.replacing(canonicalPath: url.path)
        let workerIdentity = installedWorkerIdentity.replacing(canonicalPath: url
            .appendingPathComponent("Contents/XPCServices/AIAgentWorkerXPCService.xpc")
            .path)
        gateProcessAppURL = url
        candidateAppURL = url
        installedAppURL = url
        resolvedInstalledAppURL = url
        installedCodeAppURL = url
        candidateAppIdentity = appIdentity
        installedAppIdentity = appIdentity
        candidateWorkerIdentity = workerIdentity
        installedWorkerIdentity = workerIdentity
        gateIdentity = appIdentity
    }
}

private func installationFixture() -> InstallationFixture {
    let candidateURL = URL(fileURLWithPath: "/tmp/Release/MacScope.app")
    let installedURL = URL(fileURLWithPath: "/Applications/MacScope.app")
    let provenance = makeProvenance()
    let seal = makeInstallationSeal()
    let tree = makeTreeIdentity()
    let appIdentity = makeInstallationIdentity(
        identifier: "org.macscope.app",
        path: candidateURL.path,
        cdHash: String(repeating: "a", count: 40)
    )
    let installedAppIdentity = makeInstallationIdentity(
        identifier: "org.macscope.app",
        path: installedURL.path,
        cdHash: appIdentity.cdHash
    )
    let workerIdentity = makeInstallationIdentity(
        identifier: "org.macscope.app.AIAgentWorker",
        path: candidateURL.appendingPathComponent(
            "Contents/XPCServices/AIAgentWorkerXPCService.xpc"
        ).path,
        cdHash: String(repeating: "b", count: 40)
    )
    let installedWorkerIdentity = makeInstallationIdentity(
        identifier: "org.macscope.app.AIAgentWorker",
        path: installedURL.appendingPathComponent(
            "Contents/XPCServices/AIAgentWorkerXPCService.xpc"
        ).path,
        cdHash: workerIdentity.cdHash
    )
    return .init(
        gateProcessAppURL: candidateURL,
        candidateAppURL: candidateURL,
        installedAppURL: installedURL,
        resolvedInstalledAppURL: installedURL,
        installedCodeAppURL: installedURL,
        candidateProvenance: provenance,
        installedProvenance: provenance,
        candidateSeal: seal,
        installedSeal: seal,
        candidateTreeIdentity: tree,
        installedTreeIdentity: tree,
        candidateAppIdentity: appIdentity,
        installedAppIdentity: installedAppIdentity,
        candidateWorkerIdentity: workerIdentity,
        installedWorkerIdentity: installedWorkerIdentity,
        gateIdentity: appIdentity
    )
}

private func makeProvenance(commit: Character = "a") -> Phase2QualificationGateBuildProvenance {
    .init(
        schemaVersion: 1,
        qualificationEligible: true,
        configuration: "Release",
        gitHeadCommit: String(repeating: commit, count: 40),
        gitHeadTree: String(repeating: "c", count: 40),
        repositoryClean: true,
        selectedBuildInputsSHA256: String(repeating: "d", count: 64),
        projectYAMLSHA256: String(repeating: "e", count: 64),
        dependencyRootAuthority: "xcode-resolved-build-settings",
        ghosttySourceDirectorySHA256: String(repeating: "2", count: 64),
        sleighMaterializationRootSHA256: String(repeating: "3", count: 64),
        thirdPartyManifestSHA256: String(repeating: "f", count: 64),
        thirdPartyNoticesSHA256: String(repeating: "1", count: 64),
        thirdPartyComponentIDs: ["ghostty-vt", "sleigh-native"],
        thirdPartyComponentCount: 2,
        thirdPartyDistributionStatus: "private-development-only",
        thirdPartyPublicDistributionApproved: false,
        xcodegenVersion: "2.45.4",
        xcodeVersion: "27.0",
        xcodeBuild: "27A123",
        swiftCompilerVersion: "6.4",
        swiftTargetTriple: "arm64-apple-macosx27.0",
        sdkName: "macosx27.0",
        sdkVersion: "27.0",
        sdkBuild: "27A123",
        swiftLanguageVersion: "6.0",
        architecture: "arm64",
        deploymentTarget: "27.0",
        appBundleIdentifier: "org.macscope.app",
        aiWorkerBundleIdentifier: "org.macscope.app.AIAgentWorker",
        canonicalBytes: Data(String(repeating: commit, count: 1).utf8)
    )
}

private func makeInstallationSeal() -> Phase2QualificationGateBundleSeal {
    .init(
        appExecutableSHA256: String(repeating: "a", count: 64),
        appResourceSealSHA256: String(repeating: "b", count: 64),
        workerExecutableSHA256: String(repeating: "c", count: 64),
        workerResourceSealSHA256: String(repeating: "d", count: 64),
        provenanceSHA256: String(repeating: "e", count: 64),
        wholeBundleManifestSHA256: String(repeating: "f", count: 64),
        appCDHash: String(repeating: "a", count: 40),
        workerCDHash: String(repeating: "b", count: 40)
    )
}

private func makeTreeIdentity(
    digestCharacter: Character = "1"
) -> Phase2QualificationGateBundleTreeIdentity {
    .init(
        entries: [],
        manifestSHA256: String(repeating: digestCharacter, count: 64),
        totalRegularFileBytes: 0
    )
}

private func makeInstallationIdentity(
    identifier: String,
    path: String,
    cdHash: String
) -> Phase2QualificationGateCodeIdentity {
    .init(
        identifier: identifier,
        teamIdentifier: "TEAM000000",
        signatureFlags: 0x10000,
        runtimeVersion: 27,
        leafCertificateCommonName: "Apple Development: MacScope Developer (CERT000000)",
        certificateCount: 2,
        entitlementsMatchLocalDevelopmentPolicy: true,
        cdHash: cdHash,
        canonicalPath: path
    )
}

private extension Phase2QualificationGateCodeIdentity {
    func replacing(
        identifier: String? = nil,
        teamIdentifier: String? = nil,
        signatureFlags: UInt32? = nil,
        runtimeVersion: UInt32? = nil,
        leafCertificateCommonName: String? = nil,
        certificateCount: Int? = nil,
        entitlementsMatchLocalDevelopmentPolicy: Bool? = nil,
        cdHash: String? = nil,
        canonicalPath: String? = nil
    ) -> Self {
        .init(
            identifier: identifier ?? self.identifier,
            teamIdentifier: teamIdentifier ?? self.teamIdentifier,
            signatureFlags: signatureFlags ?? self.signatureFlags,
            runtimeVersion: runtimeVersion ?? self.runtimeVersion,
            leafCertificateCommonName:
                leafCertificateCommonName ?? self.leafCertificateCommonName,
            certificateCount: certificateCount ?? self.certificateCount,
            entitlementsMatchLocalDevelopmentPolicy: entitlementsMatchLocalDevelopmentPolicy
                ?? self.entitlementsMatchLocalDevelopmentPolicy,
            cdHash: cdHash ?? self.cdHash,
            canonicalPath: canonicalPath ?? self.canonicalPath
        )
    }
}

private extension Phase2QualificationGateBundleSeal {
    func replacing(
        appExecutableSHA256: String? = nil,
        appResourceSealSHA256: String? = nil,
        workerExecutableSHA256: String? = nil,
        workerResourceSealSHA256: String? = nil,
        provenanceSHA256: String? = nil,
        wholeBundleManifestSHA256: String? = nil,
        appCDHash: String? = nil,
        workerCDHash: String? = nil
    ) -> Self {
        .init(
            appExecutableSHA256: appExecutableSHA256 ?? self.appExecutableSHA256,
            appResourceSealSHA256:
                appResourceSealSHA256 ?? self.appResourceSealSHA256,
            workerExecutableSHA256:
                workerExecutableSHA256 ?? self.workerExecutableSHA256,
            workerResourceSealSHA256:
                workerResourceSealSHA256 ?? self.workerResourceSealSHA256,
            provenanceSHA256: provenanceSHA256 ?? self.provenanceSHA256,
            wholeBundleManifestSHA256:
                wholeBundleManifestSHA256 ?? self.wholeBundleManifestSHA256,
            appCDHash: appCDHash ?? self.appCDHash,
            workerCDHash: workerCDHash ?? self.workerCDHash
        )
    }
}

private extension Phase2QualificationGateProviderCodeIdentity {
    func replacing(
        teamIdentifier: String? = nil,
        signatureFlags: UInt32? = nil,
        cdHash: String? = nil,
        canonicalBundlePath: String? = nil,
        executableSHA256: String? = nil
    ) -> Self {
        .init(
            identifier: identifier,
            teamIdentifier: teamIdentifier ?? self.teamIdentifier,
            signatureFlags: signatureFlags ?? self.signatureFlags,
            runtimeVersion: runtimeVersion,
            leafCertificateCommonName: leafCertificateCommonName,
            certificateCount: certificateCount,
            cdHash: cdHash ?? self.cdHash,
            canonicalBundlePath: canonicalBundlePath ?? self.canonicalBundlePath,
            executableSHA256: executableSHA256 ?? self.executableSHA256
        )
    }
}
