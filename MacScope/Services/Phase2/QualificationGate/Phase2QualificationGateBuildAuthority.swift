import CryptoKit
import Darwin
import Foundation
@testable import MacScope
import Security


enum Phase2QualificationGateBuildAuthorityError: Error, Equatable, Sendable {
    case debugBuild
    case provenanceUnavailable
    case provenanceMalformed
    case provenanceNoncanonical
    case provenanceIneligible
    case codeUnavailable
    case codeInvalid(OSStatus)
    case codeIdentityInvalid
    case resourceSealInvalid
    case installationMismatch
    case gateRunnerInvalid

    var terminalCaseCode: String {
        switch self {
        case .debugBuild: "debug-build"
        case .provenanceUnavailable: "provenance-unavailable"
        case .provenanceMalformed: "provenance-malformed"
        case .provenanceNoncanonical: "provenance-noncanonical"
        case .provenanceIneligible: "provenance-ineligible"
        case .codeUnavailable: "code-unavailable"
        case .codeInvalid: "code-invalid"
        case .codeIdentityInvalid: "code-identity-invalid"
        case .resourceSealInvalid: "resource-seal-invalid"
        case .installationMismatch: "installation-mismatch"
        case .gateRunnerInvalid: "gate-runner-invalid"
        }
    }
}

/// Strict parser for the bounded resource emitted by the final MacScope Release build phase.
/// Unknown keys, duplicate keys, alternate whitespace, alternate ordering, and non-Release
/// placeholders all fail because accepted bytes must equal the one canonical encoding exactly.
struct Phase2QualificationGateBuildProvenance: Equatable, Sendable {
    static let maximumBytes = 16 * 1_024

    let schemaVersion: Int
    let qualificationEligible: Bool
    let configuration: String
    let gitHeadCommit: String
    let gitHeadTree: String
    let repositoryClean: Bool
    let selectedBuildInputsSHA256: String
    let projectYAMLSHA256: String
    let dependencyRootAuthority: String
    let ghosttySourceDirectorySHA256: String
    let sleighMaterializationRootSHA256: String
    let thirdPartyManifestSHA256: String
    let thirdPartyNoticesSHA256: String
    let thirdPartyComponentIDs: [String]
    let thirdPartyComponentCount: Int
    let thirdPartyDistributionStatus: String
    let thirdPartyPublicDistributionApproved: Bool
    let xcodegenVersion: String
    let xcodeVersion: String
    let xcodeBuild: String
    let swiftCompilerVersion: String
    let swiftTargetTriple: String
    let sdkName: String
    let sdkVersion: String
    let sdkBuild: String
    let swiftLanguageVersion: String
    let architecture: String
    let deploymentTarget: String
    let appBundleIdentifier: String
    let aiWorkerBundleIdentifier: String
    let canonicalBytes: Data

