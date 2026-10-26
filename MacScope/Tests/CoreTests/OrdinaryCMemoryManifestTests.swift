import Foundation
import XCTest

/// One complete real jinit upsampler render, reused for all manifest mutations.
/// No reduced instruction stream, replacement Contract, source/candidate machine
/// execution or previously passed selector is used by this bounded new control.
final class OrdinaryCMemoryManifestTests: XCTestCase {
    private typealias C = OrdinaryC

    func testRealUpsamplerUnscaledLoadsRejectWrongWidthAndExtraEffect() throws {
        let fixtures = try OrdinaryCUpsamplerFixturePair.make(.jinit)
        try fixtures.requireFullTypedRowOwnership()
        // Full typed output was audited above; the frozen semantic/payload oracle is explicitly opaque.
        let fixture = fixtures.opaque
        let contract = try C.contract(for: fixture)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let unscaled = fixture.rows.indices.filter { fixture.rows[$0].mnemonic == "ldur" }
        XCTAssertEqual(unscaled, [71,118,155], "all retained unscaled accesses, not just the first failing row")
        for row in unscaled {
            let original = fixture.rows[row]
            XCTAssertEqual(original.operands, row == 71 ? "w11, [x25, #-0x10]" : "w8, [x25, #-0x8]")
            let metadata = try XCTUnwrap(original.structuredOperands)
            XCTAssertEqual(metadata.opcodeClass, "ldur")
            XCTAssertEqual(metadata.semantics?.memoryAccessWidth, 32)
            XCTAssertEqual(metadata.semantics?.memoryAccess, .read)
            let first = try XCTUnwrap(metadata.operands.first), last = try XCTUnwrap(metadata.operands.last)
            guard case let .register(destination) = first,
                  case let .memory(address) = last else {
                throw C.Failure.invalidContract("retained LDUR operands are not register/memory")
            }
            XCTAssertEqual(destination.width, 32)
            XCTAssertEqual(address.displacement, row == 71 ? -16 : -8)
            XCTAssertEqual(address.indexing, .offset)
            XCTAssertFalse(address.writeback)
            let effects = try XCTUnwrap(contract.memoryEffects[row])
            XCTAssertEqual(effects.count, 1)
            XCTAssertTrue(effects.allSatisfy { $0.loading && $0.bytes == 4 })
            let sites = orderedSites(candidate, row: row)
            XCTAssertEqual(sites.map(\.site.effectOrdinal), [0])
            XCTAssertTrue(sites.allSatisfy { candidate.expressionTypes[$0.span] == .u32 }, "W LDUR fetches unsigned32 bits")
        }

        // LDRSW remains a signed32 fetch with four-byte access despite its X
        // destination. Adding LDUR must not widen or unsigned-retype it.
        let signed = fixture.rows.indices.filter { fixture.rows[$0].mnemonic == "ldrsw" }
        XCTAssertEqual(signed.count, 2)
        for row in signed {
            let effects = try XCTUnwrap(contract.memoryEffects[row])
            XCTAssertEqual(effects.count, 1)
            XCTAssertTrue(effects.allSatisfy { $0.loading && $0.bytes == 4 })
            let sites = orderedSites(candidate, row: row)
            XCTAssertEqual(sites.map(\.site.effectOrdinal), [0])
            XCTAssertTrue(sites.allSatisfy { candidate.expressionTypes[$0.span] == .i32 })
        }

        // Original STP42 remains two separately ordered eight-byte writes.
        XCTAssertEqual(fixture.rows[42].mnemonic, "stp")
        XCTAssertEqual(fixture.rows[42].operands, "x8, x9, [x0]")
        let pair = try XCTUnwrap(contract.memoryEffects[42])
        XCTAssertEqual(pair.count, 2)
        XCTAssertTrue(pair.allSatisfy { !$0.loading && $0.bytes == 8 })
        let pairSites = orderedSites(candidate, row: 42)
        XCTAssertEqual(pairSites.map(\.site.effectOrdinal), [0,1])
        XCTAssertTrue(pairSites.allSatisfy { candidate.expressionTypes[$0.span] == .u64 })

        let originalSites = orderedSites(candidate, row: 71)
        guard originalSites.count == 1 else { throw C.Failure.invalidContract("unique actual header LDUR expression missing") }
        let load = originalSites[0].span
        let tokens = Array(candidate.tokens[load.first..<load.last])
        guard tokens.count >= 5, tokens.prefix(5).map(\.text) == ["*","(","uint32_t","*",")"],
              tokens.first?.line == tokens.last?.line else {
            throw C.Failure.invalidContract("actual header load is not the retained native uint32 dereference")
        }
        let typeSpan = C.Span(first: load.first + 2, last: load.first + 3)
        let widened = try replacing(candidate, span: typeSpan, with: "uint64_t")
        requireManifestFailure("memory width/order differs at row 71, effect 0") {
            _ = try C.Program(lines: widened, contract: contract)
        }

        let probe = "oracle_extra_ldur_effect"
        guard candidate.symbols[probe] == nil, !candidate.protectedNames.contains(probe) else {
            throw C.Failure.invalidContract("extra-effect probe would shadow a real candidate name")
        }
        let loadText = try text(candidate, span: load)
        let line = tokens[0].line - 1
        guard candidate.lines[line].source == fixture.rows[71].address,
              contract.exterior[71] == nil, contract.calls[71] == nil else {
            throw C.Failure.invalidContract("extra-effect mutation is not an unprotected source71 body line")
        }
        var extra = candidate.lines
        let originalLine = extra[line]
        extra[line] = .init(text: originalLine.text + " uint32_t \(probe) = \(loadText);",
                            source: originalLine.source, envelope: originalLine.envelope)
        requireManifestFailure("extra memory effect row 71") {
            _ = try C.Program(lines: extra, contract: contract)
        }
    }

