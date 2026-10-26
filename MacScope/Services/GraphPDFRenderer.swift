import CoreGraphics
import CoreText
import Foundation

/// Renders the control-flow GRAPH view to a single, vector PDF page — the
/// "Export Graph as PDF" File-menu command (a common reverse-engineering workflow:
/// capture the CFG of the open binary for a report or review).
///
/// Like `DocumentExportService`, this service is intentionally *pure*: `renderPDF`
/// returns `Data` and performs no file I/O, so it is fully unit-testable and the thin
/// write-to-disk layer lives at the call site (an `NSSavePanel` in the app shell). It
/// also avoids SwiftUI's `ImageRenderer`, which is `@MainActor`-bound and depends on a
/// live view tree — drawing straight into a Core Graphics PDF context makes the output
/// deterministic and exercisable in a headless test.
///
/// The layout is laid out the same way the on-screen `GraphView` arranges the canvas —
/// one vertical *lane* per function, basic-block nodes stacked top-to-bottom within the
/// lane, and Bézier edges between nodes — but recomputed in a view-independent
/// `GraphLayoutGeometry` so the renderer never touches `SwiftUI`/`GeometryReader`.
// ds-allow-file: exported PDFs use a fixed sRGB print palette on purpose; they must not follow
// the screen theme or display profile (see PDFColor), and GraphPDFExportTests compares output.
struct GraphPDFRenderer {
    init() {}

    /// Fixed sRGB values keep exported graph colors deterministic and independent of the active
    /// macOS appearance or a user's display color profile. The live graph remains free to use
    /// semantic system colors; a PDF is a static, printable artifact.
    private struct PDFColor {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat
    }

    /// Tunable page + drawing metrics. Kept separate from `AppGraphChrome` (the live
    /// view's metrics) because the PDF is a fixed-canvas artifact, not a resizable view.
    enum Metrics {
        static let margin: CGFloat = 36
        static let laneWidth: CGFloat = 220
        static let laneGap: CGFloat = 48
        static let headerHeight: CGFloat = 40
        static let nodeWidth: CGFloat = 188
        static let nodeHeight: CGFloat = 64
        static let nodeTopPadding: CGFloat = 12
        static let nodeVerticalGap: CGFloat = 26
        static let titleFontSize: CGFloat = 9.5
        static let bodyFontSize: CGFloat = 8
        static let headerFontSize: CGFloat = 10.5
        /// A floor so an empty / tiny graph still yields a sensible non-degenerate page.
        static let minPageWidth: CGFloat = 320
        static let minPageHeight: CGFloat = 240
        /// US Letter cap on a single dimension is not enforced — the page grows to fit
        /// the whole graph so nothing is clipped (matches the export-is-lossless ethos).
    }

    /// Primary-image compatibility wrapper for headless/export callers that do not carry an
    /// interactive image owner. Ambient editor focus must never change this result.
    func renderPDF(snapshot: WorkspaceSnapshot, title: String) -> Data? {
        renderPDF(projection: snapshot.graphProjection(in: snapshot.primarySlot), title: title)
    }

    /// Explicit-slot entry point for workspace callers. The snapshot is consulted once to freeze
    /// the requested image's aggregate; all layout and drawing thereafter consume that one value.
    func renderPDF(snapshot: WorkspaceSnapshot, in imageSlot: ImageSlot, title: String) -> Data? {
        renderPDF(projection: snapshot.graphProjection(in: imageSlot), title: title)
    }

    /// Renders one frozen image-owned CFG projection to a one-page PDF. Returns `nil` only if the
    /// Core Graphics PDF context cannot be created (which should not happen for a valid media box).
    ///
    /// `title` is drawn as a caption at the top-left and is also written into the PDF's document
    /// metadata. The output is deterministic for a given projection + title.
    func renderPDF(projection: FocusedGraphProjection, title: String) -> Data? {
        let geometry = GraphLayoutGeometry(projection: projection, metrics: Metrics.self)
        let pageSize = geometry.pageSize

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title as CFString,
            kCGPDFContextCreator: "MacScope" as CFString
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            return nil
        }

