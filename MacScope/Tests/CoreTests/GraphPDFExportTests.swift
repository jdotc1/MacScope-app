import CoreGraphics
import XCTest
@testable import MacScope

/// T1 — Export the control-flow GRAPH view to PDF.
///
/// Exercises the pure `GraphLayoutGeometry` (function→lane / block→node grouping, edge
/// sourcing) and `GraphPDFRenderer` (a one-page vector PDF, no file I/O). The renderer
/// must produce deterministic, non-empty, *valid* PDF bytes for a known snapshot, and
/// the geometry must place every function/block as a node and route every CFG edge.
final class GraphPDFExportTests: XCTestCase {

    private let slotA = ImageSlot.primary
    private let slotB = ImageSlot(rawValue: 1)
    private let slotWithoutAnalysis = ImageSlot(rawValue: 2)

    private func insn(_ address: UInt64, _ mnemonic: String = "nop") -> InstructionRow {
        InstructionRow(address: address, bytes: "1f 20 03 d5", mnemonic: mnemonic, operands: "",
                       hasBreakpoint: false, comment: nil)
    }

    private func function(_ name: String, _ start: UInt64, _ end: UInt64) -> FunctionSummary {
        FunctionSummary(id: UUID(), name: name, startAddress: start, endAddress: end, confidence: 1)
    }

    private func block(_ fn: UUID, _ start: UInt64, _ end: UInt64, _ count: Int) -> BasicBlockSummary {
        BasicBlockSummary(id: UUID(), functionID: fn, startAddress: start, endAddress: end, instructionCount: count)
    }

    /// A two-function snapshot: the first has two basic blocks joined by a branch +
    /// fallthrough, the second is a leaf called from the first.
    private func sampleSnapshot() -> WorkspaceSnapshot {
        let fnA = function("entry", 0x1000, 0x1020)
        let fnB = function("helper", 0x1020, 0x1030)
        var snap = WorkspaceSnapshot(
            binaries: [],
            functions: [fnA, fnB],
            instructions: [insn(0x1000), insn(0x1004), insn(0x1010), insn(0x1020), insn(0x1024)],
            xrefs: [],
            hexBytes: Data()
        )
        snap.basicBlocks = [
            block(fnA.id, 0x1000, 0x1010, 4),
            block(fnA.id, 0x1010, 0x1020, 4),
            block(fnB.id, 0x1020, 0x1030, 4),
        ]
        snap.controlFlowEdges = [
            ControlFlowEdge(id: UUID(), from: 0x1000, to: 0x1010, kind: "branch"),
            ControlFlowEdge(id: UUID(), from: 0x1010, to: 0x1000, kind: "fallthrough"),
        ]
        snap.xrefs = [
            XRef(id: UUID(), from: 0x1010, to: 0x1020, kind: "call"),
        ]
        return snap
    }

    /// Images A and B deliberately collide at 0x1000. B also owns a function at an address that
    /// does not occur in A, while the third loaded image deliberately has no analysis bucket.
    private func collidingImageSnapshot() -> WorkspaceSnapshot {
        let aFunction = FunctionSummary(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1")!,
            name: "A_PARSED_SENTINEL",
            startAddress: 0x1000,
            endAddress: 0x1020,
            confidence: 1
        )
        let bFunction = FunctionSummary(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1")!,
            name: "B_PARSED_SENTINEL",
            startAddress: 0x1000,
            endAddress: 0x1020,
            confidence: 1
        )
        let bOnlyFunction = FunctionSummary(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB2")!,
            name: "B_ONLY_FUNCTION_SENTINEL",
            startAddress: 0x2000,
            endAddress: 0x2010,
            confidence: 1
        )

        var analysisA = ImageAnalysis()
        analysisA.functions = [aFunction]
        analysisA.instructions = [insn(0x1000, "a_collision")]
        analysisA.controlFlowEdges = [ControlFlowEdge(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAE1")!,
            from: 0x1000,
            to: 0x1000,
            kind: "branch"
        )]

        var analysisB = ImageAnalysis()
        analysisB.functions = [bFunction, bOnlyFunction]
        analysisB.instructions = [insn(0x1000, "b_collision"), insn(0x2000, "b_only")]
        analysisB.controlFlowEdges = [ControlFlowEdge(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBE1")!,
            from: 0x1000,
            to: 0x2000,
            kind: "call"
        )]

        return WorkspaceSnapshot(
            binaries: [
                image(slot: slotA, name: "A"),
                image(slot: slotB, name: "B"),
                image(slot: slotWithoutAnalysis, name: "NoAnalysis"),
            ],
            analysisBySlot: [slotA: analysisA, slotB: analysisB],
            addressOverrides: [
                ImageAddress(slot: slotA, address: 0x1000): AddressOverride(
                    customName: "A_CUSTOM_SENTINEL"
                ),
                ImageAddress(slot: slotB, address: 0x1000): AddressOverride(
                    customName: "B_CUSTOM_SENTINEL"
                ),
            ]
        )
    }

