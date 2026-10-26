import Foundation

/// Digest of every piece of versioned knowledge an analysis depends on: the registry's primitive
/// ids and versions, the knowledge catalogues' ids and versions, the engine identity and the
/// decoder version. Lists are sorted by Unicode scalars before hashing, so the digest does not
/// depend on registry or argument order. Returns 64 lowercase hex digits.
enum NavigatorKnowledgeVersion {
    static let schemaVersion = 1

    static func digest(
        registry: NavigatorPrimitiveRegistry,
        catalogues: [NavigatorKnowledgeDescriptor],
        engineIdentity: String,
        decoderVersion: String
    ) -> String {
        func ordered(_ pairs: [(id: String, version: String)]) -> [(id: String, version: String)] {
            pairs.sorted {
                if Array($0.id.unicodeScalars) != Array($1.id.unicodeScalars) {
                    return $0.id.unicodeScalars.lexicographicallyPrecedes($1.id.unicodeScalars)
                }
                return $0.version.unicodeScalars.lexicographicallyPrecedes($1.version.unicodeScalars)
            }
        }
        let rules = ordered(registry.primitives.map { (id: $0.id, version: $0.version) })
        let knowledge = ordered(catalogues.map { (id: $0.id, version: $0.version) })
        var writer = AnalysisFingerprintCanonicalWriter()
        writer.field("kind", "navigatorKnowledgeVersion")
        writer.field("schemaVersion", schemaVersion)
        writer.field("ruleCount", rules.count)
        for rule in rules {
            writer.field("ruleID", rule.id)
            writer.field("ruleVersion", rule.version)
        }
        writer.field("catalogueCount", knowledge.count)
        for catalogue in knowledge {
            writer.field("catalogueID", catalogue.id)
            writer.field("catalogueVersion", catalogue.version)
        }
        writer.field("engineIdentity", engineIdentity)
        writer.field("decoderVersion", decoderVersion)
        return writer.digestHex()
    }

    /// The digest over `registry` and its own catalogue list.
    static func digest(registry: NavigatorPrimitiveRegistry, engineIdentity: String, decoderVersion: String) -> String {
        digest(registry: registry, catalogues: registry.catalogues, engineIdentity: engineIdentity, decoderVersion: decoderVersion)
    }
}
