import Foundation
import XCTest
@testable import MacScope

final class Phase2ModelProfileTests: XCTestCase {
    func testLengthFramedEncoderHasFrozenOwnedWireFormatAndUTF8KeyOrder() throws {
        let object: [String: Any] = [
            "\u{00E9}": "value",
            "z": 1,
            "a": true,
        ]

        let bytes = try Phase2LengthFramedCanonicalEncoder().encode(object)

        XCTAssertEqual(
            String(decoding: bytes, as: UTF8.self),
            "o29:s1:ab1:1s1:zi1:1s2:\u{00E9}s5:value"
        )
        XCTAssertFalse(bytes.starts(with: Data("{".utf8)))
    }

    func testLengthFramedEncoderCoversUsedContainersAndRejectsUnsupportedValues() throws {
        let encoder = Phase2LengthFramedCanonicalEncoder()
        let supported: [String: Any] = [
            "array": [NSNull(), false, -12, "slash/value"],
            "object": ["empty": ""],
        ]

        XCTAssertEqual(
            try encoder.encode(supported),
            try encoder.encode(supported)
        )
        XCTAssertThrowsError(try encoder.encode(["unsupported": 1.5])) { error in
            XCTAssertEqual(
                error as? Phase2LengthFramedCanonicalEncoder.Error,
                .unsupportedValue
            )
        }
    }

    func testCanonicalProfileIdentityIsStableAndBindsEverySupportDimension() throws {
        let profile = try makeProfile()
        let canonicalizer = Phase2ModelProfileCanonicalizer()

        let firstBytes = try canonicalizer.canonicalBytes(for: profile)
        let secondBytes = try canonicalizer.canonicalBytes(for: profile)
        let firstID = try canonicalizer.stableID(for: profile)

        XCTAssertEqual(firstBytes, secondBytes)
        XCTAssertTrue(firstBytes.starts(with: Data("o".utf8)))
        XCTAssertFalse(firstBytes.starts(with: Data("{".utf8)))
        XCTAssertEqual(firstID, try canonicalizer.stableID(for: profile))
        XCTAssertTrue(firstID.rawValue.hasPrefix("sha256:"))

        let changed = try makeProfile(
            generation: .init(
                id: "grounded-finalization",
                version: 1,
                temperature: 0,
                topP: 0.95,
                seed: 7,
                stopSequences: [],
                reasoningOutputPolicy: .discard
            )
        )
        XCTAssertNotEqual(firstID, try canonicalizer.stableID(for: changed))
    }

    func testEachMajorSupportDimensionChangesStableIdentity() throws {
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let baseline = try makeProfile()
        let baselineID = try canonicalizer.stableID(for: baseline)
        let changedProvider = try Phase2QualifiedProviderIdentity(
            family: baseline.provider.family,
            build: "provider-build-2",
            apiCompatibility: baseline.provider.apiCompatibility,
            endpointTransport: baseline.provider.endpointTransport
        )
        let changedArtifact = try Phase2ModelArtifactIdentity(
            modelKey: "publisher/other-model@q4_k_m",
            source: baseline.artifact.source,
            type: baseline.artifact.type,
            format: baseline.artifact.format,
            quantizationName: baseline.artifact.quantizationName,
            bitsPerWeight: baseline.artifact.bitsPerWeight,
            backingDigest: baseline.artifact.backingDigest
        )
        let changedLoad = Phase2LocalModelInstanceConfiguration(
            effectiveContextLength: 32_768,
            evaluationBatchSize: 256,
            parallelPredictions: 1,
            flashAttention: true,
            expertCount: 8,
            offloadsKVCacheToGPU: true
        )
        let changedContext = try Phase2ContextProfile(
            id: "compact-function-review",
            version: 1,
            maximumInputTokens: 16_384,
            reservedOutputTokens: 2_048,
            maximumEvidenceBytes: 1_000_000,
            compactionThresholdTokens: 12_000
        )
        let changedHardware = try Phase2HardwareTier(id: "apple-silicon-high-memory", version: 1)
        let changedManifest = try Phase2ModelProtocolManifest(
            promptModules: baseline.protocolManifest.promptModules,
            finalOutputSchema: protocolIdentity("grounded-final-output", version: 2, byte: "f"),
            groundedContext: baseline.protocolManifest.groundedContext,
            readToolRegistry: baseline.protocolManifest.readToolRegistry,
            inferenceTransport: baseline.protocolManifest.inferenceTransport,
            generationPolicy: baseline.protocolManifest.generationPolicy,
            qualificationPolicy: baseline.protocolManifest.qualificationPolicy,
            workflowAuthorityPolicy: baseline.protocolManifest.workflowAuthorityPolicy
        )

        let variants = [
            try makeProfile(provider: changedProvider),
            try makeProfile(artifact: changedArtifact),
            try makeProfile(loadedConfiguration: changedLoad),
            try makeProfile(context: changedContext),
            try makeProfile(hardwareTier: changedHardware),
            try makeProfile(protocolManifest: changedManifest),
            try makeProfile(toolCallMode: .disabled),
            try makeProfile(structuredOutputMode: .disabled),
        ]
        for variant in variants {
            XCTAssertNotEqual(baselineID, try canonicalizer.stableID(for: variant))
        }
        XCTAssertEqual(Set(try variants.map(canonicalizer.stableID)).count, variants.count)
    }

