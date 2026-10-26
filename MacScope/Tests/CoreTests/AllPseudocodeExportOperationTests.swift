import Foundation
import Darwin
import XCTest
@testable import MacScope

@MainActor
final class AllPseudocodeExportOperationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllPseudocodeExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func owner(documentGeneration: UInt64 = 7, binaryID: UUID? = nil,
                       windowGeneration: UUID? = nil) -> AllPseudocodeExportOperation.Owner {
        .init(documentID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
              windowGeneration: windowGeneration ?? UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
              documentGeneration: documentGeneration, imageSlot: 1,
              binaryID: binaryID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    }

    private func operation(_ addresses: [UInt64] = [0x30, 0x10, 0x20],
                           owner: AllPseudocodeExportOperation.Owner? = nil) -> AllPseudocodeExportOperation {
        .init(owner: owner ?? self.owner(), items: addresses.map { .init(startAddress: $0) })
    }

    private var spoolParent: URL { directory.appendingPathComponent("spool", isDirectory: true) }

    private func spoolFactory() -> @Sendable () throws -> any PseudocodeExportSink {
        let parent = spoolParent
        return {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            return try PseudocodeExportSpool(parent: parent)
        }
    }

    private var spoolEntries: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: spoolParent.path)) ?? []
    }

    private func run(_ op: AllPseudocodeExportOperation, maxProgressUpdates: Int = 32,
                     renderer: @escaping @Sendable (AllPseudocodeExportOperation.Item) throws -> String?,
                     progress: @escaping @Sendable (AllPseudocodeExportOperation.Progress) async -> Void = { _ in })
        async throws -> AllPseudocodeExportOperation.Output {
        try await op.run(maxProgressUpdates: maxProgressUpdates, makeSink: spoolFactory(),
                         renderer: renderer, progress: progress)
    }

    private func destination(_ name: String = "out.txt") -> URL { directory.appendingPathComponent(name) }

    /// Publishes to a fresh destination and returns its bytes.
    private func published(_ op: AllPseudocodeExportOperation, _ output: AllPseudocodeExportOperation.Output,
                           owner: AllPseudocodeExportOperation.Owner? = nil) throws -> Data {
        let url = destination("published-\(UUID().uuidString).txt")
        try op.publish(output, currentOwner: owner ?? self.owner(), to: url)
        return try Data(contentsOf: url)
    }

    func testRendererUsesDedicatedStack() async throws {
        let op = operation([0x10])
        let output = try await run(op) { _ in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertGreaterThanOrEqual(pthread_get_stacksize_np(pthread_self()), 16 * 1_024 * 1_024)
            return "rendered"
        }
        XCTAssertEqual(try published(op, output), Data("rendered".utf8))
    }

    func testOrderedBlocksPreserveExactSeparators() async throws {
        let op = operation()
        let output = try await run(op) { item in
            [0x10: "A", 0x20: "B", 0x30: "C"][Int(item.startAddress)]
        }
        XCTAssertEqual(try published(op, output), Data("A\n\nB\n\nC".utf8))

        let unicode = operation()
        let unicodeOutput = try await run(unicode) { item in
            [0x10: "α\r\n", 0x20: "", 0x30: "猫 e\u{301}\n"][Int(item.startAddress)]
        }
        XCTAssertEqual(try published(unicode, unicodeOutput), Data("α\r\n\n\n\n\n猫 e\u{301}\n".utf8))
        XCTAssertEqual(spoolEntries, [])
    }

    /// The spooled bytes equal the in-memory join this operation used to publish, block for block,
    /// including skipped inputs, empty blocks, CRLF, combining marks and astral scalars.
    func testSpoolOutputIsByteIdenticalToInMemoryJoin() async throws {
        let blocks: [UInt64: String?] = [
            0x10: "int64_t a(void) {\n}\n", 0x20: nil, 0x30: "", 0x40: "// é\r\nx = 1;",
            0x50: nil, 0x60: "𝔘 e\u{301} 猫\n\n", 0x70: "", 0x80: "tail",
        ]
        let addresses = blocks.keys.sorted()
        let reference = addresses.compactMap { blocks[$0]! }.joined(separator: "\n\n")
        let op = operation(addresses.reversed())
        let output = try await run(op) { blocks[$0.startAddress]! }
        XCTAssertEqual(output.byteCount, reference.utf8.count)
        XCTAssertEqual(try published(op, output), Data(reference.utf8))
    }

    /// The MacScope-source export through the operation matches the synchronous join in
    /// `DocumentExportService.renderAllPseudocode` for the same fixture snapshot.
    func testMacScopeSourceExportMatchesSynchronousRender() async throws {
        let snapshot = AnalysisEngine.previewSnapshot()
        let slot = snapshot.primarySlot
        let functions = snapshot.analysis(in: slot)?.functions ?? []
        XCTAssertGreaterThan(functions.count, 1, "fixture needs several functions")
        let service = DocumentExportService()
        let reference = service.renderAllPseudocode(snapshot: snapshot, in: slot)
        XCTAssertFalse(reference.isEmpty)
        let options = DecompilerOptions(userDefaults: .standard)
        let op = operation(functions.map(\.startAddress))
        let output = try await run(op) { item in
            DocumentExportService().renderAllPseudocodeBlock(snapshot: snapshot, startAddress: item.startAddress,
                                                             in: slot, options: options)
        }
        XCTAssertEqual(try published(op, output), Data(reference.utf8))
    }

    func testPublishReplacesExistingDestinationAndRemovesSpool() async throws {
        let url = destination()
        try Data("prior destination\n".utf8).write(to: url)
        let op = operation([0x10])
        let output = try await run(op) { _ in "new text" }
        XCTAssertEqual(spoolEntries.count, 1)
        try op.publish(output, currentOwner: owner(), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("new text".utf8))
        XCTAssertEqual(spoolEntries, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["out.txt", "spool"])
    }

    func testCancelBetweenFunctionsNeverPublishesPartialOutput() async throws {
        let op = operation()
        let calls = Calls()
        let events = Events()
        do {
            let output = try await run(op, renderer: { item in
                calls.append(item.startAddress)
                op.cancel()
                return "first block"
            }, progress: { await events.append($0) })
            try op.publish(output, currentOwner: owner(), to: destination())
            XCTFail("Cancelled render returned publishable output")
        } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(calls.values, [0x10])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path))
        XCTAssertEqual(spoolEntries, [])
        let actual = await events.values
        XCTAssertEqual(actual, [.init(completed: 0, total: 3, phase: .rendering),
                                .init(completed: 1, total: 3, phase: .cancelled)])
    }

    func testRendererFailureRetiresOperationAndPreservesDestination() async throws {
        enum Injected: Error { case secondItem }
        let op = operation()
        let events = Events()
        let url = destination("existing.txt")
        try Data("prior destination\n".utf8).write(to: url)
        do {
            let output = try await run(op, renderer: { item in
                if item.startAddress == 0x20 { throw Injected.secondItem }
                return "uncommitted"
            }, progress: { await events.append($0) })
            try op.publish(output, currentOwner: owner(), to: url)
            XCTFail("Expected failure")
        } catch Injected.secondItem {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(try Data(contentsOf: url), Data("prior destination\n".utf8))
        XCTAssertEqual(spoolEntries, [])
        let actual = await events.values
        XCTAssertEqual(actual.filter { $0.phase == .failed }.count, 1)
        XCTAssertFalse(actual.contains { $0.phase == .completed })
        XCTAssertEqual(actual.last, .init(completed: 1, total: 3, phase: .failed))
        do { _ = try await run(op) { _ in "retry" }; XCTFail("Must be retired") }
        catch { XCTAssertEqual(error as? AllPseudocodeExportOperation.Failure, .alreadyStarted) }
    }

    func testSpoolDiskFailureFailsExportAndRemovesSpool() async throws {
        let op = operation()
        let failing = FailingSink(failOnAppend: 2)
        let events = Events()
        do {
            _ = try await op.run(makeSink: { failing }, renderer: { _ in "block" },
                                 progress: { await events.append($0) })
            XCTFail("Expected disk failure")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteOutOfSpace)
        }
        XCTAssertTrue(failing.removed)
        let actual = await events.values
        XCTAssertEqual(actual.last?.phase, .failed)
    }

    func testOldGenerationCannotPublishIntoReplacementOwner() async throws {
        let op = operation([0x10])
        let output = try await run(op) { _ in "captured B" }
        let replacements = [owner(documentGeneration: 8), owner(binaryID: UUID()),
                            owner(windowGeneration: UUID())]
        for replacement in replacements {
            XCTAssertThrowsError(try op.publish(output, currentOwner: replacement, to: destination())) {
                XCTAssertEqual($0 as? AllPseudocodeExportOperation.Failure, .staleOwner)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path))
        op.cancel()
        XCTAssertThrowsError(try op.publish(output, currentOwner: owner(), to: destination()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path))
        XCTAssertEqual(spoolEntries, [])
        let later = operation([0x10], owner: replacements[0])
        let laterOutput = try await run(later) { _ in "new generation" }
        XCTAssertEqual(try published(later, laterOutput, owner: replacements[0]), Data("new generation".utf8))
    }

    func testProgressIsMonotonicAndBounded() async throws {
        let op = operation(Array(1...17).map(UInt64.init))
        let events = Events()
        _ = try await run(op, maxProgressUpdates: 4, renderer: { _ in "x" },
                          progress: { await events.append($0) })
        let actual = await events.values
        XCTAssertEqual(actual.map(\.completed), [0, 5, 10, 15, 17])
        XCTAssertEqual(actual.map(\.total), [17, 17, 17, 17, 17])
        XCTAssertEqual(actual.map(\.phase), [.rendering, .rendering, .rendering, .rendering, .completed])
        XCTAssertLessThanOrEqual(actual.count, 6)
    }

    func testSkippedInputsAndEmptyWorkRetainEmptyStringContract() async throws {
        let op = operation()
        let result = try await run(op) { $0.startAddress == 0x20 ? nil : "" }
        XCTAssertEqual(try published(op, result), Data("\n\n".utf8))
        let empty = operation([])
        let emptyResult = try await run(empty) { _ in XCTFail("No input"); return "wrong" }
        XCTAssertEqual(try published(empty, emptyResult), Data())
    }

    func testPreCancellationNeverRendersAndRetiresOnce() async throws {
        let op = operation()
        let calls = Calls()
        let events = Events()
        op.cancel()
        do {
            _ = try await run(op, renderer: { calls.append($0.startAddress); return "wrong" },
                              progress: { await events.append($0) })
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(calls.values, [])
        let actual = await events.values
        XCTAssertEqual(actual.last, .init(completed: 0, total: 3, phase: .cancelled))
        do { _ = try await run(op) { _ in "wrong" }; XCTFail("Must not restart") }
        catch { XCTAssertEqual(error as? AllPseudocodeExportOperation.Failure, .alreadyStarted) }
    }

    func testCancellationAfterRenderingStillPreventsPublication() async throws {
        let op = operation([0x10])
        let events = Events()
        let output = try await run(op, renderer: { _ in "complete but not committed" }, progress: { event in
            await events.append(event)
            if event.phase == .completed { op.cancel() }
        })
        XCTAssertTrue(op.isCancelled)
        XCTAssertEqual(spoolEntries, [], "cancelling a finished export removes its spool")
        XCTAssertThrowsError(try op.publish(output, currentOwner: owner(), to: destination())) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path))
        let actual = await events.values
        XCTAssertEqual(actual.map(\.phase), [.rendering, .completed])
    }

    func testPublicationIsSingleUseAndRejectsForeignOutput() async throws {
        let op = operation([0x10])
        let other = operation([0x10])
        let result = try await run(op) { _ in "one" }
        let foreign = try await run(other) { _ in "other" }
        XCTAssertThrowsError(try op.publish(foreign, currentOwner: owner(), to: destination("foreign.txt")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination("foreign.txt").path))
        XCTAssertEqual(try published(op, result), Data("one".utf8))
        XCTAssertThrowsError(try op.publish(result, currentOwner: owner(), to: destination("again.txt")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination("again.txt").path))
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt64] = []
    func append(_ value: UInt64) { lock.withLock { storage.append(value) } }
    var values: [UInt64] { lock.withLock { storage } }
}

private actor Events {
    var values: [AllPseudocodeExportOperation.Progress] = []
    func append(_ value: AllPseudocodeExportOperation.Progress) { values.append(value) }
}

private final class FailingSink: PseudocodeExportSink, @unchecked Sendable {
    let textURL = URL(fileURLWithPath: "/nonexistent/all-pseudocode-export-test")
    private let lock = NSLock()
    private let failOnAppend: Int
    private var appends = 0
    private var didRemove = false
    init(failOnAppend: Int) { self.failOnAppend = failOnAppend }
    func append(_ data: Data) throws {
        try lock.withLock {
            appends += 1
            if appends == failOnAppend { throw CocoaError(.fileWriteOutOfSpace) }
        }
    }
    func finish() throws -> String { String(repeating: "0", count: 64) }
    func remove() { lock.withLock { didRemove = true } }
    var removed: Bool { lock.withLock { didRemove } }
}
