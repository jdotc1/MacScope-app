import Foundation

/// Read-only call-boundary evidence. The caller attaches the selected image, slice,
/// and analysis generation before admitting these observations to a candidate.
enum ObjCSignatureCallSiteEvidence {
    static let maximumFunctions = 8
    static let maximumInstructionsPerFunction = 2_048
    static let maximumSites = 16
    static let maximumSelectorArguments = 64

    struct ValueShape: Equatable, Sendable {
        let value: String?
        let type: String?
        let widthBits: Int?

        fileprivate init(value: String? = nil) {
            self.value = value
            type = nil
            widthBits = nil
        }
    }

    struct Site: Equatable, Sendable {
        let address: UInt64
        let functionAddress: UInt64
        let selector: String
        let selrefAddress: UInt64
        let target: String
        let source: String
        let receiverShape: String?
        let selectorShape: String
        let argumentShapes: [ValueShape]
        let returnShape: ValueShape
    }

    static func collect(functions: [MacIRFunction], selector: String) -> [Site] {
        let arity = selector.unicodeScalars.filter { $0 == ":" }.count
        guard !selector.isEmpty, arity <= maximumSelectorArguments else { return [] }
        var sites: [Site] = []
        var seenAddresses: Set<UInt64> = []
        for function in functions.prefix(maximumFunctions) {
            guard function.instructions.count <= maximumInstructionsPerFunction else { continue }
            for instruction in function.instructions {
                guard case let .call(frame, result) = instruction.operation,
                      frame.target == "_objc_msgSend" || frame.target == "objc_msgSend",
                      let selectorArgument = frame.arguments.fixedArgument(at: 1),
                      let identity = selectorArgument.selectorEvidence,
                      identity.name == selector,
                      seenAddresses.insert(instruction.source.address).inserted else { continue }

                // The dispatch catalog's `id` result describes objc_msgSend, not the
                // selected method. Likewise selector arity proves no tail ABI layout.
                // Retain source-object unknowns rather than assigning GPR carriers.
                sites.append(Site(
                    address: instruction.source.address,
                    functionAddress: function.startAddress,
                    selector: identity.name,
                    selrefAddress: identity.selrefAddress,
                    target: frame.target,
                    source: "Structured MacIR",
                    receiverShape: frame.arguments.fixedArgument(at: 0).map { shape($0.value) },
                    selectorShape: shape(selectorArgument.value),
                    argumentShapes: Array(repeating: ValueShape(), count: arity),
                    returnShape: ValueShape(value: result.map { shape($0) })
                ))
                if sites.count == maximumSites { return sites }
            }
        }
        return sites
    }

    /// Describe the structured value category without reading or parsing pseudocode.
    private static func shape(_ value: MacIRValue) -> String {
        switch value {
        case let .register(name, version): "register \(name.prefix(32)) version \(version)"
        case .argument: "function parameter"
        case .argumentFragment: "source-object fragment"
        case .abiComposite: "source-object composite"
        case let .immediate(value): "constant \(value)"
        case let .stackSlot(offset): "stack slot \(offset)"
        case let .symbol(name): "symbol \(name.prefix(160))"
        case .temporary: "temporary"
        case .bitTest: "bit-test value"
        case .unary: "unary expression"
        case .binaryExpression: "binary expression"
        case .signedBitfield: "signed bitfield expression"
        case .unknown: "unknown"
        }
    }
}
