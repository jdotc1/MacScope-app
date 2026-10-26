import Foundation
import XCTest
@testable import MacScope

/// Clang 19.1.7 Darwin arm64 oracle, compared with the binder-only rich API.
/// All 304 named-formal call signatures and 25 return probes are checked. Source
/// declarations are parsed into Type Atlas; expected ABI classifications are not
/// supplied to the implementation. Composite piece ranges, pointer semantics,
/// stack sizes/alignments and register spellings are compared independently.
/// The legacy API is separately frozen at 154 PASS / 150 UNSUPPORTED.
/// Anonymous variadic actuals remain outside the named-formal interface.
///
/// Every baseline call/RETURN ID must still pass. Re-record only after comparison
/// with MACSCOPE_ABI_CALL_ORACLE_RECORD_BASELINE=1 (TEST_RUNNER_ prefix on the Mac).
final class DarwinARM64CallBindingOracleTests: XCTestCase {
    private static let baselineURL = ABICallOracleFile.fixtureDirectory.appendingPathComponent("baseline-pass.txt")

    func testOracleCallsAndReturnsAgainstRichBinder() throws {
        let file = try ABICallOracleFile.load()
        XCTAssertEqual(file.schema, "macscope-darwin-arm64-layout-abi-oracle-1")
        XCTAssertEqual(file.calls.count, 304)
        XCTAssertEqual(file.returnProbes.count, 25)

        let resolver = try Self.resolver(file: file)
        let outcomes = file.calls.map { ABICallOracleRunner.run($0, types: file.types, resolver: resolver) }
        let returns = file.returnProbes.keys.sorted().map { ABICallOracleRunner.runReturn($0, file: file, resolver: resolver) }
        XCTAssertTrue(outcomes.allSatisfy { $0.status != .fail }, "A rich binding differs from the oracle")
        XCTAssertTrue(returns.allSatisfy { $0.status == .pass }, returns.map { "\($0.id): \($0.detail)" }.joined(separator: "\n"))
        let harnessFailures = outcomes.filter { $0.status == .harness }
        XCTAssertTrue(harnessFailures.isEmpty,
                      "harness could not read \(harnessFailures.count) cases, first: \(harnessFailures.first.map { "\($0.call.id) \($0.diffs.joined(separator: "; "))" } ?? "")")

        let report = ABICallOracleReport(outcomes: outcomes, returns: returns, file: file)
        let environment = ProcessInfo.processInfo.environment
        let reportDirectory = environment["MACSCOPE_ABI_CALL_ORACLE_REPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("abi-call-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let markdown = report.markdown()
        try markdown.write(to: reportDirectory.appendingPathComponent("abi-call-oracle-report.md"), atomically: true, encoding: .utf8)
        print(markdown)
        print("ABI call oracle: \(report.summaryLine) → \(reportDirectory.path)")

        let passing = Set(outcomes.filter { $0.status == .pass }.map(\.call.id))
            .union(returns.filter { $0.status == .pass }.map(\.id))
        guard let baselineText = try? String(contentsOf: Self.baselineURL, encoding: .utf8) else {
            return XCTFail("no baseline-pass.txt; record one with TEST_RUNNER_MACSCOPE_ABI_CALL_ORACLE_RECORD_BASELINE=1")
        }
        let baseline = Set(baselineText.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty })
        XCTAssertGreaterThanOrEqual(passing.count, baseline.count, "PASS count dropped below the committed baseline")
        let regressed = baseline.subtracting(passing).sorted()
        XCTAssertTrue(regressed.isEmpty, "Baseline cases no longer pass: " + regressed.joined(separator: ", "))
        // Record only after checking every old ID; never bless a regression.
        if environment["MACSCOPE_ABI_CALL_ORACLE_RECORD_BASELINE"] == "1", regressed.isEmpty {
            try (passing.sorted().joined(separator: "\n") + "\n").write(to: Self.baselineURL, atomically: true, encoding: .utf8)
            print("ABI call oracle: recorded \(passing.count) passing call/return IDs.")
        }
        let newlyPassing = passing.subtracting(baseline)
        if !newlyPassing.isEmpty {
            print("ABI call oracle: \(newlyPassing.count) cases now pass beyond the baseline; re-record it in this PR.")
        }
    }
    static func resolver(file: ABICallOracleFile) throws -> TypeAtlasDarwinARM64LayoutResolver {
        // Source declarations are copied verbatim from the oracle's synthetic C.
        // The implementation is never fed the expected kind/size/HFA classification.
        let source = try String(contentsOf: ABICallOracleFile.fixtureDirectory.appendingPathComponent("types.h"), encoding: .utf8)
        let parsed = CTypeHeaderParser.parse(source)
        XCTAssertTrue(parsed.diagnostics.isEmpty, parsed.diagnostics.joined(separator: "\n"))
        let resolver = TypeAtlasDarwinARM64LayoutResolver(catalog: Dictionary(parsed.types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }))
        for (key, info) in file.types {
            let layout = try XCTUnwrap(resolver.resolveLayout(ofType: info.c), key)
            XCTAssertEqual(layout.size, info.size, key)
            XCTAssertEqual(layout.alignment, info.align, key)
        }
        return resolver
    }

    func testLegacyScalarOracleAndUnsupportedSetAreUnchanged() throws {
        let file = try ABICallOracleFile.load()
        let outcomes = file.calls.map { ABICallOracleRunner.run($0, types: file.types, useRich: false) }
        let baseline = try String(contentsOf: ABICallOracleFile.fixtureDirectory.appendingPathComponent("baseline-legacy-scalar-pass.txt"), encoding: .utf8)
        let expected = Set(baseline.split(whereSeparator: \.isNewline).map(String.init))
        XCTAssertEqual(Set(outcomes.filter { $0.status == .pass }.map(\.call.id)), expected)
        XCTAssertEqual(outcomes.filter { $0.status == .unsupported }.count, 150)
        XCTAssertTrue(outcomes.allSatisfy { $0.status == .pass || $0.status == .unsupported })
    }

}

