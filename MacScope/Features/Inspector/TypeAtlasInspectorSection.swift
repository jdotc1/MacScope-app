import Foundation
import LumenTokens
import LumenUI
import SwiftUI

/// U7a/U7b: what the inspector shows for the Type Atlas entry selected in the Types navigator.
/// A summary card (kind, name, the class it builds on, layout, counts), an overview, the stored
/// members with offsets, types and evidence, the methods with their implementations, a Swift
/// type's protocol witness tables and a protocol's declared properties.
/// Layout is stated honestly: offsets and sizes only where the metadata records them, otherwise
/// "Unknown layout", never a guess.
struct TypeAtlasInspectorReading: Equatable {
    struct Row: Equatable {
        var label: String
        var value: String
        var isMonospaced = false
        var allowsWrapping = false
    }

    typealias MemberRow = DSTypeMemberRow

    struct MethodRow: Identifiable, Equatable {
        let id: Int
        /// `-computeValue` / `+make` for Objective-C; the bare name otherwise. A Swift table
        /// record is named by the symbol at its implementation when the image has one, else by
        /// its positional label ("vtable #3 (name unknown)"); tables record no source names.
        var signature: String
        var implementation: UInt64?
        /// What kind of record the row is: "required"/"optional" for a protocol requirement,
        /// the Swift table ("vtable", "override", "witness", with "static" for a class method).
        var badge: String? = nil
    }

    /// One protocol a Swift type conforms to and that conformance's witness table.
    struct WitnessGroup: Identifiable, Equatable {
        var id: Int
        var protocolName: String
        var methods: [MethodRow]
        /// Why no witnesses are listed: the table was not resolved, or records none.
        var note: String?
    }

    var kind: String
    var title: String
    /// The class this entry builds on: a superclass, or the class a category extends.
    var link: String?
    var detail: String
    var stats: [LumenStat]
    var rows: [Row]
    var membersTitle: String
    var members: [MemberRow]
    /// Why some or all member offsets are missing; `nil` when every offset is known.
    var layoutNote: String?
    var methods: [MethodRow]
    /// Set when the Swift class method table could not be resolved, so an empty or short list
    /// isn't read as "no methods".
    var methodsNote: String?
    var witnesses: [WitnessGroup]
    var properties: [Row]

    static let unknownMark = DSTypeMemberRow.unknownMark
    static let unresolvedMethodTableNote = "Method table not resolved: this class's vtable layout isn't supported, so its methods aren't listed."
    static let unresolvedWitnessTableNote = "Witness table not resolved."
    static let emptyWitnessTableNote = "No witnesses recorded."

