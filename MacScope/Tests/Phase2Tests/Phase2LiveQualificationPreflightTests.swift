import Foundation
import XCTest

@testable import MacScope

final class Phase2LiveQualificationPreflightTests: XCTestCase {
    func testCandidatePreflightAndFreshnessUseExplicitSelectorWithoutHistoricalCrossover() throws {
        let fixture = try PreflightFixture(selector: .qwen38V2Q6K)
        let input = try fixture.input()
        guard case .prepared(let prepared) = Phase2LiveQualificationPreflight(
            selector: .qwen38V2Q6K
        ).evaluate(input) else { return XCTFail("Expected pure candidate preparation") }
        XCTAssertEqual(prepared.profile.artifact.bitsPerWeight, nil)
        XCTAssertEqual(prepared.runtimeBinding.loadedInstanceID, "instance-a")
        XCTAssertEqual(Phase2LiveQualificationPreflight().evaluate(input),
                       .rejected(.init(deficiencies: [.standardContractInvalid, .modelRevisionInvalid])))
        let observation = try fixture.freshObservation()
        XCTAssertTrue(Phase2LiveQualificationFreshObservationMatcher(selector: .qwen38V2Q6K)
            .compare(prepared: prepared, observation: observation).deficiencies.isEmpty)
        XCTAssertTrue(Phase2LiveQualificationFreshObservationMatcher()
            .compare(prepared: prepared, observation: observation).deficiencies
            .contains(.productionDefinitionMismatch))
    }

    func testCandidateRejectsHistoricalDefinitionAndUnknownParallelism() throws {
        let historical = try PreflightFixture()
        guard case .rejected(let crossover) = Phase2LiveQualificationPreflight(
            selector: .qwen38V2Q6K
        ).evaluate(try historical.input()) else { return XCTFail("Historical profile crossed selector") }
        XCTAssertTrue(crossover.deficiencies.contains(.standardContractInvalid))
        XCTAssertTrue(crossover.deficiencies.contains(.modelRevisionInvalid))

        let missingParallel = try PreflightFixture(
            selector: .qwen38V2Q6K,
            observedLoadedConfiguration: .init(
                effectiveContextLength: 32_768, evaluationBatchSize: 256,
                parallelPredictions: nil, flashAttention: true, expertCount: 8,
                offloadsKVCacheToGPU: true
            )
        )
        guard case .rejected(let rejection) = Phase2LiveQualificationPreflight(
            selector: .qwen38V2Q6K
        ).evaluate(try missingParallel.input()) else { return XCTFail("Unknown parallelism accepted") }
        XCTAssertTrue(rejection.deficiencies.contains(.loadedConfigurationMismatch))
    }

    func testFactoryBuildsProfileOnlyFromAuthoritativeObservation() throws {
        let fixture = try PreflightFixture()

        let result = Phase2StandardModelProfileFactory().makeProfile(
            from: try fixture.authoritativeProfileObservation
        )

        guard case .success(let profile) = result else {
            return XCTFail("Expected an exact profile, got \(result)")
        }
        XCTAssertEqual(profile.provider, fixture.providerIdentity)
        XCTAssertEqual(profile.artifact, try fixture.artifactIdentity)
        XCTAssertEqual(profile.loadedConfiguration, fixture.loadedConfiguration)
        XCTAssertEqual(profile.context, fixture.context)
        XCTAssertEqual(profile.generation, fixture.generation)
        XCTAssertEqual(profile.hardwareTier, fixture.hardwareTier)
        XCTAssertEqual(profile.protocolManifest, fixture.manifest)
    }

    func testFactoryRejectsMissingFormatQuantizationAndNonlanguageArtifacts() throws {
        let fixture = try PreflightFixture()
        let noFormat = fixture.model(
            type: .language,
            format: nil,
            quantization: fixture.quantization
        )
        let noQuantization = fixture.model(
            type: .language,
            format: .mlx,
            quantization: nil
        )
        let embedding = fixture.model(
            type: .embedding,
            format: .mlx,
            quantization: fixture.quantization
        )

        XCTAssertEqual(
            Phase2StandardModelProfileFactory().makeProfile(
                from: try fixture.authoritativeProfileObservation(model: noFormat)
            ),
            .failure(.modelFormatUnavailable)
        )
        XCTAssertEqual(
            Phase2StandardModelProfileFactory().makeProfile(
                from: try fixture.authoritativeProfileObservation(model: noQuantization)
            ),
            .failure(.modelQuantizationUnavailable)
        )
        XCTAssertEqual(
            Phase2StandardModelProfileFactory().makeProfile(
                from: try fixture.authoritativeProfileObservation(model: embedding)
            ),
            .failure(.modelNotLanguage)
        )
    }

    func testExactPreflightSeparatesReusableProfileFromLaunchLocalBinding() throws {
        let fixture = try PreflightFixture()

        let result = Phase2LiveQualificationPreflight().evaluate(try fixture.input())

        guard case .prepared(let prepared) = result else {
            return XCTFail("Expected prepared qualification, got \(result)")
        }
        XCTAssertEqual(prepared.profile.provider, fixture.providerIdentity)
        XCTAssertEqual(prepared.profile.artifact, try fixture.artifactIdentity)
        XCTAssertEqual(prepared.runtimeBinding.endpointProfileID, fixture.profileID)
        XCTAssertEqual(prepared.runtimeBinding.endpointGeneration, fixture.generationNumber)
        XCTAssertEqual(prepared.runtimeBinding.providerRevision, fixture.providerRevision)
        XCTAssertEqual(prepared.runtimeBinding.readyLease, try fixture.readyLease)
        XCTAssertEqual(prepared.runtimeBinding.modelKey, fixture.modelKey)
        XCTAssertEqual(prepared.runtimeBinding.loadedInstanceID, fixture.loadedInstanceID)
        XCTAssertEqual(prepared.runtimeBinding.artifactObservation.modelRevision, fixture.modelRevision)
        XCTAssertEqual(
            prepared.evidenceBinding.protocolProbeCatalog,
            fixture.protocolProbeCatalog
        )
        XCTAssertEqual(prepared.evidenceBinding.liveCorpus, fixture.liveCorpus)
        XCTAssertEqual(prepared.evidenceBinding.qualificationPolicy, fixture.qualificationPolicy)
        XCTAssertEqual(prepared.evidenceBinding.environment, fixture.environmentIdentity)
        XCTAssertEqual(
            prepared.evidenceBinding.environment.id,
            "phase2.r1.qualification-environment.v2"
        )
        XCTAssertEqual(prepared.evidenceBinding.environment.version, 2)
        XCTAssertEqual(
            prepared.evidenceBinding.qualificationEnvironment,
            fixture.qualificationEnvironment
        )
        XCTAssertEqual(
            prepared.evidenceBinding.productionDefinition,
            Phase2ProductionQualificationPolicy.standard.definitionIdentity
        )
        XCTAssertEqual(
            Phase2ModelProfileMatcher().match(
                profile: prepared.profile,
                observedProvider: fixture.providerIdentity,
                observedSource: fixture.source,
                observedBackingDigest: fixture.backingDigest,
                model: fixture.observedModel,
                loadedConfiguration: fixture.loadedConfiguration
            ),
            .exact
        )
    }

