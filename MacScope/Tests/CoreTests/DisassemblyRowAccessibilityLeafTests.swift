import AppKit
import SwiftUI
import XCTest
@testable import MacScope

@MainActor
final class DisassemblyRowAccessibilityLeafTests: XCTestCase {
    func testNativeHostPublishesOneStoredChildlessElementAndPressesExactlyOnce() {
        var pressCount = 0
        let view = DisassemblyRowAccessibilityLeafNSView()
        view.update(
            label: "0x1000, nop, no operands",
            identifier: "disassembly.row.0.0x1000",
            help: "Selects this instruction",
            isSelected: false,
            press: { pressCount += 1 }
        )
        let element = view.instructionAccessibilityElement

        for _ in 0..<512 {
            XCTAssertFalse(view.isAccessibilityElement())
            XCTAssertEqual(view.accessibilityChildren()?.count, 1)
            XCTAssertEqual(view.accessibilityVisibleChildren()?.count, 1)
            XCTAssertTrue(view.accessibilityChildren()?.first as AnyObject === element)
            XCTAssertEqual(element.accessibilityRole(), .staticText)
            XCTAssertEqual(element.accessibilityLabel(), "0x1000, nop, no operands")
            XCTAssertEqual(element.accessibilityValue() as? String, "0x1000, nop, no operands")
            XCTAssertEqual(element.accessibilityIdentifier(), "disassembly.row.0.0x1000")
            XCTAssertEqual(element.accessibilityHelp(), "Selects this instruction")
            XCTAssertFalse(element.isAccessibilitySelected())
            XCTAssertEqual(element.accessibilityChildren()?.count, 0)
            XCTAssertEqual(element.accessibilityVisibleChildren()?.count, 0)
            XCTAssertEqual(element.accessibilityChildrenInNavigationOrder()?.count, 0)
        }

        XCTAssertTrue(element.accessibilityPerformPress())
        XCTAssertEqual(pressCount, 1)
        XCTAssertNil(view.hitTest(.zero), "The transparent AX host must not steal pointer input.")
    }

    func testNativeElementRefreshesIdentitySelectionAndActionWithoutStaleState() {
        var selectedIdentity = ""
        let view = DisassemblyRowAccessibilityLeafNSView()
        view.update(
            label: "stale",
            identifier: "disassembly.row.0.0x0",
            help: "stale",
            isSelected: false,
            press: { selectedIdentity = "stale" }
        )
        view.update(
            label: "0x2000, ret, no operands",
            identifier: "disassembly.row.1.0x2000",
            help: "Selected instruction",
            isSelected: true,
            press: { selectedIdentity = "disassembly.row.1.0x2000" }
        )
        let element = view.instructionAccessibilityElement

        XCTAssertEqual(element.accessibilityLabel(), "0x2000, ret, no operands")
        XCTAssertEqual(element.accessibilityIdentifier(), "disassembly.row.1.0x2000")
        XCTAssertEqual(element.accessibilityHelp(), "Selected instruction")
        XCTAssertTrue(element.isAccessibilitySelected())
        XCTAssertTrue(element.accessibilityPerformPress())
        XCTAssertEqual(selectedIdentity, "disassembly.row.1.0x2000")
    }

    func testMountedBridgePublishesBoundedInstructionLeafBesideSwiftUIButton() throws {
        var pressCount = 0
        let root = HStack {
            Button("Breakpoint") {}
                .accessibilityIdentifier("breakpoint.0.0x1000")

            ZStack {
                Text("0x1000 nop")
                    .focusable(true)
                    .accessibilityHidden(true)

                DisassemblyRowAccessibilityLeaf(
                    label: "0x1000, nop, no operands",
                    identifier: "disassembly.row.0.0x1000",
                    help: "Selects this instruction",
                    isSelected: false,
                    press: { pressCount += 1 }
                )
                .allowsHitTesting(false)
            }
        }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 40)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let leaf = try XCTUnwrap(firstSubview(of: DisassemblyRowAccessibilityLeafNSView.self, in: host))
        let element = leaf.instructionAccessibilityElement
        XCTAssertFalse(leaf.isAccessibilityElement())
        XCTAssertEqual(leaf.accessibilityChildren()?.count, 1)
        XCTAssertTrue(leaf.accessibilityChildren()?.first as AnyObject === element)
        XCTAssertEqual(element.accessibilityLabel(), "0x1000, nop, no operands")
        XCTAssertEqual(element.accessibilityIdentifier(), "disassembly.row.0.0x1000")
        XCTAssertEqual(element.accessibilityChildren()?.count, 0)
        XCTAssertGreaterThan(element.frame.width, 0)
        XCTAssertGreaterThan(element.frame.height, 0)
        XCTAssertTrue(element.accessibilityPerformPress())
        XCTAssertEqual(pressCount, 1)
    }

    private func firstSubview<ViewType: NSView>(
        of type: ViewType.Type,
        in root: NSView
    ) -> ViewType? {
        if let match = root as? ViewType { return match }
        for child in root.subviews {
            if let match = firstSubview(of: type, in: child) { return match }
        }
        return nil
    }

}
