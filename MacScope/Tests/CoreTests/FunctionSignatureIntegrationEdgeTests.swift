import Foundation
import XCTest
@testable import MacScope

final class FunctionSignatureIntegrationEdgeTests: XCTestCase {
    func testSchemaV1SubtypeEligibilityNormalizesOnlyCapabilityBits() {
        let arm64All = makeLoadedBinary(cpuSubtype: 0)
        let arm64AllWithCapabilities = makeLoadedBinary(
            cpuSubtype: Int32(bitPattern: 0x8000_0000)
        )
        let subtypeUnknown = makeLoadedBinary(cpuSubtype: nil)
        let arm64e = makeLoadedBinary(cpuSubtype: 2)
        let arm64eWithCapabilities = makeLoadedBinary(
            cpuSubtype: Int32(bitPattern: 0x8000_0002)
        )
        let otherArm64Subtype = makeLoadedBinary(cpuSubtype: 1)
        let nonArm64 = makeLoadedBinary(
            cpuType: MachOConstants.cpuTypeX86_64,
            cpuSubtype: 0
        )

        XCTAssertEqual(AnalysisEngine.functionSignatureArchitecture(for: arm64All), .arm64)
        XCTAssertEqual(
            AnalysisEngine.functionSignatureArchitecture(for: arm64AllWithCapabilities),
            .arm64
        )
        XCTAssertNil(AnalysisEngine.functionSignatureArchitecture(for: subtypeUnknown))
        XCTAssertNil(AnalysisEngine.functionSignatureArchitecture(for: arm64e))
        XCTAssertNil(AnalysisEngine.functionSignatureArchitecture(for: arm64eWithCapabilities))
        XCTAssertNil(AnalysisEngine.functionSignatureArchitecture(for: otherArm64Subtype))
        XCTAssertNil(AnalysisEngine.functionSignatureArchitecture(for: nonArm64))

        XCTAssertEqual(arm64AllWithCapabilities.cpuSubtype, Int32(bitPattern: 0x8000_0000))
        XCTAssertEqual(arm64eWithCapabilities.cpuSubtype, Int32(bitPattern: 0x8000_0002))
    }

    func testCandidateRequiresCompleteContiguousFourByteRows() throws {
        let function = makeFunction(start: 0x1000, end: 0x1010)
        let rows = [
            instruction(at: 0x1008, bytes: [8, 9, 10, 11]),
            instruction(at: 0x1000, bytes: [0, 1, 2, 3]),
            instruction(at: 0x100C, bytes: [12, 13, 14, 15]),
            instruction(
                at: 0x1004,
                bytes: [4, 5, 6, 7],
                branchTarget: 0x9000,
                operands: "_misleading_rendered_name",
                flow: .call
            ),
        ]

        let candidate = try XCTUnwrap(
            AnalysisEngine.functionSignatureCandidate(
                for: function,
                architecture: .arm64,
                instructions: rows,
                referenceNamesByAddress: [0x9000: "_structured_target"]
            )
        )

        XCTAssertEqual(candidate.bytes, Array(UInt8(0)...UInt8(15)))
        XCTAssertEqual(candidate.importedReferences, [4: "_structured_target"])
    }

    func testCandidateDoesNotTreatNormalFlowBranchTargetAsImportedReference() throws {
        let function = makeFunction(start: 0x1000, end: 0x1004)
        let candidate = try XCTUnwrap(
            AnalysisEngine.functionSignatureCandidate(
                for: function,
                architecture: .arm64,
                instructions: [
                    instruction(
                        at: 0x1000,
                        bytes: [0, 1, 2, 3],
                        branchTarget: 0x9000,
                        flow: .normal
                    ),
                ],
                referenceNamesByAddress: [0x9000: "_not_a_direct_branch"]
            )
        )

        XCTAssertTrue(candidate.importedReferences.isEmpty)
    }

