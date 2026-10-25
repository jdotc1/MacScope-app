import SwiftUI
import XCTest
import LumenTokens
@testable import LumenUI

@MainActor
final class LumenSnapshotTests: XCTestCase {
    private let size = CGSize(width: 320, height: 44)
    private let standardLight = LumenSnapshot.Variant(themeID: LumenThemes.standardID, colorScheme: .light)
    private let midnightDark = LumenSnapshot.Variant(themeID: LumenThemes.midnightID, colorScheme: .dark)

    private var badges: some View {
        HStack(spacing: 6) {
            LumenBadge("Signed", systemImage: "checkmark.seal.fill", tone: .success)
            LumenBadge("3 warnings", tone: .warning)
            LumenBadge("v2", monospaced: true)
        }
    }

    func testRenderingIsRepeatableAndThemesDiffer() throws {
        let first = try XCTUnwrap(LumenSnapshot.png(of: badges, size: size, variant: standardLight, registry: TestPack.registry))
        let second = try XCTUnwrap(LumenSnapshot.png(of: badges, size: size, variant: standardLight, registry: TestPack.registry))
        let same = LumenSnapshot.compare(first, second)
        XCTAssertFalse(same.sizeMismatch)
        XCTAssertEqual(same.differingPixelFraction, 0, "\(same)")

        let other = try XCTUnwrap(LumenSnapshot.png(of: badges, size: size, variant: midnightDark, registry: TestPack.registry))
        let different = LumenSnapshot.compare(first, other)
        XCTAssertGreaterThan(different.differingPixelFraction, 0.5, "Another theme repaints the canvas: \(different)")
    }

    func testVerifyRecordsAsAFailureThenMatches() throws {
        let goldens = try temporaryFolder()
        let recorded = LumenSnapshot.verify(badges, named: "badges", size: size, variant: midnightDark,
                                            registry: TestPack.registry, goldenDirectory: goldens, record: true)
        guard case .recorded(let url) = recorded else { return XCTFail("Expected a recording, got \(recorded)") }
        XCTAssertEqual(url.lastPathComponent, "badges@midnight-dark.png")
        XCTAssertNotNil(recorded.failureMessage, "Recording is never a pass")

        let verified = LumenSnapshot.verify(badges, named: "badges", size: size, variant: midnightDark,
                                            registry: TestPack.registry, goldenDirectory: goldens, record: false)
        XCTAssertNil(verified.failureMessage, "\(verified)")

        let missing = LumenSnapshot.verify(badges, named: "badges", size: size, variant: standardLight,
                                           registry: TestPack.registry, goldenDirectory: goldens, record: false)
        guard case .missingGolden = missing else { return XCTFail("Expected a missing golden, got \(missing)") }

        try FileManager.default.copyItem(at: url, to: goldens.appending(path: "badges@standard-light.png"))
        let mismatched = LumenSnapshot.verify(badges, named: "badges", size: size, variant: standardLight,
                                              registry: TestPack.registry, goldenDirectory: goldens, record: false)
        guard case .mismatched = mismatched else { return XCTFail("Expected a mismatch, got \(mismatched)") }
    }

    /// A control that vanishes is a small share of a large golden (0.09% here, under the 0.5%
    /// whole-image tolerance) but a dense patch of change: that fails.
    func testAVanishedControlFailsAlthoughFewPixelsDiffer() throws {
        let goldens = try temporaryFolder()
        let size = CGSize(width: 740, height: 344)
        func screen(_ control: Bool) -> some View {
            ZStack(alignment: .topLeading) {
                Color.clear
                if control { Color.black.frame(width: 15, height: 15).offset(x: 101, y: 63) }
            }
        }
        _ = LumenSnapshot.verify(screen(true), named: "control", size: size, variant: standardLight,
                                 registry: TestPack.registry, goldenDirectory: goldens, record: true)
        let gone = LumenSnapshot.verify(screen(false), named: "control", size: size, variant: standardLight,
                                        registry: TestPack.registry, goldenDirectory: goldens, record: false)
        guard case .mismatched(let difference) = gone else { return XCTFail("A vanished control passed: \(gone)") }
        XCTAssertLessThan(difference.differingPixelFraction, 0.005, "\(difference)")
        XCTAssertGreaterThan(difference.densestPatchFraction, LumenSnapshot.patchTolerance, "\(difference)")
        // The view as recorded still matches.
        XCTAssertNil(LumenSnapshot.verify(screen(true), named: "control", size: size, variant: standardLight,
                                          registry: TestPack.registry, goldenDirectory: goldens, record: false).failureMessage)
    }