        context.beginPDFPage(nil)
        // PDF user space is bottom-left origin; the layout geometry is top-left origin
        // (matching the on-screen canvas), so flip the Y axis once for the whole page.
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: 1, y: -1)

        draw(geometry: geometry, title: title, in: context, pageSize: pageSize)

        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: - Drawing

    private func draw(geometry: GraphLayoutGeometry, title: String, in context: CGContext, pageSize: CGSize) {
        // Page background — a near-white fill so the vector page prints cleanly in any
        // appearance (the PDF is a static artifact, not a Light/Dark-adaptive view).
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: pageSize))

        drawCaption(title: title, geometry: geometry, in: context)

        for lane in geometry.lanes {
            drawLane(lane, in: context)
        }

        for edge in geometry.edges {
            drawEdge(edge, in: context)
        }

        for lane in geometry.lanes {
            for node in lane.nodes {
                drawNode(node, in: context)
            }
        }
    }

    private func drawCaption(title: String, geometry: GraphLayoutGeometry, in context: CGContext) {
        let caption = title.isEmpty ? "Control-flow graph" : "\(title) — control-flow graph"
        let summary = "\(geometry.lanes.count) functions · \(geometry.nodeCount) nodes · \(geometry.edges.count) edges"
        drawText(caption, at: CGPoint(x: Metrics.margin, y: Metrics.margin * 0.4),
                 fontSize: Metrics.headerFontSize, bold: true, gray: 0.1, in: context)
        drawText(summary, at: CGPoint(x: Metrics.margin, y: Metrics.margin * 0.4 + 14),
                 fontSize: Metrics.bodyFontSize, bold: false, gray: 0.4, in: context)
    }

    private func drawLane(_ lane: GraphLayoutGeometry.Lane, in context: CGContext) {
        let rect = lane.frame
        let path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.addPath(path)
        context.setFillColor(gray: 0.96, alpha: 1)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(gray: 0.78, alpha: 1)
        context.setLineWidth(0.75)
        context.strokePath()

        // Lane header band.
        let header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: Metrics.headerHeight)
        drawText(lane.title, at: CGPoint(x: header.minX + 8, y: header.minY + 6),
                 fontSize: Metrics.titleFontSize, bold: true, gray: 0.12, in: context,
                 maxWidth: header.width - 16)
        drawText(lane.subtitle, at: CGPoint(x: header.minX + 8, y: header.minY + 21),
                 fontSize: Metrics.bodyFontSize, bold: false, gray: 0.42, in: context,
                 maxWidth: header.width - 16)
    }

    private func drawNode(_ node: GraphLayoutGeometry.Node, in context: CGContext) {
        let rect = node.frame
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        if let colorTag = node.colorTag {
            let color = Self.pdfColor(for: colorTag)
            let tint: CGFloat = 0.16
            context.setFillColor(
                red: 1 - (1 - color.red) * tint,
                green: 1 - (1 - color.green) * tint,
                blue: 1 - (1 - color.blue) * tint,
                alpha: 1
            )
        } else if node.isEntry {
            context.setFillColor(red: 0.90, green: 0.94, blue: 1.0, alpha: 1)
        } else {
            context.setFillColor(gray: 1, alpha: 1)
        }
        context.fillPath()
        context.addPath(path)
        if let colorTag = node.colorTag {
            let color = Self.pdfColor(for: colorTag)
            context.setStrokeColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        } else {
            context.setStrokeColor(gray: 0.55, alpha: 1)
        }
        context.setLineWidth(node.colorTag != nil || node.isEntry ? 1.2 : 0.8)
        context.strokePath()

        drawText(node.title, at: CGPoint(x: rect.minX + 7, y: rect.minY + 6),
                 fontSize: Metrics.titleFontSize, bold: true, gray: 0.1, in: context,
                 maxWidth: rect.width - 14)
        drawText(node.subtitle, at: CGPoint(x: rect.minX + 7, y: rect.minY + 21),
                 fontSize: Metrics.bodyFontSize, bold: false, gray: 0.35, in: context,
                 maxWidth: rect.width - 14)
        drawText(node.detail, at: CGPoint(x: rect.minX + 7, y: rect.minY + 35),
                 fontSize: Metrics.bodyFontSize, bold: false, gray: 0.45, in: context,
                 maxWidth: rect.width - 14)

        if let tag = node.tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
            drawTagChip(tag, colorTag: node.colorTag, in: rect, context: context)
        }
    }

    private func drawTagChip(
        _ tag: String,
        colorTag: ColorTag?,
        in nodeRect: CGRect,
        context: CGContext
    ) {
        let fontSize: CGFloat = 7
        let horizontalInset: CGFloat = 5
        let maxChipWidth = nodeRect.width - 14
        let clippedTag = Self.truncate(
            tag,
            fontSize: fontSize,
            bold: true,
            maxWidth: maxChipWidth - horizontalInset * 2
        )
        let chipWidth = min(
            maxChipWidth,
            Self.textWidth(clippedTag, fontSize: fontSize, bold: true) + horizontalInset * 2
        )
        let chipRect = CGRect(
            x: nodeRect.minX + 7,
            y: nodeRect.minY + 47,
            width: chipWidth,
            height: 11
        )
        let chipPath = CGPath(
            roundedRect: chipRect,
            cornerWidth: chipRect.height / 2,
            cornerHeight: chipRect.height / 2,
            transform: nil
        )
        context.addPath(chipPath)
        if let colorTag {
            let color = Self.pdfColor(for: colorTag)
            let tint: CGFloat = 0.26
            context.setFillColor(
                red: 1 - (1 - color.red) * tint,
                green: 1 - (1 - color.green) * tint,
                blue: 1 - (1 - color.blue) * tint,
                alpha: 1
            )
        } else {
            context.setFillColor(gray: 0.90, alpha: 1)
        }
        context.fillPath()

        drawText(
            clippedTag,
            at: CGPoint(x: chipRect.minX + horizontalInset, y: chipRect.minY + 1),
            fontSize: fontSize,
            bold: true,
            gray: 0.20,
            in: context,
            maxWidth: chipRect.width - horizontalInset * 2
        )
    }

    private func drawEdge(_ edge: GraphLayoutGeometry.Edge, in context: CGContext) {
        context.move(to: edge.from)
        context.addCurve(to: edge.to, control1: edge.control1, control2: edge.control2)
        switch edge.kind {
        case .call:
            context.setStrokeColor(red: 0.20, green: 0.40, blue: 0.85, alpha: 1)
            context.setLineWidth(1.6)
            context.setLineDash(phase: 0, lengths: [])
        case .reference:
            context.setStrokeColor(gray: 0.45, alpha: 1)
            context.setLineWidth(1.0)
            context.setLineDash(phase: 0, lengths: [4, 3])
        case .fallThrough:
            context.setStrokeColor(gray: 0.55, alpha: 1)
            context.setLineWidth(1.0)
            context.setLineDash(phase: 0, lengths: [2, 3])
        case .branch:
            context.setStrokeColor(red: 0.80, green: 0.55, blue: 0.10, alpha: 1)
            context.setLineWidth(1.2)
            context.setLineDash(phase: 0, lengths: [])
        }
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])

        drawArrowHead(at: edge.to, angle: edge.arrowAngle, in: context)
    }

    private func drawArrowHead(at point: CGPoint, angle: CGFloat, in context: CGContext) {
        let size: CGFloat = 6
        let p1 = CGPoint(
            x: point.x - size * cos(angle - .pi / 7),
            y: point.y - size * sin(angle - .pi / 7)
        )
        let p2 = CGPoint(
            x: point.x - size * cos(angle + .pi / 7),
            y: point.y - size * sin(angle + .pi / 7)
        )
        context.move(to: point)
        context.addLine(to: p1)
        context.addLine(to: p2)
        context.closePath()
        context.setFillColor(gray: 0.3, alpha: 1)
        context.fillPath()
    }

    /// Draws a single-line, optionally width-clipped string at `point` (top-left origin
    /// in layout space). The Core Text matrix is flipped back to upright because the
    /// page context is Y-flipped for the whole drawing.
    private func drawText(
        _ string: String,
        at point: CGPoint,
        fontSize: CGFloat,
        bold: Bool,
        gray: CGFloat,
        in context: CGContext,
        maxWidth: CGFloat? = nil
    ) {
        guard !string.isEmpty else { return }
        let clipped = maxWidth.map { Self.truncate(string, fontSize: fontSize, bold: bold, maxWidth: $0) } ?? string
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, fontSize, nil)
        let color = CGColor(gray: gray, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attributed = NSAttributedString(string: clipped, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)

        context.saveGState()
        // Place the text baseline; the page is Y-flipped, so flip the text matrix
        // back to upright and offset by the cap height so `point` is the visual top.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let ascent = CTFontGetAscent(font)
        context.textPosition = CGPoint(x: point.x, y: point.y + ascent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Truncates `string` with a trailing ellipsis so its rendered width fits `maxWidth`.
    private static func truncate(_ string: String, fontSize: CGFloat, bold: Bool, maxWidth: CGFloat) -> String {
        if textWidth(string, fontSize: fontSize, bold: bold) <= maxWidth { return string }
        var characters = Array(string)
        while !characters.isEmpty {
            characters.removeLast()
            let candidate = String(characters) + "…"
            if textWidth(candidate, fontSize: fontSize, bold: bold) <= maxWidth { return candidate }
        }
        return "…"
    }

    private static func textWidth(_ string: String, fontSize: CGFloat, bold: Bool) -> CGFloat {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        return CTLineGetTypographicBounds(
            CTLineCreateWithAttributedString(attributed),
            nil,
            nil,
            nil
        )
    }

    private static func pdfColor(for tag: ColorTag) -> PDFColor {
        switch tag {
        case .red: PDFColor(red: 0.86, green: 0.18, blue: 0.18)
        case .orange: PDFColor(red: 0.91, green: 0.45, blue: 0.08)
        case .yellow: PDFColor(red: 0.86, green: 0.67, blue: 0.04)
        case .green: PDFColor(red: 0.14, green: 0.61, blue: 0.27)
        case .blue: PDFColor(red: 0.15, green: 0.42, blue: 0.82)
        case .purple: PDFColor(red: 0.55, green: 0.30, blue: 0.75)
        case .gray: PDFColor(red: 0.45, green: 0.48, blue: 0.52)
        }
    }
}