    private func sparseSiblingSnapshot() -> WorkspaceSnapshot {
        var analysisA = ImageAnalysis()
        analysisA.functions = [function("A_FUNCTION_SENTINEL", 0x3000, 0x3010)]
        analysisA.instructions = [insn(0x3000, "a_collision")]

        var analysisB = ImageAnalysis()
        analysisB.instructions = [
            insn(0x3000, "b_sparse_collision"),
            InstructionRow(
                address: 0x3008,
                bytes: "00 00 80 d2 c0 03 5f d6",
                mnemonic: "b_sparse_tail",
                operands: "",
                hasBreakpoint: false,
                comment: nil
            ),
        ]

        return WorkspaceSnapshot(
            binaries: [image(slot: slotA, name: "A"), image(slot: slotB, name: "B")],
            analysisBySlot: [slotA: analysisA, slotB: analysisB]
        )
    }

    /// The two image analyses are deliberately byte-for-byte identical. Their only graph-visible
    /// difference is authored tag/color presentation at the colliding function start, so a PDF
    /// content difference cannot be explained by structure, names, instructions, edges, or title.
    private func presentationOnlyCollisionSnapshot() -> WorkspaceSnapshot {
        let sharedFunction = FunctionSummary(
            id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDD1")!,
            name: "SHARED_PARSED_SENTINEL",
            startAddress: 0x5000,
            endAddress: 0x5010,
            confidence: 1
        )
        var sharedAnalysis = ImageAnalysis()
        sharedAnalysis.functions = [sharedFunction]
        sharedAnalysis.instructions = [insn(0x5000, "shared_collision")]

        return WorkspaceSnapshot(
            binaries: [image(slot: slotA, name: "A"), image(slot: slotB, name: "B")],
            analysisBySlot: [slotA: sharedAnalysis, slotB: sharedAnalysis],
            addressOverrides: [
                ImageAddress(slot: slotA, address: 0x5000): AddressOverride(
                    customName: "SHARED_CUSTOM_SENTINEL",
                    tag: "A_TAG_SENTINEL",
                    colorTag: .red
                ),
                ImageAddress(slot: slotB, address: 0x5000): AddressOverride(
                    customName: "SHARED_CUSTOM_SENTINEL",
                    tag: "B_TAG_SENTINEL",
                    colorTag: .blue
                ),
            ]
        )
    }

    private func image(slot: ImageSlot, name: String) -> BinaryImage {
        BinaryImage(
            id: UUID(),
            name: name,
            path: "/tmp/GraphPDFExportTests-\(name)",
            kind: "Mach-O",
            architecture: "arm64",
            slot: slot
        )
    }

    // MARK: - Geometry

    /// Every function becomes a lane and every basic block becomes a node; the two
    /// functions' three blocks yield three nodes total.
    func testGeometryMapsFunctionsAndBlocksToLanesAndNodes() {
        let geometry = GraphLayoutGeometry(snapshot: sampleSnapshot(), metrics: GraphPDFRenderer.Metrics.self)
        XCTAssertEqual(geometry.lanes.count, 2)
        XCTAssertEqual(geometry.lanes[0].title, "entry")
        XCTAssertEqual(geometry.lanes[1].title, "helper")
        XCTAssertEqual(geometry.nodeCount, 3)
        // The first node of each lane is the entry block.
        XCTAssertTrue(geometry.lanes[0].nodes.first?.isEntry == true)
        XCTAssertTrue(geometry.lanes[1].nodes.first?.isEntry == true)
    }

