import Foundation
import XCTest

@testable import MacScope

final class Phase2LocalAIProviderPreferenceStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: UserDefaultsPhase2LocalAIProviderPreferenceStore!

    override func setUp() {
        super.setUp()
        suiteName = "Phase2LocalAIProviderPreferenceStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = .init(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testVersionOneRoundTripUsesOneCanonicalBlobAndOmitsRuntimeAuthority() throws {
        let preference = try makePreference()
        store.save(preference)

        XCTAssertEqual(store.load(), preference)
        XCTAssertEqual(
            Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? []),
            [UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey]
        )

        let data = try XCTUnwrap(defaults.data(
            forKey: UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["endpointOrigin"] as? String, "http://127.0.0.1:1234")
        XCTAssertEqual(object["desiredModelKey"] as? String, "publisher/model-a")
        XCTAssertEqual(object["maximumTokens"] as? Int, 2_048)

        for forbidden in [
            "profileID", "generation", "inventory", "ownership", "readiness",
            "loadedInstances", "activity",
        ] {
            XCTAssertNil(object[forbidden], forbidden)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(forbidden), forbidden)
        }
    }

    @MainActor
    func testExplicitLegacyProviderBlobRemainsStoredButCannotFallThroughToDefault() throws {
        store.save(try makePreference())
        let key = UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
        let prior = try XCTUnwrap(defaults.data(forKey: key))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: prior) as? [String: Any])
        object["inferencePolicy"] = ["provider": "lmStudio", "reasoningEffort": "xhigh",
            "enableThinking": true, "effectiveContextTokens": 65_536] as [String: Any]
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        defaults.set(legacy, forKey: key)
        XCTAssertTrue(store.hasStoredPreference)
        XCTAssertNil(store.load())
        XCTAssertEqual(defaults.data(forKey: key), legacy)
        let controller = Phase2LocalAIProviderController(preferenceStore: store,
            defaultPreference: try .mtplxQualityDefault())
        XCTAssertTrue(controller.hasUnsupportedProviderConfiguration)
        XCTAssertNil(controller.snapshot.endpoint)
        XCTAssertNil(controller.captureReadyInferenceLease())
        XCTAssertEqual(defaults.data(forKey: key), legacy)
    }

    func testQualityDefaultEndpointUsesBoundedFifteenMinuteRequestTimeout() throws {
        let preference = try Phase2LocalAIProviderPreference.mtplxQualityDefault()
        let endpoint = try preference.makeEndpoint(profileID: UUID(), generation: 1)
        XCTAssertEqual(endpoint.requestTimeoutMilliseconds, 900_000)
        XCTAssertEqual(endpoint.resourceTimeoutMilliseconds, 1_800_000)
        XCTAssertEqual(endpoint.inferencePolicy, Phase2LocalInferencePolicy())
        XCTAssertThrowsError(try Phase2LocalProviderEndpoint(profileID: UUID(), generation: 1,
            endpointOrigin: endpoint.endpointOrigin, requestTimeoutMilliseconds: 900_001,
            resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: endpoint.inferencePolicy))
        XCTAssertThrowsError(try Phase2LocalProviderEndpoint(profileID: UUID(), generation: 1,
            endpointOrigin: endpoint.endpointOrigin, requestTimeoutMilliseconds: 31_000,
            resourceTimeoutMilliseconds: 120_000))
    }

    func testPreferenceWithoutDesiredSelectionRoundTripsWithoutSelectionKeys() throws {
        let preference = try Phase2LocalAIProviderPreference(
            endpointOrigin: "http://[::1]:65535/",
            requestTimeoutMilliseconds: 1_000,
            resourceTimeoutMilliseconds: 120_000,
            desiredSelection: nil
        )
        store.save(preference)

        XCTAssertEqual(store.load(), preference)
        let data = try XCTUnwrap(defaults.data(
            forKey: UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["endpointOrigin"] as? String, "http://[::1]:65535")
        XCTAssertNil(object["desiredModelKey"])
        XCTAssertNil(object["maximumTokens"])
    }

    func testCorruptFutureExtraAndOversizedRecordsFailClosedAndAreRetired() throws {
        let cases: [Data] = [
            Data("not-json".utf8),
            try encodedRecord(overrides: ["schemaVersion": 2]),
            try encodedRecord(overrides: ["unexpected": true]),
            Data(repeating: 0x20, count:
                UserDefaultsPhase2LocalAIProviderPreferenceStore.maximumEnvelopeBytes + 1),
        ]

        for data in cases {
            defaults.set(
                data,
                forKey: UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
            )
            XCTAssertNil(store.load())
            XCTAssertNil(
                defaults.object(
                    forKey: UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
                ),
                "an invalid preference must be retired so it cannot regain authority later"
            )
        }
    }

    func testSemanticallyValidButNoncanonicalRecordIsRetired() throws {
        let canonical = try encodedRecord(overrides: [:])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        let noncanonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted]
        )
        XCTAssertNotEqual(noncanonical, canonical)
        defaults.set(
            noncanonical,
            forKey: UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
        )

        XCTAssertNil(store.load())
        XCTAssertNil(defaults.object(
            forKey: UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
        ))
    }

    func testWrongDefaultsValueTypeIsRetired() {
        defaults.set(
            "not-a-provider-preference-envelope",
            forKey: UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
        )

        XCTAssertNil(store.load())
        XCTAssertNil(defaults.object(
            forKey: UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
        ))
    }

    func testDesiredSelectionFieldsMustBePresentOrAbsentTogether() throws {
        let onlyModel = try encodedRecord(overrides: [
            "desiredModelKey": "publisher/model-a",
        ])
        let onlyTokens = try encodedRecord(overrides: ["maximumTokens": 2_048])
        let explicitNulls = try encodedRecord(overrides: [
            "desiredModelKey": NSNull(),
            "maximumTokens": NSNull(),
        ])

        for data in [onlyModel, onlyTokens, explicitNulls] {
            defaults.set(
                data,
                forKey: UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
            )
            XCTAssertNil(store.load())
        }
    }

    func testInvalidEndpointTimeoutModelAndTokenFieldsFailClosed() throws {
        let cases: [Data] = [
            try encodedRecord(overrides: ["endpointOrigin": "http://example.com:1234"]),
            try encodedRecord(overrides: ["requestTimeoutMilliseconds": 999]),
            try encodedRecord(overrides: ["resourceTimeoutMilliseconds": 999]),
            try encodedRecord(overrides: [
                "desiredModelKey": "bad\u{0001}model",
                "maximumTokens": 2_048,
            ]),
            try encodedRecord(overrides: [
                "desiredModelKey": "publisher/model-a",
                "maximumTokens": 8_193,
            ]),
        ]

        for data in cases {
            defaults.set(
                data,
                forKey: UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
            )
            XCTAssertNil(store.load())
        }
    }

    func testClearAndInMemoryStoreHaveExactReplacementSemantics() throws {
        let first = try makePreference()
        let second = try Phase2LocalAIProviderPreference(
            endpointOrigin: "http://[::1]:4321",
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 10_000,
            desiredSelection: nil
        )

        store.save(first)
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertNil(defaults.object(
            forKey: UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
        ))

        let memory = InMemoryPhase2LocalAIProviderPreferenceStore(initialPreference: first)
        XCTAssertEqual(memory.load(), first)
        memory.save(second)
        XCTAssertEqual(memory.load(), second)
        memory.clear()
        XCTAssertNil(memory.load())
    }

    func testMakeEndpointUsesOnlyCallerSuppliedFreshRuntimeIdentity() throws {
        let preference = try makePreference()
        let profileID = UUID()
        let endpoint = try preference.makeEndpoint(profileID: profileID, generation: 73)

        XCTAssertEqual(endpoint.profileID, profileID)
        XCTAssertEqual(endpoint.generation, 73)
        XCTAssertEqual(endpoint.endpointOrigin, preference.endpointOrigin)
        XCTAssertThrowsError(
            try preference.makeEndpoint(profileID: profileID, generation: 0)
        )
    }

    func testOutputBudgetStillAtThePreviousDefaultMigratesOnceAndOtherValuesStay() throws {
        let policy = Phase2LocalInferencePolicy()
        func preference(_ maximumTokens: Int) throws -> Phase2LocalAIProviderPreference {
            try .init(endpointOrigin: "http://127.0.0.1:8000", requestTimeoutMilliseconds: 900_000,
                      resourceTimeoutMilliseconds: 1_800_000,
                      desiredSelection: .init(modelKey: "served/model", maximumTokens: maximumTokens,
                                              inferencePolicy: policy),
                      inferencePolicy: policy)
        }

        store.save(try preference(2_048))
        store.migrateOutputBudgetOnce()
        XCTAssertEqual(store.load(), try preference(8_192))
        XCTAssertEqual(Phase2LocalInferencePolicy.defaultMaximumOutputTokens, 8_192)

        // Once only: a 2,048 the user picks afterwards stays.
        store.save(try preference(2_048))
        store.migrateOutputBudgetOnce()
        XCTAssertEqual(store.load(), try preference(2_048))

        // Any other saved value is left alone, as is a store with nothing saved.
        for (index, other) in [4_096, 16_384].enumerated() {
            let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName + ".other\(index)"))
            defer { otherDefaults.removePersistentDomain(forName: suiteName + ".other\(index)") }
            let otherStore = UserDefaultsPhase2LocalAIProviderPreferenceStore(defaults: otherDefaults)
            otherStore.save(try preference(other))
            otherStore.migrateOutputBudgetOnce()
            XCTAssertEqual(otherStore.load(), try preference(other))
        }
        let emptyDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName + ".empty"))
        defer { emptyDefaults.removePersistentDomain(forName: suiteName + ".empty") }
        let emptyStore = UserDefaultsPhase2LocalAIProviderPreferenceStore(defaults: emptyDefaults)
        emptyStore.migrateOutputBudgetOnce()
        XCTAssertNil(emptyStore.load())
        XCTAssertFalse(emptyStore.hasStoredPreference)
    }

    private func makePreference() throws -> Phase2LocalAIProviderPreference {
        try Phase2LocalAIProviderPreference(
            endpointOrigin: "http://127.0.0.1:1234/",
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 30_000,
            desiredSelection: Phase2LocalAIDesiredSelection(
                modelKey: "publisher/model-a",
                maximumTokens: 2_048
            )
        )
    }

    private func encodedRecord(overrides: [String: Any]) throws -> Data {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "endpointOrigin": "http://127.0.0.1:1234",
            "requestTimeoutMilliseconds": 10_000,
            "resourceTimeoutMilliseconds": 30_000,
        ]
        for (key, value) in overrides { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

extension Phase2LocalAIProviderPreferenceStoreTests {
    func testInstalledPreferenceSuiteResolutionNeverChangesAppDomain() throws {
        let appDomain = "org.macscope.app"
        let before = NSDictionary(dictionary:
            UserDefaults.standard.persistentDomain(forName: appDomain) ?? [:])
        XCTAssertTrue(UserDefaultsPhase2LocalAIProviderPreferenceStore.productionDefaults(environment: [:])
            === UserDefaults.standard)
        let name = "org.macscope.app.tests." + UUID().uuidString
        let isolated = UserDefaultsPhase2LocalAIProviderPreferenceStore.productionDefaults(environment: [
            "MACSCOPE_WS24_RUN_INSTALLED_XCUITEST": "1",
            "MACSCOPE_TEST_PREFERENCES_SUITE": name
        ])
        defer { isolated.removePersistentDomain(forName: name) }
        let key = UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
        isolated.set(Data([0x01]), forKey: key)
        XCTAssertEqual(isolated.data(forKey: key), Data([0x01]))
        isolated.removeObject(forKey: key)
        XCTAssertNil(isolated.object(forKey: key))
        XCTAssertTrue(before.isEqual(to:
            UserDefaults.standard.persistentDomain(forName: appDomain) ?? [:]))
    }
}
