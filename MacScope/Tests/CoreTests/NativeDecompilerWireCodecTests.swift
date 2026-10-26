import Foundation
import XCTest
@testable import MacScope

final class NativeDecompilerWireCodecTests: XCTestCase {
    private let requestID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private var expectedBinding: NativeDecompilerWireExpectedRequestBinding {
        .init(request: makeRequestEnvelope())
    }

    func testSchemaV3IsTheOnlyCurrentRequestEnvelopeVersion() {
        XCTAssertEqual(NativeDecompilerWireRequestEnvelope.currentSchemaVersion, 3)
        XCTAssertEqual(NativeDecompilerWireRequestEnvelope.sparseCodeSchemaVersion, 4)
    }

    func testSchemaV4SparseCodeRangesRoundTripAndBindCanonicalDigest() throws {
        let codec = NativeDecompilerWireCodec()
        let sparse = makeSparseRequest()
        let data = try codec.encodeRequest(sparse, matching: requestID)
        XCTAssertEqual(try codec.decodeRequest(data, matching: requestID), sparse)
        let object = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any])
        let body = try XCTUnwrap(object["body"] as? [String: Any])
        let function = try XCTUnwrap(body["function"] as? [String: Any])
        XCTAssertEqual((function["codeRanges"] as? [[String: Any]])?.count, 2)

        let v3Data = try codec.encodeRequest(makeRequestEnvelope(), matching: requestID)
        let v3Object = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: v3Data, options: [], format: nil
        ) as? [String: Any])
        let v3Body = try XCTUnwrap(v3Object["body"] as? [String: Any])
        XCTAssertNil((v3Body["function"] as? [String: Any])?["codeRanges"])

        let reshaped = replacingSparseRequest(sparse, ranges: [
            .init(startAddress: .init(0x1000), endAddressExclusive: .init(0x1004)),
            .init(startAddress: .init(0x1008), endAddressExclusive: .init(0x1014)),
        ])
        XCTAssertNotEqual(reshaped.body.requestSHA256, sparse.body.requestSHA256)

        // A sparse reply requires v4 even without a block partition or PAC effect.
        let baseline = try XCTUnwrap(makeBaselineSuccessReply().success)
        let sparseResult = replacing(baseline.result, function: sparse.body.function)
        XCTAssertEqual(sparseResult.requiredReplySchemaVersion, 4)
        XCTAssertEqual(NativeDecompilerWireReplyEnvelope(
            requestID: requestID,
            success: .init(availability: baseline.availability, result: sparseResult)
        ).schemaVersion, 4)
    }

    func testSchemaV4RejectsMissingInvalidOrUncoveredCodeRanges() throws {
        let codec = NativeDecompilerWireCodec()
        let sparse = makeSparseRequest()
        let valid = try codec.encodeRequest(sparse, matching: requestID)
        XCTAssertThrowsError(try codec.decodeRequest(
            try removing(valid, path: ["body", "function", "codeRanges"]), matching: requestID
        ))
        let invalid: [[NativeDecompilerWireCodeRange]] = [
            [],
            [.init(startAddress: .init(0x1004), endAddressExclusive: .init(0x1014))],
            [.init(startAddress: .init(0x1000), endAddressExclusive: .init(0x1005)),
             .init(startAddress: .init(0x1010), endAddressExclusive: .init(0x1014))],
            [.init(startAddress: .init(0x1000), endAddressExclusive: .init(0x1014))],
            [.init(startAddress: .init(0x1000), endAddressExclusive: .init(0x1010)),
             .init(startAddress: .init(0x100c), endAddressExclusive: .init(0x1014))],
        ]
        for ranges in invalid {
            XCTAssertThrowsError(try codec.encodeRequest(
                replacingSparseRequest(sparse, ranges: ranges), matching: requestID
            ))
        }
        XCTAssertThrowsError(try codec.encodeRequest(.init(
            schemaVersion: 3, requestID: requestID, body: sparse.body
        ), matching: requestID))
    }

    func testCanonicalUInt64UsesExactlySixteenLowercaseHexCharacters() throws {
        let value = NativeDecompilerWireUInt64(0xA0_B1_C2_D3_E4_F5_06_17)
        XCTAssertEqual(value.hex, "a0b1c2d3e4f50617")
        XCTAssertEqual(value.value, 0xA0_B1_C2_D3_E4_F5_06_17)
        XCTAssertEqual(try NativeDecompilerWireUInt64(parsing: "0000000000000000").value, 0)

        for malformed in [
            "A0b1c2d3e4f50617", "0xa0b1c2d3e4f50617", "+0b1c2d3e4f50617",
            "-0b1c2d3e4f50617", " a0b1c2d3e4f50617", "a0b1c2d3e4f50617 ",
            "a0b1c2d3e4f5061", "a0b1c2d3e4f506170", "g0b1c2d3e4f50617",
        ] {
            XCTAssertThrowsError(try NativeDecompilerWireUInt64(parsing: malformed), malformed)
        }
    }

    func testRequestEncodingIsDeterministicBinaryAndUsesDataForByteViews() throws {
        let codec = NativeDecompilerWireCodec()
        let request = makeRequestEnvelope()
        let first = try codec.encodeRequest(request, matching: requestID)
        let second = try codec.encodeRequest(request, matching: requestID)

        XCTAssertEqual(first, second)
        XCTAssertLessThan(first.count, NativeDecompilerWireCodec.maximumRequestBytes)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: first, options: [], format: &format)
                as? [String: Any]
        )
        XCTAssertEqual(format, .binary)
        let body = try XCTUnwrap(object["body"] as? [String: Any])
        let regions = try XCTUnwrap(body["memoryRegions"] as? [[String: Any]])
        XCTAssertTrue(regions[0]["rawBytes"] is Data)
        XCTAssertTrue(regions[0]["effectiveBytes"] is Data)
        XCTAssertEqual(try codec.decodeRequest(first, matching: requestID), request)
    }

    func testRequestDecoderRejectsNoncanonicalDictionaryOrdering() throws {
        let codec = NativeDecompilerWireCodec()
        let canonical = try codec.encodeRequest(makeRequestEnvelope(), matching: requestID)
        let reordered = try reorderingTopDictionary(canonical)

        XCTAssertNotEqual(reordered, canonical)
        XCTAssertEqual(
            try NSDictionary(
                dictionary: XCTUnwrap(PropertyListSerialization.propertyList(
                    from: reordered, options: [], format: nil
                ) as? [String: Any])
            ),
            try NSDictionary(
                dictionary: XCTUnwrap(PropertyListSerialization.propertyList(
                    from: canonical, options: [], format: nil
                ) as? [String: Any])
            )
        )
        XCTAssertThrowsError(try codec.decodeRequest(reordered, matching: requestID))
    }

    func testRequestDecoderRejectsStaleCanonicalDigestAfterAuthorityMutation() throws {
        let codec = NativeDecompilerWireCodec()
        let canonical = makeRequestEnvelope()
        XCTAssertNoThrow(try codec.encodeRequest(canonical, matching: requestID))
        let body = canonical.body
        let substituted = NativeDecompilerWireRequestEnvelope(
            requestID: canonical.requestID,
            body: NativeDecompilerWireRequest(
                requestID: body.requestID,
                requestSHA256: body.requestSHA256,
                target: body.target,
                image: body.image,
                function: .init(
                    functionID: body.function.functionID,
                    name: "substituted-main",
                    entryAddress: body.function.entryAddress,
                    endAddressExclusive: body.function.endAddressExclusive
                ),
                memoryRegions: body.memoryRegions,
                symbols: body.symbols,
                authoredInputs: body.authoredInputs,
                budgets: body.budgets
            )
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let staleDigest = try encoder.encode(substituted)

        XCTAssertThrowsError(try codec.decodeRequest(staleDigest, matching: requestID))
    }

    func testRequestRoundTripPreservesRawProvenanceAndUsesOnlyEffectiveBytesAsExecutableAuthority() throws {
        let codec = NativeDecompilerWireCodec()
        let request = makeRequestEnvelope()
        let decoded = try codec.decodeRequest(
            codec.encodeRequest(request, matching: requestID),
            matching: requestID
        )
        let region = decoded.body.memoryRegions[0]

        XCTAssertEqual(region.rawBytes, Data([0x10, 0x20, 0x30, 0x40]))
        XCTAssertEqual(region.effectiveBytes, Data([0xAA, 0xBB, 0xCC, 0xDD]))
        XCTAssertEqual(region.executableBytes, region.effectiveBytes)
        XCTAssertNotEqual(region.executableBytes, region.rawBytes)
    }

    func testRequestDecoderRejectsVersionIDCompilerAndCanonicalUUIDViolations() throws {
        let codec = NativeDecompilerWireCodec()
        let valid = try codec.encodeRequest(makeRequestEnvelope(), matching: requestID)

        XCTAssertThrowsError(try codec.decodeRequest(valid, matching: UUID()))
        XCTAssertThrowsError(try codec.decodeRequest(
            try mutate(valid, path: ["schemaVersion"], value: UInt32(1)),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.decodeRequest(
            try mutate(valid, path: ["requestID"], value: requestID.uuidString.lowercased()),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.decodeRequest(
            try mutate(valid, path: ["body", "compilerSpecID"], value: "swift"),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.decodeRequest(
            try mutate(valid, path: ["body", "languageID"], value: "x86:LE:64:default"),
            matching: requestID
        ))
    }

    func testRequestDecoderRejectsMalformedOversizeUnknownAndMissingShapes() throws {
        let codec = NativeDecompilerWireCodec()
        let valid = try codec.encodeRequest(makeRequestEnvelope(), matching: requestID)

        XCTAssertThrowsError(try codec.decodeRequest(Data("not a property list".utf8), matching: requestID))
        XCTAssertThrowsError(try codec.decodeRequest(Data(repeating: 0, count: NativeDecompilerWireCodec.maximumRequestBytes + 1), matching: requestID))
        XCTAssertThrowsError(try codec.decodeRequest(
            try mutate(valid, path: ["body", "unknown"], value: "rejected"),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.decodeRequest(
            try removing(valid, path: ["body", "symbols"]),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.decodeRequest(
            try removing(valid, path: ["body", "memoryRegions", "0", "rawBytes"]),
            matching: requestID
        ))
    }

    func testEncoderEnforcesExactRequestAndResponseCeilings() throws {
        XCTAssertEqual(NativeDecompilerWireCodec.maximumRequestBytes, 32 * 1_024 * 1_024)
        XCTAssertEqual(NativeDecompilerWireCodec.maximumResponseBytes, 64 * 1_024 * 1_024)

        let codec = NativeDecompilerWireCodec()
        let request = makeRequestEnvelope()
        let byteCount = NativeDecompilerWireCodec.maximumRequestBytes / 2 + 1_024
        let rawBytes = Data(repeating: 0xA5, count: byteCount)
        let effectiveBytes = Data(repeating: 0x5A, count: byteCount)
        let region = NativeDecompilerWireMemoryRegion(
            name: "__text", startAddress: .init(0x1000), permissions: .readExecute,
            rawBytes: rawBytes, effectiveBytes: effectiveBytes, appliedPatchIDs: []
        )
        let body = NativeDecompilerWireRequest(
            requestID: request.body.requestID, requestSHA256: request.body.requestSHA256,
            target: request.body.target,
            image: request.body.image, function: request.body.function, memoryRegions: [region],
            symbols: request.body.symbols, authoredInputs: request.body.authoredInputs,
            budgets: .init(
                maxCodeBytes: UInt32(byteCount), maxInstructions: 16, maxOperations: 64,
                maxOutputBytes: 1_048_576, maxWallTimeMilliseconds: .init(5_000)
            )
        )
        XCTAssertThrowsError(try codec.encodeRequest(
            .init(requestID: requestID, body: body), matching: requestID
        ))

        let reply = makeBaselineSuccessReply()
        let result = reply.success!.result
        let instruction = NativeDecompilerWireInstructionRecord(
            id: "instruction:oversize", address: .init(0x1000),
            bytes: Data(repeating: 0xAA, count: NativeDecompilerWireCodec.maximumResponseBytes + 1),
            mnemonic: "ret", body: "", operationIDs: ["operation:0"],
            sourceRanges: result.instructions[0].sourceRanges
        )
        let oversizedReply = NativeDecompilerWireReplyEnvelope(
            requestID: requestID,
            success: .init(
                availability: reply.success!.availability,
                result: replacing(result, instructions: [instruction])
            )
        )
        XCTAssertThrowsError(try codec.encodeReply(oversizedReply, matching: expectedBinding))
    }

    func testRequestDecoderRejectsMalformedHexEnumsAndBytePairInvariants() throws {
        let codec = NativeDecompilerWireCodec()
        let valid = try codec.encodeRequest(makeRequestEnvelope(), matching: requestID)

        XCTAssertThrowsError(try codec.decodeRequest(
            try mutate(valid, path: ["body", "function", "entryAddress"], value: "00000000000010AF"),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.decodeRequest(
            try mutate(valid, path: ["body", "target", "rawCPUType"], value: "0100000C"),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.decodeRequest(
            try mutate(valid, path: ["body", "target", "context", "0", "name"], value: "unknown"),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.decodeRequest(
            try mutate(valid, path: ["body", "memoryRegions", "0", "permissions"], value: "read-execute"),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.decodeRequest(
            try mutate(valid, path: ["body", "memoryRegions", "0", "effectiveBytes"], value: Data([1, 2])),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.decodeRequest(
            try mutate(valid, path: ["body", "memoryRegions", "0", "rawBytes"], value: Data()),
            matching: requestID
        ))
    }

    func testRequestAcceptsAdjacentReadableExecutableRegionsAndRejectsCoverageGapsAndExecuteOnlyMemory() throws {
        let codec = NativeDecompilerWireCodec()
        let request = makeRequestEnvelope()
        let first = NativeDecompilerWireMemoryRegion(
            name: "__text.0", startAddress: .init(0x1000), permissions: .readExecute,
            rawBytes: Data([0x10, 0x20]), effectiveBytes: Data([0xAA, 0xBB]), appliedPatchIDs: []
        )
        let second = NativeDecompilerWireMemoryRegion(
            name: "__text.1", startAddress: .init(0x1002), permissions: .readWriteExecute,
            rawBytes: Data([0x30, 0x40]), effectiveBytes: Data([0xCC, 0xDD]), appliedPatchIDs: []
        )
        let adjacent = replacingRequest(request, memoryRegions: [second, first])

        XCTAssertNoThrow(try codec.encodeRequest(adjacent, matching: requestID))
        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(request, memoryRegions: [
                first,
                .init(
                    name: "__text.gap", startAddress: .init(0x1003), permissions: .readExecute,
                    rawBytes: Data([0x30, 0x40]), effectiveBytes: Data([0xCC, 0xDD]), appliedPatchIDs: []
                ),
            ]),
            matching: requestID
        ))
        for permissions in [NativeDecompilerWireMemoryPermissions.execute, .writeExecute] {
            XCTAssertThrowsError(try codec.encodeRequest(
                replacingRequest(request, memoryRegions: [
                    .init(
                        name: "__text", startAddress: .init(0x1000), permissions: permissions,
                        rawBytes: Data([0x10, 0x20, 0x30, 0x40]),
                        effectiveBytes: Data([0xAA, 0xBB, 0xCC, 0xDD]), appliedPatchIDs: []
                    ),
                ]),
                matching: requestID
            ), permissions.rawValue)
        }
    }

    func testRequestMatchesNativeRegionRecordAndTextBounds() throws {
        let codec = NativeDecompilerWireCodec()
        let request = makeRequestEnvelope()
        let regions = (0 ..< 256).map { index in
            NativeDecompilerWireMemoryRegion(
                name: String(repeating: "r", count: 256),
                startAddress: .init(0x1000 + UInt64(index)), permissions: .readExecute,
                rawBytes: Data([UInt8(truncatingIfNeeded: index)]),
                effectiveBytes: Data([UInt8(truncatingIfNeeded: index)]), appliedPatchIDs: []
            )
        }
        let function = NativeDecompilerWireFunctionIdentity(
            functionID: String(repeating: "f", count: 256),
            name: String(repeating: "n", count: 1_024), entryAddress: .init(0x1000),
            endAddressExclusive: .init(0x1100)
        )
        let bounded = replacingRequest(
            request, function: function, memoryRegions: regions,
            budgets: NativeDecompilerProductBudgetProfile.v1.wireValue
        )
        XCTAssertNoThrow(try codec.encodeRequest(bounded, matching: requestID))

        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(bounded, memoryRegions: regions + [
                .init(
                    name: "overflow", startAddress: .init(0x1100), permissions: .readExecute,
                    rawBytes: Data([0]), effectiveBytes: Data([0]), appliedPatchIDs: []
                ),
            ]),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(
                request,
                function: .init(
                    functionID: String(repeating: "f", count: 257), name: "main",
                    entryAddress: .init(0x1000), endAddressExclusive: .init(0x1004)
                )
            ),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(
                request,
                function: .init(
                    functionID: "function:main", name: String(repeating: "n", count: 1_025),
                    entryAddress: .init(0x1000), endAddressExclusive: .init(0x1004)
                )
            ),
            matching: requestID
        ))
    }

    func testRequestRejectsCrossImageAndDuplicateSymbolAndAuthoredNameRecords() throws {
        let codec = NativeDecompilerWireCodec()
        let request = makeRequestEnvelope()
        let symbol = try XCTUnwrap(request.body.symbols.first)
        let name = NativeDecompilerWireAuthoredName(
            address: .init(0x1000), subjectKind: .function, name: "main"
        )

        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(request, symbols: [
                .init(imageID: "image:other", address: symbol.address, name: symbol.name, kind: symbol.kind),
            ]),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(request, symbols: [symbol, symbol]), matching: requestID
        ))
        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(
                request,
                authoredInputs: replacingAuthoredInputs(request.body.authoredInputs, names: [name, name])
            ),
            matching: requestID
        ))
    }

    func testRequestEnforcesNativeSymbolAndAuthoredNameRecordBounds() throws {
        let codec = NativeDecompilerWireCodec()
        let request = makeRequestEnvelope()
        let symbols = (0 ... 100_000).map { index in
            NativeDecompilerWireSymbolRecord(
                imageID: request.body.image.imageID, address: .init(UInt64(index)),
                name: "symbol-\(index)", kind: .function
            )
        }
        XCTAssertNoThrow(try codec.encodeRequest(
            replacingRequest(request, symbols: Array(symbols.dropLast())), matching: requestID
        ))
        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(request, symbols: symbols), matching: requestID
        ))

        let names = (0 ... 4_096).map { index in
            NativeDecompilerWireAuthoredName(
                address: .init(UInt64(index)), subjectKind: .data, name: "name-\(index)"
            )
        }
        XCTAssertNoThrow(try codec.encodeRequest(
            replacingRequest(
                request,
                authoredInputs: replacingAuthoredInputs(
                    request.body.authoredInputs,
                    names: Array(names.dropLast())
                )
            ),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(
                request,
                authoredInputs: replacingAuthoredInputs(request.body.authoredInputs, names: names)
            ),
            matching: requestID
        ))
    }

    func testRequestMatchesEveryNativeInputTextBoundary() throws {
        let codec = NativeDecompilerWireCodec()
        let request = makeRequestEnvelope()
        let imageID = String(repeating: "i", count: 256)
        let boundedImage = NativeDecompilerWireImageIdentity(
            imageID: imageID, uuid: request.body.image.uuid,
            preferredLoadAddress: request.body.image.preferredLoadAddress
        )
        let boundedRegion = NativeDecompilerWireMemoryRegion(
            name: String(repeating: "r", count: 256),
            startAddress: .init(0x1000), permissions: .readExecute,
            rawBytes: Data([0x10, 0x20, 0x30, 0x40]),
            effectiveBytes: Data([0xAA, 0xBB, 0xCC, 0xDD]), appliedPatchIDs: []
        )
        let boundedSymbol = NativeDecompilerWireSymbolRecord(
            imageID: imageID, address: .init(0x1000),
            name: String(repeating: "s", count: 1_024), kind: .function
        )
        let boundedName = NativeDecompilerWireAuthoredName(
            address: .init(0x1000), subjectKind: .function,
            name: String(repeating: "t", count: 1_024)
        )
        XCTAssertNoThrow(try codec.encodeRequest(
            replacingRequest(
                request, image: boundedImage, memoryRegions: [boundedRegion],
                symbols: [boundedSymbol],
                authoredInputs: replacingAuthoredInputs(
                    request.body.authoredInputs,
                    names: [boundedName]
                )
            ),
            matching: requestID
        ))

        let overlongImageID = String(repeating: "i", count: 257)
        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(
                request,
                image: .init(
                    imageID: overlongImageID, uuid: request.body.image.uuid,
                    preferredLoadAddress: request.body.image.preferredLoadAddress
                ),
                symbols: [
                    .init(
                        imageID: overlongImageID, address: .init(0x1000),
                        name: "main", kind: .function
                    ),
                ]
            ),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(request, memoryRegions: [
                .init(
                    name: String(repeating: "r", count: 257), startAddress: .init(0x1000),
                    permissions: .readExecute, rawBytes: Data([0x10, 0x20, 0x30, 0x40]),
                    effectiveBytes: Data([0xAA, 0xBB, 0xCC, 0xDD]), appliedPatchIDs: []
                ),
            ]),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(request, symbols: [
                .init(
                    imageID: request.body.image.imageID, address: .init(0x1000),
                    name: String(repeating: "s", count: 1_025), kind: .function
                ),
            ]),
            matching: requestID
        ))
        XCTAssertThrowsError(try codec.encodeRequest(
            replacingRequest(
                request,
                authoredInputs: replacingAuthoredInputs(
                    request.body.authoredInputs,
                    names: [.init(
                        address: .init(0x1000), subjectKind: .function,
                        name: String(repeating: "t", count: 1_025)
                    )]
                )
            ),
            matching: requestID
        ))
    }

    func testSuccessReplyCannotBeTrustedByUUIDWithoutExactRequestIdentity() throws {
        let codec = NativeDecompilerWireCodec()
        let valid = try codec.encodeReply(makeBaselineSuccessReply(), matching: expectedBinding)
        XCTAssertThrowsError(try codec.encodeReply(makeBaselineSuccessReply(), matching: requestID))
        XCTAssertThrowsError(try codec.decodeReply(valid, matching: requestID))
        var differentImageID = try mutate(
            valid, path: ["success", "result", "image", "imageID"], value: "image:other"
        )
        for path in [
            ["success", "result", "instructions", "0", "sourceRanges", "0", "imageID"],
            ["success", "result", "operations", "0", "sourceRanges", "0", "imageID"],
            ["success", "result", "regions", "0", "sourceRanges", "0", "imageID"],
        ] {
            differentImageID = try mutate(differentImageID, path: path, value: "image:other")
        }

        let rawMutations: [Data] = [
            try mutate(
                valid, path: ["success", "result", "requestID"],
                value: "00000000-0000-0000-0000-00000000000B"
            ),
            try mutate(valid, path: ["success", "result", "requestSHA256"], value: String(repeating: "b", count: 64)),
            differentImageID,
            try mutate(
                valid, path: ["success", "result", "image", "uuid"],
                value: "20000000-0000-0000-0000-000000000002"
            ),
            try mutate(
                valid, path: ["success", "result", "image", "preferredLoadAddress"],
                value: "0000000000002000"
            ),
            try mutate(valid, path: ["success", "result", "function", "functionID"], value: "function:other"),
            try mutate(valid, path: ["success", "result", "function", "name"], value: "other"),
            try mutate(
                valid, path: ["success", "result", "function", "entryAddress"],
                value: "0000000000000fff"
            ),
            try mutate(
                valid, path: ["success", "result", "function", "endAddressExclusive"],
                value: "0000000000001005"
            ),
        ]
        let mutations = try rawMutations.map(canonicallyEncodeReplyMutation)
        for mutation in mutations {
            XCTAssertThrowsError(try codec.decodeReply(mutation, matching: expectedBinding)) { error in
                XCTAssertEqual(error as? NativeDecompilerWireCodecError, .requestBindingMismatch)
            }
        }
    }

    func testSuccessReplyExhaustivelyRoundTripsEveryStructuredResultRecordInSemanticOrder() throws {
        let codec = NativeDecompilerWireCodec()
        let fixture = makeFullSuccessFixture()
        let data = try codec.encodeReply(fixture.reply, matching: fixture.binding)
        let decoded = try codec.decodeReply(data, matching: fixture.binding)

        XCTAssertEqual(decoded, fixture.reply)
        XCTAssertEqual(decoded.success?.result.operations[0].authenticationEffect,
                       NativeDecompilerWireAuthenticationEffect.none)
        XCTAssertEqual(decoded.success?.result.operations[0].inputVarnodeIDs, ["vn.condition"])
        XCTAssertEqual(decoded.success?.result.types[0].parameterTypeIDs, ["type.u64"])
        XCTAssertEqual(decoded.success?.result.calls[0].argumentVariableIDs, ["variable.argument"])
        XCTAssertEqual(decoded.success?.result.regions[1].childRegionIDs, ["region.child"])
        XCTAssertEqual(decoded.success?.result.tokens.map(\.text), ["if", "callee", "result"])
        XCTAssertEqual(
            decoded.success?.result.pseudocodeDocument?.text,
            "uint64_t fixture(uint64_t argument) {\n\treturn argument;\n}\n"
        )
        XCTAssertEqual(decoded.success?.result.pseudocodeDocument?.language, "c")
        XCTAssertEqual(data, try codec.encodeReply(fixture.reply, matching: fixture.binding))
    }

    func testAuthenticationEffectClosedDictionaryRejectsLossyAndForgedPayloads() throws {
        let codec = NativeDecompilerWireCodec()
        let fixture = makeFullSuccessFixture()
        let valid = try codec.encodeReply(fixture.reply, matching: fixture.binding)
        let path = ["success", "result", "operations", "0", "authenticationEffect"]
        XCTAssertThrowsError(try codec.decodeReply(try removing(valid, path: path), matching: fixture.binding))
        let effects: [[String: Any]] = [
            ["kind": "unknown"], ["kind": "transformed-output"],
            ["kind": "none", "outputSSAValueID": "ssa.right"],
            ["kind": "none", "unexpected": true],
            ["kind": "transformed-output", "outputSSAValueID": ""],
        ]
        for effect in effects {
            XCTAssertThrowsError(try codec.decodeReply(try mutate(valid, path: path, value: effect),
                matching: fixture.binding))
        }
    }

    func testPseudocodeDocumentUsesAnOptionalExactShapeAndSchemaV1IsRejected() throws {
        let codec = NativeDecompilerWireCodec()
        let fixture = makeFullSuccessFixture()
        let valid = try codec.encodeReply(fixture.reply, matching: fixture.binding)

        XCTAssertNoThrow(try codec.decodeReply(valid, matching: fixture.binding))
        XCTAssertThrowsError(try codec.decodeReply(
            try mutate(valid, path: ["schemaVersion"], value: UInt32(1)),
            matching: fixture.binding
        ))
        XCTAssertThrowsError(try codec.decodeReply(
            try removing(
                valid,
                path: ["success", "result", "pseudocodeDocument", "text"]
            ),
            matching: fixture.binding
        ))
        XCTAssertThrowsError(try codec.decodeReply(
            try mutate(
                valid,
                path: ["success", "result", "pseudocodeDocument", "unexpected"],
                value: true
            ),
            matching: fixture.binding
        ))

        let withoutDocument = makeBaselineSuccessReply()
        let withoutDocumentData = try codec.encodeReply(
            withoutDocument,
            matching: expectedBinding
        )
        XCTAssertNil(
            try codec.decodeReply(withoutDocumentData, matching: expectedBinding)
                .success?.result.pseudocodeDocument
        )
    }

    func testDisabledCapabilitiesRequireTheirPublishedArraysAndReferencesToRemainEmpty() throws {
        let codec = NativeDecompilerWireCodec()
        let reply = makeBaselineSuccessReply()
        let data = try codec.encodeReply(reply, matching: expectedBinding)
        let decoded = try codec.decodeReply(data, matching: expectedBinding)
        let result = try XCTUnwrap(decoded.success?.result)

        XCTAssertTrue(result.types.isEmpty)
        XCTAssertTrue(result.phis.isEmpty)
        XCTAssertTrue(result.memoryVersions.isEmpty)
        XCTAssertTrue(result.memoryPhis.isEmpty)
        XCTAssertTrue(result.memoryEffects.isEmpty)
        XCTAssertTrue(result.variables.isEmpty)
        XCTAssertTrue(result.tokens.isEmpty)

        let invalid = NativeDecompilerWireReplyEnvelope(
            requestID: requestID,
            success: NativeDecompilerWireSuccess(
                availability: reply.success!.availability,
                result: replacing(reply.success!.result, memoryVersions: [
                    .init(
                        id: "memory:0", partition: "ram", kind: .functionEntry,
                        definingOperationID: nil, definingMemoryPhiID: nil
                    ),
                ])
            )
        )
        XCTAssertThrowsError(try codec.encodeReply(invalid, matching: expectedBinding))
    }

    func testReplyUnionRejectsUnknownKeysWrongShapeWrongIDMalformedEnumsAndRanges() throws {
        let codec = NativeDecompilerWireCodec()
        let valid = try codec.encodeReply(makeBaselineSuccessReply(), matching: expectedBinding)

        XCTAssertThrowsError(try codec.decodeReply(
            try mutate(valid, path: ["unknown"], value: true), matching: expectedBinding
        ))
        XCTAssertThrowsError(try codec.decodeReply(
            try mutate(valid, path: ["outcome"], value: "partial"), matching: expectedBinding
        ))
        XCTAssertThrowsError(try codec.decodeReply(
            try mutate(valid, path: ["failure"], value: ["code": "busy"]), matching: expectedBinding
        ))
        let wrongRequestID = UUID()
        let expectedRequest = makeRequestEnvelope()
        let body = expectedRequest.body
        let wrongBinding = NativeDecompilerWireExpectedRequestBinding(request: .init(
            requestID: wrongRequestID,
            body: .init(
                requestID: wrongRequestID, requestSHA256: body.requestSHA256,
                target: body.target,
                image: body.image, function: body.function, memoryRegions: body.memoryRegions,
                symbols: body.symbols, authoredInputs: body.authoredInputs, budgets: body.budgets
            )
        ))
        XCTAssertThrowsError(try codec.decodeReply(valid, matching: wrongBinding))
        XCTAssertThrowsError(try codec.decodeReply(
            try mutate(
                valid,
                path: ["success", "result", "instructions", "0", "sourceRanges", "0", "endAddressExclusive"],
                value: "0000000000001000"
            ),
            matching: expectedBinding
        ))
    }

    func testReplyDecoderRejectsMissingArrayOptionalPairViolationAndOversizeResponse() throws {
        let codec = NativeDecompilerWireCodec()
        let fixture = makeFullSuccessFixture()
        let valid = try codec.encodeReply(fixture.reply, matching: fixture.binding)

        XCTAssertThrowsError(try codec.decodeReply(
            try removing(valid, path: ["success", "result", "warnings"]), matching: fixture.binding
        ))
        XCTAssertThrowsError(try codec.decodeReply(
            try removing(
                valid,
                path: ["success", "result", "phis", "0", "incoming", "0", "edgeID"]
            ),
            matching: fixture.binding
        ))
        XCTAssertThrowsError(try codec.decodeReply(
            Data(repeating: 0, count: NativeDecompilerWireCodec.maximumResponseBytes + 1),
            matching: fixture.binding
        ))
    }

    func testReplyRejectsDuplicateSemanticIDsAndIncompleteOptionalDefinitions() throws {
        let codec = NativeDecompilerWireCodec()
        let fixture = makeFullSuccessFixture()
        let valid = try codec.encodeReply(fixture.reply, matching: fixture.binding)

        XCTAssertThrowsError(try codec.decodeReply(
            try duplicatingFirstElement(
                valid, path: ["success", "result", "instructions"]
            ),
            matching: fixture.binding
        ))
        let missingInput = try removing(
            valid,
            path: ["success", "result", "memoryEffects", "0", "inputMemoryVersionID"]
        )
        XCTAssertThrowsError(try codec.decodeReply(
            try removing(
                missingInput,
                path: ["success", "result", "memoryEffects", "0", "outputMemoryVersionID"]
            ),
            matching: fixture.binding
        ))
    }

    func testFrozenEnumTagsContainNoUppercaseCharacters() {
        for opcode in NativeDecompilerWireOpcode.allCases {
            XCTAssertEqual(opcode.rawValue, opcode.rawValue.lowercased())
        }
        for code in NativeDecompilerWireFailureCode.allCases {
            XCTAssertEqual(code.rawValue, code.rawValue.lowercased())
        }
    }

    func testFailureReplyRoundTripsEveryStableCodeAndRejectsUnsafeDetail() throws {
        let codec = NativeDecompilerWireCodec()
        for code in NativeDecompilerWireFailureCode.allCases {
            let reply = NativeDecompilerWireReplyEnvelope(
                requestID: requestID,
                failure: .init(code: code, detail: "bounded-detail")
            )
            XCTAssertEqual(
                try codec.decodeReply(codec.encodeReply(reply, matching: requestID), matching: requestID),
                reply
            )
        }

        let newline = NativeDecompilerWireReplyEnvelope(
            requestID: requestID,
            failure: .init(code: .nativeFailure, detail: "unsafe\ntext")
        )
        let tooLong = NativeDecompilerWireReplyEnvelope(
            requestID: requestID,
            failure: .init(code: .nativeFailure, detail: String(repeating: "x", count: 1_025))
        )
        let path = NativeDecompilerWireReplyEnvelope(
            requestID: requestID,
            failure: .init(code: .nativeFailure, detail: "/Users/person/private-input")
        )
        XCTAssertThrowsError(try codec.encodeReply(newline, matching: requestID))
        XCTAssertThrowsError(try codec.encodeReply(tooLong, matching: requestID))
        XCTAssertThrowsError(try codec.encodeReply(path, matching: requestID))
    }

    func testReplyDecoderRejectsNoncanonicalDictionaryOrdering() throws {
        let codec = NativeDecompilerWireCodec()
        let reply = NativeDecompilerWireReplyEnvelope(
            requestID: requestID,
            failure: .init(code: .cancelled, detail: nil)
        )
        let canonical = try codec.encodeReply(reply, matching: requestID)
        let foundationCanonical = try PropertyListSerialization.data(
            fromPropertyList: PropertyListSerialization.propertyList(
                from: canonical, options: [], format: nil
            ),
            format: .binary,
            options: 0
        )
        let reordered = try reorderingTopDictionary(canonical)

        XCTAssertNotEqual(reordered, canonical)
        XCTAssertNoThrow(try codec.decodeReply(foundationCanonical, matching: requestID))
        XCTAssertThrowsError(try codec.decodeReply(reordered, matching: requestID))
    }

    func testXPCProtocolSurfaceHasOnlyUUIDAndDataMessages() {
        let interface = NSXPCInterface(with: NativeDecompilerXPCProtocol.self)
        XCTAssertTrue(
            NSStringFromProtocol(interface.protocol).hasSuffix("NativeDecompilerXPCProtocol")
        )
        XCTAssertEqual(
            NSStringFromSelector(#selector(NativeDecompilerXPCProtocol.decompile(requestID:payload:withReply:))),
            "decompileWithRequestID:payload:withReply:"
        )
        XCTAssertEqual(
            NSStringFromSelector(#selector(NativeDecompilerXPCProtocol.cancel(requestID:))),
            "cancelWithRequestID:"
        )

        let probe = NativeDecompilerXPCProtocolSurfaceProbe()
        let requestID = NSUUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let payload = Data([0xAA, 0xBB]) as NSData
        var reply: NSData?
        probe.decompile(requestID: requestID, payload: payload) { reply = $0 }
        probe.cancel(requestID: requestID)

        XCTAssertTrue(probe.requestID === requestID)
        XCTAssertTrue(probe.payload === payload)
        XCTAssertTrue(reply === payload)
        XCTAssertTrue(probe.cancelledRequestID === requestID)
    }
}

private final class NativeDecompilerXPCProtocolSurfaceProbe: NSObject,
    NativeDecompilerXPCProtocol
{
    private(set) var requestID: NSUUID?
    private(set) var payload: NSData?
    private(set) var cancelledRequestID: NSUUID?

    func decompile(
        requestID: NSUUID,
        payload: NSData,
        withReply reply: @escaping (NSData) -> Void
    ) {
        self.requestID = requestID
        self.payload = payload
        reply(payload)
    }

    func cancel(requestID: NSUUID) {
        cancelledRequestID = requestID
    }
}

private extension NativeDecompilerWireCodecTests {
    func makeSparseRequest() -> NativeDecompilerWireRequestEnvelope {
        let base = makeRequestEnvelope()
        let function = NativeDecompilerWireFunctionIdentity(
            functionID: base.body.function.functionID,
            name: base.body.function.name,
            entryAddress: .init(0x1000),
            endAddressExclusive: .init(0x1014),
            codeRanges: [
                .init(startAddress: .init(0x1000), endAddressExclusive: .init(0x1004)),
                .init(startAddress: .init(0x1010), endAddressExclusive: .init(0x1014)),
            ]
        )
        let regions = [
            base.body.memoryRegions[0],
            NativeDecompilerWireMemoryRegion(
                name: "__cold", startAddress: .init(0x1010), permissions: .readExecute,
                rawBytes: Data([1, 2, 3, 4]), effectiveBytes: Data([1, 2, 3, 4]),
                appliedPatchIDs: []
            ),
        ]
        let digest = try! NativeDecompilerWireCanonicalRequest.sha256(
            schemaVersion: 4, operation: .decompile, target: base.body.target,
            image: base.body.image, function: function, memoryRegions: regions,
            symbols: base.body.symbols, authoredInputs: base.body.authoredInputs,
            budgets: NativeDecompilerProductBudgetProfile.v1
        )
        return .init(schemaVersion: 4, requestID: requestID, body: .init(
            requestID: requestID, requestSHA256: digest, target: base.body.target,
            image: base.body.image, function: function, memoryRegions: regions,
            symbols: base.body.symbols, authoredInputs: base.body.authoredInputs,
            budgets: base.body.budgets
        ))
    }

    func replacingSparseRequest(
        _ request: NativeDecompilerWireRequestEnvelope,
        ranges: [NativeDecompilerWireCodeRange]
    ) -> NativeDecompilerWireRequestEnvelope {
        let body = request.body
        let function = NativeDecompilerWireFunctionIdentity(
            functionID: body.function.functionID, name: body.function.name,
            entryAddress: body.function.entryAddress,
            endAddressExclusive: body.function.endAddressExclusive,
            codeRanges: ranges
        )
        let digest = try! NativeDecompilerWireCanonicalRequest.sha256(
            schemaVersion: 4, operation: .decompile, target: body.target,
            image: body.image, function: function, memoryRegions: body.memoryRegions,
            symbols: body.symbols, authoredInputs: body.authoredInputs,
            budgets: NativeDecompilerProductBudgetProfile.v1
        )
        return .init(schemaVersion: 4, requestID: requestID, body: .init(
            requestID: requestID, requestSHA256: digest, target: body.target,
            image: body.image, function: function, memoryRegions: body.memoryRegions,
            symbols: body.symbols, authoredInputs: body.authoredInputs,
            budgets: body.budgets
        ))
    }

    func makeRequestEnvelope() -> NativeDecompilerWireRequestEnvelope {
        let target = try! NativeDecompilerSealedTargetProfile.normalizedTarget(
            rawCPUType: 0x0100_000c,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "a", count: 64),
            selectedSliceByteCount: 4
        )
        let image = NativeDecompilerWireImageIdentity(
            imageID: "image:main",
            uuid: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            preferredLoadAddress: .init(0x1000)
        )
        let function = NativeDecompilerWireFunctionIdentity(
            functionID: "function:main",
            name: "main",
            entryAddress: .init(0x1000),
            endAddressExclusive: .init(0x1004)
        )
        let memoryRegions = [
            NativeDecompilerWireMemoryRegion(
                name: "__text",
                startAddress: .init(0x1000),
                permissions: .readExecute,
                rawBytes: Data([0x10, 0x20, 0x30, 0x40]),
                effectiveBytes: Data([0xAA, 0xBB, 0xCC, 0xDD]),
                appliedPatchIDs: ["patch000001", "patch000002"]
            ),
        ]
        let symbols = [
            NativeDecompilerWireSymbolRecord(
                imageID: "image:main",
                address: .init(0x1000),
                name: "main",
                kind: .function
            ),
        ]
        let authoredInputs = NativeDecompilerWireAuthoredInputs.empty
        let budgets = NativeDecompilerProductBudgetProfile.v1
        let requestSHA256 = try! NativeDecompilerWireCanonicalRequest.sha256(
            schemaVersion: NativeDecompilerWireRequestEnvelope.currentSchemaVersion,
            operation: .decompile,
            target: target,
            image: image,
            function: function,
            memoryRegions: memoryRegions,
            symbols: symbols,
            authoredInputs: authoredInputs,
            budgets: budgets
        )
        return NativeDecompilerWireRequestEnvelope(
            requestID: requestID,
            body: .init(
                requestID: requestID,
                requestSHA256: requestSHA256,
                target: target,
                image: image,
                function: function,
                memoryRegions: memoryRegions,
                symbols: symbols,
                authoredInputs: authoredInputs,
                budgets: budgets.wireValue
            )
        )
    }

    func replacingRequest(
        _ envelope: NativeDecompilerWireRequestEnvelope,
        image: NativeDecompilerWireImageIdentity? = nil,
        function: NativeDecompilerWireFunctionIdentity? = nil,
        memoryRegions: [NativeDecompilerWireMemoryRegion]? = nil,
        symbols: [NativeDecompilerWireSymbolRecord]? = nil,
        authoredInputs: NativeDecompilerWireAuthoredInputs? = nil,
        budgets: NativeDecompilerWireAnalysisBudgets? = nil
    ) -> NativeDecompilerWireRequestEnvelope {
        let body = envelope.body
        let selectedImage = image ?? body.image
        let selectedFunction = function ?? body.function
        let selectedRegions = memoryRegions ?? body.memoryRegions
        let selectedSymbols = symbols ?? body.symbols
        let selectedAuthoredInputs = authoredInputs ?? body.authoredInputs
        let selectedBudgets = budgets ?? body.budgets
        let requestSHA256 = (try? NativeDecompilerWireCanonicalRequest.sha256(
            schemaVersion: envelope.schemaVersion,
            operation: envelope.operation,
            target: body.target,
            image: selectedImage,
            function: selectedFunction,
            memoryRegions: selectedRegions,
            symbols: selectedSymbols,
            authoredInputs: selectedAuthoredInputs,
            budgets: NativeDecompilerProductBudgetProfile.v1
        )) ?? body.requestSHA256
        return .init(
            schemaVersion: envelope.schemaVersion, requestID: envelope.requestID,
            operation: envelope.operation,
            body: .init(
                requestID: body.requestID, requestSHA256: requestSHA256,
                target: body.target,
                image: selectedImage, function: selectedFunction,
                memoryRegions: selectedRegions,
                symbols: selectedSymbols,
                authoredInputs: selectedAuthoredInputs,
                budgets: selectedBudgets
            )
        )
    }

    func replacingAuthoredInputs(
        _ value: NativeDecompilerWireAuthoredInputs,
        names: [NativeDecompilerWireAuthoredName]
    ) -> NativeDecompilerWireAuthoredInputs {
        .init(
            schemaVersion: value.schemaVersion,
            names: names,
            signatures: value.signatures,
            appliedTypes: value.appliedTypes,
            typeDefinitions: value.typeDefinitions
        )
    }

    func makeBaselineSuccessReply() -> NativeDecompilerWireReplyEnvelope {
        let request = makeRequestEnvelope()
        let range = NativeDecompilerWireSourceRange(
            imageID: "image:main", startAddress: .init(0x1000), endAddressExclusive: .init(0x1004)
        )
        let result = NativeDecompilerWireStructuredResult(
            requestID: requestID,
            requestSHA256: request.body.requestSHA256,
            image: request.body.image,
            function: request.body.function,
            addressSpaces: [
                .init(id: "space:ram", name: "ram", kind: .processor, addressSizeBytes: 8, isProcessorSpace: true),
            ],
            types: [],
            instructions: [
                .init(
                    id: "instruction:0", address: .init(0x1000), bytes: Data([0xAA, 0xBB, 0xCC, 0xDD]),
                    mnemonic: "ret", body: "", operationIDs: ["operation:0"], sourceRanges: [range]
                ),
            ],
            varnodes: [
                .init(
                    id: "varnode:0", addressSpaceID: "space:ram", offset: .init(0), sizeBytes: 8,
                    role: .register, typeID: nil, registerName: "x0"
                ),
            ],
            operations: [
                .init(
                    id: "operation:0", blockID: "block:0", sequence: .init(0), opcode: .return,
                    outputVarnodeID: nil, inputVarnodeIDs: ["varnode:0"], directTargetAddress: nil,
                    sourceRanges: [range]
                ),
            ],
            blocks: [
                .init(
                    id: "block:0", startAddress: .init(0x1000), endAddressExclusive: .init(0x1004),
                    operationIDs: ["operation:0"], predecessorEdgeIDs: [], successorEdgeIDs: [],
                    terminatorKind: .return
                ),
            ],
            edges: [],
            ssaValues: [
                .init(
                    id: "ssa:0", varnodeID: "varnode:0", kind: .functionEntry,
                    definingOperationID: nil, definingPhiID: nil
                ),
            ],
            ssaBindings: [
                .init(operationID: "operation:0", inputSSAValueIDs: ["ssa:0"], outputSSAValueID: nil),
            ],
            phis: [], memoryVersions: [], memoryPhis: [], memoryEffects: [], variables: [], calls: [],
            regions: [
                .init(
                    id: "region:root", kind: .root, parentRegionID: nil, childRegionIDs: [],
                    blockIDs: ["block:0"], conditionOperationID: nil, sourceRanges: [range]
                ),
            ],
            tokens: [], warnings: []
        )
        return .init(
            requestID: requestID,
            success: .init(
                availability: .init(
                    available: true,
                    reasonCode: "",
                    runtimeIdentity: .init(
                        backendID: "native-decompiler", engineVersion: "12.1.2",
                        engineRevision: String(repeating: "b", count: 40), wrapperVersion: "dcp03b5-v1",
                        wrapperRevision: String(repeating: "c", count: 40),
                        packageManifestSHA256: String(repeating: "d", count: 64),
                        packageTreeSHA256: String(repeating: "e", count: 64),
                        languageID: "AARCH64:LE:64:AppleSilicon", compilerSpecID: "default",
                        targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
                        contextProfileSHA256: "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
                    ),
                    capabilities: .init(
                        nativeDecompilerHeritage: true, completeRegisterSSA: false, memorySSA: false,
                        recoveredVariables: false, recoveredTypes: false, structuredControlFlow: true,
                        tokenizedPseudocode: false, imageQualifiedSourceRanges: true
                    )
                ),
                result: result
            )
        )
    }

    func makeFullSuccessFixture() -> (
        reply: NativeDecompilerWireReplyEnvelope,
        binding: NativeDecompilerWireExpectedRequestBinding
    ) {
        let fixture = makeNativeDecompilerWireSemanticValidatorTestFixture()
        let request = NativeDecompilerWireRequestEnvelope(
            requestID: fixture.request.requestID,
            body: fixture.request
        )
        let availability = NativeDecompilerWireBackendAvailability(
            available: true,
            reasonCode: "",
            runtimeIdentity: makeBaselineSuccessReply().success!.availability.runtimeIdentity,
            capabilities: fixture.capabilities
        )
        return (
            NativeDecompilerWireReplyEnvelope(
                requestID: fixture.request.requestID,
                success: .init(availability: availability, result: fixture.result)
            ),
            NativeDecompilerWireExpectedRequestBinding(request: request)
        )
    }

    func replacing(
        _ result: NativeDecompilerWireStructuredResult,
        memoryVersions: [NativeDecompilerWireMemoryVersionRecord]
    ) -> NativeDecompilerWireStructuredResult {
        .init(
            requestID: result.requestID, requestSHA256: result.requestSHA256,
            image: result.image, function: result.function, addressSpaces: result.addressSpaces,
            types: result.types, instructions: result.instructions, varnodes: result.varnodes,
            operations: result.operations, blocks: result.blocks, edges: result.edges,
            ssaValues: result.ssaValues, ssaBindings: result.ssaBindings, phis: result.phis,
            memoryVersions: memoryVersions, memoryPhis: result.memoryPhis,
            memoryEffects: result.memoryEffects, variables: result.variables, calls: result.calls,
            regions: result.regions, tokens: result.tokens,
            pseudocodeDocument: result.pseudocodeDocument, warnings: result.warnings
        )
    }

    func replacing(
        _ result: NativeDecompilerWireStructuredResult,
        instructions: [NativeDecompilerWireInstructionRecord]
    ) -> NativeDecompilerWireStructuredResult {
        .init(
            requestID: result.requestID, requestSHA256: result.requestSHA256,
            image: result.image, function: result.function, addressSpaces: result.addressSpaces,
            types: result.types, instructions: instructions, varnodes: result.varnodes,
            operations: result.operations, blocks: result.blocks, edges: result.edges,
            ssaValues: result.ssaValues, ssaBindings: result.ssaBindings, phis: result.phis,
            memoryVersions: result.memoryVersions, memoryPhis: result.memoryPhis,
            memoryEffects: result.memoryEffects, variables: result.variables, calls: result.calls,
            regions: result.regions, tokens: result.tokens,
            pseudocodeDocument: result.pseudocodeDocument, warnings: result.warnings
        )
    }

    func replacing(
        _ result: NativeDecompilerWireStructuredResult,
        function: NativeDecompilerWireFunctionIdentity
    ) -> NativeDecompilerWireStructuredResult {
        .init(
            requestID: result.requestID, requestSHA256: result.requestSHA256,
            image: result.image, function: function, addressSpaces: result.addressSpaces,
            types: result.types, instructions: result.instructions, varnodes: result.varnodes,
            operations: result.operations, blocks: result.blocks, edges: result.edges,
            ssaValues: result.ssaValues, ssaBindings: result.ssaBindings, phis: result.phis,
            memoryVersions: result.memoryVersions, memoryPhis: result.memoryPhis,
            memoryEffects: result.memoryEffects, variables: result.variables, calls: result.calls,
            regions: result.regions, tokens: result.tokens,
            pseudocodeDocument: result.pseudocodeDocument, warnings: result.warnings,
            blockPartition: result.blockPartition
        )
    }

    func mutate(_ data: Data, path: [String], value: Any) throws -> Data {
        let root = try mutablePropertyList(data)
        try set(value, in: root, path: path[...])
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    func canonicallyEncodeReplyMutation(_ data: Data) throws -> Data {
        let reply = try PropertyListDecoder().decode(NativeDecompilerWireReplyEnvelope.self, from: data)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(reply)
    }

    func removing(_ data: Data, path: [String]) throws -> Data {
        let root = try mutablePropertyList(data)
        try remove(in: root, path: path[...])
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    func mutablePropertyList(_ data: Data) throws -> NSMutableDictionary {
        let object = try PropertyListSerialization.propertyList(
            from: data, options: [.mutableContainersAndLeaves], format: nil
        )
        return try XCTUnwrap(object as? NSMutableDictionary)
    }

    func reorderingTopDictionary(_ data: Data) throws -> Data {
        guard data.count >= 40 else { throw CocoaError(.coderReadCorrupt) }
        var reordered = data
        let trailer = data.count - 32
        let offsetSize = Int(data[trailer + 6])
        let referenceSize = Int(data[trailer + 7])
        let topObject = try binaryInteger(data, at: trailer + 16, byteCount: 8)
        let offsetTable = try binaryInteger(data, at: trailer + 24, byteCount: 8)
        let topOffset = try binaryInteger(
            data,
            at: offsetTable + topObject * offsetSize,
            byteCount: offsetSize
        )
        let marker = data[topOffset]
        guard marker >> 4 == 0x0d, marker & 0x0f >= 3, marker & 0x0f < 0x0f else {
            throw CocoaError(.coderReadCorrupt)
        }
        let count = Int(marker & 0x0f)
        let keysStart = topOffset + 1
        let valuesStart = keysStart + count * referenceSize
        let firstKey = reordered.subdata(in: keysStart..<(keysStart + referenceSize))
        let lastKeyStart = keysStart + (count - 1) * referenceSize
        let lastKey = reordered.subdata(in: lastKeyStart..<(lastKeyStart + referenceSize))
        let firstValue = reordered.subdata(in: valuesStart..<(valuesStart + referenceSize))
        let lastValueStart = valuesStart + (count - 1) * referenceSize
        let lastValue = reordered.subdata(in: lastValueStart..<(lastValueStart + referenceSize))
        reordered.replaceSubrange(keysStart..<(keysStart + referenceSize), with: lastKey)
        reordered.replaceSubrange(lastKeyStart..<(lastKeyStart + referenceSize), with: firstKey)
        reordered.replaceSubrange(valuesStart..<(valuesStart + referenceSize), with: lastValue)
        reordered.replaceSubrange(lastValueStart..<(lastValueStart + referenceSize), with: firstValue)
        return reordered
    }

    func binaryInteger(_ data: Data, at offset: Int, byteCount: Int) throws -> Int {
        guard byteCount > 0, byteCount <= 8, offset <= data.count - byteCount else {
            throw CocoaError(.coderReadCorrupt)
        }
        var value: UInt64 = 0
        for byte in data[offset..<(offset + byteCount)] {
            value = (value << 8) | UInt64(byte)
        }
        guard value <= UInt64(Int.max) else { throw CocoaError(.coderReadCorrupt) }
        return Int(value)
    }

    func duplicateKeyPropertyList() -> Data {
        // Object 3 is a two-entry dictionary whose two key references both
        // point to object 0 ("a"). Foundation cannot retain that distinction
        // once it has materialized an NSDictionary, so the wire validator must
        // reject it directly from the object table.
        var data = Data("bplist00".utf8)
        data.append(contentsOf: [0x51, 0x61])       // object 0: "a"
        data.append(contentsOf: [0x10, 0x01])       // object 1: 1
        data.append(contentsOf: [0x10, 0x02])       // object 2: 2
        data.append(contentsOf: [0xD2, 0, 0, 1, 2]) // object 3: {a: 1, a: 2}
        data.append(contentsOf: [8, 10, 12, 14])    // one-byte object offsets

        var trailer = [UInt8](repeating: 0, count: 32)
        trailer[6] = 1 // offset integer size
        trailer[7] = 1 // object reference size
        trailer[15] = 4 // object count
        trailer[23] = 3 // top object index
        trailer[31] = 19 // offset table location
        data.append(contentsOf: trailer)
        return data
    }

    func duplicatingFirstElement(_ data: Data, path: [String]) throws -> Data {
        let root = try mutablePropertyList(data)
        var cursor: Any = root
        for component in path {
            if let dictionary = cursor as? NSMutableDictionary {
                cursor = try XCTUnwrap(dictionary[component])
            } else if let array = cursor as? NSMutableArray, let index = Int(component) {
                cursor = array[index]
            } else {
                throw CocoaError(.coderInvalidValue)
            }
        }
        let array = try XCTUnwrap(cursor as? NSMutableArray)
        array.add(try XCTUnwrap(array.firstObject))
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    func set(_ value: Any, in container: Any, path: ArraySlice<String>) throws {
        let key = try XCTUnwrap(path.first)
        if path.count == 1 {
            if let dictionary = container as? NSMutableDictionary {
                dictionary[key] = value
            } else if let array = container as? NSMutableArray, let index = Int(key) {
                array[index] = value
            } else {
                XCTFail("Unsupported mutation path")
            }
            return
        }
        let next: Any
        if let dictionary = container as? NSMutableDictionary {
            next = try XCTUnwrap(dictionary[key])
        } else if let array = container as? NSMutableArray, let index = Int(key) {
            next = array[index]
        } else {
            throw CocoaError(.coderInvalidValue)
        }
        try set(value, in: next, path: path.dropFirst())
    }

    func remove(in container: Any, path: ArraySlice<String>) throws {
        let key = try XCTUnwrap(path.first)
        if path.count == 1 {
            if let dictionary = container as? NSMutableDictionary {
                dictionary.removeObject(forKey: key)
            } else if let array = container as? NSMutableArray, let index = Int(key) {
                array.removeObject(at: index)
            } else {
                XCTFail("Unsupported removal path")
            }
            return
        }
        let next: Any
        if let dictionary = container as? NSMutableDictionary {
            next = try XCTUnwrap(dictionary[key])
        } else if let array = container as? NSMutableArray, let index = Int(key) {
            next = array[index]
        } else {
            throw CocoaError(.coderInvalidValue)
        }
        try remove(in: next, path: path.dropFirst())
    }
}
