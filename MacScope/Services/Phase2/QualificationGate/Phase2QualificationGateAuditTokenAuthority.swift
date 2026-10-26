import Darwin
import Foundation
import Security

/// Ephemeral kernel evidence only; never a persisted profile or admission authority by itself.
struct Phase2QualificationGateAuditTokenCapture: Equatable {
    let processID: Int32
    let tokenBytes: Data
    let canonicalExecutablePath: String

    fileprivate init(processID: Int32, tokenBytes: Data, canonicalExecutablePath: String) {
        self.processID = processID
        self.tokenBytes = tokenBytes
        self.canonicalExecutablePath = canonicalExecutablePath
    }
}

enum Phase2QualificationGateAuditTokenFailure: Error, Equatable {
    case invalidProcessID
    case taskNameUnavailable
    case tokenUnavailable
    case tokenSizeInvalid
    case tokenProcessMismatch
    case pathUnavailable
    case identityChanged
    case signatureUnavailable
    case portReleaseFailed
}

/// Injectable mechanics only. No registry, provider configuration, process launch or fallback.
protocol Phase2QualificationGateAuditTokenBackend {
    func acquireTaskName(processID: Int32) throws -> mach_port_t
    func readToken(port: mach_port_t) throws -> Data
    func processID(token: Data) throws -> Int32
    func executablePath(token: Data) throws -> String
    func validateDynamicCode(token: Data, requirement: SecRequirement) -> Bool
    func releaseTaskName(port: mach_port_t) -> Bool
}

struct Phase2QualificationGateAuditTokenAuthority {
    private let backend: any Phase2QualificationGateAuditTokenBackend

    init() { backend = Phase2QualificationGateDarwinAuditTokenBackend() }

    init(backend: any Phase2QualificationGateAuditTokenBackend) { self.backend = backend }

    func capture(processID: Int32) -> Result<Phase2QualificationGateAuditTokenCapture,
        Phase2QualificationGateAuditTokenFailure> {
        guard processID > 1 else { return .failure(.invalidProcessID) }
        let port: mach_port_t
        do { port = try backend.acquireTaskName(processID: processID) }
        catch { return .failure(.taskNameUnavailable) }
        // mach/port.h defines the dead name as (mach_port_name_t) ~0.
        // Spell its unsigned bit pattern directly; the imported macro's -1 overflows in Swift 6.4.
        guard port != mach_port_t(MACH_PORT_NULL), port != mach_port_t.max else {
            return .failure(.taskNameUnavailable)
        }
        let result: Result<Phase2QualificationGateAuditTokenCapture,
            Phase2QualificationGateAuditTokenFailure>
        do {
            let first = try checkedToken(port: port, processID: processID)
            let firstPath = try checkedPath(token: first)
            let second = try checkedToken(port: port, processID: processID)
            guard first == second else { throw Phase2QualificationGateAuditTokenFailure.identityChanged }
            let secondPath = try checkedPath(token: second)
            let final = try checkedToken(port: port, processID: processID)
            guard second == final, firstPath == secondPath else {
                throw Phase2QualificationGateAuditTokenFailure.identityChanged
            }
            result = .success(.init(processID: processID, tokenBytes: final,
                                    canonicalExecutablePath: secondPath))
        } catch let failure as Phase2QualificationGateAuditTokenFailure {
            result = .failure(failure)
        } catch { result = .failure(.tokenUnavailable) }
        guard backend.releaseTaskName(port: port) else { return .failure(.portReleaseFailed) }
        return result
    }

    /// The requirement must come from the caller's compiled role registry. This validates
    /// dynamic code, not just its filesystem origin. No PID-only downgrade is permitted.
    func validate(_ expected: Phase2QualificationGateAuditTokenCapture,
                  requirement: SecRequirement) -> Result<Phase2QualificationGateAuditTokenCapture,
        Phase2QualificationGateAuditTokenFailure> {
        do {
            let before = try capture(processID: expected.processID).get()
            guard before == expected else { return .failure(.identityChanged) }
            guard backend.validateDynamicCode(token: before.tokenBytes, requirement: requirement) else {
                return .failure(.signatureUnavailable)
            }
            let after = try capture(processID: expected.processID).get()
            guard before == after else { return .failure(.identityChanged) }
            return .success(after)
        } catch let failure as Phase2QualificationGateAuditTokenFailure {
            return .failure(failure)
        } catch { return .failure(.tokenUnavailable) }
    }

    private func checkedToken(port: mach_port_t, processID: Int32) throws -> Data {
        let bytes = try backend.readToken(port: port)
        guard bytes.count == MemoryLayout<audit_token_t>.size else {
            throw Phase2QualificationGateAuditTokenFailure.tokenSizeInvalid
        }
        guard try backend.processID(token: bytes) == processID else {
            throw Phase2QualificationGateAuditTokenFailure.tokenProcessMismatch
        }
        return bytes
    }

    private func checkedPath(token: Data) throws -> String {
        let path = try backend.executablePath(token: token)
        guard path.hasPrefix("/"), !path.contains("\0"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else {
            throw Phase2QualificationGateAuditTokenFailure.pathUnavailable
        }
        // This is not an ancestor ownership/mode/ACL check; the role admission layer owns it.
        return path
    }
}

private struct Phase2QualificationGateDarwinAuditTokenBackend: Phase2QualificationGateAuditTokenBackend {
    func acquireTaskName(processID: Int32) throws -> mach_port_t {
        var port = mach_port_t(MACH_PORT_NULL)
        guard task_name_for_pid(mach_task_self_, processID, &port) == KERN_SUCCESS else {
            // No right is returned on failure; never request a task-control right as fallback.
            throw Phase2QualificationGateAuditTokenFailure.taskNameUnavailable
        }
        return port
    }

    func readToken(port: mach_port_t) throws -> Data {
        var token = audit_token_t()
        // SDK TASK_AUDIT_TOKEN_COUNT is sizeof(audit_token_t) / sizeof(natural_t).
        let expected = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        var count = expected
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expected)) {
                task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw Phase2QualificationGateAuditTokenFailure.tokenUnavailable }
        guard count == expected else { throw Phase2QualificationGateAuditTokenFailure.tokenSizeInvalid }
        return withUnsafeBytes(of: token) { Data($0) }
    }

    func processID(token: Data) throws -> Int32 {
        audit_token_to_pid(try decodedToken(token))
    }

    func executablePath(token: Data) throws -> String {
        var audit = try decodedToken(token)
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = bytes.withUnsafeMutableBytes {
            proc_pidpath_audittoken(&audit, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0, Int(count) < bytes.count,
              let path = String(bytes: bytes.prefix(Int(count)), encoding: .utf8) else {
            throw Phase2QualificationGateAuditTokenFailure.pathUnavailable
        }
        return path
    }

    func validateDynamicCode(token: Data, requirement: SecRequirement) -> Bool {
        guard token.count == MemoryLayout<audit_token_t>.size else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: token as CFData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes,
                Phase2QualificationGateSecurityValidationFlags.guestLookup, &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidityWithErrors(code,
            Phase2QualificationGateSecurityValidationFlags.dynamicValidity,
            requirement, nil) == errSecSuccess
    }

    func releaseTaskName(port: mach_port_t) -> Bool {
        mach_port_deallocate(mach_task_self_, port) == KERN_SUCCESS
    }

    private func decodedToken(_ bytes: Data) throws -> audit_token_t {
        guard bytes.count == MemoryLayout<audit_token_t>.size else {
            throw Phase2QualificationGateAuditTokenFailure.tokenSizeInvalid
        }
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { bytes.copyBytes(to: $0) }
        return token
    }
}
