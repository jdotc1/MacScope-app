import Foundation

/// A bounded, read-only inventory of files named by an analyst-selected app bundle.
/// No system directory, service registry or running process is consulted.
struct AttackSurfaceAnalyzer {
    typealias Report = AttackSurfaceReport

    enum InventoryError: Error { case unsupportedInput, unsafePath(String), oversized(String) }
    private let maxPlistBytes = 16 * 1024 * 1024
    private let maxBinaryBytes = 512 * 1024 * 1024

    /// A parsed image alone carries ObjC metadata but no instruction bytes. Supply its original
    /// bytes when call-site evidence is wanted; nil reports no call-derived listeners.
    func analyze(machO: MachOFile, bytes: Data? = nil) -> Report {
        guard let bytes else {
            return .init(sources: [], services: [], unmatched: [
                .init(name: nil, binaryPath: nil,
                      reason: "Parsed Mach-O has no source bytes; embedded plists and call-derived listeners were not analyzed",
                      listener: nil)
            ])
        }
        var sources: [Report.Source] = []
        var declarations: [(name: String, source: Report.Source, binary: String?, privilege: Report.Privilege, requirements: [String])] = []
        let path = "<parsed Mach-O>"
        collectEmbedded(file: machO, data: bytes, path: path, sources: &sources,
                        declarations: &declarations, privilege: .unknown)
        return assemble(sources: sources, declarations: declarations,
                        binaries: [(path, machO, bytes)])
    }

    func analyze(bundleURL: URL) throws -> Report {
        let root = bundleURL.standardizedFileURL
        guard root.isFileURL else { throw InventoryError.unsupportedInput }
        if (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
            throw InventoryError.unsafePath(root.path)
        }
        var sources: [Report.Source] = []
        var declarations: [(name: String, source: Report.Source, binary: String?, privilege: Report.Privilege, requirements: [String])] = []
        var binaries: [(path: String, file: MachOFile, bytes: Data)] = []
        let isDirectory = (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if !isDirectory {
            let data = try safeData(root, root: root, maximum: maxBinaryBytes)
            let file = try MachOParser().parse(data)
            binaries.append((root.path, file, data))
            collectEmbedded(file: file, data: data, path: root.path, sources: &sources,
                            declarations: &declarations, privilege: .unknown)
        } else {
            let contents = root.appendingPathComponent("Contents", isDirectory: true)
            let hostInfo = try readPlist(contents.appendingPathComponent("Info.plist"), root: root)
            if let hostInfo {
                sources.append(source(path: contents.appendingPathComponent("Info.plist").path, section: nil, plist: hostInfo))
            }
            let hostExecutable = hostInfo?["CFBundleExecutable"] as? String
            if let hostExecutable, safeLeaf(hostExecutable) {
                try appendBinary(contents.appendingPathComponent("MacOS").appendingPathComponent(hostExecutable), root: root, binaries: &binaries)
            }
            let hostRequirements = stringMap(hostInfo?["SMPrivilegedExecutables"])
            for url in try children(contents.appendingPathComponent("XPCServices"), root: root) where url.pathExtension == "xpc" {
                let infoURL = url.appendingPathComponent("Contents/Info.plist")
                guard let info = try readPlist(infoURL, root: root) else { continue }
                let infoSource = source(path: infoURL.path, section: nil, plist: info)
                sources.append(infoSource)
                if let executable = info["CFBundleExecutable"] as? String, safeLeaf(executable) {
                    let binary = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
                    try appendBinary(binary, root: root, binaries: &binaries)
                    if let identifier = info["CFBundleIdentifier"] as? String {
                        declarations.append((identifier, infoSource, binary.path, .appScoped, []))
                    }
                }
            }
            for url in try children(contents.appendingPathComponent("Library/LaunchServices"), root: root) {
                guard let pair = try parsedBinary(url, root: root) else {
                    sources.append(.init(path: url.path, section: "unparsed",
                                         fields: ["reason": "Not a regular supported Mach-O helper"]))
                    continue
                }
                binaries.append((url.path, pair.0, pair.1))
                collectEmbedded(file: pair.0, data: pair.1, path: url.path, sources: &sources,
                                declarations: &declarations, privilege: .root,
                                hostRequirements: hostRequirements)
            }
            for folder in ["LaunchDaemons", "LaunchAgents"] {
                for url in try children(contents.appendingPathComponent("Library").appendingPathComponent(folder), root: root)
                    where url.pathExtension == "plist" {
                    guard let plist = try readPlist(url, root: root) else { continue }
                    let item = source(path: url.path, section: nil, plist: plist)
                    sources.append(item)
                    let privilege: Report.Privilege = folder == "LaunchDaemons"
                        ? ((plist["UserName"] as? String).map { $0 == "root" ? .root : .user } ?? .root)
                        : .user
                    let binary = bundleProgram(plist, contents: contents, root: root)
                    for name in machServices(plist) {
                        declarations.append((name, item, binary?.path, privilege, []))
                    }
                    if let binary { try appendBinary(binary, root: root, binaries: &binaries) }
                }
            }
            for url in try children(contents.appendingPathComponent("Library/LoginItems"), root: root) where url.pathExtension == "app" {
                let infoURL = url.appendingPathComponent("Contents/Info.plist")
                guard let info = try readPlist(infoURL, root: root) else { continue }
                let item = source(path: infoURL.path, section: nil, plist: info)
                sources.append(item)
                if let executable = info["CFBundleExecutable"] as? String, safeLeaf(executable) {
                    try appendBinary(url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable), root: root, binaries: &binaries)
                }
            }
            // Keep the host requirement map as an explicit source, even without a helper match.
            if !hostRequirements.isEmpty {
                sources.append(.init(path: contents.appendingPathComponent("Info.plist").path,
                                     section: "SMPrivilegedExecutables", fields: hostRequirements))
            }
        }
        return assemble(sources: sources, declarations: declarations, binaries: binaries)
    }

