import CryptoKit
import Foundation

struct DebuggerRuntimeModuleInventoryRevision: Hashable, Sendable, Comparable {
    let rawValue: UInt64

    static let initial = DebuggerRuntimeModuleInventoryRevision(rawValue: 0)

    func incremented() -> DebuggerRuntimeModuleInventoryRevision? {
        let (next, overflowed) = rawValue.addingReportingOverflow(1)
        return overflowed ? nil : DebuggerRuntimeModuleInventoryRevision(rawValue: next)
    }

    static func < (
        lhs: DebuggerRuntimeModuleInventoryRevision,
        rhs: DebuggerRuntimeModuleInventoryRevision
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DebuggerRuntimeModuleAuthorityRevision: Hashable, Sendable, Comparable {
    let rawValue: UInt64

    static let initial = DebuggerRuntimeModuleAuthorityRevision(rawValue: 0)

    func incremented() -> DebuggerRuntimeModuleAuthorityRevision? {
        let (next, overflowed) = rawValue.addingReportingOverflow(1)
        return overflowed ? nil : DebuggerRuntimeModuleAuthorityRevision(rawValue: next)
    }

    static func < (
        lhs: DebuggerRuntimeModuleAuthorityRevision,
        rhs: DebuggerRuntimeModuleAuthorityRevision
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One decoder-observed top-level section with paired static and runtime addresses.
/// It is deliberately not inventory-qualified; translation creates a separate mapped-range value.
struct DebuggerRuntimeModuleMappedRangeObservation: Hashable, Sendable {
    let sectionOrdinal: UInt32
    let sectionName: String
    let staticStart: UInt64
    let runtimeStart: UInt64
    let byteCount: UInt64
    let permissions: UInt8

    init?(
        sectionOrdinal: UInt32,
        sectionName: String,
        staticStart: UInt64,
        runtimeStart: UInt64,
        byteCount: UInt64,
        permissions: UInt8
    ) {
        guard Self.isValidBoundedText(sectionName, maximumUTF8Bytes: 256),
              staticStart != .max,
              runtimeStart != .max,
              byteCount > 0,
              permissions <= 7,
              Self.hasNonoverflowingLastByte(start: staticStart, byteCount: byteCount),
              Self.hasNonoverflowingLastByte(start: runtimeStart, byteCount: byteCount) else {
            return nil
        }
        self.sectionOrdinal = sectionOrdinal
        self.sectionName = sectionName
        self.staticStart = staticStart
        self.runtimeStart = runtimeStart
        self.byteCount = byteCount
        self.permissions = permissions
    }

    private static func hasNonoverflowingLastByte(start: UInt64, byteCount: UInt64) -> Bool {
        let (lastByteDisplacement, underflowed) = byteCount.subtractingReportingOverflow(1)
        guard !underflowed else { return false }
        return !start.addingReportingOverflow(lastByteDisplacement).overflow
    }

    private static func isValidBoundedText(_ text: String, maximumUTF8Bytes: Int) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maximumUTF8Bytes else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.properties.generalCategory != .control
        }
    }
}

struct DebuggerRuntimeModuleObservationFingerprint: Hashable, Sendable, Comparable {
    let sha256: Data

    init?(sha256: Data) {
        guard sha256.count == 32 else { return nil }
        self.sha256 = sha256
    }

    static func < (
        lhs: DebuggerRuntimeModuleObservationFingerprint,
        rhs: DebuggerRuntimeModuleObservationFingerprint
    ) -> Bool {
        lhs.sha256.lexicographicallyPrecedes(rhs.sha256)
    }
}

/// Immutable evidence decoded from one complete LLDB module record.
struct DebuggerRuntimeModuleObservation: Hashable, Sendable {
    let uuid: UUID?
    let processID: Int32
    let observedStopID: UInt32
    let mappedRanges: [DebuggerRuntimeModuleMappedRangeObservation]
    let fullPath: String
    let normalizedArchitectureTriple: String
    let displayIndex: UInt32?
    let fingerprint: DebuggerRuntimeModuleObservationFingerprint

    init?(
        uuid: UUID?,
        processID: Int32,
        observedStopID: UInt32,
        mappedRanges: [DebuggerRuntimeModuleMappedRangeObservation],
        fullPath: String,
        normalizedArchitectureTriple: String,
        displayIndex: UInt32?,
        fingerprintSHA256: Data
    ) {
        guard processID > 0,
              mappedRanges.count <= 128,
              Set(mappedRanges).count == mappedRanges.count,
              Self.isValidPath(fullPath),
              Self.isValidArchitectureToken(normalizedArchitectureTriple),
              let fingerprint = DebuggerRuntimeModuleObservationFingerprint(
                  sha256: fingerprintSHA256
              ) else {
            return nil
        }
        self.uuid = uuid
        self.processID = processID
        self.observedStopID = observedStopID
        self.mappedRanges = mappedRanges.sorted(by: Self.rangePrecedes)
        self.fullPath = fullPath
        self.normalizedArchitectureTriple = normalizedArchitectureTriple
        self.displayIndex = displayIndex
        self.fingerprint = fingerprint
    }

    private static func isValidPath(_ path: String) -> Bool {
        guard path.utf8.count <= 4_096 else { return false }
        return path.unicodeScalars.allSatisfy { scalar in
            scalar.properties.generalCategory != .control
        }
    }

    private static func isValidArchitectureToken(_ token: String) -> Bool {
        guard !token.isEmpty,
              token.utf8.count <= 256,
              token == token.lowercased() else {
            return false
        }
        return token.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x2B, 0x2D, 0x2E, 0x30...0x39, 0x41...0x5A, 0x5F, 0x61...0x7A:
                true
            default:
                false
            }
        }
    }

