import AppKit
import SwiftUI
import os

// Lumen glyphs: symbols SF Symbols doesn't have, for the things Lumen's apps work with. Each draws
// as an SF Symbol: one of LumenUI's custom symbols (Resources/Symbols.xcassets, built from Apple's
// geometry so it interpolates through all nine weights) or an SF Symbol equivalent
// (`sfEquivalents`). `LumenSymbol` and `LumenIconTile` draw them that way, outlined beside text and
// filled on tiles, and follow the current font like any symbol.
//
// Each glyph also keeps its original drawing on SF Symbols' 24-point grid (line work and solid
// marks over a translucent tint layer). `LumenGlyphView` draws it, for apps that call it directly
// and as the fallback for an app-registered glyph with no symbol.
//
// Any `systemImage` parameter in Lumen accepts a glyph's `symbolName` ("lumen.callGraph"), so tiles,
// menus, badges, settings tabs and the welcome window use glyphs without new API. Apps add their own
// with `LumenGlyph.register(_:)`.

/// A glyph's three layers, in a 24 × 24 grid.
public struct LumenGlyphDrawing: Sendable {
    /// Stroked with round caps and joins at the glyph's weight.
    public var stroke = Path()
    /// Filled at full strength: the glyph's emphasis.
    public var fill = Path()
    /// Filled at `LumenGlyph.tintOpacity`: the semi-fill under the line work.
    public var tint = Path()

    public init() {}
}

/// One glyph: an identifier, a name for people, a family, and its drawing.
public struct LumenGlyph: Identifiable, Hashable, Sendable {
    /// The drawing grid, as in SF Symbols' templates. Keep marks inside 2…22.
    public static let gridSize: CGFloat = 24
    /// The tint layer's strength.
    public static let tintOpacity = 0.3

    /// The least size that draws the tint layer. Below it the semi-fill is a pixel or two wide on
    /// Retina and reads as a smudge or shadow, so small glyphs are line work and solid marks only.
    public static let tintMinimumSize: CGFloat = 24

    public let id: String
    public let title: String
    public let family: String
    public let drawing: LumenGlyphDrawing

    public init(id: String, title: String, family: String, draw: (inout LumenGlyphDrawing) -> Void) {
        self.id = id
        self.title = title
        self.family = family
        var drawing = LumenGlyphDrawing()
        draw(&drawing)
        self.drawing = drawing
    }

    /// The name to pass wherever Lumen takes a `systemImage`.
    public var symbolName: String { "lumen.\(id)" }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: Registry

public extension LumenGlyph {
    /// The glyph for a `lumen.` name, built in or registered; `nil` for SF Symbol names.
    static func named(_ name: String) -> LumenGlyph? {
        guard name.hasPrefix("lumen.") else { return nil }
        return builtInsByName[name] ?? registered.withLock { $0[name] }
    }

    /// Adds an app's own glyphs. A glyph with a built-in's id replaces nothing: built-ins win.
    static func register(_ glyphs: [LumenGlyph]) {
        registered.withLock { table in
            for glyph in glyphs { table[glyph.symbolName] = glyph }
        }
    }

    /// Every glyph: built-ins in family order, then registered ones by family and title.
    static var all: [LumenGlyph] {
        let extra = registered.withLock { Array($0.values) }
            .filter { builtInsByName[$0.symbolName] == nil }
            .sorted { ($0.family, $0.title) < ($1.family, $1.title) }
        return builtIns + extra
    }

