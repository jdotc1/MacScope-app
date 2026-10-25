import AppKit
import SwiftUI

/// Display-only semantic omission. Every chunk keeps its actual inherited SwiftUI font;
/// help, accessibility and Copy always expose the unmodified source value.
struct LumenSemanticText: View {
    let value: String
    let kind: LumenSemanticTextKind
    let lineLimit: Int
    let originalValue: String
    let renderChunk: ((String, Int) -> Text)?
    let requiredRange: Range<Int>?
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @Environment(\.layoutDirection) private var layoutDirection

    init(_ value: String, kind: LumenSemanticTextKind, lineLimit: Int = 1,
         originalValue: String? = nil, requiredRange: Range<Int>? = nil,
         renderChunk: ((String, Int) -> Text)? = nil) {
        self.value = value
        self.kind = kind
        self.lineLimit = max(1, lineLimit)
        self.originalValue = originalValue ?? value
        self.renderChunk = renderChunk
        self.requiredRange = requiredRange
    }

    var body: some View {
        if rendersOffscreen {
            label
        } else {
            label.contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(originalValue, forType: .string)
                }
            }
        }
    }

    private var label: some View {
        let candidates = LumenSemanticTextPolicy.renderPlan(for: value, kind: kind).filter { candidate, _ in
            // The bare ellipsis is never a presentation; the native fallback below replaces it.
            if candidate == "…" && value != "…" { return false }
            guard case .snippet = kind, let requiredRange, candidate != value else { return true }
            // Never choose a readable prefix that has silently omitted the matched token.
            // The tail-truncated fallback keeps the leading context, so the match stays visible.
            return candidate.count - 1 >= requiredRange.upperBound
        }
        let source = LumenSemanticTextPolicy.fallbackSource(for: value, kind: kind)
        return LumenSemanticTextLayout(lineLimit: lineLimit, direction: layoutDirection) {
            ForEach(candidates, id: \.candidate) { candidate, chunks in
                // Chunks are stateless rendering fragments. Their positions identify repeated
                // identical fragments within this immutable candidate, not model rows.
                ForEach(Array(styledChunks(for: candidate, chunks: chunks).enumerated()), id: \.offset) { _, chunk in
                    (renderChunk?(chunk.text, chunk.offset) ?? Text(verbatim: chunk.text))
                        .fixedSize()
                        .layoutValue(key: LumenSemanticCandidateKey.self, value: candidate)
                        .accessibilityHidden(true)
                }
            }
            // When no complete candidate fits: native wrapping and truncation of the original
            // (a path's file name), never a bare "…".
            (renderChunk?(source, value.count - source.count) ?? Text(verbatim: source))
                .lineLimit(lineLimit)
                .truncationMode(LumenSemanticTextPolicy.fallback(for: kind) == .tail ? .tail : .middle)
                .layoutValue(key: LumenSemanticFallbackKey.self, value: true)
                .accessibilityHidden(true)
        }
        .clipped()
        .contentShape(Rectangle())
        .textSelection(.disabled)
        .help(originalValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: originalValue))
    }

    /// Qualification omissions use ellipsis + source suffix; snippets retain a source prefix
    /// plus ellipsis. Suffix offsets map their ellipsis to the last omitted character; prefix
    /// offsets map it to the first omitted character. Callers should leave that glyph untinted.
    /// The offsets address `value`, while `originalValue` is solely the copy/accessibility value.
    private func styledChunks(for candidate: String, chunks: [String]) -> [(text: String, offset: Int)] {
        var offset: Int
        if candidate == value {
            offset = 0
        } else if case .snippet = kind {
            offset = 0
        } else {
            offset = value.count - candidate.count
        }
        return chunks.map { chunk in
            let result = (text: chunk, offset: offset)
            offset += chunk.count
            return result
        }
    }
}

private struct LumenSemanticCandidateKey: LayoutValueKey {
    static let defaultValue = ""
}

private struct LumenSemanticFallbackKey: LayoutValueKey {
    static let defaultValue = false
}

/// A single layout pass chooses the longest complete candidate that fits. This uses measured
/// text, including custom fonts, without geometry/state feedback or AppKit rendering branches.
private struct LumenSemanticTextLayout: Layout {
    let lineLimit: Int
    let direction: LayoutDirection

    struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var fallback = false
        var height: CGFloat { ascent + descent }
    }

    /// Measured once per layout invalidation: chunk sizes (fixed-size text has one ideal size)
    /// and the chosen plan per width, shared by sizeThatFits, alignment and placement (PERF-06).
    struct Cache {
        var dimensions: [Int: ViewDimensions] = [:]
        var plans: [CGFloat: [Line]] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = max(0, proposal.width ?? .infinity)
        let lines = arrange(subviews, width: width, cache: &cache)
        let intrinsicWidth = lines.map(\.width).max() ?? 0
        // Keep short labels intrinsic, as Text does in an HStack. The chosen line plan fits
        // its widest line, and a longer candidate cannot become eligible at this smaller width.
        return CGSize(width: min(width, intrinsicWidth),
                      height: lines.reduce(0) { $0 + $1.height })
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect,
                           proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? {
        guard guide == .firstTextBaseline else { return nil }
        return arrange(subviews, width: bounds.width, cache: &cache).first?.ascent
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let lines = arrange(subviews, width: bounds.width, cache: &cache)
        let chosen = Set(lines.flatMap(\.indices))
        // LayoutSubview omission is not a visibility API. Explicitly put every discarded
        // candidate beyond the clipped bounds, with its ideal size, so it cannot bleed through.
        for index in subviews.indices where !chosen.contains(index) {
            subviews[index].place(at: CGPoint(x: bounds.maxX + 1, y: bounds.maxY + 1),
                                  anchor: .topLeading, proposal: .unspecified)
        }
        var y = bounds.minY
        for line in lines {
            if line.fallback, let index = line.indices.first {
                let x = direction == .rightToLeft ? bounds.maxX - line.width : bounds.minX
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: bounds.width, height: nil))
                y += line.height
                continue
            }
            var x = direction == .rightToLeft ? bounds.maxX : bounds.minX
            for index in line.indices {
                let dimensions = measured(subviews, index, &cache)
                if direction == .rightToLeft { x -= dimensions.width }
                subviews[index].place(at: CGPoint(x: x, y: y + line.ascent - dimensions[.firstTextBaseline]),
                                      anchor: .topLeading, proposal: .unspecified)
                if direction != .rightToLeft { x += dimensions.width }
            }
            y += line.height
        }
    }

    private func measured(_ subviews: Subviews, _ index: Int, _ cache: inout Cache) -> ViewDimensions {
        if let dimensions = cache.dimensions[index] { return dimensions }
        let dimensions = subviews[index].dimensions(in: .unspecified)
        cache.dimensions[index] = dimensions
        return dimensions
    }

    private func arrange(_ subviews: Subviews, width: CGFloat, cache: inout Cache) -> [Line] {
        if let plan = cache.plans[width] { return plan }
        let plan = plan(subviews, width: width, cache: &cache)
        if cache.plans.count > 8 { cache.plans.removeAll(keepingCapacity: true) }
        cache.plans[width] = plan
        return plan
    }

    private func plan(_ subviews: Subviews, width: CGFloat, cache: inout Cache) -> [Line] {
        var groups: [[Int]] = []
        var lastCandidate: String?
        var fallbackIndex: Int?
        for index in subviews.indices {
            if subviews[index][LumenSemanticFallbackKey.self] { fallbackIndex = index; continue }
            let candidate = subviews[index][LumenSemanticCandidateKey.self]
            if candidate != lastCandidate {
                groups.append([])
                lastCandidate = candidate
            }
            groups[groups.count - 1].append(index)
        }
        for group in groups {
            var lines: [Line] = []
            var line = Line()
            var fits = true
            for index in group {
                let dimensions = measured(subviews, index, &cache)
                guard dimensions.width <= width else { fits = false; break }
                if !line.indices.isEmpty, line.width + dimensions.width > width {
                    lines.append(line)
                    // The current chunk requires another row. Stop measuring this candidate
                    // once its completed rows consume the budget, even for very long input.
                    if lines.count >= lineLimit { fits = false; break }
                    line = Line()
                }
                line.indices.append(index)
                line.width += dimensions.width
                let baseline = dimensions[.firstTextBaseline]
                line.ascent = max(line.ascent, baseline)
                line.descent = max(line.descent, dimensions.height - baseline)
            }
            if fits {
                lines.append(line)
                if lines.count <= lineLimit { return lines }
            }
        }
        // No complete candidate fits: the original wraps and truncates natively.
        if let fallbackIndex, width > 0, width.isFinite {
            let dimensions = subviews[fallbackIndex].dimensions(in: ProposedViewSize(width: width, height: nil))
            let baseline = dimensions[.firstTextBaseline]
            return [Line(indices: [fallbackIndex], width: min(width, dimensions.width), ascent: baseline,
                         descent: dimensions.height - baseline, fallback: true)]
        }
        // A zero-width probe: retain text height but draw no partial glyph.
        let height = subviews.first?.sizeThatFits(.unspecified).height ?? 0
        return [Line(ascent: height)]
    }
}
