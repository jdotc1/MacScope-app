import AppKit
import SwiftUI

/// A childless AppKit accessibility surface for one SwiftUI-rendered disassembly row.
///
/// The visual row remains SwiftUI-owned, but its selectable text and focus/context-menu wrappers
/// are deliberately hidden from accessibility. AppKit therefore answers row label queries from
/// stored values without asking SwiftUI to synthesize and cascade a label through its proxy tree.
struct DisassemblyRowAccessibilityLeaf: NSViewRepresentable {
    let label: String
    let identifier: String
    let help: String
    let isSelected: Bool
    let press: () -> Void

    func makeNSView(context: Context) -> DisassemblyRowAccessibilityLeafNSView {
        DisassemblyRowAccessibilityLeafNSView()
    }

    func updateNSView(_ view: DisassemblyRowAccessibilityLeafNSView, context: Context) {
        view.update(
            label: label,
            identifier: identifier,
            help: help,
            isSelected: isSelected,
            press: press
        )
    }
}

/// The backing view is a non-semantic container so SwiftUI's representable attachment and the
/// semantic instruction element never share the same AppKit object. Sharing that object lets
/// SwiftUI resolve an attached label by querying the platform label it is currently applying,
/// which recurses during a full XCTest hierarchy snapshot.
@MainActor
final class DisassemblyRowAccessibilityLeafNSView: NSView {
    let instructionAccessibilityElement = DisassemblyRowAccessibilityElement()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    func update(
        label: String,
        identifier: String,
        help: String,
        isSelected: Bool,
        press: @escaping () -> Void
    ) {
        instructionAccessibilityElement.update(
            label: label,
            identifier: identifier,
            help: help,
            isSelected: isSelected,
            press: press
        )
        updateAccessibilityFrame()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func accessibilityChildren() -> [Any]? {
        [instructionAccessibilityElement]
    }

    override func accessibilityVisibleChildren() -> [Any]? {
        [instructionAccessibilityElement]
    }

    override func layout() {
        super.layout()
        instructionAccessibilityElement.frame = bounds
    }

    private func configureAccessibility() {
        setAccessibilityElement(false)
        addSubview(instructionAccessibilityElement)
        setAccessibilityChildren([instructionAccessibilityElement])
        setAccessibilityVisibleChildren([instructionAccessibilityElement])
        updateAccessibilityFrame()
    }

    private func updateAccessibilityFrame() {
        instructionAccessibilityElement.frame = bounds
    }
}

/// A retained transparent child view carries the stored instruction semantics without consulting
/// SwiftUI, its representable host, or any accessibility ancestor while answering leaf attributes.
@MainActor
final class DisassemblyRowAccessibilityElement: NSView {
    private var press: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    func update(
        label: String,
        identifier: String,
        help: String,
        isSelected: Bool,
        press: @escaping () -> Void
    ) {
        self.press = press
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
        setAccessibilityValue(label)
        setAccessibilityIdentifier(identifier)
        setAccessibilityHelp(help)
        setAccessibilitySelected(isSelected)
        setAccessibilityChildren([])
        setAccessibilityVisibleChildren([])
        setAccessibilityChildrenInNavigationOrder([])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func accessibilityChildren() -> [Any]? {
        []
    }

    override func accessibilityVisibleChildren() -> [Any]? {
        []
    }

    override func accessibilityChildrenInNavigationOrder() -> [any NSAccessibilityElementProtocol]? {
        []
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityChildren([])
        setAccessibilityVisibleChildren([])
        setAccessibilityChildrenInNavigationOrder([])
    }
}