    /// `implementationNames` names Swift table records by the symbol (or the user's name) at
    /// their implementation; see `swiftImplementationAddresses`.
    init(_ entry: TypeAtlasEntry, implementationNames: [UInt64: String] = [:]) {
        kind = entry.kind.label
        title = entry.name
        link = entry.superclass.flatMap { $0.isEmpty ? nil : $0 }
        var detail: [String] = []
        if case .address(let address) = entry.id.key { detail.append(address.hexAddress) }
        detail.append(Self.layout(entry))
        self.detail = detail.joined(separator: " · ")
        membersTitle = entry.kind == .swiftEnum ? "Cases" : "Members"
        stats = [
            LumenStat(membersTitle, count: entry.members.count),
            LumenStat("Methods", count: entry.methods.count),
            LumenStat("Users", count: entry.users.count),
        ]

        var rows: [Row] = []
        if let link {
            rows.append(Row(label: entry.kind == .objcCategory ? "Extends" : "Superclass", value: link))
        }
        rows.append(Row(label: "Layout", value: Self.layout(entry)))
        if !entry.conformances.isEmpty {
            rows.append(Row(label: "Conforms to", value: entry.conformances.joined(separator: ", ")))
        }
        rows.append(Row(label: "Evidence", value: entry.evidence.label))
        if let imported = entry.imported {
            rows += [
                Row(label: "Declaration", value: entry.name),
                Row(label: "Archive", value: imported.identity.archiveSHA256, isMonospaced: true),
                Row(label: "Declaration ID", value: imported.identity.declarationID, isMonospaced: true),
                Row(label: "Target", value: imported.targetTriple),
                Row(label: "Configuration", value: imported.configurationID, isMonospaced: true),
                Row(label: "SDK", value: imported.sdkIdentity),
                Row(label: "Compiler", value: imported.compiler),
                Row(label: "Compiler version", value: imported.compilerVersion),
                Row(label: "libclang", value: imported.libclangVersion),
                Row(label: "Language", value: imported.language),
                Row(label: "Extractor", value: imported.extractorVersion),
                Row(label: "Input", value: imported.input),
                Row(label: "Type kind", value: imported.recordKind ?? imported.typeKind),
                Row(label: "Layout status", value: imported.layoutStatus),
                Row(label: "Alignment", value: imported.alignmentBytes.map { "\($0) bytes" } ?? "Unknown"),
            ]
            if let header = imported.sourceHeader {
                var source = header
                if let line = imported.sourceLine { source += ":\(line)" }
                if let column = imported.sourceColumn { source += ":\(column)" }
                rows.append(Row(label: "Source", value: source))
            }
            if let reason = imported.layoutReason { rows.append(Row(label: "Layout reason", value: reason)) }
            rows = rows.map { row in var copy = row; copy.allowsWrapping = true; return copy }
        }
        self.rows = rows

        members = entry.members.enumerated().map { index, member in
            MemberRow(
                id: index,
                offset: member.offset.map { String(format: "+0x%llX", $0) } ?? Self.unknownMark,
                name: member.name,
                type: member.type.flatMap { $0.isEmpty ? nil : $0 } ?? Self.unknownMark,
                evidence: member.evidence.label,
                evidenceSymbol: member.evidence.symbol,
                allowsWrapping: member.imported != nil,
                detail: Self.importedMemberDetail(member)
            )
        }
        layoutNote = Self.layoutNote(entry)

        let objc = entry.kind == .objcClass || entry.kind == .objcCategory
        methods = entry.methods.enumerated().map { index, method in
            Self.methodRow(method, id: index, objc: objc, implementationNames: implementationNames)
        }
        methodsNote = entry.swiftMethodTableResolved == false ? Self.unresolvedMethodTableNote : nil
        witnesses = (entry.swiftConformanceMethods ?? []).enumerated().map { index, conformance in
            let rows = (conformance.methods ?? []).enumerated().map { methodIndex, method in
                Self.methodRow(method, id: methodIndex, objc: false, implementationNames: implementationNames)
            }
            let note: String? = switch conformance.methods {
            case nil: Self.unresolvedWitnessTableNote
            case let methods? where methods.isEmpty: Self.emptyWitnessTableNote
            default: nil
            }
            return WitnessGroup(id: index, protocolName: conformance.protocolName, methods: rows, note: note)
        }
        properties = (entry.declaredProperties ?? []).map {
            Row(label: $0.name, value: $0.attributes.isEmpty ? Self.unknownMark : $0.attributes, isMonospaced: true)
        }
    }

    static func importedMemberDetail(_ member: TypeAtlasMember) -> String? {
        guard let imported = member.imported else { return nil }
        var parts = ["Absolute bit position: \(imported.absoluteBitOffset.map { String($0) } ?? "unknown")"]
        if let width = imported.bitWidth { parts.append("Bit width: \(width)") }
        if imported.flexibleArray { parts.append("Flexible-array extent: unknown") }
        if imported.anonymous { parts.append("Anonymous member") }
        return parts.joined(separator: " · ")
    }