    func testLoadedInstanceIDIsNeverInferredAndAmbiguityHasDistinctCode() throws {
        let fixture = try PreflightFixture()

        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(
                try fixture.input(explicitLoadedInstanceID: .some(nil))
            ),
            .rejected(.init(deficiencies: [.loadedInstanceIDMissing]))
        )

        let ambiguousFixture = try PreflightFixture(
            loadedInstanceIDs: ["instance-a", "instance-b"]
        )
        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(
                try ambiguousFixture.input(explicitLoadedInstanceID: .some(nil))
            ),
            .rejected(.init(deficiencies: [.loadedInstanceAmbiguous]))
        )
        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(
                try ambiguousFixture.input(explicitLoadedInstanceID: "instance-a")
            ),
            .rejected(.init(deficiencies: [.loadedInstanceAmbiguous]))
        )
    }

    func testAdvertisedContextMayExceedQualifiedContextAndExactObservationIsPreserved() throws {
        let fixture = try PreflightFixture(observedMaximumContextLength: 65_536)

        let result = Phase2LiveQualificationPreflight().evaluate(try fixture.input())

        guard case .prepared(let prepared) = result else {
            return XCTFail("Expected larger advertised context to remain eligible, got \(result)")
        }
        XCTAssertEqual(prepared.profile.context.maximumInputTokens, 32_768)
        XCTAssertEqual(prepared.runtimeBinding.advertisedMaximumContextLength, 65_536)
    }

    func testAdvertisedContextBelowQualifiedContextFailsClosed() throws {
        let fixture = try PreflightFixture(observedMaximumContextLength: 16_384)

        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(try fixture.input()),
            .rejected(.init(deficiencies: [.advertisedContextInsufficient]))
        )
    }

    func testMissingExactObservationsFailClosedWithSortedBoundedCodes() throws {
        let fixture = try PreflightFixture()
        let result = Phase2LiveQualificationPreflight().evaluate(
            try fixture.input(
                providerObservation: .some(nil),
                artifactObservation: .some(nil),
                contextObservation: .some(nil),
                generationObservation: .some(nil),
                hardwareObservation: .some(nil),
                manifestObservation: .some(nil),
                readToolRegistryObservation: .some(nil),
                qualificationPolicyObservation: .some(nil),
                protocolProbeCatalogObservation: .some(nil),
                liveCorpusObservation: .some(nil),
                environmentObservation: .some(nil)
            )
        )

        XCTAssertEqual(
            result,
            .rejected(.init(deficiencies: [
                .artifactObservationMissing,
                .contextObservationMissing,
                .environmentObservationMissing,
                .generationObservationMissing,
                .hardwareObservationMissing,
                .liveCorpusObservationMissing,
                .protocolManifestObservationMissing,
                .protocolProbeCatalogObservationMissing,
                .providerObservationMissing,
                .readToolRegistryObservationMissing,
                .qualificationPolicyObservationMissing,
            ]))
        )
    }

    func testEndpointProviderSelectionAndLeaseIdentityMismatchesFailClosed() throws {
        let fixture = try PreflightFixture()
        let otherProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let wrongProvider = Phase2EndpointBoundProviderObservation(
            endpointProfileID: otherProfileID,
            endpointGeneration: fixture.generationNumber + 1,
            providerRevision: fixture.providerRevision + 1,
            identity: try .init(
                family: "other-provider",
                build: "other-build",
                apiCompatibility: "other-api",
                endpointTransport: .loopbackHTTP
            ),
            runtimeIdentity: fixture.providerRuntimeIdentity
        )
        let wrongLease = Phase2ReadyInferenceLease(
            providerRevision: fixture.providerRevision + 1,
            configuration: try fixture.configuration,
            observedModelInventorySHA256: String(repeating: "a", count: 64)
        )

        let result = Phase2LiveQualificationPreflight().evaluate(
            try fixture.input(
                readyLease: wrongLease,
                providerObservation: wrongProvider
            )
        )

        XCTAssertEqual(
            result,
            .rejected(.init(deficiencies: [
                .providerAPICompatibilityMismatch,
                .providerBuildMismatch,
                .providerEndpointIdentityMismatch,
                .providerFamilyMismatch,
                .providerRevisionMismatch,
                .readyLeaseMismatch,
            ]))
        )
    }

    func testEveryReusableAndEvidenceDimensionRequiresExactEquality() throws {
        let fixture = try PreflightFixture()
        let otherComponent = try PreflightFixture.component(
            "phase2.r1.other.v1",
            version: 1,
            byte: "e"
        )
        let otherArtifact = Phase2LiveQualificationArtifactObservation(
            source: "other-source",
            backingDigest: try .sha256(String(repeating: "e", count: 64)),
            modelRevision: fixture.modelRevision
        )
        let otherContext = try Phase2ContextProfile(
            id: "different-context",
            version: 1,
            maximumInputTokens: 16_384,
            reservedOutputTokens: 4_096,
            maximumEvidenceBytes: 2_000_000,
            compactionThresholdTokens: 12_000
        )
        let otherGeneration = try Phase2GenerationProfile(
            id: "different-generation",
            version: 1,
            temperature: 0,
            topP: 0.9,
            seed: nil,
            stopSequences: [],
            reasoningOutputPolicy: .discard
        )
        let otherHardware = try Phase2HardwareTier(id: "other-hardware", version: 1)
        let otherManifest = try Phase2ModelProtocolManifest(
            promptModules: fixture.manifest.promptModules,
            finalOutputSchema: otherComponent,
            groundedContext: fixture.manifest.groundedContext,
            readToolRegistry: fixture.manifest.readToolRegistry,
            inferenceTransport: fixture.manifest.inferenceTransport,
            generationPolicy: fixture.manifest.generationPolicy,
            qualificationPolicy: fixture.manifest.qualificationPolicy,
            workflowAuthorityPolicy: fixture.manifest.workflowAuthorityPolicy
        )

        let result = Phase2LiveQualificationPreflight().evaluate(
            try fixture.input(
                artifactObservation: otherArtifact,
                contextObservation: otherContext,
                generationObservation: otherGeneration,
                hardwareObservation: otherHardware,
                manifestObservation: otherManifest,
                qualificationPolicyObservation: otherComponent,
                protocolProbeCatalogObservation: otherComponent,
                liveCorpusObservation: otherComponent,
                environmentObservation: PreflightFixture.environment(workerDigestByte: "e")
            )
        )

        XCTAssertEqual(
            result,
            .rejected(.init(deficiencies: [
                .artifactBackingDigestMismatch,
                .artifactSourceMismatch,
                .contextMismatch,
                .environmentMismatch,
                .generationMismatch,
                .hardwareMismatch,
                .liveCorpusMismatch,
                .protocolManifestMismatch,
                .protocolProbeCatalogMismatch,
                .qualificationPolicyMismatch,
            ]))
        )
    }

    func testWrongOrMissingExplicitInstanceAndConfigurationFailClosed() throws {
        let fixture = try PreflightFixture()
        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(
                try fixture.input(explicitLoadedInstanceID: "not-present")
            ),
            .rejected(.init(deficiencies: [.loadedInstanceMissing]))
        )

        let differentConfiguration = Phase2LocalModelInstanceConfiguration(
            effectiveContextLength: 32_768,
            evaluationBatchSize: 128,
            parallelPredictions: 1,
            flashAttention: true,
            expertCount: 8,
            offloadsKVCacheToGPU: true
        )
        let configurationFixture = try PreflightFixture(
            observedLoadedConfiguration: differentConfiguration
        )
        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(try configurationFixture.input()),
            .rejected(.init(deficiencies: [.loadedConfigurationMismatch]))
        )
    }

    func testClosedComponentNamesAndIncompleteManifestCannotPrepare() throws {
        let fixture = try PreflightFixture()
        let wrongPolicyName = try PreflightFixture.component(
            "phase2.r1.wrong-qualification-policy.v2",
            version: 2,
            byte: "a"
        )
        let unavailable = try Phase2ProtocolComponentIdentity.unavailable(
            id: "phase2.r1.final-output.v1",
            version: 1
        )
        let incompleteManifest = try Phase2ModelProtocolManifest(
            promptModules: fixture.manifest.promptModules,
            finalOutputSchema: unavailable,
            groundedContext: fixture.manifest.groundedContext,
            readToolRegistry: fixture.manifest.readToolRegistry,
            inferenceTransport: fixture.manifest.inferenceTransport,
            generationPolicy: fixture.manifest.generationPolicy,
            qualificationPolicy: fixture.manifest.qualificationPolicy,
            workflowAuthorityPolicy: fixture.manifest.workflowAuthorityPolicy
        )

        let badPolicyFixture = try PreflightFixture(qualificationPolicy: wrongPolicyName)
        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(try badPolicyFixture.input()),
            .rejected(.init(deficiencies: [.standardContractInvalid]))
        )

        let incompleteManifestFixture = try PreflightFixture(manifest: incompleteManifest)
        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(try incompleteManifestFixture.input()),
            .rejected(.init(deficiencies: [.standardContractInvalid]))
        )

        let wrongModelRevision = Phase2LiveQualificationArtifactObservation(
            source: fixture.source,
            backingDigest: fixture.backingDigest,
            modelRevision: try PreflightFixture.component(
                "phase2.r1.wrong-model-revision.v1", version: 1, byte: "e"
            )
        )
        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(
                try fixture.input(artifactObservation: wrongModelRevision)
            ),
            .rejected(.init(deficiencies: [
                .modelRevisionInvalid,
                .modelRevisionMismatch,
            ]))
        )
        let driftedModelRevision = Phase2LiveQualificationArtifactObservation(
            source: fixture.source,
            backingDigest: fixture.backingDigest,
            modelRevision: try PreflightFixture.component(
                "phase2.r1.qwen3-coder-30b-a3b-instruct-8bit.model-revision.v1",
                version: 1,
                byte: "e"
            )
        )
        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(
                try fixture.input(artifactObservation: driftedModelRevision)
            ),
            .rejected(.init(deficiencies: [.modelRevisionMismatch]))
        )
    }

    func testV2ManifestMustBindCanonicalPolicyAndBothPolicyCorpora() throws {
        let fixture = try PreflightFixture()
        let otherProbes = try PreflightFixture.component(
            "phase2.r1.protocol-probes.v1", version: 1, byte: "e"
        )
        let mismatchedManifest = try Phase2ModelProtocolManifest(
            version: 2,
            promptModules: fixture.manifest.promptModules,
            finalOutputSchema: fixture.manifest.finalOutputSchema,
            groundedContext: fixture.manifest.groundedContext,
            readToolRegistry: fixture.manifest.readToolRegistry,
            inferenceTransport: fixture.manifest.inferenceTransport,
            generationPolicy: fixture.manifest.generationPolicy,
            protocolProbeCatalog: otherProbes,
            liveQualificationCorpus: fixture.liveCorpus,
            qualificationPolicy: fixture.qualificationPolicy,
            workflowAuthorityPolicy: fixture.manifest.workflowAuthorityPolicy
        )
        let mismatchedFixture = try PreflightFixture(manifest: mismatchedManifest)

        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(try mismatchedFixture.input()),
            .rejected(.init(deficiencies: [.standardContractInvalid]))
        )
    }

    func testStandardContractRequiresCanonicalProductionDefinitionIdentity() throws {
        let substitute = try PreflightFixture.component(
            "phase2.r1.standard-qualification-definition.v1",
            version: 1,
            byte: "e"
        )
        let fixture = try PreflightFixture(productionDefinitionIdentity: substitute)

        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(try fixture.input()),
            .rejected(.init(deficiencies: [.standardContractInvalid]))
        )
    }

    func testProviderRuntimeBindingsAreFrozenAndContentAddressed() throws {
        let fixture = try PreflightFixture()

        let result = Phase2LiveQualificationPreflight().evaluate(try fixture.input())

        guard case .prepared(let prepared) = result else {
            return XCTFail("Expected prepared qualification, got \(result)")
        }
        XCTAssertEqual(
            prepared.runtimeBinding.providerRuntimeIdentity,
            fixture.providerRuntimeIdentity
        )
        XCTAssertEqual(
            [
                prepared.runtimeBinding.providerRuntimeIdentity.endpoint.id,
                prepared.runtimeBinding.providerRuntimeIdentity.processStart.id,
                prepared.runtimeBinding.providerRuntimeIdentity.executableBuild.id,
                prepared.runtimeBinding.providerRuntimeIdentity.apiProbe.id,
            ],
            [
                "phase2.r1.provider-endpoint.v1",
                "phase2.r1.provider-process-start.v1",
                "phase2.r1.provider-executable-build.v1",
                "phase2.r1.provider-api-probe.v1",
            ]
        )

        let wrong = try PreflightFixture.component(
            "phase2.r1.wrong-runtime-component.v1", version: 1, byte: "e"
        )
        let malformedRuntimeComponents: [(
            Phase2ProtocolComponentIdentity,
            Phase2ProtocolComponentIdentity,
            Phase2ProtocolComponentIdentity,
            Phase2ProtocolComponentIdentity
        )] = [
            (
                try PreflightFixture.component(
                    "phase2.r1.wrong-endpoint.v1", version: 1, byte: "e"
                ),
                fixture.providerRuntimeIdentity.processStart,
                fixture.providerRuntimeIdentity.executableBuild,
                fixture.providerRuntimeIdentity.apiProbe
            ),
            (
                fixture.providerRuntimeIdentity.endpoint,
                wrong,
                fixture.providerRuntimeIdentity.executableBuild,
                fixture.providerRuntimeIdentity.apiProbe
            ),
            (
                fixture.providerRuntimeIdentity.endpoint,
                fixture.providerRuntimeIdentity.processStart,
                wrong,
                fixture.providerRuntimeIdentity.apiProbe
            ),
            (
                fixture.providerRuntimeIdentity.endpoint,
                fixture.providerRuntimeIdentity.processStart,
                fixture.providerRuntimeIdentity.executableBuild,
                wrong
            ),
        ]
        for components in malformedRuntimeComponents {
            XCTAssertThrowsError(try Phase2EndpointBoundProviderRuntimeIdentity(
                endpoint: components.0,
                processStart: components.1,
                executableBuild: components.2,
                apiProbe: components.3
            ))
        }

        let missing = Phase2EndpointBoundProviderObservation(
            endpointProfileID: fixture.profileID,
            endpointGeneration: fixture.generationNumber,
            providerRevision: fixture.providerRevision,
            identity: fixture.providerIdentity,
            runtimeIdentity: nil
        )
        XCTAssertEqual(
            Phase2LiveQualificationPreflight().evaluate(
                try fixture.input(providerObservation: missing)
            ),
            .rejected(.init(deficiencies: [.providerRuntimeBindingMissing]))
        )
    }

    func testFreshObservationMatcherRejectsEveryRunCriticalDriftIndividually() throws {
        let fixture = try PreflightFixture()
        let prepared: Phase2PreparedLiveQualification
        switch Phase2LiveQualificationPreflight().evaluate(try fixture.input()) {
        case .prepared(let value): prepared = value
        case .rejected(let rejection):
            return XCTFail("Expected prepared fixture, got \(rejection)")
        }

        let matcher = Phase2LiveQualificationFreshObservationMatcher()
        XCTAssertTrue(matcher.compare(
            prepared: prepared,
            observation: try fixture.freshObservation()
        ).isCurrent)

        func assertOnly(
            _ expected: Phase2LiveQualificationFreshnessDeficiency,
            _ observation: Phase2LiveQualificationFreshObservation,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(
                matcher.compare(prepared: prepared, observation: observation).deficiencies,
                [expected],
                file: file,
                line: line
            )
        }

        assertOnly(
            .loadedInstanceMismatch,
            try fixture.freshObservation(explicitLoadedInstanceID: "other-instance")
        )
        assertOnly(
            .endpointIdentityMismatch,
            try fixture.freshObservation(providerObservation: fixture.providerObservation(
                endpointGeneration: fixture.generationNumber + 1
            ))
        )
        let providerRevisionObservation = Phase2EndpointBoundProviderObservation(
            endpointProfileID: fixture.profileID,
            endpointGeneration: fixture.generationNumber,
            providerRevision: fixture.providerRevision + 1,
            identity: fixture.providerIdentity,
            runtimeIdentity: fixture.providerRuntimeIdentity
        )
        assertOnly(
            .providerRevisionMismatch,
            try fixture.freshObservation(providerObservation: providerRevisionObservation)
        )
        let otherProviderObservation = Phase2EndpointBoundProviderObservation(
            endpointProfileID: fixture.profileID,
            endpointGeneration: fixture.generationNumber,
            providerRevision: fixture.providerRevision,
            identity: try .init(
                family: "other-provider",
                build: "other-build",
                apiCompatibility: "other-api",
                endpointTransport: .loopbackHTTP
            ),
            runtimeIdentity: fixture.providerRuntimeIdentity
        )
        assertOnly(
            .providerIdentityMismatch,
            try fixture.freshObservation(providerObservation: otherProviderObservation)
        )
        assertOnly(
            .readyLeaseMismatch,
            try fixture.freshObservation(readyLease: .init(
                providerRevision: fixture.providerRevision + 1,
                configuration: try fixture.configuration,
                observedModelInventorySHA256: String(repeating: "a", count: 64)
            ))
        )
        assertOnly(
            .providerProcessStartMismatch,
            try fixture.freshObservation(providerObservation: fixture.providerObservation(
                runtimeIdentity: try PreflightFixture.makeProviderRuntimeIdentity(
                    processStart: try PreflightFixture.component(
                        "phase2.r1.provider-process-start.v1", version: 1, byte: "e"
                    )
                )
            ))
        )
        assertOnly(
            .providerEndpointBindingMismatch,
            try fixture.freshObservation(providerObservation: fixture.providerObservation(
                runtimeIdentity: try PreflightFixture.makeProviderRuntimeIdentity(
                    endpoint: try PreflightFixture.component(
                        "phase2.r1.provider-endpoint.v1", version: 1, byte: "e"
                    )
                )
            ))
        )
        assertOnly(
            .providerExecutableBuildMismatch,
            try fixture.freshObservation(providerObservation: fixture.providerObservation(
                runtimeIdentity: try PreflightFixture.makeProviderRuntimeIdentity(
                    executableBuild: try PreflightFixture.component(
                        "phase2.r1.provider-executable-build.v1", version: 1, byte: "e"
                    )
                )
            ))
        )
        assertOnly(
            .providerAPIProbeMismatch,
            try fixture.freshObservation(providerObservation: fixture.providerObservation(
                runtimeIdentity: try PreflightFixture.makeProviderRuntimeIdentity(
                    apiProbe: try PreflightFixture.component(
                        "phase2.r1.provider-api-probe.v1", version: 1, byte: "e"
                    )
                )
            ))
        )
        assertOnly(
            .modelRevisionMismatch,
            try fixture.freshObservation(artifactObservation: fixture.artifactObservation(
                modelRevision: try PreflightFixture.component(
                    "phase2.r1.qwen3-coder-30b-a3b-instruct-8bit.model-revision.v1",
                    version: 1,
                    byte: "e"
                )
            ))
        )
        assertOnly(
            .modelArtifactMismatch,
            try fixture.freshObservation(artifactObservation: .init(
                source: "other-source",
                backingDigest: fixture.backingDigest,
                modelRevision: fixture.modelRevision
            ))
        )
        assertOnly(
            .generationMismatch,
            try fixture.freshObservation(generationObservation: Phase2GenerationProfile(
                id: "phase2-grounded-generation",
                version: 2,
                temperature: 0,
                topP: 1,
                seed: 7,
                stopSequences: [],
                reasoningOutputPolicy: .discard
            ))
        )
        assertOnly(
            .protocolManifestMismatch,
            try fixture.freshObservation(protocolManifestObservation: fixture.otherManifest)
        )
        let other = try PreflightFixture.component("phase2.r1.other.v1", version: 1, byte: "e")
        assertOnly(
            .readToolRegistryMismatch,
            try fixture.freshObservation(readToolRegistryObservation: other)
        )
        assertOnly(
            .qualificationPolicyMismatch,
            try fixture.freshObservation(qualificationPolicyObservation: other)
        )
        assertOnly(
            .protocolProbeCatalogMismatch,
            try fixture.freshObservation(protocolProbeCatalogObservation: other)
        )
        assertOnly(
            .liveCorpusMismatch,
            try fixture.freshObservation(liveCorpusObservation: other)
        )
        assertOnly(
            .productionDefinitionMismatch,
            try fixture.freshObservation(productionDefinitionObservation: try .init(
                id: "phase2.r1.standard-qualification-definition.v1",
                version: 1,
                sha256: String(repeating: "e", count: 64)
            ))
        )
        assertOnly(
            .environmentMismatch,
            try fixture.freshObservation(
                environmentObservation: PreflightFixture.environment(workerDigestByte: "e")
            )
        )
    }

    func testFreshObservationMatcherRevalidatesEachReusableProfileDimension() throws {
        let fixture = try PreflightFixture()
        guard case .prepared(let prepared) = Phase2LiveQualificationPreflight().evaluate(
            try fixture.input()
        ) else {
            return XCTFail("Expected prepared fixture")
        }
        let matcher = Phase2LiveQualificationFreshObservationMatcher()

        func assertExactly(
            _ expected: [Phase2LiveQualificationFreshnessDeficiency],
            _ observation: Phase2LiveQualificationFreshObservation,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(
                matcher.compare(prepared: prepared, observation: observation).deficiencies,
                expected,
                file: file,
                line: line
            )
        }

        func assertOnly(
            _ expected: Phase2LiveQualificationFreshnessDeficiency,
            _ observation: Phase2LiveQualificationFreshObservation,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            assertExactly([expected], observation, file: file, line: line)
        }

        assertExactly(
            [.modelTypeMismatch, .readyLeaseMismatch],
            try fixture.freshObservation(snapshot: fixture.snapshot(
                model: fixture.model(
                    type: .embedding,
                    format: .mlx,
                    quantization: fixture.quantization
                ),
                selectionModel: fixture.observedModel
            ))
        )
        assertExactly(
            [.modelKeyMismatch, .readyLeaseMismatch],
            try fixture.freshObservation(snapshot: fixture.snapshot(
                model: fixture.model(
                    type: .language,
                    format: .mlx,
                    quantization: fixture.quantization,
                    key: "other-model"
                ),
                selectionModel: fixture.observedModel
            ))
        )
        assertExactly(
            [.modelFormatMismatch, .readyLeaseMismatch],
            try fixture.freshObservation(snapshot: fixture.snapshot(model: fixture.model(
                type: .language,
                format: .gguf,
                quantization: fixture.quantization
            )))
        )
        assertExactly(
            [.modelQuantizationMismatch, .readyLeaseMismatch],
            try fixture.freshObservation(snapshot: fixture.snapshot(model: fixture.model(
                type: .language,
                format: .mlx,
                quantization: .init(name: "4bit", bitsPerWeight: 4)
            )))
        )
        let otherContext = try Phase2ContextProfile(
            id: "phase2-standard-32k",
            version: 1,
            maximumInputTokens: 32_768,
            reservedOutputTokens: 4_096,
            maximumEvidenceBytes: 1_999_999,
            compactionThresholdTokens: 24_000
        )
        assertOnly(
            .contextMismatch,
            try fixture.freshObservation(contextObservation: otherContext)
        )
        assertOnly(
            .hardwareTierMismatch,
            try fixture.freshObservation(hardwareObservation: .init(
                id: "other-hardware",
                version: 1
            ))
        )

        let differentConfiguration = Phase2LocalModelInstanceConfiguration(
            effectiveContextLength: 32_768,
            evaluationBatchSize: 128,
            parallelPredictions: 1,
            flashAttention: true,
            expertCount: 8,
            offloadsKVCacheToGPU: true
        )
        let configurationFixture = try PreflightFixture(
            observedLoadedConfiguration: differentConfiguration
        )
        assertExactly(
            [.loadedConfigurationMismatch, .readyLeaseMismatch],
            try fixture.freshObservation(snapshot: configurationFixture.snapshot)
        )
        let multiplicityFixture = try PreflightFixture(
            loadedInstanceIDs: ["instance-a", "instance-b"]
        )
        assertExactly(
            [.loadedInstanceMultiplicityMismatch, .readyLeaseMismatch],
            try fixture.freshObservation(snapshot: multiplicityFixture.snapshot)
        )
        let advertisedContextFixture = try PreflightFixture(
            observedMaximumContextLength: 65_536
        )
        assertExactly(
            [.advertisedContextMismatch, .readyLeaseMismatch],
            try fixture.freshObservation(snapshot: advertisedContextFixture.snapshot)
        )
    }

    func testProductionEnvironmentRequiresXcodeAndSDK27MacOS27OrNewerAndArm64() throws {
        let flexibleBuildEnvironment = try PreflightFixture.environment(
            xcodeBuild: "27Z999",
            sdkBuild: "27Z998",
            operatingSystemVersion: "28.0",
            operatingSystemBuild: "28Z997"
        )
        let flexibleFixture = try PreflightFixture(
            qualificationEnvironment: flexibleBuildEnvironment
        )
        guard case .prepared = Phase2LiveQualificationPreflight().evaluate(
            try flexibleFixture.input()
        ) else {
            return XCTFail("Build suffixes and newer macOS builds must remain eligible")
        }

        let rejectedEnvironments = [
            try PreflightFixture.environment(xcodeVersion: "26.4"),
            try PreflightFixture.environment(sdkVersion: "26.0"),
            try PreflightFixture.environment(operatingSystemVersion: "26.6"),
            try PreflightFixture.environment(architecture: "x86_64"),
        ]
        for environment in rejectedEnvironments {
            let fixture = try PreflightFixture(qualificationEnvironment: environment)
            XCTAssertEqual(
                Phase2LiveQualificationPreflight().evaluate(try fixture.input()),
                .rejected(.init(deficiencies: [.standardContractInvalid]))
            )
        }
    }

    func testFreshObservationMatcherRejectsEachTypedEnvironmentDrift() throws {
        let fixture = try PreflightFixture()
        guard case .prepared(let prepared) = Phase2LiveQualificationPreflight().evaluate(
            try fixture.input()
        ) else {
            return XCTFail("Expected prepared fixture")
        }
        let matcher = Phase2LiveQualificationFreshObservationMatcher()
        let drifts = [
            try PreflightFixture.environment(xcodeVersion: "27.1"),
            try PreflightFixture.environment(swiftCompilerVersion: "6.4.1"),
            try PreflightFixture.environment(sdkVersion: "27.1"),
            try PreflightFixture.environment(operatingSystemVersion: "27.1"),
            try PreflightFixture.environment(architecture: "arm64e"),
        ]
        for environment in drifts {
            XCTAssertEqual(
                matcher.compare(
                    prepared: prepared,
                    observation: try fixture.freshObservation(
                        environmentObservation: environment
                    )
                ).deficiencies,
                [.environmentMismatch]
            )
        }
    }
}

