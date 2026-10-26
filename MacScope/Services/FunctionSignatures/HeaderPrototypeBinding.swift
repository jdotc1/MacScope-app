import Foundation

/// Explicit header declarations bind only to unambiguous regular trie exports in
/// the selected image. A linker name is never inferred from a local symbol.
enum HeaderPrototypeBinding {
    struct Result {
        var signatures: [UInt64: FunctionSignatureOverride] = [:]
        var admittedCount = 0
        var refusedCount = 0
        var diagnostics: [String] = []
    }

    static func bind(_ prototypes: [HeaderFunctionPrototype], exports: [ExportSummary],
                     functions: [FunctionSummary], existingSignatures: [UInt64: FunctionSignatureOverride] = [:],
                     conflictingTypeNames: Set<String> = []) -> Result {
        let exportsByName = Dictionary(grouping: exports, by: \.name)
        let starts = Set(functions.map(\.startAddress))
        var candidates: [UInt64: [HeaderFunctionPrototype]] = [:]
        var result = Result()
        for prototype in prototypes {
            let matches = exportsByName["_" + prototype.name] ?? []
            let types = [prototype.signature.returnType ?? ""] + prototype.signature.args.map(\.type)
            let typeNames = Set(types.flatMap { $0.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init) })
            guard typeNames.isDisjoint(with: conflictingTypeNames), matches.count == 1,
                  let export = matches.first, let flags = export.terminalFlags,
                  // REGULAR kind (0), optionally WEAK_DEFINITION (4), no other
                  // terminal semantics, including reexport/resolver/static resolver.
                  flags & ~UInt64(0x04) == 0,
                  let address = export.address, starts.contains(address) else {
                result.refusedCount += 1
                result.diagnostics.append("Skipped prototype `\(prototype.name)`: no unique regular export at an analyzed function start, or a conflicting imported type.")
                continue
            }
            candidates[address, default: []].append(prototype)
        }
        for (address, group) in candidates {
            guard let first = group.first,
                  group.allSatisfy({ compatible($0.signature, first.signature) }),
                  existingSignatures[address].map({ compatible($0, first.signature) }) ?? true else {
                result.refusedCount += group.count
                result.diagnostics.append("Skipped incompatible exported prototypes at 0x\(String(address, radix: 16)).")
                continue
            }
            result.signatures[address] = first.signature
            result.admittedCount += group.count
        }
        return result
    }

    private static func compatible(_ lhs: FunctionSignatureOverride, _ rhs: FunctionSignatureOverride) -> Bool {
        lhs.returnType == rhs.returnType && lhs.variadicState == rhs.variadicState
            && lhs.args.map(\.type) == rhs.args.map(\.type)
    }
}
