import Foundation
import XCTest
@testable import MacScope

final class FindMultiImageTests: XCTestCase {
    private let service = BinarySearchService()
    private let secondary = ImageSlot(rawValue: 1)

    func testTextSearchReturnsMatchingResultsFromEveryImageInSlotOrder() {
        let sharedAddress: UInt64 = 0x374
        let snapshot = twoImageSnapshot(
            primary: analysis(instructions: [instruction(sharedAddress, mnemonic: "ret")]),
            secondary: analysis(instructions: [instruction(sharedAddress, mnemonic: "ret")])
        )

        let outcome = service.searchWithCount(query: "ret", mode: .text, in: snapshot)

        XCTAssertEqual(outcome.total, 2)
        XCTAssertEqual(outcome.results.map(\.imageSlot), [.primary, secondary])
        XCTAssertEqual(outcome.results.map(\.address), [sharedAddress, sharedAddress])
    }

    func testIdenticalResultsInDifferentImagesHaveDistinctIdentity() throws {
        let sharedAddress: UInt64 = 0x374
        let snapshot = twoImageSnapshot(
            primary: analysis(instructions: [instruction(sharedAddress, mnemonic: "ret")]),
            secondary: analysis(instructions: [instruction(sharedAddress, mnemonic: "ret")])
        )

        let results = service.search(query: "ret", mode: .text, in: snapshot)

        XCTAssertEqual(results.count, 2)
        XCTAssertNotEqual(results[0].id, results[1].id)
        XCTAssertEqual(Set(results).count, 2)
    }

    func testSingleImageSearchMatchesLegacyPrimaryProjectionResults() {
        var imageAnalysis = ImageAnalysis()
        imageAnalysis.instructions = [
            instruction(0x1000, mnemonic: "mov", operands: "x0, needle"),
            instruction(0x1004, mnemonic: "ret")
        ]
        imageAnalysis.stringLiterals = [
            StringLiteralSummary(
                id: UUID(),
                value: "needle string",
                address: 0x2000,
                sourceSection: "__cstring",
                byteLength: 14
            )
        ]
        imageAnalysis.symbols = [
            SymbolSummary(
                id: UUID(),
                name: "_needle_symbol",
                address: 0x3000,
                kind: "data",
                libraryName: nil
            )
        ]

        let loaded = WorkspaceSnapshot(
            binaries: [binary(slot: .primary, name: "mainprog")],
            analysisBySlot: [.primary: imageAnalysis]
        )
        let legacyFixture = WorkspaceSnapshot(
            binaries: [],
            analysisBySlot: [.primary: imageAnalysis]
        )

        let loadedOutcome = service.searchWithCount(query: "needle", mode: .text, in: loaded)
        let legacyOutcome = service.searchWithCount(query: "needle", mode: .text, in: legacyFixture)

        XCTAssertEqual(loadedOutcome.results, legacyOutcome.results)
        XCTAssertEqual(loadedOutcome.total, legacyOutcome.total)
        XCTAssertTrue(loadedOutcome.results.allSatisfy { $0.imageSlot == .primary })
    }

    private func twoImageSnapshot(
        primary: ImageAnalysis,
        secondary secondaryAnalysis: ImageAnalysis
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            // Deliberately reverse storage order: search order is defined by slot, not insertion.
            binaries: [
                binary(slot: secondary, name: "libshared.dylib"),
                binary(slot: .primary, name: "mainprog")
            ],
            analysisBySlot: [
                .primary: primary,
                secondary: secondaryAnalysis
            ]
        )
    }

    private func binary(slot: ImageSlot, name: String) -> BinaryImage {
        BinaryImage(
            id: UUID(),
            name: name,
            path: "/tmp/\(name)",
            kind: "executable",
            architecture: "arm64",
            slot: slot
        )
    }

    private func analysis(instructions: [InstructionRow]) -> ImageAnalysis {
        var analysis = ImageAnalysis()
        analysis.instructions = instructions
        return analysis
    }

    private func instruction(
        _ address: UInt64,
        mnemonic: String,
        operands: String = ""
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "c0 03 5f d6",
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: false,
            comment: nil
        )
    }
}

// MARK: - Search scopes (M10)

extension FindMultiImageTests {
    func testFocusedImageScopeSearchesOnlyThatImageAndCountsAccordingly() {
        let snapshot = twoImageSnapshot(
            primary: analysis(instructions: [instruction(0x374, mnemonic: "ret")]),
            secondary: analysis(instructions: [instruction(0x374, mnemonic: "ret")])
        )
        var scope = BinarySearchScope()
        scope.images = .focused
        scope.focusedSlot = secondary
        let outcome = service.searchWithCount(query: "ret", mode: .text, in: snapshot, scope: scope)
        XCTAssertEqual(outcome.total, 1)
        XCTAssertEqual(outcome.results.map(\.imageSlot), [secondary])
    }

    func testKindFilterRemovesExcludedKindsBeforeCounting() {
        let snapshot = twoImageSnapshot(
            primary: analysis(instructions: [instruction(0x374, mnemonic: "ret")]),
            secondary: analysis(instructions: [instruction(0x374, mnemonic: "ret")])
        )
        var scope = BinarySearchScope()
        scope.kinds = [.string]
        XCTAssertEqual(service.searchWithCount(query: "ret", mode: .text, in: snapshot, scope: scope).total, 0)
    }
}
