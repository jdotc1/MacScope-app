import CryptoKit
import XCTest
@testable import MacScope

final class LLDBRuntimeModuleInventoryDecoderTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)
    private let processID: Int32 = 4312
    private let stopID: UInt32 = 17

    func testDecodesCanonicalOnePageInventoryAndComputesProtocolFingerprints() throws {
        let modules = [
            module(
                ordinal: 0,
                uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                path: "/Applications/Example App.app/Contents/MacOS/Example App",
                triple: "arm64e-apple-macosx27.0.0",
                sections: [
                    section(ordinal: 0, name: "__TEXT", staticStart: 0x1_0000_0000, runtimeStart: 0x1_0001_0000, byteCount: 0x3000, permissions: 5),
                    section(ordinal: 1, name: "__DATA", staticStart: 0x1_0000_3000, runtimeStart: nil, byteCount: 0x1000, permissions: 3),
                ]
            ),
        ]
        let digest = digestHex(for: modules)
        let page = try decoder().decodePage(from: transcript(pageJSON(
            modules: modules,
            digest: digest,
            start: 0,
            end: 1,
            final: true,
            moduleCount: 1
        )))

        XCTAssertEqual(page.token, Data(repeating: 0xaa, count: 32))
        XCTAssertEqual(page.digest, Data(SHA256.hash(data: canonical(.array(modules)))))
        XCTAssertEqual(page.observedProcessID, processID)
        XCTAssertEqual(page.observedStopID, stopID)
        XCTAssertEqual(page.start, 0)
        XCTAssertEqual(page.end, 1)
        XCTAssertTrue(page.isFinal)
        XCTAssertEqual(page.modules.count, 1)

        let decoded = try XCTUnwrap(page.modules.first)
        XCTAssertEqual(decoded.ordinal, 0)
        XCTAssertEqual(decoded.uuid?.uuidString.lowercased(), "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(decoded.fullPath, "/Applications/Example App.app/Contents/MacOS/Example App")
        XCTAssertEqual(decoded.normalizedArchitectureTriple, "arm64e-apple-macosx27.0.0")
        XCTAssertEqual(decoded.sections.count, 2)
        XCTAssertEqual(decoded.sections[1].runtimeStart, nil)

        let expectedFingerprintInput: Phase2ProductionJSONValue = .array([
            .string("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            .string("arm64e-apple-macosx27.0.0"),
            .string(Data("/Applications/Example App.app/Contents/MacOS/Example App".utf8).base64EncodedString()),
            .array([
                .array([.string(Data("__TEXT".utf8).base64EncodedString()), .string(hex(0x1_0000_0000)), .string(hex(0x1_0001_0000)), .string(hex(0x3000)), .number("5")]),
                .array([.string(Data("__DATA".utf8).base64EncodedString()), .string(hex(0x1_0000_3000)), .null, .string(hex(0x1000)), .number("3")]),
            ]),
        ])
        XCTAssertEqual(decoded.fingerprintSHA256, Data(SHA256.hash(data: canonical(expectedFingerprintInput))))

        var assembler = try DebuggerRuntimeModuleCollectionAssembler(
            expectedToken: Data(repeating: 0xaa, count: 32),
            expectedProcessID: processID,
            startedAtUptimeNanoseconds: 1_000
        )
        let collection = try XCTUnwrap(assembler.append(page, nowUptimeNanoseconds: 2_000))
        XCTAssertEqual(collection.modules.count, 1)
        XCTAssertEqual(collection.modules[0].mappedRanges.count, 1)
        XCTAssertEqual(collection.modules[0].mappedRanges[0].sectionName, "__TEXT")
        XCTAssertEqual(collection.modules[0].observedStopID, stopID)
        XCTAssertEqual(collection.canonicalSnapshotByteCount, canonical(.array(modules)).count)
    }

    func testAssemblesCoherentMultiPageCollectionWithoutPartialPublication() throws {
        let modules = [
            module(ordinal: 0, uuid: nil, path: "/tmp/A", triple: "arm64-apple-macosx27.0.0", sections: []),
            module(ordinal: 1, uuid: "11111111-2222-3333-4444-555555555555", path: "/tmp/B", triple: "arm64e-apple-macosx27.0.0", sections: []),
        ]
        let digest = digestHex(for: modules)
        let first = try decoder().decodePage(from: transcript(pageJSON(
            modules: [modules[0]], digest: digest, start: 0, end: 1, final: false, moduleCount: 2
        )))
        let second = try decoder().decodePage(from: transcript(pageJSON(
            modules: [modules[1]], digest: digest, start: 1, end: 2, final: true, moduleCount: 2
        )))
        var assembler = try DebuggerRuntimeModuleCollectionAssembler(
            expectedToken: Data(repeating: 0xaa, count: 32),
            expectedProcessID: processID,
            startedAtUptimeNanoseconds: 0
        )

        XCTAssertNil(try assembler.append(first, nowUptimeNanoseconds: 1))
        let collection = try XCTUnwrap(assembler.append(second, nowUptimeNanoseconds: 2))
        XCTAssertEqual(collection.modules.map(\.fullPath), ["/tmp/A", "/tmp/B"])
        XCTAssertEqual(collection.modules.map(\.displayIndex), [0, 1])
    }

    func testAcceptsUnicodePathAndNameOnlyThroughCanonicalPaddedBase64() throws {
        let modules = [module(
            ordinal: 0,
            uuid: nil,
            path: "/tmp/序列 📚",
            triple: "arm64-apple-macosx27.0.0",
            sections: [section(ordinal: 0, name: "__テキスト", staticStart: 0x1000, runtimeStart: 0x2000, byteCount: 1, permissions: 5)]
        )]
        let page = try decoder().decodePage(from: transcript(pageJSON(
            modules: modules, digest: digestHex(for: modules), start: 0, end: 1, final: true, moduleCount: 1
        )))
        XCTAssertEqual(page.modules[0].fullPath, "/tmp/序列 📚")
        XCTAssertEqual(page.modules[0].sections[0].name, "__テキスト")

        let noncanonical = replacingCanonicalJSON(
            pageJSON(modules: modules, digest: digestHex(for: modules), start: 0, end: 1, final: true, moduleCount: 1),
            replacing: Data("/tmp/序列 📚".utf8).base64EncodedString(),
            with: Data("/tmp/序列 📚".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        )
        assertFailure(transcript(noncanonical), code: .invalidBase64)
    }

    func testRejectsNoncanonicalEnvelopeAndSemanticTranscriptContamination() throws {
        let modules: [Phase2ProductionJSONValue] = []
        let json = pageJSON(modules: modules, digest: digestHex(for: modules), start: 0, end: 0, final: true, moduleCount: 0)
        let canonicalLine = semanticLine(json)

        for contaminated in [
            "(lldb) script\n" + canonicalLine,
            "warning\n" + canonicalLine,
            canonicalLine + "target output\n",
            canonicalLine + canonicalLine,
            canonicalLine.dropLast() + " trailing\n",
        ] {
            assertFailure(transcript(semantic: String(contaminated)), code: .invalidFraming)
        }

        let reordered = "{\"token\":\"\(token)\",\"schema\":1,\"ok\":true,\"modules\":[],\"module_count\":0,\"start\":0,\"end\":0,\"final\":true,\"observed_stop_id\":\(stopID),\"observed_state\":\"stopped\",\"observed_pid\":\(processID),\"digest\":\"\(digestHex(for: modules))\"}"
        assertFailure(transcript(semantic: "MACSCOPE_LLDB_MODULE_PAGE_V1 \(reordered)\n"), code: .noncanonicalJSON)

        let duplicateKey = String(data: canonical(json), encoding: .utf8)!.replacingOccurrences(of: "{", with: "{\"ok\":true,", options: [], range: nil)
        assertFailure(transcript(semantic: "MACSCOPE_LLDB_MODULE_PAGE_V1 \(duplicateKey)\n"), code: .invalidJSON)
    }

    func testRejectsSchemaTypesCapacityAndSemanticCommandFailure() throws {
        let modules: [Phase2ProductionJSONValue] = []
        let valid = pageJSON(modules: modules, digest: digestHex(for: modules), start: 0, end: 0, final: true, moduleCount: 0)

        assertFailure(transcript(capacityJSON()), code: .capacity)
        assertFailure(transcript(objectReplacing(valid, key: "schema", value: .number("2"))), code: .invalidSchema)
        assertFailure(transcript(objectReplacing(valid, key: "ok", value: .string("true"))), code: .invalidSchema)

        let failed = transcript(valid, semanticCommandsSucceeded: false)
        assertFailure(failed, code: .semanticCommandFailed)
        let traceback = transcript(semantic: "Traceback (most recent call last):\n")
        assertFailure(traceback, code: .invalidFraming)
    }

    func testRejectsUnicodeTokenAndDigestAtExactUTF8ByteWidth() {
        let modules: [Phase2ProductionJSONValue] = []
        let valid = pageJSON(
            modules: modules,
            digest: digestHex(for: modules),
            start: 0,
            end: 0,
            final: true,
            moduleCount: 0
        )
        let malformedHex = String(repeating: "a", count: 62) + "é"
        XCTAssertEqual(malformedHex.utf8.count, 64)

        assertFailure(
            transcript(objectReplacing(valid, key: "token", value: .string(malformedHex))),
            code: .invalidSchema
        )
        assertFailure(
            transcript(objectReplacing(valid, key: "digest", value: .string(malformedHex))),
            code: .invalidSchema
        )
    }

    func testRejectsInvalidUUIDNumericGrammarOrdinalsAndRanges() throws {
        let validModule = module(ordinal: 0, uuid: nil, path: "/tmp/A", triple: "arm64-apple-macosx27.0.0", sections: [])
        let invalidUUID = module(ordinal: 0, uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", path: "/tmp/A", triple: "arm64-apple-macosx27.0.0", sections: [])
        let invalidHex = module(ordinal: 0, uuid: nil, path: "/tmp/A", triple: "arm64-apple-macosx27.0.0", sections: [
            .array([.number("0"), .null, .string("00000000000000FF"), .string("0000000000001000"), .string(hex(1)), .number("5")]),
        ])
        let overflowingRange = module(ordinal: 0, uuid: nil, path: "/tmp/A", triple: "arm64-apple-macosx27.0.0", sections: [
            section(ordinal: 0, name: "__TEXT", staticStart: .max - 1, runtimeStart: 0x1000, byteCount: 3, permissions: 5),
        ])

        for modules in [[invalidUUID], [invalidHex], [overflowingRange]] {
            assertFailure(transcript(pageJSON(modules: modules, digest: digestHex(for: modules), start: 0, end: 1, final: true, moduleCount: 1)))
        }

        let wrongOrdinal = objectReplacing(validModule, arrayIndex: 0, value: .number("1"))
        assertFailure(transcript(pageJSON(modules: [wrongOrdinal], digest: digestHex(for: [wrongOrdinal]), start: 0, end: 1, final: true, moduleCount: 1)), code: .invalidOrdinal)
    }

    func testRejectsOuterAndInnerPIDStateStopTokenCountAndDigestMismatch() throws {
        let modules: [Phase2ProductionJSONValue] = []
        let valid = pageJSON(modules: modules, digest: digestHex(for: modules), start: 0, end: 0, final: true, moduleCount: 0)

        assertFailure(transcript(valid, observedPID: processID + 1), code: .processMismatch)
        assertFailure(transcript(valid, observedState: .running(processID: processID)), code: .processNotStopped)
        assertFailure(transcript(objectReplacing(valid, key: "observed_pid", value: .number(String(processID + 1)))), code: .processMismatch)
        assertFailure(transcript(objectReplacing(valid, key: "observed_state", value: .string("running"))), code: .processNotStopped)

        let page = try decoder().decodePage(from: transcript(valid))
        var assembler = try DebuggerRuntimeModuleCollectionAssembler(expectedToken: Data(repeating: 0xbb, count: 32), expectedProcessID: processID, startedAtUptimeNanoseconds: 0)
        XCTAssertThrowsError(try assembler.append(page, nowUptimeNanoseconds: 1)) { error in
            XCTAssertEqual((error as? LLDBRuntimeModuleInventoryFailure)?.code, .tokenMismatch)
        }
    }

    func testRejectsMissingDuplicateAndOutOfOrderPageIntervals() throws {
        let modules = [
            module(ordinal: 0, uuid: nil, path: "/A", triple: "arm64-apple-macosx27.0.0", sections: []),
            module(ordinal: 1, uuid: nil, path: "/B", triple: "arm64-apple-macosx27.0.0", sections: []),
        ]
        let digest = digestHex(for: modules)
        let first = try decoder().decodePage(from: transcript(pageJSON(modules: [modules[0]], digest: digest, start: 0, end: 1, final: false, moduleCount: 2)))
        let duplicate = first
        let second = try decoder().decodePage(from: transcript(pageJSON(modules: [modules[1]], digest: digest, start: 1, end: 2, final: true, moduleCount: 2)))

        var duplicateAssembler = try assembler()
        XCTAssertNil(try duplicateAssembler.append(first, nowUptimeNanoseconds: 1))
        XCTAssertThrowsError(try duplicateAssembler.append(duplicate, nowUptimeNanoseconds: 2))

        var missingAssembler = try assembler()
        XCTAssertThrowsError(try missingAssembler.append(second, nowUptimeNanoseconds: 1))
    }

    func testRejectsChangedCollectionMetadataAndDuplicateFingerprint() throws {
        let identical = module(ordinal: 0, uuid: nil, path: "/same", triple: "arm64-apple-macosx27.0.0", sections: [])
        let duplicate = objectReplacing(identical, arrayIndex: 0, value: .number("1"))
        let modules = [identical, duplicate]
        let digest = digestHex(for: modules)
        let first = try decoder().decodePage(from: transcript(pageJSON(modules: [identical], digest: digest, start: 0, end: 1, final: false, moduleCount: 2)))
        let second = try decoder().decodePage(from: transcript(pageJSON(modules: [duplicate], digest: digest, start: 1, end: 2, final: true, moduleCount: 2)))
        var value = try assembler()
        XCTAssertNil(try value.append(first, nowUptimeNanoseconds: 1))
        XCTAssertThrowsError(try value.append(second, nowUptimeNanoseconds: 2)) { error in
            XCTAssertEqual((error as? LLDBRuntimeModuleInventoryFailure)?.code, .duplicateFingerprint)
        }
    }

    func testRejectsChangedStopModuleCountAndPageDigestAcrossCollection() throws {
        let modules = [
            module(ordinal: 0, uuid: nil, path: "/A", triple: "arm64-apple-macosx27.0.0", sections: []),
            module(ordinal: 1, uuid: nil, path: "/B", triple: "arm64-apple-macosx27.0.0", sections: []),
        ]
        let digest = digestHex(for: modules)
        let first = try decoder().decodePage(from: transcript(pageJSON(
            modules: [modules[0]], digest: digest, start: 0, end: 1, final: false, moduleCount: 2
        )))
        let changedPages = [
            try decoder().decodePage(from: transcript(pageJSON(
                modules: [modules[1]], digest: digest, start: 1, end: 2, final: true,
                moduleCount: 2, observedStopID: stopID + 1
            ))),
            try decoder().decodePage(from: transcript(pageJSON(
                modules: [modules[1]], digest: digest, start: 1, end: 2, final: false,
                moduleCount: 3
            ))),
            try decoder().decodePage(from: transcript(pageJSON(
                modules: [modules[1]], digest: digestHex(for: []), start: 1, end: 2,
                final: true, moduleCount: 2
            ))),
        ]

        for changedPage in changedPages {
            var value = try assembler()
            XCTAssertNil(try value.append(first, nowUptimeNanoseconds: 1))
            XCTAssertThrowsError(try value.append(changedPage, nowUptimeNanoseconds: 2)) { error in
                XCTAssertEqual(
                    (error as? LLDBRuntimeModuleInventoryFailure)?.code,
                    .collectionMismatch
                )
            }
        }
    }

    func testRejectsFinalSnapshotDigestMismatch() throws {
        let modules = [
            module(ordinal: 0, uuid: nil, path: "/A", triple: "arm64-apple-macosx27.0.0", sections: []),
        ]
        let page = try decoder().decodePage(from: transcript(pageJSON(
            modules: modules,
            digest: digestHex(for: []),
            start: 0,
            end: 1,
            final: true,
            moduleCount: 1
        )))
        var value = try assembler()

        XCTAssertThrowsError(try value.append(page, nowUptimeNanoseconds: 1)) { error in
            XCTAssertEqual((error as? LLDBRuntimeModuleInventoryFailure)?.code, .digestMismatch)
        }
    }

    func testEnforcesFrozenPageCountBoundary() throws {
        XCTAssertNoThrow(try DebuggerRuntimeModuleCollectionAssembler.validatePageCount(
            DebuggerRuntimeModuleCollectionAssembler.maximumPageCount,
            evidence: Data()
        ))
        assertInventoryFailure(.capacityExceeded) {
            try DebuggerRuntimeModuleCollectionAssembler.validatePageCount(
                DebuggerRuntimeModuleCollectionAssembler.maximumPageCount + 1,
                evidence: Data()
            )
        }
    }

    func testEnforcesFrozenModuleCountBoundaryWithoutLargeFixture() throws {
        let modules: [Phase2ProductionJSONValue] = []
        let digest = digestHex(for: modules)
        XCTAssertNoThrow(try decoder().decodePage(from: transcript(pageJSON(
            modules: modules,
            digest: digest,
            start: 0,
            end: 0,
            final: false,
            moduleCount: LLDBRuntimeModuleInventoryDecoder.maximumModuleCount
        ))))
        assertFailure(
            transcript(pageJSON(
                modules: modules,
                digest: digest,
                start: 0,
                end: 0,
                final: false,
                moduleCount: LLDBRuntimeModuleInventoryDecoder.maximumModuleCount + 1
            )),
            code: .invalidSchema
        )
    }

    func testEnforcesFrozenMappedRangeBoundaryWithoutLargeFixture() throws {
        XCTAssertNoThrow(try DebuggerRuntimeModuleCollectionAssembler.validateDecodedCapacity(
            logicalDecodedRecordByteCount: 81,
            mappedRangeCount: DebuggerRuntimeModuleCollectionAssembler.maximumMappedRangeCount,
            evidence: Data()
        ))
        assertInventoryFailure(.capacityExceeded) {
            try DebuggerRuntimeModuleCollectionAssembler.validateDecodedCapacity(
                logicalDecodedRecordByteCount: 81,
                mappedRangeCount: DebuggerRuntimeModuleCollectionAssembler.maximumMappedRangeCount + 1,
                evidence: Data()
            )
        }
    }

    func testRejectsCanonicalAndLogicalCollectionsAboveEightMiB() throws {
        XCTAssertNoThrow(try DebuggerRuntimeModuleCollectionAssembler.validateDecodedCapacity(
            logicalDecodedRecordByteCount: DebuggerRuntimeModuleCollectionAssembler.maximumLogicalDecodedRecordBytes,
            mappedRangeCount: 0,
            evidence: Data()
        ))
        assertInventoryFailure(.capacityExceeded) {
            try DebuggerRuntimeModuleCollectionAssembler.validateDecodedCapacity(
                logicalDecodedRecordByteCount: DebuggerRuntimeModuleCollectionAssembler.maximumLogicalDecodedRecordBytes + 1,
                mappedRangeCount: 0,
                evidence: Data()
            )
        }

        XCTAssertNoThrow(try DebuggerRuntimeModuleCollectionAssembler.validateCanonicalSnapshotCapacity(
            byteCount: DebuggerRuntimeModuleCollectionAssembler.maximumCanonicalSnapshotBytes,
            evidence: Data()
        ))
        assertInventoryFailure(.capacityExceeded) {
            try DebuggerRuntimeModuleCollectionAssembler.validateCanonicalSnapshotCapacity(
                byteCount: DebuggerRuntimeModuleCollectionAssembler.maximumCanonicalSnapshotBytes + 1,
                evidence: Data()
            )
        }
    }

    func testMaximumCanonicalPageCrossesNestedFramingAndEachOneByteOverFailsWithoutPublication() throws {
        let acceptedSemantic = try canonicalPageLine(
            exactUTF8ByteCount: LLDBRuntimeModuleInventoryDecoder.maximumRawPageBytes
        )
        let acceptedExchange = try nestedExchange(semantic: acceptedSemantic)
        XCTAssertEqual(acceptedSemantic.utf8.count, LLDBRuntimeModuleInventoryDecoder.maximumRawPageBytes)
        XCTAssertEqual(acceptedExchange.wrappedResultLineByteCount, 174_865)
        XCTAssertLessThanOrEqual(acceptedExchange.bytes.count, LLDBCLITranscriptDecoder.maximumExchangeBytes)
        let acceptedTranscript = try decodeNestedExchange(acceptedExchange.bytes)
        XCTAssertEqual(acceptedTranscript.exchangeByteCount, acceptedExchange.bytes.count)
        XCTAssertEqual(
            acceptedTranscript.semanticCommandResultLineByteCounts,
            [acceptedExchange.wrappedResultLineByteCount]
        )

        var publication: DebuggerRuntimeModuleDecodedCollection?
        try decodeAndPublish(acceptedExchange.bytes, publication: &publication)
        XCTAssertNotNil(publication)

        publication = nil
        let rawOverSemantic = try canonicalPageLine(
            exactUTF8ByteCount: LLDBRuntimeModuleInventoryDecoder.maximumRawPageBytes + 1
        )
        let rawOverExchange = try nestedExchange(semantic: rawOverSemantic)
        XCTAssertEqual(rawOverExchange.wrappedResultLineByteCount, 174_865)
        XCTAssertThrowsError(try decodeAndPublish(rawOverExchange.bytes, publication: &publication)) { error in
            XCTAssertEqual((error as? LLDBRuntimeModuleInventoryFailure)?.code, .rawPageTooLarge)
        }
        XCTAssertNil(publication)

        let wrappedOverByteCount = LLDBRuntimeModuleInventoryDecoder.maximumWrappedResultLineBytes + 1
        let wrappedOverSemantic = try canonicalPageLine(
            exactUTF8ByteCount: try minimumPayloadByteCount(
                forWrappedResultLineByteCount: wrappedOverByteCount
            )
        )
        let wrappedOverExchange = try nestedExchange(semantic: wrappedOverSemantic)
        XCTAssertEqual(wrappedOverExchange.wrappedResultLineByteCount, wrappedOverByteCount)
        XCTAssertLessThanOrEqual(wrappedOverExchange.bytes.count, LLDBCLITranscriptDecoder.maximumExchangeBytes)
        XCTAssertThrowsError(try decodeAndPublish(wrappedOverExchange.bytes, publication: &publication)) { error in
            XCTAssertEqual((error as? LLDBRuntimeModuleInventoryFailure)?.code, .wrappedResultTooLarge)
        }
        XCTAssertNil(publication)

        let smallSemantic = semanticLine(pageJSON(
            modules: [], digest: digestHex(for: []), start: 0, end: 0, final: true, moduleCount: 0
        ))
        let baseExchange = try nestedExchange(semantic: smallSemantic)
        let consoleByteCount = LLDBCLITranscriptDecoder.maximumExchangeBytes + 1
            - baseExchange.bytes.count - 1
        XCTAssertGreaterThan(consoleByteCount, 0)
        let outerOverExchange = try nestedExchange(
            semantic: smallSemantic,
            console: String(repeating: "x", count: consoleByteCount)
        )
        XCTAssertEqual(outerOverExchange.bytes.count, LLDBCLITranscriptDecoder.maximumExchangeBytes + 1)
        XCTAssertThrowsError(try decodeAndPublish(outerOverExchange.bytes, publication: &publication)) { error in
            XCTAssertEqual((error as? LLDBCLITranscriptFailure)?.code, .exchangeTooLarge)
        }
        XCTAssertNil(publication)
    }

    func testEnforcesCollectionDeadlineBoundary() throws {
        let modules: [Phase2ProductionJSONValue] = []
        let valid = pageJSON(modules: modules, digest: digestHex(for: modules), start: 0, end: 0, final: true, moduleCount: 0)
        let page = try decoder().decodePage(from: transcript(valid))
        var value = try assembler(startedAt: 100)
        XCTAssertThrowsError(try value.append(page, nowUptimeNanoseconds: 100 + DebuggerRuntimeModuleCollectionAssembler.maximumCollectionDurationNanoseconds + 1)) { error in
            XCTAssertEqual((error as? LLDBRuntimeModuleInventoryFailure)?.code, .deadlineExceeded)
        }
    }

    func testFrozenDecodedAccountingFormulaIncludesUnmappedSections() throws {
        let path = "/tmp/abc"
        let triple = "arm64-apple-macosx27.0.0"
        let name = "__DATA"
        let modules = [module(
            ordinal: 0,
            uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            path: path,
            triple: triple,
            sections: [section(ordinal: 0, name: name, staticStart: 0x1000, runtimeStart: nil, byteCount: 0x10, permissions: 3)]
        )]
        let page = try decoder().decodePage(from: transcript(pageJSON(modules: modules, digest: digestHex(for: modules), start: 0, end: 1, final: true, moduleCount: 1)))
        var value = try assembler()
        let collection = try XCTUnwrap(value.append(page, nowUptimeNanoseconds: 1))
        let exact = 81 + (65 + 16 + path.utf8.count + triple.utf8.count) + (27 + 8 + name.utf8.count)
        XCTAssertEqual(collection.logicalDecodedRecordByteCount, exact)
        XCTAssertEqual(collection.modules[0].mappedRanges, [])
    }

    func testFailuresRetainOnlyBoundedHashBackedEvidence() throws {
        let rawPath = "/private/secret/" + String(repeating: "sensitive", count: 1_000)
        let invalid = transcript(semantic: rawPath)
        do {
            _ = try decoder().decodePage(from: invalid)
            XCTFail("Expected decoder failure")
        } catch let failure as LLDBRuntimeModuleInventoryFailure {
            XCTAssertEqual(failure.evidenceSHA256.count, 32)
            XCTAssertGreaterThan(failure.evidenceByteCount, 4_096)
            XCTAssertFalse(String(describing: failure).contains(rawPath))
            XCTAssertFalse(failure.localizedDescription.contains(rawPath))
        }
    }

    // MARK: - Fixtures

    private func decoder() -> LLDBRuntimeModuleInventoryDecoder {
        LLDBRuntimeModuleInventoryDecoder()
    }

    private func assembler(startedAt: UInt64 = 0) throws -> DebuggerRuntimeModuleCollectionAssembler {
        try DebuggerRuntimeModuleCollectionAssembler(
            expectedToken: Data(repeating: 0xaa, count: 32),
            expectedProcessID: processID,
            startedAtUptimeNanoseconds: startedAt
        )
    }

    private func transcript(
        _ json: Phase2ProductionJSONValue,
        semanticCommandsSucceeded: Bool = true,
        observedPID: Int32? = nil,
        observedState: LLDBCLIObservedProcessState? = nil,
        exchangeByteCount: Int? = nil
    ) -> LLDBCLITranscriptResult {
        transcript(
            semantic: semanticLine(json),
            semanticCommandsSucceeded: semanticCommandsSucceeded,
            observedPID: observedPID,
            observedState: observedState,
            exchangeByteCount: exchangeByteCount
        )
    }

    private func transcript(
        semantic: String,
        semanticCommandsSucceeded: Bool = true,
        observedPID: Int32? = nil,
        observedState: LLDBCLIObservedProcessState? = nil,
        exchangeByteCount: Int? = nil
    ) -> LLDBCLITranscriptResult {
        LLDBCLITranscriptResult(
            transcript: "incidental target console is not typed evidence",
            authoritativeStatusTranscript: "Process \(processID) stopped",
            observedProcessID: observedPID ?? processID,
            observedProcessState: observedState ?? .stopped(processID: processID),
            exchangeByteCount: exchangeByteCount ?? Data(semantic.utf8).count,
            exchangeSHA256: String(repeating: "0", count: 64),
            semanticCommandsSucceeded: semanticCommandsSucceeded,
            firstFailedSemanticCommandIndex: semanticCommandsSucceeded ? nil : 0,
            semanticCommandTranscripts: [semantic],
            semanticCommandResultLineByteCounts: [
                wrappedResultLineByteCount(forPayloadByteCount: semantic.utf8.count),
            ]
        )
    }

    private struct NestedExchange {
        let bytes: Data
        let wrappedResultLineByteCount: Int
    }

    private func nestedExchange(
        semantic: String,
        console: String = ""
    ) throws -> NestedExchange {
        let markers = try boundaryMarkers()
        let encoded = Data(semantic.utf8).base64EncodedString()
        let encodedStatus = Data("Process \(processID) stopped".utf8).base64EncodedString()
        let resultLine = "\(markers.commandResultPrefix)0_\(encoded)__"
        let lines = [markers.requestBeginLine]
            + (console.isEmpty ? [] : [console])
            + [
                resultLine,
                markers.commandsSucceededLine,
                markers.statusBeginLine,
                "\(markers.statusResultPrefix)\(encodedStatus)__",
                markers.statusEndLine,
                markers.requestEndLine,
            ]
        return NestedExchange(
            bytes: Data((lines.joined(separator: "\n") + "\n").utf8),
            wrappedResultLineByteCount: resultLine.utf8.count + 1
        )
    }

    private func decodeNestedExchange(_ bytes: Data) throws -> LLDBCLITranscriptResult {
        var outer = LLDBCLITranscriptDecoder(
            markers: try boundaryMarkers(),
            observedPIDRequirement: .required,
            requiresSemanticCommandStatus: true,
            expectedSemanticCommandCount: 1
        )
        guard let result = try outer.append(bytes) else {
            throw BoundaryFixtureError.incompleteExchange
        }
        return result
    }

    private func decodeAndAssemble(
        _ exchange: Data
    ) throws -> DebuggerRuntimeModuleDecodedCollection {
        let page = try decoder().decodePage(from: decodeNestedExchange(exchange))
        var value = try assembler()
        return try XCTUnwrap(value.append(page, nowUptimeNanoseconds: 1))
    }

    private func decodeAndPublish(
        _ exchange: Data,
        publication: inout DebuggerRuntimeModuleDecodedCollection?
    ) throws {
        publication = try decodeAndAssemble(exchange)
    }

    private func canonicalPageLine(exactUTF8ByteCount target: Int) throws -> String {
        var modules: [Phase2ProductionJSONValue] = []
        while modules.count < LLDBRuntimeModuleInventoryDecoder.maximumModuleCount {
            let ordinal = modules.count
            let candidate = modules + [module(
                ordinal: ordinal,
                uuid: nil,
                path: sizedPath(ordinal: ordinal, byteCount: 4_096),
                triple: "a",
                sections: []
            )]
            guard placeholderPageLine(modules: candidate).utf8.count <= target else { break }
            modules = candidate
        }

        let currentDeficit = target - placeholderPageLine(modules: modules).utf8.count
        if currentDeficit >= 0, currentDeficit < 256, !modules.isEmpty {
            modules[modules.count - 1] = objectReplacing(
                modules[modules.count - 1],
                arrayIndex: 3,
                value: .string(String(repeating: "a", count: currentDeficit + 1))
            )
            return try finalizedPageLine(modules: modules, exactUTF8ByteCount: target)
        }

        let finalOrdinal = modules.count
        var lower = 0
        var upper = 4_096
        while lower < upper {
            let midpoint = (lower + upper + 1) / 2
            let candidate = modules + [module(
                ordinal: finalOrdinal,
                uuid: nil,
                path: sizedPath(ordinal: finalOrdinal, byteCount: midpoint),
                triple: "a",
                sections: []
            )]
            if placeholderPageLine(modules: candidate).utf8.count <= target {
                lower = midpoint
            } else {
                upper = midpoint - 1
            }
        }

        let finalPath = sizedPath(ordinal: finalOrdinal, byteCount: lower)
        var candidate = modules + [module(
            ordinal: finalOrdinal,
            uuid: nil,
            path: finalPath,
            triple: "a",
            sections: []
        )]
        let deficit = target - placeholderPageLine(modules: candidate).utf8.count
        guard deficit >= 0, deficit < 256 else { throw BoundaryFixtureError.unrepresentableSize }
        candidate[candidate.count - 1] = module(
            ordinal: finalOrdinal,
            uuid: nil,
            path: finalPath,
            triple: String(repeating: "a", count: deficit + 1),
            sections: []
        )
        return try finalizedPageLine(modules: candidate, exactUTF8ByteCount: target)
    }

    private func finalizedPageLine(
        modules: [Phase2ProductionJSONValue],
        exactUTF8ByteCount target: Int
    ) throws -> String {
        let line = semanticLine(pageJSON(
            modules: modules,
            digest: digestHex(for: modules),
            start: 0,
            end: modules.count,
            final: true,
            moduleCount: modules.count
        ))
        guard line.utf8.count == target else { throw BoundaryFixtureError.unrepresentableSize }
        return line
    }

    private func placeholderPageLine(modules: [Phase2ProductionJSONValue]) -> String {
        semanticLine(pageJSON(
            modules: modules,
            digest: String(repeating: "0", count: 64),
            start: 0,
            end: modules.count,
            final: true,
            moduleCount: modules.count
        ))
    }

    private func sizedPath(ordinal: Int, byteCount: Int) -> String {
        guard byteCount > 0 else { return "" }
        let prefix = "/\(ordinal)/"
        guard prefix.utf8.count <= byteCount else {
            return String(repeating: "x", count: byteCount)
        }
        return prefix + String(repeating: "x", count: byteCount - prefix.utf8.count)
    }

    private func minimumPayloadByteCount(
        forWrappedResultLineByteCount wrappedByteCount: Int
    ) throws -> Int {
        let fixedByteCount = try boundaryMarkers().commandResultPrefix.utf8.count
            + "0_".utf8.count + "__\n".utf8.count
        let base64ByteCount = wrappedByteCount - fixedByteCount
        guard base64ByteCount > 0, base64ByteCount.isMultiple(of: 4) else {
            throw BoundaryFixtureError.unrepresentableSize
        }
        let quartetCount = base64ByteCount / 4
        let payloadByteCount = (quartetCount - 1) * 3 + 1
        guard wrappedResultLineByteCount(forPayloadByteCount: payloadByteCount) == wrappedByteCount else {
            throw BoundaryFixtureError.unrepresentableSize
        }
        return payloadByteCount
    }

    private func wrappedResultLineByteCount(forPayloadByteCount count: Int) -> Int {
        let base64Count = ((count + 2) / 3) * 4
        return 31 + LLDBCLIExchangeMarkers.tokenCharacterCount + "_0_".utf8.count
            + base64Count + "__\n".utf8.count
    }

    private func boundaryMarkers() throws -> LLDBCLIExchangeMarkers {
        try LLDBCLIExchangeMarkers(token: String(repeating: "b", count: 64))
    }

    private func semanticLine(_ json: Phase2ProductionJSONValue) -> String {
        "MACSCOPE_LLDB_MODULE_PAGE_V1 \(String(data: canonical(json), encoding: .utf8)!)\n"
    }

    private func capacityJSON() -> Phase2ProductionJSONValue {
        .object(["code": .string("capacity"), "ok": .bool(false), "schema": .number("1"), "token": .string(token)])
    }

    private func pageJSON(
        modules: [Phase2ProductionJSONValue],
        digest: String,
        start: Int,
        end: Int,
        final: Bool,
        moduleCount: Int,
        observedStopID: UInt32? = nil
    ) -> Phase2ProductionJSONValue {
        .object([
            "digest": .string(digest),
            "end": .number(String(end)),
            "final": .bool(final),
            "module_count": .number(String(moduleCount)),
            "modules": .array(modules),
            "observed_pid": .number(String(processID)),
            "observed_state": .string("stopped"),
            "observed_stop_id": .number(String(observedStopID ?? stopID)),
            "ok": .bool(true),
            "schema": .number("1"),
            "start": .number(String(start)),
            "token": .string(token),
        ])
    }

    private func module(
        ordinal: Int,
        uuid: String?,
        path: String,
        triple: String,
        sections: [Phase2ProductionJSONValue]
    ) -> Phase2ProductionJSONValue {
        .array([
            .number(String(ordinal)),
            uuid.map(Phase2ProductionJSONValue.string) ?? .null,
            .string(Data(path.utf8).base64EncodedString()),
            .string(triple),
            .array(sections),
        ])
    }

    private func section(
        ordinal: Int,
        name: String?,
        staticStart: UInt64,
        runtimeStart: UInt64?,
        byteCount: UInt64,
        permissions: Int
    ) -> Phase2ProductionJSONValue {
        .array([
            .number(String(ordinal)),
            name.map { .string(Data($0.utf8).base64EncodedString()) } ?? .null,
            .string(hex(staticStart)),
            runtimeStart.map { .string(hex($0)) } ?? .null,
            .string(hex(byteCount)),
            .number(String(permissions)),
        ])
    }

    private func hex(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }

    private func digestHex(for modules: [Phase2ProductionJSONValue]) -> String {
        SHA256.hash(data: canonical(.array(modules))).map { String(format: "%02x", $0) }.joined()
    }

    private func canonical(_ value: Phase2ProductionJSONValue) -> Data {
        value.canonicalJSONBytes()
    }

    private func objectReplacing(
        _ value: Phase2ProductionJSONValue,
        key: String,
        value replacement: Phase2ProductionJSONValue
    ) -> Phase2ProductionJSONValue {
        guard case .object(var object) = value else { return value }
        object[key] = replacement
        return .object(object)
    }

    private func objectReplacing(
        _ value: Phase2ProductionJSONValue,
        arrayIndex: Int,
        value replacement: Phase2ProductionJSONValue
    ) -> Phase2ProductionJSONValue {
        guard case .array(var array) = value, array.indices.contains(arrayIndex) else { return value }
        array[arrayIndex] = replacement
        return .array(array)
    }

    private func replacingCanonicalJSON(
        _ value: Phase2ProductionJSONValue,
        replacing target: String,
        with replacement: String
    ) -> Phase2ProductionJSONValue {
        guard case .object(var object) = value,
              case .array(var modules) = object["modules"],
              case .array(var module) = modules.first else { return value }
        module[2] = .string(replacement)
        modules[0] = .array(module)
        object["modules"] = .array(modules)
        return .object(object)
    }

    private func assertFailure(
        _ transcript: LLDBCLITranscriptResult,
        code: LLDBRuntimeModuleInventoryDiagnosticCode? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try decoder().decodePage(from: transcript), file: file, line: line) { error in
            guard let failure = error as? LLDBRuntimeModuleInventoryFailure else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            if let code { XCTAssertEqual(failure.code, code, file: file, line: line) }
            XCTAssertEqual(failure.evidenceSHA256.count, 32, file: file, line: line)
        }
    }

    private func assertInventoryFailure(
        _ code: LLDBRuntimeModuleInventoryDiagnosticCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                (error as? LLDBRuntimeModuleInventoryFailure)?.code,
                code,
                file: file,
                line: line
            )
        }
    }
}

private enum BoundaryFixtureError: Error {
    case incompleteExchange
    case unrepresentableSize
}
