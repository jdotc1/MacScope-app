import Foundation

/// Emits a deterministic, source-like Swift interface from recovered `SwiftTypeDescriptor` models —
/// the Swift analogue of `ObjectiveCHeaderRenderer`'s class-dump. Pure and order-stable. A field
/// whose type could not be resolved with confidence is rendered WITHOUT a type annotation rather
/// than with a fabricated one (correctness over coverage), so the output never invents a type.
enum SwiftInterfaceRenderer {

    static func render(types: [SwiftTypeDescriptor], conformances: [SwiftConformance] = []) -> String {
        // Protocols per conforming type, order-stable and deduped.
        var protocolsByType: [String: [String]] = [:]
        for conformance in conformances {
            var list = protocolsByType[conformance.typeName] ?? []
            if !list.contains(conformance.protocolName) { list.append(conformance.protocolName) }
            protocolsByType[conformance.typeName] = list
        }
        let renderedNames = Set(types.map(\.name))
        var blocks = types.map { renderType($0, conformances: protocolsByType[$0.name] ?? []) }
        // A conformance whose conforming type is NOT one of the rendered nominal types (e.g. added by
        // an `extension`) — surface as a compact extension so it isn't silently dropped. Order-stable.
        var seenOrphans: Set<String> = []
        for conformance in conformances where !renderedNames.contains(conformance.typeName) {
            guard seenOrphans.insert(conformance.typeName).inserted else { continue }
            let protocols = protocolsByType[conformance.typeName] ?? []
            blocks.append("extension \(conformance.typeName): \(protocols.joined(separator: ", ")) {}")
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func renderType(_ type: SwiftTypeDescriptor, conformances: [String] = []) -> String {
        var declaration = type.kind == .unknown
            ? "/* Swift type with kind \(type.rawKind.map(String.init) ?? "?") */ \(type.name)"
            : "\(type.kind.keyword) \(type.name)"
        if !conformances.isEmpty {
            declaration += ": \(conformances.joined(separator: ", "))"
        }
        var lines = ["\(declaration) {"]
        for field in type.fields {
            lines.append("    " + renderMember(field, in: type.kind))
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func renderMember(_ field: SwiftField, in kind: SwiftTypeKind) -> String {
        if kind == .enum {
            // Enum case; append the associated type only when it resolved cleanly.
            if let type = field.typeName {
                return "case \(field.name)(\(type))"
            }
            return "case \(field.name)"
        }
        let binding = field.isVar ? "var" : "let"
        if let type = field.typeName {
            return "\(binding) \(field.name): \(type)"
        }
        return "\(binding) \(field.name)"
    }
}
