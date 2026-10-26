import Foundation
import LumenTokens
import LumenUI

/// User-facing theme names. Built-in theme names and summaries are localized through the String
/// Catalog; user themes show the name and summary from their JSON file as written.
extension LumenTheme {
    var displayName: String {
        switch id {
        case DSBuiltInThemes.scope.id: String(localized: "Scope", comment: "Built-in theme name: the default theme.")
        case DSBuiltInThemes.midnight.id: String(localized: "Midnight", comment: "Built-in theme name: deep navy, always dark.")
        case DSBuiltInThemes.contrast.id: String(localized: "Contrast", comment: "Built-in theme name: maximum legibility.")
        default: name
        }
    }

    var displaySummary: String {
        switch id {
        case DSBuiltInThemes.scope.id:
            String(localized: "Cool slate with a violet accent. Follows Light and Dark.", comment: "Built-in Scope theme description.")
        case DSBuiltInThemes.midnight.id:
            String(localized: "Deep navy with neon signals. Always dark.", comment: "Built-in Midnight theme description.")
        case DSBuiltInThemes.contrast.id:
            String(localized: "Maximum legibility: pure grounds and strong lines.", comment: "Built-in Contrast theme description.")
        default: summary
        }
    }
}
