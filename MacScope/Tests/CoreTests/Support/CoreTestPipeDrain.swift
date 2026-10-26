import Foundation

/// Reads a subprocess pipe to EOF on a background queue while the child runs.
///
/// Waiting for exit before reading deadlocks once the child writes more than the ~64 KB pipe
/// buffer: the child blocks in `write()` and never exits. Two pipes read one after the other can
/// deadlock the same way when the second fills first. Create one drain per pipe immediately after
/// `process.run()` (and before writing any stdin), wait for the process, then call `data()`.
///
/// ```swift
/// try process.run()
/// let output = CoreTestPipeDrain(outputPipe)
/// process.waitUntilExit()
/// let data = output.data()
/// ```
final class CoreTestPipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var captured = Data()

    convenience init(_ pipe: Pipe) {
        self.init(pipe.fileHandleForReading)
    }

    /// The drain retains `handle`, keeping its descriptor open for the background reader.
    init(_ handle: FileHandle) {
        self.handle = handle
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = handle.readDataToEndOfFile()
            lock.lock()
            captured = data
            lock.unlock()
            group.leave()
        }
    }

    /// Joins the background read. Call after the process has exited.
    func data() -> Data {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    /// Joins the background read and decodes it as UTF-8 (lossy), matching the call sites'
    /// existing `String(decoding:as:)` behavior.
    func text() -> String {
        String(decoding: data(), as: UTF8.self)
    }
}
