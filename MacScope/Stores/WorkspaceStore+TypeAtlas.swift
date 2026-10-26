import Foundation

/// U7d: user types in the Type Atlas open the existing type editor. "Define Type…" stays where it
/// is (command palette, Go To); the Atlas only edits a type the user already authored.
extension WorkspaceStore {
    /// The workspace definition behind a Type Atlas user-type entry, or `nil` for any other kind.
    func typeDefinition(for entry: TypeAtlasEntry) -> TypeDefinition? {
        guard entry.kind == .userType else { return nil }
        let name: String
        switch entry.id.key {
        case .name(let keyName): name = keyName
        case .address: name = entry.name
        }
        return snapshot.typeDefinitions.first { $0.name == name }
    }

    /// Opens the type editor on the Atlas entry a Types navigator row names. Returns whether the
    /// row was a user type with a definition to edit.
    @discardableResult
    func editTypeAtlasItem(_ itemID: SidebarItem.ID) -> Bool {
        guard let entry = TypeAtlasNavigator.entry(forItemID: itemID, in: typeAtlasCatalog),
              let definition = typeDefinition(for: entry) else { return false }
        beginTypeDefinition(editing: definition)
        return true
    }
}
