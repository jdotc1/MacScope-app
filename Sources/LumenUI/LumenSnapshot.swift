import AppKit
import ImageIO
import LumenTokens
import SwiftUI

/// Renders SwiftUI views to PNG under a chosen theme and compares them with golden images.
///
/// Each render uses a throwaway, non-persisting store installed as the active store only for the
/// render, so the user's selection is never touched. Subjects come from the caller; Lumen ships
/// none. A test typically does:
///
/// ```swift
/// let outcome = LumenSnapshot.verify(MyBadgeRow(), named: "badges", size: CGSize(width: 320, height: 44),
///                                    variant: .init(themeID: LumenThemes.standardID, colorScheme: .dark),
///                                    registry: AppTheme.registry, goldenDirectory: goldens)
/// if let message = outcome.failureMessage { XCTFail(message) }
/// ```
///
/// Set `LUMEN_RECORD_SNAPSHOTS=1` to rewrite the goldens. Recording is reported as a failure so a
/// run left in record mode (in CI, say) can never pass by rewriting everything.
///
/// AppKit-backed controls (`Button` with system styles, `List`, `TextField`, `ColorPicker`) can't
/// render offscreen, so subjects should stick to SwiftUI-drawn views.
@MainActor
public enum LumenSnapshot {
    /// One theme variant to render under.
    public struct Variant: Sendable, Hashable {
        public var themeID: String
        public var colorScheme: ColorScheme
        /// Themes for other surfaces, as the gallery's surface pickers allow; missing surfaces
        /// follow the window.
        public var surfaceThemeIDs: [LumenSurface: String]

        public init(themeID: String, colorScheme: ColorScheme, surfaceThemeIDs: [LumenSurface: String] = [:]) {
            self.themeID = themeID
            self.colorScheme = colorScheme
            self.surfaceThemeIDs = surfaceThemeIDs
        }

        /// A file-name label: `standard-dark`, `standard-dark+midnight-editor`.
        public var label: String {
            func short(_ id: String) -> Substring { id.split(separator: ".").last ?? "" }
            let base = "\(short(themeID))-\(colorScheme == .dark ? "dark" : "light")"
            let surfaces = surfaceThemeIDs.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "+\(short($0.value))-\($0.key.rawValue)" }
            return base + surfaces.joined()
        }