private struct PreflightFixture {
    let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
    let generationNumber: UInt64 = 7
    let providerRevision: UInt64 = 41
    let selector: Phase2QualificationProfileSelector
    let modelKey: String
    let source: String
    let loadedInstanceID: String
    let loadedInstanceIDs: [String]
    let loadedConfiguration: Phase2LocalModelInstanceConfiguration
    let observedLoadedConfiguration: Phase2LocalModelInstanceConfiguration
    let observedMaximumContextLength: Int
    let quantization: Phase2LocalModelQuantization
    let providerIdentity: Phase2QualifiedProviderIdentity
    let providerRuntimeIdentity: Phase2EndpointBoundProviderRuntimeIdentity
    let backingDigest: Phase2ModelBackingDigest
    let modelRevision: Phase2ProtocolComponentIdentity
    let context: Phase2ContextProfile
    let generation: Phase2GenerationProfile
    let hardwareTier: Phase2HardwareTier
    let manifest: Phase2ModelProtocolManifest
    let productionDefinitionIdentity: Phase2ProtocolComponentIdentity
    let qualificationPolicyDefinition: Phase2ModelQualificationPolicy
    let qualificationPolicy: Phase2ProtocolComponentIdentity
    let protocolProbeCatalog: Phase2ProtocolComponentIdentity
    let liveCorpus: Phase2ProtocolComponentIdentity
    let qualificationEnvironment: Phase2QualificationEnvironmentV2
    let environmentIdentity: Phase2ProtocolComponentIdentity

