import Foundation
@testable import MacScope

struct NativeValueNavigationFixture {
    static let requestID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let artifactUUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let workspaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let ownerToken = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    let imageID = "image.value-fixture"
    var function = NativeDecompilerWireFunctionIdentity(
        functionID: "function.values", name: "values",
        entryAddress: .init(0x1000), endAddressExclusive: .init(0x1040)
    )
    var varnodes: [NativeDecompilerWireVarnodeRecord] = []
    var operations: [NativeDecompilerWireOperationRecord] = []
    var values: [NativeDecompilerWireSSAValueRecord] = []
    var bindings: [NativeDecompilerWireSSABindingRecord] = []
    var phis: [NativeDecompilerWirePhiRecord] = []
    var tokens: [NativeDecompilerWirePseudocodeTokenRecord] = []

    init() {
        func node(_ id: String, _ register: String?, constant: UInt64? = nil) -> NativeDecompilerWireVarnodeRecord {
            .init(id: id, addressSpaceID: constant == nil ? "register" : "constant",
                  offset: .init(constant ?? 0), sizeBytes: 8,
                  role: constant == nil ? .register : .constant,
                  typeID: nil, registerName: register)
        }
        varnodes = [
            node("vn.entry", "x0"), node("vn.one", nil, constant: 1),
            node("vn.shared", "x1"), node("vn.merged", "x2"),
            node("vn.sum", "x3"), node("vn.loaded", "x4"), node("vn.called", "x5")
        ]
        operations = [
            operation("op.left", .copy, 1, ["vn.entry"], "vn.shared", "block.left", 0x1008),
            operation("op.right", .intAdd, 2, ["vn.entry", "vn.one"], "vn.shared", "block.right", 0x1010),
            operation("op.phi", .multiequal, 3, ["vn.shared", "vn.shared"], "vn.merged", "block.join", 0x1018),
            operation("op.sum", .intAdd, 4, ["vn.merged", "vn.one"], "vn.sum", "block.join", 0x101c),
            operation("op.load", .load, 5, ["vn.one", "vn.entry"], "vn.loaded", "block.join", 0x1020),
            operation("op.call", .call, 6, ["vn.one", "vn.merged"], "vn.called", "block.join", 0x1024),
            operation("op.store", .store, 7, ["vn.one", "vn.entry", "vn.merged"], nil, "block.join", 0x1028),
            operation("op.return", .return, 8, ["vn.sum"], nil, "block.join", 0x102c)
        ]
        values = [
            .init(id: "v.entry", varnodeID: "vn.entry", kind: .functionEntry, definingOperationID: nil, definingPhiID: nil),
            .init(id: "v.one", varnodeID: "vn.one", kind: .constant, definingOperationID: nil, definingPhiID: nil),
            .init(id: "v.left", varnodeID: "vn.shared", kind: .operationResult, definingOperationID: "op.left", definingPhiID: nil),
            .init(id: "v.right", varnodeID: "vn.shared", kind: .operationResult, definingOperationID: "op.right", definingPhiID: nil),
            .init(id: "v.merged", varnodeID: "vn.merged", kind: .phiResult, definingOperationID: nil, definingPhiID: "phi.join"),
            .init(id: "v.sum", varnodeID: "vn.sum", kind: .operationResult, definingOperationID: "op.sum", definingPhiID: nil),
            .init(id: "v.loaded", varnodeID: "vn.loaded", kind: .operationResult, definingOperationID: "op.load", definingPhiID: nil),
            .init(id: "v.called", varnodeID: "vn.called", kind: .operationResult, definingOperationID: "op.call", definingPhiID: nil)
        ]
        bindings = [
            .init(operationID: "op.left", inputSSAValueIDs: ["v.entry"], outputSSAValueID: "v.left"),
            .init(operationID: "op.right", inputSSAValueIDs: ["v.entry", "v.one"], outputSSAValueID: "v.right"),
            .init(operationID: "op.phi", inputSSAValueIDs: ["v.left", "v.right"], outputSSAValueID: "v.merged"),
            .init(operationID: "op.sum", inputSSAValueIDs: ["v.merged", "v.one"], outputSSAValueID: "v.sum"),
            .init(operationID: "op.load", inputSSAValueIDs: ["v.one", "v.entry"], outputSSAValueID: "v.loaded"),
            .init(operationID: "op.call", inputSSAValueIDs: ["v.one", "v.merged"], outputSSAValueID: "v.called"),
            .init(operationID: "op.store", inputSSAValueIDs: ["v.one", "v.entry", "v.merged"], outputSSAValueID: nil),
            .init(operationID: "op.return", inputSSAValueIDs: ["v.sum"], outputSSAValueID: nil)
        ]
        phis = [.init(id: "phi.join", blockID: "block.join", varnodeID: "vn.merged",
                      outputSSAValueID: "v.merged", incoming: [
                        .init(sourceBlockID: "block.left", edgeID: "edge.left", ssaValueID: "v.left"),
                        .init(sourceBlockID: "block.right", edgeID: "edge.right", ssaValueID: "v.right")
                      ])]
        tokens = [
            token("token.merged", "merged", 1, 0x101c, [
                .init(kind: .varnode, id: "vn.merged"), .init(kind: .operation, id: "op.sum")
            ]),
            token("token.shared", "shared", 8, 0x1008, [.init(kind: .variable, id: "variable.shared")]),
            token("token.loaded", "loaded", 15, 0x1020, [
                .init(kind: .varnode, id: "vn.loaded"), .init(kind: .operation, id: "op.load")
            ]),
            token("token.called", "called", 22, 0x1024, [
                .init(kind: .varnode, id: "vn.called"), .init(kind: .call, id: "call.direct")
            ])
        ]
    }