    /// Equal virtual addresses are legal in conservative analysis output. The live canvas and
    /// PDF export must use the same UUID tie-break so lane order and block ordinals cannot drift
    /// merely because the projection arrived in a different collection order.
    func testEqualAddressOrderingMatchesLiveGraphByUUID() throws {
        let lowerFunction = FunctionSummary(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "UUID-lower function",
            startAddress: 0x1000,
            endAddress: 0x1020,
            confidence: 1
        )
        let higherFunction = FunctionSummary(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "UUID-higher function",
            startAddress: 0x1000,
            endAddress: 0x1020,
            confidence: 1
        )
        let lowerBlock = BasicBlockSummary(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            functionID: lowerFunction.id,
            startAddress: 0x1000,
            endAddress: 0x1010,
            instructionCount: 11
        )
        let higherBlock = BasicBlockSummary(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            functionID: lowerFunction.id,
            startAddress: 0x1000,
            endAddress: 0x1010,
            instructionCount: 22
        )
        let projection = FocusedGraphProjection(
            imageSlot: slotA,
            functions: [higherFunction, lowerFunction],
            basicBlocks: [higherBlock, lowerBlock],
            instructions: [insn(0x1000)],
            controlFlowEdges: [],
            xrefs: [],
            presentationByAddress: [:]
        )

        let live = FocusedGraphBuilder.build(
            projection,
            viewport: CGSize(width: 1_200, height: 800)
        )
        let exported = GraphLayoutGeometry(
            projection: projection,
            metrics: GraphPDFRenderer.Metrics.self
        )

        XCTAssertEqual(exported.lanes.map(\.title), live.sections.map(\.title))
        XCTAssertEqual(exported.lanes.map(\.title), ["UUID-lower function", "UUID-higher function"])
        XCTAssertEqual(
            try XCTUnwrap(exported.lanes.first).nodes.map(\.detail),
            try XCTUnwrap(live.sections.first).nodes.map { "\($0.instructionCount) insn" }
        )
        XCTAssertEqual(exported.lanes.first?.nodes.map(\.detail), ["11 insn", "22 insn"])
    }

    /// All three edges (two CFG + one xref `call`) resolve to routed edges because every
    /// endpoint lands inside a node, and the call edge keeps its `.call` kind.
    func testGeometryRoutesEveryEdge() {
        let geometry = GraphLayoutGeometry(snapshot: sampleSnapshot(), metrics: GraphPDFRenderer.Metrics.self)
        XCTAssertEqual(geometry.edges.count, 3)
        XCTAssertEqual(geometry.edges.filter { $0.kind == .call }.count, 1)
        XCTAssertEqual(geometry.edges.filter { $0.kind == .branch }.count, 1)
        XCTAssertEqual(geometry.edges.filter { $0.kind == .fallThrough }.count, 1)
    }

    /// A duplicate xref that mirrors an existing CFG edge's endpoints is deduplicated, so
    /// the edge count does not grow.
    func testGeometryDeduplicatesXrefAgainstControlFlowEdge() {
        var snap = sampleSnapshot()
        // Same endpoints + kind as the first CFG edge -> must be dropped.
        snap.xrefs.append(XRef(id: UUID(), from: 0x1000, to: 0x1010, kind: "branch"))
        let geometry = GraphLayoutGeometry(snapshot: snap, metrics: GraphPDFRenderer.Metrics.self)
        XCTAssertEqual(geometry.edges.count, 3)
    }

