import Foundation
import XCTest
@testable import MacScope

final class C131WiringContractTests: XCTestCase {
    private func function(_ name: String, start: UInt64 = 0x1000, rows: Int = 1) -> MacIRFunction {
        var instructions = (0..<rows).map { index in
            MacIRInstruction(source: .init(address: start + UInt64(index * 4), byteText: "",
                mnemonic: "nop", operands: ""),
                operation: .intrinsic(destination: nil, name: "capture_tick", arguments: []))
        }
        instructions.append(.init(source: .init(address: start + UInt64(rows * 4),
            byteText: "", mnemonic: "ret", operands: ""), operation: .returnValue(nil)))
        return MacIRFunction(name: name, startAddress: start, instructions: instructions)
    }
    private func printer(capture: PseudocodePrinter.RenderCapture? = nil) -> PseudocodePrinter {
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        var printer = PseudocodePrinter(options: options)
        printer.renderCapture = capture
        return printer
    }

    func testFreshCaptureKeepsExactInvocationAndDocument() throws {
        let capture = PseudocodePrinter.RenderCapture()
        let printer = printer(capture: capture)
        let original = function("first")
        XCTAssertNil(capture.output)
        let document = printer.print(function: original)
        let output = try XCTUnwrap(capture.output)
        XCTAssertEqual(output.originalFunction, original)
        XCTAssertEqual(output.renderedFunction.name, original.name)
        XCTAssertEqual(output.renderedFunction.startAddress, original.startAddress)
        XCTAssertEqual(output.document, document)
        XCTAssertEqual(output.document.lines, document.lines)
        XCTAssertEqual(output.options, printer.options)
    }

    func testCopiedPrinterReusePermanentlyInvalidatesCapture() throws {
        let capture = PseudocodePrinter.RenderCapture()
        let first = printer(capture: capture)
        let second = first
        _ = first.print(function: function("first"))
        XCTAssertNotNil(capture.output)
        let secondDocument = second.print(function: function("second", start: 0x2000))
        XCTAssertEqual(secondDocument.functionName, "second", "Rendering still completes")
        XCTAssertNil(capture.output, "Second begin must revoke the reusable output slot")
        _ = first.print(function: function("third", start: 0x3000))
        XCTAssertNil(capture.output, "Invalid is permanent; a later begin cannot reset it")
    }

    private final class WorkerResult: @unchecked Sendable {
        private let lock = NSLock()
        private var document: PseudocodeDocument?
        private var failure: String?
        func finish(document: PseudocodeDocument?, failure: String?) {
            lock.lock(); defer { lock.unlock() }
            self.document = document; self.failure = failure
        }
        func read() -> (PseudocodeDocument?, String?) {
            lock.lock(); defer { lock.unlock() }
            return (document, failure)
        }
    }

    func testOverlappingCopiedPrintersCannotCombineCaptureRecords() throws {
        let capture = PseudocodePrinter.RenderCapture()
        let first = printer(capture: capture), second = first
        // The first 64 emitted lines reach the existing checkpoint after begin
        // and before complete. No fixture, process, timer race or new test hook.
        let original = function("paused_first", rows: 160)
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = WorkerResult()
        DispatchQueue.global().async {
            var paused = false
            do {
                let document = try first.print(function: original, checkpoint: {
                    guard !paused else { return }
                    paused = true
                    entered.signal()
                    guard resume.wait(timeout: .now() + 5) == .success else {
                        throw NSError(domain: "C131CheckpointTimeout", code: 1)
                    }
                })
                result.finish(document: document, failure: nil)
            } catch { result.finish(document: nil, failure: String(describing: error)) }
            finished.signal()
        }
        defer { resume.signal() }
        guard entered.wait(timeout: .now() + 5) == .success else {
            resume.signal()
            _ = finished.wait(timeout: .now() + 5)
            return XCTFail("Authored first render did not reach its checkpoint")
        }
        XCTAssertNil(capture.output, "First invocation has not completed")
        let other = second.print(function: function("overlapping_second", start: 0x4000))
        XCTAssertEqual(other.functionName, "overlapping_second")
        XCTAssertNil(capture.output, "Overlapping begin invalidates rather than replacing original")
        resume.signal()
        guard finished.wait(timeout: .now() + 5) == .success else {
            return XCTFail("Authored first render did not finish after release")
        }
        let (document, failure) = result.read()
        XCTAssertNil(failure)
        XCTAssertEqual(document?.functionName, "paused_first")
        XCTAssertNil(capture.output, "First complete cannot restore invalid mixed evidence")
    }

    func testNilCaptureKeepsAuthoredRenderingAndSourceOrder() throws {
        let original = function("same_output", rows: 12)
        let plain = printer()
        let plainDocument = plain.print(function: original)
        let capture = PseudocodePrinter.RenderCapture()
        let capturedDocument = printer(capture: capture).print(function: original)
        XCTAssertNil(plain.renderCapture)
        XCTAssertEqual(plainDocument, capturedDocument)
        XCTAssertEqual(plainDocument.lines.map(\.source), capturedDocument.lines.map(\.source))
        XCTAssertEqual(try XCTUnwrap(capture.output).document, plainDocument)
    }
}