    func range(_ address: UInt64) -> NativeDecompilerWireSourceRange {
        .init(imageID: imageID, startAddress: .init(address), endAddressExclusive: .init(address + 4))
    }

    func operation(
        _ id: String, _ opcode: NativeDecompilerWireOpcode, _ sequence: UInt64,
        _ inputs: [String], _ output: String?, _ block: String, _ address: UInt64
    ) -> NativeDecompilerWireOperationRecord {
        .init(id: id, blockID: block, sequence: .init(sequence), opcode: opcode,
              outputVarnodeID: output, inputVarnodeIDs: inputs,
              directTargetAddress: nil, sourceRanges: [range(address)])
    }

    func token(
        _ id: String, _ text: String, _ column: UInt32, _ address: UInt64,
        _ references: [NativeDecompilerWireTokenEntityReference]
    ) -> NativeDecompilerWirePseudocodeTokenRecord {
        .init(id: id, text: text, kind: .identifier, line: 1, column: column,
              sourceRanges: [range(address)], entityReferences: references)
    }

    var result: NativeDecompilerWireStructuredResult {
        func block(_ id: String, _ start: UInt64, _ end: UInt64, _ ids: [String],
                   _ incoming: [String], _ outgoing: [String]) -> NativeDecompilerWireBlockRecord {
            .init(id: id, startAddress: .init(start), endAddressExclusive: .init(end),
                  operationIDs: ids, predecessorEdgeIDs: incoming, successorEdgeIDs: outgoing,
                  terminatorKind: outgoing.isEmpty ? .return : .branch)
        }
        return .init(
            requestID: Self.requestID, requestSHA256: String(repeating: "a", count: 64),
            image: .init(imageID: imageID, uuid: Self.artifactUUID, preferredLoadAddress: .init(0x1000)),
            function: function,
            addressSpaces: [
                .init(id: "register", name: "register", kind: .processor, addressSizeBytes: 8, isProcessorSpace: false),
                .init(id: "constant", name: "const", kind: .constant, addressSizeBytes: 8, isProcessorSpace: false)
            ],
            types: [], instructions: [], varnodes: varnodes, operations: operations,
            blocks: [
                block("block.left", 0x1008, 0x100c, ["op.left"], [], ["edge.left"]),
                block("block.right", 0x1010, 0x1014, ["op.right"], [], ["edge.right"]),
                block("block.join", 0x1018, 0x1030,
                      ["op.phi", "op.sum", "op.load", "op.call", "op.store", "op.return"],
                      ["edge.left", "edge.right"], [])
            ],
            edges: [
                .init(id: "edge.left", sourceBlockID: "block.left", targetBlockID: "block.join",
                      targetAddress: .init(0x1018), kind: .branch, operationID: nil),
                .init(id: "edge.right", sourceBlockID: "block.right", targetBlockID: "block.join",
                      targetAddress: .init(0x1018), kind: .branch, operationID: nil)
            ],
            ssaValues: values, ssaBindings: bindings, phis: phis,
            memoryVersions: [
                .init(id: "memory.entry", partition: "unknown", kind: .functionEntry,
                      definingOperationID: nil, definingMemoryPhiID: nil),
                .init(id: "memory.store", partition: "unknown", kind: .operationResult,
                      definingOperationID: "op.store", definingMemoryPhiID: nil)
            ],
            memoryPhis: [],
            memoryEffects: [
                .init(id: "effect.load", operationID: "op.load", kind: .read, partition: "unknown",
                      inputMemoryVersionID: "memory.entry", outputMemoryVersionID: nil),
                .init(id: "effect.store", operationID: "op.store", kind: .write, partition: "unknown",
                      inputMemoryVersionID: "memory.entry", outputMemoryVersionID: "memory.store")
            ],
            variables: [
                .init(id: "variable.shared", name: "shared", role: .local, typeID: nil,
                      storageVarnodeIDs: ["vn.shared"], liveRanges: [range(0x1008), range(0x1010)],
                      confidence: .high, provenance: "fixture"),
                .init(id: "variable.merged", name: "merged", role: .local, typeID: nil,
                      storageVarnodeIDs: ["vn.merged"], liveRanges: [range(0x101c)],
                      confidence: .high, provenance: "fixture")
            ],
            calls: [
                .init(id: "call.direct", operationID: "op.call", kind: .direct,
                      targetAddress: nil, targetSymbol: "fixtureCallee", prototypeTypeID: nil,
                      argumentVariableIDs: ["variable.merged"], resultVariableID: nil,
                      sourceRanges: [range(0x1024)])
            ],
            regions: [], tokens: tokens,
            pseudocodeDocument: .init(text: "merged shared loaded called", language: "c", isComplete: true, isTruncated: false),
            warnings: []
        )
    }

