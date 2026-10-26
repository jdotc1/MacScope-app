import Foundation

public struct AnalysisEnvelope: Sendable {
    public let imageKey: String
    public let document: JSONValue
    public let frontier: [JSONValue]
    public let facts: [JSONValue]
    public let functions: [JSONValue]
    public let wholeApplicationRecovered: Bool

    public static func load(_ data: Data, expectedImage: String, limits: RecoveryLimits = RecoveryLimits()) throws -> AnalysisEnvelope {
        try limits.validate()
        guard data.count <= limits.bytes else { throw RecoveryError.budget("analysis transport bytes") }
        let document = try JSONDecoder().decode(JSONValue.self, from: data)
        try document.validate(limits: limits)
        guard document["schema"]?.string == "swiftrecover-analysis/2" else { throw RecoveryError.unsupported("analysis schema") }
        guard let image = document["image_key"]?.string, image == expectedImage else { throw RecoveryError.invalid("analysis image mismatch") }
        try ImageKey.validate(image)
        guard let frontier = document["frontier"]?.array,
              let facts = document["facts"]?.array,
              let functions = document["functions"]?.array,
              let completion = document["completion"],
              completion["analysis_finished"]?.bool == true,
              let complete = completion["whole_application_source_recovered"]?.bool else {
            throw RecoveryError.invalid("analysis is missing explicit completion/population fields")
        }
        for fact in facts {
            guard fact["image"]?.string == image,
                  let authority = fact["authority"]?.string,
                  Authority(rawValue: authority) != nil else { throw RecoveryError.invalid("unscoped or untyped fact") }
        }
        // This consumer version cannot admit an unrestricted full-recovery claim.
        guard !complete else { throw RecoveryError.unsupported("whole-application recovery claim has no qualified contract") }
        return AnalysisEnvelope(imageKey: image, document: document, frontier: frontier, facts: facts,
                                functions: functions, wholeApplicationRecovered: complete)
    }
}
