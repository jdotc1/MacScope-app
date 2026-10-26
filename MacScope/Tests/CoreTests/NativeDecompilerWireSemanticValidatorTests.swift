import Foundation
import XCTest
@testable import MacScope

struct NativeDecompilerWireSemanticValidatorTestFixture {
    let request: NativeDecompilerWireRequest
    let capabilities: NativeDecompilerWireBackendCapabilities
    let result: NativeDecompilerWireStructuredResult
}

func makeNativeDecompilerWireSemanticValidatorTestFixture()
    -> NativeDecompilerWireSemanticValidatorTestFixture {
    NativeDecompilerWireSemanticValidatorTests.makeFixtureForSharing()
}

final class NativeDecompilerWireSemanticValidatorTests: XCTestCase {
    func testPACTransformedOutputRequiresExactOperationSSABinding() throws {
        let fixture = makeFixture()
        let original = fixture.result.operations[2]
        var operations = fixture.result.operations
        operations[2] = .init(id: original.id, blockID: original.blockID, sequence: original.sequence,
            opcode: .callother, outputVarnodeID: original.outputVarnodeID,
            inputVarnodeIDs: original.inputVarnodeIDs, directTargetAddress: nil,
            sourceRanges: original.sourceRanges, userOperationName: "pacia",
            authenticationEffect: .init(kind: .transformedOutput, outputSSAValueID: "ssa.right"))
        XCTAssertNoThrow(try NativeDecompilerWireSemanticValidator.validate(request: fixture.request,
            capabilities: fixture.capabilities, result: replacingResult(fixture.result, operations: operations)))
        for output in ["ssa.left", "vn.result", "missing", ""] {
            operations[2].authenticationEffect = .init(kind: .transformedOutput, outputSSAValueID: output)
            assertRejected(fixture, replacingResult(fixture.result, operations: operations))
        }
    }

    func testRejectsForgedMissingOrContradictoryPACOperationEvidence() {
        let fixture = makeFixture()
        var operations = fixture.result.operations
        operations[2].userOperationName = "pacia" // Not CALLOTHER.
        assertRejected(fixture, replacingResult(fixture.result, operations: operations))
        let original = fixture.result.operations[2]
        operations[2] = .init(id: original.id, blockID: original.blockID, sequence: original.sequence,
            opcode: .callother, outputVarnodeID: original.outputVarnodeID,
            inputVarnodeIDs: original.inputVarnodeIDs, directTargetAddress: nil,
            sourceRanges: original.sourceRanges)
        assertRejected(fixture, replacingResult(fixture.result, operations: operations))
        operations[2].userOperationName = "pacia" // PAC cannot claim no effect.
        assertRejected(fixture, replacingResult(fixture.result, operations: operations))
        operations[2].userOperationName = "unrecognized-userop"
        operations[2].authenticationEffect = .init(kind: .transformedOutput, outputSSAValueID: "ssa.right")
        assertRejected(fixture, replacingResult(fixture.result, operations: operations))
        for kind in [NativeDecompilerWireAuthenticationEffectKind.authenticatedMemoryAccessWithoutTransformedAddress,
                     .authenticatedControlTransferWithoutTransformedTarget] {
            operations[2].userOperationName = "AuthDA"
            operations[2].authenticationEffect = .init(kind: kind)
            assertRejected(fixture, replacingResult(fixture.result, operations: operations)) // Existing output forbidden.
        }
    }

    func testOutputlessAuthenticationPreservesOriginalInputWithoutInventingOutput() throws {
        let fixture = makeFixture()
        let original = fixture.result.operations[4]
        for (name, kind) in [
            ("AuthDA", NativeDecompilerWireAuthenticationEffectKind.authenticatedMemoryAccessWithoutTransformedAddress),
            ("AuthIA", .authenticatedControlTransferWithoutTransformedTarget),
        ] {
            var operations = fixture.result.operations
            operations[4] = .init(id: original.id, blockID: original.blockID, sequence: original.sequence,
                opcode: .callother, outputVarnodeID: nil, inputVarnodeIDs: original.inputVarnodeIDs,
                directTargetAddress: nil, sourceRanges: original.sourceRanges,
                userOperationName: name, authenticationEffect: .init(kind: kind))
            XCTAssertNoThrow(try NativeDecompilerWireSemanticValidator.validate(request: fixture.request,
                capabilities: fixture.capabilities,
                result: replacingResult(fixture.result, operations: operations)))
            operations[4].authenticationEffect = .init(kind: kind, outputSSAValueID: "ssa.phi")
            assertRejected(fixture, replacingResult(fixture.result, operations: operations))
        }
    }

    func testAcceptsFaithfulNativeValidatedProviderGraph() throws {
        let fixture = makeFixture()

        XCTAssertNoThrow(try NativeDecompilerWireSemanticValidator.validate(
            request: fixture.request,
            capabilities: fixture.capabilities,
            result: fixture.result
        ))
        XCTAssertNoThrow(try NativeDecompilerWireSemanticValidator.validate(
            request: fixture.request,
            capabilities: replacingCapabilities(fixture.capabilities, completeRegisterSSA: false),
            result: fixture.result
        ))
    }

    func testSchemaV4RequiresExactInstructionCoverageOfEachCodeRange() throws {
        let fixture = makeFixture()
        func check(_ ranges: [NativeDecompilerWireCodeRange]) throws {
            let function = NativeDecompilerWireFunctionIdentity(
                functionID: fixture.request.function.functionID,
                name: fixture.request.function.name,
                entryAddress: fixture.request.function.entryAddress,
                endAddressExclusive: fixture.request.function.endAddressExclusive,
                codeRanges: ranges
            )
            let request = NativeDecompilerWireRequest(
                requestID: fixture.request.requestID,
                requestSHA256: fixture.request.requestSHA256,
                target: fixture.request.target, image: fixture.request.image,
                function: function, memoryRegions: fixture.request.memoryRegions,
                symbols: fixture.request.symbols, authoredInputs: fixture.request.authoredInputs,
                budgets: fixture.request.budgets
            )
            let result = replacingResult(fixture.result, function: function)
            try NativeDecompilerWireSemanticValidator.validate(
                request: request, schemaVersion: 4,
                capabilities: fixture.capabilities, result: result
            )
        }
        XCTAssertNoThrow(try check([
            .init(startAddress: .init(0x1000), endAddressExclusive: .init(0x1004)),
            .init(startAddress: .init(0x1004), endAddressExclusive: .init(0x1010)),
        ]))
        XCTAssertThrowsError(try check([
            .init(startAddress: .init(0x1000), endAddressExclusive: .init(0x1004)),
            .init(startAddress: .init(0x1008), endAddressExclusive: .init(0x1010)),
        ]))
    }

    func testRejectsEveryForgedRequestBinding() {
        let fixture = makeFixture()
        let otherImage = NativeDecompilerWireImageIdentity(
            imageID: "image.other",
            uuid: fixture.request.image.uuid,
            preferredLoadAddress: fixture.request.image.preferredLoadAddress
        )
        let otherFunction = NativeDecompilerWireFunctionIdentity(
            functionID: "function.other",
            name: fixture.request.function.name,
            entryAddress: fixture.request.function.entryAddress,
            endAddressExclusive: fixture.request.function.endAddressExclusive
        )

        assertRejected(fixture, replacingResult(fixture.result, requestID: UUID()))
        assertRejected(fixture, replacingResult(fixture.result, requestSHA256: String(repeating: "b", count: 64)))
        assertRejected(fixture, replacingResult(fixture.result, image: otherImage))
        assertRejected(fixture, replacingResult(fixture.result, function: otherFunction))
    }

    func testRejectsUnknownReferencesAndMissingOrDuplicateBindings() {
        let fixture = makeFixture()
        var operations = fixture.result.operations
        operations[0] = replacingOperation(operations[0], inputVarnodeIDs: ["vn.missing"])
        assertRejected(fixture, replacingResult(fixture.result, operations: operations))

        assertRejected(
            fixture,
            replacingResult(fixture.result, ssaBindings: Array(fixture.result.ssaBindings.dropLast()))
        )
        assertRejected(
            fixture,
            replacingResult(
                fixture.result,
                ssaBindings: fixture.result.ssaBindings + [fixture.result.ssaBindings[0]]
            )
        )
    }

