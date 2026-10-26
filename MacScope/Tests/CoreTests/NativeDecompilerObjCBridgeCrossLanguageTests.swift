#if MACSCOPE_NATIVE_BRIDGE_CROSS_LANGUAGE_STANDALONE
import Foundation

private enum CrossLanguageFixtureError: Error {
    case failed(String)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CrossLanguageFixtureError.failed(message) }
}

private func validateCP4Fixtures(directory: String) throws {
    let codec = NativeDecompilerWireCodec()
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    for name in ["partition", "authentication"] {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let requestData = try Data(contentsOf: root.appendingPathComponent("\(name)-request.bplist"))
        // Foundation emits the fixture request dictionary; type and canonicalize it
        // exactly as the existing standalone harness does. Production reply bytes
        // below are consumed unchanged and must equal Swift's canonical encoding.
        let requestValue = try PropertyListDecoder().decode(NativeDecompilerWireRequestEnvelope.self, from: requestData)
        let request = try codec.decodeRequest(codec.encodeRequest(requestValue, matching: requestID), matching: requestID)
        let binding = NativeDecompilerWireExpectedRequestBinding(request: request)
        let replyData = try Data(contentsOf: root.appendingPathComponent("\(name)-reply.bplist"))
        let reply = try codec.decodeReply(replyData, matching: binding)
        guard let result = reply.success?.result else {
            throw CrossLanguageFixtureError.failed("missing CP4 result")
        }
        try require(request.schemaVersion == 3 && reply.schemaVersion == 4, "CP4 migration versions differ")
        try require(result.requiredReplySchemaVersion == 4, "CP4 required reply version differs")
        try require(result.requestSHA256 == request.body.requestSHA256, "CP4 request digest differs")
        let canonical = try codec.encodeReply(reply, matching: binding)
        try require(canonical == replyData, "production CP4 bytes differ from Swift canonical encoding")
        try canonical.write(to: root.appendingPathComponent("\(name)-swift-reply.bplist"), options: .atomic)
        if name == "partition" {
            guard let metadata = result.blockPartition else { throw CrossLanguageFixtureError.failed("missing partition") }
            try require(metadata.version == 1, "partition version differs")
            try require(metadata.blocks.map(\.ordinal) == [0, 1], "partition ordinals differ")
            try require(metadata.blocks.map(\.entryAddress.value) == [0x1000, 0x1000], "partition addresses differ")
            try require(metadata.instructions.map(\.instructionID) == ["instruction:0"], "partition instruction differs")
            try require(metadata.instructions[0].spans.map(\.operationCount) == [0, 1], "span operation counts differ")
            try require(metadata.instructions[0].spans.map(\.firstOperationIndex) == [0, 0], "span first indices differ")
            try require(metadata.edges.map(\.transferKind) == [.splice], "partition transfer kind differs")
            try require(metadata.edges.map(\.sourceSlot) == [0] && metadata.edges.map(\.targetSlot) == [0], "partition slots differ")
            try require(result.blocks[0].terminatorKind == .splice && result.edges[0].kind == .splice, "splice kind differs")
        } else {
            try require(result.blockPartition == nil, "unexpected authentication partition")
            try require(result.operations[0].authenticationEffect.kind == .standaloneAuthenticationWithoutTransformedOutput,
                        "standalone authentication kind differs")
            try require(result.operations[0].authenticationEffect.outputSSAValueID == nil, "invented authentication output")
        }
        var plist = try PropertyListSerialization.propertyList(from: replyData, options: [], format: nil) as! [String: Any]
        plist["schemaVersion"] = 3
        let downgraded = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        var downgradeRejected = false
        do { _ = try codec.decodeReply(downgraded, matching: binding) } catch { downgradeRejected = true }
        try require(downgradeRejected, "CP4 reply downgrade accepted")
        plist["schemaVersion"] = 4
        var success = plist["success"] as! [String: Any]
        var object = success["result"] as! [String: Any]
        if name == "partition" {
            var metadata = object["blockPartition"] as! [String: Any]
            metadata["unknownOwnership"] = true
            object["blockPartition"] = metadata
        } else {
            object["unknownAuthentication"] = true
        }
        success["result"] = object
        plist["success"] = success
        let unknown = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        var unknownRejected = false
        do { _ = try codec.decodeReply(unknown, matching: binding) } catch { unknownRejected = true }
        try require(unknownRejected, "unknown CP4 metadata accepted")
    }
}

