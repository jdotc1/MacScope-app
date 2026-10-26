import XCTest
@testable import MacScope

final class PluginRegistryTests: XCTestCase {
    func testManifestDecodesCapabilitiesAndExecutionPolicy() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: sampleManifestData())

        XCTAssertEqual(manifest.identifier, "org.macscope.app.plugins.sample")
        XCTAssertEqual(manifest.execution, .xpc)
        XCTAssertEqual(manifest.architectures, ["arm64"])
        XCTAssertEqual(manifest.capabilities, [.workspaceRead, .binaryImport, .analysisSymbols])
        XCTAssertEqual(manifest.permissions.filesystemScope, .userSelected)
        XCTAssertEqual(manifest.provenance, .bundledUnsigned)
        XCTAssertEqual(manifest.commands, [])
        XCTAssertEqual(manifest.automationHelpers, [])
        XCTAssertNil(manifest.service)
    }

    func testManifestDecodesMissingProvenanceAsUnspecifiedForCompatibility() throws {
        let data = Data(
            """
            {
              "identifier": "org.macscope.app.plugins.legacy",
              "displayName": "Legacy Importer",
              "version": "0.1.0",
              "sdkVersion": "0.1",
              "minHostVersion": "0.1.0",
              "execution": "external",
              "entryPoint": "/bin/cat",
              "architectures": ["arm64"],
              "capabilities": ["workspace.read"],
              "permissions": {
                "network": false,
                "processSpawn": false,
                "filesystemScope": "user-selected"
              }
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.identifier, "org.macscope.app.plugins.legacy")
        XCTAssertEqual(manifest.provenance, .unspecified)
        XCTAssertEqual(manifest.commands, [])
        XCTAssertEqual(manifest.automationHelpers, [])
        XCTAssertNil(manifest.service)
    }

    func testManifestDecodesCommandDescriptorsAndServiceMetadata() throws {
        let data = Data(
            """
            {
              "identifier": "org.macscope.app.plugins.automation",
              "displayName": "Automation Importer",
              "version": "0.1.0",
              "sdkVersion": "0.1",
              "minHostVersion": "0.1.0",
              "execution": "xpc",
              "entryPoint": "AutomationImporterService",
              "principalClass": "AutomationImporterPlugin",
              "architectures": ["arm64"],
              "capabilities": [
                "workspace.read",
                "workspace.write",
                "analysis.symbols",
                "ui.command"
              ],
              "permissions": {
                "network": true,
                "processSpawn": false,
                "filesystemScope": "workspace"
              },
              "provenance": {
                "distribution": "bundled",
                "signatureState": "unsigned",
                "source": "bundle"
              },
              "service": {
                "mode": "xpc-service",
                "identifier": "org.macscope.app.plugins.automation.service",
                "protocolVersion": "1",
                "supportsConcurrentRequests": true
              },
              "commands": [
                {
                  "identifier": "workspace.annotateSymbol",
                  "displayName": "Annotate Symbol",
                  "capability": "workspace.write",
                  "surfaces": ["ui", "automation", "mcp", "external-api"],
                  "requiresNetwork": true,
                  "requiresProcessSpawn": false,
                  "filesystemScope": "workspace",
                  "mutationPolicy": "workspace-mutation",
                  "undoPolicy": "required",
                  "serviceMode": "xpc-service"
                },
                {
                  "identifier": "symbols.describe",
                  "displayName": "Describe Symbol",
                  "capability": "analysis.symbols"
                }
              ]
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.execution, .xpc)
        XCTAssertEqual(manifest.service?.mode, .xpcService)
        XCTAssertEqual(
            manifest.service?.identifier,
            "org.macscope.app.plugins.automation.service"
        )
        XCTAssertEqual(manifest.service?.protocolVersion, "1")
        XCTAssertEqual(manifest.service?.supportsConcurrentRequests, true)
        XCTAssertEqual(manifest.commands.count, 2)

        let mutatingCommand = try XCTUnwrap(manifest.commands.first)
        XCTAssertEqual(mutatingCommand.identifier, "workspace.annotateSymbol")
        XCTAssertEqual(mutatingCommand.displayName, "Annotate Symbol")
        XCTAssertEqual(mutatingCommand.capability, .workspaceWrite)
        XCTAssertEqual(mutatingCommand.surfaces, [.ui, .automation, .mcp, .externalAPI])
        XCTAssertEqual(mutatingCommand.requiresNetwork, true)
        XCTAssertEqual(mutatingCommand.requiresProcessSpawn, false)
        XCTAssertEqual(mutatingCommand.filesystemScope, .workspace)
        XCTAssertEqual(mutatingCommand.mutationPolicy, .workspaceMutation)
        XCTAssertEqual(mutatingCommand.undoPolicy, .required)
        XCTAssertEqual(mutatingCommand.serviceMode, .xpcService)

        let readOnlyCommand = try XCTUnwrap(manifest.commands.last)
        XCTAssertEqual(readOnlyCommand.identifier, "symbols.describe")
        XCTAssertEqual(readOnlyCommand.surfaces, [.ui])
        XCTAssertEqual(readOnlyCommand.filesystemScope, .none)
        XCTAssertEqual(readOnlyCommand.mutationPolicy, .readOnly)
        XCTAssertEqual(readOnlyCommand.undoPolicy, .notApplicable)
    }

    func testManifestDecodesOwnedStdioAutomationHelperDescriptor() throws {
        let data = Data(
            """
            {
              "identifier": "org.macscope.app.plugins.helper",
              "displayName": "Helper Importer",
              "version": "0.1.0",
              "sdkVersion": "0.1",
              "minHostVersion": "0.1.0",
              "execution": "external",
              "entryPoint": "/tmp/not-launched-helper",
              "architectures": ["arm64"],
              "capabilities": [
                "workspace.read",
                "workspace.write",
                "analysis.symbols"
              ],
              "permissions": {
                "network": false,
                "processSpawn": false,
                "filesystemScope": "workspace"
              },
              "provenance": {
                "distribution": "bundled",
                "signatureState": "unsigned",
                "source": "bundle"
              },
              "automationHelpers": [
                {
                  "identifier": "sample.stdio",
                  "displayName": "Sample Stdio Helper",
                  "serviceIdentifier": "org.macscope.app.plugins.helper.stdio",
                  "serviceMode": "stdio-json-rpc",
                  "surfaces": ["cli", "mcp"],
                  "capabilities": ["analysis.symbols", "workspace.write"],
                  "mutationPolicies": ["read-only", "workspace-mutation"],
                  "mutatingSurfaces": ["mcp"],
                  "undoPolicy": "required",
                  "cancellation": "cooperative-cancellation",
                  "logging": "stderr-json-lines"
                }
              ]
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        let helper = try XCTUnwrap(manifest.automationHelpers.first)

        XCTAssertEqual(helper.identifier, "sample.stdio")
        XCTAssertEqual(helper.displayName, "Sample Stdio Helper")
        XCTAssertEqual(
            helper.serviceIdentifier,
            "org.macscope.app.plugins.helper.stdio"
        )
        XCTAssertEqual(helper.serviceMode, .stdioJSONRPC)
        XCTAssertEqual(helper.surfaces, [.cli, .mcp])
        XCTAssertEqual(helper.capabilities, [.analysisSymbols, .workspaceWrite])
        XCTAssertEqual(helper.mutationPolicies, [.readOnly, .workspaceMutation])
        XCTAssertEqual(helper.mutatingSurfaces, [.mcp])
        XCTAssertEqual(helper.undoPolicy, .required)
        XCTAssertEqual(helper.cancellation, .cooperativeCancellation)
        XCTAssertEqual(helper.logging, .stderrJSONLines)
    }

    func testRegistryRejectsMajorSDKMismatch() throws {
        var manifest = sampleManifest()
        manifest.sdkVersion = "2.0"

        XCTAssertThrowsError(
            try PluginRegistry(hostSDKVersion: "1.0").validate(
                manifest,
                trustDecision: .unknown
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .sdkMajorMismatch(plugin: "2.0", host: "1.0")
            )
        }
    }

    func testRegistryRequiresExplicitTrustForInProcessPlugins() throws {
        var manifest = sampleManifest()
        manifest.execution = .inProcess

        XCTAssertThrowsError(
            try PluginRegistry().validate(manifest, trustDecision: .unknown)
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .inProcessRequiresExplicitTrust("org.macscope.app.plugins.sample")
            )
        }

        let descriptor = try PluginRegistry().validate(
            manifest,
            trustDecision: .allowInProcess
        )
        XCTAssertEqual(descriptor.trustDecision, .allowInProcess)
    }

    func testRegistryRejectsUnsignedThirdPartyPluginWhenSigningPolicyRequiresIt() throws {
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/bin/cat"
        manifest.principalClass = nil
        manifest.provenance = PluginProvenance(
            distribution: .thirdParty,
            signatureState: .unsigned,
            teamIdentifier: nil,
            signingIdentifier: nil,
            source: "download"
        )

        XCTAssertThrowsError(
            try PluginRegistry().validate(manifest, trustDecision: .allowExternal)
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .unsignedPluginRequiresSignature(
                    identifier: "org.macscope.app.plugins.sample",
                    distribution: .thirdParty,
                    signatureState: .unsigned
                )
            )
        }
    }

    func testRegistryRejectsProductionSignedPluginWithoutCompleteSigningIdentity() throws {
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/bin/cat"
        manifest.principalClass = nil
        manifest.provenance = PluginProvenance(
            distribution: .thirdParty,
            signatureState: .signed,
            teamIdentifier: nil,
            signingIdentifier: "Developer ID Application: Example",
            source: "download"
        )

        XCTAssertThrowsError(
            try PluginRegistry().validate(manifest, trustDecision: .allowExternal)
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .signingIdentityIncomplete(
                    identifier: "org.macscope.app.plugins.sample",
                    distribution: .thirdParty,
                    signatureState: .signed
                )
            )
        }

        let relaxedPolicy = PluginProvenancePolicy(
            allowBundledUnsigned: true,
            allowDevelopmentUnsigned: false,
            requireSignedThirdParty: true,
            requireSigningIdentityForSignedPlugins: false
        )
        let descriptor = try PluginRegistry(provenancePolicy: relaxedPolicy)
            .validate(manifest, trustDecision: .allowExternal)

        XCTAssertEqual(descriptor.manifest.provenance.signatureState, .signed)
        XCTAssertEqual(descriptor.trustDecision, .allowExternal)
    }

    func testRegistryAllowsUnsignedDevelopmentPluginOnlyWhenSettingsPolicyAllowsIt() throws {
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/bin/cat"
        manifest.principalClass = nil
        manifest.provenance = PluginProvenance(
            distribution: .developer,
            signatureState: .adHoc,
            teamIdentifier: nil,
            signingIdentifier: nil,
            source: "local-build"
        )

        XCTAssertThrowsError(
            try PluginRegistry().validate(manifest, trustDecision: .allowExternal)
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .developmentPluginRequiresSettings("org.macscope.app.plugins.sample")
            )
        }

        let developmentPolicy = PluginRuntimePolicy(
            allowDevelopmentPlugins: true,
            requireSignedPlugins: true,
            allowNetworkAccess: false,
            allowProcessSpawn: false
        )
        let descriptor = try PluginRegistry(
            provenancePolicy: PluginProvenancePolicy(runtimePolicy: developmentPolicy)
        )
        .validate(manifest, trustDecision: .allowExternal)

        XCTAssertEqual(descriptor.manifest.provenance.distribution, .developer)
        XCTAssertEqual(descriptor.manifest.provenance.signatureState, .adHoc)
    }

    func testRegistryValidatesCommandPlanningMetadataAgainstManifestEnvelope() throws {
        var capabilityEscalation = sampleManifest()
        capabilityEscalation.commands = [
            PluginCommandDescriptor(
                identifier: "debugger.resume",
                displayName: "Resume Process",
                capability: .debuggerControl,
                surfaces: [.automation],
                mutationPolicy: .debuggerMutation,
                undoPolicy: .unsupported
            )
        ]

        XCTAssertThrowsError(
            try PluginRegistry().validate(capabilityEscalation, trustDecision: .unknown)
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .commandCapabilityNotDeclared(
                    identifier: "org.macscope.app.plugins.sample",
                    command: "debugger.resume",
                    capability: .debuggerControl
                )
            )
        }

        var permissionEscalation = sampleManifest()
        permissionEscalation.commands = [
            PluginCommandDescriptor(
                identifier: "symbols.remoteResolve",
                displayName: "Remote Resolve",
                capability: .analysisSymbols,
                surfaces: [.automation, .cli],
                requiresNetwork: true
            )
        ]

        XCTAssertThrowsError(
            try PluginRegistry().validate(permissionEscalation, trustDecision: .unknown)
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .commandPermissionExceedsManifest(
                    identifier: "org.macscope.app.plugins.sample",
                    command: "symbols.remoteResolve",
                    requirement: "network access"
                )
            )
        }

        var missingUndoPolicy = sampleManifest()
        missingUndoPolicy.capabilities.append(.workspaceWrite)
        missingUndoPolicy.permissions = PluginPermissions(
            network: false,
            processSpawn: false,
            filesystemScope: .workspace
        )
        missingUndoPolicy.commands = [
            PluginCommandDescriptor(
                identifier: "workspace.applyComment",
                displayName: "Apply Comment",
                capability: .workspaceWrite,
                filesystemScope: .workspace,
                mutationPolicy: .workspaceMutation
            )
        ]

        XCTAssertThrowsError(
            try PluginRegistry().validate(missingUndoPolicy, trustDecision: .unknown)
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .commandMutationRequiresUndoPolicy(
                    identifier: "org.macscope.app.plugins.sample",
                    command: "workspace.applyComment",
                    mutationPolicy: .workspaceMutation
                )
            )
        }

        var serviceMismatch = sampleManifest()
        serviceMismatch.service = PluginServiceMetadata(mode: .stdioJSONRPC)

        XCTAssertThrowsError(
            try PluginRegistry().validate(serviceMismatch, trustDecision: .unknown)
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .serviceModeMismatch(
                    identifier: "org.macscope.app.plugins.sample",
                    execution: .xpc,
                    serviceMode: .stdioJSONRPC
                )
            )
        }
    }

    func testRegistryPlansOwnedStdioHelperMetadataWithoutLaunch() throws {
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/tmp/not-launched-helper"
        manifest.principalClass = nil
        manifest.capabilities.append(.workspaceWrite)
        manifest.permissions = PluginPermissions(
            network: false,
            processSpawn: false,
            filesystemScope: .workspace
        )
        manifest.automationHelpers = [
            PluginAutomationHelperDescriptor(
                identifier: "sample.stdio",
                displayName: "Sample Stdio Helper",
                serviceIdentifier: "org.macscope.app.plugins.sample.stdio",
                surfaces: [.cli, .mcp],
                capabilities: [.analysisSymbols, .workspaceWrite],
                mutationPolicies: [.readOnly, .workspaceMutation],
                mutatingSurfaces: [.mcp],
                undoPolicy: .required,
                cancellation: .cooperativeCancellation,
                logging: .stderrJSONLines
            )
        ]
        manifest.commands = [
            PluginCommandDescriptor(
                identifier: "workspace.applyTags",
                displayName: "Apply Tags",
                capability: .workspaceWrite,
                surfaces: [.mcp],
                filesystemScope: .workspace,
                mutationPolicy: .workspaceMutation,
                undoPolicy: .required
            )
        ]

        let descriptor = try PluginRegistry().validate(
            manifest,
            trustDecision: .allowExternal,
            manifestHash: "helper-plan-hash"
        )
        let planner = PluginAutomationFacadePlanner(policy: .settingsDefault)
        let plan = try planner.planCommand(
            descriptor,
            commandIdentifier: "workspace.applyTags",
            surface: .mcp
        )

        let helper = try XCTUnwrap(plan.automationHelper)
        XCTAssertEqual(helper.identifier, "sample.stdio")
        XCTAssertEqual(helper.serviceMode, .stdioJSONRPC)
        XCTAssertEqual(helper.cancellation, .cooperativeCancellation)
        XCTAssertEqual(helper.logging, .stderrJSONLines)
        XCTAssertEqual(plan.serviceMode, .stdioJSONRPC)
        XCTAssertEqual(
            plan.serviceIdentifier,
            "org.macscope.app.plugins.sample.stdio"
        )
        XCTAssertEqual(plan.mutationPolicy, .workspaceMutation)
        XCTAssertEqual(plan.undoPolicy, .required)
        XCTAssertTrue(plan.requiresUndoRegistration)

        let envelope = try planner.invocationEnvelope(
            for: descriptor,
            commandIdentifier: "workspace.applyTags",
            surface: .mcp,
            arguments: ["tag": "entry"],
            requestID: UUID(uuidString: "56565656-7878-9090-aaaa-bbbbbbbbbbbb")!
        )
        let lifecyclePlan = try planner.hostLifecyclePlan(for: envelope)

        XCTAssertEqual(lifecyclePlan.automationHelper?.identifier, "sample.stdio")
        XCTAssertEqual(
            lifecyclePlan.automationHelper?.cancellation,
            .cooperativeCancellation
        )
        XCTAssertEqual(lifecyclePlan.automationHelper?.logging, .stderrJSONLines)
        XCTAssertEqual(lifecyclePlan.hostKind, .externalStdio)
        XCTAssertEqual(lifecyclePlan.lifecycleStages, [
            .validateEnvelope,
            .authorizeRuntime,
            .spawnExternalHost,
            .dispatchInvocation,
            .awaitReply,
            .recordAudit,
            .terminateHost
        ])
    }

    func testRegistryRejectsHelperCapabilityEscalation() throws {
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/tmp/not-launched-helper"
        manifest.principalClass = nil
        manifest.automationHelpers = [
            PluginAutomationHelperDescriptor(
                identifier: "sample.stdio",
                displayName: "Sample Stdio Helper",
                capabilities: [.workspaceWrite]
            )
        ]

        XCTAssertThrowsError(
            try PluginRegistry().validate(manifest, trustDecision: .allowExternal)
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .automationHelperCapabilityNotDeclared(
                    identifier: "org.macscope.app.plugins.sample",
                    helper: "sample.stdio",
                    capability: .workspaceWrite
                )
            )
        }
    }

    func testRegistryRejectsHelperMutationClassificationMismatch() throws {
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/tmp/not-launched-helper"
        manifest.principalClass = nil
        manifest.capabilities.append(.workspaceWrite)
        manifest.permissions = PluginPermissions(
            network: false,
            processSpawn: false,
            filesystemScope: .workspace
        )
        manifest.automationHelpers = [
            PluginAutomationHelperDescriptor(
                identifier: "sample.stdio",
                displayName: "Sample Stdio Helper",
                surfaces: [.mcp],
                capabilities: [.workspaceWrite],
                mutationPolicies: [.readOnly],
                mutatingSurfaces: [.mcp],
                undoPolicy: .required
            )
        ]
        manifest.commands = [
            PluginCommandDescriptor(
                identifier: "workspace.applyTags",
                displayName: "Apply Tags",
                capability: .workspaceWrite,
                surfaces: [.mcp],
                filesystemScope: .workspace,
                mutationPolicy: .workspaceMutation,
                undoPolicy: .required
            )
        ]

        XCTAssertThrowsError(
            try PluginRegistry().validate(manifest, trustDecision: .allowExternal)
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .automationHelperMutationPolicyNotDeclared(
                    identifier: "org.macscope.app.plugins.sample",
                    helper: "sample.stdio",
                    command: "workspace.applyTags",
                    mutationPolicy: .workspaceMutation
                )
            )
        }
    }

    func testRegistryRejectsUndeclaredHelperMutatingSurface() throws {
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/tmp/not-launched-helper"
        manifest.principalClass = nil
        manifest.capabilities.append(.workspaceWrite)
        manifest.permissions = PluginPermissions(
            network: false,
            processSpawn: false,
            filesystemScope: .workspace
        )
        manifest.automationHelpers = [
            PluginAutomationHelperDescriptor(
                identifier: "sample.stdio",
                displayName: "Sample Stdio Helper",
                surfaces: [.mcp],
                capabilities: [.workspaceWrite],
                mutationPolicies: [.readOnly, .workspaceMutation],
                mutatingSurfaces: [],
                undoPolicy: .required
            )
        ]
        manifest.commands = [
            PluginCommandDescriptor(
                identifier: "workspace.applyTags",
                displayName: "Apply Tags",
                capability: .workspaceWrite,
                surfaces: [.mcp],
                filesystemScope: .workspace,
                mutationPolicy: .workspaceMutation,
                undoPolicy: .required
            )
        ]

        XCTAssertThrowsError(
            try PluginRegistry().validate(manifest, trustDecision: .allowExternal)
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .automationHelperMutatingSurfaceNotDeclared(
                    identifier: "org.macscope.app.plugins.sample",
                    helper: "sample.stdio",
                    command: "workspace.applyTags",
                    surface: .mcp,
                    mutationPolicy: .workspaceMutation
                )
            )
        }
    }

    func testRegistryRejectsInsufficientHelperUndoPolicy() throws {
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/tmp/not-launched-helper"
        manifest.principalClass = nil
        manifest.capabilities.append(.workspaceWrite)
        manifest.permissions = PluginPermissions(
            network: false,
            processSpawn: false,
            filesystemScope: .workspace
        )
        manifest.automationHelpers = [
            PluginAutomationHelperDescriptor(
                identifier: "sample.stdio",
                displayName: "Sample Stdio Helper",
                surfaces: [.mcp],
                capabilities: [.workspaceWrite],
                mutationPolicies: [.readOnly, .workspaceMutation],
                mutatingSurfaces: [.mcp],
                undoPolicy: .supported
            )
        ]
        manifest.commands = [
            PluginCommandDescriptor(
                identifier: "workspace.applyTags",
                displayName: "Apply Tags",
                capability: .workspaceWrite,
                surfaces: [.mcp],
                filesystemScope: .workspace,
                mutationPolicy: .workspaceMutation,
                undoPolicy: .required
            )
        ]

        XCTAssertThrowsError(
            try PluginRegistry().validate(manifest, trustDecision: .allowExternal)
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .automationHelperUndoPolicyInsufficient(
                    identifier: "org.macscope.app.plugins.sample",
                    helper: "sample.stdio",
                    command: "workspace.applyTags",
                    commandUndoPolicy: .required,
                    helperUndoPolicy: .supported
                )
            )
        }
    }

    func testRegistryDiscoversManifestJSONAndRejectsDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try sampleManifestData().write(to: directory.appendingPathComponent("a.json"))
        try sampleManifestData().write(to: directory.appendingPathComponent("b.json"))

        XCTAssertThrowsError(try PluginRegistry().discoverManifests(in: directory)) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .duplicateIdentifier("org.macscope.app.plugins.sample")
            )
        }
    }

    func testRegistryAppliesPersistedDenyDuringDiscovery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = sampleManifest()
        try manifestData(manifest).write(to: directory.appendingPathComponent("sample.json"))

        XCTAssertThrowsError(
            try PluginRegistry().discoverManifests(
                in: directory,
                trustDecisions: [manifest.identifier: .deny]
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .deniedByTrustPolicy("org.macscope.app.plugins.sample")
            )
        }
    }

    func testRegistryDiscoversInProcessManifestWithPersistedTrustAndHash() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var manifest = sampleManifest()
        manifest.execution = .inProcess
        try manifestData(manifest).write(to: directory.appendingPathComponent("sample.json"))

        XCTAssertThrowsError(try PluginRegistry().discoverManifests(in: directory)) { error in
            XCTAssertEqual(
                error as? PluginRegistryError,
                .inProcessRequiresExplicitTrust("org.macscope.app.plugins.sample")
            )
        }

        let descriptors = try PluginRegistry().discoverManifests(
            in: directory,
            trustDecisions: [manifest.identifier: .allowInProcess]
        )

        let descriptor = try XCTUnwrap(descriptors.first)
        XCTAssertEqual(descriptor.trustDecision, .allowInProcess)
        XCTAssertEqual(descriptor.manifest.execution, .inProcess)
        XCTAssertEqual(try XCTUnwrap(descriptor.manifestHash).count, 64)
    }

    func testRegistryDiagnosesDiscoveryIssuesWithoutAborting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let validManifest = sampleManifest()
        try manifestData(validManifest).write(to: directory.appendingPathComponent("a-valid.json"))
        try manifestData(validManifest).write(to: directory.appendingPathComponent("b-duplicate.json"))

        var deniedManifest = sampleManifest()
        deniedManifest.identifier = "org.macscope.app.plugins.denied"
        deniedManifest.displayName = "Denied Importer"
        try manifestData(deniedManifest).write(to: directory.appendingPathComponent("c-denied.json"))

        try Data(#"{"identifier":"broken""#.utf8)
            .write(to: directory.appendingPathComponent("d-malformed.json"))

        let report = try PluginRegistry().diagnoseManifests(
            in: directory,
            trustDecisions: [deniedManifest.identifier: .deny]
        )

        XCTAssertEqual(report.descriptors.map(\.manifest.identifier), [validManifest.identifier])
        XCTAssertTrue(report.hasErrors)
        XCTAssertEqual(report.warnings, [])
        XCTAssertEqual(
            Set(report.errors.map(\.code)),
            Set([
                .duplicateIdentifier,
                .deniedByTrustPolicy,
                .malformedManifest
            ])
        )

        let duplicate = try XCTUnwrap(
            report.errors.first { $0.code == .duplicateIdentifier }
        )
        XCTAssertEqual(duplicate.manifestIdentifier, validManifest.identifier)
        XCTAssertEqual(try XCTUnwrap(duplicate.manifestHash).count, 64)

        let denied = try XCTUnwrap(
            report.errors.first { $0.code == .deniedByTrustPolicy }
        )
        XCTAssertEqual(denied.manifestIdentifier, deniedManifest.identifier)
        XCTAssertTrue(denied.message.contains(deniedManifest.identifier))
    }

    func testRegistryDiscoveryDiagnosticsWarnForUntrustedExternalPlugins() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/bin/cat"
        manifest.principalClass = nil
        try manifestData(manifest).write(to: directory.appendingPathComponent("external.json"))

        let report = try PluginRegistry().diagnoseManifests(in: directory)

        let descriptor = try XCTUnwrap(report.descriptors.first)
        XCTAssertEqual(descriptor.manifest.identifier, manifest.identifier)
        XCTAssertEqual(descriptor.trustDecision, .unknown)
        XCTAssertEqual(descriptor.lifecycleStatus.state, .needsTrust)
        XCTAssertEqual(descriptor.lifecycleStatus.launchBlockers, [.externalTrustRequired])
        XCTAssertEqual(descriptor.lifecycleStatus.productionBlockers, [])
        XCTAssertFalse(descriptor.lifecycleStatus.isLaunchReady)
        XCTAssertFalse(descriptor.lifecycleStatus.isProductionReady)
        XCTAssertEqual(report.launchReadyDescriptors, [])
        XCTAssertEqual(report.productionReadyDescriptors, [])
        XCTAssertFalse(report.hasErrors)
        XCTAssertEqual(report.warnings.map(\.code), [.externalTrustRequired])
        XCTAssertEqual(report.warnings.first?.manifestIdentifier, manifest.identifier)

        let trustedReport = try PluginRegistry().diagnoseManifests(
            in: directory,
            trustDecisions: [manifest.identifier: .allowExternal]
        )

        XCTAssertEqual(trustedReport.descriptors.first?.trustDecision, .allowExternal)
        XCTAssertEqual(trustedReport.descriptors.first?.lifecycleStatus.state, .productionReady)
        XCTAssertEqual(trustedReport.launchReadyDescriptors.map(\.manifest.identifier), [manifest.identifier])
        XCTAssertEqual(trustedReport.productionReadyDescriptors.map(\.manifest.identifier), [manifest.identifier])
        XCTAssertEqual(trustedReport.diagnostics, [])
    }

    func testRegistryDiscoveryDiagnosticsWarnForMissingProvenanceAndRejectsIncompleteSignature() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyData = Data(
            """
            {
              "identifier": "org.macscope.app.plugins.legacy",
              "displayName": "Legacy Importer",
              "version": "0.1.0",
              "sdkVersion": "0.1",
              "minHostVersion": "0.1.0",
              "execution": "external",
              "entryPoint": "/bin/cat",
              "architectures": ["arm64"],
              "capabilities": ["workspace.read"],
              "permissions": {
                "network": false,
                "processSpawn": false,
                "filesystemScope": "user-selected"
              }
            }
            """.utf8
        )
        try legacyData.write(to: directory.appendingPathComponent("legacy.json"))

        var signedManifest = sampleManifest()
        signedManifest.identifier = "org.macscope.app.plugins.signed"
        signedManifest.displayName = "Signed Importer"
        signedManifest.execution = .external
        signedManifest.entryPoint = "/bin/cat"
        signedManifest.principalClass = nil
        signedManifest.provenance = PluginProvenance(
            distribution: .thirdParty,
            signatureState: .signed,
            teamIdentifier: nil,
            signingIdentifier: "Developer ID Application: Example",
            source: "download"
        )
        try manifestData(signedManifest).write(to: directory.appendingPathComponent("signed.json"))

        let report = try PluginRegistry().diagnoseManifests(
            in: directory,
            trustDecisions: [
                "org.macscope.app.plugins.legacy": .allowExternal,
                signedManifest.identifier: .allowExternal
            ]
        )

        XCTAssertEqual(
            report.descriptors.map(\.manifest.identifier),
            [
                "org.macscope.app.plugins.legacy"
            ]
        )
        XCTAssertTrue(report.hasErrors)
        XCTAssertEqual(
            report.warnings.map(\.code),
            [.provenanceMissing]
        )
        XCTAssertEqual(report.warnings.first?.manifestIdentifier, "org.macscope.app.plugins.legacy")
        XCTAssertEqual(
            report.errors.map(\.code),
            [.signingIdentityIncomplete]
        )

        let signingIdentityError = try XCTUnwrap(
            report.errors.first { $0.code == .signingIdentityIncomplete }
        )
        XCTAssertEqual(signingIdentityError.manifestIdentifier, signedManifest.identifier)
        XCTAssertTrue(
            signingIdentityError.message.contains("omits team or signing identifier")
        )
    }

    func testRegistryDiscoveryDiagnosticsWarnForRuntimePolicyRestrictions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/bin/cat"
        manifest.principalClass = nil
        manifest.permissions = PluginPermissions(
            network: true,
            processSpawn: true,
            filesystemScope: .userSelected
        )
        try manifestData(manifest).write(to: directory.appendingPathComponent("network-tool.json"))

        let report = try PluginRegistry().diagnoseManifests(
            in: directory,
            trustDecisions: [manifest.identifier: .allowExternal]
        )

        XCTAssertEqual(report.descriptors.map(\.manifest.identifier), [manifest.identifier])
        XCTAssertFalse(report.hasErrors)
        let descriptor = try XCTUnwrap(report.descriptors.first)
        XCTAssertEqual(descriptor.lifecycleStatus.state, .reviewRequired)
        XCTAssertEqual(descriptor.lifecycleStatus.launchBlockers, [])
        XCTAssertEqual(
            descriptor.lifecycleStatus.productionBlockers,
            [.networkAccessDisabledByPolicy, .processSpawnDisabledByPolicy]
        )
        XCTAssertTrue(descriptor.lifecycleStatus.isLaunchReady)
        XCTAssertFalse(descriptor.lifecycleStatus.isProductionReady)
        XCTAssertEqual(report.launchReadyDescriptors.map(\.manifest.identifier), [manifest.identifier])
        XCTAssertEqual(report.productionReadyDescriptors, [])
        XCTAssertEqual(
            report.warnings.map(\.code),
            [.networkAccessDisabledByPolicy, .processSpawnDisabledByPolicy]
        )
        XCTAssertEqual(report.warnings.map(\.manifestIdentifier), [manifest.identifier, manifest.identifier])
        XCTAssertTrue(report.warnings.first?.message.contains("Settings policy disables") ?? false)

        let permissivePolicy = PluginRuntimePolicy(
            allowDevelopmentPlugins: false,
            requireSignedPlugins: true,
            allowNetworkAccess: true,
            allowProcessSpawn: true
        )
        let permissiveReport = try PluginRegistry(runtimePolicy: permissivePolicy)
            .diagnoseManifests(
                in: directory,
                trustDecisions: [manifest.identifier: .allowExternal]
            )

        XCTAssertEqual(permissiveReport.descriptors.map(\.manifest.identifier), [manifest.identifier])
        XCTAssertEqual(permissiveReport.descriptors.first?.lifecycleStatus.state, .productionReady)
        XCTAssertEqual(permissiveReport.productionReadyDescriptors.map(\.manifest.identifier), [manifest.identifier])
        XCTAssertEqual(permissiveReport.diagnostics, [])
    }

    func testRegistryLifecycleStatusMarksUnsignedDevelopmentPluginAsDevelopmentOnly() throws {
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/bin/cat"
        manifest.principalClass = nil
        manifest.provenance = PluginProvenance(
            distribution: .developer,
            signatureState: .adHoc,
            teamIdentifier: nil,
            signingIdentifier: nil,
            source: "local-build"
        )

        let developmentPolicy = PluginRuntimePolicy(
            allowDevelopmentPlugins: true,
            requireSignedPlugins: true,
            allowNetworkAccess: false,
            allowProcessSpawn: false
        )
        let descriptor = try PluginRegistry(
            provenancePolicy: PluginProvenancePolicy(runtimePolicy: developmentPolicy)
        )
        .validate(manifest, trustDecision: .allowExternal)

        XCTAssertEqual(descriptor.lifecycleStatus.state, .developmentOnly)
        XCTAssertEqual(descriptor.lifecycleStatus.launchBlockers, [])
        XCTAssertEqual(descriptor.lifecycleStatus.productionBlockers, [.developmentPlugin])
        XCTAssertTrue(descriptor.lifecycleStatus.isLaunchReady)
        XCTAssertFalse(descriptor.lifecycleStatus.isProductionReady)
    }

    func testBundledSampleValidationBuildsDryRunPlanAndCapturesManifestHash() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = try writeSampleExternalPlugin(in: directory)
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = executableURL.path
        manifest.principalClass = nil
        manifest.provenance = .bundledUnsigned

        let manifestURL = directory.appendingPathComponent("sample.json")
        try manifestData(manifest).write(to: manifestURL)

        let result = PluginRegistry().validateBundledSample(manifestURL: manifestURL)

        XCTAssertTrue(result.isLaunchReady)
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertEqual(result.descriptor?.manifest.identifier, manifest.identifier)
        XCTAssertEqual(result.descriptor?.lifecycleStatus.state, .productionReady)
        XCTAssertTrue(result.descriptor?.lifecycleStatus.isProductionReady ?? false)
        XCTAssertEqual(result.executionPlan?.executableURL.path, executableURL.path)
        XCTAssertEqual(result.executionPlan?.pluginIdentifier, manifest.identifier)
        XCTAssertEqual(try XCTUnwrap(result.descriptor?.manifestHash).count, 64)
    }

    func testBundledSampleValidationRejectsNonBundledProvenance() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/bin/cat"
        manifest.principalClass = nil
        manifest.provenance = PluginProvenance(
            distribution: .thirdParty,
            signatureState: .signed,
            teamIdentifier: "ABCDE12345",
            signingIdentifier: "Developer ID Application: Example",
            source: "download"
        )

        let manifestURL = directory.appendingPathComponent("third-party.json")
        try manifestData(manifest).write(to: manifestURL)

        let result = PluginRegistry().validateBundledSample(manifestURL: manifestURL)

        XCTAssertFalse(result.isLaunchReady)
        XCTAssertNil(result.descriptor)
        XCTAssertNil(result.executionPlan)
        XCTAssertEqual(result.errors.map(\.code), [.invalidBundledSample])
        XCTAssertTrue(result.errors.first?.message.contains("requires bundled provenance") ?? false)
    }

    func testBundledSampleValidationRejectsExecutableOutsideManifestDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/bin/cat"
        manifest.principalClass = nil
        manifest.provenance = .bundledUnsigned

        let manifestURL = directory.appendingPathComponent("sample.json")
        try manifestData(manifest).write(to: manifestURL)

        let result = PluginRegistry().validateBundledSample(manifestURL: manifestURL)

        XCTAssertFalse(result.isLaunchReady)
        XCTAssertNotNil(result.descriptor)
        XCTAssertNil(result.executionPlan)
        XCTAssertEqual(result.errors.map(\.code), [.invalidBundledSample])
        XCTAssertTrue(
            result.errors.first?.message.contains("executable must be contained") ?? false
        )
    }

    func testBundledSampleValidationRejectsSymlinkEscapeFromManifestDirectory() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sampleDirectory = rootDirectory.appendingPathComponent("sample", isDirectory: true)
        let externalDirectory = rootDirectory.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sampleDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let escapedExecutableURL = try writeSampleExternalPlugin(in: externalDirectory)
        let symlinkURL = sampleDirectory.appendingPathComponent("sample-plugin-link.sh")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: escapedExecutableURL
        )

        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = symlinkURL.path
        manifest.principalClass = nil
        manifest.provenance = .bundledUnsigned

        let manifestURL = sampleDirectory.appendingPathComponent("sample.json")
        try manifestData(manifest).write(to: manifestURL)

        let result = PluginRegistry().validateBundledSample(manifestURL: manifestURL)

        XCTAssertFalse(result.isLaunchReady)
        XCTAssertNotNil(result.descriptor)
        XCTAssertNil(result.executionPlan)
        XCTAssertEqual(result.errors.map(\.code), [.invalidBundledSample])
        XCTAssertTrue(
            result.errors.first?.message.contains("executable must be contained") ?? false
        )
    }

    func testExternalHostDryRunRequiresExplicitExternalTrust() throws {
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/bin/cat"

        let descriptor = try PluginRegistry().validate(manifest, trustDecision: .unknown)
        let host = PluginExternalExecutionHost()

        XCTAssertThrowsError(try host.dryRun(descriptor)) { error in
            XCTAssertEqual(
                error as? PluginExternalExecutionError,
                .externalRequiresExplicitTrust("org.macscope.app.plugins.sample")
            )
        }
    }

    func testExternalHostRejectsInProcessManifestBeforeLaunch() throws {
        var manifest = sampleManifest()
        manifest.execution = .inProcess
        manifest.entryPoint = "/bin/cat"

        let descriptor = try PluginRegistry().validate(
            manifest,
            trustDecision: .allowInProcess
        )
        let host = PluginExternalExecutionHost()

        XCTAssertThrowsError(try host.dryRun(descriptor)) { error in
            XCTAssertEqual(
                error as? PluginExternalExecutionError,
                .unsupportedExecutionMode(
                    identifier: "org.macscope.app.plugins.sample",
                    mode: .inProcess
                )
            )
        }
    }

    func testExternalHostRejectsLifecycleDescriptorThatIsNotLaunchReady() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = try writeSampleExternalPlugin(in: directory)
        let descriptor = try externalDescriptor(executableURL: executableURL)
        let blockedDescriptor = PluginDescriptor(
            manifest: descriptor.manifest,
            manifestURL: descriptor.manifestURL,
            manifestHash: descriptor.manifestHash,
            trustDecision: .allowExternal,
            lifecycleStatus: PluginLifecycleStatus(
                launchBlockers: [.externalTrustRequired],
                productionBlockers: []
            )
        )
        let host = PluginExternalExecutionHost()

        XCTAssertThrowsError(try host.dryRun(blockedDescriptor)) { error in
            XCTAssertEqual(
                error as? PluginExternalExecutionError,
                .notLaunchReady(
                    identifier: "org.macscope.app.plugins.sample",
                    blockers: [.externalTrustRequired]
                )
            )
        }
    }

    func testRuntimeAuthorizerRejectsPermissionEscalation() throws {
        let descriptor = try PluginRegistry().validate(
            sampleManifest(),
            trustDecision: .unknown
        )
        let authorizer = PluginRuntimeAuthorizer(policy: .settingsDefault)

        XCTAssertThrowsError(
            try authorizer.authorize(
                descriptor,
                requirement: PluginRuntimeAuthorizationRequirement(
                    command: "symbols.describe",
                    capability: .analysisSymbols,
                    requiresNetwork: true
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginRuntimeAuthorizationError,
                .networkPermissionDenied(
                    identifier: "org.macscope.app.plugins.sample",
                    command: "symbols.describe"
                )
            )
        }

        XCTAssertThrowsError(
            try authorizer.authorize(
                descriptor,
                requirement: PluginRuntimeAuthorizationRequirement(
                    command: "workspace.writeIndex",
                    capability: .workspaceRead,
                    filesystemScope: .workspace
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginRuntimeAuthorizationError,
                .filesystemScopeDenied(
                    identifier: "org.macscope.app.plugins.sample",
                    command: "workspace.writeIndex",
                    required: .workspace,
                    granted: .userSelected
                )
            )
        }
    }

    func testCommandDescriptorBuildsRuntimeAuthorizationRequirement() throws {
        var manifest = sampleManifest()
        manifest.capabilities.append(.workspaceWrite)
        manifest.permissions = PluginPermissions(
            network: true,
            processSpawn: true,
            filesystemScope: .workspace
        )
        manifest.service = PluginServiceMetadata(
            mode: .xpcService,
            identifier: "org.macscope.app.plugins.sample.service",
            supportsConcurrentRequests: true
        )
        manifest.commands = [
            PluginCommandDescriptor(
                identifier: "workspace.applyTags",
                displayName: "Apply Tags",
                capability: .workspaceWrite,
                surfaces: [.automation, .mcp],
                requiresNetwork: true,
                requiresProcessSpawn: true,
                filesystemScope: .workspace,
                mutationPolicy: .workspaceMutation,
                undoPolicy: .required,
                serviceMode: .xpcService
            )
        ]
        let descriptor = try PluginRegistry().validate(manifest, trustDecision: .unknown)
        let command = try XCTUnwrap(descriptor.manifest.commands.first)

        XCTAssertEqual(
            command.authorizationRequirement,
            PluginRuntimeAuthorizationRequirement(
                command: "workspace.applyTags",
                capability: .workspaceWrite,
                requiresNetwork: true,
                requiresProcessSpawn: true,
                filesystemScope: .workspace
            )
        )

        let permissivePolicy = PluginRuntimePolicy(
            allowDevelopmentPlugins: false,
            requireSignedPlugins: true,
            allowNetworkAccess: true,
            allowProcessSpawn: true
        )
        XCTAssertNoThrow(
            try PluginRuntimeAuthorizer(policy: permissivePolicy).authorize(
                descriptor,
                requirement: command.authorizationRequirement
            )
        )
    }

    func testAutomationFacadePlannerBuildsXPCMCPPlanWithoutExecution() throws {
        var manifest = sampleManifest()
        manifest.capabilities.append(.workspaceWrite)
        manifest.permissions = PluginPermissions(
            network: false,
            processSpawn: false,
            filesystemScope: .workspace
        )
        manifest.service = PluginServiceMetadata(
            mode: .xpcService,
            identifier: "org.macscope.app.plugins.sample.service",
            supportsConcurrentRequests: true
        )
        manifest.commands = [
            PluginCommandDescriptor(
                identifier: "workspace.applyTags",
                displayName: "Apply Tags",
                capability: .workspaceWrite,
                surfaces: [.automation, .mcp],
                filesystemScope: .workspace,
                mutationPolicy: .workspaceMutation,
                undoPolicy: .required,
                serviceMode: .xpcService
            )
        ]

        let descriptor = try PluginRegistry().validate(
            manifest,
            trustDecision: .unknown,
            manifestHash: "xpc-plan-hash"
        )
        let planner = PluginAutomationFacadePlanner(policy: .settingsDefault)

        let plan = try planner.planCommand(
            descriptor,
            commandIdentifier: "workspace.applyTags",
            surface: .mcp
        )

        XCTAssertEqual(plan.pluginIdentifier, manifest.identifier)
        XCTAssertEqual(plan.pluginDisplayName, manifest.displayName)
        XCTAssertEqual(plan.commandIdentifier, "workspace.applyTags")
        XCTAssertEqual(plan.commandDisplayName, "Apply Tags")
        XCTAssertEqual(plan.surface, .mcp)
        XCTAssertEqual(plan.execution, .xpc)
        XCTAssertEqual(plan.serviceMode, .xpcService)
        XCTAssertEqual(
            plan.serviceIdentifier,
            "org.macscope.app.plugins.sample.service"
        )
        XCTAssertEqual(plan.manifestHash, "xpc-plan-hash")
        XCTAssertEqual(
            plan.authorizationRequirement,
            PluginRuntimeAuthorizationRequirement(
                command: "workspace.applyTags",
                capability: .workspaceWrite,
                filesystemScope: .workspace
            )
        )
        XCTAssertEqual(plan.mutationPolicy, .workspaceMutation)
        XCTAssertEqual(plan.undoPolicy, .required)
        XCTAssertEqual(plan.lifecycleStatus.state, .productionReady)
        XCTAssertTrue(plan.isOutOfProcess)
        XCTAssertTrue(plan.requiresUndoRegistration)
        XCTAssertEqual(
            try planner.plans(for: descriptor, surface: .mcp).map(\.commandIdentifier),
            ["workspace.applyTags"]
        )
    }

    func testAutomationFacadePlannerBuildsBoundedInvocationEnvelope() throws {
        var manifest = sampleManifest()
        manifest.capabilities.append(.workspaceWrite)
        manifest.permissions = PluginPermissions(
            network: false,
            processSpawn: false,
            filesystemScope: .workspace
        )
        manifest.service = PluginServiceMetadata(
            mode: .xpcService,
            identifier: "org.macscope.app.plugins.sample.service"
        )
        manifest.commands = [
            PluginCommandDescriptor(
                identifier: "workspace.applyTags",
                displayName: "Apply Tags",
                capability: .workspaceWrite,
                surfaces: [.mcp],
                filesystemScope: .workspace,
                mutationPolicy: .workspaceMutation,
                undoPolicy: .required,
                serviceMode: .xpcService
            )
        ]

        let descriptor = try PluginRegistry().validate(
            manifest,
            trustDecision: .unknown,
            manifestHash: "invocation-hash"
        )
        let requestID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let createdAt = Date(timeIntervalSince1970: 1_800_001_000)
        let envelope = try PluginAutomationFacadePlanner(policy: .settingsDefault)
            .invocationEnvelope(
                for: descriptor,
                commandIdentifier: "workspace.applyTags",
                surface: .mcp,
                arguments: [
                    " address ": "0x100000000",
                    "apiToken": "do-not-log"
                ],
                requestID: requestID,
                createdAt: createdAt
            )

        XCTAssertEqual(envelope.id, requestID)
        XCTAssertEqual(envelope.createdAt, createdAt)
        XCTAssertEqual(
            envelope.routingKey,
            "org.macscope.app.plugins.sample#workspace.applyTags#mcp"
        )
        XCTAssertEqual(envelope.plan.commandDisplayName, "Apply Tags")
        XCTAssertEqual(envelope.arguments.values["address"], "0x100000000")
        XCTAssertEqual(envelope.arguments.sortedKeys, ["address", "apiToken"])
        XCTAssertEqual(envelope.audit.pluginIdentifier, manifest.identifier)
        XCTAssertEqual(envelope.audit.commandIdentifier, "workspace.applyTags")
        XCTAssertEqual(envelope.audit.serviceMode, .xpcService)
        XCTAssertEqual(envelope.audit.manifestHash, "invocation-hash")
        XCTAssertEqual(envelope.audit.lifecycleState, .productionReady)
        XCTAssertTrue(envelope.audit.requiresUndoRegistration)
        XCTAssertEqual(envelope.audit.argumentCount, 2)
        XCTAssertEqual(envelope.audit.redactedArguments["address"], "0x100000000")
        XCTAssertEqual(envelope.audit.redactedArguments["apiToken"], "<redacted>")

        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(
            PluginAutomationInvocationEnvelope.self,
            from: encoded
        )
        XCTAssertEqual(decoded, envelope)
    }

    func testAutomationHostLifecyclePlanModelsXPCEnvelopeWithoutLaunchingPlugin() throws {
        var manifest = sampleManifest()
        manifest.capabilities.append(.workspaceWrite)
        manifest.permissions = PluginPermissions(
            network: false,
            processSpawn: false,
            filesystemScope: .workspace
        )
        manifest.service = PluginServiceMetadata(
            mode: .xpcService,
            identifier: "org.macscope.app.plugins.sample.service",
            supportsConcurrentRequests: true
        )
        manifest.commands = [
            PluginCommandDescriptor(
                identifier: "workspace.applyTags",
                displayName: "Apply Tags",
                capability: .workspaceWrite,
                surfaces: [.mcp],
                filesystemScope: .workspace,
                mutationPolicy: .workspaceMutation,
                undoPolicy: .required,
                serviceMode: .xpcService
            )
        ]

        let descriptor = try PluginRegistry().validate(
            manifest,
            trustDecision: .unknown,
            manifestHash: "xpc-lifecycle-hash"
        )
        let requestID = UUID(uuidString: "12121212-3434-5656-7878-909090909090")!
        let planner = PluginAutomationFacadePlanner(policy: .settingsDefault)
        let envelope = try planner.invocationEnvelope(
            for: descriptor,
            commandIdentifier: "workspace.applyTags",
            surface: .mcp,
            arguments: [
                "tag": "entry",
                "apiToken": "do-not-log"
            ],
            requestID: requestID,
            createdAt: Date(timeIntervalSince1970: 1_800_002_000)
        )

        let lifecyclePlan = try planner.hostLifecyclePlan(for: envelope)

        XCTAssertEqual(lifecyclePlan.requestID, requestID)
        XCTAssertEqual(lifecyclePlan.pluginIdentifier, manifest.identifier)
        XCTAssertEqual(lifecyclePlan.commandIdentifier, "workspace.applyTags")
        XCTAssertEqual(lifecyclePlan.surface, .mcp)
        XCTAssertEqual(lifecyclePlan.execution, .xpc)
        XCTAssertEqual(lifecyclePlan.serviceMode, .xpcService)
        XCTAssertEqual(
            lifecyclePlan.serviceIdentifier,
            "org.macscope.app.plugins.sample.service"
        )
        XCTAssertEqual(lifecyclePlan.hostKind, .xpcService)
        XCTAssertEqual(lifecyclePlan.trustBoundary, .externalProcess)
        XCTAssertTrue(lifecyclePlan.keepsPluginOutOfProcess)
        XCTAssertEqual(
            lifecyclePlan.lifecycleStages,
            [
                .validateEnvelope,
                .authorizeRuntime,
                .connectXPCService,
                .dispatchInvocation,
                .awaitReply,
                .recordAudit,
                .releaseHost
            ]
        )
        XCTAssertEqual(
            lifecyclePlan.permissionAudit,
            PluginAutomationPermissionAuditRecord(
                capability: .workspaceWrite,
                requiresNetwork: false,
                requiresProcessSpawn: false,
                filesystemScope: .workspace,
                mutationPolicy: .workspaceMutation,
                undoPolicy: .required,
                requiresUndoRegistration: true
            )
        )
        XCTAssertEqual(lifecyclePlan.invocationAudit.manifestHash, "xpc-lifecycle-hash")
        XCTAssertEqual(lifecyclePlan.invocationAudit.redactedArguments["tag"], "entry")
        XCTAssertEqual(
            lifecyclePlan.invocationAudit.redactedArguments["apiToken"],
            "<redacted>"
        )

        let encoded = try JSONEncoder().encode(lifecyclePlan)
        let decoded = try JSONDecoder().decode(
            PluginAutomationHostLifecyclePlan.self,
            from: encoded
        )
        XCTAssertEqual(decoded, lifecyclePlan)
    }

    func testAutomationHostLifecyclePlanModelsExternalCLIAsDefaultBoundaryWithoutLaunch() throws {
        let missingExecutableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("not-launched-plugin-host")
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = missingExecutableURL.path
        manifest.principalClass = nil
        manifest.service = PluginServiceMetadata(
            mode: .stdioJSONRPC,
            identifier: "org.macscope.app.plugins.sample.stdio"
        )
        manifest.commands = [
            PluginCommandDescriptor(
                identifier: "symbols.describe",
                displayName: "Describe Symbol",
                capability: .analysisSymbols,
                surfaces: [.cli, .mcp],
                serviceMode: .stdioJSONRPC
            )
        ]

        let descriptor = try PluginRegistry().validate(
            manifest,
            trustDecision: .allowExternal,
            manifestHash: "external-cli-hash"
        )
        let requestID = UUID(uuidString: "abababab-cdcd-efef-abab-cdcdcdcdcdcd")!
        let planner = PluginAutomationFacadePlanner(policy: .settingsDefault)
        let envelope = try planner.invocationEnvelope(
            for: descriptor,
            commandIdentifier: "symbols.describe",
            surface: .cli,
            arguments: ["address": "0x100000000"],
            requestID: requestID
        )

        let lifecyclePlan = try planner.hostLifecyclePlan(for: envelope)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingExecutableURL.path))
        XCTAssertEqual(lifecyclePlan.hostKind, .externalStdio)
        XCTAssertEqual(lifecyclePlan.execution, .external)
        XCTAssertEqual(lifecyclePlan.serviceMode, .stdioJSONRPC)
        XCTAssertEqual(
            lifecyclePlan.serviceIdentifier,
            "org.macscope.app.plugins.sample.stdio"
        )
        XCTAssertEqual(lifecyclePlan.trustBoundary, .externalProcess)
        XCTAssertTrue(lifecyclePlan.keepsPluginOutOfProcess)
        XCTAssertEqual(
            lifecyclePlan.lifecycleStages,
            [
                .validateEnvelope,
                .authorizeRuntime,
                .spawnExternalHost,
                .dispatchInvocation,
                .awaitReply,
                .recordAudit,
                .terminateHost
            ]
        )
        XCTAssertEqual(
            lifecyclePlan.permissionAudit,
            PluginAutomationPermissionAuditRecord(
                capability: .analysisSymbols,
                requiresNetwork: false,
                requiresProcessSpawn: false,
                filesystemScope: .none,
                mutationPolicy: .readOnly,
                undoPolicy: .notApplicable,
                requiresUndoRegistration: false
            )
        )
        XCTAssertEqual(lifecyclePlan.invocationAudit.lifecycleState, .productionReady)
        XCTAssertEqual(lifecyclePlan.invocationAudit.redactedArguments["address"], "0x100000000")
    }

    func testAutomationHostLifecyclePlanRejectsForgedInProcessEnvelope() throws {
        let lifecycleStatus = PluginLifecycleStatus(
            launchBlockers: [],
            productionBlockers: []
        )
        let commandPlan = PluginAutomationCommandPlan(
            pluginIdentifier: "org.macscope.app.plugins.sample",
            pluginDisplayName: "Sample Importer",
            commandIdentifier: "symbols.describe",
            commandDisplayName: "Describe Symbol",
            surface: .mcp,
            execution: .inProcess,
            serviceMode: .inProcess,
            serviceIdentifier: nil,
            manifestHash: "forged-hash",
            authorizationRequirement: PluginRuntimeAuthorizationRequirement(
                command: "symbols.describe",
                capability: .analysisSymbols
            ),
            mutationPolicy: .readOnly,
            undoPolicy: .notApplicable,
            lifecycleStatus: lifecycleStatus
        )
        let arguments = try PluginAutomationInvocationArguments([:])
        let audit = PluginAutomationInvocationAudit(
            pluginIdentifier: commandPlan.pluginIdentifier,
            commandIdentifier: commandPlan.commandIdentifier,
            surface: commandPlan.surface,
            serviceMode: commandPlan.serviceMode,
            manifestHash: commandPlan.manifestHash,
            lifecycleState: lifecycleStatus.state,
            requiresUndoRegistration: false,
            argumentCount: 0,
            redactedArguments: [:]
        )
        let envelope = PluginAutomationInvocationEnvelope(
            requestID: UUID(uuidString: "f0f0f0f0-1111-2222-3333-444444444444")!,
            createdAt: Date(timeIntervalSince1970: 1_800_003_000),
            plan: commandPlan,
            arguments: arguments,
            audit: audit
        )

        XCTAssertThrowsError(try PluginAutomationHostLifecyclePlan(envelope: envelope)) { error in
            XCTAssertEqual(
                error as? PluginAutomationHostLifecycleError,
                .inProcessHostUnsupported(
                    identifier: "org.macscope.app.plugins.sample",
                    command: "symbols.describe"
                )
            )
        }
    }

    func testAutomationInvocationArgumentsRejectInvalidOrOversizedArguments() throws {
        XCTAssertThrowsError(
            try PluginAutomationInvocationArguments([" ": "value"])
        ) { error in
            XCTAssertEqual(
                error as? PluginAutomationInvocationError,
                .emptyArgumentKey
            )
        }

        let longKey = String(repeating: "k", count: PluginAutomationInvocationArguments.maximumKeyLength + 1)
        XCTAssertThrowsError(
            try PluginAutomationInvocationArguments([longKey: "value"])
        ) { error in
            XCTAssertEqual(
                error as? PluginAutomationInvocationError,
                .argumentKeyTooLong(
                    key: longKey,
                    maximum: PluginAutomationInvocationArguments.maximumKeyLength
                )
            )
        }

        let longValue = String(
            repeating: "v",
            count: PluginAutomationInvocationArguments.maximumValueLength + 1
        )
        XCTAssertThrowsError(
            try PluginAutomationInvocationArguments(["payload": longValue])
        ) { error in
            XCTAssertEqual(
                error as? PluginAutomationInvocationError,
                .argumentValueTooLong(
                    key: "payload",
                    maximum: PluginAutomationInvocationArguments.maximumValueLength
                )
            )
        }
    }

    func testAutomationFacadePlannerRejectsUIAndUndeclaredSurfaces() throws {
        var manifest = sampleManifest()
        manifest.commands = [
            PluginCommandDescriptor(
                identifier: "symbols.describe",
                displayName: "Describe Symbol",
                capability: .analysisSymbols,
                surfaces: [.automation],
                serviceMode: .xpcService
            )
        ]
        let descriptor = try PluginRegistry().validate(manifest, trustDecision: .unknown)
        let planner = PluginAutomationFacadePlanner(policy: .settingsDefault)

        XCTAssertThrowsError(
            try planner.planCommand(
                descriptor,
                commandIdentifier: "symbols.describe",
                surface: .ui
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginAutomationPlanningError,
                .unsupportedSurface(.ui)
            )
        }

        XCTAssertThrowsError(
            try planner.planCommand(
                descriptor,
                commandIdentifier: "symbols.describe",
                surface: .mcp
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginAutomationPlanningError,
                .commandSurfaceNotDeclared(
                    identifier: "org.macscope.app.plugins.sample",
                    command: "symbols.describe",
                    surface: .mcp
                )
            )
        }
    }

    func testAutomationFacadePlannerRejectsInProcessAutomationPlan() throws {
        var manifest = sampleManifest()
        manifest.execution = .inProcess
        manifest.service = PluginServiceMetadata(mode: .inProcess)
        manifest.commands = [
            PluginCommandDescriptor(
                identifier: "symbols.describe",
                displayName: "Describe Symbol",
                capability: .analysisSymbols,
                surfaces: [.automation],
                serviceMode: .inProcess
            )
        ]
        let descriptor = try PluginRegistry().validate(
            manifest,
            trustDecision: .allowInProcess
        )
        let planner = PluginAutomationFacadePlanner(policy: .settingsDefault)

        XCTAssertThrowsError(
            try planner.planCommand(
                descriptor,
                commandIdentifier: "symbols.describe",
                surface: .automation
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginAutomationPlanningError,
                .inProcessAutomationUnsupported(
                    identifier: "org.macscope.app.plugins.sample",
                    command: "symbols.describe"
                )
            )
        }
    }

    func testAutomationFacadePlannerAppliesRuntimePolicyBeforeHelperPlan() throws {
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = "/bin/cat"
        manifest.principalClass = nil
        manifest.permissions = PluginPermissions(
            network: true,
            processSpawn: false,
            filesystemScope: .userSelected
        )
        manifest.service = PluginServiceMetadata(mode: .stdioJSONRPC)
        manifest.commands = [
            PluginCommandDescriptor(
                identifier: "symbols.remoteResolve",
                displayName: "Remote Resolve",
                capability: .analysisSymbols,
                surfaces: [.cli, .mcp],
                requiresNetwork: true,
                serviceMode: .stdioJSONRPC
            )
        ]

        let descriptor = try PluginRegistry().validate(
            manifest,
            trustDecision: .allowExternal
        )
        let strictPlanner = PluginAutomationFacadePlanner(policy: .settingsDefault)

        XCTAssertThrowsError(
            try strictPlanner.planCommand(
                descriptor,
                commandIdentifier: "symbols.remoteResolve",
                surface: .cli
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginAutomationPlanningError,
                .runtimeAuthorizationDenied(
                    .networkDisabledByPolicy(
                        identifier: "org.macscope.app.plugins.sample",
                        command: "symbols.remoteResolve"
                    )
                )
            )
        }

        let permissivePolicy = PluginRuntimePolicy(
            allowDevelopmentPlugins: false,
            requireSignedPlugins: true,
            allowNetworkAccess: true,
            allowProcessSpawn: false
        )
        let plan = try PluginAutomationFacadePlanner(policy: permissivePolicy)
            .planCommand(
                descriptor,
                commandIdentifier: "symbols.remoteResolve",
                surface: .cli
            )

        XCTAssertEqual(plan.surface, .cli)
        XCTAssertEqual(plan.execution, .external)
        XCTAssertEqual(plan.serviceMode, .stdioJSONRPC)
        XCTAssertFalse(plan.requiresUndoRegistration)
    }

    func testRuntimePolicyReadsSettingsDefaultsAndOverrides() throws {
        let suiteName = "PluginRuntimePolicyTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(PluginRuntimePolicy(userDefaults: userDefaults), .settingsDefault)

        userDefaults.set(true, forKey: PluginRuntimePolicy.StorageKey.allowDevelopmentPlugins)
        userDefaults.set(false, forKey: PluginRuntimePolicy.StorageKey.requireSignedPlugins)
        userDefaults.set(true, forKey: PluginRuntimePolicy.StorageKey.allowNetworkAccess)
        userDefaults.set(true, forKey: PluginRuntimePolicy.StorageKey.allowProcessSpawn)

        XCTAssertEqual(
            PluginRuntimePolicy(userDefaults: userDefaults),
            PluginRuntimePolicy(
                allowDevelopmentPlugins: true,
                requireSignedPlugins: false,
                allowNetworkAccess: true,
                allowProcessSpawn: true
            )
        )
    }

    func testRuntimeAuthorizerAppliesSettingsPolicyAfterManifestPermissions() throws {
        var manifest = sampleManifest()
        manifest.permissions = PluginPermissions(
            network: true,
            processSpawn: true,
            filesystemScope: .userSelected
        )
        let descriptor = try PluginRegistry().validate(
            manifest,
            trustDecision: .unknown
        )

        let strictAuthorizer = PluginRuntimeAuthorizer(policy: .settingsDefault)
        XCTAssertThrowsError(
            try strictAuthorizer.authorize(
                descriptor,
                requirement: PluginRuntimeAuthorizationRequirement(
                    command: "symbols.remoteResolve",
                    capability: .analysisSymbols,
                    requiresNetwork: true
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginRuntimeAuthorizationError,
                .networkDisabledByPolicy(
                    identifier: "org.macscope.app.plugins.sample",
                    command: "symbols.remoteResolve"
                )
            )
        }

        let networkOnlyPolicy = PluginRuntimePolicy(
            allowDevelopmentPlugins: false,
            requireSignedPlugins: true,
            allowNetworkAccess: true,
            allowProcessSpawn: false
        )
        let networkAuthorizer = PluginRuntimeAuthorizer(policy: networkOnlyPolicy)
        XCTAssertNoThrow(
            try networkAuthorizer.authorize(
                descriptor,
                requirement: PluginRuntimeAuthorizationRequirement(
                    command: "symbols.remoteResolve",
                    capability: .analysisSymbols,
                    requiresNetwork: true
                )
            )
        )
        XCTAssertThrowsError(
            try networkAuthorizer.authorize(
                descriptor,
                requirement: PluginRuntimeAuthorizationRequirement(
                    command: "workspace.runTool",
                    capability: .workspaceRead,
                    requiresProcessSpawn: true
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginRuntimeAuthorizationError,
                .processSpawnDisabledByPolicy(
                    identifier: "org.macscope.app.plugins.sample",
                    command: "workspace.runTool"
                )
            )
        }
    }

    func testExternalHostChecksRuntimeAuthorizationBeforeLaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let markerURL = directory.appendingPathComponent("launched.marker")
        let executableURL = try writeExternalPlugin(
            in: directory,
            name: "marker-plugin.sh",
            body: """
            #!/bin/sh
            /usr/bin/touch '\(markerURL.path)'
            /usr/bin/printf '%s\\n' '{"status":"ok","message":"launched","values":{}}'
            """
        )

        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = executableURL.path
        manifest.principalClass = nil
        manifest.capabilities = [.workspaceRead]

        let descriptor = try PluginRegistry().validate(
            manifest,
            manifestURL: directory.appendingPathComponent("sample.json"),
            trustDecision: .allowExternal,
            manifestHash: "sample-hash"
        )
        let requestID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let denialDate = Date(timeIntervalSince1970: 1_800_000_240)
        var lifecycleRecords: [PluginExternalRunRecord] = []
        let host = PluginExternalExecutionHost(
            recordLifecycle: { record in
                lifecycleRecords.append(record)
                do {
                    try database.upsertPluginExternalRun(record)
                } catch {
                    XCTFail("Failed to persist runtime denial record: \(error)")
                }
            },
            currentDate: { denialDate }
        )

        XCTAssertThrowsError(
            try host.invoke(
                descriptor,
                request: SamplePluginRequest(
                    command: "symbols.describe",
                    arguments: ["address": "0x100000000"]
                ),
                responseType: SamplePluginResponse.self,
                authorizationRequirement: PluginRuntimeAuthorizationRequirement(
                    command: "symbols.describe",
                    capability: .analysisSymbols
                ),
                requestID: requestID
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginExternalExecutionError,
                .runtimeAuthorizationDenied(
                    .missingCapability(
                        identifier: "org.macscope.app.plugins.sample",
                        command: "symbols.describe",
                        capability: .analysisSymbols
                    )
                )
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertEqual(lifecycleRecords.map(\.status), [.failed])
        let deniedRecord = try XCTUnwrap(lifecycleRecords.first)
        XCTAssertEqual(deniedRecord.requestID, requestID)
        XCTAssertEqual(deniedRecord.pluginIdentifier, manifest.identifier)
        XCTAssertEqual(deniedRecord.displayName, manifest.displayName)
        XCTAssertEqual(deniedRecord.executablePath, executableURL.path)
        XCTAssertEqual(deniedRecord.manifestHash, "sample-hash")
        XCTAssertEqual(deniedRecord.startedAt, denialDate)
        XCTAssertEqual(deniedRecord.completedAt, denialDate)
        XCTAssertNil(deniedRecord.terminationStatus)
        XCTAssertEqual(deniedRecord.stdout, "")
        XCTAssertEqual(deniedRecord.stderr, "")
        XCTAssertTrue(deniedRecord.log.contains("denied before launch"))
        XCTAssertTrue(deniedRecord.errorMessage?.contains("runtime authorization denied") ?? false)
        XCTAssertEqual(try database.pluginExternalRun(requestID: requestID), deniedRecord)
        XCTAssertEqual(
            try database.pluginExternalRuns(pluginIdentifier: manifest.identifier),
            [deniedRecord]
        )
    }

    func testExternalHostInvokesSampleCommandOverJSONStdio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = try writeSampleExternalPlugin(in: directory)

        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = executableURL.path
        manifest.principalClass = nil

        let manifestURL = directory.appendingPathComponent("sample.json")
        let manifestBytes = try manifestData(manifest)
        try manifestBytes.write(to: manifestURL)

        let descriptor = try PluginRegistry().validate(
            manifest,
            manifestURL: manifestURL,
            trustDecision: .allowExternal,
            manifestHash: "sample-hash"
        )
        let requestID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        var lifecycleRecords: [PluginExternalRunRecord] = []
        let host = PluginExternalExecutionHost(
            timeout: 2,
            recordLifecycle: { lifecycleRecords.append($0) }
        )
        let plan = try host.dryRun(descriptor)
        XCTAssertEqual(plan.executableURL.path, executableURL.path)
        XCTAssertEqual(plan.manifestHash, "sample-hash")
        XCTAssertEqual(plan.trustDecision, .allowExternal)
        XCTAssertEqual(plan.lifecycleStatus.state, .productionReady)
        XCTAssertEqual(plan.provenance, .bundledUnsigned)
        XCTAssertTrue(plan.isLaunchReady)
        XCTAssertTrue(plan.isProductionReady)

        let result = try host.invoke(
            descriptor,
            request: SamplePluginRequest(
                command: "symbols.describe",
                arguments: ["address": "0x100000000"]
            ),
            responseType: SamplePluginResponse.self,
            authorizationRequirement: PluginRuntimeAuthorizationRequirement(
                command: "symbols.describe",
                capability: .analysisSymbols,
                filesystemScope: .userSelected
            ),
            requestID: requestID
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.stdout.contains("sample external plugin invoked"))
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.response.status, "ok")
        XCTAssertEqual(result.response.message, "sample external plugin invoked")
        XCTAssertEqual(result.response.values["symbol"], "_main")
        XCTAssertEqual(result.response.values["plugin"], manifest.identifier)
        XCTAssertEqual(result.runRecord.requestID, requestID)
        XCTAssertEqual(result.runRecord.status, .completed)
        XCTAssertEqual(result.runRecord.pluginIdentifier, manifest.identifier)
        XCTAssertEqual(result.runRecord.manifestHash, "sample-hash")
        XCTAssertEqual(result.runRecord.terminationStatus, 0)
        XCTAssertEqual(result.runRecord.errorMessage, nil)
        XCTAssertTrue(result.runRecord.log.contains("trust=allowExternal"))
        XCTAssertTrue(result.runRecord.log.contains("lifecycle=production-ready"))
        XCTAssertTrue(result.runRecord.log.contains("distribution=bundled"))
        XCTAssertEqual(lifecycleRecords.map(\.status), [.started, .completed])
        XCTAssertEqual(lifecycleRecords.map(\.requestID), [requestID, requestID])
    }

    func testExternalHostPassesTrustProvenanceAndReadinessToExternalProcess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = try writeExternalPlugin(
            in: directory,
            name: "metadata-plugin.sh",
            body: """
            #!/bin/sh
            /bin/cat >/dev/null
            /usr/bin/printf '{"status":"ok","message":"metadata","values":{"trust":"%s","lifecycle":"%s","launchReady":"%s","productionReady":"%s","distribution":"%s","signature":"%s","team":"%s","source":"%s","manifestHash":"%s"}}\\n' \
              "$MACSCOPE_PLUGIN_TRUST_DECISION" \
              "$MACSCOPE_PLUGIN_LIFECYCLE_STATE" \
              "$MACSCOPE_PLUGIN_LAUNCH_READY" \
              "$MACSCOPE_PLUGIN_PRODUCTION_READY" \
              "$MACSCOPE_PLUGIN_PROVENANCE_DISTRIBUTION" \
              "$MACSCOPE_PLUGIN_SIGNATURE_STATE" \
              "$MACSCOPE_PLUGIN_TEAM_IDENTIFIER" \
              "$MACSCOPE_PLUGIN_PROVENANCE_SOURCE" \
              "$MACSCOPE_PLUGIN_MANIFEST_HASH"
            """
        )

        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = executableURL.path
        manifest.principalClass = nil
        manifest.provenance = PluginProvenance(
            distribution: .thirdParty,
            signatureState: .signed,
            teamIdentifier: "ABCDE12345",
            signingIdentifier: "Developer ID Application: Example",
            source: "download"
        )
        let descriptor = try PluginRegistry().validate(
            manifest,
            manifestURL: directory.appendingPathComponent("metadata.json"),
            trustDecision: .allowExternal,
            manifestHash: "metadata-hash"
        )
        let host = PluginExternalExecutionHost(timeout: 2)

        let result = try host.invoke(
            descriptor,
            request: SamplePluginRequest(command: "symbols.describe", arguments: [:]),
            responseType: SamplePluginResponse.self
        )

        XCTAssertEqual(result.response.status, "ok")
        XCTAssertEqual(result.response.values["trust"], "allowExternal")
        XCTAssertEqual(result.response.values["lifecycle"], "production-ready")
        XCTAssertEqual(result.response.values["launchReady"], "1")
        XCTAssertEqual(result.response.values["productionReady"], "1")
        XCTAssertEqual(result.response.values["distribution"], "third-party")
        XCTAssertEqual(result.response.values["signature"], "signed")
        XCTAssertEqual(result.response.values["team"], "ABCDE12345")
        XCTAssertEqual(result.response.values["source"], "download")
        XCTAssertEqual(result.response.values["manifestHash"], "metadata-hash")
        XCTAssertTrue(result.runRecord.log.contains("signature=signed"))
        XCTAssertTrue(result.runRecord.log.contains("requestBytes="))
    }

    func testExternalHostRecordsFailedLifecycleForNonZeroExit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = try writeExternalPlugin(
            in: directory,
            name: "failing-plugin.sh",
            body: """
            #!/bin/sh
            /usr/bin/printf '%s\\n' '{"status":"error","message":"failed","values":{}}'
            /usr/bin/printf '%s\\n' 'stderr failure' >&2
            exit 7
            """
        )
        let descriptor = try externalDescriptor(executableURL: executableURL)
        let requestID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        var lifecycleRecords: [PluginExternalRunRecord] = []
        let host = PluginExternalExecutionHost(
            timeout: 2,
            recordLifecycle: { lifecycleRecords.append($0) }
        )

        XCTAssertThrowsError(
            try host.invoke(
                descriptor,
                request: SamplePluginRequest(command: "symbols.describe", arguments: [:]),
                responseType: SamplePluginResponse.self,
                requestID: requestID
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginExternalExecutionError,
                .nonZeroExit(
                    identifier: "org.macscope.app.plugins.sample",
                    status: 7,
                    stderr: "stderr failure\n"
                )
            )
        }

        XCTAssertEqual(lifecycleRecords.map(\.status), [.started, .failed])
        let failedRecord = try XCTUnwrap(lifecycleRecords.last)
        XCTAssertEqual(failedRecord.requestID, requestID)
        XCTAssertEqual(failedRecord.terminationStatus, 7)
        XCTAssertTrue(failedRecord.stdout.contains(#""message":"failed""#))
        XCTAssertEqual(failedRecord.stderr, "stderr failure\n")
        XCTAssertTrue(failedRecord.errorMessage?.contains("exited with status 7") ?? false)
    }

    func testExternalHostRecordsCancelledLifecycleForTimeout() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = try writeExternalPlugin(
            in: directory,
            name: "slow-plugin.sh",
            body: """
            #!/bin/sh
            /bin/sleep 2
            /usr/bin/printf '%s\\n' '{"status":"ok","message":"late","values":{}}'
            """
        )
        let descriptor = try externalDescriptor(executableURL: executableURL)
        let requestID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        var lifecycleRecords: [PluginExternalRunRecord] = []
        let host = PluginExternalExecutionHost(
            timeout: 0.1,
            recordLifecycle: { lifecycleRecords.append($0) }
        )

        XCTAssertThrowsError(
            try host.invoke(
                descriptor,
                request: SamplePluginRequest(command: "symbols.describe", arguments: [:]),
                responseType: SamplePluginResponse.self,
                requestID: requestID
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginExternalExecutionError,
                .timedOut(
                    identifier: "org.macscope.app.plugins.sample",
                    timeout: 0.1
                )
            )
        }

        XCTAssertEqual(lifecycleRecords.map(\.status), [.started, .cancelled])
        let cancelledRecord = try XCTUnwrap(lifecycleRecords.last)
        XCTAssertEqual(cancelledRecord.requestID, requestID)
        XCTAssertEqual(cancelledRecord.pluginIdentifier, "org.macscope.app.plugins.sample")
        XCTAssertTrue(cancelledRecord.errorMessage?.contains("timed out") ?? false)
    }

    func testExternalHostTimesOutPluginThatNeverReadsLargeRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let pidURL = directory.appendingPathComponent("plugin.pid")
        let executableURL = try writeExternalPlugin(
            in: directory,
            name: "never-reads-plugin.sh",
            body: """
            #!/bin/sh
            echo $$ > '\(pidURL.path)'
            exec /bin/sleep 30
            """
        )
        let descriptor = try externalDescriptor(executableURL: executableURL)
        var lifecycleRecords: [PluginExternalRunRecord] = []
        let host = PluginExternalExecutionHost(
            timeout: 0.5,
            recordLifecycle: { lifecycleRecords.append($0) }
        )

        // Far larger than the ~64 KB pipe buffer: before the fix the host blocked in write()
        // before its deadline started and never returned.
        let started = Date()
        XCTAssertThrowsError(
            try host.invoke(
                descriptor,
                request: largeSampleRequest(),
                responseType: SamplePluginResponse.self
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginExternalExecutionError,
                .timedOut(
                    identifier: "org.macscope.app.plugins.sample",
                    timeout: 0.5
                )
            )
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3.5, "timeout budget 0.5 s plus termination grace and margin")

        XCTAssertEqual(lifecycleRecords.map(\.status), [.started, .cancelled])
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(pidText))
        errno = 0
        XCTAssertEqual(kill(pid, 0), -1, "the timed-out plugin must be terminated and reaped")
        XCTAssertEqual(errno, ESRCH)
    }

    func testExternalHostDeliversLargeRequestToPluginThatReadsToEOF() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = try writeExternalPlugin(
            in: directory,
            name: "count-stdin-plugin.sh",
            body: """
            #!/bin/sh
            count=$(/usr/bin/wc -c | /usr/bin/tr -d ' ')
            /usr/bin/printf '{"status":"ok","message":"counted","values":{"bytes":"%s"}}\\n' "$count"
            """
        )
        let descriptor = try externalDescriptor(executableURL: executableURL)
        let host = PluginExternalExecutionHost(timeout: 10)
        let request = largeSampleRequest()
        let expectedBytes = try JSONEncoder().encode(request).count + 1

        let result = try host.invoke(
            descriptor,
            request: request,
            responseType: SamplePluginResponse.self
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.response.status, "ok")
        XCTAssertEqual(result.response.values["bytes"], String(expectedBytes))
        XCTAssertEqual(result.runRecord.status, .completed)
    }

    func testExternalHostReportsCleanErrorWhenPluginExitsWithoutReadingLargeRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = try writeExternalPlugin(
            in: directory,
            name: "exits-early-plugin.sh",
            body: """
            #!/bin/sh
            exit 3
            """
        )
        let descriptor = try externalDescriptor(executableURL: executableURL)
        var lifecycleRecords: [PluginExternalRunRecord] = []
        let host = PluginExternalExecutionHost(
            timeout: 10,
            recordLifecycle: { lifecycleRecords.append($0) }
        )

        // The closed reader yields EPIPE on the host's write; it must neither raise SIGPIPE nor
        // an Objective-C exception, and the plugin's exit status decides the result.
        XCTAssertThrowsError(
            try host.invoke(
                descriptor,
                request: largeSampleRequest(),
                responseType: SamplePluginResponse.self
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginExternalExecutionError,
                .nonZeroExit(
                    identifier: "org.macscope.app.plugins.sample",
                    status: 3,
                    stderr: ""
                )
            )
        }
        XCTAssertEqual(lifecycleRecords.map(\.status), [.started, .failed])
    }

    func testExternalHostRecordsCancellationBeforeLaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let markerURL = directory.appendingPathComponent("launched.marker")
        let executableURL = try writeExternalPlugin(
            in: directory,
            name: "cancelled-plugin.sh",
            body: """
            #!/bin/sh
            /usr/bin/touch '\(markerURL.path)'
            /usr/bin/printf '%s\\n' '{"status":"ok","message":"launched","values":{}}'
            """
        )
        let descriptor = try externalDescriptor(executableURL: executableURL)
        let requestID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        var lifecycleRecords: [PluginExternalRunRecord] = []
        let host = PluginExternalExecutionHost(
            recordLifecycle: { lifecycleRecords.append($0) }
        )

        XCTAssertThrowsError(
            try host.invoke(
                descriptor,
                request: SamplePluginRequest(command: "symbols.describe", arguments: [:]),
                responseType: SamplePluginResponse.self,
                isCancellationRequested: { true },
                requestID: requestID
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginExternalExecutionError,
                .cancelled(identifier: "org.macscope.app.plugins.sample")
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertEqual(lifecycleRecords.map(\.status), [.cancelled])
        let cancelledRecord = try XCTUnwrap(lifecycleRecords.first)
        XCTAssertEqual(cancelledRecord.requestID, requestID)
        XCTAssertEqual(cancelledRecord.pluginIdentifier, "org.macscope.app.plugins.sample")
        XCTAssertNil(cancelledRecord.terminationStatus)
        XCTAssertTrue(cancelledRecord.log.contains("cancelled before launch"))
        XCTAssertTrue(cancelledRecord.log.contains("trust=allowExternal"))
        XCTAssertTrue(cancelledRecord.errorMessage?.contains("cancelled by the host") ?? false)
    }

    func testExternalRunRecordRetryEligibilityMatchesTerminalLifecycle() {
        let started = runRecord(
            requestID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            status: .started
        )
        let completed = runRecord(
            requestID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            status: .completed
        )
        let failed = runRecord(
            requestID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            status: .failed
        )
        let cancelled = runRecord(
            requestID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            status: .cancelled
        )

        XCTAssertFalse(started.isTerminal)
        XCTAssertFalse(started.isRetryEligible)
        XCTAssertEqual(started.retryEligibility.blockers, [.requestStillRunning])

        XCTAssertTrue(completed.isTerminal)
        XCTAssertFalse(completed.isRetryEligible)
        XCTAssertEqual(completed.retryEligibility.blockers, [.requestAlreadyCompleted])

        XCTAssertTrue(failed.isTerminal)
        XCTAssertTrue(failed.isRetryEligible)
        XCTAssertEqual(failed.retryEligibility.blockers, [])

        XCTAssertTrue(cancelled.isTerminal)
        XCTAssertTrue(cancelled.isRetryEligible)
        XCTAssertEqual(cancelled.retryEligibility.blockers, [])
    }

    func testExternalRunLogFilterBoundsSortsAndFiltersRecords() {
        let sampleIdentifier = "org.macscope.app.plugins.sample"
        let baseDate = Date(timeIntervalSince1970: 1_800_010_000)
        let olderFailed = runRecord(
            requestID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            pluginIdentifier: sampleIdentifier,
            status: .failed,
            startedAt: baseDate.addingTimeInterval(10),
            completedAt: baseDate.addingTimeInterval(12)
        )
        let completed = runRecord(
            requestID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            pluginIdentifier: sampleIdentifier,
            status: .completed,
            startedAt: baseDate.addingTimeInterval(20),
            completedAt: baseDate.addingTimeInterval(22)
        )
        let newerCancelled = runRecord(
            requestID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            pluginIdentifier: sampleIdentifier,
            status: .cancelled,
            startedAt: baseDate.addingTimeInterval(30),
            completedAt: baseDate.addingTimeInterval(32)
        )
        let inFlight = runRecord(
            requestID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            pluginIdentifier: sampleIdentifier,
            status: .started,
            startedAt: baseDate.addingTimeInterval(40),
            completedAt: nil
        )
        let otherPluginFailed = runRecord(
            requestID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            pluginIdentifier: "org.macscope.app.plugins.other",
            status: .failed,
            startedAt: baseDate.addingTimeInterval(50),
            completedAt: baseDate.addingTimeInterval(52)
        )
        let records = [
            completed,
            otherPluginFailed,
            olderFailed,
            inFlight,
            newerCancelled
        ]

        let retryFilter = PluginExternalRunLogFilter(
            pluginIdentifier: " \(sampleIdentifier) ",
            statuses: [.failed, .cancelled],
            limit: 2
        )

        XCTAssertEqual(retryFilter.effectiveLimit, 2)
        XCTAssertTrue(retryFilter.matches(newerCancelled))
        XCTAssertFalse(retryFilter.matches(completed))
        XCTAssertFalse(retryFilter.matches(otherPluginFailed))
        XCTAssertEqual(
            retryFilter.apply(to: records).map(\.requestID),
            [newerCancelled.requestID, olderFailed.requestID]
        )

        let oldestFirst = PluginExternalRunLogFilter(
            pluginIdentifier: sampleIdentifier,
            limit: 10,
            sortOrder: .oldestFirst
        )
        XCTAssertEqual(
            oldestFirst.apply(to: records).map(\.requestID),
            [
                olderFailed.requestID,
                completed.requestID,
                newerCancelled.requestID,
                inFlight.requestID
            ]
        )

        XCTAssertEqual(PluginExternalRunLogFilter(limit: -5).apply(to: records), [])
        XCTAssertEqual(
            PluginExternalRunLogFilter(limit: 500).effectiveLimit,
            PluginExternalRunLogFilter.maximumLimit
        )
    }

    private func sampleManifest() -> PluginManifest {
        PluginManifest(
            identifier: "org.macscope.app.plugins.sample",
            displayName: "Sample Importer",
            version: "0.1.0",
            sdkVersion: "0.1",
            minHostVersion: "0.1.0",
            execution: .xpc,
            entryPoint: "SampleImporterService",
            principalClass: "SampleImporterPlugin",
            architectures: ["arm64"],
            capabilities: [.workspaceRead, .binaryImport, .analysisSymbols],
            permissions: .restricted,
            provenance: .bundledUnsigned
        )
    }

    private func sampleManifestData() throws -> Data {
        try manifestData(sampleManifest())
    }

    private func manifestData(_ manifest: PluginManifest) throws -> Data {
        try JSONEncoder().encode(manifest)
    }

    private func writeSampleExternalPlugin(in directory: URL) throws -> URL {
        try writeExternalPlugin(
            in: directory,
            name: "sample-plugin.sh",
            body: """
        #!/bin/sh
        request=$(/bin/cat)
        case "$request" in
        *symbols.describe*)
          /usr/bin/printf '%s\\n' '{"status":"ok","message":"sample external plugin invoked","values":{"symbol":"_main","plugin":"org.macscope.app.plugins.sample"}}'
          ;;
        *)
          /usr/bin/printf '%s\\n' '{"status":"error","message":"unexpected command","values":{}}'
          exit 2
          ;;
        esac
        """
        )
    }

    private func writeExternalPlugin(
        in directory: URL,
        name: String,
        body: String
    ) throws -> URL {
        let executableURL = directory.appendingPathComponent(name)
        let script = body
        try script.data(using: .utf8)?.write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
        return executableURL
    }

    private func runRecord(
        requestID: UUID = UUID(),
        pluginIdentifier: String = "org.macscope.app.plugins.sample",
        displayName: String = "Sample Importer",
        executablePath: String = "/tmp/sample-plugin.sh",
        manifestHash: String? = "sample-hash",
        status: PluginExternalRunStatus,
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        completedAt: Date? = nil,
        terminationStatus: Int32? = nil,
        stdout: String = "",
        stderr: String = "",
        log: String? = nil,
        errorMessage: String? = nil
    ) -> PluginExternalRunRecord {
        let resolvedCompletedAt = completedAt ?? (
            status == .started ? nil : startedAt.addingTimeInterval(1)
        )
        return PluginExternalRunRecord(
            requestID: requestID,
            pluginIdentifier: pluginIdentifier,
            displayName: displayName,
            executablePath: executablePath,
            manifestHash: manifestHash,
            status: status,
            startedAt: startedAt,
            completedAt: resolvedCompletedAt,
            terminationStatus: terminationStatus,
            stdout: stdout,
            stderr: stderr,
            log: log ?? "[\(status.rawValue)] test plugin run",
            errorMessage: errorMessage
        )
    }

    private func externalDescriptor(
        executableURL: URL,
        manifestHash: String = "sample-hash"
    ) throws -> PluginDescriptor {
        var manifest = sampleManifest()
        manifest.execution = .external
        manifest.entryPoint = executableURL.path
        manifest.principalClass = nil

        return try PluginRegistry().validate(
            manifest,
            manifestURL: executableURL.deletingLastPathComponent().appendingPathComponent("sample.json"),
            trustDecision: .allowExternal,
            manifestHash: manifestHash
        )
    }

    private func largeSampleRequest() -> SamplePluginRequest {
        SamplePluginRequest(
            command: "symbols.describe",
            arguments: ["payload": String(repeating: "a", count: 1_048_576)]
        )
    }

    private struct SamplePluginRequest: Codable, Equatable {
        var command: String
        var arguments: [String: String]
    }

    private struct SamplePluginResponse: Codable, Equatable {
        var status: String
        var message: String
        var values: [String: String]
    }
}