    func testArtifactIdentityAcceptsAndBindsExactRepositorySource() throws {
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let baseline = try makeProfile()
        let exactSource = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit"
        let artifact = try Phase2ModelArtifactIdentity(
            modelKey: baseline.artifact.modelKey,
            source: exactSource,
            type: baseline.artifact.type,
            format: baseline.artifact.format,
            quantizationName: baseline.artifact.quantizationName,
            bitsPerWeight: baseline.artifact.bitsPerWeight,
            backingDigest: baseline.artifact.backingDigest
        )
        let exact = try makeProfile(artifact: artifact)

        XCTAssertEqual(exact.artifact.source, exactSource)
        XCTAssertNotEqual(
            try canonicalizer.stableID(for: exact),
            try canonicalizer.stableID(for: baseline)
        )
        for source in [
            "/Users/private",
            "publisher/model with space",
            "publisher//model",
            "publisher/../model",
        ] {
            XCTAssertThrowsError(try Phase2ModelArtifactIdentity(
                modelKey: baseline.artifact.modelKey,
                source: source,
                type: baseline.artifact.type,
                format: baseline.artifact.format,
                quantizationName: baseline.artifact.quantizationName,
                bitsPerWeight: baseline.artifact.bitsPerWeight,
                backingDigest: baseline.artifact.backingDigest
            ))
        }
    }

    func testCanonicalProfilePreservesSemanticStopAndPromptOrder() throws {
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let first = try makeProfile(
            generation: .init(
                id: "grounded-finalization",
                version: 1,
                temperature: 0,
                topP: 1,
                seed: 7,
                stopSequences: ["<END>", "<STOP>"],
                reasoningOutputPolicy: .discard
            )
        )
        let reorderedStops = try makeProfile(
            generation: .init(
                id: "grounded-finalization",
                version: 1,
                temperature: 0,
                topP: 1,
                seed: 7,
                stopSequences: ["<STOP>", "<END>"],
                reasoningOutputPolicy: .discard
            )
        )
        XCTAssertNotEqual(
            try canonicalizer.stableID(for: first),
            try canonicalizer.stableID(for: reorderedStops)
        )

        let reversedModules = try makeProfile(
            promptModules: Array(first.protocolManifest.promptModules.reversed())
        )
        XCTAssertNotEqual(
            try canonicalizer.stableID(for: first),
            try canonicalizer.stableID(for: reversedModules)
        )
    }

    func testV2ManifestSeparatelyBindsProtocolProbesLiveCorpusAndQualificationPolicy() throws {
        let baseline = try makeProfile()
        let protocolProbes = protocolIdentity("protocol-probes", version: 1, byte: "c")
        let liveCorpus = protocolIdentity("live-qualification-corpus", version: 1, byte: "d")
        let qualificationPolicy = protocolIdentity("qualification-policy", version: 2, byte: "a")
        let manifest = try Phase2ModelProtocolManifest(
            version: 2,
            promptModules: baseline.protocolManifest.promptModules,
            finalOutputSchema: baseline.protocolManifest.finalOutputSchema,
            groundedContext: baseline.protocolManifest.groundedContext,
            readToolRegistry: baseline.protocolManifest.readToolRegistry,
            inferenceTransport: baseline.protocolManifest.inferenceTransport,
            generationPolicy: baseline.protocolManifest.generationPolicy,
            protocolProbeCatalog: protocolProbes,
            liveQualificationCorpus: liveCorpus,
            qualificationPolicy: qualificationPolicy,
            workflowAuthorityPolicy: baseline.protocolManifest.workflowAuthorityPolicy
        )
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let baselineDigest = canonicalizer.protocolManifestDigest(for: manifest)

        let variants = [
            try replacingV2Manifest(
                manifest,
                protocolProbeCatalog: protocolIdentity("protocol-probes", version: 1, byte: "e")
            ),
            try replacingV2Manifest(
                manifest,
                liveQualificationCorpus: protocolIdentity(
                    "live-qualification-corpus",
                    version: 1,
                    byte: "e"
                )
            ),
            try replacingV2Manifest(
                manifest,
                qualificationPolicy: protocolIdentity(
                    "qualification-policy",
                    version: 2,
                    byte: "e"
                )
            ),
        ]

        XCTAssertEqual(manifest.version, 2)
        XCTAssertEqual(manifest.protocolProbeCatalog, protocolProbes)
        XCTAssertEqual(manifest.liveQualificationCorpus, liveCorpus)
        XCTAssertTrue(manifest.isCertificationEligible)
        for variant in variants {
            XCTAssertNotEqual(
                baselineDigest,
                canonicalizer.protocolManifestDigest(for: variant)
            )
        }
    }

