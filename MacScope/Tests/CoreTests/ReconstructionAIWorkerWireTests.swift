import Foundation
import CryptoKit
import XCTest

@testable import MacScope

final class ReconstructionAIWorkerWireTests: XCTestCase {
    func testR2ObjectiveRoundTripAndCrossGenerationRejection() throws {
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let round = reconstructionRoundRequest()
        let text = "Recover the exact return behavior."
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let objective = try ReconstructionRequestObjective(jobID: round.jobID, text: text, sha256: digest)
        let request = ReconstructionInferenceRoundRequestR2(protocolVersion: 9, objective: objective, request: round)
        let requestID = reconstructionID(90)
        let bytes = try codec.encodeRoundRequestR2(request, requestID: requestID)
        XCTAssertEqual(try codec.decodeRequest(bytes), .roundR2(requestID: requestID, request: request))
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        envelope["wireProtocol"] = Phase2ReconstructionAIWorkerWireCodec.wireIdentity
        XCTAssertThrowsError(try codec.decodeRequest(JSONSerialization.data(withJSONObject: envelope)))
        let event = ReconstructionAIWorkerEvent(requestID: requestID, sequence: 1, body: .completed)
        let eventBytes = try codec.encodeEvent(event, authority: .roundR2(request))
        XCTAssertEqual(try codec.decodeEvent(eventBytes, authority: .roundR2(request)), event)
        XCTAssertThrowsError(try codec.decodeEvent(eventBytes, authority: .round(round)))
        XCTAssertNotEqual(Phase2AIWorkerProductionProtocol.reconstructionR1.manifestDigest,
                          Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest)
    }

