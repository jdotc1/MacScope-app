import Foundation
import XCTest
@testable import MacScope

final class FunctionSignatureIntegrationTests: XCTestCase {
    func testUniqueMatchRenamesExistingFallbackAndProjectsLibrarySymbol() throws {
        let first = [UInt8](0x00...0x0F)
        let second = [UInt8](0x10...0x1F)
        let binary = makeBinary(bytes: first + second, functionStarts: [0x1000, 0x1010])
        let matcher = makeMatcher(
            name: "___addtf3",
            library: "libclang_rt.osx.a",
            bytes: second
        )

        let before = try XCTUnwrap(
            try AnalysisEngine(
                loader: FunctionSignatureFixtureLoader(binary: binary),
                decoder: FunctionSignatureFixtureDecoder(),
                functionSignatureMatcher: .empty
            ).analyze(url: fixtureURL)
                .functions.first { $0.startAddress == 0x1010 }
        )
        let snapshot = try AnalysisEngine(
            loader: FunctionSignatureFixtureLoader(binary: binary),
            decoder: FunctionSignatureFixtureDecoder(),
            functionSignatureMatcher: matcher
        ).analyze(url: fixtureURL)
        let renamed = try XCTUnwrap(snapshot.functions.first { $0.startAddress == 0x1010 })

        XCTAssertEqual(before.name, "sub_\(UInt64(0x1010).hexAddress)")
        XCTAssertEqual(renamed.name, "___addtf3")
        XCTAssertEqual(renamed.startAddress, before.startAddress)
        XCTAssertEqual(renamed.endAddress, before.endAddress)
        XCTAssertEqual(renamed.confidence, before.confidence)

        let projected = snapshot.symbols.filter {
            $0.address == 0x1010 && $0.kind == "library-signature"
        }
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected.first?.name, "___addtf3")
        XCTAssertEqual(projected.first?.libraryName, "libclang_rt.osx.a")
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: "/tmp/macscope-function-signature-fixture")
    }

    private func makeMatcher(
        name: String,
        library: String,
        bytes: [UInt8]
    ) -> FunctionSignatureMatcher {
        FunctionSignatureMatcher(
            database: FunctionSignatureDatabase(
                schemaVersion: FunctionSignatureDatabase.currentSchemaVersion,
                signatures: [
                    FunctionSignature(
                        architecture: .arm64,
                        name: name,
                        libraryName: library,
                        totalLength: UInt32(bytes.count),
                        prefix: FunctionSignatureMaskedPattern(
                            bytes: bytes,
                            comparisonMask: Array(repeating: 0xFF, count: bytes.count)
                        ),
                        checksum: FunctionSignatureChecksumSpan(
                            offset: UInt32(bytes.count),
                            byteCount: 0,
                            crc32: 0
                        ),
                        collisionTail: FunctionSignatureCollisionTail(
                            byteRuns: [],
                            importedReferences: []
                        )
                    ),
                ]
            )
        )
    }

    private func makeBinary(
        bytes: [UInt8],
        functionStarts: [UInt64],
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
            name: "signature-fixture",
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
            entryPointAddress: functionStarts.first,
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

private struct FunctionSignatureFixtureLoader: BinaryLoader {
    let binary: LoadedBinary

    func load(at url: URL) throws -> LoadedBinary {
        binary
    }
}

private struct FunctionSignatureFixtureDecoder: Disassembler {
    var branchTargets: [UInt64: UInt64] = [:]
    var omittedAddresses: Set<UInt64> = []

    func decode(
        _ bytes: Data,
        baseAddress: UInt64,
        maxInstructionCount: Int
    ) -> [DecodedInstruction] {
        let byteArray = Array(bytes)
        return stride(from: 0, to: min(byteArray.count, maxInstructionCount), by: 4)
            .compactMap { offset in
                let address = baseAddress + UInt64(offset)
                guard !omittedAddresses.contains(address) else { return nil }
                let end = min(offset + 4, byteArray.count)
                let target = branchTargets[address]
                return DecodedInstruction(
                    address: address,
                    bytes: Array(byteArray[offset..<end]),
                    mnemonic: target == nil ? "fixture" : "bl",
                    operands: "ignored-rendered-operand",
                    branchTarget: target,
                    comment: nil,
                    flow: target == nil ? .normal : .call
                )
            }
    }
}