    func testLegacyManifestInitializerRemainsV1AndDoesNotInventV2CorpusBindings() throws {
        let manifest = try makeProfile().protocolManifest

        XCTAssertEqual(manifest.version, 1)
        XCTAssertNil(manifest.protocolProbeCatalog)
        XCTAssertNil(manifest.liveQualificationCorpus)
    }

    func testV2ManifestRejectsLegacyQualificationPolicyIdentity() throws {
        let baseline = try makeProfile().protocolManifest

        XCTAssertThrowsError(try Phase2ModelProtocolManifest(
            version: 2,
            promptModules: baseline.promptModules,
            finalOutputSchema: baseline.finalOutputSchema,
            groundedContext: baseline.groundedContext,
            readToolRegistry: baseline.readToolRegistry,
            inferenceTransport: baseline.inferenceTransport,
            generationPolicy: baseline.generationPolicy,
            protocolProbeCatalog: protocolIdentity("protocol-probes", version: 1, byte: "c"),
            liveQualificationCorpus: protocolIdentity(
                "live-qualification-corpus",
                version: 1,
                byte: "d"
            ),
            qualificationPolicy: protocolIdentity(
                "qualification-policy",
                version: 1,
                byte: "e"
            ),
            workflowAuthorityPolicy: baseline.workflowAuthorityPolicy
        ))
    }

    func testArtifactDigestAbsenceIsExplicitAndInvalidDigestsReject() throws {
        let profile = try makeProfile(backingDigest: .unavailable)
        XCTAssertEqual(profile.artifact.backingDigest, .unavailable)

        XCTAssertThrowsError(try Phase2ModelBackingDigest.sha256("ABC")) { error in
            XCTAssertEqual(
                error as? Phase2ModelProfileValidationError,
                .invalidSHA256Digest
            )
        }
    }

    func testProfileRejectsDuplicatePromptModulesAndInvalidContextBudget() throws {
        let module = try protocolIdentity("role-and-scope", version: 1, byte: "1")
        XCTAssertThrowsError(try makeProfile(promptModules: [module, module])) { error in
            XCTAssertEqual(
                error as? Phase2ModelProfileValidationError,
                .duplicatePromptModule("role-and-scope")
            )
        }

        XCTAssertThrowsError(try Phase2ContextProfile(
            id: "normal-investigation",
            version: 1,
            maximumInputTokens: 4_096,
            reservedOutputTokens: 8_192,
            maximumEvidenceBytes: 1_000_000,
            compactionThresholdTokens: 3_000
        )) { error in
            XCTAssertEqual(
                error as? Phase2ModelProfileValidationError,
                .invalidContextBudget
            )
        }
    }

    func testGenerationRejectsNonfiniteSamplingAndDuplicateStops() throws {
        XCTAssertThrowsError(try Phase2GenerationProfile(
            id: "grounded-finalization",
            version: 1,
            temperature: .nan,
            topP: 1,
            seed: nil,
            stopSequences: [],
            reasoningOutputPolicy: .discard
        ))
        XCTAssertThrowsError(try Phase2GenerationProfile(
            id: "grounded-finalization",
            version: 1,
            temperature: 0,
            topP: 1,
            seed: nil,
            stopSequences: ["<END>", "<END>"],
            reasoningOutputPolicy: .discard
        )) { error in
            XCTAssertEqual(
                error as? Phase2ModelProfileValidationError,
                .duplicateStopSequence("<END>")
            )
        }
        XCTAssertThrowsError(try Phase2GenerationProfile(
            id: "grounded-finalization",
            version: 1,
            temperature: -0.0,
            topP: 1,
            seed: nil,
            stopSequences: [],
            reasoningOutputPolicy: .discard
        ))
    }

