import Foundation

@main struct WireSizeBoundV3Probe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let codec = NativeDecompilerWireCodec()
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        // The ObjC fixture begins as a Foundation dictionary. Match the existing
        // cross-language harness by publishing a canonical Swift request first.
        let rawRequest = try PropertyListDecoder().decode(NativeDecompilerWireRequestEnvelope.self,
            from: Data(contentsOf: root.appendingPathComponent("request.bplist")))
        let canonicalRequest = try codec.encodeRequest(rawRequest, matching: requestID)
        let request = try codec.decodeRequest(canonicalRequest, matching: requestID)
        let binding = NativeDecompilerWireExpectedRequestBinding(request: request)
        for index in 0..<8 {
            let bytes = try Data(contentsOf: root.appendingPathComponent("case-\(index).reply"))
            let reply = try codec.decodeReply(bytes, matching: binding)
            guard let result = reply.success?.result,
                  let expected = UInt64(try String(contentsOf: root.appendingPathComponent("case-\(index).bound"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) else { fatalError("missing native bound") }
            precondition(NativeDecompilerWireSemanticValidator.estimatedStructuredResultBytes(result) == expected, "native/Swift v3 mismatch")
            precondition(UInt64(bytes.count) <= expected, "actual bytes exceed bound")
            let canonical = try codec.encodeReply(reply, matching: binding)
            precondition(canonical == bytes, "integer sharing canonicality mismatch")
        }
        print("PASS: eight native/Swift v3 bounds and canonical integer round trips")
    }
}
