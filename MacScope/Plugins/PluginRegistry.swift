import CryptoKit
import Darwin
import Foundation

enum PluginTrustDecision: String, Hashable, Codable {
    case unknown
    case allowExternal
    case allowInProcess
    case deny
}

struct PluginDescriptor: Identifiable, Hashable {
    var id: String { manifest.identifier }

    var manifest: PluginManifest
    var manifestURL: URL
    var manifestHash: String?
    var trustDecision: PluginTrustDecision
    var lifecycleStatus: PluginLifecycleStatus
}

enum PluginDiscoveryDiagnosticSeverity: String, Hashable, Codable {
    case warning
    case error
}

enum PluginDiscoveryDiagnosticCode: String, Hashable, Codable {
    case fileReadFailed
    case malformedManifest
    case duplicateIdentifier
    case missingRequiredField
    case sdkMajorMismatch
    case unsupportedArchitecture
    case deniedByTrustPolicy
    case inProcessTrustRequired
    case externalTrustRequired
    case provenanceMissing
    case unsignedPlugin
    case developmentPluginNotAllowed
    case signingIdentityIncomplete
    case networkAccessDisabledByPolicy
    case processSpawnDisabledByPolicy
    case invalidBundledSample
    case commandCapabilityNotDeclared
    case commandPermissionEscalation
    case commandMutationPolicyInvalid
    case automationHelperPolicyInvalid
    case serviceModeMismatch
    case validationFailed
}

struct PluginDiscoveryDiagnostic: Identifiable, Hashable {
    var id: String {
        [
            manifestURL.path,
            manifestIdentifier ?? "",
            code.rawValue,
            severity.rawValue
        ]
        .joined(separator: "#")
    }

    var manifestURL: URL
    var manifestIdentifier: String?
    var manifestHash: String?
    var severity: PluginDiscoveryDiagnosticSeverity
    var code: PluginDiscoveryDiagnosticCode
    var message: String
}

struct PluginDiscoveryReport: Hashable {
    var descriptors: [PluginDescriptor]
    var diagnostics: [PluginDiscoveryDiagnostic]

    var errors: [PluginDiscoveryDiagnostic] {
        diagnostics.filter { $0.severity == .error }
    }

    var warnings: [PluginDiscoveryDiagnostic] {
        diagnostics.filter { $0.severity == .warning }
    }

    var hasErrors: Bool {
        !errors.isEmpty
    }

    var launchReadyDescriptors: [PluginDescriptor] {
        descriptors.filter(\.lifecycleStatus.isLaunchReady)
    }

    var productionReadyDescriptors: [PluginDescriptor] {
        descriptors.filter(\.lifecycleStatus.isProductionReady)
    }
}

enum PluginRegistryError: Error, Equatable, LocalizedError {
    case malformedManifest(String)
    case duplicateIdentifier(String)
    case missingRequiredField(String)
    case sdkMajorMismatch(plugin: String, host: String)
    case unsupportedArchitecture([String])
    case deniedByTrustPolicy(String)
    case inProcessRequiresExplicitTrust(String)
    case unsignedPluginRequiresSignature(
        identifier: String,
        distribution: PluginDistributionChannel,
        signatureState: PluginSignatureState
    )
    case signingIdentityIncomplete(
        identifier: String,
        distribution: PluginDistributionChannel,
        signatureState: PluginSignatureState
    )
    case developmentPluginRequiresSettings(String)
    case commandCapabilityNotDeclared(
        identifier: String,
        command: String,
        capability: PluginCapability
    )
    case commandPermissionExceedsManifest(
        identifier: String,
        command: String,
        requirement: String
    )
    case commandMutationRequiresCapability(
        identifier: String,
        command: String,
        mutationPolicy: PluginCommandMutationPolicy,
        capability: PluginCapability
    )
    case commandMutationRequiresUndoPolicy(
        identifier: String,
        command: String,
        mutationPolicy: PluginCommandMutationPolicy
    )
    case automationHelperCapabilityNotDeclared(
        identifier: String,
        helper: String,
        capability: PluginCapability
    )
    case automationHelperMissingForSurface(
        identifier: String,
        command: String,
        surface: PluginCommandSurface
    )
    case automationHelperMutatingSurfaceNotDeclared(
        identifier: String,
        helper: String,
        command: String,
        surface: PluginCommandSurface,
        mutationPolicy: PluginCommandMutationPolicy
    )
    case automationHelperMutationPolicyNotDeclared(
        identifier: String,
        helper: String,
        command: String,
        mutationPolicy: PluginCommandMutationPolicy
    )
    case automationHelperUndoPolicyInsufficient(
        identifier: String,
        helper: String,
        command: String,
        commandUndoPolicy: PluginCommandUndoPolicy,
        helperUndoPolicy: PluginCommandUndoPolicy
    )
    case automationHelperPolicyInvalid(
        identifier: String,
        helper: String,
        reason: String
    )
    case serviceModeMismatch(
        identifier: String,
        execution: PluginExecutionMode,
        serviceMode: PluginServiceMode
    )

    var errorDescription: String? {
        switch self {
        case .malformedManifest(let message):
            "Malformed plugin manifest: \(message)"
        case .duplicateIdentifier(let identifier):
            "Duplicate plugin identifier: \(identifier)"
        case .missingRequiredField(let field):
            "Missing required plugin manifest field: \(field)"
        case .sdkMajorMismatch(let plugin, let host):
            "Plugin SDK \(plugin) is incompatible with host SDK \(host)."
        case .unsupportedArchitecture(let architectures):
            "Plugin architectures are not supported on this host: \(architectures.joined(separator: ", "))."
        case .deniedByTrustPolicy(let identifier):
            "Plugin is denied by trust policy: \(identifier)"
        case .inProcessRequiresExplicitTrust(let identifier):
            "In-process plugin requires explicit trust: \(identifier)"
        case .unsignedPluginRequiresSignature(let identifier, let distribution, let signatureState):
            "Plugin \(identifier) from \(distribution.rawValue) distribution requires production signing; manifest declares \(signatureState.rawValue)."
        case .signingIdentityIncomplete(let identifier, let distribution, let signatureState):
            "Plugin \(identifier) from \(distribution.rawValue) distribution declares \(signatureState.rawValue) signing but omits team or signing identifier."
        case .developmentPluginRequiresSettings(let identifier):
            "Development plugin \(identifier) is disabled by Settings policy."
        case .commandCapabilityNotDeclared(let identifier, let command, let capability):
            "Plugin \(identifier) command \(command) declares capability \(capability.rawValue), but the manifest top-level capabilities do not include it."
        case .commandPermissionExceedsManifest(let identifier, let command, let requirement):
            "Plugin \(identifier) command \(command) requires \(requirement), but the manifest permissions do not grant it."
        case .commandMutationRequiresCapability(let identifier, let command, let mutationPolicy, let capability):
            "Plugin \(identifier) command \(command) declares \(mutationPolicy.rawValue), but the manifest does not include required capability \(capability.rawValue)."
        case .commandMutationRequiresUndoPolicy(let identifier, let command, let mutationPolicy):
            "Plugin \(identifier) command \(command) declares \(mutationPolicy.rawValue), but does not declare an undo policy decision."
        case .automationHelperCapabilityNotDeclared(let identifier, let helper, let capability):
            "Plugin \(identifier) automation helper \(helper) declares capability \(capability.rawValue), but the manifest top-level capabilities do not include it."
        case .automationHelperMissingForSurface(let identifier, let command, let surface):
            "Plugin \(identifier) command \(command) declares mutating \(surface.rawValue) automation, but no owned stdio helper declares that surface."
        case .automationHelperMutatingSurfaceNotDeclared(let identifier, let helper, let command, let surface, let mutationPolicy):
            "Plugin \(identifier) automation helper \(helper) exposes command \(command) on \(surface.rawValue), but does not declare that surface for \(mutationPolicy.rawValue) commands."
        case .automationHelperMutationPolicyNotDeclared(let identifier, let helper, let command, let mutationPolicy):
            "Plugin \(identifier) automation helper \(helper) exposes command \(command), but does not classify \(mutationPolicy.rawValue) as an allowed helper mutation policy."
        case .automationHelperUndoPolicyInsufficient(let identifier, let helper, let command, let commandUndoPolicy, let helperUndoPolicy):
            "Plugin \(identifier) automation helper \(helper) exposes command \(command) with undo policy \(commandUndoPolicy.rawValue), but helper undo policy is \(helperUndoPolicy.rawValue)."
        case .automationHelperPolicyInvalid(let identifier, let helper, let reason):
            "Plugin \(identifier) automation helper \(helper) is invalid: \(reason)"
        case .serviceModeMismatch(let identifier, let execution, let serviceMode):
            "Plugin \(identifier) declares execution \(execution) but service mode \(serviceMode.rawValue)."
        }
    }
}

struct PluginProvenancePolicy: Hashable, Codable {
    static let settingsDefault = PluginProvenancePolicy(runtimePolicy: .settingsDefault)

    var allowBundledUnsigned: Bool
    var allowDevelopmentUnsigned: Bool
    var requireSignedThirdParty: Bool
    var requireSigningIdentityForSignedPlugins: Bool

    init(
        allowBundledUnsigned: Bool,
        allowDevelopmentUnsigned: Bool,
        requireSignedThirdParty: Bool,
        requireSigningIdentityForSignedPlugins: Bool = true
    ) {
        self.allowBundledUnsigned = allowBundledUnsigned
        self.allowDevelopmentUnsigned = allowDevelopmentUnsigned
        self.requireSignedThirdParty = requireSignedThirdParty
        self.requireSigningIdentityForSignedPlugins = requireSigningIdentityForSignedPlugins
    }

    init(runtimePolicy: PluginRuntimePolicy) {
        self.init(
            allowBundledUnsigned: true,
            allowDevelopmentUnsigned: runtimePolicy.allowDevelopmentPlugins,
            requireSignedThirdParty: runtimePolicy.requireSignedPlugins
        )
    }

    func validate(_ manifest: PluginManifest) throws {
        let provenance = manifest.provenance
        let requiresProductionSigning: Bool

        switch provenance.distribution {
        case .bundled:
            requiresProductionSigning = !allowBundledUnsigned
        case .developer:
            if !provenance.satisfiesProductionSigning && !allowDevelopmentUnsigned {
                throw PluginRegistryError.developmentPluginRequiresSettings(manifest.identifier)
            }
            requiresProductionSigning = false
        case .thirdParty:
            requiresProductionSigning = requireSignedThirdParty
        case .unknown:
            requiresProductionSigning = false
        }

        if requiresProductionSigning && !provenance.satisfiesProductionSigning {
            throw PluginRegistryError.unsignedPluginRequiresSignature(
                identifier: manifest.identifier,
                distribution: provenance.distribution,
                signatureState: provenance.signatureState
            )
        }

        if requiresProductionSigning
            && requireSigningIdentityForSignedPlugins
            && !provenance.hasCompleteSigningIdentity {
            throw PluginRegistryError.signingIdentityIncomplete(
                identifier: manifest.identifier,
                distribution: provenance.distribution,
                signatureState: provenance.signatureState
            )
        }
    }
}