    private struct Wire: Decodable {
        let schemaVersion: Int
        let qualificationEligible: Bool
        let configuration: String
        let gitHeadCommit: String
        let gitHeadTree: String
        let repositoryClean: Bool
        let selectedBuildInputsSHA256: String
        let projectYAMLSHA256: String
        let dependencyRootAuthority: String
        let ghosttySourceDirectorySHA256: String
        let sleighMaterializationRootSHA256: String
        let thirdPartyManifestSHA256: String
        let thirdPartyNoticesSHA256: String
        let thirdPartyComponentIDs: [String]
        let thirdPartyComponentCount: Int
        let thirdPartyDistributionStatus: String
        let thirdPartyPublicDistributionApproved: Bool
        let xcodegenVersion: String
        let xcodeVersion: String
        let xcodeBuild: String
        let swiftCompilerVersion: String
        let swiftTargetTriple: String
        let sdkName: String
        let sdkVersion: String
        let sdkBuild: String
        let swiftLanguageVersion: String
        let architecture: String
        let deploymentTarget: String
        let appBundleIdentifier: String
        let aiWorkerBundleIdentifier: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case qualificationEligible = "qualification_eligible"
            case configuration
            case gitHeadCommit = "git_head_commit"
            case gitHeadTree = "git_head_tree"
            case repositoryClean = "repository_clean"
            case selectedBuildInputsSHA256 = "selected_build_inputs_sha256"
            case projectYAMLSHA256 = "project_yml_sha256"
            case dependencyRootAuthority = "dependency_root_authority"
            case ghosttySourceDirectorySHA256 = "ghostty_source_dir_sha256"
            case sleighMaterializationRootSHA256 = "sleigh_materialization_root_sha256"
            case thirdPartyManifestSHA256 = "third_party_manifest_sha256"
            case thirdPartyNoticesSHA256 = "third_party_notices_sha256"
            case thirdPartyComponentIDs = "third_party_component_ids"
            case thirdPartyComponentCount = "third_party_component_count"
            case thirdPartyDistributionStatus = "third_party_distribution_status"
            case thirdPartyPublicDistributionApproved =
                "third_party_public_distribution_approved"
            case xcodegenVersion = "xcodegen_version"
            case xcodeVersion = "xcode_version"
            case xcodeBuild = "xcode_build"
            case swiftCompilerVersion = "swift_compiler_version"
            case swiftTargetTriple = "swift_target_triple"
            case sdkName = "sdk_name"
            case sdkVersion = "sdk_version"
            case sdkBuild = "sdk_build"
            case swiftLanguageVersion = "swift_language_version"
            case architecture
            case deploymentTarget = "deployment_target"
            case appBundleIdentifier = "app_bundle_identifier"
            case aiWorkerBundleIdentifier = "ai_worker_bundle_identifier"
        }
    }

    static func parseCanonical(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              data.last == 0x0A,
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              wire.schemaVersion == 1,
              wire.qualificationEligible,
              wire.configuration == "Release",
              wire.repositoryClean,
              lowercaseHex(wire.gitHeadCommit, count: 40),
              lowercaseHex(wire.gitHeadTree, count: 40),
              lowercaseHex(wire.selectedBuildInputsSHA256, count: 64),
              lowercaseHex(wire.projectYAMLSHA256, count: 64),
              wire.dependencyRootAuthority == "xcode-resolved-build-settings",
              lowercaseHex(wire.ghosttySourceDirectorySHA256, count: 64),
              lowercaseHex(wire.sleighMaterializationRootSHA256, count: 64),
              validThirdPartyEvidence(wire),
              wire.architecture == "arm64",
              wire.deploymentTarget == "27.0",
              wire.swiftLanguageVersion == "6.0",
              majorVersion(wire.xcodeVersion) == 27,
              majorVersion(wire.sdkVersion) == 27,
              majorVersion(wire.swiftCompilerVersion) == 6,
              wire.sdkName.hasPrefix("macosx27."),
              wire.swiftTargetTriple.hasPrefix("arm64-apple-macosx27."),
              wire.appBundleIdentifier == "org.macscope.app",
              wire.aiWorkerBundleIdentifier == "org.macscope.app.AIAgentWorker",
              boundedBuildTokens(wire)
        else { throw Phase2QualificationGateBuildAuthorityError.provenanceIneligible }

        var object: [String: Any] = [
            "ai_worker_bundle_identifier": wire.aiWorkerBundleIdentifier,
            "app_bundle_identifier": wire.appBundleIdentifier,
            "architecture": wire.architecture,
            "configuration": wire.configuration,
            "deployment_target": wire.deploymentTarget,
            "dependency_root_authority": wire.dependencyRootAuthority,
            "git_head_commit": wire.gitHeadCommit,
            "git_head_tree": wire.gitHeadTree,
            "ghostty_source_dir_sha256": wire.ghosttySourceDirectorySHA256,
            "project_yml_sha256": wire.projectYAMLSHA256,
            "qualification_eligible": wire.qualificationEligible,
            "repository_clean": wire.repositoryClean,
            "schema_version": wire.schemaVersion,
            "sdk_build": wire.sdkBuild,
            "sdk_name": wire.sdkName,
            "sdk_version": wire.sdkVersion,
            "selected_build_inputs_sha256": wire.selectedBuildInputsSHA256,
            "sleigh_materialization_root_sha256": wire.sleighMaterializationRootSHA256,
            "swift_compiler_version": wire.swiftCompilerVersion,
            "swift_language_version": wire.swiftLanguageVersion,
            "swift_target_triple": wire.swiftTargetTriple,
            "third_party_component_count": wire.thirdPartyComponentCount,
            "third_party_component_ids": wire.thirdPartyComponentIDs,
            "third_party_distribution_status": wire.thirdPartyDistributionStatus,
            "third_party_manifest_sha256": wire.thirdPartyManifestSHA256,
            "third_party_notices_sha256": wire.thirdPartyNoticesSHA256,
            "third_party_public_distribution_approved":
                wire.thirdPartyPublicDistributionApproved,
            "xcode_build": wire.xcodeBuild,
            "xcode_version": wire.xcodeVersion,
            "xcodegen_version": wire.xcodegenVersion,
        ]
        let additionalEvidence = try approvedAdditionalEvidence(in: data, base: object)
        object.merge(additionalEvidence) { _, accepted in accepted }
        guard var canonical = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { throw Phase2QualificationGateBuildAuthorityError.provenanceMalformed }
        canonical.append(0x0A)
        guard canonical == data else {
            throw Phase2QualificationGateBuildAuthorityError.provenanceNoncanonical
        }
        return .init(
            schemaVersion: wire.schemaVersion,
            qualificationEligible: wire.qualificationEligible,
            configuration: wire.configuration,
            gitHeadCommit: wire.gitHeadCommit,
            gitHeadTree: wire.gitHeadTree,
            repositoryClean: wire.repositoryClean,
            selectedBuildInputsSHA256: wire.selectedBuildInputsSHA256,
            projectYAMLSHA256: wire.projectYAMLSHA256,
            dependencyRootAuthority: wire.dependencyRootAuthority,
            ghosttySourceDirectorySHA256: wire.ghosttySourceDirectorySHA256,
            sleighMaterializationRootSHA256: wire.sleighMaterializationRootSHA256,
            thirdPartyManifestSHA256: wire.thirdPartyManifestSHA256,
            thirdPartyNoticesSHA256: wire.thirdPartyNoticesSHA256,
            thirdPartyComponentIDs: wire.thirdPartyComponentIDs,
            thirdPartyComponentCount: wire.thirdPartyComponentCount,
            thirdPartyDistributionStatus: wire.thirdPartyDistributionStatus,
            thirdPartyPublicDistributionApproved:
                wire.thirdPartyPublicDistributionApproved,
            xcodegenVersion: wire.xcodegenVersion,
            xcodeVersion: wire.xcodeVersion,
            xcodeBuild: wire.xcodeBuild,
            swiftCompilerVersion: wire.swiftCompilerVersion,
            swiftTargetTriple: wire.swiftTargetTriple,
            sdkName: wire.sdkName,
            sdkVersion: wire.sdkVersion,
            sdkBuild: wire.sdkBuild,
            swiftLanguageVersion: wire.swiftLanguageVersion,
            architecture: wire.architecture,
            deploymentTarget: wire.deploymentTarget,
            appBundleIdentifier: wire.appBundleIdentifier,
            aiWorkerBundleIdentifier: wire.aiWorkerBundleIdentifier,
            canonicalBytes: data
        )
    }

    private static func boundedBuildTokens(_ value: Wire) -> Bool {
        [
            value.xcodegenVersion, value.xcodeVersion, value.xcodeBuild,
            value.swiftCompilerVersion, value.swiftTargetTriple, value.sdkName,
            value.sdkVersion, value.sdkBuild,
        ].allSatisfy { token in
            let bytes = token.utf8
            return !bytes.isEmpty && bytes.count <= 128 && bytes.allSatisfy { byte in
                (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                    || (0x30...0x39).contains(byte) || [0x2D, 0x2E, 0x5F, 0x2B].contains(byte)
            }
        }
    }


    /// The emitter has two supported closed shapes: the original 30-field record and the
    /// complete current dependency record. Never treat a partial group or an unknown field as
    /// opaque trusted metadata. The unchanged final byte comparison also rejects duplicates.
    private static func approvedAdditionalEvidence(
        in data: Data, base: [String: Any]
    ) throws -> [String: Any] {
        let invalid = Phase2QualificationGateBuildAuthorityError.provenanceIneligible
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalid
        }
        let additionalKeys = Set(source.keys).subtracting(base.keys)
        guard !additionalKeys.isEmpty else { return [:] }
        let currentKeys: Set<String> = [
            "ghostty_surface_archive_relative_path",
            "ghostty_surface_archive_sha256",
            "ghostty_surface_build_profile_sha256",
            "ghostty_surface_compilation_condition",
            "ghostty_surface_external_io_abi_version",
            "ghostty_surface_header_relative_path",
            "ghostty_surface_header_sha256",
            "ghostty_surface_module_map_relative_path",
            "ghostty_surface_module_map_sha256",
            "ghostty_surface_source_manifest_sha256",
            "ghostty_surface_source_revision",
            "ghostty_surface_source_sha256",
            "ghostty_surface_source_tree",
            "ghostty_surface_staged_descriptor_relative_path",
            "ghostty_surface_staged_descriptor_sha256",
            "ghostty_surface_staged_tree_sha256",
            "machokit_analysis_worker_compiled_identity",
            "machokit_analysis_worker_executable_sha256",
            "machokit_analysis_worker_executable_size",
            "machokit_governed_source_identity",
            "machokit_materialization_manifest_sha256",
            "machokit_materialization_root_sha256",
            "machokit_materialization_tree_sha256",
            "machokit_revision",
            "machokit_source_archive_sha256",
            "machokit_upstream_tree_sha256",
            "machokit_version",
            "native_decompiler_embedded_decompiler_archive_sha256",
            "native_decompiler_embedded_manifest_sha256",
            "native_decompiler_embedded_service_bundle_identifier",
            "native_decompiler_embedded_service_code_resources_sha256",
            "native_decompiler_embedded_service_executable_sha256",
            "native_decompiler_embedded_service_info_plist_sha256",
            "native_decompiler_embedded_sleigh_archive_sha256",
            "native_decompiler_embedded_tree_sha256",
            "native_decompiler_golden_result",
            "native_decompiler_golden_result_sha256",
            "sleigh_materialization_component_id",
            "sleigh_materialization_manifest_sha256",
            "sleigh_materialization_schema_version",
            "sleigh_materialization_tree_sha256",
        ]
        guard additionalKeys == currentKeys else { throw invalid }
        let digestKeys = [
            "ghostty_surface_archive_sha256",
            "ghostty_surface_build_profile_sha256",
            "ghostty_surface_header_sha256",
            "ghostty_surface_module_map_sha256",
            "ghostty_surface_source_manifest_sha256",
            "ghostty_surface_source_sha256",
            "ghostty_surface_staged_descriptor_sha256",
            "ghostty_surface_staged_tree_sha256",
            "machokit_analysis_worker_executable_sha256",
            "machokit_governed_source_identity",
            "machokit_materialization_manifest_sha256",
            "machokit_materialization_root_sha256",
            "machokit_materialization_tree_sha256",
            "machokit_source_archive_sha256",
            "machokit_upstream_tree_sha256",
            "native_decompiler_embedded_decompiler_archive_sha256",
            "native_decompiler_embedded_manifest_sha256",
            "native_decompiler_embedded_service_code_resources_sha256",
            "native_decompiler_embedded_service_executable_sha256",
            "native_decompiler_embedded_service_info_plist_sha256",
            "native_decompiler_embedded_sleigh_archive_sha256",
            "native_decompiler_embedded_tree_sha256",
            "native_decompiler_golden_result_sha256",
            "sleigh_materialization_manifest_sha256",
            "sleigh_materialization_tree_sha256",
        ]
        guard digestKeys.allSatisfy({ key in
            (source[key] as? String).map { lowercaseHex($0, count: 64) } == true
        }) else { throw invalid }
        for key in ["ghostty_surface_source_revision", "ghostty_surface_source_tree", "machokit_revision"] {
            guard let value = source[key] as? String, lowercaseHex(value, count: 40) else {
                throw invalid
            }
        }
        let exactStrings = [
            "ghostty_surface_compilation_condition": "MACSCOPE_FULL_GHOSTTY_SURFACE",
            "ghostty_surface_staged_descriptor_relative_path": "STAGED_GHOSTTY_SURFACE.json",
            "ghostty_surface_archive_relative_path": "libghostty-internal.a",
            "ghostty_surface_header_relative_path": "Headers/ghostty.h",
            "ghostty_surface_module_map_relative_path": "Headers/module.modulemap",
            "native_decompiler_embedded_service_bundle_identifier": "org.macscope.app.NativeDecompiler",
            "sleigh_materialization_component_id": "sleigh-native-source-dcp03b4",
        ]
        guard exactStrings.allSatisfy({ source[$0.key] as? String == $0.value }),
              strictInteger(source["ghostty_surface_external_io_abi_version"]) == 1,
              strictInteger(source["sleigh_materialization_schema_version"]) == 2,
              let executableSize = strictInteger(source["machokit_analysis_worker_executable_size"]),
              executableSize > 0,
              let version = source["machokit_version"] as? String,
              !version.isEmpty, version.utf8.count <= 32,
              version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              let identity = source["machokit_analysis_worker_compiled_identity"] as? [String: Any],
              Set(identity.keys) == ["schema", "revision", "governed_source_identity"],
              identity["schema"] as? String == "macscope-machokit-compiled-identity-v1",
              identity["revision"] as? String == source["machokit_revision"] as? String,
              identity["governed_source_identity"] as? String == source["machokit_governed_source_identity"] as? String
        else { throw invalid }

        guard let golden = source["native_decompiler_golden_result"] as? [String: Any] else {
            throw invalid
        }
        let goldenDigestKeys: Set<String> = [
            "contractArchiveSHA256",
            "contractBuildIdentitySHA256",
            "decompilerArchiveSHA256",
            "goldenSourceSHA256",
            "materializationManifestSHA256",
            "materializationTreeSHA256",
            "objcMappingSHA256",
            "objcReplySHA256",
            "objcRequestSHA256",
            "packageBackedReplySHA256",
            "packageBackedRequestSHA256",
            "packageBackedSwiftReplySHA256",
            "sleighArchiveSHA256",
            "stageStampSHA256",
            "swiftReplySHA256",
            "wrapperGitRevision",
        ]
        let goldenValueKeys: Set<String> = [
            "architecture", "backendID", "deploymentTarget", "engineGitRevision", "engineVersion",
            "passed", "schemaVersion", "sdkBuild", "sdkName", "sdkVersion", "swiftCompilerVersion",
            "swiftTargetTriple", "wrapperVersion", "xcodeBuild", "xcodeVersion",
        ]
        guard Set(golden.keys) == goldenDigestKeys.union(goldenValueKeys),
              goldenDigestKeys.allSatisfy({ key in
                  (golden[key] as? String).map { lowercaseHex($0, count: 64) } == true
              }),
              let engineRevision = golden["engineGitRevision"] as? String,
              lowercaseHex(engineRevision, count: 40),
              let engineVersion = golden["engineVersion"] as? String,
              !engineVersion.isEmpty, engineVersion.utf8.count <= 32,
              engineVersion.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              golden["backendID"] as? String == "ghidra-native-decompiler",
              golden["wrapperVersion"] as? String == "dcp05c-v1",
              let passed = golden["passed"] as? NSNumber,
              CFGetTypeID(passed) == CFBooleanGetTypeID(), passed.boolValue,
              strictInteger(golden["schemaVersion"]) == 1
        else { throw invalid }
        let goldenBindings = [
            "architecture": "architecture",
            "deploymentTarget": "deployment_target",
            "sdkBuild": "sdk_build",
            "sdkName": "sdk_name",
            "sdkVersion": "sdk_version",
            "swiftCompilerVersion": "swift_compiler_version",
            "swiftTargetTriple": "swift_target_triple",
            "xcodeBuild": "xcode_build",
            "xcodeVersion": "xcode_version",
            "materializationManifestSHA256": "native_decompiler_embedded_manifest_sha256",
            "materializationTreeSHA256": "native_decompiler_embedded_tree_sha256",
            "decompilerArchiveSHA256": "native_decompiler_embedded_decompiler_archive_sha256",
            "sleighArchiveSHA256": "native_decompiler_embedded_sleigh_archive_sha256",
        ]
        guard goldenBindings.allSatisfy({ golden[$0.key] as? String == source[$0.value] as? String }),
              source["sleigh_materialization_manifest_sha256"] as? String == source["native_decompiler_embedded_manifest_sha256"] as? String,
              source["sleigh_materialization_tree_sha256"] as? String == source["native_decompiler_embedded_tree_sha256"] as? String
        else { throw invalid }
        var goldenBytes = try JSONSerialization.data(
            withJSONObject: golden, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        goldenBytes.append(0x0A)
        let goldenDigest = SHA256.hash(data: goldenBytes).map { String(format: "%02x", $0) }.joined()
        guard source["native_decompiler_golden_result_sha256"] as? String == goldenDigest else {
            throw invalid
        }
        return source.filter { currentKeys.contains($0.key) }
    }

    private static func strictInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              String(cString: number.objCType) != "f", String(cString: number.objCType) != "d",
              number.doubleValue >= 0, number.doubleValue < Double(Int64.max) else { return nil }
        return number.int64Value
    }


    private static func validThirdPartyEvidence(_ value: Wire) -> Bool {
        guard lowercaseHex(value.thirdPartyManifestSHA256, count: 64),
              lowercaseHex(value.thirdPartyNoticesSHA256, count: 64),
              (1...512).contains(value.thirdPartyComponentCount),
              value.thirdPartyComponentIDs.count == value.thirdPartyComponentCount,
              value.thirdPartyComponentIDs == value.thirdPartyComponentIDs.sorted(),
              Set(value.thirdPartyComponentIDs).count == value.thirdPartyComponentIDs.count,
              value.thirdPartyComponentIDs.allSatisfy(validThirdPartyComponentID),
              value.thirdPartyDistributionStatus == "private-development-only"
                || value.thirdPartyDistributionStatus == "distribution-approved"
        else { return false }

        return value.thirdPartyPublicDistributionApproved
            == (value.thirdPartyDistributionStatus == "distribution-approved")
    }

    private static func validThirdPartyComponentID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard (2...64).contains(bytes.count), let first = bytes.first,
              lowercaseAlphaNumeric(first) else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            lowercaseAlphaNumeric(byte) || byte == 0x2D
        }
    }

    private static func lowercaseAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func majorVersion(_ value: String) -> Int? {
        value.split(separator: ".", maxSplits: 1).first.flatMap { Int($0) }
    }

    private static func lowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }
}

