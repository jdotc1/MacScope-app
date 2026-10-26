import CryptoKit
import Foundation

/// MacScope-owned canonical wire encoding used exclusively for content-addressed identities.
///
/// Every value is encoded as `<type><payload-byte-count>:<payload>`. Arrays preserve their
/// semantic order. Object keys are encoded in raw UTF-8 byte order, independently of locale,
/// Foundation JSON behavior, or process configuration.
struct Phase2LengthFramedCanonicalEncoder: Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case unsupportedValue
    }

    func encode(_ value: Any) throws -> Data {
        try encodedValue(value)
    }

    private func encodedValue(_ value: Any) throws -> Data {
        if value is NSNull {
            return frame(type: "n", payload: Data())
        }
        if let value = value as? Bool {
            return frame(type: "b", payload: Data((value ? "1" : "0").utf8))
        }
        if let value = value as? Int {
            return frame(type: "i", payload: Data(String(value).utf8))
        }
        if let value = value as? Int64 {
            return frame(type: "i", payload: Data(String(value).utf8))
        }
        if let value = value as? String {
            return frame(type: "s", payload: Data(value.utf8))
        }
        if let values = value as? [Any] {
            var payload = Data()
            for element in values {
                payload.append(try encodedValue(element))
            }
            return frame(type: "a", payload: payload)
        }
        if let object = value as? [String: Any] {
            var payload = Data()
            for key in object.keys.sorted(by: utf8Precedes) {
                payload.append(try encodedValue(key))
                guard let child = object[key] else { throw Error.unsupportedValue }
                payload.append(try encodedValue(child))
            }
            return frame(type: "o", payload: payload)
        }
        throw Error.unsupportedValue
    }

    private func frame(type: Character, payload: Data) -> Data {
        var framed = Data("\(type)\(payload.count):".utf8)
        framed.append(payload)
        return framed
    }

    private func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