// MARK: - Fixture

/// Mirrors only the fields of schema `macscope-darwin-arm64-layout-abi-oracle-1` the harness
/// consumes; the file's `fixture_contract` is the authority.
struct ABICallOracleFile: Decodable {
    struct TypeInfo: Decodable {
        let c: String
        let size: Int
        let align: Int
        let kind: String
        let base: String?
        let count: Int?
    }

    struct Location: Decodable {
        let register: String?
        let stackOffset: Int?
        let size: Int?
        let indirectResult: Bool?

        enum CodingKeys: String, CodingKey {
            case register, size
            case stackOffset = "stack_offset"
            case indirectResult = "indirect_result"
        }

        var rendered: String {
            if let register { return indirectResult == true ? "\(register)(indirect result)" : register }
            if let stackOffset { return "stack+\(stackOffset)/\(size ?? 0)" }
            return "?"
        }
    }

    struct Parameter: Decodable {
        let index: Int
        let type: String
        let effectiveType: String
        let indirect: Bool
        let anonymous: Bool
        let locations: [Location]

        enum CodingKeys: String, CodingKey {
            case index, type, indirect, anonymous, locations
            case effectiveType = "effective_type"
        }
    }

    struct Call: Decodable {
        let id: String
        let types: [String]
        let returnType: String
        let fixedCount: Int
        let variadic: Bool
        let family: String
        let signature: String
        let parameters: [Parameter]

        enum CodingKeys: String, CodingKey {
            case id, types, variadic, family, signature, parameters
            case returnType = "return_type"
            case fixedCount = "fixed_count"
        }
    }

    struct ReturnProbe: Decodable {
        let locations: [Location]
        let matched: Bool
    }

    let schema: String
    let types: [String: TypeInfo]
    let calls: [Call]
    let returnProbes: [String: ReturnProbe]

    enum CodingKeys: String, CodingKey {
        case schema, types, calls
        case returnProbes = "return_probes"
    }

    static let fixtureDirectory = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent() // …/CoreTests
        .appendingPathComponent("GoldenFixtures/abi-call-oracle", isDirectory: true)

