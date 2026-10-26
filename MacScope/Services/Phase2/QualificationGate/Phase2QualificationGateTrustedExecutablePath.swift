import CryptoKit
import Darwin
import Foundation

enum Phase2QualificationGateTrustedPathFailure: Error, Equatable {
    case unavailable, account, path, protection, changed, leaf, bounds, hash, process
}

struct Phase2QualificationGatePathAccount: Equatable {
    let uid: uid_t
    let home: String
}

struct Phase2QualificationGatePathProcess: Equatable {
    let processID: Int32
    let parentID: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let device: UInt64
    let inode: UInt64
    let path: String
}

struct Phase2QualificationGatePathACL: Equatable {
    struct Entry: Equatable {
        let tag: UInt32
        let permissions: UInt64
        let flags: UInt32
        let qualifier: Data
    }
    let flags: UInt32
    let entries: [Entry]

    func check() throws {
        // Selected SDK sys/acl.h: no-inherit/defer-inherit on ACL; five entry flags.
        guard flags & ~UInt32(0x20001) == 0, entries.count <= 128 else {
            throw Phase2QualificationGateTrustedPathFailure.protection
        }
        let knownPermissions: UInt64 = 0x103ffe
        let mutationPermissions: UInt64 = 0x3574
        for entry in entries {
            guard entry.tag == 1 || entry.tag == 2,
                  entry.qualifier.count == 16,
                  entry.permissions & ~knownPermissions == 0,
                  entry.flags & ~UInt32(0x1f0) == 0 else {
                throw Phase2QualificationGateTrustedPathFailure.protection
            }
            if entry.tag == 1, entry.flags & 0x100 == 0,
               entry.permissions & mutationPermissions != 0 {
                throw Phase2QualificationGateTrustedPathFailure.protection
            }
        }
    }
}

struct Phase2QualificationGatePathMetadata: Equatable {
    let device: UInt64
    let inode: UInt64
    let owner: uid_t
    let group: gid_t
    let mode: mode_t
    let flags: UInt32
    let links: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    // nil is positively observed absence, never failed inspection.
    let acl: Phase2QualificationGatePathACL?

    var isDirectory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }

    func sameObjectAndProtection(as other: Self) -> Bool {
        device == other.device && inode == other.inode && owner == other.owner
            && group == other.group && mode == other.mode && flags == other.flags
            && acl == other.acl
            && (isDirectory || (links == other.links && size == other.size
                && modificationSeconds == other.modificationSeconds
                && modificationNanoseconds == other.modificationNanoseconds
                && changeSeconds == other.changeSeconds
                && changeNanoseconds == other.changeNanoseconds))
    }

    func check(uid: uid_t, leaf: Bool) throws {
        guard owner == 0 || owner == uid, mode & 0o022 == 0 else {
            throw Phase2QualificationGateTrustedPathFailure.protection
        }
        try acl?.check()
        if leaf {
            guard mode & mode_t(S_IFMT) == mode_t(S_IFREG), mode & 0o111 != 0,
                  mode & 0o6000 == 0, links == 1, size > 0 else {
                throw Phase2QualificationGateTrustedPathFailure.leaf
            }
        } else if !isDirectory { throw Phase2QualificationGateTrustedPathFailure.path }
    }
}

/// Injectable OS mechanics; production always uses the fixed Darwin backend below.
protocol Phase2QualificationGateTrustedPathBackend {
    func account() throws -> Phase2QualificationGatePathAccount
    func openRoot() throws -> Int32
    func openChild(parent: Int32, name: String, directory: Bool) throws -> Int32
    func metadata(_ descriptor: Int32) throws -> Phase2QualificationGatePathMetadata
    func edgeMatches(parent: Int32, name: String, object: Phase2QualificationGatePathMetadata) throws -> Bool
    func read(_ descriptor: Int32, offset: Int64, count: Int) throws -> Data
    func closeDescriptor(_ descriptor: Int32)
    func token(processID: Int32) throws -> Phase2QualificationGateAuditTokenCapture
    func process(processID: Int32) throws -> Phase2QualificationGatePathProcess
}

