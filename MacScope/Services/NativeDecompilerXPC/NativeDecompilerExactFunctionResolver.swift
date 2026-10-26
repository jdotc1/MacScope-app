import Foundation

enum NativeDecompilerExactFunctionResolver {
    static func resolve(
        selectedAddress: UInt64,
        functions: [FunctionSummary]
    ) -> FunctionSummary? {
        let matches = functions.filter { function in
            guard function.endAddress >= function.startAddress else { return false }
            if function.endAddress > function.startAddress {
                return selectedAddress >= function.startAddress
                    && selectedAddress < function.endAddress
            }
            return selectedAddress == function.startAddress
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func resolve(
        functionID: UUID,
        functions: [FunctionSummary]
    ) -> FunctionSummary? {
        let matches = functions.filter { $0.id == functionID }
        return matches.count == 1 ? matches[0] : nil
    }
}