    private func assemble(
        sources initialSources: [Report.Source],
        declarations: [(name: String, source: Report.Source, binary: String?, privilege: Report.Privilege, requirements: [String])],
        binaries: [(path: String, file: MachOFile, bytes: Data)]
    ) -> Report {
        var sources = initialSources
        var listeners: [(path: String, listener: Report.Listener)] = []
        for binary in binaries {
            for summary in binary.file.codeSignature?.superBlob?.entitlementSummaries ?? [] {
                sources.append(.init(path: binary.path, section: "LC_CODE_SIGNATURE:entitlement-keys",
                                     fields: ["format": summary.format.rawValue,
                                              "keys": summary.keys.sorted().joined(separator: ", ")]))
            }
            if binary.file.encryptionInfos.contains(where: \.isActive) {
                sources.append(.init(path: binary.path, section: "LC_ENCRYPTION_INFO",
                                     fields: ["reason": "Active encryption; call sites not analyzed"]))
                continue
            }
            listeners += inspectCalls(binary.file, bytes: binary.bytes).map { (binary.path, $0) }
        }
        var used = Set<Int>()
        var services: [Report.Service] = []
        var unmatched: [Report.Unmatched] = []
        for declaration in declarations {
            var candidates = listeners.indices.filter { index in
                listeners[index].listener.serviceName == declaration.name
                && (declaration.binary == nil || declaration.binary == listeners[index].path)
            }
            let serviceListenerJoin = candidates.isEmpty && declaration.privilege == .appScoped
            if serviceListenerJoin {
                candidates = listeners.indices.filter { index in
                    !used.contains(index) && declaration.binary == listeners[index].path
                        && listeners[index].listener.setupAPI.hasSuffix("serviceListener")
                }
            }
            let chosen = candidates.count == 1 ? candidates[0] : nil
            if let chosen { used.insert(chosen) }
            let listener = chosen.map { listeners[$0].listener }
            let reason: String? = candidates.isEmpty ? "Declared service has no listener with a matching recovered name"
                : candidates.count > 1 ? "Multiple matching listeners; binary association is ambiguous"
                : serviceListenerJoin ? "serviceListener belongs to this XPC service executable; name comes from Info.plist"
                    : listener?.reason
            if candidates.isEmpty {
                unmatched.append(.init(name: declaration.name, binaryPath: declaration.binary,
                                       reason: reason ?? "No matching listener", listener: nil))
            }
            services.append(.init(machServiceName: declaration.name, declaringSource: declaration.source,
                                  binaryPath: declaration.binary, listener: listener, privilege: declaration.privilege,
                                  declaredClientRequirements: declaration.requirements,
                                  confidence: reason == nil ? .definite : .needsReview, reason: reason))
        }
        for index in listeners.indices where !used.contains(index) {
            unmatched.append(.init(name: listeners[index].listener.serviceName,
                                   binaryPath: listeners[index].path,
                                   reason: "Listener has no unique matching declaration in the selected bundle",
                                   listener: listeners[index].listener))
        }
        return .init(sources: sources, services: services, unmatched: unmatched)
    }

    private func safeLeaf(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }

