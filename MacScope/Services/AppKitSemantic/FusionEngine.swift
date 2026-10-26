import Foundation

public enum AppKitFusionEngineOutcome: Sendable {
    case claims([AppKitSemanticClaim])
    case refused(NibRefusal)
}

/// Pure reconciler: input already has MacScope-selected image identities and
/// nibkit resources admitted by a real worker. This does NOT infer runtime
/// Objective-C dispatch, subclass receivers or responder-chain resolution.
public struct AppKitFusionEngine: Sendable {
    public init() {}

    /// Use evaluate to distinguish a refusal from a successful result with no claims.
    public func reconcile(
        document: NibDecodedDocument,
        methodFacts: [ObjCMethodFact],
        allowedImageKeys: Set<AppKitImageKey>
    ) -> [AppKitSemanticClaim] {
        switch evaluate(document: document, methodFacts: methodFacts, allowedImageKeys: allowedImageKeys) { case .claims(let claims): return claims; case .refused: return [] }
    }

    public func evaluate(
        document: NibDecodedDocument,
        methodFacts: [ObjCMethodFact],
        allowedImageKeys: Set<AppKitImageKey>
    ) -> AppKitFusionEngineOutcome {
        guard document.resource.hasValidIdentity else {
            return .refused(.init(inputLabel: "<document>", reason: .invalidResourceIdentity,
                                  detail: "resource identity not admitted"))
        }
        guard document.donorRevision == NibKitRevision.reviewed else {
            return .refused(.init(inputLabel: "<document>", reason: .unsupportedDonorRevision,
                                  detail: "pinned donor identity did not match"))
        }
        guard methodFacts.count <= 65_536 else {
            return .refused(.init(inputLabel: "<document>", reason: .tooManyRecords,
                                  detail: "method fact cap 65,536 exceeded"))
        }
        guard document.outlets.count + document.actions.count + document.runtimeAttributes.count +
                  document.customClasses.count + document.navigation.count <= 65_536 else {
            return .refused(.init(inputLabel: "<document>", reason: .tooManyRecords,
                                  detail: "document record cap 65,536 exceeded"))
        }
        let methodIndex = Dictionary(grouping: methodFacts.filter {
            $0.image.hasValidIdentity && allowedImageKeys.contains($0.image) &&
            $0.image.bundleGeneration == document.resource.bundleGeneration && !$0.isClassMethod
        }, by: { MethodKey(owner: $0.ownerClass, selector: $0.selector) })
        var claims: [AppKitSemanticClaim] = []

        for (offset, outlet) in document.outlets.enumerated() {
            claims.append(make(document, originKind: "outlet", ordinal: offset,
                               key: outlet.name, source: outlet.source,
                               destination: outlet.destination, status: .observed,
                               event: outlet.event))
        }

        for (offset, entry) in document.actions.enumerated() {
            guard entry.kind == "action" else {
                // This branch is critical: nibkit puts `binding` and `help`
                // in its JSON `actions` array. Preserve, never resolve.
                claims.append(make(document, originKind: "connector." + entry.kind,
                                   ordinal: offset, key: entry.name, source: entry.source,
                                   destination: entry.destination, status: .observed,
                                   event: entry.event))
                continue
            }

            let matches = exactMatches(entry, document: document,
                                       methods: methodIndex, allowed: allowedImageKeys)
            let refusal = refusalFor(entry, document: document,
                                     allowed: allowedImageKeys, matches: matches)
            if let refusal {
                claims.append(make(document, originKind: "action", ordinal: offset,
                                   key: entry.name, source: entry.source,
                                   destination: entry.destination, status: .unresolved,
                                   candidates: matches.count, refusal: refusal,
                                   event: entry.event))
            } else if let method = matches.first {
                if method.ownerKind == .categoryDefinition {
                    claims.append(make(document, originKind: "action", ordinal: offset,
                                       key: entry.name, source: entry.source,
                                       destination: entry.destination, status: .unresolved,
                                       candidates: 1, refusal: "category-owned-method",
                                       event: entry.event))
                } else if let imp = method.implementationVMAddress, imp != 0 {
                    claims.append(make(document, originKind: "action", ordinal: offset,
                                       key: entry.name, source: entry.source,
                                       destination: entry.destination, status: .corroboratedStatic,
                                       target: .init(image: method.image, vmAddress: imp),
                                       candidates: 1, withMethodEvidence: true,
                                       event: entry.event))
                } else {
                    claims.append(make(document, originKind: "action", ordinal: offset,
                                       key: entry.name, source: entry.source,
                                       destination: entry.destination, status: .candidate,
                                       candidates: 1, withMethodEvidence: true,
                                       event: entry.event))
                }
            }
        }

        for (offset, attr) in document.runtimeAttributes.enumerated() {
            claims.append(make(document, originKind: "runtimeAttribute", ordinal: offset,
                               key: attr.keyPath, source: attr.object,
                               destination: "", status: .observed,
                               observedValue: attr.value))
        }
        for (offset, hint) in document.customClasses.enumerated() {
            claims.append(make(document, originKind: "customClassHint", ordinal: offset,
                               key: hint.class, source: hint.base,
                               destination: hint.sceneID ?? "", status: .observed,
                               observedValue: hint.module))
        }
        for (offset, hint) in document.navigation.enumerated() {
            // Explicitly a donor *hint*, not a proven AppKit storyboard edge.
            claims.append(make(document, originKind: "navigationHint", ordinal: offset,
                               key: hint.identifier ?? hint.selector ?? hint.kind,
                               source: hint.sourceClass,
                               destination: hint.destinationClass ?? hint.destinationID ?? "",
                               status: .observed))
        }
        return .claims(claims)
    }

