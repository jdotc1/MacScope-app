import Darwin
import Foundation
import XCTest
@testable import MacScope

final class OperationCoreStackHeadroomTests: XCTestCase {
    func testSSAFunctionCompletesOnSmallStack() {
        let completed = expectation(description: "SSA build completed on the small stack")
        // Keep this near the cooperative-pool budget seen in the crash reports.
        // The budget includes the SSA builder and its callers, not just operationCore.
        let stackBytes = 512 * 1_024
        // Apple's libpthread src/pthread.c _pthread_allocate adds arm64's
        // PTHREAD_T_OFFSET (12 KiB, src/types_internal.h) to library-owned stacks.
        // A custom stack uses exactly attrs->stacksize and needs its own guard.
        // Source: github.com/apple-oss-distributions/libpthread (both files).
        let pageBytes = Int(getpagesize())
        XCTAssertEqual(stackBytes % pageBytes, 0)
        let mappedBytes = pageBytes + stackBytes
        let mapped: UnsafeMutableRawPointer? = mmap(
            nil, mappedBytes, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let mapping = mapped, mapping != MAP_FAILED else {
            return XCTFail("mmap for guarded stack failed: \(errno)")
        }
        // Only the parent reclaims this caller-owned stack, after pthread_join.
        // Failure/timeout after creation retains it rather than unmapping live SP.
        var mayUnmap = true
        defer {
            if mayUnmap {
                XCTAssertEqual(munmap(mapping, mappedBytes), 0)
            }
        }
        let stackBase = mapping.advanced(by: pageBytes)
        XCTAssertEqual(stackBase.advanced(by: stackBytes), mapping.advanced(by: mappedBytes))
        let writable = mprotect(stackBase, stackBytes, PROT_READ | PROT_WRITE)
        guard writable == 0 else {
            return XCTFail("mprotect for usable stack failed: \(errno)")
        }
        // mmap left [mapping, stackBase) PROT_NONE: exactly one lower guard page.
        XCTAssertEqual(mapping.distance(to: stackBase), pageBytes)
        var attributes = pthread_attr_t()
        let initialized = pthread_attr_init(&attributes)
        guard initialized == 0 else {
            return XCTFail("pthread_attr_init failed: \(initialized)")
        }
        defer { pthread_attr_destroy(&attributes) }
        let sized = pthread_attr_setstack(&attributes, stackBase, stackBytes)
        guard sized == 0 else {
            return XCTFail("pthread_attr_setstack failed: \(sized)")
        }
        var configuredBase: UnsafeMutableRawPointer?
        var configuredBytes = 0
        let inspected = pthread_attr_getstack(&attributes, &configuredBase, &configuredBytes)
        guard inspected == 0 else {
            return XCTFail("pthread_attr_getstack failed: \(inspected)")
        }
        XCTAssertEqual(configuredBase, stackBase)
        XCTAssertEqual(configuredBytes, stackBytes)
        // Keep the default JOINABLE state so termination precedes stack release.

        // The C entry point cannot capture Swift context. Transfer the expectation
        // to the joinable thread, releasing it there (or here if creation fails).
        let context = Unmanaged.passRetained(completed).toOpaque()
        var thread: pthread_t?
        let created = pthread_create(&thread, &attributes, { context in
            let completed = Unmanaged<XCTestExpectation>.fromOpaque(context).takeRetainedValue()
            defer { completed.fulfill() }
            let stackBytes = 512 * 1_024
            let actualStackBytes = pthread_get_stacksize_np(pthread_self())
            XCTAssertEqual(actualStackBytes, stackBytes)
            guard actualStackBytes == stackBytes else { return nil }
            let assembly = [
                ("adrp", "x8, 0x4000"),
                ("ldr", "x9, [x8]"),
                ("str", "x9, [sp, #16]"),
                ("stp", "x9, x10, [sp, #32]"),
                ("ldp", "x11, x12, [sp, #32]"),
                ("ldr", "x13, [sp, #16]"),
                // Non-stack pair writeback must still reach the unknown fallback.
                ("stp", "x9, x10, [x8, #16]!"),
                ("mov", "x0, x13"),
                ("ret", "")
            ]
            let rows = assembly.enumerated().map { index, instruction in
                InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "00 00 00 00",
                               mnemonic: instruction.0, operands: instruction.1,
                               hasBreakpoint: false, comment: nil)
            }
            let function = MacIRBuilder(ssaEnabled: true).buildFunction(
                name: "small_stack_memory", startAddress: 0x1000,
                callerReturnWidth: .x0, instructions: rows)
            XCTAssertTrue(function.ssaEnabled)
            XCTAssertEqual(function.instructions.map(\.source.address), rows.map(\.address))
            guard let refused = function.instructions.first(where: { $0.source.address == 0x1018 }),
                  case .unknown = refused.operation else {
                XCTFail("Non-stack pair writeback must retain the shared unknown fallback")
                return nil
            }
            return nil
        }, context)
        guard created == 0 else {
            Unmanaged<XCTestExpectation>.fromOpaque(context).release()
            return XCTFail("pthread_create failed: \(created)")
        }
        mayUnmap = false
        guard let thread else {
            return XCTFail("pthread_create succeeded without a handle; retained stack mapping \(mapping), bytes=\(mappedBytes)")
        }
        guard XCTWaiter.wait(for: [completed], timeout: 30) == .completed else {
            return XCTFail("SSA build timed out; retained joinable thread \(thread) and stack mapping \(mapping), bytes=\(mappedBytes); no unsafe unmap")
        }
        let joined = pthread_join(thread, nil)
        guard joined == 0 else {
            return XCTFail("pthread_join failed: \(joined); retained thread \(thread) and stack mapping \(mapping), bytes=\(mappedBytes)")
        }
        mayUnmap = true
    }
}
