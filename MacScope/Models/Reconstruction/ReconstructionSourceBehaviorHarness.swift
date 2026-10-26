import Foundation

/// App-owned inputs and harness. Expected outputs come from actual independent original execution.
struct ReconstructionSourceBehaviorHarness: Hashable, Sendable {
    static let version = 1
    static let maximumCases = 256
    let inputs: [UInt32]

    enum Failure: Error { case invalidInputs, malformedOutput }

    init(inputs: [UInt32]) throws {
        guard !inputs.isEmpty, inputs.count <= Self.maximumCases,
              Set(inputs).count == inputs.count else { throw Failure.invalidInputs }
        self.inputs = inputs
    }

    static func forProfile(_ identifier: String) throws -> Self {
        switch try ReconstructionSourceProfile.enabled(identifier) {
        case .scalarU32V1: return try saturatingIncrementV1()
        case .adler32RecordV1: throw ReconstructionSourceProfile.Failure.disabledProfile
        }
    }

    static func saturatingIncrementV1() throws -> Self {
        try .init(inputs: ReconstructionSourceProfile.scalarU32V1.scalarInputs())
    }

    var sourceUTF8: Data {
        Data("""
        #include <stdint.h>
        #include <stdio.h>
        #include <inttypes.h>
        extern uint32_t reconstructed(uint32_t);
        int main(void) {
            const uint32_t inputs[] = {\(inputs.map { "UINT32_C(\($0))" }.joined(separator: ","))};
            for (unsigned i = 0; i < sizeof(inputs) / sizeof(inputs[0]); ++i) {
                uint32_t output = reconstructed(inputs[i]);
                if (printf("%" PRIu32 ":%" PRIu32 "\\n", inputs[i], output) < 0) return 74;
            }
            return 0;
        }

        """.utf8)
    }

    /// Strict bounded output parser; does not derive or invent expected values.
    func decodeObservedOutputs(_ bytes: Data) throws -> [UInt32] {
        guard bytes.count <= 16_384, let text = String(data: bytes, encoding: .utf8),
              text.last == "\n" else { throw Failure.malformedOutput }
        let lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == inputs.count else { throw Failure.malformedOutput }
        return try zip(lines, inputs).map { line, input in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0] == Substring(String(input)),
                  let output = UInt32(fields[1]), fields[1] == Substring(String(output)) else {
                throw Failure.malformedOutput
            }
            return output
        }
    }
}
