import Foundation

/// WS-7: a synthetic runtime layout for a multi-image workspace. Each image slot gets a load
/// `slide` so images occupy DISJOINT runtime ranges; `runtimeVA = imageVA + slide(slot)`. The
/// primary image is always slide 0 (so single-image workspaces are unchanged and their VAs are
/// identical). Derived + transient — never persisted; recomputed with the cross-image edges.
struct ImageLayout: Sendable, Equatable {
    /// One image's placement in the synthetic runtime space. Its runtime range is
    /// `[runtimeBase, runtimeBase + runtimeSize)`; ranges never overlap across slots, and
    /// `runtimeBase + runtimeSize` never exceeds `UInt64.max` (checked at construction).
    /// `slide` is the modular (two's-complement) offset `runtimeBase - imageMinVA`, so a
    /// secondary placed BELOW its own image VAs carries a wrapped slide that `runtimeVA` and
    /// `resolve` undo exactly.
    struct Placement: Sendable, Equatable {
        var slide: UInt64
        var runtimeBase: UInt64
        var runtimeSize: UInt64

        func contains(runtimeVA v: UInt64) -> Bool {
            v >= runtimeBase && v - runtimeBase < runtimeSize
        }
    }

    /// Why an image with sections received no runtime range. A rejected slot has no placement:
    /// `resolve` never returns it, so runtime navigation can never land on it by accident.
    enum Rejection: Error, Sendable, Equatable {
        /// A section's `address + size` (or the page-aligned extent) wraps past `UInt64.max`.
        case sectionExtentOverflow
        /// No disjoint, page-aligned range fits above the ranges already reserved.
        case addressSpaceExhausted
        /// The primary image's own extent could not be established, so disjointness from it
        /// cannot be proven for any secondary.
        case primaryExtentUnavailable
    }

    var placements: [ImageSlot: Placement] = [:]
    /// Images that have sections but were conservatively left unplaced (never wrapped/overlapped).
    var rejections: [ImageSlot: Rejection] = [:]

    /// The slide for `slot` (0 when the slot has no placement — e.g. a section-less image).
    func slide(_ slot: ImageSlot) -> UInt64 { placements[slot]?.slide ?? 0 }

    /// Projects an image-VA into the unified runtime space.
    func runtimeVA(_ a: ImageAddress) -> UInt64 { a.address &+ slide(a.slot) }

    /// Resolves a runtime VA back to the image whose disjoint range contains it. At most one range
    /// matches (they are disjoint by construction). Nil when the value falls in a gap / no image.
    func resolve(runtimeVA v: UInt64) -> ImageAddress? {
        for (slot, p) in placements where p.contains(runtimeVA: v) {
            return ImageAddress(slot: slot, address: v &- p.slide)
        }
        return nil
    }
}

/// Computes the stacked runtime layout from each image's section VA extent. Pure + deterministic.
///
/// MS-07: the ACTUAL primary (`snapshot.primarySlot`, the first workspace image — not necessarily
/// the lowest numeric slot after a remap) is reserved first at its unchanged image VAs. Every
/// secondary, in ascending slot order, is then placed at a single checked cursor that starts one
/// guard page past the primary's reservation and advances past each placed secondary. A
/// section-less primary still reserves `[0, page)`, so no two secondaries can share the fallback
/// base. All arithmetic is overflow-checked; an image that cannot be placed disjointly is recorded
/// in `rejections` instead of wrapping or overlapping.
enum ImageLayoutResolver {
    /// arm64 page granularity; also the guard-band gap kept between adjacent images.
    static let page: UInt64 = 0x4000

    /// Page-aligns `v` upward; nil when the aligned value would exceed `UInt64.max`.
    private static func checkedPageAlignUp(_ v: UInt64) -> UInt64? {
        let (bumped, overflow) = v.addingReportingOverflow(page - 1)
        return overflow ? nil : bumped & ~(page - 1)
    }