private func expectedReply(
    request: NativeDecompilerWireRequest
) -> NativeDecompilerWireReplyEnvelope {
    let range: (UInt64, UInt64) -> NativeDecompilerWireSourceRange = { start, end in
        NativeDecompilerWireSourceRange(
            imageID: request.image.imageID,
            startAddress: .init(start),
            endAddressExclusive: .init(end)
        )
    }
    let result = NativeDecompilerWireStructuredResult(
        requestID: request.requestID,
        requestSHA256: request.requestSHA256,
        image: request.image,
        function: request.function,
        addressSpaces: [
            .init(id: "space.ram", name: "ram", kind: .processor, addressSizeBytes: 8,
                  isProcessorSpace: true),
            .init(id: "space.unique", name: "unique", kind: .unique, addressSizeBytes: 8,
                  isProcessorSpace: true),
        ],
        types: [
            .init(
                id: "type.function", kind: .function, name: "fixture_t", byteSize: nil,
                isSigned: nil, pointeeTypeID: nil, fields: [], confidence: .high,
                provenance: "contract-fixture", returnTypeID: "type.u64",
                parameterTypeIDs: ["type.u64"]
            ),
            .init(
                id: "type.pointer", kind: .pointer, name: "uint64_t *", byteSize: .init(8),
                isSigned: nil, pointeeTypeID: "type.u64", fields: [], confidence: .asserted,
                provenance: "caller-hint", returnTypeID: nil, parameterTypeIDs: []
            ),
            .init(
                id: "type.structure", kind: .structure, name: "fixture_struct", byteSize: .init(8),
                isSigned: nil, pointeeTypeID: nil,
                fields: [.init(name: "member", typeID: "type.u64", bitOffset: .init(0), bitSize: .init(64))],
                confidence: .medium, provenance: "native-recovery", returnTypeID: nil,
                parameterTypeIDs: []
            ),
            .init(
                id: "type.u64", kind: .integer, name: "uint64_t", byteSize: .init(8),
                isSigned: false, pointeeTypeID: nil, fields: [], confidence: .high,
                provenance: "contract-fixture", returnTypeID: nil, parameterTypeIDs: []
            ),
        ],
        instructions: [
            .init(id: "instruction.0", address: .init(0x1000), bytes: Data([1, 2, 3, 4]),
                  mnemonic: "cbz", body: "cbz w0, right", operationIDs: ["op.0"],
                  sourceRanges: [range(0x1000, 0x1004)]),
            .init(id: "instruction.1", address: .init(0x1004), bytes: Data([5, 6, 7, 8]),
                  mnemonic: "bl", body: "bl callee", operationIDs: ["op.1"],
                  sourceRanges: [range(0x1004, 0x1008)]),
            .init(id: "instruction.2", address: .init(0x1008), bytes: Data([9, 10, 11, 12]),
                  mnemonic: "mov", body: "mov x0, #2", operationIDs: ["op.2"],
                  sourceRanges: [range(0x1008, 0x100c)]),
            .init(id: "instruction.3", address: .init(0x100c), bytes: Data([13, 14, 15, 16]),
                  mnemonic: "ret", body: "ret", operationIDs: ["op.3"],
                  sourceRanges: [range(0x100c, 0x1010)]),
        ],
        varnodes: [
            .init(id: "vn.condition", addressSpaceID: "space.unique", offset: .init(0), sizeBytes: 8,
                  role: .constant, typeID: "type.u64", registerName: nil),
            .init(id: "vn.result", addressSpaceID: "space.unique", offset: .init(8), sizeBytes: 8,
                  role: .register, typeID: "type.u64", registerName: "x0"),
        ],
        operations: [
            .init(id: "op.0", blockID: "block.0", sequence: .init(0), opcode: .cbranch,
                  outputVarnodeID: nil, inputVarnodeIDs: ["vn.condition"],
                  directTargetAddress: .init(0x1008), sourceRanges: [range(0x1000, 0x1004)]),
            .init(id: "op.1", blockID: "block.1", sequence: .init(0), opcode: .call,
                  outputVarnodeID: "vn.result", inputVarnodeIDs: ["vn.condition"],
                  directTargetAddress: .init(0x2000), sourceRanges: [range(0x1004, 0x1008)]),
            .init(id: "op.2", blockID: "block.2", sequence: .init(0), opcode: .callother,
                  outputVarnodeID: "vn.result", inputVarnodeIDs: ["vn.condition"],
                  directTargetAddress: nil, sourceRanges: [range(0x1008, 0x100c)],
                  userOperationName: "pacia",
                  authenticationEffect: .init(kind: .transformedOutput, outputSSAValueID: "ssa.right")),
            .init(id: "op.3", blockID: "block.3", sequence: .init(0), opcode: .return,
                  outputVarnodeID: nil, inputVarnodeIDs: ["vn.result"], directTargetAddress: nil,
                  sourceRanges: [range(0x100c, 0x1010)]),
        ],
        blocks: [
            .init(id: "block.0", startAddress: .init(0x1000), endAddressExclusive: .init(0x1004),
                  operationIDs: ["op.0"], predecessorEdgeIDs: [],
                  successorEdgeIDs: ["edge.0", "edge.1"], terminatorKind: .conditional),
            .init(id: "block.1", startAddress: .init(0x1004), endAddressExclusive: .init(0x1008),
                  operationIDs: ["op.1"], predecessorEdgeIDs: ["edge.0"],
                  successorEdgeIDs: ["edge.2"], terminatorKind: .branch),
            .init(id: "block.2", startAddress: .init(0x1008), endAddressExclusive: .init(0x100c),
                  operationIDs: ["op.2"], predecessorEdgeIDs: ["edge.1"],
                  successorEdgeIDs: ["edge.3"], terminatorKind: .branch),
            .init(id: "block.3", startAddress: .init(0x100c), endAddressExclusive: .init(0x1010),
                  operationIDs: ["op.3"], predecessorEdgeIDs: ["edge.2", "edge.3"],
                  successorEdgeIDs: [], terminatorKind: .return),
        ],
        edges: [
            .init(id: "edge.0", sourceBlockID: "block.0", targetBlockID: "block.1",
                  targetAddress: .init(0x1004), kind: .trueBranch, operationID: "op.0"),
            .init(id: "edge.1", sourceBlockID: "block.0", targetBlockID: "block.2",
                  targetAddress: .init(0x1008), kind: .falseBranch, operationID: "op.0"),
            .init(id: "edge.2", sourceBlockID: "block.1", targetBlockID: "block.3",
                  targetAddress: .init(0x100c), kind: .branch, operationID: "op.1"),
            .init(id: "edge.3", sourceBlockID: "block.2", targetBlockID: "block.3",
                  targetAddress: .init(0x100c), kind: .branch, operationID: "op.2"),
        ],
        ssaValues: [
            .init(id: "ssa.condition", varnodeID: "vn.condition", kind: .constant,
                  definingOperationID: nil, definingPhiID: nil),
            .init(id: "ssa.left", varnodeID: "vn.result", kind: .operationResult,
                  definingOperationID: "op.1", definingPhiID: nil),
            .init(id: "ssa.phi", varnodeID: "vn.result", kind: .phiResult,
                  definingOperationID: nil, definingPhiID: "phi.0"),
            .init(id: "ssa.right", varnodeID: "vn.result", kind: .operationResult,
                  definingOperationID: "op.2", definingPhiID: nil),
        ],
        ssaBindings: [
            .init(operationID: "op.0", inputSSAValueIDs: ["ssa.condition"], outputSSAValueID: nil),
            .init(operationID: "op.1", inputSSAValueIDs: ["ssa.condition"], outputSSAValueID: "ssa.left"),
            .init(operationID: "op.2", inputSSAValueIDs: ["ssa.condition"], outputSSAValueID: "ssa.right"),
            .init(operationID: "op.3", inputSSAValueIDs: ["ssa.phi"], outputSSAValueID: nil),
        ],
        phis: [.init(
            id: "phi.0", blockID: "block.3", varnodeID: "vn.result", outputSSAValueID: "ssa.phi",
            incoming: [
                .init(sourceBlockID: "block.1", edgeID: "edge.2", ssaValueID: "ssa.left"),
                .init(sourceBlockID: "block.2", edgeID: "edge.3", ssaValueID: "ssa.right"),
            ]
        )],
        memoryVersions: [
            .init(id: "memory.entry", partition: "unknown", kind: .functionEntry,
                  definingOperationID: nil, definingMemoryPhiID: nil),
            .init(id: "memory.left", partition: "unknown", kind: .operationResult,
                  definingOperationID: "op.1", definingMemoryPhiID: nil),
            .init(id: "memory.merge", partition: "unknown", kind: .phiResult,
                  definingOperationID: nil, definingMemoryPhiID: "memory-phi.0"),
            .init(id: "memory.right", partition: "unknown", kind: .operationResult,
                  definingOperationID: "op.2", definingMemoryPhiID: nil),
        ],
        memoryPhis: [.init(
            id: "memory-phi.0", blockID: "block.3", partition: "unknown",
            outputMemoryVersionID: "memory.merge",
            incoming: [
                .init(sourceBlockID: "block.1", edgeID: "edge.2", memoryVersionID: "memory.left"),
                .init(sourceBlockID: "block.2", edgeID: "edge.3", memoryVersionID: "memory.right"),
            ]
        )],
        memoryEffects: [
            .init(id: "effect.left", operationID: "op.1", kind: .write, partition: "unknown",
                  inputMemoryVersionID: "memory.entry", outputMemoryVersionID: "memory.left"),
            .init(id: "effect.merge-read", operationID: "op.3", kind: .read, partition: "unknown",
                  inputMemoryVersionID: "memory.merge", outputMemoryVersionID: nil),
            .init(id: "effect.right", operationID: "op.2", kind: .write, partition: "unknown",
                  inputMemoryVersionID: "memory.entry", outputMemoryVersionID: "memory.right"),
        ],
        variables: [
            .init(id: "variable.argument", name: "argument", role: .parameter, typeID: "type.u64",
                  storageVarnodeIDs: ["vn.condition"], liveRanges: [range(0x1000, 0x100c)],
                  confidence: .high, provenance: "contract-fixture"),
            .init(id: "variable.result", name: "result", role: .result, typeID: "type.u64",
                  storageVarnodeIDs: ["vn.result"], liveRanges: [range(0x1004, 0x1010)],
                  confidence: .high, provenance: "contract-fixture"),
        ],
        calls: [.init(
            id: "call.0", operationID: "op.1", kind: .direct, targetAddress: .init(0x2000),
            targetSymbol: "_callee", prototypeTypeID: "type.function",
            argumentVariableIDs: ["variable.argument"], resultVariableID: "variable.result",
            sourceRanges: [range(0x1004, 0x1008)]
        )],
        regions: [
            .init(id: "region.child", kind: .sequence, parentRegionID: "region.root",
                  childRegionIDs: [], blockIDs: ["block.3"], conditionOperationID: nil,
                  sourceRanges: [range(0x100c, 0x1010)]),
            .init(id: "region.root", kind: .root, parentRegionID: nil,
                  childRegionIDs: ["region.child"],
                  blockIDs: ["block.0", "block.1", "block.2", "block.3"],
                  conditionOperationID: "op.0", sourceRanges: [range(0x1000, 0x1010)]),
        ],
        tokens: [
            .init(id: "token.0", text: "if", kind: .keyword, line: 1, column: 1,
                  sourceRanges: [range(0x1000, 0x1004)], entityReferences: [
                    .init(kind: .instruction, id: "instruction.0"),
                    .init(kind: .region, id: "region.root"),
                  ]),
            .init(id: "token.1", text: "callee", kind: .identifier, line: 2, column: 1,
                  sourceRanges: [range(0x1004, 0x1008)], entityReferences: [
                    .init(kind: .call, id: "call.0"),
                    .init(kind: .operation, id: "op.1"),
                  ]),
            .init(id: "token.2", text: "result", kind: .identifier, line: 3, column: 1,
                  sourceRanges: [range(0x100c, 0x1010)], entityReferences: [
                    .init(kind: .block, id: "block.3"),
                    .init(kind: .type, id: "type.u64"),
                    .init(kind: .variable, id: "variable.result"),
                    .init(kind: .varnode, id: "vn.result"),
                  ]),
        ],
        pseudocodeDocument: .init(
            text: "uint64_t fixture(uint64_t argument) {\n\treturn argument;\n}\n",
            language: "c",
            isComplete: true,
            isTruncated: false
        ),
        warnings: [.init(
            code: "fixture-warning", severity: .warning, message: "fixture warning",
            sourceRanges: [range(0x1000, 0x1004)]
        )]
    )
    let availability = NativeDecompilerWireBackendAvailability(
        available: true,
        reasonCode: "",
        runtimeIdentity: .init(
            backendID: "fixture-native-provider", engineVersion: "12.1.2",
            engineRevision: String(repeating: "b", count: 40), wrapperVersion: "dcp05c-v1",
            wrapperRevision: String(repeating: "c", count: 40),
            packageManifestSHA256: String(repeating: "d", count: 64),
            packageTreeSHA256: String(repeating: "e", count: 64),
            languageID: "AARCH64:LE:64:AppleSilicon", compilerSpecID: "default",
            targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
            contextProfileSHA256: "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
        ),
        capabilities: .init(
            nativeDecompilerHeritage: true, completeRegisterSSA: true, memorySSA: true,
            recoveredVariables: true, recoveredTypes: true, structuredControlFlow: true,
            tokenizedPseudocode: true, imageQualifiedSourceRanges: true
        )
    )
    return NativeDecompilerWireReplyEnvelope(
        requestID: request.requestID,
        success: NativeDecompilerWireSuccess(availability: availability, result: result)
    )
}