    /// The families in display order.
    static var families: [String] {
        var seen: Set<String> = []
        return all.map(\.family).filter { seen.insert($0).inserted }
    }
}

private extension LumenGlyph {
    static let registered = OSAllocatedUnfairLock<[String: LumenGlyph]>(initialState: [:])
    static let builtInsByName = Dictionary(uniqueKeysWithValues: builtIns.map { ($0.symbolName, $0) })
}

extension LumenGlyph {
    /// SF Symbols that stand for Lumen glyphs, in their outline form for use beside text. Tiles
    /// ask for the filled form (`.symbolVariant(.fill)`, or `sfFillOverrides` where the filled
    /// symbol isn't named `<name>.fill`), as Apple's guidance pairs outline with text and fill with
    /// colored backgrounds.
    static let sfEquivalents: [String: String] = [
        "lumen.disassembly": "text.alignleft",
        "lumen.pseudocode": "curlybraces",
        "lumen.callGraph": "point.3.connected.trianglepath.dotted",
        "lumen.crossReference": "arrow.left.arrow.right",
        "lumen.entryPoint": "arrow.right.to.line",
        "lumen.memoryMap": "memorychip",
        "lumen.lens": "magnifyingglass",
        "lumen.imageSeries": "square.stack.3d.up",
        "lumen.redactedField": "eye.slash",
        "lumen.windowLevel": "slider.horizontal.3",
        "lumen.binaryFile": "doc",
        "lumen.axialSlice": "circle.and.line.horizontal",
    ]

    /// Filled forms not named `<name>.fill`.
    static let sfFillOverrides: [String: String] = [
        "point.3.connected.trianglepath.dotted": "point.3.filled.connected.trianglepath.dotted",
    ]

    /// Lumen glyphs drawn as custom SF Symbols in LumenUI's asset catalog (Resources/Symbols.xcassets),
    /// built from Apple's symbol geometry and stem weights so they sit with SF Symbols.
    static let customSymbols: Set<String> = ["lumen.patchedBytes", "lumen.colorMix", "lumen.token", "lumen.breakpoint", "lumen.anonymize"]
    /// Custom symbols with a filled companion (`<name>.fill`) for tiles. Color mix stays an outline
    /// on tiles: filled, its three discs merge into one shape at 16–20 pt.
    static let customFillSymbols: Set<String> = ["lumen.breakpoint.fill", "lumen.token.fill",
                                                 "lumen.patchedBytes.fill", "lumen.anonymize.fill"]

    /// The image a tile or label draws for a Lumen glyph or SF Symbol name: a custom symbol, an SF
    /// Symbol equivalent, or `nil` for a Lumen glyph with neither.
    /// - Parameter filled: the filled form, for tiles.
    static func symbolImage(for name: String, filled: Bool = false) -> Image? {
        if customSymbols.contains(name) {
            return Image(filled && customFillSymbols.contains(name + ".fill") ? name + ".fill" : name, bundle: .module)
        }
        guard let symbol = sfSymbol(for: name) else { return nil }
        if filled, let override = sfFillOverrides[symbol] { return Image(systemName: override) }
        return Image(systemName: symbol)
    }

    /// The SF Symbol a tile draws for `name`: its equivalent for a Lumen glyph, `nil` for a Lumen
    /// glyph without one, and `name` itself for an SF Symbol.
    static func sfSymbol(for name: String) -> String? {
        if let equivalent = sfEquivalents[name] { return equivalent }
        return LumenGlyph.named(name) == nil ? name : nil
    }
}

// MARK: Rendering

/// A glyph at a size, in the current foreground style.
public struct LumenGlyphView: View {
    public enum Weight: Sendable {
        case regular, bold
        /// Stroke width in grid units: the custom symbols' stem at the same size.
        var lineWidth: CGFloat { self == .regular ? 1.45 : 1.75 }
    }

    private let glyph: LumenGlyph
    private let size: CGFloat
    private let weight: Weight
    private let label: String?

    /// - Parameters:
    ///   - weight: `nil` picks bold below 18 pt, so strokes stay about a point wide.
    ///   - label: the accessibility label; defaults to the glyph's title.
    public init(_ glyph: LumenGlyph, size: CGFloat = 16, weight: Weight? = nil, label: String? = nil) {
        self.glyph = glyph
        self.size = size
        self.weight = weight ?? (size < 18 ? .bold : .regular)
        self.label = label
    }