struct Phase2QualificationGateCodeIdentity: Equatable, Sendable {
    let identifier: String
    let teamIdentifier: String
    let signatureFlags: UInt32
    let runtimeVersion: UInt32
    let leafCertificateCommonName: String
    let certificateCount: Int
    let entitlementsMatchLocalDevelopmentPolicy: Bool
    let cdHash: String
    let canonicalPath: String
}

enum Phase2QualificationGateCodeIdentityPolicy {
    enum Role: Sendable {
        case app
        case worker
        case gateRunner
    }

    private static let approvedTeamIdentifier = "TEAM000000"
    private static let approvedLeafCertificate =
        "Apple Development: MacScope Developer (CERT000000)"
    private static let hardenedRuntimeFlag: UInt32 = 0x10000
    private static let adHocFlag: UInt32 = 0x0002

    static func accepts(_ value: Phase2QualificationGateCodeIdentity, role: Role) -> Bool {
        let expectedIdentifier = switch role {
        case .app: "org.macscope.app"
        case .worker: "org.macscope.app.AIAgentWorker"
        case .gateRunner: "org.macscope.app"
        }
        return value.identifier == expectedIdentifier
            && value.teamIdentifier == approvedTeamIdentifier
            && value.signatureFlags & hardenedRuntimeFlag == hardenedRuntimeFlag
            && value.signatureFlags & adHocFlag == 0
            && value.runtimeVersion > 0
            && value.leafCertificateCommonName == approvedLeafCertificate
            && value.certificateCount >= 2
            && value.entitlementsMatchLocalDevelopmentPolicy
            && lowerHex(value.cdHash, allowedCounts: [40, 64])
            && canonicalAbsolutePath(value.canonicalPath)
    }

