import Foundation

/// Inclusive dotted-version range, compared numerically component by component. A bound applies
/// at its own precision: `6.3` as a maximum admits `6.3.1`, and `6.0` as a minimum admits `6.0.2`.
struct NavigatorVersionRange: Hashable, Codable, Sendable {
    var minimum: String
    var maximum: String

    /// nil when `version` (or a bound) is not a dotted list of decimal components.
    func contains(_ version: String) -> Bool? {
        guard let value = Self.components(version),
              let lower = Self.components(minimum),
              let upper = Self.components(maximum) else { return nil }
        return Self.compare(value, lower) >= 0 && Self.compare(value, upper) <= 0
    }

    var isWellFormed: Bool {
        guard let lower = Self.components(minimum), let upper = Self.components(maximum) else { return false }
        return Self.compare(lower, upper) <= 0
    }

    static func components(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }), let value = Int(part) else {
                return nil
            }
            values.append(value)
        }
        return values
    }

    /// Compares `value` with `bound` over the bound's components only, padding `value` with zeros.
    private static func compare(_ value: [Int], _ bound: [Int]) -> Int {
        for offset in bound.indices {
            let component = offset < value.count ? value[offset] : 0
            if component != bound[offset] { return component < bound[offset] ? -1 : 1 }
        }
        return 0
    }
}

/// Where a primitive or catalogue is valid. Every empty list (and a nil `swiftABI` or
/// `swiftTools`) means "any". Within a constrained dimension a key value outside the list puts the
/// key out of range; a key with no value for that dimension (no platforms, no swift tool record)
/// leaves the verdict undetermined, which callers treat like out of range.
struct NavigatorApplicability: Hashable, Codable, Sendable {
    enum Verdict: String, Hashable, Sendable {
        case inRange
        case outOfRange
        case undetermined
    }

    var archs: [String]
    var platforms: [String]
    var swiftABI: String?
    var linkerFlavors: [String]
    /// Swift tool versions (`LC_BUILD_VERSION` tool `swift`) the knowledge was generated for.
    var swiftTools: NavigatorVersionRange?

    static let any = NavigatorApplicability()

    init(
        archs: [String] = [],
        platforms: [String] = [],
        swiftABI: String? = nil,
        linkerFlavors: [String] = [],
        swiftTools: NavigatorVersionRange? = nil
    ) {
        self.archs = archs
        self.platforms = platforms
        self.swiftABI = swiftABI
        self.linkerFlavors = linkerFlavors
        self.swiftTools = swiftTools
    }

    func verdict(for key: NavigatorToolchainKey) -> Verdict {
        var undetermined = false
        if !archs.isEmpty, !archs.containsExactly(key.arch) { return .outOfRange }
        if let swiftABI, key.swiftABI != swiftABI { return .outOfRange }
        if !linkerFlavors.isEmpty, !linkerFlavors.containsExactly(key.linkerFlavor) { return .outOfRange }
        if !platforms.isEmpty {
            if key.platforms.isEmpty {
                undetermined = true
            } else if !key.platforms.contains(where: { platforms.containsExactly($0.name) }) {
                return .outOfRange
            }
        }
        if let swiftTools {
            let versions = key.tools.filter { $0.name == "swift" }.map(\.version)
            if versions.isEmpty {
                undetermined = true
            } else {
                for version in versions {
                    switch swiftTools.contains(version) {
                    case true?: continue
                    case false?: return .outOfRange
                    case nil: undetermined = true
                    }
                }
            }
        }
        return undetermined ? .undetermined : .inRange
    }

    func admits(_ key: NavigatorToolchainKey) -> Bool {
        verdict(for: key) == .inRange
    }
}

/// A versioned knowledge catalogue (signature tables, no-return lists, runtime seeds). Its
/// `{id, version}` enters the knowledge-version digest; `onOutOfRange` says what a consumer does
/// when a slice's toolchain key falls outside `applicability`.
struct NavigatorKnowledgeDescriptor: Hashable, Codable, Sendable {
    var id: String
    var version: String
    var applicability: NavigatorApplicability
    /// `abstain` | `downgrade` | `proceed`.
    var onOutOfRange: String

    init(id: String, version: String, applicability: NavigatorApplicability, onOutOfRange: String = "proceed") {
        self.id = id
        self.version = version
        self.applicability = applicability
        self.onOutOfRange = onOutOfRange
    }
}

struct NavigatorPrimitiveDescriptor: Hashable, Codable, Sendable {
    typealias Applicability = NavigatorApplicability

    var id: String
    var version: String
    /// `authoritative` | `derived` | `candidate` | `proven` — the contract status its facts carry
    /// (not `tier`: `NavigatorFact.tier` is an Int64 precedence).
    var producesStatus: String
    /// `cheap` | `bounded` | `expensive`.
    var costClass: String
    /// Predicate or gap names from the vocabulary.
    var inputs: [String]
    var outputs: [String]
    var applicability: Applicability
    /// `abstain` | `downgrade` | `proceed`.
    var onOutOfRange: String
    /// False for a primitive that is declared so the registry and digest can name it, but has no
    /// producer yet.
    var isImplemented: Bool