private func validateMappingCoverage(_ data: Data) throws {
    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let root = object as? [String: Any], Set(root.keys) == [
        "enums", "optionals", "tokenEntityKinds",
    ], let enums = root["enums"] as? [String: [String]],
       let optionals = root["optionals"] as? [String: [String: Bool]],
       let tokenEntityKinds = root["tokenEntityKinds"] as? [String] else {
        throw CrossLanguageFixtureError.failed("mapping coverage fixture shape differs")
    }

    let expectedEnums: [String: Set<String>] = [
        "addressSpaceKinds": ["constant", "processor", "spacebase", "unique", "fspec", "iop", "join"],
        "typeKinds": [
            "array", "boolean", "enumeration", "floating-point", "function", "integer",
            "pointer", "structure", "union", "unknown", "void",
        ],
        "varnodeRoles": [
            "address", "constant", "internal", "join", "memory", "register", "stack", "unique",
        ],
        "opcodes": Set(NativeDecompilerWireOpcode.allCases.map(\.rawValue)),
        "blockTerminatorKinds": ["branch", "conditional", "exit", "fallthrough", "return", "switch"],
        "edgeKinds": ["branch", "fallthrough", "false", "switch-case", "switch-default", "true"],
        "ssaValueKinds": ["annotation", "constant", "function-entry", "operation-result", "phi-result"],
        "memoryVersionKinds": ["function-entry", "operation-result", "phi-result"],
        "memoryEffectKinds": ["read", "write", "read-write"],
        "variableRoles": ["global", "local", "parameter", "result", "temporary"],
        "callKinds": ["direct", "indirect"],
        "regionKinds": [
            "condition", "do-while", "goto", "if", "infinite-loop", "multi-goto", "root",
            "sequence", "switch", "while",
        ],
        "tokenKinds": [
            "comment", "identifier", "keyword", "literal", "operation", "punctuation", "type",
            "whitespace",
        ],
        "diagnosticSeverities": ["error", "information", "warning"],
        "confidences": ["asserted", "high", "medium", "low", "unknown"],
        "failureCodes": Set(
            NativeDecompilerWireFailureCode.allCases
                .filter { $0 != .malformedReply }
                .map(\.rawValue)
        ),
    ]
    try require(Set(enums.keys) == Set(expectedEnums.keys), "mapping enum families differ")
    for (family, expected) in expectedEnums {
        guard let values = enums[family] else {
            throw CrossLanguageFixtureError.failed("missing enum family \(family)")
        }
        try require(values.count == expected.count, "duplicate or missing enum mapping in \(family)")
        try require(Set(values) == expected, "enum mapping differs in \(family)")
    }

    let expectedOptionals: Set<String> = [
        "types.byteSize", "types.isSigned", "types.pointeeTypeID", "types.returnTypeID",
        "varnodes.typeID", "varnodes.registerName",
        "operations.outputVarnodeID", "operations.directTargetAddress",
        "edges.targetBlockID", "edges.operationID",
        "ssaValues.definingOperationID", "ssaValues.definingPhiID",
        "ssaBindings.outputSSAValueID",
        "phis.incoming.sourceBlockID", "phis.incoming.edgeID",
        "memoryVersions.definingOperationID", "memoryVersions.definingMemoryPhiID",
        "memoryPhis.incoming.sourceBlockID", "memoryPhis.incoming.edgeID",
        "memoryEffects.inputMemoryVersionID", "memoryEffects.outputMemoryVersionID",
        "variables.typeID",
        "calls.targetAddress", "calls.targetSymbol", "calls.prototypeTypeID", "calls.resultVariableID",
        "regions.parentRegionID", "regions.conditionOperationID",
    ]
    try require(Set(optionals.keys) == expectedOptionals, "optional mapping inventory differs")
    for (path, coverage) in optionals {
        try require(
            coverage == ["present": true, "absent": true],
            "optional mapping does not prove both states: \(path)"
        )
    }

    let expectedTokenEntities: Set<String> = [
        "block", "call", "instruction", "operation", "region", "type", "variable", "varnode",
    ]
    try require(tokenEntityKinds.count == expectedTokenEntities.count, "token entity mappings duplicate")
    try require(Set(tokenEntityKinds) == expectedTokenEntities, "token entity mappings differ")
}

