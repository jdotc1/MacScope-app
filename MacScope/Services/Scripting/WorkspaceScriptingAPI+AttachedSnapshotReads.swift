import Foundation

extension WorkspaceScriptingAPI {
    /// The remaining attached reads share the request-owned snapshot worker. Preserve legacy
    /// replies inside the budget; refuse excessive work explicitly instead of returning a
    /// truncated result that looks complete. Nothing here touches the live store.
    nonisolated static func attachedSnapshotRead(
        _ command: String,
        arguments: ScriptValue,
        snapshot: WorkspaceSnapshot,
        commandCatalog: [ScriptingCommandInfo] = [],
        checkpoint: () throws -> Void
    ) throws -> ScriptValue {
        try checkpoint()
        var work = 0
        func step() throws {
            guard work < maximumSnapshotSelectionWork else {
                throw ScriptingError.invalidArgument("\(command) exceeds the snapshot work budget")
            }
            if work % checkpointInterval == 0 { try checkpoint() }
            work += 1
        }
        func append(_ row: ScriptValue, to rows: inout [ScriptValue]) throws {
            guard rows.count < maximumSnapshotRows else {
                throw ScriptingError.invalidArgument("\(command) exceeds the snapshot result budget")
            }
            rows.append(row)
        }
        func checkRows(_ count: Int) throws {
            guard count <= maximumSnapshotRows else {
                throw ScriptingError.invalidArgument("\(command) exceeds the snapshot result budget")
            }
        }
        switch command {
        case "commands":
            var rows: [ScriptValue] = []
            for info in commandCatalog {
                try step()
                try append(.object([
                    "name": .string(info.name), "summary": .string(info.summary),
                    "mutates": .bool(info.mutates),
                    "arguments": .array(info.arguments.map(ScriptValue.string)),
                ]), to: &rows)
            }
            return .array(rows)

        case "info":
            let binary = snapshot.binaries.first
            return .object([
                "name": .string(binary?.name ?? ""),
                "format": .string(binary?.kind ?? ""),
                "architecture": .string(binary?.architecture ?? ""),
                "functionCount": .int(Int64(snapshot.functions.count)),
                "instructionCount": .int(Int64(snapshot.instructions.count)),
                "symbolCount": .int(Int64(snapshot.symbols.count)),
                "stringCount": .int(Int64(snapshot.stringLiterals.count)),
            ])

        case "name-at":
            let target = try address(arguments, "address")
            var parsed: String?
            for function in snapshot.functions {
                try step()
                if function.startAddress == target { parsed = function.name; break }
            }
            if parsed == nil {
                for symbol in snapshot.symbols {
                    try step()
                    if symbol.address == target { parsed = symbol.name; break }
                }
            }
            let name = snapshot.displayName(at: target, default: parsed ?? "")
            return name.isEmpty ? .null : .string(name)

        case "resolve-symbol":
            guard let value = arguments["name"] else { throw ScriptingError.missingArgument("name") }
            guard let name = value.stringValue else { throw ScriptingError.invalidArgument("name must be a string") }
            let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, let analysis = snapshot.analysis(in: snapshot.primarySlot) else { return .null }
            func matches(_ candidate: String) -> Bool {
                if candidate.caseInsensitiveCompare(query) == .orderedSame { return true }
                let candidate = candidate.hasPrefix("_") ? String(candidate.dropFirst()) : candidate
                let query = query.hasPrefix("_") ? String(query.dropFirst()) : query
                return !query.isEmpty && candidate.caseInsensitiveCompare(query) == .orderedSame
            }
            for function in analysis.functions {
                try step()
                let authored = snapshot.addressOverrides[
                    ImageAddress(slot: snapshot.primarySlot, address: function.startAddress)
                ]?.customName
                if matches(authored ?? function.name) || matches(function.name) { return .hex(function.startAddress) }
            }
            for item in analysis.exports {
                try step()
                if matches(item.name) { return item.address.map(ScriptValue.hex) ?? .null }
            }
            for item in analysis.symbols {
                try step()
                if let address = item.address, matches(item.name) { return .hex(address) }
            }
            return .null

        case "callers", "callees":
            // `imageSlot` filters the graph to one image; unfiltered reads keep the primary image.
            // Either way each row names the image that produced it.
            let filter = try resolveImageSlotFilter(arguments, snapshot: snapshot)
            let view = filter.map { imageProjection(of: snapshot, in: $0) } ?? snapshot
            let function = try boundedSnapshotFunction(arguments, snapshot: view, checkpoint: checkpoint)
            let range = view.functionRange(function)
            let rowSlot = filter ?? view.primarySlot
            var seen = Set<[UInt64]>()
            var rows: [ScriptValue] = []
            for ref in view.xrefs {
                try step()
                guard ref.kind == XRefKind.call,
                      range.contains(command == "callers" ? ref.to : ref.from),
                      seen.insert([ref.from, ref.to]).inserted else { continue }
                try append(callEdgeRow(ref, slot: rowSlot), to: &rows)
            }
            return .array(rows)

        case "xrefs":
            return try snapshotXRefRead(arguments, snapshot: snapshot, checkpoint: checkpoint)

        case "register-names":
            let function = try boundedSnapshotFunction(arguments, snapshot: snapshot, checkpoint: checkpoint)
            let raw = snapshot.addressOverrides[
                ImageAddress(slot: snapshot.primarySlot, address: function.startAddress)
            ]?.registerNames ?? [:]
            try checkRows(raw.count)
            let names = snapshot.registerNameOverrides(forProcedureAt: function.startAddress)
            var renames: [String: ScriptValue] = [:]
            for (register, name) in names { try step(); renames[register] = .string(name) }
            return .object(["address": .hex(function.startAddress), "renames": .object(renames)])

        case "local-labels":
            var labels: [(UInt64, String)] = []
            for (key, override) in snapshot.addressOverrides {
                try step()
                guard key.slot == snapshot.primarySlot,
                      let label = override.localLabel, !label.isEmpty else { continue }
                try checkRows(labels.count + 1)
                labels.append((key.address, label))
            }
            labels.sort { $0.0 < $1.0 }
            var rows: [ScriptValue] = []
            for (address, label) in labels {
                try step()
                try append(.object(["address": .hex(address), "label": .string(label)]), to: &rows)
            }
            return .array(rows)

        case "manual-xrefs":
            var rows: [ScriptValue] = []
            for edit in snapshot.manualXRefs {
                try step()
                guard edit.imageSlot == snapshot.primarySlot else { continue }
                try append(.object([
                    "from": .hex(edit.from), "to": .hex(edit.to), "kind": .string(edit.kind),
                    "suppressed": .bool(edit.isSuppression),
                ]), to: &rows)
            }
            return .array(rows)

        case "bookmarks":
            var bookmarks: [Bookmark] = []
            for bookmark in snapshot.bookmarks {
                try step()
                guard bookmark.imageSlot == snapshot.primarySlot else { continue }
                try checkRows(bookmarks.count + 1)
                bookmarks.append(bookmark)
            }
            bookmarks.sort { $0.address == $1.address ? $0.name < $1.name : $0.address < $1.address }
            var rows: [ScriptValue] = []
            for bookmark in bookmarks {
                try step()
                try append(.object(["address": .hex(bookmark.address), "name": .string(bookmark.name)]), to: &rows)
            }
            return .array(rows)

        case "segment-overrides":
            try checkRows(snapshot.segmentOverrides.count)
            let overrides = snapshot.segmentOverrides.sorted { $0.originalName < $1.originalName }
            var rows: [ScriptValue] = []
            for override in overrides {
                try step()
                try append(.object([
                    "section": .string(override.originalName),
                    "displayName": override.displayName.map(ScriptValue.string) ?? .null,
                    "rebaseDelta": .int(override.rebaseDelta),
                ]), to: &rows)
            }
            return .array(rows)

        case "read-bytes":
            let target = try address(arguments, "address")
            let requested = arguments["count"]?.intValue.map { Int(max(0, $0)) } ?? 16
            let slot = try resolveImageSlot(arguments, snapshot: snapshot)
            let analysis = snapshot.analysis(in: slot)
            var selected: SectionSummary?
            for section in analysis?.sections ?? [] {
                try step()
                if section.address <= target && target < section.address &+ section.size { selected = section; break }
            }
            guard let section = selected else {
                throw ScriptingError.invalidArgument("address \(ScriptValue.hex(target).stringValue ?? "") is not in any mapped section")
            }
            let delta = target - section.address
            let available = min(UInt64(requested), section.size - delta)
            let bytes = analysis?.imageBytes ?? Data()
            let (sliceStart, overflowed) = section.fileOffset.addingReportingOverflow(delta)
            let length: Int
            if section.isZeroFill { length = Int(min(available, UInt64(Int.max))) }
            else if !overflowed, sliceStart <= UInt64(bytes.count) {
                length = Int(min(available, UInt64(bytes.count) - sliceStart))
            } else { length = 0 }
            guard length <= maximumSnapshotSelectionWork else {
                throw ScriptingError.invalidArgument("read-bytes exceeds the snapshot byte budget")
            }
            let digits = Array("0123456789abcdef".utf8)
            var hex: [UInt8] = []
            hex.reserveCapacity(length * 2)
            for index in 0..<length {
                try step()
                let byte: UInt8 = section.isZeroFill ? 0 : bytes[bytes.startIndex + Int(sliceStart) + index]
                hex.append(digits[Int(byte >> 4)])
                hex.append(digits[Int(byte & 15)])
            }
            var fields: [String: ScriptValue] = [
                "address": .hex(target), "length": .count(UInt64(length)),
                "hex": .string(String(decoding: hex, as: UTF8.self)),
            ]
            fields.merge(imageProvenanceFields(slot: slot, snapshot: snapshot)) { _, label in label }
            return .object(fields)

        default:
            throw ScriptingError.unknownCommand(command)
        }
    }
}
