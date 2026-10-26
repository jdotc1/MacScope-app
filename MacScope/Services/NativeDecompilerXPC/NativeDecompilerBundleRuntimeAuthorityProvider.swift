import CryptoKit
import Darwin
import Foundation
import Security

protocol NativeDecompilerRuntimeAuthorityProviding: Sendable {
    func attestRuntimeAuthority() async throws -> NativeDecompilerRuntimeIdentity
}

enum NativeDecompilerRuntimeAuthorityAttestationError: Error, Equatable, Sendable {
    case bundleTopologyInvalid
    case peerRequirementRejected
    case buildEvidenceInvalid
    case packageManifestInvalid
    case packageTreeInvalid
    case sealedProfileMismatch
}

/// Derives native runtime authority only from the signed, bundle-local service and its governed
/// resources. A request or an XPC reply is deliberately not an input to this decision.
struct NativeDecompilerBundleRuntimeAuthorityProvider:
    NativeDecompilerRuntimeAuthorityProviding, Sendable
{
    typealias SignatureValidator = @Sendable (URL) throws -> Void
    typealias AttestationObserver = @Sendable (AttestationGate) -> Void

    enum AttestationGate: Sendable {
        case directoryGraphOpened
        case evidenceRead
        case packageHashed
        case beforeFinalRevalidation
    }

    private static let maximumGoldenBytes = 64 * 1_024
    private static let maximumManifestBytes = 1 * 1_024 * 1_024
    private static let maximumCodeResourcesBytes = 64 * 1_024 * 1_024
    private static let maximumPackageFiles = 100_000
    private static let maximumPackageBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    private static let maximumPackageFileBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    private static let appleSiliconCriticalFileRelativePaths = [
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AppleSilicon.ldefs",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_AppleSilicon.sla",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.pspec",
        "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_apple.cspec",
    ]

    private static let goldenKeys: Set<String> = [
        "architecture", "backendID", "contractArchiveSHA256",
        "contractBuildIdentitySHA256", "decompilerArchiveSHA256", "deploymentTarget",
        "engineGitRevision", "engineVersion", "goldenSourceSHA256",
        "materializationManifestSHA256", "materializationTreeSHA256", "objcMappingSHA256",
        "objcReplySHA256", "objcRequestSHA256", "packageBackedReplySHA256",
        "packageBackedRequestSHA256", "packageBackedSwiftReplySHA256", "passed",
        "schemaVersion", "sdkBuild", "sdkName", "sdkVersion", "sleighArchiveSHA256",
        "stageStampSHA256", "swiftCompilerVersion", "swiftReplySHA256",
        "swiftTargetTriple", "wrapperGitRevision", "wrapperVersion", "xcodeBuild", "xcodeVersion",
    ]
    private static let manifestKeys: Set<String> = [
        "artifact", "componentId", "ghidraGitRevision", "ghidraVersion", "package",
        "schemaVersion", "sleighGitRevision", "sleighVersion",
    ]
    private static let sourceManifestKeys = manifestKeys.subtracting(["artifact"]).union(["sourceBuild"])
    private static let artifactKeys: Set<String> = ["filename", "platform", "sha256", "url"]
    private static let packageKeys: Set<String> = [
        "cmakeConfigRelativePath", "criticalFileSha256", "decompilerLibraryRelativePath",
        "fileCount", "processorSpecRelativeRoot", "relativeRoot", "sleighLibraryRelativePath",
        "totalBytes", "treeSha256",
    ]
    private static let provenanceBaseKeys: Set<String> = [
        "ai_worker_bundle_identifier", "app_bundle_identifier", "architecture", "configuration",
        "deployment_target", "git_head_commit", "git_head_tree", "project_yml_sha256",
        "qualification_eligible", "repository_clean", "schema_version", "sdk_build", "sdk_name", "sdk_version",
        "selected_build_inputs_sha256", "swift_compiler_version", "swift_language_version",
        "swift_target_triple", "third_party_component_count", "third_party_component_ids",
        "third_party_distribution_status", "third_party_manifest_sha256",
        "third_party_notices_sha256", "third_party_public_distribution_approved", "xcode_build",
        "xcode_version", "xcodegen_version",
    ]
    private static let provenanceNativeKeys: Set<String> = [
        "native_decompiler_embedded_decompiler_archive_sha256",
        "native_decompiler_embedded_manifest_sha256",
        "native_decompiler_embedded_service_bundle_identifier",
        "native_decompiler_embedded_service_code_resources_sha256",
        "native_decompiler_embedded_service_executable_sha256",
        "native_decompiler_embedded_service_info_plist_sha256",
        "native_decompiler_embedded_sleigh_archive_sha256",
        "native_decompiler_embedded_tree_sha256", "native_decompiler_golden_result",
        "native_decompiler_golden_result_sha256",
    ]
    private static let provenanceDependencyRootKeys: Set<String> = [
        "dependency_root_authority", "ghostty_source_dir_sha256",
        "sleigh_materialization_root_sha256",
    ]
    private let appBundleURL: URL
    private let signatureValidator: SignatureValidator
    private let observer: AttestationObserver

    init(
        appBundleURL: URL = Bundle.main.bundleURL,
        signatureValidator: @escaping SignatureValidator = Self.validateSignature,
        attestationObserver: @escaping AttestationObserver = { _ in }
    ) {
        self.appBundleURL = appBundleURL
        self.signatureValidator = signatureValidator
        observer = attestationObserver
    }

    func attestRuntimeAuthority() async throws -> NativeDecompilerRuntimeIdentity {
        let appBundleURL = appBundleURL
        let signatureValidator = signatureValidator
        let observer = observer
        let worker = Task.detached(priority: .userInitiated) {
            try Self.attest(
                appBundleURL: appBundleURL,
                signatureValidator: signatureValidator,
                observer: observer
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private struct Metadata: Equatable {
        let device, inode, links, size: UInt64
        let mode: UInt16
        let modifiedSeconds, modifiedNanos, changedSeconds, changedNanos: Int64

        init(_ info: stat) {
            device = UInt64(info.st_dev); inode = UInt64(info.st_ino)
            links = UInt64(info.st_nlink); mode = UInt16(info.st_mode)
            size = info.st_size >= 0 ? UInt64(info.st_size) : .max
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanos = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    private final class DirectoryLease {
        let fd: Int32
        let metadata: Metadata
        let entries: Set<String>
        let parent: DirectoryLease?
        let name: String?

        init(root: URL) throws {
            var before = stat()
            guard root.path.withCString({ lstat($0, &before) }) == 0,
                  (before.st_mode & S_IFMT) == S_IFDIR
            else { throw Error.bundleTopologyInvalid }
            let opened = root.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard opened >= 0 else { throw Error.bundleTopologyInvalid }
            fd = opened; parent = nil; name = nil
            var after = stat()
            guard fstat(fd, &after) == 0, Metadata(before) == Metadata(after) else {
                close(fd); throw Error.bundleTopologyInvalid
            }
            metadata = Metadata(after)
            do { entries = try Self.readEntries(fd) } catch { close(fd); throw error }
        }

        init(parent: DirectoryLease, name: String) throws {
            guard Self.validName(name) else { throw Error.bundleTopologyInvalid }
            var before = stat()
            guard fstatat(parent.fd, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
                  (before.st_mode & S_IFMT) == S_IFDIR
            else { throw Error.bundleTopologyInvalid }
            let opened = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard opened >= 0 else { throw Error.bundleTopologyInvalid }
            fd = opened; self.parent = parent; self.name = name
            var after = stat()
            guard fstat(fd, &after) == 0, Metadata(before) == Metadata(after) else {
                close(fd); throw Error.bundleTopologyInvalid
            }
            metadata = Metadata(after)
            do { entries = try Self.readEntries(fd) } catch { close(fd); throw error }
        }

        deinit { close(fd) }

        func revalidate() throws {
            try Task.checkCancellation()
            var current = stat()
            guard fstat(fd, &current) == 0, Metadata(current) == metadata,
                  try Self.readEntries(fd) == entries
            else { throw Error.bundleTopologyInvalid }
            if let parent, let name {
                var linked = stat()
                guard fstatat(parent.fd, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                      Metadata(linked) == metadata
                else { throw Error.bundleTopologyInvalid }
            }
        }

        private static func readEntries(_ fd: Int32) throws -> Set<String> {
            let duplicate = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard duplicate >= 0, let directory = fdopendir(duplicate) else {
                if duplicate >= 0 { close(duplicate) }
                throw Error.bundleTopologyInvalid
            }
            defer { closedir(directory) }
            var result = Set<String>(); errno = 0
            while let entry = readdir(directory) {
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                if name != "." && name != ".." {
                    guard validName(name), result.insert(name).inserted else {
                        throw Error.bundleTopologyInvalid
                    }
                }
                errno = 0
            }
            guard errno == 0 else { throw Error.bundleTopologyInvalid }
            return result
        }

        private static func validName(_ name: String) -> Bool {
            !name.isEmpty && name != "." && name != ".." && !name.contains("/")
                && name.utf8.count <= Int(NAME_MAX)
        }
    }

    private struct FileBinding {
        let parent: DirectoryLease
        let name: String
        let metadata: Metadata

        func revalidate() throws {
            var current = stat()
            guard fstatat(parent.fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  Metadata(current) == metadata
            else { throw Error.bundleTopologyInvalid }
        }
    }

    private struct BundleGraph {
        let appResources, service, serviceContents, serviceResources: DirectoryLease
        let packageContainer, package, macOS, signature: DirectoryLease
        let all: [DirectoryLease]

        init(_ appURL: URL) throws {
            let app = try DirectoryLease(root: appURL)
            let contents = try DirectoryLease(parent: app, name: "Contents")
            appResources = try DirectoryLease(parent: contents, name: "Resources")
            let xpc = try DirectoryLease(parent: contents, name: "XPCServices")
            service = try DirectoryLease(parent: xpc, name: "NativeDecompilerXPCService.xpc")
            serviceContents = try DirectoryLease(parent: service, name: "Contents")
            serviceResources = try DirectoryLease(parent: serviceContents, name: "Resources")
            packageContainer = try DirectoryLease(parent: serviceResources, name: "NativeDecompilerPackage")
            package = try DirectoryLease(parent: packageContainer, name: "package")
            macOS = try DirectoryLease(parent: serviceContents, name: "MacOS")
            signature = try DirectoryLease(parent: serviceContents, name: "_CodeSignature")
            all = [app, contents, appResources, xpc, service, serviceContents, serviceResources,
                   packageContainer, package, macOS, signature]
            guard service.entries == ["Contents"],
                  serviceContents.entries == ["Info.plist", "MacOS", "Resources", "_CodeSignature"],
                  serviceResources.entries == ["NativeDecompilerBridgeGolden.json", "NativeDecompilerPackage"],
                  packageContainer.entries == ["MATERIALIZATION.json", "package"],
                  macOS.entries == ["NativeDecompilerXPCService"],
                  signature.entries == ["CodeResources"]
            else { throw Error.bundleTopologyInvalid }
        }

        func revalidate() throws { for directory in all { try directory.revalidate() } }
    }

    private struct PackageTree {
        let digest: String
        let count: Int
        let bytes: UInt64
        let digests: [String: String]
        let directories: [DirectoryLease]
        let files: [FileBinding]

        func revalidate() throws {
            for directory in directories { try directory.revalidate() }
            for file in files { try file.revalidate() }
        }
    }

    private struct Manifest {
        let treeDigest: String
        let count: Int
        let bytes: UInt64
        let criticalDigests: [String: String]
    }

    private typealias Error = NativeDecompilerRuntimeAuthorityAttestationError
    private typealias JSONObject = [String: Phase2ProductionJSONValue]

    private static func attest(
        appBundleURL: URL,
        signatureValidator: SignatureValidator,
        observer: AttestationObserver
    ) throws -> NativeDecompilerRuntimeIdentity {
        try Task.checkCancellation()
        let graph = try BundleGraph(appBundleURL)
        observer(.directoryGraphOpened); try Task.checkCancellation()
        let serviceURL = appBundleURL.appendingPathComponent(
            "Contents/XPCServices/NativeDecompilerXPCService.xpc", isDirectory: true
        )
        let leasedServiceURL = try descriptorURL(graph.service)
        guard leasedServiceURL.standardizedFileURL.path == serviceURL.standardizedFileURL.path else {
            throw Error.bundleTopologyInvalid
        }
        try graph.revalidate()
        do { try signatureValidator(leasedServiceURL) } catch { throw Error.peerRequirementRejected }
        try graph.revalidate()

        let goldenRead = try readFile(
            graph.serviceResources, "NativeDecompilerBridgeGolden.json", maximum: maximumGoldenBytes
        )
        let manifestRead = try readFile(
            graph.packageContainer, "MATERIALIZATION.json", maximum: maximumManifestBytes
        )
        let provenanceRead = try readFile(
            graph.appResources, "MacScopeBuildProvenance.json", maximum: maximumManifestBytes
        )
        let infoRead = try readFile(
            graph.serviceContents, "Info.plist", maximum: maximumManifestBytes
        )
        let executableRead = try readFile(
            graph.macOS, "NativeDecompilerXPCService", maximum: Int(maximumPackageFileBytes)
        )
        let codeResourcesRead = try readFile(
            graph.signature, "CodeResources", maximum: maximumCodeResourcesBytes
        )
        let evidenceBindings = [
            goldenRead.1, manifestRead.1, provenanceRead.1, infoRead.1,
            executableRead.1, codeResourcesRead.1,
        ]
        let goldenBytes = goldenRead.0
        let manifestBytes = manifestRead.0
        let provenanceBytes = provenanceRead.0
        let infoBytes = infoRead.0
        let executableBytes = executableRead.0
        let codeResourcesBytes = codeResourcesRead.0
        observer(.evidenceRead); try Task.checkCancellation()

        let golden = try canonicalObject(goldenBytes, keys: goldenKeys, error: .buildEvidenceInvalid)
        let manifestObject = try canonicalObject(
            manifestBytes, keys: manifestKeys, alternativeKeys: sourceManifestKeys,
            error: .packageManifestInvalid
        )
        let manifest = try parseManifest(manifestObject)
        try validateGolden(golden, manifest: manifest, manifestBytes: manifestBytes)
        let tree = try hashPackage(graph.package)
        observer(.packageHashed); try Task.checkCancellation()
        guard tree.digest == manifest.treeDigest, tree.count == manifest.count,
              tree.bytes == manifest.bytes
        else { throw Error.packageTreeInvalid }
        guard appleSiliconCriticalFileRelativePaths.allSatisfy({
                  manifest.criticalDigests[$0] != nil
                      && manifest.criticalDigests[$0] == tree.digests[$0]
              }),
              manifest.criticalDigests.allSatisfy({ tree.digests[$0.key] == $0.value })
        else { throw Error.packageTreeInvalid }
        let decompilerDigest = try digest(golden, "decompilerArchiveSHA256", .buildEvidenceInvalid)
        let sleighDigest = try digest(golden, "sleighArchiveSHA256", .buildEvidenceInvalid)
        guard tree.digests["lib/libdecomp.a"] == decompilerDigest,
              tree.digests["lib/libsla.a"] == sleighDigest
        else { throw Error.buildEvidenceInvalid }
        try validateProvenance(
            provenanceBytes, golden: golden, goldenBytes: goldenBytes,
            manifestBytes: manifestBytes, tree: tree, decompiler: decompilerDigest,
            sleigh: sleighDigest, info: infoBytes, executable: executableBytes,
            codeResources: codeResourcesBytes
        )

        let target = try NativeDecompilerSealedTargetProfile.normalizedTarget(
            rawCPUType: 0x0100_000c, rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "0", count: 64), selectedSliceByteCount: 1
        )
        guard target.languageID == "AARCH64:LE:64:AppleSilicon",
              target.compilerSpecID == "default",
              target.profileID == "apple-aarch64-pac-visible-clobber-v1"
        else { throw Error.sealedProfileMismatch }

        observer(.beforeFinalRevalidation); try Task.checkCancellation()
        try revalidate(evidenceBindings)
        try tree.revalidate(); try graph.revalidate()
        do { try signatureValidator(leasedServiceURL) } catch { throw Error.peerRequirementRejected }
        try revalidate(evidenceBindings)
        try tree.revalidate(); try graph.revalidate(); try Task.checkCancellation()
        return NativeDecompilerRuntimeIdentity(
            backendID: try string(golden, "backendID", .buildEvidenceInvalid),
            engineVersion: try string(golden, "engineVersion", .buildEvidenceInvalid),
            engineRevision: try string(golden, "engineGitRevision", .buildEvidenceInvalid),
            wrapperVersion: try string(golden, "wrapperVersion", .buildEvidenceInvalid),
            wrapperRevision: try digest(golden, "wrapperGitRevision", .buildEvidenceInvalid),
            packageManifestSHA256: try digest(golden, "materializationManifestSHA256", .buildEvidenceInvalid),
            packageTreeSHA256: try digest(golden, "materializationTreeSHA256", .buildEvidenceInvalid),
            languageID: target.languageID, compilerSpecID: target.compilerSpecID,
            targetProfileID: target.profileID, contextProfileSHA256: target.contextProfileSHA256
        )
    }

    private static func validateGolden(
        _ golden: JSONObject,
        manifest: Manifest,
        manifestBytes: Data
    ) throws {
        for key in goldenKeys where key.hasSuffix("SHA256") || key == "wrapperGitRevision" {
            _ = try digest(golden, key, .buildEvidenceInvalid)
        }
        let revision = try string(golden, "engineGitRevision", .buildEvidenceInvalid)
        guard try integer(golden, "schemaVersion", .buildEvidenceInvalid) == 1,
              try bool(golden, "passed", .buildEvidenceInvalid), isGitSHA1(revision),
              try string(golden, "architecture", .buildEvidenceInvalid) == "arm64",
              try string(golden, "backendID", .buildEvidenceInvalid) == "ghidra-native-decompiler",
              try string(golden, "wrapperVersion", .buildEvidenceInvalid) == "dcp05c-v1",
              try string(golden, "engineVersion", .buildEvidenceInvalid) == "12.1.2",
              revision == "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
              try string(golden, "deploymentTarget", .buildEvidenceInvalid) == "27.0",
              try string(golden, "swiftTargetTriple", .buildEvidenceInvalid).range(
                of: #"\Aarm64-apple-macosx27\.[0-9]+(?:\.[0-9]+)?\z"#, options: .regularExpression
              ) != nil,
              try string(golden, "sdkVersion", .buildEvidenceInvalid).hasPrefix("27."),
              try string(golden, "xcodeVersion", .buildEvidenceInvalid).hasPrefix("27."),
              try digest(golden, "materializationManifestSHA256", .buildEvidenceInvalid) == sha256(manifestBytes),
              try digest(golden, "materializationTreeSHA256", .buildEvidenceInvalid) == manifest.treeDigest
        else { throw Error.buildEvidenceInvalid }
    }

    private static func parseManifest(_ object: JSONObject) throws -> Manifest {
        let schema = try integer(object, "schemaVersion", .packageManifestInvalid)
        switch schema {
        case 1:
            guard Set(object.keys) == manifestKeys,
                  try string(object, "componentId", .packageManifestInvalid) == "sleigh-native-dcp03b4",
                  let artifact = object["artifact"]?.objectValue,
                  Set(artifact.keys) == artifactKeys,
                  try string(artifact, "platform", .packageManifestInvalid) == "macos-arm64",
                  try string(artifact, "filename", .packageManifestInvalid) == "macOS-sleigh-12.1.2-1.arm64.tar.gz",
                  try string(artifact, "url", .packageManifestInvalid) == "https://github.com/lifting-bits/sleigh/releases/download/v12.1.2/macOS-sleigh-12.1.2-1.arm64.tar.gz",
                  try digest(artifact, "sha256", .packageManifestInvalid) == "e1391c811de7b2d79c9e8a1f6f74cd9ade23baf55deebd75c626a3152e5e451a"
            else { throw Error.packageManifestInvalid }
        case 2:
            guard Set(object.keys) == sourceManifestKeys,
                  try string(object, "componentId", .packageManifestInvalid) == "sleigh-native-source-dcp03b4",
                  let sourceBuild = object["sourceBuild"]?.objectValue
            else { throw Error.packageManifestInvalid }
            try validateSourceBuild(sourceBuild)
        default:
            // Sanitizer schema 3 is developer evidence, never private-product runtime authority.
            throw Error.packageManifestInvalid
        }
        guard try string(object, "sleighVersion", .packageManifestInvalid) == "12.1.2",
              try string(object, "sleighGitRevision", .packageManifestInvalid) == "bfd38a983b4aa53dd386365e1df5ed5499b7e2fb",
              try string(object, "ghidraVersion", .packageManifestInvalid) == "12.1.2",
              try string(object, "ghidraGitRevision", .packageManifestInvalid) == "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
              let package = object["package"]?.objectValue,
              Set(package.keys) == packageKeys,
              try string(package, "relativeRoot", .packageManifestInvalid) == "package",
              try string(package, "processorSpecRelativeRoot", .packageManifestInvalid) == "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages",
              try string(package, "cmakeConfigRelativePath", .packageManifestInvalid) == "lib/cmake/sleigh/sleighConfig.cmake",
              try string(package, "decompilerLibraryRelativePath", .packageManifestInvalid) == "lib/libdecomp.a",
              try string(package, "sleighLibraryRelativePath", .packageManifestInvalid) == "lib/libsla.a",
              let criticalObject = package["criticalFileSha256"]?.objectValue,
              !criticalObject.isEmpty,
              let count = exactInt(package, "fileCount"), count > 0,
              let bytes = exactUInt64(package, "totalBytes"), bytes > 0
        else { throw Error.packageManifestInvalid }
        var criticalDigests = [String: String]()
        for path in criticalObject.keys {
            guard isSafeRelativePath(path) else { throw Error.packageManifestInvalid }
            criticalDigests[path] = try digest(
                criticalObject,
                path,
                .packageManifestInvalid
            )
        }
        return Manifest(
            treeDigest: try digest(package, "treeSha256", .packageManifestInvalid),
            count: count,
            bytes: bytes,
            criticalDigests: criticalDigests
        )
    }

    private static func validateSourceBuild(_ object: JSONObject) throws {
        // Exact canonical _source_static_evidence("none") from
        // Scripts/native-decompiler-direct/sleigh_package.py, including all pinned source
        // trees, patch paths/digests and offline build options. The compiler/tool locations
        // are bounded signed build evidence rather than fixed machine-path authority.
        var staticEvidence = Phase2ProductionJSONValue.object(
            object.filter { $0.key != "toolchain" }
        ).canonicalJSONBytes()
        staticEvidence.append(0x0A)
        guard sha256(staticEvidence) == "0a0fd1ab9285a988ab565361eeabe5383e21faeee5d8adb90aee0129fc144e70",
              let toolchain = object["toolchain"]?.objectValue,
              Set(toolchain.keys) == ["compiler", "cmake", "ninja"]
        else { throw Error.packageManifestInvalid }
        for name in ["compiler", "cmake", "ninja"] {
            guard let tool = toolchain[name]?.objectValue,
                  Set(tool.keys) == ["path", "sha256", "version"]
            else { throw Error.packageManifestInvalid }
            let path = try string(tool, "path", .packageManifestInvalid)
            let version = try string(tool, "version", .packageManifestInvalid)
            _ = try digest(tool, "sha256", .packageManifestInvalid)
            guard path.hasPrefix("/"),
                  !path.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }),
                  !version.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" })
            else { throw Error.packageManifestInvalid }
            let validVersion: Bool
            switch name {
            case "compiler": validVersion = version.hasPrefix("Apple clang version 21.")
            case "cmake": validVersion = version.range(
                of: #"^cmake version [0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression
            ) != nil
            default: validVersion = version.range(
                of: #"^[0-9]+\.[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression
            ) != nil
            }
            guard validVersion else { throw Error.packageManifestInvalid }
        }
    }

    private static func validateProvenance(
        _ bytes: Data,
        golden: JSONObject,
        goldenBytes: Data,
        manifestBytes: Data,
        tree: PackageTree,
        decompiler: String,
        sleigh: String,
        info: Data,
        executable: Data,
        codeResources: Data
    ) throws {
        let value: Phase2ProductionJSONValue
        do {
            value = try Phase2StrictJSONParser().parse(
                bytes,
                limits: .init(maximumBytes: bytes.count, maximumDepth: 12,
                              maximumTokens: 4_096, maximumMembersAndElements: 2_048)
            )
        } catch { throw Error.buildEvidenceInvalid }
        guard let object = value.objectValue else { throw Error.buildEvidenceInvalid }
        var newlineCanonical = value.canonicalJSONBytes(); newlineCanonical.append(0x0A)
        guard bytes == value.canonicalJSONBytes() || bytes == newlineCanonical,
              try integer(object, "schema_version", .buildEvidenceInvalid) == 1,
              try string(object, "architecture", .buildEvidenceInvalid) == "arm64",
              try string(object, "deployment_target", .buildEvidenceInvalid) == "27.0",
              try string(object, "swift_language_version", .buildEvidenceInvalid) == "6.0",
              try string(object, "app_bundle_identifier", .buildEvidenceInvalid) == "org.macscope.app",
              try string(object, "ai_worker_bundle_identifier", .buildEvidenceInvalid) == "org.macscope.app.AIAgentWorker",
              try string(object, "sdk_version", .buildEvidenceInvalid).hasPrefix("27."),
              try string(object, "sdk_name", .buildEvidenceInvalid).hasPrefix("macosx27.")
        else { throw Error.buildEvidenceInvalid }
        let configuration = try string(object, "configuration", .buildEvidenceInvalid)
        let qualificationEligible = try bool(
            object, "qualification_eligible", .buildEvidenceInvalid
        )
        let repositoryClean = try bool(object, "repository_clean", .buildEvidenceInvalid)
        let expectedProvenanceKeys = provenanceBaseKeys
            .union(provenanceNativeKeys)
            .union(configuration == "Release" ? provenanceDependencyRootKeys : [])
        if Set(object.keys) != expectedProvenanceKeys {
            // Share the current emitter's closed schema with qualification rather than
            // admitting arbitrary dependency fields here. Native package, golden and service
            // bytes are still independently bound below; parsed metadata never replaces them.
            guard configuration == "Release",
                  (try? Phase2QualificationGateBuildProvenance.parseCanonical(bytes)) != nil
            else { throw Error.buildEvidenceInvalid }
        }
        guard (configuration == "Release" && qualificationEligible && repositoryClean)
                || (configuration == "Debug" && !qualificationEligible && !repositoryClean),
              object["native_decompiler_golden_result"] == .object(golden),
              try digest(object, "native_decompiler_golden_result_sha256", .buildEvidenceInvalid) == sha256(goldenBytes),
              try digest(object, "native_decompiler_embedded_manifest_sha256", .buildEvidenceInvalid) == sha256(manifestBytes),
              try digest(object, "native_decompiler_embedded_tree_sha256", .buildEvidenceInvalid) == tree.digest,
              try digest(object, "native_decompiler_embedded_decompiler_archive_sha256", .buildEvidenceInvalid) == decompiler,
              try digest(object, "native_decompiler_embedded_sleigh_archive_sha256", .buildEvidenceInvalid) == sleigh,
              try string(object, "native_decompiler_embedded_service_bundle_identifier", .buildEvidenceInvalid) == "org.macscope.app.NativeDecompiler",
              try digest(object, "native_decompiler_embedded_service_info_plist_sha256", .buildEvidenceInvalid) == sha256(info),
              try digest(object, "native_decompiler_embedded_service_executable_sha256", .buildEvidenceInvalid) == sha256(executable),
              try digest(object, "native_decompiler_embedded_service_code_resources_sha256", .buildEvidenceInvalid) == sha256(codeResources)
        else { throw Error.buildEvidenceInvalid }
        let releaseDigestKeys = [
            "git_head_commit", "git_head_tree", "selected_build_inputs_sha256",
            "project_yml_sha256", "third_party_manifest_sha256", "third_party_notices_sha256",
        ]
        if configuration == "Release" {
            guard try string(object, "dependency_root_authority", .buildEvidenceInvalid)
                    == "xcode-resolved-build-settings",
                  try digest(object, "ghostty_source_dir_sha256", .buildEvidenceInvalid)
                    .count == 64,
                  try digest(object, "sleigh_materialization_root_sha256", .buildEvidenceInvalid)
                    .count == 64
            else { throw Error.buildEvidenceInvalid }
            for key in releaseDigestKeys {
                let evidence = try string(object, key, .buildEvidenceInvalid)
                guard key.hasPrefix("git_head_") ? isGitSHA1(evidence) : isSHA256(evidence) else {
                    throw Error.buildEvidenceInvalid
                }
            }
        } else {
            let debugSourceKeys = ["git_head_commit", "git_head_tree", "selected_build_inputs_sha256"]
            let debugSourceIdentityIsValid: Bool
            if debugSourceKeys.allSatisfy({ object[$0] == .null }) {
                debugSourceIdentityIsValid = true
            } else if case let .string(commit)? = object["git_head_commit"],
                      case let .string(tree)? = object["git_head_tree"],
                      case let .string(inputs)? = object["selected_build_inputs_sha256"] {
                debugSourceIdentityIsValid = isGitSHA1(commit) && isGitSHA1(tree) && isSHA256(inputs)
            } else {
                debugSourceIdentityIsValid = false
            }
            // Optional Debug source identity does not confer Release qualification.
            guard debugSourceIdentityIsValid,
                  releaseDigestKeys.filter({ !debugSourceKeys.contains($0) })
                    .allSatisfy({ object[$0] == .null }),
                  object["xcodegen_version"] == .null,
                  object["third_party_component_ids"]?.arrayValue?.isEmpty == true,
                  try integer(object, "third_party_component_count", .buildEvidenceInvalid) == 0,
                  object["third_party_distribution_status"] == .null,
                  try !bool(
                      object, "third_party_public_distribution_approved", .buildEvidenceInvalid
                  )
            else { throw Error.buildEvidenceInvalid }
        }
        for (provenanceKey, goldenKey) in [
            ("swift_target_triple", "swiftTargetTriple"),
            ("swift_compiler_version", "swiftCompilerVersion"),
            ("xcode_version", "xcodeVersion"), ("xcode_build", "xcodeBuild"),
            ("sdk_build", "sdkBuild"),
        ] where try string(object, provenanceKey, .buildEvidenceInvalid)
            != string(golden, goldenKey, .buildEvidenceInvalid) {
            throw Error.buildEvidenceInvalid
        }
    }

    private static func canonicalObject(
        _ bytes: Data,
        keys: Set<String>,
        alternativeKeys: Set<String>? = nil,
        error: Error
    ) throws -> JSONObject {
        do {
            let value = try Phase2StrictJSONParser().parse(
                bytes,
                limits: .init(maximumBytes: bytes.count, maximumDepth: 8,
                              maximumTokens: 2_048, maximumMembersAndElements: 1_024)
            )
            guard let object = value.objectValue,
                  Set(object.keys) == keys || Set(object.keys) == alternativeKeys
            else { throw error }
            var newlineCanonical = value.canonicalJSONBytes(); newlineCanonical.append(0x0A)
            guard bytes == value.canonicalJSONBytes() || bytes == newlineCanonical else { throw error }
            return object
        } catch let attestation as Error { throw attestation } catch { throw error }
    }

    private static func string(_ object: JSONObject, _ key: String, _ error: Error) throws -> String {
        guard let value = object[key]?.stringValue, !value.isEmpty, value.utf8.count <= 4_096
        else { throw error }
        return value
    }

    private static func digest(_ object: JSONObject, _ key: String, _ error: Error) throws -> String {
        let value = try string(object, key, error)
        guard isSHA256(value) else { throw error }
        return value
    }

    private static func bool(_ object: JSONObject, _ key: String, _ error: Error) throws -> Bool {
        guard let value = object[key]?.boolValue else { throw error }
        return value
    }

    private static func integer(_ object: JSONObject, _ key: String, _ error: Error) throws -> Int {
        guard let value = exactInt(object, key) else { throw error }
        return value
    }

    private static func exactInt(_ object: JSONObject, _ key: String) -> Int? {
        guard case let .number(raw)? = object[key], !raw.isEmpty,
              raw.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(raw)
    }

    private static func exactUInt64(_ object: JSONObject, _ key: String) -> UInt64? {
        guard case let .number(raw)? = object[key], !raw.isEmpty,
              raw.allSatisfy({ $0.isNumber }) else { return nil }
        return UInt64(raw)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    private static func isGitSHA1(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.utf8.count <= 4_096
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func readFile(
        _ parent: DirectoryLease,
        _ name: String,
        maximum: Int
    ) throws -> (Data, FileBinding) {
        try Task.checkCancellation()
        var beforeInfo = stat()
        guard fstatat(parent.fd, name, &beforeInfo, AT_SYMLINK_NOFOLLOW) == 0,
              (beforeInfo.st_mode & S_IFMT) == S_IFREG, beforeInfo.st_nlink == 1,
              beforeInfo.st_size >= 0
        else { throw Error.bundleTopologyInvalid }
        let before = Metadata(beforeInfo)
        guard before.size <= UInt64(maximum) else { throw Error.bundleTopologyInvalid }
        let fd = openat(parent.fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Error.bundleTopologyInvalid }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, Metadata(opened) == before else {
            throw Error.bundleTopologyInvalid
        }
        var result = Data(); result.reserveCapacity(Int(before.size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw Error.bundleTopologyInvalid }
            if count == 0 { break }
            result.append(buffer, count: count)
            guard result.count <= maximum else { throw Error.bundleTopologyInvalid }
        }
        let binding = FileBinding(parent: parent, name: name, metadata: before)
        guard UInt64(result.count) == before.size else { throw Error.bundleTopologyInvalid }
        try binding.revalidate()
        return (result, binding)
    }

    private static func revalidate(_ bindings: [FileBinding]) throws {
        for binding in bindings {
            try Task.checkCancellation()
            try binding.revalidate()
        }
    }

    private static func descriptorURL(_ directory: DirectoryLease) throws -> URL {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(directory.fd, F_GETPATH, &path) == 0 else {
            throw Error.bundleTopologyInvalid
        }
        let end = path.firstIndex(of: 0) ?? path.endIndex
        guard end > path.startIndex else { throw Error.bundleTopologyInvalid }
        let bytes = path[..<end].map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
    }

    private static func hashPackage(_ root: DirectoryLease) throws -> PackageTree {
        var directories = [root]
        var files = [(String, FileBinding)]()
        try collect(root, prefix: "", directories: &directories, files: &files)
        files.sort { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
        var treeHasher = SHA256(); var total: UInt64 = 0
        var digests = [String: String]()
        for (path, binding) in files {
            let read = try readFile(binding.parent, binding.name, maximum: Int(maximumPackageFileBytes))
            guard read.1.metadata == binding.metadata else { throw Error.bundleTopologyInvalid }
            let fileDigest = sha256(read.0)
            let next = total.addingReportingOverflow(UInt64(read.0.count))
            guard !next.overflow, next.partialValue <= maximumPackageBytes else {
                throw Error.packageTreeInvalid
            }
            total = next.partialValue
            treeHasher.update(data: Data(path.utf8)); treeHasher.update(data: Data([0]))
            treeHasher.update(data: Data(String(read.0.count).utf8)); treeHasher.update(data: Data([0]))
            treeHasher.update(data: Data(fileDigest.utf8)); treeHasher.update(data: Data([0]))
            digests[path] = fileDigest
        }
        return PackageTree(digest: hex(treeHasher.finalize()), count: files.count, bytes: total,
                           digests: digests, directories: directories, files: files.map(\.1))
    }

    private static func collect(
        _ directory: DirectoryLease,
        prefix: String,
        directories: inout [DirectoryLease],
        files: inout [(String, FileBinding)]
    ) throws {
        try Task.checkCancellation()
        for name in directory.entries.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            guard isSafeRelativePath(path) else { throw Error.packageTreeInvalid }
            var info = stat()
            guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Error.bundleTopologyInvalid
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                let child = try DirectoryLease(parent: directory, name: name)
                directories.append(child)
                try collect(child, prefix: path, directories: &directories, files: &files)
            case S_IFREG:
                guard info.st_nlink == 1, files.count < maximumPackageFiles,
                      UInt64(info.st_size) <= maximumPackageFileBytes
                else { throw Error.bundleTopologyInvalid }
                files.append((path, FileBinding(parent: directory, name: name, metadata: Metadata(info))))
            default: throw Error.bundleTopologyInvalid
            }
        }
    }

    private static func validateSignature(of serviceURL: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(serviceURL as CFURL, [], &code) == errSecSuccess,
              let code else { throw Error.peerRequirementRejected }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            NativeDecompilerXPCPeerRequirement.service as CFString, [], &requirement
        ) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidityWithErrors(
                code,
                SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)
                    | UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode)
                    | UInt32(kSecCSRestrictSymlinks) | UInt32(kSecCSRestrictSidebandData)
                    | 0x8000_0000 | 0x2000_0000), requirement, nil
              ) == errSecSuccess
        else { throw Error.peerRequirementRejected }
    }

    private static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
