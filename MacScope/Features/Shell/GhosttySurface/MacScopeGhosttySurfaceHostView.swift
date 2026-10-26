import AppKit
import Foundation

struct MacScopeGhosttyKeyInput: Equatable, Sendable {
    let keyCode: UInt16
    let characters: String?
    let charactersIgnoringModifiers: String?
    let modifierFlags: UInt
    let isRepeat: Bool
}

enum MacScopeGhosttyPointerButton: Int, Equatable, Sendable {
    case left
    case right
    case middle
    case other
}

enum MacScopeGhosttyPointerPhase: Equatable, Sendable {
    case entered
    case exited
    case moved
    case pressed
    case dragged
    case released
}

struct MacScopeGhosttyPointerInput: Equatable, Sendable {
    let phase: MacScopeGhosttyPointerPhase
    let button: MacScopeGhosttyPointerButton?
    let location: CGPoint
    let modifierFlags: UInt
    let clickCount: Int
    let pressure: Double
}

struct MacScopeGhosttyScrollInput: Equatable, Sendable {
    let deltaX: CGFloat
    let deltaY: CGFloat
    let hasPreciseDeltas: Bool
    let modifierFlags: UInt
    let phaseRawValue: UInt
    let momentumPhaseRawValue: UInt
}

enum MacScopeGhosttySelectionAction: Equatable, Sendable {
    case copy
    case selectAll
    case clear
}

enum MacScopeGhosttySurfaceHostEvent: Equatable, Sendable {
    case draw(CGRect)
    case wakeup
    case key(MacScopeGhosttyKeyInput)
    case modifierFlagsChanged(MacScopeGhosttyKeyInput)
    case text(String, replacementRange: NSRange)
    case preedit(String, selectedRange: NSRange, replacementRange: NSRange)
    case unmarkText
    case command(String)
    case pointer(MacScopeGhosttyPointerInput)
    case scroll(MacScopeGhosttyScrollInput)
    case selection(MacScopeGhosttySelectionAction)
    case paste(String)
    case focus(Bool)
    case resize(size: CGSize, backingScale: CGFloat)
    case display(scale: CGFloat, displayID: UInt32?)
    case occlusion(Bool)
}

@MainActor
protocol MacScopeGhosttySurfaceHostEventSink: AnyObject {
    @discardableResult
    func ghosttyHostView(
        _ hostView: MacScopeGhosttySurfaceHostView,
        handle event: MacScopeGhosttySurfaceHostEvent
    ) -> Bool

    func selectedText(in hostView: MacScopeGhosttySurfaceHostView) -> String?
    func textInputRect(in hostView: MacScopeGhosttySurfaceHostView) -> NSRect?
}

extension MacScopeGhosttySurfaceHostEventSink {
    func selectedText(in hostView: MacScopeGhosttySurfaceHostView) -> String? { nil }
    func textInputRect(in hostView: MacScopeGhosttySurfaceHostView) -> NSRect? { nil }
}

@MainActor
protocol MacScopeGhosttySurfaceHostLifecycleSink: AnyObject {
    func ghosttyHostViewDidAttachToWindow(_ hostView: MacScopeGhosttySurfaceHostView)
}

/// AppKit edge for the full terminal surface.
///
/// The view owns responder-chain and text-input mechanics only. It normalizes AppKit objects into
/// MacScope-owned values before forwarding them, so neither SwiftUI nor later broker layers need
/// to import GhosttyKit or retain `NSEvent` instances.
@MainActor
final class MacScopeGhosttySurfaceHostView: NSView, @preconcurrency NSTextInputClient {
    private static let maximumForwardedTextUTF8ByteCount = 32 << 10
    private static let maximumSelectionUTF8ByteCount = 4 << 20
    private static let maximumBackingScale: CGFloat = 16
    private static let maximumPixelDimension: CGFloat = 1_048_576

    private(set) weak var eventSink: (any MacScopeGhosttySurfaceHostEventSink)?

    private var pointerTrackingArea: NSTrackingArea?
    private weak var lifecycleSink: (any MacScopeGhosttySurfaceHostLifecycleSink)?
    private weak var observedWindow: NSWindow?
    private var markedText = NSMutableAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    private var lastResize: ResizeSnapshot?
    private var lastDisplay: DisplaySnapshot?
    private var lastOcclusion: Bool?
    private var lastFocus: Bool?
    private var isPreparedForDismantle = false

    private struct ResizeSnapshot: Equatable {
        let size: CGSize
        let backingScale: CGFloat
    }

