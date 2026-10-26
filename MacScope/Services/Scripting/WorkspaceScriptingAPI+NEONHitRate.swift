import Darwin
import Foundation

extension WorkspaceScriptingAPI {
    /// One explicitly authorized library measurement; never a general corpus API.
    static func libjpegNEONHitRate(snapshot: WorkspaceSnapshot) throws -> ScriptValue {
        let allowed = URL(fileURLWithPath: "/opt/homebrew/lib/libjpeg.8.dylib")
        guard snapshot.binaries.count == 1,
              let binary = snapshot.binary(in: .primary),
              let analysis = snapshot.analysis(in: .primary),
              URL(fileURLWithPath: binary.path).resolvingSymlinksInPath() == allowed.resolvingSymlinksInPath(),
              binary.architecture.lowercased().contains("arm64"),
              analysis.functions.count <= 10_000, analysis.instructions.count <= 2_000_000 else {
            throw ScriptingError.invalidArgument("neon-hitrate requires only the authorized arm64 libjpeg.8.dylib image within measurement bounds")
        }
        let path = allowed.resolvingSymlinksInPath().path
        func fileLease() throws -> [Int64] {
            var value = stat()
            guard lstat(path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
                throw ScriptingError.invalidArgument("neon-hitrate binary is unavailable or not an ordinary file")
            }
            return [Int64(value.st_dev), Int64(bitPattern: UInt64(value.st_ino)), Int64(value.st_mode),
                    Int64(value.st_nlink), value.st_size, Int64(value.st_mtimespec.tv_sec),
                    Int64(value.st_mtimespec.tv_nsec), Int64(value.st_ctimespec.tv_sec),
                    Int64(value.st_ctimespec.tv_nsec)]
        }
        let initialLease = try fileLease()
        let rows = analysis.instructions.sorted { $0.address < $1.address }
        func firstIndex(_ address: UInt64) -> Int {
            var lower = 0, upper = rows.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if rows[middle].address < address { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
        func encodedWord(_ row: InstructionRow) -> UInt32? {
            let tokens = row.bytes.split(separator: " ")
            guard tokens.count == 4, tokens.allSatisfy({ $0.count == 2 }) else { return nil }
            let bytes = tokens.compactMap { UInt8($0, radix: 16) }
            guard bytes.count == 4 else { return nil }
            return bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        }
        func containsNEON(_ row: InstructionRow, word: UInt32) -> Bool {
            // Advanced SIMD vector and scalar arithmetic encodings. Scalar FP
            // (0x1e...) is excluded. SIMD structure transfers and explicit Q/V
            // memory carriers count as NEON memory, including ordinary LDR Q.
            if word & 0x1e00_0000 == 0x0e00_0000 || word & 0x5e00_0000 == 0x5e00_0000
                || word & 0xbe00_0000 == 0x0c00_0000 { return true }
            let memory = ["ldr", "str", "ldur", "stur", "ldp", "stp", "ldnp", "stnp"]
            return memory.contains(row.mnemonic.lowercased())
                && row.operands.range(of: #"\b(?:q[0-9]+|v[0-9]+\.[0-9]+[bhsd])\b"#,
                                      options: .regularExpression) != nil
        }
        var neonFunctions = 0, liftedFunctions = 0, unclassifiedRows = 0, emptyFunctions = 0
        var hits: [ScriptValue] = []
        var visited = Set<UInt64>()
        for function in analysis.functions {
            guard visited.insert(function.startAddress).inserted else {
                throw ScriptingError.invalidArgument("neon-hitrate discovered duplicate function start")
            }
            let range = snapshot.functionRange(function)
            let body = Array(rows[firstIndex(range.lowerBound)..<firstIndex(range.upperBound)])
            guard body.count <= 100_000 else {
                throw ScriptingError.invalidArgument("neon-hitrate function exceeds instruction bound")
            }
            if body.isEmpty { emptyFunctions += 1 }
            var hasNEON = false
            for row in body {
                if let word = encodedWord(row) { hasNEON = hasNEON || containsNEON(row, word: word) }
                else { unclassifiedRows += 1 }
            }
            guard hasNEON else { continue }
            neonFunctions += 1
            let ir = MacIRBuilder().buildFunction(name: function.name,
                startAddress: function.startAddress, jumpTables: snapshot.resolvedJumpTables(in: .primary),
                objcSelectors: analysis.objcSelectors, constantStrings: snapshot.constantStrings(in: .primary),
                instructions: body)
            // MacIRInstruction owns flat typed effect annotations. There are no
            // nested instruction arrays in MacIROperation; D06 regions belong
            // to the separate renderer and are deliberately never inspected.
            var kinds = Set<String>()
            for instruction in ir.instructions {
                if case .unknown = instruction.operation { continue }
                for child in Mirror(reflecting: instruction).children {
                    guard let label = child.label, label.hasPrefix("neon") else { continue }
                    let optional = Mirror(reflecting: child.value)
                    if optional.displayStyle == .optional && !optional.children.isEmpty { kinds.insert(label) }
                }
            }
            if !kinds.isEmpty {
                liftedFunctions += 1
                if hits.count < 10 {
                    hits.append(.object(["name": .string(function.name), "address": .hex(function.startAddress),
                                         "typedMatchers": .array(kinds.sorted().map(ScriptValue.string))]))
                }
            }
        }
        guard allowed.resolvingSymlinksInPath().path == path,
              try fileLease() == initialLease else {
            throw ScriptingError.invalidArgument("neon-hitrate binary metadata changed during measurement")
        }
        return .object([
            "schemaVersion": .int(1), "binary": .string(allowed.path), "resolvedBinary": .string(path),
            "scope": .string("one authorized installed-app analysis; discovered functions only; no corpus/generalization"),
            "functionCount": .int(Int64(visited.count)), "neonFunctionCount": .int(Int64(neonFunctions)),
            "exactLiftFunctionCount": .int(Int64(liftedFunctions)),
            "neonFunctionsWithoutExactLift": .int(Int64(neonFunctions - liftedFunctions)),
            "emptyFunctionCount": .int(Int64(emptyFunctions)), "unclassifiedInstructionRows": .int(Int64(unclassifiedRows)),
            "hitNames": .array(hits),
            "denominatorDefinition": .string("Advanced SIMD vector/scalar or structure-transfer encoding, plus explicit Q/V ordinary memory operands; scalar FP and scalar D-only memory are excluded"),
            "numeratorDefinition": .string("NEON-containing functions with at least one non-unknown MacIR instruction carrying a nonnil neon* typed annotation from MacIRBuilder; no native provider, renderer or generic D06 regions"),
        ])
    }
}