    /// `[minVA, maxVA)` over all sections with checked end arithmetic. `.none` = no sections;
    /// `.overflow` = some section end wraps.
    private enum Extent {
        case none
        case overflow
        case span(minVA: UInt64, maxVA: UInt64)
    }

    private static func extent(of analysis: ImageAnalysis?) -> Extent {
        guard let sections = analysis?.sections, !sections.isEmpty else { return .none }
        var minVA = UInt64.max
        var maxVA: UInt64 = 0
        for section in sections {
            let (end, overflow) = section.address.addingReportingOverflow(section.size)
            if overflow { return .overflow }
            minVA = min(minVA, section.address)
            maxVA = max(maxVA, end)
        }
        return .span(minVA: minVA, maxVA: maxVA)
    }

    static func layout(_ snapshot: WorkspaceSnapshot) -> ImageLayout {
        var layout = ImageLayout()
        guard !snapshot.binaries.isEmpty else { return layout }
        let primarySlot = snapshot.primarySlot

        // 1. Reserve the actual primary first, at slide 0 and its unchanged image VAs.
        //    `cursor` is the next free page-aligned runtime base; nil = nothing more fits.
        var cursor: UInt64?
        var primaryRejection: ImageLayout.Rejection?
        switch extent(of: snapshot.analysis(in: primarySlot)) {
        case .none:
            // Section-less primary: identity VAs are unknown, but `[0, page)` is still reserved
            // so the first secondary starts at one page and every later one advances past it.
            cursor = page
        case .overflow:
            layout.rejections[primarySlot] = .sectionExtentOverflow
            primaryRejection = .primaryExtentUnavailable
            cursor = nil
        case let .span(minVA, maxVA):
            let span = maxVA - minVA                       // maxVA >= minVA by construction
            let available = UInt64.max - minVA             // room before the top of the space
            // Prefer the page-aligned extent; clamp to the exact (never wrapping) real extent
            // when alignment would pass `UInt64.max`. Real primary VAs always stay resolvable.
            let size = checkedPageAlignUp(span).map { min($0, available) } ?? span
            layout.placements[primarySlot] = .init(slide: 0, runtimeBase: minVA, runtimeSize: size)
            cursor = nextBase(after: minVA, size: size)
        }

        // 2. Secondaries in ascending slot order (append-only stable), each from the cursor.
        let secondaries = snapshot.binaries.map(\.slot).filter { $0 != primarySlot }.sorted()
        for slot in secondaries {
            let minVA: UInt64
            let maxVA: UInt64
            switch extent(of: snapshot.analysis(in: slot)) {
            case .none:
                continue                // a section-less secondary gets no range (unchanged)
            case .overflow:
                layout.rejections[slot] = .sectionExtentOverflow
                continue
            case let .span(lo, hi):
                minVA = lo
                maxVA = hi
            }
            if let primaryRejection {
                layout.rejections[slot] = primaryRejection
                continue
            }
            guard let size = checkedPageAlignUp(maxVA - minVA) else {
                layout.rejections[slot] = .sectionExtentOverflow
                continue
            }
            guard let base = cursor else {
                layout.rejections[slot] = .addressSpaceExhausted
                continue
            }
            let (_, endOverflow) = base.addingReportingOverflow(size)
            guard !endOverflow else {
                // Does not fit; the cursor is unchanged so a later, smaller image may still fit.
                layout.rejections[slot] = .addressSpaceExhausted
                continue
            }
            layout.placements[slot] = .init(slide: base &- minVA, runtimeBase: base, runtimeSize: size)
            cursor = nextBase(after: base, size: size)
        }
        return layout
    }

    /// The page-aligned base one guard page past `[base, base + size)`; nil on overflow.
    private static func nextBase(after base: UInt64, size: UInt64) -> UInt64? {
        let (end, o1) = base.addingReportingOverflow(size)
        guard !o1 else { return nil }
        let (guarded, o2) = end.addingReportingOverflow(page)
        guard !o2 else { return nil }
        return checkedPageAlignUp(guarded)
    }
}