/// Owns descriptors until released. This protects against untrusted-principal replacement;
/// the account owner can still modify its files. It is not immutable or running-memory proof.
final class Phase2QualificationGateTrustedExecutablePathCapture {
    let role: Phase2QualificationProviderExecutableRole
    let token: Phase2QualificationGateAuditTokenCapture
    let executable: Phase2QualificationExecutableIdentity
    private let descriptors: [Int32]
    private let backend: any Phase2QualificationGateTrustedPathBackend

    fileprivate init(role: Phase2QualificationProviderExecutableRole,
                     token: Phase2QualificationGateAuditTokenCapture,
                     executable: Phase2QualificationExecutableIdentity,
                     descriptors: [Int32], backend: any Phase2QualificationGateTrustedPathBackend) {
        self.role = role
        self.token = token
        self.executable = executable
        self.descriptors = descriptors
        self.backend = backend
    }

    deinit { for descriptor in descriptors.reversed() { backend.closeDescriptor(descriptor) } }
}

struct Phase2QualificationGateTrustedExecutablePath {
    private let backend: any Phase2QualificationGateTrustedPathBackend
    static let maximumBytes: Int64 = 512 * 1024 * 1024
    static let maximumComponents = 64

    init() { backend = Phase2QualificationGateDarwinTrustedPathBackend() }
    init(backend: any Phase2QualificationGateTrustedPathBackend) { self.backend = backend }