    func testRejectsEffectiveByteCoverageAndOperationOwnershipForgery() {
        let fixture = makeFixture()
        var instructions = fixture.result.instructions
        instructions[0] = replacingInstruction(instructions[0], address: .init(0x1001))
        assertRejected(fixture, replacingResult(fixture.result, instructions: instructions))

        instructions = fixture.result.instructions
        instructions[0] = replacingInstruction(instructions[0], bytes: Data([0xff, 0x02, 0x03, 0x04]))
        assertRejected(fixture, replacingResult(fixture.result, instructions: instructions))

        instructions = fixture.result.instructions
        instructions[0] = replacingInstruction(instructions[0], operationIDs: [])
        assertRejected(fixture, replacingResult(fixture.result, instructions: instructions))
    }

    func testRejectsBlockAndEdgeAdjacencyOrCanonicalOrderForgery() {
        let fixture = makeFixture()
        var blocks = fixture.result.blocks
        blocks[0] = replacingBlock(blocks[0], successorEdgeIDs: ["edge.0"])
        assertRejected(fixture, replacingResult(fixture.result, blocks: blocks))

        var edges = fixture.result.edges
        edges[0] = replacingEdge(edges[0], targetAddress: .init(0x1008))
        assertRejected(fixture, replacingResult(fixture.result, edges: edges))

        assertRejected(
            fixture,
            replacingResult(fixture.result, addressSpaces: fixture.result.addressSpaces.reversed())
        )
    }

    func testRejectsPhiPathCardinalityAndDefinitionForgery() {
        let fixture = makeFixture()
        let phi = fixture.result.phis[0]
        var phis = fixture.result.phis
        phis[0] = replacingPhi(phi, incoming: [phi.incoming[0]])
        assertRejected(fixture, replacingResult(fixture.result, phis: phis))

        phis[0] = replacingPhi(phi, incoming: [phi.incoming[0], phi.incoming[0]])
        assertRejected(fixture, replacingResult(fixture.result, phis: phis))

        var values = fixture.result.ssaValues
        let outputIndex = values.firstIndex(where: { $0.id == phi.outputSSAValueID })!
        values[outputIndex] = replacingSSAValue(values[outputIndex], definingPhiID: "phi.missing")
        assertRejected(fixture, replacingResult(fixture.result, ssaValues: values))

        phis = fixture.result.phis
        let left = phis[0].incoming[0]
        let right = phis[0].incoming[1]
        phis[0] = replacingPhi(phis[0], incoming: [
            NativeDecompilerWirePhiIncomingRecord(
                sourceBlockID: left.sourceBlockID,
                edgeID: left.edgeID,
                ssaValueID: right.ssaValueID
            ),
            NativeDecompilerWirePhiIncomingRecord(
                sourceBlockID: right.sourceBlockID,
                edgeID: right.edgeID,
                ssaValueID: left.ssaValueID
            ),
        ])
        assertRejected(fixture, replacingResult(fixture.result, phis: phis))
    }

    func testRejectsMemorySSAPathPartitionAndDefinitionForgery() {
        let fixture = makeFixture()
        var effects = fixture.result.memoryEffects
        effects[0] = replacingMemoryEffect(effects[0], inputMemoryVersionID: "memory.missing")
        assertRejected(fixture, replacingResult(fixture.result, memoryEffects: effects))

        let phi = fixture.result.memoryPhis[0]
        var phis = fixture.result.memoryPhis
        phis[0] = replacingMemoryPhi(
            phi,
            incoming: [phi.incoming[0], replacingMemoryIncoming(phi.incoming[1], edgeID: "edge.2")]
        )
        assertRejected(fixture, replacingResult(fixture.result, memoryPhis: phis))

        effects = fixture.result.memoryEffects
        effects[2] = replacingMemoryEffect(effects[2], outputMemoryVersionID: "memory.left")
        assertRejected(fixture, replacingResult(fixture.result, memoryEffects: effects))
    }

    func testRejectsVariableCallTokenDiagnosticAndRegionRelationshipForgery() {
        let fixture = makeFixture()
        var variables = fixture.result.variables
        variables[0] = replacingVariable(
            variables[0],
            storageVarnodeIDs: [variables[0].storageVarnodeIDs[0], variables[0].storageVarnodeIDs[0]]
        )
        assertRejected(fixture, replacingResult(fixture.result, variables: variables))

        var calls = fixture.result.calls
        calls[0] = replacingCall(calls[0], operationID: "op.2")
        assertRejected(fixture, replacingResult(fixture.result, calls: calls))

        var tokens = fixture.result.tokens
        tokens[0] = replacingToken(
            tokens[0],
            entityReferences: tokens[0].entityReferences + [tokens[0].entityReferences[0]]
        )
        assertRejected(fixture, replacingResult(fixture.result, tokens: tokens))

        assertRejected(
            fixture,
            replacingResult(fixture.result, warnings: fixture.result.warnings + fixture.result.warnings)
        )

        let root = fixture.result.regions.first(where: { $0.id == "region.root" })!
        let child = fixture.result.regions.first(where: { $0.id == "region.child" })!
        let cyclicRoot = replacingRegion(root, parentRegionID: "region.child")
        let cyclicChild = replacingRegion(child, childRegionIDs: ["region.root"])
        assertRejected(fixture, replacingResult(fixture.result, regions: [cyclicChild, cyclicRoot]))
    }

    func testPresentationDocumentIsValidatedIndependentlyFromTokenCapability() throws {
        let fixture = makeFixture()
        let withoutTokens = replacingResult(fixture.result, tokens: [])
        XCTAssertNoThrow(try NativeDecompilerWireSemanticValidator.validate(
            request: fixture.request,
            capabilities: replacingCapabilities(fixture.capabilities, tokenizedPseudocode: false),
            result: withoutTokens
        ))

        let invalidDocuments: [(name: String, document: NativeDecompilerWirePseudocodeDocument)] = [
            ("empty text", NativeDecompilerWirePseudocodeDocument(
                text: "", language: "c", isComplete: true, isTruncated: false
            )),
            ("unsupported language", NativeDecompilerWirePseudocodeDocument(
                text: "int f(void) {}", language: "cpp", isComplete: true, isTruncated: false
            )),
            ("contradictory completion flags", NativeDecompilerWirePseudocodeDocument(
                text: "int f(void) {}", language: "c", isComplete: true, isTruncated: true
            )),
            ("carriage return", NativeDecompilerWirePseudocodeDocument(
                text: "int f(void) {\r\n}\n", language: "c", isComplete: true, isTruncated: false
            )),
            ("escape control", NativeDecompilerWirePseudocodeDocument(
                text: "int f(void) {\u{1b}}\n", language: "c", isComplete: true, isTruncated: false
            )),
            ("oversized text", NativeDecompilerWirePseudocodeDocument(
                text: String(repeating: "x", count: (1 << 20) + 1),
                language: "c", isComplete: false, isTruncated: true
            )),
        ]
        for invalid in invalidDocuments {
            XCTAssertThrowsError(
                try NativeDecompilerWireSemanticValidator.validate(
                    request: fixture.request,
                    capabilities: fixture.capabilities,
                    result: replacingResult(
                        fixture.result,
                        pseudocodeDocument: invalid.document
                    )
                ),
                "accepted invalid pseudocode document: \(invalid.name)"
            )
        }
    }

    func testRejectsNegativeCapabilityContradictions() {
        let fixture = makeFixture()

        assertRejected(fixture, fixture.result, capabilities: replacingCapabilities(
            fixture.capabilities, memorySSA: false
        ))
        assertRejected(fixture, fixture.result, capabilities: replacingCapabilities(
            fixture.capabilities, recoveredVariables: false
        ))
        assertRejected(fixture, fixture.result, capabilities: replacingCapabilities(
            fixture.capabilities, recoveredTypes: false
        ))
        assertRejected(fixture, fixture.result, capabilities: replacingCapabilities(
            fixture.capabilities, structuredControlFlow: false
        ))
        assertRejected(fixture, fixture.result, capabilities: replacingCapabilities(
            fixture.capabilities, tokenizedPseudocode: false
        ))
        assertRejected(fixture, fixture.result, capabilities: replacingCapabilities(
            fixture.capabilities, nativeDecompilerHeritage: false
        ))
        assertRejected(fixture, fixture.result, capabilities: replacingCapabilities(
            fixture.capabilities, imageQualifiedSourceRanges: false
        ))
    }

