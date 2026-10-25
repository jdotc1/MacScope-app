import AppKit
import SwiftUI
import XCTest
import LumenTokens
@testable import LumenUI

/// Components an app would otherwise have to build itself.
@MainActor
final class LumenGapComponentTests: XCTestCase {
    private let tools = ["files", "symbols", "search", "graph"]

    func testToolLayoutReadsAndWritesMacScopesStoredForm() {
        var layout = LumenToolLayout(encoded: "", all: tools)
        XCTAssertTrue(layout.isDefault)
        XCTAssertEqual(layout.encoded, "", "The default arrangement stores nothing")
        layout.move("search", by: -1)
        XCTAssertTrue(layout.hide("graph"))
        XCTAssertEqual(layout.encoded, "files,search,symbols,-graph")
        let reread = LumenToolLayout(encoded: layout.encoded, all: tools)
        XCTAssertEqual(reread.visible, ["files", "search", "symbols"])
    }

    func testToolLayoutKeepsOneToolAndAdaptsToToolsAddedOrRemoved() {
        var layout = LumenToolLayout(encoded: "-files,-symbols,-search,-graph", all: tools)
        XCTAssertEqual(layout.visible, tools, "Everything hidden reads as everything shown")
        layout = LumenToolLayout(encoded: "graph,gone,files", all: tools)
        XCTAssertEqual(layout.order, ["graph", "files", "symbols", "search"], "New tools join at the end; unknown ones drop")
        var single = LumenToolLayout(encoded: "-files,-symbols,-search", all: tools)
        XCTAssertFalse(single.hide("graph"), "The last visible tool can't be hidden")
        single.reset()
        XCTAssertTrue(single.isDefault)
    }

    func testToolLayoutMovesAmongVisibleToolsOnly() {
        var layout = LumenToolLayout(encoded: "files,-symbols,search,graph", all: tools)
        XCTAssertFalse(layout.canMove("files", by: -1))
        layout.move("search", by: -1)
        XCTAssertEqual(layout.visible, ["search", "files", "graph"])
        XCTAssertTrue(layout.hidden.contains("symbols"))
    }

    func testRowStatesResolveAsMacOSDoes() {
        XCTAssertEqual(LumenRowState.resolve(isSelected: true, isHovered: true, isEnabled: false), .disabled)
        XCTAssertEqual(LumenRowState.resolve(isSelected: true, isFocused: true, isActiveWindow: false), .selectedInactive)
        XCTAssertEqual(LumenRowState.resolve(isSelected: false, isFocused: true, isHovered: true), .focused)
        XCTAssertEqual(LumenRowState.resolve(isSelected: false, isHovered: true), .hovered)
    }

    func testCodeFontStoresAsAString() {
        XCTAssertEqual(LumenCodeFont(rawValue: "Menlo:13"), LumenCodeFont(family: "Menlo", size: 13))
        XCTAssertEqual(LumenCodeFont(rawValue: "system:12"), .standard)
        XCTAssertEqual(LumenCodeFont(family: nil, size: 40).size, LumenCodeFont.sizeRange.upperBound)
        XCTAssertEqual(LumenCodeFont(family: "Menlo", size: 13).rawValue, "Menlo:13")
        XCTAssertNil(LumenCodeFont(rawValue: "garbage"))
        XCTAssertEqual(LumenCodeFont(family: "No Such Font").nsFont().isFixedPitch, true, "Falls back to the system monospaced font")
    }

    /// PRINCIPLES §6: each fits a narrow column without clipping.
    func testTheNewPiecesFitNarrowColumns() {
        let widths: [(String, CGFloat, CGFloat)] = [
            ("banner", LumenLayout.minimumWidth(of: LumenBanner("The binary changed on disk since it was analyzed.", title: "Out of date",
                                                                  actionTitle: "Reanalyze", action: {}, onDismiss: {})), 220),
            ("loading", LumenLayout.minimumWidth(of: LumenLoadingState("Analyzing", message: "Reading symbols", progress: 0.4, onCancel: {})), 240),
            ("error", LumenLayout.minimumWidth(of: LumenErrorState("Couldn't open the file", message: "It was moved or deleted.",
                                                                     recovery: "Choose it again.", onRetry: {})), 240),
            ("row", LumenLayout.minimumWidth(of: LumenListRow("a_very_long_symbol_name_that_keeps_going", detail: "0x100003F40",
                                                               systemImage: "lumen.pseudocode", hue: .hueIndigo) { LumenCount(1234) }), 160),
            ("welcome", LumenLayout.minimumWidth(of: LumenWelcomePanel(appName: "MacScope", tagline: "Open a binary to begin.",
                                                                        markSymbol: "lumen.lens", actions: [
                LumenWelcomeAction("Open…", subtitle: "Browse for a binary", systemImage: "folder.fill", hue: .hueBlue) {}]
            )), 320),
            ("deck controls", LumenLayout.minimumWidth(of: LumenPanelDeckControls(
                decks: [LumenPanelDeck(id: "debugger", title: "Debugger", systemImage: "ladybug.fill"),
                        LumenPanelDeck(id: "shell", title: "Shell", systemImage: "terminal.fill")],
                selection: .constant("debugger"), isPresented: .constant(true))), 90),
        ]
        for (name, width, limit) in widths {
            XCTAssertLessThanOrEqual(width, limit, "\(name) needs \(width) pt")
        }
    }
}

