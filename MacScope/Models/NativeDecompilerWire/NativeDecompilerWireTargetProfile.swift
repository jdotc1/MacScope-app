import Foundation

enum NativeDecompilerWireTargetProfileError: Error, Equatable, Sendable {
    case unsupportedArchitecture(rawCPUType: UInt32, rawCPUSubtype: UInt32)
    case invalidSelectedSliceSHA256
    case invalidSelectedSliceByteCount
}

enum NativeDecompilerWireArchitectureVariant: String, Sendable, Equatable, Codable {
    case arm64
    case arm64e
    case x86_64
}

struct NativeDecompilerWireTargetContextValue: Sendable, Equatable, Codable {
    let name: String
    let value: UInt32
}

struct NativeDecompilerWireTarget: Sendable, Equatable, Codable {
    let rawCPUType: String
    let rawCPUSubtype: String
    let normalizedVariant: NativeDecompilerWireArchitectureVariant
    let recognizedCapabilityBits: String
    let pointerAuthABIVersion: UInt32?
    let selectedSliceSHA256: String
    let selectedSliceByteCount: NativeDecompilerWireUInt64
    let profileID: String
    let languageID: String
    let compilerSpecID: String
    let contextProfileSHA256: String
    let context: [NativeDecompilerWireTargetContextValue]
}

enum NativeDecompilerSealedTargetProfile {
    private static let arm64CPUType: UInt32 = 0x0100_000c

    static func normalizedTarget(
        rawCPUType: UInt32,
        rawCPUSubtype: UInt32,
        selectedSliceSHA256: String,
        selectedSliceByteCount: UInt64,
        // Wire validation may recognize this contract before runtime admission.
        // App request construction keeps disabled targets unavailable by default.
        allowDisabledProfiles: Bool = false
    ) throws -> NativeDecompilerWireTarget {
        if allowDisabledProfiles, rawCPUType == 0x0100_0007, rawCPUSubtype == 3 {
            guard Self.isCanonicalSHA256(selectedSliceSHA256) else {
                throw NativeDecompilerWireTargetProfileError.invalidSelectedSliceSHA256
            }
            guard selectedSliceByteCount > 0 else {
                throw NativeDecompilerWireTargetProfileError.invalidSelectedSliceByteCount
            }
            return NativeDecompilerWireTarget(
                rawCPUType: Self.canonicalHex(rawCPUType),
                rawCPUSubtype: Self.canonicalHex(rawCPUSubtype),
                normalizedVariant: .x86_64,
                recognizedCapabilityBits: "00000000",
                pointerAuthABIVersion: nil,
                selectedSliceSHA256: selectedSliceSHA256,
                selectedSliceByteCount: .init(selectedSliceByteCount),
                profileID: "apple-x86_64-sysv-v1",
                languageID: "x86:LE:64:default",
                compilerSpecID: "gcc",
                contextProfileSHA256: "5fd328d91f7f3a0f815136362f1fe60ba5749f1a72c2337b30c7b7765edf9deb",
                context: [
                    .init(name: "addrsize", value: 2),
                    .init(name: "opsize", value: 1),
                    .init(name: "rexprefix", value: 0),
                    .init(name: "longMode", value: 1),
                ]
            )
        }
        guard rawCPUType == arm64CPUType else {
            throw NativeDecompilerWireTargetProfileError.unsupportedArchitecture(
                rawCPUType: rawCPUType,
                rawCPUSubtype: rawCPUSubtype
            )
        }

        let variant: NativeDecompilerWireArchitectureVariant
        let recognizedCapabilityBits: String
        let pointerAuthABIVersion: UInt32?
        switch rawCPUSubtype {
        case 0x0000_0000:
            variant = .arm64
            recognizedCapabilityBits = "00000000"
            pointerAuthABIVersion = nil
        case 0x8000_0000:
            variant = .arm64
            recognizedCapabilityBits = "80000000"
            pointerAuthABIVersion = nil
        case 0x0000_0002:
            variant = .arm64e
            recognizedCapabilityBits = "00000000"
            pointerAuthABIVersion = nil
        case 0x8000_0002:
            variant = .arm64e
            recognizedCapabilityBits = "80000000"
            pointerAuthABIVersion = 0
        default:
            throw NativeDecompilerWireTargetProfileError.unsupportedArchitecture(
                rawCPUType: rawCPUType,
                rawCPUSubtype: rawCPUSubtype
            )
        }

        guard Self.isCanonicalSHA256(selectedSliceSHA256) else {
            throw NativeDecompilerWireTargetProfileError.invalidSelectedSliceSHA256
        }
        guard selectedSliceByteCount > 0 else {
            throw NativeDecompilerWireTargetProfileError.invalidSelectedSliceByteCount
        }

        return NativeDecompilerWireTarget(
            rawCPUType: Self.canonicalHex(rawCPUType),
            rawCPUSubtype: Self.canonicalHex(rawCPUSubtype),
            normalizedVariant: variant,
            recognizedCapabilityBits: recognizedCapabilityBits,
            pointerAuthABIVersion: pointerAuthABIVersion,
            selectedSliceSHA256: selectedSliceSHA256,
            selectedSliceByteCount: NativeDecompilerWireUInt64(selectedSliceByteCount),
            profileID: "apple-aarch64-pac-visible-clobber-v1",
            languageID: "AARCH64:LE:64:AppleSilicon",
            compilerSpecID: "default",
            contextProfileSHA256:
                "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5",
            context: [
                NativeDecompilerWireTargetContextValue(name: "ShowPAC", value: 1),
                NativeDecompilerWireTargetContextValue(name: "PAC_clobber", value: 1),
                NativeDecompilerWireTargetContextValue(name: "ShowBTI", value: 0),
                NativeDecompilerWireTargetContextValue(name: "ShowMemTag", value: 0),
            ]
        )
    }

