import Foundation

enum Phase2LocalAIEndpointAdmissionPolicy {
    enum Classification: Equatable, Sendable {
        case loopback(canonicalOrigin: String)
        case nonLoopback
        case invalid
    }

    /// The product supports only an HTTP origin with an explicit port. Literal loopback values use
    /// the shared worker canonicalizer; the familiar `localhost` spelling is resolved locally to a
    /// literal address before any authority object or persisted preference is created.
    static func classify(_ value: String) -> Classification {
        guard !value.isEmpty, value.utf8.count <= 128 else { return .invalid }
        if let canonical = Phase2AIWorkerConfigurationValidation
            .canonicalLoopbackOrigin(value)
        {
            return .loopback(canonicalOrigin: canonical)
        }
        guard let components = URLComponents(string: value),
              components.scheme == "http",
              components.user == nil,
              components.password == nil,
              let port = components.port,
              (1...Int(UInt16.max)).contains(port),
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              let encodedHost = components.percentEncodedHost,
              !encodedHost.isEmpty
        else { return .invalid }

        if encodedHost.lowercased() == "localhost" {
            return .loopback(canonicalOrigin: "http://127.0.0.1:\(port)")
        }
        return .nonLoopback
    }
}

protocol Phase2LocalAIProviderPreferencePersisting: AnyObject {
    var hasStoredPreference: Bool { get }
    func load() -> Phase2LocalAIProviderPreference?
    func save(_ preference: Phase2LocalAIProviderPreference)
    func clear()
}

extension Phase2LocalAIProviderPreferencePersisting {
    var hasStoredPreference: Bool { load() != nil }
}

