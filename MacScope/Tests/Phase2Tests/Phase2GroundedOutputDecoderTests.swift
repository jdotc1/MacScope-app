import Foundation
import XCTest

@testable import MacScope

final class Phase2GroundedOutputDecoderTests: XCTestCase {
    func testDecodesExactFlatAnswerAndAbstentionVariants() throws {
        let evidence = outputID(1)
        let decoder = Phase2GroundedFinalDecoder()

        XCTAssertEqual(
            try decoder.decode(
                envelope(kind: "answer", text: "Grounded answer", evidence: [evidence.uuidString], reason: ""),
                allowedEvidenceIDs: [evidence]
            ),
            .answer(text: "Grounded answer", evidenceIDs: [evidence])
        )
        XCTAssertEqual(
            try decoder.decode(
                envelope(kind: "insufficient_evidence", text: "", evidence: [], reason: "More evidence is required."),
                allowedEvidenceIDs: [evidence]
            ),
            .insufficientEvidence(text: "More evidence is required.")
        )
    }

    func testRequiresExactlyFourFlatFieldsAndRejectsToolSideChannels() {
        let invalid = [
            #"{"kind":"answer","text":"x","evidence_ids":[],"reason":"","extra":true}"#,
            #"{"kind":"answer","kind":"answer","text":"x","evidence_ids":[],"reason":""}"#,
            #"{"kind":"answer","text":"x","evidence_ids":[],"reason":""} trailing"#,
            #"{"kind":"answer","text":"x","evidence_ids":[],"reason":"","tool_calls":[]}"#,
            #"{"kind":"answer","text":{"answer":"x"},"evidence_ids":[],"reason":""}"#,
            #"{"kind":"other","text":"x","evidence_ids":[],"reason":""}"#,
            #"{"kind":"answer","text":"x","evidence_ids":[]}"#,
            "```json\n{\"kind\":\"answer\",\"text\":\"x\",\"evidence_ids\":[],\"reason\":\"\"}\n```",
        ]

        for value in invalid {
            XCTAssertThrowsError(
                try Phase2GroundedFinalDecoder().decode(Data(value.utf8), allowedEvidenceIDs: []),
                "Expected rejection for \(value.prefix(80))"
            )
        }
    }