    func testCandidateAbstainsForGapDuplicateShortOrOverlappingRows() {
        let function = makeFunction(start: 0x1000, end: 0x1010)
        let complete = stride(from: UInt64(0x1000), to: 0x1010, by: 4).map {
            instruction(at: $0, bytes: [0, 1, 2, 3])
        }
        let malformedCases: [(String, [DecodedInstruction])] = [
            ("gap", complete.filter { $0.address != 0x1004 }),
            ("duplicate", complete + [complete[1]]),
            (
                "short row",
                complete.enumerated().map { index, row in
                    index == 1 ? instruction(at: row.address, bytes: [0, 1, 2]) : row
                }
            ),
            (
                "overlapping or unaligned row",
                complete.enumerated().map { index, row in
                    index == 1 ? instruction(at: 0x1002, bytes: row.bytes) : row
                }
            ),
        ]

        for (label, rows) in malformedCases {
            XCTAssertNil(
                AnalysisEngine.functionSignatureCandidate(
                    for: function,
                    architecture: .arm64,
                    instructions: rows,
                    referenceNamesByAddress: [:]
                ),
                label
            )
        }
    }

    func testCandidateAbstainsBeforeMaterializingRangeOverMaximum() {
        let overMaximum = makeFunction(
            start: 0x1000,
            end: 0x1000 + 1_048_576 + 4
        )

        XCTAssertNil(
            AnalysisEngine.functionSignatureCandidate(
                for: overMaximum,
                architecture: .arm64,
                instructions: [instruction(at: 0x1000, bytes: [0, 1, 2, 3])],
                referenceNamesByAddress: [:]
            )
        )
    }

    func testProjectionHonorsAuthoritativeAndExistingNamePrecedenceAndPreservesIdentity() {
        let bytes = Array(UInt8(0)...UInt8(15))
        let matcher = makeMatcher(signatures: [makeSignature(bytes: bytes)])
        let fallback = makeFunction(start: 0x1000, end: 0x1010, confidence: 0.41)
        let realSymbolAddress = makeFunction(start: 0x2000, end: 0x2010, confidence: 0.42)
        let exportAddress = makeFunction(start: 0x2800, end: 0x2810, confidence: 0.43)
        let userNamed = makeFunction(
            name: "user_override",
            start: 0x3000,
            end: 0x3010,
            confidence: 0.44
        )
        let entryNamed = makeFunction(name: "_entry", start: 0x4000, end: 0x4010)
        let textNamed = makeFunction(name: "__text", start: 0x5000, end: 0x5010)
        let original = [fallback, realSymbolAddress, exportAddress, userNamed, entryNamed, textNamed]
        let candidate = FunctionSignatureCandidate(
            architecture: .arm64,
            bytes: bytes,
            importedReferences: [:]
        )
        let candidates = Dictionary(
            uniqueKeysWithValues: original.map { ($0.startAddress, candidate) }
        )

        let projection = AnalysisEngine.projectFunctionSignatureMatches(
            functions: original,
            candidatesByStartAddress: candidates,
            matcher: matcher,
            authoritativeAddresses: [realSymbolAddress.startAddress, exportAddress.startAddress]
        )

        XCTAssertEqual(projection.functions.map(\.name), [
            "signature_name",
            realSymbolAddress.name,
            exportAddress.name,
            "user_override",
            "_entry",
            "__text",
        ])
        XCTAssertEqual(projection.symbols.count, 1)
        XCTAssertEqual(projection.symbols.first?.address, fallback.startAddress)
        XCTAssertEqual(projection.symbols.first?.kind, "library-signature")
        XCTAssertEqual(projection.symbols.first?.libraryName, "fixture-library")

        for (before, after) in zip(original, projection.functions) {
            XCTAssertEqual(after.id, before.id)
            XCTAssertEqual(after.startAddress, before.startAddress)
            XCTAssertEqual(after.endAddress, before.endAddress)
            XCTAssertEqual(after.confidence, before.confidence)
        }
    }

