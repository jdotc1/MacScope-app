import Foundation

/// DP04 D1: one function's usage of a root (a callee formal when transferred across a
/// direct call edge). Offsets are relative to the root as that function sees it.
struct MacIRStructUsageSummary: Hashable, Sendable {
    let observations: [StructLayoutCandidate.Observation]
    let unresolvedAccessAddresses: [UInt64]

    /// The summary as the caller sees it when it passes `root + offset` to `target`.
    func shifted(by offset: Int64, via target: String) -> Self {
        Self(observations: observations.map {
            StructLayoutCandidate.Observation(offset: $0.offset &+ offset, byteWidth: $0.byteWidth, role: $0.role,
                                              extensionKind: $0.extensionKind, carrier: $0.carrier,
                                              sourceAddress: $0.sourceAddress, viaCalls: [target] + $0.viaCalls)
        }, unresolvedAccessAddresses: unresolvedAccessAddresses)
    }
}