    @Environment(\.lumenGlyphTint) private var tint

    public var body: some View {
        let lineWidth = max(1, weight.lineWidth * size / LumenGlyph.gridSize)
        ZStack {
            if size < LumenGlyph.tintMinimumSize {
                EmptyView()
            } else if let tint {
                GlyphLayer(path: glyph.drawing.tint).fill(tint)
            } else {
                GlyphLayer(path: glyph.drawing.tint).fill().opacity(LumenGlyph.tintOpacity)
            }
            GlyphLayer(path: glyph.drawing.fill).fill()
            GlyphLayer(path: glyph.drawing.stroke)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(label ?? glyph.title)
        .accessibilityAddTraits(.isImage)
    }
}

extension EnvironmentValues {
    /// The tint layer's color where the default (the foreground at 30%) would weaken the marks on top
    /// of it: icon tiles darken under white glyphs instead of lightening.
    @Entry var lumenGlyphTint: Color? = nil
}

/// A drawing scaled from the 24-unit grid to its frame.
private struct GlyphLayer: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path {
        path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / LumenGlyph.gridSize, y: rect.height / LumenGlyph.gridSize))
    }
}

/// A symbol by name: for `lumen.` names, its custom SF Symbol or SF equivalent (the Lumen glyph if it
/// has neither), an SF Symbol otherwise. Without a size it
/// takes the current font's symbol size, as `Image(systemName:)` does.
public struct LumenSymbol: View {
    private let name: String
    private let size: CGFloat?

    public init(_ name: String, size: CGFloat? = nil) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        if LumenGlyph.named(name) != nil, let image = LumenGlyph.symbolImage(for: name) {
            // A custom SF Symbol or an SF equivalent: it follows the font's size and weight.
            if let size { image.font(.system(size: size * 0.8)) } else { image }
        } else if let glyph = LumenGlyph.named(name) {
            if let size {
                LumenGlyphView(glyph, size: size)
            } else {
                // An invisible SF Symbol measures the font; the glyph fills its box.
                Image(systemName: "square").hidden()
                    .overlay {
                        GeometryReader { proxy in
                            let side = max(proxy.size.width, proxy.size.height) * 1.15
                            LumenGlyphView(glyph, size: side)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    }
            }
        } else if let size {
            Image(systemName: name).font(.system(size: size * 0.8))
        } else {
            Image(systemName: name)
        }
    }
}

public extension LumenGlyph {
    /// The glyph as a template `NSImage`, for AppKit and native menus: the system tints it, including
    /// the menu highlight. It renders the glyph's symbol (custom or SF equivalent) as `LumenSymbol`
    /// does; an app-registered glyph without one renders its drawing. `weight` applies only to a
    /// drawing.
    @MainActor
    func templateImage(size: CGFloat = 16, weight: LumenGlyphView.Weight? = nil, scale: CGFloat = 2) -> NSImage? {
        let content: AnyView = if let symbol = LumenGlyph.symbolImage(for: symbolName) {
            AnyView(symbol.font(.system(size: size * 0.8)).frame(width: size, height: size).foregroundStyle(.black))
        } else {
            AnyView(LumenGlyphView(self, size: size, weight: weight).foregroundStyle(.black))
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        image.isTemplate = true
        image.accessibilityDescription = title
        return image
    }

    /// The glyph as a template `Image`, for `Label` icons in native menus and toolbars: its symbol
    /// (custom or SF equivalent), which takes the current font's size as any symbol does, so `size`
    /// applies only to an app-registered glyph without one (rendered from its drawing at that size).
    @MainActor
    func image(size: CGFloat = 16) -> Image {
        if let symbol = LumenGlyph.symbolImage(for: symbolName) { return symbol.renderingMode(.template) }
        return templateImage(size: size).map { Image(nsImage: $0).renderingMode(.template) } ?? Image(systemName: "questionmark.square.dashed")
    }
}

// MARK: Built-in glyphs

public extension LumenGlyph {
    static let builtIns: [LumenGlyph] = [
        .lens, .colorMix, .token,
        .binaryFile, .callGraph, .disassembly, .pseudocode, .patchedBytes, .breakpoint, .memoryMap, .entryPoint, .crossReference,
        .imageSeries, .axialSlice, .anonymize, .redactedField, .windowLevel,
    ]

