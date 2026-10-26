import Foundation
import Security
import XCTest

#if canImport(MacScope)
@testable import MacScope
#endif

final class NativeDecompilerXPCPeerRequirementTests: XCTestCase {
    func testPeerRequirementsCompileAndBindFrozenIdentifiers() throws {
        XCTAssertEqual(
            NativeDecompilerXPCPeerRequirement.app,
            "identifier \"org.macscope.app\" and "
                + "anchor apple generic and certificate leaf[subject.CN] = "
                + "\"Apple Development: MacScope Developer (CERT000000)\" and "
                + "certificate leaf[subject.OU] = \"TEAM000000\" and "
                + "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
        )
        XCTAssertEqual(
            NativeDecompilerXPCPeerRequirement.service,
            "identifier \"org.macscope.app.NativeDecompiler\" and "
                + "anchor apple generic and certificate leaf[subject.CN] = "
                + "\"Apple Development: MacScope Developer (CERT000000)\" and "
                + "certificate leaf[subject.OU] = \"TEAM000000\" and "
                + "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
        )

        try assertCompiles(NativeDecompilerXPCPeerRequirement.app)
        try assertCompiles(NativeDecompilerXPCPeerRequirement.service)
    }

    func testClientAdmissionInstallsServiceRequirementExactlyOnceBeforeResume() {
        let gate = NativeDecompilerXPCClientAdmissionGate()
        var events: [String] = []

        gate.installRequirement {
            events.append("requirement:\($0)")
        }
        gate.installRequirement {
            events.append("duplicate-requirement:\($0)")
        }
        gate.resume {
            events.append("resume")
        }
        gate.resume {
            events.append("duplicate-resume")
        }

        XCTAssertEqual(
            events,
            [
                "requirement:\(NativeDecompilerXPCPeerRequirement.service)",
                "resume",
            ]
        )
    }

    func testListenerAdmissionInstallsAppRequirementBeforeExportsAndResume() {
        var events: [String] = []

        NativeDecompilerXPCListenerAdmission.accept(
            installRequirement: { events.append("requirement:\($0)") },
            exportInterface: { events.append("interface") },
            exportObject: { events.append("object") },
            resume: { events.append("resume") }
        )

        XCTAssertEqual(
            events,
            [
                "requirement:\(NativeDecompilerXPCPeerRequirement.app)",
                "interface",
                "object",
                "resume",
            ]
        )
    }

    private func assertCompiles(_ expression: String) throws {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            expression as CFString,
            SecCSFlags(),
            &requirement
        )
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNotNil(requirement)
    }
}