    func testAmbiguousMatchDoesNotMutateFunctionOrEmitSymbol() {
        let bytes = Array(UInt8(0)...UInt8(31))
        let exact = makeSignature(bytes: bytes, name: "alpha", libraryName: "libA")
        let wildcardVariant = makeSignature(
            bytes: bytes,
            name: "beta",
            libraryName: "libB",
            wildcardInstructionOffset: 4
        )
        let matcher = makeMatcher(signatures: [wildcardVariant, exact])
        let function = makeFunction(start: 0x1000, end: 0x1020)
        let candidate = FunctionSignatureCandidate(
            architecture: .arm64,
            bytes: bytes,
            importedReferences: [:]
        )

        let projection = AnalysisEngine.projectFunctionSignatureMatches(
            functions: [function],
            candidatesByStartAddress: [function.startAddress: candidate],
            matcher: matcher,
            authoritativeAddresses: []
        )

        XCTAssertEqual(projection.functions, [function])
        XCTAssertTrue(projection.symbols.isEmpty)
    }

    func testSyntheticLibrarySymbolsHaveDeterministicAddressOrder() {
        let bytes = Array(UInt8(0)...UInt8(15))
        let matcher = makeMatcher(signatures: [makeSignature(bytes: bytes)])
        let functions = [
            makeFunction(start: 0x3000, end: 0x3010),
            makeFunction(start: 0x1000, end: 0x1010),
            makeFunction(start: 0x2000, end: 0x2010),
        ]
        let candidate = FunctionSignatureCandidate(
            architecture: .arm64,
            bytes: bytes,
            importedReferences: [:]
        )
        let candidates = Dictionary(
            uniqueKeysWithValues: functions.reversed().map { ($0.startAddress, candidate) }
        )

        let first = AnalysisEngine.projectFunctionSignatureMatches(
            functions: functions,
            candidatesByStartAddress: candidates,
            matcher: matcher,
            authoritativeAddresses: []
        )
        let second = AnalysisEngine.projectFunctionSignatureMatches(
            functions: Array(functions.reversed()),
            candidatesByStartAddress: candidates,
            matcher: matcher,
            authoritativeAddresses: []
        )
        let firstProjection = first.symbols.map { ($0.address, $0.name, $0.libraryName) }
        let secondProjection = second.symbols.map { ($0.address, $0.name, $0.libraryName) }

        XCTAssertEqual(first.symbols.compactMap(\.address), [0x1000, 0x2000, 0x3000])
        XCTAssertEqual(
            firstProjection.map { "\($0.0.map(String.init) ?? "nil")|\($0.1)|\($0.2 ?? "")" },
            secondProjection.map { "\($0.0.map(String.init) ?? "nil")|\($0.1)|\($0.2 ?? "")" }
        )
    }

    func testStructuredRealAndStubReferencesMatchButConflictingRawNamesAbstain() throws {
        let expectedName = "_required_import"
        let targetAddress: UInt64 = 0x9000
        let matcher = makeReferenceMatcher(expectedName: expectedName)
        let realSymbol = SymbolSummary(
            id: UUID(),
            name: expectedName,
            address: targetAddress,
            kind: "external",
            libraryName: nil
        )
        let conflictingSymbol = SymbolSummary(
            id: UUID(),
            name: "_conflicting_name",
            address: targetAddress,
            kind: "external",
            libraryName: nil
        )
        let stub = makeIndirectSymbol(address: targetAddress, name: expectedName)

        let realSnapshot = try analyzeReferenceFixture(
            matcher: matcher,
            symbols: [realSymbol],
            indirectSymbols: [],
            targetAddress: targetAddress
        )
        let stubSnapshot = try analyzeReferenceFixture(
            matcher: matcher,
            symbols: [],
            indirectSymbols: [stub],
            targetAddress: targetAddress
        )
        let conflictSnapshot = try analyzeReferenceFixture(
            matcher: matcher,
            symbols: [conflictingSymbol],
            indirectSymbols: [stub],
            targetAddress: targetAddress
        )

        XCTAssertEqual(function(at: 0x1004, in: realSnapshot)?.name, "reference_signature")
        XCTAssertEqual(function(at: 0x1004, in: stubSnapshot)?.name, "reference_signature")
        XCTAssertEqual(
            function(at: 0x1004, in: conflictSnapshot)?.name,
            "sub_\(UInt64(0x1004).hexAddress)"
        )
    }