    var success: NativeDecompilerWireSuccess {
        .init(availability: .init(
            available: true, reasonCode: "available",
            runtimeIdentity: .init(
                backendID: "native-decompiler", engineVersion: "12.1.2", engineRevision: "fixture",
                wrapperVersion: "fixture", wrapperRevision: "fixture",
                packageManifestSHA256: String(repeating: "c", count: 64),
                packageTreeSHA256: String(repeating: "d", count: 64),
                languageID: "AARCH64:LE:64:AppleSilicon", compilerSpecID: "default",
                targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
                contextProfileSHA256: String(repeating: "e", count: 64)
            ),
            capabilities: .init(
                nativeDecompilerHeritage: true, completeRegisterSSA: true, memorySSA: false,
                recoveredVariables: true, recoveredTypes: false, structuredControlFlow: true,
                tokenizedPseudocode: true, imageQualifiedSourceRanges: true
            )
        ), result: result)
    }

    @MainActor
    func scope(
        generation: UInt64 = 1,
        ownerToken: UUID = Self.ownerToken,
        workspaceID: UUID = Self.workspaceID,
        imageSlot: ImageSlot = .init(rawValue: 7),
        fingerprint: String = String(repeating: "b", count: 64)
    ) -> NativePseudocodeActionScope? {
        let coordinate = NativeDecompilerPresentationCoordinate(
            imageSlot: imageSlot, ownerBinaryID: Self.artifactUUID, artifactUUID: Self.artifactUUID,
            imageID: imageID, functionID: function.functionID, requestSHA256: result.requestSHA256,
            analysisInputFingerprintSHA256: fingerprint
        )
        return .init(
            workspaceID: workspaceID,
            publication: .init(ownerToken: ownerToken, generation: generation,
                               coordinate: coordinate, requestID: Self.requestID),
            state: .ready(coordinate: coordinate, success: success),
            expected: .init(imageSlot: imageSlot, ownerBinaryID: Self.artifactUUID,
                            artifactUUID: Self.artifactUUID, functionID: function.functionID,
                            analysisInputFingerprintSHA256: fingerprint)
        )
    }
}
