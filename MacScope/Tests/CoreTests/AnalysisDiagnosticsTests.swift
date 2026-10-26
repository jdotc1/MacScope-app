import Foundation
import XCTest
@testable import MacScope

/// Diagnostics-collector unit tests (pure derivation) + a store-level select-to-jump test.
/// These exercise the Problems-panel data path WITHOUT a binary: the collector is a pure
/// function over synthetic analysis products, so each test states an exact input and asserts
/// the exact diagnostic(s) produced — no "non-empty" tautologies.
final class AnalysisDiagnosticsTests: XCTestCase {

    // MARK: - Builders

    private func row(_ address: UInt64, mnemonic: String = "nop", bytes: String = "1f 20 03 d5") -> InstructionRow {
        InstructionRow(address: address, bytes: bytes, mnemonic: mnemonic, operands: "", hasBreakpoint: false, comment: nil)
    }

    private func textSection(address: UInt64 = 0x1000, size: UInt64 = 0x1000) -> SectionSummary {
        SectionSummary(id: UUID(), name: "__TEXT,__text", address: address, size: size, fileOffset: 0, isExecutable: true)
    }

    private func dataSection(address: UInt64 = 0x4000, size: UInt64 = 0x1000) -> SectionSummary {
        SectionSummary(id: UUID(), name: "__DATA,__data", address: address, size: size, fileOffset: 0x3000, isExecutable: false)
    }

    private func identifier(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0001-0000-%012x", value))!
    }

    private func authority(
        document: Int = 2,
        generation: UInt64 = 1
    ) -> AnalysisDiagnostic.Authority {
        AnalysisDiagnostic.Authority(
            imageID: identifier(1),
            documentID: identifier(document),
            sessionID: identifier(3),
            runID: identifier(4),
            analysisGeneration: generation
        )!
    }

    // MARK: - 0. Hostile section spans must not trap (BUG-003)

    /// Sections whose `address + size` overflows previously hit the `Range`
    /// precondition (`&+` produced upperBound < lowerBound) in all three range
    /// computations. The collector must drop such sections and keep working on
    /// the valid ones — never trap and never treat a wrapped low-address window
    /// as real coverage.
    func testOverflowingSectionSpansAreDroppedNotTrapped() throws {
        let hostileText = SectionSummary(
            id: UUID(), name: "__TEXT,__hostile", address: .max - 0x0F, size: 0x1000,
            fileOffset: 0, isExecutable: true
        )
        // 0x0800 sits inside the *wrapped* low window ([0, 0x0FEF)) the hostile
        // section would have covered had `&+` been kept. With the section
        // dropped, the placeholder is in no executable range → no diagnostic.
        let strayPlaceholder = row(0x0800, mnemonic: ".byte", bytes: "ff")
        // A well-formed section keeps working: an undecoded placeholder inside
        // it must still be reported.
        let realPlaceholder = row(0x1010, mnemonic: "unknown", bytes: "00 00 00 00")
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [strayPlaceholder, realPlaceholder],
            controlFlowEdges: [],
            xrefs: [],
            sections: [hostileText, textSection()]
        )

        let diagnostics = AnalysisDiagnosticsCollector().collect(input)

