import CryptoKit
import Darwin
import Foundation

enum WS24InstalledAppQualificationGate: String, CaseIterable, Codable, Hashable, Sendable {
    case sealedReleaseProvenance = "sealed-release-provenance"
    case localSigningPolicy = "local-signing-policy"
    case sourceInstallEquality = "source-install-equality"
    case installedLaunchSmoke = "installed-launch-smoke"
    case directDebuggerTransportContracts = "direct-debugger-transport-contracts"
    case repeatedLaunchDetachStress = "repeated-launch-detach-stress"
    case repeatedAttachDetachStress = "repeated-attach-detach-stress"
    case repeatedRestartStress = "repeated-restart-stress"
    case incrementalXCUITest = "incremental-xcuitest"
    case securityGate = "security-gate"
    case performanceGate = "performance-gate"
    case supportedToolchainMatrix = "supported-toolchain-matrix"

    var minimumAcceptedAttempts: Int {
        switch self {
        case .repeatedLaunchDetachStress,
             .repeatedAttachDetachStress,
             .repeatedRestartStress:
            10
        default:
            1
        }
    }
}

enum WS24InstalledAppQualificationEvidenceStatus: String, Codable, Hashable, Sendable {
    case passed
    case failed
}

struct WS24InstalledAppQualificationEvidence: Codable, Hashable, Sendable {
    let gate: WS24InstalledAppQualificationGate
    let status: WS24InstalledAppQualificationEvidenceStatus
    let sourceCommit: String
    let installedExecutableSHA256: String
    let acceptedAttempts: Int

    init(
        gate: WS24InstalledAppQualificationGate,
        status: WS24InstalledAppQualificationEvidenceStatus,
        sourceCommit: String,
        installedExecutableSHA256: String,
        acceptedAttempts: Int = 1
    ) {
        self.gate = gate
        self.status = status
        self.sourceCommit = sourceCommit
        self.installedExecutableSHA256 = installedExecutableSHA256
        self.acceptedAttempts = acceptedAttempts
    }
}

enum WS24InstalledAppQualificationDeficiencyCode: String, Codable, Hashable, Sendable {
    case missingRequiredGate = "missing-required-gate"
    case duplicateGateEvidence = "duplicate-gate-evidence"
    case gateFailed = "gate-failed"
    case staleSourceCommit = "stale-source-commit"
    case emptyInstalledExecutableDigest = "empty-installed-executable-digest"
    case malformedInstalledExecutableDigest = "malformed-installed-executable-digest"
    case inconsistentInstalledExecutableDigest = "inconsistent-installed-executable-digest"
    case insufficientAcceptedAttempts = "insufficient-accepted-attempts"
}

struct WS24InstalledAppQualificationDeficiency: Codable, Hashable, Sendable {
    let code: WS24InstalledAppQualificationDeficiencyCode
    let gate: WS24InstalledAppQualificationGate?

    init(
        _ code: WS24InstalledAppQualificationDeficiencyCode,
        gate: WS24InstalledAppQualificationGate? = nil
    ) {
        self.code = code
        self.gate = gate
    }
}

struct WS24InstalledAppQualificationSummary: Codable, Hashable, Sendable {
    let sourceCommit: String
    let installedExecutableSHA256: String
    let acceptedGates: [WS24InstalledAppQualificationGate]
}

enum WS24InstalledAppQualificationResult: Hashable, Sendable {
    case accepted(WS24InstalledAppQualificationSummary)
    case rejected([WS24InstalledAppQualificationDeficiency])
}

struct WS24InstalledAppQualificationReport: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let sourceCommit: String
    let installedExecutableSHA256: String
    let generatedAtUnixMilliseconds: Int64?
    let evidence: [WS24InstalledAppQualificationEvidence]
    let accepted: Bool
    let acceptedGates: [WS24InstalledAppQualificationGate]
    let deficiencies: [WS24InstalledAppQualificationDeficiency]
    let performanceThresholds: PerformanceThresholdsSnapshot

    init(
        sourceCommit: String,
        installedExecutableSHA256: String,
        generatedAtUnixMilliseconds: Int64? = nil,
        evidence: [WS24InstalledAppQualificationEvidence],
        result: WS24InstalledAppQualificationResult,
        performanceThresholds: WS24InstalledAppPerformanceThresholds = .init()
    ) {
        self.schemaVersion = 1
        self.sourceCommit = sourceCommit
        self.installedExecutableSHA256 = installedExecutableSHA256
        self.generatedAtUnixMilliseconds = generatedAtUnixMilliseconds
        self.evidence = Self.canonicalEvidence(evidence)
        self.performanceThresholds = .init(performanceThresholds)
        switch result {
        case .accepted(let summary):
            self.accepted = true
            self.acceptedGates = summary.acceptedGates.sorted { $0.rawValue < $1.rawValue }
            self.deficiencies = []
        case .rejected(let deficiencies):
            self.accepted = false
            self.acceptedGates = []
            self.deficiencies = deficiencies.sorted {
                if $0.code.rawValue != $1.code.rawValue {
                    return $0.code.rawValue < $1.code.rawValue
                }
                return ($0.gate?.rawValue ?? "") < ($1.gate?.rawValue ?? "")
            }
        }
    }

    func encodedJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private static func canonicalEvidence(
        _ evidence: [WS24InstalledAppQualificationEvidence]
    ) -> [WS24InstalledAppQualificationEvidence] {
        evidence.sorted {
            if $0.gate.rawValue != $1.gate.rawValue {
                return $0.gate.rawValue < $1.gate.rawValue
            }
            if $0.sourceCommit != $1.sourceCommit {
                return $0.sourceCommit < $1.sourceCommit
            }
            if $0.installedExecutableSHA256 != $1.installedExecutableSHA256 {
                return $0.installedExecutableSHA256 < $1.installedExecutableSHA256
            }
            if $0.status.rawValue != $1.status.rawValue {
                return $0.status.rawValue < $1.status.rawValue
            }
            return $0.acceptedAttempts < $1.acceptedAttempts
        }
    }

    struct PerformanceThresholdsSnapshot: Codable, Hashable, Sendable {
        let launchDetachMaximumDurationMilliseconds: Double
        let attachDetachMaximumDurationMilliseconds: Double
        let restartMaximumDurationMilliseconds: Double
        let maximumPeakResidentMemoryMegabytes: Double

        init(_ thresholds: WS24InstalledAppPerformanceThresholds) {
            self.launchDetachMaximumDurationMilliseconds =
                thresholds.maxAttemptDurationMillisecondsByScenario[.launchDetach] ?? 0
            self.attachDetachMaximumDurationMilliseconds =
                thresholds.maxAttemptDurationMillisecondsByScenario[.attachDetach] ?? 0
            self.restartMaximumDurationMilliseconds =
                thresholds.maxAttemptDurationMillisecondsByScenario[.restart] ?? 0
            self.maximumPeakResidentMemoryMegabytes = thresholds.maxPeakResidentMemoryMegabytes
        }
    }
}

struct WS24InstalledAppQualificationReportAssembler: Sendable {
    let evaluator: WS24InstalledAppQualificationEvaluator
    let performanceThresholds: WS24InstalledAppPerformanceThresholds

    init(
        expectedSourceCommit: String,
        performanceThresholds: WS24InstalledAppPerformanceThresholds = .init()
    ) {
        self.evaluator = .init(expectedSourceCommit: expectedSourceCommit)
        self.performanceThresholds = performanceThresholds
    }

    func makeReport(
        sourceCommit: String,
        installedExecutableSHA256: String,
        evidence: [WS24InstalledAppQualificationEvidence],
        generatedAtUnixMilliseconds: Int64? = nil
    ) -> WS24InstalledAppQualificationReport {
        WS24InstalledAppQualificationReport(
            sourceCommit: sourceCommit,
            installedExecutableSHA256: installedExecutableSHA256,
            generatedAtUnixMilliseconds: generatedAtUnixMilliseconds,
            evidence: evidence,
            result: evaluator.evaluate(evidence),
            performanceThresholds: performanceThresholds
        )
    }
}

enum WS24InstalledAppQualificationReportWriterError: Error, Equatable, Sendable {
    case outputURLIsDirectory(String)
}

struct WS24InstalledAppQualificationReportWriteResult: Hashable, Sendable {
    let reportURL: URL
    let reportSHA256: String
    let byteCount: Int
}

struct WS24InstalledAppQualificationReportWriter: Sendable {
    func writeReport(
        _ report: WS24InstalledAppQualificationReport,
        to reportURL: URL
    ) throws -> WS24InstalledAppQualificationReportWriteResult {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: reportURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw WS24InstalledAppQualificationReportWriterError
                .outputURLIsDirectory(reportURL.path)
        }

