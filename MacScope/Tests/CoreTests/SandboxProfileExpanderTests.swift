import Foundation
import XCTest
@testable import MacScope

final class SandboxProfileExpanderTests: XCTestCase {
    func testReaderRoundTripAndLocations() throws {
        let source = "; introductory comment\n(allow mach-lookup (global-name \"a\\\"b\"))\n(deny file-read*)"
        let first = try SandboxProfileExpander.parse(source)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0].location, .init(line: 2, column: 1))
        XCTAssertEqual(first[1].location, .init(line: 3, column: 1))
        let canonical = first.map(\.rendered).joined(separator: "\n")
        XCTAssertEqual(try SandboxProfileExpander.parse(canonical).map(\.rendered), first.map(\.rendered))
    }

    func testNestedMacroAndSimpleValueExpansion() throws {
        let profile = """
        (define service "com.example.helper")
        (define (lookup name) (allow mach-lookup (global-name name)))
        (define (network) (allow network-outbound) (lookup service))
        (network)
        """
        let report = try SandboxProfileExpander.expand(profile: profile, entitlements: [])
        XCTAssertEqual(report.effectiveRules.map(\.operation), ["network-outbound", "mach-lookup"])
        XCTAssertEqual(report.grantedNamedMachServices, ["com.example.helper"])
        XCTAssertEqual(report.effectiveRules[1].arguments, ["(global-name \"com.example.helper\")"])
        XCTAssertTrue(report.unresolvedMacros.isEmpty)
    }

    func testEntitlementGateUnlocksOnlySuppliedRules() throws {
        let profile = """
        (define (network-client)
          (allow system-network)
          (allow network-outbound)
          (allow mach-lookup (global-name "com.example.network")))
        (when (entitlement "com.apple.security.network.client") (network-client))
        """
        let without = try SandboxProfileExpander.expand(profile: profile, entitlements: [])
        XCTAssertTrue(without.effectiveRules.isEmpty)
        let with = try SandboxProfileExpander.expand(
            profile: profile, entitlements: ["com.apple.security.network.client"])
        XCTAssertEqual(with.effectiveRules.count, 3)
        XCTAssertEqual(with.grantedNamedMachServices, ["com.example.network"])
        XCTAssertEqual(with.entitlementRules["com.apple.security.network.client"], with.effectiveRules)
        let encoded = try JSONEncoder().encode(with)
        XCTAssertEqual(try JSONDecoder().decode(SandboxProfileExpander.Report.self, from: encoded), with)
    }

    func testUnresolvedImportMacroAndCycleAreReported() throws {
        let profile = """
        (import "missing.sb")
        (import "shared.sb")
        (define (a) (b))
        (define (b) (a))
        (unknown-rule-set)
        (a)
        """
        let report = try SandboxProfileExpander.expand(
            profile: profile, imports: ["shared.sb": "(allow file-read* (subpath \"/tmp\"))"], entitlements: [])
        XCTAssertEqual(report.unresolvedImports, ["missing.sb"])
        XCTAssertEqual(report.unresolvedMacros, ["unknown-rule-set"])
        XCTAssertEqual(report.effectiveRules.map(\.operation), ["file-read*"])
        XCTAssertEqual(report.effectiveRules[0].arguments, ["(subpath \"/tmp\")"])
        XCTAssertFalse(report.expansionCycles.isEmpty)
    }

    func testDuplicateDeclarationCombinesEntitlementProvenance() throws {
        let profile = """
        (when (entitlement "one") (allow mach-lookup (global-name "com.example.shared")))
        (when (entitlement "two") (allow mach-lookup (global-name "com.example.shared")))
        """
        let report = try SandboxProfileExpander.expand(profile: profile, entitlements: ["one", "two"])
        XCTAssertEqual(report.effectiveRules.count, 1)
        XCTAssertEqual(report.effectiveRules[0].unlockedBy, ["one", "two"])
        XCTAssertEqual(report.entitlementRules["one"], report.effectiveRules)
        XCTAssertEqual(report.entitlementRules["two"], report.effectiveRules)
    }

    func testSimpleDefinitionCanHoldARuleForm() throws {
        let report = try SandboxProfileExpander.expand(
            profile: "(define shared (allow file-read* (literal \"/tmp/example\"))) (shared)",
            entitlements: [])
        XCTAssertEqual(report.effectiveRules.map(\.operation), ["file-read*"])
        XCTAssertTrue(report.unresolvedMacros.isEmpty)
    }

    func testRegexLiteralRoundTripsAndMixedFiltersRemainVerbatim() throws {
        let single = "(allow file-read* (regex #\"^/private/tmp/\"))"
        let parsed = try SandboxProfileExpander.parse(single)
        XCTAssertEqual(parsed.map(\.rendered), [single])
        XCTAssertEqual(try SandboxProfileExpander.parse(parsed[0].rendered).map(\.rendered), [single])

        let mixed = "(allow file-read* (regex #\"^/private/tmp/\") (subpath \"/tmp\"))"
        let report = try SandboxProfileExpander.expand(profile: mixed, entitlements: [])
        XCTAssertEqual(report.effectiveRules.count, 1)
        XCTAssertEqual(report.effectiveRules[0].arguments,
                       ["(regex #\"^/private/tmp/\")", "(subpath \"/tmp\")"])
    }

    func testValueFanOutStopsAtGlobalExpansionBudget() throws {
        var forms = ["(define v40 \"x\")"]
        for level in stride(from: 39, through: 0, by: -1) {
            forms.append("(define v\(level) (v\(level + 1) v\(level + 1)))")
        }
        forms.append("(define (m) (allow file-read* v0))")
        forms.append("(m)")

        let started = Date()
        let report = try SandboxProfileExpander.expand(profile: forms.joined(separator: "\n"), entitlements: [])
        XCTAssertTrue(report.effectiveRules.isEmpty)
        XCTAssertTrue(report.expansionCycles.contains("expansion limit"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }

    func testMacroFanOutStopsAtGlobalExpansionBudget() throws {
        var forms: [String] = []
        for level in 0..<40 {
            forms.append("(define (m\(level)) (m\(level + 1)) (m\(level + 1)))")
        }
        forms.append("(define (m40) (begin))")
        forms.append("(m0)")

        let started = Date()
        let report = try SandboxProfileExpander.expand(profile: forms.joined(separator: "\n"), entitlements: [])
        XCTAssertTrue(report.effectiveRules.isEmpty)
        XCTAssertTrue(report.expansionCycles.contains("expansion limit"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }
}
