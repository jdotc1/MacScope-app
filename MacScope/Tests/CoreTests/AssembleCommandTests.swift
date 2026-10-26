import XCTest
@testable import MacScope

/// T042 (store core) — assembling ARM64 text at an address encodes the instruction with the
/// existing `ARM64Assembler` and applies it as a reversible 4-byte patch through the proven
/// patch model. An unencodable instruction surfaces a precise issue and applies nothing
/// (non-destructive). The File ▸ Assemble Instruction… command will drive this method.
@MainActor
final class AssembleCommandTests: XCTestCase {

    /// `nop` encodes to `1f 20 03 d5` (`0xd503201f`) — exactly the canonical ARM64 NOP — and
    /// lands as a byte patch at the target address, the reversible/re-analyzed patch path.
    func testAssembleEncodesAndAppliesPatch() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00000 as UInt64

        XCTAssertTrue(store.assemble(at: address, text: "nop"))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.patch, BytePatch.arm64NOP)
        XCTAssertNil(store.lastIssue)
    }

    /// An unknown mnemonic must NOT mutate the document — it surfaces the assembler's
    /// precise diagnostic and leaves the address unpatched.
    func testAssembleRejectsUnencodableInstructionNonDestructively() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00000 as UInt64

        XCTAssertFalse(store.assemble(at: address, text: "frobnicate x0, x1"))
        XCTAssertNotNil(store.lastIssue)
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)]?.patch)
    }

    /// Routing: the typed `assembleInstruction` command opens the Assemble sheet for the
    /// selected instruction (mirrors Patch Bytes), so it is reachable through the menu and
    /// guarded by `WorkspaceCommandRoutingTests`' distinct-entry-point/effect checks.
    func testAssembleInstructionCommandPresentsSheet() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectInstruction(0x1000_00000)
        XCTAssertNil(store.pendingAssembleRequest)
        store.perform(.assembleInstruction)
        XCTAssertEqual(store.pendingAssembleRequest?.address, 0x1000_00000)
    }

    // MARK: - Architecture-appropriate assembly

    /// Builds a store over an x86_64 instruction so the exact-owner assemble path must route to
    /// the `X86_64Assembler` rather than the ARM64 one.
    private func makeX86Store() -> WorkspaceStore {
        let address = 0x1_0000 as UInt64
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(
                id: UUID(),
                name: "x86-target",
                path: "/x86-target",
                kind: "Executable",
                architecture: "x86_64"
            )],
            functions: [],
            instructions: [
                InstructionRow(
                    address: address,
                    bytes: "90",
                    mnemonic: "nop",
                    operands: "",
                    hasBreakpoint: false,
                    comment: nil
                )
            ],
            xrefs: [],
            hexBytes: Data()
        )
        return WorkspaceStore(workspaceName: "x86", snapshot: snapshot, engine: AnalysisEngine())
    }

    /// On an x86_64 target, `nop` must encode to the x86 single-byte NOP `0x90` — proving the
    /// assemble authoring path selects the architecture-appropriate assembler. (On ARM64 the
    /// same mnemonic encodes to the 4-byte `1f 20 03 d5`, so this discriminates the routing.)
    func testAssembleRoutesToX86AssemblerForX86Target() {
        let store = makeX86Store()
        let address = 0x1_0000 as UInt64

        XCTAssertTrue(store.assemble(at: address, text: "nop"))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.patch?.bytes, [0x90])
        XCTAssertNil(store.lastIssue)
    }

    /// A second x86-only encoding (`ret` → `0xc3`) that the ARM64 assembler would encode to a
    /// different 4-byte value — a stronger guard that x86 text is genuinely routed to the x86
    /// encoder and not merely coincidentally matching.
    func testAssembleEncodesX86RetForX86Target() {
        let store = makeX86Store()
        let address = 0x1_0000 as UInt64

        XCTAssertTrue(store.assemble(at: address, text: "ret"))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.patch?.bytes, [0xc3])
        XCTAssertNil(store.lastIssue)
    }

    /// The ARM64 default is preserved: a store with no x86_64 target still uses the ARM64
    /// assembler (`nop` → `1f 20 03 d5`), so the routing change can't regress the ARM64 path.
    func testAssembleKeepsARM64ForARM64Target() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00000 as UInt64

        XCTAssertTrue(store.assemble(at: address, text: "nop"))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.patch, BytePatch.arm64NOP)
    }

    /// A MacScope-unsupported instruction family reaches the reviewed source fallback through the
    /// real store path and still lands only after the router's round-trip and independent decode.
    func testAssembleUsesVerifiedFallbackForUnsupportedARM64Family() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00000 as UInt64

        XCTAssertTrue(store.assemble(at: address, text: "gmi x0, x1, x2"))
        XCTAssertEqual(
            store.snapshot.addressOverrides[.primary(address)]?.patch?.bytes,
            [0x20, 0x14, 0xc2, 0x9a]
        )
        XCTAssertNil(store.lastIssue)
    }
}
