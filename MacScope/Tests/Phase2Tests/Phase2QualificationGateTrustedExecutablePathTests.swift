import Darwin
import Foundation
import Security
import XCTest
@testable import MacScope

final class Phase2QualificationGateTrustedExecutablePathTests: XCTestCase {
    typealias Failure = Phase2QualificationGateTrustedPathFailure
    typealias Metadata = Phase2QualificationGatePathMetadata
    typealias ACL = Phase2QualificationGatePathACL

    func testProtectionAndACLPolicyTable() throws {
        let qualifier = Data(repeating: 0, count: 16)
        for (mode, owner, accepted) in [(0o755, 501, true), (0o700, 0, true),
            (0o757, 501, false), (0o775, 501, false), (0o755, 502, false)] {
            let value = metadata(mode: mode_t(S_IFDIR) | mode_t(mode), owner: uid_t(owner))
            if accepted { XCTAssertNoThrow(try value.check(uid: 501, leaf: false)) }
            else { XCTAssertThrowsError(try value.check(uid: 501, leaf: false)) }
        }
        for (tag, permissions, flags, accepted) in [
            (1, UInt64(2), UInt32(0), true), (2, 0x3574, 0, true),
            (1, 4, 0, false), (1, 4, 0x100, true), (1, 4, 0x10, false),
            (3, 2, 0, false), (1, 1 << 30, 0, false), (2, 2, 1 << 30, false)] {
            let value = ACL(flags: 0, entries: [.init(tag: UInt32(tag), permissions: permissions,
                flags: flags, qualifier: qualifier)])
            if accepted { XCTAssertNoThrow(try value.check()) }
            else { XCTAssertThrowsError(try value.check()) }
        }
        let denyAndGrant = ACL(flags: 0, entries: [
            .init(tag: 2, permissions: 4, flags: 0, qualifier: qualifier),
            .init(tag: 1, permissions: 4, flags: 0, qualifier: qualifier)])
        XCTAssertThrowsError(try denyAndGrant.check())
        XCTAssertNoThrow(try metadata().check(uid: 501, leaf: true)) // known absent ACL
    }

    func testTraversalRejectionsReleaseEveryAcquiredDescriptor() throws {
        let cases: [(String, Failure)] = [("secure", .hash), ("acl-unavailable", .unavailable),
            ("writable", .protection), ("edge-replaced", .changed), ("retrace-replaced", .changed),
            ("file-drift", .changed), ("short-read", .changed), ("oversized-read", .changed),
            ("growth", .changed), ("oversize", .bounds), ("hardlink", .leaf), ("fifo", .leaf),
            ("token", .process), ("account", .process), ("alias", .path), ("process-inode", .process)]
        for (scenario, expected) in cases {
            let backend = Backend(scenario: scenario)
            let token = try backend.initialToken()
            XCTAssertThrowsError(try Phase2QualificationGateTrustedExecutablePath(backend: backend)
                .capture(role: .node, token: token), scenario) {
                XCTAssertEqual($0 as? Failure, expected, scenario)
            }
            XCTAssertEqual(backend.closed.sorted(), backend.opened.sorted(), scenario)
            XCTAssertEqual(Set(backend.closed).count, backend.closed.count, scenario)
            XCTAssertLessThanOrEqual(backend.maximumRead, 65536, scenario)
        }
    }

    func testDirectorySiblingTimesDoNotBecomeExecutableIdentity() {
        let first = metadata(mode: mode_t(S_IFDIR) | 0o755)
        let siblingWrite = metadata(mode: mode_t(S_IFDIR) | 0o755, size: 500, time: 99)
        XCTAssertTrue(first.sameObjectAndProtection(as: siblingWrite))
        XCTAssertFalse(metadata().sameObjectAndProtection(as: metadata(time: 99)))
        XCTAssertFalse(first.sameObjectAndProtection(as: metadata(mode: mode_t(S_IFDIR) | 0o757)))
    }