    private static func methodRow(
        _ method: TypeAtlasMethod,
        id: Int,
        objc: Bool,
        implementationNames: [UInt64: String]
    ) -> MethodRow {
        if let table = method.swiftMetadata {
            // A named row keeps the table position in its badge; an unnamed one already says it.
            let symbol = method.implementation.flatMap { implementationNames[$0] }
            var badge = symbol == nil ? table.source.rawValue : "\(table.source.rawValue) #\(table.index)"
            if table.isInstance == false { badge += " · static" }
            return MethodRow(id: id, signature: symbol ?? method.name, implementation: method.implementation, badge: badge)
        }
        let badge = method.isOptionalRequirement.map { $0 ? "optional" : "required" }
        let signature = objc || method.isOptionalRequirement != nil
            ? (method.isClassMethod ? "+" : "-") + method.name : method.name
        return MethodRow(id: id, signature: signature, implementation: method.implementation, badge: badge)
    }

    /// The implementations of the entry's Swift table records, the only addresses whose names
    /// the reading needs.
    static func swiftImplementationAddresses(_ entry: TypeAtlasEntry) -> Set<UInt64> {
        let methods = entry.methods + (entry.swiftConformanceMethods ?? []).flatMap { $0.methods ?? [] }
        return Set(methods.compactMap { $0.swiftMetadata == nil ? nil : $0.implementation })
    }

    /// "24 bytes" from `instanceSize`; otherwise "Unknown layout", or "Unknown size" when every
    /// member offset is still known.
    static func layout(_ entry: TypeAtlasEntry) -> String {
        if let size = entry.instanceSize { return "\(size) byte\(size == 1 ? "" : "s")" }
        if entry.imported != nil { return "Unknown layout" }
        let offsetsKnown = !entry.members.isEmpty && entry.members.allSatisfy { $0.offset != nil }
        return offsetsKnown ? "Unknown size" : "Unknown layout"
    }

    static func layoutNote(_ entry: TypeAtlasEntry) -> String? {
        if let imported = entry.imported {
            var notes: [String] = []
            if let reason = imported.layoutReason { notes.append("Unknown layout: " + reason) }
            if entry.members.contains(where: { $0.imported?.absoluteBitOffset == nil }) {
                notes.append("Missing imported offsets remain unknown; no authored layout is substituted.")
            }
            if entry.members.contains(where: { $0.imported?.flexibleArray == true }) {
                notes.append("Flexible-array extent is unknown; the enclosing size is the compiler-recorded size.")
            }
            return notes.isEmpty ? nil : notes.joined(separator: " ")
        }
        let unknown = entry.members.filter { $0.offset == nil }.count
        if unknown == 0 { return nil }
        if unknown == entry.members.count {
            return "Unknown layout: the image records no offsets for these \(entry.kind == .swiftEnum ? "cases" : "members")."
        }
        return "Partly unknown layout: rows marked — have no offset recorded in the image."
    }

    struct UserRow: Identifiable, Equatable {
        var id: UInt64 { address }
        var address: UInt64
        /// The containing function and offset (`main+0x14`), or the bare address outside any.
        var label: String
    }

    static let userRowLimit = 50

    /// The type's users as reference rows, by the function each sits in: at most `limit`, in
    /// address order, plus how many more were not listed.
    static func userRows(
        _ users: [UInt64],
        functions: [FunctionSummary],
        name: (FunctionSummary) -> String,
        limit: Int = userRowLimit
    ) -> (rows: [UserRow], notListed: Int) {
        let sorted = Array(Set(users)).sorted()
        let rows = sorted.prefix(limit).map { address -> UserRow in
            guard let function = functions.first(where: { address >= $0.startAddress && address < $0.endAddress }) else {
                return UserRow(address: address, label: address.hexAddress)
            }
            let offset = address - function.startAddress
            return UserRow(address: address, label: offset == 0 ? name(function) : "\(name(function))+0x\(String(offset, radix: 16, uppercase: true))")
        }
        return (rows, max(0, sorted.count - limit))
    }