    /// The page grows to fit two side-by-side lanes (never the degenerate minimum).
    func testGeometryPageSizeFitsLanes() {
        let geometry = GraphLayoutGeometry(snapshot: sampleSnapshot(), metrics: GraphPDFRenderer.Metrics.self)
        XCTAssertGreaterThan(geometry.pageSize.width, GraphPDFRenderer.Metrics.laneWidth)
        XCTAssertGreaterThanOrEqual(geometry.pageSize.height, GraphPDFRenderer.Metrics.minPageHeight)
        // The right lane's frame must be fully inside the page.
        let rightLane = geometry.lanes[1].frame
        XCTAssertLessThanOrEqual(rightLane.maxX, geometry.pageSize.width)
    }

    /// The explicit B projection owns every lane, edge, and authored name even though A has a
    /// function at the same virtual address. A's sentinel and branch edge cannot leak into B.
    func testExplicitSlotGeometryUsesOnlyRequestedCollidingImage() {
        let projection = collidingImageSnapshot().graphProjection(in: slotB)
        let geometry = GraphLayoutGeometry(projection: projection, metrics: GraphPDFRenderer.Metrics.self)

        XCTAssertEqual(projection.imageSlot, slotB)
        XCTAssertEqual(geometry.lanes.map(\.title), ["B_CUSTOM_SENTINEL", "B_ONLY_FUNCTION_SENTINEL"])
        XCTAssertFalse(geometry.lanes.map(\.title).contains("A_CUSTOM_SENTINEL"))
        XCTAssertEqual(geometry.edges.count, 1)
        XCTAssertEqual(geometry.edges.first?.kind, .call)
    }

