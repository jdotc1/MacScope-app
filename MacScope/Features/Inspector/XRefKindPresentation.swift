import Foundation

/// U7c: how a cross-reference kind reads in the lists: the quiet tag on an inspector reference row,
/// the title of an Xrefs navigator row, and the object kind whose badge that row shows. A class
/// reference (RX-02a `classref`) reads "class ref" and wears the Objective-C class badge; the other
/// kinds keep their names and the cross-reference badge.
enum XRefKindPresentation {
    static func tag(_ kind: String) -> String {
        kind == XRefKind.classref ? "class ref" : kind
    }

    static func title(_ kind: String) -> String {
        let tag = tag(kind)
        return tag.prefix(1).uppercased() + tag.dropFirst()
    }

    static func objectKind(_ kind: String) -> DSObjectKind {
        kind == XRefKind.classref ? .objcClass : .xref
    }

    /// The badge for an Xrefs navigator row, from the glyph the store gave it (`objectKind(_:).symbol`).
    static func badgeKind(forRowSymbol symbol: String) -> DSObjectKind {
        symbol == DSObjectKind.objcClass.symbol ? .objcClass : .xref
    }
}