    // Lumen

    /// Lumen's mark: a lens with a spark of light.
    static let lens = LumenGlyph(id: "lens", title: "Lens", family: "Lumen") { d in
        d.stroke.circle(10.5, 10.5, 6.5)
        d.stroke.m(15.3, 15.3); d.stroke.l(20.5, 20.5)
        d.tint.circle(10.5, 10.5, 6.5)
        d.fill.m(10.5, 6.9)
        d.fill.q(14.1, 10.5, c: 11.2, 9.8)
        d.fill.q(10.5, 14.1, c: 11.2, 11.2)
        d.fill.q(6.9, 10.5, c: 9.8, 11.2)
        d.fill.q(10.5, 6.9, c: 9.8, 9.8)
        d.fill.closeSubpath()
    }

    /// Three overlapping hues: themes and color.
    static let colorMix = LumenGlyph(id: "colorMix", title: "Color Mix", family: "Lumen") { d in
        for (x, y) in [(12.0, 8.5), (8.2, 15.0), (15.8, 15.0)] {
            d.stroke.circle(x, y, 5)
            d.tint.circle(x, y, 5)
        }
    }

    /// A named color role.
    static let token = LumenGlyph(id: "token", title: "Token", family: "Lumen") { d in
        d.stroke.rrect(3, 7.5, 18, 9, 4.5)
        d.tint.rrect(3, 7.5, 18, 9, 4.5)
        d.fill.circle(7.5, 12, 1.9)
        d.stroke.m(12, 12); d.stroke.l(17.5, 12)
    }

    // Binary analysis

    /// An executable file: a page of bytes.
    static let binaryFile = LumenGlyph(id: "binaryFile", title: "Binary", family: "Binary Analysis") { d in
        let page: [(CGFloat, CGFloat)] = [(5.5, 3), (14, 3), (18.5, 7.5), (18.5, 21), (5.5, 21)]
        d.stroke.poly(page, closed: true)
        d.tint.poly(page, closed: true)
        d.stroke.poly([(14, 3), (14, 7.5), (18.5, 7.5)])
        d.fill.rrect(8, 11, 3.4, 2.2, 1.1); d.fill.rrect(12.6, 11, 3.4, 2.2, 1.1)
        d.fill.rrect(8, 15, 2.2, 2.2, 1.1); d.fill.rrect(11.6, 15, 4.4, 2.2, 1.1)
    }

    /// A function and its callees.
    static let callGraph = LumenGlyph(id: "callGraph", title: "Call Graph", family: "Binary Analysis") { d in
        d.fill.rrect(8, 2.5, 8, 6, 2.2)
        d.stroke.rrect(3, 16, 7, 5, 1.6); d.tint.rrect(3, 16, 7, 5, 1.6)
        d.stroke.rrect(14, 16, 7, 5, 1.6); d.tint.rrect(14, 16, 7, 5, 1.6)
        d.stroke.m(12, 9); d.stroke.l(12, 11.5)
        d.stroke.m(6.5, 16); d.stroke.l(6.5, 13.3); d.stroke.q(8.3, 11.5, c: 6.5, 11.5)
        d.stroke.l(15.7, 11.5); d.stroke.q(17.5, 13.3, c: 17.5, 11.5); d.stroke.l(17.5, 16)
    }

