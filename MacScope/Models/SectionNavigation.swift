import Foundation

/// Pure, view-free navigation + section-operation helpers for the staple
/// "Next Code / Next Data / Next Unexplored" jumps, "Truncate / Select Procedure"
/// range logic, and the bulk "Transform Section to Strings" scan.
///
/// Everything here operates on plain value snapshots (sorted addresses, function
/// ranges, raw section bytes) so it is fully unit-testable without a `WorkspaceStore`,
/// a window, or any binary on disk. The store wires these to the live snapshot; the
/// scripting API and menu commands wire them to the user.
enum AddressNavigation {
    /// The next *code* address strictly after `current`: the first decoded
    /// instruction whose address is greater than `current` and which the user has
    /// NOT marked as data. `instructionAddresses` must be sorted ascending and
    /// de-duplicated (the snapshot's `instructions` already are). Returns nil at the
    /// end of the listing (no further code).
    ///
    /// - Parameters:
    ///   - current: the address the cursor sits on (nil = before the first row, so the
    ///     first code address is returned).
    ///   - instructionAddresses: ascending instruction addresses.
    ///   - dataAddresses: addresses the user marked as data (excluded from "code").
    static func nextCode(
        after current: UInt64?,
        instructionAddresses: [UInt64],
        dataAddresses: Set<UInt64>
    ) -> UInt64? {
        firstAddress(after: current, in: instructionAddresses) { !dataAddresses.contains($0) }
    }

    /// The next *data* address strictly after `current`: the lowest address greater
    /// than `current` that is in `dataAddresses` (user mark-as-data / a data shape /
    /// a recovered string literal). `dataAddresses` need not be sorted. Returns nil
    /// when there is no further data address.
    static func nextData(
        after current: UInt64?,
        dataAddresses: Set<UInt64>
    ) -> UInt64? {
        let floor = current ?? UInt64(0)
        // When `current` is nil we want the very first data address (>= 0); when it
        // is set we want strictly greater. Fold both into one predicate.
        return dataAddresses
            .filter { current == nil ? true : $0 > floor }
            .min()
    }

    /// The next start address strictly greater than `current` (or the lowest start when
    /// `current` is nil), drawn from `starts` (procedure or section start addresses; need
    /// not be sorted or de-duplicated). The pure model behind Next Procedure / Next Section.
    /// Returns nil when there is no later start.
    static func nextStart(after current: UInt64?, in starts: [UInt64]) -> UInt64? {
        starts.filter { start in current.map { start > $0 } ?? true }.min()
    }

    /// The previous start address strictly less than `current` (or the highest start when
    /// `current` is nil), drawn from `starts`. The pure model behind Previous Procedure /
    /// Previous Section. Returns nil when there is no earlier start.
    static func previousStart(before current: UInt64?, in starts: [UInt64]) -> UInt64? {
        starts.filter { start in current.map { start < $0 } ?? true }.max()
    }

    /// The next *unexplored* address strictly after `current`: the start of the next
    /// gap — a loaded address that has neither a decoded instruction nor a data mark.
    /// Computed by walking the executable section spans and returning the first
    /// address `> current` that is not covered by any instruction's byte extent and
    /// is not data-marked.
    ///
    /// `instructionExtents` are `(address, byteWidth)` pairs (ascending by address);
    /// an instruction covers `[address, address + width)`. `coverageSpans` are the
    /// loaded regions to search within (typically the executable sections). Returns
    /// nil when every remaining loaded address is already explored.
    static func nextUnexplored(
        after current: UInt64?,
        instructionExtents: [(address: UInt64, width: UInt64)],
        dataAddresses: Set<UInt64>,
        coverageSpans: [(start: UInt64, end: UInt64)]
    ) -> UInt64? {
        // Normalize the search floor: strictly after `current`, or the lowest span
        // start when nothing is selected.
        let spans = coverageSpans
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !spans.isEmpty else { return nil }

        // A set of every address covered by a decoded instruction's bytes. Bounded by
        // the instruction count × width, so this is cheap for real listings.
        var covered = Set<UInt64>()
        for extent in instructionExtents {
            let width = max(extent.width, 1)
            // Overflow-safe: stop expanding if the extent would wrap past UInt64.max.
            var offset: UInt64 = 0
            while offset < width {
                let address = extent.address &+ offset
                if address < extent.address { break } // wrapped
                covered.insert(address)
                offset &+= 1
            }
        }

        for span in spans {
            // The first candidate in this span: the span start, or one past `current`
            // when `current` falls inside/before this span.
            var candidate = span.start
            if let current, current >= span.start {
                // Strictly after current.
                guard current &+ 1 > current else { continue } // current == UInt64.max
                candidate = max(span.start, current &+ 1)
            }
            while candidate < span.end {
                if !covered.contains(candidate) && !dataAddresses.contains(candidate) {
                    return candidate
                }
                guard candidate &+ 1 > candidate else { break } // wrap guard
                candidate &+= 1
            }
        }
        return nil
    }

