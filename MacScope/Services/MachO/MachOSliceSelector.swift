import Foundation

/// Pure, headless-testable selection logic for a fat/universal Mach-O's slices.
///
/// The fat parser enumerates every architecture slice into `[MachOUniversalSlice]`;
/// this type decides WHICH one the thin-Mach-O path should be handed. Selection is
/// kept out of the parser and the UI so both can share one validated rule and so the
/// rule can be unit-tested without any file I/O or SwiftUI.
///
/// Default rule (no explicit request): prefer the host architecture (arm64), then
/// fall back to x86_64, then to the first slice — so a universal binary always loads
/// even when it carries no arm64 slice. An explicit, in-range `requestedIndex` (the
/// user's pick from the open-time dialog) overrides the default.
enum MachOSliceSelector {
    /// The host architecture MacScope runs on. arm64 is preferred when a slice for it
    /// exists; exposed as a constant so the rule is explicit (and overridable in tests).
    static let hostCPUType: Int32 = MachOConstants.cpuTypeARM64

    enum SelectionError: Error, Equatable {
        /// The slice list was empty — a fat header with zero usable architectures.
        case noSlices
        /// `requestedIndex` did not name a slice in the list. The caller decides whether
        /// to surface this or silently fall back; the parser treats it as a hard error so
        /// a stale/garbage index never silently loads the wrong architecture.
        case requestedIndexOutOfRange(Int)
    }

    /// Returns the index of the slice to load.
    ///
    /// - Parameters:
    ///   - slices: every slice the fat header enumerated, in file order.
    ///   - requestedIndex: an explicit user pick, or nil for the default rule.
    ///   - hostCPUType: the host architecture to prefer (defaults to arm64).
    /// - Throws: `SelectionError` when the list is empty or an explicit request is out
    ///   of range.
    static func selectedIndex(
        in slices: [MachOUniversalSlice],
        requestedIndex: Int? = nil,
        hostCPUType: Int32 = MachOSliceSelector.hostCPUType
    ) throws -> Int {
        guard !slices.isEmpty else {
            throw SelectionError.noSlices
        }

        if let requestedIndex {
            guard slices.indices.contains(requestedIndex) else {
                throw SelectionError.requestedIndexOutOfRange(requestedIndex)
            }
            return requestedIndex
        }

        if let hostSlice = slices.first(where: { $0.cpuType == hostCPUType }) {
            return hostSlice.index
        }
        if let x86Slice = slices.first(where: { $0.cpuType == MachOConstants.cpuTypeX86_64 }) {
            return x86Slice.index
        }
        return slices[0].index
    }

    /// Convenience returning the selected slice itself (not just its index).
    static func selectedSlice(
        in slices: [MachOUniversalSlice],
        requestedIndex: Int? = nil,
        hostCPUType: Int32 = MachOSliceSelector.hostCPUType
    ) throws -> MachOUniversalSlice {
        let index = try selectedIndex(in: slices, requestedIndex: requestedIndex, hostCPUType: hostCPUType)
        // `index` is a slice's own `.index` field, which equals its array position for a
        // well-formed table; resolve by matching the field, falling back to the position.
        if let slice = slices.first(where: { $0.index == index }) {
            return slice
        }
        guard slices.indices.contains(index) else {
            throw SelectionError.requestedIndexOutOfRange(index)
        }
        return slices[index]
    }
}
