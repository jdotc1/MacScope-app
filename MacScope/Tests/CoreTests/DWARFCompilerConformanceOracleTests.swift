import Foundation
import XCTest
@testable import MacScope

/// Bounded regression for independently validated, linked CP17 section reductions.
/// No compiler invocation, subprocess, network access, or corpus execution.
/// The saved pair uses independent DWARF traversal and LLVM expectations;
/// two authored vectors check inheritance and conservative lookup failure.
final class DWARFCompilerConformanceOracleTests: XCTestCase {
    /// This is intentionally a genuine regression test. At the pinned revision,
    /// saved product execution returns left/unit.c and 0x402000, so the two value
    /// assertions below are expected to fail until the product is repaired.
    func testIndexedCURootAttributesUseTheirOwnLateBases() throws {
        try assertCompilationUnit(.indexedBeforeBases)
    }

    /// Same semantic CU, original linked tables, and values; only base/indexed
    /// attribute ordering differs. Saved product execution recovers both values.
    func testBaseFirstCURootControl() throws {
        try assertCompilationUnit(.basesBeforeIndexed)
    }

    func testDescendantsInheritLateBasesAndNextCUResetsThem() {
        // Two contributions deliberately disagree at the same indexes. The
        // second CU omits bases and must use its own default, not inherit 24.
        let sections = indexedSections(rootIndexes: 0, includeDefaultCU: true)
        let roots = DWARFDIETree(sections: sections).parse()
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(roots.first?.attributes[0x03], .string("late.c"))
        XCTAssertEqual(roots.first?.attributes[0x11], .address(0x2000))
        XCTAssertEqual(roots.first?.children.first?.attributes[0x03], .string("late_fn"))
        XCTAssertEqual(roots.first?.children.first?.attributes[0x11], .address(0x2010))
        XCTAssertEqual(roots.last?.attributes[0x03], .string("default.c"))
        XCTAssertEqual(roots.last?.attributes[0x11], .address(0x1000))
        XCTAssertEqual(roots.last?.children.first?.attributes[0x03], .string("default_fn"))
        XCTAssertEqual(roots.last?.children.first?.attributes[0x11], .address(0x1010))
    }

    func testUnresolvableIndexesRetainRawValues() {
        let roots = DWARFDIETree(sections: indexedSections(rootIndexes: 255)).parse()
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots.first?.attributes[0x03], .strIndex(255))
        XCTAssertEqual(roots.first?.attributes[0x11], .addrIndex(255))
        // A failed root lookup must not lose the bases used by its child.
        XCTAssertEqual(roots.first?.children.first?.attributes[0x03], .string("late_fn"))
        XCTAssertEqual(roots.first?.children.first?.attributes[0x11], .address(0x2010))
    }

    private func indexedSections(rootIndexes: UInt8, includeDefaultCU: Bool = false) -> DWARFReader.Sections {
        // Root: strx1/addrx1 followed by sec_offset bases. Child and second
        // root: ULEB strx/addrx. All offsets/addresses are explicit test facts.
        let abbrev = Data([
            1, 0x11, 1, 3, 0x25, 0x11, 0x29, 0x72, 0x17, 0x73, 0x17, 0, 0,
            2, 0x2e, 0, 3, 0x1a, 0x11, 0x1b, 0, 0,
            3, 0x11, 1, 3, 0x1a, 0x11, 0x1b, 0, 0, 0,
        ])
        func littleEndian(_ value: UInt64, count: Int) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        func unit(_ die: [UInt8]) -> Data {
            let body: [UInt8] = [5, 0, 1, 8, 0, 0, 0, 0] + die
            return Data(littleEndian(UInt64(body.count), count: 4) + body)
        }
        let lateRoot: [UInt8] = [1, rootIndexes, rootIndexes]
            + littleEndian(24, count: 4) + littleEndian(24, count: 4)
        var info = unit(lateRoot + [2, 1, 1, 0])
        if includeDefaultCU { info += unit([3, 0, 0, 2, 1, 1, 0]) }
        var offsets = [UInt8](repeating: 0, count: 8)
        for offset in [UInt64(0), 10, 0, 0, 21, 28] {
            offsets += littleEndian(offset, count: 4)
        }
        var addresses = [UInt8](repeating: 0, count: 8)
        for address in [UInt64(0x1000), 0x1010, 0x2000, 0x2010] {
            addresses += littleEndian(address, count: 8)
        }
        return DWARFReader.Sections(
            debugInfo: info, debugAbbrev: abbrev,
            debugStr: Data("default.c\0default_fn\0late.c\0late_fn\0".utf8),
            debugStrOffsets: Data(offsets), debugAddr: Data(addresses)
        )
    }

    private enum Fixture: String {
        case indexedBeforeBases = "cu-root-indexed-before-bases"
        case basesBeforeIndexed = "cu-root-bases-before-indexed-control"
    }

    private func assertCompilationUnit(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let directory = try fixtureDirectory(fixture)
        func section(_ name: String) throws -> Data {
            try Data(contentsOf: directory.appendingPathComponent(name + ".bin"))
        }
        let sections = DWARFReader.Sections(
            debugInfo: try section("debug_info"),
            debugAbbrev: try section("debug_abbrev"),
            debugStr: try section("debug_str"),
            debugStrOffsets: try section("debug_str_offsets"),
            debugAddr: try section("debug_addr")
        )
        let roots = DWARFDIETree(sections: sections).parse()
        XCTAssertEqual(roots.count, 1, "Saved witness contains exactly one CU", file: file, line: line)
        let root = try XCTUnwrap(roots.first, "CU recovery is required", file: file, line: line)
        // DW_AT_name = 0x03; DW_AT_low_pc = 0x11. These constants identify
        // independent semantic facts, not a copied renderer or recovered baseline.
        XCTAssertEqual(root.attributes[0x03], DWARFAttributeValue.string("entry.c"), file: file, line: line)
        XCTAssertEqual(root.attributes[0x11], DWARFAttributeValue.address(0x401030), file: file, line: line)
    }

    private func fixtureDirectory(_ fixture: Fixture) throws -> URL {
        let relative = "GoldenFixtures/dwarf-compiler-conformance"
        // Source checkout is available to the normal focused CoreTests workflow.
        let sourceRoot = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relative, isDirectory: true)
        var candidates = [sourceRoot]
        // Also support an explicit fixture-folder resource in a packaged test target.
        let bundle = Bundle(for: DWARFCompilerConformanceOracleTests.self)
        if let resource = bundle.url(forResource: "dwarf-compiler-conformance", withExtension: nil,
                                     subdirectory: "GoldenFixtures") {
            candidates.append(resource)
        }
        if let resource = bundle.url(forResource: "dwarf-compiler-conformance", withExtension: nil) {
            candidates.append(resource)
        }
        for root in candidates {
            let directory = root.appendingPathComponent(fixture.rawValue, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("debug_info.bin").path) {
                return directory
            }
        }
        throw NSError(domain: "CP17FixtureConsumer", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Missing saved CP17 fixture \(fixture.rawValue); include the fixture folder or use the source checkout."
        ])
    }
}
