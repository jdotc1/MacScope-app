import Foundation
import XCTest
@testable import MacScope

/// End-to-end WS-11 contracts that deliberately cross the loader -> effective decode ->
/// function discovery -> signature projection -> display seams. Pure matcher predicates live in
/// `FunctionSignatureMatcherTests`; this suite protects the production transitions around them.
final class FunctionSignaturePipelineTests: XCTestCase {
    private let fixtureURL = URL(fileURLWithPath: "/tmp/macscope-function-signature-pipeline")

    func testEffectivePatchCanEnableSignatureMatch() throws {
        let original = [UInt8](0x10...0x1F)
        let patched = [UInt8](0xA0...0xA3) + Array(original.dropFirst(4))
        let binary = makeBinary(
            bytes: [UInt8](0x00...0x0F) + original,
            functionStarts: [0x1000, 0x1010]
        )
        let matcher = makeMatcher(name: "___patch_enabled", bytes: patched)

        let unpatched = try analyze(binary: binary, matcher: matcher)
        XCTAssertNil(librarySymbol(in: unpatched, at: 0x1010))

        let effective = try analyze(
            binary: binary,
            matcher: matcher,
            overrides: [
                0x1010: AddressOverride(
                    patch: BytePatch(bytes: Array(patched.prefix(4)))
                ),
            ]
        )
        XCTAssertEqual(function(in: effective, at: 0x1010)?.name, "___patch_enabled")
        XCTAssertEqual(librarySymbol(in: effective, at: 0x1010)?.name, "___patch_enabled")
    }

    func testEffectivePatchCanDisableSignatureMatch() throws {
        let original = [UInt8](0x10...0x1F)
        let binary = makeBinary(
            bytes: [UInt8](0x00...0x0F) + original,
            functionStarts: [0x1000, 0x1010]
        )
        let matcher = makeMatcher(name: "___patch_disabled", bytes: original)

        let baseline = try analyze(binary: binary, matcher: matcher)
        XCTAssertEqual(librarySymbol(in: baseline, at: 0x1010)?.name, "___patch_disabled")

        let effective = try analyze(
            binary: binary,
            matcher: matcher,
            overrides: [
                0x1010: AddressOverride(
                    patch: BytePatch(bytes: [0xEE, 0xEE, 0xEE, 0xEE])
                ),
            ]
        )
        XCTAssertNil(librarySymbol(in: effective, at: 0x1010))
        XCTAssertEqual(
            function(in: effective, at: 0x1010)?.name,
            "sub_\(UInt64(0x1010).hexAddress)"
        )
    }

    func testDataOverrideGapAbstainsInsteadOfMatchingPartialBytes() throws {
        let target = [UInt8](0x10...0x1F)
        let binary = makeBinary(
            bytes: [UInt8](0x00...0x0F) + target,
            functionStarts: [0x1000, 0x1010]
        )

        let snapshot = try analyze(
            binary: binary,
            matcher: makeMatcher(name: "___must_be_contiguous", bytes: target),
            overrides: [0x1014: AddressOverride(isData: true)]
        )

        XCTAssertNil(librarySymbol(in: snapshot, at: 0x1010))
    }

    func testUndefinedOverrideGapAbstainsInsteadOfMatchingPartialBytes() throws {
        let target = [UInt8](0x10...0x1F)
        let binary = makeBinary(
            bytes: [UInt8](0x00...0x0F) + target,
            functionStarts: [0x1000, 0x1010]
        )

        let snapshot = try analyze(
            binary: binary,
            matcher: makeMatcher(name: "___must_be_defined", bytes: target),
            overrides: [0x1014: AddressOverride(isUndefined: true)]
        )

        XCTAssertNil(librarySymbol(in: snapshot, at: 0x1010))
    }

    func testStructuredBranchTargetToRealSymbolSuppliesReferenceEvidence() throws {
        let fixture = referenceFixture()
        let symbol = SymbolSummary(
            id: UUID(),
            name: "_puts",
            address: fixture.referenceTarget,
            kind: "external",
            libraryName: nil
        )
        let binary = makeBinary(
            bytes: fixture.bytes,
            functionStarts: fixture.functionStarts,
            symbols: [symbol]
        )

        let snapshot = try analyze(
            binary: binary,
            decoder: PipelineFixtureDecoder(
                branchTargets: [fixture.matchAddress: fixture.referenceTarget]
            ),
            matcher: makeMatcher(
                name: "___real_reference",
                bytes: fixture.matchBytes,
                expectedReference: (offset: 0, name: "_puts")
            )
        )

        XCTAssertEqual(librarySymbol(in: snapshot, at: fixture.matchAddress)?.name, "___real_reference")
    }

