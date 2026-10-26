import Foundation

/// Only values admitted by the hostile-image loader and parser cross-check worker.
/// No persisted rows, functions, xrefs, CFG, attachment or authored edits cross this seam.
/// The UUID binds a response to one captured request; it is not an artifact digest.
struct RehydrationLoaderProducts: Sendable {
    var requestID: UUID
    var requestedSliceIndex: Int?
    var imageByteCount: Int
    var sliceOffset: UInt64
    var sliceSize: UInt64?
    var sections: [SectionSummary]
    var mappings: [FileAddressMapping]
    var preferredSegmentLayout: MachOPreferredSegmentLayout? = nil
    var codeDataRanges: [CodeDataRangeSummary] = []
    var relocations: [RelocationSummary] = []
    var identityEffectiveByteRanges: [IdentityEffectiveByteRangeAttestation] = []
    var machOMetadata: MachOLoadMetadata? = nil
    var objcClasses: [ObjCClass] = []
    var objcCategories: [ObjCCategory] = []
    var objcProtocols: [ObjCProtocol] = []
    var swiftTypes: [SwiftTypeDescriptor] = []
    var swiftConformances: [SwiftConformance] = []
    var objcSelectors: [UInt64: String] = [:]
    var constantCFStrings: [UInt64: String] = [:]
    var objcClassReferences: [UInt64: ObjCClassReferenceTarget] = [:]
    var loaderTruncations: [AnalysisDiagnosticsCollector.LoaderTruncation] = []
    var parserDisagreements: [ParserCrossCheckDisagreement] = []
    var parserCrossCheckSkip: ParserCrossCheckSkip? = nil
    var loaderFindings: [LoaderFinding] = []

    enum Failure: Error, Equatable { case mismatchedRequest, invalidAuthority, overLimit }
    static let maximumRecordCount = 1_000_000

    func validate(imageByteCount expectedCount: Int, requestedSliceIndex expectedSlice: Int?,
                  requestID expectedID: UUID) throws {
        guard requestID == expectedID, requestedSliceIndex == expectedSlice else {
            throw Failure.mismatchedRequest
        }
        try validate(imageByteCount: expectedCount)
    }

    /// Never trust decoder-synthesized Codable fields as physical-byte authority.
    /// Recompute mappings using the exact selected-slice extent and validate layout against it.
    func validate(imageByteCount expectedCount: Int) throws {
        guard imageByteCount == expectedCount, expectedCount >= 0,
              requestedSliceIndex.map({ $0 >= 0 }) ?? true,
              sliceOffset <= UInt64(expectedCount) else { throw Failure.invalidAuthority }
        let available = UInt64(expectedCount) - sliceOffset
        let length = sliceSize ?? available
        guard length <= available, let payloadLength = Int(exactly: length) else {
            throw Failure.invalidAuthority
        }
        var counts: [Int] = [sections.count, mappings.count, codeDataRanges.count, relocations.count]
        counts += [identityEffectiveByteRanges.count, objcClasses.count, objcCategories.count, objcProtocols.count]
        counts += [swiftTypes.count, swiftConformances.count, objcSelectors.count, constantCFStrings.count]
        counts += [objcClassReferences.count, loaderTruncations.count, parserDisagreements.count, loaderFindings.count]
        counts.append(preferredSegmentLayout?.records.count ?? 0)
        guard counts.allSatisfy({ $0 <= Self.maximumRecordCount }) else { throw Failure.overLimit }
        guard mappings == FileAddressMapping.verifiedMappings(from: sections, payloadLength: payloadLength) else {
            throw Failure.invalidAuthority
        }
        if let layout = preferredSegmentLayout {
            _ = try MachOPreferredSegmentLayout(records: layout.records, selectedSliceByteCount: length)
        }
    }
}
