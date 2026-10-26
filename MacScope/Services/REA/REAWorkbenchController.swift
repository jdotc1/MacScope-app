import AppKit
import Foundation
import Darwin
import Observation

/// One foreground inspection session. Only authenticated accepted worker responses publish.
@MainActor @Observable
final class REAWorkbenchController {
    typealias Acceptance = @MainActor (REAResultEvidence) throws -> Void
    typealias Authority = @MainActor (String, UUID) -> REAResultAuthority?
    private var selectedBinary: LoadedBinary?
    private let selectedBinaryURL: URL
    private let expectedSelectedSHA256: String
    private let requestedSliceIndex: Int?
    let workspaceID: UUID
    @ObservationIgnored private let onAccepted: Acceptance
    @ObservationIgnored private let makeAuthority: Authority
    private(set) var history: [REAResultEvidence]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let worker = XPCREAInspectionProvider(transport: NSXPCConnectionTransport())
    private(set) var rootURL: URL?
    private(set) var leftExecutable: URL?
    private(set) var rightExecutable: URL?
    private(set) var inputDirectory: URL?
    var argumentsText = ""
    var environmentText = ""
    var workingDirectory = "."
    private(set) var isRunning = false
    private(set) var status = "Choose a folder to inspect the selected image and its captured resources."
    private(set) var errorMessage: String?
    private(set) var presentation: REAInspectionResultPresentation?
    var selectedName: String { selectedBinary?.name ?? selectedBinaryURL.lastPathComponent }
    var isReady: Bool { selectedBinary != nil }
    init(selectedBinaryURL: URL, expectedSelectedSHA256: String, requestedSliceIndex: Int? = nil,
         workspaceID: UUID, history: [REAResultEvidence] = [], makeAuthority: @escaping Authority, onAccepted: @escaping Acceptance) {
        self.selectedBinaryURL = selectedBinaryURL; self.expectedSelectedSHA256 = expectedSelectedSHA256
        self.requestedSliceIndex = requestedSliceIndex; self.workspaceID = workspaceID; self.onAccepted = onAccepted
        self.makeAuthority = makeAuthority; self.history = history
    }
    func loadSelectedImage() async {
        guard selectedBinary == nil, !isRunning else { return }
        isRunning = true; status = "Verifying the workspace image…"
        defer { isRunning = false }
        do {
            let url = selectedBinaryURL, index = requestedSliceIndex
            let loaded = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try MachOBinaryLoader(requestedSliceIndex: index).load(at: url)
            }.value
            try Task.checkCancellation()
            guard try REAUIResourceProjection.selectedSliceSHA256(loaded) == expectedSelectedSHA256 else { throw Failure.selectedImageChanged }
            selectedBinary = loaded; status = "Image verified. Choose the folder or programs to inspect."
        } catch { errorMessage = String(describing: error); status = "The workspace image could not be verified." }
    }
    func chooseRoot() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose the bounded folder containing the selected executable and resources."
        panel.prompt = "Use Folder"
        panel.directoryURL = URL(fileURLWithPath: selectedBinary?.resolvedExecutablePath ?? selectedBinaryURL.path).deletingLastPathComponent()
        if panel.runModal() == .OK { rootURL = panel.url }
    }
    func chooseExecutable(left: Bool) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.message = "Choose the \(left ? "first" : "second") executable to run in the bounded scenario."
        panel.prompt = "Use Executable"
        if panel.runModal() == .OK { if left { leftExecutable = panel.url } else { rightExecutable = panel.url } }
    }
    func chooseInputDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose input files to copy into the immutable execution scenario."
        panel.prompt = "Use Inputs"
        if panel.runModal() == .OK { inputDirectory = panel.url }
    }
    func inspectNative() { start(.nativeApplication) }
    func inspectUI() { start(.uiResources) }
    func comparePrograms() { start(.processComparison) }
    func cancel() { task?.cancel() }
    func showHistorical(_ record: REAResultEvidence) {
        do {
            try record.validate()
            guard record.authority.workspaceID == workspaceID, let operation = REAInspectionOperation(rawValue: record.operation) else { throw Failure.staleAuthority }
            presentation = try REAInspectionResultPresentation.make(operation: operation, title: selectedName,
                resultData: record.responseJSON, coverage: ["Retained historical evidence; fresh capture is required for current navigation authority."],
                provenance: ["Selected image: \(record.authority.imageSHA256)", "Capture snapshot: \(record.authority.snapshotID.uuidString)"])
            status = "Viewing retained evidence."
        } catch { errorMessage = String(describing: error) }
    }

    private func start(_ operation: REAInspectionOperation) {
        guard !isRunning, let selectedBinary else { return }
        let imageSHA: String
        do { imageSHA = try REAUIResourceProjection.selectedSliceSHA256(selectedBinary) }
        catch { errorMessage = String(describing: error); return }
        let snapshotUUID = UUID()
        guard let authority = makeAuthority(imageSHA, snapshotUUID), authority.workspaceID == workspaceID,
              authority.imageSHA256 == imageSHA, authority.snapshotID == snapshotUUID else {
            errorMessage = "Workspace authority changed. Reopen this inspection from the current workspace."; return
        }
        isRunning = true; errorMessage = nil; status = "Capturing committed inputs…"
        task = Task { [self] in
            defer { isRunning = false; task = nil }
            do {
                let snapshotID = snapshotUUID.uuidString
                switch operation {
                case .nativeApplication:
                    guard let rootURL, let facts = selectedBinary.reaNativeImageFacts else { throw Failure.missingNativeInput }
                    let path = selectedBinary.resolvedExecutablePath ?? selectedBinary.path
                    let relative = try Self.relativePath(path, root: rootURL)
                    let binary = selectedBinary
                    let input = try await Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        return try REANativeApplicationCapture.capture(rootURL: rootURL, selectedBinary: binary,
                            selectedRelativePath: relative, selectedFacts: facts)
                    }.value
                    try await inspect(input, operation: operation, authority: authority,
                        coverage: ["Bounded immutable folder capture; dependency resolution stays within the captured tree."])
                case .uiResources:
                    guard let rootURL else { throw Failure.missingRoot }
                    _ = try Self.relativePath(selectedBinary.resolvedExecutablePath ?? selectedBinary.path, root: rootURL)
                    let binary = selectedBinary
                    let batch = try await Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        return try REAUIResourceCapture.acquire(rootURL: rootURL, selectedImage: binary, snapshotID: snapshotID)
                    }.value
                    let candidates = try await Task.detached(priority: .userInitiated) {
                        try Self.captureCatalogInputs(rootURL)
                    }.value
                    guard let runner = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("SourceExecutionRunner") else { throw Failure.invalidScenario }
                    var catalogs: [REAUIAssetCatalogCapture] = []
                    var metadataBytes = 0
                    let maximumMetadataBytes = min(4 * 1024 * 1024,
                        8 * 1024 * 1024 - batch.documents.reduce(0) { $0 + $1.bytes.count })
                    var omittedCatalogs = candidates.omitted
                    for candidate in candidates.captured {
                        try Task.checkCancellation()
                        guard metadataBytes < maximumMetadataBytes else { omittedCatalogs += 1; continue }
                        status = "Capturing asset catalog metadata…"
                        let request = try await Task.detached(priority: .userInitiated) {
                            try REAAssetCatalogCaptureProvider.stage(catalogBytes: candidate.bytes, relativePath: candidate.path,
                                selectedImage: binary, snapshotID: snapshotID, runner: runner)
                        }.value
                        let accepted = try await REAAssetCatalogCaptureProvider().capture(request)
                        guard accepted.response.metadata.count <= maximumMetadataBytes - metadataBytes else {
                            omittedCatalogs += 1
                            continue
                        }
                        metadataBytes += accepted.response.metadata.count
                        catalogs.append(accepted.catalog)
                    }
                    let input = try REAUIResourceProjection.build(selectedImage: binary, snapshotID: snapshotID,
                        documents: batch.documents, omittedDocuments: batch.omittedDocuments,
                        catalogs: catalogs.isEmpty ? nil : catalogs, omittedCatalogs: omittedCatalogs)
                    try await inspect(input, operation: operation, authority: authority,
                        coverage: ["\(batch.documents.count) captured archives; \(batch.omittedDocuments) omitted.",
                                   "\(catalogs.count) asset catalogs captured through the authenticated broker using Apple’s asset metadata tool; \(omittedCatalogs) omitted.",
                                   "Static Objective-C candidates do not prove runtime dispatch. Missing catalog metadata remains unavailable."])
                case .processComparison:
                    guard let leftExecutable, let rightExecutable else { throw Failure.missingExecutables }
                    let arguments = argumentsText.isEmpty ? [] : argumentsText.components(separatedBy: "\n")
                    var environment: [String: String] = [:]
                    for line in environmentText.components(separatedBy: "\n") where !line.isEmpty {
                        guard let equal = line.firstIndex(of: "="), equal != line.startIndex else { throw Failure.invalidScenario }
                        let key = String(line[..<equal]), value = String(line[line.index(after: equal)...])
                        guard environment.updateValue(value, forKey: key) == nil else { throw Failure.invalidScenario }
                    }
                    let inputs = try await Task.detached(priority: .userInitiated) { [inputDirectory] in
                        try Self.captureInputs(inputDirectory)
                    }.value
                    let tree = try Self.treeCommitment(inputs)
                    let scenario = REAProcessScenario(arguments: arguments, environment: environment,
                        inputTreeSHA256: tree, workingDirectory: workingDirectory, interactions: [],
                        dimensions: ["stdout", "stderr", "exit"], normalization: .init(kind: "exact-values-v1"))
                    guard scenario.isSupported, let runner = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("SourceExecutionRunner") else { throw Failure.invalidScenario }
                    let (firstRequest, secondRequest) = try await Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        let first = try REAScenarioCaptureProvider.stage(executable: leftExecutable, runner: runner,
                            scenario: scenario, files: inputs.files, directories: inputs.directories)
                        let second = try REAScenarioCaptureProvider.stage(executable: rightExecutable, runner: runner,
                            scenario: scenario, files: inputs.files, directories: inputs.directories)
                        return (first, second)
                    }.value
                    let provider = REAScenarioCaptureProvider()
                    status = "Running the first executable…"
                    let first = try await provider.capture(firstRequest)
                    try Task.checkCancellation(); status = "Running the second executable…"
                    let second = try await provider.capture(secondRequest)
                    let input = try REAProcessComparisonProjection.input(left: first, right: second)
                    try await inspect(input, operation: operation, authority: authority,
                        coverage: ["Two authenticated executions; separate final stdout/stderr snapshots and termination.",
                                   "Ten-second execution limit and bounded output. Filesystem effects and interactive behavior were not captured."])
                }
            } catch is CancellationError { status = "Cancelled. Unaccepted results were not published." }
            catch { errorMessage = String(describing: error); status = "Inspection did not produce an accepted result." }
        }
    }
    private struct Request<Input: Encodable>: Encodable {
        let schemaVersion = 1; let requestID: String; let operation: String; let input: Input
    }
    private func inspect<Input: Encodable>(_ input: Input, operation: REAInspectionOperation,
        authority: REAResultAuthority, coverage: [String]) async throws {
        try Task.checkCancellation(); status = "Inspecting captured evidence…"
        let id = UUID()
        let request = try REAInspectionWireCodec.canonicalRequest(Request(requestID: id.uuidString,
            operation: operation.rawValue, input: input), requestID: id)
        if !(try REAResultEvidenceStore.canRetainLargestResponse(requestJSON: request)) {
            status = "Inspecting captured evidence… A large result may remain visible without being saved."
        }
        let response = try await worker.inspect(requestData: request, requestID: id, operation: operation,
            implementationIdentity: REAEmbeddedIdentity.implementationIdentity)
        try Task.checkCancellation()
        let presentation = try REAInspectionResultPresentation.make(operation: operation, title: selectedName,
            resultData: response, coverage: coverage, provenance: ["Selected image: \(authority.imageSHA256)", "Capture snapshot: \(authority.snapshotID.uuidString)"])
        let evidence = try REAResultEvidence(requestID: id, operation: operation.rawValue, authority: authority,
            requestJSON: request, responseJSON: response)
        acceptForPresentation(evidence, presentation: presentation)
    }

    /// Called only after worker and operation-specific admission. Persistence failure must
    /// not erase a valid captured result or mislabel it as saved/citable workspace history.
    func acceptForPresentation(_ evidence: REAResultEvidence, presentation: REAInspectionResultPresentation) {
        self.presentation = presentation
        do {
            var retained = try REAResultEvidenceStore(records: history)
            try retained.publish(evidence, activeAuthority: evidence.authority)
            try onAccepted(evidence)
            history = retained.records
            status = "Accepted result. Saved evidence retains the newest results within its size limit."
            errorMessage = nil
        } catch {
            status = "Inspection complete. This result is visible but was not added to saved evidence."
            errorMessage = "Save failed: \(error). The displayed result is not available to workspace evidence citations."
        }
    }
    private enum Failure: Error { case staleAuthority, selectedImageChanged, missingRoot, missingNativeInput, selectedImageOutsideRoot, missingExecutables, invalidScenario, unsafeInput, inputBudget }
    private nonisolated static func relativePath(_ path: String, root: URL) throws -> String {
        let base = root.standardizedFileURL.path
        let selected = URL(fileURLWithPath: path).standardizedFileURL.path
        guard selected.hasPrefix(base + "/") else { throw Failure.selectedImageOutsideRoot }
        return String(selected.dropFirst(base.count + 1))
    }
    private struct Inputs: Sendable { var files: [String: Data]; var directories: [String] }
    private nonisolated static func captureInputs(_ root: URL?) throws -> Inputs {
        guard let root else { return .init(files: [:], directories: []) }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure.unsafeInput }; defer { close(rootFD) }
        var result = Inputs(files: [:], directories: []), total = 0
        func walk(_ directory: Int32, _ prefix: String, _ depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 16, result.files.count + result.directories.count <= 1024 else { throw Failure.inputBudget }
            guard let stream = fdopendir(dup(directory)) else { throw Failure.unsafeInput }
            defer { closedir(stream) }
            var names: [String] = []; errno = 0
            while let item = readdir(stream) {
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name != "." && name != ".." { names.append(name) }
                guard names.count + result.files.count + result.directories.count <= 1024 else { throw Failure.inputBudget }
                errno = 0
            }
            guard errno == 0 else { throw Failure.unsafeInput }
            for name in names.sorted() {
                try Task.checkCancellation()
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard REAProcessScenario.safeRelative(path) else { throw Failure.unsafeInput }
                var before = stat()
                guard fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.unsafeInput }
                if before.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw Failure.unsafeInput }; defer { close(child) }
                    result.directories.append(path); try walk(child, path, depth + 1)
                } else {
                    guard before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= 1_048_576,
                          before.st_size <= 16_777_216 - total else { throw Failure.inputBudget }
                    let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    guard file >= 0 else { throw Failure.unsafeInput }; defer { close(file) }
                    var opened = stat(), after = stat()
                    guard fstat(file, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
                          opened.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeInput }
                    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
                    while true {
                        let n = read(file, &buffer, buffer.count)
                        if n < 0 && errno == EINTR { continue }
                        guard n >= 0 else { throw Failure.unsafeInput }; if n == 0 { break }
                        guard bytes.count + n <= 1_048_576, total + n <= 16_777_216 else { throw Failure.inputBudget }
                        bytes.append(contentsOf: buffer.prefix(n)); total += n
                    }
                    guard fstat(file, &after) == 0, after.st_size == opened.st_size, bytes.count == opened.st_size,
                          after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
                          after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else { throw Failure.unsafeInput }
                    result.files[path] = bytes
                }
            }
        }
        try walk(rootFD, "", 0); return result
    }
    struct CatalogInput: Sendable { let path: String; let bytes: Data }
    struct CatalogInputs: Sendable { let captured: [CatalogInput]; let omitted: Int }
    nonisolated static func captureCatalogInputs(_ root: URL) throws -> CatalogInputs {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure.unsafeInput }; defer { close(rootFD) }
        var result: [CatalogInput] = [], examined = 0, total = 0, omitted = 0
        func walk(_ directory: Int32, _ prefix: String, _ depth: Int) throws {
            try Task.checkCancellation(); guard depth <= 16 else { throw Failure.inputBudget }
            guard let stream = fdopendir(dup(directory)) else { throw Failure.unsafeInput }
            defer { closedir(stream) }
            var names: [String] = []; errno = 0
            while let item = readdir(stream) {
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name != "." && name != ".." { names.append(name); examined += 1 }
                guard examined <= 20_000 else { throw Failure.inputBudget }; errno = 0
            }
            guard errno == 0 else { throw Failure.unsafeInput }
            for name in names.sorted() {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                var before = stat(); guard fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.unsafeInput }
                if before.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw Failure.unsafeInput }; defer { close(child) }
                    try walk(child, path, depth + 1)
                } else if name.lowercased().hasSuffix(".car") {
                    guard before.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeInput }
                    guard result.count < 4, before.st_size > 0, before.st_size <= 67_108_864,
                          before.st_size <= 134_217_728 - total else {
                        omitted += 1
                        continue
                    }
                    let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    guard file >= 0 else { throw Failure.unsafeInput }; defer { close(file) }
                    var opened = stat(), after = stat()
                    guard fstat(file, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
                          opened.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeInput }
                    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
                    while true {
                        try Task.checkCancellation()
                        let n = read(file, &buffer, buffer.count)
                        if n < 0 && errno == EINTR { continue }
                        guard n >= 0 else { throw Failure.unsafeInput }; if n == 0 { break }
                        guard bytes.count + n <= 67_108_864, total + n <= 134_217_728 else { throw Failure.inputBudget }
                        bytes.append(contentsOf: buffer.prefix(n)); total += n
                    }
                    guard fstat(file, &after) == 0, after.st_size == opened.st_size, bytes.count == opened.st_size,
                          after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
                          after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else { throw Failure.unsafeInput }
                    result.append(.init(path: path, bytes: bytes))
                }
            }
        }
        try walk(rootFD, "", 0); return CatalogInputs(captured: result, omitted: omitted)
    }
    private nonisolated static func treeCommitment(_ input: Inputs) throws -> String {
        var entries = input.files.map { REAScenarioCapture.InputFile(kind: "file", path: $0.key,
            sha256: REACaptureCommitment.digest($0.value), byteCount: UInt64($0.value.count)) }
        entries += input.directories.map { .init(kind: "directory", path: $0, sha256: REACaptureCommitment.digest(Data()), byteCount: 0) }
        return try REACaptureCommitment.sha256(entries.sorted { $0.path < $1.path })
    }
}
