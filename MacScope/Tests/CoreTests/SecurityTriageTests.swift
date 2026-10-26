import Foundation
import XCTest
@testable import MacScope

@MainActor
final class SecurityTriageFixtureTests: XCTestCase {
    private static let fixtureDirectory = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("GoldenFixtures/security-triage-v1", isDirectory: true)

    func testReportRoundTripsWithCanonicalEvidence() throws {
        let finding = SecurityTriageFinding(
            rule: .r3NonconstantFormat,
            confidence: .needsReview,
            evidenceAddresses: [0x20, 0x10, 0x20],
            reason: "format provenance crosses a join"
        )
        let mitigation = SecurityTriageMitigation(
            rule: .r1UnboundedCopy,
            evidenceAddresses: [0x30],
            reason: "FORTIFY checked copy"
        )
        let report = SecurityTriageReport(functions: [
            SecurityTriageFunctionReport(
                functionName: "fixture",
                functionStartAddress: 0x10,
                findings: [finding],
                mitigations: [mitigation]
            )
        ])
        XCTAssertEqual(try JSONDecoder().decode(
            SecurityTriageReport.self,
            from: JSONEncoder().encode(report)
        ), report)
        XCTAssertEqual(report.functions[0].findings[0].evidenceAddresses, [0x10, 0x20])
    }

    func testR1ThroughR4FixturesAtO1AndO2() throws {
        for optimization in ["O1", "O2"] {
            let reports = try analyzeFixture(named: "security-c-arm64-\(optimization)")
            for rule in [SecurityTriageRule.r1UnboundedCopy, .r2AllocationSizeOverflow,
                         .r3NonconstantFormat, .r4UncheckedAllocation] {
                let prefix = "sec1_\(rule.rawValue.lowercased())_"
                let positives = reports.filter { $0.key.hasPrefix(prefix + "positive_") }
                let safe = reports.filter { $0.key.hasPrefix(prefix + "safe_") }
                XCTAssertEqual(positives.count, 3, "\(optimization) \(rule.rawValue) positive fixture discovery")
                XCTAssertEqual(safe.count, 3, "\(optimization) \(rule.rawValue) safe fixture discovery")
                for (name, report) in positives {
                    XCTAssertTrue(report.findings.contains { $0.rule == rule },
                                  "\(optimization) \(name) must emit \(rule.rawValue): \(report.findings)")
                }
                for (name, report) in safe {
                    XCTAssertFalse(report.findings.contains { $0.rule == rule },
                                   "\(optimization) \(name) must not emit \(rule.rawValue): \(report.findings)")
                }
            }
        }
    }

    func testR5ObjectiveCListenerFixturesAtO1AndO2() throws {
        for optimization in ["O1", "O2"] {
            let reports = try analyzeFixture(named: "security-objc-arm64-\(optimization)")
            let riskyOwners = ["SEC1PIDListener", "SEC1UnconditionalListener"]
            let safeOwners = ["SEC1AuditTokenListener", "SEC1CodeSigningListener"]
            for owner in riskyOwners {
                let report = try XCTUnwrap(reports.values.first {
                    $0.functionName.contains(owner) && $0.functionName.contains("shouldAcceptNewConnection")
                }, "\(optimization) \(owner)")
                XCTAssertTrue(report.findings.contains { $0.rule == .r5XPCPeerTrust },
                              "\(optimization) \(owner) must emit R5")
            }
            for owner in safeOwners {
                let report = try XCTUnwrap(reports.values.first {
                    $0.functionName.contains(owner) && $0.functionName.contains("shouldAcceptNewConnection")
                }, "\(optimization) \(owner)")
                XCTAssertFalse(report.findings.contains { $0.rule == .r5XPCPeerTrust },
                               "\(optimization) \(owner) must not emit R5")
            }
        }
    }

