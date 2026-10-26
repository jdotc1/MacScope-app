import Foundation

extension PseudocodeNameContext {
    /// Keep pointer-valued loads typed where their SSA destination is used as
    /// an address. A pointer field consumed only by integer arithmetic retains
    /// its carrier cast, even though field propagation knows the pointee type.
    mutating func collectRecordPointerConsumers(in function: MacIRFunction) {
        var consumers: Set<MacIRValue> = []
        let printer = PseudocodePrinter()
        func hasPointerType(_ value: MacIRValue) -> Bool {
            let type: String?
            if case let .argument(binding) = value { type = argumentTypes[binding] }
            else { type = valueTypes[value] }
            return type.flatMap { printer.resolvedPointer($0, names: self) } != nil
        }
        func addressBase(_ address: MacIRValue, depth: Int = 0) {
            guard depth < 64 else { return }
            switch address {
            case .register, .temporary, .argument:
                consumers.insert(address)
            case let .binaryExpression(op, left, right) where op == "+" || op == "-":
                if case .immediate = right { addressBase(left, depth: depth + 1) }
                else if hasPointerType(left) { addressBase(left, depth: depth + 1) }
                if op == "+" {
                    if case .immediate = left { addressBase(right, depth: depth + 1) }
                    else if hasPointerType(right) { addressBase(right, depth: depth + 1) }
                }
            case let .unary(op, value) where op.first == "(" && op.last == ")":
                if printer.resolvedPointer(String(op.dropFirst().dropLast()), names: self) != nil {
                    addressBase(value, depth: depth + 1)
                }
            default: break
            }
        }
        for instruction in function.instructions {
            switch instruction.operation {
            case let .load(_, address), let .store(_, address): addressBase(address)
            case let .loadWriteback(_, _, base, _, _), let .storeWriteback(_, _, base, _, _):
                addressBase(base)
            case let .intrinsic(_, name, arguments)
                where ["save_pair", "restore_pair", "save_pair_writeback", "restore_pair_writeback"].contains(name):
                if arguments.count > 2 { addressBase(arguments[2]) }
            default: break
            }
        }
        for binding in function.nameBindings {
            guard let type = binding.type, printer.resolvedPointer(type, names: self) != nil,
                  case let .register(name, version) = binding.target else { continue }
            consumers.insert(.register(name: name, version: version))
        }
        recordPointerConsumers = consumers
    }
}

extension PseudocodePrinter {
    /// Only emitted C pointer types introduce element scaling. Inferred types on
    /// undeclared SSA names retain their independent legacy rendering policy.
    func emittedRecordPointer(_ value: MacIRValue, names: PseudocodeNameContext) -> String? {
        guard let type = emittedPointerType(for: value, names: names),
              let original = resolvedPointer(type, names: names) else { return nil }
        // An ambiguous whole-pointer alias may require byte addressing but can
        // never establish a field proof or an element stride.
        guard let pointer = recordUniquePointer(type, names: names) else { return type }
        guard original.indirectionLevel == 1, pointer.indirectionLevel == 1 else { return nil }
        if let layout = TypeAtlasDarwinARM64LayoutResolver(catalog: names.recordFieldTypesByName)
            .resolveLayout(ofType: pointer.pointeeWords.joined(separator: " ")),
           layout.kind == .integer || layout.kind == .floating { return nil }
        return type
    }

    private func recordUniquePointer(_ spelling: String, names: PseudocodeNameContext) -> DarwinARM64NormalizedDataPointer? {
        var type = spelling
        var visited: Set<String> = []
        while true {
            if let pointer = DarwinARM64ParameterBinder.normalizedDataPointer(type) { return pointer }
            let name = type.split(whereSeparator: \.isWhitespace)
                .filter { $0 != "const" && $0 != "volatile" }.joined(separator: " ")
            guard visited.insert(name).inserted,
                  let alias = names.recordFieldTypesByName[name], alias.kind == .typedef,
                  alias.vectorByteSize == nil, alias.fields.count == 1,
                  alias.fields[0].layoutIsUnknown != true, alias.fields[0].isAtomic != true,
                  alias.fields[0].declaratorSemanticsV1 == nil || alias.fields[0].declaratorSemanticsV1 == .ordinary else { return nil }
            type = alias.fields[0].type
        }
    }