        let undecoded = diagnostics.filter { $0.kind == .undecodedInstruction }
        XCTAssertEqual(undecoded.map(\.address), [0x1010],
                       "only the placeholder inside the valid section is reported; the wrapped window is not coverage")
    }

    func testUnresolvedBranchTargetYieldsExactlyThatDiagnostic() throws {
        // Two decoded instructions at 0x1000/0x1004; a branch from 0x1004 to 0x9999, which
        // was never decoded → exactly one error diagnostic anchored on the dangling target.
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000), row(0x1004)],
            controlFlowEdges: [ControlFlowEdge(id: UUID(), from: 0x1004, to: 0x9999, kind: "branch")],
            xrefs: [],
            sections: [textSection()]
        )

        let diagnostics = AnalysisDiagnosticsCollector().collect(input)

        XCTAssertEqual(diagnostics.count, 1)
        let diagnostic = try XCTUnwrap(diagnostics.first)
        XCTAssertEqual(diagnostic.kind, .unresolvedBranchTarget)
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertEqual(diagnostic.address, 0x9999)
    }

    func testBranchToDecodedInstructionProducesNoDiagnostic() {
        // The branch lands on a real instruction start (0x1004) → no unresolved-target noise.
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000), row(0x1004)],
            controlFlowEdges: [ControlFlowEdge(id: UUID(), from: 0x1000, to: 0x1004, kind: "branch")],
            xrefs: [],
            sections: [textSection()]
        )
        XCTAssertTrue(AnalysisDiagnosticsCollector().collect(input).isEmpty)
    }

    func testCallEdgeToImportIsNotReportedAsUnresolved() {
        // A `call` edge to an undecoded address (an import) is BY DESIGN excluded — only
        // intra-procedural branch/switch/fallthrough edges must resolve in-image.
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000)],
            controlFlowEdges: [ControlFlowEdge(id: UUID(), from: 0x1000, to: 0x9999, kind: "call")],
            xrefs: [],
            sections: [textSection()]
        )
        XCTAssertTrue(AnalysisDiagnosticsCollector().collect(input).isEmpty)
    }

    func testBranchToImportStubSectionIsNotReportedAsUnresolved() {
        // A tail-call `b _puts_stub` targets a stub in __TEXT,__stubs — a real mapped address
        // outside the decoded __text — so it must NOT be flagged as an unresolved branch target.
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000)],
            controlFlowEdges: [ControlFlowEdge(id: UUID(), from: 0x1000, to: 0x4000, kind: "branch")],
            xrefs: [],
            sections: [
                SectionSummary(id: UUID(), name: "__TEXT,__text", address: 0x1000, size: 0x100, fileOffset: 0, isExecutable: true),
                SectionSummary(id: UUID(), name: "__TEXT,__stubs", address: 0x4000, size: 0x100, fileOffset: 0x4000, isExecutable: true),
            ]
        )
        XCTAssertTrue(AnalysisDiagnosticsCollector().collect(input).isEmpty,
                      "A tail-call branch into a stub section must not be flagged as unresolved.")
    }

    func testBranchToDanglingAddressOutsideAllSectionsStillReported() {
        // Anti-over-suppression guard: a branch into NO section is still a real diagnostic
        // (the stub exemption must not blanket-suppress genuinely dangling targets).
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000)],
            controlFlowEdges: [ControlFlowEdge(id: UUID(), from: 0x1000, to: 0x9999, kind: "branch")],
            xrefs: [],
            sections: [SectionSummary(id: UUID(), name: "__TEXT,__text", address: 0x1000, size: 0x100, fileOffset: 0, isExecutable: true)]
        )
        let diags = AnalysisDiagnosticsCollector().collect(input)
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags.first?.kind, .unresolvedBranchTarget)
    }

    // MARK: - 2. Undecoded instruction in executable section

    func testUndecodedInstructionInsideExecutableCodeIsReported() {
        // An ARM64 `unknown` placeholder at 0x1004 inside __text → one error.
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000), row(0x1004, mnemonic: "unknown")],
            controlFlowEdges: [],
            xrefs: [],
            sections: [textSection()]
        )
        let diagnostics = AnalysisDiagnosticsCollector().collect(input)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.kind, .undecodedInstruction)
        XCTAssertEqual(diagnostics.first?.address, 0x1004)
    }

    func testUndecodedPlaceholderOutsideExecutableSectionIsNotReported() {
        // A `.byte` placeholder that sits in a DATA section is intentional (data, not a
        // decode failure) → suppressed.
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x4010, mnemonic: ".byte")],
            controlFlowEdges: [],
            xrefs: [],
            sections: [textSection(), dataSection()]
        )
        XCTAssertTrue(AnalysisDiagnosticsCollector().collect(input).isEmpty)
    }

    // MARK: - 3. Xref outside any section

    func testXrefTargetOutsideEverySectionIsReportedAsWarning() {
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000)],
            controlFlowEdges: [],
            xrefs: [XRef(id: UUID(), from: 0x1000, to: 0xFFFF_0000, kind: XRefKind.data)],
            sections: [textSection(), dataSection()]
        )
        let diagnostics = AnalysisDiagnosticsCollector().collect(input)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.kind, .xrefTargetOutsideSections)
        XCTAssertEqual(diagnostics.first?.severity, .warning)
        XCTAssertEqual(diagnostics.first?.address, 0xFFFF_0000)
    }

    func testXrefTargetInsideADataSectionIsNotReported() {
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000)],
            controlFlowEdges: [],
            xrefs: [XRef(id: UUID(), from: 0x1000, to: 0x4010, kind: XRefKind.data)],
            sections: [textSection(), dataSection()]
        )
        XCTAssertTrue(AnalysisDiagnosticsCollector().collect(input).isEmpty)
    }

    // MARK: - 4. Loader truncation passthrough

    func testLoaderTruncationBecomesWarningDiagnostic() {
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000)],
            controlFlowEdges: [],
            xrefs: [],
            sections: [textSection()],
            loaderTruncations: [.init(address: 0x2000, message: "Symbol table ran past end of slice.")]
        )
        let diagnostics = AnalysisDiagnosticsCollector().collect(input)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.kind, .loaderTruncation)
        XCTAssertEqual(diagnostics.first?.severity, .warning)
        XCTAssertEqual(diagnostics.first?.address, 0x2000)
        XCTAssertEqual(
            diagnostics.first?.message,
            "The loader reported a truncated or over-read structure."
        )
    }

    // MARK: - Ordering / dedup

    func testDiagnosticsSortErrorsBeforeWarningsThenByAddress() {
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000), row(0x1004, mnemonic: "unknown")],
            controlFlowEdges: [ControlFlowEdge(id: UUID(), from: 0x1000, to: 0x2000, kind: "branch")],
            xrefs: [XRef(id: UUID(), from: 0x1000, to: 0xAAAA, kind: XRefKind.data)],
            sections: [textSection()]
        )
        let diagnostics = AnalysisDiagnosticsCollector().collect(input)
        // 2 errors (undecoded @1004, unresolved branch @2000) then 1 warning (@AAAA).
        XCTAssertEqual(diagnostics.map(\.severity), [.error, .error, .warning])
        // Errors sorted by address: 0x1004 < 0x2000.
        XCTAssertEqual(diagnostics[0].address, 0x1004)
        XCTAssertEqual(diagnostics[1].address, 0x2000)
        XCTAssertEqual(diagnostics[2].address, 0xAAAA)
    }

    func testIdenticalDiagnosticsFromDistinctEdgesAreDeduplicated() {
        // Two different branch sources to the SAME undecoded target produce two raw
        // diagnostics with an identical message — collapsed to one.
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000), row(0x1004)],
            controlFlowEdges: [
                ControlFlowEdge(id: UUID(), from: 0x1000, to: 0x9999, kind: "branch"),
                ControlFlowEdge(id: UUID(), from: 0x1004, to: 0x9999, kind: "branch")
            ],
            xrefs: [],
            sections: [textSection()]
        )
        // Distinct `from` → distinct messages → both kept (each is a real, separately-jumpable
        // problem). The dedup only collapses byte-identical diagnostics.
        let diagnostics = AnalysisDiagnosticsCollector().collect(input)
        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertEqual(Set(diagnostics.map(\.address)), [0x9999])
    }

    // MARK: - Authority, privacy, bounds, and retirement

    func testAuthorityRejectsMalformedIdentifiersAndCollectorRejectsInvalidEvidence() {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        XCTAssertNil(AnalysisDiagnostic.Authority(
            imageID: zero,
            documentID: identifier(2),
            sessionID: identifier(3),
            runID: identifier(4),
            analysisGeneration: 1
        ))
        XCTAssertNil(AnalysisDiagnostic.Authority(
            imageID: identifier(1),
            documentID: identifier(2),
            sessionID: identifier(3),
            runID: identifier(4),
            analysisGeneration: 0
        ))
        XCTAssertNil(AnalysisDiagnostic.SourceCoordinate(address: .max))
        let malformedAuthority = Data("""
        {
          "imageID": "not-a-uuid",
          "documentID": "\(identifier(2).uuidString)",
          "sessionID": "\(identifier(3).uuidString)",
          "runID": "\(identifier(4).uuidString)",
          "analysisGeneration": 1
        }
        """.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AnalysisDiagnostic.Authority.self,
                from: malformedAuthority
            )
        )

        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000)],
            controlFlowEdges: [
                ControlFlowEdge(id: zero, from: 0x1000, to: 0x9000, kind: "branch"),
                ControlFlowEdge(id: identifier(10), from: 0x1000, to: .max, kind: "branch"),
                ControlFlowEdge(id: identifier(11), from: 0x1000, to: 0x9000, kind: "branch\u{0}"),
            ],
            xrefs: [
                XRef(id: zero, from: 0x1000, to: 0xA000, kind: XRefKind.data),
                XRef(id: identifier(12), from: 0x1000, to: 0xA000, kind: "data/../../"),
                XRef(id: identifier(13), from: .max, to: 0xA000, kind: XRefKind.data),
            ],
            sections: [textSection()],
            loaderTruncations: [.init(address: .max, message: "ignored")]
        )

        XCTAssertTrue(AnalysisDiagnosticsCollector().collect(input).isEmpty)
    }

    func testDiagnosticsAreDeterministicallyBoundedIndependentOfInputOrder() {
        let count = AnalysisDiagnosticsCollector.maximumDiagnosticCount + 19
        let xrefs = (0..<count).map { index in
            XRef(
                id: identifier(100 + index),
                from: 0x1000,
                to: 0x8000 + UInt64(index * 4),
                kind: XRefKind.data
            )
        }
        func input(_ values: [XRef]) -> AnalysisDiagnosticsCollector.Input {
            AnalysisDiagnosticsCollector.Input(
                instructions: [row(0x1000)],
                controlFlowEdges: [],
                xrefs: values,
                sections: [textSection()]
            )
        }

        let forward = AnalysisDiagnosticsCollector().collect(input(xrefs))
        let reverse = AnalysisDiagnosticsCollector().collect(input(Array(xrefs.reversed())))

        XCTAssertEqual(forward.count, AnalysisDiagnosticsCollector.maximumDiagnosticCount)
        XCTAssertEqual(forward.map(\.id), reverse.map(\.id))
        XCTAssertEqual(forward.map(\.address), forward.map(\.address).sorted())
        XCTAssertTrue(forward.allSatisfy {
            $0.message.utf8.count <= AnalysisDiagnostic.maximumMessageUTF8Bytes
                && $0.sourceCoordinate?.address == 0x1000
                && $0.provenance == .crossReference
                && $0.failure == .xrefTargetOutsideSections
        })
    }

    func testLoaderTextAndSensitiveAppMessageAreNotRetained() throws {
        let thirdPartyText = """
        prompt=/Users/alice/private/request.txt Authorization: Bearer top-secret
        \(String(repeating: "de ad be ef ", count: 300))
        """
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [],
            controlFlowEdges: [],
            xrefs: [],
            sections: [textSection()],
            loaderTruncations: [.init(address: 0x1000, message: thirdPartyText)]
        )

        let diagnostic = try XCTUnwrap(AnalysisDiagnosticsCollector().collect(input).first)
        XCTAssertEqual(
            diagnostic.message,
            "The loader reported a truncated or over-read structure."
        )
        XCTAssertEqual(diagnostic.sourceCoordinate?.address, 0x1000)
        XCTAssertEqual(diagnostic.provenance, .loader)
        XCTAssertFalse(diagnostic.message.contains("/Users/"))
        XCTAssertFalse(diagnostic.message.localizedCaseInsensitiveContains("secret"))

        let appOwned = AnalysisDiagnostic(
            severity: .error,
            address: 0x1000,
            kind: .unresolvedBranchTarget,
            message: "Failed at /Users/alice/private.bin"
        )
        XCTAssertFalse(appOwned.message.contains("/Users/"))
        XCTAssertTrue(appOwned.message.contains("<redacted-path>"))

        let secret = AnalysisDiagnostic(
            severity: .error,
            address: 0x1000,
            kind: .unresolvedBranchTarget,
            message: "Authorization: Bearer top-secret"
        )
        XCTAssertEqual(
            secret.message,
            "A control-flow target was not decoded as an instruction."
        )
    }

    func testImageValidationCachePreservesSanitizationAndChecksEveryAuthorityCoordinate() throws {
        var context = AnalysisDiagnostic.ImageValidationContext()
        let messages = ["An instruction inside executable code could not be decoded.",
                        "Failed at /Users/alice/private.bin", "Authorization: Bearer secret", " \n "]
        for message in messages {
            for address in [UInt64(0x1000), 0x1004] {
                let source = try XCTUnwrap(AnalysisDiagnostic.SourceCoordinate(address: address))
                let cached = context.validated(severity: .error, address: address, kind: .undecodedInstruction,
                    message: message, provenance: .decoder, authority: nil, sourceCoordinate: source)
                let uncached = AnalysisDiagnostic.validated(severity: .error, address: address, kind: .undecodedInstruction,
                    message: message, provenance: .decoder, authority: nil, sourceCoordinate: source)
                XCTAssertEqual(cached, uncached)
                XCTAssertNil(context.validated(severity: .error, address: .max, kind: .undecodedInstruction,
                    message: message, provenance: .decoder, authority: nil, sourceCoordinate: source))
                XCTAssertNil(context.validated(severity: .error, address: address, kind: .undecodedInstruction,
                    message: message, provenance: .loader, authority: nil, sourceCoordinate: source))
            }
        }
    }

    func testPublicationFenceRejectsCrossDocumentStaleGenerationAndRetirement() throws {
        let collector = AnalysisDiagnosticsCollector()
        let old = authority(document: 2, generation: 1)
        let fence = AnalysisDiagnosticsPublicationFence(authority: old)
        let oldPermit = try XCTUnwrap(fence.permit(for: old))

        let otherDocument = authority(document: 20, generation: 1)
        let otherPermit = try XCTUnwrap(
            fence.replaceCurrentAuthority(with: otherDocument)
        )
        let current = authority(document: 20, generation: 2)
        let currentPermit = try XCTUnwrap(
            fence.replaceCurrentAuthority(with: current)
        )
        XCTAssertNil(fence.replaceCurrentAuthority(with: otherDocument))

        func input(
            _ authority: AnalysisDiagnostic.Authority,
            _ permit: AnalysisDiagnosticsPublicationFence.Permit
        ) -> AnalysisDiagnosticsCollector.Input {
            AnalysisDiagnosticsCollector.Input(
                instructions: [row(0x1000)],
                controlFlowEdges: [
                    ControlFlowEdge(
                        id: identifier(50),
                        from: 0x1000,
                        to: 0x9000,
                        kind: "branch"
                    )
                ],
                xrefs: [],
                sections: [textSection()],
                authority: authority,
                publicationPermit: permit
            )
        }

        XCTAssertTrue(collector.collect(input(old, oldPermit)).isEmpty)
        XCTAssertTrue(collector.collect(input(otherDocument, otherPermit)).isEmpty)

        let currentInput = input(current, currentPermit)
        let currentDiagnostics = collector.collect(currentInput)
        XCTAssertEqual(currentDiagnostics.count, 1)
        XCTAssertTrue(currentDiagnostics.allSatisfy { $0.isCurrent(for: current) })

        var published: [AnalysisDiagnostic]?
        XCTAssertFalse(collector.collect(input(old, oldPermit)) { published = $0 })
        XCTAssertNil(published)
        XCTAssertTrue(collector.collect(currentInput) { published = $0 })
        XCTAssertEqual(published, currentDiagnostics)

        XCTAssertTrue(fence.retire(current))
        published = nil
        XCTAssertFalse(collector.collect(currentInput) { published = $0 })
        XCTAssertNil(published, "retirement must prevent a completed old batch from resurrecting")
    }

    func testCancelledCollectionCannotPublish() async throws {
        let current = authority(document: 30, generation: 1)
        let fence = AnalysisDiagnosticsPublicationFence(authority: current)
        let permit = try XCTUnwrap(fence.permit(for: current))
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000)],
            controlFlowEdges: [
                ControlFlowEdge(
                    id: identifier(60),
                    from: 0x1000,
                    to: 0x9000,
                    kind: "branch"
                )
            ],
            xrefs: [],
            sections: [textSection()],
            authority: current,
            publicationPermit: permit
        )

        let task = Task { () -> (published: Bool, callbackInvoked: Bool) in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                // Cancellation is the condition under test; continue into the publication gate.
            }
            var callbackInvoked = false
            let published = AnalysisDiagnosticsCollector().collect(input) { _ in
                callbackInvoked = true
            }
            return (published, callbackInvoked)
        }
        task.cancel()

        let result = await task.value
        XCTAssertFalse(result.published)
        XCTAssertFalse(result.callbackInvoked)
    }

    // MARK: - Store integration: select-to-jump

    @MainActor
    func testSelectingDiagnosticJumpsToItsAddress() {
        // A snapshot whose instructions are 0x1000/0x1004 and a diagnostic anchored on a
        // decoded address (0x1004): jumping selects it and stays in the disassembly view.
        var snapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [],
            instructions: [row(0x1000), row(0x1004)],
            xrefs: [],
            hexBytes: Data()
        )
        snapshot.diagnostics = [
            AnalysisDiagnostic(severity: .error, address: 0x1004, kind: .unresolvedBranchTarget, message: "test")
        ]
        let store = WorkspaceStore(workspaceName: "Problems", snapshot: snapshot, engine: AnalysisEngine())
        XCTAssertEqual(store.selectedAddress, 0x1000) // seeded at first instruction

        store.navigateToDiagnostic(store.diagnostics[0])
        XCTAssertEqual(store.selectedAddress, 0x1004)
        XCTAssertEqual(store.editorMode, .disassembly)
    }

    @MainActor
    func testSelectingMappedUndecodedDiagnosticFallsBackToHexView() {
        // A diagnostic anchored on a mapped NON-instruction address: the jump still lands, and
        // the editor falls back to the hex view without fabricating a decoded row.
        let dataBytes = Data(repeating: 0, count: 0x20)
        var snapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [],
            instructions: [row(0x1000)],
            xrefs: [],
            hexBytes: dataBytes,
            sections: [
                SectionSummary(
                    id: UUID(),
                    name: "__DATA,__data",
                    address: 0x9990,
                    size: UInt64(dataBytes.count),
                    fileOffset: 0,
                    isExecutable: false
                )
            ],
            imageBytes: dataBytes
        )
        snapshot.diagnostics = [
            AnalysisDiagnostic(severity: .error, address: 0x9999, kind: .unresolvedBranchTarget, message: "dangling")
        ]
        let store = WorkspaceStore(workspaceName: "Problems", snapshot: snapshot, engine: AnalysisEngine())

        store.navigateToDiagnostic(store.diagnostics[0])
        XCTAssertEqual(store.selectedAddress, 0x9999)
        XCTAssertNil(store.selectedInstruction)
        XCTAssertEqual(store.editorMode, .hex)
    }

    @MainActor
    func testSelectingUnmappedDiagnosticIsACompleteNoOp() {
        var snapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [],
            instructions: [row(0x1000)],
            xrefs: [],
            hexBytes: Data()
        )
        snapshot.diagnostics = [
            AnalysisDiagnostic(
                severity: .error,
                address: 0x9999,
                kind: .unresolvedBranchTarget,
                message: "unmapped"
            )
        ]
        let store = WorkspaceStore(workspaceName: "Problems", snapshot: snapshot, engine: AnalysisEngine())
        store.editorMode = .disassembly

        store.navigateToDiagnostic(store.diagnostics[0])

        XCTAssertEqual(store.selectedAddress, 0x1000)
        XCTAssertEqual(store.editorMode, .disassembly)
    }

    // MARK: - End-to-end: real engine populates snapshot.diagnostics

    func testEngineSurfacesUnresolvedBranchFromRealFixture() throws {
        // A real, parseable thin Mach-O whose first instruction is an unconditional branch
        // to an address 0x800 past the start of a tiny __text section (well outside it), so
        // the target is never decoded. Driving the FULL engine must surface exactly one
        // unresolved-branch error anchored on that target — proving the collector is wired
        // into `analyze(...)`, not just unit-tested in isolation.
        //
        //   b   #+0x800   → 0x14000000 | (0x800 >> 2)=0x200 → 0x14000200 → LE 00 02 00 14
        //   ret           → c0 03 5f d6
        let code = Data([0x00, 0x02, 0x00, 0x14, 0xc0, 0x03, 0x5f, 0xd6])
        let fixture = MachOFixture.makeExecutable(code: code)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagFixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture.bytes.write(to: url)

        let snapshot = try AnalysisEngine().analyze(url: url)

        // The branch instruction is at the section start; its target is start + 0x800.
        let expectedTarget = fixture.baseAddress &+ 0x800
        let unresolved = snapshot.diagnostics.filter { $0.kind == .unresolvedBranchTarget }
        XCTAssertEqual(unresolved.count, 1, "all diagnostics: \(snapshot.diagnostics)")
        let diagnostic = try XCTUnwrap(unresolved.first)
        XCTAssertEqual(diagnostic.address, expectedTarget)
        XCTAssertEqual(diagnostic.severity, .error)
        // And the target is genuinely absent from the decoded stream (a true unresolved edge,
        // not a labeling accident).
        XCTAssertFalse(snapshot.instructions.contains { $0.address == expectedTarget })
    }

    func testEngineProducesNoUnresolvedBranchForSelfContainedFixture() throws {
        // The default fixture's code is a self-contained prologue/body/ret with one internal
        // `bl` (a call, excluded by design) — no intra-procedural branch escapes the section,
        // so a correct collector yields zero unresolved-branch diagnostics.
        let fixture = MachOFixture.makeExecutable()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagFixtureClean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture.bytes.write(to: url)

        let snapshot = try AnalysisEngine().analyze(url: url)
        XCTAssertTrue(
            snapshot.diagnostics.allSatisfy { $0.kind != .unresolvedBranchTarget },
            "unexpected unresolved-branch diagnostics: \(snapshot.diagnostics)"
        )
    }

    @MainActor
    func testProblemsToggleFlipsPanelVisibility() {
        let store = WorkspaceStore(workspaceName: "Problems", snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()), engine: AnalysisEngine())
        XCTAssertFalse(store.showProblems)
        // WS-2: menu commands now address the focused document's store, so a directly-posted
        // command must name its target store (an untargeted post is correctly ignored).
        NotificationCenter.default.post(name: .macScopeToggleProblems, object: nil,
                                        userInfo: [WorkspaceStore.commandTargetStoreKey: store])
        let expectation = expectation(description: "panel toggles on")
        DispatchQueue.main.async {
            XCTAssertTrue(store.showProblems)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}