    func testRejectsPositiveCapabilityContradictions() {
        let fixture = makeFixture()

        // Complete register SSA does not require a register-named varnode (native contract,
        // Backend.cpp): a void function whose only register write is dead publishes constant
        // varnodes alone. It still requires SSA values and one binding per operation.
        let unnamedVarnodes = fixture.result.varnodes.map { replacingVarnode($0, registerName: .some(nil)) }
        XCTAssertNoThrow(try NativeDecompilerWireSemanticValidator.validate(request: fixture.request,
            capabilities: fixture.capabilities, result: replacingResult(fixture.result, varnodes: unnamedVarnodes)))
        assertRejected(fixture, replacingResult(fixture.result, varnodes: unnamedVarnodes, ssaValues: []))

        assertRejected(fixture, replacingResult(
            fixture.result, memoryVersions: [], memoryPhis: [], memoryEffects: []
        ))

        var calls = fixture.result.calls
        let untypedVarnodes = fixture.result.varnodes.map { replacingVarnode($0, typeID: .some(nil)) }
        let untypedVariables = fixture.result.variables.map { replacingVariable($0, typeID: .some(nil)) }
        calls[0] = replacingCall(calls[0], prototypeTypeID: .some(nil))
        assertRejected(fixture, replacingResult(
            fixture.result,
            types: [],
            varnodes: untypedVarnodes,
            variables: untypedVariables,
            calls: calls
        ))

        var regionlessTokens = fixture.result.tokens
        regionlessTokens[0] = replacingToken(
            regionlessTokens[0],
            entityReferences: regionlessTokens[0].entityReferences.filter { $0.kind != .region }
        )
        assertRejected(fixture, replacingResult(
            fixture.result, regions: [], tokens: regionlessTokens
        ))

        assertRejected(fixture, replacingResult(fixture.result, tokens: []))
    }

    func testRejectsNativePublicationBudgetContradictions() {
        let fixture = makeFixture()

        assertRejected(fixture, fixture.result, request: replacingRequest(
            fixture.request,
            budgets: replacingBudgets(fixture.request.budgets, maxInstructions: 3)
        ))
        assertRejected(fixture, fixture.result, request: replacingRequest(
            fixture.request,
            budgets: replacingBudgets(fixture.request.budgets, maxOperations: 3)
        ))
        assertRejected(fixture, fixture.result, request: replacingRequest(
            fixture.request,
            budgets: replacingBudgets(fixture.request.budgets, maxOutputBytes: 1)
        ))
    }

    func testRejectsNativeRecordBoundsControlTextAndDuplicateSourceRanges() {
        let fixture = makeFixture()
        var spaces = fixture.result.addressSpaces
        spaces[0] = replacingAddressSpace(spaces[0], addressSizeBytes: 0)
        assertRejected(fixture, replacingResult(fixture.result, addressSpaces: spaces))

        var instructions = fixture.result.instructions
        instructions[0] = replacingInstruction(instructions[0], body: "bad\u{1b}body")
        assertRejected(fixture, replacingResult(fixture.result, instructions: instructions))

        instructions = fixture.result.instructions
        instructions[0] = replacingInstruction(
            instructions[0],
            sourceRanges: instructions[0].sourceRanges + instructions[0].sourceRanges
        )
        assertRejected(fixture, replacingResult(fixture.result, instructions: instructions))

        var varnodes = fixture.result.varnodes
        varnodes[0] = replacingVarnode(varnodes[0], sizeBytes: 0)
        assertRejected(fixture, replacingResult(fixture.result, varnodes: varnodes))
    }

    /// §4.73: ordinary code carries 64-bit constants in [-8, -1] and stack slots at
    /// negative offsets. Constant and spacebase offsets wrap, so only storage in the
    /// other spaces is checked for an end past 2^64.
    func testWrappingOffsetSpacesAcceptNegativeOffsetsAndStorageSpacesStillRejectOverflow() throws {
        let fixture = makeFixture()
        let conditionIndex = try XCTUnwrap(fixture.result.varnodes.firstIndex { $0.id == "vn.condition" })
        for kind in [NativeDecompilerWireAddressSpaceKind.constant, .spacebase] {
            let spaces = [NativeDecompilerWireAddressSpaceRecord(
                id: "space.a-wrapping", name: "wrapping", kind: kind,
                addressSizeBytes: 8, isProcessorSpace: false
            )] + fixture.result.addressSpaces
            var varnodes = fixture.result.varnodes
            varnodes[conditionIndex] = replacingVarnode(
                varnodes[conditionIndex], addressSpaceID: "space.a-wrapping", offset: UInt64.max - 7
            )
            XCTAssertNoThrow(try NativeDecompilerWireSemanticValidator.validate(
                request: fixture.request,
                capabilities: fixture.capabilities,
                result: replacingResult(fixture.result, addressSpaces: spaces, varnodes: varnodes)
            ), "\(kind)")
        }
        var varnodes = fixture.result.varnodes
        varnodes[conditionIndex] = replacingVarnode(varnodes[conditionIndex], offset: UInt64.max - 7)
        assertRejected(fixture, replacingResult(fixture.result, varnodes: varnodes))
    }
}

extension NativeDecompilerWireSemanticValidatorTests {
    func makeFixture() -> NativeDecompilerWireSemanticValidatorTestFixture {
        Self.makeFixtureForSharing()
    }