    /// Legacy hand-built IR without a descriptor uses the carrier's natural
    /// width. A temporary or arbitrary expression does not prove such a width.
    private func recordRegisterAccess(_ carrier: MacIRValue) -> MacIRMemoryAccess? {
        guard case let .register(rawName, _) = carrier else { return nil }
        let name = rawName.lowercased()
        if ["xzr", "fp", "lr", "sp", "wsp"].contains(name) { return .init(byteWidth: 8) }
        if name == "wzr" { return .init(byteWidth: 4) }
        if let integer = MacIRBuilder.integerRegisterView(name) {
            return .init(byteWidth: integer.width / 8)
        }
        let width: Int
        switch name.first {
        case "b": width = 1
        case "h": width = 2
        case "s": width = 4
        case "d": width = 8
        case "q", "v": width = 16
        default: return nil
        }
        guard let index = Int(name.dropFirst()), (0..<32).contains(index) else { return nil }
        return .init(byteWidth: width)
    }

    private func recordFloatingRegister(_ name: String) -> Bool {
        let name = name.lowercased()
        guard ["h", "s", "d"].contains(String(name.prefix(1))),
              let index = Int(name.dropFirst()), (0..<32).contains(index) else { return false }
        return true
    }

    private struct RecordCarrierShape {
        let bytes: Int
        let floating: Bool
    }

    func recordNaturalAccess(_ carrier: MacIRValue, names: PseudocodeNameContext, isStore: Bool = false) -> MacIRMemoryAccess? {
        if !isStore { return recordRegisterAccess(carrier) }
        guard let shape = recordCarrierShape(carrier, names: names), [1, 2, 4, 8, 16].contains(shape.bytes) else { return nil }
        return .init(byteWidth: shape.bytes)
    }

    private func recordDeclaredShape(_ type: String, names: PseudocodeNameContext) -> RecordCarrierShape? {
        if ["_Float16", "__fp16", "half"].contains(type) { return .init(bytes: 2, floating: true) }
        guard let layout = TypeAtlasDarwinARM64LayoutResolver(catalog: names.recordFieldTypesByName).resolveLayout(ofType: type),
              layout.kind == .integer || layout.kind == .floating else { return nil }
        return .init(bytes: layout.size, floating: layout.kind == .floating)
    }

