import ApplicationServices
import CryptoKit
import Darwin
import Foundation

/// AppKit exposes the document-edited Boolean on the native close button, not AXWindow.
/// Resolve the exact window relationship afresh; unsupported/malformed observations fail closed.
enum Task10DocumentEditedReader {
    static func read(
        window: AXUIElement,
        expectedPID: pid_t,
        attribute: (AXUIElement, CFString) -> (AXError, CFTypeRef?) = copyAttribute,
        processID: (AXUIElement) -> (AXError, pid_t) = copyProcessID
    ) throws -> Bool {
        func requirePID(_ element: AXUIElement) throws {
            let (status, pid) = processID(element)
            guard status == .success, expectedPID > 0, pid == expectedPID else {
                throw invalid("document/close-button process identity", status)
            }
        }
        func element(_ name: CFString, of owner: AXUIElement) throws -> AXUIElement {
            let (status, value) = attribute(owner, name)
            guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw invalid("\(name) AXUIElement type", status)
            }
            // The CF type identity is checked before this otherwise unconditional CF bridge.
            return value as! AXUIElement
        }
        func requireString(_ name: CFString, of owner: AXUIElement, equals expected: String) throws {
            let (status, value) = attribute(owner, name)
            guard status == .success, let value, CFGetTypeID(value) == CFStringGetTypeID(),
                  value as? String == expected else {
                throw invalid("close-button \(name)", status)
            }
        }

        try requirePID(window)
        let close = try element(kAXCloseButtonAttribute as CFString, of: window)
        try requirePID(close)
        try requireString(kAXRoleAttribute as CFString, of: close, equals: kAXButtonRole as String)
        try requireString(kAXSubroleAttribute as CFString, of: close, equals: kAXCloseButtonSubrole as String)
        let owner = try element(kAXWindowAttribute as CFString, of: close)
        guard CFEqual(owner, window) else { throw invalid("close-button window identity", .success) }
        let (status, value) = attribute(close, kAXEditedAttribute as CFString)
        guard status == .success, let value, CFGetTypeID(value) == CFBooleanGetTypeID(),
              let edited = value as? Bool else {
            throw invalid("close-button Boolean AXEdited", status)
        }
        return edited
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: CFString) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        return (status, value)
    }

    private static func copyProcessID(_ element: AXUIElement) -> (AXError, pid_t) {
        var pid: pid_t = 0
        let status = AXUIElementGetPid(element, &pid)
        return (status, pid)
    }

    private static func invalid(_ reason: String, _ status: AXError) -> NSError {
        NSError(domain: "Task10DocumentEditedReader", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot prove \(reason) (AX error \(status.rawValue))."])
    }
}

/// A stable, read-only observation of the two package files consumed by the creation oracle.
/// Physical root replacement proves a new publication even when serialized bytes are identical;
/// it never substitutes for the separate canonical history/content validation.
struct Task10SavedPackageObservation {
    struct RootIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    let packageURL: URL
    let documentID: UUID
    let workspaceID: UUID
    let rootIdentity: RootIdentity
    let workspaceManifest: Data
    let checkpointManifest: Data

    func isNewPublication(after prior: Self) throws -> Bool {
        guard packageURL == prior.packageURL, documentID == prior.documentID,
              workspaceID == prior.workspaceID else {
            throw Self.invalid("Save changed the package or logical document identity")
        }
        return rootIdentity != prior.rootIdentity
    }