    private static func lowerHex(_ value: String, allowedCounts: Set<Int>) -> Bool {
        allowedCounts.contains(value.utf8.count) && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func canonicalAbsolutePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 4_096, value.first == "/",
              !value.contains("\0") else { return false }
        return URL(fileURLWithPath: value).standardizedFileURL.path == value
    }
}

/// Canonical identity of every supported filesystem object in one `.app` tree.
///
/// The absolute root is intentionally excluded so a Release candidate can be compared with its
/// `/Applications` installation. Every relative path is encoded as its exact UTF-8 bytes after a
/// descriptor-anchored, no-follow walk. Directories and regular files bind their object type,
/// mode, and canonical logical size. Directory size is normalized to zero because APFS allocation
/// metadata may differ after `ditto`; regular files bind their exact size and a stable SHA-256 of
/// their complete contents.
/// Unsupported objects, hardlinks, aliases, path drift, and bounds violations fail closed.
struct Phase2QualificationGateBundleTreeIdentity: Equatable, Sendable {
    enum ObjectType: UInt8, Equatable, Sendable {
        case directory = 1
        case regularFile = 2
    }

    struct Entry: Equatable, Sendable {
        let relativePathUTF8: [UInt8]
        let objectType: ObjectType
        let mode: UInt32
        let size: Int64
        let contentSHA256: String?
    }

    static let maximumEntries = 50_000
    static let maximumRegularFiles = 40_000
    static let maximumDepth = 64
    static let maximumRelativePathBytes = 4_096
    static let maximumRegularFileBytes: Int64 = 2_147_483_648
    static let maximumTotalRegularFileBytes: Int64 = 8_589_934_592

    let entries: [Entry]
    let manifestSHA256: String
    let totalRegularFileBytes: Int64

    static func capture(at rootURL: URL) throws -> Self {
        try Collector.capture(at: rootURL)
    }

    func isByteIdentical(to other: Self) -> Bool {
        phase2IsSHA256Hex(manifestSHA256)
            && phase2IsSHA256Hex(other.manifestSHA256)
            && self == other
    }

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct Collector {
        private var entries: [Entry] = []
        private var observedObjects: Set<FileIdentity> = []
        private var regularFileCount = 0
        private var totalRegularFileBytes: Int64 = 0

        static func capture(at rootURL: URL) throws -> Phase2QualificationGateBundleTreeIdentity {
            var collector = Self()
            return try collector.captureRoot(at: rootURL)
        }

        private mutating func captureRoot(
            at rootURL: URL
        ) throws -> Phase2QualificationGateBundleTreeIdentity {
            let standardized = URL(fileURLWithPath: rootURL.path).standardizedFileURL
            guard rootURL.isFileURL,
                  rootURL.path == standardized.path,
                  rootURL.path.utf8.count <= maximumRelativePathBytes,
                  rootURL.resolvingSymlinksInPath().standardizedFileURL.path == rootURL.path
            else { throw invalid }

            var before = stat()
            let descriptor = rootURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path, Darwin.lstat(path, &before) == 0,
                      objectType(before.st_mode) == .directory else { return -1 }
                return Darwin.open(
                    path,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
                )
            }
            guard descriptor >= 0 else { throw invalid }
            defer { Darwin.close(descriptor) }

            var opened = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  sameSnapshot(before, opened) else { throw invalid }
            try register(opened)
            try appendEntry(
                path: Array(".".utf8),
                type: .directory,
                metadata: opened,
                contentSHA256: nil
            )
            try walkDirectory(
                descriptor,
                relativePath: [],
                depth: 0
            )

            var after = stat()
            var pathAfter = stat()
            let rootStillMatches = rootURL.withUnsafeFileSystemRepresentation { path in
                path != nil && Darwin.lstat(path!, &pathAfter) == 0
            }
            guard Darwin.fstat(descriptor, &after) == 0,
                  sameSnapshot(opened, after),
                  rootStillMatches,
                  sameSnapshot(after, pathAfter) else { throw invalid }

            entries.sort { lhs, rhs in
                lhs.relativePathUTF8.lexicographicallyPrecedes(rhs.relativePathUTF8)
            }
            let manifest = canonicalManifest(entries)
            return .init(
                entries: entries,
                manifestSHA256: SHA256.hash(data: manifest)
                    .map { String(format: "%02x", $0) }.joined(),
                totalRegularFileBytes: totalRegularFileBytes
            )
        }

        private mutating func walkDirectory(
            _ descriptor: Int32,
            relativePath: [UInt8],
            depth: Int
        ) throws {
            guard depth < maximumDepth else { throw invalid }
            let names = try directoryEntryNames(descriptor)
            for name in names {
                let childPath = relativePath.isEmpty
                    ? name : relativePath + [UInt8(ascii: "/")] + name
                guard !childPath.isEmpty,
                      childPath.count <= maximumRelativePathBytes else { throw invalid }
                try withNullTerminatedName(name) { pointer in
                    var before = stat()
                    guard Darwin.fstatat(
                        descriptor,
                        pointer,
                        &before,
                        AT_SYMLINK_NOFOLLOW
                    ) == 0,
                        let type = objectType(before.st_mode)
                    else { throw invalid }

                    switch type {
                    case .regularFile:
                        try captureRegularFile(
                            parent: descriptor,
                            name: pointer,
                            relativePath: childPath,
                            before: before
                        )
                    case .directory:
                        try captureDirectory(
                            parent: descriptor,
                            name: pointer,
                            relativePath: childPath,
                            depth: depth + 1,
                            before: before
                        )
                    }
                }
            }
        }