    init(
        id: String,
        version: String,
        producesStatus: String,
        costClass: String,
        inputs: [String],
        outputs: [String],
        applicability: Applicability,
        onOutOfRange: String,
        isImplemented: Bool = true
    ) {
        self.id = id
        self.version = version
        self.producesStatus = producesStatus
        self.costClass = costClass
        self.inputs = inputs
        self.outputs = outputs
        self.applicability = applicability
        self.onOutOfRange = onOutOfRange
        self.isImplemented = isImplemented
    }
}

/// Fixed list of navigator primitives and knowledge catalogues with cost and applicability.
struct NavigatorPrimitiveRegistry: Hashable, Sendable {
    static let costClasses = ["cheap", "bounded", "expensive"]
    static let outOfRangePolicies = ["abstain", "downgrade", "proceed"]
    /// Statuses a primitive may declare; `unknown` is a vocabulary status but not something a
    /// primitive produces.
    static let producibleStatuses = ["authoritative", "proven", "derived", "candidate"]

    let primitives: [NavigatorPrimitiveDescriptor]
    let catalogues: [NavigatorKnowledgeDescriptor]

    init(primitives: [NavigatorPrimitiveDescriptor], catalogues: [NavigatorKnowledgeDescriptor]) {
        self.primitives = primitives
        self.catalogues = catalogues
    }

    func lookup(id: String) -> NavigatorPrimitiveDescriptor? {
        primitives.first { $0.id == id }
    }

    func catalogue(id: String) -> NavigatorKnowledgeDescriptor? {
        catalogues.first { $0.id == id }
    }

    /// Primitives whose applicability admits `key`, in registry order.
    func applicable(to key: NavigatorToolchainKey) -> [NavigatorPrimitiveDescriptor] {
        primitives.filter { $0.applicability.admits(key) }
    }

    /// `proceed` when `descriptor` is in range for `key`; otherwise its declared `onOutOfRange`.
    func disposition(of descriptor: NavigatorPrimitiveDescriptor, for key: NavigatorToolchainKey) -> String {
        descriptor.applicability.admits(key) ? "proceed" : descriptor.onOutOfRange
    }

    /// `proceed` when `catalogue` is in range for `key`; otherwise its declared `onOutOfRange`.
    func disposition(of catalogue: NavigatorKnowledgeDescriptor, for key: NavigatorToolchainKey) -> String {
        catalogue.applicability.admits(key) ? "proceed" : catalogue.onOutOfRange
    }

    /// Reasons the registry disagrees with `NavigatorContractVocabulary` or with its own field
    /// domains; empty means valid. Every input and output must be a vocabulary predicate or gap.
    func validateAgainstVocabulary() -> [String] {
        var reasons: [String] = []
        var seen = Set<String>()
        for descriptor in primitives {
            let at = "primitive \(descriptor.id.isEmpty ? "<empty>" : descriptor.id)"
            if descriptor.id.isEmpty { reasons.append("\(at): empty id") }
            if descriptor.version.isEmpty { reasons.append("\(at): empty version") }
            if !seen.insert(descriptor.id).inserted { reasons.append("\(at): duplicate id") }
            if !NavigatorContractVocabulary.statuses.containsExactly(descriptor.producesStatus)
                || !Self.producibleStatuses.containsExactly(descriptor.producesStatus) {
                reasons.append("\(at): producesStatus \(descriptor.producesStatus) not a producible vocabulary status")
            }
            if !Self.costClasses.containsExactly(descriptor.costClass) {
                reasons.append("\(at): costClass \(descriptor.costClass) not cheap|bounded|expensive")
            }
            if !Self.outOfRangePolicies.containsExactly(descriptor.onOutOfRange) {
                reasons.append("\(at): onOutOfRange \(descriptor.onOutOfRange) not abstain|downgrade|proceed")
            }
            for term in descriptor.inputs where !Self.isVocabularyTerm(term) {
                reasons.append("\(at): input \(term) not a vocabulary predicate or gap")
            }
            for term in descriptor.outputs where !Self.isVocabularyTerm(term) {
                reasons.append("\(at): output \(term) not a vocabulary predicate or gap")
            }
            reasons += Self.applicabilityReasons(descriptor.applicability, at)
        }
        for catalogue in catalogues {
            let at = "catalogue \(catalogue.id.isEmpty ? "<empty>" : catalogue.id)"
            if catalogue.id.isEmpty { reasons.append("\(at): empty id") }
            if catalogue.version.isEmpty { reasons.append("\(at): empty version") }
            if !seen.insert(catalogue.id).inserted { reasons.append("\(at): duplicate id") }
            if !Self.outOfRangePolicies.containsExactly(catalogue.onOutOfRange) {
                reasons.append("\(at): onOutOfRange \(catalogue.onOutOfRange) not abstain|downgrade|proceed")
            }
            reasons += Self.applicabilityReasons(catalogue.applicability, at)
        }
        return reasons
    }

