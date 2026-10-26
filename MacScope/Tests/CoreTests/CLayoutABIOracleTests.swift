import Foundation
import XCTest
@testable import MacScope

/// The Darwin arm64 record-layout oracle (`GoldenFixtures/c-layout-abi-oracle/`): 4,644 C
/// records with Clang 19.1.7's arm64-apple-macos14 layout. Each record is imported on its own
/// (the common preamble and dependencies, then its declaration) with `CTypeHeaderParser`, and its
/// size, alignment and member offsets from `TypeDefinition` are compared with Clang's.
///
/// Members are matched by name: direct fields, and the fields of an anonymous struct or union,
/// which the layout promotes. A plain member must sit at Clang's byte offset. Bitfields,
/// including unnamed and zero-width fields, must match the exact absolute bit offset and width.
/// A second gate exports each imported record with
/// `CTypeHeaderRenderer`, re-imports it, and requires the same size, alignment and offsets.
///
/// Every record in `baseline-pass.txt` must still match Clang, and every record in
/// `baseline-roundtrip.txt` must still survive the round trip. Record new baselines with
/// `TEST_RUNNER_MACSCOPE_LAYOUT_ORACLE_RECORD_BASELINE=1` (written only when nothing in the old ones
/// regressed). The report goes to `TEST_RUNNER_MACSCOPE_LAYOUT_ORACLE_REPORT=<dir>`, or to the
/// temporary directory when unset.
final class CLayoutABIOracleTests: XCTestCase {
    struct Field: Decodable {
        let name: String?
        let depth: Int
        let byteOffset: Int
        let bitOffset: Int
        let bitWidth: Int?

        enum CodingKeys: String, CodingKey {
            case name, depth
            case byteOffset = "byte_offset"
            case bitOffset = "bit_offset"
            case bitWidth = "bit_width"
        }
    }

    struct Layout: Decodable {
        let name: String
        let kind: String
        let family: String
        let declaration: String
        let size: Int
        let align: Int
        let fields: [Field]
    }

    struct File: Decodable {
        let schema: String
        let productRevision: String
        let preamble: String
        let dependencies: [String]
        let layouts: [Layout]

        enum CodingKeys: String, CodingKey {
            case schema, preamble, dependencies, layouts
            case productRevision = "product_revision"
        }
    }

    /// The first difference found in a record, in the order checked.
    enum Outcome: String, CaseIterable {
        case pass
        case notImported = "not-imported"
        case sizeUnknown = "size-unknown"
        case sizeMismatch = "size-mismatch"
        case alignMismatch = "align-mismatch"
        case memberMissing = "member-missing"
        case offsetMismatch = "offset-mismatch"
        case bitfieldOutsideStorage = "bitfield-outside-storage"
        case bitfieldOffsetMismatch = "bitfield-offset-mismatch"
    }

    /// What MacScope computed for one record: size, alignment and each named member's byte offset.
    struct BitMember: Equatable {
        var name: String
        var offset: Int?
        var width: Int
    }

    struct Computed: Equatable {
        var size: Int?
        var align: Int?
        var offsets: [String: Int]
        var bits: [BitMember]
    }

    static let fixtureDirectory = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent() // …/CoreTests
        .appendingPathComponent("GoldenFixtures/c-layout-abi-oracle", isDirectory: true)

    static func loadLayouts() throws -> File {
        let compressed = try Data(contentsOf: fixtureDirectory.appendingPathComponent("layouts.json.gz"))
        return try JSONDecoder().decode(File.self, from: try A64OracleGzip.decompress(compressed))
    }

    static func source(_ layout: Layout, in file: File) -> String {
        ([file.preamble] + file.dependencies + [layout.declaration]).joined(separator: "\n") + "\n"
    }