    // Runs only against a create-only test-owned directory, never provider paths.
    // Also exercises Darwin zero-success / EINVAL-exhaustion and all-bit flag queries.
    func testDarwinDescriptorACLAndNoFollowFixture() throws {
        // Keep fixtures under the work root when MACSCOPE_WORK_ROOT names an existing directory;
        // otherwise use the per-process temporary root like the surrounding CoreTests fixtures.
        let root = TestWorkRoot.scratch
        let directory = root
            .appendingPathComponent("trusted-path-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fd = open(directory.appendingPathComponent("leaf").path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o700)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { _ = close(fd) }
        XCTAssertEqual("x".withCString { write(fd, $0, 1) }, 1)
        let backend = Phase2QualificationGateDarwinTrustedPathBackend()
        XCTAssertNoThrow(try backend.metadata(fd).check(uid: getuid(), leaf: true))
        for (tag, permission, allowed) in [(ACL_EXTENDED_DENY, ACL_WRITE_DATA, true),
            (ACL_EXTENDED_ALLOW, ACL_READ_DATA, true), (ACL_EXTENDED_ALLOW, ACL_WRITE_DATA, false)] {
            var acl = acl_init(1)
            defer { if let acl { _ = acl_free(UnsafeMutableRawPointer(acl)) } }
            var entry: acl_entry_t?
            XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
            let item = try XCTUnwrap(entry)
            XCTAssertEqual(acl_set_tag_type(item, tag), 0)
            var principal = try XCTUnwrap(UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C")).uuid
            XCTAssertEqual(withUnsafePointer(to: &principal) { acl_set_qualifier(item, $0) }, 0)
            var permissions: acl_permset_t?
            XCTAssertEqual(acl_get_permset(item, &permissions), 0)
            XCTAssertEqual(acl_add_perm(try XCTUnwrap(permissions), permission), 0)
            XCTAssertEqual(acl_set_fd_np(fd, try XCTUnwrap(acl), ACL_TYPE_EXTENDED), 0)
            let observation = try backend.metadata(fd)
            XCTAssertEqual(observation.acl?.entries.count, 1)
            if allowed { XCTAssertNoThrow(try observation.check(uid: getuid(), leaf: true)) }
            else { XCTAssertThrowsError(try observation.check(uid: getuid(), leaf: true)) }
        }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { XCTFail("fixture directory open failed"); return }
        defer { _ = close(parent) }
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("alias").path,
                                                  withDestinationPath: "leaf")
        XCTAssertThrowsError(try backend.openChild(parent: parent, name: "alias", directory: false))
        let old = try backend.metadata(fd)
        try FileManager.default.moveItem(at: directory.appendingPathComponent("leaf"),
                                        to: directory.appendingPathComponent("renamed"))
        XCTAssertThrowsError(try backend.edgeMatches(parent: parent, name: "leaf", object: old))
        XCTAssertEqual(try backend.read(fd, offset: 0, count: 1), Data("x".utf8))
        XCTAssertThrowsError(try backend.metadata(-1)) // unavailable cannot become absent ACL
    }

    private func metadata(mode: mode_t = mode_t(S_IFREG) | 0o755, owner: uid_t = 501,
                          size: Int64 = 1, time: Int64 = 1) -> Metadata {
        Self.value(mode: mode, owner: owner, size: size, time: time)
    }

    private static func value(mode: mode_t = mode_t(S_IFREG) | 0o755, owner: uid_t = 501,
                              size: Int64 = 1, time: Int64 = 1, inode: UInt64 = 9,
                              links: UInt64 = 1) -> Metadata {
        .init(device: 1, inode: inode, owner: owner, group: 20, mode: mode, flags: 0,
              links: links, size: size, modificationSeconds: time, modificationNanoseconds: 0,
              changeSeconds: time, changeNanoseconds: 0, acl: nil)
    }

    private final class Backend: Phase2QualificationGateTrustedPathBackend {
        let scenario: String
        var opened: [Int32] = [], closed: [Int32] = []
        var leafDescriptors: Set<Int32> = []
        var tokenCalls = 0, accountCalls = 0, walks = 0, maximumRead = 0
        var hasRead = false
        init(scenario: String) { self.scenario = scenario }
        func account() throws -> Phase2QualificationGatePathAccount {
            accountCalls += 1
            return .init(uid: scenario == "account" && accountCalls > 1 ? 502 : 501, home: "/Users/test-authority")
        }
        func initialToken() throws -> Phase2QualificationGateAuditTokenCapture {
            try Phase2QualificationGateAuditTokenAuthority(backend: TokenBackend(alias: scenario == "alias", changed: false))
                .capture(processID: 123).get()
        }
        func token(processID: Int32) throws -> Phase2QualificationGateAuditTokenCapture {
            tokenCalls += 1
            return try Phase2QualificationGateAuditTokenAuthority(backend: TokenBackend(alias: false,
                changed: scenario == "token" && tokenCalls > 1)).capture(processID: processID).get()
        }
        func process(processID: Int32) throws -> Phase2QualificationGatePathProcess {
            .init(processID: processID, parentID: 1, startSeconds: 1, startMicroseconds: 0,
                  device: 1, inode: scenario == "process-inode" ? 10 : 9, path: "/Users/test-authority/" +
                    Phase2QualificationProviderRuntimeExpectation.candidate.executable(for: .node).homeRelativePath)
        }
        func openRoot() throws -> Int32 { walks += 1; return allocate() }
        func openChild(parent: Int32, name: String, directory: Bool) throws -> Int32 {
            let fd = allocate()
            if !directory { leafDescriptors.insert(fd) }
            return fd
        }
        private func allocate() -> Int32 {
            let fd = Int32(opened.count + 10)
            opened.append(fd)
            return fd
        }
        func metadata(_ descriptor: Int32) throws -> Metadata {
            if scenario == "acl-unavailable" { throw Failure.unavailable }
            let leaf = leafDescriptors.contains(descriptor)
            var mode = leaf ? mode_t(S_IFREG) | 0o755 : mode_t(S_IFDIR) | 0o755
            if scenario == "writable" { mode |= 0o002 }
            if scenario == "fifo" && leaf { mode = mode_t(S_IFIFO) | 0o755 }
            return Phase2QualificationGateTrustedExecutablePathTests.value(mode: mode,
                size: scenario == "oversize" && leaf ? Phase2QualificationGateTrustedExecutablePath.maximumBytes + 1 : 1,
                time: scenario == "file-drift" && leaf && hasRead ? 2 : 1,
                inode: scenario == "retrace-replaced" && walks > 1 ? 10 : 9,
                links: scenario == "hardlink" && leaf ? 2 : 1)
        }
        func edgeMatches(parent: Int32, name: String, object: Metadata) throws -> Bool { scenario != "edge-replaced" }
        func read(_ descriptor: Int32, offset: Int64, count: Int) throws -> Data {
            maximumRead = max(maximumRead, count)
            hasRead = true
            if scenario == "short-read" { return Data() }
            if scenario == "oversized-read" { return Data(repeating: 0, count: count + 1) }
            if offset == 0 || scenario == "growth" { return Data([120]) }
            return Data()
        }
        func closeDescriptor(_ descriptor: Int32) { closed.append(descriptor) }
    }

    private struct TokenBackend: Phase2QualificationGateAuditTokenBackend {
        let alias: Bool
        let changed: Bool
        func acquireTaskName(processID: Int32) throws -> mach_port_t { 42 }
        func readToken(port: mach_port_t) throws -> Data { Data(repeating: changed ? 2 : 1, count: MemoryLayout<audit_token_t>.size) }
        func processID(token: Data) throws -> Int32 { 123 }
        func executablePath(token: Data) throws -> String {
            "/Users/test-authority/" + (alias ? "node-alias" : Phase2QualificationProviderRuntimeExpectation.candidate.executable(for: .node).homeRelativePath)
        }
        func validateDynamicCode(token: Data, requirement: SecRequirement) -> Bool { false }
        func releaseTaskName(port: mach_port_t) -> Bool { true }
    }
}