    func capture(role: Phase2QualificationProviderExecutableRole,
                 token: Phase2QualificationGateAuditTokenCapture) throws
        -> Phase2QualificationGateTrustedExecutablePathCapture {
        let account = try backend.account()
        let expected = Phase2QualificationProviderRuntimeExpectation.candidate.executable(for: role)
        let path = account.home + "/" + expected.homeRelativePath
        guard account.home.hasPrefix("/"), !account.home.hasSuffix("/"),
              !path.contains("\0"), path.utf8.count < 4 * Int(MAXPATHLEN),
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              token.canonicalExecutablePath == path else {
            throw Phase2QualificationGateTrustedPathFailure.path
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard !components.isEmpty, components.count <= Self.maximumComponents,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Phase2QualificationGateTrustedPathFailure.bounds
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        func budget() throws {
            guard clock.now < deadline else { throw Phase2QualificationGateTrustedPathFailure.bounds }
        }
        guard try backend.token(processID: token.processID) == token else {
            throw Phase2QualificationGateTrustedPathFailure.process
        }
        let process = try backend.process(processID: token.processID)
        guard process.processID == token.processID, process.startSeconds > 0,
              process.startMicroseconds < 1_000_000, process.path == path else {
            throw Phase2QualificationGateTrustedPathFailure.process
        }
        var descriptors: [Int32] = []
        var transferred = false
        defer { if !transferred { for descriptor in descriptors.reversed() { backend.closeDescriptor(descriptor) } } }
        func walk() throws -> [Phase2QualificationGatePathMetadata] {
            let start = descriptors.count
            descriptors.append(try backend.openRoot())
            var values = [try backend.metadata(descriptors[start])]
            try values[0].check(uid: account.uid, leaf: false)
            for (index, component) in components.enumerated() {
                try budget()
                guard let parent = descriptors.last else { throw Phase2QualificationGateTrustedPathFailure.path }
                let leaf = index == components.count - 1
                let descriptor = try backend.openChild(parent: parent, name: component, directory: !leaf)
                descriptors.append(descriptor)
                let value = try backend.metadata(descriptor)
                try value.check(uid: account.uid, leaf: leaf)
                guard try backend.edgeMatches(parent: parent, name: component, object: value) else {
                    throw Phase2QualificationGateTrustedPathFailure.changed
                }
                values.append(value)
            }
            return values
        }
        let values = try walk()
        guard let leaf = values.last, let leafDescriptor = descriptors.last else {
            throw Phase2QualificationGateTrustedPathFailure.path
        }
        guard leaf.size <= Self.maximumBytes else { throw Phase2QualificationGateTrustedPathFailure.bounds }
        var digest = SHA256()
        var offset: Int64 = 0
        while offset < leaf.size {
            try budget()
            let count = Int(min(65536, leaf.size - offset))
            let bytes = try backend.read(leafDescriptor, offset: offset, count: count)
            guard !bytes.isEmpty, bytes.count <= count else { throw Phase2QualificationGateTrustedPathFailure.changed }
            digest.update(data: bytes)
            offset += Int64(bytes.count)
        }
        guard try backend.read(leafDescriptor, offset: offset, count: 1).isEmpty else {
            throw Phase2QualificationGateTrustedPathFailure.changed
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let identity = Phase2QualificationExecutableIdentity(deviceID: leaf.device, fileID: leaf.inode, sha256: hash)
        // Re-traverse independently from /, retaining both chains to detect parent replacement.
        let again = try walk()
        guard zip(values, again).allSatisfy({ $0.sameObjectAndProtection(as: $1) }) else {
            throw Phase2QualificationGateTrustedPathFailure.changed
        }
        for index in descriptors.indices {
            try budget()
            let slot = index % values.count
            let current = try backend.metadata(descriptors[index])
            guard values[slot].sameObjectAndProtection(as: current) else {
                throw Phase2QualificationGateTrustedPathFailure.changed
            }
            if slot > 0, try !backend.edgeMatches(parent: descriptors[index - 1],
                name: components[slot - 1], object: current) {
                throw Phase2QualificationGateTrustedPathFailure.changed
            }
        }
        guard try backend.account() == account,
              try backend.process(processID: token.processID) == process,
              try backend.token(processID: token.processID) == token else {
            throw Phase2QualificationGateTrustedPathFailure.process
        }
        try budget()
        guard identity.deviceID == process.device, identity.fileID == process.inode else {
            throw Phase2QualificationGateTrustedPathFailure.process
        }
        guard hash == expected.sha256 else { throw Phase2QualificationGateTrustedPathFailure.hash }
        transferred = true
        return .init(role: role, token: token, executable: identity,
                     descriptors: descriptors, backend: backend)
    }
}

struct Phase2QualificationGateDarwinTrustedPathBackend: Phase2QualificationGateTrustedPathBackend {
    func account() throws -> Phase2QualificationGatePathAccount {
        let uid = getuid()
        guard uid == geteuid() else { throw Phase2QualificationGateTrustedPathFailure.account }
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var storage = [CChar](repeating: 0, count: 65536)
        return try storage.withUnsafeMutableBufferPointer { buffer in
            guard getpwuid_r(uid, &record, buffer.baseAddress, buffer.count, &result) == 0,
                  result != nil, record.pw_uid == uid, let home = record.pw_dir else {
                throw Phase2QualificationGateTrustedPathFailure.account
            }
            return .init(uid: uid, home: String(cString: home))
        }
    }

    func openRoot() throws -> Int32 { try checked(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) }
    func openChild(parent: Int32, name: String, directory: Bool) throws -> Int32 {
        try checked(openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0)))
    }
    private func checked(_ descriptor: Int32) throws -> Int32 {
        guard descriptor >= 0 else { throw Phase2QualificationGateTrustedPathFailure.unavailable }
        return descriptor
    }
    func closeDescriptor(_ descriptor: Int32) { _ = Darwin.close(descriptor) }