    static func load() throws -> ABICallOracleFile {
        let compressed = try Data(contentsOf: fixtureDirectory.appendingPathComponent("call-vectors.json.gz"))
        return try JSONDecoder().decode(ABICallOracleFile.self, from: try A64OracleGzip.decompress(compressed))
    }
}

// MARK: - Runner

enum ABICallOracleRunner {
    enum Status: String, CaseIterable {
        case pass = "PASS"
        case fail = "FAIL"
        case unsupported = "UNSUPPORTED"
        case harness = "HARNESS"
    }

    struct Outcome {
        let call: ABICallOracleFile.Call
        let status: Status
        let categories: [String]
        let placementsCompared: Int
        let placementsMatched: Int
        let unsupportedFormals: [String]
        let anonymousActuals: Int
        let diffs: [String]
    }

    /// Categories a case is reported under (a case may carry several).
    static let categoryOrder = [
        "scalars", "fp", "hfa-hva", "small-aggregate", "large-aggregate",
        "variadic", "int128", "vector", "stack-spill",
    ]

    /// The binder's documented abstention set: aggregates (incl. HFA/HVA), short vectors, int128.
    static func isDocumentedLimit(_ key: String, types: [String: ABICallOracleFile.TypeInfo]) -> Bool {
        guard let info = types[key] else { return false }
        return info.kind == "aggregate" || info.kind == "hfa" || info.kind == "vector" || key == "i128"
    }

    static func categories(of call: ABICallOracleFile.Call, types: [String: ABICallOracleFile.TypeInfo]) -> [String] {
        var tags = Set<String>()
        for key in call.types {
            guard let info = types[key] else { continue }
            switch info.kind {
            case "int": tags.insert(key == "i128" ? "int128" : "scalars")
            case "fp": tags.insert("fp")
            case "hfa": tags.insert("hfa-hva")
            case "vector": tags.insert("vector")
            case "aggregate": tags.insert(info.size > 16 ? "large-aggregate" : "small-aggregate")
            default: break
            }
        }
        if call.variadic { tags.insert("variadic") }
        if call.parameters.prefix(call.fixedCount).contains(where: { $0.locations.contains { $0.stackOffset != nil } }) {
            tags.insert("stack-spill")
        }
        return categoryOrder.filter(tags.contains)
    }

    /// The binder's register spelling; widths the oracle never uses render distinctly so they
    /// cannot match by accident.
    static func render(_ location: MacIRABIParameterLocation) -> String {
        switch location {
        case let .gpr(index, carrierWidth):
            switch carrierWidth {
            case 32: "w\(index)"
            case 64: "x\(index)"
            default: "gpr\(index)/\(carrierWidth)"
            }
        case let .simd(index, scalarWidth):
            switch scalarWidth {
            case 32: "s\(index)"
            case 64: "d\(index)"
            case 128: "q\(index)"
            default: "v\(index)/\(scalarWidth)"
            }
        case let .entryStack(byteOffset, size, _):
            "stack+\(byteOffset)/\(size)"
        case let .unbound(reason):
            "unbound(\(reason))"
        }
    }

    static func render(_ register: DarwinARM64RichRegister) -> String {
        switch register {
        case let .gpr(index, width): return width == 32 ? "w\(index)" : (width == 64 ? "x\(index)" : "gpr\(index)/\(width)")
        case let .simd(index, width):
            let prefix = [32: "s", 64: "d", 128: "q"][width] ?? "simd/\(width)/"
            return prefix + String(index)
        }
    }

    static func render(_ location: DarwinARM64RichParameterLocation) -> String {
        switch location {
        case let .gpr(index, width): return render(.gpr(index: index, carrierWidth: width) as DarwinARM64RichRegister)
        case let .simd(index, width): return render(.simd(index: index, registerWidth: width) as DarwinARM64RichRegister)
        case let .entryStack(offset, size, _): return "stack+\(offset)/\(size)"
        case let .composite(pieces): return pieces.map { render($0.register) }.joined(separator: ",")
        case let .indirect(pointer, _, _):
            switch pointer {
            case let .gpr(index): return "x\(index)"
            case let .entryStack(offset): return "stack+\(offset)/8"
            }
        case let .unbound(reason): return "unbound(\(reason))"
        }
    }