    func testR2RejectsMissingSubstitutedAndUnknownObjectiveFields() throws {
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let final = reconstructionFinalRequest()
        let text = "Explain this function."
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let objective = try ReconstructionRequestObjective(jobID: final.jobID, text: text, sha256: digest)
        let request = ReconstructionFinalSynthesisRequestR2(protocolVersion: 9, objective: objective, request: final)
        let requestID = reconstructionID(91)
        let bytes = try codec.encodeFinalRequestR2(request, requestID: requestID)
        XCTAssertEqual(try codec.decodeRequest(bytes), .finalSynthesisR2(requestID: requestID, request: request))
        for mutation in ["missing", "text", "jobID", "extra"] {
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            var wrapper = try XCTUnwrap(envelope["request"] as? [String: Any])
            var fields = try XCTUnwrap(wrapper["objective"] as? [String: Any])
            switch mutation {
            case "missing": wrapper.removeValue(forKey: "objective")
            case "text": fields["text"] = "Substituted objective"
            case "jobID": fields["jobID"] = reconstructionID(999).uuidString
            default: fields["extra"] = true
            }
            if mutation != "missing" { wrapper["objective"] = fields }
            envelope["request"] = wrapper
            XCTAssertThrowsError(try codec.decodeRequest(JSONSerialization.data(withJSONObject: envelope)), mutation)
        }
        XCTAssertThrowsError(try ReconstructionRequestObjective(jobID: final.jobID, text: " ", sha256: digest))
        for invalidText in ["Goal\u{0}suffix", String(repeating: "x", count: 4_097)] {
            let invalidDigest = SHA256.hash(data: Data(invalidText.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertThrowsError(try ReconstructionRequestObjective(jobID: final.jobID, text: invalidText, sha256: invalidDigest))
        }
        let duplicateKeyJSON = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\"text\":", with: "\"text\":\"duplicate\",\"text\":")
        XCTAssertThrowsError(try codec.decodeRequest(Data(duplicateKeyJSON.utf8)))
    }

    func testRoundAndFinalRequestsRoundTripWithExactClosedShapes() throws {
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let round = reconstructionRoundRequest()
        let final = reconstructionFinalRequest()

        let roundData = try codec.encodeRoundRequest(round, requestID: reconstructionID(90))
        let finalData = try codec.encodeFinalRequest(final, requestID: reconstructionID(91))

        XCTAssertEqual(try codec.decodeRequest(roundData), .round(
            requestID: reconstructionID(90), request: round
        ))
        XCTAssertEqual(try codec.decodeRequest(finalData), .finalSynthesis(
            requestID: reconstructionID(91), request: final
        ))
        XCTAssertEqual(try objectKeys(roundData), [
            "phase", "request", "requestID", "wireProtocol",
        ])
        XCTAssertEqual(try objectKeys(finalData), [
            "phase", "request", "requestID", "wireProtocol",
        ])
        XCTAssertFalse(String(decoding: finalData, as: UTF8.self).contains("handles"))
    }

    func testRoundRejectsUnknownDuplicateAndCrossRoundHandles() throws {
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let requestID = reconstructionID(90)
        let valid = try codec.encodeRoundRequest(reconstructionRoundRequest(), requestID: requestID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["command"] = "run"
        XCTAssertThrowsError(try codec.decodeRequest(JSONSerialization.data(withJSONObject: object)))

        var request = try XCTUnwrap(object["request"] as? [String: Any])
        request["handles"] = [
            ["handleID": reconstructionID(10).uuidString,
             "operationID": ReconstructionOperationID.corpusSummary.rawValue],
            ["handleID": reconstructionID(10).uuidString,
             "operationID": ReconstructionOperationID.checkpointStatus.rawValue],
        ]
        object.removeValue(forKey: "command")
        object["request"] = request
        XCTAssertThrowsError(try codec.decodeRequest(JSONSerialization.data(withJSONObject: object)))
    }

    func testOrdinaryRoundRejectsSourceRevisionHandleAtEncodeAndDecode() throws {
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let requestID = reconstructionID(90)
        for operation in [MacScopeAnalysisCore.ReconstructionOperationID.sourceRevision, .sourceOracle, .sourceEvaluate] {
            let handle = MacScopeAnalysisCore.ReconstructionOfferedToolHandle(
                handleID: reconstructionID(10), operationID: operation
            )
            XCTAssertThrowsError(try codec.encodeRoundRequest(
                reconstructionRoundRequest(handles: [handle]), requestID: requestID
            )) { error in
                XCTAssertEqual(error as? ReconstructionAIWorkerWireError, .invalidAuthority)
            }
            let bytes = try codec.encodeRoundRequest(reconstructionRoundRequest(), requestID: requestID)
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            var request = try XCTUnwrap(envelope["request"] as? [String: Any])
            request["handles"] = [["handleID": handle.handleID.uuidString,
                                   "operationID": handle.operationID.rawValue]]
            envelope["request"] = request
            XCTAssertThrowsError(try codec.decodeRequest(JSONSerialization.data(withJSONObject: envelope)))
        }
    }

    func testNestedRequestAndEventObjectsRejectUnknownKeys() throws {
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let request = reconstructionRoundRequest()
        let requestID = reconstructionID(90)
        let validRequest = try codec.encodeRoundRequest(request, requestID: requestID)
        var requestEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validRequest) as? [String: Any]
        )
        var requestObject = try XCTUnwrap(requestEnvelope["request"] as? [String: Any])
        var context = try XCTUnwrap(requestObject["context"] as? [String: Any])
        context["path"] = "/private/tmp/authority-bypass"
        requestObject["context"] = context
        requestEnvelope["request"] = requestObject
        XCTAssertThrowsError(try codec.decodeRequest(
            JSONSerialization.data(withJSONObject: requestEnvelope)
        ))

        let candidate = ReconstructionInferenceRoundCandidate(
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            selectedHandleIDs: [],
            disposition: .sufficientEvidence,
            unresolvedGaps: []
        )
        let validEvent = try codec.encodeEvent(
            .init(requestID: requestID, sequence: 1, body: .roundCandidate(candidate)),
            authority: .round(request)
        )
        var eventEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validEvent) as? [String: Any]
        )
        var body = try XCTUnwrap(eventEnvelope["body"] as? [String: Any])
        body["command"] = "execute"
        eventEnvelope["body"] = body
        XCTAssertThrowsError(try codec.decodeEvent(
            JSONSerialization.data(withJSONObject: eventEnvelope),
            authority: .round(request)
        ))
    }

    func testRoundGapDeclarationsAreLimitedToTypedContextAuthority() throws {
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let request = reconstructionRoundRequest(
            allowedGapSubjects: ["artifact:main"],
            allowedGapCategories: ["missing-symbol"]
        )
        let accepted = ReconstructionInferenceRoundCandidate(
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            selectedHandleIDs: [],
            disposition: .blocked,
            unresolvedGaps: [.init(
                subject: "artifact:main",
                category: "missing-symbol",
                reason: "No durable symbol evidence was supplied."
            )]
        )
        XCTAssertNoThrow(try codec.encodeEvent(
            .init(requestID: reconstructionID(90), sequence: 1, body: .roundCandidate(accepted)),
            authority: .round(request)
        ))

        let forged = ReconstructionInferenceRoundCandidate(
            jobID: accepted.jobID,
            checkpointRevision: accepted.checkpointRevision,
            roundID: accepted.roundID,
            selectedHandleIDs: [],
            disposition: .blocked,
            unresolvedGaps: [.init(
                subject: "artifact:other",
                category: "missing-symbol",
                reason: "Forged authority."
            )]
        )
        XCTAssertThrowsError(try codec.encodeEvent(
            .init(requestID: reconstructionID(90), sequence: 1, body: .roundCandidate(forged)),
            authority: .round(request)
        ))
    }

    func testResolvedGapClaimBindsSuppliedGapSelectedHandleAndRetrievedEvidence() throws {
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let gapID = reconstructionID(40)
        let evidenceID = reconstructionID(41)
        let handleID = reconstructionID(10)
        let request = reconstructionRoundRequest(
            allowedGapIDs: [gapID],
            evidenceIDs: [evidenceID]
        )
        let accepted = ReconstructionInferenceRoundCandidate(
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            selectedHandleIDs: [handleID],
            disposition: .continue,
            unresolvedGaps: [],
            resolvedGaps: [.init(
                gapID: gapID,
                handleID: handleID,
                evidenceID: evidenceID
            )]
        )
        XCTAssertNoThrow(try codec.encodeEvent(
            .init(
                requestID: reconstructionID(90),
                sequence: 1,
                body: .roundCandidate(accepted)
            ),
            authority: .round(request)
        ))

        for forged in [
            ReconstructionEvidenceGapResolutionClaim(
                gapID: reconstructionID(999),
                handleID: handleID,
                evidenceID: evidenceID
            ),
            ReconstructionEvidenceGapResolutionClaim(
                gapID: gapID,
                handleID: reconstructionID(999),
                evidenceID: evidenceID
            ),
            ReconstructionEvidenceGapResolutionClaim(
                gapID: gapID,
                handleID: handleID,
                evidenceID: reconstructionID(999)
            ),
        ] {
            let candidate = ReconstructionInferenceRoundCandidate(
                jobID: request.jobID,
                checkpointRevision: request.checkpointRevision,
                roundID: request.roundID,
                selectedHandleIDs: [handleID],
                disposition: .continue,
                unresolvedGaps: [],
                resolvedGaps: [forged]
            )
            XCTAssertThrowsError(try codec.encodeEvent(
                .init(
                    requestID: reconstructionID(90),
                    sequence: 1,
                    body: .roundCandidate(candidate)
                ),
                authority: .round(request)
            ))
        }
    }

    func testRoundCandidateRejectsUnofferedIDsIdentityDriftAndArbitraryAuthority() throws {
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let request = reconstructionRoundRequest()
        let candidate = ReconstructionInferenceRoundCandidate(
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            selectedHandleIDs: [reconstructionID(10)],
            disposition: .continue,
            unresolvedGaps: []
        )
        let event = ReconstructionAIWorkerEvent(
            requestID: reconstructionID(90), sequence: 1,
            body: .roundCandidate(candidate)
        )
        let encoded = try codec.encodeEvent(event, authority: .round(request))
        XCTAssertEqual(try codec.decodeEvent(encoded, authority: .round(request)), event)

        let forged = ReconstructionInferenceRoundCandidate(
            jobID: request.jobID, checkpointRevision: request.checkpointRevision,
            roundID: request.roundID, selectedHandleIDs: [reconstructionID(999)],
            disposition: .continue, unresolvedGaps: []
        )
        XCTAssertThrowsError(try codec.encodeEvent(.init(
            requestID: reconstructionID(90), sequence: 1,
            body: .roundCandidate(forged)
        ), authority: .round(request)))
    }

    func testUsageOverflowIsRejectedAtEncodeAndDecodeBoundaries() throws {
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let request = reconstructionRoundRequest()
        let requestID = reconstructionID(90)
        let overflowUsage = Phase2AIWorkerWireUsage(
            promptTokens: Int.max,
            completionTokens: 1,
            totalTokens: Int.max
        )
        let overflowEvent = ReconstructionAIWorkerEvent(
            requestID: requestID,
            sequence: 1,
            body: .usage(overflowUsage)
        )
        XCTAssertThrowsError(try codec.encodeEvent(
            overflowEvent,
            authority: .round(request)
        )) {
            XCTAssertEqual($0 as? ReconstructionAIWorkerWireError, .invalidEnvelope)
        }

        let hostileEnvelope: [String: Any] = [
            "body": [
                "kind": "usage",
                "usage": [
                    "promptTokens": Int.max,
                    "completionTokens": 1,
                    "totalTokens": Int.max,
                ],
            ],
            "requestID": requestID.uuidString,
            "sequence": 1,
            "wireProtocol": Phase2ReconstructionAIWorkerWireCodec.wireIdentity,
        ]
        let hostileData = try JSONSerialization.data(
            withJSONObject: hostileEnvelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(try codec.decodeEvent(
            hostileData,
            authority: .round(request)
        )) {
            XCTAssertEqual($0 as? ReconstructionAIWorkerWireError, .invalidEnvelope)
        }
    }

    func testFinalCandidateKindShapeIsEnforcedAtTheWireBoundary() throws {
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let request = reconstructionFinalRequest()
        let requestID = reconstructionID(91)
        let evidenceID = try XCTUnwrap(request.acceptedEvidenceIDs.first)

        for candidate in [
            ReconstructionFinalSynthesisCandidate(
                kind: .synthesis,
                text: "The durable evidence supports this synthesis.",
                evidenceIDs: [evidenceID]
            ),
            ReconstructionFinalSynthesisCandidate(
                kind: .insufficientEvidence,
                text: "The accepted evidence cannot support a synthesis.",
                evidenceIDs: []
            ),
        ] {
            XCTAssertNoThrow(try codec.encodeEvent(
                .init(
                    requestID: requestID,
                    sequence: 1,
                    body: .finalCandidate(candidate)
                ),
                authority: .finalSynthesis(request)
            ))
        }

        let invalid = [
            ReconstructionFinalSynthesisCandidate(
                kind: .synthesis,
                text: "",
                evidenceIDs: [evidenceID]
            ),
            ReconstructionFinalSynthesisCandidate(
                kind: .synthesis,
                text: "Uncited synthesis",
                evidenceIDs: []
            ),
            ReconstructionFinalSynthesisCandidate(
                kind: .insufficientEvidence,
                text: "Must not cite arbitrary evidence.",
                evidenceIDs: [evidenceID]
            ),
            ReconstructionFinalSynthesisCandidate(
                kind: .insufficientEvidence,
                text: "",
                evidenceIDs: []
            ),
            ReconstructionFinalSynthesisCandidate(
                kind: .insufficientEvidence,
                text: String(repeating: "x", count: 4_097),
                evidenceIDs: []
            ),
        ]
        for candidate in invalid {
            XCTAssertThrowsError(try codec.encodeEvent(
                .init(
                    requestID: requestID,
                    sequence: 1,
                    body: .finalCandidate(candidate)
                ),
                authority: .finalSynthesis(request)
            ))
        }
    }

    func testContextAndDigestBoundsFailClosed() throws {
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let invalid = ReconstructionInferenceRoundRequest(
            protocolVersion: 7,
            jobID: reconstructionID(1), checkpointRevision: 3,
            roundID: reconstructionID(2), corpusManifestSHA256: String(repeating: "A", count: 64),
            evidenceFrontierSHA256: digest(2), registryManifestSHA256: digest(3),
            context: .init(canonicalBytes: Data(), canonicalSHA256: digest(4), evidenceIDs: []),
            handles: [.init(handleID: reconstructionID(10), operationID: .corpusSummary)]
        )
        XCTAssertThrowsError(try codec.encodeRoundRequest(invalid, requestID: reconstructionID(90)))
    }
}