    /// Width-only interpretation of statically typed scalar carriers. This does
    /// not propagate types through SSA definitions or infer from a field layout.
    private func recordCarrierShape(_ value: MacIRValue, names: PseudocodeNameContext,
                                    depth: Int = 0) -> RecordCarrierShape? {
        guard depth < 64 else { return nil }
        switch value {
        case let .register(name, _):
            guard let access = recordRegisterAccess(value) else { return nil }
            return .init(bytes: access.byteWidth, floating: recordFloatingRegister(name))
        case .immediate, .stackSlot: return .init(bytes: 8, floating: false)
        case .bitTest: return .init(bytes: 4, floating: false)
        case let .symbol(text): return Double(text) == nil ? nil : .init(bytes: 8, floating: true)
        case let .argument(binding):
            guard let parameter = names.recordParametersByBinding[binding], parameter.abiLocation.bindingID == binding,
                  let declared = recordDeclaredShape(parameter.type, names: names) else { return nil }
            switch parameter.abiLocation {
            case let .gpr(_, bits):
                return declared.floating ? nil : .init(bytes: min(declared.bytes, bits / 8), floating: false)
            case let .simd(_, bits):
                return declared.floating && declared.bytes == bits / 8 ? declared : nil
            case let .entryStack(_, size, _):
                return size <= 8 && declared.bytes <= size ? declared : nil
            case .unbound: return nil
            }
        case let .unary(op, operand):
            if op.first == "(", op.last == ")" {
                return recordDeclaredShape(String(op.dropFirst().dropLast()), names: names)
            }
            guard let inner = recordCarrierShape(operand, names: names, depth: depth + 1) else { return nil }
            if inner.floating { return op == "-" ? inner : nil }
            if op == "!" { return .init(bytes: 4, floating: false) }
            return op == "-" || op == "~" ? .init(bytes: max(4, inner.bytes), floating: false) : nil
        case let .binaryExpression(op, left, right):
            guard let lhs = recordCarrierShape(left, names: names, depth: depth + 1),
                  let rhs = recordCarrierShape(right, names: names, depth: depth + 1) else { return nil }
            if ["==", "!=", "<", "<=", ">", ">="].contains(op) { return .init(bytes: 4, floating: false) }
            if lhs.floating || rhs.floating {
                guard ["+", "-", "*", "/"].contains(op) else { return nil }
                return .init(bytes: max(lhs.floating ? lhs.bytes : 0, rhs.floating ? rhs.bytes : 0), floating: true)
            }
            if op == "&&" || op == "||" { return .init(bytes: 4, floating: false) }
            if op == "<<" || op == ">>" { return .init(bytes: max(4, lhs.bytes), floating: false) }
            guard ["+", "-", "*", "/", "%", "&", "|", "^"].contains(op) else { return nil }
            return .init(bytes: max(4, lhs.bytes, rhs.bytes), floating: false)
        case .temporary, .unknown, .argumentFragment, .abiComposite, .signedBitfield: return nil
        }
    }

    private func recordAddress(_ value: MacIRValue, names: PseudocodeNameContext,
                               depth: Int = 0) -> (base: MacIRValue, offset: Int)? {
        guard depth < 64 else { return nil }
        if case let .binaryExpression(op, left, right) = value, op == "+" || op == "-" {
            if case let .immediate(bytes) = right,
               let inner = recordAddress(left, names: names, depth: depth + 1),
               let delta = Int(exactly: bytes) {
                let result = op == "+" ? inner.offset.addingReportingOverflow(delta)
                    : inner.offset.subtractingReportingOverflow(delta)
                return result.overflow ? nil : (inner.base, result.partialValue)
            }
            if op == "+", case let .immediate(bytes) = left,
               let inner = recordAddress(right, names: names, depth: depth + 1),
               let delta = Int(exactly: bytes) {
                let result = inner.offset.addingReportingOverflow(delta)
                return result.overflow ? nil : (inner.base, result.partialValue)
            }
            return nil
        }
        return emittedRecordPointer(value, names: names) == nil ? nil : (value, 0)
    }

    private struct RecordLeaf {
        let path: String
        let type: String
        let writable: Bool
    }

    private func recordResolvedType(_ spelling: String, catalog: [String: TypeDefinition],
                                    visiting: Set<String> = []) -> String? {
        let name = spelling.split(whereSeparator: \.isWhitespace)
            .filter { $0 != "const" && $0 != "volatile" }.joined(separator: " ")
        guard !name.contains("_Atomic"), !name.contains("restrict") else { return nil }
        guard let alias = catalog[name], alias.kind == .typedef else { return name }
        guard !visiting.contains(name), alias.vectorByteSize == nil, alias.fields.count == 1,
              alias.fields[0].layoutIsUnknown != true, alias.fields[0].isAtomic != true,
              alias.fields[0].declaratorSemanticsV1 == nil || alias.fields[0].declaratorSemanticsV1 == .ordinary else { return nil }
        return recordResolvedType(alias.fields[0].type, catalog: catalog, visiting: visiting.union([name]))
    }