    init(
        selector: Phase2QualificationProfileSelector = .historicalF4C,
        loadedInstanceIDs: [String] = ["instance-a"],
        observedLoadedConfiguration: Phase2LocalModelInstanceConfiguration? = nil,
        observedMaximumContextLength: Int? = nil,
        qualificationPolicy: Phase2ProtocolComponentIdentity? = nil,
        manifest: Phase2ModelProtocolManifest? = nil,
        qualificationEnvironment: Phase2QualificationEnvironmentV2? = nil,
        productionDefinitionIdentity: Phase2ProtocolComponentIdentity? = nil
    ) throws {
        self.selector = selector
        let candidate = selector == .qwen38V2Q6K
        modelKey = candidate ? "qwen3.8-27b-obliterated" : "qwen3-coder-30b-a3b-instruct"
        source = candidate ? "OBLITERATUS/Qwen3.8-27B-OBLITERATED" : "mlx-community"
        quantization = .init(name: candidate ? "Q6_K" : "8bit", bitsPerWeight: candidate ? nil : 8)
        self.loadedInstanceIDs = loadedInstanceIDs
        loadedInstanceID = loadedInstanceIDs.first ?? "instance-a"
        loadedConfiguration = .init(
            effectiveContextLength: 32_768,
            evaluationBatchSize: 256,
            parallelPredictions: 1,
            flashAttention: true,
            expertCount: 8,
            offloadsKVCacheToGPU: true
        )
        self.observedLoadedConfiguration = observedLoadedConfiguration ?? loadedConfiguration
        self.observedMaximumContextLength = observedMaximumContextLength ?? (candidate ? 262_144 : 32_768)
        providerIdentity = try .init(
            family: "lm-studio",
            build: "0.4.19+2",
            apiCompatibility: "openai-chat-completions-v1",
            endpointTransport: .loopbackHTTP
        )
        providerRuntimeIdentity = try Self.makeProviderRuntimeIdentity()
        backingDigest = try .sha256(
            candidate ? "d4ab1fe8f27e4f6c8544198d5971f43e6c98801d5b2a24654ab2c1bdb9c4c717"
                : "49060c25bb8c4f63ef7471796832dc9e7c12b63e553472907ae27f05c7596ace"
        )
        let production = Phase2QualificationProfileContract.resolve(selector).production
        self.productionDefinitionIdentity = productionDefinitionIdentity
            ?? production.definitionIdentity
        modelRevision = production.modelRevision.identity
        context = try .init(
            id: "phase2-standard-32k",
            version: 1,
            maximumInputTokens: 32_768,
            reservedOutputTokens: 4_096,
            maximumEvidenceBytes: 2_000_000,
            compactionThresholdTokens: 24_000
        )
        generation = try .init(
            id: "phase2-grounded-generation",
            version: 2,
            temperature: 0,
            topP: 1,
            seed: nil,
            stopSequences: [],
            reasoningOutputPolicy: .discard
        )
        hardwareTier = try .init(id: "apple-m1-max-64gb", version: 1)
        let frozenProtocolProbeCatalog = production.protocolProbeCatalogIdentity
        protocolProbeCatalog = frozenProtocolProbeCatalog
        let frozenLiveCorpus = production.liveScenarioCatalog.identity
        liveCorpus = frozenLiveCorpus
        let frozenPolicyDefinition = production.policy
        qualificationPolicyDefinition = frozenPolicyDefinition
        let canonicalPolicy = production.policyIdentity
        let frozenPolicy = qualificationPolicy ?? canonicalPolicy
        self.qualificationPolicy = frozenPolicy
        let frozenEnvironment = try qualificationEnvironment ?? Self.environment()
        self.qualificationEnvironment = frozenEnvironment
        environmentIdentity = try frozenEnvironment.contentIdentity()
        if let manifest {
            self.manifest = manifest
        } else {
            let productionManifest = Phase2ModelProtocolManifest.productionGroundedReadOnly
            self.manifest = try .init(
                version: 2,
                promptModules: productionManifest.promptModules,
                finalOutputSchema: productionManifest.finalOutputSchema,
                groundedContext: productionManifest.groundedContext,
                readToolRegistry: productionManifest.readToolRegistry,
                inferenceTransport: productionManifest.inferenceTransport,
                generationPolicy: productionManifest.generationPolicy,
                protocolProbeCatalog: frozenProtocolProbeCatalog,
                liveQualificationCorpus: frozenLiveCorpus,
                qualificationPolicy: frozenPolicy,
                workflowAuthorityPolicy: productionManifest.workflowAuthorityPolicy
            )
        }
    }