/// A single-blob UserDefaults store for the app-global desired provider preference.
/// Invalid, oversized, unknown-version, and noncanonical records fail closed and are retired so a
/// later decoder cannot resurrect stale desired authority.
/// Recognized historical provider records are the exception: preserved inert, never admitted.
final class UserDefaultsPhase2LocalAIProviderPreferenceStore:
    Phase2LocalAIProviderPreferencePersisting
{
    static let storageKey = "phase2.localAI.providerPreference.v1"
    static let maximumEnvelopeBytes = 4_096

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = UserDefaultsPhase2LocalAIProviderPreferenceStore.productionDefaults(),
        storageKey: String = UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
    ) {
        self.defaults = defaults
        self.key = storageKey
    }

    /// Installed tests opt into a unique, non-app suite. Normal launches retain
    /// the existing standard-defaults behavior without an environment override.
    static func productionDefaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        guard let suiteName = environment["MACSCOPE_TEST_PREFERENCES_SUITE"] else { return .standard }
        let prefix = "org.macscope.app.tests."
        precondition(environment["MACSCOPE_WS24_RUN_INSTALLED_XCUITEST"] == "1"
            && suiteName.hasPrefix(prefix)
            && UUID(uuidString: String(suiteName.dropFirst(prefix.count))) != nil,
            "Invalid isolated installed-test preference suite")
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated installed-test preference suite")
        }
        return defaults
    }

    func load() -> Phase2LocalAIProviderPreference? {
        guard defaults.object(forKey: key) != nil else { return nil }
        guard let data = defaults.data(forKey: key),
              !data.isEmpty,
              data.count <= Self.maximumEnvelopeBytes,
              hasExactTopLevelKeys(data),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              wire.schemaVersion == Wire.currentSchemaVersion
        else {
            clear()
            return nil
        }

        // Historical explicit LM profiles remain stored, but cannot mint current
        // endpoint authority. Presence is separate from successful active decoding.
        if wire.inferencePolicy?.provider == .lmStudio { return nil }

        let desiredSelection: Phase2LocalAIDesiredSelection?
        if let modelKey = wire.desiredModelKey, let maximumTokens = wire.maximumTokens {
            desiredSelection = try? .init(
                modelKey: modelKey,
                maximumTokens: maximumTokens,
                inferencePolicy: wire.inferencePolicy
            )
            guard desiredSelection != nil else {
                clear()
                return nil
            }
        } else {
            guard wire.desiredModelKey == nil, wire.maximumTokens == nil else {
                clear()
                return nil
            }
            desiredSelection = nil
        }

        let canonicalOrigin: String
        switch Phase2LocalAIEndpointAdmissionPolicy.classify(wire.endpointOrigin) {
        case .loopback(let origin):
            canonicalOrigin = origin
        case .nonLoopback, .invalid:
            clear()
            return nil
        }
        guard let preference = try? Phase2LocalAIProviderPreference(
            endpointOrigin: canonicalOrigin,
            requestTimeoutMilliseconds: wire.requestTimeoutMilliseconds,
            resourceTimeoutMilliseconds: wire.resourceTimeoutMilliseconds,
            desiredSelection: desiredSelection,
            inferencePolicy: wire.inferencePolicy
        ), let canonicalData = encode(preference), canonicalData == data else {
            clear()
            return nil
        }
        return preference
    }

    var hasStoredPreference: Bool { defaults.object(forKey: key) != nil }

    static let outputBudgetMigrationKey = "phase2.localAI.outputBudgetMigration.v1"
    /// The output budget a selection was given before the default became 8,192 tokens.
    static let previousDefaultMaximumTokens = 2_048

    /// Moves a saved selection still at the previous 2,048-token default to the current
    /// default, once per defaults domain. Any other value is left alone, and after the first
    /// call so is a 2,048 the user picks again.
    func migrateOutputBudgetOnce() {
        guard !defaults.bool(forKey: Self.outputBudgetMigrationKey) else { return }
        defaults.set(true, forKey: Self.outputBudgetMigrationKey)
        guard let preference = load(),
              let selection = preference.desiredSelection,
              selection.maximumTokens == Self.previousDefaultMaximumTokens,
              let migrated = try? Phase2LocalAIProviderPreference(
                endpointOrigin: preference.endpointOrigin,
                requestTimeoutMilliseconds: preference.requestTimeoutMilliseconds,
                resourceTimeoutMilliseconds: preference.resourceTimeoutMilliseconds,
                desiredSelection: .init(
                    modelKey: selection.modelKey,
                    maximumTokens: Phase2LocalInferencePolicy.defaultMaximumOutputTokens,
                    inferencePolicy: preference.inferencePolicy
                ),
                inferencePolicy: preference.inferencePolicy
              )
        else { return }
        save(migrated)
    }

    func save(_ preference: Phase2LocalAIProviderPreference) {
        guard let data = encode(preference) else {
            clear()
            return
        }
        defaults.set(data, forKey: key)
    }

    private func encode(_ preference: Phase2LocalAIProviderPreference) -> Data? {
        let wire = Wire(preference: preference)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(wire),
              data.count <= Self.maximumEnvelopeBytes
        else { return nil }
        return data
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    private func hasExactTopLevelKeys(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return false }
        let required = Set([
            "schemaVersion",
            "endpointOrigin",
            "requestTimeoutMilliseconds",
            "resourceTimeoutMilliseconds",
        ])
        let selection = Set(["desiredModelKey", "maximumTokens"])
        var keys = Set(dictionary.keys)
        if keys.contains("inferencePolicy") {
            guard Phase2AIWorkerConfigurationWireCodec.hasClosedPolicy(dictionary["inferencePolicy"]) else { return false }
            keys.remove("inferencePolicy")
        }
        if keys == required { return true }
        guard keys == required.union(selection) else { return false }
        return !(dictionary["desiredModelKey"] is NSNull)
            && !(dictionary["maximumTokens"] is NSNull)
    }

    private struct Wire: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let endpointOrigin: String
        let requestTimeoutMilliseconds: Int
        let resourceTimeoutMilliseconds: Int
        let desiredModelKey: String?
        let maximumTokens: Int?
        let inferencePolicy: Phase2LocalInferencePolicy?

        init(preference: Phase2LocalAIProviderPreference) {
            schemaVersion = Self.currentSchemaVersion
            endpointOrigin = preference.endpointOrigin
            requestTimeoutMilliseconds = preference.requestTimeoutMilliseconds
            resourceTimeoutMilliseconds = preference.resourceTimeoutMilliseconds
            desiredModelKey = preference.desiredSelection?.modelKey
            maximumTokens = preference.desiredSelection?.maximumTokens
            inferencePolicy = preference.inferencePolicy
        }
    }
}

/// Deterministic no-I/O store for controller tests and runtime-only composition.
final class InMemoryPhase2LocalAIProviderPreferenceStore:
    Phase2LocalAIProviderPreferencePersisting
{
    private var preference: Phase2LocalAIProviderPreference?

    init(initialPreference: Phase2LocalAIProviderPreference? = nil) {
        preference = initialPreference
    }

    func load() -> Phase2LocalAIProviderPreference? {
        preference
    }

    func save(_ preference: Phase2LocalAIProviderPreference) {
        self.preference = preference
    }

    func clear() {
        preference = nil
    }
}