    private func safeData(_ url: URL, root: URL, maximum: Int) throws -> Data {
        let normalized = url.standardizedFileURL
        try ensureInside(normalized, root: root)
        let values = try normalized.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw InventoryError.unsafePath(normalized.path) }
        guard let size = values.fileSize, size <= maximum else { throw InventoryError.oversized(normalized.path) }
        let data = try Data(contentsOf: normalized, options: .mappedIfSafe)
        guard data.count <= maximum else { throw InventoryError.oversized(normalized.path) }
        return data
    }

    private func children(_ directory: URL, root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try ensureInside(directory.standardizedFileURL, root: root)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw InventoryError.unsafePath(directory.path) }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
            .sorted { $0.path < $1.path }
    }

    private func ensureInside(_ url: URL, root: URL) throws {
        let rootPath = root.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            throw InventoryError.unsafePath(url.path)
        }
        var cursor = url
        while cursor.path != rootPath {
            if (try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                throw InventoryError.unsafePath(cursor.path)
            }
            cursor.deleteLastPathComponent()
        }
    }

    private func readPlist(_ url: URL, root: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = try safeData(url, root: root, maximum: maxPlistBytes)
        return try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
    }

    private func parsedBinary(_ url: URL, root: URL) throws -> (MachOFile, Data)? {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        let bytes = try safeData(url, root: root, maximum: maxBinaryBytes)
        guard let file = try? MachOParser().parse(bytes) else { return nil }
        return (file, bytes)
    }

    private func appendBinary(_ url: URL, root: URL, binaries: inout [(path: String, file: MachOFile, bytes: Data)]) throws {
        if binaries.contains(where: { $0.path == url.path }) { return }
        if let pair = try parsedBinary(url, root: root) { binaries.append((url.path, pair.0, pair.1)) }
    }

    private func bundleProgram(_ plist: [String: Any], contents: URL, root: URL) -> URL? {
        let value = (plist["BundleProgram"] as? String) ?? (plist["Program"] as? String)
        guard let value, !value.hasPrefix("/") else { return nil }
        let url = contents.appendingPathComponent(value).standardizedFileURL
        return url.path.hasPrefix(root.path + "/") ? url : nil
    }

    private func source(path: String, section: String?, plist: [String: Any]) -> Report.Source {
        let keys = ["CFBundleIdentifier", "ServiceType", "RunLoopType", "JoinExistingSession", "Label", "Program",
                    "BundleProgram", "ProgramArguments", "AssociatedBundleIdentifiers", "SMAuthorizedClients"]
        var fields: [String: String] = [:]
        for key in keys {
            if let value = plist[key] { fields[key] = String(describing: value) }
        }
        if let xpc = plist["XPCService"] as? [String: Any] {
            for key in ["ServiceType", "RunLoopType", "JoinExistingSession"] {
                if let value = xpc[key] { fields["XPCService." + key] = String(describing: value) }
            }
        }
        if let map = plist["MachServices"] as? [String: Any] {
            fields["MachServices"] = map.keys.sorted().joined(separator: ", ")
        }
        return .init(path: path, section: section, fields: fields)
    }

    private func stringMap(_ value: Any?) -> [String: String] {
        guard let map = value as? [String: String] else { return [:] }
        return map
    }

    private func machServices(_ plist: [String: Any]) -> [String] {
        (plist["MachServices"] as? [String: Any])?.keys.sorted() ?? []
    }

    private func collectEmbedded(file: MachOFile, data: Data, path: String,
                                 sources: inout [Report.Source],
                                 declarations: inout [(name: String, source: Report.Source, binary: String?, privilege: Report.Privilege, requirements: [String])],
                                 privilege: Report.Privilege,
                                 hostRequirements: [String: String] = [:]) {
        var embedded: [String: [String: Any]] = [:]
        for section in file.sections where section.sectionName == "__info_plist" || section.sectionName == "__launchd_plist" {
            let start = file.selectedSliceOffset.addingReportingOverflow(UInt64(section.fileOffset))
            guard !start.overflow, start.partialValue <= UInt64(data.count), section.size <= UInt64(maxPlistBytes),
                  section.size <= UInt64(data.count) - start.partialValue else { continue }
            let range = Int(start.partialValue)..<Int(start.partialValue + section.size)
            guard let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: range), format: nil) as? [String: Any] else { continue }
            let item = source(path: path, section: section.qualifiedName, plist: plist)
            sources.append(item)
            embedded[section.sectionName] = plist
        }
        if let launch = embedded["__launchd_plist"] {
            let clients = (embedded["__info_plist"]?["SMAuthorizedClients"] as? [String])
                ?? (launch["SMAuthorizedClients"] as? [String]) ?? []
            let label = launch["Label"] as? String
            let requirements = clients + (label.flatMap { hostRequirements[$0] }.map { [$0] } ?? [])
            let section = file.sections.first(where: { $0.sectionName == "__launchd_plist" })?.qualifiedName
            let item = source(path: path, section: section, plist: launch)
            for name in machServices(launch) {
                declarations.append((name, item, path, privilege, requirements))
            }
        }
    }
}
