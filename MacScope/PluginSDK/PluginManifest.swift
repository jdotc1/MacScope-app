import Foundation

enum PluginExecutionMode: Hashable, Codable {
    case xpc
    case external
    case inProcess

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "xpc":
            self = .xpc
        case "external":
            self = .external
        case "in-process", "in_process", "inProcess":
            self = .inProcess
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported plugin execution mode: \(value)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .xpc:
            try container.encode("xpc")
        case .external:
            try container.encode("external")
        case .inProcess:
            try container.encode("in-process")
        }
    }
}

enum PluginCapability: String, Hashable, Codable, CaseIterable {
    case workspaceRead = "workspace.read"
    case workspaceWrite = "workspace.write"
    case binaryImport = "binary.import"
    case analysisSymbols = "analysis.symbols"
    case analysisDecompiler = "analysis.decompiler"
    case debuggerRead = "debugger.read"
    case debuggerControl = "debugger.control"
    case uiCommand = "ui.command"
    /// Receive the host theme (`PluginThemeSnapshot`) to style the plugin's own UI. Read-only.
    case uiTheme = "ui.theme"
}

enum PluginCommandSurface: String, Hashable, Codable, CaseIterable {
    case ui
    case automation
    case externalAPI = "external-api"
    case cli
    case mcp

    var isAutomationFacade: Bool {
        self != .ui
    }

    var isStdioAutomationHelperSurface: Bool {
        switch self {
        case .cli, .mcp:
            return true
        case .ui, .automation, .externalAPI:
            return false
        }
    }
}

enum PluginServiceMode: String, Hashable, Codable, CaseIterable {
    case xpcService = "xpc-service"
    case stdioJSONRPC = "stdio-json-rpc"
    case helperExecutable = "helper-executable"
    case inProcess = "in-process"

    var isOutOfProcess: Bool {
        switch self {
        case .xpcService, .stdioJSONRPC, .helperExecutable:
            return true
        case .inProcess:
            return false
        }
    }

    static func inferred(for execution: PluginExecutionMode) -> PluginServiceMode {
        switch execution {
        case .xpc:
            return .xpcService
        case .external:
            return .stdioJSONRPC
        case .inProcess:
            return .inProcess
        }
    }

    func isCompatible(with execution: PluginExecutionMode) -> Bool {
        switch (execution, self) {
        case (.xpc, .xpcService),
             (.external, .stdioJSONRPC),
             (.external, .helperExecutable),
             (.inProcess, .inProcess):
            return true
        default:
            return false
        }
    }
}

struct PluginServiceMetadata: Hashable, Codable {
    var mode: PluginServiceMode
    var identifier: String?
    var protocolVersion: String
    var supportsConcurrentRequests: Bool

    init(
        mode: PluginServiceMode,
        identifier: String? = nil,
        protocolVersion: String = "1",
        supportsConcurrentRequests: Bool = false
    ) {
        self.mode = mode
        self.identifier = identifier
        self.protocolVersion = protocolVersion
        self.supportsConcurrentRequests = supportsConcurrentRequests
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case identifier
        case protocolVersion
        case supportsConcurrentRequests
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decode(PluginServiceMode.self, forKey: .mode),
            identifier: try container.decodeIfPresent(String.self, forKey: .identifier),
            protocolVersion: try container.decodeIfPresent(
                String.self,
                forKey: .protocolVersion
            ) ?? "1",
            supportsConcurrentRequests: try container.decodeIfPresent(
                Bool.self,
                forKey: .supportsConcurrentRequests
            ) ?? false
        )
    }
}

enum PluginCommandMutationPolicy: String, Hashable, Codable, CaseIterable {
    case readOnly = "read-only"
    case workspaceMutation = "workspace-mutation"
    case debuggerMutation = "debugger-mutation"
    case externalSideEffect = "external-side-effect"

    var isMutating: Bool {
        self != .readOnly
    }

    var requiredCapability: PluginCapability? {
        switch self {
        case .readOnly, .externalSideEffect:
            return nil
        case .workspaceMutation:
            return .workspaceWrite
        case .debuggerMutation:
            return .debuggerControl
        }
    }

    var requiresUndoPolicyDecision: Bool {
        switch self {
        case .readOnly, .externalSideEffect:
            return false
        case .workspaceMutation, .debuggerMutation:
            return true
        }
    }

    var requiresHostUndoRegistration: Bool {
        requiresUndoPolicyDecision
    }
}

enum PluginCommandUndoPolicy: String, Hashable, Codable, CaseIterable {
    case notApplicable = "not-applicable"
    case unsupported
    case supported
    case required
}