    static func capture(at packageURL: URL) throws -> Self {
        guard packageURL.isFileURL,
              packageURL.standardizedFileURL.path == packageURL.path,
              packageURL.resolvingSymlinksInPath().path == packageURL.path else {
            throw invalid("Save package path is not canonical and physical")
        }
        let root = Darwin.open(packageURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw invalid("Save package root cannot be opened") }
        defer { Darwin.close(root) }
        var before = stat()
        guard Darwin.fstat(root, &before) == 0 else { throw invalid("Save package root cannot be observed") }
        let manifest = try read("manifest.json", under: root)
        let reconstruction = Darwin.openat(root, "Reconstruction", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard reconstruction >= 0 else { throw invalid("Save reconstruction directory cannot be opened") }
        defer { Darwin.close(reconstruction) }
        var reconstructionBefore = stat()
        guard Darwin.fstat(reconstruction, &reconstructionBefore) == 0 else {
            throw invalid("Save reconstruction directory cannot be observed")
        }
        let checkpoint = try read("checkpoint-manifest.json", under: reconstruction)
        guard let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              object["formatIdentifier"] as? String == "org.macscope.workspace-package",
              object["formatVersion"] as? Int == 3,
              let document = object["documentID"] as? String, let documentID = UUID(uuidString: document),
              let workspace = object["workspaceUUID"] as? String, let workspaceID = UUID(uuidString: workspace),
              let descriptor = object["reconstruction"] as? [String: Any],
              descriptor["checkpointManifestPath"] as? String == "Reconstruction/checkpoint-manifest.json",
              descriptor["checkpointManifestSHA256"] as? String == SHA256.hash(data: checkpoint)
                .map({ String(format: "%02x", $0) }).joined() else {
            throw invalid("Save package identity or checkpoint binding is invalid")
        }
        var after = stat()
        var named = stat()
        var reconstructionAfter = stat()
        var reconstructionNamed = stat()
        guard try read("manifest.json", under: root) == manifest,
              try read("checkpoint-manifest.json", under: reconstruction) == checkpoint,
              Darwin.fstat(reconstruction, &reconstructionAfter) == 0,
              Darwin.fstatat(root, "Reconstruction", &reconstructionNamed, AT_SYMLINK_NOFOLLOW) == 0,
              sameMetadata(reconstructionBefore, reconstructionAfter),
              sameMetadata(reconstructionAfter, reconstructionNamed),
              Darwin.fstat(root, &after) == 0,
              Darwin.lstat(packageURL.path, &named) == 0,
              sameMetadata(before, after), sameMetadata(after, named),
              packageURL.resolvingSymlinksInPath().path == packageURL.path else {
            throw invalid("Save package changed during observation")
        }
        return Self(packageURL: packageURL, documentID: documentID, workspaceID: workspaceID,
                    rootIdentity: RootIdentity(device: before.st_dev, inode: before.st_ino),
                    workspaceManifest: manifest, checkpointManifest: checkpoint)
    }

    private static func read(_ name: String, under directory: Int32) throws -> Data {
        let descriptor = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalid("Save manifest cannot be opened: \(name)") }
        defer { Darwin.close(descriptor) }
        var before = stat()
        let maximumBytes = 16 * 1024 * 1024
        guard Darwin.fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size > 0, before.st_size <= off_t(maximumBytes) else {
            throw invalid("Save manifest is not a bounded regular file: \(name)")
        }
        let bytes = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            .read(upToCount: maximumBytes + 1) ?? Data()
        var after = stat()
        var named = stat()
        guard bytes.count == Int(before.st_size),
              Darwin.fstat(descriptor, &after) == 0,
              Darwin.fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameMetadata(before, after), sameMetadata(after, named) else {
            throw invalid("Save manifest changed during observation: \(name)")
        }
        return bytes
    }

    private static func sameMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func invalid(_ reason: String) -> NSError {
        NSError(domain: "Task10SavedPackageObservation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason])
    }
}

/// A narrow test oracle over the actual File > Save output, not a persistence implementation.
/// CoreTests feeds production canonical DTOs to this same UI-runner helper.
enum Task10CreationHistoryVerifier {
    struct Proof {
        let jobID: UUID
        let creationOrdinal: UInt64
        let currentRevision: Int
        let initialTaskCount: Int
    }