    /// Whether an entry with no users still shows the Users section, so "none found" is said
    /// rather than implied: the kinds whose users the Atlas looks for.
    static func listsUsers(_ entry: TypeAtlasEntry) -> Bool {
        !entry.users.isEmpty || entry.kind == .objcClass || entry.kind == .userType
    }

    /// The navigator row of the entry `link` names in `catalog`: the class it builds on, when that
    /// class is in the Atlas (same image, or a user type).
    static func linkedItemID(for entry: TypeAtlasEntry, in catalog: ImageTypeCatalog) -> SidebarItem.ID? {
        guard let name = entry.superclass, !name.isEmpty else { return nil }
        let classKinds: [TypeAtlasKind] = [.objcClass, .swiftClass, .swiftStruct, .swiftEnum, .userType]
        guard let target = catalog.entries(named: name).min(by: {
            (classKinds.firstIndex(of: $0.kind) ?? .max) < (classKinds.firstIndex(of: $1.kind) ?? .max)
        }), target.id != entry.id, classKinds.contains(target.kind) else { return nil }
        return TypeAtlasNavigator.itemID(for: target.id)
    }
}

extension TypeAtlasEvidence {
    var symbol: String {
        switch self {
        case .descriptor: "checkmark.seal"
        case .staticEvaluation: "function"
        case .authored: "pencil"
        case .compilerImport: "archivebox"
        case .unknown: "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .descriptor: "Compiler metadata"
        case .staticEvaluation: "Static evaluation"
        case .authored: "Authored"
        case .compilerImport: "Compiler import"
        case .unknown: "Unknown"
        }
    }
}

/// The selected type's summary card and sections, in inspector order.
struct TypeAtlasInspector: View {
    @ObservedObject var store: WorkspaceStore
    let entry: TypeAtlasEntry

    var body: some View {
        let slot = entry.id.slot
        let reading = TypeAtlasInspectorReading(entry, implementationNames: implementationNames(in: slot))
        let linked = TypeAtlasInspectorReading.linkedItemID(for: entry, in: store.typeAtlasCatalog)
        LumenInspectorSummary(
            kind: reading.kind,
            hue: .kindType,
            title: reading.title,
            link: reading.link,
            detail: reading.detail,
            stats: reading.stats,
            onOpenLink: linked.map { itemID in { store.activateSidebarItem(itemID) } }
        )
        .padding(Lumen.Space.s4)
        .accessibilityIdentifier("typeAtlas.inspector.summary")

        InspectorSection(id: .typeAtlas, title: "Overview", systemImage: entry.kind.systemImage) {
            VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                ForEach(Array(reading.rows.enumerated()), id: \.offset) { _, row in
                    MetadataRow(label: row.label, value: row.value, isMonospaced: row.isMonospaced, allowsWrapping: row.allowsWrapping)
                }
                // U7d: a user type opens the existing editor; Define Type… stays where it is.
                if let definition = store.typeDefinition(for: entry) {
                    Button("Edit Type…") { store.beginTypeDefinition(editing: definition) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, Lumen.Space.s2)
                        .accessibilityIdentifier("typeAtlas.editType")
                }
            }
            .padding(.vertical, AppInspectorChrome.valueGroupVerticalPadding)
        }

        if !reading.members.isEmpty {
            InspectorSection(id: .typeMembers, title: reading.membersTitle, systemImage: "list.bullet.rectangle") {
                DSTypeMembersTable(rows: reading.members, note: reading.layoutNote)
            }
        }