enum PluginAutomationHelperCancellationExpectation: String, Hashable, Codable, CaseIterable {
    case hostManagedTermination = "host-managed-termination"
    case cooperativeCancellation = "cooperative-cancellation"
    case unsupported
}

enum PluginAutomationHelperLoggingExpectation: String, Hashable, Codable, CaseIterable {
    case stderrText = "stderr-text"
    case stderrJSONLines = "stderr-json-lines"
    case structuredEvents = "structured-events"
}

struct PluginAutomationHelperDescriptor: Hashable, Codable {
    var identifier: String
    var displayName: String
    var serviceIdentifier: String?
    var serviceMode: PluginServiceMode
    var surfaces: [PluginCommandSurface]
    var capabilities: [PluginCapability]
    var mutationPolicies: [PluginCommandMutationPolicy]
    var mutatingSurfaces: [PluginCommandSurface]
    var undoPolicy: PluginCommandUndoPolicy
    var cancellation: PluginAutomationHelperCancellationExpectation
    var logging: PluginAutomationHelperLoggingExpectation

    init(
        identifier: String,
        displayName: String,
        serviceIdentifier: String? = nil,
        serviceMode: PluginServiceMode = .stdioJSONRPC,
        surfaces: [PluginCommandSurface] = [.cli, .mcp],
        capabilities: [PluginCapability] = [],
        mutationPolicies: [PluginCommandMutationPolicy] = [.readOnly],
        mutatingSurfaces: [PluginCommandSurface] = [],
        undoPolicy: PluginCommandUndoPolicy = .notApplicable,
        cancellation: PluginAutomationHelperCancellationExpectation = .hostManagedTermination,
        logging: PluginAutomationHelperLoggingExpectation = .stderrText
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.serviceIdentifier = serviceIdentifier
        self.serviceMode = serviceMode
        self.surfaces = surfaces
        self.capabilities = capabilities
        self.mutationPolicies = mutationPolicies
        self.mutatingSurfaces = mutatingSurfaces
        self.undoPolicy = undoPolicy
        self.cancellation = cancellation
        self.logging = logging
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case displayName
        case serviceIdentifier
        case serviceMode
        case surfaces
        case capabilities
        case mutationPolicies
        case mutatingSurfaces
        case undoPolicy
        case cancellation
        case logging
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            identifier: try container.decode(String.self, forKey: .identifier),
            displayName: try container.decode(String.self, forKey: .displayName),
            serviceIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .serviceIdentifier
            ),
            serviceMode: try container.decodeIfPresent(
                PluginServiceMode.self,
                forKey: .serviceMode
            ) ?? .stdioJSONRPC,
            surfaces: try container.decodeIfPresent(
                [PluginCommandSurface].self,
                forKey: .surfaces
            ) ?? [.cli, .mcp],
            capabilities: try container.decodeIfPresent(
                [PluginCapability].self,
                forKey: .capabilities
            ) ?? [],
            mutationPolicies: try container.decodeIfPresent(
                [PluginCommandMutationPolicy].self,
                forKey: .mutationPolicies
            ) ?? [.readOnly],
            mutatingSurfaces: try container.decodeIfPresent(
                [PluginCommandSurface].self,
                forKey: .mutatingSurfaces
            ) ?? [],
            undoPolicy: try container.decodeIfPresent(
                PluginCommandUndoPolicy.self,
                forKey: .undoPolicy
            ) ?? .notApplicable,
            cancellation: try container.decodeIfPresent(
                PluginAutomationHelperCancellationExpectation.self,
                forKey: .cancellation
            ) ?? .hostManagedTermination,
            logging: try container.decodeIfPresent(
                PluginAutomationHelperLoggingExpectation.self,
                forKey: .logging
            ) ?? .stderrText
        )
    }
}

struct PluginCommandDescriptor: Hashable, Codable {
    var identifier: String
    var displayName: String
    var capability: PluginCapability
    var surfaces: [PluginCommandSurface]
    var requiresNetwork: Bool
    var requiresProcessSpawn: Bool
    var filesystemScope: PluginFilesystemScope
    var mutationPolicy: PluginCommandMutationPolicy
    var undoPolicy: PluginCommandUndoPolicy
    var serviceMode: PluginServiceMode?