@MainActor
final class LumenTidyTests: XCTestCase {
    func testTheModeSwitcherCollapsesToGlyphsRatherThanClipping() {
        enum Mode: String, CaseIterable { case disassembly = "Disassembly", pseudocode = "Pseudocode", graph = "Graph", hex = "Hex" }
        let switcher = LumenModeSwitcher(selection: .constant(Mode.graph), options: Mode.allCases, title: \.rawValue,
                                         systemImage: { _ in "circle" })
        XCTAssertLessThan(LumenLayout.minimumWidth(of: switcher), 200)
    }

    func testThePanelBarAndStatsCardFitNarrowColumns() {
        let bar = LumenPanelBar("Debugger", systemImage: "ladybug.fill", status: "Not attached · LLDB ready",
                                secondary: [LumenBarAction("Breakpoints", systemImage: "lumen.breakpoint") {}],
                                primary: LumenBarAction("Attach to Process…") {})
        XCTAssertLessThan(LumenLayout.minimumWidth(of: bar), 380, "The status truncates and actions drop to glyphs")
        let card = LumenStatsCard([LumenStat("Targets", count: 0), LumenStat("Functions", count: 120_000), LumenStat("Xrefs", count: 0)])
        XCTAssertLessThanOrEqual(LumenLayout.minimumWidth(of: card), LumenLayout.sidebarColumn.min)
    }

    /// C-25 / C-26: the static mirror reaches the control height and tiles; the ramp's init takes every role.
    func testTheStaticMirrorAndTypographyInitCoverEveryRole() {
        XCTAssertEqual(Lumen.Layout.controlHeight, LumenMetrics.standard.layout.controlHeight)
        XCTAssertEqual(Lumen.Layout.tileHero, LumenMetrics.standard.layout.tileHero)
        XCTAssertEqual(Lumen.Layout.disclosureGlyph, LumenMetrics.standard.layout.disclosureGlyph)
        XCTAssertEqual(Lumen.Font.sectionLabelTracking, LumenMetrics.standard.typography.sectionLabelTracking)
        let s = LumenMetrics.Typography.standard
        let ramp = LumenMetrics.Typography(title2: s.title2, title3: s.title3, headline: s.headline, body: s.body,
                                           bodyEmphasized: s.bodyEmphasized, callout: s.callout, subheadline: s.subheadline,
                                           footnote: s.footnote, caption: s.caption, captionEmphasized: s.captionEmphasized,
                                           sectionLabel: s.sectionLabel, monoCaption: s.monoCaption, monoSmall: s.monoSmall,
                                           display: s.display, sectionLabelTracking: 1, stat: .title)
        XCTAssertEqual(ramp.sectionLabelTracking, 1)
        XCTAssertEqual(ramp.stat, .title)
    }

    func testTheAddressFieldKeepsHexAndParsesIt() {
        XCTAssertEqual(LumenAddressField.sanitize("0x1000_00F50 "), "100000F50")
        XCTAssertEqual(LumenAddressField.sanitize("zz12g3"), "123")
        XCTAssertEqual(LumenAddressField.parse("100000f50"), 0x1_0000_0F50)
        XCTAssertNil(LumenAddressField.parse(""))
        XCTAssertNil(LumenAddressField.parse(String(repeating: "f", count: 17)))
    }

    func testChangingADurationRetimesItsCurves() {
        var motion = LumenMetrics.Motion.standard
        motion.fast = 0.5
        XCTAssertEqual(motion.fastCurve, .easeInOut(duration: 0.5))
        motion.emphasized = 0.6
        XCTAssertEqual(motion.emphasizedCurve, .spring(duration: 0.6, bounce: 0.18))
    }

    func testTheActiveStoreOverrideIsScopedToItsCaller() {
        let store = TestPack.store(themes: LumenRegistry.core.builtInThemes)
        LumenThemeStore.withActiveStore(store) { XCTAssertTrue(LumenThemeStore.active === store) }
        XCTAssertFalse(LumenThemeStore.active === store)
    }

    func testAnAccentChangeRebuildsThePaletteOnlyWhenFollowingTheSystem() {
        let store = TestPack.store(themes: LumenRegistry.core.builtInThemes)
        let before = store.paletteKey
        store.systemColorsDidChange()
        XCTAssertEqual(store.paletteKey, before, "The theme's own accent doesn't change")
        store.setUsesSystemAccent(true)
        let following = store.paletteKey
        store.systemColorsDidChange()
        XCTAssertNotEqual(store.paletteKey, following)
    }
}
