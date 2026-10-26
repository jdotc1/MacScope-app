import Foundation
#if !DOT61_PORTABLE
import XCTest
@testable import MacScope
#endif

/// DOT-61: independent, tiny authored PE layouts, not a port of directory admission.
/// One 512-byte section contains one import and one export. The expectations below
/// are explicit per witness. No fixture exceeds 1 KiB or exercises entry-count caps.
enum PEDataDirectoryCountWitnesses {
    enum Kind: String, CaseIterable {
        case pe32, pe32Plus
        var countOffset: Int { self == .pe32 ? 92 : 108 }
        var arrayOffset: Int { self == .pe32 ? 96 : 112 }
        var imageBase: UInt64 { self == .pe32 ? 0x0040_0000 : 0x1_4000_0000 }
        var importName: String { self == .pe32 ? "I32" : "I64" }
        var exportName: String { self == .pe32 ? "E32" : "E64" }
    }
    enum Expected: String {
        case empty, exportOnly, both, sectionTableTruncated, poisonBudget
    }
    struct Witness {
        let name: String
        let kind: Kind
        let bytes: Data
        let expected: Expected
        let stringLimit: Int
    }
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func cases() -> [Witness] {
        var result: [Witness] = []
        for kind in Kind.allCases {
            func add(_ label: String, count: UInt32, declared: Int? = nil,
                     readable: Int? = nil, poisonImport: Bool = false,
                     poisonExport: Bool = false, omitImport: Bool = false,
                     expected: Expected) {
                result.append(Witness(
                    name: "\(kind.rawValue)-\(label)", kind: kind,
                    bytes: fixture(kind, count: count, declared: declared,
                                   readable: readable, poisonImport: poisonImport,
                                   poisonExport: poisonExport, omitImport: omitImport),
                    expected: expected, stringLimit: 8))
            }
            // Poison controls use names >8 bytes. Traversing either excluded table
            // would throw, not just return an accidentally empty result.
            add("count0-export-poison", count: 0, poisonExport: true,
                omitImport: true, expected: .empty)
            add("count0-both-poison", count: 0, poisonImport: true,
                poisonExport: true, expected: .empty)
            add("count1-import-poison", count: 1, poisonImport: true, expected: .exportOnly)
            add("count2-import-poison-control", count: 2, poisonImport: true, expected: .poisonBudget)
            add("count2-tiny-tables", count: 2, expected: .both)
            add("max-count-tiny-tables", count: .max, expected: .both)

            // All bytes continue beyond the declared optional header. The actual
            // section header begins exactly at its declared end. Any directory bytes
            // outside it are poison/section bytes, never a logical continuation.
            add("declared-count-absent", count: .max,
                declared: kind.countOffset, expected: .empty)
            add("declared-count-one-byte", count: .max,
                declared: kind.countOffset + 1, expected: .empty)
            add("declared-count-three-bytes", count: .max,
                declared: kind.countOffset + 3, expected: .empty)
            add("declared-no-slots", count: .max,
                declared: kind.arrayOffset, expected: .empty)
            add("declared-export-seven-bytes", count: .max,
                declared: kind.arrayOffset + 7, expected: .empty)
            add("declared-export-complete", count: .max,
                declared: kind.arrayOffset + 8, expected: .exportOnly)
            add("declared-import-seven-bytes", count: .max,
                declared: kind.arrayOffset + 15, expected: .exportOnly)
            add("declared-two-complete-slots", count: .max,
                declared: kind.arrayOffset + 16, expected: .both)

            // Physical truncation also removes the later section table. The public
            // parser must refuse that image, not claim a successfully loaded empty
            // table. We assert the real error and do not pretend to isolate a private
            // helper at an unreachable successful-image boundary.
            add("readable-count-absent", count: .max,
                readable: kind.countOffset, expected: .sectionTableTruncated)
            add("readable-count-one-byte", count: .max,
                readable: kind.countOffset + 1, expected: .sectionTableTruncated)
            add("readable-count-three-bytes", count: .max,
                readable: kind.countOffset + 3, expected: .sectionTableTruncated)
            add("readable-export-seven-bytes", count: .max,
                readable: kind.arrayOffset + 7, expected: .sectionTableTruncated)
            add("readable-import-seven-bytes", count: .max,
                readable: kind.arrayOffset + 15, expected: .sectionTableTruncated)
        }
        return result
    }