    private func recordLeaf(in spelling: String, offset: Int, width: Int, path: String,
                            catalog: [String: TypeDefinition], depth: Int = 0, writable: Bool = true) -> RecordLeaf? {
        guard depth < 64, offset >= 0, width > 0,
              let type = recordResolvedType(spelling, catalog: catalog) else { return nil }
        let writable = writable && !recordHasConst(spelling, catalog: catalog)
        // Peel the first C array dimension, retaining subsequent dimensions in
        // the element type. Stride, bounds and products must all be exact.
        if let open = type.firstIndex(of: "["), let close = type[open...].firstIndex(of: "]") {
            guard type.hasSuffix("]"), let count = Int(type[type.index(after: open)..<close]), count > 0 else { return nil }
            let element = String(type[..<open]) + String(type[type.index(after: close)...])
            guard let stride = TypeDefinition.size(ofType: element, in: catalog), stride > 0,
                  let total = TypeDefinition.size(ofType: type, in: catalog), total > 0,
                  offset < total, width <= total - offset else { return nil }
            let index = offset / stride
            guard index < count else { return nil }
            return recordLeaf(in: element, offset: offset % stride, width: width,
                path: "\(path)[\(index)]", catalog: catalog, depth: depth + 1, writable: writable)
        }
        let resolver = TypeAtlasDarwinARM64LayoutResolver(catalog: catalog)
        let layout = resolver.resolveLayout(ofType: type)
        if let layout {
            guard layout.size > 0, offset < layout.size, width <= layout.size - offset else { return nil }
            if layout.kind == .integer || layout.kind == .floating {
                return offset == 0 && width == layout.size && !path.isEmpty
                    ? RecordLeaf(path: path, type: type, writable: writable) : nil
            }
        }
        let name = type.hasPrefix("struct ") ? String(type.dropFirst(7)) : type
        guard let definition = catalog[name], definition.kind == .struct,
              !definition.fields.isEmpty else { return nil }
        // The pinned member-layout contract retains exact direct members before
        // an unresolved tail. Only a root scalar member may use that prefix;
        // nested paths and array strides still require a complete layout.
        let prefixOnly = layout == nil && depth == 0 && path.isEmpty
        guard layout?.kind == .aggregate || prefixOnly else { return nil }
        // Inspect declared fields too: memberLayout can promote anonymous
        // union members and erase the overlapping aggregate's origin.
        guard definition.fields.allSatisfy({ !$0.promotesInlineFields &&
            ($0.inlineAggregateKind == nil ? $0.inlineFields.isEmpty : $0.inlineAggregateKind == .struct) }) else { return nil }
        let members = definition.memberLayout(in: catalog)
        let prefixTargets = prefixOnly ? members.filter { $0.offset == offset } : []
        let prefixTargetName = prefixTargets.count == 1 ? prefixTargets[0].field.name : nil
        // A lowered pointer-to-array neighbor proves pointer storage only. It
        // never supplies the representation of the selected field expression.
        func ordinaryOrNonTargetLayoutCarrier(_ field: FieldDef) -> Bool {
            if field.declaratorSemanticsV1 == nil || field.declaratorSemanticsV1 == .ordinary {
                return true
            }
            guard prefixOnly, let prefixTargetName, field.name != prefixTargetName,
                  field.declaratorSemanticsV1 == .pointerToArrayCarrier,
                  DarwinARM64ParameterBinder.normalizedDataPointer(field.type) != nil,
                  let carrierLayout = resolver.resolveLayout(ofType: field.type),
                  carrierLayout.kind == .integer,
                  carrierLayout.size == 8, carrierLayout.alignment == 8 else { return false }
            return true
        }
        let keywords: Set<String> = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn", "_Static_assert", "_Thread_local"]
        // Names must identify one field, never one arbitrary duplicate. Imported
        // offsets are not C-layout authority, and bitfields are not scalar lvalues.
        guard Set(members.map { $0.field.name }).count == members.count,
              members.allSatisfy({ member in
                  let field = member.field
                  return Self.isCIdentifier(field.name) && !keywords.contains(field.name) && field.bitWidth == nil &&
                      field.layoutIsUnknown != true && field.isAtomic != true &&
                      field.byteOffset == nil && field.layoutSource == nil &&
                      !field.promotesInlineFields &&
                      ordinaryOrNonTargetLayoutCarrier(field)
              }) else { return nil }
        if prefixOnly {
            guard Set(definition.fields.map { $0.name }).count == definition.fields.count,
                  definition.fields.allSatisfy({ field in
                      Self.isCIdentifier(field.name) && !keywords.contains(field.name) &&
                          field.bitWidth == nil && field.layoutIsUnknown != true && field.isAtomic != true &&
                          field.byteOffset == nil && field.layoutSource == nil && !field.promotesInlineFields &&
                          ordinaryOrNonTargetLayoutCarrier(field)
                  }),
                  members.filter({ $0.offset == offset }).count == 1,
                  let member = members.first(where: { $0.offset == offset }),
                  member.field.inlineAggregateKind == nil,
                  (member.field.declaratorSemanticsV1 == nil || member.field.declaratorSemanticsV1 == .ordinary),
                  let memberLayout = resolver.resolveLayout(ofType: member.field.type),
                  memberLayout.kind == .integer || memberLayout.kind == .floating,
                  memberLayout.size == width else { return nil }
            return recordLeaf(in: member.field.type, offset: 0, width: width,
                path: member.field.name, catalog: catalog, depth: depth + 1,
                writable: writable && !recordHasConst(member.field.type, catalog: catalog))
        }
        // A named inline record has the same checked layout rules as a catalog
        // record. Give that local definition a collision-free lookup key only
        // while proving this member; it never changes the caller's type catalog.
        func memberType(_ field: FieldDef) -> (String, [String: TypeDefinition]) {
            guard field.inlineAggregateKind == .struct else { return (field.type, catalog) }
            var index = 0
            var key = "__record_inline_0"
            while catalog[key] != nil { index += 1; key = "__record_inline_\(index)" }
            var local = catalog
            local[key] = TypeDefinition(kind: .struct, name: key, fields: field.inlineFields,
                                       layoutRules: field.inlineAggregateLayoutRules)
            return (key, local)
        }
        let containing = members.filter { member in
            let (type, local) = memberType(member.field)
            guard let size = TypeDefinition.size(ofType: type, in: local), size > 0,
                  member.offset <= offset else { return false }
            return offset - member.offset < size
        }
        guard containing.count == 1, let member = containing.first else { return nil }
        let next = path.isEmpty ? member.field.name : path + "." + member.field.name
        let (memberSpelling, local) = memberType(member.field)
        return recordLeaf(in: memberSpelling, offset: offset - member.offset, width: width,
                          path: next, catalog: local, depth: depth + 1,
                          writable: writable && !recordHasConst(member.field.type, catalog: catalog))
    }