    private struct DisplaySnapshot: Equatable {
        let backingScale: CGFloat
        let displayID: UInt32?
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    var isObservingWindow: Bool { observedWindow != nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if observedWindow !== newWindow {
            // This callback runs while `window` still names the old owner. Close its focus lease
            // before clearing snapshots so a detached or transferred first responder cannot
            // leave the native surface logically focused.
            publishFocus(false)
            stopObservingWindow()
            resetPublishedEnvironment()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingWindowIfNeeded()
        guard window != nil else { return }
        lifecycleSink?.ghosttyHostViewDidAttachToWindow(self)
        publishCurrentEnvironment()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        publishDisplay()
        publishResize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        publishResize()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
            self.pointerTrackingArea = nil
        }
        guard !isPreparedForDismantle else { return }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func draw(_ dirtyRect: NSRect) {
        let handled = eventSink?.ghosttyHostView(self, handle: .draw(dirtyRect)) ?? false
        guard !handled else { return }
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            publishFocus(window?.isKeyWindow == true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            publishFocus(false)
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        guard let input = keyInput(event) else {
            interpretKeyEvents([event])
            return
        }
        guard eventSink?.ghosttyHostView(self, handle: .key(input)) != true else { return }
        interpretKeyEvents([event])
    }

    override func flagsChanged(with event: NSEvent) {
        guard let input = keyInput(event) else {
            super.flagsChanged(with: event)
            return
        }
        let handled = eventSink?.ghosttyHostView(
            self,
            handle: .modifierFlagsChanged(input)
        ) ?? false
        if !handled {
            super.flagsChanged(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              let character = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }

        switch character {
        case "c":
            return copySelection(to: .general)
        case "a":
            return eventSink?.ghosttyHostView(self, handle: .selection(.selectAll)) ?? false
        case "v":
            guard let value = NSPasteboard.general.string(forType: .string) else { return true }
            return forwardPaste(value)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func doCommand(by selector: Selector) {
        let handled = eventSink?.ghosttyHostView(
            self,
            handle: .command(NSStringFromSelector(selector))
        ) ?? false
        if !handled {
            super.doCommand(by: selector)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        forwardPointer(event, phase: .entered, button: nil)
    }

    override func mouseExited(with event: NSEvent) {
        forwardPointer(event, phase: .exited, button: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        forwardPointer(event, phase: .moved, button: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        forwardPointer(event, phase: .pressed, button: .left)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardPointer(event, phase: .dragged, button: .left)
    }

    override func mouseUp(with event: NSEvent) {
        forwardPointer(event, phase: .released, button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardPointer(event, phase: .pressed, button: .right)
    }

    override func rightMouseDragged(with event: NSEvent) {
        forwardPointer(event, phase: .dragged, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardPointer(event, phase: .released, button: .right)
    }

    override func otherMouseDown(with event: NSEvent) {
        forwardPointer(event, phase: .pressed, button: pointerButton(event.buttonNumber))
    }

    override func otherMouseDragged(with event: NSEvent) {
        forwardPointer(event, phase: .dragged, button: pointerButton(event.buttonNumber))
    }

    override func otherMouseUp(with event: NSEvent) {
        forwardPointer(event, phase: .released, button: pointerButton(event.buttonNumber))
    }

    override func scrollWheel(with event: NSEvent) {
        let handled = eventSink?.ghosttyHostView(
            self,
            handle: .scroll(MacScopeGhosttyScrollInput(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                modifierFlags: event.modifierFlags.rawValue,
                phaseRawValue: event.phase.rawValue,
                momentumPhaseRawValue: event.momentumPhase.rawValue
            ))
        ) ?? false
        if !handled {
            super.scrollWheel(with: event)
        }
    }

    @discardableResult
    func copySelection(to pasteboard: NSPasteboard) -> Bool {
        guard let selected = eventSink?.selectedText(in: self),
              !selected.isEmpty,
              Self.isForwardableText(selected, limit: Self.maximumSelectionUTF8ByteCount)
        else {
            return false
        }
        pasteboard.clearContents()
        guard pasteboard.setString(selected, forType: .string) else { return false }
        _ = eventSink?.ghosttyHostView(self, handle: .selection(.copy))
        return true
    }

    func requestRender() {
        guard eventSink != nil, window != nil, !isPreparedForDismantle else { return }
        // Native wakeup intents already enter through the backend's tick callback. A render
        // request only coalesces an AppKit draw; reflecting it as another wakeup would create a
        // render -> tick -> render feedback loop and let queued work outlive its generation.
        needsDisplay = true
    }

    @discardableResult
    func installLifecycleSink(
        _ sink: any MacScopeGhosttySurfaceHostLifecycleSink
    ) -> Bool {
        guard !isPreparedForDismantle else { return false }
        if lifecycleSink === sink { return true }
        guard lifecycleSink == nil, eventSink == nil else { return false }
        lifecycleSink = sink
        return true
    }

    func removeLifecycleSink(_ sink: any MacScopeGhosttySurfaceHostLifecycleSink) {
        guard lifecycleSink === sink else { return }
        lifecycleSink = nil
    }

    @discardableResult
    func installEventSink(_ sink: any MacScopeGhosttySurfaceHostEventSink) -> Bool {
        guard !isPreparedForDismantle else { return false }
        if eventSink === sink { return true }
        guard eventSink == nil else { return false }
        needsDisplay = false
        eventSink = sink
        resetPublishedEnvironment()
        return true
    }

    func removeEventSink(_ sink: any MacScopeGhosttySurfaceHostEventSink) {
        guard eventSink === sink else { return }
        needsDisplay = false
        eventSink = nil
        resetPublishedEnvironment()
    }

    /// Idempotently severs AppKit observers and coordinator callbacks before representable release.
    func prepareForDismantle() {
        guard !isPreparedForDismantle else { return }
        isPreparedForDismantle = true
        lifecycleSink = nil
        needsDisplay = false
        eventSink = nil
        stopObservingWindow()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
            self.pointerTrackingArea = nil
        }
        markedText = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        resetPublishedEnvironment()
    }

    @discardableResult
    func forwardPaste(_ value: String) -> Bool {
        guard !value.isEmpty, Self.isForwardableText(value) else { return false }
        return eventSink?.ghosttyHostView(self, handle: .paste(value)) ?? false
    }

    func publishCurrentEnvironment() {
        guard window != nil, eventSink != nil, !isPreparedForDismantle else { return }
        publishDisplay()
        publishResize()
        publishOcclusion()
        publishFocus(window?.isKeyWindow == true && window?.firstResponder === self)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        guard let value = Self.boundedPlainString(string), !value.isEmpty else { return }
        _ = eventSink?.ghosttyHostView(
            self,
            handle: .text(value, replacementRange: replacementRange)
        )
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        guard let value = Self.boundedPlainString(string) else {
            markedText = NSMutableAttributedString()
            markedSelection = NSRange(location: 0, length: 0)
            _ = eventSink?.ghosttyHostView(self, handle: .unmarkText)
            return
        }
        markedText = NSMutableAttributedString(string: value)
        markedSelection = Self.clamped(selectedRange, length: markedText.length)
        _ = eventSink?.ghosttyHostView(
            self,
            handle: .preedit(
                value,
                selectedRange: markedSelection,
                replacementRange: replacementRange
            )
        )
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        _ = eventSink?.ghosttyHostView(self, handle: .unmarkText)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        hasMarkedText()
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { markedSelection }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .foregroundColor, .backgroundColor, .underlineStyle]
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= markedText.length else {
            return nil
        }
        actualRange?.pointee = range
        return markedText.attributedSubstring(from: range)
    }

    func characterIndex(for point: NSPoint) -> Int { markedText.length }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }
        let local = eventSink?.textInputRect(in: self)
            ?? NSRect(x: bounds.minX, y: bounds.maxY, width: 1, height: 1)
        return window.convertToScreen(convert(local, to: nil))
    }

    private func configure() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal")
        setAccessibilityHelp("Interactive terminal surface")
    }

    private func keyInput(_ event: NSEvent) -> MacScopeGhosttyKeyInput? {
        // AppKit character and repeat accessors require key-down/up events. Modifier
        // events carry only key code and flags; querying their characters raises NSException.
        switch event.type {
        case .flagsChanged:
            return MacScopeGhosttyKeyInput(
                keyCode: event.keyCode,
                characters: nil,
                charactersIgnoringModifiers: nil,
                modifierFlags: event.modifierFlags.rawValue,
                isRepeat: false
            )
        case .keyDown, .keyUp:
            let characters = event.characters
            let unmodified = event.charactersIgnoringModifiers
            guard characters.map({ Self.isForwardableText($0) }) ?? true,
                  unmodified.map({ Self.isForwardableText($0) }) ?? true
            else { return nil }
            return MacScopeGhosttyKeyInput(
                keyCode: event.keyCode,
                characters: characters,
                charactersIgnoringModifiers: unmodified,
                modifierFlags: event.modifierFlags.rawValue,
                isRepeat: event.isARepeat
            )
        default:
            return nil
        }
    }

    private func forwardPointer(
        _ event: NSEvent,
        phase: MacScopeGhosttyPointerPhase,
        button: MacScopeGhosttyPointerButton?
    ) {
        let local = convert(event.locationInWindow, from: nil)
        let input = MacScopeGhosttyPointerInput(
            phase: phase,
            button: button,
            location: local,
            modifierFlags: event.modifierFlags.rawValue,
            clickCount: event.clickCount,
            pressure: Double(event.pressure)
        )
        let handled = eventSink?.ghosttyHostView(self, handle: .pointer(input)) ?? false
        if !handled, phase == .pressed, button == .right {
            super.rightMouseDown(with: event)
        }
    }

    private func pointerButton(_ number: Int) -> MacScopeGhosttyPointerButton {
        switch number {
        case 0: .left
        case 1: .right
        case 2: .middle
        default: .other
        }
    }

    private func publishResize() {
        guard let window, eventSink != nil, !isPreparedForDismantle else { return }
        let scale = Self.boundedScale(window.backingScaleFactor)
        guard Self.isValidResize(size: bounds.size, backingScale: scale) else { return }
        let snapshot = ResizeSnapshot(size: bounds.size, backingScale: scale)
        guard snapshot != lastResize else { return }
        lastResize = snapshot
        _ = eventSink?.ghosttyHostView(
            self,
            handle: .resize(size: snapshot.size, backingScale: snapshot.backingScale)
        )
    }

    private func publishDisplay() {
        guard let window, let screen = window.screen,
              eventSink != nil, !isPreparedForDismantle
        else { return }
        let scale = Self.boundedScale(screen.backingScaleFactor)
        let displayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value
        let snapshot = DisplaySnapshot(backingScale: scale, displayID: displayID)
        guard snapshot != lastDisplay else { return }
        lastDisplay = snapshot
        _ = eventSink?.ghosttyHostView(
            self,
            handle: .display(scale: snapshot.backingScale, displayID: snapshot.displayID)
        )
    }

    private func publishOcclusion() {
        guard let window, eventSink != nil, !isPreparedForDismantle else { return }
        let visible = window.occlusionState.contains(.visible)
        guard visible != lastOcclusion else { return }
        lastOcclusion = visible
        _ = eventSink?.ghosttyHostView(self, handle: .occlusion(visible))
    }

    private func publishFocus(_ focused: Bool) {
        guard window != nil, eventSink != nil, !isPreparedForDismantle else { return }
        guard focused != lastFocus else { return }
        lastFocus = focused
        _ = eventSink?.ghosttyHostView(self, handle: .focus(focused))
    }

    private func startObservingWindowIfNeeded() {
        guard !isPreparedForDismantle,
              let window,
              observedWindow !== window
        else { return }
        stopObservingWindow()
        observedWindow = window
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowFocusChanged(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowFocusChanged(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowDisplayChanged(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowOcclusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    private func stopObservingWindow() {
        NotificationCenter.default.removeObserver(self)
        observedWindow = nil
    }

    @objc private func windowFocusChanged(_ notification: Notification) {
        guard notificationIsFromObservedWindow(notification), let window else { return }
        publishFocus(window.isKeyWindow && window.firstResponder === self)
    }

    @objc private func windowDisplayChanged(_ notification: Notification) {
        guard notificationIsFromObservedWindow(notification) else { return }
        publishDisplay()
        publishResize()
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        guard notificationIsFromObservedWindow(notification) else { return }
        publishOcclusion()
    }

    private func notificationIsFromObservedWindow(_ notification: Notification) -> Bool {
        guard let observedWindow,
              let sourceWindow = notification.object as? NSWindow
        else { return false }
        return sourceWindow === observedWindow && sourceWindow === window
    }

    private func resetPublishedEnvironment() {
        lastResize = nil
        lastDisplay = nil
        lastOcclusion = nil
        lastFocus = nil
    }

    private static func boundedScale(_ candidate: CGFloat) -> CGFloat {
        guard candidate.isFinite else { return 1 }
        return min(max(1, candidate), maximumBackingScale)
    }

    private static func boundedPlainString(_ value: Any) -> String? {
        let plain: String
        if let attributed = value as? NSAttributedString {
            guard attributed.length <= maximumForwardedTextUTF8ByteCount else { return nil }
            plain = attributed.string
        } else {
            plain = value as? String ?? ""
        }
        return isForwardableText(plain) ? plain : nil
    }

    private static func isForwardableText(
        _ value: String
    ) -> Bool {
        isForwardableText(value, limit: maximumForwardedTextUTF8ByteCount)
    }

    private static func isForwardableText(
        _ value: String,
        limit: Int
    ) -> Bool {
        value.utf8.count <= limit
    }

    private static func isValidResize(size: CGSize, backingScale: CGFloat) -> Bool {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width >= 0,
              size.height >= 0,
              backingScale.isFinite,
              backingScale >= 1,
              backingScale <= maximumBackingScale
        else { return false }
        return size.width * backingScale <= maximumPixelDimension
            && size.height * backingScale <= maximumPixelDimension
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        guard range.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let location = min(max(0, range.location), length)
        let upperBound = min(max(location, NSMaxRange(range)), length)
        return NSRange(location: location, length: upperBound - location)
    }
}
