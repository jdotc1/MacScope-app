import Foundation

/// Presentation of loader observations, never a trust or whole-container signing verdict.
struct MachOSignatureCoveragePresentation: Equatable {
    let source: String
    let coverage: String
    let signature: String

    // Compatibility arguments are retained for existing callers, but neither a request index
    // nor attachment byte extent establishes the original container kind.
    init(imageName: String, architecture: String, selectedSliceIndex: Int?,
         hasOtherContainerBytes: Bool?, hasCodeSignature: Bool,
         machOSelectedSliceFact: MachOSelectedSliceFact? = nil) {
        let slice = machOSelectedSliceFact?.displayLabel ?? "slice unknown"
        source = "\(imageName) · \(architecture) · \(slice)"
        switch machOSelectedSliceFact?.containerKind {
        case .universal:
            if machOSelectedSliceFact?.sliceCount == 1 {
                coverage = "The loaded slice of a single-slice universal Mach-O was examined. Embedded metadata does not establish signature validity or trust."
            } else {
                coverage = "Partial container coverage: only the loaded slice was examined. Other slices are unexamined and may have different signatures or entitlements."
            }
        case .thin:
            coverage = "The loaded thin Mach-O slice was examined. Embedded metadata does not establish signature validity or trust."
        case nil:
            coverage = "Only the loaded slice was examined. Container coverage is unavailable; any other slices are unexamined and may differ."
        }
        signature = hasCodeSignature
            ? "Embedded signature metadata is present in this slice."
            : "No embedded signature metadata was recovered for this slice."
    }
}
