import Foundation
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Exact current-main native scalar transport. This is not the older captured-call
/// context adapter, a reduced workspace, or a fresh header import.
/// Every PseudocodeRenderInput stored field is mapped. Native model Codable owns
/// operand/type/signature schemas; intentionally absent custom-schema keys stay absent.
struct NativeScalarContext: Codable, Equatable {
    struct AddressEntry<Value: Codable & Equatable>: Codable, Equatable {
        let address: String
        let value: Value
    }
    struct JumpTable: Codable, Equatable { let dispatch_address: String; let targets: [String] }
    struct Constant: Codable, Equatable { let address: String; let text: String; let kind: String }
    struct IndirectCall: Codable, Equatable {
        let call_address: String; let target: String; let name: String; let slot: String
    }
    let image_slot: ImageSlot
    let function_name: String
    let start_address: String?
    let jump_tables: [JumpTable]
    let objc_selectors: [AddressEntry<String>]
    let constant_strings: [Constant]
    let name_overrides: [String: String]
    let signature_overrides: [AddressEntry<FunctionSignatureOverride>]
    let authored_call_signatures_by_target: [String: FunctionSignatureOverride]
    let register_name_overrides: [String: String]
    let stack_local_overrides: [String: StackLocalOverride]
    let types: [TypeDefinition]
    let resolved_indirect_calls: [IndirectCall]
    let slot_call_contracts: [AddressEntry<FunctionPointerSignatureV1>]
    let caller_return_width: Int?
    let caller_return_type: String?

    init(_ input: PseudocodeRenderInput) {
        image_slot = input.imageSlot
        function_name = input.functionName
        start_address = input.startAddress.map(Self.hex)
        jump_tables = input.jumpTables.keys.sorted().map {
            JumpTable(dispatch_address: Self.hex($0), targets: input.jumpTables[$0]!.map(Self.hex))
        }
        objc_selectors = Self.entries(input.objcSelectors)
        constant_strings = input.constantStrings.keys.sorted().map {
            Constant(address: Self.hex($0), text: input.constantStrings[$0]!.text,
                     kind: input.constantStrings[$0]!.kind.rawValue)
        }
        name_overrides = input.nameOverrides
        signature_overrides = Self.entries(input.signatureOverrides)
        authored_call_signatures_by_target = input.authoredCallSignaturesByTarget
        register_name_overrides = input.registerNameOverrides
        stack_local_overrides = input.stackLocalOverrides
        types = input.types
        resolved_indirect_calls = input.resolvedIndirectCalls.keys.sorted().map {
            let call = input.resolvedIndirectCalls[$0]!
            return IndirectCall(call_address: Self.hex($0), target: Self.hex(call.target),
                                name: call.name, slot: call.slot)
        }
        slot_call_contracts = Self.entries(input.slotCallContracts)
        caller_return_width = input.callerReturnWidth?.rawValue
        caller_return_type = input.callerReturnType
    }

    func restore(rows: [InstructionRow], indices: [NativeScalarParameterIndex]) throws -> PseudocodeRenderInput {
        var tables: [UInt64: [UInt64]] = [:]
        for table in jump_tables {
            let key = try Self.address(table.dispatch_address)
            guard tables.updateValue(try table.targets.map(Self.address), forKey: key) == nil else {
                throw NativeScalarFixture.Failure.invalid("duplicate jump table")
            }
        }
        var constants: [UInt64: MacIRConstantString] = [:]
        for constant in constant_strings {
            guard let kind = MacIRConstantString.Kind(rawValue: constant.kind) else {
                throw NativeScalarFixture.Failure.invalid("unknown constant kind")
            }
            let key = try Self.address(constant.address)
            guard constants.updateValue(.init(text: constant.text, kind: kind), forKey: key) == nil else {
                throw NativeScalarFixture.Failure.invalid("duplicate constant")
            }
        }
        var calls: [UInt64: PseudocodeIndirectCall] = [:]
        for call in resolved_indirect_calls {
            let value = PseudocodeIndirectCall(target: try Self.address(call.target), name: call.name, slot: call.slot)
            guard calls.updateValue(value, forKey: try Self.address(call.call_address)) == nil else {
                throw NativeScalarFixture.Failure.invalid("duplicate indirect call")
            }
        }
        let width = caller_return_width.flatMap(MacIRCallerReturnEvidence.Width.init(rawValue:))
        guard caller_return_width == nil || width != nil else {
            throw NativeScalarFixture.Failure.invalid("unknown caller return width")
        }
        var input = PseudocodeRenderInput(imageSlot: image_slot, functionName: function_name,
            startAddress: try start_address.map(Self.address), jumpTables: tables,
            objcSelectors: try Self.dictionary(objc_selectors), constantStrings: constants,
            nameOverrides: name_overrides, signatureOverrides: try Self.dictionary(signature_overrides),
            authoredCallSignaturesByTarget: authored_call_signatures_by_target,
            registerNameOverrides: register_name_overrides, stackLocalOverrides: stack_local_overrides,
            types: types, instructions: rows, resolvedIndirectCalls: calls,
            slotCallContracts: try Self.dictionary(slot_call_contracts),
            callerReturnWidth: width, callerReturnType: caller_return_type)
        try NativeScalarParameterIndex.restore(indices, into: &input)
        return input
    }

