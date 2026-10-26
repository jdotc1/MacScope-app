import CryptoKit
import Foundation

enum Phase2QualificationEnvironmentV2ValidationError: Error, Equatable, Sendable {
    case invalidField
    case invalidDigest
    case invalidHardware
}

/// Payload-free, reusable identity for the exact build, toolchain, OS, and hardware declaration
/// used by an F4C run. It deliberately contains no path, username, endpoint, serial number,
/// hardware UUID, credential, or provider content.
struct Phase2QualificationEnvironmentV2: Hashable, Sendable {
    let bundleShortVersion: String
    let bundleVersion: String
    let macScopeCommit: String
    let appExecutableDigest: String
    let workerExecutableDigest: String
    let signingRequirementDigest: String
    let xcodeVersion: String
    let xcodeBuild: String
    let swiftCompilerVersion: String
    let sdkVersion: String
    let sdkBuild: String
    let operatingSystemVersion: String
    let operatingSystemBuild: String
    let architecture: String
    let hardwareModel: String
    let processorFamily: String
    let physicalMemoryBytes: UInt64
    let physicalCoreCount: Int
    let logicalCoreCount: Int
    let performanceCoreCount: Int
    let efficiencyCoreCount: Int

    init(
        bundleShortVersion: String,
        bundleVersion: String,
        macScopeCommit: String,
        appExecutableDigest: String,
        workerExecutableDigest: String,
        signingRequirementDigest: String,
        xcodeVersion: String,
        xcodeBuild: String,
        swiftCompilerVersion: String,
        sdkVersion: String,
        sdkBuild: String,
        operatingSystemVersion: String,
        operatingSystemBuild: String,
        architecture: String,
        hardwareModel: String,
        processorFamily: String,
        physicalMemoryBytes: UInt64,
        physicalCoreCount: Int,
        logicalCoreCount: Int,
        performanceCoreCount: Int,
        efficiencyCoreCount: Int
    ) throws {
        let compactFields = [
            bundleShortVersion, bundleVersion, xcodeVersion, xcodeBuild,
            swiftCompilerVersion, sdkVersion, sdkBuild, operatingSystemVersion,
            operatingSystemBuild, architecture,
        ]
        guard compactFields.allSatisfy({ phase2IsOpaqueToken($0, maximumBytes: 128) }),
              phase2IsBoundedIdentifier(hardwareModel, maximumBytes: 128),
              phase2IsBoundedIdentifier(processorFamily, maximumBytes: 256),
              Self.isLowercaseHex(macScopeCommit, exactCount: 40)
        else { throw Phase2QualificationEnvironmentV2ValidationError.invalidField }
        guard [appExecutableDigest, workerExecutableDigest, signingRequirementDigest]
            .allSatisfy(phase2IsSHA256Hex)
        else { throw Phase2QualificationEnvironmentV2ValidationError.invalidDigest }
        guard physicalMemoryBytes > 0,
              physicalMemoryBytes <= 1_099_511_627_776,
              (1...1_024).contains(physicalCoreCount),
              (physicalCoreCount...1_024).contains(logicalCoreCount),
              (1...physicalCoreCount).contains(performanceCoreCount),
              (1...physicalCoreCount).contains(efficiencyCoreCount),
              performanceCoreCount + efficiencyCoreCount == physicalCoreCount
        else { throw Phase2QualificationEnvironmentV2ValidationError.invalidHardware }

        self.bundleShortVersion = bundleShortVersion
        self.bundleVersion = bundleVersion
        self.macScopeCommit = macScopeCommit
        self.appExecutableDigest = appExecutableDigest
        self.workerExecutableDigest = workerExecutableDigest
        self.signingRequirementDigest = signingRequirementDigest
        self.xcodeVersion = xcodeVersion
        self.xcodeBuild = xcodeBuild
        self.swiftCompilerVersion = swiftCompilerVersion
        self.sdkVersion = sdkVersion
        self.sdkBuild = sdkBuild
        self.operatingSystemVersion = operatingSystemVersion
        self.operatingSystemBuild = operatingSystemBuild
        self.architecture = architecture
        self.hardwareModel = hardwareModel
        self.processorFamily = processorFamily
        self.physicalMemoryBytes = physicalMemoryBytes
        self.physicalCoreCount = physicalCoreCount
        self.logicalCoreCount = logicalCoreCount
        self.performanceCoreCount = performanceCoreCount
        self.efficiencyCoreCount = efficiencyCoreCount
    }

    func contentIdentity() throws -> Phase2ProtocolComponentIdentity {
        try Phase2QualificationV2Identity.make(
            id: "phase2.r1.qualification-environment.v2",
            version: 2,
            object: [
                "app_executable_digest": appExecutableDigest,
                "architecture": architecture,
                "bundle_short_version": bundleShortVersion,
                "bundle_version": bundleVersion,
                "hardware_model": hardwareModel,
                "efficiency_core_count": efficiencyCoreCount,
                "logical_core_count": logicalCoreCount,
                "macscope_commit": macScopeCommit,
                "operating_system_build": operatingSystemBuild,
                "operating_system_version": operatingSystemVersion,
                "physical_core_count": physicalCoreCount,
                "physical_memory_bytes": Int64(physicalMemoryBytes),
                "performance_core_count": performanceCoreCount,
                "processor_family": processorFamily,
                "sdk_build": sdkBuild,
                "sdk_version": sdkVersion,
                "signing_requirement_digest": signingRequirementDigest,
                "swift_compiler_version": swiftCompilerVersion,
                "worker_executable_digest": workerExecutableDigest,
                "xcode_build": xcodeBuild,
                "xcode_version": xcodeVersion,
            ]
        )
    }