    func testIdentifiersRejectNoncanonicalUnicodeAndReportTokensRejectPayloadGrammar() throws {
        let decomposed = "mode\u{301}l"
        XCTAssertNotEqual(
            Array(decomposed.utf8),
            Array(decomposed.precomposedStringWithCanonicalMapping.utf8)
        )
        XCTAssertThrowsError(try Phase2ModelArtifactIdentity(
            modelKey: decomposed,
            source: "provider-catalog",
            type: .language,
            format: .gguf,
            quantizationName: "Q4_K_M",
            bitsPerWeight: 4,
            backingDigest: .unavailable
        ))
        for invalid in ["contains space", "/Users/private", "https://host", "Bearer-token"] {
            XCTAssertThrowsError(try Phase2ProtocolComponentIdentity(
                id: invalid,
                version: 1,
                sha256: String(repeating: "a", count: 64)
            ))
            XCTAssertThrowsError(try Phase2HardwareTier(id: invalid, version: 1))
            XCTAssertThrowsError(try Phase2ContextProfile(
                id: invalid,
                version: 1,
                maximumInputTokens: 32_768,
                reservedOutputTokens: 4_096,
                maximumEvidenceBytes: 2_000_000,
                compactionThresholdTokens: 24_000
            ))
        }
    }

    func testProfileRejectsInvalidLoadedConfiguration() throws {
        let invalid = Phase2LocalModelInstanceConfiguration(
            effectiveContextLength: 32_768,
            evaluationBatchSize: -1,
            parallelPredictions: 0,
            flashAttention: true,
            expertCount: -8,
            offloadsKVCacheToGPU: true
        )
        XCTAssertThrowsError(try makeProfile(loadedConfiguration: invalid)) { error in
            XCTAssertEqual(
                error as? Phase2ModelProfileValidationError,
                .invalidContextBudget
            )
        }
    }

    func testHashBoundProfileCannotMatchHashlessProviderCatalog() throws {
        let hash = try Phase2ModelBackingDigest.sha256(String(repeating: "d", count: 64))
        let profile = try makeProfile(backingDigest: hash)
        XCTAssertEqual(
            Phase2ModelProfileMatcher().match(
                profile: profile,
                observedProvider: profile.provider,
                observedSource: profile.artifact.source,
                observedBackingDigest: .unavailable,
                model: makeObservedModel(key: profile.artifact.modelKey),
                loadedConfiguration: profile.loadedConfiguration
            ),
            .mismatch([.backingDigest])
        )
    }

    func testMatcherRequiresExactModelArtifactAndLoadedConfiguration() throws {
        let profile = try makeProfile()
        let exactModel = makeObservedModel(
            key: profile.artifact.modelKey,
            displayName: "A friendly display name"
        )
        let result = Phase2ModelProfileMatcher().match(
            profile: profile,
            observedProvider: profile.provider,
            observedSource: profile.artifact.source,
            observedBackingDigest: .unavailable,
            model: exactModel,
            loadedConfiguration: profile.loadedConfiguration
        )
        XCTAssertEqual(result, .exact)

        let aliasOnly = makeObservedModel(
            key: "publisher/a-different-artifact",
            displayName: profile.artifact.modelKey
        )
        let mismatch = Phase2ModelProfileMatcher().match(
            profile: profile,
            observedProvider: profile.provider,
            observedSource: profile.artifact.source,
            observedBackingDigest: .unavailable,
            model: aliasOnly,
            loadedConfiguration: profile.loadedConfiguration
        )
        XCTAssertEqual(mismatch, .mismatch([.modelKey]))

        XCTAssertEqual(
            Phase2ModelProfileMatcher().match(
                profile: profile,
                observedProvider: profile.provider,
                observedSource: "different-source",
                observedBackingDigest: .unavailable,
                model: exactModel,
                loadedConfiguration: profile.loadedConfiguration
            ),
            .mismatch([.modelSource])
        )

        let decomposedKey = profile.artifact.modelKey.replacingOccurrences(
            of: "model",
            with: "mode\u{301}l"
        )
        XCTAssertEqual(
            Phase2ModelProfileMatcher().match(
                profile: profile,
                observedProvider: profile.provider,
                observedSource: profile.artifact.source,
                observedBackingDigest: profile.artifact.backingDigest,
                model: makeObservedModel(key: decomposedKey),
                loadedConfiguration: profile.loadedConfiguration
            ),
            .mismatch([.modelKey])
        )
    }