    private func recordHasConst(_ spelling: String, catalog: [String: TypeDefinition], visiting: Set<String> = []) -> Bool {
        let words = spelling.split(whereSeparator: { $0.isWhitespace || $0 == "*" })
        if words.contains("const") { return true }
        let name = spelling.split(whereSeparator: \.isWhitespace)
            .filter { $0 != "volatile" }.joined(separator: " ")
        guard !visiting.contains(name), let alias = catalog[name], alias.kind == .typedef,
              alias.fields.count == 1 else { return false }
        return recordHasConst(alias.fields[0].type, catalog: catalog, visiting: visiting.union([name]))
    }

    private func recordPointeeQualified(_ spelling: String, qualifier: String,
                                        catalog: [String: TypeDefinition], visiting: Set<String> = []) -> Bool {
        if let star = spelling.firstIndex(of: "*"),
           DarwinARM64ParameterBinder.normalizedDataPointer(spelling) != nil {
            let pointee = String(spelling[..<star])
            if pointee.split(whereSeparator: \.isWhitespace).contains(Substring(qualifier)) { return true }
            return recordTypeQualified(pointee, qualifier: qualifier, catalog: catalog)
        }
        // Qualifying a pointer typedef qualifies the pointer object, not its
        // pointee. Follow the target without promoting those outer qualifiers.
        let name = spelling.split(whereSeparator: \.isWhitespace)
            .filter { $0 != "const" && $0 != "volatile" }.joined(separator: " ")
        guard !visiting.contains(name), let alias = catalog[name], alias.kind == .typedef,
              alias.fields.count == 1 else { return false }
        return recordPointeeQualified(alias.fields[0].type, qualifier: qualifier,
                                      catalog: catalog, visiting: visiting.union([name]))
    }