    /// Addressed instructions, with the current line.
    static let disassembly = LumenGlyph(id: "disassembly", title: "Disassembly", family: "Binary Analysis") { d in
        d.tint.rrect(7.4, 11.9, 14.6, 4.2, 2.1)
        for y in [6.0, 10, 14, 18] { d.fill.circle(4.5, y, 1.2) }
        d.stroke.m(9, 6); d.stroke.l(19.5, 6)
        d.stroke.m(9, 10); d.stroke.l(16, 10)
        d.stroke.m(11, 14); d.stroke.l(20, 14)
        d.stroke.m(9, 18); d.stroke.l(15, 18)
    }

    /// Decompiled source between braces.
    static let pseudocode = LumenGlyph(id: "pseudocode", title: "Pseudocode", family: "Binary Analysis") { d in
        d.tint.rrect(8.4, 7.5, 7.2, 9, 1.6)
        d.stroke.m(8.5, 4); d.stroke.q(6, 6.5, c: 6, 4); d.stroke.l(6, 9.5); d.stroke.q(4, 12, c: 6, 12)
        d.stroke.q(6, 14.5, c: 6, 12); d.stroke.l(6, 17.5); d.stroke.q(8.5, 20, c: 6, 20)
        d.stroke.m(15.5, 4); d.stroke.q(18, 6.5, c: 18, 4); d.stroke.l(18, 9.5); d.stroke.q(20, 12, c: 18, 12)
        d.stroke.q(18, 14.5, c: 18, 12); d.stroke.l(18, 17.5); d.stroke.q(15.5, 20, c: 18, 20)
        d.stroke.m(10, 10.5); d.stroke.l(14, 10.5)
        d.stroke.m(10, 13.5); d.stroke.l(12.8, 13.5)
    }

    /// Bytes, one of them changed.
    static let patchedBytes = LumenGlyph(id: "patchedBytes", title: "Patched Bytes", family: "Binary Analysis") { d in
        for (x, y) in [(3.5, 3.5), (13.0, 3.5), (3.5, 13.0)] {
            d.stroke.rrect(x, y, 7.5, 7.5, 1.8)
            d.tint.rrect(x, y, 7.5, 7.5, 1.8)
        }
        d.fill.rrect(12.15, 12.15, 9.2, 9.2, 2.6)
    }

    /// A breakpoint marker, as in the debugger gutter.
    static let breakpoint = LumenGlyph(id: "breakpoint", title: "Breakpoint", family: "Binary Analysis") { d in
        let shape: [(CGFloat, CGFloat)] = [(3, 6.5), (15.5, 6.5), (21, 12), (15.5, 17.5), (3, 17.5)]
        d.stroke.poly(shape, closed: true)
        d.tint.poly(shape, closed: true)
    }

    /// Segments of an address space, one selected.
    static let memoryMap = LumenGlyph(id: "memoryMap", title: "Memory Map", family: "Binary Analysis") { d in
        d.stroke.rrect(5, 3, 14, 18, 2.6)
        d.tint.rrect(5, 3, 14, 18, 2.6)
        d.stroke.m(5, 8); d.stroke.l(19, 8)
        d.stroke.m(5, 12.5); d.stroke.l(19, 12.5)
        d.stroke.m(5, 17); d.stroke.l(19, 17)
        d.fill.rrect(6.6, 13.6, 10.8, 2.3, 0.8)
    }

    /// Where execution starts.
    static let entryPoint = LumenGlyph(id: "entryPoint", title: "Entry Point", family: "Binary Analysis") { d in
        d.stroke.circle(14.5, 12, 6.5)
        d.tint.circle(14.5, 12, 6.5)
        d.stroke.m(3, 12); d.stroke.l(13, 12)
        d.stroke.poly([(10, 9), (13, 12), (10, 15)])
    }

    /// A reference from one place to another.
    static let crossReference = LumenGlyph(id: "crossReference", title: "Cross-Reference", family: "Binary Analysis") { d in
        d.stroke.circle(6, 17.5, 2.8)
        d.tint.circle(6, 17.5, 2.8)
        d.fill.circle(18, 6.5, 3)
        d.stroke.m(6, 14.2); d.stroke.q(13.6, 6.5, c: 6, 6.5)
        d.stroke.poly([(11.3, 4.2), (13.7, 6.5), (11.3, 8.8)])
    }

