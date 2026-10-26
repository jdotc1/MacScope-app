import Foundation

/// Static declaration analysis. It does not execute the image or ask dyld to resolve a path.
struct LoadPathRiskAnalyzer {
    typealias Existence = (URL) -> Bool
    private static let idDylib: UInt32 = 0x0d
    private static let dyldEnvironment: UInt32 = 0x27
    private static let csHard: UInt32 = 0x0000_0100
    private static let csKill: UInt32 = 0x0000_0200
    private static let csRestrict: UInt32 = 0x0000_0800
    private static let csRequireLV: UInt32 = 0x0000_2000
    private static let csRuntime: UInt32 = 0x0001_0000
    private static let disableLV = "com.apple.security.cs.disable-library-validation"
    private static let allowDyldEnvironment = "com.apple.security.cs.allow-dyld-environment-variables"
    private let maximumDepth = 8

    enum AnalysisError: Error {
        case notABundle, noExecutable, unsafeInput, inventoryLimit, notMachO
    }

    private struct ParsedArchitecture {
        let selectedCPUType: Int32
        let availableCPUTypes: Set<Int32>

        init(_ file: MachOFile) {
            selectedCPUType = file.header.cpuType
            availableCPUTypes = Set([file.header.cpuType] + (file.universalBinary?.slices.map(\.cpuType) ?? []))
        }
    }