    func testStructuredBranchTargetToEligibleStubSuppliesReferenceEvidence() throws {
        let fixture = referenceFixture()
        let binary = makeBinary(
            bytes: fixture.bytes,
            functionStarts: fixture.functionStarts,
            indirectSymbols: [indirectSymbol(name: "_puts", address: fixture.referenceTarget)]
        )

        let snapshot = try analyze(
            binary: binary,
            decoder: PipelineFixtureDecoder(
                branchTargets: [fixture.matchAddress: fixture.referenceTarget]
            ),
            matcher: makeMatcher(
                name: "___stub_reference",
                bytes: fixture.matchBytes,
                expectedReference: (offset: 0, name: "_puts")
            )
        )

        XCTAssertEqual(librarySymbol(in: snapshot, at: fixture.matchAddress)?.name, "___stub_reference")
    }

    func testOperandStringWithoutStructuredBranchTargetIsNotReferenceEvidence() throws {
        let fixture = referenceFixture()
        let binary = makeBinary(
            bytes: fixture.bytes,
            functionStarts: fixture.functionStarts,
            symbols: [
                SymbolSummary(
                    id: UUID(),
                    name: "_puts",
                    address: fixture.referenceTarget,
                    kind: "external",
                    libraryName: nil
                ),
            ]
        )

        let snapshot = try analyze(
            binary: binary,
            decoder: PipelineFixtureDecoder(
                operandsByAddress: [fixture.matchAddress: "_puts"]
            ),
            matcher: makeMatcher(
                name: "___operand_is_not_evidence",
                bytes: fixture.matchBytes,
                expectedReference: (offset: 0, name: "_puts")
            )
        )

        XCTAssertNil(librarySymbol(in: snapshot, at: fixture.matchAddress))
    }

    func testConflictingRealAndIndirectNamesMakeReferenceEvidenceAmbiguous() throws {
        let fixture = referenceFixture()
        let binary = makeBinary(
            bytes: fixture.bytes,
            functionStarts: fixture.functionStarts,
            symbols: [
                SymbolSummary(
                    id: UUID(),
                    name: "_puts",
                    address: fixture.referenceTarget,
                    kind: "external",
                    libraryName: nil
                ),
            ],
            indirectSymbols: [
                indirectSymbol(name: "_printf", address: fixture.referenceTarget),
            ]
        )

        let snapshot = try analyze(
            binary: binary,
            decoder: PipelineFixtureDecoder(
                branchTargets: [fixture.matchAddress: fixture.referenceTarget]
            ),
            matcher: makeMatcher(
                name: "___ambiguous_reference",
                bytes: fixture.matchBytes,
                expectedReference: (offset: 0, name: "_puts")
            )
        )

        XCTAssertNil(librarySymbol(in: snapshot, at: fixture.matchAddress))
    }

    func testEntryAndTextGeneratedNamesRemainProtected() throws {
        let bytes = [UInt8](0x00...0x0F)
        let matcher = makeMatcher(name: "___must_not_replace_generated_root", bytes: bytes)

        let entrySnapshot = try analyze(
            binary: makeBinary(
                bytes: bytes,
                functionStarts: [0x1000],
                entryPointAddress: 0x1000
            ),
            matcher: matcher
        )
        XCTAssertEqual(function(in: entrySnapshot, at: 0x1000)?.name, "_entry")
        XCTAssertNil(librarySymbol(in: entrySnapshot, at: 0x1000))

        let textSnapshot = try analyze(
            binary: makeBinary(
                bytes: bytes,
                functionStarts: [0x1000],
                entryPointAddress: nil
            ),
            matcher: matcher
        )
        XCTAssertEqual(function(in: textSnapshot, at: 0x1000)?.name, "__text")
        XCTAssertNil(librarySymbol(in: textSnapshot, at: 0x1000))
    }

