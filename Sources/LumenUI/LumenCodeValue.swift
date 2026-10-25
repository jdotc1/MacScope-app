import AppKit
import SwiftUI

/// Selectable inspector code text. AppKit's paragraph controls prevent typographic hyphens
/// from masquerading as identifier characters; the attributed string always holds the original.
struct LumenCodeValue: View {
    let value: String
    let font: Font
    let nativeFont: NSFont?
    let color: Color
    var kind: LumenSemanticTextKind = .expression
    var lineLimit: Int = 2
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    var body: some View {
        if !rendersOffscreen, let nativeFont {
            LumenNativeCodeValue(value: value, font: nativeFont, color: color, kind: kind, lineLimit: lineLimit)
        } else if rendersOffscreen {
            LumenSemanticText(value, kind: kind, lineLimit: lineLimit)
                .font(font).foregroundStyle(color)
        } else {
            // SwiftUI exposes no NSFont conversion for an arbitrary Font. Preserve native
            // text selection and the original string for this custom-font live fallback.
            // Its single-line middle truncation does not insert typographic hyphens.
            Text(value).font(font).foregroundStyle(color)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                .help(value).accessibilityLabel(value)
        }
    }
}

private struct LumenNativeCodeValue: NSViewRepresentable {
    let value: String
    let font: NSFont
    let color: Color
    let kind: LumenSemanticTextKind
    let lineLimit: Int

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.cell = LumenSemanticCodeCell(textCell: value)
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        field.isBezeled = false
        field.maximumNumberOfLines = max(1, lineLimit)
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if let cell = field.cell as? LumenSemanticCodeCell {
            cell.kind = kind
            cell.semanticLineLimit = max(1, lineLimit)
        }
        field.maximumNumberOfLines = max(1, lineLimit)
        let paragraph = NSMutableParagraphStyle()
        paragraph.usesDefaultHyphenation = false
        paragraph.hyphenationFactor = 0
        paragraph.lineBreakStrategy = []
        paragraph.lineBreakMode = .byWordWrapping
        field.font = font
        field.textColor = NSColor(color)
        field.attributedStringValue = NSAttributedString(string: value, attributes: [
            .font: font, .foregroundColor: NSColor(color), .paragraphStyle: paragraph
        ])
        field.lineBreakStrategy = []
        field.toolTip = value
        field.setAccessibilityValue(value)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let lines = (nsView.cell as? LumenSemanticCodeCell)?.presentation(width: max(0, width - 4)) ?? [value]
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return CGSize(width: max(0, width), height: lineHeight * CGFloat(max(1, lines.count)) + 2)
    }
}

/// Only drawing uses the semantic plan. AppKit's field editor, accessibility and copy
/// continue to read the complete attributedStringValue, never a shortened display value.
final class LumenSemanticCodeCell: NSTextFieldCell {
    var kind: LumenSemanticTextKind = .expression
    var semanticLineLimit: Int = 2

    private struct PlanKey: Equatable {
        var value: String, kind: LumenSemanticTextKind, lineLimit: Int, font: NSFont, width: CGFloat
    }
    /// sizeThatFits and every drawInterior ask for the same plan; keep the last one (PERF-12).
    private var lastPlan: (key: PlanKey, lines: [String])?

    func presentation(width: CGFloat) -> [String] {
        let displayFont = font ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        let key = PlanKey(value: stringValue, kind: kind, lineLimit: semanticLineLimit, font: displayFont, width: max(0, width))
        if let lastPlan, lastPlan.key == key { return lastPlan.lines }
        let lines = LumenSemanticTextPolicy.presentation(for: key.value, kind: kind,
            width: key.width, maxLines: semanticLineLimit) {
                ($0 as NSString).size(withAttributes: [.font: displayFont]).width
            }
        lastPlan = (key, lines)
        return lines
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Selection uses AppKit's original text, including when the presentation is abbreviated.
        if let field = controlView as? NSTextField, field.currentEditor() != nil {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        let rect = drawingRect(forBounds: cellFrame)
        let displayFont = font ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        let lineHeight = ceil(displayFont.ascender - displayFont.descender + displayFont.leading)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: displayFont, .foregroundColor: textColor ?? NSColor.labelColor
        ]
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        for (index, line) in presentation(width: rect.width).enumerated() {
            (line as NSString).draw(in: NSRect(x: rect.minX,
                y: rect.minY + CGFloat(index) * lineHeight,
                width: rect.width, height: lineHeight), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
