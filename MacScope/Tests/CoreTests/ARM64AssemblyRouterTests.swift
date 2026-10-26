import Foundation
import XCTest
@testable import MacScope

final class ARM64AssemblyRouterTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _assembleInputs: [(String, ARM64AssemblyArchitecture)] = []
        private var _disassembleCount = 0

        var assembleInputs: [(String, ARM64AssemblyArchitecture)] {
            lock.withLock { _assembleInputs }
        }

        var disassembleCount: Int {
            lock.withLock { _disassembleCount }
        }

        func recordAssemble(_ text: String, architecture: ARM64AssemblyArchitecture) {
            lock.withLock { _assembleInputs.append((text, architecture)) }
        }

        func recordDisassemble() {
            lock.withLock { _disassembleCount += 1 }
        }
    }

    private struct FakePrimary: ARM64AssemblyPrimaryBackend {
        let outcome: ARM64PrimaryAssemblyOutcome

        func assemble(
            _ text: String,
            at address: UInt64
        ) -> ARM64PrimaryAssemblyOutcome {
            _ = (text, address)
            return outcome
        }
    }

    private enum FixtureError: Error {
        case rejected(String)
    }

    private struct FakeFallback: ARM64AssemblyFallbackBackend {
        let probe: Probe
        let bytesByText: [String: [UInt8]]
        let canonicalByBytes: [String: String]
        let failingInputs: Set<String>

        init(
            probe: Probe = Probe(),
            bytesByText: [String: [UInt8]],
            canonicalByBytes: [String: String],
            failingInputs: Set<String> = []
        ) {
            self.probe = probe
            self.bytesByText = bytesByText
            self.canonicalByBytes = canonicalByBytes
            self.failingInputs = failingInputs
        }

        func assemble(
            _ text: String,
            architecture: ARM64AssemblyArchitecture
        ) throws -> [UInt8] {
            probe.recordAssemble(text, architecture: architecture)
            if failingInputs.contains(text) {
                throw FixtureError.rejected("SENTINEL-UPSTREAM-DETAIL\n/private/source.swift")
            }
            guard let bytes = bytesByText[text] else {
                throw FixtureError.rejected("missing fixture input")
            }
            return bytes
        }

        func disassemble(
            _ bytes: [UInt8],
            architecture: ARM64AssemblyArchitecture
        ) throws -> String {
            _ = architecture
            probe.recordDisassemble()
            guard let canonical = canonicalByBytes[Self.key(bytes)] else {
                throw FixtureError.rejected("missing fixture word")
            }
            return canonical
        }

        private static func key(_ bytes: [UInt8]) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    private let gmiBytes: [UInt8] = [0x20, 0x14, 0xc2, 0x9a]
    private let otherGMIOperandsBytes: [UInt8] = [0x49, 0x15, 0xcb, 0x9a]
    private let nopBytes: [UInt8] = [0x1f, 0x20, 0x03, 0xd5]

    private func unsupportedPrimary(_ mnemonic: String = "gmi") -> FakePrimary {
        FakePrimary(outcome: .unsupportedInstructionFamily(mnemonic))
    }

    private func gmiFallback(
        probe: Probe = Probe(),
        requested: String = "gmi x0, x1, x2",
        canonical: String = "gmi x0, x1, x2",
        bytes: [UInt8]? = nil,
        canonicalReassemblyBytes: [UInt8]? = nil
    ) -> FakeFallback {
        let selectedBytes = bytes ?? gmiBytes
        var bytesByText = [requested: selectedBytes]
        bytesByText[canonical] = canonicalReassemblyBytes ?? selectedBytes
        return FakeFallback(
            probe: probe,
            bytesByText: bytesByText,
            canonicalByBytes: [
                selectedBytes.map { String(format: "%02x", $0) }.joined(): canonical,
            ]
        )
    }

    func testPrimarySuccessDoesNotInvokeFallback() {
        let probe = Probe()
        let fallback = gmiFallback(probe: probe)
        let primaryProduct = ARM64AssemblyProduct(
            bytes: nopBytes,
            canonicalText: "nop",
            backend: .macScopePrimary
        )

        let result = ARM64AssemblyRouter(
            primary: FakePrimary(outcome: .success(primaryProduct)),
            fallback: fallback
        ).assemble("nop", at: 0x1000, architecture: .arm64)

        XCTAssertEqual(result, .success(primaryProduct))
        XCTAssertTrue(probe.assembleInputs.isEmpty)
        XCTAssertEqual(probe.disassembleCount, 0)
    }

    func testOnlyTypedUnsupportedFamilyInvokesFallback() {
        let probe = Probe()
        let result = ARM64AssemblyRouter(
            primary: unsupportedPrimary(),
            fallback: gmiFallback(probe: probe)
        ).assemble("gmi x0, x1, x2", at: 0x1000, architecture: .arm64)

        guard case .success(let product) = result else {
            return XCTFail("expected admitted fallback, got \(result)")
        }
        XCTAssertEqual(product.bytes, gmiBytes)
        XCTAssertEqual(product.backend, .swiftAssemblySourceFallback)
        XCTAssertEqual(probe.assembleInputs.count, 2, "requested and canonical text must both assemble")
        XCTAssertEqual(probe.disassembleCount, 1)
    }

    func testEverySubstantivePrimaryRejectionRemainsAuthoritative() {
        let reasons = [
            "empty instruction",
            "'gmi' expects 3 operands",
            "bad operand 'fixture'",
            "bad register 'x99'",
            "register width mismatch: fixture",
            "immediate out of range: fixture",
            "branch/offset out of range: fixture",
            "not encodable: fixture",
            "internal error",
        ]

        for reason in reasons {
            let probe = Probe()
            let result = ARM64AssemblyRouter(
                primary: FakePrimary(outcome: .rejected(reason)),
                fallback: gmiFallback(probe: probe)
            ).assemble("gmi x0, x1, x2", at: 0x1000, architecture: .arm64)

            XCTAssertEqual(result, .failure(.primaryRejected(reason)), reason)
            XCTAssertTrue(probe.assembleInputs.isEmpty, reason)
        }
    }

    func testMacScopeNotEncodableIsClassifiedAsAuthoritativeRejection() {
        let outcome = MacScopeARM64AssemblyBackend.classify(
            .failure(.notEncodable("fixture substantive rejection")),
            requestedText: "fixture",
            address: 0x1000
        )
        XCTAssertEqual(outcome, .rejected("not encodable: fixture substantive rejection"))
    }

    func testTopLevelUnsupportedFamilyIsTypedButKnownFamilyInvalidFormIsNot() {
        let backend = MacScopeARM64AssemblyBackend()

        XCTAssertEqual(
            backend.assemble("gmi x0, x1, x2", at: 0x1000),
            .unsupportedInstructionFamily("gmi")
        )
        guard case .rejected = backend.assemble("fmla x0, x1, x2", at: 0x1000) else {
            return XCTFail("a malformed form of a known family must remain authoritative")
        }
    }

    func testAbsoluteOrAmbiguousPCRelativeTargetsNeverInvokeZeroPCFallback() {
        let cases = [
            "b 0x2000", "b 8192", "b destination",
            "bl 0x2000", "b.eq 8192",
            "cbz x0, 8192", "cbnz x0, destination",
            "tbz x0, #1, 8192", "tbnz x0, #1, destination",
            "adr x0, 8192", "adrp x0, destination",
            "ldr x0, 8192", "ldrsw x0, 0x2000", "prfm pldl1keep, destination",
        ]

        for text in cases {
            let probe = Probe()
            let result = ARM64AssemblyRouter(
                primary: unsupportedPrimary(text.split(separator: " ").first.map(String.init) ?? ""),
                fallback: gmiFallback(probe: probe)
            ).assemble(text, at: 0x1000, architecture: .arm64)

            XCTAssertEqual(result, .failure(.addressSensitiveFallbackUnsupported), text)
            XCTAssertTrue(probe.assembleInputs.isEmpty, text)
        }
    }

    func testExplicitNumericRelativeOffsetMayReachFallback() {
        let relativeForms = [
            "b #4", "bl #-4", "b.eq #0x10",
            "cbz x0, #8", "tbz x0, #1, #-8",
            "adr x0, #16", "adrp x0, #-0x1000",
            "ldr x0, #4", "ldrsw x0, #-4", "prfm pldl1keep, #8",
        ]

        for text in relativeForms {
            let probe = Probe()
            let fallback = FakeFallback(
                probe: probe,
                bytesByText: [:],
                canonicalByBytes: [:],
                failingInputs: [text]
            )
            let result = ARM64AssemblyRouter(
                primary: unsupportedPrimary(),
                fallback: fallback
            ).assemble(text, at: 0x1000, architecture: .arm64)

            XCTAssertEqual(result, .failure(.fallbackFailed), text)
            XCTAssertEqual(probe.assembleInputs.count, 1, text)
        }
    }

    func testExplicitRelativeBranchIsCheckedAgainstMacScopeAtTheRealAddress() {
        let bytes: [UInt8] = [0x01, 0x00, 0x00, 0x14] // b #4
        let fallback = FakeFallback(
            bytesByText: ["b #0x4": bytes, "b #4": bytes],
            canonicalByBytes: ["01000014": "b #4"]
        )

        let result = ARM64AssemblyRouter(
            primary: unsupportedPrimary("b"),
            fallback: fallback
        ).assemble("b #0x4", at: 0x1000, architecture: .arm64)

        guard case .success(let product) = result else {
            return XCTFail("real-address independent decode should confirm target 0x1004, got \(result)")
        }
        XCTAssertEqual(product.bytes, bytes)
        XCTAssertEqual(product.backend, .swiftAssemblySourceFallback)
    }

    func testFallbackMustReturnExactlyOneFourByteWord() {
        let invalidWords: [[UInt8]] = [[], [0, 1, 2], [0, 1, 2, 3, 4]]
        for bytes in invalidWords {
            let fallback = gmiFallback(bytes: bytes)
            let result = ARM64AssemblyRouter(
                primary: unsupportedPrimary(),
                fallback: fallback
            ).assemble("gmi x0, x1, x2", at: 0x1000, architecture: .arm64)

            XCTAssertEqual(result, .failure(.fallbackReturnedWrongByteCount(bytes.count)))
        }
    }

    func testCanonicalReassemblyMustReturnTheSameWord() {
        let requested = "GMI X0, X1, X2"
        let canonical = "gmi x0, x1, x2"
        let fallback = gmiFallback(
            requested: requested,
            canonical: canonical,
            canonicalReassemblyBytes: nopBytes
        )

        let result = ARM64AssemblyRouter(
            primary: unsupportedPrimary(),
            fallback: fallback
        ).assemble(requested, at: 0x1000, architecture: .arm64)

        XCTAssertEqual(result, .failure(.fallbackRoundTripWordMismatch))
    }

    func testSameMnemonicWithDifferentOperandsIsRejected() {
        let requested = "gmi x0, x1, x2"
        let canonical = "gmi x9, x10, x11"
        let fallback = gmiFallback(
            requested: requested,
            canonical: canonical,
            bytes: otherGMIOperandsBytes
        )

        let result = ARM64AssemblyRouter(
            primary: unsupportedPrimary(),
            fallback: fallback
        ).assemble(requested, at: 0x1000, architecture: .arm64)

        XCTAssertEqual(
            result,
            .failure(.fallbackCanonicalTextMismatch)
        )
    }

    func testNOPMasqueradingAsGMIIsRejectedByIndependentMacScopeDecode() {
        let fallback = gmiFallback(bytes: nopBytes)

        let result = ARM64AssemblyRouter(
            primary: unsupportedPrimary(),
            fallback: fallback
        ).assemble("gmi x0, x1, x2", at: 0x1000, architecture: .arm64)

        XCTAssertEqual(result, .failure(.macScopeDecoderSemanticMismatch))
    }

    func testClosedOperandAwareAliasRuleAcceptsCMPAndSUBSOnlyWithZeroDestination() {
        let bytes: [UInt8] = [0x1f, 0x00, 0x01, 0xeb] // subs xzr, x0, x1; decoded as cmp x0, x1
        let valid = FakeFallback(
            bytesByText: ["subs xzr, x0, x1": bytes, "cmp x0, x1": bytes],
            canonicalByBytes: ["1f0001eb": "cmp x0, x1"]
        )
        let accepted = ARM64AssemblyRouter(
            primary: unsupportedPrimary("subs"),
            fallback: valid
        ).assemble("subs xzr, x0, x1", at: 0x1000, architecture: .arm64)
        guard case .success = accepted else {
            return XCTFail("closed CMP/SUBS alias should be admitted, got \(accepted)")
        }

        let invalid = FakeFallback(
            bytesByText: ["subs x0, x0, x1": bytes, "cmp x0, x1": bytes],
            canonicalByBytes: ["1f0001eb": "cmp x0, x1"]
        )
        let rejected = ARM64AssemblyRouter(
            primary: unsupportedPrimary("subs"),
            fallback: invalid
        ).assemble("subs x0, x0, x1", at: 0x1000, architecture: .arm64)
        XCTAssertEqual(
            rejected,
            .failure(.fallbackCanonicalTextMismatch)
        )
    }

    func testMissingExactArchitectureFailsClosedBeforeFallback() {
        let probe = Probe()
        let result = ARM64AssemblyRouter(
            primary: unsupportedPrimary(),
            fallback: gmiFallback(probe: probe)
        ).assemble("gmi x0, x1, x2", at: 0x1000, architecture: nil)

        XCTAssertEqual(result, .failure(.fallbackArchitectureUnavailable))
        XCTAssertTrue(probe.assembleInputs.isEmpty)
    }

    func testArm64AndArm64eIdentityAreForwardedWithoutCollapsing() {
        for architecture in [ARM64AssemblyArchitecture.arm64, .arm64e] {
            let probe = Probe()
            let result = ARM64AssemblyRouter(
                primary: unsupportedPrimary(),
                fallback: gmiFallback(probe: probe)
            ).assemble("gmi x0, x1, x2", at: 0x1000, architecture: architecture)

            guard case .success = result else {
                return XCTFail("expected \(architecture) success, got \(result)")
            }
            XCTAssertEqual(probe.assembleInputs.map { $0.1 }, [architecture, architecture])
        }
    }

    func testExactArchitectureResolutionPrefersArtifactEvidenceAndFailsClosed() {
        XCTAssertEqual(
            ARM64AssemblyArchitecture.resolve(
                architectureDisplayName: "arm64 (universal slice 1/2 @ 0x1000)",
                artifactVariant: .arm64e
            ),
            .arm64e
        )
        XCTAssertEqual(
            ARM64AssemblyArchitecture.resolve(
                architectureDisplayName: "arm64",
                artifactVariant: nil
            ),
            .arm64
        )
        XCTAssertEqual(
            ARM64AssemblyArchitecture.resolve(
                architectureDisplayName: "arm64e",
                artifactVariant: nil
            ),
            .arm64e
        )
        XCTAssertNil(
            ARM64AssemblyArchitecture.resolve(
                architectureDisplayName: "arm64 (universal slice 1/2 @ 0x1000)",
                artifactVariant: nil
            )
        )
        XCTAssertNil(
            ARM64AssemblyArchitecture.resolve(
                architectureDisplayName: "arm64",
                artifactVariant: .other
            )
        )
    }

    func testUpstreamErrorTextNeverEscapesStableAppOwnedFailure() {
        let fallback = FakeFallback(
            bytesByText: [:],
            canonicalByBytes: [:],
            failingInputs: ["gmi x0, x1, x2"]
        )
        let result = ARM64AssemblyRouter(
            primary: unsupportedPrimary(),
            fallback: fallback
        ).assemble("gmi x0, x1, x2", at: 0x1000, architecture: .arm64)

        XCTAssertEqual(result, .failure(.fallbackFailed))
        XCTAssertFalse(String(describing: result).contains("SENTINEL-UPSTREAM-DETAIL"))
        XCTAssertFalse(String(describing: result).contains("/private/source.swift"))
    }

    // MARK: - MS-22: FEAT_PAuth_LR label forms are PC-relative

    func testPointerAuthLRAbsoluteLabelsNeverInvokeZeroPCFallback() {
        for text in ["autiasppc 0xff8", "autibsppc 4088", "retaasppc destination", "retabsppc 0xff8"] {
            let probe = Probe()
            let result = ARM64AssemblyRouter(
                primary: unsupportedPrimary(text.split(separator: " ").first.map(String.init) ?? ""),
                fallback: gmiFallback(probe: probe)
            ).assemble(text, at: 0x1000, architecture: .arm64)

            XCTAssertEqual(result, .failure(.addressSensitiveFallbackUnsupported), text)
            XCTAssertTrue(probe.assembleInputs.isEmpty, text)
        }
    }

    func testPointerAuthLRRelativeLabelIsCheckedAgainstMacScopeAtTheRealAddress() {
        // retaasppc with imm16 = 2: label = PC - 8. MacScope decodes 0x5500005f at 0x1000 as
        // `retaasppc 0xff8`; the addressless fallback renders `#-8`.
        let bytes: [UInt8] = [0x5f, 0x00, 0x00, 0x55]
        let fallback = FakeFallback(
            bytesByText: ["retaasppc #-8": bytes],
            canonicalByBytes: ["5f000055": "retaasppc #-8"]
        )

        let result = ARM64AssemblyRouter(
            primary: unsupportedPrimary("retaasppc"),
            fallback: fallback
        ).assemble("retaasppc #-8", at: 0x1000, architecture: .arm64)

        guard case .success(let product) = result else {
            return XCTFail("the real-address decode should confirm label 0xff8, got \(result)")
        }
        XCTAssertEqual(product.bytes, bytes)
    }
}