    func testCustomOverrideWinsAcrossListingSymbolizedLabelAndPseudocodeHeader() throws {
        let target = [UInt8](0x10...0x1F)
        let address = UInt64(0x1010)
        let derivedName = "___derived_library_name"
        let customName = "analyst_verified_name"
        let snapshot = try analyze(
            binary: makeBinary(
                bytes: [UInt8](0x00...0x0F) + target,
                functionStarts: [0x1000, address]
            ),
            matcher: makeMatcher(name: derivedName, bytes: target),
            overrides: [address: AddressOverride(customName: customName)]
        )

        let derivedFunction = try XCTUnwrap(function(in: snapshot, at: address))
        XCTAssertEqual(derivedFunction.name, derivedName)
        XCTAssertEqual(snapshot.displayName(at: address, default: derivedFunction.name), customName)
        XCTAssertEqual(snapshot.symbolizedLabel(for: address), customName)

        let listingLabel = DisassemblyListingBuilder.build(snapshot: snapshot).compactMap { row -> LabelRow? in
            guard case let .label(label) = row, label.address == address else { return nil }
            return label
        }.first
        XCTAssertEqual(listingLabel?.name, customName)

        let targetFunction = try XCTUnwrap(snapshot.pseudocodeTarget(selectedAddress: address))
        let pseudocode = PseudocodePrinter().print(
            functionName: snapshot.displayName(
                at: targetFunction.function.startAddress,
                default: targetFunction.function.name
            ),
            startAddress: targetFunction.function.startAddress,
            jumpTables: snapshot.resolvedJumpTables(in: snapshot.primarySlot),
            objcSelectors: snapshot.objcSelectors,
            nameOverrides: snapshot.functionNameOverrides(),
            signatureOverrides: snapshot.functionSignatureOverrides(in: snapshot.primarySlot),
            registerNameOverrides: snapshot.registerNameOverrides(forProcedureAt: address),
            types: snapshot.typeDefinitions,
            instructions: targetFunction.instructions
        ).text
        XCTAssertTrue(pseudocode.contains("\(customName)("), pseudocode)
        XCTAssertFalse(pseudocode.contains("\(derivedName)("), pseudocode)
    }

    func testEmptyStandardMatcherPreservesNormalizedAnalysisBytes() throws {
        let binary = makeBinary(
            bytes: [UInt8](0x00...0x1F),
            functionStarts: [0x1000, 0x1010]
        )
        let baseline = try AnalysisEngine(
            loader: PipelineFixtureLoader(binary: binary),
            decoder: PipelineFixtureDecoder(),
            functionSignatureMatcher: .empty
        ).analyze(url: fixtureURL)
        let defaultPath = try AnalysisEngine(
            loader: PipelineFixtureLoader(binary: binary),
            decoder: PipelineFixtureDecoder()
        ).analyze(url: fixtureURL)

        XCTAssertEqual(
            try GoldenOutput(snapshot: defaultPath).jsonData(),
            try GoldenOutput(snapshot: baseline).jsonData()
        )
    }

    // MARK: - Fixtures

    private func analyze(
        binary: LoadedBinary,
        decoder: PipelineFixtureDecoder = PipelineFixtureDecoder(),
        matcher: FunctionSignatureMatcher,
        overrides: [UInt64: AddressOverride] = [:]
    ) throws -> WorkspaceSnapshot {
        try AnalysisEngine(
            loader: PipelineFixtureLoader(binary: binary),
            decoder: decoder,
            functionSignatureMatcher: matcher
        ).analyze(url: fixtureURL, overrides: overrides)
    }