        /// Every appearance each of `themes` declares.
        public static func all(for themes: [LumenTheme]) -> [Variant] {
            themes.flatMap { theme in
                theme.supportedAppearances.map { Variant(themeID: theme.id, colorScheme: $0 ? .dark : .light) }
            }
        }
    }

    /// The store a render uses: every built-in theme (hidden ones included) plus `themes`, with
    /// the variant's selections, persisting nothing.
    public static func store(for variant: Variant, registry: LumenRegistry, themes: [LumenTheme] = []) -> LumenThemeStore {
        let store = LumenThemeStore(registry: registry,
                                    configuration: LumenStoreConfiguration(appName: "LumenSnapshot",
                                                                           themesDirectory: URL(fileURLWithPath: "/dev/null/lumen-snapshot")),
                                    themes: registry.builtInThemes + themes, persistsSelection: false)
        store.select(variant.themeID)
        for (surface, id) in variant.surfaceThemeIDs { store.select(id, for: surface) }
        // An unknown id would silently render (and record) the default theme under the wrong name.
        precondition(store.theme().id == variant.themeID, "Snapshot theme \(variant.themeID) isn't a built-in or one of `themes`")
        for (surface, id) in variant.surfaceThemeIDs {
            precondition(store.theme(for: surface).id == id, "Snapshot theme \(id) for \(surface) isn't available")
        }
        return store
    }

    /// How a snapshot is drawn.
    public enum Renderer: Sendable {
        /// `ImageRenderer`, one pass, with `lumenRendersOffscreen` set: fast, and the default.
        case image
        /// A real borderless window that's never shown, on the live code paths
        /// (`lumenRendersOffscreen` off), laid out until it settles and captured at `scale`
        /// whatever the display's backing scale. For
        /// views whose live layout feeds measurements back through preferences, which a one-pass
        /// render can't: `LumenTable`'s natural column widths.
        case window
    }

    /// The view rendered to PNG at `scale`, on the theme's canvas, or `nil` when rendering fails.
    /// - Parameters:
    ///   - themes: extra themes (user or example themes) the variant may name.
    ///   - metrics: the app's metrics, applied as `.lumenMetrics(_:)` would.
    public static func png<Content: View>(of view: Content, size: CGSize, variant: Variant, registry: LumenRegistry,
                                          themes: [LumenTheme] = [], metrics: LumenMetrics = .standard,
                                          scale: CGFloat = 2) -> Data? {
        render(view, size: size, variant: variant, registry: registry, themes: themes, metrics: metrics, scale: scale).png
    }

    /// The view rendered to PNG with `renderer` (see `Renderer`).
    public static func png<Content: View>(of view: Content, size: CGSize, variant: Variant, registry: LumenRegistry,
                                          themes: [LumenTheme] = [], metrics: LumenMetrics = .standard,
                                          scale: CGFloat = 2, renderer: Renderer) -> Data? {
        render(view, size: size, variant: variant, registry: registry, themes: themes, metrics: metrics, scale: scale,
               renderer: renderer).png
    }

    /// The render and the tokens it drew that `registry` doesn't know.
    public static func render<Content: View>(_ view: Content, size: CGSize, variant: Variant, registry: LumenRegistry,
                                      themes: [LumenTheme] = [], metrics: LumenMetrics = .standard,
                                      scale: CGFloat = 2) -> (png: Data?, unknownTokens: Set<LumenToken>) {
        let store = store(for: variant, registry: registry, themes: themes)
        let png = renderPNG(view, size: size, variant: variant, store: store, metrics: metrics, scale: scale)
        return (png, store.unknownTokens)
    }

    /// The render with `renderer` (see `Renderer`) and the tokens it drew that `registry` doesn't
    /// know. Both renderers record unknown tokens the same way.
    public static func render<Content: View>(_ view: Content, size: CGSize, variant: Variant, registry: LumenRegistry,
                                             themes: [LumenTheme] = [], metrics: LumenMetrics = .standard,
                                             scale: CGFloat = 2, renderer: Renderer) -> (png: Data?, unknownTokens: Set<LumenToken>) {
        let store = store(for: variant, registry: registry, themes: themes)
        let png: Data?
        switch renderer {
        case .image: png = renderPNG(view, size: size, variant: variant, store: store, metrics: metrics, scale: scale)
        case .window: png = renderWindowPNG(view, size: size, variant: variant, store: store, metrics: metrics, scale: scale)
        }
        return (png, store.unknownTokens)
    }

    private static func renderPNG<Content: View>(_ view: Content, size: CGSize, variant: Variant, store: LumenThemeStore,
                                                 metrics: LumenMetrics, scale: CGFloat) -> Data? {
        return LumenThemeStore.withActiveStore(store) {
            let palette = store.resolvedPalette()
            let content = view
                .frame(width: size.width, height: size.height)
                .background(palette[.bgCanvas])
                .environment(\.colorScheme, variant.colorScheme)
                .environment(\.lumenPalette, palette)
                .environment(\.lumenStore, store)
                .environment(\.lumenMetrics, metrics)
                .environment(\.lumenRendersOffscreen, true)
                .tint(palette[.accent])   // as `.lumenPaletteRoot()` tints a real window's native controls
            let renderer = ImageRenderer(content: content)
            renderer.scale = scale
            guard let image = renderer.cgImage else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
    }

    @MainActor
    private static func renderWindowPNG<Content: View>(_ view: Content, size: CGSize, variant: Variant, store: LumenThemeStore,
                                                       metrics: LumenMetrics, scale: CGFloat) -> Data? {
        LumenThemeStore.withActiveStore(store) {
            MainActor.assumeIsolated { () -> Data? in
                let palette = store.resolvedPalette()
                let content = view
                    .frame(width: size.width, height: size.height)
                    .background(palette[.bgCanvas])
                    .environment(\.colorScheme, variant.colorScheme)
                    .environment(\.lumenPalette, palette)
                    .environment(\.lumenStore, store)
                    .environment(\.lumenMetrics, metrics)
                    .environment(\.lumenRendersOffscreen, false)
                    // Round layout to the capture's pixel grid, not the display's.
                    .environment(\.displayScale, scale)
                    // The window is never key; draw as the key window does, as the image renderer does.
                    .environment(\.controlActiveState, .key)
                    .tint(palette[.accent])
                let host = NSHostingView(rootView: AnyView(content))
                host.sizingOptions = []
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: variant.colorScheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                window.setContentSize(size)
                defer { window.close() }
                // Preference-driven layout (measured widths) and AppKit text fields take a few passes
                // to settle: capture until two captures in a row are identical (at most ~1.2 s).
                @MainActor func settle(_ passes: Int) {
                    for _ in 0..<passes {
                        host.layoutSubtreeIfNeeded()
                        host.displayIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                    }
                }
                // Capture into a bitmap of exactly `size` × `scale` pixels, whatever the display's
                // backing scale: a 1x screen or a headless runner draws the same pixels as a Retina one.
                let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
                let colorSpace = host.bitmapImageRepForCachingDisplay(in: host.bounds)?.colorSpace ?? .sRGB
                @MainActor func capture() -> NSBitmapImageRep? {
                    guard let blank = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                          let rep = blank.retagging(with: colorSpace) else { return nil }
                    rep.size = host.bounds.size
                    host.cacheDisplay(in: host.bounds, to: rep)
                    return rep
                }
                settle(12)
                var previous = capture()
                var rep = previous
                for _ in 0..<8 {
                    settle(6)
                    rep = capture()
                    if let rep, let previous, rep.tiffRepresentation == previous.tiffRepresentation { break }
                    previous = rep
                }
                return rep?.representation(using: .png, properties: [:])
            }
        }
    }

    public struct Difference: Sendable, CustomStringConvertible {
        public let differingPixelFraction: Double
        public let maxChannelDelta: Int
        public let sizeMismatch: Bool
        /// The share of differing pixels in the densest `patchSize`-pixel square (stepped by half a
        /// patch): a control that vanished or moved is a dense patch however small a share of the
        /// whole image it is.
        public let densestPatchFraction: Double

        public var description: String {
            func percent(_ value: Double) -> String { (value * 100).formatted(.number.precision(.fractionLength(2))) }
            return sizeMismatch ? "size differs"
                : "\(percent(differingPixelFraction))% of pixels differ, \(percent(densestPatchFraction))% in the densest \(LumenSnapshot.patchSize) px patch (max channel delta \(maxChannelDelta))"
        }
    }

    /// The side of the square `Difference.densestPatchFraction` measures, in pixels (16 pt at the
    /// renderer's 2x): about a checkbox or an icon button.
    public nonisolated static let patchSize = 32
    /// The share of a patch allowed to differ in `verify`, on top of its whole-image tolerance. Text
    /// antialiasing noise stays well under it; a control that disappears fills over half a patch.
    public nonisolated static let patchTolerance = 0.25

    /// Compares two PNGs. A pixel differs when any channel moves by more than `channelTolerance`
    /// (absorbs antialiasing and rasterizer noise).
    public nonisolated static func compare(_ a: Data, _ b: Data, channelTolerance: Int = 12) -> Difference {
        guard let pa = rgba(a), let pb = rgba(b), pa.width == pb.width, pa.height == pb.height else {
            return Difference(differingPixelFraction: 1, maxChannelDelta: 255, sizeMismatch: true, densestPatchFraction: 1)
        }
        // Differing pixels are counted per half-patch tile; a patch is 2 × 2 tiles.
        let tile = patchSize / 2
        let columns = (pa.width + tile - 1) / tile, rows = (pa.height + tile - 1) / tile
        var tiles = [Int](repeating: 0, count: columns * rows)
        // Both images are redrawn into the same 8-bit sRGB RGBA layout, so bytes compare directly.
        var differing = 0, maxDelta = 0
        pa.bytes.withUnsafeBufferPointer { x in
            pb.bytes.withUnsafeBufferPointer { y in
                var i = 0
                while i < x.count {
                    var delta = 0
                    for c in 0..<4 { delta = max(delta, abs(Int(x[i + c]) - Int(y[i + c]))) }
                    maxDelta = max(maxDelta, delta)
                    if delta > channelTolerance {
                        differing += 1
                        let pixel = i / 4
                        tiles[(pixel / pa.width / tile) * columns + (pixel % pa.width) / tile] += 1
                    }
                    i += 4
                }
            }
        }
        var densest = 0
        for row in 0..<rows {
            for column in 0..<columns {
                var count = 0
                for (dy, dx) in [(0, 0), (0, 1), (1, 0), (1, 1)] where row + dy < rows && column + dx < columns {
                    count += tiles[(row + dy) * columns + column + dx]
                }
                densest = max(densest, count)
            }
        }
        return Difference(differingPixelFraction: Double(differing) / Double(pa.width * pa.height),
                          maxChannelDelta: maxDelta, sizeMismatch: false,
                          densestPatchFraction: Double(densest) / Double(patchSize * patchSize))
    }

    /// The image's pixels as premultiplied 8-bit sRGB RGBA.
    private nonisolated static func rgba(_ data: Data) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (width, height, bytes) : nil
    }

    /// What `verify` found.
    public enum Outcome: Sendable {
        case matched(Difference)
        case mismatched(Difference)
        case missingGolden(URL)
        case recorded(URL)
        case renderFailed

        /// `nil` only for a match. Recording is a failure on purpose (see the type's notes).
        public var failureMessage: String? {
            switch self {
            case .matched: nil
            case .mismatched(let difference): "Snapshot differs from its golden: \(difference)"
            case .missingGolden(let url): "Missing golden \(url.lastPathComponent); run with LUMEN_RECORD_SNAPSHOTS=1"
            case .recorded(let url): "Recorded \(url.lastPathComponent); review it, then run again without LUMEN_RECORD_SNAPSHOTS"
            case .renderFailed: "The view could not be rendered"
            }
        }
    }

    /// Whether the environment asks to record goldens (`LUMEN_RECORD_SNAPSHOTS=1`).
    public nonisolated static var isRecording: Bool {
        ProcessInfo.processInfo.environment["LUMEN_RECORD_SNAPSHOTS"] == "1"
    }

    /// Renders `view` and compares it with `<goldenDirectory>/<name>@<variant>.png`, or writes
    /// that file when recording.
    /// - Parameter tolerance: the fraction of pixels allowed to differ. However small that is, no
    ///   `patchSize` square may differ by more than `patchTolerance`: a vanished control fails.
    public static func verify<Content: View>(_ view: Content, named name: String, size: CGSize, variant: Variant,
                                             registry: LumenRegistry, themes: [LumenTheme] = [],
                                             metrics: LumenMetrics = .standard, goldenDirectory: URL,
                                             record: Bool = isRecording, tolerance: Double = 0.005) -> Outcome {
        verify(view, named: name, size: size, variant: variant, registry: registry, themes: themes, metrics: metrics,
               goldenDirectory: goldenDirectory, record: record, tolerance: tolerance, renderer: .image)
    }

    /// `verify`, drawn with `renderer` (see `Renderer`).
    public static func verify<Content: View>(_ view: Content, named name: String, size: CGSize, variant: Variant,
                                             registry: LumenRegistry, themes: [LumenTheme] = [],
                                             metrics: LumenMetrics = .standard, goldenDirectory: URL,
                                             record: Bool = isRecording, tolerance: Double = 0.005, renderer: Renderer) -> Outcome {
        let url = goldenDirectory.appending(path: "\(name)@\(variant.label).png")
        guard let rendered = png(of: view, size: size, variant: variant, registry: registry, themes: themes, metrics: metrics,
                                 renderer: renderer) else {
            return .renderFailed
        }
        if record {
            do {
                try FileManager.default.createDirectory(at: goldenDirectory, withIntermediateDirectories: true)
                try rendered.write(to: url)
            } catch {
                return .renderFailed
            }
            return .recorded(url)
        }
        guard let golden = try? Data(contentsOf: url) else { return .missingGolden(url) }
        let difference = compare(rendered, golden)
        let matches = !difference.sizeMismatch && difference.differingPixelFraction <= tolerance
            && difference.densestPatchFraction <= patchTolerance
        return matches ? .matched(difference) : .mismatched(difference)
    }
}

extension EnvironmentValues {
    /// True inside `LumenSnapshot`'s renderer, which can't draw AppKit-backed views (scroll views,
    /// drag sources, context menus). Components drop those modifiers here so golden images show them.
    @Entry var lumenRendersOffscreen = false
    /// Set by `LumenCarousel`: item cards grow to the row's height so siblings share a bottom edge.
    @Entry var lumenMatchesRowHeight = false
}

public extension View {
    /// Draws Lumen components as they render in golden images: scroll views, text fields and menus
    /// give way to static content AppKit can draw offscreen. For an app's own snapshot harness
    /// (`ImageRenderer`); `LumenSnapshot` sets it itself.
    func lumenRendersOffscreen(_ offscreen: Bool = true) -> some View {
        environment(\.lumenRendersOffscreen, offscreen)
    }
}
