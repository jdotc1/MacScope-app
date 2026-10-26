import CryptoKit
import Foundation

extension AnalysisEngine {
    /// Largest selected slice the independent engines re-parse (decision D4). Larger slices are
    /// not handed to the engines; they get a single "cross-check skipped: size" diagnostic.
    static let maximumParserCrossCheckBytes = 64 * 1_024 * 1_024

    /// Re-parses the exact selected-slice bytes with the injected engines and compares them with
    /// the loader. Thin Mach-O slices and PE images only; everything else returns no rows.
    /// dyld-shared-cache images are skipped silently, oversized slices with one skip row, and an
    /// engine verdict is reused for every later analysis of the same slice digest. The result is
    /// diagnostics-only: the only error this throws is cancellation.
    func parserCrossCheckOutcome(
        for loaded: LoadedBinary,
        cancellation: AnalysisCancellationToken
    ) throws -> ParserCrossCheckOutcome {
        guard let parserCrossCheck else { return .notChecked }
        try cancellation.check()
        guard !loaded.isDyldSharedCacheProjection,
              let range = exactSliceRange(of: loaded), !range.isEmpty else {
            return .notChecked
        }
        // Classify from the header alone so an oversized slice is never copied.
        let header = Data(loaded.bytes[range.lowerBound ..< min(range.upperBound, range.lowerBound + 32)])
        guard let format = ParserCrossCheckFormat.classify(sliceBytes: header),
              !ParserCrossCheckFormat.isDyldSharedCacheImage(machHeaderPrefix: header) else {
            return .notChecked
        }
        guard range.count <= parserCrossCheckByteLimit else {
            let anchor = loaded.sections.map(\.address).min() ?? 0
            return ParserCrossCheckOutcome(skip: ParserCrossCheckSkip(
                address: anchor,
                reason: .size(byteCount: range.count, limit: parserCrossCheckByteLimit)
            ))
        }
        let bytes = loaded.bytes.subdata(in: range)
        let key = ParserCrossCheckVerdictCache.Key(
            sha256: Self.parserCrossCheckDigest(of: bytes, loaded: loaded),
            byteCount: bytes.count,
            format: format
        )
        let reports = parserCrossCheckCache.reports(for: key) {
            parserCrossCheck.reports(forSliceBytes: bytes, format: format)
        }
        try cancellation.check()
        return ParserCrossCheckOutcome(
            disagreements: ParserCrossCheckComparator.disagreements(loaded: loaded, format: format, reports: reports)
        )
    }

    /// The selected-slice SHA-256: the loader's verified Mach-O artifact identity when it covers
    /// exactly these bytes, otherwise computed here (PE images carry no artifact identity).
    static func parserCrossCheckDigest(of bytes: Data, loaded: LoadedBinary) -> String {
        if loaded.artifactIntegrityState == .verified,
           let identity = loaded.artifactIdentity,
           identity.selectedSliceByteCount == UInt64(bytes.count) {
            return identity.selectedSliceSHA256
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