        let parentDirectory = reportURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )

        let data = try report.encodedJSONData()
        try data.write(to: reportURL, options: [.atomic])

        return .init(
            reportURL: reportURL,
            reportSHA256: Self.sha256Hex(data),
            byteCount: data.count
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct WS24InstalledAppQualificationEvaluator: Sendable {
    let expectedSourceCommit: String

    init(expectedSourceCommit: String) {
        self.expectedSourceCommit = expectedSourceCommit
    }

    func evaluate(
        _ evidence: [WS24InstalledAppQualificationEvidence]
    ) -> WS24InstalledAppQualificationResult {
        var deficiencies: Set<WS24InstalledAppQualificationDeficiency> = []
        var evidenceByGate: [WS24InstalledAppQualificationGate: WS24InstalledAppQualificationEvidence] = [:]
        var duplicateGates: Set<WS24InstalledAppQualificationGate> = []

        for item in evidence {
            if evidenceByGate[item.gate] != nil {
                duplicateGates.insert(item.gate)
            } else {
                evidenceByGate[item.gate] = item
            }
        }

        for gate in duplicateGates {
            deficiencies.insert(.init(.duplicateGateEvidence, gate: gate))
        }

        for gate in Self.requiredGates {
            guard let item = evidenceByGate[gate] else {
                deficiencies.insert(.init(.missingRequiredGate, gate: gate))
                continue
            }
            if item.status != .passed {
                deficiencies.insert(.init(.gateFailed, gate: gate))
            }
            if item.sourceCommit != expectedSourceCommit {
                deficiencies.insert(.init(.staleSourceCommit, gate: gate))
            }
            if item.installedExecutableSHA256.isEmpty {
                deficiencies.insert(.init(.emptyInstalledExecutableDigest, gate: gate))
            } else if !Self.isLowercaseSHA256(item.installedExecutableSHA256) {
                deficiencies.insert(.init(.malformedInstalledExecutableDigest, gate: gate))
            }
            if item.acceptedAttempts < gate.minimumAcceptedAttempts {
                deficiencies.insert(.init(.insufficientAcceptedAttempts, gate: gate))
            }
        }

        let acceptedDigests = Set(
            Self.requiredGates.compactMap { gate -> String? in
                guard let item = evidenceByGate[gate],
                      item.status == .passed,
                      item.sourceCommit == expectedSourceCommit,
                      Self.isLowercaseSHA256(item.installedExecutableSHA256)
                else { return nil }
                return item.installedExecutableSHA256
            }
        )

        if acceptedDigests.count > 1 {
            deficiencies.insert(.init(.inconsistentInstalledExecutableDigest))
        }

        if deficiencies.isEmpty, let digest = acceptedDigests.first {
            return .accepted(.init(
                sourceCommit: expectedSourceCommit,
                installedExecutableSHA256: digest,
                acceptedGates: Self.requiredGates
            ))
        }

        return .rejected(Self.sorted(deficiencies))
    }

    static let requiredGates: [WS24InstalledAppQualificationGate] =
        WS24InstalledAppQualificationGate.allCases
            .filter { $0 != .incrementalXCUITest }
            .sorted { $0.rawValue < $1.rawValue }

    static let optionalGates: [WS24InstalledAppQualificationGate] = [
        .incrementalXCUITest,
    ]

    private static func sorted(
        _ deficiencies: Set<WS24InstalledAppQualificationDeficiency>
    ) -> [WS24InstalledAppQualificationDeficiency] {
        deficiencies.sorted {
            if $0.code.rawValue != $1.code.rawValue {
                return $0.code.rawValue < $1.code.rawValue
            }
            return ($0.gate?.rawValue ?? "") < ($1.gate?.rawValue ?? "")
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

enum WS24InstalledAppArtifactCollectorError: Error, Equatable, Sendable {
    case missingSourceExecutable(String)
    case missingInstalledExecutable(String)
    case sourceExecutableIsDirectory(String)
    case installedExecutableIsDirectory(String)
    case missingReleaseProvenance(String)
    case releaseProvenanceIsDirectory(String)
    case unreadableReleaseProvenance
}

enum WS24InstalledAppDirectTransportRunnerError: Error, Equatable, Sendable {
    case missingInstalledAppBundle(String)
    case installedAppBundleIsNotDirectory(String)
    case missingInstalledExecutable(String)
    case installedExecutableIsDirectory(String)
}

struct WS24InstalledAppArtifactDigest: Hashable, Sendable {
    let sourceCommit: String
    let sourceExecutableSHA256: String
    let installedExecutableSHA256: String

    var sourceMatchesInstall: Bool {
        sourceExecutableSHA256 == installedExecutableSHA256
    }
}

struct WS24InstalledAppArtifactCollector: Sendable {
    func collectSourceInstallEqualityEvidence(
        sourceExecutableURL: URL,
        installedExecutableURL: URL,
        sourceCommit: String
    ) throws -> (digest: WS24InstalledAppArtifactDigest, evidence: WS24InstalledAppQualificationEvidence) {
        try requireRegularFile(
            sourceExecutableURL,
            missing: .missingSourceExecutable(sourceExecutableURL.path),
            directory: .sourceExecutableIsDirectory(sourceExecutableURL.path)
        )
        try requireRegularFile(
            installedExecutableURL,
            missing: .missingInstalledExecutable(installedExecutableURL.path),
            directory: .installedExecutableIsDirectory(installedExecutableURL.path)
        )

        let sourceSHA256 = try Self.sha256Hex(contentsOf: sourceExecutableURL)
        let installedSHA256 = try Self.sha256Hex(contentsOf: installedExecutableURL)
        let digest = WS24InstalledAppArtifactDigest(
            sourceCommit: sourceCommit,
            sourceExecutableSHA256: sourceSHA256,
            installedExecutableSHA256: installedSHA256
        )

        return (
            digest,
            .init(
                gate: .sourceInstallEquality,
                status: digest.sourceMatchesInstall ? .passed : .failed,
                sourceCommit: sourceCommit,
                installedExecutableSHA256: installedSHA256
            )
        )
    }

    func collectSealedReleaseProvenanceEvidence(
        provenanceURL: URL,
        installedExecutableSHA256: String,
        expectedSourceCommit: String
    ) throws -> WS24InstalledAppQualificationEvidence {
        try requireRegularFile(
            provenanceURL,
            missing: .missingReleaseProvenance(provenanceURL.path),
            directory: .releaseProvenanceIsDirectory(provenanceURL.path)
        )
        let payload: ReleaseBuildProvenancePayload
        do {
            payload = try JSONDecoder().decode(
                ReleaseBuildProvenancePayload.self,
                from: try Data(contentsOf: provenanceURL)
            )
        } catch {
            throw WS24InstalledAppArtifactCollectorError.unreadableReleaseProvenance
        }

        let accepted = payload.schemaVersion == 1
            && payload.qualificationEligible
            && payload.configuration == "Release"
            && payload.gitHeadCommit == expectedSourceCommit
            && payload.repositoryClean
            && payload.hasRequiredDigestFields
            && payload.hasRequiredToolchainFields

        return .init(
            gate: .sealedReleaseProvenance,
            status: accepted ? .passed : .failed,
            sourceCommit: payload.gitHeadCommit ?? expectedSourceCommit,
            installedExecutableSHA256: installedExecutableSHA256
        )
    }

    static func executableURL(
        inAppBundle appBundleURL: URL,
        executableName: String = "MacScope"
    ) -> URL {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
    }

    static func releaseProvenanceURL(inAppBundle appBundleURL: URL) -> URL {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("MacScopeBuildProvenance.json", isDirectory: false)
    }

    private func requireRegularFile(
        _ url: URL,
        missing: WS24InstalledAppArtifactCollectorError,
        directory: WS24InstalledAppArtifactCollectorError
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw missing
        }
        if isDirectory.boolValue {
            throw directory
        }
    }

    private static func sha256Hex(contentsOf url: URL) throws -> String {
        let bytes = try Data(contentsOf: url)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private struct ReleaseBuildProvenancePayload: Decodable {
        let schemaVersion: Int
        let qualificationEligible: Bool
        let configuration: String
        let gitHeadCommit: String?
        let repositoryClean: Bool
        let selectedBuildInputsSHA256: String?
        let projectYMLSHA256: String?
        let xcodeVersion: String?
        let xcodeBuild: String?
        let swiftCompilerVersion: String?
        let swiftTargetTriple: String?
        let sdkName: String?
        let sdkVersion: String?
        let architecture: String?
        let deploymentTarget: String?

        var hasRequiredDigestFields: Bool {
            Self.isLowercaseSHA256(selectedBuildInputsSHA256)
                && Self.isLowercaseSHA256(projectYMLSHA256)
        }

        var hasRequiredToolchainFields: Bool {
            xcodeVersion?.hasPrefix("27.") == true
                && xcodeBuild?.isEmpty == false
                && swiftCompilerVersion?.hasPrefix("6.") == true
                && swiftTargetTriple?.hasPrefix("arm64-apple-macosx27") == true
                && sdkName?.hasPrefix("macosx27.") == true
                && sdkVersion?.hasPrefix("27.") == true
                && architecture == "arm64"
                && deploymentTarget == "27.0"
        }

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case qualificationEligible = "qualification_eligible"
            case configuration
            case gitHeadCommit = "git_head_commit"
            case repositoryClean = "repository_clean"
            case selectedBuildInputsSHA256 = "selected_build_inputs_sha256"
            case projectYMLSHA256 = "project_yml_sha256"
            case xcodeVersion = "xcode_version"
            case xcodeBuild = "xcode_build"
            case swiftCompilerVersion = "swift_compiler_version"
            case swiftTargetTriple = "swift_target_triple"
            case sdkName = "sdk_name"
            case sdkVersion = "sdk_version"
            case architecture
            case deploymentTarget = "deployment_target"
        }

        private static func isLowercaseSHA256(_ value: String?) -> Bool {
            guard let value else { return false }
            let bytes = Array(value.utf8)
            guard bytes.count == 64 else { return false }
            return bytes.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
        }
    }
}

enum WS24InstalledAppDirectTransportOperation: String, CaseIterable, Hashable, Sendable {
    case launch
    case attach
    case nonKillingDetach = "non-killing-detach"
    case terminate
    case restart
}

enum WS24InstalledAppDirectTransportObservationSource: String, Hashable, Sendable {
    case directDebuggerClient = "direct-debugger-client"
    case installedLaunchSmoke = "installed-launch-smoke"
    case incrementalXCUITest = "incremental-xcuitest"
}

struct WS24InstalledAppDirectTransportObservation: Hashable, Sendable {
    let operation: WS24InstalledAppDirectTransportOperation
    let passed: Bool
    let source: WS24InstalledAppDirectTransportObservationSource
    let sourceCommit: String
    let installedExecutableSHA256: String
    let observedProcessID: Int32?
    let usedBroadProcessKill: Bool
    let leftProcessResidue: Bool
    let targetSurvivedAfterOperation: Bool?

    init(
        operation: WS24InstalledAppDirectTransportOperation,
        passed: Bool,
        source: WS24InstalledAppDirectTransportObservationSource = .directDebuggerClient,
        sourceCommit: String,
        installedExecutableSHA256: String,
        observedProcessID: Int32? = nil,
        usedBroadProcessKill: Bool = false,
        leftProcessResidue: Bool = false,
        targetSurvivedAfterOperation: Bool? = nil
    ) {
        self.operation = operation
        self.passed = passed
        self.source = source
        self.sourceCommit = sourceCommit
        self.installedExecutableSHA256 = installedExecutableSHA256
        self.observedProcessID = observedProcessID
        self.usedBroadProcessKill = usedBroadProcessKill
        self.leftProcessResidue = leftProcessResidue
        self.targetSurvivedAfterOperation = targetSurvivedAfterOperation
    }
}

struct WS24InstalledAppDirectTransportRunConfiguration: Hashable, Sendable {
    let installedAppBundleURL: URL
    let sourceCommit: String
    let installedExecutableSHA256: String
    let executableName: String

    init(
        installedAppBundleURL: URL,
        sourceCommit: String,
        installedExecutableSHA256: String,
        executableName: String = "MacScope"
    ) {
        self.installedAppBundleURL = installedAppBundleURL
        self.sourceCommit = sourceCommit
        self.installedExecutableSHA256 = installedExecutableSHA256
        self.executableName = executableName
    }

    var installedExecutableURL: URL {
        WS24InstalledAppArtifactCollector.executableURL(
            inAppBundle: installedAppBundleURL,
            executableName: executableName
        )
    }
}

struct WS24InstalledAppDirectTransportStepResult: Hashable, Sendable {
    let operation: WS24InstalledAppDirectTransportOperation
    let passed: Bool
    let observedProcessID: Int32?
    /// App-owned lifetime peak for the exact observed target. This never crosses the
    /// public WS24 direct/stress report seam except through the performance gate.
    let peakResidentMemoryMegabytes: Int?
    let usedBroadProcessKill: Bool
    let leftProcessResidue: Bool
    let targetSurvivedAfterOperation: Bool?

    init(
        operation: WS24InstalledAppDirectTransportOperation,
        passed: Bool,
        observedProcessID: Int32?,
        peakResidentMemoryMegabytes: Int? = nil,
        usedBroadProcessKill: Bool = false,
        leftProcessResidue: Bool = false,
        targetSurvivedAfterOperation: Bool? = nil
    ) {
        self.operation = operation
        self.passed = passed
        self.observedProcessID = observedProcessID
        self.peakResidentMemoryMegabytes = peakResidentMemoryMegabytes
        self.usedBroadProcessKill = usedBroadProcessKill
        self.leftProcessResidue = leftProcessResidue
        self.targetSurvivedAfterOperation = targetSurvivedAfterOperation
    }
}

@MainActor
protocol WS24InstalledAppDirectTransportExecuting: Sendable {
    func executeDirectTransportStep(
        _ operation: WS24InstalledAppDirectTransportOperation,
        configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) async throws -> WS24InstalledAppDirectTransportStepResult
}

@MainActor
struct WS24InstalledAppDirectTransportRunner<Executor: WS24InstalledAppDirectTransportExecuting>: Sendable {
    let executor: Executor

    init(executor: Executor) {
        self.executor = executor
    }

    func run(
        configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) async throws -> WS24InstalledAppQualificationEvidence {
        try validateInstalledApp(configuration)

        var observations: [WS24InstalledAppDirectTransportObservation] = []
        observations.reserveCapacity(WS24InstalledAppDirectTransportOperation.allCases.count)

        for operation in WS24InstalledAppDirectTransportOperation.allCases {
            let result: WS24InstalledAppDirectTransportStepResult
            do {
                result = try await executor.executeDirectTransportStep(
                    operation,
                    configuration: configuration
                )
            } catch {
                result = .init(
                    operation: operation,
                    passed: false,
                    observedProcessID: nil,
                    leftProcessResidue: true
                )
            }
            observations.append(WS24InstalledAppDirectTransportObservation(
                operation: result.operation,
                passed: result.passed,
                source: .directDebuggerClient,
                sourceCommit: configuration.sourceCommit,
                installedExecutableSHA256: configuration.installedExecutableSHA256,
                observedProcessID: result.observedProcessID,
                usedBroadProcessKill: result.usedBroadProcessKill,
                leftProcessResidue: result.leftProcessResidue,
                targetSurvivedAfterOperation: result.targetSurvivedAfterOperation
            ))
        }

        return WS24InstalledAppDirectTransportCollector().collectEvidence(
            observations: observations,
            expectedSourceCommit: configuration.sourceCommit,
            installedExecutableSHA256: configuration.installedExecutableSHA256
        )
    }

    private func validateInstalledApp(
        _ configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) throws {
        var bundleIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: configuration.installedAppBundleURL.path,
            isDirectory: &bundleIsDirectory
        ) else {
            throw WS24InstalledAppDirectTransportRunnerError
                .missingInstalledAppBundle(configuration.installedAppBundleURL.path)
        }
        guard bundleIsDirectory.boolValue else {
            throw WS24InstalledAppDirectTransportRunnerError
                .installedAppBundleIsNotDirectory(configuration.installedAppBundleURL.path)
        }

        var executableIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: configuration.installedExecutableURL.path,
            isDirectory: &executableIsDirectory
        ) else {
            throw WS24InstalledAppDirectTransportRunnerError
                .missingInstalledExecutable(configuration.installedExecutableURL.path)
        }
        guard !executableIsDirectory.boolValue else {
            throw WS24InstalledAppDirectTransportRunnerError
                .installedExecutableIsDirectory(configuration.installedExecutableURL.path)
        }
    }
}

enum WS24InstalledAppLocalLLDBDirectTransportExecutorError: Error, Equatable, Sendable {
    case backendUnavailable(String)
    case invalidProcessState(String)
    case processObservation(String)
    case processResidue(String)
}

@MainActor
struct WS24InstalledAppLocalLLDBDirectTransportExecutor:
    WS24InstalledAppDirectTransportExecuting,
    WS24InstalledAppStressExecuting
{
    private let launchClientFactory: @MainActor () -> LocalLLDBDebuggerClient
    private let attachClientFactory: @MainActor () -> LocalLLDBDebuggerClient
    private let evidenceProvider: DarwinDebuggerLocalProcessEvidenceProvider
    private let identityObserver: DebuggerLocalProcessIdentityObserver
    private let waitTimeout: Duration
    private let cleanupTimeout: Duration

    init(
        launchClientFactory: @escaping @MainActor () -> LocalLLDBDebuggerClient = {
            let environment = ProcessInfo.processInfo.environment
            let developerDirectory = environment["DEVELOPER_DIR"]
                ?? "/Applications/Xcode-beta.app/Contents/Developer"
            let lldbPath = XcodeLLDBCommandLineAdapter.discoverLLDBExecutablePath(
                environment: ["DEVELOPER_DIR": developerDirectory]
            )
            return LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: FoundationDebuggerProcessRunner(),
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: FileManager.default.currentDirectoryPath,
                launchTimeoutSeconds: 15,
                liveSessionFactory: { FoundationLLDBCommandSessionTransport() }
            ))
        },
        attachClientFactory: @escaping @MainActor () -> LocalLLDBDebuggerClient = {
            LocalLLDBDebuggerClient(debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities())
        },
        evidenceProvider: DarwinDebuggerLocalProcessEvidenceProvider =
            DarwinDebuggerLocalProcessEvidenceProvider(),
        waitTimeout: Duration = .seconds(3),
        cleanupTimeout: Duration = .seconds(10)
    ) {
        self.launchClientFactory = launchClientFactory
        self.attachClientFactory = attachClientFactory
        self.evidenceProvider = evidenceProvider
        self.identityObserver = DebuggerLocalProcessIdentityObserver(provider: evidenceProvider)
        self.waitTimeout = waitTimeout
        self.cleanupTimeout = cleanupTimeout
    }

    func executeDirectTransportStep(
        _ operation: WS24InstalledAppDirectTransportOperation,
        configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) async throws -> WS24InstalledAppDirectTransportStepResult {
        switch operation {
        case .launch:
            return try await launchThenTerminate(configuration: configuration, operation: operation)
        case .terminate:
            return try await launchThenTerminate(configuration: configuration, operation: operation)
        case .restart:
            return try await restart(configuration: configuration)
        case .attach:
            return try await attachThenDetachAndTerminate(
                configuration: configuration,
                operation: operation,
                requireSurvivalAfterDetach: false
            )
        case .nonKillingDetach:
            return try await attachThenDetachAndTerminate(
                configuration: configuration,
                operation: operation,
                requireSurvivalAfterDetach: true
            )
        }
    }

    func executeStressAttempt(
        scenario: WS24InstalledAppStressScenario,
        attemptIndex: Int,
        configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) async throws -> WS24InstalledAppStressAttemptResult {
        switch scenario {
        case .launchDetach:
            let result = try await launchThenDetachAndTerminate(configuration: configuration)
            return WS24InstalledAppStressAttemptResult(
                scenario: scenario,
                attemptIndex: attemptIndex,
                passed: result.passed,
                observedProcessID: result.observedProcessID,
                peakResidentMemoryMegabytes: result.peakResidentMemoryMegabytes,
                usedBroadProcessKill: result.usedBroadProcessKill,
                leftProcessResidue: result.leftProcessResidue,
                preservedTargetAfterDetach: result.targetSurvivedAfterOperation,
                terminalCleanupCompleted: !result.leftProcessResidue
            )
        case .attachDetach:
            let result = try await attachThenDetachAndTerminate(
                configuration: configuration,
                operation: .nonKillingDetach,
                requireSurvivalAfterDetach: true
            )
            return WS24InstalledAppStressAttemptResult(
                scenario: scenario,
                attemptIndex: attemptIndex,
                passed: result.passed,
                observedProcessID: result.observedProcessID,
                peakResidentMemoryMegabytes: result.peakResidentMemoryMegabytes,
                usedBroadProcessKill: result.usedBroadProcessKill,
                leftProcessResidue: result.leftProcessResidue,
                preservedTargetAfterDetach: result.targetSurvivedAfterOperation,
                terminalCleanupCompleted: !result.leftProcessResidue
            )
        case .restart:
            let result = try await restart(configuration: configuration)
            return WS24InstalledAppStressAttemptResult(
                scenario: scenario,
                attemptIndex: attemptIndex,
                passed: result.passed,
                observedProcessID: result.observedProcessID,
                peakResidentMemoryMegabytes: result.peakResidentMemoryMegabytes,
                usedBroadProcessKill: result.usedBroadProcessKill,
                leftProcessResidue: result.leftProcessResidue,
                terminalCleanupCompleted: !result.leftProcessResidue
            )
        }
    }

    private func launchThenTerminate(
        configuration: WS24InstalledAppDirectTransportRunConfiguration,
        operation: WS24InstalledAppDirectTransportOperation
    ) async throws -> WS24InstalledAppDirectTransportStepResult {
        let client = launchClientFactory()
        guard client.capabilities.isBackendAvailable,
              client.capabilities.canLaunch,
              client.capabilities.canControlExecution else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError
                .backendUnavailable(client.capabilities.summary)
        }

        var snapshot = client.makeInitialSnapshot()
        snapshot = try await client.launch(DebuggerLaunchConfiguration(
            executablePath: configuration.installedExecutableURL.path,
            workingDirectory: configuration.installedAppBundleURL
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
        ))

        guard let targetProcessID = snapshot.liveProcessID,
              targetProcessID > 0 else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError
                .invalidProcessState("Launch did not produce one live installed-app PID.")
        }

        let peakResidentMemoryMegabytes = try Self.peakResidentMemoryMegabytes(
            processID: targetProcessID
        )

        let terminated = try await client.terminate(from: snapshot)
        guard case .exited = terminated.processState else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError
                .invalidProcessState(
                    "Terminate returned \(terminated.processState.displayTitle), expected exited."
                )
        }
        try await waitForExactProcessExit(
            processID: targetProcessID,
            expectedExecutablePath: configuration.installedExecutableURL.standardizedFileURL.path
        )

        return WS24InstalledAppDirectTransportStepResult(
            operation: operation,
            passed: true,
            observedProcessID: targetProcessID,
            peakResidentMemoryMegabytes: peakResidentMemoryMegabytes,
            targetSurvivedAfterOperation: operation == .terminate ? false : nil
        )
    }

    private func launchThenDetachAndTerminate(
        configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) async throws -> WS24InstalledAppDirectTransportStepResult {
        let client = launchClientFactory()
        guard client.capabilities.isBackendAvailable,
              client.capabilities.canLaunch,
              client.capabilities.canControlExecution else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError
                .backendUnavailable(client.capabilities.summary)
        }

        let launched = try await client.launch(DebuggerLaunchConfiguration(
            executablePath: configuration.installedExecutableURL.path,
            workingDirectory: configuration.installedAppBundleURL
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
        ))
        guard let processID = launched.liveProcessID,
              processID > 0 else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError
                .invalidProcessState("Launch-detach did not produce a live installed-app PID.")
        }
        let authorization = try await waitForStableAuthorizationEvidence(processID: processID)
        let selectedIdentity = authorization.identity
        guard selectedIdentity.canonicalExecutablePath
                == configuration.installedExecutableURL.standardizedFileURL.path else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processObservation(
                "Launched process resolved to \(selectedIdentity.canonicalExecutablePath), "
                    + "not \(configuration.installedExecutableURL.path)."
            )
        }
        let detached = try await client.detach(from: launched)
        guard case .notAttached = detached.processState else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.invalidProcessState(
                "Launch-detach returned \(detached.processState.displayTitle), expected not attached."
            )
        }
        let survival = await identityObserver.reobserveIdentity(selectedIdentity)
        guard case .resolved(let survivingIdentity) = survival,
              survivingIdentity == selectedIdentity else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processObservation(
                "Launch-detach target did not survive as the exact selected process identity."
            )
        }
        let peakResidentMemoryMegabytes = try Self.peakResidentMemoryMegabytes(
            processID: processID
        )
        try await terminateOwnedProcessIfNeeded(
            processID: processID,
            expectedExecutablePath: selectedIdentity.canonicalExecutablePath
        )
        return WS24InstalledAppDirectTransportStepResult(
            operation: .nonKillingDetach,
            passed: true,
            observedProcessID: processID,
            peakResidentMemoryMegabytes: peakResidentMemoryMegabytes,
            targetSurvivedAfterOperation: true
        )
    }

    private func restart(
        configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) async throws -> WS24InstalledAppDirectTransportStepResult {
        let first = try await launchThenTerminate(configuration: configuration, operation: .launch)
        let second = try await launchThenTerminate(configuration: configuration, operation: .launch)
        guard let firstPID = first.observedProcessID,
              let secondPID = second.observedProcessID,
              firstPID > 0,
              secondPID > 0,
              firstPID != secondPID else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError
                .invalidProcessState("Restart did not observe two distinct installed-app PIDs.")
        }
        return WS24InstalledAppDirectTransportStepResult(
            operation: .restart,
            passed: true,
            observedProcessID: secondPID,
            peakResidentMemoryMegabytes: max(
                first.peakResidentMemoryMegabytes ?? 0,
                second.peakResidentMemoryMegabytes ?? 0
            )
        )
    }

    private func attachThenDetachAndTerminate(
        configuration: WS24InstalledAppDirectTransportRunConfiguration,
        operation: WS24InstalledAppDirectTransportOperation,
        requireSurvivalAfterDetach: Bool
    ) async throws -> WS24InstalledAppDirectTransportStepResult {
        let process = Process()
        process.executableURL = configuration.installedExecutableURL
        process.currentDirectoryURL = configuration.installedAppBundleURL
            .deletingLastPathComponent()
            .standardizedFileURL
        try process.run()

        let processID = Int32(process.processIdentifier)
        let usedBroadProcessKill = false
        var leftProcessResidue = false
        var detachedSurvival: Bool?

        do {
            let authorization = try await waitForStableAuthorizationEvidence(processID: processID)
            let selectedIdentity = authorization.identity
            guard selectedIdentity.canonicalExecutablePath
                    == configuration.installedExecutableURL.standardizedFileURL.path else {
                throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processObservation(
                    "Spawned process resolved to \(selectedIdentity.canonicalExecutablePath), "
                        + "not \(configuration.installedExecutableURL.path)."
                )
            }

            let client = attachClientFactory()
            guard client.capabilities.isBackendAvailable,
                  client.capabilities.canAttach,
                  client.capabilities.canControlExecution else {
                throw WS24InstalledAppLocalLLDBDirectTransportExecutorError
                    .backendUnavailable(client.capabilities.summary)
            }

            let initial = client.makeInitialSnapshot()
            let attached = try await client.attach(
                DebuggerLocalAttachRequest(selectedIdentity: selectedIdentity),
                from: initial
            )
            guard attached.liveProcessID == processID else {
                throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.invalidProcessState(
                    "Attach returned \(attached.processState.displayTitle), expected pid \(processID)."
                )
            }

            let detached = try await client.detach(from: attached)
            guard case .notAttached = detached.processState else {
                throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.invalidProcessState(
                    "Detach returned \(detached.processState.displayTitle), expected not attached."
                )
            }

            let survival = await identityObserver.reobserveIdentity(selectedIdentity)
            if case .resolved(let survivingIdentity) = survival,
               survivingIdentity == selectedIdentity,
               process.isRunning {
                detachedSurvival = true
            } else {
                detachedSurvival = false
            }

            if requireSurvivalAfterDetach, detachedSurvival != true {
                throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processObservation(
                    "Detached target did not survive as the exact selected process identity."
                )
            }

            let peakResidentMemoryMegabytes = try Self.peakResidentMemoryMegabytes(
                processID: processID
            )

            try await terminateOwnedProcessIfNeeded(process, expectedExecutablePath: selectedIdentity.canonicalExecutablePath)

            return WS24InstalledAppDirectTransportStepResult(
                operation: operation,
                passed: true,
                observedProcessID: processID,
                peakResidentMemoryMegabytes: peakResidentMemoryMegabytes,
                usedBroadProcessKill: usedBroadProcessKill,
                leftProcessResidue: leftProcessResidue,
                targetSurvivedAfterOperation: requireSurvivalAfterDetach ? detachedSurvival : nil
            )
        } catch {
            if process.isRunning {
                try? await terminateOwnedProcessIfNeeded(
                    process,
                    expectedExecutablePath: configuration.installedExecutableURL.standardizedFileURL.path
                )
            }
            leftProcessResidue = process.isRunning
            if leftProcessResidue {
                throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processResidue(
                    "Installed-app pid \(processID) remained after failed \(operation.rawValue)."
                )
            }
            throw error
        }
    }

    private func waitForStableAuthorizationEvidence(
        processID: Int32
    ) async throws -> DebuggerLocalProcessAuthorizationEvidence {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: waitTimeout)
        var lastResult: DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> =
            .unknown(.unstableSnapshot)
        repeat {
            let result = await evidenceProvider.authorizationEvidence(processID: processID)
            switch result {
            case .resolved(let evidence):
                return evidence
            case .unknown(.unstableSnapshot):
                lastResult = result
                try await clock.sleep(for: .milliseconds(25))
            case .unknown, .ineligible:
                throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processObservation(
                    "Installed app pid \(processID) did not produce attach authorization evidence: "
                        + "\(result)"
                )
            }
        } while clock.now < deadline
        throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processObservation(
            "Installed app pid \(processID) did not stabilize for attach evidence: \(lastResult)"
        )
    }

    private func terminateOwnedProcessIfNeeded(
        _ process: Process,
        expectedExecutablePath: String
    ) async throws {
        guard process.isRunning else { return }
        let processID = Int32(process.processIdentifier)
        let observedPath = Self.executablePath(for: processID)
        guard observedPath == expectedExecutablePath else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processObservation(
                "Refusing exact cleanup for pid \(processID); observed executable "
                    + "\(observedPath ?? "<unresolved>") did not match \(expectedExecutablePath)."
            )
        }
        process.terminate()
        do {
            try await waitForProcessExit(process)
        } catch {
            guard process.isRunning,
                  Self.executablePath(for: processID) == expectedExecutablePath else {
                throw error
            }
            Darwin.kill(processID, SIGKILL)
            try await waitForProcessExit(process)
        }
    }

    private func terminateOwnedProcessIfNeeded(
        processID: Int32,
        expectedExecutablePath: String
    ) async throws {
        guard Self.processMatchesExecutable(
            processID: processID,
            expectedExecutablePath: expectedExecutablePath
        ) else { return }
        let observedPath = Self.executablePath(for: processID)
        guard observedPath == expectedExecutablePath else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processObservation(
                "Refusing exact cleanup for pid \(processID); observed executable "
                    + "\(observedPath ?? "<unresolved>") did not match \(expectedExecutablePath)."
            )
        }
        Darwin.kill(processID, SIGTERM)
        do {
            try await waitForExactProcessExit(
                processID: processID,
                expectedExecutablePath: expectedExecutablePath
            )
        } catch {
            guard Self.processMatchesExecutable(
                processID: processID,
                expectedExecutablePath: expectedExecutablePath
            ) else {
                throw error
            }
            Darwin.kill(processID, SIGKILL)
            try await waitForExactProcessExit(
                processID: processID,
                expectedExecutablePath: expectedExecutablePath
            )
        }
    }

    private func waitForProcessExit(_ process: Process) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: waitTimeout)
        while process.isRunning, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(25))
        }
        guard !process.isRunning else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processResidue(
                "Installed-app pid \(process.processIdentifier) did not exit within \(waitTimeout)."
            )
        }
    }

    private func waitForExactProcessExit(
        processID: Int32,
        expectedExecutablePath: String
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: cleanupTimeout)
        while Self.processMatchesExecutable(
            processID: processID,
            expectedExecutablePath: expectedExecutablePath
        ), clock.now < deadline {
            try await clock.sleep(for: .milliseconds(25))
        }
        guard !Self.processMatchesExecutable(
            processID: processID,
            expectedExecutablePath: expectedExecutablePath
        ) else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processResidue(
                "Installed-app pid \(processID) still resolved to \(expectedExecutablePath) "
                    + "within \(cleanupTimeout)."
            )
        }
    }

    private static func processIsRunning(_ processID: Int32) -> Bool {
        errno = 0
        return Darwin.kill(processID, 0) == 0 || errno == EPERM
    }

    private static func processMatchesExecutable(
        processID: Int32,
        expectedExecutablePath: String
    ) -> Bool {
        processIsRunning(processID) && executablePath(for: processID) == expectedExecutablePath
    }

    private static func executablePath(for processID: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let count = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func peakResidentMemoryMegabytes(processID: Int32) throws -> Int {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processID, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0, usage.ri_lifetime_max_phys_footprint > 0 else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processObservation(
                "Installed app pid \(processID) did not expose bounded peak-memory evidence."
            )
        }
        let bytesPerMegabyte = UInt64(1_024 * 1_024)
        let rounded = (usage.ri_lifetime_max_phys_footprint + bytesPerMegabyte - 1)
            / bytesPerMegabyte
        guard rounded <= UInt64(Int.max) else {
            throw WS24InstalledAppLocalLLDBDirectTransportExecutorError.processObservation(
                "Installed app pid \(processID) peak-memory evidence overflowed."
            )
        }
        return Int(rounded)
    }
}