        private mutating func captureDirectory(
            parent: Int32,
            name: UnsafePointer<CChar>,
            relativePath: [UInt8],
            depth: Int,
            before: stat
        ) throws {
            let descriptor = Darwin.openat(
                parent,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            )
            guard descriptor >= 0 else { throw invalid }
            defer { Darwin.close(descriptor) }

            var opened = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  sameSnapshot(before, opened) else { throw invalid }
            try register(opened)
            try appendEntry(
                path: relativePath,
                type: .directory,
                metadata: opened,
                contentSHA256: nil
            )
            try walkDirectory(
                descriptor,
                relativePath: relativePath,
                depth: depth
            )

            var after = stat()
            var pathAfter = stat()
            guard Darwin.fstat(descriptor, &after) == 0,
                  sameSnapshot(opened, after),
                  Darwin.fstatat(
                      parent,
                      name,
                      &pathAfter,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  sameSnapshot(after, pathAfter) else { throw invalid }
        }

        private mutating func captureRegularFile(
            parent: Int32,
            name: UnsafePointer<CChar>,
            relativePath: [UInt8],
            before: stat
        ) throws {
            guard before.st_nlink == 1,
                  before.st_size >= 0,
                  before.st_size <= maximumRegularFileBytes,
                  regularFileCount < maximumRegularFiles else { throw invalid }
            let (prospectiveTotal, overflow) = totalRegularFileBytes
                .addingReportingOverflow(before.st_size)
            guard !overflow,
                  prospectiveTotal <= maximumTotalRegularFileBytes else { throw invalid }

            let descriptor = Darwin.openat(
                parent,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else { throw invalid }
            defer { Darwin.close(descriptor) }

            var opened = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  sameSnapshot(before, opened),
                  objectType(opened.st_mode) == .regularFile,
                  opened.st_nlink == 1 else { throw invalid }
            try register(opened)

            var hash = SHA256()
            var totalRead: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw invalid
                }
                let (next, readOverflow) = totalRead.addingReportingOverflow(Int64(count))
                guard !readOverflow,
                      next <= opened.st_size,
                      next <= maximumRegularFileBytes else { throw invalid }
                hash.update(data: Data(buffer[0..<count]))
                totalRead = next
            }

            var after = stat()
            var pathAfter = stat()
            guard Darwin.fstat(descriptor, &after) == 0,
                  sameSnapshot(opened, after),
                  totalRead == after.st_size,
                  Darwin.fstatat(
                      parent,
                      name,
                      &pathAfter,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  sameSnapshot(after, pathAfter) else { throw invalid }

            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            try appendEntry(
                path: relativePath,
                type: .regularFile,
                metadata: after,
                contentSHA256: digest
            )
            regularFileCount += 1
            totalRegularFileBytes = prospectiveTotal
        }

        private mutating func appendEntry(
            path: [UInt8],
            type: ObjectType,
            metadata: stat,
            contentSHA256: String?
        ) throws {
            guard entries.count < maximumEntries,
                  !path.isEmpty,
                  path.count <= maximumRelativePathBytes,
                  path.allSatisfy({ $0 != 0 }),
                  metadata.st_size >= 0,
                  type == .regularFile ? contentSHA256.map(phase2IsSHA256Hex) == true
                    : contentSHA256 == nil
            else { throw invalid }
            entries.append(.init(
                relativePathUTF8: path,
                objectType: type,
                mode: UInt32(metadata.st_mode),
                size: type == .regularFile ? metadata.st_size : 0,
                contentSHA256: contentSHA256
            ))
        }

        private mutating func register(_ metadata: stat) throws {
            let identity = FileIdentity(
                device: UInt64(metadata.st_dev),
                inode: UInt64(metadata.st_ino)
            )
            guard observedObjects.insert(identity).inserted else { throw invalid }
        }

        private func directoryEntryNames(_ descriptor: Int32) throws -> [[UInt8]] {
            let duplicate = Darwin.dup(descriptor)
            guard duplicate >= 0 else { throw invalid }
            guard let directory = Darwin.fdopendir(duplicate) else {
                Darwin.close(duplicate)
                throw invalid
            }
            defer { Darwin.closedir(directory) }

            var names: [[UInt8]] = []
            var observedNames: Set<Data> = []
            errno = 0
            while let entry = Darwin.readdir(directory) {
                let length = Int(entry.pointee.d_namlen)
                guard length > 0, length <= Int(NAME_MAX) else { throw invalid }
                let bytes = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(
                        to: UInt8.self,
                        capacity: Int(NAME_MAX) + 1
                    ) { rebound in
                        Array(UnsafeBufferPointer(start: rebound, count: length))
                    }
                }
                if bytes == Array(".".utf8) || bytes == Array("..".utf8) {
                    errno = 0
                    continue
                }
                guard String(bytes: bytes, encoding: .utf8) != nil,
                      !bytes.contains(0),
                      !bytes.contains(UInt8(ascii: "/")),
                      observedNames.insert(Data(bytes)).inserted else { throw invalid }
                names.append(bytes)
                errno = 0
            }
            guard errno == 0 else { throw invalid }
            names.sort { $0.lexicographicallyPrecedes($1) }
            return names
        }

        private func withNullTerminatedName<T>(
            _ bytes: [UInt8],
            _ body: (UnsafePointer<CChar>) throws -> T
        ) throws -> T {
            var name = bytes.map { CChar(bitPattern: $0) }
            name.append(0)
            return try name.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { throw invalid }
                return try body(baseAddress)
            }
        }

        private func objectType(_ mode: mode_t) -> ObjectType? {
            switch mode & S_IFMT {
            case S_IFDIR: .directory
            case S_IFREG: .regularFile
            default: nil
            }
        }

        private func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
            lhs.st_dev == rhs.st_dev
                && lhs.st_ino == rhs.st_ino
                && lhs.st_mode == rhs.st_mode
                && lhs.st_nlink == rhs.st_nlink
                && lhs.st_uid == rhs.st_uid
                && lhs.st_gid == rhs.st_gid
                && lhs.st_size == rhs.st_size
                && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
                && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
                && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
                && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
        }

        private func canonicalManifest(_ values: [Entry]) -> Data {
            var data = Data("MacScope.bundle-tree.v1\0".utf8)
            data.appendFixedWidth(UInt32(values.count))
            for value in values {
                data.appendFixedWidth(UInt32(value.relativePathUTF8.count))
                data.append(contentsOf: value.relativePathUTF8)
                data.append(value.objectType.rawValue)
                data.appendFixedWidth(value.mode)
                data.appendFixedWidth(UInt64(value.size))
                if let digest = value.contentSHA256 {
                    data.append(UInt8(64))
                    data.append(contentsOf: digest.utf8)
                } else {
                    data.append(UInt8(0))
                }
            }
            return data
        }

        private var invalid: Phase2QualificationGateBuildAuthorityError {
            .resourceSealInvalid
        }
    }
}

private extension Data {
    mutating func appendFixedWidth<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

struct Phase2QualificationGateBundleSeal: Equatable, Sendable {
    let appExecutableSHA256: String
    let appResourceSealSHA256: String
    let workerExecutableSHA256: String
    let workerResourceSealSHA256: String
    let provenanceSHA256: String
    let wholeBundleManifestSHA256: String
    let appCDHash: String
    let workerCDHash: String

    func isByteIdentical(to other: Self) -> Bool {
        isWellFormed && other.isWellFormed && self == other
    }