        if !reading.methods.isEmpty || reading.methodsNote != nil {
            InspectorSection(id: .typeMethods, title: "Methods", systemImage: "function") {
                VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                    methodRows(reading.methods, identifierPrefix: "typeAtlas.method")
                    if let note = reading.methodsNote {
                        noteText(note, identifier: "typeAtlas.methods.note")
                    }
                }
                .padding(.vertical, AppInspectorChrome.valueGroupVerticalPadding)
            }
        }

        if !reading.witnesses.isEmpty {
            InspectorSection(id: .typeWitnesses, title: "Protocol Witnesses", systemImage: "checklist") {
                VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                    ForEach(reading.witnesses) { group in
                        VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                            Text(group.protocolName)
                                .font(.caption.weight(.semibold))
                                .accessibilityIdentifier("typeAtlas.witness.\(group.id)")
                            methodRows(group.methods, identifierPrefix: "typeAtlas.witness.\(group.id).method")
                            if let note = group.note {
                                noteText(note, identifier: "typeAtlas.witness.\(group.id).note")
                            }
                        }
                    }
                }
                .padding(.vertical, AppInspectorChrome.valueGroupVerticalPadding)
            }
        }

        if !reading.properties.isEmpty {
            InspectorSection(id: .typeProperties, title: "Properties", systemImage: "list.bullet") {
                VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                    ForEach(Array(reading.properties.enumerated()), id: \.offset) { _, row in
                        MetadataRow(label: row.label, value: row.value, isMonospaced: row.isMonospaced, allowsWrapping: row.allowsWrapping)
                    }
                }
                .padding(.vertical, AppInspectorChrome.valueGroupVerticalPadding)
            }
        }

        if TypeAtlasInspectorReading.listsUsers(entry) {
            let users = TypeAtlasInspectorReading.userRows(
                entry.users,
                functions: store.snapshot.analysis(in: slot)?.functions ?? [],
                name: { store.snapshot.displayName(at: $0.startAddress, in: slot, default: $0.name) }
            )
            InspectorSection(id: .typeUsers, title: "Users", systemImage: "lumen.crossReference") {
                VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                    if users.rows.isEmpty {
                        Text(entry.kind == .userType ? "Not applied to any address in this image." : "No uses found in this image.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(users.rows) { user in
                        LumenReferenceRow("\(user.label)  \(user.address.hexAddress)", kind: entry.kind == .userType ? "applied" : nil) {
                            store.goToAddress(user.address, in: slot)
                        }
                        .accessibilityIdentifier("typeAtlas.user.\(user.address.hexAddress)")
                    }
                    if users.notListed > 0 {
                        Text("\(users.notListed) more not listed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, AppInspectorChrome.valueGroupVerticalPadding)
            }
        }
    }

    @ViewBuilder
    private func methodRows(_ methods: [TypeAtlasInspectorReading.MethodRow], identifierPrefix: String) -> some View {
        ForEach(methods) { method in
            if let implementation = method.implementation {
                LumenReferenceRow("\(method.signature)  \(implementation.hexAddress)", kind: method.badge ?? "IMP") {
                    store.goToAddress(implementation, in: entry.id.slot)
                }
                .accessibilityIdentifier("\(identifierPrefix).\(method.id)")
            } else {
                MetadataRow(
                    label: method.signature,
                    value: method.badge.map { "\($0) · no implementation in this image" } ?? "No implementation in this image"
                )
            }
        }
    }

    /// One pass over the image's symbols for just the Swift implementations listed; a user's
    /// name at the address wins, as everywhere else.
    private func implementationNames(in slot: ImageSlot) -> [UInt64: String] {
        let wanted = TypeAtlasInspectorReading.swiftImplementationAddresses(entry)
        guard !wanted.isEmpty else { return [:] }
        var names: [UInt64: String] = [:]
        for symbol in store.snapshot.analysis(in: slot)?.symbols ?? [] {
            guard let address = symbol.address, wanted.contains(address), names[address] == nil,
                  !symbol.name.isEmpty else { continue }
            names[address] = symbol.name
        }
        for address in wanted {
            let name = store.snapshot.displayName(at: address, in: slot, default: names[address] ?? "")
            names[address] = name.isEmpty ? nil : name
        }
        return names
    }

    private func noteText(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }
}