    /// The caller supplies the parsed image, so this overload reads no image bytes.
    /// `existence` is invoked only for lexical, non-symlinked paths within bundleRoot.
    func analyze(
        _ image: MachOFile,
        at imageURL: URL,
        bundleRoot: URL? = nil,
        mainExecutableURL: URL? = nil,
        selectedSliceBytes: Data? = nil,
        candidateAccessEvidence: [LoadPathRiskReport.CandidateAccessEvidence] = [],
        existence: Existence = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> LoadPathRiskReport {
        let root = bundleRoot?.standardizedFileURL
        let main = (mainExecutableURL ?? imageURL).standardizedFileURL
        let path = imageURL.standardizedFileURL
        let item = analyzeImage(image, at: path, role: .mainExecutable, root: root, main: main,
                                mainRpaths: [], sliceBytes: selectedSliceBytes,
                                access: candidateAccessEvidence, existence: existence)
        return LoadPathRiskReport(bundleRoot: root?.path, images: [item], assumptions: assumptions(for: [image]))
    }

    /// Inventories only regular files inside the supplied app bundle. Symlink entries are
    /// ignored, and recursion follows only a present, safe in-bundle library candidate.
    func analyze(
        bundleURL: URL,
        candidateAccessEvidence: [LoadPathRiskReport.CandidateAccessEvidence] = [],
        existence: Existence = { FileManager.default.fileExists(atPath: $0.path) }
    ) throws -> LoadPathRiskReport {
        let root = bundleURL.standardizedFileURL
        guard root.pathExtension == "app" else { throw AnalysisError.notABundle }
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw AnalysisError.unsafeInput }
        let infoURL = root.appendingPathComponent("Contents/Info.plist")
        guard safe(infoURL, within: root),
              let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executableName = plist["CFBundleExecutable"] as? String,
              !executableName.contains("/"), executableName != ".", executableName != ".." else {
            throw AnalysisError.noExecutable
        }
        let main = root.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName).standardizedFileURL
        guard safe(main, within: root) else { throw AnalysisError.unsafeInput }
        let mainInput = try parseBundled(main, root: root)
        let mainFile = mainInput.file
        var reports: [LoadPathRiskReport.Image] = []
        var parsed: [MachOFile] = [mainFile]
        var architectures: [String: ParsedArchitecture] = [:]
        var visited: Set<String> = []
        func visit(_ input: (file: MachOFile, bytes: Data), _ path: URL, _ role: LoadPathRiskReport.Role,
                   _ mainRpaths: [MachORPath], _ depth: Int) {
            guard depth <= maximumDepth, visited.insert(path.path).inserted else { return }
            let file = input.file
            architectures[path.path] = ParsedArchitecture(file)
            let report = analyzeImage(file, at: path, role: role, root: root, main: main,
                                      mainRpaths: mainRpaths, sliceBytes: input.bytes,
                                      access: candidateAccessEvidence, existence: existence)
            reports.append(report)
            guard depth < maximumDepth else { return }
            for candidate in report.resolution where candidate.location == .bundle && candidate.existence == .present {
                let next = URL(fileURLWithPath: candidate.candidate)
                guard !visited.contains(next.path), let child = try? parseBundled(next, root: root) else { continue }
                parsed.append(child.file)
                visit(child, next, roleFor(next, root: root), role == .mainExecutable ? file.rpaths : mainRpaths, depth + 1)
            }
        }
        visit(mainInput, main, .mainExecutable, [], 0)
        // Also report bundle images that are loaded by a host or discovered independently.
        // The bounded inventory does not infer who loads a plug-in or helper.
        for path in try inventory(root: root) where !visited.contains(path.path) {
            guard let file = try? parseBundled(path, root: root) else { continue }
            parsed.append(file.file)
            visit(file, path, roleFor(path, root: root), [], 0)
        }
        for imageIndex in reports.indices {
            guard let sourceCPUType = architectures[reports[imageIndex].path]?.selectedCPUType else { continue }
            for resolutionIndex in reports[imageIndex].resolution.indices {
                let resolution = reports[imageIndex].resolution[resolutionIndex]
                guard resolution.location == .bundle, resolution.existence == .present else { continue }
                let candidatePath = URL(fileURLWithPath: resolution.candidate).standardizedFileURL.path
                let assessment: LoadPathRiskReport.ArchitectureAssessment
                if let candidate = architectures[candidatePath] {
                    assessment = candidate.availableCPUTypes.contains(sourceCPUType)
                        ? .matchingCPUType : .differentCPUType
                } else {
                    assessment = .unassessed
                }
                reports[imageIndex].resolution[resolutionIndex].architectureAssessment = assessment
                let architectureNote: String = switch assessment {
                case .matchingCPUType:
                    "A parsed Mach-O slice declares the referring image's CPU type; other loader requirements were not assessed."
                case .differentCPUType:
                    "Candidate is present, but no parsed Mach-O slice declares the referring image's CPU type."
                case .unassessed:
                    "Candidate is reported present; no parsed Mach-O CPU-type evidence is available."
                }
                reports[imageIndex].resolution[resolutionIndex].note =
                    [resolution.note, architectureNote].compactMap { $0 }.joined(separator: " ")
            }
        }
        return LoadPathRiskReport(bundleRoot: root.path, images: reports,
                                  assumptions: assumptions(for: parsed))
    }

    private func parseBundled(_ url: URL, root: URL) throws -> (file: MachOFile, bytes: Data) {
        guard safe(url, within: root) else { throw AnalysisError.unsafeInput }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= 4 && size <= 128 * 1024 * 1024 else { throw AnalysisError.notMachO }
        let handle = try FileHandle(forReadingFrom: url)
        let prefix = try handle.read(upToCount: 4) ?? Data()
        try handle.close()
        guard [Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xca, 0xfe, 0xba, 0xbe]),
               Data([0xca, 0xfe, 0xba, 0xbf])].contains(prefix) else { throw AnalysisError.notMachO }
        let bytes = try Data(contentsOf: url)
        let file = try MachOParser().parse(bytes)
        if let slice = file.universalBinary?.selectedSlice {
            guard slice.offset <= UInt64(bytes.count), slice.size <= UInt64(bytes.count) - slice.offset else {
                throw AnalysisError.unsafeInput
            }
            return (file, bytes.subdata(in: Int(slice.offset)..<Int(slice.offset + slice.size)))
        }
        return (file, bytes)
    }

    private func inventory(root: URL) throws -> [URL] {
        var files: [URL] = []
        var pending: [(URL, Int)] = [(root.appendingPathComponent("Contents"), 0)]
        while let (directory, depth) = pending.popLast() {
            guard depth <= 12, safe(directory, within: root) else { continue }
            let children = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]).sorted { $0.path < $1.path }
            for entry in children {
                // Enumeration may rewrite /var as /private/var; keep the validated parent's spelling.
                let child = directory.appendingPathComponent(entry.lastPathComponent)
                guard safe(child, within: root) else { continue }
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true { pending.append((child, depth + 1)) }
                else if values.isRegularFile == true { files.append(child) }
                if files.count + pending.count > 4096 { throw AnalysisError.inventoryLimit }
            }
        }
        return files
    }

    private func roleFor(_ url: URL, root: URL) -> LoadPathRiskReport.Role {
        let suffix = String(url.path.dropFirst(root.path.count))
        if suffix.contains("/PlugIns/") || suffix.contains("/Plug-ins/") { return .plugIn }
        if suffix.contains("/Library/LaunchServices/") || suffix.contains("/XPCServices/") || suffix.contains("/Helpers/") { return .helper }
        if suffix.split(separator: "/").dropLast().contains(where: { $0.lowercased().hasSuffix(".framework") }) {
            return .framework
        }
        return .library
    }

    private func analyzeImage(_ file: MachOFile, at path: URL, role: LoadPathRiskReport.Role,
                              root: URL?, main: URL, mainRpaths: [MachORPath],
                              sliceBytes: Data?, access: [LoadPathRiskReport.CandidateAccessEvidence],
                              existence: Existence) -> LoadPathRiskReport.Image {
        let metadata = MachOLoadMetadata.from(file).codeSignature
        let flags = metadata?.codeSignatureFlags ?? 0
        let entitlements = EntitlementValueReader.read(signature: file.codeSignature, sliceBytes: sliceBytes ?? Data())
        let mitigation = Mitigation(flags: flags, hasFlags: metadata?.codeSignatureFlags != nil,
                                    hasTeam: metadata?.teamIdentifier != nil, entitlements: entitlements)
        let dylibCommands = file.loadCommands.enumerated().filter { command in
            [MachOConstants.loadCommandLoadDylib, MachOConstants.loadCommandLoadWeakDylib,
             MachOConstants.loadCommandReexportDylib, MachOConstants.loadCommandLoadUpwardDylib,
             MachOConstants.loadCommandLazyLoadDylib].contains(command.element.command)
        }.map(\.offset)
        let localRpathCommands = file.loadCommands.enumerated().filter { $0.element.command == MachOConstants.loadCommandRPath }.map(\.offset)
        let rpaths: [(MachORPath, LoadPathRiskReport.Command)] = zip(file.rpaths, localRpathCommands).map {
            ($0.0, .init(index: $0.1, name: "LC_RPATH", rawString: $0.0.path))
        } + (role == .mainExecutable ? [] : mainRpaths.enumerated().map {
            ($0.element, .init(index: $0.offset, name: "LC_RPATH (main executable)", rawString: $0.element.path))
        })
        var resolution: [LoadPathRiskReport.Resolution] = []
        var findings: [LoadPathRiskReport.Finding] = []
        func add(_ id: String, _ detail: String, _ commands: [LoadPathRiskReport.Command],
                 _ requested: LoadPathRiskReport.Confidence = .definite,
                 _ requestedReason: String = "Declaration is present in the parsed load commands.") {
            let rule = LoadPathRiskCatalog.rules.first { $0.id == id }!
            let adjusted = mitigation.adjust(id: id, severity: rule.severity, confidence: requested, reason: requestedReason)
            findings.append(.init(ruleID: id, severity: adjusted.0, confidence: adjusted.1,
                                  confidenceReason: adjusted.2, reason: "\(rule.reason) \(detail)",
                                  mitigation: adjusted.3, commands: commands))
        }
        for (rpath, command) in rpaths where !command.name.contains("main executable") {
            if rpath.pathKind == .relative || rpath.pathKind == .empty {
                add("L3", "LC_RPATH is \(rpath.pathKind.rawValue).", [command], .needsReview,
                    "The process working directory is not known statically.")
            }
            if rpath.path.hasPrefix("/") && outsideWritableAssumption(rpath.path, root: root) != nil {
                add("L4", outsideWritableAssumption(rpath.path, root: root)!, [command], .needsReview,
                    "Path ownership and writability outside the bundle were not checked.")
            }
        }
        for (dylib, index) in zip(file.dylibs, dylibCommands) {
            let command = LoadPathRiskReport.Command(index: index, name: dylib.commandName, rawString: dylib.name)
            let options: [(String, LoadPathRiskReport.Command?)]
            if dylib.pathKind == .rpathRelative {
                options = rpaths.map { pair in
                    let rpath = pair.0
                    let source = pair.1
                    return (expand(rpath.path, loader: source.name.contains("main executable") ? main : path, main: main)
                        .map { URL(fileURLWithPath: $0).appendingPathComponent(dylib.rpathSuffix ?? "").standardizedFileURL.path }
                        ?? "\(rpath.path)/\(dylib.rpathSuffix ?? "")", source)
                }
            } else {
                options = [(expand(dylib.name, loader: path, main: main) ?? dylib.name, nil)]
            }
            let start = resolution.count
            for (order, option) in options.enumerated() {
                let candidate = classify(option.0, root: root, existence: existence)
                resolution.append(.init(dependency: command, candidate: option.0, searchOrder: order,
                                        rpath: option.1, location: candidate.0, existence: candidate.1,
                                        note: candidate.2))
            }
            let current = Array(resolution[start...])
            if dylib.pathKind == .relative || dylib.pathKind == .empty {
                add("L3", "Dependency is \(dylib.pathKind.rawValue).", [command], .needsReview,
                    "The process working directory is not known statically.")
            }
            if dylib.name.hasPrefix("/"), let why = outsideWritableAssumption(dylib.name, root: root) {
                add("L4", why, [command], .needsReview, "Path ownership and writability outside the bundle were not checked.")
            }
            if dylib.command == MachOConstants.loadCommandLoadWeakDylib,
               !current.contains(where: { $0.location == .bundle && $0.existence == .present }),
               !current.isEmpty, !current.allSatisfy({ $0.location == .sealedSystem }) {
                add("L1", "No candidate is present inside the bundle; outside candidates were not probed.", [command], .needsReview,
                    "An outside path or shared-cache image may satisfy the weak link; only in-bundle absence is definite.")
            }
            if dylib.pathKind == .rpathRelative,
               let bundled = current.firstIndex(where: { $0.location == .bundle && $0.existence == .present }),
               let earlier = current.prefix(bundled).first(where: { $0.location == .elsewhere }) {
                add("L2", "Candidate \(earlier.candidate) precedes bundled candidate \(current[bundled].candidate).",
                    [command] + (earlier.rpath.map { [$0] } ?? []), .needsReview,
                    "Search order is definite; outside existence and writability are unverified.")
            }
            if [MachOConstants.loadCommandReexportDylib, MachOConstants.loadCommandLoadUpwardDylib].contains(dylib.command),
               current.contains(where: { $0.location == .elsewhere }) {
                add("L6", "A declared link has an outside candidate.", [command], .needsReview,
                    "The outside library was not inspected; this records the boundary in the declaration.")
            }
        }
        let envIndices = file.loadCommands.enumerated().filter { $0.element.command == Self.dyldEnvironment }.map(\.offset)
        for (entry, index) in zip(file.loaderFacts?.dyldEnvironment ?? [], envIndices) {
            add("L5", "Entry: \(String(reflecting: entry)). Dyld honors supported variables only when process restrictions permit them.",
                [.init(index: index, name: "LC_DYLD_ENVIRONMENT", rawString: entry)], .needsReview,
                "Whether the launcher and OS honor this setting requires runtime context.")
        }
        if role != .mainExecutable {
            let idIndices = file.loadCommands.enumerated().filter { $0.element.command == Self.idDylib }.map(\.offset)
            for (name, index) in zip(file.loaderFacts?.installNames ?? [], idIndices) where !installNameMatches(name, found: path) {
                add("L7", "Install name \(name) differs from found path \(path.path).",
                    [.init(index: index, name: "LC_ID_DYLIB", rawString: name)])
            }
        }
        let platform = file.buildVersion.map { "\($0.platformName) minimum \($0.minimumOSVersion.stringValue)" }
            ?? file.legacyMinimumOSVersion.map { "\($0.platformName) minimum \($0.minimumOSVersion.stringValue)" }
            ?? "platform/minimum OS unspecified"
        let privilege = declaredPrivilege(file, bytes: sliceBytes, at: path, root: root)
        let priority = priority(findings: findings, resolution: resolution, privilege: privilege,
                                mitigation: mitigation, access: access)
        return .init(path: path.path, role: role, platform: platform, resolution: resolution, findings: findings,
                     entitlementState: entitlements.state.rawValue, privilege: privilege, priority: priority)
    }

    private func installNameMatches(_ name: String, found: URL) -> Bool {
        if name == found.path { return true }
        for token in ["@rpath/", "@loader_path/", "@executable_path/"] where name.hasPrefix(token) {
            let suffix = String(name.dropFirst(token.count))
            return found.path.hasSuffix("/" + suffix)
        }
        return false
    }

    private func expand(_ raw: String, loader: URL, main: URL) -> String? {
        let base: URL
        let suffix: Substring
        if raw == "@loader_path" { base = loader.deletingLastPathComponent(); suffix = "" }
        else if raw.hasPrefix("@loader_path/") { base = loader.deletingLastPathComponent(); suffix = raw.dropFirst(13) }
        else if raw == "@executable_path" { base = main.deletingLastPathComponent(); suffix = "" }
        else if raw.hasPrefix("@executable_path/") { base = main.deletingLastPathComponent(); suffix = raw.dropFirst(17) }
        else if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardizedFileURL.path }
        else { return nil }
        return base.appendingPathComponent(String(suffix)).standardizedFileURL.path
    }

    private func classify(_ raw: String, root: URL?, existence: Existence)
      -> (LoadPathRiskReport.Location, LoadPathRiskReport.Existence, String?) {
        guard raw.hasPrefix("/") else { return (.unresolved, .notChecked, "Working directory or loader token unresolved") }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        if let root, inside(url, root: root) {
            guard safe(url, within: root) else { return (.bundle, .notChecked, "Symlink or unsafe path; no filesystem probe") }
            return (.bundle, existence(url) ? .present : .absent, nil)
        }
        if sealed(url.path) { return (.sealedSystem, .notChecked, "May be supplied by the dyld shared cache") }
        return (.elsewhere, .notChecked, "Outside the bundle: existence and writability not checked")
    }

    private func outsideWritableAssumption(_ path: String, root: URL?) -> String? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL
        if let root, inside(normalized, root: root) { return nil }
        if sealed(normalized.path) { return nil }
        let prefix = ["/usr/local", "/opt", "/tmp", "/private/tmp", "/Users", "/Library"]
            .first { normalized.path == $0 || normalized.path.hasPrefix($0 + "/") } ?? "other unsealed absolute location"
        return "\(prefix) is outside the sealed system; user/admin writability is an assumption, not a filesystem finding."
    }

    private func sealed(_ path: String) -> Bool {
        (path == "/System" || path.hasPrefix("/System/")) ||
        (path == "/usr/lib" || path.hasPrefix("/usr/lib/"))
    }

    private func inside(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    /// Reject symlinks in any path component. This conservative check avoids following a
    /// bundle-contained link into another volume before invoking the existence callback.
    private func safe(_ url: URL, within root: URL) -> Bool {
        guard inside(url, root: root),
              (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        var cursor = root
        let suffix = url.path.dropFirst(root.path.count).split(separator: "/")
        for component in suffix {
            cursor.appendPathComponent(String(component))
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
        }
        return true
    }

    private func assumptions(for files: [MachOFile]) -> [String] {
        let versions = files.compactMap { $0.buildVersion?.minimumOSVersion.stringValue ?? $0.legacyMinimumOSVersion?.minimumOSVersion.stringValue }
        return ["@rpath candidates are reported in declared runpath order; a dependent image inherits main-executable runpaths after its own in this bounded model.",
                "System candidates under /System and /usr/lib are not probed. On modern macOS they may exist only in the dyld shared cache; minimum OS declarations: \(versions.isEmpty ? "unspecified" : versions.joined(separator: ", ")).",
                "Working-directory paths, dynamic dlopen, loader fallbacks, path aliases and external filesystem permissions require separate runtime review."]
    }

    private func launchUser(_ plist: [String: Any]) -> String {
        guard let raw = plist["UserName"] else { return "root" }
        guard let value = raw as? String, !value.isEmpty else { return "<invalid UserName>" }
        return value
    }

    private func declaredPrivilege(_ file: MachOFile, bytes: Data?, at path: URL,
                                   root: URL?) -> LoadPathRiskReport.Privilege {
        var declarations: [(String, String)] = []
        if let root, path.path.hasPrefix(root.appendingPathComponent("Contents/Library/LaunchServices").path + "/"),
           let bytes, let section = file.sections.first(where: {
               $0.segmentName == "__TEXT" && $0.sectionName == "__launchd_plist"
           }), section.size <= 65_536, UInt64(section.fileOffset) <= UInt64(bytes.count),
           section.size <= UInt64(bytes.count) - UInt64(section.fileOffset),
           let plist = try? PropertyListSerialization.propertyList(from: bytes.subdata(
               in: Int(section.fileOffset)..<Int(UInt64(section.fileOffset) + section.size)), format: nil) as? [String: Any],
           let label = plist["Label"] as? String, !label.isEmpty {
            declarations.append((launchUser(plist), path.path + "#__TEXT,__launchd_plist"))
        }
        if let root {
            let directory = root.appendingPathComponent("Contents/Library/LaunchDaemons")
            if safe(directory, within: root),
               let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
                // Keep enumerated children in the caller's lexical root, including /var aliases.
                for name in names.sorted().prefix(64) {
                    let url = directory.appendingPathComponent(name)
                    guard url.pathExtension == "plist" else { continue }
                    guard safe(url, within: root),
                          let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 65_536, let data = try? Data(contentsOf: url), data.count <= 65_536,
                          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                          let label = plist["Label"] as? String, !label.isEmpty else { continue }
                    let declaredPath: URL?
                    if let relative = plist["BundleProgram"] as? String, !relative.hasPrefix("/") {
                        declaredPath = root.appendingPathComponent(relative).standardizedFileURL
                    } else if let absolute = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first,
                              absolute.hasPrefix("/") {
                        declaredPath = URL(fileURLWithPath: absolute).standardizedFileURL
                    } else { declaredPath = nil }
                    guard declaredPath?.path == path.path else { continue }
                    declarations.append((launchUser(plist), url.path))
                }
            }
        }
        let users = Set(declarations.map { $0.0 })
        let kind: LoadPathRiskReport.Privilege.Kind = users == ["root"] ? .root :
            (users.count == 1 && !users.contains("<invalid UserName>") ? .user : .unknown)
        return .init(kind: kind, sources: declarations.map { $0.1 },
                     reason: declarations.isEmpty ? "No matching launchd plist establishes privilege; a helper path alone is insufficient." :
                        "Matching launchd declarations name " + users.sorted().joined(separator: ", ") +
                        "; installation and actual execution identity are not established.")
    }

    private func priority(findings: [LoadPathRiskReport.Finding], resolution: [LoadPathRiskReport.Resolution],
                          privilege: LoadPathRiskReport.Privilege, mitigation: Mitigation,
                          access: [LoadPathRiskReport.CandidateAccessEvidence]) -> LoadPathRiskReport.Priority {
        let loadRules = Set(["L1", "L2", "L4", "L6"])
        let riskyCommands = Set(findings.filter { loadRules.contains($0.ruleID) }.flatMap(\.commands))
        if privilege.kind == .root, mitigation.libraryValidationAllowsCandidate,
           let evidence = access.first(where: { evidence in
               evidence.exists && evidence.writerUserID != 0 && !evidence.source.isEmpty &&
               resolution.contains(where: { candidate in
                   candidate.candidate == evidence.path && riskyCommands.contains(candidate.dependency) &&
                   candidate.location == .elsewhere
               })
           }) {
            return .init(level: .high, reason: "Matching plist declares root, library validation does not block the candidate, and caller evidence " +
                         evidence.source + " establishes candidate " + evidence.path + " as existing and writable by UID " + String(evidence.writerUserID) +
                         ". Priority is conditional on that evidence; actual loading and other runtime policy remain unverified.")
        }
        let notable = findings.contains { $0.severity != .informational }
        return .init(level: notable ? .review : .informational,
                     reason: notable ? "Review declarations. High priority additionally requires a matching root launchd declaration, no library-validation barrier, and explicit non-root writer/existence evidence; outside paths are never probed." :
                        "No non-informational loading finding remains under the declared mitigations.")
    }

    private struct Mitigation {
        let flags: UInt32
        let hasFlags: Bool
        let hasTeam: Bool
        let entitlements: DeclaredEntitlements

        func relaxation(_ key: String) -> Bool? {
            guard entitlements.state != .unparsed else { return nil }
            guard let value = entitlements.values[key] else { return false }
            if case .boolean(let enabled) = value { return enabled }
            return nil
        }

        var libraryValidationAllowsCandidate: Bool {
            guard hasFlags, flags & LoadPathRiskAnalyzer.csRestrict == 0 else { return false }
            let enabled = flags & (LoadPathRiskAnalyzer.csRequireLV | LoadPathRiskAnalyzer.csRuntime) != 0
            return !enabled || relaxation(LoadPathRiskAnalyzer.disableLV) == true
        }

        func adjust(id: String, severity: LoadPathRiskReport.Severity,
                    confidence: LoadPathRiskReport.Confidence, reason: String)
          -> (LoadPathRiskReport.Severity, LoadPathRiskReport.Confidence, String, String?) {
            let restricted = flags & LoadPathRiskAnalyzer.csRestrict != 0
            let enforcement = flags & (LoadPathRiskAnalyzer.csHard | LoadPathRiskAnalyzer.csKill) != 0
            let enforcementNote = enforcement ? " CS_HARD/CS_KILL enforce signature failure behavior, not path ownership." : ""
            let runtime = flags & LoadPathRiskAnalyzer.csRuntime != 0
            let validation = flags & LoadPathRiskAnalyzer.csRequireLV != 0 || runtime
            if id == "L5", restricted || runtime {
                switch relaxation(LoadPathRiskAnalyzer.allowDyldEnvironment) {
                case true:
                    return (severity, .needsReview, "The dyld-environment exception is Boolean true; launcher and OS restrictions still require review.",
                            "The declared exception removes the hardened-runtime mitigation; CS_RESTRICT and other runtime policy are not proven bypassed." + enforcementNote)
                case false:
                    return (.informational, .definite, "The relaxing entitlement is absent or Boolean false.",
                            "CS_RUNTIME or CS_RESTRICT suppresses dyld environment settings without an enabled exception." + enforcementNote)
                case nil:
                    return (severity, .needsReview, "Entitlement values are unreadable or the exception is not Boolean; no relaxation is inferred.", nil)
                }
            } else if ["L1", "L2", "L4", "L6"].contains(id), validation {
                switch relaxation(LoadPathRiskAnalyzer.disableLV) {
                case true:
                    return (severity, confidence, reason,
                            "disable-library-validation is Boolean true; library-validation mitigation is not applied. Other loader constraints remain unverified." + enforcementNote)
                case nil:
                    return (severity, .needsReview, "Entitlement values are unreadable or the exception is not Boolean; library-validation status needs review.", nil)
                case false:
                    break
                }
                if !hasTeam {
                    return (.low, .needsReview, "Signature has no team identifier; exact ad hoc library validation outcome needs review.",
                            "CS_REQUIRE_LV or CS_RUNTIME is set, but team-based validation cannot be established from an ad hoc signature." + enforcementNote)
                }
                return (.informational, confidence, reason,
                        "CS_REQUIRE_LV or CS_RUNTIME requires compatible signed libraries; an independently supplied copy normally fails validation." + enforcementNote)
            }
            if !hasFlags && id != "L7" {
                return (severity, .needsReview, "Code Directory flags are unavailable; signing mitigation is unknown.", nil)
            }
            return (severity, confidence, reason, nil)
        }
    }
}
