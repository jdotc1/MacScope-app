import Foundation

/// Emits a deterministic Objective-C header (`@interface … @end`) from recovered `ObjCClass`
/// models — a standard class-dump artifact. Pure and order-stable;
/// member types come from `ObjCTypeEncoding` (which falls back to `id` rather than guess).
enum ObjectiveCHeaderRenderer {

    static func render(classes: [ObjCClass], categories: [ObjCCategory] = []) -> String {
        (classes.map(renderInterface) + categories.map(renderCategory)).joined(separator: "\n\n")
    }

    /// Renders a category as `@interface Class (Name) … @end`. Categories carry no ivars (they can't
    /// add storage); protocols the category adopts go in the `<…>` clause.
    private static func renderCategory(_ category: ObjCCategory) -> String {
        var lines: [String] = []
        var declaration = "@interface \(category.className) (\(category.name))"
        if !category.adoptedProtocols.isEmpty {
            declaration += " <\(category.adoptedProtocols.joined(separator: ", "))>"
        }
        lines.append(declaration)
        for property in category.properties { lines.append(renderProperty(property)) }
        for method in category.classMethods { lines.append(ObjCTypeEncoding.methodSignature(method)) }
        for method in category.instanceMethods { lines.append(ObjCTypeEncoding.methodSignature(method)) }
        lines.append("@end")
        return lines.joined(separator: "\n")
    }

    private static func renderInterface(_ cls: ObjCClass) -> String {
        var lines: [String] = []

        var declaration = "@interface \(cls.name)"
        if let superclass = cls.superclassName, !superclass.isEmpty {
            declaration += " : \(superclass)"
        }
        if !cls.adoptedProtocols.isEmpty {
            declaration += " <\(cls.adoptedProtocols.joined(separator: ", "))>"
        }
        lines.append(declaration)

        if !cls.ivars.isEmpty {
            lines.append("{")
            for ivar in cls.ivars {
                let type = ivar.typeEncoding.map(ObjCTypeEncoding.decode) ?? "id"
                lines.append("    \(ObjCTypeEncoding.declaration(type: type, name: ivar.name));")
            }
            lines.append("}")
        }

        for property in cls.properties {
            lines.append(renderProperty(property))
        }
        for method in cls.classMethods {
            lines.append(ObjCTypeEncoding.methodSignature(method))
        }
        for method in cls.instanceMethods {
            lines.append(ObjCTypeEncoding.methodSignature(method))
        }

        lines.append("@end")
        return lines.joined(separator: "\n")
    }

    /// Renders `@property (attrs) Type name;` from the raw runtime attribute string. Only the
    /// declaration-relevant attributes are surfaced (atomicity, memory, readonly); accessor and
    /// backing-ivar attributes are omitted.
    private static func renderProperty(_ property: ObjCProperty) -> String {
        var type = "id"
        var attributes: [String] = []
        for component in property.attributes.components(separatedBy: ",") {
            guard let marker = component.first else { continue }
            switch marker {
            case "T": type = ObjCTypeEncoding.decode(String(component.dropFirst()))
            case "R": attributes.append("readonly")
            case "C": attributes.append("copy")
            case "&": attributes.append("strong")
            case "W": attributes.append("weak")
            case "N": attributes.append("nonatomic")
            default: break // G/S (accessors), V (backing ivar), D (dynamic) etc. — not in the decl
            }
        }
        let attributeText = attributes.isEmpty ? "" : "(\(attributes.joined(separator: ", "))) "
        return "@property \(attributeText)\(ObjCTypeEncoding.declaration(type: type, name: property.name));"
    }
}
