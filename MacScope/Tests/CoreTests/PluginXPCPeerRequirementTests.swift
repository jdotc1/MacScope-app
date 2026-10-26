import Foundation
import Security
import XCTest

@testable import MacScope

final class PluginXPCPeerRequirementTests: XCTestCase {
    func testPeerRequirementsCompileAndBindFrozenIdentifiers() throws {
        XCTAssertEqual(
            PluginXPCPeerRequirement.app,
            "identifier \"org.macscope.app\" and "
                + "anchor apple generic and certificate leaf[subject.CN] = "
                + "\"Apple Development: MacScope Developer (CERT000000)\" and "
                + "certificate leaf[subject.OU] = \"TEAM000000\" and "
                + "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
        )
        XCTAssertEqual(
            PluginXPCPeerRequirement.service,
            "identifier \"org.macscope.app.PluginXPCService\" and "
                + "anchor apple generic and certificate leaf[subject.CN] = "
                + "\"Apple Development: MacScope Developer (CERT000000)\" and "
                + "certificate leaf[subject.OU] = \"TEAM000000\" and "
                + "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
        )

        try assertCompiles(PluginXPCPeerRequirement.app)
        try assertCompiles(PluginXPCPeerRequirement.service)
    }

    func testListenerAdmissionInstallsAppRequirementBeforeExportsAndResume() {
        var events: [String] = []

        PluginXPCListenerAdmission.accept(
            installRequirement: { events.append("requirement:\($0)") },
            exportInterface: { events.append("interface") },
            exportObject: { events.append("object") },
            resume: { events.append("resume") }
        )

        XCTAssertEqual(
            events,
            [
                "requirement:\(PluginXPCPeerRequirement.app)",
                "interface",
                "object",
                "resume",
            ]
        )
    }

    private func assertCompiles(_ expression: String) throws {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(expression as CFString, [], &requirement)
        XCTAssertEqual(status, errSecSuccess, "requirement must compile: \(expression)")
        XCTAssertNotNil(requirement)
    }
}