    private var isWellFormed: Bool {
        [
            appExecutableSHA256, appResourceSealSHA256, workerExecutableSHA256,
            workerResourceSealSHA256, provenanceSHA256, wholeBundleManifestSHA256,
        ].allSatisfy(phase2IsSHA256Hex)
            && [appCDHash, workerCDHash].allSatisfy { value in
                [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy {
                    (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
                }
            }
    }
}

/// Closed Release-app authority. The collector supplies no caller-injected paths, observations,
/// requirements, digests, or Security results. The same object also validates every connection-
/// bound AI-worker PID handed to the process authority.
@MainActor
final class Phase2QualificationGateBuildAuthority:
    Phase2QualificationGateWorkerProcessValidating
{
    let provenance: Phase2QualificationGateBuildProvenance
    let appExecutableSHA256: String
    let workerExecutableSHA256: String
    let signingRequirementSHA256: String

    private let capture: Phase2QualificationGateBuildAuthorityCapture

    private init(capture: Phase2QualificationGateBuildAuthorityCapture) {
        self.capture = capture
        provenance = capture.provenance
        appExecutableSHA256 = capture.candidateSeal.appExecutableSHA256
        workerExecutableSHA256 = capture.candidateSeal.workerExecutableSHA256
        signingRequirementSHA256 = SHA256.hash(
            data: Data(Phase2AIWorkerPeerRequirement.app.utf8)
        ).map { String(format: "%02x", $0) }.joined()
    }

    static func collectCurrent() throws -> Phase2QualificationGateBuildAuthority {
        try collectCurrent(installationMode: .stagedCandidate)
    }

    static func collectInstalledCanaryCurrent() throws -> Phase2QualificationGateBuildAuthority {
        try collectCurrent(installationMode: .installedCanary)
    }

    private static func collectCurrent(
        installationMode: Phase2QualificationGateInstallationMode
    ) throws -> Phase2QualificationGateBuildAuthority {
        #if DEBUG
        throw Phase2QualificationGateBuildAuthorityError.debugBuild
        #else
        return try .init(capture: Phase2QualificationGateBuildAuthoritySecurity.collectCurrent(
            installationMode: installationMode
        ))
        #endif
    }

    func isCurrent() -> Bool {
        Phase2QualificationGateBuildAuthoritySecurity.isCurrent(capture)
    }

    func validateWorkerProcess(
        receipt: Phase2InferenceWorkerProcessReceipt,
        observation: Phase2QualificationProcessObservation
    ) -> Bool {
        guard receipt.processIdentifier == observation.processID,
              observation.hasValidIdentity,
              observation.executableIdentity.sha256 == workerExecutableSHA256,
              isCurrent(),
              let identity = Phase2QualificationGateBuildAuthoritySecurity
                .activeWorkerIdentity(processID: receipt.processIdentifier),
              Phase2QualificationGateCodeIdentityPolicy.accepts(identity, role: .worker),
              identity.cdHash == capture.candidateWorkerIdentity.cdHash,
              identity.canonicalPath == capture.candidateWorkerIdentity.canonicalPath
        else { return false }
        return true
    }
}

private struct Phase2QualificationGateBuildAuthorityCapture {
    let provenance: Phase2QualificationGateBuildProvenance
    let candidateSeal: Phase2QualificationGateBundleSeal
    let installedSeal: Phase2QualificationGateBundleSeal
    let candidateTreeIdentity: Phase2QualificationGateBundleTreeIdentity
    let installedTreeIdentity: Phase2QualificationGateBundleTreeIdentity
    let candidateAppIdentity: Phase2QualificationGateCodeIdentity
    let candidateWorkerIdentity: Phase2QualificationGateCodeIdentity
    let installedAppIdentity: Phase2QualificationGateCodeIdentity
    let installedWorkerIdentity: Phase2QualificationGateCodeIdentity
    let gateRunnerIdentity: Phase2QualificationGateCodeIdentity
    let gateRunnerExecutableSHA256: String
    let dynamicSelfCode: SecCode
    let candidateAppCode: SecStaticCode
    let candidateWorkerCode: SecStaticCode
    let installedAppCode: SecStaticCode
    let installedWorkerCode: SecStaticCode
    let gateRunnerCode: SecStaticCode
}

/// Pure installation-equivalence policy over values already collected by the private Security
/// authority. Keeping this seam free of `Sec*`, `Bundle.main`, and conditional compilation lets
/// CoreTests exercise every refusal independently without widening the live collection surface.
enum Phase2QualificationGateInstallationMode: Sendable {
    case stagedCandidate
    case installedCanary
}

enum Phase2QualificationGateInstallationAdjudicator {
    static func adjudicate(
        installationMode: Phase2QualificationGateInstallationMode = .stagedCandidate,
        gateProcessAppURL: URL,
        candidateAppURL: URL,
        installedAppURL: URL,
        resolvedInstalledAppURL: URL,
        installedCodeAppURL: URL,
        candidateProvenance: Phase2QualificationGateBuildProvenance,
        installedProvenance: Phase2QualificationGateBuildProvenance,
        candidateSeal: Phase2QualificationGateBundleSeal,
        installedSeal: Phase2QualificationGateBundleSeal,
        candidateTreeIdentity: Phase2QualificationGateBundleTreeIdentity,
        installedTreeIdentity: Phase2QualificationGateBundleTreeIdentity,
        candidateAppIdentity: Phase2QualificationGateCodeIdentity,
        installedAppIdentity: Phase2QualificationGateCodeIdentity,
        candidateWorkerIdentity: Phase2QualificationGateCodeIdentity,
        installedWorkerIdentity: Phase2QualificationGateCodeIdentity,
        gateIdentity: Phase2QualificationGateCodeIdentity
    ) throws {
        guard gateProcessAppURL == candidateAppURL else {
            throw Phase2QualificationGateBuildAuthorityError.gateRunnerInvalid
        }
        guard resolvedInstalledAppURL.path == installedAppURL.path else {
            throw Phase2QualificationGateBuildAuthorityError.installationMismatch
        }
        switch installationMode {
        case .stagedCandidate:
            guard candidateAppURL != resolvedInstalledAppURL else {
                throw Phase2QualificationGateBuildAuthorityError.installationMismatch
            }
        case .installedCanary:
            guard installedAppURL.path == "/Applications/MacScope.app",
                  candidateAppURL == resolvedInstalledAppURL,
                  candidateAppIdentity == installedAppIdentity,
                  candidateWorkerIdentity == installedWorkerIdentity,
                  gateIdentity == candidateAppIdentity else {
                throw Phase2QualificationGateBuildAuthorityError.installationMismatch
            }
        }
        guard installedCodeAppURL == resolvedInstalledAppURL else {
            throw Phase2QualificationGateBuildAuthorityError.installationMismatch
        }
        guard candidateProvenance == installedProvenance,
              candidateSeal.isByteIdentical(to: installedSeal),
              candidateTreeIdentity.isByteIdentical(to: installedTreeIdentity),
              candidateAppIdentity.cdHash == installedAppIdentity.cdHash,
              candidateWorkerIdentity.cdHash == installedWorkerIdentity.cdHash
        else { throw Phase2QualificationGateBuildAuthorityError.installationMismatch }
        guard Phase2QualificationGateCodeIdentityPolicy.accepts(
            gateIdentity,
            role: .gateRunner
        ) else { throw Phase2QualificationGateBuildAuthorityError.gateRunnerInvalid }
    }
}

/// Xcode 27's Security module does not expose the common `SecCSFlags` C-enum cases as Swift
/// globals. Keep the values mirrored from Security/CSCommon.h in one audited policy instead of
/// weakening validation when those overlay names are unavailable. The call-specific static-code
/// flags below remain sourced from the SDK overlay.
enum Phase2QualificationGateSecurityValidationFlags {
    static let considerExpiration: UInt32 = 0x8000_0000 // 1 << 31
    static let noNetworkAccess: UInt32 = 0x2000_0000 // 1 << 29
    static let checkTrustedAnchors: UInt32 = 0x0800_0000 // 1 << 27
    static let matchGuestRequirementInKernel: UInt32 = 0x0080_0000 // 1 << 23

    static let sharedStrictFlags = considerExpiration
        | noNetworkAccess

    static let staticValidity = SecCSFlags(rawValue:
        UInt32(kSecCSCheckAllArchitectures)
            | UInt32(kSecCSCheckNestedCode)
            | UInt32(kSecCSStrictValidate)
            | sharedStrictFlags
            | UInt32(kSecCSRestrictSymlinks)
            | UInt32(kSecCSRestrictSidebandData)
    )

    static let dynamicValidity = SecCSFlags(rawValue:
        considerExpiration | noNetworkAccess
    )

    // SecCodeCopyGuestWithAttributes documents only default flags. Validation
    // policy belongs on the subsequent SecCodeCheckValidityWithErrors call.
    static let guestLookup = SecCSFlags()
}

private enum Phase2QualificationGateBuildAuthoritySecurity {
    private static let installedAppURL = URL(fileURLWithPath: "/Applications/MacScope.app")
    private static let workerRelativePath =
        "Contents/XPCServices/AIAgentWorkerXPCService.xpc"
    private static let provenanceRelativePath =
        "Contents/Resources/MacScopeBuildProvenance.json"
    private static let sealedProvenanceRelativePath =
        "Resources/MacScopeBuildProvenance.json"
    private static let appRequirement = Phase2AIWorkerPeerRequirement.app
    private static let workerRequirement = Phase2AIWorkerPeerRequirement.worker
    // The non-injected Gate executes in the exact candidate app process. Reusing the app's
    // designated requirement is stricter than accepting a separately injected test bundle and
    // preserves the AIAgentWorker peer requirement without any debugging entitlement.
    private static let gateRequirement = appRequirement

    private static let staticValidityFlags =
        Phase2QualificationGateSecurityValidationFlags.staticValidity
    private static let dynamicValidityFlags =
        Phase2QualificationGateSecurityValidationFlags.dynamicValidity

    static func collectCurrent(
        installationMode: Phase2QualificationGateInstallationMode
    ) throws -> Phase2QualificationGateBuildAuthorityCapture {
        let dynamicSelf = try copySelf()
        let appRequirement = try requirement(Self.appRequirement)
        try checkDynamic(dynamicSelf, requirement: appRequirement)
        let candidateAppCode = try copyStatic(dynamicSelf)
        let candidateAppURL = try canonicalBundleURL(
            candidateAppCode,
            pathExtension: "app"
        )
        let candidate = try collectBundle(
            appURL: candidateAppURL,
            appCode: candidateAppCode
        )
        let gateProcessAppURL = Bundle.main.bundleURL
            .resolvingSymlinksInPath().standardizedFileURL
        let exactInstalled = installedAppURL.resolvingSymlinksInPath().standardizedFileURL
        let installedAppCode = try staticCode(
            at: installedAppURL,
            requirement: Self.appRequirement
        )
        let installedCodeAppURL = try canonicalBundleURL(
            installedAppCode,
            pathExtension: "app"
        )
        let installed = try collectBundle(
            appURL: installedAppURL,
            appCode: installedAppCode
        )
        let gateCode = candidateAppCode
        let gateIdentity = candidate.appIdentity
        try Phase2QualificationGateInstallationAdjudicator.adjudicate(
            installationMode: installationMode,
            gateProcessAppURL: gateProcessAppURL,
            candidateAppURL: candidateAppURL,
            installedAppURL: installedAppURL,
            resolvedInstalledAppURL: exactInstalled,
            installedCodeAppURL: installedCodeAppURL,
            candidateProvenance: candidate.provenance,
            installedProvenance: installed.provenance,
            candidateSeal: candidate.seal,
            installedSeal: installed.seal,
            candidateTreeIdentity: candidate.treeIdentity,
            installedTreeIdentity: installed.treeIdentity,
            candidateAppIdentity: candidate.appIdentity,
            installedAppIdentity: installed.appIdentity,
            candidateWorkerIdentity: candidate.workerIdentity,
            installedWorkerIdentity: installed.workerIdentity,
            gateIdentity: gateIdentity
        )
        let gateDigest = candidate.seal.appExecutableSHA256

        return .init(
            provenance: candidate.provenance,
            candidateSeal: candidate.seal,
            installedSeal: installed.seal,
            candidateTreeIdentity: candidate.treeIdentity,
            installedTreeIdentity: installed.treeIdentity,
            candidateAppIdentity: candidate.appIdentity,
            candidateWorkerIdentity: candidate.workerIdentity,
            installedAppIdentity: installed.appIdentity,
            installedWorkerIdentity: installed.workerIdentity,
            gateRunnerIdentity: gateIdentity,
            gateRunnerExecutableSHA256: gateDigest,
            dynamicSelfCode: dynamicSelf,
            candidateAppCode: candidateAppCode,
            candidateWorkerCode: candidate.workerCode,
            installedAppCode: installedAppCode,
            installedWorkerCode: installed.workerCode,
            gateRunnerCode: gateCode
        )
    }

    static func isCurrent(_ capture: Phase2QualificationGateBuildAuthorityCapture) -> Bool {
        do {
            try checkDynamic(
                capture.dynamicSelfCode,
                requirement: requirement(appRequirement)
            )
            let validations: [(SecStaticCode, SecRequirement)] = [
                (capture.candidateAppCode, try requirement(appRequirement)),
                (capture.candidateWorkerCode, try requirement(workerRequirement)),
                (capture.installedAppCode, try requirement(appRequirement)),
                (capture.installedWorkerCode, try requirement(workerRequirement)),
                (capture.gateRunnerCode, try requirement(gateRequirement)),
            ]
            for (code, requirement) in validations {
                try checkStatic(code, requirement: requirement)
            }
            let candidateURL = URL(fileURLWithPath: capture.candidateAppIdentity.canonicalPath)
            let installedURL = URL(fileURLWithPath: capture.installedAppIdentity.canonicalPath)
            let candidate = try collectBundle(
                appURL: candidateURL,
                appCode: capture.candidateAppCode
            )
            let installed = try collectBundle(
                appURL: installedURL,
                appCode: capture.installedAppCode
            )
            let gateDigest = candidate.seal.appExecutableSHA256
            let currentGateIdentity = try codeIdentity(capture.gateRunnerCode)
            return candidate.provenance == capture.provenance
                && installed.provenance == capture.provenance
                && candidate.seal == capture.candidateSeal
                && installed.seal == capture.installedSeal
                && candidate.seal.isByteIdentical(to: installed.seal)
                && candidate.treeIdentity == capture.candidateTreeIdentity
                && installed.treeIdentity == capture.installedTreeIdentity
                && candidate.treeIdentity.isByteIdentical(to: installed.treeIdentity)
                && candidate.appIdentity == capture.candidateAppIdentity
                && candidate.workerIdentity == capture.candidateWorkerIdentity
                && installed.appIdentity == capture.installedAppIdentity
                && installed.workerIdentity == capture.installedWorkerIdentity
                && currentGateIdentity == capture.gateRunnerIdentity
                && gateDigest == capture.gateRunnerExecutableSHA256
        } catch {
            return false
        }
    }

    static func activeWorkerIdentity(processID: Int32) -> Phase2QualificationGateCodeIdentity? {
        guard processID > 1 else { return nil }
        do {
            var guest: SecCode?
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: processID)]
                as CFDictionary
            let status = SecCodeCopyGuestWithAttributes(
                nil,
                attributes,
                Phase2QualificationGateSecurityValidationFlags.guestLookup,
                &guest
            )
            guard status == errSecSuccess, let guest else {
                throw Phase2QualificationGateBuildAuthorityError.codeInvalid(status)
            }
            let requirement = try requirement(workerRequirement)
            try checkDynamic(guest, requirement: requirement)
            return try codeIdentity(copyStatic(guest))
        } catch {
            return nil
        }
    }

