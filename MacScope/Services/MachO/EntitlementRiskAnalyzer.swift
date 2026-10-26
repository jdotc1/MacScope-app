import Foundation

struct EntitlementRiskReport: Codable, Sendable {
    struct SignatureSummary: Codable, Sendable {
        var codeDirectoryFlags: UInt32?
        var hardenedRuntime: Bool?
        var libraryValidation: Bool?
        var restrict: Bool?
        var kill: Bool?
        var hard: Bool?
        var adHoc: Bool?
        var teamID: String?
        /// Code Directory platform byte, not proof that the signature is Apple trusted.
        var platformIdentifier: UInt8?
        /// Only a positive flag is evidence; absent runtime-only flags cannot prove false.
        var platformBinary: Bool?
        var sandboxDeclaration: String
    }

    struct Finding: Codable, Sendable {
        var ruleID: String
        var keysInvolved: [String]
        var severity: EntitlementRiskSeverity
        var confidence: EntitlementRiskConfidence
        var reason: String
    }

    var architecture: String?
    var sliceOffset: UInt64?
    var signature: SignatureSummary
    var entitlements: DeclaredEntitlements
    var findings: [Finding]
    var unknownKeys: [String]
}

enum EntitlementRiskBuildIntent: Equatable, Sendable { case unknown, development, release }

/// Classifies declarations only. This does not validate a signature, certificate, or TCC decision.
enum EntitlementRiskAnalyzer {
    private static let adhoc: UInt32 = 0x0000_0002
    private static let hard: UInt32 = 0x0000_0100
    private static let kill: UInt32 = 0x0000_0200
    private static let restrict: UInt32 = 0x0000_0800
    private static let requireLV: UInt32 = 0x0000_2000
    private static let runtime: UInt32 = 0x0001_0000
    private static let platformBinary: UInt32 = 0x0400_0000
    private static let exceptionPrefix = "com.apple.security.cs."

    static func analyze(
        file: MachOFile,
        selectedSliceBytes: Data,
        expectsAppSandbox: Bool = false,
        buildIntent: EntitlementRiskBuildIntent = .unknown
    ) -> EntitlementRiskReport {
        let values = EntitlementValueReader.read(signature: file.codeSignature, sliceBytes: selectedSliceBytes)
        let directory = file.codeSignature?.superBlob?.blobs.first {
            $0.type == MachOConstants.codeSignatureSlotCodeDirectory
        }?.codeDirectory
        return evaluate(
            codeDirectory: directory,
            entitlements: values,
            architecture: file.architectureName,
            sliceOffset: file.selectedSliceOffset,
            expectsAppSandbox: expectsAppSandbox,
            buildIntent: buildIntent
        )
    }