    func testLibjpegSecurityTriageWitness() throws {
        let environment = ProcessInfo.processInfo.environment
        // Invoke through xcodebuild with TEST_RUNNER_ prefixed transport variables; the test
        // host strips that prefix before exposing these opt-in keys through ProcessInfo.
        guard environment["MACSCOPE_SEC1_LIBJPEG_WITNESS"] == "1" else { return }
        let inputPath = "/opt/homebrew/lib/libjpeg.8.dylib"
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputPath), "libjpeg witness input is absent")
        let destinationPath = try XCTUnwrap(environment["MACSCOPE_SEC1_OUT"])
        XCTAssertFalse(destinationPath.isEmpty, "MACSCOPE_SEC1_OUT must name a fresh receipt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationPath),
                       "witness receipt already exists; do not repeat unchanged input")

        let snapshot = try AnalysisEngine().analyze(url: URL(fileURLWithPath: inputPath))
        let slot = snapshot.primarySlot
        let analysis = try XCTUnwrap(snapshot.analysis(in: slot))
        var functions: [MacIRFunction] = []
        let indirectReport = snapshot.imageWideIndirectCalls(
            in: slot,
            compute: true,
            inspectFunctions: { functions = $0 }
        )
        XCTAssertNotNil(indirectReport, "complete image-wide MacIR construction is required")
        XCTAssertEqual(analysis.functions.count, 914)
        XCTAssertEqual(functions.count, 914)

        let readOnlyRanges: [Range<UInt64>] = analysis.sections.compactMap { section in
            guard section.name.hasPrefix("__TEXT,"), !section.isZeroFill,
                  section.size > 0 else { return nil }
            let end = section.address.addingReportingOverflow(section.size)
            return end.overflow ? nil : section.address..<end.partialValue
        }
        let report = SecurityTriageService.report(
            functions: functions,
            context: SecurityTriageContext(readOnlyAddressRanges: readOnlyRanges)
        )
        var findingCounts: [String: Int] = [:]
        var mitigationCounts: [String: Int] = [:]
        for function in report.functions {
            for finding in function.findings {
                findingCounts["\(finding.rule.rawValue).\(finding.confidence.rawValue)", default: 0] += 1
            }
            for mitigation in function.mitigations {
                mitigationCounts[mitigation.rule.rawValue, default: 0] += 1
            }
        }
        let receipt = SecurityTriageWitnessReceipt(
            functionCount: functions.count,
            findingCounts: findingCounts,
            mitigationCounts: mitigationCounts,
            report: report
        )
        let data = try JSONEncoder.securityTriageWitness.encode(receipt)
        try data.write(to: URL(fileURLWithPath: destinationPath), options: .atomic)
        print("SEC1 witness functions=\(functions.count) findings=\(findingCounts) mitigations=\(mitigationCounts)")
    }

    private func analyzeFixture(named name: String) throws -> [String: SecurityTriageFunctionReport] {
        let url = Self.fixtureDirectory.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing fixture \(name)")
        let snapshot = try AnalysisEngine().analyze(url: url)
        let slot = snapshot.primarySlot
        let analysis = try XCTUnwrap(snapshot.analysis(in: slot))
        let identities = objectiveCIdentities(in: analysis)
        var reports: [String: SecurityTriageFunctionReport] = [:]
        for summary in analysis.functions where summary.name.contains("sec1_")
            || summary.name.contains("SEC1") {
            let input = try XCTUnwrap(snapshot.pseudocodeRenderInput(exactFunctionID: summary.id, in: slot))
            let target = try XCTUnwrap(snapshot.pseudocodeTarget(
                selectedAddress: summary.startAddress,
                in: slot
            ))
            XCTAssertEqual(target.function.id, summary.id)
            let function = PseudocodePrinter().buildFunction(
                functionName: input.functionName,
                startAddress: input.startAddress,
                jumpTables: input.jumpTables,
                objcSelectors: input.objcSelectors,
                constantStrings: input.constantStrings,
                signatureOverrides: input.signatureOverrides,
                authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
                callerReturnWidth: input.callerReturnWidth,
                types: input.types,
                instructions: target.instructions
            )
            let destinationObjectRanges: [Range<UInt64>] = analysis.sections.compactMap { section in
                guard section.name == "__DATA,__sec1_buf", section.size > 0 else { return nil }
                let end = section.address.addingReportingOverflow(section.size)
                return end.overflow ? nil : section.address..<end.partialValue
            }
            let context = SecurityTriageContext(
                constantStrings: input.constantStrings,
                readOnlyAddressRanges: analysis.sections.compactMap { section in
                    guard section.name.hasPrefix("__TEXT,"), !section.isZeroFill,
                          section.size > 0 else { return nil }
                    let end = section.address.addingReportingOverflow(section.size)
                    return end.overflow ? nil : section.address..<end.partialValue
                },
                destinationObjectRanges: destinationObjectRanges,
                objectiveCMethodsByImplementation: identities
            )
            let report = SecurityTriageService.analyze(
                function: function,
                context: context
            )
            if summary.name.contains("sec1_r1_safe_constant")
                || summary.name.contains("sec1_r1_safe_guard"),
               report.findings.contains(where: {
                   $0.rule == SecurityTriageRule.r1UnboundedCopy
               }) {
                let ir = function.instructions.map {
                    "0x\(String($0.source.address, radix: 16)): \(String(reflecting: $0.operation))"
                }.joined(separator: " | ")
                XCTFail("R1 safe diagnostic ranges=\(destinationObjectRanges) IR=\(ir)")
            }
            reports[normalize(summary.name)] = report
        }
        return reports
    }

    private func objectiveCIdentities(
        in analysis: ImageAnalysis
    ) -> [UInt64: [SecurityTriageObjectiveCMethodIdentity]] {
        var result: [UInt64: [SecurityTriageObjectiveCMethodIdentity]] = [:]
        for cls in analysis.objcClasses {
            for method in cls.classMethods + cls.instanceMethods {
                guard let address = method.implementation else { continue }
                result[address, default: []].append(.init(
                    ownerName: cls.name,
                    selector: method.selector,
                    isClassMethod: method.isClassMethod
                ))
            }
        }
        for category in analysis.objcCategories {
            for method in category.classMethods + category.instanceMethods {
                guard let address = method.implementation else { continue }
                result[address, default: []].append(.init(
                    ownerName: "\(category.className)(\(category.name))",
                    selector: method.selector,
                    isClassMethod: method.isClassMethod
                ))
            }
        }
        return result
    }

    private func normalize(_ name: String) -> String {
        name.hasPrefix("_") ? String(name.dropFirst()) : name
    }
}

private struct SecurityTriageWitnessReceipt: Codable {
    var functionCount: Int
    var findingCounts: [String: Int]
    var mitigationCounts: [String: Int]
    var report: SecurityTriageReport
}

private extension JSONEncoder {
    static var securityTriageWitness: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
