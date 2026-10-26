import Foundation

extension PseudocodePrinter {
    /// DP04 C1: user-authored stack local names/types, keyed by the local's entry-SP range
    /// (`MacIRStackStorage.authoringKey`). Only a local whose proven `stackStorage` matches
    /// takes the edit; it renames the declaration and every use (uses resolve through the
    /// local). An invalid identifier, a name another parameter/local already uses, or an
    /// invalid type spelling leaves that field unapplied. Unmatched keys are orphans: kept in
    /// the workspace, never retargeted to another local.
    static func applyingStackLocalOverrides(_ overrides: [String: StackLocalOverride],
                                            to function: MacIRFunction) -> MacIRFunction {
        guard !overrides.isEmpty,
              function.localVariables.contains(where: { $0.stackStorage != nil }) else { return function }
        var function = function
        var occupied = Set(function.parameters.map(\.name) + function.localVariables.map(\.name))
        var renamedByOffset: [Int64: (name: String, type: String)] = [:]
        function.localVariables = function.localVariables.map { local in
            guard let storage = local.stackStorage,
                  let edit = overrides[storage.authoringKey]?.normalized else { return local }
            var local = local
            if let name = edit.name, isCIdentifier(name), !occupied.contains(name) {
                occupied.remove(local.name)
                occupied.insert(name)
                local.name = name
            }
            if let type = edit.typeName, isTypeSpelling(type) { local.type = type }
            renamedByOffset[local.offset] = (local.name, local.type)
            return local
        }
        function.nameBindings = function.nameBindings.map { binding in
            guard case let .stackSlot(offset) = binding.target, let renamed = renamedByOffset[offset] else { return binding }
            return MacIRNameBinding(target: binding.target, name: renamed.name, type: renamed.type, kind: binding.kind)
        }
        return function
    }

    public static func isCIdentifier(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, text.utf8.count <= 128,
              first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
        return text.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    /// A conservative C type spelling: identifier words, spaces and trailing `*`.
    public static func isTypeSpelling(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128, trimmed == text else { return false }
        let base = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
        guard !base.isEmpty, trimmed.drop(while: { $0 != "*" }).allSatisfy({ $0 == "*" || $0 == " " }) else { return false }
        return base.split(separator: " ").allSatisfy { isCIdentifier(String($0)) }
    }
}
