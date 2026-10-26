import AppKit
import Foundation
import XCTest
@testable import MacScope

@MainActor
final class PatternPanelTests: XCTestCase {
    func testOverlayPositive() throws {
        let store = makeStore(patchAddress: 0x1006)
        let frame = PatternPaneFrame.read(store)
        let capture = try PatternAppCapture(frame: frame, record: 4..<16,
                                           source: "u16 field @ 2;", sourceIdentity: "user-text")
        XCTAssertEqual(frame.bytes[6], 0xAB)
        XCTAssertEqual(frame.patchedOffsets, [6])
        XCTAssertEqual(capture.request.bytes[2], 0xAB)
        XCTAssertEqual(PatternPanel.capturedBytesLabel, "Captured rendered bytes")
    }
    func testOverlayNegative() throws {
        let store = makeStore(patchAddress: 0x9000)
        XCTAssertThrowsError(try BytePatchOverlay(patches: store.snapshot.patches(in: .primary),
                                                mappings: store.snapshot.imageByteMappings(in: .primary)))
        let frame = PatternPaneFrame.read(store)
        let capture = try PatternAppCapture(frame: frame, record: 4..<16,
                                           source: "u16 field @ 2;", sourceIdentity: "user-text")
        XCTAssertEqual(frame.bytes, Data((0..<32).map(UInt8.init)))
        XCTAssertTrue(frame.patchedOffsets.isEmpty)
        XCTAssertEqual(capture.request.bytes, Data((4..<16).map(UInt8.init)))
        XCTAssertEqual(PatternPanel.capturedBytesLabel, "Captured rendered bytes")
    }
    func testSpecimensPositive() throws {
        for (entry, resource, expected) in specimens {
            var requested: [String] = []
            let source = try PatternSourceCatalog.source(for: entry, userText: "ignored") { name in
                requested.append(name); return Data(expected.utf8)
            }
            XCTAssertEqual(requested, [resource])
            XCTAssertEqual(source, expected)
            XCTAssertEqual(try PatternSourceCatalog.source(for: entry, userText: "ignored", bundle: .main), expected)
            XCTAssertEqual(entry.id, entry.rawValue)
        }
        let text = String(repeating: "a", count: 32_768)
        XCTAssertEqual(try PatternSourceCatalog.source(for: .userText, userText: text) { _ in
            XCTFail("User text must not access resources"); return nil
        }, text)
    }
    func testSpecimensNegative() {
        for (entry, _, _) in specimens {
            XCTAssertThrowsError(try PatternSourceCatalog.source(for: entry, userText: "fallback") { _ in nil }) {
                guard case PatternInterpretationError.nativeUnavailable = $0 else {
                    return XCTFail("Missing resource must be unavailable")
                }
            }
        }
        for text in [String(repeating: "a", count: 32_769), String(repeating: "é", count: 16_385)] {
            XCTAssertThrowsError(try PatternSourceCatalog.source(for: .userText, userText: text) { _ in nil }) {
                guard case PatternInterpretationError.invalidRequest = $0 else {
                    return XCTFail("Oversized UTF-8 must be refused")
                }
            }
        }
    }
    func testTreeAndValidationPositive() throws {
        let fixture = PatternAppTestFixture()
        let capture = try fixture.begin()
        var reply = PatternAppTestFixture.reply(capture.request)
        reply.status = .partial
        var array = reply.nodes[0]
        array.kind = .array; array.childCount = 1; array.childrenTruncated = true
        var bits = array
        bits.id = 2; bits.parentID = 1; bits.depth = 1; bits.kind = .bitfieldField
        bits.childCount = 0; bits.childrenTruncated = false
        bits.bits = .init(offsetWithinFirstByte: 7, count: 2, numbering: .msb0)
        var unsupported = array
        unsupported.id = 3; unsupported.kind = .unsupported; unsupported.backing = .unsupported
        unsupported.ranges = []; unsupported.childCount = 0; unsupported.childrenTruncated = false
        reply.nodes = [array, bits, unsupported]
        fixture.owner.accept(data: try JSONEncoder().encode(reply), requestID: capture.request.requestID,
                             generation: fixture.owner.generation)
        XCTAssertEqual(fixture.owner.phase, .partial)
        XCTAssertEqual(fixture.nodes.count, 3)
        XCTAssertFalse(PatternPanel.visible(bits, nodes: fixture.nodes, expanded: []))
        XCTAssertTrue(PatternPanel.visible(bits, nodes: fixture.nodes, expanded: [1]))
        XCTAssertTrue(PatternPanel.detail(for: array).contains("truncated"))
        XCTAssertTrue(PatternPanel.detail(for: bits).contains("bits 7 + 2, msb0"))
        XCTAssertTrue(fixture.owner.canReveal(fieldID: 2, generation: fixture.owner.generation))
        XCTAssertFalse(fixture.owner.canReveal(fieldID: 3, generation: fixture.owner.generation))
    }
    func testTreeAndValidationNegative() throws {
        for variant in 0..<6 {
            let fixture = PatternAppTestFixture()
            let capture = try fixture.begin()
            var reply = PatternAppTestFixture.reply(capture.request)
            if variant == 0 {
                reply.nodes.append(reply.nodes[0])
            } else if variant == 1 {
                var child = reply.nodes[0]
                child.id = 2; child.parentID = 1; child.depth = 1
                reply.nodes[0].childCount = 1
                reply.nodes.append(child)
            } else {
                reply.status = .partial
                reply.nodes[0].kind = .unsupported
                reply.nodes[0].backing = [PatternField.Backing.file, .synthetic, .empty, .outOfRange][variant - 2]
                if variant != 2 { reply.nodes[0].ranges = [] }
                if variant == 3 { reply.nodes[0].sectionID = 1 }
                if variant == 4 { reply.nodes[0].declaredSize = 0 }
                if variant == 5 { reply.nodes[0].patternOffset = 20 }
            }
            fixture.owner.accept(data: try JSONEncoder().encode(reply), requestID: capture.request.requestID,
                                 generation: fixture.owner.generation)
            XCTAssertEqual(fixture.owner.phase, .refused)
            XCTAssertTrue(fixture.nodes.isEmpty)
            XCTAssertNil(fixture.reveal())
        }
    }
    func testRevealIdentityPositive() throws {
        let fixture = PatternAppTestFixture()
        fixture.patchedOffsets = [6]
        try fixture.publish()
        let view = EditableHexTextView()
        let model = HexEditModel(bytes: fixture.bytes, mappings: fixture.mappings)
        var scrolls: [NSRange] = []
        var edits = 0
        var moves = 0
        view.onPatternRevealScroll = { scrolls.append($0) }
        view.onByteEdit = { _, _ in edits += 1; return false }
        view.onCaretMove = { _, _ in moves += 1; return false }
        view.render(model: model, editable: false, patchedOffsets: fixture.patchedOffsets)
        let selection = view.selectedRange()
        XCTAssertEqual(fixture.reveal(), 6..<8)
        let first = try XCTUnwrap(fixture.owner.revealCommand)
        view.render(model: model, editable: false, patchedOffsets: fixture.patchedOffsets, patternReveal: first)
        XCTAssertEqual(fixture.reveal(), 6..<8)
        let second = try XCTUnwrap(fixture.owner.revealCommand)
        XCTAssertNotEqual(first.token, second.token)
        view.render(model: model, editable: false, patchedOffsets: fixture.patchedOffsets, patternReveal: second)
        view.render(model: model, editable: false, patchedOffsets: fixture.patchedOffsets, patternReveal: second)
        XCTAssertEqual(scrolls.count, 2)
        let firstCell = try XCTUnwrap(EditableHexTextView.characterRange(forOffset: 6, bytesPerRow: 16))
        XCTAssertEqual(scrolls, [firstCell, firstCell])
        for offset in 6..<8 {
            let cell = try XCTUnwrap(EditableHexTextView.characterRange(forOffset: offset, bytesPerRow: 16))
            XCTAssertNotNil(view.textStorage?.attribute(.underlineStyle, at: cell.location, effectiveRange: nil))
        }
        XCTAssertNotNil(view.textStorage?.attribute(.backgroundColor, at: firstCell.location, effectiveRange: nil))
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(edits, 0); XCTAssertEqual(moves, 0)
        XCTAssertEqual(fixture.patchedOffsets, [6])
    }
    func testRevealIdentityNegative() throws {
        let fixture = PatternAppTestFixture()
        try fixture.publish()
        _ = fixture.reveal()
        let view = EditableHexTextView()
        let legacy = EditableHexTextView()
        let model = HexEditModel(bytes: fixture.bytes, mappings: fixture.mappings)
        var scrolls = 0
        view.onPatternRevealScroll = { _ in scrolls += 1 }
        view.render(model: model, editable: false, patternReveal: fixture.owner.revealCommand)
        fixture.owner.invalidate()
        XCTAssertNil(fixture.owner.revealCommand)
        view.render(model: model, editable: false, patternReveal: nil)
        legacy.render(model: model, editable: false)
        XCTAssertEqual(scrolls, 1)
        XCTAssertEqual(view.attributedString(), legacy.attributedString())
        XCTAssertEqual(view.selectedRange(), legacy.selectedRange())
        let unavailable = PatternInterpretationOwner(live: { (fixture.frame, fixture.record, fixture.source, fixture.sourceIdentity) })
        unavailable.start(capture: try fixture.capture())
        XCTAssertEqual(unavailable.phase, .unavailable)
        XCTAssertNil(unavailable.reveal(fieldID: 1, generation: unavailable.generation))
        XCTAssertEqual(fixture.transport.sends, 0)
    }

