import Foundation
import XCTest
@testable import MacScope

final class EntitlementRiskTests: XCTestCase {
    private var fixtureDirectory: URL {
        TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures/entitlement-risk")
    }

    private func report(_ name: String, expectsSandbox: Bool = false) throws -> EntitlementRiskReport {
        let bytes = try Data(contentsOf: fixtureDirectory.appendingPathComponent(name))
        let file = try MachOParser().parse(bytes)
        return EntitlementRiskAnalyzer.analyze(file: file, selectedSliceBytes: bytes,
                                               expectsAppSandbox: expectsSandbox)
    }

    func testHardenedRuntimeOffSuppressesExceptionPile() throws {
        let result = try report("runtime-off")
        XCTAssertEqual(result.signature.hardenedRuntime, false)
        XCTAssertEqual(result.entitlements.values["com.apple.security.cs.disable-library-validation"], .boolean(true))
        XCTAssertEqual(result.findings.map(\.ruleID), ["signature.no-hardened-runtime"])
    }

    func testLibraryValidationAlone() throws {
        let result = try report("library-validation")
        XCTAssertEqual(result.signature.hardenedRuntime, true)
        XCTAssertEqual(result.findings.map(\.ruleID), ["entitlement.com.apple.security.cs.disable-library-validation"])
        XCTAssertEqual(result.findings.first?.severity, .medium)
    }

    func testLibraryValidationAndDyldElevatedCombination() throws {
        let result = try report("library-and-dyld")
        XCTAssertEqual(result.findings.map(\.ruleID), ["runtime.library-validation-plus-dyld"])
        XCTAssertEqual(result.findings.first?.severity, .high)
    }

    func testJITIsNarrower() throws {
        let result = try report("jit-only")
        XCTAssertEqual(result.findings.map(\.ruleID), ["entitlement.com.apple.security.cs.allow-jit"])
        XCTAssertEqual(result.findings.first?.severity, .low)
    }

    func testAdHocTaskAllowIsDevelopmentFinding() throws {
        let result = try report("task-allow")
        XCTAssertEqual(result.signature.adHoc, true)
        XCTAssertEqual(result.findings.map(\.ruleID), ["debug.get-task-allow-development"])
    }

    func testSandboxExceptionPreservesArray() throws {
        let result = try report("sandbox-exception", expectsSandbox: true)
        XCTAssertEqual(result.signature.sandboxDeclaration, "true")
        XCTAssertEqual(result.findings.map(\.ruleID), ["sandbox.temporary-exception"])
        XCTAssertEqual(result.entitlements.values["com.apple.security.temporary-exception.files.absolute-path.read-only"],
                       .array([.string("/tmp/fixture-read-only")]))
    }

    func testCleanHardenedBinaryHasNoFindings() throws {
        let result = try report("clean-runtime")
        XCTAssertEqual(result.signature.hardenedRuntime, true)
        XCTAssertEqual(result.entitlements.state, .absent)
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testTeamSignedReleaseTaskAllowRequiresReview() {
        let directory = MachOCodeDirectorySummary(
            version: 0x20200, flags: 0x0001_0000, hashOffset: 0, identifierOffset: 0,
            specialSlotCount: 0, codeSlotCount: 0, codeLimit: 0, hashSize: 32, hashType: 2,
            platform: 0, pageSize: 12, identifier: "fixture", teamIdentifier: "TESTTEAM")
        let declared = DeclaredEntitlements(state: .parsed, format: "XML",
                                            values: ["com.apple.security.get-task-allow": .boolean(true)], reason: nil)
        let result = EntitlementRiskAnalyzer.evaluate(codeDirectory: directory,
                                                       entitlements: declared, buildIntent: .release)
        XCTAssertEqual(result.findings.map(\.ruleID), ["debug.get-task-allow-release"])
        XCTAssertEqual(result.findings.first?.confidence, .needsReview)
    }

    func testFalseValueAndUnknownKeyAreNotScored() {
        let directory = MachOCodeDirectorySummary(
            version: 0x20200, flags: 0x0001_0000, hashOffset: 0, identifierOffset: 0,
            specialSlotCount: 0, codeSlotCount: 0, codeLimit: 0, hashSize: 32, hashType: 2,
            platform: 0, pageSize: 12, identifier: "fixture", teamIdentifier: nil)
        let declared = DeclaredEntitlements(state: .parsed, format: "XML",
                                            values: ["com.apple.security.cs.allow-jit": .boolean(false),
                                                     "example.unknown": .string("value")], reason: nil)
        let result = EntitlementRiskAnalyzer.evaluate(codeDirectory: directory, entitlements: declared)
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.unknownKeys, ["example.unknown"])
    }
}