struct WS24InstalledAppDirectTransportCollector: Sendable {
    func collectEvidence(
        observations: [WS24InstalledAppDirectTransportObservation],
        expectedSourceCommit: String,
        installedExecutableSHA256: String
    ) -> WS24InstalledAppQualificationEvidence {
        let observationsByOperation = Dictionary(grouping: observations, by: \.operation)

        let accepted = WS24InstalledAppDirectTransportOperation.allCases.allSatisfy { operation in
            guard let operationObservations = observationsByOperation[operation],
                  operationObservations.count == 1,
                  let observation = operationObservations.first else {
                return false
            }
            return observation.passed
                && observation.source == .directDebuggerClient
                && observation.sourceCommit == expectedSourceCommit
                && observation.installedExecutableSHA256 == installedExecutableSHA256
                && Self.hasValidProcessEvidence(observation)
                && !observation.usedBroadProcessKill
                && !observation.leftProcessResidue
                && Self.satisfiesOperationSpecificPostcondition(observation)
        } && observations.count == WS24InstalledAppDirectTransportOperation.allCases.count

        return .init(
            gate: .directDebuggerTransportContracts,
            status: accepted ? .passed : .failed,
            sourceCommit: expectedSourceCommit,
            installedExecutableSHA256: installedExecutableSHA256
        )
    }