    private struct BundleCapture {
        let provenance: Phase2QualificationGateBuildProvenance
        let seal: Phase2QualificationGateBundleSeal
        let treeIdentity: Phase2QualificationGateBundleTreeIdentity
        let appIdentity: Phase2QualificationGateCodeIdentity
        let workerIdentity: Phase2QualificationGateCodeIdentity
        let workerCode: SecStaticCode
    }

    private static func collectBundle(
        appURL: URL,
        appCode: SecStaticCode
    ) throws -> BundleCapture {
        try checkStatic(appCode, requirement: requirement(appRequirement))
        let appIdentity = try codeIdentity(appCode)
        guard Phase2QualificationGateCodeIdentityPolicy.accepts(appIdentity, role: .app),
              appIdentity.canonicalPath == appURL.resolvingSymlinksInPath().standardizedFileURL.path
        else { throw Phase2QualificationGateBuildAuthorityError.codeIdentityInvalid }

        let workerURL = appURL.appendingPathComponent(workerRelativePath, isDirectory: true)
        let workerCode = try staticCode(at: workerURL, requirement: workerRequirement)
        let workerIdentity = try codeIdentity(workerCode)
        guard Phase2QualificationGateCodeIdentityPolicy.accepts(workerIdentity, role: .worker),
              workerIdentity.canonicalPath
                == workerURL.resolvingSymlinksInPath().standardizedFileURL.path
        else { throw Phase2QualificationGateBuildAuthorityError.codeIdentityInvalid }

        let provenanceFile = try Phase2QualificationGateRegularFile.read(
            appURL.appendingPathComponent(provenanceRelativePath),
            maximumBytes: Int64(Phase2QualificationGateBuildProvenance.maximumBytes),
            retainBytes: true
        )
        let provenance = try Phase2QualificationGateBuildProvenance.parseCanonical(
            provenanceFile.data
        )
        guard SecCodeValidateFileResource(
            appCode,
            sealedProvenanceRelativePath as CFString,
            provenanceFile.data as CFData,
            SecCSFlags()
        ) == errSecSuccess else {
            throw Phase2QualificationGateBuildAuthorityError.resourceSealInvalid
        }

        let appExecutable = try Phase2QualificationGateRegularFile.read(
            appURL.appendingPathComponent("Contents/MacOS/MacScope"),
            maximumBytes: 1_073_741_824,
            retainBytes: false
        )
        let appResources = try Phase2QualificationGateRegularFile.read(
            appURL.appendingPathComponent("Contents/_CodeSignature/CodeResources"),
            maximumBytes: 16 * 1_024 * 1_024,
            retainBytes: false
        )
        let workerExecutable = try Phase2QualificationGateRegularFile.read(
            workerURL.appendingPathComponent("Contents/MacOS/AIAgentWorkerXPCService"),
            maximumBytes: 1_073_741_824,
            retainBytes: false
        )
        let workerResources = try Phase2QualificationGateRegularFile.read(
            workerURL.appendingPathComponent("Contents/_CodeSignature/CodeResources"),
            maximumBytes: 16 * 1_024 * 1_024,
            retainBytes: false
        )
        let treeIdentity = try Phase2QualificationGateBundleTreeIdentity.capture(at: appURL)
        let seal = Phase2QualificationGateBundleSeal(
            appExecutableSHA256: appExecutable.sha256,
            appResourceSealSHA256: appResources.sha256,
            workerExecutableSHA256: workerExecutable.sha256,
            workerResourceSealSHA256: workerResources.sha256,
            provenanceSHA256: provenanceFile.sha256,
            wholeBundleManifestSHA256: treeIdentity.manifestSHA256,
            appCDHash: appIdentity.cdHash,
            workerCDHash: workerIdentity.cdHash
        )
        guard seal.isByteIdentical(to: seal) else {
            throw Phase2QualificationGateBuildAuthorityError.resourceSealInvalid
        }
        return .init(
            provenance: provenance,
            seal: seal,
            treeIdentity: treeIdentity,
            appIdentity: appIdentity,
            workerIdentity: workerIdentity,
            workerCode: workerCode
        )
    }