    static func makeFixtureForSharing() -> NativeDecompilerWireSemanticValidatorTestFixture {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let image = NativeDecompilerWireImageIdentity(
            imageID: "image.main",
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            preferredLoadAddress: .init(0x1000)
        )
        let function = NativeDecompilerWireFunctionIdentity(
            functionID: "function.fixture",
            name: "_fixture",
            entryAddress: .init(0x1000),
            endAddressExclusive: .init(0x1010)
        )
        let effective = Data(1...16)
        let request = NativeDecompilerWireRequest(
            requestID: requestID,
            requestSHA256: "63c212780d28fd79ed994dcdf8f9e080685217e1726beafaa3465926a5f03e14",
            target: try! NativeDecompilerSealedTargetProfile.normalizedTarget(
                rawCPUType: 0x0100_000c,
                rawCPUSubtype: 0,
                selectedSliceSHA256: String(repeating: "a", count: 64),
                selectedSliceByteCount: UInt64(effective.count)
            ),
            image: image,
            function: function,
            memoryRegions: [NativeDecompilerWireMemoryRegion(
                name: "__text",
                startAddress: .init(0x1000),
                permissions: .readExecute,
                rawBytes: Data(repeating: 0, count: 16),
                effectiveBytes: effective,
                appliedPatchIDs: ["patch000000"]
            )],
            symbols: [NativeDecompilerWireSymbolRecord(
                imageID: image.imageID,
                address: .init(0x1000),
                name: "_fixture",
                kind: .function
            )],
            authoredInputs: .empty,
            budgets: NativeDecompilerProductBudgetProfile.v1.wireValue
        )

        let range: (UInt64, UInt64) -> NativeDecompilerWireSourceRange = { start, end in
            NativeDecompilerWireSourceRange(
                imageID: image.imageID,
                startAddress: .init(start),
                endAddressExclusive: .init(end)
            )
        }
        let instructions = [
            NativeDecompilerWireInstructionRecord(
                id: "instruction.0", address: .init(0x1000), bytes: effective.subdata(in: 0..<4),
                mnemonic: "cbz", body: "cbz w0, right", operationIDs: ["op.0"],
                sourceRanges: [range(0x1000, 0x1004)]
            ),
            NativeDecompilerWireInstructionRecord(
                id: "instruction.1", address: .init(0x1004), bytes: effective.subdata(in: 4..<8),
                mnemonic: "bl", body: "bl callee", operationIDs: ["op.1"],
                sourceRanges: [range(0x1004, 0x1008)]
            ),
            NativeDecompilerWireInstructionRecord(
                id: "instruction.2", address: .init(0x1008), bytes: effective.subdata(in: 8..<12),
                mnemonic: "mov", body: "mov x0, #2", operationIDs: ["op.2"],
                sourceRanges: [range(0x1008, 0x100c)]
            ),
            NativeDecompilerWireInstructionRecord(
                id: "instruction.3", address: .init(0x100c), bytes: effective.subdata(in: 12..<16),
                mnemonic: "ret", body: "ret", operationIDs: ["op.3", "op.4"],
                sourceRanges: [range(0x100c, 0x1010)]
            ),
        ]
        let operations = [
            NativeDecompilerWireOperationRecord(
                id: "op.0", blockID: "block.0", sequence: .init(0), opcode: .cbranch,
                outputVarnodeID: nil, inputVarnodeIDs: ["vn.condition"], directTargetAddress: .init(0x1008),
                sourceRanges: [range(0x1000, 0x1004)]
            ),
            NativeDecompilerWireOperationRecord(
                id: "op.1", blockID: "block.1", sequence: .init(0), opcode: .call,
                outputVarnodeID: "vn.result", inputVarnodeIDs: ["vn.condition"],
                directTargetAddress: .init(0x2000), sourceRanges: [range(0x1004, 0x1008)]
            ),
            NativeDecompilerWireOperationRecord(
                id: "op.2", blockID: "block.2", sequence: .init(0), opcode: .copy,
                outputVarnodeID: "vn.result", inputVarnodeIDs: ["vn.condition"],
                directTargetAddress: nil, sourceRanges: [range(0x1008, 0x100c)]
            ),
            NativeDecompilerWireOperationRecord(
                id: "op.3", blockID: "block.3", sequence: .init(0), opcode: .multiequal,
                outputVarnodeID: "vn.result", inputVarnodeIDs: ["vn.result", "vn.result"],
                directTargetAddress: nil,
                sourceRanges: [range(0x100c, 0x1010)]
            ),
            NativeDecompilerWireOperationRecord(
                id: "op.4", blockID: "block.3", sequence: .init(1), opcode: .return,
                outputVarnodeID: nil, inputVarnodeIDs: ["vn.result"], directTargetAddress: nil,
                sourceRanges: [range(0x100c, 0x1010)]
            ),
        ]
        let blocks = [
            NativeDecompilerWireBlockRecord(
                id: "block.0", startAddress: .init(0x1000), endAddressExclusive: .init(0x1004),
                operationIDs: ["op.0"], predecessorEdgeIDs: [], successorEdgeIDs: ["edge.0", "edge.1"],
                terminatorKind: .conditional
            ),
            NativeDecompilerWireBlockRecord(
                id: "block.1", startAddress: .init(0x1004), endAddressExclusive: .init(0x1008),
                operationIDs: ["op.1"], predecessorEdgeIDs: ["edge.0"], successorEdgeIDs: ["edge.2"],
                terminatorKind: .branch
            ),
            NativeDecompilerWireBlockRecord(
                id: "block.2", startAddress: .init(0x1008), endAddressExclusive: .init(0x100c),
                operationIDs: ["op.2"], predecessorEdgeIDs: ["edge.1"], successorEdgeIDs: ["edge.3"],
                terminatorKind: .branch
            ),
            NativeDecompilerWireBlockRecord(
                id: "block.3", startAddress: .init(0x100c), endAddressExclusive: .init(0x1010),
                operationIDs: ["op.3", "op.4"], predecessorEdgeIDs: ["edge.2", "edge.3"],
                successorEdgeIDs: [],
                terminatorKind: .return
            ),
        ]
        let edges = [
            NativeDecompilerWireEdgeRecord(
                id: "edge.0", sourceBlockID: "block.0", targetBlockID: "block.1",
                targetAddress: .init(0x1004), kind: .trueBranch, operationID: "op.0"
            ),
            NativeDecompilerWireEdgeRecord(
                id: "edge.1", sourceBlockID: "block.0", targetBlockID: "block.2",
                targetAddress: .init(0x1008), kind: .falseBranch, operationID: "op.0"
            ),
            NativeDecompilerWireEdgeRecord(
                id: "edge.2", sourceBlockID: "block.1", targetBlockID: "block.3",
                targetAddress: .init(0x100c), kind: .branch, operationID: "op.1"
            ),
            NativeDecompilerWireEdgeRecord(
                id: "edge.3", sourceBlockID: "block.2", targetBlockID: "block.3",
                targetAddress: .init(0x100c), kind: .branch, operationID: "op.2"
            ),
        ]
        let result = NativeDecompilerWireStructuredResult(
            requestID: requestID,
            requestSHA256: request.requestSHA256,
            image: image,
            function: function,
            addressSpaces: [
                NativeDecompilerWireAddressSpaceRecord(
                    id: "space.ram", name: "ram", kind: .processor,
                    addressSizeBytes: 8, isProcessorSpace: true
                ),
                NativeDecompilerWireAddressSpaceRecord(
                    id: "space.unique", name: "unique", kind: .unique,
                    addressSizeBytes: 8, isProcessorSpace: true
                ),
            ],
            types: [
                NativeDecompilerWireTypeRecord(
                    id: "type.function", kind: .function, name: "fixture_t", byteSize: nil,
                    isSigned: nil, pointeeTypeID: nil, fields: [], confidence: .high,
                    provenance: "contract-fixture", returnTypeID: "type.u64",
                    parameterTypeIDs: ["type.u64"]
                ),
                NativeDecompilerWireTypeRecord(
                    id: "type.u64", kind: .integer, name: "uint64_t", byteSize: .init(8),
                    isSigned: false, pointeeTypeID: nil, fields: [], confidence: .high,
                    provenance: "contract-fixture", returnTypeID: nil, parameterTypeIDs: []
                ),
            ],
            instructions: instructions,
            varnodes: [
                NativeDecompilerWireVarnodeRecord(
                    id: "vn.condition", addressSpaceID: "space.unique", offset: .init(0), sizeBytes: 8,
                    role: .constant, typeID: "type.u64", registerName: nil
                ),
                NativeDecompilerWireVarnodeRecord(
                    id: "vn.result", addressSpaceID: "space.unique", offset: .init(8), sizeBytes: 8,
                    role: .register, typeID: "type.u64", registerName: "x0"
                ),
            ],
            operations: operations,
            blocks: blocks,
            edges: edges,
            ssaValues: [
                NativeDecompilerWireSSAValueRecord(
                    id: "ssa.condition", varnodeID: "vn.condition", kind: .constant,
                    definingOperationID: nil, definingPhiID: nil
                ),
                NativeDecompilerWireSSAValueRecord(
                    id: "ssa.left", varnodeID: "vn.result", kind: .operationResult,
                    definingOperationID: "op.1", definingPhiID: nil
                ),
                NativeDecompilerWireSSAValueRecord(
                    id: "ssa.phi", varnodeID: "vn.result", kind: .phiResult,
                    definingOperationID: nil, definingPhiID: "phi.0"
                ),
                NativeDecompilerWireSSAValueRecord(
                    id: "ssa.right", varnodeID: "vn.result", kind: .operationResult,
                    definingOperationID: "op.2", definingPhiID: nil
                ),
            ],
            ssaBindings: [
                NativeDecompilerWireSSABindingRecord(
                    operationID: "op.0", inputSSAValueIDs: ["ssa.condition"], outputSSAValueID: nil
                ),
                NativeDecompilerWireSSABindingRecord(
                    operationID: "op.1", inputSSAValueIDs: ["ssa.condition"], outputSSAValueID: "ssa.left"
                ),
                NativeDecompilerWireSSABindingRecord(
                    operationID: "op.2", inputSSAValueIDs: ["ssa.condition"], outputSSAValueID: "ssa.right"
                ),
                NativeDecompilerWireSSABindingRecord(
                    operationID: "op.3", inputSSAValueIDs: ["ssa.left", "ssa.right"],
                    outputSSAValueID: "ssa.phi"
                ),
                NativeDecompilerWireSSABindingRecord(
                    operationID: "op.4", inputSSAValueIDs: ["ssa.phi"], outputSSAValueID: nil
                ),
            ],
            phis: [NativeDecompilerWirePhiRecord(
                id: "phi.0", blockID: "block.3", varnodeID: "vn.result", outputSSAValueID: "ssa.phi",
                incoming: [
                    NativeDecompilerWirePhiIncomingRecord(
                        sourceBlockID: "block.1", edgeID: "edge.2", ssaValueID: "ssa.left"
                    ),
                    NativeDecompilerWirePhiIncomingRecord(
                        sourceBlockID: "block.2", edgeID: "edge.3", ssaValueID: "ssa.right"
                    ),
                ]
            )],
            memoryVersions: [
                NativeDecompilerWireMemoryVersionRecord(
                    id: "memory.entry", partition: "unknown", kind: .functionEntry,
                    definingOperationID: nil, definingMemoryPhiID: nil
                ),
                NativeDecompilerWireMemoryVersionRecord(
                    id: "memory.left", partition: "unknown", kind: .operationResult,
                    definingOperationID: "op.1", definingMemoryPhiID: nil
                ),
                NativeDecompilerWireMemoryVersionRecord(
                    id: "memory.merge", partition: "unknown", kind: .phiResult,
                    definingOperationID: nil, definingMemoryPhiID: "memory-phi.0"
                ),
                NativeDecompilerWireMemoryVersionRecord(
                    id: "memory.right", partition: "unknown", kind: .operationResult,
                    definingOperationID: "op.2", definingMemoryPhiID: nil
                ),
            ],
            memoryPhis: [NativeDecompilerWireMemoryPhiRecord(
                id: "memory-phi.0", blockID: "block.3", partition: "unknown",
                outputMemoryVersionID: "memory.merge",
                incoming: [
                    NativeDecompilerWireMemoryPhiIncomingRecord(
                        sourceBlockID: "block.1", edgeID: "edge.2", memoryVersionID: "memory.left"
                    ),
                    NativeDecompilerWireMemoryPhiIncomingRecord(
                        sourceBlockID: "block.2", edgeID: "edge.3", memoryVersionID: "memory.right"
                    ),
                ]
            )],
            memoryEffects: [
                NativeDecompilerWireMemoryEffectRecord(
                    id: "effect.left", operationID: "op.1", kind: .write, partition: "unknown",
                    inputMemoryVersionID: "memory.entry", outputMemoryVersionID: "memory.left"
                ),
                NativeDecompilerWireMemoryEffectRecord(
                    id: "effect.merge-read", operationID: "op.4", kind: .read, partition: "unknown",
                    inputMemoryVersionID: "memory.merge", outputMemoryVersionID: nil
                ),
                NativeDecompilerWireMemoryEffectRecord(
                    id: "effect.right", operationID: "op.2", kind: .write, partition: "unknown",
                    inputMemoryVersionID: "memory.entry", outputMemoryVersionID: "memory.right"
                ),
            ],
            variables: [
                NativeDecompilerWireVariableRecord(
                    id: "variable.argument", name: "argument", role: .parameter, typeID: "type.u64",
                    storageVarnodeIDs: ["vn.condition"], liveRanges: [range(0x1000, 0x100c)],
                    confidence: .high, provenance: "contract-fixture"
                ),
                NativeDecompilerWireVariableRecord(
                    id: "variable.result", name: "result", role: .result, typeID: "type.u64",
                    storageVarnodeIDs: ["vn.result"], liveRanges: [range(0x1004, 0x1010)],
                    confidence: .high, provenance: "contract-fixture"
                ),
            ],
            calls: [NativeDecompilerWireCallRecord(
                id: "call.0", operationID: "op.1", kind: .direct, targetAddress: .init(0x2000),
                targetSymbol: "_callee", prototypeTypeID: "type.function",
                argumentVariableIDs: ["variable.argument"], resultVariableID: "variable.result",
                sourceRanges: [range(0x1004, 0x1008)]
            )],
            regions: [
                NativeDecompilerWireRegionRecord(
                    id: "region.child", kind: .sequence, parentRegionID: "region.root",
                    childRegionIDs: [], blockIDs: ["block.3"], conditionOperationID: nil,
                    sourceRanges: [range(0x100c, 0x1010)]
                ),
                NativeDecompilerWireRegionRecord(
                    id: "region.root", kind: .root, parentRegionID: nil,
                    childRegionIDs: ["region.child"],
                    blockIDs: ["block.0", "block.1", "block.2", "block.3"],
                    conditionOperationID: "op.0", sourceRanges: [range(0x1000, 0x1010)]
                ),
            ],
            tokens: [
                NativeDecompilerWirePseudocodeTokenRecord(
                    id: "token.0", text: "if", kind: .keyword, line: 1, column: 1,
                    sourceRanges: [range(0x1000, 0x1004)],
                    entityReferences: [
                        NativeDecompilerWireTokenEntityReference(kind: .instruction, id: "instruction.0"),
                        NativeDecompilerWireTokenEntityReference(kind: .region, id: "region.root"),
                    ]
                ),
                NativeDecompilerWirePseudocodeTokenRecord(
                    id: "token.1", text: "callee", kind: .identifier, line: 2, column: 1,
                    sourceRanges: [range(0x1004, 0x1008)],
                    entityReferences: [
                        NativeDecompilerWireTokenEntityReference(kind: .call, id: "call.0"),
                        NativeDecompilerWireTokenEntityReference(kind: .operation, id: "op.1"),
                    ]
                ),
                NativeDecompilerWirePseudocodeTokenRecord(
                    id: "token.2", text: "result", kind: .identifier, line: 3, column: 1,
                    sourceRanges: [range(0x100c, 0x1010)],
                    entityReferences: [
                        NativeDecompilerWireTokenEntityReference(kind: .block, id: "block.3"),
                        NativeDecompilerWireTokenEntityReference(kind: .type, id: "type.u64"),
                        NativeDecompilerWireTokenEntityReference(kind: .variable, id: "variable.result"),
                        NativeDecompilerWireTokenEntityReference(kind: .varnode, id: "vn.result"),
                    ]
                ),
            ],
            pseudocodeDocument: NativeDecompilerWirePseudocodeDocument(
                text: "uint64_t fixture(uint64_t argument) {\n\treturn argument;\n}\n",
                language: "c",
                isComplete: true,
                isTruncated: false
            ),
            warnings: [NativeDecompilerWireDiagnosticRecord(
                code: "fixture-warning", severity: .warning, message: "fixture warning",
                sourceRanges: [range(0x1000, 0x1004)]
            )]
        )
        let capabilities = NativeDecompilerWireBackendCapabilities(
            nativeDecompilerHeritage: true,
            completeRegisterSSA: true,
            memorySSA: true,
            recoveredVariables: true,
            recoveredTypes: true,
            structuredControlFlow: true,
            tokenizedPseudocode: true,
            imageQualifiedSourceRanges: true
        )
        return NativeDecompilerWireSemanticValidatorTestFixture(
            request: request,
            capabilities: capabilities,
            result: result
        )
    }