    private func recordTypeQualified(_ spelling: String, qualifier: String,
                                     catalog: [String: TypeDefinition], visiting: Set<String> = []) -> Bool {
        let words = spelling.split(whereSeparator: \.isWhitespace)
        if words.contains(Substring(qualifier)) { return true }
        let name = words.filter { $0 != "const" && $0 != "volatile" }.joined(separator: " ")
        guard !visiting.contains(name), let alias = catalog[name], alias.kind == .typedef,
              alias.fields.count == 1 else { return false }
        return recordTypeQualified(alias.fields[0].type, qualifier: qualifier,
                                   catalog: catalog, visiting: visiting.union([name]))
    }

    private func recordContainsVolatile(_ spelling: String, catalog: [String: TypeDefinition],
                                        visiting: Set<String> = []) -> Bool {
        if recordTypeQualified(spelling, qualifier: "volatile", catalog: catalog) { return true }
        guard let type = recordResolvedType(spelling, catalog: catalog) else { return false }
        if let open = type.firstIndex(of: "[") {
            return recordContainsVolatile(String(type[..<open]), catalog: catalog, visiting: visiting)
        }
        let name = type.hasPrefix("struct ") ? String(type.dropFirst(7)) :
            (type.hasPrefix("union ") ? String(type.dropFirst(6)) : type)
        guard !visiting.contains(name), let definition = catalog[name],
              definition.kind == .struct || definition.kind == .union else { return false }
        func contains(_ fields: [FieldDef], depth: Int) -> Bool {
            guard depth < 64 else { return true }
            return fields.contains {
                recordContainsVolatile($0.type, catalog: catalog, visiting: visiting.union([name])) ||
                    contains($0.inlineFields, depth: depth + 1)
            }
        }
        return contains(definition.fields, depth: 0)
    }

