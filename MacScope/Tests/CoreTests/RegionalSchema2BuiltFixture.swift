import Foundation
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Same-tip schema2 input authority. Historical fixtures are not consulted.
/// This factory is source-only until selected resources, applicability and the
/// exact caller are independently approved. Construction is not acceptance.
struct RegionalSchema2BuiltFixture {
    let capture: RegionalSchema2Fixture.Capture
    let input: PseudocodeRenderInput
    let original: MacIRFunction
    let document: PseudocodeDocument

    var rows: [InstructionRow] { input.instructions }
    /// Exact captured baseline text bound to source 39a734962, never an old-resource or fresh-print baseline.
    var baselineText: String { capture.canonical_text }

    struct Prepared {
        let capture: RegionalSchema2Fixture.Capture
        let input: PseudocodeRenderInput
        let original: MacIRFunction
    }
    var originalCFGBlocks: [RegionalSwitchFixture.CapturedBlock] {
        CFGBuilder.buildCFG(instructions: original.instructions).blocks.map {
            RegionalSwitchFixture.CapturedBlock($0, instructions: original.instructions)
        }
    }
    static func requireCompleteInputAuthority(_ input: PseudocodeRenderInput,
                                             capture: RegionalSchema2Fixture.Capture) throws {
        let restored = try capture.restoredInput()
        guard RegionalSchema2Context(input) == capture.render_input_context,
              RegionalSchema2Context(input) == RegionalSchema2Context(restored),
              RegionalSchema2ParameterIndex.capture(input) == capture.signature_parameter_compatibility_indices,
              RegionalSchema2ParameterIndex.capture(input) == RegionalSchema2ParameterIndex.capture(restored),
              input.instructions == capture.input_rows, input.instructions == restored.instructions else {
            throw RegionalSchema2Fixture.Failure.invalid("full eighteen-field input/three-map authority mismatch")
        }
    }

    /// Explicit independent binding and target; no default resource, schema1
    /// migration, workspace reconstruction, header import or machine decoding.
    /// One producer build and zero prints; no baseline or alternate-option print.
    static func prepare(resource: URL, binding: RegionalSchema2Fixture.Binding,
                        function: String, start: UInt64) throws -> Prepared {
        let captures = try RegionalSchema2Fixture.load(resource: resource, binding: binding)
        let matches = captures.filter {
            $0.function == function && $0.start == RegionalSchema2Context.hex(start)
        }
        guard matches.count == 1, let capture = matches.first else {
            throw RegionalSchema2Fixture.Failure.invalid("schema2 resource does not bind the requested exact target")
        }
        // Decoding alone is not restoration: this validates all 18 fields and
        // restores the exact three-map signature compatibility-index ledger.
        let input = try capture.restoredInput()
        guard input.functionName == function, input.startAddress == start,
              RegionalSchema2Context(input) == capture.render_input_context,
              RegionalSchema2ParameterIndex.capture(input) == capture.signature_parameter_compatibility_indices,
              input.instructions == capture.input_rows else {
            throw RegionalSchema2Fixture.Failure.invalid("complete schema2 input restoration mismatch")
        }
        let printer = PseudocodePrinter(options: .default)
        // All 13 buildFunction inputs. In particular, direct authority is the
        // complete captured signature map, never a substituted/default empty map.
        let original = printer.buildFunction(
            functionName: input.functionName,
            startAddress: input.startAddress,
            jumpTables: input.jumpTables,
            objcSelectors: input.objcSelectors,
            constantStrings: input.constantStrings,
            signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            directCallVoidResultTargets: input.directCallVoidResultTargets,
            slotCallContracts: input.slotCallContracts,
            callerReturnWidth: input.callerReturnWidth,
            callerReturnType: input.callerReturnType,
            types: input.types,
            instructions: input.instructions)
        guard original.instructions.count == input.instructions.count,
              zip(original.instructions, input.instructions).allSatisfy({ pair in
                  let (instruction, row) = pair
                  return instruction.source.address == row.address && instruction.source.byteText == row.bytes &&
                  instruction.source.mnemonic == row.mnemonic && instruction.source.operands == row.operands &&
                  instruction.source.comment == row.comment && instruction.source.structuredOperands == row.structuredOperands
              }),
              CFGBuilder.buildCFG(instructions: original.instructions).blocks.map({
                  NativeScalarFixture.FrozenBlock($0, instructions: original.instructions)
              }) == capture.cfg_blocks else {
            throw RegionalSchema2Fixture.Failure.invalid("schema2 source identity/CFG changed; not a presentation result")
        }
        return .init(capture: capture, input: input, original: original)
    }

    /// Exactly one original build and one candidate print. prepare is exposed
    /// separately for build-only certificate callers, not an extra print route.
    static func make(resource: URL, binding: RegionalSchema2Fixture.Binding,
                     function: String, start: UInt64) throws -> Self {
        let prepared = try prepare(resource: resource, binding: binding, function: function, start: start)
        let capture = prepared.capture, input = prepared.input, original = prepared.original
        let printer = PseudocodePrinter(options: .default)
        // All six parameters of this overload. imageSlot is retained/checked
        // above but neither Printer API accepts it. No unsupported parameter is
        // invented; the producer has already consumed the other input fields.
        let document = printer.print(
            function: original,
            types: input.types,
            nameOverrides: input.nameOverrides,
            registerNameOverrides: input.registerNameOverrides,
            stackLocalOverrides: input.stackLocalOverrides,
            resolvedIndirectCalls: input.resolvedIndirectCalls)
        return .init(capture: capture, input: input, original: original, document: document)
    }
}