    func assertRejected(
        _ fixture: NativeDecompilerWireSemanticValidatorTestFixture,
        _ result: NativeDecompilerWireStructuredResult,
        capabilities: NativeDecompilerWireBackendCapabilities? = nil,
        request: NativeDecompilerWireRequest? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try NativeDecompilerWireSemanticValidator.validate(
                request: request ?? fixture.request,
                capabilities: capabilities ?? fixture.capabilities,
                result: result
            ),
            file: file,
            line: line
        )
    }
}

private func replacingResult(
    _ value: NativeDecompilerWireStructuredResult,
    requestID: UUID? = nil,
    requestSHA256: String? = nil,
    image: NativeDecompilerWireImageIdentity? = nil,
    function: NativeDecompilerWireFunctionIdentity? = nil,
    addressSpaces: [NativeDecompilerWireAddressSpaceRecord]? = nil,
    types: [NativeDecompilerWireTypeRecord]? = nil,
    instructions: [NativeDecompilerWireInstructionRecord]? = nil,
    varnodes: [NativeDecompilerWireVarnodeRecord]? = nil,
    operations: [NativeDecompilerWireOperationRecord]? = nil,
    blocks: [NativeDecompilerWireBlockRecord]? = nil,
    edges: [NativeDecompilerWireEdgeRecord]? = nil,
    ssaValues: [NativeDecompilerWireSSAValueRecord]? = nil,
    ssaBindings: [NativeDecompilerWireSSABindingRecord]? = nil,
    phis: [NativeDecompilerWirePhiRecord]? = nil,
    memoryVersions: [NativeDecompilerWireMemoryVersionRecord]? = nil,
    memoryPhis: [NativeDecompilerWireMemoryPhiRecord]? = nil,
    memoryEffects: [NativeDecompilerWireMemoryEffectRecord]? = nil,
    variables: [NativeDecompilerWireVariableRecord]? = nil,
    calls: [NativeDecompilerWireCallRecord]? = nil,
    regions: [NativeDecompilerWireRegionRecord]? = nil,
    tokens: [NativeDecompilerWirePseudocodeTokenRecord]? = nil,
    pseudocodeDocument: NativeDecompilerWirePseudocodeDocument? = nil,
    warnings: [NativeDecompilerWireDiagnosticRecord]? = nil
) -> NativeDecompilerWireStructuredResult {
    NativeDecompilerWireStructuredResult(
        requestID: requestID ?? value.requestID,
        requestSHA256: requestSHA256 ?? value.requestSHA256,
        image: image ?? value.image,
        function: function ?? value.function,
        addressSpaces: addressSpaces ?? value.addressSpaces,
        types: types ?? value.types,
        instructions: instructions ?? value.instructions,
        varnodes: varnodes ?? value.varnodes,
        operations: operations ?? value.operations,
        blocks: blocks ?? value.blocks,
        edges: edges ?? value.edges,
        ssaValues: ssaValues ?? value.ssaValues,
        ssaBindings: ssaBindings ?? value.ssaBindings,
        phis: phis ?? value.phis,
        memoryVersions: memoryVersions ?? value.memoryVersions,
        memoryPhis: memoryPhis ?? value.memoryPhis,
        memoryEffects: memoryEffects ?? value.memoryEffects,
        variables: variables ?? value.variables,
        calls: calls ?? value.calls,
        regions: regions ?? value.regions,
        tokens: tokens ?? value.tokens,
        pseudocodeDocument: pseudocodeDocument ?? value.pseudocodeDocument,
        warnings: warnings ?? value.warnings
    )
}