    func testPerSurfaceThemesRenderThroughTheSurface() throws {
        // A keyword chip drawn in the editor surface, the way an app's code view would be.
        struct KeywordChip: View {
            @Environment(\.lumenPalette) private var palette
            var body: some View {
                Text("func").font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette[TestPack.keyword])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette[.bgInset])
            }
        }
        let window = LumenSnapshot.Variant(themeID: LumenThemes.standardID, colorScheme: .dark)
        let split = LumenSnapshot.Variant(themeID: LumenThemes.standardID, colorScheme: .dark,
                                          surfaceThemeIDs: [TestPack.editor: LumenThemes.midnightID])
        XCTAssertEqual(split.label, "standard-dark+midnight-editor")
        let a = try XCTUnwrap(LumenSnapshot.png(of: KeywordChip(), size: CGSize(width: 80, height: 40), variant: window, registry: TestPack.registry))
        let b = try XCTUnwrap(LumenSnapshot.png(of: KeywordChip(), size: CGSize(width: 80, height: 40), variant: split, registry: TestPack.registry))
        let difference = LumenSnapshot.compare(a, b)
        XCTAssertGreaterThan(difference.differingPixelFraction, 0, "The keyword takes the editor theme's color")
        XCTAssertLessThan(difference.differingPixelFraction, 0.5, "Window roles (the inset ground) don't change")
    }

    func testSnapshotRenderingNeverChangesTheActiveStore() {
        let before = LumenThemeStore.active
        let selection = before.theme().id
        _ = LumenSnapshot.png(of: badges, size: size, variant: midnightDark, registry: TestPack.registry)
        XCTAssertTrue(LumenThemeStore.active === before, "The scoped override is removed afterwards")
        XCTAssertEqual(before.theme().id, selection)
    }

    func testMiniaturesDrawEachThemesOwnColors() throws {
        let slate = try LumenThemeLibrary.decodeTheme(Data(contentsOf: TestPack.darkSidebarURL)).flattened { TestPack.registry.theme(id: $0) }
        let standard = try XCTUnwrap(TestPack.registry.theme(id: LumenThemes.standardID))
        func render(_ theme: LumenTheme) throws -> Data {
            try XCTUnwrap(LumenSnapshot.png(of: LumenThemeMiniature(theme: theme, registry: TestPack.registry, appearance: .light),
                                            size: CGSize(width: 200, height: 104), variant: standardLight, registry: TestPack.registry))
        }
        let difference = LumenSnapshot.compare(try render(standard), try render(slate))
        // Slate Sidebar changes only the sidebar column, about a fifth of the miniature.
        XCTAssertGreaterThan(difference.differingPixelFraction, 0.1, "\(difference)")
    }

    /// A third-of-a-point bar captured at 3x fills exactly one pixel column. An upsampled capture
    /// at the display's 2x backing scale smears it across several partial columns.
    func testTheWindowRendererCapturesAtTheRequestedScaleNotTheDisplays() throws {
        let bar = ZStack(alignment: .topLeading) {
            Color.white
            Color.black.frame(width: 1.0 / 3.0).padding(.leading, 1)
        }
        let size = CGSize(width: 10, height: 6)
        let data = try XCTUnwrap(LumenSnapshot.png(of: bar, size: size, variant: standardLight, registry: TestPack.registry,
                                                   scale: 3, renderer: .window))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 30)
        XCTAssertEqual(rep.pixelsHigh, 18)
        func brightness(_ x: Int) -> CGFloat { rep.colorAt(x: x, y: 9)?.usingColorSpace(.sRGB)?.brightnessComponent ?? -1 }
        XCTAssertLessThan(brightness(3), 0.05, "The bar's pixel is solid")
        XCTAssertGreaterThan(brightness(2), 0.95, "No smear to the left")
        XCTAssertGreaterThan(brightness(4), 0.95, "No smear to the right")
    }

    private struct TypoToken: View {
        @Environment(\.lumenPalette) private var palette
        var body: some View { palette[LumenToken("typo.snapshot")].frame(width: 20, height: 20) }
    }

    func testBothRenderersRecordUnknownTokens() {
        for renderer in [LumenSnapshot.Renderer.image, .window] {
            let result = LumenSnapshot.render(TypoToken(), size: CGSize(width: 40, height: 40), variant: standardLight,
                                              registry: TestPack.registry, renderer: renderer)
            XCTAssertNotNil(result.png, "\(renderer)")
            XCTAssertTrue(result.unknownTokens.contains(LumenToken("typo.snapshot")), "\(renderer)")
        }
    }
}
