import SwiftUI
import LumenTokens
import LumenUI

/// MacScope's symbol boundary: custom Lumen glyphs and SF Symbols share the same names API.
struct DSSymbol: View {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        LumenSymbol(name)
    }
}

extension DS {
    /// Native menus and pickers require an Image, rather than a custom SwiftUI glyph view.
    @MainActor
    static func symbolImage(_ name: String, size: CGFloat = 16) -> Image {
        LumenGlyph.named(name)?.image(size: size) ?? Image(systemName: name)
    }
}

/// The reverse-engineering object kinds MacScope draws, each with one symbol and one color role
/// everywhere (navigator rows, inspector headers, palettes, search results).
enum DSObjectKind: String, CaseIterable, Sendable {
    case function, symbol, importedSymbol, exportedSymbol
    case segment, section, string
    case objcClass, swiftType, cType
    case image, slice, entitlement, signature
    case breakpoint, xref, bookmark

    /// A Lumen glyph or an SF Symbol, rendered through the design-system symbol adapters.
    var symbol: String {
        switch self {
        case .function: "function"
        case .symbol: "number"
        case .importedSymbol: "arrow.down.circle"
        case .exportedSymbol: "arrow.up.circle"
        case .segment: "lumen.memoryMap"
        case .section: "rectangle.split.3x1"
        case .string: "quote.opening"
        case .objcClass: "cube"
        case .swiftType: "cube.transparent"
        case .cType: "curlybraces"
        case .image: "lumen.binaryFile"
        case .slice: "cpu"
        case .entitlement: "key.horizontal"
        case .signature: "checkmark.seal"
        case .breakpoint: "lumen.breakpoint"
        case .xref: "lumen.crossReference"
        case .bookmark: "bookmark"
        }
    }

    /// Kinds whose system stand-in is weakest; the first custom glyphs to draw.
    var customCandidate: Bool {
        switch self {
        case .section, .slice, .swiftType: true
        default: false
        }
    }

    var token: LumenToken {
        switch self {
        case .function: .kindFunction
        case .symbol, .exportedSymbol: .kindSymbol
        case .importedSymbol: .kindImport
        case .segment: .kindSegment
        case .section: .kindSection
        case .string: .kindString
        case .objcClass, .swiftType, .cType: .kindType
        case .image, .slice: .kindImage
        case .entitlement, .signature: .kindSecurity
        case .breakpoint, .xref, .bookmark: .kindDebug
        }
    }

    /// The kind of a navigator item, from its id prefix (`function:`, `xref:`, …). `nil` for
    /// headers (`section:`) and items without an object kind (`debug:`, `extensions:`).
    static func forSidebarItemID(_ id: String) -> DSObjectKind? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        switch id[..<colon] {
        case "function": return .function
        case "symbol": return .symbol
        case "import": return .importedSymbol
        case "export": return .exportedSymbol
        case "string": return .string
        case "xref": return .xref
        case "binary": return .image
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .function: "Function"
        case .symbol: "Symbol"
        case .importedSymbol: "Imported symbol"
        case .exportedSymbol: "Exported symbol"
        case .segment: "Segment"
        case .section: "Section"
        case .string: "String"
        case .objcClass: "Objective-C class"
        case .swiftType: "Swift type"
        case .cType: "C type"
        case .image: "Image"
        case .slice: "Architecture slice"
        case .entitlement: "Entitlement"
        case .signature: "Code signature"
        case .breakpoint: "Breakpoint"
        case .xref: "Cross-reference"
        case .bookmark: "Bookmark"
        }
    }
}

/// Nova-style kind badge: the kind's glyph in its color on a soft tint of the same color. Reads in
/// light and dark themes alike and pairs color with shape, never color alone.
struct DSKindBadge: View {
    /// The tile's tint strength; the validator checks the glyph against the composited tile.
    static let tintOpacity = 0.16

    let kind: DSObjectKind
    var size: CGFloat = 16
    var body: some View {
        LumenSymbolBadge(systemImage: kind.symbol, token: kind.token, label: kind.label, size: size)
    }
}

#Preview("Kind badges") {
    VStack(alignment: .leading, spacing: Lumen.Space.s3) {
        ForEach(DSObjectKind.allCases, id: \.self) { kind in
            HStack(spacing: Lumen.Space.s4) {
                DSKindBadge(kind: kind)
                Text(kind.label).font(Lumen.Font.body)
            }
        }
    }
    .padding(Lumen.Space.s8)
}