    var artifactIdentity: Phase2ModelArtifactIdentity {
        get throws {
            try .init(
                modelKey: modelKey,
                source: source,
                type: .language,
                format: selector == .qwen38V2Q6K ? .gguf : .mlx,
                quantizationName: selector == .qwen38V2Q6K ? "Q6_K" : "8bit",
                bitsPerWeight: quantization.bitsPerWeight,
                backingDigest: backingDigest
            )
        }
    }

    var otherManifest: Phase2ModelProtocolManifest {
        get throws {
            try .init(
                promptModules: manifest.promptModules,
                finalOutputSchema: Self.component(
                    "phase2.r1.other-final-output.v1", version: 1, byte: "e"
                ),
                groundedContext: manifest.groundedContext,
                readToolRegistry: manifest.readToolRegistry,
                inferenceTransport: manifest.inferenceTransport,
                generationPolicy: manifest.generationPolicy,
                qualificationPolicy: manifest.qualificationPolicy,
                workflowAuthorityPolicy: manifest.workflowAuthorityPolicy
            )
        }
    }

    func providerObservation(
        endpointGeneration: UInt64? = nil,
        runtimeIdentity: Phase2EndpointBoundProviderRuntimeIdentity? = nil
    ) -> Phase2EndpointBoundProviderObservation {
        .init(
            endpointProfileID: profileID,
            endpointGeneration: endpointGeneration ?? generationNumber,
            providerRevision: providerRevision,
            identity: providerIdentity,
            runtimeIdentity: runtimeIdentity ?? providerRuntimeIdentity
        )
    }

