import Foundation

/// Static type-grounded vocabulary only; explicitly not objc_msgSend dispatch
/// resolution. Future production pack must be qualified to exact SDK/toolchain.
public struct VerifiedAPICallFact: Sendable {
    public let declaringClass: String
    public let selector: String
    public let isClassMethod: Bool
    public let typeDeclarationOrigin: String

    public init(declaringClass: String, selector: String,
                isClassMethod: Bool, typeDeclarationOrigin: String) {
        self.declaringClass = declaringClass
        self.selector = selector
        self.isClassMethod = isClassMethod
        self.typeDeclarationOrigin = typeDeclarationOrigin
    }
}

public enum AppKitAPIHint: String, Sendable {
    case targetMutation, actionMutation, actionRouting
}

public enum StaticAppKitRuleCatalog {
    /// Requires a verified declaring-class *and* selector, not selector text
    /// alone. This method adds a label, never a concrete target/IMP.
    public static func hint(for fact: VerifiedAPICallFact) -> AppKitAPIHint? {
        guard !fact.isClassMethod && !fact.typeDeclarationOrigin.isEmpty else { return nil }
        switch (fact.declaringClass, fact.selector) {
        case ("NSControl", "setTarget:"), ("NSMenuItem", "setTarget:"):
            return .targetMutation
        case ("NSControl", "setAction:"), ("NSMenuItem", "setAction:"):
            return .actionMutation
        case ("NSApplication", "sendAction:to:from:"):
            return .actionRouting
        default: return nil
        }
    }
}
