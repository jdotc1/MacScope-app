import XCTest
@testable import MacScope

/// Tier 3 — the color-tag palette manager model. Asserts rename/recolor, the
/// per-slot/global reset, and the persistence round-trip (only overrides stored; defaults
/// inherited; corrupt data degrades safely). The slot keys (`ColorTag` cases) are the
/// stable persistence identity, so the test pins that they never change under a rename.
final class ColorTagPaletteTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let suite = "ColorTagPaletteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Defaults

    func testDefaultsCoverEverySlotWithShippedName() {
        let palette = ColorTagPalette.defaults
        XCTAssertEqual(palette.entries.count, ColorTag.allCases.count)
        for tag in ColorTag.allCases {
            let entry = palette.entry(for: tag)
            XCTAssertEqual(entry.name, tag.displayName)
            XCTAssertNil(entry.colorOverride)
        }
        XCTAssertTrue(palette.overrideMap().isEmpty)
    }

    // MARK: - Rename

    func testRenameChangesNameButNotSlotIdentity() {
        var palette = ColorTagPalette.defaults
        palette.rename(.red, to: "Critical")
        XCTAssertEqual(palette.entry(for: .red).name, "Critical")
        // The slot key is unchanged — a per-address `.red` assignment still resolves here.
        XCTAssertEqual(palette.entry(for: .red).tag, .red)
    }

    func testEmptyRenameFallsBackToDefaultName() {
        var palette = ColorTagPalette.defaults
        palette.rename(.blue, to: "   ")
        XCTAssertEqual(palette.entry(for: .blue).name, ColorTag.blue.displayName)
    }

    // MARK: - Recolor

    func testRecolorSetsAndClearsOverride() {
        var palette = ColorTagPalette.defaults
        let teal = PaletteColor(red: 0, green: 0.5, blue: 0.5)
        palette.recolor(.green, to: teal)
        XCTAssertEqual(palette.entry(for: .green).colorOverride, teal)
        palette.recolor(.green, to: nil)
        XCTAssertNil(palette.entry(for: .green).colorOverride)
    }

    func testPaletteColorClampsOutOfRangeComponents() {
        let color = PaletteColor(red: 2, green: -1, blue: 0.5, opacity: 9)
        XCTAssertEqual(color.red, 1)
        XCTAssertEqual(color.green, 0)
        XCTAssertEqual(color.blue, 0.5)
        XCTAssertEqual(color.opacity, 1)
    }

    // MARK: - Reset

    func testResetOneSlotRestoresNameAndColor() {
        var palette = ColorTagPalette.defaults
        palette.rename(.orange, to: "Warn")
        palette.recolor(.orange, to: PaletteColor(red: 1, green: 0, blue: 0))
        palette.reset(.orange)
        XCTAssertEqual(palette.entry(for: .orange).name, ColorTag.orange.displayName)
        XCTAssertNil(palette.entry(for: .orange).colorOverride)
    }

    func testResetAllRestoresShippedPalette() {
        var palette = ColorTagPalette.defaults
        palette.rename(.red, to: "X")
        palette.recolor(.blue, to: PaletteColor(red: 0, green: 0, blue: 1))
        palette.resetAll()
        XCTAssertEqual(palette, ColorTagPalette.defaults)
        XCTAssertTrue(palette.overrideMap().isEmpty)
    }

    // MARK: - Persistence round-trip

    func testOverrideMapOnlyContainsChangedSlots() {
        var palette = ColorTagPalette.defaults
        palette.rename(.red, to: "Critical")
        let overrides = palette.overrideMap()
        XCTAssertEqual(Array(overrides.keys), [ColorTag.red.rawValue])
        XCTAssertEqual(overrides[ColorTag.red.rawValue]?.name, "Critical")
        XCTAssertNil(overrides[ColorTag.red.rawValue]?.color)
    }

    func testPersistAndLoadRoundTrip() {
        let d = defaults()
        var palette = ColorTagPalette.defaults
        let teal = PaletteColor(red: 0, green: 0.5, blue: 0.5)
        palette.rename(.red, to: "Critical")
        palette.recolor(.green, to: teal)
        palette.persist(to: d)

        let loaded = ColorTagPalette.load(from: d)
        XCTAssertEqual(loaded.entry(for: .red).name, "Critical")
        XCTAssertEqual(loaded.entry(for: .green).colorOverride, teal)
        // Untouched slot keeps its default name and no override.
        XCTAssertEqual(loaded.entry(for: .blue).name, ColorTag.blue.displayName)
        XCTAssertNil(loaded.entry(for: .blue).colorOverride)
        XCTAssertEqual(loaded, palette)
    }

    func testPersistEmptyOverridesClearsTheStoredKey() {
        let d = defaults()
        var palette = ColorTagPalette.defaults
        palette.rename(.red, to: "X")
        palette.persist(to: d)
        XCTAssertNotNil(d.data(forKey: ColorTagPalette.storageKey))
        palette.resetAll()
        palette.persist(to: d)
        XCTAssertNil(d.data(forKey: ColorTagPalette.storageKey))
        XCTAssertEqual(ColorTagPalette.load(from: d), ColorTagPalette.defaults)
    }

    func testCorruptStoredDataDegradesToDefaults() {
        let d = defaults()
        d.set(Data("not json".utf8), forKey: ColorTagPalette.storageKey)
        XCTAssertEqual(ColorTagPalette.load(from: d), ColorTagPalette.defaults)
    }

    func testUnknownSlotIdInStorageIsIgnored() {
        let d = defaults()
        let payload = ["chartreuse": ColorTagPalette.StoredEntry(name: "Nope", color: nil)]
        d.set(try! JSONEncoder().encode(payload), forKey: ColorTagPalette.storageKey)
        XCTAssertEqual(ColorTagPalette.load(from: d), ColorTagPalette.defaults)
    }
}