    init(
        identifier: String,
        displayName: String,
        capability: PluginCapability,
        surfaces: [PluginCommandSurface] = [.ui],
        requiresNetwork: Bool = false,
        requiresProcessSpawn: Bool = false,
        filesystemScope: PluginFilesystemScope = .none,
        mutationPolicy: PluginCommandMutationPolicy = .readOnly,
        undoPolicy: PluginCommandUndoPolicy = .notApplicable,
        serviceMode: PluginServiceMode? = nil
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.capability = capability
        self.surfaces = surfaces
        self.requiresNetwork = requiresNetwork
        self.requiresProcessSpawn = requiresProcessSpawn
        self.filesystemScope = filesystemScope
        self.mutationPolicy = mutationPolicy
        self.undoPolicy = undoPolicy
        self.serviceMode = serviceMode
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case displayName
        case capability
        case surfaces
        case requiresNetwork
        case requiresProcessSpawn
        case filesystemScope
        case mutationPolicy
        case undoPolicy
        case serviceMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            identifier: try container.decode(String.self, forKey: .identifier),
            displayName: try container.decode(String.self, forKey: .displayName),
            capability: try container.decode(PluginCapability.self, forKey: .capability),
            surfaces: try container.decodeIfPresent(
                [PluginCommandSurface].self,
                forKey: .surfaces
            ) ?? [.ui],
            requiresNetwork: try container.decodeIfPresent(
                Bool.self,
                forKey: .requiresNetwork
            ) ?? false,
            requiresProcessSpawn: try container.decodeIfPresent(
                Bool.self,
                forKey: .requiresProcessSpawn
            ) ?? false,
            filesystemScope: try container.decodeIfPresent(
                PluginFilesystemScope.self,
                forKey: .filesystemScope
            ) ?? .none,
            mutationPolicy: try container.decodeIfPresent(
                PluginCommandMutationPolicy.self,
                forKey: .mutationPolicy
            ) ?? .readOnly,
            undoPolicy: try container.decodeIfPresent(
                PluginCommandUndoPolicy.self,
                forKey: .undoPolicy
            ) ?? .notApplicable,
            serviceMode: try container.decodeIfPresent(
                PluginServiceMode.self,
                forKey: .serviceMode
            )
        )
    }
}

enum PluginFilesystemScope: String, Hashable, Codable {
    case none
    case userSelected = "user-selected"
    case workspace
}

enum PluginDistributionChannel: String, Hashable, Codable, CaseIterable {
    case bundled
    case developer
    case thirdParty = "third-party"
    case unknown
}

enum PluginSignatureState: String, Hashable, Codable, CaseIterable {
    case unsigned
    case adHoc = "ad-hoc"
    case signed
    case notarized
    case unknown
}

enum PluginLifecycleState: String, Hashable, Codable {
    case blocked
    case needsTrust = "needs-trust"
    case developmentOnly = "development-only"
    case reviewRequired = "review-required"
    case productionReady = "production-ready"
}

enum PluginLifecycleGate: String, Hashable, Codable {
    case deniedByTrustPolicy = "denied-by-trust-policy"
    case externalTrustRequired = "external-trust-required"
    case inProcessTrustRequired = "in-process-trust-required"
    case provenanceMissing = "provenance-missing"
    case productionSignatureRequired = "production-signature-required"
    case signingIdentityIncomplete = "signing-identity-incomplete"
    case developmentPlugin = "development-plugin"
    case networkAccessDisabledByPolicy = "network-access-disabled-by-policy"
    case processSpawnDisabledByPolicy = "process-spawn-disabled-by-policy"
}

struct PluginLifecycleStatus: Hashable, Codable {
    var state: PluginLifecycleState
    var launchBlockers: [PluginLifecycleGate]
    var productionBlockers: [PluginLifecycleGate]

    var isLaunchReady: Bool {
        launchBlockers.isEmpty
    }

    var isProductionReady: Bool {
        state == .productionReady
    }

    init(
        launchBlockers: [PluginLifecycleGate],
        productionBlockers: [PluginLifecycleGate]
    ) {
        self.launchBlockers = launchBlockers
        self.productionBlockers = productionBlockers
        self.state = Self.state(
            launchBlockers: launchBlockers,
            productionBlockers: productionBlockers
        )
    }

    private static func state(
        launchBlockers: [PluginLifecycleGate],
        productionBlockers: [PluginLifecycleGate]
    ) -> PluginLifecycleState {
        if launchBlockers.contains(.deniedByTrustPolicy) {
            return .blocked
        }

        if !launchBlockers.isEmpty {
            return .needsTrust
        }

        if productionBlockers.contains(.developmentPlugin) {
            return .developmentOnly
        }

        if !productionBlockers.isEmpty {
            return .reviewRequired
        }

        return .productionReady
    }
}