@main
private enum NativeDecompilerObjCBridgeCrossLanguageMain {
    static func main() throws {
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--validate-cp4-fixtures" {
            try validateCP4Fixtures(directory: CommandLine.arguments[2])
            return
        }
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--validate-request" {
            let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
            _ = try NativeDecompilerWireCodec().decodeRequest(input, matching: requestID)
            return
        }
        if CommandLine.arguments.count == 4,
           CommandLine.arguments[1] == "--canonicalize-request" {
            let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let request = try PropertyListDecoder().decode(
                NativeDecompilerWireRequestEnvelope.self,
                from: input
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(request).write(
                to: URL(fileURLWithPath: CommandLine.arguments[3]),
                options: .atomic
            )
            return
        }
        if CommandLine.arguments.count == 4,
           CommandLine.arguments[1] == "--canonicalize-reply" {
            let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let reply = try PropertyListDecoder().decode(
                NativeDecompilerWireReplyEnvelope.self,
                from: input
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(reply).write(
                to: URL(fileURLWithPath: CommandLine.arguments[3]),
                options: .atomic
            )
            return
        }
        if CommandLine.arguments.count == 5,
           CommandLine.arguments[1] == "--validate-package-backed" {
            try validatePackageBackedReply(
                requestPath: CommandLine.arguments[2],
                replyPath: CommandLine.arguments[3],
                swiftOutputPath: CommandLine.arguments[4]
            )
            return
        }
        try require(
            CommandLine.arguments.count == 5,
            "expected request, reply, mapping-coverage, and Swift-output paths"
        )
        let requestData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let replyData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let mappingData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let swiftOutputURL = URL(fileURLWithPath: CommandLine.arguments[4])
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let codec = NativeDecompilerWireCodec()
        let request = try codec.decodeRequest(requestData, matching: requestID)
        let binding = NativeDecompilerWireExpectedRequestBinding(request: request)
        let reply = try codec.decodeReply(replyData, matching: binding)
        let canonicalBytes = try codec.encodeReply(reply, matching: binding)
        try require(
            canonicalBytes == replyData,
            "Objective-C++ reply bytes differ from Swift canonical encoding"
        )
        let roundTrip = try codec.decodeReply(canonicalBytes, matching: binding)
        let repeatedCanonicalBytes = try codec.encodeReply(roundTrip, matching: binding)

        try validateMappingCoverage(mappingData)
        try require(
            repeatedCanonicalBytes == canonicalBytes,
            "Swift canonical reply bytes are not deterministic"
        )
        try require(roundTrip == reply, "Swift record round trip differs from Objective-C++")
        try require(reply == expectedReply(request: request.body), "decoded reply differs from independent Swift graph")
        try canonicalBytes.write(to: swiftOutputURL, options: .atomic)
        try require(reply.outcome == .success && reply.failure == nil, "expected success union")
        guard let success = reply.success else {
            throw CrossLanguageFixtureError.failed("missing success payload")
        }
        let capabilities = success.availability.capabilities
        try require(success.availability.available, "availability is false")
        try require(
            capabilities.nativeDecompilerHeritage && capabilities.completeRegisterSSA &&
            capabilities.memorySSA && capabilities.recoveredVariables &&
            capabilities.recoveredTypes && capabilities.structuredControlFlow &&
            capabilities.tokenizedPseudocode && capabilities.imageQualifiedSourceRanges,
            "full capability vector was not preserved"
        )

        let result = success.result
        try require(result.requestID == requestID, "result request UUID differs")
        try require(result.requestSHA256 == request.body.requestSHA256, "result digest differs")
        try require(result.image == request.body.image, "result image differs")
        try require(result.function == request.body.function, "result function differs")
        try require(result.addressSpaces.map(\.id) == ["space.ram", "space.unique"], "spaces differ")
        try require(
            result.types.map(\.id) == ["type.function", "type.pointer", "type.structure", "type.u64"],
            "types differ"
        )
        try require(result.types[0].returnTypeID == "type.u64", "return type optional missing")
        try require(result.types[0].parameterTypeIDs == ["type.u64"], "parameter type differs")
        try require(result.types[1].pointeeTypeID == "type.u64", "pointee optional missing")
        try require(result.types[2].fields.count == 1, "type field record missing")
        try require(result.types[3].byteSize?.value == 8, "byte-size optional missing")
        try require(result.types[3].isSigned == false, "signedness optional differs")
        try require(result.instructions.map(\.id) == [
            "instruction.0", "instruction.1", "instruction.2", "instruction.3",
        ], "instructions differ")
        try require(result.varnodes.map(\.id) == ["vn.condition", "vn.result"], "varnodes differ")
        try require(result.varnodes[1].typeID == "type.u64", "varnode type optional missing")
        try require(result.varnodes[1].registerName == "x0", "register optional missing")
        try require(result.operations.map(\.id) == ["op.0", "op.1", "op.2", "op.3"], "operations differ")
        try require(result.operations[0].opcode == .cbranch, "opcode enum differs")
        try require(result.operations[0].directTargetAddress?.value == 0x1008, "branch target missing")
        try require(result.operations[1].outputVarnodeID == "vn.result", "operation output missing")
        try require(result.operations[2].userOperationName == "pacia", "PAC user-operation name lost")
        try require(result.operations[2].authenticationEffect ==
            .init(kind: .transformedOutput, outputSSAValueID: "ssa.right"), "PAC SSA effect lost")
        try require(result.operations[0].authenticationEffect == .none, "ordinary operation effect differs")
        try require(result.blocks.map(\.id) == ["block.0", "block.1", "block.2", "block.3"], "blocks differ")
        try require(result.blocks[0].terminatorKind == .conditional, "terminator enum differs")
        try require(result.edges.map(\.id) == ["edge.0", "edge.1", "edge.2", "edge.3"], "edges differ")
        try require(result.edges[0].targetBlockID == "block.1", "edge target optional missing")
        try require(result.edges[0].operationID == "op.0", "edge operation optional missing")
        try require(result.ssaValues.map(\.id) == [
            "ssa.condition", "ssa.left", "ssa.phi", "ssa.right",
        ], "SSA values differ")
        try require(result.ssaValues[1].definingOperationID == "op.1", "SSA operation optional missing")
        try require(result.ssaValues[2].definingPhiID == "phi.0", "SSA phi optional missing")
        try require(result.ssaBindings.count == 4, "SSA bindings differ")
        try require(result.ssaBindings[1].outputSSAValueID == "ssa.left", "SSA output missing")
        try require(result.phis.count == 1 && result.phis[0].incoming.count == 2, "phi graph differs")
        try require(result.phis[0].incoming[0].sourceBlockID == "block.1", "phi source missing")
        try require(result.phis[0].incoming[0].edgeID == "edge.2", "phi edge missing")
        try require(result.memoryVersions.map(\.id) == [
            "memory.entry", "memory.left", "memory.merge", "memory.right",
        ], "memory versions differ")
        try require(
            result.memoryVersions[2].definingMemoryPhiID == "memory-phi.0",
            "memory phi definition missing"
        )
        try require(result.memoryPhis.count == 1 && result.memoryPhis[0].incoming.count == 2, "memory phi differs")
        try require(result.memoryEffects.map(\.id) == [
            "effect.left", "effect.merge-read", "effect.right",
        ], "memory effects differ")
        try require(result.memoryEffects[0].inputMemoryVersionID == "memory.entry", "memory input missing")
        try require(result.memoryEffects[0].outputMemoryVersionID == "memory.left", "memory output missing")
        try require(result.variables.map(\.id) == ["variable.argument", "variable.result"], "variables differ")
        try require(result.variables[0].typeID == "type.u64", "variable type missing")
        try require(result.calls.count == 1 && result.calls[0].kind == .direct, "call record differs")
        try require(result.calls[0].targetAddress?.value == 0x2000, "call target missing")
        try require(result.calls[0].targetSymbol == "_callee", "call symbol missing")
        try require(result.calls[0].prototypeTypeID == "type.function", "call prototype missing")
        try require(result.calls[0].resultVariableID == "variable.result", "call result missing")
        try require(result.regions.map(\.id) == ["region.child", "region.root"], "regions differ")
        try require(result.regions[0].parentRegionID == "region.root", "region parent missing")
        try require(result.regions[1].conditionOperationID == "op.0", "region condition missing")
        try require(result.tokens.map(\.id) == ["token.0", "token.1", "token.2"], "tokens differ")
        try require(
            result.pseudocodeDocument?.text ==
                "uint64_t fixture(uint64_t argument) {\n\treturn argument;\n}\n",
            "pseudocode document differs"
        )
        try require(Set(result.tokens[2].entityReferences.map(\.kind)) == [
            .block, .type, .variable, .varnode,
        ], "token entity enum set differs")
        try require(result.warnings.count == 1, "diagnostic record missing")
        try require(result.warnings[0].severity == .warning, "diagnostic enum differs")
        try require(result.warnings[0].sourceRanges.count == 1, "diagnostic range missing")
    }

    private static func validatePackageBackedReply(
        requestPath: String,
        replyPath: String,
        swiftOutputPath: String
    ) throws {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000077")!
        let requestData = try Data(contentsOf: URL(fileURLWithPath: requestPath))
        let replyData = try Data(contentsOf: URL(fileURLWithPath: replyPath))
        let codec = NativeDecompilerWireCodec()
        let request = try codec.decodeRequest(requestData, matching: requestID)
        let binding = NativeDecompilerWireExpectedRequestBinding(request: request)
        let reply = try codec.decodeReply(replyData, matching: binding)
        guard let success = reply.success else {
            throw CrossLanguageFixtureError.failed("package-backed bridge did not return success")
        }
        try require(reply.outcome == .success && reply.failure == nil, "package-backed union differs")
        try require(success.availability.available, "package-backed availability is false")
        try require(success.result.requestID == requestID, "package-backed request identity differs")
        try require(success.result.requestSHA256 == request.body.requestSHA256, "package-backed digest differs")
        try require(success.result.image == request.body.image, "package-backed image differs")
        try require(success.result.function == request.body.function, "package-backed function differs")
        try require(success.result.instructions.count == 2, "package-backed instruction coverage differs")
        try require(!success.result.operations.isEmpty, "package-backed p-code is empty")
        try require(!success.result.blocks.isEmpty, "package-backed CFG is empty")
        try require(
            success.result.ssaBindings.count == success.result.operations.count,
            "package-backed mandatory SSA bindings differ"
        )
        let effectiveInstructionBytes = success.result.instructions.reduce(into: Data()) {
            $0.append($1.bytes)
        }
        try require(
            effectiveInstructionBytes == Data([0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]),
            "package-backed result did not use exact effective function bytes"
        )
        let canonical = try codec.encodeReply(reply, matching: binding)
        let repeated = try codec.encodeReply(
            codec.decodeReply(canonical, matching: binding),
            matching: binding
        )
        try require(canonical == repeated, "package-backed Swift encoding is not deterministic")
        try canonical.write(to: URL(fileURLWithPath: swiftOutputPath), options: .atomic)
    }
}
#endif
