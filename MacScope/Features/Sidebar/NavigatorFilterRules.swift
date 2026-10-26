import Foundation
import LumenUI

/// U8-3: structured filters for the Symbols and Strings navigators, edited with `LumenRuleEditor`
/// ("[All] of the following are true" over [field] [operator] [value] rows). They narrow the rows
/// the text filter leaves; a row whose value is empty is ignored, so a fresh rule filters nothing.
struct NavigatorFilterRules: Equatable {
    var match: LumenRuleMatch = .all
    var conditions: [LumenRuleCondition]

    init(tool: WorkspaceTool) {
        let field = NavigatorFilterField.fields(for: tool).first ?? ""
        conditions = [LumenRuleCondition(field: field, comparison: NavigatorFilterField.comparisons(for: field).first ?? "",
                                         id: Self.defaultConditionID(for: tool))]
    }

    /// The fresh rule's condition keeps one id per tool. The sidebar rebuilds this rule on every read
    /// until the first edit stores it, and `LumenRuleEditor` writes by condition id, so a new id per
    /// read would drop that first edit.
    static func defaultConditionID(for tool: WorkspaceTool) -> UUID {
        let index = WorkspaceTool.allCases.firstIndex(of: tool) ?? 0
        return UUID(uuidString: String(format: "4E415646-494C-5452-0000-%012X", index))!
    }

    /// The conditions that filter: those with a value.
    var effectiveConditions: [LumenRuleCondition] {
        conditions.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var isActive: Bool { !effectiveConditions.isEmpty }

    /// Whether a row with these field values passes. Fields a row doesn't have read as empty.
    func matches(_ fields: [String: String]) -> Bool {
        let results = effectiveConditions.map { NavigatorFilterField.evaluate($0, value: fields[$0.field] ?? "") }
        guard !results.isEmpty else { return true }
        switch match {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.contains(true)
        case .none: return !results.contains(true)
        }
    }
}

/// The fields and operators each navigator offers, and how a condition reads a row's value.
enum NavigatorFilterField {
    static let name = "Name", kind = "Kind", library = "Library", address = "Address"
    static let text = "Text", section = "Section", length = "Length"

    static let contains = "contains", isEqual = "is", beginsWith = "begins with", endsWith = "ends with"
    static let doesNotContain = "doesn't contain", greaterThan = "greater than", lessThan = "less than"
    /// A regular expression, offered for a string's text only.
    static let matchesPattern = "matches"

    /// The tools with rule filters.
    static func supports(_ tool: WorkspaceTool) -> Bool { !fields(for: tool).isEmpty }

    static func fields(for tool: WorkspaceTool) -> [String] {
        switch tool {
        case .symbols: [name, kind, library, address]
        case .strings: [text, section, length, address]
        default: []
        }
    }

    static func isNumeric(_ field: String) -> Bool { field == address || field == length }

    static func comparisons(for field: String) -> [String] {
        if isNumeric(field) { return [isEqual, greaterThan, lessThan] }
        let text = [contains, isEqual, beginsWith, endsWith, doesNotContain]
        return field == Self.text ? text + [matchesPattern] : text
    }

    static func evaluate(_ condition: LumenRuleCondition, value: String) -> Bool {
        let wanted = condition.value.trimmingCharacters(in: .whitespaces)
        if isNumeric(condition.field) {
            guard let lhs = number(value, field: condition.field), let rhs = number(wanted, field: condition.field) else { return false }
            switch condition.comparison {
            case greaterThan: return lhs > rhs
            case lessThan: return lhs < rhs
            default: return lhs == rhs
            }
        }
        switch condition.comparison {
        case isEqual: return value.compare(wanted, options: [.caseInsensitive]) == .orderedSame
        case beginsWith: return value.range(of: wanted, options: [.caseInsensitive, .anchored]) != nil
        case endsWith: return value.range(of: wanted, options: [.caseInsensitive, .anchored, .backwards]) != nil
        case doesNotContain: return !value.localizedCaseInsensitiveContains(wanted)
        case matchesPattern:
            // An invalid pattern matches nothing rather than everything.
            guard let regex = try? NSRegularExpression(pattern: wanted, options: [.caseInsensitive]) else { return false }
            return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        default: return value.localizedCaseInsensitiveContains(wanted)
        }
    }

    /// An address reads as hex (with or without 0x); a length as decimal.
    static func number(_ text: String, field: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard field == address else { return UInt64(trimmed) }
        let digits = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        return UInt64(digits, radix: 16)
    }
}