    private func makeMatcher(
        name: String,
        library: String = "libclang_rt.osx.a",
        bytes: [UInt8],
        expectedReference: (offset: UInt32, name: String)? = nil
    ) -> FunctionSignatureMatcher {
        var prefixBytes = bytes
        var comparisonMask = Array(repeating: UInt8.max, count: bytes.count)
        var importedReferences: [FunctionSignatureImportedReference] = []
        if let expectedReference {
            let start = Int(expectedReference.offset)
            for index in start..<(start + 4) {
                prefixBytes[index] = 0
                comparisonMask[index] = 0
            }
            importedReferences = [
                FunctionSignatureImportedReference(
                    instructionOffset: expectedReference.offset,
                    expectedSymbolName: expectedReference.name
                ),
            ]
        }
        return FunctionSignatureMatcher(
            database: FunctionSignatureDatabase(
                schemaVersion: FunctionSignatureDatabase.currentSchemaVersion,
                signatures: [
                    FunctionSignature(
                        architecture: .arm64,
                        name: name,
                        libraryName: library,
                        totalLength: UInt32(bytes.count),
                        prefix: FunctionSignatureMaskedPattern(
                            bytes: prefixBytes,
                            comparisonMask: comparisonMask
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
                    ),
                ]
            )
        )
    }

    private func makeBinary(
        bytes: [UInt8],
        functionStarts: [UInt64],
        entryPointAddress: UInt64? = 0x1000,
        symbols: [SymbolSummary] = [],
        exports: [ExportSummary] = [],
        indirectSymbols: [IndirectSymbolSummary] = []
    ) -> LoadedBinary {
        let text = BinarySection(
            name: "__TEXT,__text",
            address: 0x1000,
            size: UInt64(bytes.count),
            fileOffset: 0,
            isExecutable: true,
            fileSize: UInt64(bytes.count)
        )
        return LoadedBinary(
            name: "signature-pipeline-fixture",
            path: fixtureURL.path,
            isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64,
            cpuSubtype: 0,
            fileTypeName: "fixture",
            architectureDisplayName: "arm64",
            metadata: .empty,
            bytes: Data(bytes),
            sliceOffset: 0,
            sliceSize: UInt64(bytes.count),
            sections: [text],
            executableTextSection: text,
            entryPointAddress: entryPointAddress,
            symbols: symbols,
            imports: [],
            indirectSymbols: indirectSymbols,
            exports: exports,
            stringLiterals: [],
            functionStarts: functionStarts,
            objcSelectors: [:]
        )
    }

    private func referenceFixture() -> (
        bytes: [UInt8],
        matchBytes: [UInt8],
        functionStarts: [UInt64],
        matchAddress: UInt64,
        referenceTarget: UInt64
    ) {
        let leading = [UInt8](0x00...0x1F)
        let matched = [UInt8](0x20...0x3F)
        return (
            bytes: leading + matched,
            matchBytes: matched,
            functionStarts: [0x1000, 0x1020],
            matchAddress: 0x1020,
            referenceTarget: 0x2000
        )
    }

    private func indirectSymbol(name: String, address: UInt64) -> IndirectSymbolSummary {
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
            libraryName: "libSystem.B.dylib",
            isLocal: false,
            isAbsolute: false
        )
    }

    private func function(in snapshot: WorkspaceSnapshot, at address: UInt64) -> FunctionSummary? {
        snapshot.functions.first { $0.startAddress == address }
    }

    private func librarySymbol(in snapshot: WorkspaceSnapshot, at address: UInt64) -> SymbolSummary? {
        snapshot.symbols.first { $0.address == address && $0.kind == "library-signature" }
    }
}

private struct PipelineFixtureLoader: BinaryLoader {
    let binary: LoadedBinary

    func load(at url: URL) throws -> LoadedBinary {
        binary
    }
}

private struct PipelineFixtureDecoder: Disassembler {
    var branchTargets: [UInt64: UInt64] = [:]
    var operandsByAddress: [UInt64: String] = [:]

    func decode(
        _ bytes: Data,
        baseAddress: UInt64,
        maxInstructionCount: Int
    ) -> [DecodedInstruction] {
        let values = Array(bytes)
        return stride(from: 0, to: min(values.count, maxInstructionCount), by: 4).map { offset in
            let address = baseAddress + UInt64(offset)
            let end = min(offset + 4, values.count)
            let branchTarget = branchTargets[address]
            let renderedOperand = operandsByAddress[address]
            let isRenderedCall = renderedOperand != nil
            return DecodedInstruction(
                address: address,
                bytes: Array(values[offset..<end]),
                mnemonic: branchTarget != nil || isRenderedCall ? "bl" : "fixture",
                operands: renderedOperand ?? "",
                branchTarget: branchTarget,
                comment: nil,
                flow: branchTarget != nil || isRenderedCall ? .call : .normal
            )
        }
    }
}
