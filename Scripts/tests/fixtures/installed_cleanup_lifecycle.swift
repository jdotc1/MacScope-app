// Native regression fixture. Compile this after the Task10CCleanup and XCTestCase
// extension extracted from WS24InstalledAppUITests.swift in the same Swift source.
// Run in an isolated XCTest product, never against the installed app or preferences.
// Four intentional failures are required; the host validates the five JSON observations.
import Foundation
import XCTest

@MainActor
private enum CleanupFixtureState {
    static var value: Data?
    static var events: [String] = []
    static var unrelated = "synthetic-sentinel"
    static let original = Data([0, 0xff, 0x41, 0x00])

    static func reset(present: Bool = true) {
        value = present ? original : nil
        events = []
        unrelated = "synthetic-sentinel"
    }

    static func record(_ name: String, originallyPresent: Bool = true) throws {
        guard let root = ProcessInfo.processInfo.environment["MACSCOPE_CLEANUP_FIXTURE_ROOT"] else {
            throw NSError(domain: "CleanupFixture", code: 1)
        }
        let document: [String: Any] = [
            "original_restored": value == (originallyPresent ? original : nil),
            "unrelated_unchanged": unrelated == "synthetic-sentinel",
            "events": events
        ]
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: root).appendingPathComponent(name),
                   options: .withoutOverwriting)
    }
}

final class InstalledCleanupLifecycleFixture: XCTestCase {
    @MainActor
    private func registerSnapshot(present: Bool = true, observation: String) {
        CleanupFixtureState.reset(present: present)
        let original = CleanupFixtureState.value
        // Registered first so the host observes state after all owned cleanup.
        addTeardownBlock { @MainActor in
            try CleanupFixtureState.record(observation, originallyPresent: present)
        }
        _ = registerTask10Cleanup {
            CleanupFixtureState.value = original
            CleanupFixtureState.events.append("restore")
        }
        CleanupFixtureState.value = nil
    }

    @MainActor
    func testAssertionInterruptionRestoresAfterOwnedResources() {
        continueAfterFailure = false
        registerSnapshot(observation: "assertion.json")
        _ = registerTask10Cleanup { CleanupFixtureState.events.append("provider") }
        _ = registerTask10Cleanup { CleanupFixtureState.events.append("candidate") }
        XCTAssertTrue(false, "Intentional assertion interruption; expected failure.")
        CleanupFixtureState.events.append("unexpected-continuation")
    }

    @MainActor
    func testAbsentBaselineSurvivesInterruption() {
        continueAfterFailure = false
        registerSnapshot(present: false, observation: "absent.json")
        CleanupFixtureState.value = Data([1, 2, 3])
        XCTAssertTrue(false, "Intentional assertion interruption; expected failure.")
    }

    @MainActor
    func testCleanupAssertionCannotSkipOtherCleanup() {
        continueAfterFailure = false
        registerSnapshot(observation: "cleanup-assertion.json")
        _ = registerTask10Cleanup { CleanupFixtureState.events.append("provider") }
        _ = registerTask10Cleanup {
            CleanupFixtureState.events.append("candidate")
            XCTAssertTrue(false, "Intentional cleanup failure; expected failure.")
            CleanupFixtureState.events.append("candidate-completed")
        }
    }

    @MainActor
    func testThrownCleanupCannotSkipRestoration() {
        continueAfterFailure = false
        registerSnapshot(observation: "cleanup-throw.json")
        _ = registerTask10Cleanup { CleanupFixtureState.events.append("provider") }
        _ = registerTask10Cleanup {
            CleanupFixtureState.events.append("candidate")
            throw NSError(domain: "CleanupFixture", code: 2)
        }
    }

    @MainActor
    func testImmediateCleanupIsNotRepeatedAtTeardown() throws {
        continueAfterFailure = false
        registerSnapshot(observation: "immediate.json")
        let cleanup = registerTask10Cleanup { CleanupFixtureState.events.append("provider") }
        try cleanup.perform()
        try cleanup.perform()
        XCTAssertEqual(CleanupFixtureState.events, ["provider"])
    }
}
