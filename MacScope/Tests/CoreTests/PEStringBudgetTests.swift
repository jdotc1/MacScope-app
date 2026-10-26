import Foundation
import XCTest
@testable import MacScope

/// Review-only regression proposal. Not compiled or executed in the Linux audit environment.
final class PEStringBudgetTests: XCTestCase {
    private let smallLimits = PEBinaryLoader.StringLimits(
        maximumStringBytes: 512,
        maximumTotalStringBytes: 1_024,
        maximumTotalScannedBytes: 4_096
    )

    func testRepeatedImportNameCannotMultiplyRetainedStringBytes() {
        let bytes = namedImportPE(count: 8, name: String(repeating: "A", count: 256))
        assertStringBoundExceeded {
            _ = try PEBinaryLoader.parse(
                bytes: bytes, name: "shared-name.exe", path: "/fixture",
                stringLimits: smallLimits
            )
        }
    }

    func testOrdinalLabelsCannotCopyOneLongLibraryNameWithoutCharge() {
        let bytes = namedImportPE(
            count: 8, name: "unused", libraryName: String(repeating: "D", count: 256), ordinal: true
        )
        assertStringBoundExceeded {
            _ = try PEBinaryLoader.parse(
                bytes: bytes, name: "shared-library.exe", path: "/fixture",
                stringLimits: smallLimits
            )
        }
    }

    func testRepeatedCOFFSymbolNameUsesTheSameAggregateBudget() {
        let bytes = coffSymbols(count: 8, name: String(repeating: "A", count: 256))
        assertStringBoundExceeded {
            _ = try PEBinaryLoader.parse(
                bytes: bytes, name: "shared-name.obj", path: "/fixture",
                stringLimits: smallLimits
            )
        }
    }

    func testAliasedStringSectionsCannotMultiplyRetainedStringBytes() {
        var limits = smallLimits
        limits.maximumTotalStringBytes = 400
        let bytes = coffStringSections(count: 2, content: Data(Array(repeating: UInt8(0x41), count: 256) + [0]))
        assertStringBoundExceeded {
            _ = try PEBinaryLoader.parse(
                bytes: bytes, name: "shared-section.obj", path: "/fixture",
                stringLimits: limits
            )
        }
    }

    func testScanBudgetAlsoCountsBytesThatDoNotEmitAString() {
        var limits = smallLimits
        limits.maximumTotalScannedBytes = 128
        let bytes = coffStringSections(count: 1, content: Data(repeating: 0x80, count: 1_024))
        assertStringBoundExceeded {
            _ = try PEBinaryLoader.parse(
                bytes: bytes, name: "nonprinting.obj", path: "/fixture",
                stringLimits: limits
            )
        }
    }

    func testProductionEntryPointRejectsAnIndividualNameOverOneMiB() {
        let bytes = namedImportPE(count: 1, name: String(repeating: "A", count: 1_048_577))
        assertStringBoundExceeded {
            _ = try PEBinaryLoader.parse(bytes: bytes, name: "overlong.exe", path: "/fixture")
        }
    }

    func testOrdinaryRepeatedImportsRetainTheirNamesAndLibrary() throws {
        let loaded = try PEBinaryLoader.parse(
            bytes: namedImportPE(count: 3, name: "printf"), name: "ordinary.exe", path: "/fixture",
            stringLimits: smallLimits
        )
        XCTAssertEqual(loaded.imports.map(\.name), ["printf", "printf", "printf"])
        XCTAssertEqual(loaded.imports.map(\.libraryName), ["lib", "lib", "lib"])
    }