    private static func hasValidProcessEvidence(
        _ observation: WS24InstalledAppDirectTransportObservation
    ) -> Bool {
        guard let observedProcessID = observation.observedProcessID else { return false }
        return observedProcessID > 0
    }

    private static func satisfiesOperationSpecificPostcondition(
        _ observation: WS24InstalledAppDirectTransportObservation
    ) -> Bool {
        switch observation.operation {
        case .nonKillingDetach:
            observation.targetSurvivedAfterOperation == true
        case .terminate:
            observation.targetSurvivedAfterOperation == false
        case .launch, .attach, .restart:
            true
        }
    }
}

enum WS24InstalledAppStressScenario: String, CaseIterable, Hashable, Sendable {
    case launchDetach = "launch-detach"
    case attachDetach = "attach-detach"
    case restart = "restart"

    var gate: WS24InstalledAppQualificationGate {
        switch self {
        case .launchDetach:
            .repeatedLaunchDetachStress
        case .attachDetach:
            .repeatedAttachDetachStress
        case .restart:
            .repeatedRestartStress
        }
    }

    var requiresNonKillingDetachProof: Bool {
        switch self {
        case .launchDetach, .attachDetach:
            true
        case .restart:
            false
        }
    }
}

struct WS24InstalledAppStressAttemptObservation: Hashable, Sendable {
    let scenario: WS24InstalledAppStressScenario
    let attemptIndex: Int
    let passed: Bool
    let sourceCommit: String
    let installedExecutableSHA256: String
    let observedProcessID: Int32?
    let usedBroadProcessKill: Bool
    let leftProcessResidue: Bool
    let preservedTargetAfterDetach: Bool?
    let terminalCleanupCompleted: Bool

    init(
        scenario: WS24InstalledAppStressScenario,
        attemptIndex: Int,
        passed: Bool,
        sourceCommit: String,
        installedExecutableSHA256: String,
        observedProcessID: Int32?,
        usedBroadProcessKill: Bool = false,
        leftProcessResidue: Bool = false,
        preservedTargetAfterDetach: Bool? = nil,
        terminalCleanupCompleted: Bool = true
    ) {
        self.scenario = scenario
        self.attemptIndex = attemptIndex
        self.passed = passed
        self.sourceCommit = sourceCommit
        self.installedExecutableSHA256 = installedExecutableSHA256
        self.observedProcessID = observedProcessID
        self.usedBroadProcessKill = usedBroadProcessKill
        self.leftProcessResidue = leftProcessResidue
        self.preservedTargetAfterDetach = preservedTargetAfterDetach
        self.terminalCleanupCompleted = terminalCleanupCompleted
    }
}

struct WS24InstalledAppStressAttemptResult: Hashable, Sendable {
    let scenario: WS24InstalledAppStressScenario
    let attemptIndex: Int
    let passed: Bool
    let observedProcessID: Int32?
    let peakResidentMemoryMegabytes: Int?
    let usedBroadProcessKill: Bool
    let leftProcessResidue: Bool
    let preservedTargetAfterDetach: Bool?
    let terminalCleanupCompleted: Bool

    init(
        scenario: WS24InstalledAppStressScenario,
        attemptIndex: Int,
        passed: Bool,
        observedProcessID: Int32?,
        peakResidentMemoryMegabytes: Int? = nil,
        usedBroadProcessKill: Bool = false,
        leftProcessResidue: Bool = false,
        preservedTargetAfterDetach: Bool? = nil,
        terminalCleanupCompleted: Bool = true
    ) {
        self.scenario = scenario
        self.attemptIndex = attemptIndex
        self.passed = passed
        self.observedProcessID = observedProcessID
        self.peakResidentMemoryMegabytes = peakResidentMemoryMegabytes
        self.usedBroadProcessKill = usedBroadProcessKill
        self.leftProcessResidue = leftProcessResidue
        self.preservedTargetAfterDetach = preservedTargetAfterDetach
        self.terminalCleanupCompleted = terminalCleanupCompleted
    }
}