    func testMatcherComparesBackingDigestAvailabilityAndValueExactly() throws {
        let unavailableProfile = try makeProfile(backingDigest: .unavailable)
        let concreteA = try Phase2ModelBackingDigest.sha256(String(repeating: "a", count: 64))
        let concreteB = try Phase2ModelBackingDigest.sha256(String(repeating: "b", count: 64))

        XCTAssertEqual(
            Phase2ModelProfileMatcher().match(
                profile: unavailableProfile,
                observedProvider: unavailableProfile.provider,
                observedSource: unavailableProfile.artifact.source,
                observedBackingDigest: concreteA,
                model: makeObservedModel(key: unavailableProfile.artifact.modelKey),
                loadedConfiguration: unavailableProfile.loadedConfiguration
            ),
            .mismatch([.backingDigest])
        )

        let concreteProfile = try makeProfile(backingDigest: concreteA)
        XCTAssertEqual(
            Phase2ModelProfileMatcher().match(
                profile: concreteProfile,
                observedProvider: concreteProfile.provider,
                observedSource: concreteProfile.artifact.source,
                observedBackingDigest: concreteB,
                model: makeObservedModel(key: concreteProfile.artifact.modelKey),
                loadedConfiguration: concreteProfile.loadedConfiguration
            ),
            .mismatch([.backingDigest])
        )
    }

    func testMatcherReportsProviderFormatQuantizationAndConfigurationDrift() throws {
        let profile = try makeProfile()
        let model = makeObservedModel(
            key: profile.artifact.modelKey,
            format: .mlx,
            quantization: .init(name: "Q8_0", bitsPerWeight: 8)
        )
        let changedConfiguration = Phase2LocalModelInstanceConfiguration(
            effectiveContextLength: 16_384,
            evaluationBatchSize: 256,
            parallelPredictions: 2,
            flashAttention: false,
            expertCount: 4,
            offloadsKVCacheToGPU: false
        )
        let observedProvider = try Phase2QualifiedProviderIdentity(
            family: profile.provider.family,
            build: "different-build",
            apiCompatibility: profile.provider.apiCompatibility,
            endpointTransport: profile.provider.endpointTransport
        )

        XCTAssertEqual(
            Phase2ModelProfileMatcher().match(
                profile: profile,
                observedProvider: observedProvider,
                observedSource: profile.artifact.source,
                observedBackingDigest: .unavailable,
                model: model,
                loadedConfiguration: changedConfiguration
            ),
            .mismatch([
                .providerBuild,
                .modelFormat,
                .quantization,
                .loadedConfiguration,
            ])
        )
    }