    /// Returns only field text, so declaration-certificate callers can veto the
    /// same contextual rendering without confusing a safe byte fallback with it.
    func recordFieldMemoryText(address: MacIRValue, carrier: MacIRValue,
                               access: MacIRMemoryAccess, isStore: Bool,
                               names: PseudocodeNameContext) -> String? {
        if case .stackSlot = address { return nil }
        guard let target = recordAddress(address, names: names),
              let type = emittedRecordPointer(target.base, names: names),
              let pointer = recordUniquePointer(type, names: names),
              let leaf = recordLeaf(in: pointer.pointeeWords.joined(separator: " "),
                offset: target.offset, width: access.byteWidth, path: "", catalog: names.recordFieldTypesByName),
              let layout = TypeAtlasDarwinARM64LayoutResolver(catalog: names.recordFieldTypesByName)
                .resolveLayout(ofType: leaf.type) else { return nil }
        guard leaf.type != "bool", leaf.type != "_Bool" else { return nil }
        if isStore {
            guard leaf.writable, !recordPointeeQualified(type, qualifier: "const", catalog: names.recordFieldTypesByName) else { return nil }
        }
        let floating: Bool
        let carrierWidth: Int?
        if case let .register(name, _) = carrier {
            floating = recordFloatingRegister(name)
            carrierWidth = recordRegisterAccess(carrier)?.byteWidth
            guard carrierWidth != nil, floating || MacIRBuilder.integerRegisterView(name) != nil else { return nil }
        } else {
            // An access descriptor supplies memory width, not a value's scalar
            // representation. Do not infer a field class from an unnamed carrier.
            guard isStore, case .immediate = carrier else { return nil }
            floating = false
            carrierWidth = nil
        }
        // Explicit memory descriptors prove temporary memory widths, but do not
        // prove a floating carrier or a pointer-valued store source.
        if let carrierWidth {
            if floating { guard access.byteWidth == carrierWidth && access.extensionKind == .none else { return nil } }
            guard isStore ? access.byteWidth <= carrierWidth :
                (access.extensionKind == .none ? access.byteWidth == carrierWidth : access.byteWidth < carrierWidth) else { return nil }
        } else if isStore {
            guard case .immediate = carrier else { return nil }
        }
        guard layout.kind == (floating ? .floating : .integer) else { return nil }
        if DarwinARM64ParameterBinder.normalizedDataPointer(leaf.type) != nil {
            guard !isStore, !floating, access.byteWidth == 8, access.extensionKind == .none else { return nil }
        } else if isStore {
            // Assignment to bool normalizes bits; enums and signed narrowing can
            // also change C conversion behavior. Use a typed byte store instead.
            guard floating || names.scalarSignedness(leaf.type) == false,
                  leaf.type != "bool", leaf.type != "_Bool" else { return nil }
        } else if floating {
            guard access.extensionKind == .none else { return nil }
        } else {
            switch access.extensionKind {
            case .sign: guard names.scalarSignedness(leaf.type) == true else { return nil }
            case .zero: guard names.scalarSignedness(leaf.type) == false else { return nil }
            case .none: guard access.byteWidth == 4 || access.byteWidth == 8 else { return nil }
            }
        }
        let baseText = valueText(for: target.base, names: names)
        let base: String
        switch target.base {
        case .argument, .register, .stackSlot, .temporary: base = baseText
        default: base = "(\(baseText))"
        }
        let member = "\(base)->\(leaf.path)"
        // Field-layout inference alone does not make an integer carrier a C
        // pointer. Actual pointer consumers or a declared pointer type do.
        return DarwinARM64ParameterBinder.normalizedDataPointer(leaf.type) != nil
            && !names.recordPointerConsumers.contains(carrier)
            ? "(uint64_t)(\(member))" : member
    }