struct WS24InstalledAppStressCollector: Sendable {
    func collectEvidence(
        scenario: WS24InstalledAppStressScenario,
        attempts: [WS24InstalledAppStressAttemptObservation],
        expectedSourceCommit: String,
        installedExecutableSHA256: String
    ) -> WS24InstalledAppQualificationEvidence {
        let acceptedAttempts = attempts.filter { attempt in
            attempt.scenario == scenario
                && attempt.passed
                && attempt.sourceCommit == expectedSourceCommit
                && attempt.installedExecutableSHA256 == installedExecutableSHA256
                && Self.hasValidProcessEvidence(attempt)
                && !attempt.usedBroadProcessKill
                && !attempt.leftProcessResidue
                && attempt.terminalCleanupCompleted
                && Self.satisfiesScenarioPostcondition(attempt)
        }.count

        let accepted = acceptedAttempts >= scenario.gate.minimumAcceptedAttempts
            && attempts.count == acceptedAttempts
            && Self.hasContiguousAttemptIndexes(attempts)

        return .init(
            gate: scenario.gate,
            status: accepted ? .passed : .failed,
            sourceCommit: expectedSourceCommit,
            installedExecutableSHA256: installedExecutableSHA256,
            acceptedAttempts: acceptedAttempts
        )
    }

    private static func hasValidProcessEvidence(
        _ attempt: WS24InstalledAppStressAttemptObservation
    ) -> Bool {
        guard let observedProcessID = attempt.observedProcessID else { return false }
        return observedProcessID > 0
    }

    private static func satisfiesScenarioPostcondition(
        _ attempt: WS24InstalledAppStressAttemptObservation
    ) -> Bool {
        if attempt.scenario.requiresNonKillingDetachProof {
            return attempt.preservedTargetAfterDetach == true
        }
        return attempt.preservedTargetAfterDetach == nil
    }

    private static func hasContiguousAttemptIndexes(
        _ attempts: [WS24InstalledAppStressAttemptObservation]
    ) -> Bool {
        guard !attempts.isEmpty else { return false }
        let indexes = attempts.map(\.attemptIndex).sorted()
        return indexes == Array(1...attempts.count)
    }
}

@MainActor
protocol WS24InstalledAppStressExecuting: Sendable {
    func executeStressAttempt(
        scenario: WS24InstalledAppStressScenario,
        attemptIndex: Int,
        configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) async throws -> WS24InstalledAppStressAttemptResult
}

@MainActor
struct WS24InstalledAppStressRunner<Executor: WS24InstalledAppStressExecuting>: Sendable {
    let scenario: WS24InstalledAppStressScenario
    let executor: Executor

    init(
        scenario: WS24InstalledAppStressScenario,
        executor: Executor
    ) {
        self.scenario = scenario
        self.executor = executor
    }

    func run(
        configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) async throws -> WS24InstalledAppQualificationEvidence {
        try validateInstalledApp(configuration)

        var observations: [WS24InstalledAppStressAttemptObservation] = []
        observations.reserveCapacity(scenario.gate.minimumAcceptedAttempts)

        for attemptIndex in 1...scenario.gate.minimumAcceptedAttempts {
            let result: WS24InstalledAppStressAttemptResult
            do {
                result = try await executor.executeStressAttempt(
                    scenario: scenario,
                    attemptIndex: attemptIndex,
                    configuration: configuration
                )
            } catch {
                result = .init(
                    scenario: scenario,
                    attemptIndex: attemptIndex,
                    passed: false,
                    observedProcessID: nil,
                    leftProcessResidue: true,
                    terminalCleanupCompleted: false
                )
            }
            observations.append(.init(
                scenario: result.scenario,
                attemptIndex: result.attemptIndex,
                passed: result.passed,
                sourceCommit: configuration.sourceCommit,
                installedExecutableSHA256: configuration.installedExecutableSHA256,
                observedProcessID: result.observedProcessID,
                usedBroadProcessKill: result.usedBroadProcessKill,
                leftProcessResidue: result.leftProcessResidue,
                preservedTargetAfterDetach: result.preservedTargetAfterDetach,
                terminalCleanupCompleted: result.terminalCleanupCompleted
            ))
        }

        return WS24InstalledAppStressCollector().collectEvidence(
            scenario: scenario,
            attempts: observations,
            expectedSourceCommit: configuration.sourceCommit,
            installedExecutableSHA256: configuration.installedExecutableSHA256
        )
    }

    private func validateInstalledApp(
        _ configuration: WS24InstalledAppDirectTransportRunConfiguration
    ) throws {
        var bundleIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: configuration.installedAppBundleURL.path,
            isDirectory: &bundleIsDirectory
        ) else {
            throw WS24InstalledAppDirectTransportRunnerError
                .missingInstalledAppBundle(configuration.installedAppBundleURL.path)
        }
        guard bundleIsDirectory.boolValue else {
            throw WS24InstalledAppDirectTransportRunnerError
                .installedAppBundleIsNotDirectory(configuration.installedAppBundleURL.path)
        }

        var executableIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: configuration.installedExecutableURL.path,
            isDirectory: &executableIsDirectory
        ) else {
            throw WS24InstalledAppDirectTransportRunnerError
                .missingInstalledExecutable(configuration.installedExecutableURL.path)
        }
        guard !executableIsDirectory.boolValue else {
            throw WS24InstalledAppDirectTransportRunnerError
                .installedExecutableIsDirectory(configuration.installedExecutableURL.path)
        }
    }
}

struct WS24InstalledAppSecurityObservation: Hashable, Sendable {
    let sourceCommit: String
    let installedExecutableSHA256: String
    let sealedReleaseProvenancePassed: Bool
    let localSigningPolicyPassed: Bool
    let strictDeepCodesignPassed: Bool
    let certificateBackedAppleDevelopmentSigning: Bool
    let hardenedRuntimeEnabled: Bool
    let entitlementsLimitedToLocalDevelopmentPolicy: Bool
    let directTransportEvidence: WS24InstalledAppQualificationEvidence
    let stressEvidence: [WS24InstalledAppQualificationEvidence]

    init(
        sourceCommit: String,
        installedExecutableSHA256: String,
        sealedReleaseProvenancePassed: Bool,
        localSigningPolicyPassed: Bool,
        strictDeepCodesignPassed: Bool,
        certificateBackedAppleDevelopmentSigning: Bool,
        hardenedRuntimeEnabled: Bool,
        entitlementsLimitedToLocalDevelopmentPolicy: Bool,
        directTransportEvidence: WS24InstalledAppQualificationEvidence,
        stressEvidence: [WS24InstalledAppQualificationEvidence]
    ) {
        self.sourceCommit = sourceCommit
        self.installedExecutableSHA256 = installedExecutableSHA256
        self.sealedReleaseProvenancePassed = sealedReleaseProvenancePassed
        self.localSigningPolicyPassed = localSigningPolicyPassed
        self.strictDeepCodesignPassed = strictDeepCodesignPassed
        self.certificateBackedAppleDevelopmentSigning = certificateBackedAppleDevelopmentSigning
        self.hardenedRuntimeEnabled = hardenedRuntimeEnabled
        self.entitlementsLimitedToLocalDevelopmentPolicy = entitlementsLimitedToLocalDevelopmentPolicy
        self.directTransportEvidence = directTransportEvidence
        self.stressEvidence = stressEvidence
    }
}

struct WS24InstalledAppSecurityCollector: Sendable {
    func collectEvidence(
        observation: WS24InstalledAppSecurityObservation,
        expectedSourceCommit: String,
        installedExecutableSHA256: String
    ) -> WS24InstalledAppQualificationEvidence {
        let accepted = observation.sourceCommit == expectedSourceCommit
            && observation.installedExecutableSHA256 == installedExecutableSHA256
            && observation.sealedReleaseProvenancePassed
            && observation.localSigningPolicyPassed
            && observation.strictDeepCodesignPassed
            && observation.certificateBackedAppleDevelopmentSigning
            && observation.hardenedRuntimeEnabled
            && observation.entitlementsLimitedToLocalDevelopmentPolicy
            && Self.isPassingEvidence(
                observation.directTransportEvidence,
                gate: .directDebuggerTransportContracts,
                expectedSourceCommit: expectedSourceCommit,
                installedExecutableSHA256: installedExecutableSHA256
            )
            && Self.hasPassingStressEvidence(
                observation.stressEvidence,
                expectedSourceCommit: expectedSourceCommit,
                installedExecutableSHA256: installedExecutableSHA256
            )

        return .init(
            gate: .securityGate,
            status: accepted ? .passed : .failed,
            sourceCommit: expectedSourceCommit,
            installedExecutableSHA256: installedExecutableSHA256
        )
    }

    private static func hasPassingStressEvidence(
        _ evidence: [WS24InstalledAppQualificationEvidence],
        expectedSourceCommit: String,
        installedExecutableSHA256: String
    ) -> Bool {
        let evidenceByGate = Dictionary(grouping: evidence, by: \.gate)
        return WS24InstalledAppStressScenario.allCases.allSatisfy { scenario in
            guard let gateEvidence = evidenceByGate[scenario.gate],
                  gateEvidence.count == 1,
                  let item = gateEvidence.first else {
                return false
            }
            return isPassingEvidence(
                item,
                gate: scenario.gate,
                expectedSourceCommit: expectedSourceCommit,
                installedExecutableSHA256: installedExecutableSHA256
            ) && item.acceptedAttempts >= scenario.gate.minimumAcceptedAttempts
        } && evidence.count == WS24InstalledAppStressScenario.allCases.count
    }

    private static func isPassingEvidence(
        _ evidence: WS24InstalledAppQualificationEvidence,
        gate: WS24InstalledAppQualificationGate,
        expectedSourceCommit: String,
        installedExecutableSHA256: String
    ) -> Bool {
        evidence.gate == gate
            && evidence.status == .passed
            && evidence.sourceCommit == expectedSourceCommit
            && evidence.installedExecutableSHA256 == installedExecutableSHA256
    }
}

struct WS24InstalledAppPerformanceThresholds: Hashable, Sendable {
    let maxAttemptDurationMillisecondsByScenario: [WS24InstalledAppStressScenario: Double]
    let maxPeakResidentMemoryMegabytes: Double

    init(
        maxAttemptDurationMillisecondsByScenario: [WS24InstalledAppStressScenario: Double] = [
            .launchDetach: 15_000,
            .attachDetach: 15_000,
            .restart: 20_000,
        ],
        maxPeakResidentMemoryMegabytes: Double = 2_048
    ) {
        self.maxAttemptDurationMillisecondsByScenario = maxAttemptDurationMillisecondsByScenario
        self.maxPeakResidentMemoryMegabytes = maxPeakResidentMemoryMegabytes
    }
}

struct WS24InstalledAppPerformanceObservation: Hashable, Sendable {
    let scenario: WS24InstalledAppStressScenario
    let attemptIndex: Int
    let sourceCommit: String
    let installedExecutableSHA256: String
    let durationMilliseconds: Double
    let peakResidentMemoryMegabytes: Double
    let timedOut: Bool

    init(
        scenario: WS24InstalledAppStressScenario,
        attemptIndex: Int,
        sourceCommit: String,
        installedExecutableSHA256: String,
        durationMilliseconds: Double,
        peakResidentMemoryMegabytes: Double,
        timedOut: Bool = false
    ) {
        self.scenario = scenario
        self.attemptIndex = attemptIndex
        self.sourceCommit = sourceCommit
        self.installedExecutableSHA256 = installedExecutableSHA256
        self.durationMilliseconds = durationMilliseconds
        self.peakResidentMemoryMegabytes = peakResidentMemoryMegabytes
        self.timedOut = timedOut
    }
}

struct WS24InstalledAppPerformanceCollector: Sendable {
    let thresholds: WS24InstalledAppPerformanceThresholds

    init(thresholds: WS24InstalledAppPerformanceThresholds = .init()) {
        self.thresholds = thresholds
    }