    static func validate(_ location: DarwinARM64RichParameterLocation, info: ABICallOracleFile.TypeInfo,
                         expected: [ABICallOracleFile.Location]) -> Bool {
        switch location {
        case let .composite(pieces):
            guard pieces.map(\.size) == expected.compactMap(\.size) else { return false }
            var cursor = 0
            for piece in pieces {
                guard piece.valueByteOffset == cursor, piece.size > 0 else { return false }
                cursor += piece.size
            }
            return cursor == info.size
        case let .indirect(_, size, alignment): return size == info.size && alignment == info.align
        case let .entryStack(_, size, alignment):
            let expectedAlignment = info.kind == "aggregate" ? 8 : info.align
            return size == expected.first?.size && alignment == expectedAlignment
        case .gpr, .simd: return expected.count == 1 && expected[0].size == info.size
        case .unbound: return false
        }
    }

    struct ReturnOutcome {
        let id: String
        let status: Status
        let detail: String
    }

    static func runReturn(_ key: String, file: ABICallOracleFile, resolver: TypeAtlasDarwinARM64LayoutResolver) -> ReturnOutcome {
        let id = "RETURN:" + key
        guard let info = file.types[key], let probe = file.returnProbes[key], probe.matched else {
            return ReturnOutcome(id: id, status: .harness, detail: "Missing or uncorroborated fixture")
        }
        let expected = probe.locations.map(\.rendered).joined(separator: ",")
        let result = DarwinARM64ParameterBinder.returnLocation(for: info.c, resolver: resolver)
        let actual: String
        let shapeOK: Bool
        switch result {
        case .void: actual = "void"; shapeOK = probe.locations.isEmpty
        case let .single(register): actual = render(register); shapeOK = probe.locations.count == 1 && probe.locations[0].size == info.size
        case let .composite(pieces):
            actual = pieces.map { render($0.register) }.joined(separator: ",")
            shapeOK = validate(.composite(pieces: pieces), info: info, expected: probe.locations)
        case let .indirect(index, size, alignment):
            actual = "x\(index)(indirect result)"
            shapeOK = size == info.size && alignment == info.align
        case .unbound: return ReturnOutcome(id: id, status: .unsupported, detail: "Unbound \(info.c)")
        }
        let pass = actual == expected && shapeOK
        return ReturnOutcome(id: id, status: pass ? .pass : .fail, detail: pass ? actual : "expected \(expected); actual \(actual); shapeOK=\(shapeOK)")
    }

