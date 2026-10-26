import XCTest
@testable import MacScope

final class GoToMultiImageTests: XCTestCase {
    private let secondary = ImageSlot(rawValue: 1)

    func testImageModeEmitsOneNamedSlotRoutedEntryPerMatchingImage() {
        let address: UInt64 = 0x374
        let names: [ImageSlot: String] = [
            .primary: "mainprog",
            secondary: "libshared.dylib"
        ]

        let entries = CommandPaletteCatalog.addressEntries(
            for: address,
            matchingSlots: [.primary, secondary],
            imageName: { names[$0] },
            mode: .image,
            resolvedRuntimeTarget: nil
        )

        XCTAssertEqual(entries.map(\.title), [
            "Go to \(address.hexAddress) — mainprog",
            "Go to \(address.hexAddress) — libshared.dylib"
        ])
        assertSlotAction(entries[0].action, address: address, slot: .primary)
        assertSlotAction(entries[1].action, address: address, slot: secondary)
    }

    func testImageModeSingleMatchEmitsOneEntry() {
        let address: UInt64 = 0x2000

        let entries = CommandPaletteCatalog.addressEntries(
            for: address,
            matchingSlots: [secondary],
            imageName: { $0 == self.secondary ? "only-here.dylib" : nil },
            mode: .image,
            resolvedRuntimeTarget: nil
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "Go to \(address.hexAddress) — only-here.dylib")
        assertSlotAction(entries[0].action, address: address, slot: secondary)
    }

    func testRuntimeModeEmitsOnlyTheResolvedImagesEntryAndRoutesToItsImageVA() {
        let enteredRuntimeVA: UInt64 = 0x1_0000_4374
        let resolved = ImageAddress(slot: secondary, address: 0x374)

        let entries = CommandPaletteCatalog.addressEntries(
            for: enteredRuntimeVA,
            matchingSlots: [.primary, secondary],
            imageName: { $0 == self.secondary ? "libshared.dylib" : "mainprog" },
            mode: .runtime,
            resolvedRuntimeTarget: resolved
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "Go to \(enteredRuntimeVA.hexAddress) — libshared.dylib")
        assertSlotAction(entries[0].action, address: resolved.address, slot: secondary)
    }

    func testUnmappedImageAddressKeepsFocusedSlotFallback() {
        let address: UInt64 = 0x9999

        let entries = CommandPaletteCatalog.addressEntries(
            for: address,
            matchingSlots: [],
            imageName: { _ in XCTFail("An unmapped fallback must not request an image name"); return nil },
            mode: .image,
            resolvedRuntimeTarget: nil
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "Go to \(address.hexAddress)")
        XCTAssertEqual(entries[0].subtitle, "Raw Address")
        guard case .goToAddress(let routedAddress) = entries[0].action else {
            return XCTFail("Expected the legacy focused-slot .goToAddress fallback action")
        }
        XCTAssertEqual(routedAddress, address)
    }

    private func assertSlotAction(
        _ action: CommandPaletteAction,
        address expectedAddress: UInt64,
        slot expectedSlot: ImageSlot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .goToAddressInSlot(let address, let slot) = action else {
            return XCTFail("Expected .goToAddressInSlot", file: file, line: line)
        }
        XCTAssertEqual(address, expectedAddress, file: file, line: line)
        XCTAssertEqual(slot, expectedSlot, file: file, line: line)
    }
}