    /// Own both success and refusal for emitted record bases: failed exact
    /// proof must not fall through to legacy first-offset field sugar.
    func recordMemoryText(address: MacIRValue, carrier: MacIRValue,
                          access: MacIRMemoryAccess, isStore: Bool,
                          names: PseudocodeNameContext, allowField: Bool = true) -> String? {
        if case .stackSlot = address { return nil }
        guard emittedRecordPointer(address, names: names) != nil else { return nil }
        if allowField, let field = recordFieldMemoryText(address: address, carrier: carrier, access: access,
                                             isStore: isStore, names: names) { return field }
        let floating: Bool
        if let shape = recordCarrierShape(carrier, names: names) { floating = shape.floating }
        else if case let .argument(binding) = carrier { floating = binding.kind == .simd }
        else { floating = false }
        let shape = recordCarrierShape(carrier, names: names)
        let bitBridge = shape.map { $0.floating && [2, 4, 8].contains($0.bytes) && $0.bytes != access.byteWidth } == true
        let type: String
        if bitBridge { type = access.byteWidth == 16 ? "__uint128_t" : "uint\(access.byteWidth * 8)_t" }
        else if floating && access.byteWidth == 2 { type = "_Float16" }
        else if floating && access.byteWidth == 4 { type = "float" }
        else if floating && access.byteWidth == 8 { type = "double" }
        else if access.byteWidth == 16 { type = "__uint128_t" }
        else { type = "\(access.extensionKind == .sign ? "int" : "uint")\(access.byteWidth * 8)_t" }
        let pointerType = emittedRecordPointer(address, names: names)!
        let pointee = recordUniquePointer(pointerType, names: names)?.pointeeWords.joined(separator: " ")
        // A volatile-qualified object must remain volatile at the actual memory
        // dereference. When a record contains volatile storage, conservatively
        // retain that qualification on raw accesses that cannot name a leaf.
        let isVolatile = recordPointeeQualified(pointerType, qualifier: "volatile", catalog: names.recordFieldTypesByName)
            || pointee.map { recordContainsVolatile($0, catalog: names.recordFieldTypesByName) } == true
        let memory = "*(\(isVolatile ? "volatile " : "")\(type) *)(\(recordByteAddressText(address, names: names)))"
        if bitBridge, !isStore, let shape {
            return "__bitcast_f\(shape.bytes * 8)((uint\(shape.bytes * 8)_t)(\(memory)))"
        }
        return memory
    }
    func recordStoreValueText(_ value: MacIRValue, names: PseudocodeNameContext, access: MacIRMemoryAccess? = nil) -> String {
        let text = valueText(for: value, names: names)
        if let access, let shape = recordCarrierShape(value, names: names), shape.floating,
           [2, 4, 8].contains(shape.bytes), shape.bytes != access.byteWidth {
            let type = access.byteWidth == 16 ? "__uint128_t" : "uint\(access.byteWidth * 8)_t"
            return "(\(type))(__bitcast_u\(shape.bytes * 8)(\(text)))"
        }
        return emittedPointerType(for: value, names: names) == nil ? text : "(uint64_t)(\(text))"
    }

    /// No memory type or field may be inferred from an untyped carrier. The
    /// intrinsic preserves the address and value without inventing an access width.
    func recordUnknownWidthText(address: MacIRValue, carrier: MacIRValue, isStore: Bool,
                                names: PseudocodeNameContext) -> String? {
        if case .stackSlot = address { return nil }
        guard emittedRecordPointer(address, names: names) != nil,
              recordNaturalAccess(carrier, names: names, isStore: isStore) == nil else { return nil }
        let byteAddress = recordByteAddressText(address, names: names)
        return isStore ? "__store_unknown_width(\(byteAddress), \(valueText(for: carrier, names: names)))"
            : "__load_unknown_width(\(byteAddress))"
    }

    private func recordByteAddressText(_ address: MacIRValue, names: PseudocodeNameContext) -> String {
        func byteBase(_ value: MacIRValue, type: String) -> String {
            if case .binaryExpression = value {
                return "(\(recordByteAddressText(value, names: names)))"
            }
            let words = ["const", "volatile"].filter {
                recordPointeeQualified(type, qualifier: $0, catalog: names.recordFieldTypesByName)
            }.joined(separator: " ")
            let prefix = words.isEmpty ? "" : words + " "
            return "(\(prefix)uint8_t *)(\(valueText(for: value, names: names)))"
        }
        if case let .binaryExpression(op, left, right) = address, op == "+" || op == "-" {
            if let type = emittedPointerType(for: left, names: names), emittedPointerType(for: right, names: names) == nil {
                return "\(byteBase(left, type: type)) \(op) \(parenthesizedOperandText(for: right, names: names))"
            }
            if op == "+", let type = emittedPointerType(for: right, names: names), emittedPointerType(for: left, names: names) == nil {
                return "\(byteBase(right, type: type)) \(op) \(parenthesizedOperandText(for: left, names: names))"
            }
        }
        if let type = emittedPointerType(for: address, names: names) { return byteBase(address, type: type) }
        return valueText(for: address, names: names)
    }
}