    private static func isLowercaseHex(_ value: String, exactCount: Int) -> Bool {
        value.utf8.count == exactCount && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }
}

struct Phase2QualificationEnvironmentObservation: Sendable {
    var bundleShortVersion: String
    var bundleVersion: String
    var macScopeCommit: String
    var appExecutableDigest: String
    var workerExecutableDigest: String
    var signingRequirementDigest: String
    var xcodeVersion: String
    var xcodeBuild: String
    var swiftCompilerVersion: String
    var sdkVersion: String
    var sdkBuild: String
    var operatingSystemVersion: String
    var operatingSystemBuild: String
    var architecture: String
    var hardwareModel: String
    var processorFamily: String
    var physicalMemoryBytes: UInt64
    var physicalCoreCount: Int
    var logicalCoreCount: Int
    var performanceCoreCount: Int
    var efficiencyCoreCount: Int
}

struct Phase2QualificationHardwarePolicy: Hashable, Sendable {
    static let thisM1Max64GiB = Self(
        hardwareModel: "MacBookPro18,2",
        processorFamily: "Apple M1 Max",
        physicalMemoryBytes: 68_719_476_736,
        physicalCoreCount: 10,
        logicalCoreCount: 10,
        performanceCoreCount: 8,
        efficiencyCoreCount: 2
    )

    let hardwareModel: String
    let processorFamily: String
    let physicalMemoryBytes: UInt64
    let physicalCoreCount: Int
    let logicalCoreCount: Int
    let performanceCoreCount: Int
    let efficiencyCoreCount: Int
}

struct Phase2QualificationEnvironmentCollector: Sendable {
    func collect(
        observation: Phase2QualificationEnvironmentObservation,
        hardwarePolicy: Phase2QualificationHardwarePolicy
    ) throws -> Phase2QualificationEnvironmentV2 {
        let strings = [
            observation.bundleShortVersion, observation.bundleVersion,
            observation.macScopeCommit, observation.appExecutableDigest,
            observation.workerExecutableDigest, observation.signingRequirementDigest,
            observation.xcodeVersion, observation.xcodeBuild,
            observation.swiftCompilerVersion, observation.sdkVersion, observation.sdkBuild,
            observation.operatingSystemVersion, observation.operatingSystemBuild,
            observation.architecture, observation.hardwareModel, observation.processorFamily,
        ]
        guard strings.allSatisfy(Self.isPayloadFree),
              observation.hardwareModel == hardwarePolicy.hardwareModel,
              observation.processorFamily == hardwarePolicy.processorFamily,
              observation.physicalMemoryBytes == hardwarePolicy.physicalMemoryBytes,
              observation.physicalCoreCount == hardwarePolicy.physicalCoreCount,
              observation.logicalCoreCount == hardwarePolicy.logicalCoreCount,
              observation.performanceCoreCount == hardwarePolicy.performanceCoreCount,
              observation.efficiencyCoreCount == hardwarePolicy.efficiencyCoreCount
        else { throw Phase2QualificationEnvironmentV2ValidationError.invalidHardware }
        return try .init(
            bundleShortVersion: observation.bundleShortVersion,
            bundleVersion: observation.bundleVersion,
            macScopeCommit: observation.macScopeCommit,
            appExecutableDigest: observation.appExecutableDigest,
            workerExecutableDigest: observation.workerExecutableDigest,
            signingRequirementDigest: observation.signingRequirementDigest,
            xcodeVersion: observation.xcodeVersion,
            xcodeBuild: observation.xcodeBuild,
            swiftCompilerVersion: observation.swiftCompilerVersion,
            sdkVersion: observation.sdkVersion,
            sdkBuild: observation.sdkBuild,
            operatingSystemVersion: observation.operatingSystemVersion,
            operatingSystemBuild: observation.operatingSystemBuild,
            architecture: observation.architecture,
            hardwareModel: observation.hardwareModel,
            processorFamily: observation.processorFamily,
            physicalMemoryBytes: observation.physicalMemoryBytes,
            physicalCoreCount: observation.physicalCoreCount,
            logicalCoreCount: observation.logicalCoreCount,
            performanceCoreCount: observation.performanceCoreCount,
            efficiencyCoreCount: observation.efficiencyCoreCount
        )
    }

    private static func isPayloadFree(_ value: String) -> Bool {
        guard value.utf8.count <= 256 else { return false }
        let lowered = value.lowercased()
        return !value.contains("/") && !value.contains("\\") && !value.contains("@")
            && !lowered.contains("://") && !lowered.contains("credential")
            && !lowered.contains("token=") && !lowered.contains("password")
    }
}

enum Phase2QualificationV2Identity {
    static func make(
        id: String,
        version: Int,
        object: [String: Any]
    ) throws -> Phase2ProtocolComponentIdentity {
        let bytes = try Phase2LengthFramedCanonicalEncoder().encode(object)
        let digest = SHA256.hash(data: bytes).map { byte in
            let value = String(byte, radix: 16, uppercase: false)
            return value.count == 1 ? "0" + value : value
        }.joined()
        return try .init(id: id, version: version, sha256: digest)
    }
}
