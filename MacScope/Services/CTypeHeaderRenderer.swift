import Foundation

/// Clean-room C type-declaration RENDERER — the symmetric inverse of
/// `CTypeHeaderParser`. Turns the workspace type catalog's `TypeDefinition`
/// values back out as C `struct` / `union` / `enum` / `typedef` source so the
/// authored catalog can be exported to a `.h` file and re-imported (round-trip).
///
/// ROUND-TRIP CONTRACT. For any catalog the parser produced, rendering it and
/// re-parsing the text yields the *equivalent* catalog — same kind, name, and
/// ordered fields (ids are freshly minted on each parse, so equivalence is "by
/// value modulo id"). To make that hold exactly the renderer:
///   - emits the catalog's stored field `type` verbatim as the declarator's base
///     type, splitting a trailing pointer (` *`) or array (`[N]`/`[]`) suffix back
///     into declarator syntax (`Node *next;`, `char name[16];`) — the mirror of
///     how the parser folds those suffixes INTO the stored `type`;
///   - emits EVERY enum case with an explicit `= value`. The parser stores the
///     resolved absolute value of each case (auto-increment already applied), so a
///     bare `enum { A, B }` would re-import as `0,1` — correct here, but a catalog
///     whose first case is non-zero (e.g. authored `5,6,7`) only round-trips if the
///     value is written out. Explicit values are always faithful.
///
/// PURE. Like the parser and `DocumentExportService`, this performs no I/O — it
/// returns a `String`. The thin write-to-disk layer lives at the call site.
enum CTypeHeaderRenderer {
    /// Renders the whole catalog to a single C header string, one declaration per
    /// type in catalog order, separated by a blank line. A short banner comment is
    /// prepended so an exported file is self-describing; an empty catalog renders
    /// just the banner with a "no types" note (never an empty/confusing file).
    static func render(types: [TypeDefinition]) -> String {
        var blocks: [String] = [banner]
        if types.isEmpty {
            blocks.append("// No user-defined types are in the workspace type catalog.")
            return blocks.joined(separator: "\n") + "\n"
        }
        for type in types {
            blocks.append(renderType(type))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static let banner =
        "// MacScope type catalog export.\n// Re-importable C type declarations (struct / union / enum / typedef)."

    /// Renders one `TypeDefinition` to its C declaration.
    static func renderType(_ type: TypeDefinition) -> String {
        switch type.kind {
        case .struct:
            return renderRecord(keyword: "struct", type: type)
        case .union:
            return renderRecord(keyword: "union", type: type)
        case .enum:
            return renderEnum(type)
        case .typedef:
            return renderTypedef(type)
        }
    }

    // MARK: - struct / union

    /// `struct Name {\n    <field>;\n    …\n};` — one declarator per field, each
    /// split back into `base name[suffix]` declarator form.
    private static func renderRecord(keyword: String, type: TypeDefinition) -> String {
        var lines = ["\(keyword)\(attributes(type.layoutRules)) \(type.name) {"]
        for field in type.fields {
            lines.append("    " + renderFieldDeclarator(field) + ";")
        }
        lines.append("};")
        let body = lines.joined(separator: "\n")
        if let pack = type.layoutRules.packAlignment {
            return "#pragma pack(push, \(pack))\n" + body + "\n#pragma pack(pop)"
        }
        return body
    }

    private static func attributes(_ rules: AggregateLayoutRules) -> String {
        var values: [String] = []
        if rules.isPacked { values.append("packed") }
        if let alignment = rules.minimumAlignment { values.append("aligned(\(alignment))") }
        return values.isEmpty ? "" : " __attribute__((" + values.joined(separator: ", ") + "))"
    }

    /// Renders one field as a C declarator, undoing the parser's suffix-folding:
    /// a stored type of `Node *` becomes `Node *name`; `char[16]` becomes
    /// `char name[16]`; `void *` becomes `void *name`. A plain primitive/user type
    /// (`int32_t`) becomes `int32_t name`.
    static func renderFieldDeclarator(_ field: FieldDef) -> String {
        var declaration: String
        if field.layoutIsUnknown == true {
            if field.name.isEmpty {
                return "__attribute__((__macscope_unknown_layout__)) unsigned int : 0 /* unsupported original layout */"
            }
            return "__attribute__((__macscope_unknown_layout__)) __macscope_unknown_layout " + field.name + " /* unsupported original layout */"
        }
        if let kind = field.inlineAggregateKind {
            let inner = field.inlineFields.map { renderFieldDeclarator($0) + ";" }.joined(separator: " ")
            declaration = kind.rawValue + attributes(field.inlineAggregateLayoutRules) + " { " + inner + " }"
            if !field.promotesInlineFields { declaration += " " + field.name }
        } else {
            let (base, pointer, array) = splitType(field.type)
            let pointerSpacer = pointer.isEmpty ? " " : " " + pointer
            declaration = base + pointerSpacer + field.name + array
        }
        if let width = field.bitWidth { declaration += " : \(width)" }
        let rules = AggregateLayoutRules(isPacked: field.isPacked == true, minimumAlignment: field.minimumAlignment)
        if field.promotesInlineFields {
            // A trailing attribute on an unnamed inline record belongs to its
            // definition in C. Member attributes must precede the record keyword.
            declaration = attributes(rules).trimmingCharacters(in: .whitespaces) + " " + declaration
            declaration = declaration.trimmingCharacters(in: .whitespaces)
        } else {
            declaration += attributes(rules)
        }
        if let type = field.minimumAlignmentType { declaration = "_Alignas(\(type)) " + declaration }
        if field.isAtomic == true { declaration = "_Atomic " + declaration }
        return declaration
    }

    /// Splits a stored field `type` into its base spelling, a pointer run
    /// (`"*"`, `"**"`, … or empty), and an array suffix (`"[16]"`, `"[]"`, or
    /// empty). The parser builds the stored form as `base + " " + "***" + "[N]"`;
    /// this is the exact inverse.
    static func splitType(_ stored: String) -> (base: String, pointer: String, array: String) {
        var working = stored.trimmingCharacters(in: .whitespaces)

        // Trailing array suffix `[…]` (at most one — the parser only folds one).
        var array = ""
        while working.hasSuffix("]"), let open = working.lastIndex(of: "[") {
            array = String(working[open...]) + array
            working = String(working[..<open]).trimmingCharacters(in: .whitespaces)
        }

        // Trailing pointer run `*`/`**`/… separated from the base by a space.
        var pointer = ""
        while working.hasSuffix("*") {
            pointer = "*" + pointer
            working = String(working.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        return (working, pointer, array)
    }

    // MARK: - enum

    /// `enum Name {\n    Case = value,\n    …\n};` — every case carries an explicit
    /// value so a non-zero-based catalog round-trips faithfully.
    private static func renderEnum(_ type: TypeDefinition) -> String {
        guard type.enumValuesIncomplete != true else {
            return "// Skipped incomplete enum `\(type.name)`: one or more enumerator values are unknown."
        }
        var lines = ["enum \(type.name) {"]
        for (index, field) in type.fields.enumerated() {
            let comma = index == type.fields.count - 1 ? "" : ","
            // `field.type` holds the resolved integer value as a decimal string.
            lines.append("    \(field.name) = \(field.type)\(comma)")
        }
        lines.append("};")
        return lines.joined(separator: "\n")
    }

    // MARK: - typedef

    /// `typedef <base><ptr> Alias;` — the single stored field's `type` is the
    /// aliased base (with any pointer suffix), the type's `name` is the alias.
    private static func renderTypedef(_ type: TypeDefinition) -> String {
        // The parser stores a typedef as a single FieldDef(name: alias, type: base).
        // A zero-field typedef (reachable via TypeEditorSheet authoring) has no aliased
        // base; emitting `typedef void Name;` would synthesize a phantom field that
        // re-imports to a different field count (1 vs 0). Skip it with a diagnostic
        // comment instead so the export stays a faithful round-trip.
        guard let base = type.fields.first?.type else {
            return "// Skipped typedef `\(type.name)`: no aliased base type (zero fields)."
        }
        if type.fields.first?.layoutIsUnknown == true {
            return "typedef __macscope_unknown_layout \(type.name) __attribute__((__macscope_unknown_layout__)); /* unsupported original layout */"
        }
        let (baseName, pointer, array) = splitType(base)
        // `typedef int64_t Alias;` / `typedef char *Alias;` / `typedef int Arr[4];`
        let pointerSpacer = pointer.isEmpty ? " " : " " + pointer
        let vector = type.vectorByteSize.map { " __attribute__((vector_size(\($0))))" } ?? ""
        let atomic = type.fields.first?.isAtomic == true ? "_Atomic " : ""
        return "typedef \(atomic)\(baseName)\(pointerSpacer)\(type.name)\(array)\(vector);"
    }
}
