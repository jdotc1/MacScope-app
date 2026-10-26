import Foundation
import XCTest
@testable import MacScope

/// Unit tests for the three pure browser view-models (Imports / Exports /
/// Sections). They exercise the headless sort + filter logic only — the SwiftUI
/// list views are thin and carry no logic of their own.
final class BrowserModelTests: XCTestCase {

    // MARK: - Fixtures

    private func anImport(_ name: String, library: String? = nil, ordinal: Int? = nil) -> ImportSummary {
        ImportSummary(id: UUID(), name: name, libraryName: library, libraryOrdinal: ordinal)
    }

    private func anExport(_ name: String, address: UInt64? = nil, source: String = "exports trie") -> ExportSummary {
        ExportSummary(id: UUID(), name: name, address: address, source: source)
    }

    private func aSection(
        _ name: String,
        address: UInt64,
        size: UInt64,
        fileOffset: UInt64,
        isExecutable: Bool = false,
        isZeroFill: Bool = false
    ) -> SectionSummary {
        SectionSummary(
            id: UUID(),
            name: name,
            address: address,
            size: size,
            fileOffset: fileOffset,
            isExecutable: isExecutable,
            isZeroFill: isZeroFill
        )
    }

    // MARK: - Imports: empty + populated

    func testImportsEmptySnapshot() {
        let model = ImportsBrowserModel(imports: [])
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.rows.count, 0)
    }

    func testImportsPopulatedDefaultSortIsByName() {
        let imports = [
            anImport("_printf", library: "libSystem.B.dylib", ordinal: 2),
            anImport("_abort", library: "libSystem.B.dylib", ordinal: 2),
            anImport("_objc_msgSend", library: "libobjc.A.dylib", ordinal: 1)
        ]
        let model = ImportsBrowserModel(imports: imports)
        XCTAssertEqual(model.rows.map(\.name), ["_abort", "_objc_msgSend", "_printf"])
    }

    func testImportsLibraryPlaceholderForNilLibrary() {
        let model = ImportsBrowserModel(imports: [anImport("_x", library: nil, ordinal: nil)])
        XCTAssertEqual(model.rows.first?.library, ImportsBrowserModel.noLibraryPlaceholder)
        XCTAssertEqual(model.rows.first?.ordinalText, ImportsBrowserModel.noLibraryPlaceholder)
    }

    func testImportsSortByLibraryThenName() {
        let imports = [
            anImport("_printf", library: "libSystem.B.dylib"),
            anImport("_objc_msgSend", library: "libobjc.A.dylib"),
            anImport("_abort", library: "libSystem.B.dylib")
        ]
        let model = ImportsBrowserModel(imports: imports, sort: .library)
        // Library sort is case-insensitive (the model lowercases), so "libobjc"
        // precedes "libsystem" (o < s); within libSystem, by name (abort < printf).
        XCTAssertEqual(model.rows.map(\.name), ["_objc_msgSend", "_abort", "_printf"])
        XCTAssertEqual(model.rows.map(\.library), ["libobjc.A.dylib", "libSystem.B.dylib", "libSystem.B.dylib"])
    }

    func testImportsSortByOrdinalPlacesOrdinalLessLast() {
        let imports = [
            anImport("_c", ordinal: nil),
            anImport("_a", ordinal: 3),
            anImport("_b", ordinal: 1)
        ]
        let model = ImportsBrowserModel(imports: imports, sort: .ordinal)
        XCTAssertEqual(model.rows.map(\.name), ["_b", "_a", "_c"])
        XCTAssertEqual(model.rows.last?.ordinalText, ImportsBrowserModel.noLibraryPlaceholder)
    }

    func testImportsFilterMatchesNameAndLibraryCaseInsensitive() {
        let imports = [
            anImport("_printf", library: "libSystem.B.dylib"),
            anImport("_objc_msgSend", library: "libobjc.A.dylib")
        ]
        // Match by symbol name fragment.
        XCTAssertEqual(ImportsBrowserModel(imports: imports, filter: "PRINT").rows.map(\.name), ["_printf"])
        // Match by library fragment narrows to the libobjc import.
        XCTAssertEqual(ImportsBrowserModel(imports: imports, filter: "libobjc").rows.map(\.name), ["_objc_msgSend"])
        // No match → empty.
        XCTAssertTrue(ImportsBrowserModel(imports: imports, filter: "zzz").isEmpty)
    }

    // MARK: - Exports: empty + populated, forwarders, ordinal-only

    func testExportsEmptySnapshot() {
        XCTAssertTrue(ExportsBrowserModel(exports: []).isEmpty)
    }

    func testExportsPopulatedDefaultSortIsByName() {
        let exports = [
            anExport("_main", address: 0x2000),
            anExport("_helper", address: 0x1000),
            anExport("_zeta", address: 0x3000)
        ]
        let model = ExportsBrowserModel(exports: exports)
        XCTAssertEqual(model.rows.map(\.name), ["_helper", "_main", "_zeta"])
    }

    func testExportsForwarderRowsLabeled() {
        let exports = [
            anExport("_local", address: 0x1000, source: "exports trie"),
            anExport("NTDLL.RtlEqual", address: nil, source: "forwarder")
        ]
        let model = ExportsBrowserModel(exports: exports)
        let forwarder = model.rows.first { $0.name == "NTDLL.RtlEqual" }
        XCTAssertEqual(forwarder?.isForwarder, true)
        XCTAssertEqual(forwarder?.addressText, ExportsBrowserModel.noAddressPlaceholder)
        let local = model.rows.first { $0.name == "_local" }
        XCTAssertEqual(local?.isForwarder, false)
        // Filtering on "forwarder" (the source) isolates the forwarder export.
        let filtered = ExportsBrowserModel(exports: exports, filter: "forwarder")
        XCTAssertEqual(filtered.rows.map(\.name), ["NTDLL.RtlEqual"])
    }

    func testExportsByOrdinalOnlyExportShownWithSynthesizedName() {
        // PE labels nameless ordinal exports "#<ordinal>" upstream; they must still appear.
        let exports = [anExport("#42", address: 0x4000, source: "export-table")]
        let model = ExportsBrowserModel(exports: exports)
        XCTAssertEqual(model.rows.map(\.name), ["#42"])
        XCTAssertEqual(model.rows.first?.addressText, UInt64(0x4000).hexAddress)
    }

    func testExportsNamelessFallbackPlaceholder() {
        let model = ExportsBrowserModel(exports: [anExport("", address: 0x10)])
        XCTAssertEqual(model.rows.first?.name, ExportsBrowserModel.unnamedPlaceholder)
    }

    func testExportsSortByAddressPlacesAddresslessLast() {
        let exports = [
            anExport("_b", address: nil, source: "forwarder"),
            anExport("_a", address: 0x2000),
            anExport("_c", address: 0x1000)
        ]
        let model = ExportsBrowserModel(exports: exports, sort: .address)
        XCTAssertEqual(model.rows.map(\.name), ["_c", "_a", "_b"])
        XCTAssertEqual(model.rows.last?.addressText, ExportsBrowserModel.noAddressPlaceholder)
    }

    func testExportsFilterMatchesAddressFragment() {
        let exports = [
            anExport("_a", address: 0x1000),
            anExport("_b", address: 0x2abc)
        ]
        XCTAssertEqual(ExportsBrowserModel(exports: exports, filter: "2abc").rows.map(\.name), ["_b"])
    }

    // MARK: - Sections: empty + populated, zero-fill, sorts

    func testSectionsEmptySnapshot() {
        XCTAssertTrue(SectionsBrowserModel(sections: []).isEmpty)
    }

    func testSectionsPopulatedDefaultSortIsByAddress() {
        let sections = [
            aSection("__DATA,__data", address: 0x3000, size: 0x40, fileOffset: 0x3000),
            aSection("__TEXT,__text", address: 0x1000, size: 0x200, fileOffset: 0x1000, isExecutable: true),
            aSection("__TEXT,__cstring", address: 0x1200, size: 0x80, fileOffset: 0x1200)
        ]
        let model = SectionsBrowserModel(sections: sections)
        XCTAssertEqual(model.rows.map(\.name), ["__TEXT,__text", "__TEXT,__cstring", "__DATA,__data"])
        XCTAssertEqual(model.rows.first?.isExecutable, true)
    }

    func testSectionsZeroFillShownAndFlagged() {
        let sections = [
            aSection("__TEXT,__text", address: 0x1000, size: 0x100, fileOffset: 0x1000, isExecutable: true),
            aSection("__DATA,__bss", address: 0x4000, size: 0x800, fileOffset: 0, isZeroFill: true)
        ]
        let model = SectionsBrowserModel(sections: sections)
        let bss = model.rows.first { $0.name == "__DATA,__bss" }
        XCTAssertNotNil(bss, "zero-fill sections must be shown, not dropped")
        XCTAssertEqual(bss?.isZeroFill, true)
        XCTAssertEqual(bss?.fileOffsetText, SectionsBrowserModel.zeroFillOffsetPlaceholder)
    }

    func testSectionsSortByName() {
        let sections = [
            aSection("__TEXT,__text", address: 0x1000, size: 0x100, fileOffset: 0x1000),
            aSection("__DATA,__data", address: 0x2000, size: 0x40, fileOffset: 0x2000)
        ]
        let model = SectionsBrowserModel(sections: sections, sort: .name)
        XCTAssertEqual(model.rows.map(\.name), ["__DATA,__data", "__TEXT,__text"])
    }

    func testSectionsSortBySizeDescending() {
        let sections = [
            aSection("small", address: 0x1000, size: 0x10, fileOffset: 0x1000),
            aSection("large", address: 0x2000, size: 0x1000, fileOffset: 0x2000),
            aSection("mid", address: 0x3000, size: 0x100, fileOffset: 0x3000)
        ]
        let model = SectionsBrowserModel(sections: sections, sort: .size)
        XCTAssertEqual(model.rows.map(\.name), ["large", "mid", "small"])
    }

    func testSectionsFilterMatchesNameAndAddress() {
        let sections = [
            aSection("__TEXT,__text", address: 0x1000, size: 0x100, fileOffset: 0x1000),
            aSection("__DATA,__data", address: 0x2000, size: 0x40, fileOffset: 0x2000)
        ]
        XCTAssertEqual(SectionsBrowserModel(sections: sections, filter: "text").rows.map(\.name), ["__TEXT,__text"])
        // Address fragment of the second section.
        XCTAssertEqual(SectionsBrowserModel(sections: sections, filter: "2000").rows.map(\.name), ["__DATA,__data"])
    }

    func testSectionsSizeAndOffsetRendering() {
        let model = SectionsBrowserModel(sections: [
            aSection("__TEXT,__text", address: 0x4000, size: 0x1f40, fileOffset: 0xc00, isExecutable: true)
        ])
        let row = model.rows.first
        XCTAssertEqual(row?.addressText, UInt64(0x4000).hexAddress)
        XCTAssertEqual(row?.sizeText, "0x1f40")
        XCTAssertEqual(row?.fileOffsetText, "0xc00")
    }

    // MARK: - BrowserPane

    func testBrowserPaneDefaultAndCases() {
        XCTAssertEqual(BrowserPane.allCases, [.imports, .exports, .sections])
        XCTAssertEqual(BrowserPane.imports.displayName, "Imports")
        XCTAssertEqual(BrowserPane.exports.displayName, "Exports")
        XCTAssertEqual(BrowserPane.sections.displayName, "Sections")
        // Each pane carries a non-empty SF Symbol for the segmented control.
        for pane in BrowserPane.allCases {
            XCTAssertFalse(pane.systemImage.isEmpty)
        }
    }

    // MARK: - Browser row → navigation mapping

    func testExportRowNavigationAddressForAddressedExport() {
        let row = ExportsBrowserModel(exports: [anExport("_main", address: 0x2000)]).rows.first!
        XCTAssertEqual(BrowserNavigationTarget.address(forExport: row), 0x2000)
        XCTAssertTrue(BrowserNavigationTarget.isNavigable(row))
    }

    func testForwarderExportRowIsNotNavigable() {
        let row = ExportsBrowserModel(
            exports: [anExport("NTDLL.RtlEqual", address: nil, source: "forwarder")]
        ).rows.first!
        XCTAssertNil(BrowserNavigationTarget.address(forExport: row))
        XCTAssertFalse(BrowserNavigationTarget.isNavigable(row))
    }

    func testSectionRowNavigationAddressIsAlwaysPresent() {
        let row = SectionsBrowserModel(sections: [
            aSection("__TEXT,__text", address: 0x1000, size: 0x100, fileOffset: 0x1000, isExecutable: true)
        ]).rows.first!
        XCTAssertEqual(BrowserNavigationTarget.address(forSection: row), 0x1000)
    }
}