struct Phase2ModelProfileCanonicalizer: Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case encodingFailed
    }

    func canonicalBytes(for profile: Phase2ModelProfile) throws -> Data {
        try encode(profileObject(profile))
    }

    func stableID(for profile: Phase2ModelProfile) throws -> Phase2ModelProfileID {
        try Phase2ModelProfileID(rawValue: "sha256:\(digest(try canonicalBytes(for: profile)))")
    }

    func protocolManifestDigest(
        for manifest: Phase2ModelProtocolManifest
    ) -> String {
        // Every manifest value has already passed construction validation, so failure here is a
        // programmer error rather than provider-controlled input. Preserve a total pure API.
        let bytes = try! encode(protocolManifestObject(manifest))
        return digest(bytes)
    }

    func qualificationPolicyIdentity(
        for policy: Phase2ModelQualificationPolicy
    ) throws -> Phase2ProtocolComponentIdentity {
        let bytes = try encode(qualificationPolicyObject(policy))
        return try Phase2ProtocolComponentIdentity(
            id: policy.id,
            version: policy.version,
            sha256: digest(bytes)
        )
    }

    private func profileObject(_ profile: Phase2ModelProfile) -> [String: Any] {
        [
            "artifact": [
                "backing_digest": backingDigestObject(profile.artifact.backingDigest),
                "bits_per_weight_ieee754": profile.artifact.bitsPerWeight
                    .map { canonicalDoubleBits($0) as Any } ?? NSNull(),
                "format": profile.artifact.format.rawValue,
                "model_key": profile.artifact.modelKey,
                "quantization_name": profile.artifact.quantizationName,
                "source": profile.artifact.source,
                "type": profile.artifact.type.rawValue,
            ],
            "authority_ceiling": profile.authorityCeiling.rawValue,
            "context": [
                "compaction_threshold_tokens": profile.context.compactionThresholdTokens,
                "id": profile.context.id,
                "maximum_evidence_bytes": profile.context.maximumEvidenceBytes,
                "maximum_input_tokens": profile.context.maximumInputTokens,
                "reserved_output_tokens": profile.context.reservedOutputTokens,
                "version": profile.context.version,
            ],
            "generation": [
                "id": profile.generation.id,
                "reasoning_output_policy": profile.generation.reasoningOutputPolicy.rawValue,
                "seed": profile.generation.seed.map { $0 as Any } ?? NSNull(),
                "stop_sequences": profile.generation.stopSequences,
                "temperature_ieee754": canonicalDoubleBits(profile.generation.temperature),
                "top_p_ieee754": canonicalDoubleBits(profile.generation.topP),
                "version": profile.generation.version,
            ],
            "hardware_tier": componentObject(profile.hardwareTier),
            "loaded_configuration": loadedConfigurationObject(profile.loadedConfiguration),
            "protocol_manifest": protocolManifestObject(profile.protocolManifest),
            "provider": [
                "api_compatibility": profile.provider.apiCompatibility,
                "build": profile.provider.build,
                "endpoint_transport": profile.provider.endpointTransport.rawValue,
                "family": profile.provider.family,
            ],
            "structured_output_mode": profile.structuredOutputMode.rawValue,
            "tool_call_mode": profile.toolCallMode.rawValue,
            "version": profile.version,
            "workflow": profile.workflow.rawValue,
        ]
    }

    private func backingDigestObject(_ digest: Phase2ModelBackingDigest) -> [String: Any] {
        switch digest.storage {
        case .unavailable:
            return ["availability": "unavailable"]
        case let .sha256(value):
            return ["algorithm": "sha256", "availability": "available", "value": value]
        }
    }

    private func loadedConfigurationObject(
        _ configuration: Phase2LocalModelInstanceConfiguration
    ) -> [String: Any] {
        [
            "effective_context_length": configuration.effectiveContextLength,
            "evaluation_batch_size": configuration.evaluationBatchSize.map { $0 as Any } ?? NSNull(),
            "expert_count": configuration.expertCount.map { $0 as Any } ?? NSNull(),
            "flash_attention": configuration.flashAttention.map { $0 as Any } ?? NSNull(),
            "offloads_kv_cache_to_gpu": configuration.offloadsKVCacheToGPU.map { $0 as Any } ?? NSNull(),
            "parallel_predictions": configuration.parallelPredictions.map { $0 as Any } ?? NSNull(),
        ]
    }

    private func protocolManifestObject(_ manifest: Phase2ModelProtocolManifest) -> [String: Any] {
        var object: [String: Any] = [
            "final_output_schema": componentObject(manifest.finalOutputSchema),
            "generation_policy": componentObject(manifest.generationPolicy),
            "grounded_context": componentObject(manifest.groundedContext),
            "inference_transport": componentObject(manifest.inferenceTransport),
            "prompt_modules": manifest.promptModules.map(componentObject),
            "qualification_policy": componentObject(manifest.qualificationPolicy),
            "read_tool_registry": componentObject(manifest.readToolRegistry),
            "workflow_authority_policy": componentObject(manifest.workflowAuthorityPolicy),
        ]
        if manifest.version == 2 {
            object["version"] = manifest.version
            object["protocol_probe_catalog"] = componentObject(manifest.protocolProbeCatalog!)
            object["live_qualification_corpus"] = componentObject(
                manifest.liveQualificationCorpus!
            )
        }
        return object
    }

    private func qualificationPolicyObject(
        _ policy: Phase2ModelQualificationPolicy
    ) -> [String: Any] {
        if policy.version == 1 {
            return [
                "corpus_digest": policy.corpusDigest,
                "id": policy.id,
                "requirements": policy.requirements.map { requirement in
                    [
                        "category": requirement.category.rawValue,
                        "acceptance_criteria": componentObject(requirement.acceptanceCriteria),
                        "probe_id": requirement.probeID,
                        "required_measurements": requirement.requiredMeasurements.map(\.rawValue),
                        "required_trial_count": requirement.requiredTrialCount,
                        "severity": requirement.severity.rawValue,
                    ]
                },
                "version": policy.version,
            ]
        }
        return [
            "corpus_digest": policy.corpusDigest,
            "deterministic_fixture_corpus": componentObject(
                policy.deterministicFixtureCorpus!
            ),
            "id": policy.id,
            "live_qualification_corpus": componentObject(policy.liveQualificationCorpus!),
            "maximum_evidence_age_milliseconds": policy.maximumEvidenceAgeMilliseconds!,
            "metric_semantics": componentObject(policy.metricSemantics!),
            "protocol_probe_catalog": componentObject(policy.protocolProbeCatalog!),
            "requirements": policy.requirements.map { requirement in
                [
                    "category": requirement.category.rawValue,
                    "acceptance_criteria": componentObject(requirement.acceptanceCriteria),
                    "evidence_requirement": requirement.evidenceRequirement!.rawValue,
                    "execution_kind": requirement.executionKind!.rawValue,
                    "numeric_rules": requirement.numericRules.map { rule in
                        [
                            "comparison": rule.comparison.rawValue,
                            "measurement": rule.measurement.rawValue,
                            "scope": rule.scope.rawValue,
                            "threshold": rule.threshold,
                        ]
                    },
                    "probe_id": requirement.probeID,
                    "required_measurements": requirement.requiredMeasurements.map(\.rawValue),
                    "required_trial_count": requirement.requiredTrialCount,
                    "severity": requirement.severity.rawValue,
                ]
            },
            "version": policy.version,
        ]
    }

    private func componentObject(_ identity: Phase2ProtocolComponentIdentity) -> [String: Any] {
        [
            "availability": identity.availability.rawValue,
            "id": identity.id,
            "sha256": identity.sha256.map { $0 as Any } ?? NSNull(),
            "version": identity.version,
        ]
    }

    private func componentObject(_ tier: Phase2HardwareTier) -> [String: Any] {
        ["id": tier.id, "version": tier.version]
    }

    private func encode(_ object: [String: Any]) throws -> Data {
        do {
            return try Phase2LengthFramedCanonicalEncoder().encode(object)
        } catch {
            throw Error.encodingFailed
        }
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { fixedWidthHex(UInt64($0), width: 2) }.joined()
    }

    private func canonicalDoubleBits(_ value: Double) -> String {
        let normalized = value == 0 ? 0.0 : value
        return fixedWidthHex(normalized.bitPattern, width: 16)
    }

    private func fixedWidthHex(_ value: UInt64, width: Int) -> String {
        let unpadded = String(value, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, width - unpadded.count)) + unpadded
    }
}