    private func orderedSites(_ candidate: C.Program, row: Int) -> [(span: C.Span, site: C.SourceSite)] {
        candidate.memorySites.filter { $0.value.row == row }.map { (span: $0.key, site: $0.value) }
            .sorted { $0.span.first < $1.span.first }
    }

    private func requireManifestFailure(_ reason: String, _ action: () throws -> Void) {
        do { try action(); XCTFail("expected exact memory manifest refusal: \(reason)") }
        catch let failure as C.Failure {
            guard case let .invalidContract(actual) = failure else { return XCTFail("wrong failure category: \(failure)") }
            XCTAssertEqual(actual, reason)
        } catch { XCTFail("unexpected infrastructure failure: \(error)") }
    }

    private func text(_ candidate: C.Program, span: C.Span) throws -> String {
        let range = try byteRange(candidate, span: span)
        let bytes = Array(candidate.lines.map(\.text).joined(separator: "\n").utf8)
        return String(decoding: bytes[range], as: UTF8.self)
    }

    private func replacing(_ candidate: C.Program, span: C.Span, with replacement: String) throws -> [C.TextLine] {
        let range = try byteRange(candidate, span: span)
        let first = candidate.tokens[span.first], last = candidate.tokens[span.last - 1]
        guard first.line == last.line else { throw C.Failure.invalidContract("memory mutation crosses actual source lines") }
        let line = first.line - 1, offset = candidate.lines.prefix(line).reduce(0) { $0 + $1.text.utf8.count + 1 }
        var bytes = Array(candidate.lines[line].text.utf8)
        bytes.replaceSubrange((range.lowerBound - offset)..<(range.upperBound - offset), with: replacement.utf8)
        var lines = candidate.lines
        lines[line] = .init(text: String(decoding: bytes, as: UTF8.self), source: lines[line].source, envelope: lines[line].envelope)
        return lines
    }

    private func byteRange(_ candidate: C.Program, span: C.Span) throws -> Range<Int> {
        guard span.first < span.last, candidate.tokens.indices.contains(span.first), candidate.tokens.indices.contains(span.last - 1) else {
            throw C.Failure.invalidContract("invalid actual memory expression span")
        }
        let first = candidate.tokens[span.first], last = candidate.tokens[span.last - 1]
        return first.byteOffset..<(last.byteOffset + last.text.utf8.count)
    }
}
