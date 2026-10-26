import Foundation
import XCTest
@testable import MacScope

/// A single identity map is shared by all converted assertions in a test.
/// Only register version digits may differ; views and all other text stay exact.
struct SSAAlphaEquivalence {
    struct ExpectedIdentity: Hashable {
        let name: String
        let version: Int
    }

    struct Identity: Hashable {
        let cell: Int
        let version: Int
    }

    struct Definition: Equatable {
        /// Nil denotes the architectural entry definition, not an unknown row.
        let sourceRow: UInt64?
        let width: Int
    }

    private(set) var forward: [ExpectedIdentity: Identity] = [:]
    private var reverse: [Identity: Set<ExpectedIdentity>] = [:]
    private var expectedDefinitions: [ExpectedIdentity: Definition]
    private var actualDefinitions: [Identity: Definition]
    private var provenanceError: String?

    init(expectedDefinitions: [ExpectedIdentity: Definition] = [:],
         actualDefinitions: [Identity: Definition] = [:]) {
        self.expectedDefinitions = expectedDefinitions
        self.actualDefinitions = actualDefinitions
    }

    init(expected: MacIRFunction, actual: MacIRFunction) {
        let expectedRecords = Self.definitions(in: expected)
        let actualRecords = Self.definitions(in: actual)
        expectedDefinitions = expectedRecords.values
        actualDefinitions = [:]
        provenanceError = expectedRecords.error ?? actualRecords.error
        for (token, definition) in actualRecords.values {
            guard let cell = Self.cell(for: token.name) else { continue }
            let identity = Identity(cell: cell, version: token.version)
            if let old = actualDefinitions[identity], old != definition {
                provenanceError = "Actual cell identity has conflicting defining rows or widths"
            }
            actualDefinitions[identity] = definition
        }
    }

    /// Lift the same captured input with the legacy identity namespace. This
    /// supplies provenance only; it does not replace the frozen text authority.
    static func legacyFunction(from input: PseudocodeRenderInput) -> MacIRFunction {
        return MacIRConfiguration.$ssaOverride.withValue(false) {
            return PseudocodePrinter(options: .default).buildFunction(
                functionName: input.functionName, startAddress: input.startAddress,
                jumpTables: input.jumpTables, objcSelectors: input.objcSelectors,
                constantStrings: input.constantStrings, signatureOverrides: input.signatureOverrides,
                authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
                directCallVoidResultTargets: input.directCallVoidResultTargets,
                slotCallContracts: input.slotCallContracts, callerReturnWidth: input.callerReturnWidth,
                callerReturnType: input.callerReturnType, types: input.types, instructions: input.instructions)
        }
    }

    private static func cell(for name: String) -> Int? {
        guard name.first == "w" || name.first == "x",
              let cell = Int(name.dropFirst()), (0...30).contains(cell) else { return nil }
        return cell
    }

    private static func definitions(in function: MacIRFunction)
        -> (values: [ExpectedIdentity: Definition], error: String?) {
        var result: [ExpectedIdentity: Definition] = [:]
        var error: String?
        func record(_ value: MacIRValue, row: UInt64?, width: Int? = nil) {
            if case let .abiComposite(_, fragments) = value {
                fragments.forEach { record($0, row: row, width: width) }
                return
            }
            guard case let .register(name, version) = value, cell(for: name) != nil else { return }
            let key = ExpectedIdentity(name: name, version: version)
            let definition = Definition(sourceRow: row, width: width ?? (name.first == "w" ? 32 : 64))
            if let old = result[key], old != definition {
                error = "Register identity has conflicting defining rows or widths"
            }
            result[key] = definition
        }
        for cell in 0...30 {
            for view in ["w", "x"] {
                record(.register(name: "\(view)\(cell)", version: 0), row: nil, width: 64)
            }
        }
        for instruction in function.instructions {
            let row = instruction.source.address
            switch instruction.operation {
            case let .assign(destination, _), let .binary(destination, _, _, _),
                 let .load(destination, _), let .stackSlotRead(destination, _, _),
                 let .select(destination, _, _, _, _, _), let .compareToBool(destination, _, _, _):
                record(destination, row: row)
            case let .loadWriteback(destination, base, _, _, _):
                record(destination, row: row)
                record(base, row: row)
            case let .storeWriteback(_, base, _, _, _):
                record(base, row: row)
            case let .stackSlotPairRead(first, _, _, second, _, _):
                record(first, row: row)
                record(second, row: row)
            case let .intrinsic(destination, name, arguments):
                if let destination { record(destination, row: row) }
                if name == "restore_pair" || name == "restore_pair_writeback" {
                    arguments.prefix(2).forEach { record($0, row: row) }
                }
                if (name == "restore_pair_writeback" || name == "save_pair_writeback"), arguments.count == 6 {
                    record(arguments[3], row: row)
                }
            case let .call(_, destination), let .unknown(destination, _, _, _):
                if let destination { record(destination, row: row) }
            default:
                break
            }
        }
        for phi in function.phis {
            record(phi.destination, row: phi.blockAddress, width: phi.bitWidth)
        }
        if let info = function.ssaInfo {
            for (row, bindings) in info.plan.rowWriteBindings.enumerated() {
                guard info.sourceAddresses.indices.contains(row) else {
                    error = "SSA write binding has no source row"
                    continue
                }
                for id in bindings.values {
                    let canonical = info.plan.canonicalID(id)
                    guard info.plan.definitions.indices.contains(canonical), let value = info.values[canonical] else {
                        error = "SSA write binding has no definition"
                        continue
                    }
                    let definition = info.plan.definitions[canonical]
                    // An alias may point at an earlier definition: its write slot
                    // is not evidence that the earlier value was defined here.
                    if canonical != id { continue }
                    record(value, row: info.sourceAddresses[row], width: definition.bitWidth)
                }
            }
            for definition in info.plan.definitions where info.plan.canonicalID(definition.id) == definition.id {
                guard let value = info.values[definition.id] else { continue }
                switch definition.origin {
                case .entry:
                    record(value, row: nil, width: definition.bitWidth)
                case let .instruction(address), let .callClobber(address), let .refusal(_, address):
                    record(value, row: address, width: definition.bitWidth)
                case .phi, .callResult:
                    // Phi and call rows were recorded from their typed IR above
                    // or the explicit row-write table, never from textual order.
                    break
                }
            }
        }
        return (result, error)
    }

