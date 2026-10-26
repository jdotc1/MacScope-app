import Foundation

enum EntitlementRiskSeverity: String, Codable, Sendable { case high, medium, low, info }
enum EntitlementRiskConfidence: String, Codable, Sendable { case definite, needsReview = "needs-review" }

struct EntitlementRiskCatalogEntry: Codable, Sendable {
    enum RiskyValue: String, Codable, Sendable { case trueValue, absentOrFalse, nonempty, present }
    let key: String
    let riskyValue: RiskyValue
    let category: String
    let severity: EntitlementRiskSeverity
    let why: String
    let appleReference: String
}

/// Declarative key-to-effect catalog; wildcard entries match only their stated prefix.
enum EntitlementRiskCatalog {
    static let entries: [EntitlementRiskCatalogEntry] = [
        .init(key: "com.apple.security.cs.disable-library-validation", riskyValue: .trueValue,
              category: "hardened runtime", severity: .medium,
              why: "Allows loading code without the usual library team validation.",
              appleReference: "Disable Library Validation Entitlement"),
        .init(key: "com.apple.security.cs.allow-dyld-environment-variables", riskyValue: .trueValue,
              category: "hardened runtime", severity: .medium,
              why: "Permits dyld environment variables to affect launch-time loading.",
              appleReference: "Allow DYLD Environment Variables Entitlement"),
        .init(key: "com.apple.security.cs.allow-unsigned-executable-memory", riskyValue: .trueValue,
              category: "hardened runtime", severity: .high,
              why: "Permits executable memory without the narrower JIT entitlement constraints.",
              appleReference: "Allow Unsigned Executable Memory Entitlement"),
        .init(key: "com.apple.security.cs.allow-jit", riskyValue: .trueValue,
              category: "hardened runtime", severity: .low,
              why: "Permits JIT memory with a narrower exception than unsigned executable memory.",
              appleReference: "Allow Execution of JIT-compiled Code Entitlement"),
        .init(key: "com.apple.security.cs.disable-executable-page-protection", riskyValue: .trueValue,
              category: "hardened runtime", severity: .high,
              why: "Disables executable-page protection for this process.",
              appleReference: "Disable Executable Memory Protection Entitlement"),
        .init(key: "com.apple.security.cs.debugger", riskyValue: .trueValue,
              category: "hardened runtime", severity: .medium,
              why: "Grants debugging capability that can weaken process isolation when honored.",
              appleReference: "Debugger Entitlement"),
        .init(key: "com.apple.security.get-task-allow", riskyValue: .trueValue,
              category: "debuggability", severity: .medium,
              why: "Allows debugger attachment; review whether a team-signed release should ship with it.",
              appleReference: "Get Task Allow Entitlement"),
        .init(key: "com.apple.security.app-sandbox", riskyValue: .absentOrFalse,
              category: "sandbox posture", severity: .medium,
              why: "No App Sandbox is declared for this executable.",
              appleReference: "App Sandbox Entitlement"),
        .init(key: "com.apple.security.temporary-exception.*", riskyValue: .present,
              category: "sandbox posture", severity: .medium,
              why: "A temporary sandbox exception extends the declared sandbox access; inspect its value.",
              appleReference: "App Sandbox Temporary Exception Entitlements"),
        .init(key: "com.apple.security.device.camera", riskyValue: .trueValue,
              category: "privacy capability", severity: .info,
              why: "Declares camera access capability; actual access remains subject to privacy controls.",
              appleReference: "Camera Entitlement"),
        .init(key: "com.apple.security.device.microphone", riskyValue: .trueValue,
              category: "privacy capability", severity: .info,
              why: "Declares microphone access capability; actual access remains subject to privacy controls.",
              appleReference: "Audio Input Entitlement"),
        .init(key: "com.apple.security.automation.apple-events", riskyValue: .trueValue,
              category: "privacy capability", severity: .info,
              why: "Declares Apple Events automation capability; TCC and target policy still apply.",
              appleReference: "Apple Events Entitlement"),
        .init(key: "com.apple.security.personal-information.addressbook", riskyValue: .trueValue,
              category: "privacy capability", severity: .info,
              why: "Declares Contacts capability; TCC still controls access.",
              appleReference: "Address Book Entitlement"),
        .init(key: "com.apple.security.personal-information.calendars", riskyValue: .trueValue,
              category: "privacy capability", severity: .info,
              why: "Declares Calendar capability; TCC still controls access.",
              appleReference: "Calendar Entitlement"),
        .init(key: "com.apple.security.personal-information.location", riskyValue: .trueValue,
              category: "privacy capability", severity: .info,
              why: "Declares location capability; privacy authorization still applies.",
              appleReference: "Location Entitlement"),
        .init(key: "com.apple.private.*", riskyValue: .present,
              category: "private entitlement", severity: .medium,
              why: "A private entitlement generally requires Apple signing to be honored.",
              appleReference: "Code Signing and Entitlements")
    ]

    static func entry(for key: String) -> EntitlementRiskCatalogEntry? {
        entries.first { entry in
            entry.key.hasSuffix(".*") ? key.hasPrefix(String(entry.key.dropLast())) : key == entry.key
        }
    }
}