private func replacingInstruction(
    _ value: NativeDecompilerWireInstructionRecord,
    address: NativeDecompilerWireUInt64? = nil,
    bytes: Data? = nil,
    body: String? = nil,
    operationIDs: [String]? = nil,
    sourceRanges: [NativeDecompilerWireSourceRange]? = nil
) -> NativeDecompilerWireInstructionRecord {
    NativeDecompilerWireInstructionRecord(
        id: value.id, address: address ?? value.address, bytes: bytes ?? value.bytes,
        mnemonic: value.mnemonic, body: body ?? value.body,
        operationIDs: operationIDs ?? value.operationIDs,
        sourceRanges: sourceRanges ?? value.sourceRanges
    )
}

private func replacingAddressSpace(
    _ value: NativeDecompilerWireAddressSpaceRecord,
    addressSizeBytes: UInt32
) -> NativeDecompilerWireAddressSpaceRecord {
    NativeDecompilerWireAddressSpaceRecord(
        id: value.id,
        name: value.name,
        kind: value.kind,
        addressSizeBytes: addressSizeBytes,
        isProcessorSpace: value.isProcessorSpace
    )
}

private func replacingOperation(
    _ value: NativeDecompilerWireOperationRecord,
    inputVarnodeIDs: [String]? = nil
) -> NativeDecompilerWireOperationRecord {
    NativeDecompilerWireOperationRecord(
        id: value.id, blockID: value.blockID, sequence: value.sequence, opcode: value.opcode,
        outputVarnodeID: value.outputVarnodeID,
        inputVarnodeIDs: inputVarnodeIDs ?? value.inputVarnodeIDs,
        directTargetAddress: value.directTargetAddress, sourceRanges: value.sourceRanges
    )
}

private func replacingBlock(
    _ value: NativeDecompilerWireBlockRecord,
    successorEdgeIDs: [String]? = nil
) -> NativeDecompilerWireBlockRecord {
    NativeDecompilerWireBlockRecord(
        id: value.id, startAddress: value.startAddress, endAddressExclusive: value.endAddressExclusive,
        operationIDs: value.operationIDs, predecessorEdgeIDs: value.predecessorEdgeIDs,
        successorEdgeIDs: successorEdgeIDs ?? value.successorEdgeIDs,
        terminatorKind: value.terminatorKind
    )
}

private func replacingEdge(
    _ value: NativeDecompilerWireEdgeRecord,
    targetAddress: NativeDecompilerWireUInt64? = nil
) -> NativeDecompilerWireEdgeRecord {
    NativeDecompilerWireEdgeRecord(
        id: value.id, sourceBlockID: value.sourceBlockID, targetBlockID: value.targetBlockID,
        targetAddress: targetAddress ?? value.targetAddress, kind: value.kind, operationID: value.operationID
    )
}

private func replacingSSAValue(
    _ value: NativeDecompilerWireSSAValueRecord,
    definingPhiID: String?
) -> NativeDecompilerWireSSAValueRecord {
    NativeDecompilerWireSSAValueRecord(
        id: value.id, varnodeID: value.varnodeID, kind: value.kind,
        definingOperationID: value.definingOperationID, definingPhiID: definingPhiID
    )
}

private func replacingPhi(
    _ value: NativeDecompilerWirePhiRecord,
    incoming: [NativeDecompilerWirePhiIncomingRecord]
) -> NativeDecompilerWirePhiRecord {
    NativeDecompilerWirePhiRecord(
        id: value.id, blockID: value.blockID, varnodeID: value.varnodeID,
        outputSSAValueID: value.outputSSAValueID, incoming: incoming
    )
}

private func replacingMemoryIncoming(
    _ value: NativeDecompilerWireMemoryPhiIncomingRecord,
    edgeID: String?
) -> NativeDecompilerWireMemoryPhiIncomingRecord {
    NativeDecompilerWireMemoryPhiIncomingRecord(
        sourceBlockID: value.sourceBlockID, edgeID: edgeID, memoryVersionID: value.memoryVersionID
    )
}

private func replacingMemoryPhi(
    _ value: NativeDecompilerWireMemoryPhiRecord,
    incoming: [NativeDecompilerWireMemoryPhiIncomingRecord]
) -> NativeDecompilerWireMemoryPhiRecord {
    NativeDecompilerWireMemoryPhiRecord(
        id: value.id, blockID: value.blockID, partition: value.partition,
        outputMemoryVersionID: value.outputMemoryVersionID, incoming: incoming
    )
}

private func replacingMemoryEffect(
    _ value: NativeDecompilerWireMemoryEffectRecord,
    inputMemoryVersionID: String? = nil,
    outputMemoryVersionID: String? = nil
) -> NativeDecompilerWireMemoryEffectRecord {
    NativeDecompilerWireMemoryEffectRecord(
        id: value.id, operationID: value.operationID, kind: value.kind, partition: value.partition,
        inputMemoryVersionID: inputMemoryVersionID ?? value.inputMemoryVersionID,
        outputMemoryVersionID: outputMemoryVersionID ?? value.outputMemoryVersionID
    )
}

private func replacingVariable(
    _ value: NativeDecompilerWireVariableRecord,
    typeID: String?? = nil,
    storageVarnodeIDs: [String]? = nil
) -> NativeDecompilerWireVariableRecord {
    NativeDecompilerWireVariableRecord(
        id: value.id, name: value.name, role: value.role, typeID: typeID ?? value.typeID,
        storageVarnodeIDs: storageVarnodeIDs ?? value.storageVarnodeIDs,
        liveRanges: value.liveRanges, confidence: value.confidence, provenance: value.provenance
    )
}

private func replacingCall(
    _ value: NativeDecompilerWireCallRecord,
    operationID: String? = nil,
    prototypeTypeID: String?? = nil,
    argumentVariableIDs: [String]? = nil,
    resultVariableID: String?? = nil
) -> NativeDecompilerWireCallRecord {
    NativeDecompilerWireCallRecord(
        id: value.id, operationID: operationID ?? value.operationID, kind: value.kind,
        targetAddress: value.targetAddress, targetSymbol: value.targetSymbol,
        prototypeTypeID: prototypeTypeID ?? value.prototypeTypeID,
        argumentVariableIDs: argumentVariableIDs ?? value.argumentVariableIDs,
        resultVariableID: resultVariableID ?? value.resultVariableID,
        sourceRanges: value.sourceRanges
    )
}

