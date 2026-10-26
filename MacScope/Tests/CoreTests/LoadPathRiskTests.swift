import XCTest
@testable import MacScope

final class LoadPathRiskTests: XCTestCase {
    private var fixtureDirectory: URL {
        TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures/load-path-risk")
    }

    func testOrdinaryFixtureReportsExactDeclarationsWithoutOutsideProbe() throws {
        let report = try assess("ordinary")
        let main = try XCTUnwrap(report.images.first { $0.role == .mainExecutable })
        let framework = try XCTUnwrap(report.images.first { $0.role == .framework })
        XCTAssertEqual(main.findings.map(\.ruleID).sorted(), ["L1", "L2", "L3", "L4", "L5"])
        XCTAssertEqual(framework.findings.map(\.ruleID).sorted(), ["L4", "L6", "L7"])
        XCTAssertEqual(main.resolution.filter { $0.dependency.rawString.contains("Found.framework") }.map(\.location),
                       [.elsewhere, .bundle, .unresolved])
        XCTAssertEqual(main.resolution.filter { $0.dependency.rawString.contains("Found.framework") }.map(\.existence),
                       [.notChecked, .present, .notChecked])
        XCTAssertTrue(main.findings.contains { $0.ruleID == "L2" && $0.commands.count == 2 })
        XCTAssertTrue(main.findings.contains { $0.ruleID == "L5" && $0.commands.first?.rawString.contains("DYLD_LIBRARY_PATH=") == true })
    }

    func testHardenedFixtureLowersLoadabilityWithoutEntitlementValueClaim() throws {
        let report = try assess("hardened")
        let main = try XCTUnwrap(report.images.first { $0.role == .mainExecutable })
        let framework = try XCTUnwrap(report.images.first { $0.role == .framework })
        XCTAssertEqual(main.findings.map(\.ruleID).sorted(), ["L1", "L2", "L3", "L4", "L5"])
        XCTAssertEqual(framework.findings.map(\.ruleID).sorted(), ["L4", "L6", "L7"])
        for finding in main.findings where ["L1", "L2", "L4", "L5"].contains(finding.ruleID) {
            XCTAssertTrue([.low, .informational].contains(finding.severity), "\(finding.ruleID): \(finding.severity)")
            XCTAssertNotNil(finding.mitigation)
        }
    }

    func testFrameworkRoleUsesParentDirectorySuffixWithoutChangingPath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("LoadPathRisk-\(UUID().uuidString).app")
        try fileManager.copyItem(at: fixtureDirectory.appendingPathComponent("ordinary.app"), to: root)
        defer { try? fileManager.removeItem(at: root) }

        let frameworks = root.appendingPathComponent("Contents/Frameworks")
        let source = frameworks.appendingPathComponent("Found.framework/Found")
        let upperDirectory = frameworks.appendingPathComponent("Upper.FRAMEWORK")
        let nearDirectory = frameworks.appendingPathComponent("Near.framework2")
        try fileManager.createDirectory(at: upperDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nearDirectory, withIntermediateDirectories: true)
        let upper = upperDirectory.appendingPathComponent("Upper")
        let near = nearDirectory.appendingPathComponent("Near")
        let standalone = frameworks.appendingPathComponent("Standalone.framework")
        try fileManager.copyItem(at: source, to: upper)
        try fileManager.copyItem(at: source, to: near)
        try fileManager.copyItem(at: source, to: standalone)

