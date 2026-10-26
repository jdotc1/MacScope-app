import Foundation

/// Structured toolchain identity of one Mach-O slice, detected from its load commands and sections.
/// `canonical` is the deterministic serialisation used as the opaque `toolchain` string of v1
/// records; it covers every field except `derivedFrom`, so two slices built by the same toolchain
/// for the same targets share it. `unknown` confidence is a value, never an error: the caller
/// raises `unsupportedToolchain` when a rule's applicability cannot be evaluated.
struct NavigatorToolchainKey: Hashable, Codable, Sendable {
    /// One `LC_BUILD_VERSION` or `LC_VERSION_MIN_*` target, versions as `MachOVersion.stringValue`.
    struct Platform: Hashable, Codable, Sendable {
        var name: String
        var minOS: String
        var sdk: String
    }

    /// One `LC_BUILD_VERSION` tool record (`clang`, `swift`, `ld`, `lld`, or `tool <n>`).
    struct Tool: Hashable, Codable, Sendable {
        var name: String
        var version: String
    }

    enum Confidence: String, Codable, CaseIterable, Hashable, Sendable {
        /// At least one `LC_BUILD_VERSION` carries tool records.
        case exact
        /// Only `LC_VERSION_MIN_*`, or `LC_BUILD_VERSION` without tool records.
        case partial
        /// Neither `LC_BUILD_VERSION` nor `LC_VERSION_MIN_*`.
        case unknown
    }

    static let linkerFlavors = ["chained", "classic", "none"]
    static let canonicalPrefix = "toolchain-key/1"

    var arch: String
    var platforms: [Platform]
    var tools: [Tool]
    /// `"5"` when any `__swift5_*` section is present; nil otherwise.
    var swiftABI: String?
    /// `chained` (`LC_DYLD_CHAINED_FIXUPS`), `classic` (`LC_DYLD_INFO[_ONLY]`) or `none`.
    var linkerFlavor: String
    var confidence: Confidence
    /// Selected-slice SHA-256 the key was detected from.
    var derivedFrom: String
    var canonical: String

    private enum CodingKeys: String, CodingKey {
        case arch
        case platforms
        case tools
        case swiftABI
        case linkerFlavor
        case confidence
        case derivedFrom
        case canonical
    }

    init(
        arch: String,
        platforms: [Platform],
        tools: [Tool],
        swiftABI: String?,
        linkerFlavor: String,
        confidence: Confidence,
        derivedFrom: String
    ) {
        self.arch = arch
        self.platforms = platforms
        self.tools = tools
        self.swiftABI = swiftABI
        self.linkerFlavor = linkerFlavor
        self.confidence = confidence
        self.derivedFrom = derivedFrom
        canonical = Self.canonicalText(
            arch: arch,
            platforms: platforms,
            tools: tools,
            swiftABI: swiftABI,
            linkerFlavor: linkerFlavor,
            confidence: confidence
        )
    }