private func replacingRegion(
    _ value: NativeDecompilerWireRegionRecord,
    parentRegionID: String?? = nil,
    childRegionIDs: [String]? = nil
) -> NativeDecompilerWireRegionRecord {
    NativeDecompilerWireRegionRecord(
        id: value.id, kind: value.kind, parentRegionID: parentRegionID ?? value.parentRegionID,
        childRegionIDs: childRegionIDs ?? value.childRegionIDs, blockIDs: value.blockIDs,
        conditionOperationID: value.conditionOperationID, sourceRanges: value.sourceRanges
    )
}

private func replacingToken(
    _ value: NativeDecompilerWirePseudocodeTokenRecord,
    entityReferences: [NativeDecompilerWireTokenEntityReference]
) -> NativeDecompilerWirePseudocodeTokenRecord {
    NativeDecompilerWirePseudocodeTokenRecord(
        id: value.id, text: value.text, kind: value.kind, line: value.line, column: value.column,
        sourceRanges: value.sourceRanges, entityReferences: entityReferences
    )
}

private func replacingVarnode(
    _ value: NativeDecompilerWireVarnodeRecord,
    typeID: String?? = nil,
    registerName: String?? = nil,
    sizeBytes: UInt32? = nil,
    addressSpaceID: String? = nil,
    offset: UInt64? = nil
) -> NativeDecompilerWireVarnodeRecord {
    NativeDecompilerWireVarnodeRecord(
        id: value.id, addressSpaceID: addressSpaceID ?? value.addressSpaceID,
        offset: offset.map { .init($0) } ?? value.offset,
        sizeBytes: sizeBytes ?? value.sizeBytes, role: value.role,
        typeID: typeID ?? value.typeID, registerName: registerName ?? value.registerName
    )
}

private func replacingCapabilities(
    _ value: NativeDecompilerWireBackendCapabilities,
    nativeDecompilerHeritage: Bool? = nil,
    completeRegisterSSA: Bool? = nil,
    memorySSA: Bool? = nil,
    recoveredVariables: Bool? = nil,
    recoveredTypes: Bool? = nil,
    structuredControlFlow: Bool? = nil,
    tokenizedPseudocode: Bool? = nil,
    imageQualifiedSourceRanges: Bool? = nil
) -> NativeDecompilerWireBackendCapabilities {
    NativeDecompilerWireBackendCapabilities(
        nativeDecompilerHeritage: nativeDecompilerHeritage ?? value.nativeDecompilerHeritage,
        completeRegisterSSA: completeRegisterSSA ?? value.completeRegisterSSA,
        memorySSA: memorySSA ?? value.memorySSA,
        recoveredVariables: recoveredVariables ?? value.recoveredVariables,
        recoveredTypes: recoveredTypes ?? value.recoveredTypes,
        structuredControlFlow: structuredControlFlow ?? value.structuredControlFlow,
        tokenizedPseudocode: tokenizedPseudocode ?? value.tokenizedPseudocode,
        imageQualifiedSourceRanges: imageQualifiedSourceRanges ?? value.imageQualifiedSourceRanges
    )
}

private func replacingRequest(
    _ value: NativeDecompilerWireRequest,
    budgets: NativeDecompilerWireAnalysisBudgets
) -> NativeDecompilerWireRequest {
    NativeDecompilerWireRequest(
        requestID: value.requestID,
        requestSHA256: value.requestSHA256,
        target: value.target,
        image: value.image,
        function: value.function,
        memoryRegions: value.memoryRegions,
        symbols: value.symbols,
        authoredInputs: value.authoredInputs,
        budgets: budgets
    )
}

private func replacingBudgets(
    _ value: NativeDecompilerWireAnalysisBudgets,
    maxInstructions: UInt32? = nil,
    maxOperations: UInt32? = nil,
    maxOutputBytes: UInt32? = nil
) -> NativeDecompilerWireAnalysisBudgets {
    NativeDecompilerWireAnalysisBudgets(
        maxCodeBytes: value.maxCodeBytes,
        maxInstructions: maxInstructions ?? value.maxInstructions,
        maxOperations: maxOperations ?? value.maxOperations,
        maxOutputBytes: maxOutputBytes ?? value.maxOutputBytes,
        maxWallTimeMilliseconds: value.maxWallTimeMilliseconds
    )
}

// CP4: a complete test-only JSON projection generated from the real C++ exporter.
// The JSON is an inspectable cross-language corpus, not the production transport.
private struct CP4NativeFixture: Decodable {
    let name: String
    let accepted: Bool
    let cppError: String
    let requestID: UUID
    let requestSHA256: String
    let image: NativeDecompilerWireImageIdentity
    let function: NativeDecompilerWireFunctionIdentity
    let memoryRegions: [NativeDecompilerWireMemoryRegion]
    let symbols: [NativeDecompilerWireSymbolRecord]
    let capabilities: NativeDecompilerWireBackendCapabilities
    let runtimeIdentity: NativeDecompilerRuntimeIdentity
    let estimatedBytes: NativeDecompilerWireUInt64
    let encodedSizeUpperBound: NativeDecompilerWireUInt64
    let replyVersion: UInt32
    let result: NativeDecompilerWireStructuredResult

    func request(outputBudget: UInt32? = nil) throws -> NativeDecompilerWireRequest {
        let profile = NativeDecompilerProductBudgetProfile.v1.wireValue
        let budgets = NativeDecompilerWireAnalysisBudgets(profileID: profile.profileID,
            maxCodeBytes: profile.maxCodeBytes, maxInstructions: profile.maxInstructions,
            maxOperations: profile.maxOperations, maxOutputBytes: outputBudget ?? profile.maxOutputBytes,
            maxWallTimeMilliseconds: profile.maxWallTimeMilliseconds)
        return NativeDecompilerWireRequest(requestID: requestID, requestSHA256: requestSHA256,
            target: try NativeDecompilerSealedTargetProfile.normalizedTarget(rawCPUType: 0x0100_000c,
                rawCPUSubtype: 2, selectedSliceSHA256: String(repeating: "a", count: 64),
                selectedSliceByteCount: UInt64(memoryRegions.reduce(0) { $0 + $1.effectiveBytes.count })),
            image: image, function: function, memoryRegions: memoryRegions, symbols: symbols,
            authoredInputs: .empty, budgets: budgets)
    }

    func reply(version: UInt32? = nil) -> NativeDecompilerWireReplyEnvelope {
        .init(schemaVersion: version, requestID: requestID, success: .init(availability: .init(
            available: true, reasonCode: "", runtimeIdentity: runtimeIdentity, capabilities: capabilities), result: result))
    }
}

private func cp4CorpusObjects() throws -> [[String: Any]] {
    let url = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/NativeDecompilerWireCP4.json")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
}

private func cp4PositiveFixtures() throws -> [CP4NativeFixture] {
    try cp4CorpusObjects().filter { $0["accepted"] as? Bool == true }.map {
        try JSONDecoder().decode(CP4NativeFixture.self, from: JSONSerialization.data(withJSONObject: $0))
    }
}

extension NativeDecompilerWireSemanticValidatorTests {
    func testCP4CompleteNativeCorpusMatchesSwiftAndPublicationBudgets() throws {
        let fixtures = try cp4PositiveFixtures()
        XCTAssertEqual(fixtures.count, 12)
        for fixture in fixtures {
            let request = try fixture.request()
            XCTAssertNoThrow(try NativeDecompilerWireSemanticValidator.validate(request: request,
                capabilities: fixture.capabilities, result: fixture.result), fixture.name)
            XCTAssertEqual(NativeDecompilerWireSemanticValidator.estimatedStructuredResultBytes(fixture.result),
                fixture.estimatedBytes.value, fixture.name)
            XCTAssertEqual(fixture.result.requiredReplySchemaVersion, fixture.replyVersion, fixture.name)
            let codec = NativeDecompilerWireCodec()
            let envelope = NativeDecompilerWireRequestEnvelope(requestID: fixture.requestID, body: request)
            let binding = NativeDecompilerWireExpectedRequestBinding(request: envelope)
            // This also checks the C++ canonical request SHA-256 against Swift's unchanged preimage.
            let requestBytes = try codec.encodeRequest(envelope, matching: fixture.requestID)
            XCTAssertEqual(try codec.decodeRequest(requestBytes, matching: fixture.requestID), envelope, fixture.name)
            let reply = fixture.reply()
            let bytes = try codec.encodeReply(reply, matching: binding)
            XCTAssertEqual(bytes, try codec.encodeReply(reply, matching: binding), fixture.name)
            XCTAssertLessThanOrEqual(UInt64(bytes.count), fixture.encodedSizeUpperBound.value, fixture.name)
            XCTAssertEqual(try codec.decodeReply(bytes, matching: binding), reply, fixture.name)
            print("cp4-swift-positive \(fixture.name) estimated=\(fixture.estimatedBytes.value) bplist=\(bytes.count) schema=\(reply.schemaVersion)")
        }
    }