    func artifactObservation(
        modelRevision: Phase2ProtocolComponentIdentity? = nil
    ) -> Phase2LiveQualificationArtifactObservation {
        .init(
            source: source,
            backingDigest: backingDigest,
            modelRevision: modelRevision ?? self.modelRevision
        )
    }

    var endpoint: Phase2LocalProviderEndpoint {
        get throws {
            try .init(
                profileID: profileID,
                generation: generationNumber,
                endpointOrigin: "http://127.0.0.1:1234",
                requestTimeoutMilliseconds: 10_000,
                resourceTimeoutMilliseconds: 30_000
            )
        }
    }

    var observedModel: Phase2LocalModelDescriptor {
        model(
            type: .language,
            format: selector == .qwen38V2Q6K ? .gguf : .mlx,
            quantization: quantization
        )
    }

    func model(
        type: Phase2LocalModelType,
        format: Phase2LocalModelFormat?,
        quantization: Phase2LocalModelQuantization?,
        key: String? = nil
    ) -> Phase2LocalModelDescriptor {
        .init(
            type: type,
            publisher: selector == .qwen38V2Q6K ? "OBLITERATUS" : "Qwen",
            key: key ?? modelKey,
            displayName: "Qwen3 Coder 30B A3B",
            architecture: "qwen3moe",
            quantization: quantization,
            sizeBytesOnDisk: selector == .qwen38V2Q6K ? 22_431_004_152 : 32_456_771_170,
            parameterCountDescription: "30B-A3B",
            maximumContextLength: observedMaximumContextLength,
            format: format,
            capabilities: .init(
                supportsVision: false,
                trainedForToolUse: true,
                reasoning: nil
            ),
            variants: [],
            providerSelectedVariant: nil,
            loadedInstances: loadedInstanceIDs.map {
                .init(id: $0, configuration: observedLoadedConfiguration)
            }
        )
    }