    /// The lowest address in `addresses` satisfying `predicate` and strictly greater
    /// than `current` (or any address when `current` is nil). `addresses` MUST be
    /// sorted ascending; the scan stops at the first match.
    private static func firstAddress(
        after current: UInt64?,
        in addresses: [UInt64],
        where predicate: (UInt64) -> Bool
    ) -> UInt64? {
        for address in addresses {
            if let current, address <= current { continue }
            if predicate(address) { return address }
        }
        return nil
    }
}

/// Steps through the cross-references whose target is a fixed anchor address — the pure
/// model behind Next XREF / Previous XREF. Cycles through the referrer ("from") addresses
/// in stable ascending order, wrapping at the ends, keeping the anchor fixed so stepping
/// onto a referrer doesn't restart the walk.
struct XRefStepCursor: Equatable {
    /// The address whose referrers we cycle through.
    let anchor: UInt64
    /// The distinct referrer addresses targeting `anchor`, ascending.
    let froms: [UInt64]
    /// Index of the current referrer, or nil before the first step.
    private(set) var index: Int?

    init(anchor: UInt64, froms: [UInt64]) {
        self.anchor = anchor
        self.froms = Array(Set(froms)).sorted()
        self.index = nil
    }

    var isEmpty: Bool { froms.isEmpty }

    var current: UInt64? {
        guard let index, froms.indices.contains(index) else { return nil }
        return froms[index]
    }

    /// True when `address` belongs to this cursor's orbit (the anchor or one of its
    /// referrers), so Next-XREF after navigating to a referrer keeps cycling the same set.
    func covers(_ address: UInt64) -> Bool { address == anchor || froms.contains(address) }

    @discardableResult
    mutating func next() -> UInt64? {
        guard !froms.isEmpty else { index = nil; return nil }
        index = index.map { ($0 + 1) % froms.count } ?? 0
        return current
    }

    @discardableResult
    mutating func previous() -> UInt64? {
        guard !froms.isEmpty else { index = nil; return nil }
        index = index.map { ($0 - 1 + froms.count) % froms.count } ?? (froms.count - 1)
        return current
    }
}

/// Pure range logic for the "Truncate Procedure" and "Select Procedure" commands.
enum ProcedureRange {
    /// A half-open `[start, end)` address range.
    struct Range: Equatable {
        var start: UInt64
        var end: UInt64
    }

    /// The enclosing function for `address`: the function whose `[start, end)` range
    /// contains it, falling back to the greatest function starting at or before the
    /// address (mirrors `WorkspaceStore.enclosingFunction`). Returns nil when no
    /// function precedes the address at all.
    static func enclosingFunction(
        for address: UInt64,
        functions: [FunctionSummary]
    ) -> FunctionSummary? {
        functions.first { function in
            if function.endAddress > function.startAddress {
                return address >= function.startAddress && address < function.endAddress
            }
            return address == function.startAddress
        } ?? functions
            .filter { $0.startAddress <= address }
            .max { $0.startAddress < $1.startAddress }
    }

    /// The whole-range selection for "Select Procedure": the enclosing function's
    /// `[start, end)`. Returns nil when no function encloses the address.
    static func selectRange(
        for address: UInt64,
        functions: [FunctionSummary]
    ) -> Range? {
        guard let function = enclosingFunction(for: address, functions: functions) else { return nil }
        let end = max(function.endAddress, function.startAddress)
        return Range(start: function.startAddress, end: end)
    }

    /// The new function bounds for "Truncate Procedure": set the enclosing function's
    /// end to `truncationAddress` (the byte AFTER the last instruction to keep is the
    /// caller's responsibility — here `truncationAddress` is treated as the new
    /// exclusive end). Returns nil when:
    ///   - no function encloses the address, or
    ///   - the truncation point is at or before the function start (a degenerate /
    ///     empty function), or
    ///   - the truncation point is at or beyond the current end (nothing to truncate).
    ///
    /// On success returns the function's start and the validated new end so the caller
    /// can record a bounding override and re-drive discovery for just that function.
    static func truncatedBounds(
        at truncationAddress: UInt64,
        functions: [FunctionSummary]
    ) -> Range? {
        guard let function = enclosingFunction(for: truncationAddress, functions: functions) else { return nil }
        guard truncationAddress > function.startAddress else { return nil }
        let currentEnd = max(function.endAddress, function.startAddress)
        guard truncationAddress < currentEnd else { return nil }
        return Range(start: function.startAddress, end: truncationAddress)
    }
}

