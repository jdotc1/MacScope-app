import Foundation

/// Bridges Cocoa scripting values — the `[String: Any]` an `NSScriptCommand` exposes via
/// `evaluatedArguments`, built from NSNumber / NSString / NSArray / NSDictionary — to and
/// from the in-process `ScriptValue` model. Kept pure so the conversion is unit-testable
/// without a running app or a live Apple event; the `NSScriptCommand` shell is the only
/// piece that needs the real dispatcher.
enum AppleScriptArgumentBridge {

    /// Converts one Cocoa scripting value into a `ScriptValue`. Unrecognized values (and
    /// `NSNull`) become `.null` rather than trapping — a malformed Apple event can never
    /// take down the process.
    static func scriptValue(from any: Any) -> ScriptValue {
        switch any {
        case let value as ScriptValue:
            return value
        case is NSNull:
            return .null
        case let number as NSNumber:
            // CFBoolean is an NSNumber; distinguish it so true/false round-trip as bool.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            // Integral numbers map to .int; only genuinely fractional ones to .double.
            let double = number.doubleValue
            if double.rounded(.towardZero) == double, let int = Int64(exactly: double) {
                return .int(int)
            }
            return .double(double)
        case let string as String:
            return .string(string)
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues(scriptValue(from:)))
        case let array as [Any]:
            return .array(array.map(scriptValue(from:)))
        default:
            return .null
        }
    }

    /// Converts a record of Cocoa scripting arguments to `ScriptValue` parameters.
    static func scriptValues(from arguments: [String: Any]) -> [String: ScriptValue] {
        arguments.mapValues(scriptValue(from:))
    }

    /// Converts a `ScriptValue` result back to a Cocoa value an `NSScriptCommand` can return
    /// (NSString / NSNumber / NSArray / NSDictionary / NSNull), preserving structure.
    static func cocoaValue(from value: ScriptValue) -> Any {
        switch value {
        case .null: return NSNull()
        case let .bool(bool): return bool
        case let .int(int): return Int(int)
        case let .double(double): return double
        case let .string(string): return string
        case let .array(items): return items.map(cocoaValue(from:))
        case let .object(fields): return fields.mapValues(cocoaValue(from:))
        }
    }
}
