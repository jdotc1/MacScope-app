import Foundation

import MachO
func witness(_ metadata: UnsafeRawPointer) -> [String: Any] {
    let table = metadata.load(fromByteOffset: -8, as: UnsafeRawPointer.self)
    let flags = table.load(fromByteOffset: 80, as: UInt32.self)
    return ["size": table.load(fromByteOffset: 64, as: UInt.self),
            "stride": table.load(fromByteOffset: 72, as: UInt.self), "flags": flags,
            "alignment": UInt(flags & 255) + 1,
            "extraInhabitants": table.load(fromByteOffset: 84, as: UInt32.self),
            "isPOD": flags & 0x10000 == 0, "isBitwiseTakable": flags & 0x100000 == 0,
            "hasEnumWitnesses": flags & 0x200000 != 0, "incomplete": flags & 0x400000 != 0]
}
func metadataPointer(_ type: Any.Type) -> UnsafeRawPointer { unsafeBitCast(type, to: UnsafeRawPointer.self) }
func runtimeRow(_ metadata: UnsafeRawPointer, source: String, image: ImageTypes?) -> [String: Any] {
    let type = unsafeBitCast(metadata, to: Any.Type.self)
    let kind = metadata.load(as: UInt.self)
    var row: [String: Any] = ["qualifiedName": _typeName(type, qualified: true),
        "source": source, "kind": kind == 0x200 ? "struct" : (kind == 0x201 || kind == 0x202 ? "enum" : (kind == 0x301 ? "tuple" : "class")),
        "kindWord": kind, "vwt": witness(metadata)]
    if let name = _mangledTypeName(type) { row["mangled"] = name }
    if let va = image?.address(metadata) { row["metadataVA"] = va } else { row["external"] = true }
    return row
}
func queryImage(_ path: String, names: [String], fields: Bool, isolate: Bool = false) throws -> [String: Any] {
    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        return ["status": "failed", "image": path, "types": [], "unanswered": [["reason": "dlopen", "detail": dlerror().map { String(cString: $0) } ?? "unknown"]], "summary": ["askable": 0, "answered": 0, "rate": 0]]
    }
    // Retain the handle: runtime metadata can reference this image until process exit.
    _ = handle
    let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    guard let index = (0..<_dyld_image_count()).first(where: {
        guard let name = _dyld_get_image_name($0) else { return false }
        return URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath().path == canonical
    }), let header = _dyld_get_image_header(index) else {
        return ["status": "failed", "types": [], "unanswered": [["reason": "dlopen", "detail": "loaded image not found"]]]
    }
    let image = ImageTypes(header: header, slide: _dyld_get_image_vmaddr_slide(index))
    var rows: [[String: Any]] = [], unanswered: [[String: Any]] = []
    var askable = 0, answered = 0, dependent = 0
    for descriptor in image.descriptors() {
        let flags = descriptor.loadUnaligned(as: UInt32.self)
        let path = image.path(descriptor)
        var identity: [String: Any] = ["descriptorVA": image.address(descriptor) as Any, "path": path.text, "generic": flags & 0x80 != 0, "descriptorKind": flags & 31]
        if let name = path.mangled { identity["mangled"] = name }
        let generic = flags & 0x80 != 0
        var row: [String: Any]
        if generic {
            identity["reason"] = "generic"
            row = identity
        } else {
            askable += 1
            row = try resolveQuery(isolate: isolate, identity: identity) {
                var metadata = path.mangled.flatMap { _typeByName($0) }.map(metadataPointer)
                var source = "name"
                if metadata == nil && path.anonymous, let accessor = relative(descriptor.advanced(by: 12)) {
                    typealias Accessor = @convention(c) (UInt) -> UnsafeRawPointer?
                    metadata = unsafeBitCast(accessor, to: Accessor.self)(0)
                    source = "accessor"
                }
                if let metadata {
                    return runtimeRow(metadata, source: source, image: image).merging(identity) { old, _ in old }
                }
                return identity.merging(["reason": path.anonymous ? "anonymous-context" : "nil-from-runtime"]) { _, new in new }
            }
            if row["vwt"] != nil { answered += 1 }
        }
        if fields && flags & 31 == 17, let fd = relative(descriptor.advanced(by: 16)) {
            let recordSize = Int(fd.load(fromByteOffset: 10, as: UInt16.self))
            let count = Int(fd.load(fromByteOffset: 12, as: UInt32.self))
            var records: [[String: Any]] = []
            if recordSize >= 12 && count < 100000 {
                for n in 0..<count {
                    let record = fd.advanced(by: 16 + n * recordSize)
                    var field: [String: Any] = ["name": cstring(relative(record.advanced(by: 8))) ?? ""]
                    if let mangled = relative(record.advanced(by: 4)) {
                        let bytes = mangledBytes(mangled)
                        field["mangledType"] = bytes.display
                        if bytes.dependent {
                            dependent += 1; field["reason"] = "dependent"
                            unanswered.append(["descriptorVA": image.address(descriptor) as Any, "field": field["name"]!, "reason": "dependent"])
                        } else {
                            askable += 1
                            let identity: [String: Any] = ["mangled": bytes.display,
                                "descriptorVA": image.address(descriptor) as Any, "field": field["name"]!]
                            let resolved = try resolveQuery(isolate: isolate, identity: identity) {
                                if let type = _getTypeByMangledNameInContext(mangled.assumingMemoryBound(to: UInt8.self), UInt(bytes.length), genericContext: nil, genericArguments: nil) {
                                    return runtimeRow(metadataPointer(type), source: "mangled", image: image)
                                }
                                return identity.merging(["reason": "nil-from-runtime"]) { _, new in new }
                            }
                            field.merge(resolved) { old, _ in old }
                            if resolved["vwt"] != nil { answered += 1 }
                            else { unanswered.append(resolved) }
                        }
                    } else { field["reason"] = "nil-from-runtime" }
                    records.append(field)
                }
            }
            row["fields"] = records
        }
        if row["reason"] != nil { unanswered.append(row) } else { rows.append(row) }
    }
    for name in names {
        askable += 1
        let identity: [String: Any] = ["mangled": name]
        let row = try resolveQuery(isolate: isolate, identity: identity) {
            if let type = _typeByName(name) {
                return runtimeRow(metadataPointer(type), source: "name", image: image)
            }
            return ["mangled": name, "reason": "nil-from-runtime"]
        }
        if row["vwt"] != nil { answered += 1; rows.append(row) }
        else { unanswered.append(row) }
    }
    return ["status": "ok", "image": path, "types": rows, "unanswered": unanswered,
            "summary": ["askable": askable, "answered": answered, "dependent": dependent, "rate": askable == 0 ? 1.0 : Double(answered) / Double(askable)]]
}