struct PluginRegistry {
    var hostSDKVersion: String = "0.1"
    var supportedArchitectures: Set<String> = ["arm64"]
    var runtimePolicy: PluginRuntimePolicy = .settingsDefault
    var provenancePolicy: PluginProvenancePolicy = .settingsDefault

    func loadManifest(at url: URL) throws -> PluginManifest {
        try decodeManifest(Data(contentsOf: url))
    }

    func discoverManifests(
        in directory: URL,
        trustDecisions: [String: PluginTrustDecision] = [:]
    ) throws -> [PluginDescriptor] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var identifiers = Set<String>()
        return try urls.map { url in
            let data = try Data(contentsOf: url)
            let manifest = try decodeManifest(data)
            guard identifiers.insert(manifest.identifier).inserted else {
                throw PluginRegistryError.duplicateIdentifier(manifest.identifier)
            }
            return try validate(
                manifest,
                manifestURL: url,
                trustDecision: trustDecisions[manifest.identifier] ?? .unknown,
                manifestHash: Self.sha256Hex(of: data)
            )
        }
    }

    func diagnoseManifests(
        in directory: URL,
        trustDecisions: [String: PluginTrustDecision] = [:]
    ) throws -> PluginDiscoveryReport {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var identifiers = Set<String>()
        var descriptors: [PluginDescriptor] = []
        var diagnostics: [PluginDiscoveryDiagnostic] = []

        for url in urls {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                diagnostics.append(
                    diagnostic(
                        for: url,
                        severity: .error,
                        code: .fileReadFailed,
                        message: "Could not read plugin manifest: \(error.localizedDescription)"
                    )
                )
                continue
            }

            let manifestHash = Self.sha256Hex(of: data)
            let manifest: PluginManifest
            do {
                manifest = try decodeManifest(data)
            } catch {
                diagnostics.append(
                    diagnostic(
                        for: url,
                        manifestHash: manifestHash,
                        severity: .error,
                        code: discoveryCode(for: error),
                        message: error.localizedDescription
                    )
                )
                continue
            }

            if !identifiers.insert(manifest.identifier).inserted {
                let error = PluginRegistryError.duplicateIdentifier(manifest.identifier)
                diagnostics.append(
                    diagnostic(
                        for: url,
                        manifestIdentifier: manifest.identifier,
                        manifestHash: manifestHash,
                        severity: .error,
                        code: .duplicateIdentifier,
                        message: error.localizedDescription
                    )
                )
                continue
            }

            do {
                let descriptor = try validate(
                    manifest,
                    manifestURL: url,
                    trustDecision: trustDecisions[manifest.identifier] ?? .unknown,
                    manifestHash: manifestHash
                )
                descriptors.append(descriptor)

                if descriptor.manifest.execution == .external
                    && descriptor.trustDecision != .allowExternal {
                    diagnostics.append(
                        diagnostic(
                            for: url,
                            manifestIdentifier: descriptor.manifest.identifier,
                            manifestHash: manifestHash,
                            severity: .warning,
                            code: .externalTrustRequired,
                            message: "External plugin requires explicit trust before execution: \(descriptor.manifest.identifier)"
                        )
                    )
                }

                diagnostics.append(
                    contentsOf: provenanceDiagnostics(
                        for: descriptor.manifest,
                        manifestURL: url,
                        manifestHash: manifestHash
                    )
                )
                diagnostics.append(
                    contentsOf: runtimePolicyDiagnostics(
                        for: descriptor.manifest,
                        manifestURL: url,
                        manifestHash: manifestHash
                    )
                )
            } catch {
                diagnostics.append(
                    diagnostic(
                        for: url,
                        manifestIdentifier: manifest.identifier,
                        manifestHash: manifestHash,
                        severity: .error,
                        code: discoveryCode(for: error),
                        message: error.localizedDescription
                    )
                )
            }
        }

        return PluginDiscoveryReport(
            descriptors: descriptors,
            diagnostics: diagnostics
        )
    }

    func validate(
        _ manifest: PluginManifest,
        manifestURL: URL = URL(fileURLWithPath: "/dev/null"),
        trustDecision: PluginTrustDecision,
        manifestHash: String? = nil
    ) throws -> PluginDescriptor {
        try require(!manifest.identifier.isEmpty, field: "identifier")
        try require(!manifest.displayName.isEmpty, field: "displayName")
        try require(!manifest.version.isEmpty, field: "version")
        try require(!manifest.sdkVersion.isEmpty, field: "sdkVersion")

        guard majorVersion(manifest.sdkVersion) == majorVersion(hostSDKVersion) else {
            throw PluginRegistryError.sdkMajorMismatch(
                plugin: manifest.sdkVersion,
                host: hostSDKVersion
            )
        }

        guard !supportedArchitectures.isDisjoint(with: Set(manifest.architectures)) else {
            throw PluginRegistryError.unsupportedArchitecture(manifest.architectures)
        }

        try validatePlanningMetadata(manifest)

        if trustDecision == .deny {
            throw PluginRegistryError.deniedByTrustPolicy(manifest.identifier)
        }

        if manifest.execution == .inProcess && trustDecision != .allowInProcess {
            throw PluginRegistryError.inProcessRequiresExplicitTrust(manifest.identifier)
        }

        try provenancePolicy.validate(manifest)

        return PluginDescriptor(
            manifest: manifest,
            manifestURL: manifestURL,
            manifestHash: manifestHash,
            trustDecision: trustDecision,
            lifecycleStatus: lifecycleStatus(
                for: manifest,
                trustDecision: trustDecision
            )
        )
    }

    private func require(_ condition: Bool, field: String) throws {
        if !condition {
            throw PluginRegistryError.missingRequiredField(field)
        }
    }

    private func validatePlanningMetadata(_ manifest: PluginManifest) throws {
        if let service = manifest.service {
            try validateServiceMetadata(service, for: manifest)
        }

        for helper in manifest.automationHelpers {
            try validateAutomationHelperDescriptor(helper, for: manifest)
        }

        for command in manifest.commands {
            try validateCommandDescriptor(command, for: manifest)
            try validateAutomationHelperCoverage(command, for: manifest)
        }
    }

    private func validateServiceMetadata(
        _ service: PluginServiceMetadata,
        for manifest: PluginManifest
    ) throws {
        guard service.mode.isCompatible(with: manifest.execution) else {
            throw PluginRegistryError.serviceModeMismatch(
                identifier: manifest.identifier,
                execution: manifest.execution,
                serviceMode: service.mode
            )
        }
    }

    private func validateCommandDescriptor(
        _ command: PluginCommandDescriptor,
        for manifest: PluginManifest
    ) throws {
        try require(!command.identifier.isEmpty, field: "commands.identifier")
        try require(!command.displayName.isEmpty, field: "commands.displayName")

        guard manifest.capabilities.contains(command.capability) else {
            throw PluginRegistryError.commandCapabilityNotDeclared(
                identifier: manifest.identifier,
                command: command.identifier,
                capability: command.capability
            )
        }

        if command.requiresNetwork && !manifest.permissions.network {
            throw PluginRegistryError.commandPermissionExceedsManifest(
                identifier: manifest.identifier,
                command: command.identifier,
                requirement: "network access"
            )
        }

        if command.requiresProcessSpawn && !manifest.permissions.processSpawn {
            throw PluginRegistryError.commandPermissionExceedsManifest(
                identifier: manifest.identifier,
                command: command.identifier,
                requirement: "process spawning"
            )
        }

        guard PluginRuntimeAuthorizer.includes(
            granted: manifest.permissions.filesystemScope,
            required: command.filesystemScope
        ) else {
            throw PluginRegistryError.commandPermissionExceedsManifest(
                identifier: manifest.identifier,
                command: command.identifier,
                requirement: "filesystem scope \(command.filesystemScope.rawValue)"
            )
        }

        if let requiredCapability = command.mutationPolicy.requiredCapability,
           !manifest.capabilities.contains(requiredCapability) {
            throw PluginRegistryError.commandMutationRequiresCapability(
                identifier: manifest.identifier,
                command: command.identifier,
                mutationPolicy: command.mutationPolicy,
                capability: requiredCapability
            )
        }

        if command.mutationPolicy.requiresUndoPolicyDecision
            && command.undoPolicy == .notApplicable {
            throw PluginRegistryError.commandMutationRequiresUndoPolicy(
                identifier: manifest.identifier,
                command: command.identifier,
                mutationPolicy: command.mutationPolicy
            )
        }

        if let commandServiceMode = command.serviceMode,
           let service = manifest.service,
           commandServiceMode != service.mode {
            throw PluginRegistryError.serviceModeMismatch(
                identifier: manifest.identifier,
                execution: manifest.execution,
                serviceMode: commandServiceMode
            )
        }
    }

    private func validateAutomationHelperDescriptor(
        _ helper: PluginAutomationHelperDescriptor,
        for manifest: PluginManifest
    ) throws {
        try require(!helper.identifier.isEmpty, field: "automationHelpers.identifier")
        try require(!helper.displayName.isEmpty, field: "automationHelpers.displayName")
        try require(!helper.surfaces.isEmpty, field: "automationHelpers.surfaces")
        try require(!helper.capabilities.isEmpty, field: "automationHelpers.capabilities")
        try require(!helper.mutationPolicies.isEmpty, field: "automationHelpers.mutationPolicies")

        guard helper.serviceMode == .stdioJSONRPC else {
            throw PluginRegistryError.automationHelperPolicyInvalid(
                identifier: manifest.identifier,
                helper: helper.identifier,
                reason: "owned CLI/MCP helpers must use stdio-json-rpc service mode"
            )
        }

        for surface in helper.surfaces {
            guard surface.isStdioAutomationHelperSurface else {
                throw PluginRegistryError.automationHelperPolicyInvalid(
                    identifier: manifest.identifier,
                    helper: helper.identifier,
                    reason: "surface \(surface.rawValue) is not a CLI/MCP stdio helper surface"
                )
            }
        }

        for surface in helper.mutatingSurfaces {
            guard surface.isStdioAutomationHelperSurface,
                  helper.surfaces.contains(surface) else {
                throw PluginRegistryError.automationHelperPolicyInvalid(
                    identifier: manifest.identifier,
                    helper: helper.identifier,
                    reason: "mutating surface \(surface.rawValue) must also be declared in helper surfaces"
                )
            }
        }

        for capability in helper.capabilities {
            guard manifest.capabilities.contains(capability) else {
                throw PluginRegistryError.automationHelperCapabilityNotDeclared(
                    identifier: manifest.identifier,
                    helper: helper.identifier,
                    capability: capability
                )
            }
        }

        for mutationPolicy in helper.mutationPolicies {
            if let requiredCapability = mutationPolicy.requiredCapability,
               !helper.capabilities.contains(requiredCapability) {
                throw PluginRegistryError.automationHelperCapabilityNotDeclared(
                    identifier: manifest.identifier,
                    helper: helper.identifier,
                    capability: requiredCapability
                )
            }

            if mutationPolicy.requiresUndoPolicyDecision
                && helper.undoPolicy == .notApplicable {
                throw PluginRegistryError.automationHelperPolicyInvalid(
                    identifier: manifest.identifier,
                    helper: helper.identifier,
                    reason: "mutation policy \(mutationPolicy.rawValue) requires helper undo metadata"
                )
            }
        }
    }

    private func validateAutomationHelperCoverage(
        _ command: PluginCommandDescriptor,
        for manifest: PluginManifest
    ) throws {
        guard !manifest.automationHelpers.isEmpty else {
            return
        }

        for surface in command.surfaces where surface.isStdioAutomationHelperSurface {
            let helpers = manifest.automationHelpers.filter {
                $0.surfaces.contains(surface)
            }

            guard !helpers.isEmpty else {
                if command.mutationPolicy.isMutating {
                    throw PluginRegistryError.automationHelperMissingForSurface(
                        identifier: manifest.identifier,
                        command: command.identifier,
                        surface: surface
                    )
                }
                continue
            }

            guard let helper = helpers.first(where: {
                $0.capabilities.contains(command.capability)
            }) else {
                throw PluginRegistryError.automationHelperCapabilityNotDeclared(
                    identifier: manifest.identifier,
                    helper: helpers[0].identifier,
                    capability: command.capability
                )
            }

            guard command.mutationPolicy.isMutating else {
                continue
            }

            guard helper.mutatingSurfaces.contains(surface) else {
                throw PluginRegistryError.automationHelperMutatingSurfaceNotDeclared(
                    identifier: manifest.identifier,
                    helper: helper.identifier,
                    command: command.identifier,
                    surface: surface,
                    mutationPolicy: command.mutationPolicy
                )
            }

            guard helper.mutationPolicies.contains(command.mutationPolicy) else {
                throw PluginRegistryError.automationHelperMutationPolicyNotDeclared(
                    identifier: manifest.identifier,
                    helper: helper.identifier,
                    command: command.identifier,
                    mutationPolicy: command.mutationPolicy
                )
            }

            guard helperUndoPolicy(
                helper.undoPolicy,
                supports: command.undoPolicy
            ) else {
                throw PluginRegistryError.automationHelperUndoPolicyInsufficient(
                    identifier: manifest.identifier,
                    helper: helper.identifier,
                    command: command.identifier,
                    commandUndoPolicy: command.undoPolicy,
                    helperUndoPolicy: helper.undoPolicy
                )
            }
        }
    }

    private func helperUndoPolicy(
        _ helperPolicy: PluginCommandUndoPolicy,
        supports commandPolicy: PluginCommandUndoPolicy
    ) -> Bool {
        switch commandPolicy {
        case .notApplicable:
            return true
        case .unsupported:
            return helperPolicy != .notApplicable
        case .supported:
            return helperPolicy == .supported || helperPolicy == .required
        case .required:
            return helperPolicy == .required
        }
    }

    private func majorVersion(_ version: String) -> Int {
        Int(version.split(separator: ".").first ?? "0") ?? 0
    }

    private func decodeManifest(_ data: Data) throws -> PluginManifest {
        do {
            return try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let error as DecodingError {
            throw PluginRegistryError.malformedManifest(String(describing: error))
        } catch {
            throw error
        }
    }

    private func diagnostic(
        for url: URL,
        manifestIdentifier: String? = nil,
        manifestHash: String? = nil,
        severity: PluginDiscoveryDiagnosticSeverity,
        code: PluginDiscoveryDiagnosticCode,
        message: String
    ) -> PluginDiscoveryDiagnostic {
        PluginDiscoveryDiagnostic(
            manifestURL: url,
            manifestIdentifier: manifestIdentifier?.isEmpty == true ? nil : manifestIdentifier,
            manifestHash: manifestHash,
            severity: severity,
            code: code,
            message: message
        )
    }

    private func discoveryCode(for error: Error) -> PluginDiscoveryDiagnosticCode {
        guard let registryError = error as? PluginRegistryError else {
            return .validationFailed
        }

        switch registryError {
        case .malformedManifest:
            return .malformedManifest
        case .duplicateIdentifier:
            return .duplicateIdentifier
        case .missingRequiredField:
            return .missingRequiredField
        case .sdkMajorMismatch:
            return .sdkMajorMismatch
        case .unsupportedArchitecture:
            return .unsupportedArchitecture
        case .deniedByTrustPolicy:
            return .deniedByTrustPolicy
        case .inProcessRequiresExplicitTrust:
            return .inProcessTrustRequired
        case .unsignedPluginRequiresSignature:
            return .unsignedPlugin
        case .signingIdentityIncomplete:
            return .signingIdentityIncomplete
        case .developmentPluginRequiresSettings:
            return .developmentPluginNotAllowed
        case .commandCapabilityNotDeclared:
            return .commandCapabilityNotDeclared
        case .commandPermissionExceedsManifest:
            return .commandPermissionEscalation
        case .commandMutationRequiresCapability,
             .commandMutationRequiresUndoPolicy:
            return .commandMutationPolicyInvalid
        case .automationHelperCapabilityNotDeclared,
             .automationHelperMissingForSurface,
             .automationHelperMutatingSurfaceNotDeclared,
             .automationHelperMutationPolicyNotDeclared,
             .automationHelperUndoPolicyInsufficient,
             .automationHelperPolicyInvalid:
            return .automationHelperPolicyInvalid
        case .serviceModeMismatch:
            return .serviceModeMismatch
        }
    }

    private func provenanceDiagnostics(
        for manifest: PluginManifest,
        manifestURL: URL,
        manifestHash: String?
    ) -> [PluginDiscoveryDiagnostic] {
        var diagnostics: [PluginDiscoveryDiagnostic] = []

        if manifest.provenance == .unspecified {
            diagnostics.append(
                diagnostic(
                    for: manifestURL,
                    manifestIdentifier: manifest.identifier,
                    manifestHash: manifestHash,
                    severity: .warning,
                    code: .provenanceMissing,
                    message: "Plugin manifest does not declare provenance or signing metadata: \(manifest.identifier)"
                )
            )
        }

        if provenancePolicy.requireSigningIdentityForSignedPlugins
            && !manifest.provenance.hasCompleteSigningIdentity {
            diagnostics.append(
                diagnostic(
                    for: manifestURL,
                    manifestIdentifier: manifest.identifier,
                    manifestHash: manifestHash,
                    severity: .warning,
                    code: .signingIdentityIncomplete,
                    message: "Plugin manifest declares \(manifest.provenance.signatureState.rawValue) signing but omits team or signing identifier: \(manifest.identifier)"
                )
            )
        }

        return diagnostics
    }

    private func runtimePolicyDiagnostics(
        for manifest: PluginManifest,
        manifestURL: URL,
        manifestHash: String?
    ) -> [PluginDiscoveryDiagnostic] {
        var diagnostics: [PluginDiscoveryDiagnostic] = []

        if manifest.permissions.network && !runtimePolicy.allowNetworkAccess {
            diagnostics.append(
                diagnostic(
                    for: manifestURL,
                    manifestIdentifier: manifest.identifier,
                    manifestHash: manifestHash,
                    severity: .warning,
                    code: .networkAccessDisabledByPolicy,
                    message: "Plugin manifest requests network access, but Settings policy disables plugin network access: \(manifest.identifier)"
                )
            )
        }

        if manifest.permissions.processSpawn && !runtimePolicy.allowProcessSpawn {
            diagnostics.append(
                diagnostic(
                    for: manifestURL,
                    manifestIdentifier: manifest.identifier,
                    manifestHash: manifestHash,
                    severity: .warning,
                    code: .processSpawnDisabledByPolicy,
                    message: "Plugin manifest requests process spawning, but Settings policy disables plugin process spawning: \(manifest.identifier)"
                )
            )
        }

        return diagnostics
    }

    private func lifecycleStatus(
        for manifest: PluginManifest,
        trustDecision: PluginTrustDecision
    ) -> PluginLifecycleStatus {
        var launchBlockers: [PluginLifecycleGate] = []
        var productionBlockers: [PluginLifecycleGate] = []

        if trustDecision == .deny {
            launchBlockers.append(.deniedByTrustPolicy)
        }

        if manifest.execution == .external && trustDecision != .allowExternal {
            launchBlockers.append(.externalTrustRequired)
        }

        if manifest.execution == .inProcess && trustDecision != .allowInProcess {
            launchBlockers.append(.inProcessTrustRequired)
        }

        switch manifest.provenance.distribution {
        case .unknown:
            productionBlockers.append(.provenanceMissing)
        case .developer:
            if !manifest.provenance.satisfiesProductionSigning {
                productionBlockers.append(.developmentPlugin)
            }
        case .thirdParty:
            if provenancePolicy.requireSignedThirdParty
                && !manifest.provenance.satisfiesProductionSigning {
                productionBlockers.append(.productionSignatureRequired)
            }
        case .bundled:
            break
        }

        if provenancePolicy.requireSigningIdentityForSignedPlugins
            && !manifest.provenance.hasCompleteSigningIdentity {
            productionBlockers.append(.signingIdentityIncomplete)
        }

        if manifest.permissions.network && !runtimePolicy.allowNetworkAccess {
            productionBlockers.append(.networkAccessDisabledByPolicy)
        }

        if manifest.permissions.processSpawn && !runtimePolicy.allowProcessSpawn {
            productionBlockers.append(.processSpawnDisabledByPolicy)
        }

        return PluginLifecycleStatus(
            launchBlockers: launchBlockers,
            productionBlockers: productionBlockers
        )
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct PluginBundledSampleValidationResult {
    var descriptor: PluginDescriptor?
    var diagnostics: [PluginDiscoveryDiagnostic]
    var executionPlan: PluginExternalExecutionPlan?

    var errors: [PluginDiscoveryDiagnostic] {
        diagnostics.filter { $0.severity == .error }
    }

    var warnings: [PluginDiscoveryDiagnostic] {
        diagnostics.filter { $0.severity == .warning }
    }

    var isLaunchReady: Bool {
        descriptor != nil && executionPlan != nil && errors.isEmpty
    }
}

extension PluginRegistry {
    func validateBundledSample(
        manifestURL: URL,
        trustDecision: PluginTrustDecision = .allowExternal,
        externalHost: PluginExternalExecutionHost = PluginExternalExecutionHost()
    ) -> PluginBundledSampleValidationResult {
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            return PluginBundledSampleValidationResult(
                descriptor: nil,
                diagnostics: [
                    diagnostic(
                        for: manifestURL,
                        severity: .error,
                        code: .fileReadFailed,
                        message: "Could not read bundled sample manifest: \(error.localizedDescription)"
                    )
                ],
                executionPlan: nil
            )
        }

        let manifestHash = Self.sha256Hex(of: data)
        let manifest: PluginManifest
        do {
            manifest = try decodeManifest(data)
        } catch {
            return PluginBundledSampleValidationResult(
                descriptor: nil,
                diagnostics: [
                    diagnostic(
                        for: manifestURL,
                        manifestHash: manifestHash,
                        severity: .error,
                        code: discoveryCode(for: error),
                        message: error.localizedDescription
                    )
                ],
                executionPlan: nil
            )
        }

        var diagnostics = provenanceDiagnostics(
            for: manifest,
            manifestURL: manifestURL,
            manifestHash: manifestHash
        )

        guard manifest.provenance.distribution == .bundled else {
            diagnostics.append(
                diagnostic(
                    for: manifestURL,
                    manifestIdentifier: manifest.identifier,
                    manifestHash: manifestHash,
                    severity: .error,
                    code: .invalidBundledSample,
                    message: "Bundled sample validation requires bundled provenance for \(manifest.identifier)."
                )
            )
            return PluginBundledSampleValidationResult(
                descriptor: nil,
                diagnostics: diagnostics,
                executionPlan: nil
            )
        }

        let descriptor: PluginDescriptor
        do {
            descriptor = try validate(
                manifest,
                manifestURL: manifestURL,
                trustDecision: trustDecision,
                manifestHash: manifestHash
            )
        } catch {
            diagnostics.append(
                diagnostic(
                    for: manifestURL,
                    manifestIdentifier: manifest.identifier,
                    manifestHash: manifestHash,
                    severity: .error,
                    code: discoveryCode(for: error),
                    message: error.localizedDescription
                )
            )
            return PluginBundledSampleValidationResult(
                descriptor: nil,
                diagnostics: diagnostics,
                executionPlan: nil
            )
        }

        let plan: PluginExternalExecutionPlan
        do {
            plan = try externalHost.dryRun(descriptor)
        } catch {
            diagnostics.append(
                diagnostic(
                    for: manifestURL,
                    manifestIdentifier: manifest.identifier,
                    manifestHash: manifestHash,
                    severity: .error,
                    code: .invalidBundledSample,
                    message: error.localizedDescription
                )
            )
            return PluginBundledSampleValidationResult(
                descriptor: descriptor,
                diagnostics: diagnostics,
                executionPlan: nil
            )
        }

        let sampleRootURL = manifestURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let executableURL = plan.executableURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard Self.isURL(executableURL, containedIn: sampleRootURL) else {
            diagnostics.append(
                diagnostic(
                    for: manifestURL,
                    manifestIdentifier: manifest.identifier,
                    manifestHash: manifestHash,
                    severity: .error,
                    code: .invalidBundledSample,
                    message: "Bundled sample executable must be contained by the manifest directory for \(manifest.identifier): \(plan.executableURL.path)"
                )
            )
            return PluginBundledSampleValidationResult(
                descriptor: descriptor,
                diagnostics: diagnostics,
                executionPlan: nil
            )
        }

        return PluginBundledSampleValidationResult(
            descriptor: descriptor,
            diagnostics: diagnostics,
            executionPlan: plan
        )
    }

    private static func isURL(_ url: URL, containedIn rootURL: URL) -> Bool {
        let pathComponents = url.pathComponents
        let rootComponents = rootURL.pathComponents
        guard pathComponents.count > rootComponents.count else {
            return false
        }

        return pathComponents.prefix(rootComponents.count) == rootComponents[...]
    }
}

struct PluginExternalExecutionPlan: Equatable {
    var pluginIdentifier: String
    var displayName: String
    var executableURL: URL
    var manifestHash: String?
    var trustDecision: PluginTrustDecision
    var lifecycleStatus: PluginLifecycleStatus
    var provenance: PluginProvenance

    var isLaunchReady: Bool {
        lifecycleStatus.isLaunchReady
    }

    var isProductionReady: Bool {
        lifecycleStatus.isProductionReady
    }
}

struct PluginRuntimePolicy: Hashable, Codable {
    enum StorageKey {
        static let allowDevelopmentPlugins = "allowDevelopmentPlugins"
        static let requireSignedPlugins = "requireSignedPlugins"
        static let allowNetworkAccess = "allowPluginNetworkAccess"
        static let allowProcessSpawn = "allowPluginProcessSpawn"
    }

    static let settingsDefault = PluginRuntimePolicy(
        allowDevelopmentPlugins: false,
        requireSignedPlugins: true,
        allowNetworkAccess: false,
        allowProcessSpawn: false
    )

    var allowDevelopmentPlugins: Bool
    var requireSignedPlugins: Bool
    var allowNetworkAccess: Bool
    var allowProcessSpawn: Bool

    init(
        allowDevelopmentPlugins: Bool,
        requireSignedPlugins: Bool,
        allowNetworkAccess: Bool,
        allowProcessSpawn: Bool
    ) {
        self.allowDevelopmentPlugins = allowDevelopmentPlugins
        self.requireSignedPlugins = requireSignedPlugins
        self.allowNetworkAccess = allowNetworkAccess
        self.allowProcessSpawn = allowProcessSpawn
    }

    init(userDefaults: UserDefaults) {
        let defaults = Self.settingsDefault
        self.init(
            allowDevelopmentPlugins: Self.bool(
                forKey: StorageKey.allowDevelopmentPlugins,
                in: userDefaults,
                default: defaults.allowDevelopmentPlugins
            ),
            requireSignedPlugins: Self.bool(
                forKey: StorageKey.requireSignedPlugins,
                in: userDefaults,
                default: defaults.requireSignedPlugins
            ),
            allowNetworkAccess: Self.bool(
                forKey: StorageKey.allowNetworkAccess,
                in: userDefaults,
                default: defaults.allowNetworkAccess
            ),
            allowProcessSpawn: Self.bool(
                forKey: StorageKey.allowProcessSpawn,
                in: userDefaults,
                default: defaults.allowProcessSpawn
            )
        )
    }

    private static func bool(
        forKey key: String,
        in userDefaults: UserDefaults,
        default defaultValue: Bool
    ) -> Bool {
        (userDefaults.object(forKey: key) as? Bool) ?? defaultValue
    }
}

struct PluginRuntimeAuthorizationRequirement: Hashable, Codable {
    var command: String
    var capability: PluginCapability
    var requiresNetwork: Bool
    var requiresProcessSpawn: Bool
    var filesystemScope: PluginFilesystemScope

    init(
        command: String,
        capability: PluginCapability,
        requiresNetwork: Bool = false,
        requiresProcessSpawn: Bool = false,
        filesystemScope: PluginFilesystemScope = .none
    ) {
        self.command = command
        self.capability = capability
        self.requiresNetwork = requiresNetwork
        self.requiresProcessSpawn = requiresProcessSpawn
        self.filesystemScope = filesystemScope
    }
}

extension PluginCommandDescriptor {
    var authorizationRequirement: PluginRuntimeAuthorizationRequirement {
        PluginRuntimeAuthorizationRequirement(
            command: identifier,
            capability: capability,
            requiresNetwork: requiresNetwork,
            requiresProcessSpawn: requiresProcessSpawn,
            filesystemScope: filesystemScope
        )
    }
}

enum PluginRuntimeAuthorizationError: Error, Equatable, LocalizedError {
    case missingCapability(identifier: String, command: String, capability: PluginCapability)
    case networkPermissionDenied(identifier: String, command: String)
    case networkDisabledByPolicy(identifier: String, command: String)
    case processSpawnPermissionDenied(identifier: String, command: String)
    case processSpawnDisabledByPolicy(identifier: String, command: String)
    case filesystemScopeDenied(
        identifier: String,
        command: String,
        required: PluginFilesystemScope,
        granted: PluginFilesystemScope
    )

    var errorDescription: String? {
        switch self {
        case .missingCapability(let identifier, let command, let capability):
            "Plugin \(identifier) is not authorized to run \(command); missing capability \(capability.rawValue)."
        case .networkPermissionDenied(let identifier, let command):
            "Plugin \(identifier) is not authorized to run \(command); manifest network permission is disabled."
        case .networkDisabledByPolicy(let identifier, let command):
            "Plugin \(identifier) is not authorized to run \(command); Settings policy disables plugin network access."
        case .processSpawnPermissionDenied(let identifier, let command):
            "Plugin \(identifier) is not authorized to run \(command); manifest process-spawn permission is disabled."
        case .processSpawnDisabledByPolicy(let identifier, let command):
            "Plugin \(identifier) is not authorized to run \(command); Settings policy disables plugin process spawning."
        case .filesystemScopeDenied(let identifier, let command, let required, let granted):
            "Plugin \(identifier) is not authorized to run \(command); filesystem scope \(required.rawValue) is required but manifest grants \(granted.rawValue)."
        }
    }
}

struct PluginRuntimeAuthorizer {
    var policy: PluginRuntimePolicy

    init(policy: PluginRuntimePolicy) {
        self.policy = policy
    }

    init(userDefaults: UserDefaults = .standard) {
        self.init(policy: PluginRuntimePolicy(userDefaults: userDefaults))
    }

    func authorize(
        _ descriptor: PluginDescriptor,
        requirement: PluginRuntimeAuthorizationRequirement?
    ) throws {
        guard let requirement else {
            return
        }

        let manifest = descriptor.manifest
        guard manifest.capabilities.contains(requirement.capability) else {
            throw PluginRuntimeAuthorizationError.missingCapability(
                identifier: manifest.identifier,
                command: requirement.command,
                capability: requirement.capability
            )
        }

        if requirement.requiresNetwork && !manifest.permissions.network {
            throw PluginRuntimeAuthorizationError.networkPermissionDenied(
                identifier: manifest.identifier,
                command: requirement.command
            )
        }

        if requirement.requiresNetwork && !policy.allowNetworkAccess {
            throw PluginRuntimeAuthorizationError.networkDisabledByPolicy(
                identifier: manifest.identifier,
                command: requirement.command
            )
        }

        if requirement.requiresProcessSpawn && !manifest.permissions.processSpawn {
            throw PluginRuntimeAuthorizationError.processSpawnPermissionDenied(
                identifier: manifest.identifier,
                command: requirement.command
            )
        }

        if requirement.requiresProcessSpawn && !policy.allowProcessSpawn {
            throw PluginRuntimeAuthorizationError.processSpawnDisabledByPolicy(
                identifier: manifest.identifier,
                command: requirement.command
            )
        }

        guard Self.includes(
            granted: manifest.permissions.filesystemScope,
            required: requirement.filesystemScope
        ) else {
            throw PluginRuntimeAuthorizationError.filesystemScopeDenied(
                identifier: manifest.identifier,
                command: requirement.command,
                required: requirement.filesystemScope,
                granted: manifest.permissions.filesystemScope
            )
        }
    }

    static func includes(
        granted: PluginFilesystemScope,
        required: PluginFilesystemScope
    ) -> Bool {
        switch required {
        case .none:
            return true
        case .userSelected:
            return granted == .userSelected || granted == .workspace
        case .workspace:
            return granted == .workspace
        }
    }
}

struct PluginAutomationCommandPlan: Hashable, Codable {
    var pluginIdentifier: String
    var pluginDisplayName: String
    var commandIdentifier: String
    var commandDisplayName: String
    var surface: PluginCommandSurface
    var automationHelper: PluginAutomationHelperDescriptor? = nil
    var execution: PluginExecutionMode
    var serviceMode: PluginServiceMode
    var serviceIdentifier: String?
    var manifestHash: String?
    var authorizationRequirement: PluginRuntimeAuthorizationRequirement
    var mutationPolicy: PluginCommandMutationPolicy
    var undoPolicy: PluginCommandUndoPolicy
    var lifecycleStatus: PluginLifecycleStatus

    var isOutOfProcess: Bool {
        serviceMode.isOutOfProcess
    }

    var requiresUndoRegistration: Bool {
        mutationPolicy.requiresHostUndoRegistration
    }
}

struct PluginAutomationInvocationArguments: Hashable, Codable {
    static let maximumCount = 64
    static let maximumKeyLength = 80
    static let maximumValueLength = 4_096

    var values: [String: String]

    init(_ values: [String: String]) throws {
        guard values.count <= Self.maximumCount else {
            throw PluginAutomationInvocationError.tooManyArguments(
                maximum: Self.maximumCount
            )
        }

        var normalized: [String: String] = [:]
        for (key, value) in values {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty else {
                throw PluginAutomationInvocationError.emptyArgumentKey
            }

            guard normalizedKey.count <= Self.maximumKeyLength else {
                throw PluginAutomationInvocationError.argumentKeyTooLong(
                    key: normalizedKey,
                    maximum: Self.maximumKeyLength
                )
            }

            guard value.count <= Self.maximumValueLength else {
                throw PluginAutomationInvocationError.argumentValueTooLong(
                    key: normalizedKey,
                    maximum: Self.maximumValueLength
                )
            }

            normalized[normalizedKey] = value
        }

        self.values = normalized
    }

    var sortedKeys: [String] {
        values.keys.sorted()
    }

    var redactedAuditValues: [String: String] {
        values.mapValues { value in
            value
        }
        .reduce(into: [:]) { partial, entry in
            partial[entry.key] = Self.shouldRedact(entry.key)
                ? "<redacted>"
                : entry.value
        }
    }

    private static func shouldRedact(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        return normalized.contains("token")
            || normalized.contains("secret")
            || normalized.contains("password")
            || normalized.contains("apikey")
            || normalized.contains("authorization")
            || normalized.contains("credential")
    }
}

struct PluginAutomationInvocationAudit: Hashable, Codable {
    var pluginIdentifier: String
    var commandIdentifier: String
    var surface: PluginCommandSurface
    var serviceMode: PluginServiceMode
    var manifestHash: String?
    var lifecycleState: PluginLifecycleState
    var requiresUndoRegistration: Bool
    var argumentCount: Int
    var redactedArguments: [String: String]
}

struct PluginAutomationInvocationEnvelope: Identifiable, Hashable, Codable {
    var id: UUID { requestID }

    var requestID: UUID
    var createdAt: Date
    var plan: PluginAutomationCommandPlan
    var arguments: PluginAutomationInvocationArguments
    var audit: PluginAutomationInvocationAudit

    var routingKey: String {
        [
            plan.pluginIdentifier,
            plan.commandIdentifier,
            plan.surface.rawValue
        ]
        .joined(separator: "#")
    }
}

enum PluginAutomationHostKind: String, Hashable, Codable {
    case xpcService = "xpc-service"
    case externalStdio = "external-stdio"
    case externalHelper = "external-helper"
}

enum PluginAutomationHostLifecycleStage: String, Hashable, Codable, CaseIterable {
    case validateEnvelope = "validate-envelope"
    case authorizeRuntime = "authorize-runtime"
    case connectXPCService = "connect-xpc-service"
    case spawnExternalHost = "spawn-external-host"
    case dispatchInvocation = "dispatch-invocation"
    case awaitReply = "await-reply"
    case recordAudit = "record-audit"
    case releaseHost = "release-host"
    case terminateHost = "terminate-host"
}

enum PluginAutomationTrustBoundary: String, Hashable, Codable {
    case externalProcess = "external-process"
}

enum PluginAutomationHostLifecycleError: Error, Equatable, LocalizedError {
    case inProcessHostUnsupported(identifier: String, command: String)

    var errorDescription: String? {
        switch self {
        case .inProcessHostUnsupported(let identifier, let command):
            "Plugin \(identifier) command \(command) cannot be given an automation host lifecycle because in-process plugin hosting is disabled."
        }
    }
}

struct PluginAutomationPermissionAuditRecord: Hashable, Codable {
    var capability: PluginCapability
    var requiresNetwork: Bool
    var requiresProcessSpawn: Bool
    var filesystemScope: PluginFilesystemScope
    var mutationPolicy: PluginCommandMutationPolicy
    var undoPolicy: PluginCommandUndoPolicy
    var requiresUndoRegistration: Bool
}

struct PluginAutomationHostLifecyclePlan: Hashable, Codable {
    var requestID: UUID
    var pluginIdentifier: String
    var commandIdentifier: String
    var surface: PluginCommandSurface
    var automationHelper: PluginAutomationHelperDescriptor?
    var execution: PluginExecutionMode
    var serviceMode: PluginServiceMode
    var serviceIdentifier: String?
    var hostKind: PluginAutomationHostKind
    var trustBoundary: PluginAutomationTrustBoundary
    var lifecycleStages: [PluginAutomationHostLifecycleStage]
    var permissionAudit: PluginAutomationPermissionAuditRecord
    var invocationAudit: PluginAutomationInvocationAudit

    var keepsPluginOutOfProcess: Bool {
        trustBoundary == .externalProcess && serviceMode.isOutOfProcess
    }

    init(envelope: PluginAutomationInvocationEnvelope) throws {
        let plan = envelope.plan
        guard plan.serviceMode.isOutOfProcess else {
            throw PluginAutomationHostLifecycleError.inProcessHostUnsupported(
                identifier: plan.pluginIdentifier,
                command: plan.commandIdentifier
            )
        }

        let hostKind = Self.hostKind(for: plan.serviceMode)
        self.requestID = envelope.requestID
        self.pluginIdentifier = plan.pluginIdentifier
        self.commandIdentifier = plan.commandIdentifier
        self.surface = plan.surface
        self.automationHelper = plan.automationHelper
        self.execution = plan.execution
        self.serviceMode = plan.serviceMode
        self.serviceIdentifier = plan.serviceIdentifier
        self.hostKind = hostKind
        self.trustBoundary = .externalProcess
        self.lifecycleStages = Self.lifecycleStages(for: hostKind)
        self.permissionAudit = PluginAutomationPermissionAuditRecord(
            capability: plan.authorizationRequirement.capability,
            requiresNetwork: plan.authorizationRequirement.requiresNetwork,
            requiresProcessSpawn: plan.authorizationRequirement.requiresProcessSpawn,
            filesystemScope: plan.authorizationRequirement.filesystemScope,
            mutationPolicy: plan.mutationPolicy,
            undoPolicy: plan.undoPolicy,
            requiresUndoRegistration: plan.requiresUndoRegistration
        )
        self.invocationAudit = envelope.audit
    }

    private static func hostKind(
        for serviceMode: PluginServiceMode
    ) -> PluginAutomationHostKind {
        switch serviceMode {
        case .xpcService:
            return .xpcService
        case .stdioJSONRPC:
            return .externalStdio
        case .helperExecutable:
            return .externalHelper
        case .inProcess:
            preconditionFailure("In-process automation host lifecycle must be rejected before host kind resolution.")
        }
    }

    private static func lifecycleStages(
        for hostKind: PluginAutomationHostKind
    ) -> [PluginAutomationHostLifecycleStage] {
        switch hostKind {
        case .xpcService:
            return [
                .validateEnvelope,
                .authorizeRuntime,
                .connectXPCService,
                .dispatchInvocation,
                .awaitReply,
                .recordAudit,
                .releaseHost
            ]
        case .externalStdio, .externalHelper:
            return [
                .validateEnvelope,
                .authorizeRuntime,
                .spawnExternalHost,
                .dispatchInvocation,
                .awaitReply,
                .recordAudit,
                .terminateHost
            ]
        }
    }
}

enum PluginAutomationInvocationError: Error, Equatable, LocalizedError {
    case emptyArgumentKey
    case tooManyArguments(maximum: Int)
    case argumentKeyTooLong(key: String, maximum: Int)
    case argumentValueTooLong(key: String, maximum: Int)

    var errorDescription: String? {
        switch self {
        case .emptyArgumentKey:
            "Plugin automation invocation arguments cannot contain an empty key."
        case .tooManyArguments(let maximum):
            "Plugin automation invocation has too many arguments; maximum is \(maximum)."
        case .argumentKeyTooLong(let key, let maximum):
            "Plugin automation invocation argument key \(key) is longer than \(maximum) characters."
        case .argumentValueTooLong(let key, let maximum):
            "Plugin automation invocation argument \(key) is longer than \(maximum) characters."
        }
    }
}

enum PluginAutomationPlanningError: Error, Equatable, LocalizedError {
    case unsupportedSurface(PluginCommandSurface)
    case commandNotDeclared(identifier: String, command: String)
    case commandSurfaceNotDeclared(
        identifier: String,
        command: String,
        surface: PluginCommandSurface
    )
    case notLaunchReady(identifier: String, blockers: [PluginLifecycleGate])
    case serviceModeMismatch(
        identifier: String,
        execution: PluginExecutionMode,
        serviceMode: PluginServiceMode
    )
    case inProcessAutomationUnsupported(identifier: String, command: String)
    case runtimeAuthorizationDenied(PluginRuntimeAuthorizationError)

    var errorDescription: String? {
        switch self {
        case .unsupportedSurface(let surface):
            "Plugin automation planning does not expose \(surface.rawValue) commands."
        case .commandNotDeclared(let identifier, let command):
            "Plugin \(identifier) does not declare command \(command)."
        case .commandSurfaceNotDeclared(let identifier, let command, let surface):
            "Plugin \(identifier) command \(command) is not declared for \(surface.rawValue)."
        case .notLaunchReady(let identifier, let blockers):
            "Plugin \(identifier) is not launch-ready for automation planning: \(blockers.map(\.rawValue).joined(separator: ", "))."
        case .serviceModeMismatch(let identifier, let execution, let serviceMode):
            "Plugin \(identifier) declares execution \(execution) but automation service mode \(serviceMode.rawValue)."
        case .inProcessAutomationUnsupported(let identifier, let command):
            "Plugin \(identifier) command \(command) cannot be exposed to automation through an in-process service plan."
        case .runtimeAuthorizationDenied(let error):
            "Plugin automation planning denied runtime authorization: \(error.localizedDescription)"
        }
    }
}

struct PluginAutomationFacadePlanner {
    var runtimeAuthorizer: PluginRuntimeAuthorizer

    init(runtimeAuthorizer: PluginRuntimeAuthorizer = PluginRuntimeAuthorizer()) {
        self.runtimeAuthorizer = runtimeAuthorizer
    }

    init(policy: PluginRuntimePolicy) {
        self.init(runtimeAuthorizer: PluginRuntimeAuthorizer(policy: policy))
    }

    func planCommand(
        _ descriptor: PluginDescriptor,
        commandIdentifier: String,
        surface: PluginCommandSurface
    ) throws -> PluginAutomationCommandPlan {
        guard surface.isAutomationFacade else {
            throw PluginAutomationPlanningError.unsupportedSurface(surface)
        }

        guard descriptor.lifecycleStatus.isLaunchReady else {
            throw PluginAutomationPlanningError.notLaunchReady(
                identifier: descriptor.manifest.identifier,
                blockers: descriptor.lifecycleStatus.launchBlockers
            )
        }

        guard let command = descriptor.manifest.commands.first(
            where: { $0.identifier == commandIdentifier }
        ) else {
            throw PluginAutomationPlanningError.commandNotDeclared(
                identifier: descriptor.manifest.identifier,
                command: commandIdentifier
            )
        }

        guard command.surfaces.contains(surface) else {
            throw PluginAutomationPlanningError.commandSurfaceNotDeclared(
                identifier: descriptor.manifest.identifier,
                command: command.identifier,
                surface: surface
            )
        }

        let serviceMode = command.serviceMode
            ?? automationHelper(
                for: command,
                surface: surface,
                in: descriptor.manifest
            )?.serviceMode
            ?? descriptor.manifest.service?.mode
            ?? PluginServiceMode.inferred(for: descriptor.manifest.execution)
        guard serviceMode.isCompatible(with: descriptor.manifest.execution) else {
            throw PluginAutomationPlanningError.serviceModeMismatch(
                identifier: descriptor.manifest.identifier,
                execution: descriptor.manifest.execution,
                serviceMode: serviceMode
            )
        }

        guard serviceMode.isOutOfProcess else {
            throw PluginAutomationPlanningError.inProcessAutomationUnsupported(
                identifier: descriptor.manifest.identifier,
                command: command.identifier
            )
        }

        let requirement = command.authorizationRequirement
        do {
            try runtimeAuthorizer.authorize(descriptor, requirement: requirement)
        } catch let error as PluginRuntimeAuthorizationError {
            throw PluginAutomationPlanningError.runtimeAuthorizationDenied(error)
        }

        let helper = automationHelper(
            for: command,
            surface: surface,
            in: descriptor.manifest
        )

        return PluginAutomationCommandPlan(
            pluginIdentifier: descriptor.manifest.identifier,
            pluginDisplayName: descriptor.manifest.displayName,
            commandIdentifier: command.identifier,
            commandDisplayName: command.displayName,
            surface: surface,
            automationHelper: helper,
            execution: descriptor.manifest.execution,
            serviceMode: serviceMode,
            serviceIdentifier: helper?.serviceIdentifier
                ?? descriptor.manifest.service?.identifier,
            manifestHash: descriptor.manifestHash,
            authorizationRequirement: requirement,
            mutationPolicy: command.mutationPolicy,
            undoPolicy: command.undoPolicy,
            lifecycleStatus: descriptor.lifecycleStatus
        )
    }

    func plans(
        for descriptor: PluginDescriptor,
        surface: PluginCommandSurface
    ) throws -> [PluginAutomationCommandPlan] {
        guard surface.isAutomationFacade else {
            throw PluginAutomationPlanningError.unsupportedSurface(surface)
        }

        return try descriptor.manifest.commands
            .filter { $0.surfaces.contains(surface) }
            .map {
                try planCommand(
                    descriptor,
                    commandIdentifier: $0.identifier,
                    surface: surface
                )
            }
    }

    func invocationEnvelope(
        for descriptor: PluginDescriptor,
        commandIdentifier: String,
        surface: PluginCommandSurface,
        arguments: [String: String] = [:],
        requestID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> PluginAutomationInvocationEnvelope {
        let plan = try planCommand(
            descriptor,
            commandIdentifier: commandIdentifier,
            surface: surface
        )
        let invocationArguments = try PluginAutomationInvocationArguments(arguments)
        let audit = PluginAutomationInvocationAudit(
            pluginIdentifier: plan.pluginIdentifier,
            commandIdentifier: plan.commandIdentifier,
            surface: plan.surface,
            serviceMode: plan.serviceMode,
            manifestHash: plan.manifestHash,
            lifecycleState: plan.lifecycleStatus.state,
            requiresUndoRegistration: plan.requiresUndoRegistration,
            argumentCount: invocationArguments.values.count,
            redactedArguments: invocationArguments.redactedAuditValues
        )

        return PluginAutomationInvocationEnvelope(
            requestID: requestID,
            createdAt: createdAt,
            plan: plan,
            arguments: invocationArguments,
            audit: audit
        )
    }

    private func automationHelper(
        for command: PluginCommandDescriptor,
        surface: PluginCommandSurface,
        in manifest: PluginManifest
    ) -> PluginAutomationHelperDescriptor? {
        manifest.automationHelpers.first {
            $0.surfaces.contains(surface)
                && $0.capabilities.contains(command.capability)
                && (!command.mutationPolicy.isMutating
                    || $0.mutatingSurfaces.contains(surface))
        }
    }

    func hostLifecyclePlan(
        for envelope: PluginAutomationInvocationEnvelope
    ) throws -> PluginAutomationHostLifecyclePlan {
        try PluginAutomationHostLifecyclePlan(envelope: envelope)
    }
}

enum PluginExternalRunStatus: String, Hashable, Codable {
    case started
    case completed
    case failed
    case cancelled
}

struct PluginExternalRunRecord: Identifiable, Hashable, Codable {
    var id: UUID { requestID }

    var requestID: UUID
    var pluginIdentifier: String
    var displayName: String
    var executablePath: String
    var manifestHash: String?
    var status: PluginExternalRunStatus
    var startedAt: Date
    var completedAt: Date?
    var terminationStatus: Int32?
    var stdout: String
    var stderr: String
    var log: String
    var errorMessage: String?
}

enum PluginExternalRunRetryBlocker: String, Hashable, Codable {
    case requestStillRunning = "request-still-running"
    case requestAlreadyCompleted = "request-already-completed"
}

struct PluginExternalRunRetryEligibility: Hashable, Codable {
    var blockers: [PluginExternalRunRetryBlocker]

    var isEligible: Bool {
        blockers.isEmpty
    }

    init(blockers: [PluginExternalRunRetryBlocker]) {
        self.blockers = blockers
    }
}

enum PluginExternalRunLogSortOrder: String, Hashable, Codable {
    case newestFirst = "newest-first"
    case oldestFirst = "oldest-first"
}

struct PluginExternalRunLogFilter: Hashable, Codable {
    static let maximumLimit = 200

    var pluginIdentifier: String?
    var statuses: Set<PluginExternalRunStatus>
    var limit: Int
    var sortOrder: PluginExternalRunLogSortOrder

    init(
        pluginIdentifier: String? = nil,
        statuses: Set<PluginExternalRunStatus> = [],
        limit: Int = 50,
        sortOrder: PluginExternalRunLogSortOrder = .newestFirst
    ) {
        let normalizedIdentifier = pluginIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.pluginIdentifier = normalizedIdentifier?.isEmpty == true
            ? nil
            : normalizedIdentifier
        self.statuses = statuses
        self.limit = limit
        self.sortOrder = sortOrder
    }

    var effectiveLimit: Int {
        min(max(limit, 0), Self.maximumLimit)
    }

    func apply(to records: [PluginExternalRunRecord]) -> [PluginExternalRunRecord] {
        guard effectiveLimit > 0 else {
            return []
        }

        return records
            .filter(matches)
            .sorted(by: isOrderedBefore)
            .prefix(effectiveLimit)
            .map { $0 }
    }

    func matches(_ record: PluginExternalRunRecord) -> Bool {
        if let pluginIdentifier, record.pluginIdentifier != pluginIdentifier {
            return false
        }

        if !statuses.isEmpty && !statuses.contains(record.status) {
            return false
        }

        return true
    }

    private func isOrderedBefore(
        _ lhs: PluginExternalRunRecord,
        _ rhs: PluginExternalRunRecord
    ) -> Bool {
        let lhsDate = lhs.completedAt ?? lhs.startedAt
        let rhsDate = rhs.completedAt ?? rhs.startedAt

        if lhsDate != rhsDate {
            switch sortOrder {
            case .newestFirst:
                return lhsDate > rhsDate
            case .oldestFirst:
                return lhsDate < rhsDate
            }
        }

        return lhs.requestID.uuidString < rhs.requestID.uuidString
    }
}

extension PluginExternalRunRecord {
    var isTerminal: Bool {
        status != .started
    }

    var retryEligibility: PluginExternalRunRetryEligibility {
        switch status {
        case .failed, .cancelled:
            PluginExternalRunRetryEligibility(blockers: [])
        case .started:
            PluginExternalRunRetryEligibility(blockers: [.requestStillRunning])
        case .completed:
            PluginExternalRunRetryEligibility(blockers: [.requestAlreadyCompleted])
        }
    }

    var isRetryEligible: Bool {
        retryEligibility.isEligible
    }
}

struct PluginExternalExecutionResult<Response> {
    var response: Response
    var terminationStatus: Int32
    var stdout: String
    var stderr: String
    var runRecord: PluginExternalRunRecord
}

enum PluginExternalExecutionError: Error, Equatable, LocalizedError {
    case deniedByTrustPolicy(String)
    case externalRequiresExplicitTrust(String)
    case unsupportedExecutionMode(identifier: String, mode: PluginExecutionMode)
    case notLaunchReady(identifier: String, blockers: [PluginLifecycleGate])
    case missingEntryPoint(String)
    case entryPointMustBeAbsolute(String)
    case entryPointNotExecutable(String)
    case launchFailed(String)
    case cancelled(identifier: String)
    case timedOut(identifier: String, timeout: TimeInterval)
    case outputTooLarge(identifier: String, limit: Int)
    case nonZeroExit(identifier: String, status: Int32, stderr: String)
    case invalidJSONOutput(identifier: String, message: String)
    case runtimeAuthorizationDenied(PluginRuntimeAuthorizationError)

    var errorDescription: String? {
        switch self {
        case .deniedByTrustPolicy(let identifier):
            "Plugin is denied by trust policy: \(identifier)"
        case .externalRequiresExplicitTrust(let identifier):
            "External plugin requires explicit trust: \(identifier)"
        case .unsupportedExecutionMode(let identifier, let mode):
            "Plugin \(identifier) cannot run through the external host because its execution mode is \(mode)."
        case .notLaunchReady(let identifier, let blockers):
            "External plugin \(identifier) is not launch-ready: \(blockers.map(\.rawValue).joined(separator: ", "))."
        case .missingEntryPoint(let identifier):
            "External plugin is missing an executable entry point: \(identifier)"
        case .entryPointMustBeAbsolute(let entryPoint):
            "External plugin entry point must be an absolute path: \(entryPoint)"
        case .entryPointNotExecutable(let entryPoint):
            "External plugin entry point is not executable: \(entryPoint)"
        case .launchFailed(let message):
            "External plugin launch failed: \(message)"
        case .cancelled(let identifier):
            "External plugin \(identifier) was cancelled by the host."
        case .timedOut(let identifier, let timeout):
            "External plugin \(identifier) timed out after \(timeout) seconds."
        case .outputTooLarge(let identifier, let limit):
            "External plugin \(identifier) produced more than \(limit) bytes of output."
        case .nonZeroExit(let identifier, let status, let stderr):
            "External plugin \(identifier) exited with status \(status): \(stderr)"
        case .invalidJSONOutput(let identifier, let message):
            "External plugin \(identifier) produced invalid JSON: \(message)"
        case .runtimeAuthorizationDenied(let error):
            "External plugin runtime authorization denied: \(error.localizedDescription)"
        }
    }
}

struct PluginExternalExecutionHost {
    var timeout: TimeInterval
    var maximumOutputBytes: Int
    var environment: [String: String]
    var runtimeAuthorizer: PluginRuntimeAuthorizer
    var recordLifecycle: ((PluginExternalRunRecord) -> Void)?
    var currentDate: () -> Date

    init(
        timeout: TimeInterval = 5,
        maximumOutputBytes: Int = 1_048_576,
        environment: [String: String] = Self.defaultEnvironment,
        runtimeAuthorizer: PluginRuntimeAuthorizer = PluginRuntimeAuthorizer(),
        recordLifecycle: ((PluginExternalRunRecord) -> Void)? = nil,
        currentDate: @escaping () -> Date = Date.init
    ) {
        self.timeout = max(0.1, timeout)
        self.maximumOutputBytes = max(1, maximumOutputBytes)
        self.environment = environment
        self.runtimeAuthorizer = runtimeAuthorizer
        self.recordLifecycle = recordLifecycle
        self.currentDate = currentDate
    }

    func dryRun(_ descriptor: PluginDescriptor) throws -> PluginExternalExecutionPlan {
        try executionPlan(for: descriptor)
    }

    func invoke<Request: Encodable, Response: Decodable>(
        _ descriptor: PluginDescriptor,
        request: Request,
        responseType: Response.Type,
        authorizationRequirement: PluginRuntimeAuthorizationRequirement? = nil,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        isCancellationRequested: () -> Bool = { false },
        requestID: UUID = UUID()
    ) throws -> PluginExternalExecutionResult<Response> {
        let plan = try executionPlan(for: descriptor)
        do {
            try runtimeAuthorizer.authorize(
                descriptor,
                requirement: authorizationRequirement
            )
        } catch let error as PluginRuntimeAuthorizationError {
            let executionError = PluginExternalExecutionError.runtimeAuthorizationDenied(error)
            recordLifecycle?(
                authorizationDeniedRecord(
                    plan: plan,
                    requestID: requestID,
                    errorMessage: executionError.localizedDescription
                )
            )
            throw executionError
        }

        if isCancellationRequested() {
            let executionError = PluginExternalExecutionError.cancelled(
                identifier: plan.pluginIdentifier
            )
            recordLifecycle?(
                cancellationRecord(
                    plan: plan,
                    requestID: requestID,
                    errorMessage: executionError.localizedDescription,
                    detail: "External plugin request \(requestID.uuidString) was cancelled before launch for \(plan.pluginIdentifier)."
                )
            )
            throw executionError
        }

        var requestData = try encoder.encode(request)
        requestData.append(0x0A)

        let startedAt = currentDate()
        var runRecord = PluginExternalRunRecord(
            requestID: requestID,
            pluginIdentifier: plan.pluginIdentifier,
            displayName: plan.displayName,
            executablePath: plan.executableURL.path,
            manifestHash: plan.manifestHash,
            status: .started,
            startedAt: startedAt,
            completedAt: nil,
            terminationStatus: nil,
            stdout: "",
            stderr: "",
            log: Self.logLine(
                status: .started,
                date: startedAt,
                message: "External plugin request \(requestID.uuidString) started for \(plan.pluginIdentifier). \(Self.auditContext(for: plan, requestByteCount: requestData.count))"
            ),
            errorMessage: nil
        )
        recordLifecycle?(runRecord)

        func finish(
            status: PluginExternalRunStatus,
            terminationStatus: Int32?,
            stdout: String,
            stderr: String,
            errorMessage: String?
        ) -> PluginExternalRunRecord {
            var updated = runRecord
            updated.status = status
            updated.completedAt = currentDate()
            updated.terminationStatus = terminationStatus
            updated.stdout = stdout
            updated.stderr = stderr
            updated.errorMessage = errorMessage
            updated.log.append(
                "\n" + Self.logLine(
                    status: status,
                    date: updated.completedAt ?? currentDate(),
                    message: Self.lifecycleMessage(
                        pluginIdentifier: plan.pluginIdentifier,
                        status: status,
                        terminationStatus: terminationStatus,
                        errorMessage: errorMessage
                    )
                )
            )
            runRecord = updated
            recordLifecycle?(updated)
            return updated
        }

        let fileManager = FileManager.default
        let invocationDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MacScopePluginHost-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: invocationDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: invocationDirectory) }

        let stdoutURL = invocationDirectory.appendingPathComponent("stdout.json")
        let stderrURL = invocationDirectory.appendingPathComponent("stderr.log")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let inputPipe = Pipe()
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = []
        process.environment = invocationEnvironment(for: descriptor)
        process.standardInput = inputPipe
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        // The request is fed through a non-blocking, SIGPIPE-suppressed descriptor inside the
        // deadline loop below. A plugin that never reads stdin must not hold the caller in
        // write() before the timeout starts, and a plugin that exits early must not signal the app.
        let requestFeeder: PluginStdinFeeder
        do {
            requestFeeder = try PluginStdinFeeder(
                handle: inputPipe.fileHandleForWriting,
                request: requestData
            )
            try process.run()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            let executionError = PluginExternalExecutionError.launchFailed(error.localizedDescription)
            _ = finish(
                status: .failed,
                terminationStatus: nil,
                stdout: "",
                stderr: "",
                errorMessage: executionError.localizedDescription
            )
            throw executionError
        }

        let deadline = Date().addingTimeInterval(timeout)
        defer { requestFeeder.close() }
        requestFeeder.pump()
        while process.isRunning {
            if isCancellationRequested() {
                requestFeeder.close()
                Self.terminate(process)
                try? stdoutHandle.close()
                try? stderrHandle.close()
                let capture = Self.capturedOutput(
                    stdoutURL: stdoutURL,
                    stderrURL: stderrURL,
                    limit: maximumOutputBytes
                )
                let executionError = PluginExternalExecutionError.cancelled(
                    identifier: plan.pluginIdentifier
                )
                _ = finish(
                    status: .cancelled,
                    terminationStatus: process.terminationStatus,
                    stdout: capture.stdout,
                    stderr: capture.stderr,
                    errorMessage: executionError.localizedDescription
                )
                throw executionError
            }

            if Date() >= deadline {
                requestFeeder.close()
                Self.terminate(process)
                try? stdoutHandle.close()
                try? stderrHandle.close()
                let capture = Self.capturedOutput(
                    stdoutURL: stdoutURL,
                    stderrURL: stderrURL,
                    limit: maximumOutputBytes
                )
                let executionError = PluginExternalExecutionError.timedOut(
                    identifier: plan.pluginIdentifier,
                    timeout: timeout
                )
                _ = finish(
                    status: .cancelled,
                    terminationStatus: process.terminationStatus,
                    stdout: capture.stdout,
                    stderr: capture.stderr,
                    errorMessage: executionError.localizedDescription
                )
                throw executionError
            }
            if requestFeeder.isOpen {
                requestFeeder.pump()
                requestFeeder.waitUntilWritable(milliseconds: 10)
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        requestFeeder.close()

        try? stdoutHandle.close()
        try? stderrHandle.close()

        let stdoutData = try Data(contentsOf: stdoutURL)
        let stderrData = try Data(contentsOf: stderrURL)
        let stdout = Self.text(from: stdoutData, limit: maximumOutputBytes)
        let stderr = Self.text(from: stderrData, limit: maximumOutputBytes)

        guard process.terminationStatus == 0 else {
            let executionError = PluginExternalExecutionError.nonZeroExit(
                identifier: plan.pluginIdentifier,
                status: process.terminationStatus,
                stderr: stderr
            )
            _ = finish(
                status: .failed,
                terminationStatus: process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                errorMessage: executionError.localizedDescription
            )
            throw executionError
        }

        guard stdoutData.count <= maximumOutputBytes else {
            let executionError = PluginExternalExecutionError.outputTooLarge(
                identifier: plan.pluginIdentifier,
                limit: maximumOutputBytes
            )
            _ = finish(
                status: .failed,
                terminationStatus: process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                errorMessage: executionError.localizedDescription
            )
            throw executionError
        }

        do {
            let response = try decoder.decode(responseType, from: stdoutData)
            let completedRecord = finish(
                status: .completed,
                terminationStatus: process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                errorMessage: nil
            )
            return PluginExternalExecutionResult(
                response: response,
                terminationStatus: process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                runRecord: completedRecord
            )
        } catch {
            let executionError = PluginExternalExecutionError.invalidJSONOutput(
                identifier: plan.pluginIdentifier,
                message: String(describing: error)
            )
            _ = finish(
                status: .failed,
                terminationStatus: process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                errorMessage: executionError.localizedDescription
            )
            throw executionError
        }
    }

    private func executionPlan(for descriptor: PluginDescriptor) throws -> PluginExternalExecutionPlan {
        if descriptor.trustDecision == .deny {
            throw PluginExternalExecutionError.deniedByTrustPolicy(descriptor.manifest.identifier)
        }

        guard descriptor.manifest.execution == .external else {
            throw PluginExternalExecutionError.unsupportedExecutionMode(
                identifier: descriptor.manifest.identifier,
                mode: descriptor.manifest.execution
            )
        }

        guard descriptor.trustDecision == .allowExternal else {
            throw PluginExternalExecutionError.externalRequiresExplicitTrust(
                descriptor.manifest.identifier
            )
        }

        guard descriptor.lifecycleStatus.isLaunchReady else {
            throw PluginExternalExecutionError.notLaunchReady(
                identifier: descriptor.manifest.identifier,
                blockers: descriptor.lifecycleStatus.launchBlockers
            )
        }

        guard let entryPoint = descriptor.manifest.entryPoint, !entryPoint.isEmpty else {
            throw PluginExternalExecutionError.missingEntryPoint(descriptor.manifest.identifier)
        }

        guard entryPoint.hasPrefix("/") else {
            throw PluginExternalExecutionError.entryPointMustBeAbsolute(entryPoint)
        }

        let executableURL = URL(fileURLWithPath: entryPoint).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            FileManager.default.isExecutableFile(atPath: executableURL.path)
        else {
            throw PluginExternalExecutionError.entryPointNotExecutable(executableURL.path)
        }

        return PluginExternalExecutionPlan(
            pluginIdentifier: descriptor.manifest.identifier,
            displayName: descriptor.manifest.displayName,
            executableURL: executableURL,
            manifestHash: descriptor.manifestHash,
            trustDecision: descriptor.trustDecision,
            lifecycleStatus: descriptor.lifecycleStatus,
            provenance: descriptor.manifest.provenance
        )
    }

    private func authorizationDeniedRecord(
        plan: PluginExternalExecutionPlan,
        requestID: UUID,
        errorMessage: String
    ) -> PluginExternalRunRecord {
        let now = currentDate()
        return PluginExternalRunRecord(
            requestID: requestID,
            pluginIdentifier: plan.pluginIdentifier,
            displayName: plan.displayName,
            executablePath: plan.executableURL.path,
            manifestHash: plan.manifestHash,
            status: .failed,
            startedAt: now,
            completedAt: now,
            terminationStatus: nil,
            stdout: "",
            stderr: "",
            log: Self.logLine(
                status: .failed,
                date: now,
                message: "External plugin request \(requestID.uuidString) was denied before launch for \(plan.pluginIdentifier): \(errorMessage)"
            ),
            errorMessage: errorMessage
        )
    }

    private func cancellationRecord(
        plan: PluginExternalExecutionPlan,
        requestID: UUID,
        errorMessage: String,
        detail: String
    ) -> PluginExternalRunRecord {
        let now = currentDate()
        return PluginExternalRunRecord(
            requestID: requestID,
            pluginIdentifier: plan.pluginIdentifier,
            displayName: plan.displayName,
            executablePath: plan.executableURL.path,
            manifestHash: plan.manifestHash,
            status: .cancelled,
            startedAt: now,
            completedAt: now,
            terminationStatus: nil,
            stdout: "",
            stderr: "",
            log: Self.logLine(
                status: .cancelled,
                date: now,
                message: "\(detail) \(Self.auditContext(for: plan, requestByteCount: nil))"
            ),
            errorMessage: errorMessage
        )
    }

    private func invocationEnvironment(for descriptor: PluginDescriptor) -> [String: String] {
        var values = environment
        values["MACSCOPE_PLUGIN_IDENTIFIER"] = descriptor.manifest.identifier
        values["MACSCOPE_PLUGIN_VERSION"] = descriptor.manifest.version
        values["MACSCOPE_PLUGIN_TRUST_DECISION"] = descriptor.trustDecision.rawValue
        values["MACSCOPE_PLUGIN_LIFECYCLE_STATE"] = descriptor.lifecycleStatus.state.rawValue
        values["MACSCOPE_PLUGIN_LAUNCH_READY"] = descriptor.lifecycleStatus.isLaunchReady ? "1" : "0"
        values["MACSCOPE_PLUGIN_PRODUCTION_READY"] = descriptor.lifecycleStatus.isProductionReady ? "1" : "0"
        values["MACSCOPE_PLUGIN_PROVENANCE_DISTRIBUTION"] = descriptor.manifest.provenance.distribution.rawValue
        values["MACSCOPE_PLUGIN_SIGNATURE_STATE"] = descriptor.manifest.provenance.signatureState.rawValue
        if let teamIdentifier = descriptor.manifest.provenance.teamIdentifier {
            values["MACSCOPE_PLUGIN_TEAM_IDENTIFIER"] = teamIdentifier
        }
        if let signingIdentifier = descriptor.manifest.provenance.signingIdentifier {
            values["MACSCOPE_PLUGIN_SIGNING_IDENTIFIER"] = signingIdentifier
        }
        if let source = descriptor.manifest.provenance.source {
            values["MACSCOPE_PLUGIN_PROVENANCE_SOURCE"] = source
        }
        if let manifestHash = descriptor.manifestHash {
            values["MACSCOPE_PLUGIN_MANIFEST_HASH"] = manifestHash
        }
        return values
    }

    private static let defaultEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": FileManager.default.temporaryDirectory.path
    ]

    private static func capturedOutput(
        stdoutURL: URL,
        stderrURL: URL,
        limit: Int
    ) -> (stdout: String, stderr: String) {
        let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
        return (
            stdout: text(from: stdoutData, limit: limit),
            stderr: text(from: stderrData, limit: limit)
        )
    }

    private static func text(from data: Data, limit: Int) -> String {
        String(data: Data(data.prefix(limit)), encoding: .utf8) ?? ""
    }

    private static func terminate(_ process: Process) {
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(0.2)
        while process.isRunning && Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        // Poll instead of `waitUntilExit()`, which runs the current run loop and must not be
        // re-entered from a SwiftUI update on the main thread. SIGKILL cannot be ignored, so the
        // loop ends once Foundation observes the reaped child.
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private static func auditContext(
        for plan: PluginExternalExecutionPlan,
        requestByteCount: Int?
    ) -> String {
        var fields = [
            "trust=\(plan.trustDecision.rawValue)",
            "lifecycle=\(plan.lifecycleStatus.state.rawValue)",
            "launchReady=\(plan.isLaunchReady)",
            "productionReady=\(plan.isProductionReady)",
            "distribution=\(plan.provenance.distribution.rawValue)",
            "signature=\(plan.provenance.signatureState.rawValue)"
        ]
        if let manifestHash = plan.manifestHash {
            fields.append("manifestHash=\(manifestHash)")
        }
        if let requestByteCount {
            fields.append("requestBytes=\(requestByteCount)")
        }
        return fields.joined(separator: " ")
    }

    private static func logLine(
        status: PluginExternalRunStatus,
        date: Date,
        message: String
    ) -> String {
        "[\(status.rawValue)] \(ISO8601DateFormatter().string(from: date)) \(message)"
    }

    private static func lifecycleMessage(
        pluginIdentifier: String,
        status: PluginExternalRunStatus,
        terminationStatus: Int32?,
        errorMessage: String?
    ) -> String {
        switch status {
        case .started:
            "External plugin request started for \(pluginIdentifier)."
        case .completed:
            "External plugin \(pluginIdentifier) completed with status \(terminationStatus ?? 0)."
        case .failed:
            "External plugin \(pluginIdentifier) failed: \(errorMessage ?? "unknown error")."
        case .cancelled:
            "External plugin \(pluginIdentifier) was cancelled: \(errorMessage ?? "unknown cancellation")."
        }
    }
}

/// Writes an external plugin request to the plugin's stdin without ever blocking the caller.
///
/// The write descriptor is made non-blocking and descriptor-locally SIGPIPE-suppressed before
/// launch. `pump()` writes whatever the pipe accepts, so the host's deadline and cancellation
/// checks keep running when a plugin never reads stdin. The descriptor is closed after the full
/// request is written (plugins that read to EOF still terminate), after the plugin closes its end
/// (EPIPE), or when the host stops the plugin. Single-thread use only, from `invoke`.
final class PluginStdinFeeder {
    private let handle: FileHandle
    private let request: Data
    private var offset = 0
    private(set) var isOpen = true

    init(handle: FileHandle, request: Data) throws {
        let descriptor = handle.fileDescriptor
        guard Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
        }
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags != -1, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
        }
        self.handle = handle
        self.request = request
    }

    /// Writes as many pending request bytes as the pipe accepts without blocking.
    func pump() {
        guard isOpen else { return }
        let descriptor = handle.fileDescriptor
        var shouldClose = false
        request.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let base = rawBuffer.baseAddress else {
                shouldClose = true
                return
            }
            while offset < rawBuffer.count {
                let written = Darwin.write(descriptor, base + offset, rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                let code = Darwin.errno
                if written < 0 && code == EINTR { continue }
                if written < 0 && code == EAGAIN { return }
                // EPIPE (the plugin closed stdin or exited) or another write failure: stop
                // feeding. The plugin's exit status and output decide the result, as before.
                shouldClose = true
                return
            }
            shouldClose = true
        }
        if shouldClose { close() }
    }

    /// Waits up to `milliseconds` for the pipe to accept more bytes (or report its reader gone).
    func waitUntilWritable(milliseconds: Int32) {
        guard isOpen else { return }
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
        _ = Darwin.poll(&descriptor, 1, milliseconds)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        try? handle.close()
    }
}