    /// Decodes the fields and recomputes `canonical`; a stored `canonical` that disagrees is corrupt.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            arch: try container.decode(String.self, forKey: .arch),
            platforms: try container.decode([Platform].self, forKey: .platforms),
            tools: try container.decode([Tool].self, forKey: .tools),
            swiftABI: try container.decodeIfPresent(String.self, forKey: .swiftABI),
            linkerFlavor: try container.decode(String.self, forKey: .linkerFlavor),
            confidence: try container.decode(Confidence.self, forKey: .confidence),
            derivedFrom: try container.decode(String.self, forKey: .derivedFrom)
        )
        let stored = try container.decode(String.self, forKey: .canonical)
        guard stored == canonical else {
            throw DecodingError.dataCorruptedError(
                forKey: .canonical,
                in: container,
                debugDescription: "Toolchain key canonical text does not match its fields."
            )
        }
    }

    /// The version of the first `swift` tool record, if any.
    var swiftToolVersion: String? {
        tools.first { $0.name == "swift" }?.version
    }

    /// `toolchain-key/1|arch=…|platforms=<name>:<minOS>:<sdk>,…|tools=<name>:<version>,…|swiftABI=…|linker=…|confidence=…`
    /// with list order preserved (load-command order) and `-` for an absent Swift ABI.
    static func canonicalText(
        arch: String,
        platforms: [Platform],
        tools: [Tool],
        swiftABI: String?,
        linkerFlavor: String,
        confidence: Confidence
    ) -> String {
        let platformText = platforms.map { "\($0.name):\($0.minOS):\($0.sdk)" }.joined(separator: ",")
        let toolText = tools.map { "\($0.name):\($0.version)" }.joined(separator: ",")
        return [
            canonicalPrefix,
            "arch=\(arch)",
            "platforms=\(platformText)",
            "tools=\(toolText)",
            "swiftABI=\(swiftABI ?? "-")",
            "linker=\(linkerFlavor)",
            "confidence=\(confidence.rawValue)",
        ].joined(separator: "|")
    }
}

enum NavigatorToolchainKeyDetector {
    static let swiftABI5SectionPrefix = "__swift5_"

    static func detect(file: MachOFile, identity: MachOSliceArtifactIdentity) -> NavigatorToolchainKey {
        // A `MachOFile` built before `buildVersions` existed (or by hand) may carry only the
        // last-wins `buildVersion`; fall back to it so detection never loses the one record it has.
        let buildVersions = file.buildVersions.isEmpty ? (file.buildVersion.map { [$0] } ?? []) : file.buildVersions

        let legacyVersions = file.legacyMinimumOSVersions.isEmpty
            ? (file.legacyMinimumOSVersion.map { [$0] } ?? []) : file.legacyMinimumOSVersions

        var platforms = buildVersions.map {
            NavigatorToolchainKey.Platform(
                name: $0.platformName,
                minOS: $0.minimumOSVersion.stringValue,
                sdk: $0.sdkVersion.stringValue
            )
        }
        for legacy in legacyVersions {
            platforms.append(NavigatorToolchainKey.Platform(
                name: legacy.platformName,
                minOS: legacy.minimumOSVersion.stringValue,
                sdk: legacy.sdkVersion.stringValue
            ))
        }

        var tools: [NavigatorToolchainKey.Tool] = []
        for buildVersion in buildVersions {
            for record in buildVersion.tools {
                let tool = NavigatorToolchainKey.Tool(name: record.toolName, version: record.version.stringValue)
                if !tools.contains(tool) { tools.append(tool) }
            }
        }

        let confidence: NavigatorToolchainKey.Confidence
        if buildVersions.contains(where: { !$0.tools.isEmpty }) {
            confidence = .exact
        } else if !buildVersions.isEmpty || !legacyVersions.isEmpty {
            confidence = .partial
        } else {
            confidence = .unknown
        }

        return NavigatorToolchainKey(
            arch: identity.architectureVariant.rawValue,
            platforms: platforms,
            tools: tools,
            swiftABI: swiftABI(sections: file.sections),
            linkerFlavor: linkerFlavor(file: file),
            confidence: confidence,
            derivedFrom: identity.selectedSliceSHA256
        )
    }

    static func swiftABI(sections: [MachOSection]) -> String? {
        sections.contains { $0.sectionName.hasPrefix(swiftABI5SectionPrefix) } ? "5" : nil
    }

    static func linkerFlavor(file: MachOFile) -> String {
        let commands = Set(file.loadCommands.map(\.command))
        if file.dyldChainedFixups != nil || commands.contains(MachOConstants.loadCommandDyldChainedFixups) {
            return "chained"
        }
        if commands.contains(MachOConstants.loadCommandDyldInfo) || commands.contains(MachOConstants.loadCommandDyldInfoOnly) {
            return "classic"
        }
        return "none"
    }
}