        let report = try LoadPathRiskAnalyzer().analyze(bundleURL: root)
        let roles = Dictionary(uniqueKeysWithValues: report.images.map { ($0.path, $0.role) })
        XCTAssertEqual(roles[upper.path], .framework, "Observed paths: \(roles.keys.sorted())")
        XCTAssertEqual(roles[near.path], .library)
        XCTAssertEqual(roles[standalone.path], .library)
        XCTAssertEqual(roles[source.path], .framework)
    }

    func testCandidateCPUTypeKeepsPresenceSeparateFromAssessment() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("LoadPathRisk-CPU-\(UUID().uuidString).app")
        try fileManager.copyItem(at: fixtureDirectory.appendingPathComponent("ordinary.app"), to: root)
        defer { try? fileManager.removeItem(at: root) }
        let candidateURL = root.appendingPathComponent("Contents/Frameworks/Found.framework/Found")
        let buildRoot = fileManager.temporaryDirectory.appendingPathComponent("LoadPathRisk-CPU-build-\(UUID().uuidString)")
        try fileManager.createDirectory(at: buildRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: buildRoot) }
        let x86Candidate = buildRoot.appendingPathComponent("candidate-x86_64.dylib")
        let armCandidate = buildRoot.appendingPathComponent("candidate-arm64.dylib")
        let universalCandidate = buildRoot.appendingPathComponent("candidate-universal.dylib")

        func runTool(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "xcrun \(arguments.joined(separator: " "))")
        }

        let stub = fixtureDirectory.appendingPathComponent("stub.c").path
        func buildCandidate(_ arch: String, at output: URL) throws {
            try runTool(["--sdk", "macosx", "clang", "-arch", arch, "-O1", "-dynamiclib", stub,
                         "-install_name", "@rpath/Found.framework/Found", "-o", output.path])
        }
        try buildCandidate("x86_64", at: x86Candidate)
        try buildCandidate("arm64", at: armCandidate)
        try runTool(["lipo", "-create", armCandidate.path, x86Candidate.path,
                     "-output", universalCandidate.path])

        func mainAndCandidate() throws -> (LoadPathRiskReport.Image, LoadPathRiskReport.Resolution) {
            let report = try LoadPathRiskAnalyzer().analyze(bundleURL: root)
            let main = try XCTUnwrap(report.images.first { $0.role == .mainExecutable })
            let candidate = try XCTUnwrap(main.resolution.first {
                $0.location == .bundle && $0.dependency.rawString.contains("Found.framework/Found")
            })
            return (main, candidate)
        }

        let (compatibleMain, compatible) = try mainAndCandidate()
        XCTAssertEqual(compatible.existence, .present)
        XCTAssertEqual(compatible.architectureAssessment, .matchingCPUType)
        let outsideNote = try XCTUnwrap(compatibleMain.resolution.first { $0.location == .elsewhere }?.note)

        try fileManager.removeItem(at: candidateURL)
        try fileManager.copyItem(at: x86Candidate, to: candidateURL)
        let (incompatibleMain, incompatible) = try mainAndCandidate()
        XCTAssertEqual(incompatible.existence, .present)
        XCTAssertEqual(incompatible.architectureAssessment, .differentCPUType)
        XCTAssertTrue(incompatible.note?.contains("Candidate is present") == true)
        XCTAssertEqual(incompatibleMain.findings.map(\.ruleID), compatibleMain.findings.map(\.ruleID))
        XCTAssertEqual(incompatibleMain.resolution.first { $0.location == .elsewhere }?.note, outsideNote)

        try fileManager.removeItem(at: candidateURL)
        try fileManager.copyItem(at: universalCandidate, to: candidateURL)
        let (_, universal) = try mainAndCandidate()
        XCTAssertEqual(universal.existence, .present)
        XCTAssertEqual(universal.architectureAssessment, .matchingCPUType)

        try fileManager.removeItem(at: candidateURL)
        try Data("not a Mach-O image".utf8).write(to: candidateURL)
        let (unassessedMain, unassessed) = try mainAndCandidate()
        XCTAssertEqual(unassessed.existence, .present)
        XCTAssertEqual(unassessed.architectureAssessment, .unassessed)
        XCTAssertEqual(unassessedMain.findings.map(\.ruleID), compatibleMain.findings.map(\.ruleID))

        try fileManager.removeItem(at: candidateURL)
        let (_, absent) = try mainAndCandidate()
        XCTAssertEqual(absent.existence, .absent)
        XCTAssertNil(absent.architectureAssessment)
    }

    func testLegacyResolutionDecodesWithoutArchitectureAssessment() throws {
        let json = #"{"dependency":{"index":0,"name":"LC_LOAD_DYLIB","rawString":"@rpath/lib.dylib"},"candidate":"/tmp/lib.dylib","searchOrder":0,"location":"bundle","existence":"present"}"#
        let resolution = try JSONDecoder().decode(LoadPathRiskReport.Resolution.self, from: Data(json.utf8))
        XCTAssertNil(resolution.architectureAssessment)
    }

    private func assess(_ name: String) throws -> LoadPathRiskReport {
        let root = fixtureDirectory.appendingPathComponent("\(name).app").standardizedFileURL
        var checked: [String] = []
        let report = try LoadPathRiskAnalyzer().analyze(bundleURL: root) { candidate in
            XCTAssertTrue(candidate.path.hasPrefix(root.path + "/"), "Outside probe: \(candidate.path)")
            checked.append(candidate.path)
            return FileManager.default.fileExists(atPath: candidate.path)
        }
        XCTAssertFalse(checked.isEmpty)
        XCTAssertTrue(report.images.allSatisfy { $0.path.hasPrefix(root.path + "/") })
        XCTAssertTrue(report.images.flatMap(\.resolution).filter { $0.location != .bundle }.allSatisfy { $0.existence == .notChecked })
        return report
    }
}
