import WeakLibrary
public func importedFeatureAvailable() -> Bool {
    if #_hasSymbol(optionalFeature) { return true }
    return false
}