    var inventory: Phase2LocalModelInventory {
        get throws {
            try inventory(model: observedModel)
        }
    }

    func inventory(model: Phase2LocalModelDescriptor) throws -> Phase2LocalModelInventory {
        try .init(
            profileID: profileID,
            generation: generationNumber,
            models: [model]
        )
    }

    var selection: Phase2LocalAISelection {
        get throws {
            try selection(model: observedModel)
        }
    }

    func selection(model: Phase2LocalModelDescriptor) throws -> Phase2LocalAISelection {
            try .authorize(
                endpoint: endpoint,
                inventory: inventory(model: model),
                modelKey: modelKey,
                maximumTokens: 4_096
            )
    }

    var snapshot: Phase2LocalAIProviderSnapshot {
        get throws {
            try snapshot(model: observedModel)
        }
    }

    func snapshot(
        model: Phase2LocalModelDescriptor,
        selectionModel: Phase2LocalModelDescriptor? = nil
    ) throws -> Phase2LocalAIProviderSnapshot {
            .init(
                endpoint: try endpoint,
                observation: .accepted(try inventory(model: model)),
                selection: try selection(model: selectionModel ?? model),
                activity: .idle,
                revision: providerRevision
            )
    }

    var configuration: Phase2AIProviderConfiguration {
        get throws { try selection.configuration }
    }

    var readyLease: Phase2ReadyInferenceLease {
        get throws { try XCTUnwrap(snapshot.readyInferenceLease) }
    }

    var authoritativeProfileObservation: Phase2StandardModelProfileObservation {
        get throws { try authoritativeProfileObservation(model: observedModel) }
    }

    func authoritativeProfileObservation(
        model: Phase2LocalModelDescriptor
    ) throws -> Phase2StandardModelProfileObservation {
        .init(
            profileVersion: 2,
            provider: providerIdentity,
            model: model,
            source: source,
            backingDigest: backingDigest,
            loadedConfiguration: loadedConfiguration,
            context: context,
            generation: generation,
            hardwareTier: hardwareTier,
            workflow: .groundedReadOnly,
            authorityCeiling: .groundedReadOnly,
            toolCallMode: .requiredReadOnly,
            structuredOutputMode: .jsonSchema,
            protocolManifest: manifest
        )
    }

    var definition: Phase2StandardModelProfileDefinition {
        get throws {
            .init(
                productionDefinitionIdentity: productionDefinitionIdentity,
                profileVersion: 2,
                provider: providerIdentity,
                artifact: try artifactIdentity,
                modelRevisionIdentity: modelRevision,
                advertisedMaximumContextLength: selector == .qwen38V2Q6K ? 262_144 : 32_768,
                loadedConfiguration: loadedConfiguration,
                context: context,
                generation: generation,
                hardwareTier: hardwareTier,
                workflow: .groundedReadOnly,
                authorityCeiling: .groundedReadOnly,
                toolCallMode: .requiredReadOnly,
                structuredOutputMode: .jsonSchema,
                protocolManifest: manifest,
                qualificationPolicy: qualificationPolicyDefinition,
                inferenceMaximumTokens: 4_096,
                protocolProbeCatalogIdentity: protocolProbeCatalog,
                liveCorpusIdentity: liveCorpus,
                qualificationEnvironment: qualificationEnvironment
            )
        }
    }