    static func run(_ call: ABICallOracleFile.Call, types: [String: ABICallOracleFile.TypeInfo],
                    resolver: TypeAtlasDarwinARM64LayoutResolver = .init(), useRich: Bool = true) -> Outcome {
        let tags = categories(of: call, types: types)
        func harness(_ reason: String) -> Outcome {
            Outcome(call: call, status: .harness, categories: tags, placementsCompared: 0, placementsMatched: 0,
                    unsupportedFormals: [], anonymousActuals: 0, diffs: [reason])
        }
        guard call.fixedCount <= call.types.count, call.parameters.count == call.types.count else {
            return harness("fixed_count \(call.fixedCount) / parameters \(call.parameters.count) / types \(call.types.count) disagree")
        }
        let named = Array(call.parameters.prefix(call.fixedCount))
        guard named.allSatisfy({ !$0.anonymous }),
              call.parameters.dropFirst(call.fixedCount).allSatisfy(\.anonymous) else {
            return harness("anonymous flags disagree with fixed_count")
        }
        var spellings: [String] = []
        for parameter in named {
            guard let info = types[parameter.type] else { return harness("unknown oracle type \(parameter.type)") }
            spellings.append(info.c)
        }

        let bound: [DarwinARM64RichParameterLocation]
        if useRich {
            bound = DarwinARM64ParameterBinder.bindRich(parameterTypes: spellings, isVariadic: call.variadic, resolver: resolver)
        } else {
            bound = DarwinARM64ParameterBinder.bind(parameterTypes: spellings, isVariadic: call.variadic).map { location in
                switch location {
                case let .gpr(index, width): .gpr(index: index, carrierWidth: width)
                case let .simd(index, width): .simd(index: index, registerWidth: width)
                case let .entryStack(offset, size, alignment): .entryStack(byteOffset: offset, size: size, alignment: alignment)
                case let .unbound(reason): .unbound(reason: reason)
                }
            }
        }
        guard bound.count == named.count else {
            return harness("binder returned \(bound.count) locations for \(named.count) formals")
        }

        var compared = 0
        var matched = 0
        var unsupported: [String] = []
        var diffs: [String] = []
        var sawDocumentedLimit = false
        for (parameter, location) in zip(named, bound) {
            let expected = parameter.locations.map(\.rendered).joined(separator: ",")
            if case let .unbound(reason) = location {
                switch reason {
                case .unsupportedType where isDocumentedLimit(parameter.type, types: types):
                    sawDocumentedLimit = true
                    unsupported.append("p\(parameter.index):\(parameter.type)")
                    continue
                case .dependentOnUnsupportedEarlierParameter where sawDocumentedLimit:
                    unsupported.append("p\(parameter.index):\(parameter.type)(dependent)")
                    continue
                default:
                    compared += 1
                    diffs.append("p\(parameter.index) \(parameter.type): expected \(expected), binder \(render(location))")
                    continue
                }
            }
            compared += 1
            let actual = render(location)
            let indirect: Bool
            if case .indirect = location { indirect = true } else { indirect = false }
            let shapeOK = validate(location, info: types[parameter.type]!, expected: parameter.locations)
            if actual == expected && indirect == parameter.indirect && shapeOK {
                matched += 1
            } else {
                diffs.append("p\(parameter.index) \(parameter.type): expected \(expected), binder \(actual), indirect=\(indirect), shapeOK=\(shapeOK)")
            }
        }

        let status: Status = !diffs.isEmpty ? .fail : (unsupported.isEmpty ? .pass : .unsupported)
        return Outcome(call: call, status: status, categories: tags, placementsCompared: compared,
                       placementsMatched: matched, unsupportedFormals: unsupported,
                       anonymousActuals: call.types.count - call.fixedCount, diffs: diffs)
    }
}

// MARK: - Report

struct ABICallOracleReport {
    let outcomes: [ABICallOracleRunner.Outcome]
    let returns: [ABICallOracleRunner.ReturnOutcome]
    let file: ABICallOracleFile

    private typealias Status = ABICallOracleRunner.Status
    private static let columns: [Status] = [.pass, .fail, .unsupported, .harness]

    private func counts(_ subset: [ABICallOracleRunner.Outcome]) -> [Status: Int] {
        Dictionary(grouping: subset, by: \.status).mapValues(\.count)
    }

    var summaryLine: String {
        let totals = counts(outcomes)
        return Self.columns.map { "\($0.rawValue) \(totals[$0] ?? 0)" }.joined(separator: " · ")
            + " · RETURN PASS \(returns.filter { $0.status == .pass }.count)/\(file.returnProbes.count)"
    }