    /// Also accepts a constructed signature model for policy tests and external callers.
    static func evaluate(
        codeDirectory: MachOCodeDirectorySummary?,
        entitlements: DeclaredEntitlements,
        architecture: String? = nil,
        sliceOffset: UInt64? = nil,
        expectsAppSandbox: Bool = false,
        buildIntent: EntitlementRiskBuildIntent = .unknown
    ) -> EntitlementRiskReport {
        let flags = codeDirectory?.flags
        func has(_ bit: UInt32) -> Bool? { flags.map { $0 & bit != 0 } }
        let team = codeDirectory?.teamIdentifier
        let adHoc: Bool? = has(adhoc) == true ? true : (team == nil ? nil : false)
        let values = entitlements.values
        let sandbox: String
        if entitlements.state == .absent { sandbox = "absent" }
        else if entitlements.state == .unparsed { sandbox = "unparsed" }
        else if values["com.apple.security.app-sandbox"]?.isTrue == true { sandbox = "true" }
        else if values["com.apple.security.app-sandbox"]?.isFalse == true { sandbox = "false" }
        else if values["com.apple.security.app-sandbox"] == nil { sandbox = "absent" }
        else { sandbox = "unrecognized value" }

        let signature = EntitlementRiskReport.SignatureSummary(
            codeDirectoryFlags: flags,
            hardenedRuntime: has(runtime),
            libraryValidation: has(requireLV),
            restrict: has(restrict),
            kill: has(kill),
            hard: has(hard),
            adHoc: adHoc,
            teamID: team,
            platformIdentifier: codeDirectory?.platform,
            platformBinary: has(platformBinary) == true ? true : nil,
            sandboxDeclaration: sandbox
        )
        var findings: [EntitlementRiskReport.Finding] = []
        func add(_ id: String, _ keys: [String], _ severity: EntitlementRiskSeverity,
                 _ confidence: EntitlementRiskConfidence, _ reason: String) {
            findings.append(.init(ruleID: id, keysInvolved: keys, severity: severity,
                                  confidence: confidence, reason: reason))
        }

        if signature.hardenedRuntime == false {
            add("signature.no-hardened-runtime", [], .high, .definite,
                "Code Directory does not declare CS_RUNTIME; runtime exception entitlements have no hardened-runtime policy to relax.")
        } else if signature.hardenedRuntime == nil {
            add("signature.flags-unavailable", [], .info, .needsReview,
                "Code Directory flags are unavailable; hardened-runtime status cannot be classified.")
        }
        if entitlements.state == .unparsed {
            add("entitlements.unparsed", [], .info, .needsReview,
                "Entitlement values could not be read completely; key effects are not scored.")
        }

        let libraryKey = "com.apple.security.cs.disable-library-validation"
        let dyldKey = "com.apple.security.cs.allow-dyld-environment-variables"
        let combo = signature.hardenedRuntime == true && values[libraryKey]?.isTrue == true &&
            values[dyldKey]?.isTrue == true
        if combo {
            add("runtime.library-validation-plus-dyld", [libraryKey, dyldKey], .high, .definite,
                "Together these declarations allow unvalidated third-party code to be selected at launch via dyld environment variables.")
        }

        if entitlements.state == .parsed {
            if expectsAppSandbox && sandbox != "true" {
                add("sandbox.missing-or-false", ["com.apple.security.app-sandbox"], .medium,
                    sandbox == "unrecognized value" ? .needsReview : .definite,
                    "This app does not declare an enabled App Sandbox.")
            }
            for key in values.keys.sorted() {
                guard let entry = EntitlementRiskCatalog.entry(for: key), let value = values[key] else { continue }
                if key == "com.apple.security.app-sandbox" { continue }
                if key.hasPrefix(exceptionPrefix) && signature.hardenedRuntime == false { continue }
                if combo && (key == libraryKey || key == dyldKey) { continue }
                let active: Bool
                switch entry.riskyValue {
                case .trueValue: active = value.isTrue
                case .absentOrFalse: active = value.isFalse
                case .nonempty: active = value != .array([])
                case .present: active = true
                }
                guard active else { continue }
                if key == "com.apple.security.get-task-allow" {
                    if adHoc == true || buildIntent == .development {
                        add("debug.get-task-allow-development", [key], .low, .definite,
                            "Debugger attachment is expected for an ad-hoc or declared development build.")
                    } else if team != nil && adHoc == false && buildIntent == .release {
                        add("debug.get-task-allow-release", [key], .high, .needsReview,
                            "Debugger attachment on a declared team-signed release is likely a shipping mistake; certificate class is unverified.")
                    } else {
                        add("debug.get-task-allow-review", [key], .medium, .needsReview,
                            "Debugger attachment is declared, but release/development signing intent is unknown.")
                    }
                } else if key.hasPrefix("com.apple.private.") {
                    let platform = signature.platformBinary == true
                    add("private.entitlement", [key], platform ? .info : .medium, .needsReview,
                        "Private entitlement declared; Apple signing and OS honoring cannot be established from Code Directory flags.")
                } else if key.hasPrefix("com.apple.security.temporary-exception.") {
                    add("sandbox.temporary-exception", [key], sandbox == "true" ? .medium : .low,
                        .needsReview, "Declares \(key) with value \(describe(value)); review the access it opens in the app's sandbox.")
                } else {
                    add("entitlement.\(key)", [key], entry.severity,
                        signature.hardenedRuntime == nil && entry.category == "hardened runtime" ? .needsReview : .definite,
                        entry.why)
                }
            }
        }
        if flags == nil {
            findings = findings.map { finding in
                var revised = finding
                revised.confidence = .needsReview
                return revised
            }
        }
        return .init(architecture: architecture, sliceOffset: sliceOffset, signature: signature,
                     entitlements: entitlements, findings: findings,
                     unknownKeys: values.keys.filter { EntitlementRiskCatalog.entry(for: $0) == nil }.sorted())
    }

    private static func describe(_ value: DeclaredEntitlementValue) -> String {
        let text = String(describing: value).replacingOccurrences(of: "\n", with: " ")
        return String(text.prefix(240))
    }
}
