import AppKit
import os

/// Explicit headless entry policy. Window-testing hosts and the normal production application
/// never opt in merely because XCTest is present.
@MainActor
enum MacScopeHeadlessHostPolicy {
    private static let logger = Logger(subsystem: "org.macscope.MacScope",
                                       category: "ReconstructionHeadlessHost")
    private static let delegate = MacScopeHeadlessHostDelegate()
    private(set) static var isEnabled = false

    static func installIfRequested(arguments: [String], environment: [String: String]) {
        guard ReconstructionHeadlessHostConfiguration.isRequested(arguments: arguments,
                                                                 environment: environment) else { return }
        isEnabled = true
        let application = NSApplication.shared
        let applied = application.setActivationPolicy(.prohibited)
        application.delegate = delegate
        logger.info("Headless activation policy prohibited: \(applied, privacy: .public)")
    }

    static func shouldIgnoreQuit(isHeadless: Bool, isExecuting: Bool) -> Bool {
        isHeadless && isExecuting
    }

    static func terminationReply() -> NSApplication.TerminateReply {
        guard shouldIgnoreQuit(isHeadless: isEnabled,
                               isExecuting: ReconstructionExecutionActivity.shared.isExecuting) else {
            return .terminateNow
        }
        // 'spid' is keySenderPIDAttr. Absent for programmatic termination or senders that do not
        // supply the attribute; no sender identity is invented in that case.
        let sender = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: 0x73706964)?.int32Value
        let senderText = sender.map(String.init) ?? "unavailable"
        logger.notice("Ignored Quit while reconstruction is executing; senderPID=\(senderText, privacy: .public)")
        return .terminateCancel
    }
}

@MainActor
final class MacScopeHeadlessHostDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MacScopeHeadlessHostPolicy.terminationReply()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if MacScopeHeadlessHostPolicy.isEnabled { NSApplication.shared.setActivationPolicy(.prohibited) }
    }
}