    struct InvalidHistory: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "Creation history did not prove commit-before-execution: \(reason)" }
    }

    static func hasEmptyIdentity(_ accessibilityText: String) -> Bool {
        // emptyHeader owns this identity surface; header's "No job" value is not rendered
        // when the projection is empty.
        accessibilityText.localizedCaseInsensitiveContains("No reconstruction job")
    }

    static func selectedNavigatorJobID(
        identifier: String, label: String, isSelected: Bool,
        expectedObjective: String, visibleCreationOrdinal: UInt64
    ) throws -> UUID {
        let identifierPrefix = "reconstruction:job:"
        let labelPrefix = "\(expectedObjective), #\(visibleCreationOrdinal) · "
        guard isSelected, identifier.hasPrefix(identifierPrefix),
              let jobID = UUID(uuidString: String(identifier.dropFirst(identifierPrefix.count))),
              label.hasPrefix(labelPrefix), label.count > labelPrefix.count else {
            throw invalid("selected navigator objective/ordinal/job identity")
        }
        return jobID
    }

    /// Total/pending counts change at the initial atomic publication; they are not execution.
    static func hasAutomatedProgress(_ accessibilityText: String) throws -> Bool {
        let pattern = #"(\d+) of (\d+) tasks completed; (\d+) pending, (\d+) running, (\d+) completed, (\d+) failed, (\d+) blocked"#
        let expression = try NSRegularExpression(pattern: pattern)
        let text = accessibilityText as NSString
        let matches = expression.matches(in: accessibilityText, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty, text.length <= 4096 else { throw invalid("missing progress counts") }
        let summaries = try matches.map { match in
            try (1...7).map { group in
                guard let value = Int(text.substring(with: match.range(at: group))), value >= 0 else {
                    throw invalid("invalid progress count")
                }
                return value
            }
        }
        guard let counts = summaries.first, summaries.allSatisfy({ $0 == counts }),
              counts[0] == counts[4], counts[1] == counts[2...6].reduce(0, +) else {
            throw invalid("inconsistent progress counts")
        }
        return counts[3...6].contains { $0 > 0 }
    }

    static func verify(
        workspaceManifest: Data, checkpointManifest: Data,
        expectedProjectID: UUID, expectedOccurrenceID: UUID,
        expectedObjective: String, visibleCreationOrdinal: UInt64
    ) throws -> Proof {
        let workspace = try object(workspaceManifest)
        guard workspace["formatIdentifier"] as? String == "org.macscope.workspace-package",
              workspace["formatVersion"] as? Int == 3,
              let descriptor = workspace["reconstruction"] as? [String: Any],
              descriptor["checkpointManifestPath"] as? String == "Reconstruction/checkpoint-manifest.json",
              descriptor["checkpointManifestSHA256"] as? String == sha256(checkpointManifest) else {
            throw invalid("workspace/checkpoint file binding")
        }
        let manifest = try object(checkpointManifest)
        guard manifest["schemaVersion"] as? Int == 1,
              let jobs = manifest["jobs"] as? [[String: Any]], jobs.count == 1,
              let job = jobs.first, let jobID = job["jobID"] as? String,
              let uuid = UUID(uuidString: jobID),
              job["creationOrdinal"] as? UInt64 == visibleCreationOrdinal,
              job["reconstructionProjectID"] as? String == expectedProjectID.uuidString,
              job["objective"] as? String == expectedObjective,
              job["objectiveSHA256"] as? String == sha256(Data(expectedObjective.utf8)),
              let tasks = manifest["tasks"] as? [[String: Any]], !tasks.isEmpty, tasks.count <= 4096,
              let checkpoints = manifest["checkpoints"] as? [[String: Any]],
              checkpoints.count > 1, checkpoints.count <= 4096 else {
            throw invalid("new job identity or missing execution history")
        }
        var taskByID: [String: [String: Any]] = [:]
        for task in tasks {
            guard let identity = task["identity"] as? [String: Any],
                  identity["jobID"] as? String == jobID,
                  let taskID = identity["taskID"] as? String, UUID(uuidString: taskID) != nil,
                  taskByID.updateValue(task, forKey: taskID) == nil else {
                throw invalid("task ownership or duplicate identity")
            }
            try verifyCanonical(identity, byteCount: false)
        }
        let ordered = try checkpoints.sorted {
            try integer($0, "revision") < integer($1, "revision")
        }
        var seenCheckpointIDs = Set<String>()
        for (revision, checkpoint) in ordered.enumerated() {
            guard try integer(checkpoint, "revision") == revision,
                  checkpoint["jobID"] as? String == jobID,
                  let checkpointID = checkpoint["checkpointID"] as? String,
                  UUID(uuidString: checkpointID) != nil,
                  seenCheckpointIDs.insert(checkpointID).inserted else {
                throw invalid("checkpoint revision/identity")
            }
            try verifyCanonical(checkpoint, byteCount: true)
            if revision == 0 {
                guard checkpoint["parentCheckpointID"] == nil,
                      checkpoint["parentCheckpointSHA256"] == nil else { throw invalid("initial parent") }
            } else {
                let parent = ordered[revision - 1]
                guard checkpoint["parentCheckpointID"] as? String == parent["checkpointID"] as? String,
                      checkpoint["parentCheckpointSHA256"] as? String == parent["canonicalSHA256"] as? String else {
                    throw invalid("broken parent chain")
                }
            }
            var memberIDs = Set<String>()
            for key in taskStateKeys {
                let ids = try identifiers(checkpoint, key)
                guard ids.allSatisfy({ taskByID[$0] != nil && memberIDs.insert($0).inserted }) else {
                    throw invalid("checkpoint task membership")
                }
            }
        }
        guard let initial = ordered.first, let current = ordered.last,
              initial["coordinatorState"] as? String == "created",
              initial["corpusManifestSHA256"] as? String == job["creationCorpusManifestSHA256"] as? String,
              initial["terminalReason"] == nil,
              job["currentCheckpointID"] as? String == current["checkpointID"] as? String,
              job["state"] as? String == current["coordinatorState"] as? String else {
            throw invalid("initial/current job cut")
        }
        let initialIDs = try identifiers(initial, "pendingTaskIDs")
        guard initialIDs.count == 3 else { throw invalid("initial selected task DAG") }
        for key in ["runningTaskIDs", "completedTaskIDs", "failedTaskIDs", "blockedTaskIDs", "modelReceiptIDs", "toolReceiptIDs"] {
            guard try identifiers(initial, key).isEmpty else { throw invalid("initial execution or receipt") }
        }
        var taskByKind: [String: [String: Any]] = [:]
        for taskID in initialIDs {
            guard let task = taskByID[taskID], let identity = task["identity"] as? [String: Any],
                  let kind = identity["kind"] as? String,
                  ["ingest", "classify", "discoverRelations"].contains(kind),
                  taskByKind.updateValue(identity, forKey: kind) == nil,
                  identity["operationContractIdentity"] as? String == "reconstruction.\(kind).v1",
                  let subject = identity["subject"] as? [String: Any],
                  let artifact = subject["artifact"] as? [String: Any],
                  let coordinate = artifact["_0"] as? [String: Any],
                  let occurrence = coordinate["occurrenceID"] as? [String: Any],
                  occurrence["rawValue"] as? String == expectedOccurrenceID.uuidString else {
                throw invalid("initial task subject/kind")
            }
        }
        for (kind, dependencyKind) in [("ingest", nil), ("classify", "ingest"), ("discoverRelations", "classify")] as [(String, String?)] {
            guard let task = taskByKind[kind] else { throw invalid("initial task kind") }
            let expectedDependencies = dependencyKind.flatMap { taskByKind[$0]?["taskID"] as? String }.map { [$0] } ?? []
            guard try identifiers(task, "dependencyTaskIDs") == expectedDependencies else { throw invalid("initial dependencies") }
        }
        // Current records are mutable; the immutable initial checkpoint is the pending-only cut.
        for (key, state) in zip(taskStateKeys, ["pending", "running", "completed", "failed", "blocked"]) {
            let expected = Set(tasks.compactMap { task -> String? in
                guard task["state"] as? String == state else { return nil }
                return (task["identity"] as? [String: Any])?["taskID"] as? String
            })
            guard Set(try identifiers(current, key)) == expected else { throw invalid("current task projection") }
        }
        let executedInitialIDs = Set(try identifiers(current, "runningTaskIDs") + identifiers(current, "completedTaskIDs"))
            .intersection(initialIDs)
        guard !executedInitialIDs.isEmpty else { throw invalid("pending-only history is not automation") }
        return Proof(jobID: uuid, creationOrdinal: visibleCreationOrdinal,
                     currentRevision: ordered.count - 1, initialTaskCount: initialIDs.count)
    }

    private static let taskStateKeys = ["pendingTaskIDs", "runningTaskIDs", "completedTaskIDs", "failedTaskIDs", "blockedTaskIDs"]

    private static func verifyCanonical(_ record: [String: Any], byteCount: Bool) throws {
        var preimage = record
        guard let digest = preimage.removeValue(forKey: "canonicalSHA256") as? String else { throw invalid("canonical digest missing") }
        let expectedByteCount = preimage.removeValue(forKey: "canonicalEncodedByteCount") as? Int
        // Matches ReconstructionCanonicalJSON's sortedKeys/withoutEscapingSlashes wire format.
        // Production DTO compatibility is independently exercised by the CoreTests positive case.
        let bytes = try JSONSerialization.data(withJSONObject: preimage, options: [.sortedKeys, .withoutEscapingSlashes])
        guard digest == sha256(bytes), !byteCount || expectedByteCount == bytes.count else {
            throw invalid("canonical identity mismatch")
        }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 16 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalid("invalid bounded manifest")
        }
        return object
    }

    private static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        guard let value = object[key] as? Int, value >= 0 else { throw invalid("missing \(key)") }
        return value
    }

    private static func identifiers(_ object: [String: Any], _ key: String) throws -> [String] {
        guard let ids = object[key] as? [String], ids.count <= 4096,
              ids.allSatisfy({ UUID(uuidString: $0) != nil }), Set(ids).count == ids.count else {
            throw invalid("invalid \(key)")
        }
        return ids
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func invalid(_ reason: String) -> InvalidHistory { InvalidHistory(reason: reason) }
}
