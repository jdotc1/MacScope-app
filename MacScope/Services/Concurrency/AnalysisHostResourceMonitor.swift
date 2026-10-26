import Darwin
import Foundation

enum AnalysisMemoryPressure: Int, Equatable, Sendable { case normal, warning, critical }

struct AnalysisHostResourceSnapshot: Equatable, Sendable {
    let availableMemoryBytes: UInt64?
    let thermalState: ProcessInfo.ThermalState
    let lowPowerMode: Bool
    let memoryPressure: AnalysisMemoryPressure

    /// Observed VM headroom estimate, not a promise that allocation will succeed. Inactive
    /// pages may require reclamation. Compressed/swap/wired pages are deliberately excluded;
    /// purgeable pages are not added separately because the counters can overlap.
    static func live(memoryPressure: AnalysisMemoryPressure = .normal) -> Self {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
            / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        let pageStatus = host_page_size(host, &pageSize)
        let pages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count)
        let bytes = pages.multipliedReportingOverflow(by: UInt64(pageSize))
        let available: UInt64? = status == KERN_SUCCESS && pageStatus == KERN_SUCCESS
            && !bytes.overflow ? min(bytes.partialValue, ProcessInfo.processInfo.physicalMemory) : nil
        return .init(availableMemoryBytes: available,
            thermalState: ProcessInfo.processInfo.thermalState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            memoryPressure: memoryPressure)
    }
}

/// Event-driven host signals plus a low-frequency headroom sample. The timer is necessary:
/// memory may become available while pressure stays normal, which emits no pressure transition.
/// It performs one bounded Mach statistics query per five seconds, never sleeps a Swift task.
/// Synchronization audit: mutable callbacks/start/pressure are lock-protected; source handlers
/// capture this monitor weakly. Consumer closures capture their owner weakly as well.
final class AnalysisHostResourceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.macscope.analysis.resources", qos: .utility)
    private var pressure: AnalysisMemoryPressure = .normal
    private var callback: (@Sendable (AnalysisHostResourceSnapshot) -> Void)?
    private var observers: [any NSObjectProtocol] = []
    private let memorySource: any DispatchSourceMemoryPressure
    private let timer: any DispatchSourceTimer

    init() {
        memorySource = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        timer = DispatchSource.makeTimerSource(queue: queue)
        // Access thermalState before registering its notification, as required by Foundation.
        _ = ProcessInfo.processInfo.thermalState
        memorySource.setEventHandler { [weak self] in self?.memoryChanged() }
        timer.setEventHandler { [weak self] in self?.emit() }
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .seconds(1))
        for name in [ProcessInfo.thermalStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
                [weak self] _ in self?.emit()
            })
        }
        memorySource.activate()
        timer.activate()
    }

    deinit {
        memorySource.cancel()
        timer.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func observe(_ callback: @escaping @Sendable (AnalysisHostResourceSnapshot) -> Void) {
        lock.withLock { self.callback = callback }
    }

    func snapshot() -> AnalysisHostResourceSnapshot {
        .live(memoryPressure: lock.withLock { pressure })
    }

    private func memoryChanged() {
        let event = memorySource.data
        lock.withLock {
            pressure = event.contains(.critical) ? .critical
                : event.contains(.warning) ? .warning : .normal
        }
        emit()
    }

    private func emit() {
        let callback = lock.withLock { self.callback }
        callback?(snapshot())
    }
}