    private static func rangePrecedes(
        _ lhs: DebuggerRuntimeModuleMappedRangeObservation,
        _ rhs: DebuggerRuntimeModuleMappedRangeObservation
    ) -> Bool {
        if lhs.sectionOrdinal != rhs.sectionOrdinal {
            return lhs.sectionOrdinal < rhs.sectionOrdinal
        }
        if lhs.sectionName != rhs.sectionName { return lhs.sectionName < rhs.sectionName }
        if lhs.staticStart != rhs.staticStart { return lhs.staticStart < rhs.staticStart }
        if lhs.runtimeStart != rhs.runtimeStart { return lhs.runtimeStart < rhs.runtimeStart }
        if lhs.byteCount != rhs.byteCount { return lhs.byteCount < rhs.byteCount }
        return lhs.permissions < rhs.permissions
    }
}

struct DebuggerRuntimeModuleInstanceID: Hashable, Sendable {
    let processID: Int32
    let stop: DebuggerStopCoordinate
    let inventoryRevision: DebuggerRuntimeModuleInventoryRevision
    let ordinal: UInt32
}

struct DebuggerRuntimeModuleInstance: Hashable, Sendable {
    let id: DebuggerRuntimeModuleInstanceID
    let observation: DebuggerRuntimeModuleObservation
}

struct DebuggerRuntimeModuleInventory: Hashable, Sendable {
    let revision: DebuggerRuntimeModuleInventoryRevision
    let stop: DebuggerStopCoordinate
    let processID: Int32
    let observedStopID: UInt32
    let modules: [DebuggerRuntimeModuleInstance]
}

enum DebuggerRuntimeModuleUnavailableReason: Hashable, Sendable {
    case noStoppedProcess
    case newStop
    case refreshInProgress
    case refreshFailed(DebuggerRuntimeModuleFailureEvidence)
    case expressionEvaluationAdmitted
    case resumeCapableOperationAdmitted
    case running
    case terminal
    case sessionInvalidated
}

enum DebuggerRuntimeModuleFailureCode: String, Hashable, Sendable {
    case collectionFailed
}

/// Fixed-size safe evidence for a runtime-module failure. Raw debugger text is consumed only while
/// hashing and is never retained as a preview, path, environment value, expression, or transcript.
struct DebuggerRuntimeModuleFailureEvidence: Hashable, Sendable {
    let code: DebuggerRuntimeModuleFailureCode
    let evidenceByteCount: Int
    let evidenceSHA256: Data

    init(
        code: DebuggerRuntimeModuleFailureCode = .collectionFailed,
        redacting rawText: String
    ) {
        let bytes = Data(rawText.utf8)
        self.code = code
        self.evidenceByteCount = bytes.count
        self.evidenceSHA256 = Data(SHA256.hash(data: bytes))
    }
}

enum DebuggerRuntimeModuleAuthority: Hashable, Sendable {
    case available(DebuggerRuntimeModuleInventory)
    case unavailable(DebuggerRuntimeModuleUnavailableReason)
}

struct DebuggerRuntimeModuleRemap: Hashable, Sendable {
    let previous: DebuggerRuntimeModuleObservationFingerprint
    let current: DebuggerRuntimeModuleObservationFingerprint
}

struct DebuggerRuntimeModuleInventoryChanges: Hashable, Sendable {
    let appeared: [DebuggerRuntimeModuleObservationFingerprint]
    let disappeared: [DebuggerRuntimeModuleObservationFingerprint]
    let remapped: [DebuggerRuntimeModuleRemap]

    static let empty = DebuggerRuntimeModuleInventoryChanges(
        appeared: [],
        disappeared: [],
        remapped: []
    )
}