    static func verify(_ witness: Witness) throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(description: "\(witness.name): \(message)") }
        }
        let loaded: LoadedBinary
        do {
            // Exactly one production parse per witness. The returned value is the
            // real LoadedBinary and contains the real ImportSummary/ExportSummary.
            loaded = try PEBinaryLoader.parse(
                bytes: witness.bytes, name: witness.name + ".exe", path: "/synthetic/" + witness.name,
                stringLimits: .init(maximumStringBytes: witness.stringLimit,
                                    maximumTotalStringBytes: 128,
                                    maximumTotalScannedBytes: 256))
        } catch let error as PELoadError {
            switch (witness.expected, error) {
            case (.sectionTableTruncated, .truncated(let context)):
                try require(context == "section table", "unexpected truncation: \(context)")
                return
            case (.poisonBudget, .boundExceeded(let context)):
                try require(context == "individual string bytes", "unexpected poison failure: \(context)")
                return
            default:
                throw Failure(description: "\(witness.name): unexpected PE error \(error)")
            }
        }
        try require(witness.expected != .sectionTableTruncated && witness.expected != .poisonBudget,
                    "expected refusal but parsing succeeded")
        let expectExport = witness.expected == .exportOnly || witness.expected == .both
        let expectImport = witness.expected == .both
        try require(loaded.exports.count == (expectExport ? 1 : 0), "wrong export count")
        try require(loaded.imports.count == (expectImport ? 1 : 0), "wrong import count")
        if expectExport {
            try require(loaded.exports[0].name == witness.kind.exportName, "wrong export name")
            // EAT target is authored as RVA 0x3000, not computed from any admission rule.
            try require(loaded.exports[0].address == witness.kind.imageBase + 0x3000, "wrong export address")
            try require(loaded.exports[0].source == "export-table", "wrong export provenance")
        }
        if expectImport {
            try require(loaded.imports[0].name == witness.kind.importName, "wrong import name")
            try require(loaded.imports[0].libraryName == "D61.DLL", "wrong DLL")
            try require(loaded.imports[0].libraryOrdinal == nil, "named import became ordinal")
        }
        try require(loaded.symbols.isEmpty, "unexpected COFF fallback symbols")
        try require(loaded.bytes == witness.bytes && loaded.sliceOffset == 0, "byte authority changed")
        try require(loaded.sections.count == 1, "wrong real section projection")
        try require(loaded.sections[0].address == witness.kind.imageBase + 0x1000, "wrong section VA")
        try require(loaded.sections[0].fileOffset == 0x200 && loaded.sections[0].fileSize == 0x200,
                    "wrong section file extent")
        try require(loaded.entryPointAddress == witness.kind.imageBase + 0x3000, "wrong entry projection")
        try require(loaded.fileTypeName == "PE executable", "wrong format")
        try require(loaded.stringLiterals.isEmpty && loaded.functionStarts.isEmpty,
                    "unexpected independent table contents")
    }

    /// Fixed independent byte layout: PE @0x80, optional header @0x98, section
    /// @ declared optional end, raw section @0x200 (RVA0x1000), 512 raw bytes.
    /// IMPORT @raw+0x00, ILT +0x40, hint/name +0x70, DLL +0x90.
    /// EXPORT @raw+0x100, EAT +0x140, name ptr +0x150, ordinal +0x160, name +0x170.
    private static func fixture(_ kind: Kind, count: UInt32, declared: Int?,
                                readable: Int?, poisonImport: Bool,
                                poisonExport: Bool, omitImport: Bool) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put(_ offset: Int, _ value: UInt64, _ width: Int) {
            for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        func string(_ offset: Int, _ value: String) {
            for (i, byte) in value.utf8.enumerated() { bytes[offset + i] = byte }
            bytes[offset + value.utf8.count] = 0
        }
        let optional = 0x98
        let optionalSize = declared ?? (kind == .pe32 ? 0xE0 : 0xF0)
        put(0, 0x5A4D, 2); put(0x3C, 0x80, 4); put(0x80, 0x4550, 4)
        put(0x84, kind == .pe32 ? 0x014C : 0x8664, 2)
        put(0x86, 1, 2); put(0x94, UInt64(optionalSize), 2); put(0x96, 0x0022, 2)
        put(optional, kind == .pe32 ? 0x010B : 0x020B, 2)
        put(optional + 16, 0x3000, 4)
        put(optional + (kind == .pe32 ? 28 : 24), kind.imageBase, kind == .pe32 ? 4 : 8)
        put(optional + kind.countOffset, UInt64(count), 4)
        put(optional + kind.arrayOffset, 0x1100, 4)
        put(optional + kind.arrayOffset + 4, 40, 4)
        put(optional + kind.arrayOffset + 8, omitImport ? 0 : 0x1000, 4)
        put(optional + kind.arrayOffset + 12, omitImport ? 0 : 40, 4)

        // Write the actual section header last: truncated-declaration witnesses
        // intentionally make readable would-be optional bytes be section bytes.
        let section = optional + optionalSize
        string(section, ".d61")
        for i in 5..<8 { bytes[section + i] = 0 }
        put(section + 8, 0x200, 4); put(section + 12, 0x1000, 4)
        put(section + 16, 0x200, 4); put(section + 20, 0x200, 4)
        put(section + 36, 0x4000_0040, 4)

        put(0x200, 0x1040, 4); put(0x20C, 0x1090, 4); put(0x210, 0x1040, 4)
        put(0x240, 0x1070, kind == .pe32 ? 4 : 8)
        string(0x272, kind.importName)
        string(0x290, poisonImport ? "POISON_IMPORT_DLL" : "D61.DLL")
        put(0x310, 1, 4); put(0x314, 1, 4); put(0x318, 1, 4)
        put(0x31C, 0x1140, 4); put(0x320, 0x1150, 4); put(0x324, 0x1160, 4)
        put(0x340, 0x3000, 4); put(0x350, 0x1170, 4); put(0x360, 0, 2)
        string(0x370, poisonExport ? "POISON_EXPORT_NAME" : kind.exportName)
        return Data(readable.map { Array(bytes.prefix(optional + $0)) } ?? bytes)
    }
}

#if !DOT61_PORTABLE
final class PEDataDirectoryCountTests: XCTestCase {
    func testLogicalCountAndIndependentHeaderExtents() throws {
        for witness in PEDataDirectoryCountWitnesses.cases() {
            XCTAssertNoThrow(try PEDataDirectoryCountWitnesses.verify(witness), witness.name)
        }
    }
}
#endif