    /// A sibling with no functions or blocks still exports its own sparse instruction range. The
    /// half-open end comes from the final row's real eight-byte width, not A's colliding function.
    func testExplicitSlotGeometryAndPDFUseBOnlySparseFallback() throws {
        let snapshot = sparseSiblingSnapshot()
        let projection = snapshot.graphProjection(in: slotB)
        let geometry = GraphLayoutGeometry(projection: projection, metrics: GraphPDFRenderer.Metrics.self)

        XCTAssertEqual(projection.sparseInstructionRange, 0x3000..<0x3010)
        XCTAssertEqual(geometry.lanes.count, 1)
        XCTAssertEqual(geometry.lanes.first?.title, "Instructions")
        XCTAssertEqual(geometry.lanes.first?.nodes.first?.endAddress, 0x3010)

        let data = try XCTUnwrap(
            GraphPDFRenderer().renderPDF(snapshot: snapshot, in: slotB, title: "B sparse")
        )
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertNotNil(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
    }

    /// A sparse row at UInt64.max cannot form the required half-open end. Geometry must abstain
    /// instead of trapping, wrapping to zero, or manufacturing a node/edge, while PDF export keeps
    /// the existing valid empty-graph behavior.
    func testExplicitSlotGeometryAbstainsWhenSparseHalfOpenEndOverflows() throws {
        let projection = FocusedGraphProjection(
            imageSlot: slotB,
            functions: [],
            basicBlocks: [],
            instructions: [InstructionRow(
                address: .max,
                bytes: "ff",
                mnemonic: "overflow_sentinel",
                operands: "",
                hasBreakpoint: false,
                comment: nil
            )],
            controlFlowEdges: [],
            xrefs: [],
            presentationByAddress: [:]
        )

        XCTAssertNil(projection.sparseInstructionRange)
        let geometry = GraphLayoutGeometry(projection: projection, metrics: GraphPDFRenderer.Metrics.self)
        XCTAssertTrue(geometry.lanes.isEmpty)
        XCTAssertEqual(geometry.nodeCount, 0)
        XCTAssertTrue(geometry.edges.isEmpty)

        let data = try XCTUnwrap(
            GraphPDFRenderer().renderPDF(projection: projection, title: "Overflow abstention")
        )
        XCTAssertNotNil(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
    }

    // MARK: - PDF output

    /// The renderer produces non-empty bytes that begin with the PDF magic and end with
    /// the EOF marker — i.e. a structurally valid PDF, not an empty blob.
    func testRenderPDFProducesValidNonEmptyDocument() throws {
        let data = try XCTUnwrap(GraphPDFRenderer().renderPDF(snapshot: sampleSnapshot(), title: "sample"))
        XCTAssertGreaterThan(data.count, 512, "A real graph PDF should be more than a stub.")

        let header = data.prefix(5)
        XCTAssertEqual(String(decoding: header, as: UTF8.self), "%PDF-")

        // The EOF marker appears near the tail of every well-formed PDF.
        let tail = data.suffix(32)
        let tailString = String(decoding: tail, as: UTF8.self)
        XCTAssertTrue(tailString.contains("%%EOF"), "PDF should end with the EOF marker.")
    }

    /// Core Graphics can re-open the rendered bytes as a single-page PDF document — the
    /// strongest "it is a real PDF" check available without a third-party parser.
    func testRenderedPDFIsParseableAsSinglePage() throws {
        let data = try XCTUnwrap(GraphPDFRenderer().renderPDF(snapshot: sampleSnapshot(), title: "sample"))
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, 1)
        let page = try XCTUnwrap(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        XCTAssertGreaterThan(box.width, 0)
        XCTAssertGreaterThan(box.height, 0)
    }

    /// Re-rendering the SAME snapshot twice yields an identical drawing: the page count,
    /// media box, and — most importantly — the page CONTENT STREAM (the actual vector
    /// drawing commands) are byte-identical. The whole-file bytes are intentionally NOT
    /// compared because a PDF trailer embeds a per-document creation timestamp + random
    /// file ID, so two valid renders of the same drawing differ only in that metadata.
    func testRenderPDFIsDeterministic() throws {
        let snapshot = sampleSnapshot()
        let projection = snapshot.graphProjection(in: snapshot.primarySlot)
        let first = try XCTUnwrap(GraphPDFRenderer().renderPDF(projection: projection, title: "sample"))
        let second = try XCTUnwrap(GraphPDFRenderer().renderPDF(projection: projection, title: "sample"))

        // Equal size is a fast necessary condition; the content-stream check is the proof.
        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(try pageContentStream(of: first), try pageContentStream(of: second))
    }

    /// A loaded image with no analysis has a valid empty export. It does not borrow A's lane merely
    /// because A is primary or happens to contain colliding graph evidence.
    func testExplicitSlotPDFHandlesMissingAnalysisWithoutPrimaryFallback() throws {
        let snapshot = collidingImageSnapshot()
        let missingProjection = snapshot.graphProjection(in: slotWithoutAnalysis)
        let geometry = GraphLayoutGeometry(
            projection: missingProjection,
            metrics: GraphPDFRenderer.Metrics.self
        )
        XCTAssertEqual(missingProjection.imageSlot, slotWithoutAnalysis)
        XCTAssertTrue(geometry.lanes.isEmpty)
        XCTAssertTrue(geometry.edges.isEmpty)

        let missing = try XCTUnwrap(
            GraphPDFRenderer().renderPDF(
                snapshot: snapshot,
                in: slotWithoutAnalysis,
                title: "No analysis"
            )
        )
        XCTAssertNotNil(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: missing as CFData))))

