import Foundation

/// Projects only caller-captured tree entries and loader-owned facts. It never opens or imports images.
enum REANativeApplicationProjection {
    enum Failure: Error { case incompleteInventory, invalidPath, duplicatePath, invalidRoot, budgetExceeded }
    static func project(subject: REANativeSubject, entries: [REANativeEntry], images: [REANativeImage], roots: [String], architecture: String? = nil, inventoryComplete: Bool) throws -> REANativeApplicationInput {
        guard inventoryComplete else { throw Failure.incompleteInventory }
        guard entries.count <= 20_000, images.count <= 2048, roots.count <= 128 else { throw Failure.budgetExceeded }
        guard Set(entries.map(\.path)).count == entries.count, Set(images.map(\.path)).count == images.count else { throw Failure.duplicatePath }
        for entry in entries {
            guard validPath(entry.path), (entry.kind != .symlink || entry.target != nil) else { throw Failure.invalidPath }
            if let component = entry.component, component.path != entry.path { throw Failure.invalidPath }
        }
        for image in images where !validPath(image.path) { throw Failure.invalidPath }
        let paths = Set(entries.filter { $0.kind == .file || $0.kind == .slice }.map(\.path))
        guard !roots.isEmpty, Set(roots).count == roots.count, roots.allSatisfy({ validPath($0) && paths.contains($0) }) else { throw Failure.invalidRoot }
        return REANativeApplicationInput(inventoryComplete: true, subject: subject, entries: entries, images: images, roots: roots, architecture: architecture)
    }
    static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4096 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func selectedImage(path: String, loadedBinary: LoadedBinary, machO: MachOFile) -> REANativeImage {
        let unsupported: (String) -> REANativeImage = { REANativeImage(path: path, facts: .unsupported($0)) }
        guard loadedBinary.cpuType == machO.header.cpuType, loadedBinary.cpuSubtype == machO.header.cpuSubtype,
              loadedBinary.sliceOffset == machO.selectedSliceOffset else { return unsupported("Selected image and parser authority do not match") }
        return sliceFacts(path: path, machO: machO, physicalFileSize: UInt64(loadedBinary.bytes.count), selectedSliceSize: loadedBinary.sliceSize)
    }
    static func sliceFacts(path: String, machO: MachOFile, physicalFileSize: UInt64, selectedSliceSize: UInt64?) -> REANativeImage {
        let unsupported: (String) -> REANativeImage = { REANativeImage(path: path, facts: .unsupported($0)) }
        guard let facts = machO.loaderFacts else { return unsupported("Loader declarations were not captured") }
        let fat = machO.universalBinary?.selectedSlice
        let size = selectedSliceSize ?? physicalFileSize
        let offset = machO.selectedSliceOffset
        let (end, overflow) = offset.addingReportingOverflow(size)
        guard !overflow, size > 0, end <= physicalFileSize, offset <= 9_007_199_254_740_991, size <= 9_007_199_254_740_991 else { return unsupported("Physical slice identity is unavailable or exceeds exact JavaScript integer range") }
        if let fat, fat.offset != offset || fat.size != size { return unsupported("Selected FAT table identity does not match loader extent") }
        guard facts.installNames.count <= 1 else { return unsupported("Multiple LC_ID_DYLIB declarations") }
        guard machO.dylibs.allSatisfy({ ($0.useFlags ?? 0) & ~UInt32(0x0f) == 0 }) else { return unsupported("Unsupported dylib_use_command flags retained by loader") }
        var platforms: [UInt32] = []
        for platform in facts.declaredPlatforms where !platforms.contains(platform) { platforms.append(platform) }
        let dependencies = machO.dylibs.map { d in
            let flags = d.useFlags
            return REANativeDependency(command: d.commandName, encoding: flags == nil ? "dylib_command" : "dylib_use_command", install_name: d.name,
                weak: flags.map { $0 & 1 != 0 } ?? (d.loadKind == "weak"), upward: flags.map { $0 & 4 != 0 } ?? (d.loadKind == "upward"),
                reexport: flags.map { $0 & 2 != 0 } ?? (d.loadKind == "reexport"), delayed_init: flags.map { $0 & 8 != 0 } ?? false,
                current_version: d.currentVersion.stringValue, compatibility_version: d.compatibilityVersion.stringValue)
        }
        let subtype = UInt32(bitPattern: machO.header.cpuSubtype)
        let architecture = machO.header.cpuType == MachOConstants.cpuTypeARM64 && subtype & 0x00ff_ffff == 2 ? "arm64e" : machO.architectureName
        let fileType: String = switch machO.header.fileType { case 2: "execute"; case 6: "dylib"; case 8: "bundle"; default: "other" }
        let slice = REANativeSlice(architecture: architecture, slice_offset: offset, slice_size: size,
            cpu_type: UInt32(bitPattern: machO.header.cpuType), cpu_subtype: subtype,
            fat_cpu_type: fat.map { UInt32(bitPattern: $0.cpuType) }, fat_cpu_subtype: fat.map { UInt32(bitPattern: $0.cpuSubtype) }, fat_alignment_exponent: fat?.alignment,
            file_type: fileType, file_type_code: machO.header.fileType, platform: machO.buildVersion?.platform, platforms: platforms, install_name: facts.installNames.first,
            dependencies: dependencies, rpaths: machO.rpaths.map(\.path), dyld_environment: facts.dyldEnvironment,
            code_signature_present: machO.loadCommands.contains { $0.command == MachOConstants.loadCommandCodeSignature })
        return REANativeImage(path: path, facts: .parsed([slice]))
    }
}