    func testRejectsRecursivelyDuplicatedKeysBeforeSchemaValidation() {
        let data = Data(#"{"kind":"answer","text":"x","evidence_ids":[],"reason":"","ignored":{"x":1,"x":2}}"#.utf8)
        XCTAssertThrowsError(try Phase2GroundedFinalDecoder().decode(data, allowedEvidenceIDs: [])) { error in
            XCTAssertEqual(error as? Phase2GroundedFinalDecodingError, .invalidSchema)
        }
    }

    func testVariantSemanticsAreMutuallyExclusiveAndFailClosed() {
        let evidence = outputID(2)
        let invalid = [
            envelope(kind: "answer", text: "", evidence: [evidence.uuidString], reason: ""),
            envelope(kind: "answer", text: "x", evidence: [], reason: ""),
            envelope(kind: "answer", text: "x", evidence: [evidence.uuidString], reason: "why"),
            envelope(kind: "insufficient_evidence", text: "x", evidence: [], reason: "why"),
            envelope(kind: "insufficient_evidence", text: "", evidence: [evidence.uuidString], reason: "why"),
            envelope(kind: "insufficient_evidence", text: "", evidence: [], reason: ""),
        ]

        for data in invalid {
            XCTAssertThrowsError(try Phase2GroundedFinalDecoder().decode(data, allowedEvidenceIDs: [evidence]))
        }
    }

    func testRequiresCanonicalUppercaseExactAllowedEvidenceMembership() throws {
        // Use alphabetic hexadecimal digits so lowercasing actually produces a
        // distinct, noncanonical UUID spelling.
        let known = outputID(0xAB)
        let unknown = outputID(0xCD)
        let decoder = Phase2GroundedFinalDecoder()
        let mixedCase = known.uuidString.replacingOccurrences(of: "AB", with: "aB")
        XCTAssertNotEqual(mixedCase, mixedCase.uppercased())
        XCTAssertNotEqual(mixedCase, mixedCase.lowercased())
        let noncanonical = [
            known.uuidString.lowercased(),
            mixedCase,
            "{\(known.uuidString)}",
            known.uuidString.replacingOccurrences(of: "-", with: ""),
            " \(known.uuidString)",
            "\(known.uuidString) ",
            "not-a-uuid",
        ]

        for encoded in noncanonical {
            XCTAssertThrowsError(
                try decoder.decode(
                    envelope(kind: "answer", text: "x", evidence: [encoded], reason: ""),
                    allowedEvidenceIDs: [known]
                )
            ) { error in
                XCTAssertEqual(error as? Phase2GroundedFinalDecodingError, .invalidEvidenceID)
            }
        }
        let escapedCanonical = known.uuidString.replacingOccurrences(of: "-", with: #"\u002D"#)
        let escapedEnvelope = Data(
            #"{"kind":"answer","text":"x","evidence_ids":["\#(escapedCanonical)"],"reason":""}"#.utf8
        )
        XCTAssertThrowsError(try decoder.decode(escapedEnvelope, allowedEvidenceIDs: [known])) { error in
            XCTAssertEqual(error as? Phase2GroundedFinalDecodingError, .invalidEvidenceID)
        }
        XCTAssertThrowsError(
            try decoder.decode(
                envelope(kind: "answer", text: "x", evidence: [unknown.uuidString], reason: ""),
                allowedEvidenceIDs: [known]
            )
        ) { error in
            XCTAssertEqual(error as? Phase2GroundedFinalDecodingError, .unknownEvidenceID)
        }
        XCTAssertThrowsError(
            try decoder.decode(
                envelope(kind: "answer", text: "x", evidence: [known.uuidString, known.uuidString], reason: ""),
                allowedEvidenceIDs: [known]
            )
        ) { error in
            XCTAssertEqual(error as? Phase2GroundedFinalDecodingError, .duplicateEvidenceID)
        }
    }

    func testEnforcesEvidenceCountAndUTF8TextAndReasonByteCeilings() throws {
        let evidence = [outputID(5), outputID(6), outputID(7), outputID(8)]
        let answerAtLimit = String(repeating: "é", count: 30_000)
        let reasonAtLimit = String(repeating: "é", count: 2_048)

        XCTAssertEqual(
            try Phase2GroundedFinalDecoder().decode(
                envelope(kind: "answer", text: answerAtLimit, evidence: [evidence[0].uuidString], reason: ""),
                allowedEvidenceIDs: Set(evidence)
            ),
            .answer(text: answerAtLimit, evidenceIDs: [evidence[0]])
        )
        XCTAssertEqual(
            try Phase2GroundedFinalDecoder().decode(
                envelope(kind: "insufficient_evidence", text: "", evidence: [], reason: reasonAtLimit),
                allowedEvidenceIDs: []
            ),
            .insufficientEvidence(text: reasonAtLimit)
        )

        let failures: [(Data, Phase2GroundedFinalDecodingError)] = [
            (envelope(kind: "answer", text: answerAtLimit + "x", evidence: [evidence[0].uuidString], reason: ""), .textByteLimitExceeded),
            (envelope(kind: "insufficient_evidence", text: "", evidence: [], reason: reasonAtLimit + "x"), .reasonByteLimitExceeded),
            (envelope(kind: "answer", text: "x", evidence: evidence.map(\.uuidString), reason: ""), .evidenceLimitExceeded),
        ]
        for (data, expected) in failures {
            XCTAssertThrowsError(try Phase2GroundedFinalDecoder().decode(data, allowedEvidenceIDs: Set(evidence))) { error in
                XCTAssertEqual(error as? Phase2GroundedFinalDecodingError, expected)
            }
        }
    }

    func testEnforcesExactEnvelopeByteCeilingBeforeParsing() throws {
        let evidence = outputID(9)
        let base = envelope(kind: "answer", text: "x", evidence: [evidence.uuidString], reason: "")
        let padding = Data(repeating: UInt8(ascii: " "), count: Phase2GroundedFinalDecoder.maximumEnvelopeBytes - base.count)
        let atLimit = base + padding
        XCTAssertEqual(atLimit.count, 65_536)
        XCTAssertNoThrow(try Phase2GroundedFinalDecoder().decode(atLimit, allowedEvidenceIDs: [evidence]))

        let overLimit = atLimit + Data([UInt8(ascii: " ")])
        XCTAssertThrowsError(try Phase2GroundedFinalDecoder().decode(overLimit, allowedEvidenceIDs: [evidence])) { error in
            XCTAssertEqual(error as? Phase2GroundedFinalDecodingError, .envelopeByteLimitExceeded)
        }
    }

    func testEnforcesRootCountedDepthEightMaximumAndMaximumPlusOne() {
        let acceptedByParser = nestedUnknownPayload(arrayDepth: 6)
        XCTAssertThrowsError(try Phase2GroundedFinalDecoder().decode(acceptedByParser, allowedEvidenceIDs: [])) { error in
            XCTAssertEqual(error as? Phase2GroundedFinalDecodingError, .invalidSchema)
        }
        let rejectedByParser = nestedUnknownPayload(arrayDepth: 7)
        XCTAssertThrowsError(try Phase2GroundedFinalDecoder().decode(rejectedByParser, allowedEvidenceIDs: [])) { error in
            XCTAssertEqual(error as? Phase2GroundedFinalDecodingError, .resourceLimitExceeded)
        }
    }

    func testEnforcesAggregateMemberElementMaximumAndMaximumPlusOne() {
        for (count, expected) in [(512, Phase2GroundedFinalDecodingError.invalidSchema), (513, .resourceLimitExceeded)] {
            let members = (0..<count).map { #""k\#($0)":null"# }.joined(separator: ",")
            XCTAssertThrowsError(
                try Phase2GroundedFinalDecoder().decode(Data("{\(members)}".utf8), allowedEvidenceIDs: [])
            ) { error in
                XCTAssertEqual(error as? Phase2GroundedFinalDecodingError, expected)
            }
        }
    }

    func testEnforcesLexicalTokenMaximumAndMaximumPlusOne() {
        // Root array contributes two tokens. Each seven-deep empty-array value contributes
        // fourteen tokens and each separator contributes one: 15n + 1.
        for count in [273, 274] {
            let value = String(repeating: "[", count: 7) + String(repeating: "]", count: 7)
            let document = "[" + Array(repeating: value, count: count).joined(separator: ",") + "]"
            var parser = Phase2FinalJSONParser(data: Data(document.utf8), maximumAggregateEntries: .max)
            if count == 273 {
                XCTAssertNoThrow(try parser.parse())
            } else {
                XCTAssertThrowsError(try parser.parse()) { error in
                    XCTAssertEqual(error as? Phase2FinalJSONParser.Failure, .resourceLimit)
                }
            }
        }
    }

    func testTrimsTrailingJSONRemnantsTheModelLeftInAnswerText() throws {
        let evidence = outputID(1)
        let decoder = Phase2GroundedFinalDecoder()
        func decoded(_ text: String, proposal: Any? = nil) throws -> String {
            var object: [String: Any] = [
                "kind": "answer", "text": text, "evidence_ids": [evidence.uuidString], "reason": "",
            ]
            if let proposal { object["proposal"] = proposal }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard case .answer(let answer, _) = try decoder.decode(
                data, allowedEvidenceIDs: [evidence], proposalOperations: proposal == nil ? [] : ["comment"]
            ) else { throw Phase2GroundedFinalDecodingError.invalidSchema }
            return answer
        }
        let envelope = #"<macscope-authoring-proposal-v1>{"operation":"comment","value":"Adds 0x11","evidence_id":"\#(evidence.uuidString)"}</macscope-authoring-proposal-v1>"#

        // Remnants seen in installed-build answers from a small local model.
        XCTAssertEqual(try decoded("It is part of the _checksum function.}"), "It is part of the _checksum function.")
        XCTAssertEqual(try decoded("The operation is: w8 = w8 + 0x11.\n\n{\\"), "The operation is: w8 = w8 + 0x11.")
        XCTAssertEqual(try decoded("Proposed comment: `// Increment by 0x11 (17)\"}"), "Proposed comment: `// Increment by 0x11 (17)")
        // Before a terminal text envelope, and with a structured proposal.
        XCTAssertEqual(try decoded("Adds 0x11 to w8.}\n" + envelope), "Adds 0x11 to w8.\n\n" + envelope)
        XCTAssertEqual(
            try decoded("Adds 0x11 to w8.}\n" + envelope,
                        proposal: ["operation": "comment", "value": "Adds 0x11", "evidence_id": evidence.uuidString]),
            "Adds 0x11 to w8.\n\n" + #"<macscope-authoring-proposal-v1>{"evidence_id":"\#(evidence.uuidString)","operation":"comment","value":"Adds 0x11"}</macscope-authoring-proposal-v1>"#
        )
        // Balanced braces and quotes at the end are prose, and clean text is untouched.
        for clean in ["The loop is `while (n) { n--; }`", "It returns {x, y}", #"The string is "abc""#,
                      "Adds 0x11.\n" + envelope, "}"] {
            XCTAssertEqual(try decoded(clean), clean)
        }
    }

    private func envelope(kind: String, text: String, evidence: [String], reason: String) -> Data {
        try! JSONSerialization.data(
            withJSONObject: ["kind": kind, "text": text, "evidence_ids": evidence, "reason": reason],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func nestedUnknownPayload(arrayDepth: Int) -> Data {
        let nested = String(repeating: "[", count: arrayDepth) + "null" + String(repeating: "]", count: arrayDepth)
        return Data("{\"unknown\":\(nested)}".utf8)
    }
}

private func outputID(_ byte: UInt8) -> UUID {
    UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
}
