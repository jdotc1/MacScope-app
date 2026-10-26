import Foundation
import XCTest
@testable import MacScope

final class SwiftRuntimeConventionSeedsTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SwiftConvention/" + name)
    }

    func testGeneratedTableMatchesRetainedDeclarationsAndRoles() throws {
        let data = try Data(contentsOf: fixture("swift_runtime_seeds.json"))
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let source = try XCTUnwrap(doc["source"] as? [String: String])
        XCTAssertEqual(source["tag"], SwiftRuntimeConventionSeeds.sourceTag)
        XCTAssertEqual(source["sha256"], SwiftRuntimeConventionSeeds.sourceSHA256)
        let rows = try XCTUnwrap(doc["entries"] as? [[String: Any]])
        let seeds = SwiftRuntimeConventionSeeds.all
        XCTAssertEqual(rows.count, 81)
        XCTAssertEqual(seeds.count, rows.count)
        XCTAssertEqual(Set(seeds.map(\.name)).count, seeds.count)
        for (row, seed) in zip(rows, seeds) {
            let roles = try XCTUnwrap(row["roles"] as? [String: Any])
            XCTAssertEqual(seed.name, row["name"] as? String)
            XCTAssertEqual(seed.cc, row["cc"] as? String)
            XCTAssertEqual(seed.returns, row["returns"] as? [String])
            XCTAssertEqual(seed.args, row["args"] as? [String])
            XCTAssertEqual(seed.positionalArgs, roles["positionalArgs"] as? [String])
            XCTAssertEqual(seed.returnShape, roles["returnShape"] as? String)
            XCTAssertEqual(seed.contextIn, roles["contextIn"] as? [String])
            XCTAssertEqual(seed.errorOut, roles["errorOut"] as? String)
            XCTAssertEqual(seed.asyncContextIn, roles["asyncContextIn"] as? String)
            XCTAssertEqual(seed.indirectResult, roles["indirectResult"] as? String)
            XCTAssertEqual(seed.note, roles["note"] as? String)
            XCTAssertEqual(seed.convention.rawValue, roles["convention"] as? String)
            var evidence = SwiftBoundaryEvidence()
            evidence.runtimeHelper = seed.helperFacts
            let decision = SwiftConventionAdapter.decide(evidence)
            XCTAssertEqual(decision.convention, seed.convention)
            XCTAssertEqual(decision.contextIn, seed.contextIn)
            XCTAssertEqual(decision.errorOut, seed.errorOut)
            XCTAssertEqual(decision.asyncContextIn, seed.cc == "SwiftAsyncCC" ? (seed.asyncContextIn ?? "x22") : seed.asyncContextIn)
        }
    }

    func testSeedNamesConventionsAndTypesMatchRuntimeDefinitionExtract() throws {
        // Retained line-numbered declarations from swift-6.3-RELEASE RuntimeFunctions.def.
        // This checks offline declaration agreement, not freshness of the upstream source.
        let text = try String(contentsOf: fixture("RuntimeFunctions.non-c.txt"), encoding: .utf8)
        let pattern = #"^\s*\d+\s+([A-Za-z_]\w*)\s+(SwiftCC|SwiftAsyncCC)\s+RETURNS\(([^)]*)\)\s+ARGS\(([^)]*)\)$"#
        let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var names = Set<String>()
        // Multi-line declarations were flattened with their trailing comments; drop each
        // comment up to the next IR type name, as the generator strips them before parsing.
        func types(_ value: String) -> [String] {
            value.replacingOccurrences(of: #"//.*?(?=\b\w+Ty\b|$)"#, with: "", options: .regularExpression)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        for match in matches {
            let name = ns.substring(with: match.range(at: 1))
            XCTAssertTrue(names.insert(name).inserted, name)
            let seed = try XCTUnwrap(SwiftRuntimeConventionSeeds.seed(named: name), name)
            XCTAssertEqual(seed.cc, ns.substring(with: match.range(at: 2)), name)
            let returns = types(ns.substring(with: match.range(at: 3)))
            XCTAssertEqual(seed.returns, returns == ["VoidTy"] ? [] : returns, name)
            XCTAssertEqual(seed.args, types(ns.substring(with: match.range(at: 4))), name)
        }
        XCTAssertEqual(names, Set(SwiftRuntimeConventionSeeds.all.map(\.name)))
    }

    func testSpecialRolesRemainSeparateFromOrdinaryCatalog() throws {
        let box = try XCTUnwrap(SwiftRuntimeConventionSeeds.seed(named: "swift_allocBox"))
        XCTAssertEqual(box.returnShape, "pair(x0,x1)")
        let throwing = try XCTUnwrap(SwiftRuntimeConventionSeeds.seed(named: "swift_willThrow"))
        XCTAssertEqual(throwing.contextIn, ["x20"])
        XCTAssertEqual(throwing.errorOut, "x21")
        XCTAssertEqual(throwing.positionalArgs, [])
        for seed in SwiftRuntimeConventionSeeds.all {
            XCTAssertTrue(["SwiftCC", "SwiftAsyncCC"].contains(seed.cc))
            if seed.cc == "SwiftAsyncCC", !seed.args.isEmpty { XCTAssertEqual(seed.asyncContextIn, "x22", seed.name) }
        }
        XCTAssertNil(SwiftRuntimeConventionSeeds.seed(named: "swift_retainDirect"))
        XCTAssertNil(SwiftRuntimeConventionSeeds.seed(named: "swift_releaseDirect"))
        XCTAssertNil(SwiftRuntimeConventionSeeds.seed(named: "swift_retain"))
    }
}