    static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }
    static func address(_ text: String) throws -> UInt64 {
        guard text.hasPrefix("0x"), let value = UInt64(text.dropFirst(2), radix: 16), hex(value) == text else {
            throw NativeScalarFixture.Failure.invalid("noncanonical UInt64 address: \(text)")
        }
        return value
    }
    private static func entries<V: Codable & Equatable>(_ map: [UInt64: V]) -> [AddressEntry<V>] {
        map.keys.sorted().map { AddressEntry(address: hex($0), value: map[$0]!) }
    }
    private static func dictionary<V: Codable & Equatable>(_ entries: [AddressEntry<V>]) throws -> [UInt64: V] {
        var result: [UInt64: V] = [:]
        for entry in entries {
            guard result.updateValue(entry.value, forKey: try address(entry.address)) == nil else {
                throw NativeScalarFixture.Failure.invalid("duplicate address key")
            }
        }
        return result
    }
}

/// ArgOverride Codable AND equality omit index. A semantic == alone is not enough.
/// These independent coordinates retain all stored indices, including any nondefault
/// value, without injecting forbidden `index` keys into native parameterList JSON.
struct NativeScalarParameterIndex: Codable, Equatable {
    let dictionary: String
    let key: String
    let parameter_position: Int
    let row_token: String
    let compatibility_index: Int

    static func capture(_ input: PseudocodeRenderInput) -> [Self] {
        var result: [Self] = []
        func append(_ signature: FunctionSignatureOverride, dictionary: String, key: String) {
            guard case let .authoritative(rows) = signature.parameterList else { return }
            for (position, row) in rows.enumerated() {
                result.append(Self(dictionary: dictionary, key: key, parameter_position: position,
                                   row_token: row.rowToken, compatibility_index: row.index))
            }
        }
        for key in input.signatureOverrides.keys.sorted() {
            append(input.signatureOverrides[key]!, dictionary: "signature_overrides", key: NativeScalarContext.hex(key))
        }
        for key in input.authoredCallSignaturesByTarget.keys.sorted() {
            append(input.authoredCallSignaturesByTarget[key]!, dictionary: "authored_call_signatures_by_target", key: key)
        }
        return result
    }

    static func restore(_ ledger: [Self], into input: inout PseudocodeRenderInput) throws {
        let coordinates = capture(input)
        guard coordinates.count == ledger.count else {
            throw NativeScalarFixture.Failure.invalid("incomplete/extra signature compatibility ledger")
        }
        for (decoded, saved) in zip(coordinates, ledger) {
            guard decoded.dictionary == saved.dictionary, decoded.key == saved.key,
                  decoded.parameter_position == saved.parameter_position, decoded.row_token == saved.row_token else {
                throw NativeScalarFixture.Failure.invalid("signature compatibility ledger identity/order mismatch")
            }
            func patched(_ signature: FunctionSignatureOverride) throws -> FunctionSignatureOverride {
                var result = signature
                guard case var .authoritative(rows) = result.parameterList,
                      rows.indices.contains(saved.parameter_position),
                      rows[saved.parameter_position].rowToken == saved.row_token else {
                    throw NativeScalarFixture.Failure.invalid("missing signature row")
                }
                // @testable access to the native stored compatibility coordinate.
                // Direct property replacement avoids a normalizing initializer.
                rows[saved.parameter_position].index = saved.compatibility_index
                result.parameterList = .authoritative(rows)
                return result
            }
            switch saved.dictionary {
            case "signature_overrides":
                let key = try NativeScalarContext.address(saved.key)
                guard let signature = input.signatureOverrides[key] else {
                    throw NativeScalarFixture.Failure.invalid("missing address signature")
                }
                input.signatureOverrides[key] = try patched(signature)
            case "authored_call_signatures_by_target":
                guard let signature = input.authoredCallSignaturesByTarget[saved.key] else {
                    throw NativeScalarFixture.Failure.invalid("missing target signature")
                }
                input.authoredCallSignaturesByTarget[saved.key] = try patched(signature)
            default:
                throw NativeScalarFixture.Failure.invalid("unknown signature dictionary")
            }
        }
        guard capture(input) == ledger else {
            throw NativeScalarFixture.Failure.invalid("stored signature indices were normalized or lost")
        }
    }
}