    private static func canonicalHex(_ value: UInt32) -> String {
        String(format: "%08x", value)
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

/// Strong value for the frozen production profile carried by schema v3.
struct NativeDecompilerProfiledAnalysisBudgets: Sendable, Equatable {
    let profileID: String
    let maxCodeBytes: UInt32
    let maxInstructions: UInt32
    let maxOperations: UInt32
    let maxOutputBytes: UInt32
    let maxWallTimeMilliseconds: NativeDecompilerWireUInt64

    var wireValue: NativeDecompilerWireAnalysisBudgets { .init(self) }
}

enum NativeDecompilerProductBudgetProfile {
    static let v1 = NativeDecompilerProfiledAnalysisBudgets(
        profileID: "native-product-budget-v1",
        maxCodeBytes: 1_048_576,
        maxInstructions: 65_536,
        maxOperations: 262_144,
        maxOutputBytes: 1_048_576,
        maxWallTimeMilliseconds: NativeDecompilerWireUInt64(5_000)
    )

    // DP03: v1's identity and limits stay frozen; v2 differs only in its 8 MiB
    // output ceiling.
    static let v2 = NativeDecompilerProfiledAnalysisBudgets(
        profileID: "native-product-budget-v2",
        maxCodeBytes: v1.maxCodeBytes,
        maxInstructions: v1.maxInstructions,
        maxOperations: v1.maxOperations,
        maxOutputBytes: 8_388_608,
        maxWallTimeMilliseconds: v1.maxWallTimeMilliseconds
    )

    // v3 differs from v2 only in its 32 MiB output ceiling (libjpeg
    // `_encode_one_block` needs more than 8 MiB at the varnode stage); it stays
    // under the 64 MiB transport ceiling and is the product default.
    static let v3 = NativeDecompilerProfiledAnalysisBudgets(
        profileID: "native-product-budget-v3",
        maxCodeBytes: v1.maxCodeBytes,
        maxInstructions: v1.maxInstructions,
        maxOperations: v1.maxOperations,
        maxOutputBytes: 33_554_432,
        maxWallTimeMilliseconds: v1.maxWallTimeMilliseconds
    )

    static let productDefault = v3

    /// How long the client waits for a reply beyond the provider's wall budget. The
    /// service enforces its own hard deadline at budget + 500 ms and replies `timedOut`;
    /// the remaining margin covers encoding and transferring an output of up to the
    /// 32 MiB v3 ceiling. A client watchdog at exactly the provider budget cancels and
    /// invalidates the connection instead, and every request queued behind it starves
    /// while the service relaunches (libjpeg batch on b2898c32e).
    static let clientReplyMargin: Duration = .milliseconds(2_500)

    /// The service's own hard deadline beyond the wall budget; past it the service process
    /// terminates itself (NativeDecompilerServiceComposition.nativeTerminationGraceMilliseconds).
    static let serviceTerminationGrace: Duration = .milliseconds(500)

    /// The service hard deadline implied by a client wait from `clientWaitBudget`: an
    /// interruption at or after it is the service's own deadline kill, not an epoch race.
    static func serviceHardDeadline(forClientWait wait: Duration) -> Duration? {
        let deadline = wait - clientReplyMargin + serviceTerminationGrace
        return deadline > .zero ? deadline : nil
    }

    static func clientWaitBudget(
        for profile: NativeDecompilerProfiledAnalysisBudgets = productDefault
    ) -> Duration {
        .milliseconds(Int64(clamping: profile.maxWallTimeMilliseconds.value)) + clientReplyMargin
    }

    /// The sealed profile whose identity and limits exactly match `budgets`.
    static func sealed(_ budgets: NativeDecompilerWireAnalysisBudgets) -> NativeDecompilerProfiledAnalysisBudgets? {
        [v1, v2, v3].first { $0.wireValue == budgets }
    }
}