    private static func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }

    private func statusRow(_ label: String, _ subset: [ABICallOracleRunner.Outcome]) -> String {
        let c = counts(subset)
        let compared = subset.reduce(0) { $0 + $1.placementsCompared }
        let matched = subset.reduce(0) { $0 + $1.placementsMatched }
        return Self.row([label, "\(subset.count)"] + Self.columns.map { "\(c[$0] ?? 0)" } + ["\(matched)/\(compared)"])
    }

    func markdown() -> String {
        var lines: [String] = []
        lines.append("# Darwin arm64 call-binding oracle vs DarwinARM64ParameterBinder")
        lines.append("")
        lines.append("Oracle: schema \(file.schema), \(file.calls.count) call signatures, \(file.returnProbes.count) return probes.")
        lines.append("Summary: \(summaryLine).")
        lines.append("")
        lines.append("- PASS: every named formal's placement matches the oracle.")
        lines.append("- FAIL: any placement differs, or the binder abstains outside its documented limit.")
        lines.append("- UNSUPPORTED: the binder abstains on an aggregate, HFA/HVA, short vector or `__int128` (or a later formal that depends on one). Formals bound before the abstention are still compared.")
        lines.append("- Return probes use the binder-only return API; x8 is caller-provided result storage.")
        lines.append("- Placements column: matched/compared named-formal placements (abstentions are not compared).")
        let anonymous = outcomes.reduce(0) { $0 + $1.anonymousActuals }
        lines.append("- Anonymous variadic actuals not fed to the formal-only binder: \(anonymous).")
        lines.append("")

        let header = Self.row(["Group", "Cases"] + Self.columns.map(\.rawValue) + ["Placements"])
        let rule = Self.row(["---", "---:"] + Self.columns.map { _ in "---:" } + ["---:"])

        lines.append("## By category (a case may carry several)")
        lines.append("")
        lines.append(header)
        lines.append(rule)
        for category in ABICallOracleRunner.categoryOrder {
            lines.append(statusRow(category, outcomes.filter { $0.categories.contains(category) }))
        }
        lines.append(statusRow("**all**", outcomes))
        lines.append("")

        lines.append("## By oracle family")
        lines.append("")
        lines.append(header)
        lines.append(rule)
        for family in Set(outcomes.map(\.call.family)).sorted() {
            lines.append(statusRow(family, outcomes.filter { $0.call.family == family }))
        }
        lines.append("")

        lines.append("## Return probes")
        lines.append("")
        lines.append(Self.row(["ID", "Status", "Detail"]))
        lines.append(Self.row(["---", "---", "---"]))
        for result in returns { lines.append(Self.row([result.id, result.status.rawValue, result.detail])) }
        lines.append("")

        lines.append("## UNSUPPORTED by first abstaining type")
        lines.append("")
        var firstType: [String: Int] = [:]
        for outcome in outcomes where outcome.status == .unsupported {
            let first = outcome.unsupportedFormals.first.map { String($0.split(separator: ":").last ?? "") } ?? "?"
            firstType[first, default: 0] += 1
        }
        lines.append(Self.row(["Type", "Cases"]))
        lines.append(Self.row(["---", "---:"]))
        for (type, count) in firstType.sorted(by: { $0.key < $1.key }) {
            lines.append(Self.row(["`\(type)`", "\(count)"]))
        }
        lines.append("")

        lines.append("## FAIL cases")
        lines.append("")
        let failures = outcomes.filter { $0.status == .fail || $0.status == .harness }
        if failures.isEmpty {
            lines.append("None.")
        } else {
            for outcome in failures {
                lines.append("- \(outcome.call.id) [\(outcome.call.family)] `\(outcome.call.signature)`: \(outcome.status.rawValue)")
                for diff in outcome.diffs { lines.append("  - \(diff)") }
            }
        }
        lines.append("")

        lines.append("## Return compiler corroboration")
        lines.append("")
        lines.append(Self.row(["Type", "Oracle carriers", "Oracle matched"]))
        lines.append(Self.row(["---", "---", "---"]))
        for (type, probe) in file.returnProbes.sorted(by: { $0.key < $1.key }) {
            lines.append(Self.row(["`\(type)`", probe.locations.map(\.rendered).joined(separator: ", "), probe.matched ? "yes" : "no"]))
        }
        lines.append("")

        lines.append("## Every case")
        lines.append("")
        lines.append(Self.row(["Case", "Family", "Status", "Placements", "Abstained", "Signature"]))
        lines.append(Self.row(["---", "---", "---", "---:", "---", "---"]))
        for outcome in outcomes {
            lines.append(Self.row([
                outcome.call.id, outcome.call.family, outcome.status.rawValue,
                "\(outcome.placementsMatched)/\(outcome.placementsCompared)",
                outcome.unsupportedFormals.joined(separator: " "),
                "`\(outcome.call.signature)`",
            ]))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