    func collectEvidence(
        observations: [WS24InstalledAppPerformanceObservation],
        expectedSourceCommit: String,
        installedExecutableSHA256: String
    ) -> WS24InstalledAppQualificationEvidence {
        var acceptedAttempts = 0
        let observationsByScenario = Dictionary(grouping: observations, by: \.scenario)

        let accepted = WS24InstalledAppStressScenario.allCases.allSatisfy { scenario in
            guard let scenarioObservations = observationsByScenario[scenario],
                  scenarioObservations.count >= scenario.gate.minimumAcceptedAttempts,
                  hasContiguousAttemptIndexes(scenarioObservations),
                  let maxDuration = thresholds.maxAttemptDurationMillisecondsByScenario[scenario] else {
                return false
            }
            let scenarioAccepted = scenarioObservations.allSatisfy { observation in
                observation.sourceCommit == expectedSourceCommit
                    && observation.installedExecutableSHA256 == installedExecutableSHA256
                    && observation.durationMilliseconds.isFinite
                    && observation.durationMilliseconds >= 0
                    && observation.durationMilliseconds <= maxDuration
                    && observation.peakResidentMemoryMegabytes.isFinite
                    && observation.peakResidentMemoryMegabytes >= 0
                    && observation.peakResidentMemoryMegabytes <= thresholds.maxPeakResidentMemoryMegabytes
                    && !observation.timedOut
            }
            if scenarioAccepted {
                acceptedAttempts += scenarioObservations.count
            }
            return scenarioAccepted
        } && observations.count == acceptedAttempts

        return .init(
            gate: .performanceGate,
            status: accepted ? .passed : .failed,
            sourceCommit: expectedSourceCommit,
            installedExecutableSHA256: installedExecutableSHA256,
            acceptedAttempts: acceptedAttempts
        )
    }

    private func hasContiguousAttemptIndexes(
        _ observations: [WS24InstalledAppPerformanceObservation]
    ) -> Bool {
        guard !observations.isEmpty else { return false }
        let indexes = observations.map(\.attemptIndex).sorted()
        return indexes == Array(1...observations.count)
    }
}

struct WS24InstalledAppToolchainObservation: Hashable, Sendable {
    let sourceCommit: String
    let installedExecutableSHA256: String
    let releaseProvenanceQualified: Bool
    let xcodeVersion: String
    let swiftCompilerVersion: String
    let swiftTargetTriple: String
    let sdkName: String
    let sdkVersion: String
    let architecture: String
    let deploymentTarget: String
    let hostArchitecture: String
    let hostMacOSMajorVersion: Int
    let developerDirectoryUsesXcode27: Bool

    init(
        sourceCommit: String,
        installedExecutableSHA256: String,
        releaseProvenanceQualified: Bool,
        xcodeVersion: String,
        swiftCompilerVersion: String,
        swiftTargetTriple: String,
        sdkName: String,
        sdkVersion: String,
        architecture: String,
        deploymentTarget: String,
        hostArchitecture: String,
        hostMacOSMajorVersion: Int,
        developerDirectoryUsesXcode27: Bool
    ) {
        self.sourceCommit = sourceCommit
        self.installedExecutableSHA256 = installedExecutableSHA256
        self.releaseProvenanceQualified = releaseProvenanceQualified
        self.xcodeVersion = xcodeVersion
        self.swiftCompilerVersion = swiftCompilerVersion
        self.swiftTargetTriple = swiftTargetTriple
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
        self.architecture = architecture
        self.deploymentTarget = deploymentTarget
        self.hostArchitecture = hostArchitecture
        self.hostMacOSMajorVersion = hostMacOSMajorVersion
        self.developerDirectoryUsesXcode27 = developerDirectoryUsesXcode27
    }
}

struct WS24InstalledAppToolchainCollector: Sendable {
    func collectEvidence(
        observation: WS24InstalledAppToolchainObservation,
        expectedSourceCommit: String,
        installedExecutableSHA256: String
    ) -> WS24InstalledAppQualificationEvidence {
        let accepted = observation.sourceCommit == expectedSourceCommit
            && observation.installedExecutableSHA256 == installedExecutableSHA256
            && observation.releaseProvenanceQualified
            && observation.xcodeVersion.hasPrefix("27.")
            && observation.swiftCompilerVersion.hasPrefix("6.")
            && observation.swiftTargetTriple.hasPrefix("arm64-apple-macosx27")
            && observation.sdkName.hasPrefix("macosx27.")
            && observation.sdkVersion.hasPrefix("27.")
            && observation.architecture == "arm64"
            && observation.deploymentTarget == "27.0"
            && observation.hostArchitecture == "arm64"
            && observation.hostMacOSMajorVersion >= 27
            && observation.developerDirectoryUsesXcode27

        return .init(
            gate: .supportedToolchainMatrix,
            status: accepted ? .passed : .failed,
            sourceCommit: expectedSourceCommit,
            installedExecutableSHA256: installedExecutableSHA256
        )
    }
}

// MARK: - Installed Release live-gate entry point

enum WS24InstalledLiveExecutionGate: String, CaseIterable, Codable, Hashable, Sendable {
    case installedLaunchSmoke = "installed-launch-smoke"
    case directDebuggerTransportContracts = "direct-debugger-transport-contracts"
    case repeatedLaunchDetachStress = "repeated-launch-detach-stress"
    case repeatedAttachDetachStress = "repeated-attach-detach-stress"
    case repeatedRestartStress = "repeated-restart-stress"
    case performanceGate = "performance-gate"

    var stressScenario: WS24InstalledAppStressScenario? {
        switch self {
        case .repeatedLaunchDetachStress: .launchDetach
        case .repeatedAttachDetachStress: .attachDetach
        case .repeatedRestartStress: .restart
        case .installedLaunchSmoke,
             .directDebuggerTransportContracts,
             .performanceGate:
            nil
        }
    }
}

struct WS24InstalledLiveExecutionAttempt: Encodable, Equatable, Sendable {
    let attemptIndex: Int
    let endedAtUnixMilliseconds: Int64
    let exitCode: Int
    let failure: String?
    let peakResidentMemoryMegabytes: Int?
    let scenario: String
    let seed: Int64?
    let startedAtUnixMilliseconds: Int64
    let timedOut: Bool

    private enum CodingKeys: String, CodingKey {
        case attemptIndex
        case endedAtUnixMilliseconds
        case exitCode
        case failure
        case peakResidentMemoryMegabytes
        case scenario
        case seed
        case startedAtUnixMilliseconds
        case timedOut
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attemptIndex, forKey: .attemptIndex)
        try container.encode(endedAtUnixMilliseconds, forKey: .endedAtUnixMilliseconds)
        try container.encode(exitCode, forKey: .exitCode)
        if let failure {
            try container.encode(failure, forKey: .failure)
        } else {
            try container.encodeNil(forKey: .failure)
        }
        if let peakResidentMemoryMegabytes {
            try container.encode(
                peakResidentMemoryMegabytes,
                forKey: .peakResidentMemoryMegabytes
            )
        } else {
            try container.encodeNil(forKey: .peakResidentMemoryMegabytes)
        }
        try container.encode(scenario, forKey: .scenario)
        if let seed {
            try container.encode(seed, forKey: .seed)
        } else {
            try container.encodeNil(forKey: .seed)
        }
        try container.encode(startedAtUnixMilliseconds, forKey: .startedAtUnixMilliseconds)
        try container.encode(timedOut, forKey: .timedOut)
    }
}

enum WS24InstalledLiveExecutionReportError: Error, Equatable, Sendable {
    case oversizedTerminalReport
    case noncanonicalTerminalReport
}

struct WS24InstalledLiveExecutionReport: Encodable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumByteCount = 1_024 * 1_024

    let attempts: [WS24InstalledLiveExecutionAttempt]
    let gate: String
    let installedExecutableSHA256: String
    let sourceCommit: String
    let sourceTree: String

    private enum CodingKeys: String, CodingKey {
        case attempts
        case gate
        case installedExecutableSHA256
        case schemaVersion
        case sourceCommit
        case sourceTree
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attempts, forKey: .attempts)
        try container.encode(gate, forKey: .gate)
        try container.encode(
            installedExecutableSHA256,
            forKey: .installedExecutableSHA256
        )
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(sourceCommit, forKey: .sourceCommit)
        try container.encode(sourceTree, forKey: .sourceTree)
    }

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard !data.isEmpty, data.count <= Self.maximumByteCount else {
            throw WS24InstalledLiveExecutionReportError.oversizedTerminalReport
        }
        guard data.last != 0x0A, data.last != 0x0D else {
            throw WS24InstalledLiveExecutionReportError.noncanonicalTerminalReport
        }
        return data
    }
}

enum WS24InstalledLiveGateApplicationRunnerError: Error, Equatable, Sendable {
    case invalidAuthority(String)
    case invalidObservation(String)
    case staleInstalledProcess(String)
    case clockFailure
}

/// Reserved, ordinary-launch-neutral entry point for the exact installed Release app.
///
/// The outer Python producer validates the candidate, source app, pending transaction, run
/// authority, and preparation receipt. This process independently binds those inputs to its own
/// installed executable and Release provenance, performs every live observation, and emits only
/// the terminal closed report. It never receives a pass/status/timing/PID value from its caller.
@MainActor
enum WS24InstalledLiveGateApplicationRunner {
    static let selector = "--ws24-installed-live-gate"
    static let installedAppPath = "/Applications/MacScope.app"
    static let installedExecutablePath =
        "/Applications/MacScope.app/Contents/MacOS/MacScope"
    static let maximumFailureBytes = 512

    struct Request: Equatable, Sendable {
        let gate: WS24InstalledLiveExecutionGate
        let sourceCommit: String
        let sourceTree: String
        let installedExecutableSHA256: String
        let pendingExposedAtUnixNanoseconds: UInt64
        let developerDirectory: String
    }

    enum LaunchDecision: Equatable, Sendable {
        case ordinary
        case rejected
        case requested(Request)
    }

    static func decision(
        arguments: [String],
        environment: [String: String]
    ) -> LaunchDecision {
        let supplied = Array(arguments.dropFirst())
        let containsReservedArgument = supplied.contains {
            $0.hasPrefix("--ws24-installed-live-")
        }
        guard containsReservedArgument else { return .ordinary }
        guard !containsUnsafeEnvironment(environment),
              arguments.first == installedExecutablePath,
              supplied.count == 12,
              supplied[0] == selector,
              supplied[2] == "--source-commit",
              supplied[4] == "--source-tree",
              supplied[6] == "--installed-executable-sha256",
              supplied[8] == "--pending-exposed-at-unix-nanoseconds",
              supplied[10] == "--developer-directory",
              let gate = WS24InstalledLiveExecutionGate(rawValue: supplied[1]),
              isLowercaseHex(supplied[3], count: 40),
              isLowercaseHex(supplied[5], count: 40),
              isLowercaseHex(supplied[7], count: 64),
              let exposedAt = UInt64(supplied[9]),
              exposedAt > 0,
              isBoundedAbsolutePath(supplied[11]) else {
            return .rejected
        }
        return .requested(.init(
            gate: gate,
            sourceCommit: supplied[3],
            sourceTree: supplied[5],
            installedExecutableSHA256: supplied[7],
            pendingExposedAtUnixNanoseconds: exposedAt,
            developerDirectory: supplied[11]
        ))
    }

