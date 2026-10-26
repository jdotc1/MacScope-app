import Foundation

/// Checks the addresses an Assistant answer quotes against the accepted grounded context.
///
/// An address token in the answer prose is supported when it equals an address, bound or
/// integer in the accepted evidence, lies inside an accepted evidence range, or equals an
/// operand literal that appears in evidence text. Hex values below one page are treated as
/// small constants or offsets rather than addresses, and decimal tokens count only when they
/// are long enough to look like addresses.
struct Phase2AssistantAddressCheck: Sendable {
    struct Token: Equatable, Sendable {
        let text: String
        /// `nil` when the token does not fit in 64 bits; such a token is never supported.
        let value: UInt64?
        let range: Range<String.Index>
    }

    static let smallestCheckedHexValue: UInt64 = 0x1000
    static let shortestCheckedDecimalDigits = 9
    static let unverifiedMarker = "(unverified address)"

    /// Addresses and bounds the evidence names, in hex, for the repair instruction.
    let evidenceAddresses: [UInt64]
    private let supportedValues: Set<UInt64>
    private let supportedRanges: [Range<UInt64>]

    init(context: Phase2GroundedContext) {
        var addresses = Set<UInt64>()
        var values = Set<UInt64>()
        var ranges: [Range<UInt64>] = []
        for record in context.records {
            for citation in record.citations {
                Self.collect(citation.target, addresses: &addresses, ranges: &ranges)
            }
            switch record.data {
            case .value(let value):
                Self.collect(value, name: nil, addresses: &addresses, values: &values, ranges: &ranges)
            case .conflict(let conflict):
                for claim in conflict.claims {
                    Self.collect(claim.value, name: nil, addresses: &addresses, values: &values, ranges: &ranges)
                    for citation in claim.citations {
                        Self.collect(citation.target, addresses: &addresses, ranges: &ranges)
                    }
                }
            case .unavailable:
                break
            }
        }
        evidenceAddresses = addresses.sorted()
        supportedValues = values.union(addresses)
        supportedRanges = ranges
    }

    /// Address tokens in `text` that the accepted evidence does not support, in order of
    /// first appearance and without repeats.
    func unsupportedAddresses(in text: String) -> [Token] {
        var seen = Set<String>()
        return Self.addressTokens(in: text).filter { token in
            !isSupported(token) && seen.insert(token.text.lowercased()).inserted
        }
    }

    func isSupported(_ token: Token) -> Bool {
        guard let value = token.value else { return false }
        return supportedValues.contains(value)
            || supportedRanges.contains { $0.contains(value) }
    }

    /// Copies `text` with every unsupported address followed by a visible marker.
    func flaggingUnsupportedAddresses(in text: String) -> String {
        var flagged = text
        for token in Self.addressTokens(in: text).reversed() where !isSupported(token) {
            flagged.replaceSubrange(token.range, with: "\(token.text) \(Self.unverifiedMarker)")
        }
        return flagged
    }

    static func hex(_ value: UInt64) -> String {
        Phase2GroundedAddressProjection.hex(value)
    }

    /// Hex tokens of at least one page and long decimal tokens, in order.
    static func addressTokens(in text: String) -> [Token] {
        let whole = NSRange(text.startIndex..., in: text)
        var tokens: [Token] = []
        for match in hexPattern.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            let literal = String(text[range])
            let value = UInt64(literal.dropFirst(2), radix: 16)
            if let value, value < smallestCheckedHexValue { continue }
            tokens.append(Token(text: literal, value: value, range: range))
        }
        for match in decimalPattern.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            let literal = String(text[range])
            guard literal.count >= shortestCheckedDecimalDigits else { continue }
            tokens.append(Token(text: literal, value: UInt64(literal), range: range))
        }
        return tokens.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: - Evidence collection

    private static let hexPattern = try! NSRegularExpression(
        pattern: "(?<![0-9A-Za-z_])0[xX][0-9A-Fa-f]+(?![0-9A-Za-z_])"
    )
    private static let decimalPattern = try! NSRegularExpression(
        pattern: "(?<![0-9A-Za-z_.])[0-9]+(?![0-9A-Za-z_]|\\.[0-9])"
    )

    private static func collect(
        _ target: Phase2ReadCitationTarget,
        addresses: inout Set<UInt64>,
        ranges: inout [Range<UInt64>]
    ) {
        switch target {
        case .staticLocation(let location):
            addresses.insert(location.address)
        case .functionRange(let range):
            addresses.insert(range.start)
            addresses.insert(range.endExclusive)
            if range.isValid { ranges.append(range.start..<range.endExclusive) }
        case .workspace, .image:
            break
        }
    }

    private static func collect(
        _ value: Phase2ReadFactValue,
        name: String?,
        addresses: inout Set<UInt64>,
        values: inout Set<UInt64>,
        ranges: inout [Range<UInt64>]
    ) {
        switch value {
        case .unsignedInteger(let integer):
            if let name, Phase2GroundedAddressProjection.addressFactNames.contains(name) {
                addresses.insert(integer)
            } else {
                values.insert(integer)
            }
        case .signedInteger(let integer):
            values.insert(UInt64(bitPattern: integer))
        case .text(let text):
            values.formUnion(literals(in: text))
        case .staticLocation(let location):
            addresses.insert(location.address)
        case .list(let items):
            for item in items {
                collect(item, name: name, addresses: &addresses, values: &values, ranges: &ranges)
            }
        case .object(let fields):
            for field in fields {
                collect(field.value, name: field.name, addresses: &addresses, values: &values, ranges: &ranges)
            }
            if case .unsignedInteger(let start)? = fields.first(where: { $0.name == "start" })?.value,
               case .unsignedInteger(let end)? = fields.first(where: { $0.name == "endExclusive" })?.value,
               start < end {
                ranges.append(start..<end)
            }
        case .boolean:
            break
        }
    }

    /// Every hex or decimal literal in evidence text, such as instruction operands.
    private static func literals(in text: String) -> Set<UInt64> {
        let whole = NSRange(text.startIndex..., in: text)
        var values = Set<UInt64>()
        for match in hexPattern.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text),
                  let value = UInt64(text[range].dropFirst(2), radix: 16)
            else { continue }
            values.insert(value)
        }
        for match in decimalPattern.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text),
                  let value = UInt64(text[range])
            else { continue }
            values.insert(value)
        }
        return values
    }
}
