import AppKit
import SwiftUI
import LumenTokens

/// An app icon in macOS's icon grid: a Lumen tile at 824 of 1024 points, centered, with the standard
/// soft drop shadow. Any symbol or glyph name works, in any hue.
public struct LumenAppIcon: View {
    private let systemImage: String
    private let hue: LumenToken
    private let size: CGFloat

    public init(_ systemImage: String, hue: LumenToken, size: CGFloat = 1024) {
        self.systemImage = systemImage
        self.hue = hue
        self.size = size
    }

    public var body: some View {
        LumenIconTile(systemImage, hue: hue, size: size * 824 / 1024)
            .shadow(color: .black.opacity(0.28), radius: size * 10 / 1024, y: size * 10 / 1024)
            .frame(width: size, height: size)
    }
}

/// The running app's Dock icon, drawn from a Lumen tile in the current theme. For internal apps
/// built without an icon asset.
public enum LumenDockIcon {
    /// The icon as an image, 512 points at 2× (1024 pixels).
    @MainActor
    public static func image(_ systemImage: String, hue: LumenToken, colorScheme: ColorScheme = .light) -> NSImage? {
        let renderer = ImageRenderer(content: LumenAppIcon(systemImage, hue: hue, size: 512).environment(\.colorScheme, colorScheme))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 512, height: 512))
    }

    /// Sets the Dock icon for this run of the app. Call it again after a theme change to recolor it.
    @MainActor
    public static func apply(_ systemImage: String, hue: LumenToken, colorScheme: ColorScheme = .light) {
        if let image = image(systemImage, hue: hue, colorScheme: colorScheme) {
            NSApplication.shared.applicationIconImage = image
        }
    }
}