    func input(
        explicitLoadedInstanceID: String?? = nil,
        readyLease: Phase2ReadyInferenceLease?? = nil,
        providerObservation: Phase2EndpointBoundProviderObservation?? = nil,
        artifactObservation: Phase2LiveQualificationArtifactObservation?? = nil,
        contextObservation: Phase2ContextProfile?? = nil,
        generationObservation: Phase2GenerationProfile?? = nil,
        hardwareObservation: Phase2HardwareTier?? = nil,
        manifestObservation: Phase2ModelProtocolManifest?? = nil,
        readToolRegistryObservation: Phase2ProtocolComponentIdentity?? = nil,
        qualificationPolicyObservation: Phase2ProtocolComponentIdentity?? = nil,
        protocolProbeCatalogObservation: Phase2ProtocolComponentIdentity?? = nil,
        liveCorpusObservation: Phase2ProtocolComponentIdentity?? = nil,
        environmentObservation: Phase2QualificationEnvironmentV2?? = nil
    ) throws -> Phase2LiveQualificationPreflightInput {
        try .init(
            standard: definition,
            snapshot: snapshot,
            readyLease: readyLease ?? .some(self.readyLease),
            explicitLoadedInstanceID: explicitLoadedInstanceID ?? .some(loadedInstanceID),
            providerObservation: providerObservation ?? .some(.init(
                endpointProfileID: profileID,
                endpointGeneration: generationNumber,
                providerRevision: providerRevision,
                identity: providerIdentity,
                runtimeIdentity: providerRuntimeIdentity
            )),
            artifactObservation: artifactObservation ?? .some(.init(
                source: source,
                backingDigest: backingDigest,
                modelRevision: modelRevision
            )),
            contextObservation: contextObservation ?? .some(context),
            generationObservation: generationObservation ?? .some(generation),
            hardwareObservation: hardwareObservation ?? .some(hardwareTier),
            protocolManifestObservation: manifestObservation ?? .some(manifest),
            readToolRegistryObservation: readToolRegistryObservation
                ?? .some(manifest.readToolRegistry),
            qualificationPolicyObservation: qualificationPolicyObservation
                ?? .some(qualificationPolicy),
            protocolProbeCatalogObservation: protocolProbeCatalogObservation
                ?? .some(protocolProbeCatalog),
            liveCorpusObservation: liveCorpusObservation ?? .some(liveCorpus),
            environmentObservation: environmentObservation ?? .some(qualificationEnvironment)
        )
    }

    func freshObservation(
        snapshot: Phase2LocalAIProviderSnapshot? = nil,
        readyLease: Phase2ReadyInferenceLease? = nil,
        explicitLoadedInstanceID: String? = nil,
        providerObservation: Phase2EndpointBoundProviderObservation? = nil,
        artifactObservation: Phase2LiveQualificationArtifactObservation? = nil,
        contextObservation: Phase2ContextProfile? = nil,
        generationObservation: Phase2GenerationProfile? = nil,
        hardwareObservation: Phase2HardwareTier? = nil,
        productionDefinitionObservation: Phase2ProtocolComponentIdentity? = nil,
        protocolManifestObservation: Phase2ModelProtocolManifest? = nil,
        readToolRegistryObservation: Phase2ProtocolComponentIdentity? = nil,
        qualificationPolicyObservation: Phase2ProtocolComponentIdentity? = nil,
        protocolProbeCatalogObservation: Phase2ProtocolComponentIdentity? = nil,
        liveCorpusObservation: Phase2ProtocolComponentIdentity? = nil,
        environmentObservation: Phase2QualificationEnvironmentV2? = nil
    ) throws -> Phase2LiveQualificationFreshObservation {
        .init(
            snapshot: try snapshot ?? self.snapshot,
            readyLease: try readyLease ?? self.readyLease,
            explicitLoadedInstanceID: explicitLoadedInstanceID ?? loadedInstanceID,
            providerObservation: providerObservation ?? self.providerObservation(),
            artifactObservation: artifactObservation ?? self.artifactObservation(),
            contextObservation: contextObservation ?? context,
            generationObservation: generationObservation ?? generation,
            hardwareObservation: hardwareObservation ?? hardwareTier,
            productionDefinitionObservation: productionDefinitionObservation
                ?? productionDefinitionIdentity,
            protocolManifestObservation: protocolManifestObservation ?? manifest,
            readToolRegistryObservation: readToolRegistryObservation ?? manifest.readToolRegistry,
            qualificationPolicyObservation: qualificationPolicyObservation ?? qualificationPolicy,
            protocolProbeCatalogObservation: protocolProbeCatalogObservation ?? protocolProbeCatalog,
            liveCorpusObservation: liveCorpusObservation ?? liveCorpus,
            environmentObservation: environmentObservation ?? qualificationEnvironment
        )
    }

    static func environment(
        workerDigestByte: Character = "b",
        xcodeVersion: String = "27.0",
        xcodeBuild: String = "27A5218g",
        swiftCompilerVersion: String = "6.4",
        sdkVersion: String = "27.0",
        sdkBuild: String = "26A5378i",
        operatingSystemVersion: String = "27.0",
        operatingSystemBuild: String = "26A5378n",
        architecture: String = "arm64"
    ) throws -> Phase2QualificationEnvironmentV2 {
        try .init(
            bundleShortVersion: "0.1.0",
            bundleVersion: "1",
            macScopeCommit: String(repeating: "1", count: 40),
            appExecutableDigest: String(repeating: "a", count: 64),
            workerExecutableDigest: String(repeating: workerDigestByte, count: 64),
            signingRequirementDigest: String(repeating: "c", count: 64),
            xcodeVersion: xcodeVersion,
            xcodeBuild: xcodeBuild,
            swiftCompilerVersion: swiftCompilerVersion,
            sdkVersion: sdkVersion,
            sdkBuild: sdkBuild,
            operatingSystemVersion: operatingSystemVersion,
            operatingSystemBuild: operatingSystemBuild,
            architecture: architecture,
            hardwareModel: "MacBookPro18,2",
            processorFamily: "Apple M1 Max",
            physicalMemoryBytes: 68_719_476_736,
            physicalCoreCount: 10,
            logicalCoreCount: 10,
            performanceCoreCount: 8,
            efficiencyCoreCount: 2
        )
    }

    static func makeProviderRuntimeIdentity(
        endpoint: Phase2ProtocolComponentIdentity? = nil,
        processStart: Phase2ProtocolComponentIdentity? = nil,
        executableBuild: Phase2ProtocolComponentIdentity? = nil,
        apiProbe: Phase2ProtocolComponentIdentity? = nil
    ) throws -> Phase2EndpointBoundProviderRuntimeIdentity {
        try .init(
            endpoint: endpoint ?? component(
                "phase2.r1.provider-endpoint.v1", version: 1, byte: "1"
            ),
            processStart: processStart ?? component(
                "phase2.r1.provider-process-start.v1", version: 1, byte: "2"
            ),
            executableBuild: executableBuild ?? component(
                "phase2.r1.provider-executable-build.v1", version: 1, byte: "3"
            ),
            apiProbe: apiProbe ?? component(
                "phase2.r1.provider-api-probe.v1", version: 1, byte: "4"
            )
        )
    }

    static func component(
        _ id: String,
        version: Int,
        byte: Character
    ) throws -> Phase2ProtocolComponentIdentity {
        try .init(id: id, version: version, sha256: String(repeating: byte, count: 64))
    }
}
