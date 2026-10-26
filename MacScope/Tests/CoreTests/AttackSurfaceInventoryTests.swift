import Foundation
import XCTest
@testable import MacScope

final class AttackSurfaceInventoryTests: XCTestCase {
    private var fixture: URL {
        TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures/xpc-attack-surface/Fixture.app")
    }

    func testBundleInventoryRetainsDeclarationsAndUnmatchedEvidence() throws {
        let report = try AttackSurfaceAnalyzer().analyze(bundleURL: fixture)
        let names = Set(report.services.map(\.machServiceName))
        XCTAssertTrue(names.contains("com.example.fixture.control"))
        XCTAssertTrue(names.contains("com.example.fixture.absent"))
        XCTAssertTrue(names.contains("com.example.fixture.events"))
        XCTAssertTrue(names.contains("com.example.fixture.daemon"))
        XCTAssertTrue(names.contains("com.example.fixture.user"))
        XCTAssertTrue(names.contains("com.example.fixture.service"))
        XCTAssertEqual(report.services.first(where: { $0.machServiceName == "com.example.fixture.control" })?.privilege, .root)
        XCTAssertEqual(report.services.first(where: { $0.machServiceName == "com.example.fixture.control" })?.listener?.kind, .nsxpc)
        XCTAssertNotNil(report.services.first(where: { $0.machServiceName == "com.example.fixture.control" })?.listener?.acceptanceAddress)
        XCTAssertEqual(report.services.first(where: { $0.machServiceName == "com.example.fixture.control" })?
            .listener?.interfaces.first(where: { $0.protocolName == "FixtureControl" })?.methods.count, 3)
        XCTAssertTrue(report.services.first(where: { $0.machServiceName == "com.example.fixture.control" })?
            .listener?.interfaces.first(where: { $0.protocolName == "FixtureControl" })?
            .methods.contains(where: { $0.selector == "statusWithReply:" && $0.takesReplyBlock }) == true)
        XCTAssertEqual(report.services.first(where: { $0.machServiceName == "com.example.fixture.events" })?.listener?.kind, .libxpc)
        XCTAssertEqual(report.services.first(where: { $0.machServiceName == "com.example.fixture.service" })?.listener?.kind, .nsxpc)
        XCTAssertTrue(report.services.first(where: { $0.machServiceName == "com.example.fixture.control" })?
            .declaredClientRequirements.contains(where: { $0.contains("com.example.fixture.host") }) == true)
        XCTAssertTrue(report.unmatched.contains(where: { $0.name == "com.example.fixture.absent" }))
        XCTAssertTrue(report.unmatched.contains(where: { $0.listener?.setupAPI.hasSuffix("anonymousListener") == true }))
        XCTAssertTrue(report.unmatched.contains(where: {
            $0.listener?.setupAPI.contains("xpc_main") == true && $0.listener?.messageKeys.contains("action") == true
        }))
        XCTAssertEqual(report.services.first(where: { $0.machServiceName == "com.example.fixture.user" })?.privilege, .user)
        XCTAssertTrue(report.sources.contains(where: { $0.section == "__TEXT,__launchd_plist" }))
        XCTAssertTrue(report.sources.contains(where: { $0.section == "SMPrivilegedExecutables" }))
        XCTAssertTrue(report.sources.contains(where: { $0.fields["XPCService.JoinExistingSession"] != nil }))
        XCTAssertTrue(report.sources.contains(where: { $0.fields["CFBundleIdentifier"] == "com.example.fixture.login" }))
        let encoded = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(AttackSurfaceReport.self, from: encoded).services.count, report.services.count)
    }

    func testProtocolMetadataHasThreeExportCandidatesIncludingReply() throws {
        let binary = fixture.appendingPathComponent("Contents/Library/LaunchServices/FixtureHelper")
        let file = try MachOParser().parse(Data(contentsOf: binary))
        let protocolValue = try XCTUnwrap(file.objectiveCMetadata.protocols.first { $0.name == "FixtureControl" })
        let methods = protocolValue.requiredMethods + protocolValue.optionalMethods
        XCTAssertEqual(methods.count, 3)
        XCTAssertTrue(methods.contains(where: { $0.selector == "statusWithReply:" && $0.typeEncoding?.contains("@?") == true }))
        let delegate = try XCTUnwrap(file.objectiveCMetadata.classes.first { $0.name == "FixtureDelegate" })
        XCTAssertNotNil(delegate.instanceMethods.first(where: { $0.selector == "listener:shouldAcceptNewConnection:" })?.implementation)
    }

    func testSingleMachOUsesOnlyEmbeddedDeclarations() throws {
        let binary = fixture.appendingPathComponent("Contents/Library/LaunchServices/FixtureHelper")
        let report = try AttackSurfaceAnalyzer().analyze(bundleURL: binary)
        XCTAssertEqual(Set(report.services.map(\.machServiceName)),
                       ["com.example.fixture.control", "com.example.fixture.absent"])
        XCTAssertTrue(report.services.allSatisfy { $0.privilege == .unknown })
        XCTAssertTrue(report.sources.allSatisfy { $0.path == binary.path })
        let bytes = try Data(contentsOf: binary)
        let parsed = try MachOParser().parse(bytes)
        let parsedReport = AttackSurfaceAnalyzer().analyze(machO: parsed, bytes: bytes)
        XCTAssertEqual(Set(parsedReport.services.map(\.machServiceName)),
                       Set(report.services.map(\.machServiceName)))
    }

    func testSymlinkedBundleRootIsRejected() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: fixture)
        defer { try? FileManager.default.removeItem(at: temporary) }
        XCTAssertThrowsError(try AttackSurfaceAnalyzer().analyze(bundleURL: temporary))
    }
}