    private static func copySelf() throws -> SecCode {
        var code: SecCode?
        let status = SecCodeCopySelf(SecCSFlags(), &code)
        guard status == errSecSuccess, let code else {
            throw Phase2QualificationGateBuildAuthorityError.codeInvalid(status)
        }
        return code
    }

    private static func copyStatic(_ code: SecCode) throws -> SecStaticCode {
        var staticCode: SecStaticCode?
        let status = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw Phase2QualificationGateBuildAuthorityError.codeInvalid(status)
        }
        return staticCode
    }

    private static func staticCode(
        at url: URL,
        requirement expression: String
    ) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code)
        guard status == errSecSuccess, let code else {
            throw Phase2QualificationGateBuildAuthorityError.codeInvalid(status)
        }
        try checkStatic(code, requirement: requirement(expression))
        return code
    }

    private static func requirement(_ expression: String) throws -> SecRequirement {
        var value: SecRequirement?
        let status = SecRequirementCreateWithString(
            expression as CFString,
            SecCSFlags(),
            &value
        )
        guard status == errSecSuccess, let value else {
            throw Phase2QualificationGateBuildAuthorityError.codeInvalid(status)
        }
        return value
    }

    private static func checkDynamic(
        _ code: SecCode,
        requirement: SecRequirement
    ) throws {
        let status = SecCodeCheckValidityWithErrors(
            code,
            dynamicValidityFlags,
            requirement,
            nil
        )
        guard status == errSecSuccess else {
            throw Phase2QualificationGateBuildAuthorityError.codeInvalid(status)
        }
    }

    private static func checkStatic(
        _ code: SecStaticCode,
        requirement: SecRequirement
    ) throws {
        let status = SecStaticCodeCheckValidityWithErrors(
            code,
            staticValidityFlags,
            requirement,
            nil
        )
        guard status == errSecSuccess else {
            throw Phase2QualificationGateBuildAuthorityError.codeInvalid(status)
        }
    }

    private static func canonicalBundleURL(
        _ code: SecStaticCode,
        pathExtension requiredExtension: String
    ) throws -> URL {
        var value: CFURL?
        let status = SecCodeCopyPath(code, SecCSFlags(), &value)
        guard status == errSecSuccess, let value else {
            throw Phase2QualificationGateBuildAuthorityError.codeInvalid(status)
        }
        var cursor = value as URL
        cursor = cursor.resolvingSymlinksInPath().standardizedFileURL
        while cursor.path != "/", cursor.pathExtension != requiredExtension {
            cursor.deleteLastPathComponent()
        }
        guard cursor.pathExtension == requiredExtension else {
            throw Phase2QualificationGateBuildAuthorityError.codeIdentityInvalid
        }
        return cursor
    }

    private static func codeIdentity(
        _ code: SecStaticCode
    ) throws -> Phase2QualificationGateCodeIdentity {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        let status = SecCodeCopySigningInformation(code, flags, &information)
        guard status == errSecSuccess,
              let info = information as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let signatureFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value,
              let runtimeVersion = (info[kSecCodeInfoRuntimeVersion as String] as? NSNumber)?
                .uint32Value,
              let cdHashData = info[kSecCodeInfoUnique as String] as? Data,
              let certificates = info[kSecCodeInfoCertificates as String]
                as? [SecCertificate],
              let leaf = certificates.first,
              let leafName = certificateCommonName(leaf)
        else { throw Phase2QualificationGateBuildAuthorityError.codeIdentityInvalid }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let opaqueEntitlements = info[kSecCodeInfoEntitlements as String] as? Data
        let entitlementsMatchLocalDevelopmentPolicy =
            entitlementMapMatchesLocalDevelopmentPolicy(entitlements)
            && entitlementBlobMatchesLocalDevelopmentPolicy(opaqueEntitlements)
        let path = try canonicalBundleURL(
            code,
            pathExtension: identifier == "org.macscope.app" ? "app"
                : identifier == "org.macscope.app.CoreTests" ? "xctest" : "xpc"
        )
        return .init(
            identifier: identifier,
            teamIdentifier: team,
            signatureFlags: signatureFlags,
            runtimeVersion: runtimeVersion,
            leafCertificateCommonName: leafName,
            certificateCount: certificates.count,
            entitlementsMatchLocalDevelopmentPolicy: entitlementsMatchLocalDevelopmentPolicy,
            cdHash: cdHashData.map { String(format: "%02x", $0) }.joined(),
            canonicalPath: path.path
        )
    }

    private static func entitlementBlobMatchesLocalDevelopmentPolicy(
        _ entitlements: Data?
    ) -> Bool {
        guard let entitlements else { return true }
        guard let object = try? PropertyListSerialization.propertyList(
            from: entitlements,
            options: [],
            format: nil
        ), let value = object as? [String: Any] else { return false }
        return entitlementMapMatchesLocalDevelopmentPolicy(value)
    }

    private static func entitlementMapMatchesLocalDevelopmentPolicy(
        _ entitlements: [String: Any]?
    ) -> Bool {
        guard let entitlements, !entitlements.isEmpty else { return true }
        guard entitlements.count == 1,
              let value = entitlements["com.apple.security.get-task-allow"]
        else { return false }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        return false
    }

    private static func certificateCommonName(_ value: SecCertificate) -> String? {
        var name: CFString?
        guard SecCertificateCopyCommonName(value, &name) == errSecSuccess else { return nil }
        return name as String?
    }
}

private struct Phase2QualificationGateRegularFile {
    let data: Data
    let sha256: String

    static func read(
        _ url: URL,
        maximumBytes: Int64,
        retainBytes: Bool
    ) throws -> Self {
        guard maximumBytes >= 0 else {
            throw Phase2QualificationGateBuildAuthorityError.resourceSealInvalid
        }
        var before = stat()
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path, Darwin.lstat(path, &before) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_size >= 0,
                  before.st_size <= maximumBytes else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw Phase2QualificationGateBuildAuthorityError.resourceSealInvalid
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0, sameFile(before, opened) else {
            throw Phase2QualificationGateBuildAuthorityError.resourceSealInvalid
        }

        var hash = SHA256()
        var retained = Data()
        if retainBytes { retained.reserveCapacity(Int(opened.st_size)) }
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw Phase2QualificationGateBuildAuthorityError.resourceSealInvalid
            }
            let (next, overflow) = total.addingReportingOverflow(Int64(count))
            guard !overflow, next <= maximumBytes else {
                throw Phase2QualificationGateBuildAuthorityError.resourceSealInvalid
            }
            let chunk = Data(buffer[0..<count])
            hash.update(data: chunk)
            if retainBytes { retained.append(chunk) }
            total = next
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              sameFile(opened, after), total == after.st_size else {
            throw Phase2QualificationGateBuildAuthorityError.resourceSealInvalid
        }
        return .init(
            data: retained,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