struct PluginProvenance: Hashable, Codable {
    var distribution: PluginDistributionChannel
    var signatureState: PluginSignatureState
    var teamIdentifier: String?
    var signingIdentifier: String?
    var source: String?

    static let unspecified = PluginProvenance(
        distribution: .unknown,
        signatureState: .unknown,
        teamIdentifier: nil,
        signingIdentifier: nil,
        source: nil
    )

    static let bundledUnsigned = PluginProvenance(
        distribution: .bundled,
        signatureState: .unsigned,
        teamIdentifier: nil,
        signingIdentifier: nil,
        source: "bundle"
    )

    var satisfiesProductionSigning: Bool {
        switch signatureState {
        case .signed, .notarized:
            return true
        case .unsigned, .adHoc, .unknown:
            return false
        }
    }

    var hasCompleteSigningIdentity: Bool {
        guard satisfiesProductionSigning else {
            return true
        }

        return teamIdentifier?.isEmpty == false
            && signingIdentifier?.isEmpty == false
    }
}

struct PluginPermissions: Hashable, Codable {
    var network: Bool
    var processSpawn: Bool
    var filesystemScope: PluginFilesystemScope

    static let restricted = PluginPermissions(
        network: false,
        processSpawn: false,
        filesystemScope: .userSelected
    )
}

struct PluginManifest: Identifiable, Hashable, Codable {
    var id: String { identifier }

    var identifier: String
    var displayName: String
    var version: String
    var sdkVersion: String
    var minHostVersion: String
    var execution: PluginExecutionMode
    var entryPoint: String?
    var principalClass: String?
    var architectures: [String]
    var capabilities: [PluginCapability]
    var permissions: PluginPermissions
    var provenance: PluginProvenance
    var commands: [PluginCommandDescriptor]
    var service: PluginServiceMetadata?
    var automationHelpers: [PluginAutomationHelperDescriptor]

    enum CodingKeys: String, CodingKey {
        case identifier
        case displayName
        case version
        case sdkVersion
        case minHostVersion
        case execution
        case entryPoint
        case principalClass
        case architectures
        case capabilities
        case permissions
        case provenance
        case commands
        case service
        case automationHelpers
    }

    init(
        identifier: String,
        displayName: String,
        version: String,
        sdkVersion: String,
        minHostVersion: String,
        execution: PluginExecutionMode,
        entryPoint: String?,
        principalClass: String?,
        architectures: [String],
        capabilities: [PluginCapability],
        permissions: PluginPermissions,
        provenance: PluginProvenance = .unspecified,
        commands: [PluginCommandDescriptor] = [],
        service: PluginServiceMetadata? = nil,
        automationHelpers: [PluginAutomationHelperDescriptor] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.version = version
        self.sdkVersion = sdkVersion
        self.minHostVersion = minHostVersion
        self.execution = execution
        self.entryPoint = entryPoint
        self.principalClass = principalClass
        self.architectures = architectures
        self.capabilities = capabilities
        self.permissions = permissions
        self.provenance = provenance
        self.commands = commands
        self.service = service
        self.automationHelpers = automationHelpers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            identifier: try container.decode(String.self, forKey: .identifier),
            displayName: try container.decode(String.self, forKey: .displayName),
            version: try container.decode(String.self, forKey: .version),
            sdkVersion: try container.decode(String.self, forKey: .sdkVersion),
            minHostVersion: try container.decode(String.self, forKey: .minHostVersion),
            execution: try container.decode(PluginExecutionMode.self, forKey: .execution),
            entryPoint: try container.decodeIfPresent(String.self, forKey: .entryPoint),
            principalClass: try container.decodeIfPresent(String.self, forKey: .principalClass),
            architectures: try container.decode([String].self, forKey: .architectures),
            capabilities: try container.decode([PluginCapability].self, forKey: .capabilities),
            permissions: try container.decode(PluginPermissions.self, forKey: .permissions),
            provenance: try container.decodeIfPresent(
                PluginProvenance.self,
                forKey: .provenance
            ) ?? .unspecified,
            commands: try container.decodeIfPresent(
                [PluginCommandDescriptor].self,
                forKey: .commands
            ) ?? [],
            service: try container.decodeIfPresent(
                PluginServiceMetadata.self,
                forKey: .service
            ),
            automationHelpers: try container.decodeIfPresent(
                [PluginAutomationHelperDescriptor].self,
                forKey: .automationHelpers
            ) ?? []
        )
    }
}