    private func makeStore(patchAddress: UInt64) -> WorkspaceStore {
        let bytes = Data((0..<32).map(UInt8.init))
        var snapshot = WorkspaceSnapshot(
            binaries: [.init(id: UUID(), name: "pattern fixture", path: "", kind: "fixture", architecture: "arm64")],
            functions: [], instructions: [], xrefs: [], hexBytes: bytes,
            sections: [.init(id: UUID(), name: "__data", address: 0x1000, size: 32, fileOffset: 0, isExecutable: false)],
            imageBytes: bytes)
        snapshot.addressOverrides[ImageAddress(slot: .primary, address: patchAddress)] = .init(patch: .init(bytes: [0xAB]))
        return WorkspaceStore(workspaceName: "pattern fixture", snapshot: snapshot,
                              engine: AnalysisEngine(), autosaveScheduler: nil)
    }
    private var specimens: [(PatternSourceCatalog.Entry, String, String)] { [
        (.pngIHDR, "png_ihdr", """
        // SPDX-License-Identifier: GPL-2.0-only
        // Narrow adaptation of the IHDR record/enums in WerWolv/ImHex-Patterns,
        // patterns/png.hexpat at e07e98adc810f0c052035ee1fdabae7ec65110e2.
        // Upstream notice/license and exact source are in pattern_context.
        // The adapter accepts this flattened, self-contained prefix only.
        // This interprets 33 bytes; it does not validate PNG CRCs or decode an image.
        enum PNGColorType : u8 {
            Grayscale = 0,
            RGBTriple = 2,
            Palette = 3,
            GrayscaleAlpha = 4,
            RGBA = 6
        };
        enum PNGInterlacing : u8 {
            None = 0,
            Adam7 = 1
        };
        struct IHDR {
            be u32 width;
            be u32 height;
            u8 bit_depth;
            PNGColorType color_type;
            u8 compression_method;
            u8 filter_method;
            PNGInterlacing interlacing;
        };
        struct PNGPrefix {
            u8 signature[8];
            be u32 length;
            u8 chunk_type[4];
            IHDR ihdr;
            be u32 crc;
        };
        PNGPrefix png @ 0;
        
        
        """),
        (.nestedRecord, "nested_record", """
        // MacScope-owned fixture: 12 bytes; little-endian unless a field says otherwise.
        enum RecordKind : u8 {
            small = 1,
            large = 2
        };
        struct Header {
            u8 magic[2];
            RecordKind kind;
            u8 version;
        };
        bitfield Flags {
            enabled : 1;
            mode : 3;
            reserved : 4;
        };
        struct Sample {
            u16 value;
            Flags flags;
        };
        struct Packet {
            Header header;
            Sample samples[2];
            u16 trailer;
        };
        Packet packet @ 0;
        
        
        """),
        (.crossByteBits, "cross_byte_bits", """
        // MacScope-owned two-byte fixture; bit 0 denotes the first MSB in this record.
        bitfield CrossBits {
            a : 3;
            b : 10;
            c : 3;
        };
        be CrossBits cross @ 0;
        
        
        """),
        (.synthetic, "synthetic", """
        // Local exported values are not byte ranges, even though their patterns may
        // also appear in the runtime's main-section root list.
        u32 computed = 42 [[export]];
        u8 first @ 0;
        
        
        """),
    ] }
}