    static func isVocabularyTerm(_ term: String) -> Bool {
        NavigatorContractVocabulary.predicates[term] != nil || NavigatorContractVocabulary.gaps.containsExactly(term)
    }

    private static let architectureNames = ["arm64", "arm64e", "x86_64", "x86_64h", "other"]

    private static func applicabilityReasons(_ applicability: NavigatorApplicability, _ at: String) -> [String] {
        var reasons: [String] = []
        for arch in applicability.archs where !architectureNames.containsExactly(arch) {
            reasons.append("\(at): arch \(arch) not a slice architecture variant")
        }
        for flavor in applicability.linkerFlavors where !NavigatorToolchainKey.linkerFlavors.containsExactly(flavor) {
            reasons.append("\(at): linker flavor \(flavor) not chained|classic|none")
        }
        if let swiftABI = applicability.swiftABI, swiftABI != "5" {
            reasons.append("\(at): swiftABI \(swiftABI) not 5")
        }
        if let swiftTools = applicability.swiftTools, !swiftTools.isWellFormed {
            reasons.append("\(at): swiftTools \(swiftTools.minimum)–\(swiftTools.maximum) is not a dotted version range")
        }
        return reasons
    }
}

extension NavigatorPrimitiveRegistry {
    /// The rules with producers (`SwiftMetadataFactProjection`, the structural function-start
    /// proof and the call-target derivation), three rule ids declared ahead of their producers,
    /// and the three knowledge catalogues.
    static let standard = NavigatorPrimitiveRegistry(
        primitives: [
            NavigatorPrimitiveDescriptor(
                id: "macho.slice-identity",
                version: "1",
                producesStatus: "authoritative",
                costClass: "cheap",
                inputs: [],
                outputs: [],
                applicability: .any,
                onOutOfRange: "proceed",
                isImplemented: false
            ),
            NavigatorPrimitiveDescriptor(
                id: "macho.build-version",
                version: "1",
                producesStatus: "authoritative",
                costClass: "cheap",
                inputs: [],
                outputs: ["unsupportedToolchain"],
                applicability: .any,
                onOutOfRange: "proceed",
                isImplemented: false
            ),
            NavigatorPrimitiveDescriptor(
                id: SwiftMetadataFactProjection.rule,
                version: SwiftMetadataFactProjection.ruleVersion,
                producesStatus: "authoritative",
                costClass: "bounded",
                inputs: [],
                outputs: [
                    "hasName", "nominalKind", "isGeneric", "isPrivateOrLocal", "isImportedCType", "superclass",
                    "storedField", "enumCase", "isProtocol", "conformsTo",
                    "unknownContext", "unknownType", "unresolvedTypeReference", "unresolvedProtocol",
                    "malformedFieldDescriptor",
                ],
                applicability: NavigatorApplicability(swiftABI: "5"),
                onOutOfRange: "proceed"
            ),
            NavigatorPrimitiveDescriptor(
                id: "objc.class-parser",
                version: "1",
                producesStatus: "authoritative",
                costClass: "bounded",
                inputs: [],
                outputs: ["hasName", "superclass", "conformsTo"],
                applicability: .any,
                onOutOfRange: "proceed",
                isImplemented: false
            ),
            .functionStartStructuralProof,
            .functionStartCallTargetDerivation,
        ],
        catalogues: [
            CallSignatureCatalog.knowledge,
            NoReturnCatalog.knowledge,
            RuntimeSignatureSeeds.knowledge,
        ]
    )
}

extension NavigatorPrimitiveDescriptor {
    /// `proof.function-start-structural@1`: loader-only structural proof of a function start.
    static let functionStartStructuralProof = NavigatorPrimitiveDescriptor(
        id: FunctionStartStructuralProof.rule,
        version: FunctionStartStructuralProof.ruleVersion,
        producesStatus: "proven",
        costClass: "cheap",
        inputs: [],
        outputs: ["isFunctionStart", "boundaryUncertain"],
        applicability: NavigatorApplicability(
            archs: ["arm64", "arm64e"],
            platforms: ["macOS"],
            linkerFlavors: ["chained", "classic"]
        ),
        onOutOfRange: "abstain"
    )

    /// `derive.function-start-call-target@1`: derived function start for the target of a direct
    /// `bl` from a proven function start. Produces no certificate and never `proven`.
    static let functionStartCallTargetDerivation = NavigatorPrimitiveDescriptor(
        id: FunctionStartCallTargetDerivation.rule,
        version: FunctionStartCallTargetDerivation.ruleVersion,
        producesStatus: "derived",
        costClass: "bounded",
        inputs: ["isFunctionStart"],
        outputs: ["isFunctionStart", "boundaryUncertain"],
        applicability: NavigatorApplicability(
            archs: ["arm64", "arm64e"],
            platforms: ["macOS"],
            linkerFlavors: ["chained", "classic"]
        ),
        onOutOfRange: "abstain"
    )
}