    /// Returns only for an ordinary launch. A reserved request owns this process through one
    /// terminal report or a bounded failure exit.
    static func runIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let launchDecision = decision(arguments: arguments, environment: environment)
        switch launchDecision {
        case .ordinary:
            return false
        case .rejected:
            emitFailure("invalid-request")
            Darwin.exit(EX_USAGE)
        case .requested(let request):
            #if DEBUG
            _ = request
            emitFailure("release-build-required")
            Darwin.exit(EX_CONFIG)
            #else
            Task { @MainActor in
                do {
                    let report = try await execute(
                        request: request,
                        environment: environment
                    )
                    try FileHandle.standardOutput.write(contentsOf: report.canonicalData())
                    Darwin.exit(EXIT_SUCCESS)
                } catch {
                    emitFailure(String(reflecting: type(of: error)))
                    Darwin.exit(EX_SOFTWARE)
                }
            }
            dispatchMain()
            #endif
        }
    }

    static func deterministicSeed(
        sourceCommit: String,
        sourceTree: String,
        installedExecutableSHA256: String,
        reportGate: String,
        scenario: String,
        attemptIndex: Int
    ) -> Int64 {
        let fields = [
            "ws24-installed-live-seed-v1",
            sourceCommit,
            sourceTree,
            installedExecutableSHA256,
            reportGate,
            scenario,
            String(attemptIndex),
        ]
        var framed = Data()
        for (index, field) in fields.enumerated() {
            if index > 0 { framed.append(0) }
            framed.append(contentsOf: field.utf8)
        }
        var value: UInt64 = 0
        for byte in SHA256.hash(data: framed).prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return Int64(value & UInt64(Int64.max))
    }

    private struct ReleaseProvenance: Decodable {
        let schemaVersion: Int
        let qualificationEligible: Bool
        let configuration: String
        let repositoryClean: Bool
        let gitHeadCommit: String
        let gitHeadTree: String
        let xcodeVersion: String
        let swiftCompilerVersion: String
        let swiftTargetTriple: String
        let sdkName: String
        let sdkVersion: String
        let architecture: String
        let deploymentTarget: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case qualificationEligible = "qualification_eligible"
            case configuration
            case repositoryClean = "repository_clean"
            case gitHeadCommit = "git_head_commit"
            case gitHeadTree = "git_head_tree"
            case xcodeVersion = "xcode_version"
            case swiftCompilerVersion = "swift_compiler_version"
            case swiftTargetTriple = "swift_target_triple"
            case sdkName = "sdk_name"
            case sdkVersion = "sdk_version"
            case architecture
            case deploymentTarget = "deployment_target"
        }
    }

    private struct RegularFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let mode: UInt32
        let links: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        init(_ value: stat) {
            device = UInt64(truncatingIfNeeded: value.st_dev)
            inode = UInt64(truncatingIfNeeded: value.st_ino)
            size = Int64(value.st_size)
            mode = UInt32(value.st_mode)
            links = UInt64(truncatingIfNeeded: value.st_nlink)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        }
    }

    private struct StressRun {
        let attempts: [WS24InstalledLiveExecutionAttempt]
        let performanceObservations: [WS24InstalledAppPerformanceObservation]
    }

    private static let stressScenarioOrder: [WS24InstalledAppStressScenario] = [
        .launchDetach,
        .attachDetach,
        .restart,
    ]

    private static func execute(
        request: Request,
        environment: [String: String]
    ) async throws -> WS24InstalledLiveExecutionReport {
        try validateRuntimeAuthority(request: request, environment: environment)
        try await requireCleanInstalledProcessFence()

        let debuggerAuthorities = DebuggerRuntimeAuthorities()
        let executor = WS24InstalledAppLocalLLDBDirectTransportExecutor(
            launchClientFactory: {
                LocalLLDBDebuggerClient(
                    debuggerRuntimeAuthorities: debuggerAuthorities
                )
            },
            attachClientFactory: {
                LocalLLDBDebuggerClient(
                    debuggerRuntimeAuthorities: debuggerAuthorities
                )
            }
        )
        let configuration = WS24InstalledAppDirectTransportRunConfiguration(
            installedAppBundleURL: URL(
                fileURLWithPath: installedAppPath,
                isDirectory: true
            ),
            sourceCommit: request.sourceCommit,
            installedExecutableSHA256: request.installedExecutableSHA256
        )

        let attempts: [WS24InstalledLiveExecutionAttempt]
        switch request.gate {
        case .installedLaunchSmoke:
            attempts = [try await runLaunchSmoke(
                request: request,
                configuration: configuration,
                executor: executor
            )]
        case .directDebuggerTransportContracts:
            attempts = [try await runDirectTransportContracts(
                request: request,
                configuration: configuration,
                executor: executor
            )]
        case .repeatedLaunchDetachStress,
             .repeatedAttachDetachStress,
             .repeatedRestartStress:
            guard let scenario = request.gate.stressScenario else {
                throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                    "stress-gate-mapping"
                )
            }
            attempts = try await runStressScenario(
                request: request,
                reportGate: request.gate.rawValue,
                scenario: scenario,
                includePerformance: false,
                configuration: configuration,
                executor: executor
            ).attempts
        case .performanceGate:
            var collectedAttempts: [WS24InstalledLiveExecutionAttempt] = []
            var performance: [WS24InstalledAppPerformanceObservation] = []
            for scenario in stressScenarioOrder {
                let run = try await runStressScenario(
                    request: request,
                    reportGate: request.gate.rawValue,
                    scenario: scenario,
                    includePerformance: true,
                    configuration: configuration,
                    executor: executor
                )
                collectedAttempts.append(contentsOf: run.attempts)
                performance.append(contentsOf: run.performanceObservations)
            }
            let evidence = WS24InstalledAppPerformanceCollector().collectEvidence(
                observations: performance,
                expectedSourceCommit: request.sourceCommit,
                installedExecutableSHA256: request.installedExecutableSHA256
            )
            guard evidence.status == .passed,
                  evidence.acceptedAttempts == 30,
                  collectedAttempts.count == 30 else {
                throw WS24InstalledLiveGateApplicationRunnerError.invalidObservation(
                    "performance-collector-rejected"
                )
            }
            attempts = collectedAttempts
        }

        try await requireCleanInstalledProcessFence()
        try validateRuntimeAuthority(request: request, environment: environment)
        return WS24InstalledLiveExecutionReport(
            attempts: attempts,
            gate: request.gate.rawValue,
            installedExecutableSHA256: request.installedExecutableSHA256,
            sourceCommit: request.sourceCommit,
            sourceTree: request.sourceTree
        )
    }

    private static func runLaunchSmoke(
        request: Request,
        configuration: WS24InstalledAppDirectTransportRunConfiguration,
        executor: WS24InstalledAppLocalLLDBDirectTransportExecutor
    ) async throws -> WS24InstalledLiveExecutionAttempt {
        try await requireCleanInstalledProcessFence()
        let measurement: (
            value: WS24InstalledAppDirectTransportStepResult,
            started: Int64,
            ended: Int64,
            duration: Int64
        )
        do {
            measurement = try await measure(
                exposureNanoseconds: request.pendingExposedAtUnixNanoseconds
            ) {
                try await executor.executeDirectTransportStep(
                    .launch,
                    configuration: configuration
                )
            }
        } catch {
            try await requireCleanInstalledProcessFence()
            throw error
        }
        try await requireCleanInstalledProcessFence()
        let result = measurement.value
        guard result.operation == .launch,
              result.passed,
              (result.observedProcessID ?? 0) > 0,
              !result.usedBroadProcessKill,
              !result.leftProcessResidue else {
            throw WS24InstalledLiveGateApplicationRunnerError.invalidObservation(
                "installed-launch-smoke-rejected"
            )
        }
        return successfulAttempt(
            index: 1,
            scenario: request.gate.rawValue,
            seed: nil,
            peakResidentMemoryMegabytes: nil,
            started: measurement.started,
            ended: measurement.ended
        )
    }

    private static func runDirectTransportContracts(
        request: Request,
        configuration: WS24InstalledAppDirectTransportRunConfiguration,
        executor: WS24InstalledAppLocalLLDBDirectTransportExecutor
    ) async throws -> WS24InstalledLiveExecutionAttempt {
        try await requireCleanInstalledProcessFence()
        let measurement: (
            value: WS24InstalledAppQualificationEvidence,
            started: Int64,
            ended: Int64,
            duration: Int64
        )
        do {
            measurement = try await measure(
                exposureNanoseconds: request.pendingExposedAtUnixNanoseconds
            ) {
                try await WS24InstalledAppDirectTransportRunner(executor: executor).run(
                    configuration: configuration
                )
            }
        } catch {
            try await requireCleanInstalledProcessFence()
            throw error
        }
        try await requireCleanInstalledProcessFence()
        let evidence = measurement.value
        guard evidence.gate == .directDebuggerTransportContracts,
              evidence.status == .passed,
              evidence.sourceCommit == request.sourceCommit,
              evidence.installedExecutableSHA256 == request.installedExecutableSHA256,
              evidence.acceptedAttempts == 1 else {
            throw WS24InstalledLiveGateApplicationRunnerError.invalidObservation(
                "direct-transport-collector-rejected"
            )
        }
        return successfulAttempt(
            index: 1,
            scenario: request.gate.rawValue,
            seed: nil,
            peakResidentMemoryMegabytes: nil,
            started: measurement.started,
            ended: measurement.ended
        )
    }

    private static func runStressScenario(
        request: Request,
        reportGate: String,
        scenario: WS24InstalledAppStressScenario,
        includePerformance: Bool,
        configuration: WS24InstalledAppDirectTransportRunConfiguration,
        executor: WS24InstalledAppLocalLLDBDirectTransportExecutor
    ) async throws -> StressRun {
        let attemptCount = scenario.gate.minimumAcceptedAttempts
        guard attemptCount >= 10 else {
            throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                "stress-attempt-count"
            )
        }
        var attempts: [WS24InstalledLiveExecutionAttempt] = []
        var observations: [WS24InstalledAppStressAttemptObservation] = []
        var performance: [WS24InstalledAppPerformanceObservation] = []
        attempts.reserveCapacity(attemptCount)
        observations.reserveCapacity(attemptCount)
        performance.reserveCapacity(includePerformance ? attemptCount : 0)

        for attemptIndex in 1...attemptCount {
            try await requireCleanInstalledProcessFence()
            let seed = deterministicSeed(
                sourceCommit: request.sourceCommit,
                sourceTree: request.sourceTree,
                installedExecutableSHA256: request.installedExecutableSHA256,
                reportGate: reportGate,
                scenario: scenario.gate.rawValue,
                attemptIndex: attemptIndex
            )
            let measurement: (
                value: WS24InstalledAppStressAttemptResult,
                started: Int64,
                ended: Int64,
                duration: Int64
            )
            do {
                measurement = try await measure(
                    exposureNanoseconds: request.pendingExposedAtUnixNanoseconds
                ) {
                    try await executor.executeStressAttempt(
                        scenario: scenario,
                        attemptIndex: attemptIndex,
                        configuration: configuration
                    )
                }
            } catch {
                try await requireCleanInstalledProcessFence()
                throw error
            }
            try await requireCleanInstalledProcessFence()

            let result = measurement.value
            guard result.scenario == scenario,
                  result.attemptIndex == attemptIndex,
                  result.passed,
                  (result.observedProcessID ?? 0) > 0,
                  !result.usedBroadProcessKill,
                  !result.leftProcessResidue,
                  result.terminalCleanupCompleted,
                  (!scenario.requiresNonKillingDetachProof
                    || result.preservedTargetAfterDetach == true),
                  (scenario.requiresNonKillingDetachProof
                    || result.preservedTargetAfterDetach == nil) else {
                throw WS24InstalledLiveGateApplicationRunnerError.invalidObservation(
                    "stress-attempt-rejected"
                )
            }
            observations.append(.init(
                scenario: result.scenario,
                attemptIndex: result.attemptIndex,
                passed: result.passed,
                sourceCommit: request.sourceCommit,
                installedExecutableSHA256: request.installedExecutableSHA256,
                observedProcessID: result.observedProcessID,
                usedBroadProcessKill: result.usedBroadProcessKill,
                leftProcessResidue: result.leftProcessResidue,
                preservedTargetAfterDetach: result.preservedTargetAfterDetach,
                terminalCleanupCompleted: result.terminalCleanupCompleted
            ))

            let peak: Int?
            if includePerformance {
                guard let measuredPeak = result.peakResidentMemoryMegabytes,
                      measuredPeak > 0 else {
                    throw WS24InstalledLiveGateApplicationRunnerError.invalidObservation(
                        "performance-memory-unavailable"
                    )
                }
                peak = measuredPeak
                performance.append(.init(
                    scenario: scenario,
                    attemptIndex: attemptIndex,
                    sourceCommit: request.sourceCommit,
                    installedExecutableSHA256: request.installedExecutableSHA256,
                    durationMilliseconds: Double(measurement.duration),
                    peakResidentMemoryMegabytes: Double(measuredPeak),
                    timedOut: false
                ))
            } else {
                peak = nil
            }
            attempts.append(successfulAttempt(
                index: attemptIndex,
                scenario: scenario.gate.rawValue,
                seed: seed,
                peakResidentMemoryMegabytes: peak,
                started: measurement.started,
                ended: measurement.ended
            ))
        }

        let stressEvidence = WS24InstalledAppStressCollector().collectEvidence(
            scenario: scenario,
            attempts: observations,
            expectedSourceCommit: request.sourceCommit,
            installedExecutableSHA256: request.installedExecutableSHA256
        )
        guard stressEvidence.gate == scenario.gate,
              stressEvidence.status == .passed,
              stressEvidence.acceptedAttempts == attemptCount,
              attempts.count == attemptCount else {
            throw WS24InstalledLiveGateApplicationRunnerError.invalidObservation(
                "stress-collector-rejected"
            )
        }
        return StressRun(
            attempts: attempts,
            performanceObservations: performance
        )
    }

    private static func successfulAttempt(
        index: Int,
        scenario: String,
        seed: Int64?,
        peakResidentMemoryMegabytes: Int?,
        started: Int64,
        ended: Int64
    ) -> WS24InstalledLiveExecutionAttempt {
        WS24InstalledLiveExecutionAttempt(
            attemptIndex: index,
            endedAtUnixMilliseconds: ended,
            exitCode: 0,
            failure: nil,
            peakResidentMemoryMegabytes: peakResidentMemoryMegabytes,
            scenario: scenario,
            seed: seed,
            startedAtUnixMilliseconds: started,
            timedOut: false
        )
    }

    private static func measure<Value>(
        exposureNanoseconds: UInt64,
        operation: () async throws -> Value
    ) async throws -> (value: Value, started: Int64, ended: Int64, duration: Int64) {
        let observedWallStart = try realtimeMilliseconds()
        let monotonicStart = try monotonicNanoseconds()
        let value = try await operation()
        let monotonicEnd = try monotonicNanoseconds()
        guard monotonicEnd >= monotonicStart else {
            throw WS24InstalledLiveGateApplicationRunnerError.clockFailure
        }
        let elapsedNanoseconds = monotonicEnd - monotonicStart
        let roundedMilliseconds = elapsedNanoseconds / 1_000_000
            + (elapsedNanoseconds % 1_000_000 == 0 ? 0 : 1)
        guard roundedMilliseconds <= UInt64(Int64.max) else {
            throw WS24InstalledLiveGateApplicationRunnerError.clockFailure
        }
        let duration = Int64(roundedMilliseconds)
        let exposedWholeMilliseconds = exposureNanoseconds / 1_000_000
            + (exposureNanoseconds % 1_000_000 == 0 ? 0 : 1)
        guard exposedWholeMilliseconds <= UInt64(Int64.max) else {
            throw WS24InstalledLiveGateApplicationRunnerError.clockFailure
        }
        let started = max(observedWallStart, Int64(exposedWholeMilliseconds))
        let (ended, overflow) = started.addingReportingOverflow(duration)
        guard !overflow else {
            throw WS24InstalledLiveGateApplicationRunnerError.clockFailure
        }
        return (value, started, ended, duration)
    }

    private static func realtimeMilliseconds() throws -> Int64 {
        var value = timespec()
        guard clock_gettime(CLOCK_REALTIME, &value) == 0,
              value.tv_sec >= 0,
              (0..<1_000_000_000).contains(value.tv_nsec) else {
            throw WS24InstalledLiveGateApplicationRunnerError.clockFailure
        }
        let (whole, overflow) = Int64(value.tv_sec).multipliedReportingOverflow(by: 1_000)
        let (milliseconds, sumOverflow) = whole.addingReportingOverflow(
            Int64(value.tv_nsec / 1_000_000)
        )
        guard !overflow, !sumOverflow else {
            throw WS24InstalledLiveGateApplicationRunnerError.clockFailure
        }
        return milliseconds
    }

    private static func monotonicNanoseconds() throws -> UInt64 {
        var value = timespec()
        guard clock_gettime(CLOCK_MONOTONIC_RAW, &value) == 0,
              value.tv_sec >= 0,
              (0..<1_000_000_000).contains(value.tv_nsec) else {
            throw WS24InstalledLiveGateApplicationRunnerError.clockFailure
        }
        let (whole, overflow) = UInt64(value.tv_sec)
            .multipliedReportingOverflow(by: 1_000_000_000)
        let (nanoseconds, sumOverflow) = whole.addingReportingOverflow(UInt64(value.tv_nsec))
        guard !overflow, !sumOverflow else {
            throw WS24InstalledLiveGateApplicationRunnerError.clockFailure
        }
        return nanoseconds
    }

    private static func validateRuntimeAuthority(
        request: Request,
        environment: [String: String]
    ) throws {
        guard environment["DEVELOPER_DIR"] == request.developerDirectory,
              canonicalExistingPath(request.developerDirectory, directory: true)
                == request.developerDirectory,
              canonicalExistingPath(
                request.developerDirectory + "/usr/bin/lldb",
                directory: false
              ) != nil else {
            throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                "developer-directory"
            )
        }
        guard canonicalExistingPath(installedAppPath, directory: true) == installedAppPath,
              canonicalExistingPath(installedExecutablePath, directory: false)
                == installedExecutablePath,
              Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
                == installedAppPath,
              Bundle.main.executableURL?.standardizedFileURL.resolvingSymlinksInPath().path
                == installedExecutablePath else {
            throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                "installed-path"
            )
        }

        let currentNanoseconds = try realtimeNanoseconds()
        guard request.pendingExposedAtUnixNanoseconds <= currentNanoseconds else {
            throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                "pending-exposure"
            )
        }
        let executableDigest = try sha256HexOfStableRegularFile(
            atPath: installedExecutablePath,
            maximumBytes: 512 * 1_024 * 1_024
        )
        guard executableDigest == request.installedExecutableSHA256 else {
            throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                "installed-digest"
            )
        }

        let provenancePath = installedAppPath
            + "/Contents/Resources/MacScopeBuildProvenance.json"
        let provenanceData = try stableRegularFileData(
            atPath: provenancePath,
            maximumBytes: 1_024 * 1_024
        )
        let provenance = try JSONDecoder().decode(
            ReleaseProvenance.self,
            from: provenanceData
        )
        guard provenance.schemaVersion == 1,
              provenance.qualificationEligible,
              provenance.configuration == "Release",
              provenance.repositoryClean,
              provenance.gitHeadCommit == request.sourceCommit,
              provenance.gitHeadTree == request.sourceTree,
              provenance.xcodeVersion.hasPrefix("27."),
              provenance.swiftCompilerVersion.hasPrefix("6."),
              provenance.swiftTargetTriple.hasPrefix("arm64-apple-macosx27"),
              provenance.sdkName.hasPrefix("macosx27."),
              provenance.sdkVersion.hasPrefix("27."),
              provenance.architecture == "arm64",
              provenance.deploymentTarget == "27.0" else {
            throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                "release-provenance"
            )
        }
    }

    private static func stableRegularFileData(
        atPath path: String,
        maximumBytes: Int
    ) throws -> Data {
        let before = try regularFileIdentity(atPath: path, maximumBytes: maximumBytes)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var payload = Data()
        while true {
            let remaining = maximumBytes - payload.count
            guard remaining >= 0 else {
                throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                    "bounded-file-read"
                )
            }
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining + 1)),
                  !chunk.isEmpty else { break }
            payload.append(chunk)
            guard payload.count <= maximumBytes else {
                throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                    "bounded-file-read"
                )
            }
        }
        guard try regularFileIdentity(atPath: path, maximumBytes: maximumBytes) == before,
              Int64(payload.count) == before.size else {
            throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                "file-identity-drift"
            )
        }
        return payload
    }

    private static func sha256HexOfStableRegularFile(
        atPath path: String,
        maximumBytes: Int
    ) throws -> String {
        let before = try regularFileIdentity(atPath: path, maximumBytes: maximumBytes)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            let (nextCount, overflow) = byteCount.addingReportingOverflow(Int64(chunk.count))
            guard !overflow, nextCount <= Int64(maximumBytes) else {
                throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                    "bounded-executable-read"
                )
            }
            byteCount = nextCount
            hasher.update(data: chunk)
        }
        guard try regularFileIdentity(atPath: path, maximumBytes: maximumBytes) == before,
              byteCount == before.size else {
            throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                "executable-identity-drift"
            )
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func regularFileIdentity(
        atPath path: String,
        maximumBytes: Int
    ) throws -> RegularFileIdentity {
        var value = stat()
        guard path.withCString({ Darwin.lstat($0, &value) }) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_nlink == 1,
              value.st_size >= 0,
              value.st_size <= Int64(maximumBytes) else {
            throw WS24InstalledLiveGateApplicationRunnerError.invalidAuthority(
                "regular-file-identity"
            )
        }
        return RegularFileIdentity(value)
    }

    private static func canonicalExistingPath(
        _ path: String,
        directory: Bool
    ) -> String? {
        var value = stat()
        guard path.withCString({ Darwin.lstat($0, &value) }) == 0,
              (value.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
              (directory || value.st_nlink == 1) else { return nil }
        let resolved = URL(fileURLWithPath: path, isDirectory: directory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return resolved == path ? resolved : nil
    }

    private static func realtimeNanoseconds() throws -> UInt64 {
        var value = timespec()
        guard clock_gettime(CLOCK_REALTIME, &value) == 0,
              value.tv_sec >= 0,
              (0..<1_000_000_000).contains(value.tv_nsec) else {
            throw WS24InstalledLiveGateApplicationRunnerError.clockFailure
        }
        let (whole, overflow) = UInt64(value.tv_sec)
            .multipliedReportingOverflow(by: 1_000_000_000)
        let (nanoseconds, sumOverflow) = whole.addingReportingOverflow(UInt64(value.tv_nsec))
        guard !overflow, !sumOverflow else {
            throw WS24InstalledLiveGateApplicationRunnerError.clockFailure
        }
        return nanoseconds
    }

    private static func requireCleanInstalledProcessFence() async throws {
        let resolution = await DarwinDebuggerLocalProcessEvidenceProvider().processIDs()
        guard case .resolved(let processIDs) = resolution else {
            throw WS24InstalledLiveGateApplicationRunnerError.staleInstalledProcess(
                "process-enumeration-unavailable"
            )
        }
        let ownProcessID = Int32(Darwin.getpid())
        let stale = processIDs.filter { processID in
            processID != ownProcessID
                && executablePath(for: processID) == installedExecutablePath
        }
        guard stale.isEmpty else {
            throw WS24InstalledLiveGateApplicationRunnerError.staleInstalledProcess(
                stale.map(String.init).joined(separator: ",")
            )
        }
    }

    private static func executablePath(for processID: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro and is not imported into Swift.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func containsUnsafeEnvironment(_ environment: [String: String]) -> Bool {
        environment.keys.contains { key in
            let normalized = key.uppercased()
            return normalized.contains("DYLD_")
                || normalized.hasPrefix("MACSCOPE_")
                || normalized.contains("XCTEST")
                || normalized.contains("XCINJECTBUNDLEINTO")
                || normalized == "LLVM_PROFILE_FILE"
                || ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]
                    .contains(normalized)
        }
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == count && bytes.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isBoundedAbsolutePath(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 4_096
            && !value.contains("\0")
            && value.hasPrefix("/")
    }

    private static func emitFailure(_ rawReason: String) {
        let prefix = "ERROR: WS24 installed live gate failed: "
        let suffix = "\n"
        let available = max(0, maximumFailureBytes - prefix.utf8.count - suffix.utf8.count)
        let reasonBytes = Array(rawReason.utf8.prefix(available))
        var payload = Data(prefix.utf8)
        payload.append(contentsOf: reasonBytes)
        payload.append(contentsOf: suffix.utf8)
        try? FileHandle.standardError.write(contentsOf: payload)
    }
}