    static func catalog(_ types: [TypeDefinition]) -> [String: TypeDefinition] {
        Dictionary(types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func computed(_ name: String, in catalog: [String: TypeDefinition]) -> Computed? {
        guard let definition = catalog[name] else { return nil }
        var offsets: [String: Int] = [:]
        for member in definition.memberLayout(in: catalog) where !member.field.name.isEmpty {
            offsets[member.field.name] = offsets[member.field.name] ?? member.offset
        }
        return Computed(size: TypeDefinition.size(ofType: name, in: catalog),
                        align: TypeDefinition.alignment(ofType: name, in: catalog),
                        offsets: offsets,
                        bits: definition.memberLayout(in: catalog).compactMap { member in
                            member.field.bitWidth.map { BitMember(name: member.field.name, offset: member.field.bitOffset, width: $0) }
                        })
    }

    /// Clang's fields that MacScope lays out by name: direct fields, and fields of an anonymous
    /// aggregate (which the layout promotes into the enclosing record).
    static func comparableFields(_ layout: Layout, includingUnnamedBitfields: Bool = false) -> [Field] {
        var result: [Field] = []
        var anonymousDepths: [Int] = []
        for field in layout.fields {
            anonymousDepths.removeAll { $0 >= field.depth }
            let promoted = field.depth == 1 || anonymousDepths.contains(field.depth - 1)
            if field.name == nil {
                if field.bitWidth == nil { anonymousDepths.append(field.depth) }
                else if includingUnnamedBitfields && promoted { result.append(field) }
                continue
            }
            if promoted { result.append(field) }
        }
        return result
    }

    static func check(_ layout: Layout, types: [TypeDefinition]) -> (Outcome, String) {
        let catalog = catalog(types)
        guard catalog[layout.name] != nil, let computed = computed(layout.name, in: catalog) else {
            return (.notImported, "no \(layout.kind) \(layout.name) after import")
        }
        guard let size = computed.size else { return (.sizeUnknown, "size unknown; Clang \(layout.size)") }
        guard size == layout.size else { return (.sizeMismatch, "size \(size); Clang \(layout.size)") }
        guard computed.align == layout.align else {
            return (.alignMismatch, "align \(computed.align.map(String.init) ?? "unknown"); Clang \(layout.align)")
        }
        let expectedBits = comparableFields(layout, includingUnnamedBitfields: true).filter { $0.bitWidth != nil }
        // Includes unnamed and zero-width fields; byte containment alone misses packed crossings.
        guard computed.bits.count == expectedBits.count else {
            return (.memberMissing, "bitfield count \(computed.bits.count); Clang \(expectedBits.count)")
        }
        for (actual, expected) in zip(computed.bits, expectedBits) {
            guard actual.name == (expected.name ?? ""), actual.offset == expected.bitOffset, actual.width == expected.bitWidth else {
                return (.bitfieldOffsetMismatch, "\(actual.name): bit \(actual.offset.map(String.init) ?? "?") width \(actual.width); Clang bit \(expected.bitOffset) width \(expected.bitWidth ?? 0)")
            }
        }
        for field in comparableFields(layout) {
            let name = field.name ?? ""
            guard let offset = computed.offsets[name] else { return (.memberMissing, "no member \(name)") }
            if field.bitWidth == nil && offset != field.byteOffset {
                return (.offsetMismatch, "\(name) at \(offset); Clang \(field.byteOffset)")
            }
        }
        return (.pass, "")
    }

    func testRecordLayoutsAgainstClang() throws {
        let file = try Self.loadLayouts()
        XCTAssertEqual(file.schema, "macscope-c-layout-abi-oracle-slice-1")
        XCTAssertEqual(file.layouts.count, 4_644)

        var outcomes: [(layout: Layout, outcome: Outcome, detail: String)] = []
        var roundTrips: [(layout: Layout, stable: Bool, detail: String)] = []
        for layout in file.layouts {
            // One record per import: a batch would hit the parser's token budget.
            let imported = CTypeHeaderParser.parse(Self.source(layout, in: file)).types
            let (outcome, detail) = Self.check(layout, types: imported)
            outcomes.append((layout, outcome, detail))

            let first = Self.computed(layout.name, in: Self.catalog(imported))
            let reimported = CTypeHeaderParser.parse(CTypeHeaderRenderer.render(types: imported)).types
            let second = Self.computed(layout.name, in: Self.catalog(reimported))
            if let first, first.size != nil {
                let stable = first == second
                roundTrips.append((layout, stable, stable ? "" : "import \(Self.describe(first)); re-import \(second.map(Self.describe) ?? "missing")"))
            }
        }

        let environment = ProcessInfo.processInfo.environment
        let reportDirectory = environment["MACSCOPE_LAYOUT_ORACLE_REPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("c-layout-abi-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let report = Self.report(file: file, outcomes: outcomes, roundTrips: roundTrips)
        try report.markdown.write(to: reportDirectory.appendingPathComponent("c-layout-abi-oracle-report.md"), atomically: true, encoding: .utf8)
        print("C layout oracle: \(report.summary) → \(reportDirectory.path)")

        let passing = Set(outcomes.filter { $0.outcome == .pass }.map(\.layout.name))
        let stable = Set(roundTrips.filter(\.stable).map(\.layout.name))
        let record = environment["MACSCOPE_LAYOUT_ORACLE_RECORD_BASELINE"] == "1"
        var regressed = false
        for (fileName, current, what) in [("baseline-pass.txt", passing, "match Clang"), ("baseline-roundtrip.txt", stable, "survive export and re-import")] {
            let url = Self.fixtureDirectory.appendingPathComponent(fileName)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                if !record { XCTFail("no \(fileName); record one with TEST_RUNNER_MACSCOPE_LAYOUT_ORACLE_RECORD_BASELINE=1") }
                continue
            }
            let baseline = Set(text.split(whereSeparator: \.isNewline).map(String.init))
            let lost = baseline.subtracting(current).sorted()
            if !lost.isEmpty { regressed = true }
            XCTAssertTrue(lost.isEmpty, "\(lost.count) baseline records no longer \(what): \(lost.prefix(20).joined(separator: ", "))")
            let gained = current.subtracting(baseline).count
            if gained > 0, !record { print("C layout oracle: \(gained) records now \(what) beyond \(fileName); re-record it in this PR.") }
        }
        if record, !regressed {
            try (passing.sorted().joined(separator: "\n") + "\n")
                .write(to: Self.fixtureDirectory.appendingPathComponent("baseline-pass.txt"), atomically: true, encoding: .utf8)
            try (stable.sorted().joined(separator: "\n") + "\n")
                .write(to: Self.fixtureDirectory.appendingPathComponent("baseline-roundtrip.txt"), atomically: true, encoding: .utf8)
            print("C layout oracle: recorded \(passing.count) matching and \(stable.count) round-trip-stable records.")
        }
    }

    func testSupplementaryClangAttributeAndPackingLayouts() throws {
        let compressed = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("supplementary-layouts.json.gz"))
        let file = try JSONDecoder().decode(File.self, from: try A64OracleGzip.decompress(compressed))
        XCTAssertEqual(file.schema, "macscope-c-layout-abi-supplement-1")
        XCTAssertEqual(file.layouts.count, 477)
        var failures: [String] = []
        var roundTripFailures: [String] = []
        for layout in file.layouts {
            let imported = CTypeHeaderParser.parse(Self.source(layout, in: file)).types
            let (outcome, detail) = Self.check(layout, types: imported)
            if outcome != .pass { failures.append("\(layout.name) \(outcome.rawValue): \(detail)\n\(layout.declaration)") }
            let reimported = CTypeHeaderParser.parse(CTypeHeaderRenderer.render(types: imported)).types
            if Self.computed(layout.name, in: Self.catalog(imported)) != Self.computed(layout.name, in: Self.catalog(reimported)) {
                roundTripFailures.append(layout.name + "\n" + CTypeHeaderRenderer.render(types: imported))
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n\n"))
        XCTAssertTrue(roundTripFailures.isEmpty, roundTripFailures.joined(separator: "\n\n"))
        print("Supplementary Clang layouts: \(file.layouts.count - failures.count)/\(file.layouts.count); round trips \(file.layouts.count - roundTripFailures.count)/\(file.layouts.count)")
    }

    func testComparableFieldsPromoteOnlyAnonymousAggregates() throws {
        func field(_ name: String?, _ depth: Int, bitWidth: Int? = nil) -> Field {
            Field(name: name, depth: depth, byteOffset: 0, bitOffset: 0, bitWidth: bitWidth)
        }
        let layout = Layout(name: "L", kind: "struct", family: "x", declaration: "", size: 0, align: 1, fields: [
            field("head", 1), field(nil, 1), field("first", 2), field("second", 2),
            field("nested", 1), field("inner", 2), field(nil, 1, bitWidth: 0), field("tail", 1),
        ])
        XCTAssertEqual(Self.comparableFields(layout).compactMap(\.name), ["head", "first", "second", "nested", "tail"])
    }

    // MARK: Report

    static func describe(_ computed: Computed) -> String {
        "size \(computed.size.map(String.init) ?? "?") align \(computed.align.map(String.init) ?? "?") "
            + computed.offsets.sorted { $0.key < $1.key }.map { "\($0.key)@\($0.value)" }.joined(separator: " ")
    }

    struct Report {
        let summary: String
        let markdown: String
    }

    static func report(file: File, outcomes: [(layout: Layout, outcome: Outcome, detail: String)],
                       roundTrips: [(layout: Layout, stable: Bool, detail: String)]) -> Report {
        var totals: [Outcome: Int] = [:]
        var byFamily: [String: [Outcome: Int]] = [:]
        for entry in outcomes {
            totals[entry.outcome, default: 0] += 1
            byFamily[entry.layout.family, default: [:]][entry.outcome, default: 0] += 1
        }
        let stableCount = roundTrips.filter(\.stable).count
        let summary = Outcome.allCases.map { "\(totals[$0] ?? 0) \($0.rawValue)" }.joined(separator: ", ")
            + " of \(outcomes.count); round trip \(stableCount)/\(roundTrips.count) stable"
        var lines = ["# C record layouts against Clang", "",
                     "Reference: Clang 19.1.7, arm64-apple-macos14 (gnu11, freestanding, -O0); oracle baseline \(file.productRevision).", "",
                     "| Outcome | Records |", "|---|---:|"]
        lines += Outcome.allCases.map { "| \($0.rawValue) | \(totals[$0] ?? 0) |" }
        lines += ["", "Export and re-import: \(stableCount) of \(roundTrips.count) records with a known size keep their size, alignment and offsets.",
                  "", "## By family", "",
                  "| Family | Total | " + Outcome.allCases.map(\.rawValue).joined(separator: " | ") + " | round trip stable |",
                  "|---|---:|" + String(repeating: "---:|", count: Outcome.allCases.count + 1)]
        for family in byFamily.keys.sorted() {
            let counts = byFamily[family]!
            let trips = roundTrips.filter { $0.layout.family == family }
            lines.append("| \(family) | \(counts.values.reduce(0, +)) | "
                + Outcome.allCases.map { String(counts[$0] ?? 0) }.joined(separator: " | ")
                + " | \(trips.filter(\.stable).count)/\(trips.count) |")
        }
        lines += ["", "## Every non-passing record", ""]
        for entry in outcomes where entry.outcome != .pass {
            lines.append("- \(entry.layout.name) (\(entry.layout.family), \(entry.outcome.rawValue)): \(entry.detail) — `\(entry.layout.declaration)`")
        }
        lines += ["", "## Every record changed by export and re-import", ""]
        for trip in roundTrips where !trip.stable {
            lines.append("- \(trip.layout.name) (\(trip.layout.family)): \(trip.detail) — `\(trip.layout.declaration)`")
        }
        return Report(summary: summary, markdown: lines.joined(separator: "\n") + "\n")
    }
}