    private struct MethodKey: Hashable {
        let owner: String
        let selector: String
    }

    private func exactMatches(_ c: NibConnection, document: NibDecodedDocument,
                              methods: [MethodKey: [ObjCMethodFact]], allowed: Set<AppKitImageKey>) -> [ObjCMethodFact] {
        guard validName(c.name), validName(c.destination), !isDynamicLabel(c.destination) else {
            return []
        }
        return methods[MethodKey(owner: c.destination, selector: c.name)] ?? []
    }

    private func refusalFor(_ c: NibConnection, document: NibDecodedDocument,
                            allowed: Set<AppKitImageKey>, matches: [ObjCMethodFact]) -> String? {
        guard validName(c.name) else { return "missing-or-invalid-selector" }
        guard validName(c.destination) else { return "missing-or-invalid-destination" }
        guard !isDynamicLabel(c.destination) else { return "dynamic-or-proxy-target" }
        guard document.resource.hasValidIdentity else { return "invalid-resource-identity" }
        guard allowed.contains(where: { $0.bundleGeneration == document.resource.bundleGeneration }) else {
            return "no-matching-image-generation"
        }
        switch matches.count {
        case 0: return "no-exact-instance-method"
        case 1: return nil
        default: return "ambiguous-method-owner-or-image"
        }
    }

    private func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 1024 &&
        name.trimmingCharacters(in: .whitespacesAndNewlines) == name &&
        name.unicodeScalars.allSatisfy {
            // Do not accept terminal control bytes/Unicode control scalars
            // as identifiers to use in equality-based code navigation.
            !$0.properties.isDefaultIgnorableCodePoint &&
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private func isDynamicLabel(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("(proxy)") || lower.contains("placeholder") ||
               lower == "first responder" || lower == "firstresponder" ||
               lower == "nsfirstresponder" || lower == "file's owner" ||
               lower == "nsapplication"
    }

    private func make(_ document: NibDecodedDocument, originKind: String, ordinal: Int,
                      key: String, source: String, destination: String,
                      status: AppKitClaimStatus,
                      target: CandidateImplementation? = nil, candidates: Int = 0,
                      refusal: String? = nil, withMethodEvidence: Bool = false,
                      event: String? = nil, observedValue: String? = nil) -> AppKitSemanticClaim {
        let resource = document.resource
        // Injective length-prefix encoding; Swift Hasher is randomized and
        // would not be a stable source-evidence identifier across launches.
        func component(_ s: String) -> String { "\(s.utf8.count):\(s)" }
        let keyParts = ["appkit-v1", component(resource.bundleID),
                        component(resource.bundleGeneration),
                        component(resource.relativePath), component(resource.contentSHA256),
                        component(originKind), String(ordinal)]
        let origins = withMethodEvidence
            ? ["nibkit-resource", "macscope-objc-metadata"]
            : ["nibkit-resource"]
        return .init(claimID: keyParts.joined(separator: "/"), resource: resource,
                     donorRevision: document.donorRevision, kind: originKind,
                     ordinal: ordinal, selectorOrKey: key,
                     sourceLabel: source, destinationLabel: destination,
                     eventLabel: event, observedValue: observedValue,
                     status: status, candidateImplementation: target,
                     candidateCount: candidates, refusalReason: refusal,
                     evidenceOrigins: origins)
    }
}