    func metadata(_ descriptor: Int32) throws -> Phase2QualificationGatePathMetadata {
        guard let security = filesec_init() else { throw Phase2QualificationGateTrustedPathFailure.unavailable }
        defer { filesec_free(security) }
        var value = stat()
        var present: Int32 = 0
        guard fstatx_np(descriptor, &value, security) == 0,
              filesec_query_property(security, FILESEC_ACL, &present) == 0 else {
            throw Phase2QualificationGateTrustedPathFailure.unavailable
        }
        var aclValue: Phase2QualificationGatePathACL?
        if present != 0 {
            var acl: acl_t?
            guard filesec_get_property(security, FILESEC_ACL, &acl) == 0, let acl else {
                throw Phase2QualificationGateTrustedPathFailure.unavailable
            }
            defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
            aclValue = try Self.inspectACL(acl)
        }
        return .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino),
            owner: value.st_uid, group: value.st_gid, mode: value.st_mode, flags: value.st_flags,
            links: UInt64(value.st_nlink), size: value.st_size,
            modificationSeconds: Int64(value.st_mtimespec.tv_sec), modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec), changeNanoseconds: Int64(value.st_ctimespec.tv_nsec), acl: aclValue)
    }

    /// Public sys/acl.h interfaces only. A failed flag query is unavailable, not absence.
    static func inspectACL(_ acl: acl_t) throws -> Phase2QualificationGatePathACL {
        func flags(_ object: UnsafeMutableRawPointer) throws -> UInt32 {
            var set: acl_flagset_t?
            guard acl_get_flagset_np(object, &set) == 0, let set else {
                throw Phase2QualificationGateTrustedPathFailure.unavailable
            }
            var bits: UInt32 = 0
            for index in 0..<32 {
                let bit = UInt32(1) << index
                let result = acl_get_flag_np(set, acl_flag_t(rawValue: bit))
                guard result == 0 || result == 1 else { throw Phase2QualificationGateTrustedPathFailure.unavailable }
                if result == 1 { bits |= bit }
            }
            return bits
        }
        let aclFlags = try flags(UnsafeMutableRawPointer(acl))
        var entries: [Phase2QualificationGatePathACL.Entry] = []
        var selector = ACL_FIRST_ENTRY.rawValue
        while true {
            var entry: acl_entry_t?
            errno = 0
            let status = acl_get_entry(acl, selector, &entry)
            if status == -1, errno == EINVAL { break }
            guard status == 0, let entry, entries.count < 128 else {
                throw Phase2QualificationGateTrustedPathFailure.unavailable
            }
            selector = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0,
                  acl_get_permset_mask_np(entry, &permissions) == 0,
                  let qualifier = acl_get_qualifier(entry) else {
                throw Phase2QualificationGateTrustedPathFailure.unavailable
            }
            defer { _ = acl_free(qualifier) }
            entries.append(.init(tag: tag.rawValue, permissions: permissions,
                flags: try flags(UnsafeMutableRawPointer(entry)), qualifier: Data(bytes: qualifier, count: 16)))
        }
        return .init(flags: aclFlags, entries: entries)
    }

    func edgeMatches(parent: Int32, name: String, object: Phase2QualificationGatePathMetadata) throws -> Bool {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Phase2QualificationGateTrustedPathFailure.unavailable
        }
        return UInt64(UInt32(bitPattern: value.st_dev)) == object.device && UInt64(value.st_ino) == object.inode
            && value.st_uid == object.owner && value.st_gid == object.group && value.st_mode == object.mode
            && value.st_flags == object.flags
    }
    func read(_ descriptor: Int32, offset: Int64, count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        let amount = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, offset) }
        guard amount >= 0 else { throw Phase2QualificationGateTrustedPathFailure.unavailable }
        return Data(buffer.prefix(amount))
    }
    func token(processID: Int32) throws -> Phase2QualificationGateAuditTokenCapture {
        try Phase2QualificationGateAuditTokenAuthority().capture(processID: processID).get()
    }
    func process(processID: Int32) throws -> Phase2QualificationGatePathProcess {
        var before = proc_bsdinfo()
        var after = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &before, size) == size else {
            throw Phase2QualificationGateTrustedPathFailure.process
        }
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = bytes.withUnsafeMutableBytes { proc_pidpath(processID, $0.baseAddress, UInt32($0.count)) }
        guard count > 0, Int(count) < bytes.count,
              let path = String(bytes: bytes.prefix(Int(count)), encoding: .utf8) else {
            throw Phase2QualificationGateTrustedPathFailure.process
        }
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &after, size) == size,
              before.pbi_pid == UInt32(processID), before.pbi_pid == after.pbi_pid,
              before.pbi_ppid == after.pbi_ppid,
              before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec else {
            throw Phase2QualificationGateTrustedPathFailure.process
        }
        return .init(processID: processID, parentID: after.pbi_ppid,
            startSeconds: after.pbi_start_tvsec, startMicroseconds: after.pbi_start_tvusec,
            device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino), path: path)
    }
}
