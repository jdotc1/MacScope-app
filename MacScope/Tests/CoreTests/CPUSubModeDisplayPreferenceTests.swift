import XCTest
@testable import MacScope

/// Tier 3 — the CPU sub-mode display hint preference. A small but real contract: the hint
/// is OFF by default (so the listing is unchanged until opted in) and reads back from
/// UserDefaults. Guards against a silent default flip.
final class CPUSubModeDisplayPreferenceTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let suite = "CPUSubModeDisplayPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultIsOff() {
        XCTAssertFalse(CPUSubModeDisplayPreference.default)
        XCTAssertFalse(CPUSubModeDisplayPreference.read(from: defaults()))
    }

    func testReadsStoredValue() {
        let d = defaults()
        d.set(true, forKey: CPUSubModeDisplayPreference.storageKey)
        XCTAssertTrue(CPUSubModeDisplayPreference.read(from: d))
        d.set(false, forKey: CPUSubModeDisplayPreference.storageKey)
        XCTAssertFalse(CPUSubModeDisplayPreference.read(from: d))
    }
}
