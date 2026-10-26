import Foundation

/// Checked construction of a half-open virtual-address span from parser-supplied
/// `address`/`size` fields.
///
/// Section spans, array bounds, and instruction addresses in an image are all
/// attacker-controlled: a crafted Mach-O/ELF/PE can declare `address + size`
/// past `UInt64.max`. Trapping `+` aborts the whole process on such input, and
/// wrapping `&+` is worse — it silently converts a malformed high address into a
/// plausible low one, which can misattribute bytes to the wrong image or address
/// domain. Both violate the app's correctness-over-coverage contract (a missing
/// result must be preferred to a wrong one).
///
/// This helper is the single fail-closed seam: it returns `nil` for a zero-size,
/// overflowing, or degenerate span so callers either emit one stable diagnostic
/// or omit the unusable region, never trap and never fabricate a wrapped range.
extension Range where Bound == UInt64 {
    /// A validated half-open span `start..<(start + size)`, or `nil` when the
    /// span is empty (`size == 0`) or `start + size` overflows `UInt64`.
    static func validated(start: UInt64, size: UInt64) -> Range<UInt64>? {
        guard size > 0 else { return nil }
        let (end, overflow) = start.addingReportingOverflow(size)
        guard !overflow, end > start else { return nil }
        return start..<end
    }
}

extension UInt64 {
    /// True when `self + step == other` with no overflow. Instruction-adjacency
    /// checks in the lift/print path compute `address + 4`; at the very top of
    /// the address space that traps, and a wrapped low neighbor must never be
    /// treated as "the next instruction". An overflowing successor is therefore
    /// not adjacent to anything — fail closed rather than trap or wrap.
    func isContiguous(to other: UInt64, step: UInt64 = 4) -> Bool {
        let (next, overflow) = addingReportingOverflow(step)
        return !overflow && next == other
    }

    /// The address `step` bytes after `self`, or `nil` when that overflows —
    /// the honest "end address unknown" answer for a final instruction sitting
    /// at the top of the address space.
    func addressAfter(step: UInt64 = 4) -> UInt64? {
        let (next, overflow) = addingReportingOverflow(step)
        return overflow ? nil : next
    }
}