private func reconstructionRoundRequest(
    allowedGapSubjects: [String] = [],
    allowedGapCategories: [String] = [],
    allowedGapIDs: [UUID] = [],
    evidenceIDs: [UUID] = [],
    handles: [MacScopeAnalysisCore.ReconstructionOfferedToolHandle] = [
        .init(handleID: reconstructionID(10), operationID: .corpusSummary)
    ]
) -> ReconstructionInferenceRoundRequest {
    .init(
        protocolVersion: 8, jobID: reconstructionID(1), checkpointRevision: 3,
        roundID: reconstructionID(2), corpusManifestSHA256: digest(1),
        evidenceFrontierSHA256: digest(2),
        registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
        context: .init(
            canonicalBytes: Data(#"{"records":[]}"#.utf8),
            canonicalSHA256: "1b8b4c0b6f6ad1d32565952720bc004eeb1f188f62045e4d5525ae2af8c78432",
            evidenceIDs: evidenceIDs,
            allowedGapSubjects: allowedGapSubjects,
            allowedGapCategories: allowedGapCategories,
            allowedGapIDs: allowedGapIDs
        ),
        handles: handles
    )
}

private func reconstructionFinalRequest() -> ReconstructionFinalSynthesisRequest {
    .init(
        jobID: reconstructionID(1), checkpointRevision: 3,
        corpusManifestSHA256: digest(1), evidenceFrontierSHA256: digest(2),
        acceptedEvidenceIDs: [reconstructionID(20)],
        context: .init(
            canonicalBytes: Data(#"{"records":[]}"#.utf8),
            canonicalSHA256: "1b8b4c0b6f6ad1d32565952720bc004eeb1f188f62045e4d5525ae2af8c78432",
            evidenceIDs: [reconstructionID(20)],
            allowedGapSubjects: [],
            allowedGapCategories: []
        )
    )
}

private func objectKeys(_ data: Data) throws -> Set<String> {
    Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
}

private func reconstructionID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "20000000-0000-4000-8000-%012d", value))!
}

private func digest(_ value: Int) -> String { String(format: "%064x", value) }