    func testCP4RejectsEveryNativeNegativeFixture() throws {
        let objects = try cp4CorpusObjects().filter { $0["accepted"] as? Bool == false }
        XCTAssertEqual(objects.count, 28)
        for object in objects {
            let name = try XCTUnwrap(object["name"] as? String)
            let data = try JSONSerialization.data(withJSONObject: object)
            do {
                let fixture = try JSONDecoder().decode(CP4NativeFixture.self, from: data)
                let request = try fixture.request()
                XCTAssertThrowsError(try NativeDecompilerWireSemanticValidator.validate(request: request,
                    capabilities: fixture.capabilities, result: fixture.result), name)
                print("cp4-swift-negative \(name) semantic-rejection; native=\(fixture.cppError)")
            } catch is DecodingError {
                // Unknown closed enums and illegal authentication payloads fail even before graph validation.
                print("cp4-swift-negative \(name) closed-model-rejection")
            }
        }
    }

    func testCP4ZeroOpMultiOwnerAndStandaloneAuthenticationRemainExplicit() throws {
        let fixtures = try cp4PositiveFixtures()
        let loop = try XCTUnwrap(fixtures.first { $0.name == "zero-op-loop" })
        let partition = try XCTUnwrap(loop.result.blockPartition)
        let entry = try XCTUnwrap(loop.result.blocks.first { $0.id == partition.entryBlockID })
        XCTAssertTrue(entry.operationIDs.isEmpty)
        XCTAssertEqual(entry.terminatorKind, .splice)
        XCTAssertEqual(entry.successorEdgeIDs.count, 1)
        XCTAssertEqual(partition.instructions.first?.spans.first?.operationCount, 0)
        XCTAssertTrue(loop.result.phis.allSatisfy { $0.incoming.allSatisfy { $0.edgeID != nil && $0.sourceBlockID != nil } })
        let csel = try XCTUnwrap(fixtures.first { $0.name == "multi-owner-csel" })
        let instruction = try XCTUnwrap(csel.result.instructions.first { $0.address.value == 0x1004 })
        let ownership = try XCTUnwrap(csel.result.blockPartition?.instructions.first { $0.instructionID == instruction.id })
        XCTAssertEqual(ownership.spans.count, 3)
        XCTAssertEqual(Set(ownership.spans.map(\.blockID)).count, 3)
        XCTAssertEqual(ownership.spans.reduce(UInt32(0)) { $0 + $1.operationCount }, UInt32(instruction.operationIDs.count))
        let auth = try XCTUnwrap(fixtures.first { $0.name == "standalone-autibsp" })
        let operation = try XCTUnwrap(auth.result.operations.first {
            $0.authenticationEffect.kind == .standaloneAuthenticationWithoutTransformedOutput
        })
        XCTAssertEqual(operation.userOperationName, "AuthIB")
        XCTAssertEqual(operation.inputVarnodeIDs.count, 3)
        XCTAssertNil(operation.outputVarnodeID)
        XCTAssertNil(operation.authenticationEffect.outputSSAValueID)
        XCTAssertEqual(auth.result.instructions.first?.bytes, Data([0xff,0x23,0x03,0xd5]))
        XCTAssertTrue(auth.result.operations.contains { $0.opcode == .return && $0.sourceRanges.first?.startAddress.value == 0x1004 })
    }

    func testCP4ReplyVersionMigrationAndClosedMetadataShape() throws {
        let codec = NativeDecompilerWireCodec()
        for fixture in try cp4PositiveFixtures() where fixture.replyVersion == 4 {
            let envelope = NativeDecompilerWireRequestEnvelope(requestID: fixture.requestID, body: try fixture.request())
            let binding = NativeDecompilerWireExpectedRequestBinding(request: envelope)
            for version: UInt32 in [3, 5] {
                let reply = fixture.reply(version: version)
                XCTAssertThrowsError(try codec.encodeReply(reply, matching: binding), fixture.name) {
                    XCTAssertEqual($0 as? NativeDecompilerWireCodecError, .unsupportedSchemaVersion)
                }
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                let bytes = try encoder.encode(reply)
                XCTAssertThrowsError(try codec.decodeReply(bytes, matching: binding), fixture.name) {
                    XCTAssertEqual($0 as? NativeDecompilerWireCodecError, .unsupportedSchemaVersion)
                }
            }
            guard fixture.result.blockPartition != nil else { continue }
            let bytes = try codec.encodeReply(fixture.reply(), matching: binding)
            var root = try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
            var success = try XCTUnwrap(root["success"] as? [String: Any])
            var result = try XCTUnwrap(success["result"] as? [String: Any])
            var partition = try XCTUnwrap(result["blockPartition"] as? [String: Any])
            partition["inventedOwnership"] = true
            result["blockPartition"] = partition; success["result"] = result; root["success"] = success
            let unknown = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
            XCTAssertThrowsError(try codec.decodeReply(unknown, matching: binding), fixture.name) {
                XCTAssertEqual($0 as? NativeDecompilerWireCodecError, .invalidShape)
            }
        }
    }

    func testCP4SemanticBudgetBoundaryIncludesEveryMetadataField() throws {
        for fixture in try cp4PositiveFixtures() where fixture.result.blockPartition != nil {
            let bound = try XCTUnwrap(UInt32(exactly: fixture.estimatedBytes.value))
            XCTAssertNoThrow(try NativeDecompilerWireSemanticValidator.validate(request: fixture.request(outputBudget: bound),
                capabilities: fixture.capabilities, result: fixture.result), fixture.name)
            XCTAssertThrowsError(try NativeDecompilerWireSemanticValidator.validate(request: fixture.request(outputBudget: bound - 1),
                capabilities: fixture.capabilities, result: fixture.result), fixture.name)
        }
    }
}

/// `decompile-document` replies carry the document and warnings only.
extension NativeDecompilerWireSemanticValidatorTests {
    private func documentOnly(_ result: NativeDecompilerWireStructuredResult,
                              keepingOperations: Bool = false) -> NativeDecompilerWireStructuredResult {
        .init(requestID: result.requestID, requestSHA256: result.requestSHA256, image: result.image,
              function: result.function, addressSpaces: [], types: [], instructions: [], varnodes: [],
              operations: keepingOperations ? result.operations : [], blocks: [], edges: [], ssaValues: [],
              ssaBindings: [], phis: [], memoryVersions: [], memoryPhis: [], memoryEffects: [], variables: [],
              calls: [], regions: [], tokens: [], pseudocodeDocument: result.pseudocodeDocument,
              warnings: [.init(code: "native-structure-omitted", severity: .warning,
                               message: "Document-only request: the structured graph was not exported.",
                               sourceRanges: [])])
    }

    func testDocumentOnlyReplyValidatesOnlyForTheDocumentOperation() throws {
        let fixture = try XCTUnwrap(try cp4PositiveFixtures().first { $0.result.pseudocodeDocument != nil })
        let request = try fixture.request()
        let document = documentOnly(fixture.result)
        XCTAssertNoThrow(try NativeDecompilerWireSemanticValidator.validate(
            request: request, operation: .decompileDocument, capabilities: fixture.capabilities, result: document))
        XCTAssertThrowsError(try NativeDecompilerWireSemanticValidator.validate(
            request: request, capabilities: fixture.capabilities, result: document),
            "a full decompile reply may not omit the graph")
        XCTAssertThrowsError(try NativeDecompilerWireSemanticValidator.validate(
            request: request, operation: .decompileDocument, capabilities: fixture.capabilities,
            result: documentOnly(fixture.result, keepingOperations: true)),
            "a document-only reply carries no graph records")
        XCTAssertThrowsError(try NativeDecompilerWireSemanticValidator.validate(
            request: request, operation: .decompileDocument, capabilities: fixture.capabilities,
            result: fixture.result), "the full graph is not a document-only reply")
    }
}