    private func makeProfile(
        backingDigest: Phase2ModelBackingDigest = .unavailable,
        generation: Phase2GenerationProfile? = nil,
        promptModules: [Phase2ProtocolComponentIdentity]? = nil,
        provider: Phase2QualifiedProviderIdentity? = nil,
        artifact: Phase2ModelArtifactIdentity? = nil,
        loadedConfiguration: Phase2LocalModelInstanceConfiguration? = nil,
        context: Phase2ContextProfile? = nil,
        hardwareTier: Phase2HardwareTier? = nil,
        toolCallMode: Phase2ToolCallMode = .requiredReadOnly,
        structuredOutputMode: Phase2StructuredOutputMode = .jsonSchema,
        protocolManifest suppliedManifest: Phase2ModelProtocolManifest? = nil
    ) throws -> Phase2ModelProfile {
        let modules = try promptModules ?? [
            protocolIdentity("role-and-scope", version: 1, byte: "1"),
            protocolIdentity("evidence-contract", version: 1, byte: "2"),
            protocolIdentity("prompt-injection", version: 1, byte: "3"),
            protocolIdentity("grounded-final-output", version: 1, byte: "4"),
        ]
        let protocolManifest = try suppliedManifest ?? Phase2ModelProtocolManifest(
            promptModules: modules,
            finalOutputSchema: protocolIdentity("grounded-final-output", version: 1, byte: "5"),
            groundedContext: protocolIdentity("grounded-context", version: 1, byte: "6"),
            readToolRegistry: protocolIdentity("grounded-read-registry", version: 1, byte: "7"),
            inferenceTransport: protocolIdentity("chat-completions-tool-free", version: 1, byte: "8"),
            generationPolicy: protocolIdentity("generation-policy", version: 1, byte: "9"),
            qualificationPolicy: protocolIdentity("qualification-policy", version: 1, byte: "a"),
            workflowAuthorityPolicy: protocolIdentity(
                "grounded-read-only-authority",
                version: 1,
                byte: "b"
            )
        )
        return try Phase2ModelProfile(
            version: 1,
            provider: provider ?? .init(
                family: "local-openai-compatible",
                build: "provider-build-1",
                apiCompatibility: "openai-chat-completions-v1",
                endpointTransport: .loopbackHTTP
            ),
            artifact: artifact ?? .init(
                modelKey: "publisher/exact-model@q4_k_m",
                source: "provider-catalog",
                type: .language,
                format: .gguf,
                quantizationName: "Q4_K_M",
                bitsPerWeight: 4,
                backingDigest: backingDigest
            ),
            loadedConfiguration: loadedConfiguration ?? .init(
                effectiveContextLength: 32_768,
                evaluationBatchSize: 512,
                parallelPredictions: 1,
                flashAttention: true,
                expertCount: 8,
                offloadsKVCacheToGPU: true
            ),
            context: context ?? .init(
                id: "normal-investigation",
                version: 1,
                maximumInputTokens: 32_768,
                reservedOutputTokens: 4_096,
                maximumEvidenceBytes: 2_000_000,
                compactionThresholdTokens: 24_000
            ),
            generation: generation ?? .init(
                id: "grounded-finalization",
                version: 1,
                temperature: 0,
                topP: 1,
                seed: 7,
                stopSequences: [],
                reasoningOutputPolicy: .discard
            ),
            hardwareTier: hardwareTier ?? .init(id: "apple-silicon-current-host", version: 1),
            workflow: .groundedReadOnly,
            authorityCeiling: .groundedReadOnly,
            toolCallMode: toolCallMode,
            structuredOutputMode: structuredOutputMode,
            protocolManifest: protocolManifest
        )
    }

    private func makeObservedModel(
        key: String,
        displayName: String = "Exact Model",
        format: Phase2LocalModelFormat = .gguf,
        quantization: Phase2LocalModelQuantization = .init(name: "Q4_K_M", bitsPerWeight: 4)
    ) -> Phase2LocalModelDescriptor {
        Phase2LocalModelDescriptor(
            type: .language,
            publisher: "publisher",
            key: key,
            displayName: displayName,
            architecture: "test-architecture",
            quantization: quantization,
            sizeBytesOnDisk: 15_000_000_000,
            parameterCountDescription: "30B-A3B",
            maximumContextLength: 262_144,
            format: format,
            capabilities: .init(
                supportsVision: false,
                trainedForToolUse: true,
                reasoning: .init(allowedOptions: [.off], defaultOption: .off)
            ),
            variants: [key],
            providerSelectedVariant: key,
            loadedInstances: []
        )
    }

    private func protocolIdentity(
        _ id: String,
        version: Int,
        byte: Character
    ) -> Phase2ProtocolComponentIdentity {
        try! .init(
            id: id,
            version: version,
            sha256: String(repeating: String(byte), count: 64)
        )
    }

    private func replacingV2Manifest(
        _ manifest: Phase2ModelProtocolManifest,
        protocolProbeCatalog: Phase2ProtocolComponentIdentity? = nil,
        liveQualificationCorpus: Phase2ProtocolComponentIdentity? = nil,
        qualificationPolicy: Phase2ProtocolComponentIdentity? = nil
    ) throws -> Phase2ModelProtocolManifest {
        try .init(
            version: 2,
            promptModules: manifest.promptModules,
            finalOutputSchema: manifest.finalOutputSchema,
            groundedContext: manifest.groundedContext,
            readToolRegistry: manifest.readToolRegistry,
            inferenceTransport: manifest.inferenceTransport,
            generationPolicy: manifest.generationPolicy,
            protocolProbeCatalog: protocolProbeCatalog ?? manifest.protocolProbeCatalog!,
            liveQualificationCorpus: liveQualificationCorpus ?? manifest.liveQualificationCorpus!,
            qualificationPolicy: qualificationPolicy ?? manifest.qualificationPolicy,
            workflowAuthorityPolicy: manifest.workflowAuthorityPolicy
        )
    }
}
