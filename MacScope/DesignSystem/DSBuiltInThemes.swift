import LumenTokens
import LumenUI

/// Branded themes use the same values and registry as rendering and validation, flattened onto the
/// Lumen themes they inherit.
enum DSBuiltInThemes {
    static let all: [LumenTheme] = MacScopeLumen.registry.galleryThemes
    static let defaultID = MacScopeThemes.scopeID
    static let scope = MacScopeLumen.registry.theme(id: MacScopeThemes.scopeID)!
    static let midnight = MacScopeLumen.registry.theme(id: MacScopeThemes.midnightID)!
    static let contrast = MacScopeLumen.registry.theme(id: MacScopeThemes.contrastID)!
}