    func testExportAddressSuppressesCompetingSyntheticStub() throws {
        let occupiedAddress: UInt64 = 0x9000
        let binary = makeLoadedBinary(
            cpuSubtype: 0,
            indirectSymbols: [makeIndirectSymbol(address: occupiedAddress, name: "_stub_name")],
            exports: [
                ExportSummary(
                    id: UUID(),
                    name: "_export_name",
                    address: occupiedAddress,
                    source: "export-trie"
                ),
            ]
        )
        let snapshot = try AnalysisEngine(
            loader: FunctionSignatureEdgeFixtureLoader(binary: binary),
            decoder: FunctionSignatureEdgeFixtureDecoder(),
            functionSignatureMatcher: .empty
        ).analyze(url: fixtureURL)

        XCTAssertFalse(
            snapshot.symbols.contains {
                $0.address == occupiedAddress && $0.kind == "stub"
            }
        )
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: "/tmp/macscope-function-signature-edge-fixture")
    }

    private func analyzeReferenceFixture(
        matcher: FunctionSignatureMatcher,
        symbols: [SymbolSummary],
        indirectSymbols: [IndirectSymbolSummary],
        targetAddress: UInt64
    ) throws -> WorkspaceSnapshot {
        let bytes = Array(UInt8(0)...UInt8(23))
        let binary = makeLoadedBinary(
            bytes: bytes,
            cpuSubtype: 0,
            symbols: symbols,
            indirectSymbols: indirectSymbols,
            functionStarts: [0x1004]
        )
        return try AnalysisEngine(
            loader: FunctionSignatureEdgeFixtureLoader(binary: binary),
            decoder: FunctionSignatureEdgeFixtureDecoder(branchTargets: [0x1008: targetAddress]),
            functionSignatureMatcher: matcher
        ).analyze(url: fixtureURL)
    }

    private func function(
        at address: UInt64,
        in snapshot: WorkspaceSnapshot
    ) -> FunctionSummary? {
        snapshot.functions.first { $0.startAddress == address }
    }

    private func makeReferenceMatcher(expectedName: String) -> FunctionSignatureMatcher {
        let bytes = Array(UInt8(4)...UInt8(23))
        let signature = makeSignature(
            bytes: bytes,
            name: "reference_signature",
            wildcardInstructionOffset: 4,
            importedReferences: [
                FunctionSignatureImportedReference(
                    instructionOffset: 4,
                    expectedSymbolName: expectedName
                ),
            ]
        )
        return makeMatcher(signatures: [signature])
    }

    private func makeMatcher(signatures: [FunctionSignature]) -> FunctionSignatureMatcher {
        FunctionSignatureMatcher(
            database: FunctionSignatureDatabase(
                schemaVersion: FunctionSignatureDatabase.currentSchemaVersion,
                signatures: signatures
            )
        )
    }

    private func makeSignature(
        bytes: [UInt8],
        name: String = "signature_name",
        libraryName: String = "fixture-library",
        wildcardInstructionOffset: Int? = nil,
        importedReferences: [FunctionSignatureImportedReference] = []
    ) -> FunctionSignature {
        var prefixBytes = bytes
        var mask = Array(repeating: UInt8(0xFF), count: bytes.count)
        if let wildcardInstructionOffset {
            prefixBytes.replaceSubrange(
                wildcardInstructionOffset..<(wildcardInstructionOffset + 4),
                with: repeatElement(0, count: 4)
            )
            mask.replaceSubrange(
                wildcardInstructionOffset..<(wildcardInstructionOffset + 4),
                with: repeatElement(0, count: 4)
            )
        }
        return FunctionSignature(
            architecture: .arm64,
            name: name,
            libraryName: libraryName,
            totalLength: UInt32(bytes.count),
            prefix: FunctionSignatureMaskedPattern(
                bytes: prefixBytes,
                comparisonMask: mask
            ),
            checksum: FunctionSignatureChecksumSpan(
                offset: UInt32(bytes.count),
                byteCount: 0,
                crc32: 0
            ),
            collisionTail: FunctionSignatureCollisionTail(
                byteRuns: [],
                importedReferences: importedReferences
            )
        )
    }

    private func makeFunction(
        name: String? = nil,
        start: UInt64,
        end: UInt64,
        confidence: Double = 0.5
    ) -> FunctionSummary {
        FunctionSummary(
            id: UUID(),
            name: name ?? "sub_\(start.hexAddress)",
            startAddress: start,
            endAddress: end,
            confidence: confidence
        )
    }

    private func instruction(
        at address: UInt64,
        bytes: [UInt8],
        branchTarget: UInt64? = nil,
        operands: String = "",
        flow: InstructionFlow = .normal
    ) -> DecodedInstruction {
        DecodedInstruction(
            address: address,
            bytes: bytes,
            mnemonic: flow == .call ? "bl" : "fixture",
            operands: operands,
            branchTarget: branchTarget,
            comment: nil,
            flow: flow
        )
    }

    private func makeIndirectSymbol(
        address: UInt64,
        name: String
    ) -> IndirectSymbolSummary {
        IndirectSymbolSummary(
            id: UUID(),
            kind: "stub",
            sourceSection: "__TEXT,__stubs",
            address: address,
            entrySize: 4,
            tableIndex: 0,
            rawSymbolIndex: 0,
            symbolIndex: 0,
            symbolName: name,
            libraryOrdinal: 1,
            libraryName: "fixture.dylib",
            isLocal: false,
            isAbsolute: false
        )
    }

    private func makeLoadedBinary(
        bytes: [UInt8] = Array(UInt8(0)...UInt8(15)),
        cpuType: Int32 = MachOConstants.cpuTypeARM64,
        cpuSubtype: Int32?,
        symbols: [SymbolSummary] = [],
        indirectSymbols: [IndirectSymbolSummary] = [],
        exports: [ExportSummary] = [],
        functionStarts: [UInt64] = []
    ) -> LoadedBinary {
        let section = BinarySection(
            name: "__TEXT,__text",
            address: 0x1000,
            size: UInt64(bytes.count),
            fileOffset: 0,
            isExecutable: true,
            fileSize: UInt64(bytes.count)
        )
        return LoadedBinary(
            name: "function-signature-edge-fixture",
            path: fixtureURL.path,
            isBundle: false,
            cpuType: cpuType,
            cpuSubtype: cpuSubtype,
            fileTypeName: "Mach-O fixture",
            architectureDisplayName: cpuType == MachOConstants.cpuTypeARM64 ? "arm64" : "x86_64",
            metadata: .empty,
            bytes: Data(bytes),
            sliceOffset: 0,
            sliceSize: UInt64(bytes.count),
            sections: [section],
            executableTextSection: section,
            entryPointAddress: nil,
            symbols: symbols,
            imports: [],
            indirectSymbols: indirectSymbols,
            exports: exports,
            stringLiterals: [],
            functionStarts: functionStarts,
            objcSelectors: [:]
        )
    }
}

private struct FunctionSignatureEdgeFixtureLoader: BinaryLoader {
    let binary: LoadedBinary

    func load(at url: URL) throws -> LoadedBinary {
        binary
    }
}

private struct FunctionSignatureEdgeFixtureDecoder: Disassembler {
    var branchTargets: [UInt64: UInt64] = [:]

    func decode(
        _ bytes: Data,
        baseAddress: UInt64,
        maxInstructionCount: Int
    ) -> [DecodedInstruction] {
        let byteArray = Array(bytes)
        return stride(from: 0, to: byteArray.count, by: 4)
            .prefix(maxInstructionCount)
            .map { offset in
                let address = baseAddress + UInt64(offset)
                let end = min(offset + 4, byteArray.count)
                let target = branchTargets[address]
                return DecodedInstruction(
                    address: address,
                    bytes: Array(byteArray[offset..<end]),
                    mnemonic: target == nil ? "fixture" : "bl",
                    operands: "_rendered_operand_is_not_reference_evidence",
                    branchTarget: target,
                    comment: nil,
                    flow: target == nil ? .normal : .call
                )
            }
    }
}