    private static let registers = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])([xw])([0-9]|[12][0-9]|30)_([0-9]+)(?![A-Za-z0-9_])"#)

    mutating func mismatch(actual: String, expected: String) -> String? {
        if let provenanceError { return provenanceError }
        guard let registers = Self.registers else { return "Invalid register token pattern" }
        let actualText = actual as NSString
        let expectedText = expected as NSString
        let actualTokens = registers.matches(in: actual, range: NSRange(location: 0, length: actualText.length))
        let expectedTokens = registers.matches(in: expected, range: NSRange(location: 0, length: expectedText.length))
        guard actualTokens.count == expectedTokens.count else { return "Register occurrence count changed" }
        var candidate = self
        var actualOffset = 0
        var expectedOffset = 0
        for (actualToken, expectedToken) in zip(actualTokens, expectedTokens) {
            let actualVersion = actualToken.range(at: 3)
            let expectedVersion = expectedToken.range(at: 3)
            let actualPrefix = actualText.substring(with: NSRange(location: actualOffset, length: actualVersion.location - actualOffset))
            let expectedPrefix = expectedText.substring(with: NSRange(location: expectedOffset, length: expectedVersion.location - expectedOffset))
            guard actualPrefix == expectedPrefix else { return "Text outside register version digits changed" }
            guard let actualCell = Int(actualText.substring(with: actualToken.range(at: 2))),
                  let actualNumber = Int(actualText.substring(with: actualVersion)),
                  let expectedNumber = Int(expectedText.substring(with: expectedVersion)) else {
                return "Register identity is not representable"
            }
            let expectedName = expectedText.substring(with: expectedToken.range(at: 1))
                + expectedText.substring(with: expectedToken.range(at: 2))
            let source = ExpectedIdentity(name: expectedName, version: expectedNumber)
            let destination = Identity(cell: actualCell, version: actualNumber)
            guard let expectedDefinition = candidate.expectedDefinitions[source],
                  let actualDefinition = candidate.actualDefinitions[destination] else {
                return "Register identity is missing defining-row provenance"
            }
            guard expectedDefinition == actualDefinition else {
                return "Defining source row or width changed"
            }
            if let existing = candidate.forward[source], existing != destination {
                return "One expected identity maps to different actual identities"
            }
            for existing in candidate.reverse[destination, default: []] where existing != source {
                guard let previousDefinition = candidate.expectedDefinitions[existing],
                      previousDefinition == expectedDefinition else {
                    return "Distinct defining source rows map to one actual identity"
                }
            }
            candidate.forward[source] = destination
            candidate.reverse[destination, default: []].insert(source)
            actualOffset = NSMaxRange(actualVersion)
            expectedOffset = NSMaxRange(expectedVersion)
        }
        guard actualText.substring(from: actualOffset) == expectedText.substring(from: expectedOffset) else {
            return "Text outside register version digits changed"
        }
        self = candidate
        return nil
    }

    /// Translate only identities already accepted by the method's shared map.
    /// No new correspondence can be inferred from an expected string alone.
    func translatedExpected(_ text: String) -> String? {
        guard provenanceError == nil, let registers = Self.registers else { return nil }
        let original = text as NSString
        let translated = NSMutableString(string: text)
        for token in registers.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            let name = original.substring(with: token.range(at: 1))
                + original.substring(with: token.range(at: 2))
            guard let version = Int(original.substring(with: token.range(at: 3))),
                  let destination = forward[ExpectedIdentity(name: name, version: version)] else { return nil }
            translated.replaceCharacters(in: token.range(at: 3), with: String(destination.version))
        }
        return translated as String
    }

    mutating func assertEquivalent(_ actual: [String], _ expected: [String],
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard actual.count == expected.count else {
            return XCTFail("Statement count changed: \(actual.count) != \(expected.count)", file: file, line: line)
        }
        for (actualLine, expectedLine) in zip(actual, expected) {
            let failure = mismatch(actual: actualLine, expected: expectedLine)
            XCTAssertNil(failure, "\(failure ?? ""); actual: \(actualLine); expected: \(expectedLine)", file: file, line: line)
        }
    }
}
