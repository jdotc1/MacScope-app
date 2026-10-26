import Foundation

/// Caller-owned components of the analysis input key. The fingerprint builder does not know any of
/// them: the caller computes `knowledgeVersion` with `NavigatorKnowledgeVersion.digest` and the
/// overlay and override digests from the workspace it owns.
struct NavigatorInputKeyContext: Hashable, Codable, Sendable {
    var patchOverlayDigest: String
    var analyzerStamp: String
    var knowledgeVersion: String
    var structuralOverridesDigest: String

    init(patchOverlayDigest: String, analyzerStamp: String, knowledgeVersion: String, structuralOverridesDigest: String) {
        self.patchOverlayDigest = patchOverlayDigest
        self.analyzerStamp = analyzerStamp
        self.knowledgeVersion = knowledgeVersion
        self.structuralOverridesDigest = structuralOverridesDigest
    }
}

/// Content-addressed analysis input key:
/// `H(sliceSHA256 ‖ selectedSliceIndex ‖ patchOverlayDigest ‖ analyzerStamp ‖ knowledgeVersion ‖ structuralOverridesDigest)`.
/// Each component is written length-prefixed by `AnalysisFingerprintCanonicalWriter`, so no
/// concatenation of two components can collide with another split. Returns 64 lowercase hex digits.
enum NavigatorAnalysisInputKey {
    static let schemaVersion = 1

    static func inputKey(sliceSHA256: String, selectedSliceIndex: Int?, context: NavigatorInputKeyContext) -> String {
        var writer = AnalysisFingerprintCanonicalWriter()
        writer.field("kind", "navigatorAnalysisInputKey")
        writer.field("schemaVersion", schemaVersion)
        writer.field("sliceSHA256", sliceSHA256)
        writer.optionalField("selectedSliceIndex", selectedSliceIndex)
        writer.field("patchOverlayDigest", context.patchOverlayDigest)
        writer.field("analyzerStamp", context.analyzerStamp)
        writer.field("knowledgeVersion", context.knowledgeVersion)
        writer.field("structuralOverridesDigest", context.structuralOverridesDigest)
        return writer.digestHex()
    }
}