/// A contiguous run of printable bytes terminated by a NUL, found by scanning raw
/// section bytes. `address` is the virtual address of the first byte; `value` is the
/// decoded UTF-8 string; `byteLength` is the printable length EXCLUDING the NUL.
struct ScannedStringSpan: Equatable {
    var address: UInt64
    var value: String
    var byteLength: Int
}

/// Pure "Transform Section to Strings" scanner: walk a section's bytes for
/// NUL-terminated runs of printable C-string characters and emit one span per run.
///
/// The acceptance rule mirrors the Mach-O cstring recovery (`isRecoverableCStringBytes`
/// + a UTF-8 round-trip + a non-whitespace check) so a section transform agrees with
/// the import-time literal recovery. Untrusted-byte safe: a missing terminator at the
/// section end is dropped (not emitted), and the caller-provided `maximumCount` /
/// length cap bound the work on a hostile section.
enum SectionStringScanner {
    /// Default minimum printable length. A 1-character "string" is almost always
    /// noise (alignment padding, a stray byte); the transform uses a small floor.
    static let defaultMinimumLength = 1
    /// Upper bound on a single run's length, matching the importer's literal cap, so a
    /// pathological un-terminated-looking region cannot balloon one span.
    static let maximumLength = 4096
    /// Upper bound on the number of spans emitted from one section.
    static let maximumCount = 1_048_576

    /// Scans `bytes` (the raw section contents) for NUL-terminated printable runs.
    ///
    /// - Parameters:
    ///   - bytes: the section's bytes, indexed from 0.
    ///   - baseAddress: the virtual address of `bytes[0]` (so emitted spans carry the
    ///     correct VA).
    ///   - minimumLength: the smallest printable run length to accept (default 1).
    ///   - maximumCount: cap on emitted spans (default `maximumCount`).
    /// - Returns: the spans in ascending address order.
    static func scan(
        bytes: Data,
        baseAddress: UInt64,
        minimumLength: Int = defaultMinimumLength,
        maximumCount: Int = maximumCount
    ) -> [ScannedStringSpan] {
        guard maximumCount > 0, !bytes.isEmpty else { return [] }
        let minimum = max(minimumLength, 1)

        // Work over a contiguous [UInt8] view so indexing is O(1) regardless of the
        // Data's slice base (a section sub-Data can have a non-zero startIndex).
        let buffer = [UInt8](bytes)
        let count = buffer.count

        var spans: [ScannedStringSpan] = []
        var cursor = 0
        while cursor < count && spans.count < maximumCount {
            let runStart = cursor
            var terminator = cursor
            while terminator < count, buffer[terminator] != 0 {
                terminator += 1
            }

            // No NUL before the section end: this trailing run is unterminated, so it
            // is NOT a C string — stop (every later byte is part of this same run).
            guard terminator < count else { break }

            cursor = terminator + 1
            let runLength = terminator - runStart
            guard runLength >= minimum, runLength <= maximumLength else { continue }

            let run = buffer[runStart..<terminator]
            guard isPrintableCStringRun(run) else { continue }
            guard let value = String(bytes: run, encoding: .utf8) else { continue }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            // Overflow-safe VA: a base + offset that would wrap is dropped rather than
            // emitting a bogus address.
            guard baseAddress <= UInt64.max - UInt64(runStart) else { continue }
            spans.append(ScannedStringSpan(
                address: baseAddress + UInt64(runStart),
                value: value,
                byteLength: runLength
            ))
        }
        return spans
    }

    /// True when every byte is an acceptable C-string byte: common ASCII whitespace
    /// control codes (tab / LF / CR) or any byte from 0x20 up (printable ASCII +
    /// high-bit UTF-8 continuation/lead bytes, validated by the later UTF-8 decode).
    /// Mirrors `MachOParser.isRecoverableCStringBytes`.
    private static func isPrintableCStringRun(_ bytes: ArraySlice<UInt8>) -> Bool {
        for byte in bytes {
            switch byte {
            case 0x09, 0x0a, 0x0d:
                continue
            case 0x20...0xff:
                continue
            default:
                return false
            }
        }
        return true
    }
}