    private func assertStringBoundExceeded(
        file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let failure = error as? PELoadError, case .boundExceeded = failure else {
                XCTFail("Expected a typed string-budget refusal; got \(error)", file: file, line: line)
                return
            }
        }
    }

    /// Every nonzero thunk references one shared hint/name record. The fixture itself stays small.
    private func namedImportPE(count: Int, name: String, libraryName: String = "lib", ordinal: Bool = false) -> Data {
        let pe = 0x80
        let coff = pe + 4
        let optional = coff + 20
        let sectionTable = optional + 0xF0
        let raw = 0x200
        let rva: UInt32 = 0x1000
        let thunk = 64
        let library = thunk + (count + 1) * 8
        let libraryBytes = Array(libraryName.utf8) + [0]
        let hintName = library + libraryBytes.count
        let text = Array(name.utf8) + [0]
        let rawCount = hintName + 2 + text.count
        var data = Data(repeating: 0, count: raw + rawCount)
        data[0] = 0x4D
        data[1] = 0x5A
        put32(&data, 0x3C, UInt32(pe))
        data[pe] = 0x50
        data[pe + 1] = 0x45
        put16(&data, coff, 0x8664)
        put16(&data, coff + 2, 1)
        put16(&data, coff + 16, 0xF0)
        put16(&data, optional, 0x20B)
        put64(&data, optional + 24, 0x1_4000_0000)
        put32(&data, optional + 108, 16)
        put32(&data, optional + 120, rva)
        put32(&data, optional + 124, 40)
        section(&data, at: sectionTable, name: ".idata", rva: rva, size: rawCount, raw: raw)
        put32(&data, raw, rva + UInt32(thunk))
        put32(&data, raw + 12, rva + UInt32(library))
        put32(&data, raw + 16, rva + UInt32(thunk))
        for index in 0..<count {
            let value = ordinal ? (UInt64(1) << 63) | UInt64(index + 1) : UInt64(rva) + UInt64(hintName)
            put64(&data, raw + thunk + index * 8, value)
        }
        data.replaceSubrange((raw + library)..<(raw + library + libraryBytes.count), with: libraryBytes)
        data.replaceSubrange((raw + hintName + 2)..<(raw + hintName + 2 + text.count), with: text)
        return data
    }

    private func coffSymbols(count: Int, name: String) -> Data {
        let symbolTable = 61
        let stringTable = symbolTable + count * 18
        let text = Array(name.utf8) + [0]
        var data = Data(repeating: 0, count: stringTable + 4 + text.count)
        put16(&data, 0, 0x8664)
        put16(&data, 2, 1)
        put32(&data, 8, UInt32(symbolTable))
        put32(&data, 12, UInt32(count))
        section(&data, at: 20, name: ".text", rva: 0x1000, size: 1, raw: 60)
        data[60] = 0xC3
        for index in 0..<count {
            let base = symbolTable + index * 18
            put32(&data, base + 4, 4)
            put16(&data, base + 12, 1)
            data[base + 16] = 2
        }
        put32(&data, stringTable, UInt32(4 + text.count))
        data.replaceSubrange((stringTable + 4)..<(stringTable + 4 + text.count), with: text)
        return data
    }

    private func coffStringSections(count: Int, content: Data) -> Data {
        let raw = 20 + count * 40
        var data = Data(repeating: 0, count: raw + content.count)
        put16(&data, 0, 0x8664)
        put16(&data, 2, UInt16(count))
        for index in 0..<count {
            section(&data, at: 20 + index * 40, name: ".rdata", rva: 0x1000 + UInt32(index) * 0x1000,
                    size: content.count, raw: raw)
        }
        data.replaceSubrange(raw..<(raw + content.count), with: content)
        return data
    }

    private func section(_ data: inout Data, at offset: Int, name: String, rva: UInt32, size: Int, raw: Int) {
        for (index, byte) in name.utf8.prefix(8).enumerated() { data[offset + index] = byte }
        put32(&data, offset + 8, UInt32(size))
        put32(&data, offset + 12, rva)
        put32(&data, offset + 16, UInt32(size))
        put32(&data, offset + 20, UInt32(raw))
        put32(&data, offset + 36, 0x4000_0040)
    }

    private func put16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
        for index in 0..<2 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private func put32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private func put64(_ data: inout Data, _ offset: Int, _ value: UInt64) {
        for index in 0..<8 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}