    // Imaging

    /// A series of image slices.
    static let imageSeries = LumenGlyph(id: "imageSeries", title: "Image Series", family: "Imaging") { d in
        let top: [(CGFloat, CGFloat)] = [(12, 3.5), (21, 8), (12, 12.5), (3, 8)]
        d.stroke.poly(top, closed: true)
        d.tint.poly(top, closed: true)
        d.stroke.poly([(3, 12), (12, 16.5), (21, 12)])
        d.stroke.poly([(3, 16), (12, 20.5), (21, 16)])
    }

    /// A head with an axial scan plane.
    static let axialSlice = LumenGlyph(id: "axialSlice", title: "Axial Slice", family: "Imaging") { d in
        d.stroke.addEllipse(in: CGRect(x: 5.5, y: 3, width: 13, height: 18))
        d.tint.addEllipse(in: CGRect(x: 5.5, y: 3, width: 13, height: 18))
        d.fill.addEllipse(in: CGRect(x: 3, y: 10.5, width: 18, height: 4))
    }

    /// A person with the identifying part covered.
    static let anonymize = LumenGlyph(id: "anonymize", title: "Anonymize", family: "Imaging") { d in
        d.stroke.circle(12, 8, 3.8)
        d.tint.circle(12, 8, 3.8)
        d.stroke.m(4.5, 20.5); d.stroke.q(12, 13.8, c: 4.5, 13.8); d.stroke.q(19.5, 20.5, c: 19.5, 13.8)
        d.tint.m(4.5, 20.5); d.tint.q(12, 13.8, c: 4.5, 13.8); d.tint.q(19.5, 20.5, c: 19.5, 13.8); d.tint.closeSubpath()
        d.fill.rrect(6.3, 6.75, 11.4, 2.6, 1.3)
    }

    /// A metadata field with its value removed.
    static let redactedField = LumenGlyph(id: "redactedField", title: "Redacted Field", family: "Imaging") { d in
        d.tint.rrect(4.5, 5, 15, 14, 1)
        d.stroke.poly([(7.5, 5), (4.5, 5), (4.5, 19), (7.5, 19)])
        d.stroke.poly([(16.5, 5), (19.5, 5), (19.5, 19), (16.5, 19)])
        d.fill.rrect(7.5, 10.7, 9, 2.6, 1.3)
    }

    /// Window and level: the slice of an image's intensity histogram that's displayed. Bars inside
    /// the window are solid; those outside are thin.
    static let windowLevel = LumenGlyph(id: "windowLevel", title: "Window/Level", family: "Imaging") { d in
        d.tint.rrect(7, 3.5, 10, 17, 2)
        for (x, height) in [(9.4, 9.0), (12.0, 14.0), (14.6, 10.0)] {
            d.fill.rrect(x - 1.1, 19 - height, 2.2, height, 1.1)
        }
        d.stroke.m(4, 18.2); d.stroke.l(4, 15)
        d.stroke.m(20, 18.2); d.stroke.l(20, 13.5)
    }
}

// Terse drawing helpers for the 24-unit grid.
private extension Path {
    mutating func m(_ x: CGFloat, _ y: CGFloat) { move(to: CGPoint(x: x, y: y)) }
    mutating func l(_ x: CGFloat, _ y: CGFloat) { addLine(to: CGPoint(x: x, y: y)) }
    mutating func q(_ x: CGFloat, _ y: CGFloat, c cx: CGFloat, _ cy: CGFloat) {
        addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
    }
    mutating func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    mutating func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
        addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r), style: .continuous)
    }
    mutating func poly(_ points: [(CGFloat, CGFloat)], closed: Bool = false) {
        guard let first = points.first else { return }
        m(first.0, first.1)
        for point in points.dropFirst() { l(point.0, point.1) }
        if closed { closeSubpath() }
    }
}