        let primary = try XCTUnwrap(GraphPDFRenderer().renderPDF(snapshot: snapshot, title: "No analysis"))
        XCTAssertNotEqual(try pageContentStream(of: missing), try pageContentStream(of: primary))
    }

    /// The legacy snapshot-only API remains a deterministic primary-image wrapper even when an
    /// explicit B export is also requested. It exactly matches rendering A's frozen projection.
    func testLegacyPDFWrapperRemainsPrimaryCompatibility() throws {
        let snapshot = collidingImageSnapshot()
        let renderer = GraphPDFRenderer()

        let legacy = try XCTUnwrap(renderer.renderPDF(snapshot: snapshot, title: "collision"))
        let explicitPrimary = try XCTUnwrap(renderer.renderPDF(
            projection: snapshot.graphProjection(in: snapshot.primarySlot),
            title: "collision"
        ))
        let explicitB = try XCTUnwrap(renderer.renderPDF(snapshot: snapshot, in: slotB, title: "collision"))

        XCTAssertEqual(try pageContentStream(of: legacy), try pageContentStream(of: explicitPrimary))
        XCTAssertNotEqual(try pageContentStream(of: legacy), try pageContentStream(of: explicitB))
    }

    /// The File-menu command freezes every focused-image input before it presents a Save panel.
    /// A later focus change therefore cannot redirect the rendered bytes, PDF title, suggested
    /// filename, or disambiguating message back to the primary image at a colliding address.
    @MainActor
    func testGUIExportContextFreezesFocusedSiblingBeforeSavePanel() throws {
        let snapshot = collidingImageSnapshot()
        let store = WorkspaceStore(
            workspaceName: "Collision workspace",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        store.focusImage(slotB)

        let context = GraphPDFExportContext.capture(from: store)
        store.focusImage(slotA) // Models a focus change while the already-captured export is pending.

        XCTAssertEqual(context.projection.imageSlot, slotB)
        XCTAssertEqual(context.title, "Collision workspace — B")
        XCTAssertEqual(context.defaultName, "Collision workspace-B-graph")
        XCTAssertEqual(context.message, "Export the control-flow graph from B.")

        let renderer = GraphPDFRenderer()
        let captured = try XCTUnwrap(renderer.renderPDF(
            projection: context.projection,
            title: context.title
        ))
        let expectedB = try XCTUnwrap(renderer.renderPDF(
            projection: snapshot.graphProjection(in: slotB),
            title: context.title
        ))
        let wrongA = try XCTUnwrap(renderer.renderPDF(
            projection: snapshot.graphProjection(in: slotA),
            title: context.title
        ))

        XCTAssertEqual(try pageContentStream(of: captured), try pageContentStream(of: expectedB))
        XCTAssertNotEqual(try pageContentStream(of: captured), try pageContentStream(of: wrongA))
    }

    /// A single-image workspace keeps the pre-WS-17 title and suggested filename and does not add
    /// a redundant Save-panel message merely to use the focused export seam.
    @MainActor
    func testGUIExportContextPreservesSingleImagePresentation() {
        var snapshot = collidingImageSnapshot()
        snapshot.removeImage(in: slotB)
        snapshot.removeImage(in: slotWithoutAnalysis)
        let store = WorkspaceStore(
            workspaceName: "Single workspace",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )

        let context = GraphPDFExportContext.capture(from: store)

        XCTAssertEqual(context.projection.imageSlot, slotA)
        XCTAssertEqual(context.title, "Single workspace")
        XCTAssertEqual(context.defaultName, "Single workspace-graph")
        XCTAssertNil(context.message)
    }

    /// The frozen A and B projections have identical graph structure and names; only their tag and
    /// color differ. Each presentation component must therefore affect the rendered PDF, proving
    /// the exporter consumes the aggregate instead of silently dropping graph-visible authoring.
    func testExplicitSlotPDFRendersDistinctTagAndColorFromFrozenProjection() throws {
        let snapshot = presentationOnlyCollisionSnapshot()
        let projectionA = snapshot.graphProjection(in: slotA)
        let projectionB = snapshot.graphProjection(in: slotB)

        XCTAssertEqual(projectionA.functions, projectionB.functions)
        XCTAssertEqual(projectionA.basicBlocks, projectionB.basicBlocks)
        XCTAssertEqual(projectionA.instructions, projectionB.instructions)
        XCTAssertEqual(projectionA.controlFlowEdges, projectionB.controlFlowEdges)
        XCTAssertEqual(projectionA.xrefs, projectionB.xrefs)
        XCTAssertEqual(projectionA.presentationByAddress[0x5000]?.customName, "SHARED_CUSTOM_SENTINEL")
        XCTAssertEqual(projectionB.presentationByAddress[0x5000]?.customName, "SHARED_CUSTOM_SENTINEL")
        XCTAssertEqual(projectionA.presentationByAddress[0x5000]?.tag, "A_TAG_SENTINEL")
        XCTAssertEqual(projectionB.presentationByAddress[0x5000]?.tag, "B_TAG_SENTINEL")
        XCTAssertEqual(projectionA.presentationByAddress[0x5000]?.colorTag, .red)
        XCTAssertEqual(projectionB.presentationByAddress[0x5000]?.colorTag, .blue)

        var bWithATag = projectionB
        bWithATag.presentationByAddress[0x5000]?.tag = "A_TAG_SENTINEL"
        var bWithAColor = projectionB
        bWithAColor.presentationByAddress[0x5000]?.colorTag = .red

        let renderer = GraphPDFRenderer()
        let streamA = try pageContentStream(of: try XCTUnwrap(
            renderer.renderPDF(projection: projectionA, title: "Shared presentation")
        ))
        let streamB = try pageContentStream(of: try XCTUnwrap(
            renderer.renderPDF(projection: projectionB, title: "Shared presentation")
        ))
        let streamBWithATag = try pageContentStream(of: try XCTUnwrap(
            renderer.renderPDF(projection: bWithATag, title: "Shared presentation")
        ))
        let streamBWithAColor = try pageContentStream(of: try XCTUnwrap(
            renderer.renderPDF(projection: bWithAColor, title: "Shared presentation")
        ))

        XCTAssertNotEqual(streamA, streamB, "A and B authored graph presentation must render distinctly")
        XCTAssertNotEqual(streamB, streamBWithATag, "the frozen tag must affect PDF output")
        XCTAssertNotEqual(streamB, streamBWithAColor, "the frozen color must affect PDF output")
    }

    /// Extracts the decoded content stream(s) of page 1 — the deterministic drawing
    /// payload. The PDF spec permits a page's `/Contents` to be EITHER a single stream
    /// OR an array of streams (whose decoded bytes concatenate into one content stream);
    /// CG currently emits a single stream, but this handles both so the determinism check
    /// never goes flaky if CG ever switches to an array.
    private func pageContentStream(of data: Data) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(document.page(at: 1))
        let dictionary = try XCTUnwrap(page.dictionary)

        // Single-stream form: /Contents is one stream object.
        var streamRef: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dictionary, "Contents", &streamRef),
           let stream = streamRef {
            return try decodedStreamData(stream)
        }

        // Array form: /Contents is an array of streams; concatenate their decoded bytes
        // (the spec treats this as a single content stream split at arbitrary boundaries).
        var arrayRef: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Contents", &arrayRef),
                      "page /Contents is neither a stream nor an array of streams")
        let array = try XCTUnwrap(arrayRef)
        var concatenated = Data()
        for index in 0..<CGPDFArrayGetCount(array) {
            var element: CGPDFStreamRef?
            XCTAssertTrue(CGPDFArrayGetStream(array, index, &element),
                          "element \(index) of /Contents array is not a stream")
            concatenated.append(try decodedStreamData(try XCTUnwrap(element)))
        }
        return concatenated
    }

    /// Copies a content stream's decoded bytes.
    private func decodedStreamData(_ stream: CGPDFStreamRef) throws -> Data {
        var format = CGPDFDataFormat.raw
        let cfData = try XCTUnwrap(CGPDFStreamCopyData(stream, &format))
        return cfData as Data
    }

    /// An empty snapshot still produces a valid, non-empty PDF (the empty-state page),
    /// so the command never crashes or writes a zero-byte file.
    func testRenderPDFHandlesEmptySnapshot() throws {
        let empty = WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        let data = try XCTUnwrap(GraphPDFRenderer().renderPDF(snapshot: empty, title: "empty"))
        XCTAssertGreaterThan(data.count, 0)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        XCTAssertNotNil(CGPDFDocument(provider))
    }

    /// A user rename on a function start flows through `displayName(at:)` into the lane
    /// title, so an exported graph honors authoring overrides exactly like the listing export.
    func testRenderHonorsCustomFunctionName() {
        var snap = sampleSnapshot()
        snap.addressOverrides[.primary(0x1000)] = AddressOverride(customName: "main")
        let geometry = GraphLayoutGeometry(snapshot: snap, metrics: GraphPDFRenderer.Metrics.self)
        XCTAssertEqual(geometry.lanes.first?.title, "main")
    }

    /// A snapshot with only loose instructions (no functions, no blocks) still yields one
    /// fallback lane so the export is never blank for a sparsely-analyzed binary.
    func testGeometryFallsBackToInstructionRange() {
        var snap = WorkspaceSnapshot(binaries: [], functions: [],
                                     instructions: [insn(0x2000), insn(0x2004)], xrefs: [], hexBytes: Data())
        snap.controlFlowEdges = []
        let geometry = GraphLayoutGeometry(snapshot: snap, metrics: GraphPDFRenderer.Metrics.self)
        XCTAssertEqual(geometry.lanes.count, 1)
        XCTAssertEqual(geometry.lanes.first?.title, "Instructions")
        XCTAssertEqual(geometry.nodeCount, 1)
    }

    // MARK: - Minimap geometry

    /// The minimap scales the whole canvas down uniformly to fit its box: a 1000x800
    /// canvas into a 200x150 box scales by the limiting (height) axis, 150/800.
    func testMinimapScalesCanvasToFitBox() {
        let geometry = GraphMinimapGeometry(
            canvasSize: CGSize(width: 1000, height: 800),
            viewportSize: CGSize(width: 400, height: 300),
            scrollOffset: .zero,
            minimapSize: CGSize(width: 200, height: 150)
        )
        XCTAssertEqual(geometry.scale, 150.0 / 800.0, accuracy: 1e-9)
        XCTAssertEqual(geometry.contentSize.width, 1000 * geometry.scale, accuracy: 1e-6)
        XCTAssertEqual(geometry.contentSize.height, 150, accuracy: 1e-6)
    }

    /// With no scroll, the viewport rect sits at the minimap origin and is the viewport
    /// size scaled by the same factor.
    func testMinimapViewportRectAtOrigin() {
        let geometry = GraphMinimapGeometry(
            canvasSize: CGSize(width: 1000, height: 1000),
            viewportSize: CGSize(width: 250, height: 250),
            scrollOffset: .zero,
            minimapSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(geometry.viewportRect.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(geometry.viewportRect.minY, 0, accuracy: 1e-6)
        // scale = 100/1000 = 0.1; rect = 250 * 0.1 = 25.
        XCTAssertEqual(geometry.viewportRect.width, 25, accuracy: 1e-6)
        XCTAssertEqual(geometry.viewportRect.height, 25, accuracy: 1e-6)
    }

    /// Scrolling moves the viewport rect proportionally: half-way down a 1000-tall canvas
    /// with a 250-tall viewport puts the rect's top at offset 375 * scale.
    func testMinimapViewportRectTracksScroll() {
        let geometry = GraphMinimapGeometry(
            canvasSize: CGSize(width: 1000, height: 1000),
            viewportSize: CGSize(width: 250, height: 250),
            scrollOffset: CGPoint(x: 0, y: 375),
            minimapSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(geometry.viewportRect.minY, 37.5, accuracy: 1e-6)
    }

    /// An overscroll offset (beyond `canvas - viewport`) is clamped so the rect never
    /// leaves the drawn content — its far edge sits exactly on the content edge.
    func testMinimapViewportRectClampsOverscroll() {
        let geometry = GraphMinimapGeometry(
            canvasSize: CGSize(width: 1000, height: 1000),
            viewportSize: CGSize(width: 250, height: 250),
            scrollOffset: CGPoint(x: 5000, y: 5000),
            minimapSize: CGSize(width: 100, height: 100)
        )
        // max offset = 1000 - 250 = 750; scaled = 75; rect far edge = 75 + 25 = 100 = content edge.
        XCTAssertEqual(geometry.viewportRect.maxX, 100, accuracy: 1e-6)
        XCTAssertEqual(geometry.viewportRect.maxY, 100, accuracy: 1e-6)
    }

    /// A degenerate (zero) canvas does not divide-by-zero; the geometry is finite.
    func testMinimapHandlesZeroCanvas() {
        let geometry = GraphMinimapGeometry(
            canvasSize: .zero,
            viewportSize: CGSize(width: 100, height: 100),
            scrollOffset: .zero,
            minimapSize: CGSize(width: 50, height: 50)
        )
        XCTAssertTrue(geometry.scale.isFinite)
        XCTAssertTrue(geometry.contentSize.width.isFinite)
        XCTAssertTrue(geometry.viewportRect.width.isFinite)
    }
}
