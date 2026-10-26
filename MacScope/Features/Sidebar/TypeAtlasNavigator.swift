import Foundation

/// U7a: the Type Atlas tool's navigator rows over one image's `ImageTypeCatalog` (RX-02a). One
/// count section per kind that has entries, in a fixed order, and one row per entry. Row ids are
/// `typeAtlas.<kind>:<key>`, so they double as the rows' accessibility identifiers and give the
/// kind badge its kind; the key is the entry's metadata address, or its name when it has none.
enum TypeAtlasNavigator {
    static let itemPrefix = "typeAtlas."
    static let sectionPrefix = "section:typeAtlas."

    /// Sections in the order they are listed: classes first, the name-only protocols and the
    /// user's own types last.
    static let kindOrder: [TypeAtlasKind] = [
        .objcClass, .swiftClass, .swiftStruct, .swiftEnum, .objcCategory, .objcProtocol, .userType, .importedType,
    ]

    static func itemID(for id: TypeAtlasEntryID) -> SidebarItem.ID {
        switch id.key {
        case .address(let address): "\(itemPrefix)\(id.kind.rawValue):\(address.hexAddress)"
        case .name(let name): "\(itemPrefix)\(id.kind.rawValue):name:\(name)"
        }
    }

    static func sectionID(for kind: TypeAtlasKind) -> SidebarItem.ID { sectionPrefix + kind.rawValue }

    static func isEntryItem(_ itemID: SidebarItem.ID) -> Bool { itemID.hasPrefix(itemPrefix) }

    /// The kind a row or section id names, or `nil` for any other id.
    static func kind(forItemID itemID: SidebarItem.ID) -> TypeAtlasKind? {
        let rest: Substring
        if itemID.hasPrefix(sectionPrefix) {
            rest = itemID.dropFirst(sectionPrefix.count)
        } else if itemID.hasPrefix(itemPrefix) {
            rest = itemID.dropFirst(itemPrefix.count).prefix { $0 != ":" }
        } else {
            return nil
        }
        return TypeAtlasKind(rawValue: String(rest))
    }

    static func entry(forItemID itemID: SidebarItem.ID, in catalog: ImageTypeCatalog) -> TypeAtlasEntry? {
        guard isEntryItem(itemID) else { return nil }
        return catalog.entries.first { self.itemID(for: $0.id) == itemID }
    }

    static func items(for catalog: ImageTypeCatalog) -> [SidebarItem] {
        let byKind = Dictionary(grouping: catalog.entries, by: \.kind)
        var items: [SidebarItem] = []
        for kind in kindOrder {
            guard let entries = byKind[kind], !entries.isEmpty else { continue }
            items.append(SidebarItem(
                id: sectionID(for: kind),
                title: kind.sectionTitle,
                detail: kind == .importedType ? "\(entries.count) imported declarations" : "\(entries.count) in this image",
                systemImage: kind.systemImage
            ))
            items += entries
                .sorted {
                    let order = $0.name.localizedStandardCompare($1.name)
                    if order == .orderedSame, $0.imported != nil, $1.imported != nil {
                        return itemID(for: $0.id) < itemID(for: $1.id)
                    }
                    return order == .orderedAscending
                }
                .map { SidebarItem(id: itemID(for: $0.id), title: $0.name, detail: detail(for: $0), systemImage: kind.systemImage) }
        }
        return items
    }

    /// The row's second line: what the type is built on, then how much is known about it. The
    /// filter matches it too, so "NSObject" or "Equatable" finds subclasses and conformers.
    static func detail(for entry: TypeAtlasEntry) -> String {
        var parts: [String] = []
        if let imported = entry.imported {
            parts += ["Compiler import", "Archive \(imported.identity.archiveSHA256)",
                      imported.identity.declarationID, imported.targetTriple,
                      "Layout: \(imported.layoutStatus)"]
        }
        if let superclass = entry.superclass, !superclass.isEmpty {
            // A category's "superclass" is the class it extends.
            parts.append(entry.kind == .objcCategory ? "on \(superclass)" : ": \(superclass)")
        } else if !entry.conformances.isEmpty {
            parts.append(entry.conformances.joined(separator: ", "))
        }
        if !entry.members.isEmpty { parts.append(counted(entry.members.count, entry.kind == .swiftEnum ? "case" : "member")) }
        if !entry.methods.isEmpty { parts.append(counted(entry.methods.count, "method")) }
        if !entry.users.isEmpty { parts.append(counted(entry.users.count, "user")) }
        if parts.isEmpty, case .address(let address) = entry.id.key { parts.append(address.hexAddress) }
        return parts.isEmpty ? entry.kind.label : parts.joined(separator: " · ")
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

extension TypeAtlasKind {
    var label: String {
        switch self {
        case .swiftClass: "Swift class"
        case .swiftStruct: "Swift struct"
        case .swiftEnum: "Swift enum"
        case .objcClass: "Objective-C class"
        case .objcCategory: "Objective-C category"
        case .objcProtocol: "Objective-C protocol"
        case .userType: "User type"
        case .importedType: "Imported type"
        }
    }

    var sectionTitle: String {
        switch self {
        case .swiftClass: "Swift Classes"
        case .swiftStruct: "Swift Structs"
        case .swiftEnum: "Swift Enums"
        case .objcClass: "Objective-C Classes"
        case .objcCategory: "Categories"
        case .objcProtocol: "Protocols"
        case .userType: "User Types"
        case .importedType: "Imported Types"
        }
    }

    /// The design-system object kind that badges this kind's rows.
    var objectKind: DSObjectKind {
        switch self {
        case .objcClass, .objcCategory, .objcProtocol: .objcClass
        case .swiftClass, .swiftStruct, .swiftEnum: .swiftType
        case .userType, .importedType: .cType
        }
    }

    var systemImage: String { objectKind.symbol }
}
