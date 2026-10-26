#include "CP4DTOTestWriter.hpp"
#include "CanonicalRequest.hpp"
#include <fstream>
#include "MacScopeNativeDecompiler/Backend.hpp"
#include "MacScopeNativeDecompiler/GhidraProvider.hpp"

#include "BoundedUTF8StreamBuffer.hpp"
#include "DefinitionIdentity.hpp"
#include "GhidraPacQualificationSupport.hpp"
#include "GhidraRuntimeInternal.hpp"
#include "GhidraVariableIdentity.hpp"

#include <ghidra/context.hh>
#include <ghidra/database.hh>
#include <ghidra/fspec.hh>
#include <ghidra/jumptable.hh>
#include <ghidra/loadimage.hh>
#include <ghidra/opbehavior.hh>
#include <ghidra/translate.hh>
#include <ghidra/xml.hh>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <functional>
#include <iostream>
#include <limits>
#include <map>
#include <new>
#include <optional>
#include <ostream>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <tuple>
#include <unordered_map>
#include <utility>

#if !defined(MACSCOPE_TEST_SLEIGH_TREE_SHA256)
#error "provider tests require MACSCOPE_TEST_SLEIGH_TREE_SHA256"
#endif
#include <vector>

#if !defined(MACSCOPE_TEST_SLEIGH_PACKAGE_ROOT)
#error "provider tests require MACSCOPE_TEST_SLEIGH_PACKAGE_ROOT"
#endif
#if !defined(MACSCOPE_TEST_SLEIGH_MANIFEST_SHA256)
#error "provider tests require MACSCOPE_TEST_SLEIGH_MANIFEST_SHA256"
#endif
#if !defined(MACSCOPE_TEST_SLEIGH_PROCESSOR_SPEC_ROOT)
#error "provider tests require MACSCOPE_TEST_SLEIGH_PROCESSOR_SPEC_ROOT"
#endif

using namespace macscope::native_decompiler;

namespace macscope::native_decompiler::detail {

enum class PacCompanionOpcode : std::uint8_t {
    other,
    copy,
    load,
    branchIndirect,
    callIndirect,
    return_,
};

struct PacCompanionOperation final {
    PacCompanionOpcode opcode = PacCompanionOpcode::other;
    std::optional<std::uintptr_t> output;
    std::vector<std::optional<std::uintptr_t>> inputs;
    bool exceptionReturn = false;
};

struct PacCompanionDescriptor final {
    std::string userOperationName;
    std::string mnemonic;
    std::size_t authenticationIndex = 0;
    std::vector<PacCompanionOperation> operations;
};

enum class PacCompanionKind : std::uint8_t {
    authenticatedMemoryAccess,
    authenticatedControlTransfer,
};

[[nodiscard]] PacCompanionKind classifyPacCompanionShape(
    const PacCompanionDescriptor& descriptor
);

} // namespace macscope::native_decompiler::detail

namespace {

constexpr Address kEntryAddress = 0x1000;
constexpr Address kEndAddressExclusive = 0x1008;
constexpr std::string_view kLanguageId = "AARCH64:LE:64:AppleSilicon";
constexpr std::string_view kCompilerSpecId = "default";
constexpr std::string_view kTargetProfileId = "apple-aarch64-pac-visible-clobber-v1";
constexpr std::string_view kContextProfileSha256 =
    "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5";
constexpr std::string_view kPackageTreeSha256 =
    MACSCOPE_TEST_SLEIGH_TREE_SHA256;

int failures = 0;

void check(bool condition, std::string_view message) {
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

// Token metadata is budgeted before the document. Compare the complete semantic
// graph separately, removing only the two presentation layers and their one
// dedicated truncation warning; all other diagnostics remain authoritative.
[[nodiscard]] StructuredResult withoutNativePresentation(StructuredResult result) {
    result.tokens.clear();
    result.pseudocodeDocument.reset();
    std::erase_if(result.warnings, [](const auto& warning) {
        return warning.code == "native-pseudocode-token-metadata-truncated";
    });
    return result;
}

void checkBoundedNativePresentation(
    const AnalysisRequestView& request,
    const StructuredResult& result,
    const StructuredResult& baseline,
    bool requirePresentationLoss
) {
    validateStructuredResult(request, result);
    check(structuredResultEncodedSizeUpperBound(result) <= request.budgets.maxOutputBytes,
          "complete native publication stays inside the requested byte budget");
    check(withoutNativePresentation(result) == withoutNativePresentation(baseline),
          "budgeted presentation preserves the complete semantic DTO graph and other diagnostics");
    const bool tokenMetadataChanged = result.tokens != baseline.tokens;
    const bool tokenWarning = std::any_of(result.warnings.begin(), result.warnings.end(),
        [](const auto& warning) {
            return warning.code == "native-pseudocode-token-metadata-truncated";
        });
    check(tokenWarning == tokenMetadataChanged,
          "changed token metadata is explicitly marked with its dedicated warning");
    for (const auto& token : result.tokens) {
        check(std::find(baseline.tokens.begin(), baseline.tokens.end(), token) != baseline.tokens.end(),
              "every retained presentation token preserves its complete baseline record");
    }
    check(result.pseudocodeDocument.has_value() && baseline.pseudocodeDocument.has_value(),
          "successful native publication retains a document");
    if (!result.pseudocodeDocument || !baseline.pseudocodeDocument) return;
    const auto& document = *result.pseudocodeDocument;
    const auto& original = *baseline.pseudocodeDocument;
    check(original.isComplete && !original.isTruncated,
          "unbounded presentation baseline is complete");
    check(!document.text.empty() && document.language == original.language &&
              original.text.starts_with(document.text),
          "budgeted native document is a nonempty exact prefix with unchanged language");
    const bool documentShortened = document.text != original.text;
    check(document.isTruncated == documentShortened && document.isComplete == !documentShortened,
          "native document completeness flags describe its actual retained prefix");
    if (requirePresentationLoss) {
        check(tokenMetadataChanged || documentShortened,
              "a budget below the full presentation bounds at least one presentation layer");
    }
    // Derive capacity from THIS result's token metadata, not a different budget's
    // token set. The one-byte probe uses the same semantic and warning records.
    auto documentless = result;
    documentless.pseudocodeDocument.reset();
    const auto baseBytes = structuredResultEncodedSizeUpperBound(documentless);
    documentless.pseudocodeDocument = PseudocodeDocumentRecord{
        .text = "x", .language = document.language, .isComplete = true, .isTruncated = false,
    };
    const auto oneByteBytes = structuredResultEncodedSizeUpperBound(documentless);
    check(oneByteBytes > baseBytes, "document accounting includes one text byte");
    if (oneByteBytes <= baseBytes) return;
    const auto overhead = oneByteBytes - baseBytes - 1U;
    check(baseBytes <= request.budgets.maxOutputBytes &&
              overhead < request.budgets.maxOutputBytes - baseBytes,
          "successful document has positive retained-text capacity");
    if (baseBytes > request.budgets.maxOutputBytes ||
        overhead >= request.budgets.maxOutputBytes - baseBytes) return;
    check(document.text.size() <= request.budgets.maxOutputBytes - baseBytes - overhead,
          "native document never exceeds its per-result calculated byte capacity");
}

void checkRuntimeSnapshotUnchanged(
    const detail::GhidraRuntimeSnapshot& before,
    const detail::GhidraRuntimeSnapshot& after,
    std::string_view scenario
) {
    check(after.started == before.started,
          std::string(scenario) + " does not change runtime started state");
    check(after.initializationFailed == before.initializationFailed,
          std::string(scenario) + " does not latch runtime initialization failure");
    check(after.liveLeaseCount == before.liveLeaseCount,
          std::string(scenario) + " does not leak or consume a runtime lease");
    check(after.startupCallCount == before.startupCallCount,
          std::string(scenario) + " does not repeat native startup");
    check(after.identityFrozen == before.identityFrozen,
          std::string(scenario) + " does not change frozen runtime identity");
}

template <typename Function>
std::string expectContractError(Function function, std::string_view message) {
    try {
        function();
        ++failures;
        std::cerr << "FAIL: expected ContractError: " << message << '\n';
    } catch (const ContractError& error) {
        return error.what();
    } catch (const std::exception& error) {
        ++failures;
        std::cerr << "FAIL: expected ContractError for " << message
                  << ", received std::exception: " << error.what() << '\n';
    } catch (...) {
        ++failures;
        std::cerr << "FAIL: expected ContractError for " << message
                  << ", received an unknown exception\n";
    }
    return {};
}

template <typename Function>
std::optional<StructuredResult> produceOrFail(Function function, std::string_view scenario) {
    try {
        return function();
    } catch (const ContractError& error) {
        ++failures;
        std::cerr << "FAIL: " << scenario << " remains unsupported: " << error.what() << '\n';
    } catch (const std::exception& error) {
        ++failures;
        std::cerr << "FAIL: " << scenario << " raised std::exception: " << error.what() << '\n';
    } catch (...) {
        ++failures;
        std::cerr << "FAIL: " << scenario << " raised an unknown exception\n";
    }
    return std::nullopt;
}

[[nodiscard]] bool isLowerHexRevision(std::string_view value) {
    return (value.size() == 40U || value.size() == 64U) &&
        std::all_of(value.begin(), value.end(), [](unsigned char character) {
            return (character >= '0' && character <= '9') ||
                (character >= 'a' && character <= 'f');
        });
}

[[nodiscard]] GhidraBackendConfiguration makeConfiguration(
    std::string languageId = std::string(kLanguageId),
    std::string compilerSpecId = std::string(kCompilerSpecId)
) {
    return {
        MACSCOPE_TEST_SLEIGH_PACKAGE_ROOT,
        MACSCOPE_TEST_SLEIGH_MANIFEST_SHA256,
        MACSCOPE_TEST_SLEIGH_PROCESSOR_SPEC_ROOT,
        std::move(languageId),
        std::move(compilerSpecId),
    };
}

[[nodiscard]] std::vector<std::uint8_t> effectiveRegionBytes() {
    // mov w0, #42; ret. Native AArch64 decode may read a fixed-size lookahead
    // beyond the function extent, so the caller maps additional NOP bytes.
    std::vector<std::uint8_t> bytes = {
        0x40, 0x05, 0x80, 0x52,
        0xc0, 0x03, 0x5f, 0xd6,
    };
    constexpr std::array<std::uint8_t, 4> nop = {0x1f, 0x20, 0x03, 0xd5};
    while (bytes.size() < 64U) {
        bytes.insert(bytes.end(), nop.begin(), nop.end());
    }
    return bytes;
}

[[nodiscard]] AnalysisRequestView makeRequestForFunction(
    std::string requestSuffix,
    std::string functionName,
    std::vector<std::uint8_t> functionBytes,
    std::vector<SymbolRecord> additionalSymbols = {},
    std::string languageId = std::string(kLanguageId),
    std::string compilerSpecId = std::string(kCompilerSpecId)
) {
    const auto endAddressExclusive =
        kEntryAddress + static_cast<Address>(functionBytes.size());
    auto effectiveBytes = functionBytes;
    constexpr std::array<std::uint8_t, 4> nop = {0x1f, 0x20, 0x03, 0xd5};
    const auto mappedByteCount = functionBytes.size() + 64U;
    while (effectiveBytes.size() < mappedByteCount) {
        effectiveBytes.insert(effectiveBytes.end(), nop.begin(), nop.end());
    }
    auto rawBytes = std::vector<std::uint8_t>(effectiveBytes.size(), 0U);
    std::vector<SymbolRecord> symbols = {
        SymbolRecord{
            "image.ghidra-provider",
            kEntryAddress,
            functionName,
            "function",
        },
    };
    symbols.insert(
        symbols.end(),
        std::make_move_iterator(additionalSymbols.begin()),
        std::make_move_iterator(additionalSymbols.end())
    );
    const auto requestId = "request.ghidra-provider." + requestSuffix;
    const auto functionId = "function.ghidra-provider." + requestSuffix;
    return AnalysisRequestView(
        requestId,
        std::string(64U, 'a'),
        std::move(languageId),
        std::move(compilerSpecId),
        ImageIdentity{
            "image.ghidra-provider",
            "00000000-0000-0000-0000-000000000042",
            kEntryAddress,
        },
        FunctionIdentity{
            functionId,
            std::move(functionName),
            kEntryAddress,
            endAddressExclusive,
            {},
        },
        ByteProvider({
            MemoryRegion{
                "__text",
                kEntryAddress,
                "r-x",
                std::move(rawBytes),
                std::move(effectiveBytes),
                {"patch000000"},
            },
        }),
        SymbolProvider(std::move(symbols)),
        TypeHintProvider({}),
        AnalysisBudgets{
            .maxCodeBytes = 4096,
            .maxInstructions = 256,
            .maxOperations = 4096,
            .maxOutputBytes = 4U * 1024U * 1024U,
            .maxWallTimeMilliseconds = 10'000,
        }
    );
}

[[nodiscard]] AnalysisRequestView makeRequest(
    std::string languageId = std::string(kLanguageId),
    std::string compilerSpecId = std::string(kCompilerSpecId)
) {
    auto bytes = effectiveRegionBytes();
    bytes.resize(static_cast<std::size_t>(kEndAddressExclusive - kEntryAddress));
    return makeRequestForFunction(
        "mov42",
        "_returnFortyTwo",
        std::move(bytes),
        {},
        std::move(languageId),
        std::move(compilerSpecId)
    );
}

[[nodiscard]] AnalysisRequestView makeConditionalRequest() {
    // cmp w0, #0; b.eq 0x1010; mov w0, #1; ret; mov w0, #2; ret
    return makeRequestForFunction(
        "conditional",
        "_selectOneOrTwo",
        {
            0x1f, 0x00, 0x00, 0x71,
            0x60, 0x00, 0x00, 0x54,
            0x20, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6,
            0x40, 0x00, 0x80, 0x52,
            0xc0, 0x03, 0x5f, 0xd6,
        }
    );
}

[[nodiscard]] AnalysisRequestView makeDirectCallRequest() {
    // bl 0x1020; ret. The callee is deliberately outside the function range
    // and is known only through the caller-owned symbol provider.
    return makeRequestForFunction(
        "direct-call",
        "_callKnownCallee",
        {
            0x08, 0x00, 0x00, 0x94,
            0xc0, 0x03, 0x5f, 0xd6,
        },
        {
            SymbolRecord{
                "image.ghidra-provider",
                0x1020,
                "_dataAtCalleeAddress",
                "data",
            },
            SymbolRecord{
                "image.ghidra-provider",
                0x1020,
                "_knownCallee",
                "function",
            },
        }
    );
}

[[nodiscard]] AnalysisRequestView makeIndirectCallRequest() {
    // blr x0; ret
    return makeRequestForFunction(
        "indirect-call",
        "_callRegister",
        {
            0x00, 0x00, 0x3f, 0xd6,
            0xc0, 0x03, 0x5f, 0xd6,
        }
    );
}

[[nodiscard]] AnalysisRequestView makeLoopRequest() {
    // cbz w0, 0x100c; sub w0, w0, #1; b 0x1000; ret
    return makeRequestForFunction(
        "loop",
        "_countDown",
        {
            0x60, 0x00, 0x00, 0x34,
            0x00, 0x04, 0x00, 0x51,
            0xfe, 0xff, 0xff, 0x17,
            0xc0, 0x03, 0x5f, 0xd6,
        }
    );
}

[[nodiscard]] AnalysisRequestView makeLoadStoreRequest() {
    // ldr w1, [x0]; add w1, w1, #1; str w1, [x0]; mov w0, w1; ret
    return makeRequestForFunction(
        "load-store",
        "_incrementPointee",
        {
            0x01, 0x00, 0x40, 0xb9,
            0x21, 0x04, 0x00, 0x11,
            0x01, 0x00, 0x00, 0xb9,
            0xe0, 0x03, 0x01, 0x2a,
            0xc0, 0x03, 0x5f, 0xd6,
        }
    );
}

[[nodiscard]] std::vector<std::uint8_t> littleEndianWords(
    const std::vector<std::uint32_t>& words
) {
    std::vector<std::uint8_t> bytes;
    bytes.reserve(words.size() * sizeof(std::uint32_t));
    for (const auto word : words) {
        bytes.push_back(static_cast<std::uint8_t>(word));
        bytes.push_back(static_cast<std::uint8_t>(word >> 8U));
        bytes.push_back(static_cast<std::uint8_t>(word >> 16U));
        bytes.push_back(static_cast<std::uint8_t>(word >> 24U));
    }
    return bytes;
}

[[nodiscard]] AnalysisRequestView makePacRequest(
    std::string suffix,
    std::vector<std::uint32_t> words
) {
    return makeRequestForFunction(
        "pac-" + suffix,
        "_pac_" + suffix,
        littleEndianWords(words)
    );
}

[[nodiscard]] AnalysisRequestView makePacOutputRequest() {
    // Keep every transformed result live by chaining x0 through exact A/B
    // sign, authenticate, zero-modifier, strip, and generic-auth forms. The
    // x30 stack forms feed the terminal authenticated return.
    return makePacRequest(
        "output",
        {
            0xd280'0020U, // mov x0, #1
            0x9100'03e1U, // mov x1, sp
            0xd280'0006U, // mov x6, #0
            0xdac1'0020U, // pacia x0, x1
            0xca00'00c6U, // eor x6, x6, x0
            0xdac1'0440U, // pacib x0, x2
            0xca00'00c6U, // eor x6, x6, x0
            0xdac1'1060U, // autia x0, x3
            0xca00'00c6U, // eor x6, x6, x0
            0xdac1'1c80U, // autdb x0, x4
            0xca00'00c6U, // eor x6, x6, x0
            0xdac1'23e0U, // paciza x0
            0xca00'00c6U, // eor x6, x6, x0
            0xdac1'27e0U, // pacizb x0
            0xca00'00c6U, // eor x6, x6, x0
            0xdac1'3fe0U, // autdzb x0
            0xca00'00c6U, // eor x6, x6, x0
            0xdac1'43e0U, // xpaci x0
            0xca00'00c6U, // eor x6, x6, x0
            0xdac1'47e0U, // xpacd x0
            0xca00'00c6U, // eor x6, x6, x0
            0x9ac1'3000U, // pacga x0, x0, x1
            0xca00'00c6U, // eor x6, x6, x0
            0xd503'233fU, // paciasp
            0xca1e'00c6U, // eor x6, x6, x30
            0xd503'237fU, // pacibsp
            0xca1e'00c6U, // eor x6, x6, x30
            0xaa06'03e0U, // mov x0, x6
            0xd65f'0bffU, // retaa
        }
    );
}

[[nodiscard]] AnalysisRequestView makePacMemoryRequest() {
    return makePacRequest(
        "memory",
        {
            0xf820'0420U, // ldraa x0, [x1]
            0xf8a0'0462U, // ldrab x2, [x3]
            0x8b02'0000U, // add x0, x0, x2
            0xd65f'03c0U, // ret
        }
    );
}

constexpr Address kSwitchEntryAddress = 0x1000003f0;
constexpr Address kSwitchEndAddressExclusive = 0x100000494;
constexpr Address kSwitchMappedEndAddressExclusive = 0x100000500;

[[nodiscard]] std::vector<std::uint8_t> switchMappedEffectiveBytes() {
    // Exact caller-owned effective slice from the deterministic Xcode 27 -Oz
    // fixture. The requested function ends at 0x100000494; the remainder
    // contains its local callees and the native jump table at
    // [0x1000004e0, 0x1000004e8). The final 24 bytes are the actual
    // caller-owned bytes through the end of the native table-emulation read;
    // omitting them must fail closed rather than allowing upstream zero-fill.
    return {
        0xfd, 0x7b, 0xbf, 0xa9, 0xfd, 0x03, 0x00, 0x91, 0x1f, 0x1c, 0x00, 0x71,
        0x08, 0x04, 0x00, 0x54, 0xe8, 0x03, 0x00, 0x2a, 0x09, 0x00, 0x00, 0x90,
        0x29, 0x81, 0x13, 0x91, 0x8a, 0x00, 0x00, 0x10, 0x2b, 0x69, 0x68, 0x38,
        0x4a, 0x09, 0x0b, 0x8b, 0x40, 0x01, 0x1f, 0xd6, 0xe0, 0x03, 0x01, 0xaa,
        0x1d, 0x00, 0x00, 0x94, 0x19, 0x00, 0x00, 0x14, 0xe0, 0x03, 0x01, 0xaa,
        0x23, 0x00, 0x00, 0x94, 0x16, 0x00, 0x00, 0x14, 0xe0, 0x03, 0x01, 0xaa,
        0x1c, 0x00, 0x00, 0x94, 0x13, 0x00, 0x00, 0x14, 0xe0, 0x03, 0x01, 0xaa,
        0x1b, 0x00, 0x00, 0x94, 0x10, 0x00, 0x00, 0x14, 0xe0, 0x03, 0x01, 0xaa,
        0x21, 0x00, 0x00, 0x94, 0x0d, 0x00, 0x00, 0x14, 0xe0, 0x03, 0x01, 0xaa,
        0x10, 0x00, 0x00, 0x94, 0x0a, 0x00, 0x00, 0x14, 0xe0, 0x03, 0x01, 0xaa,
        0x16, 0x00, 0x00, 0x94, 0x07, 0x00, 0x00, 0x14, 0xe0, 0x03, 0x01, 0xaa,
        0x16, 0x00, 0x00, 0x94, 0x04, 0x00, 0x00, 0x14, 0xe0, 0x03, 0x01, 0xaa,
        0xe1, 0x0f, 0x80, 0x52, 0xce, 0xff, 0xff, 0x97, 0x00, 0x04, 0x00, 0x91,
        0xfd, 0x7b, 0xc1, 0xa8, 0xc0, 0x03, 0x5f, 0xd6, 0x00, 0x40, 0x00, 0x91,
        0xc0, 0x03, 0x5f, 0xd6, 0x28, 0x04, 0x80, 0x52, 0x00, 0x00, 0x08, 0xca,
        0xc0, 0x03, 0x5f, 0xd6, 0x00, 0xc8, 0x00, 0xd1, 0xc0, 0x03, 0x5f, 0xd6,
        0x00, 0x04, 0x00, 0x8b, 0xc0, 0x03, 0x5f, 0xd6, 0x00, 0x50, 0x01, 0x91,
        0xc0, 0x03, 0x5f, 0xd6, 0xa8, 0x0c, 0x80, 0x52, 0x00, 0x00, 0x08, 0xca,
        0xc0, 0x03, 0x5f, 0xd6, 0x00, 0xd8, 0x01, 0xd1, 0xc0, 0x03, 0x5f, 0xd6,
        0x08, 0xf0, 0x7d, 0xd3, 0x00, 0x01, 0x00, 0xcb, 0xc0, 0x03, 0x5f, 0xd6,
        0x00, 0x0f, 0x06, 0x09, 0x03, 0x12, 0x15, 0x0c,
        0x01, 0x00, 0x00, 0x00, 0x1c, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
        0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00,
    };
}

[[nodiscard]] AnalysisRequestView makeSwitchRequest(bool omitAuxiliaryBytes = false) {
    auto effective = switchMappedEffectiveBytes();
    if (effective.size() != static_cast<std::size_t>(
            kSwitchMappedEndAddressExclusive - kSwitchEntryAddress
        )) {
        throw ContractError("test-switch-effective-slice-size-mismatch");
    }
    const auto functionByteCount = static_cast<std::size_t>(
        kSwitchEndAddressExclusive - kSwitchEntryAddress
    );
    std::vector<MemoryRegion> regions;
    if (omitAuxiliaryBytes) {
        std::vector<std::uint8_t> functionBytes(
            effective.begin(), effective.begin() + static_cast<std::ptrdiff_t>(functionByteCount)
        );
        regions.push_back(MemoryRegion{
            "__text-function",
            kSwitchEntryAddress,
            "r-x",
            std::vector<std::uint8_t>(functionBytes.size(), 0U),
            std::move(functionBytes),
            {"patch000043"},
        });
    } else {
        regions.push_back(MemoryRegion{
            "__text-mapped",
            kSwitchEntryAddress,
            "r-x",
            std::vector<std::uint8_t>(effective.size(), 0U),
            std::move(effective),
            {"patch000043"},
        });
    }
    return AnalysisRequestView(
        omitAuxiliaryBytes ? "request.ghidra-provider.switch-unmapped" :
            "request.ghidra-provider.switch",
        std::string(64U, 'b'),
        std::string(kLanguageId),
        std::string(kCompilerSpecId),
        ImageIdentity{
            "image.ghidra-provider.switch",
            "00000000-0000-0000-0000-000000000043",
            0x100000000,
        },
        FunctionIdentity{
            omitAuxiliaryBytes ? "function.ghidra-provider.switch-unmapped" :
                "function.ghidra-provider.switch",
            "_macscope_fixture_switch",
            kSwitchEntryAddress,
            kSwitchEndAddressExclusive,
            {},
        },
        ByteProvider(std::move(regions)),
        SymbolProvider({
            SymbolRecord{
                "image.ghidra-provider.switch",
                kSwitchEntryAddress,
                "_macscope_fixture_switch",
                "function",
            },
        }),
        TypeHintProvider({}),
        AnalysisBudgets{
            .maxCodeBytes = 4096,
            .maxInstructions = 256,
            .maxOperations = 4096,
            .maxOutputBytes = 4U * 1024U * 1024U,
            .maxWallTimeMilliseconds = 10'000,
        }
    );
}

[[nodiscard]] std::vector<std::uint8_t> joinedInstructionBytes(
    const StructuredResult& result
) {
    std::vector<std::uint8_t> bytes;
    for (const auto& instruction : result.instructions) {
        bytes.insert(bytes.end(), instruction.bytes.begin(), instruction.bytes.end());
    }
    return bytes;
}

[[nodiscard]] const VarnodeRecord* findVarnode(
    const StructuredResult& result,
    std::string_view id
) {
    const auto iterator = std::find_if(
        result.varnodes.begin(),
        result.varnodes.end(),
        [id](const VarnodeRecord& varnode) { return varnode.id == id; }
    );
    return iterator == result.varnodes.end() ? nullptr : &*iterator;
}

[[nodiscard]] bool containsMovFortyTwo(const StructuredResult& result) {
    for (const auto& operation : result.operations) {
        if (operation.opcode != "COPY" || operation.inputVarnodeIds.size() != 1U) {
            continue;
        }
        const auto* input = findVarnode(result, operation.inputVarnodeIds.front());
        if (input != nullptr && input->role == "constant" && input->offset == 42U) {
            return true;
        }
    }
    return false;
}

[[nodiscard]] const BlockRecord* findBlock(
    const StructuredResult& result,
    std::string_view id
) {
    const auto iterator = std::find_if(
        result.blocks.begin(),
        result.blocks.end(),
        [id](const BlockRecord& block) { return block.id == id; }
    );
    return iterator == result.blocks.end() ? nullptr : &*iterator;
}

[[nodiscard]] const OperationRecord* findOperation(
    const StructuredResult& result,
    std::string_view opcode
) {
    const auto iterator = std::find_if(
        result.operations.begin(),
        result.operations.end(),
        [opcode](const OperationRecord& operation) { return operation.opcode == opcode; }
    );
    return iterator == result.operations.end() ? nullptr : &*iterator;
}

[[nodiscard]] std::vector<const OperationRecord*> findUserOperations(
    const StructuredResult& result,
    std::string_view name
) {
    std::vector<const OperationRecord*> matches;
    for (const auto& operation : result.operations) {
        if (operation.userOperationName == name) matches.push_back(&operation);
    }
    return matches;
}

[[nodiscard]] const SsaBindingRecord* findSsaBinding(
    const StructuredResult& result,
    std::string_view operationId
) {
    const auto iterator = std::find_if(
        result.ssaBindings.begin(), result.ssaBindings.end(),
        [operationId](const SsaBindingRecord& binding) {
            return binding.operationId == operationId;
        }
    );
    return iterator == result.ssaBindings.end() ? nullptr : &*iterator;
}

void checkTransformedUserOperation(
    const StructuredResult& result,
    const OperationRecord& operation,
    std::string_view expectedName
) {
    check(operation.opcode == "CALLOTHER", "PAC intrinsic remains an exact CALLOTHER");
    check(operation.userOperationName == expectedName,
          "PAC intrinsic exports the exact attested user-operation name");
    check(operation.authenticationEffect.kind == AuthenticationEffectKind::transformedOutput,
          "output-bearing PAC intrinsic exports transformed-output");
    check(operation.outputVarnodeId.has_value(),
          "transformed PAC operation retains its governed output varnode");
    const auto* binding = findSsaBinding(result, operation.id);
    check(binding != nullptr && binding->outputSsaValueId.has_value(),
          "transformed PAC operation retains its exact output SSA binding");
    if (binding != nullptr) {
        check(operation.authenticationEffect.outputSsaValueId == binding->outputSsaValueId,
              "transformed PAC effect binds to the same operation output SSA value");
    }
}

void checkOutputlessAuthenticationEffect(
    const StructuredResult& result,
    const OperationRecord& operation,
    AuthenticationEffectKind expectedKind
) {
    check(operation.opcode == "CALLOTHER", "outputless PAC fact remains a CALLOTHER");
    check(operation.authenticationEffect.kind == expectedKind,
          "outputless PAC fact exports the exact closed authentication effect");
    check(!operation.authenticationEffect.outputSsaValueId.has_value(),
          "outputless PAC effect does not fabricate an output SSA value");
    check(!operation.outputVarnodeId.has_value(),
          "outputless PAC operation does not fabricate an output varnode");
    const auto* binding = findSsaBinding(result, operation.id);
    check(binding != nullptr && !binding->outputSsaValueId.has_value(),
          "outputless PAC operation has no output SSA binding");
}

[[nodiscard]] const EdgeRecord* findEdge(
    const StructuredResult& result,
    std::string_view sourceBlockId,
    std::string_view kind
) {
    const auto iterator = std::find_if(
        result.edges.begin(),
        result.edges.end(),
        [sourceBlockId, kind](const EdgeRecord& edge) {
            return edge.sourceBlockId == sourceBlockId && edge.kind == kind;
        }
    );
    return iterator == result.edges.end() ? nullptr : &*iterator;
}

[[nodiscard]] const RegionRecord* findRegion(
    const StructuredResult& result,
    std::string_view kind
) {
    const auto iterator = std::find_if(
        result.regions.begin(),
        result.regions.end(),
        [kind](const RegionRecord& region) { return region.kind == kind; }
    );
    return iterator == result.regions.end() ? nullptr : &*iterator;
}

[[nodiscard]] bool isStableProviderReason(std::string_view value) {
    return !value.empty() && value.size() <= 128U && value.starts_with("native-provider-") &&
        value.find('/') == std::string_view::npos &&
        value.find('\\') == std::string_view::npos &&
        value.find("0x") == std::string_view::npos &&
        std::all_of(value.begin(), value.end(), [](unsigned char character) {
            return (character >= 'a' && character <= 'z') ||
                (character >= '0' && character <= '9') || character == '-';
        });
}

void checkCapabilityTruth(const StructuredResult& result) {
    check(result.memoryVersions.empty(), "false MemorySSA capability publishes no versions");
    check(result.memoryPhis.empty(), "false MemorySSA capability publishes no memory phis");
    check(result.memoryEffects.empty(), "false MemorySSA capability publishes no memory effects");
    for (const auto& variable : result.variables) {
        check(variable.typeId && !variable.storageVarnodeIds.empty() &&
                  !variable.liveRanges.empty(),
              "qualified variable capability publishes only fully bound native variables");
    }
    check(!result.types.empty(), "qualified recovered-types capability publishes native types");
    check(!result.tokens.empty(), "qualified token capability publishes native tokens");
    for (const auto& token : result.tokens) {
        check(!token.sourceRanges.empty(),
              "qualified native token carries image-qualified operation evidence");
    }
}

void checkNativeTypeGraph(const StructuredResult& result) {
    std::set<std::string> typeIds;
    bool hasFunctionType = false;
    for (const auto& type : result.types) {
        check(typeIds.insert(type.id).second, "native type graph has unique deterministic IDs");
        check(type.id != "type:0000000000000000" &&
                  type.id != "type:native:0000000000000000",
              "anonymous native types never publish the colliding zero ID");
        hasFunctionType = hasFunctionType || type.kind == "function";
    }
    for (const auto& type : result.types) {
        if (type.pointeeTypeId) {
            check(typeIds.contains(*type.pointeeTypeId),
                  "native pointer/array type resolves its dependency");
        }
        if (type.returnTypeId) {
            check(typeIds.contains(*type.returnTypeId),
                  "native function type resolves its return type");
        }
        for (const auto& parameter : type.parameterTypeIds) {
            check(typeIds.contains(parameter),
                  "native function type resolves every ordered parameter type");
        }
        for (const auto& field : type.fields) {
            check(typeIds.contains(field.typeId),
                  "native aggregate type resolves every ordered field type");
        }
    }
    for (const auto& varnode : result.varnodes) {
        check(varnode.typeId && typeIds.contains(*varnode.typeId),
              "every exported native varnode resolves its recovered type");
    }
    for (const auto& call : result.calls) {
        check(call.prototypeTypeId && typeIds.contains(*call.prototypeTypeId),
              "every native call resolves its recovered function prototype");
    }
    check(hasFunctionType, "native type graph includes the analyzed function prototype");
}

void checkNativeVariableGraph(
    const AnalysisRequestView& request,
    const StructuredResult& result
) {
    std::set<std::string> typeIds;
    std::set<std::string> varnodeIds;
    std::set<std::string> variableIds;
    for (const auto& type : result.types) typeIds.insert(type.id);
    for (const auto& varnode : result.varnodes) varnodeIds.insert(varnode.id);
    check(!result.variables.empty(), "native high-variable graph publishes recovered variables");
    for (const auto& variable : result.variables) {
        check(variableIds.insert(variable.id).second,
              "native recovered variables have unique deterministic IDs");
        check(!variable.name.empty(), "native recovered variables have a bounded native name");
        check(variable.name != "unnamed-storage",
              "native recovered variables never publish a fabricated placeholder name");
        check(variable.id.starts_with("variable:symbol:"),
              "native recovered variable identity is anchored to a native symbol");
        check(variable.role == "parameter" || variable.role == "local" || variable.role == "global",
              "native recovered variables publish only qualified roles");
        check(variable.typeId && typeIds.contains(*variable.typeId),
              "native recovered variables resolve an accepted native type");
        check(!variable.storageVarnodeIds.empty(),
              "native recovered variables bind exported storage varnodes");
        for (const auto& storage : variable.storageVarnodeIds) {
            check(varnodeIds.contains(storage),
                  "native recovered variable storage resolves to an exported varnode");
        }
        check(!variable.liveRanges.empty(),
              "native recovered variables retain image-qualified native cover ranges");
        for (const auto& range : variable.liveRanges) {
            check(range.imageId == request.image.imageId &&
                      range.startAddress >= request.function.entryAddress &&
                      range.startAddress < range.endAddressExclusive &&
                      range.endAddressExclusive <= request.function.endAddressExclusive,
                  "native recovered variable range stays inside the requested image function");
        }
    }
}

void checkNativeSsaHeritageRelationships(const StructuredResult& result) {
    std::unordered_map<std::string, const SsaValueRecord*> valuesById;
    for (const auto& value : result.ssaValues) {
        const auto [_, inserted] = valuesById.emplace(value.id, &value);
        check(inserted, "native heritage publishes unique SSA value IDs");
    }

    std::unordered_map<std::string, const SsaBindingRecord*> bindingsByOperation;
    std::set<std::string> bindingOutputValueIds;
    for (const auto& binding : result.ssaBindings) {
        const auto [_, inserted] = bindingsByOperation.emplace(binding.operationId, &binding);
        check(inserted, "native heritage publishes exactly one binding per operation");
        if (binding.outputSsaValueId) {
            check(bindingOutputValueIds.insert(*binding.outputSsaValueId).second,
                  "native heritage publishes each operation definition once");
        }
    }

    std::unordered_map<std::string, const PhiRecord*> phisById;
    for (const auto& phi : result.phis) {
        const auto [_, inserted] = phisById.emplace(phi.id, &phi);
        check(inserted, "complete register SSA publishes unique phi IDs");
    }

    for (const auto& operation : result.operations) {
        const auto binding = bindingsByOperation.find(operation.id);
        check(binding != bindingsByOperation.end(),
              "every native operation has its required heritage binding");
        if (binding == bindingsByOperation.end()) continue;

        check(binding->second->inputSsaValueIds.size() == operation.inputVarnodeIds.size(),
              "native binding preserves every operation input in order");
        const auto inputCount = std::min(
            binding->second->inputSsaValueIds.size(), operation.inputVarnodeIds.size()
        );
        for (std::size_t index = 0; index < inputCount; ++index) {
            const auto value = valuesById.find(binding->second->inputSsaValueIds[index]);
            check(value != valuesById.end(),
                  "native operation input resolves to a published SSA value");
            if (value != valuesById.end()) {
                check(value->second->varnodeId == operation.inputVarnodeIds[index],
                      "native operation input SSA value retains its exact varnode relationship");
            }
        }

        if (operation.outputVarnodeId) {
            check(binding->second->outputSsaValueId.has_value(),
                  "native operation definition has an output SSA value");
            if (binding->second->outputSsaValueId) {
                const auto value = valuesById.find(*binding->second->outputSsaValueId);
                check(value != valuesById.end(),
                      "native operation definition resolves to a published SSA value");
                if (value != valuesById.end()) {
                    check(value->second->varnodeId == *operation.outputVarnodeId,
                          "native operation definition retains its exact output varnode");
                    if (operation.opcode == "MULTIEQUAL") {
                        check(!value->second->definingOperationId &&
                                  value->second->definingPhiId.has_value(),
                              "native MULTIEQUAL output is defined only by its phi");
                        if (value->second->definingPhiId) {
                            const auto phi = phisById.find(*value->second->definingPhiId);
                            check(phi != phisById.end() &&
                                      phi->second->outputSsaValueId == value->second->id &&
                                      phi->second->blockId == operation.blockId,
                                  "native MULTIEQUAL binding resolves to its block-owned phi");
                        }
                    } else {
                        check(value->second->definingOperationId == operation.id &&
                                  !value->second->definingPhiId,
                              "native operation definition is represented only by its defining operation");
                    }
                }
            }
        } else {
            check(!binding->second->outputSsaValueId,
                  "native operation without output has no fabricated SSA definition");
        }
    }

    for (const auto& value : result.ssaValues) {
        if (value.kind == "operationResult") {
            check(value.definingOperationId.has_value() && !value.definingPhiId,
                  "native operation-result SSA value has only an operation definition");
            if (value.definingOperationId) {
                check(bindingsByOperation.contains(*value.definingOperationId) &&
                          bindingOutputValueIds.contains(value.id),
                      "native operation-result SSA value is published by its defining binding");
            }
        } else if (value.kind == "phiResult") {
            check(!value.definingOperationId && value.definingPhiId.has_value() &&
                      phisById.contains(value.definingPhiId.value_or("")),
                  "native phi-result SSA value has only a resolved phi definition");
        } else {
            check(!value.definingOperationId && !value.definingPhiId,
                  "native entry-like SSA value has no fabricated definition");
        }
    }
}

void checkExactInstructionEvidence(
    const AnalysisRequestView& request,
    const StructuredResult& result
) {
    check(joinedInstructionBytes(result) == request.effectiveFunctionBytes(),
          "instruction bytes exactly equal caller-owned effective function bytes");
    check(result.ssaBindings.size() == result.operations.size(),
          "every operation has exactly one mandatory SSA binding");

    std::set<std::string> boundOperationIds;
    for (const auto& binding : result.ssaBindings) {
        check(boundOperationIds.insert(binding.operationId).second,
              "SSA bindings contain each operation exactly once");
    }
    for (const auto& operation : result.operations) {
        check(boundOperationIds.contains(operation.id),
              "each operation resolves to its mandatory SSA binding");
    }

    Address expectedAddress = request.function.entryAddress;
    for (const auto& instruction : result.instructions) {
        check(instruction.id == "insn:" + [&] {
            constexpr char digits[] = "0123456789abcdef";
            std::string value(16U, '0');
            auto address = instruction.address;
            for (std::size_t index = 0; index < value.size(); ++index) {
                value[value.size() - 1U - index] = digits[address & 0xfU];
                address >>= 4U;
            }
            return value;
        }(), "instruction ID is its canonical 16-digit address");
        check(instruction.address == expectedAddress,
              "instructions preserve contiguous address order");
        check(instruction.sourceRanges.size() == 1U,
              "each instruction has one exact source range");
        if (instruction.sourceRanges.size() == 1U) {
            const auto& range = instruction.sourceRanges.front();
            check(range.imageId == request.image.imageId,
                  "instruction source range preserves caller-owned image identity");
            check(range.startAddress == instruction.address,
                  "instruction source range starts at its address");
            check(range.endAddressExclusive == instruction.address + instruction.bytes.size(),
                  "instruction source range ends after its exact effective bytes");
        }
        expectedAddress += static_cast<Address>(instruction.bytes.size());
    }
    check(expectedAddress == request.function.endAddressExclusive,
          "instructions exactly cover the requested function range");
}

void checkBlockOperationOrdering(const StructuredResult& result) {
    if (result.blockPartition) {
        std::set<std::string> owned;
        for (const auto& block : result.blocks) {
            for (std::size_t sequence = 0; sequence < block.operationIds.size(); ++sequence) {
                const auto found = std::find_if(result.operations.begin(), result.operations.end(),
                    [&](const auto& op) { return op.id == block.operationIds[sequence]; });
                check(found != result.operations.end() && found->blockId == block.id &&
                    found->sequence == sequence && owned.insert(found->id).second,
                    "final CFG preserves exact block-local p-code order and exclusive operation ownership");
            }
        }
        check(owned.size() == result.operations.size(), "final CFG accounts for every live operation");
        return;
    }
    for (const auto& block : result.blocks) {
        std::vector<std::string> expected;
        for (const auto& instruction : result.instructions) {
            if (instruction.address >= block.startAddress &&
                instruction.address < block.endAddressExclusive) {
                expected.insert(
                    expected.end(),
                    instruction.operationIds.begin(),
                    instruction.operationIds.end()
                );
            }
        }
        check(block.operationIds == expected,
              "block operations are the instruction operations in semantic address order");
    }
}

void checkInitialAvailability(const BackendAvailability& availability) {
    check(availability.available, "verified native provider reports available");
    check(availability.reasonCode.empty(), "available provider has no failure reason");
    check(availability.identity.backendId == "ghidra-native-decompiler",
          "provider publishes the frozen backend ID");
    check(availability.identity.ghidraVersion == "12.1.2",
          "provider publishes the frozen Ghidra version");
    check(
        availability.identity.ghidraGitRevision ==
            "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
        "provider publishes the pinned native Ghidra revision"
    );
    check(availability.identity.wrapperVersion == "dcp05c-v1",
          "provider publishes the frozen wrapper version");
    check(isLowerHexRevision(availability.identity.wrapperGitRevision),
          "provider publishes an explicit canonical wrapper revision");
    check(availability.runtimeIdentity.has_value(),
          "available provider publishes a prepared runtime identity");
    if (availability.runtimeIdentity) {
        const auto& runtimeIdentity = *availability.runtimeIdentity;
        check(runtimeIdentity.backendId == availability.identity.backendId,
              "prepared and legacy identities agree on the backend ID");
        check(runtimeIdentity.engineVersion == availability.identity.ghidraVersion,
              "prepared identity derives its engine version from compiled identity");
        check(runtimeIdentity.engineRevision == availability.identity.ghidraGitRevision,
              "prepared identity derives its engine revision from compiled identity");
        check(runtimeIdentity.wrapperVersion == availability.identity.wrapperVersion,
              "prepared identity derives its wrapper version from compiled identity");
        check(runtimeIdentity.wrapperRevision == availability.identity.wrapperGitRevision,
              "prepared identity derives its wrapper revision from compiled identity");
        check(runtimeIdentity.packageManifestSha256 == MACSCOPE_TEST_SLEIGH_MANIFEST_SHA256,
              "prepared identity derives its manifest digest from package attestation");
        check(runtimeIdentity.packageTreeSha256.size() == 64U,
              "prepared identity includes the attested complete-tree digest");
        check(runtimeIdentity.languageId == kLanguageId &&
                  runtimeIdentity.compilerSpecId == kCompilerSpecId,
              "prepared identity contains only the ready language/compiler pair");
        check(runtimeIdentity.targetProfileId == kTargetProfileId,
              "prepared identity contains the successfully selected target profile");
        check(runtimeIdentity.contextProfileSha256 == kContextProfileSha256,
              "prepared identity contains the applied and read-back context profile");
    }

    check(availability.capabilities.nativeDecompilerHeritage,
          "initial provider claims native decompiler heritage");
    check(availability.capabilities.imageQualifiedSourceRanges,
          "initial provider claims image-qualified source ranges");
    check(availability.capabilities.completeRegisterSsa,
          "initial provider claims the qualified complete register SSA adapter");
    check(!availability.capabilities.memorySsa,
          "initial provider does not overclaim MemorySSA");
    check(availability.capabilities.recoveredVariables,
          "initial provider claims qualified native recovered variables");
    check(availability.capabilities.recoveredTypes,
          "initial provider claims the qualified recovered type graph");
    check(availability.capabilities.structuredControlFlow,
          "initial provider claims direct native structured control flow");
    check(availability.capabilities.tokenizedPseudocode,
          "initial provider claims qualified native pseudocode tokens");
}

void testProviderIdentityAndAvailability(
    NativeStructuredProvider& provider,
    StructuredDecompilerBackend& backend
) {
    const auto rawAvailability = provider.availability();
    validateBackendAvailability(rawAvailability);
    checkInitialAvailability(rawAvailability);

    const auto availability = backend.availability();
    validateBackendAvailability(availability);
    checkInitialAvailability(availability);
}

void testUnsupportedConfigurationFailsClosed() {
    expectContractError(
        [] { (void)makeGhidraProvider(makeConfiguration("x86:LE:64:default", "default")); },
        "raw provider rejects an unsupported language"
    );
    expectContractError(
        [] { (void)makeGhidraBackend(makeConfiguration("x86:LE:64:default", "default")); },
        "validated backend rejects an unsupported language"
    );
    expectContractError(
        [] { (void)makeGhidraProvider(makeConfiguration(std::string(kLanguageId), "unapproved")); },
        "raw provider rejects an unsupported compiler specification"
    );
    expectContractError(
        [] { (void)makeGhidraBackend(makeConfiguration(std::string(kLanguageId), "unapproved")); },
        "validated backend rejects an unsupported compiler specification"
    );
}

void testAppleProfileReadiness() {
    using detail::GhidraReadinessFault;

    const auto selectedProfile = normalizeAppleMachOTarget(
        0x0100'000cU,
        0x8000'0002U,
        std::string(64U, 'a'),
        4'096U
    );
    std::optional<PreparedGhidraRuntimeIdentity> publishedIdentity;

    const auto beforeGenericLanguage = detail::ghidraRuntimeSnapshot();
    const auto genericLanguage = expectContractError(
        [&] {
            publishedIdentity = detail::prepareGhidraRuntimeIdentityForTesting(
                makeConfiguration("AARCH64:LE:64:v8A", "default"),
                normalizeAppleMachOTarget(
                    0x0100'000cU, 0x8000'0002U, std::string(64U, 'a'), 4'096U
                ),
                GhidraReadinessFault::none
            );
        },
        "generic AArch64 language cannot satisfy Apple-profile readiness"
    );
    check(genericLanguage == "native-apple-profile-language-mismatch",
          "generic AArch64 fails with the stable language-mismatch reason");
    check(!publishedIdentity.has_value(),
          "generic AArch64 rejection publishes no runtime identity");
    checkRuntimeSnapshotUnchanged(
        beforeGenericLanguage,
        detail::ghidraRuntimeSnapshot(),
        "generic AArch64 readiness rejection"
    );

    const auto beforeSwiftCompiler = detail::ghidraRuntimeSnapshot();
    const auto swiftCompiler = expectContractError(
        [&] {
            publishedIdentity = detail::prepareGhidraRuntimeIdentityForTesting(
                makeConfiguration(std::string(kLanguageId), "swift"),
                selectedProfile,
                GhidraReadinessFault::none
            );
        },
        "Swift compiler specification cannot satisfy Apple-profile readiness"
    );
    check(swiftCompiler == "native-apple-profile-compiler-mismatch",
          "Swift compiler specification fails with the stable compiler-mismatch reason");
    check(!publishedIdentity.has_value(),
          "Swift compiler rejection publishes no runtime identity");
    checkRuntimeSnapshotUnchanged(
        beforeSwiftCompiler,
        detail::ghidraRuntimeSnapshot(),
        "Swift compiler readiness rejection"
    );

    const std::filesystem::path packageRoot(MACSCOPE_TEST_SLEIGH_PACKAGE_ROOT);
    detail::GhidraRuntimeLease stableRuntimeLease(detail::GhidraRuntimeIdentity{
        .materializationRoot = packageRoot.parent_path().string(),
        .manifestSha256 = MACSCOPE_TEST_SLEIGH_MANIFEST_SHA256,
        .closedTreeSha256 = std::string(kPackageTreeSha256),
        .packageRoot = packageRoot.string(),
        .globalSpecRoot = (packageRoot / "share/sleigh/specfiles").string(),
        .processorSpecRoot = MACSCOPE_TEST_SLEIGH_PROCESSOR_SPEC_ROOT,
        .languageId = std::string(kLanguageId),
        .compilerSpecId = std::string(kCompilerSpecId),
    });

    struct RejectedFault final {
        GhidraReadinessFault fault;
        std::string_view reason;
        std::string_view description;
    };
    constexpr std::array rejectedFaults = {
        RejectedFault{GhidraReadinessFault::missingShowPac,
                      "native-apple-profile-context-missing", "missing ShowPAC"},
        RejectedFault{GhidraReadinessFault::mismatchedPacClobber,
                      "native-apple-profile-context-mismatch", "mismatched PAC_clobber"},
        RejectedFault{GhidraReadinessFault::nullContext,
                      "native-apple-profile-context-unavailable", "null context"},
        RejectedFault{GhidraReadinessFault::nullTranslator,
                      "native-apple-profile-translator-unavailable", "null translator"},
        RejectedFault{GhidraReadinessFault::missingRequiredUserOp,
                      "native-apple-profile-userops-invalid", "missing PAC userop"},
        RejectedFault{GhidraReadinessFault::duplicateRequiredUserOp,
                      "native-apple-profile-userops-invalid", "duplicate required userop"},
        RejectedFault{GhidraReadinessFault::unexpectedSelectedProfile,
                      "native-apple-profile-identity-mismatch", "unexpected selected profile"},
        RejectedFault{GhidraReadinessFault::decodeBeforeHook,
                      "native-apple-profile-hook-incomplete", "decode before profile hook"},
    };
    for (const auto& rejected : rejectedFaults) {
        publishedIdentity.reset();
        const auto beforeFault = detail::ghidraRuntimeSnapshot();
        const auto message = expectContractError(
            [&] {
                publishedIdentity = detail::prepareGhidraRuntimeIdentityForTesting(
                    makeConfiguration(), selectedProfile, rejected.fault
                );
            },
            rejected.description
        );
        check(message == rejected.reason,
              std::string(rejected.description) + " fails with its stable readiness reason");
        check(!publishedIdentity.has_value(),
              std::string(rejected.description) + " publishes no runtime identity");
        checkRuntimeSnapshotUnchanged(
            beforeFault,
            detail::ghidraRuntimeSnapshot(),
            rejected.description
        );
    }

    publishedIdentity = detail::prepareGhidraRuntimeIdentityForTesting(
        makeConfiguration(), selectedProfile, GhidraReadinessFault::none
    );
    const auto& identity = *publishedIdentity;
    check(identity.backendId == "ghidra-native-decompiler",
          "ready runtime publishes the frozen backend ID");
    check(identity.engineVersion == "12.1.2",
          "ready runtime publishes the compiled engine version");
    check(identity.engineRevision == "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
          "ready runtime publishes the compiled engine revision");
    check(identity.wrapperVersion == "dcp05c-v1",
          "ready runtime publishes the DCP-05C wrapper version");
    check(isLowerHexRevision(identity.wrapperRevision),
          "ready runtime publishes a canonical compiled wrapper revision");
    check(identity.packageManifestSha256 == MACSCOPE_TEST_SLEIGH_MANIFEST_SHA256,
          "ready runtime publishes the attested manifest digest");
    check(identity.packageTreeSha256 == kPackageTreeSha256,
          "ready runtime publishes the exact attested complete-tree digest");
    check(identity.languageId == kLanguageId,
          "ready runtime publishes the prepared Apple-Silicon language");
    check(identity.compilerSpecId == kCompilerSpecId,
          "ready runtime publishes the prepared default compiler specification");
    check(identity.targetProfileId == kTargetProfileId,
          "ready runtime publishes the selected target profile");
    check(identity.contextProfileSha256 == kContextProfileSha256,
          "ready runtime publishes the applied and read-back context profile");

    const auto provider = makeGhidraProvider(makeConfiguration());
    const auto availability = provider->availability();
    check(availability.runtimeIdentity.has_value(),
          "only fully successful provider readiness publishes runtime identity");
    if (availability.runtimeIdentity) {
        check(*availability.runtimeIdentity == identity,
              "published provider runtime identity equals the successful readiness result");
    }
}

void testTargetNormalization() {
    struct AcceptedTarget final {
        std::uint32_t rawSubtype;
        ArchitectureVariant variant;
        std::string_view capabilityBits;
        std::optional<std::uint32_t> pointerAuthAbiVersion;
    };
    const std::array acceptedTargets = {
        AcceptedTarget{0x0000'0000U, ArchitectureVariant::arm64, "00000000", std::nullopt},
        AcceptedTarget{0x8000'0000U, ArchitectureVariant::arm64, "80000000", std::nullopt},
        AcceptedTarget{0x0000'0002U, ArchitectureVariant::arm64e, "00000000", std::nullopt},
        AcceptedTarget{0x8000'0002U, ArchitectureVariant::arm64e, "80000000", 0U},
    };

    for (const auto& accepted : acceptedTargets) {
        const auto target = normalizeAppleMachOTarget(
            0x0100'000cU,
            accepted.rawSubtype,
            std::string(64U, 'b'),
            8'192U
        );
        check(target.normalizedVariant == accepted.variant,
              "accepted Mach-O subtype normalizes to the frozen architecture variant");
        check(target.recognizedCapabilityBits == accepted.capabilityBits,
              "accepted Mach-O subtype preserves only recognized capability bits");
        check(target.pointerAuthAbiVersion == accepted.pointerAuthAbiVersion,
              "accepted Mach-O subtype preserves the qualified pointer-auth ABI version");
        check(target.languageId == kLanguageId && target.compilerSpecId == kCompilerSpecId,
              "every accepted target selects only the Apple language and default compiler");
        check(target.profileId == kTargetProfileId &&
                  target.contextProfileSha256 == kContextProfileSha256,
              "every accepted target selects the same sealed target/context profile");
        check(target.context == std::array<TargetContextValue, 4>{
                  TargetContextValue{"ShowPAC", 1},
                  TargetContextValue{"PAC_clobber", 1},
                  TargetContextValue{"ShowBTI", 0},
                  TargetContextValue{"ShowMemTag", 0},
              },
              "every accepted target carries the exact ordered context defaults");
    }

    constexpr std::array rejectedSubtypes = {
        0x0000'0001U, 0x1000'0002U, 0x7000'0002U, 0x8000'0003U, 0xffff'ffffU,
    };
    for (const auto subtype : rejectedSubtypes) {
        expectContractError(
            [subtype] {
                (void)normalizeAppleMachOTarget(
                    0x0100'000cU, subtype, std::string(64U, 'b'), 8'192U
                );
            },
            "unsupported Apple Mach-O subtype"
        );
    }
}

void testCancellationBeforeNativeWork(
    NativeStructuredProvider& provider,
    StructuredDecompilerBackend& backend
) {
    std::atomic_bool cancelled = true;
    const auto request = makeRequest();

    const auto rawMessage = expectContractError(
        [&] { (void)provider.produce(request, CancellationToken(&cancelled)); },
        "raw provider observes pre-entry cancellation"
    );
    check(rawMessage == "analysis was cancelled",
          "raw provider returns the stable cancellation reason");

    const auto validatedMessage = expectContractError(
        [&] { (void)backend.decompile(request, CancellationToken(&cancelled)); },
        "validated backend observes pre-entry cancellation"
    );
    check(validatedMessage == "analysis was cancelled",
          "validated backend returns the stable cancellation reason");
}

void testRequestLanguageAndCompilerMismatchFailClosed(StructuredDecompilerBackend& backend) {
    const auto wrongLanguage = makeRequest("x86:LE:64:default", "default");
    expectContractError(
        [&] { (void)backend.decompile(wrongLanguage, CancellationToken{}); },
        "provider rejects a request for another language"
    );

    const auto wrongCompiler = makeRequest(std::string(kLanguageId), "unapproved");
    expectContractError(
        [&] { (void)backend.decompile(wrongCompiler, CancellationToken{}); },
        "provider rejects a request for another compiler specification"
    );
}

void testStraightLineEffectiveByteResultAndDeterminism(StructuredDecompilerBackend& backend) {
    const auto request = makeRequest();
    check(request.rawFunctionBytes() != request.effectiveFunctionBytes(),
          "fixture raw and effective function bytes deliberately diverge");

    const auto first = backend.decompile(request, CancellationToken{});
    validateStructuredResult(request, first);

    check(first.requestId == request.requestId, "request ID round-trips exactly");
    check(first.requestSha256 == request.requestSha256, "request digest round-trips exactly");
    check(first.image == request.image, "image identity round-trips exactly");
    check(first.function == request.function, "function identity round-trips exactly");
    check(!first.instructions.empty(), "straight-line function produces instructions");
    check(!first.operations.empty(), "straight-line function produces native p-code");
    check(!first.blocks.empty(), "straight-line function produces a basic block");
    check(first.ssaBindings.size() == first.operations.size(),
          "every operation has exactly one mandatory SSA binding");
    check(joinedInstructionBytes(first) == request.effectiveFunctionBytes(),
          "instruction bytes come only from caller-owned effective memory");
    check(joinedInstructionBytes(first) != request.rawFunctionBytes(),
          "raw provenance bytes are not native byte authority");
    check(containsMovFortyTwo(first),
          "native p-code represents the effective mov w0, #42 instruction");
    check(first.pseudocodeDocument.has_value(),
          "straight-line function publishes a native pseudocode document");
    if (first.pseudocodeDocument) {
        check(!first.pseudocodeDocument->text.empty(),
              "native pseudocode document is nonempty");
        check(first.pseudocodeDocument->language == "c",
              "native pseudocode document declares the frozen C language");
        check(first.pseudocodeDocument->isComplete,
              "ordinary native pseudocode output is complete");
        check(!first.pseudocodeDocument->isTruncated,
              "ordinary native pseudocode output is not truncated");
    }
    check(backend.availability().capabilities.tokenizedPseudocode,
          "native structured markup advertises qualified semantic tokens");
    check(!first.tokens.empty(),
          "native structured markup accompanies the presentation document with tokens");

    const auto second = backend.decompile(request, CancellationToken{});
    validateStructuredResult(request, second);
    check(second == first, "repeated provider calls produce identical canonical DTOs");

    auto freshBackend = makeGhidraBackend(makeConfiguration());
    const auto fresh = freshBackend->decompile(request, CancellationToken{});
    validateStructuredResult(request, fresh);
    check(fresh == first,
          "fresh provider instances produce byte-identical pseudocode and structured DTOs");
}

void testPseudocodeOutputIsBoundedAndUtf8Valid(NativeStructuredProvider& provider) {
    {
        detail::BoundedUTF8StreamBuffer utf8Buffer(3U);
        std::ostream output(&utf8Buffer);
        output << "\xc3\xa9\xc3\xa9";
        output.flush();
        check(utf8Buffer.overflowed(),
              "fixed-capacity stream records a write beyond its retained prefix");
        check(utf8Buffer.text() == "\xc3\xa9",
              "overflow trimming removes an incomplete trailing UTF-8 scalar");
    }

    const auto baselineRequest = makeRequest();
    const auto baseline = provider.produce(baselineRequest, CancellationToken{});
    validateStructuredResult(baselineRequest, baseline);
    check(baseline.pseudocodeDocument.has_value(),
          "baseline native result publishes pseudocode before truncation testing");
    if (!baseline.pseudocodeDocument || baseline.pseudocodeDocument->text.size() <= 16U) {
        check(false, "baseline pseudocode is long enough to exercise bounded truncation");
        return;
    }

    auto documentless = baseline;
    documentless.pseudocodeDocument.reset();
    const auto documentlessBytes = structuredResultEncodedSizeUpperBound(documentless);
    auto oneByteDocument = documentless;
    oneByteDocument.pseudocodeDocument = PseudocodeDocumentRecord{
        .text = "x",
        .language = "c",
        .isComplete = true,
        .isTruncated = false,
    };
    const auto oneByteDocumentBytes = structuredResultEncodedSizeUpperBound(oneByteDocument);
    check(oneByteDocumentBytes >= documentlessBytes + 1U,
          "document accounting includes its fixed overhead and one text byte");
    if (oneByteDocumentBytes < documentlessBytes + 1U) return;

    const auto fixedDocumentOverhead = oneByteDocumentBytes - documentlessBytes - 1U;
    // This chooses a smaller total budget; token-first publication determines
    // the actual document allowance, checked from the resulting DTO below.
    constexpr std::size_t baselineTextAllowance = 16U;
    auto boundedRequest = makeRequest();
    boundedRequest.budgets.maxOutputBytes = documentlessBytes + fixedDocumentOverhead +
        baselineTextAllowance;
    const auto bounded = provider.produce(boundedRequest, CancellationToken{});
    checkBoundedNativePresentation(boundedRequest, bounded, baseline, true);

    // A full-token baseline cannot predict a later document's zero capacity:
    // tokens may shrink first. The complete semantic graph itself remains a
    // non-negotiable lower bound, independent of either presentation layer.
    const auto semanticBytes = structuredResultEncodedSizeUpperBound(
        withoutNativePresentation(baseline));
    check(semanticBytes > 0U, "complete native semantic graph has a nonzero byte bound");
    if (semanticBytes == 0U) return;
    auto impossibleRequest = makeRequest();
    impossibleRequest.budgets.maxOutputBytes = semanticBytes - 1U;
    const auto message = expectContractError(
        [&] { (void)provider.produce(impossibleRequest, CancellationToken{}); },
        "complete native semantic graph with insufficient publication capacity"
    );
    check(message == "native-provider-output-budget-exceeded",
          "native provider fails closed rather than publishing an incomplete semantic graph");
}

void testConditionalMultiBlockCfg(
    NativeStructuredProvider& provider,
    StructuredDecompilerBackend& backend
) {
    const auto request = makeConditionalRequest();
    const auto raw = produceOrFail(
        [&] { return provider.produce(request, CancellationToken{}); },
        "conditional multi-block native export"
    );
    if (!raw) return;
    validateStructuredResult(request, *raw);
    const auto firstValue = produceOrFail(
        [&] { return backend.decompile(request, CancellationToken{}); },
        "validated conditional multi-block export"
    );
    if (!firstValue) return;
    const auto& first = *firstValue;
    validateStructuredResult(request, first);
    check(first == *raw, "validated wrapper publishes the exact canonical native CFG DTO");

    checkExactInstructionEvidence(request, first);
    checkBlockOperationOrdering(first);
    checkCapabilityTruth(first);
    check(first.blocks.size() == 3U,
          "conditional fixture produces exactly entry, false, and true blocks");
    check(first.edges.size() == 2U,
          "conditional fixture produces exactly two internal CFG edges");

    constexpr std::string_view entryBlockId = "block:0000000000001000";
    constexpr std::string_view falseBlockId = "block:0000000000001010";
    constexpr std::string_view trueBlockId = "block:0000000000001008";
    const auto* entry = findBlock(first, entryBlockId);
    const auto* falseBlock = findBlock(first, falseBlockId);
    const auto* trueBlock = findBlock(first, trueBlockId);
    check(entry != nullptr, "entry block has its canonical semantic ID");
    check(falseBlock != nullptr, "false block has its canonical semantic ID");
    check(trueBlock != nullptr, "true block has its canonical semantic ID");
    if (entry != nullptr) {
        check(entry->startAddress == 0x1000 && entry->endAddressExclusive == 0x1008,
              "entry block spans cmp and conditional branch exactly");
        check(entry->terminatorKind == "conditional",
              "entry block publishes a conditional terminator");
    }
    if (falseBlock != nullptr) {
        check(falseBlock->startAddress == 0x1010 && falseBlock->endAddressExclusive == 0x1018,
              "native false output spans its mov and return exactly");
        check(falseBlock->terminatorKind == "return",
              "native false-output block publishes a return terminator");
    }
    if (trueBlock != nullptr) {
        check(trueBlock->startAddress == 0x1008 && trueBlock->endAddressExclusive == 0x1010,
              "native true output spans its mov and return exactly");
        check(trueBlock->terminatorKind == "return",
              "native true-output block publishes a return terminator");
    }

    std::unordered_map<std::string, const EdgeRecord*> edgesByKind;
    for (const auto& edge : first.edges) {
        edgesByKind.emplace(edge.kind, &edge);
    }
    const auto falseIterator = edgesByKind.find("false");
    const auto trueIterator = edgesByKind.find("true");
    check(falseIterator != edgesByKind.end(), "conditional CFG has a false edge");
    check(trueIterator != edgesByKind.end(), "conditional CFG has a true edge");
    if (falseIterator != edgesByKind.end()) {
        const auto& edge = *falseIterator->second;
        check(edge.id ==
                  "edge:block:0000000000001000:false:0000000000001010:0",
              "false edge has the frozen deterministic semantic ID");
        check(edge.sourceBlockId == entryBlockId && edge.targetBlockId == falseBlockId,
              "false edge has reciprocal internal block ownership");
        check(edge.targetAddress == 0x1010,
              "false edge preserves the native semantic false target");
    }
    if (trueIterator != edgesByKind.end()) {
        const auto& edge = *trueIterator->second;
        check(edge.id ==
                  "edge:block:0000000000001000:true:0000000000001008:1",
              "true edge has the frozen deterministic semantic ID");
        check(edge.sourceBlockId == entryBlockId && edge.targetBlockId == trueBlockId,
              "true edge has reciprocal internal block ownership");
        check(edge.targetAddress == 0x1008,
              "true edge preserves the native semantic true target");
    }

    const auto second = backend.decompile(request, CancellationToken{});
    validateStructuredResult(request, second);
    check(second == first, "conditional CFG DTO is deterministic across repeated analysis");
}

void testDirectCallAndSpecialSpaceMapping(
    NativeStructuredProvider& provider,
    StructuredDecompilerBackend& backend
) {
    const auto request = makeDirectCallRequest();
    const auto raw = produceOrFail(
        [&] { return provider.produce(request, CancellationToken{}); },
        "direct-call and special-space native export"
    );
    if (!raw) return;
    validateStructuredResult(request, *raw);
    const auto firstValue = produceOrFail(
        [&] { return backend.decompile(request, CancellationToken{}); },
        "validated direct-call and special-space export"
    );
    if (!firstValue) return;
    const auto& first = *firstValue;
    validateStructuredResult(request, first);
    check(first == *raw, "validated wrapper publishes the exact canonical native call DTO");

    checkExactInstructionEvidence(request, first);
    checkBlockOperationOrdering(first);
    checkCapabilityTruth(first);
    const auto* callOperation = findOperation(first, "CALL");
    check(callOperation != nullptr, "direct BL instruction produces a CALL operation");
    check(first.calls.size() == 1U, "CALL operation has exactly one mandatory CallRecord");
    if (callOperation != nullptr) {
        check(callOperation->id.starts_with("op:0000000000001000:"),
              "CALL operation ID uses instruction address and stable native sequence");
        check(callOperation->directTargetAddress == 0x1020,
              "CALL operation preserves the exact direct target");
        check(callOperation->sourceRanges ==
                  std::vector<SourceRange>{{request.image.imageId, 0x1000, 0x1004}},
              "CALL operation has the exact image-qualified instruction range");
    }
    if (first.calls.size() == 1U && callOperation != nullptr) {
        const auto& call = first.calls.front();
        check(call.id == "call:" + callOperation->id,
              "CallRecord ID is derived only from the defining operation ID");
        check(call.operationId == callOperation->id,
              "CallRecord references the defining CALL operation");
        check(call.kind == "direct", "CallRecord distinguishes a direct call");
        check(call.targetAddress == 0x1020,
              "CallRecord preserves the direct target address");
        check(call.targetSymbol == "_knownCallee",
              "CallRecord selects the exact callable target symbol");
        check(call.targetSymbol != "_dataAtCalleeAddress",
              "CallRecord never substitutes a non-callable data symbol");
        check(call.prototypeTypeId && call.argumentVariableIds.empty() &&
                  !call.resultVariableId,
              "qualified type recovery publishes the native call prototype without fabricating variables");
        check(call.sourceRanges == callOperation->sourceRanges,
              "CallRecord preserves the defining operation source range");
    }

    std::set<std::string> specialKinds;
    std::set<std::string> specialSpaceIds;
    for (const auto& space : first.addressSpaces) {
        if (space.kind == "iop" || space.kind == "fspec" || space.kind == "join") {
            specialKinds.insert(space.kind);
            specialSpaceIds.insert(space.id);
            check(space.id == "space:" + space.name,
                  "special address-space ID is derived from its canonical native name");
        }
    }
    check(specialKinds.contains("iop") && specialKinds.contains("fspec") &&
              specialKinds.contains("join"),
          "provider exposes all native special spaces by semantic identity");
    bool sawSpecialVarnode = false;
    for (const auto& varnode : first.varnodes) {
        if (!specialSpaceIds.contains(varnode.addressSpaceId)) {
            continue;
        }
        sawSpecialVarnode = true;
        check(varnode.role == "internal" || varnode.role == "join",
              "special varnode has a semantic internal or join role");
        check(varnode.id.find("0x") == std::string::npos,
              "special varnode ID never serializes a pointer-like value");
        check(varnode.id.starts_with("varnode:"),
              "special varnode uses the frozen semantic varnode namespace");
    }
    check(sawSpecialVarnode,
          "direct call fixture exercises at least one semantically mapped special varnode");

    const auto second = backend.decompile(request, CancellationToken{});
    validateStructuredResult(request, second);
    check(second == first, "direct-call DTO is deterministic across repeated analysis");
}

void testIndirectCall(StructuredDecompilerBackend& backend) {
    const auto request = makeIndirectCallRequest();
    const auto result = backend.decompile(request, CancellationToken{});
    validateStructuredResult(request, result);

    checkExactInstructionEvidence(request, result);
    checkBlockOperationOrdering(result);
    checkCapabilityTruth(result);
    check(result.blocks.size() == 1U, "indirect call fixture has one native basic block");
    check(result.edges.empty(), "indirect call and return have no CFG edges");
    const auto* operation = findOperation(result, "CALLIND");
    check(operation != nullptr, "BLR instruction produces a CALLIND operation");
    check(result.calls.size() == 1U, "CALLIND operation has exactly one CallRecord");
    if (operation != nullptr) {
        check(!operation->directTargetAddress,
              "CALLIND operation does not fabricate a direct target");
        check(operation->sourceRanges ==
                  std::vector<SourceRange>{{request.image.imageId, 0x1000, 0x1004}},
              "CALLIND operation has the exact image-qualified source range");
    }
    if (operation != nullptr && result.calls.size() == 1U) {
        const auto& call = result.calls.front();
        check(call.id == "call:" + operation->id,
              "indirect CallRecord ID derives only from its operation");
        check(call.operationId == operation->id,
              "indirect CallRecord resolves to its defining operation");
        check(call.kind == "indirect", "indirect CallRecord preserves call kind");
        check(!call.targetAddress && !call.targetSymbol && call.prototypeTypeId &&
                  call.argumentVariableIds.empty() && !call.resultVariableId,
              "indirect CallRecord publishes only its native prototype and no fabricated target or variables");
        check(call.sourceRanges == operation->sourceRanges,
              "indirect CallRecord preserves its exact defining source range");
    }
}

// RX-17: the by-element dot-product operand used to export no value, so native
// p-code generation crashed on real BFDOT/USDOT/SUDOT code. Each helper
// accumulates into v0, and fmov w0, s0 keeps the chain live through the return.
void testIndexedDotProductElementOperands(StructuredDecompilerBackend& backend) {
    const auto request = makeRequestForFunction(
        "indexed-dot-product",
        "_indexedDotProducts",
        {
            0x20, 0xf8, 0x62, 0x4f, // bfdot v0.4s, v1.8h, v2.2h[3]
            0x20, 0xf8, 0xa2, 0x4f, // usdot v0.4s, v1.16b, v2.4b[3]
            0x20, 0xf8, 0x22, 0x4f, // sudot v0.4s, v1.16b, v2.4b[3]
            0x00, 0x00, 0x26, 0x1e, // fmov w0, s0
            0xc0, 0x03, 0x5f, 0xd6, // ret
        }
    );
    const auto result = produceOrFail(
        [&] { return backend.decompile(request, CancellationToken{}); },
        "indexed dot-product by-element decompile"
    );
    if (!result) return;
    validateStructuredResult(request, *result);
    checkExactInstructionEvidence(request, *result);

    struct Expected final {
        std::string_view mnemonic;
        std::string_view elementOperand;
        std::string_view helper;
    };
    constexpr std::array<Expected, 3> expected = {{
        {"bfdot", "v2.2H[", "NEON_bfdot"},
        {"usdot", "v2.4B[", "NEON_usdot"},
        {"sudot", "v2.4B[", "NEON_sudot"},
    }};
    check(result->instructions.size() == 5U,
          "indexed dot-product fixture decodes all five instructions");
    for (std::size_t index = 0; index < expected.size(); ++index) {
        const auto& want = expected[index];
        if (index >= result->instructions.size()) break;
        const auto& instruction = result->instructions[index];
        check(instruction.mnemonic == want.mnemonic,
              std::string(want.mnemonic) + " by-element decodes with its mnemonic");
        check(instruction.body.find(want.elementOperand) != std::string::npos &&
                  instruction.body.find("3]") != std::string::npos,
              std::string(want.mnemonic) + " by-element shows the indexed element operand");
        check(!instruction.operationIds.empty(),
              std::string(want.mnemonic) + " by-element produces native p-code");
        check(!findUserOperations(*result, want.helper).empty(),
              std::string(want.mnemonic) + " by-element retains its named helper");
    }
    check(result->pseudocodeDocument.has_value() &&
              !result->pseudocodeDocument->text.empty(),
          "indexed dot-product function publishes a nonempty pseudocode document");
}

void testNativeHeritageAndSameProcessDeterminism(
    NativeStructuredProvider& provider,
    StructuredDecompilerBackend& backend
) {
    const auto availability = backend.availability();
    check(availability.capabilities.nativeDecompilerHeritage &&
              availability.capabilities.imageQualifiedSourceRanges &&
              availability.capabilities.structuredControlFlow,
          "native heritage scenario requires the always-on structural capability claims");
    check(availability.capabilities.completeRegisterSsa && !availability.capabilities.memorySsa &&
              availability.capabilities.recoveredVariables && availability.capabilities.recoveredTypes &&
              availability.capabilities.tokenizedPseudocode,
          "native heritage scenario promotes register SSA, recovered types, variables, and tokens");

    const auto loopRequest = makeLoopRequest();
    const auto raw = produceOrFail(
        [&] { return provider.produce(loopRequest, CancellationToken{}); },
        "native heritage raw loop export"
    );
    if (!raw) return;
    validateStructuredResult(loopRequest, *raw);
    checkCapabilityTruth(*raw);
    checkNativeSsaHeritageRelationships(*raw);

    const auto first = backend.decompile(loopRequest, CancellationToken{});
    validateStructuredResult(loopRequest, first);
    check(first == *raw, "validated wrapper preserves the raw native heritage DTO exactly");
    checkCapabilityTruth(first);
    checkNativeSsaHeritageRelationships(first);

    check(!first.phis.empty(),
          "native loop heritage publishes its directly sourced PhiRecords");
    if (!first.phis.empty()) {
        auto malformed = first;
        malformed.phis.front().incoming.pop_back();
        expectContractError(
            [&] { validateStructuredResult(loopRequest, malformed); },
            "incomplete native phi predecessor evidence"
        );

        malformed = first;
        auto& incoming = malformed.phis.front().incoming;
        if (incoming.size() >= 2U) {
            std::swap(incoming[0].ssaValueId, incoming[1].ssaValueId);
            expectContractError(
                [&] { validateStructuredResult(loopRequest, malformed); },
                "swapped native phi input-to-edge provenance"
            );
        }
    }
    for (std::size_t run = 0; run < 5U; ++run) {
        const auto repeated = backend.decompile(loopRequest, CancellationToken{});
        validateStructuredResult(loopRequest, repeated);
        check(repeated == first,
              "complete native heritage DTO is deterministic across same-process repeat runs");
    }

    const auto directRequest = makeDirectCallRequest();
    const auto direct = backend.decompile(directRequest, CancellationToken{});
    validateStructuredResult(directRequest, direct);
    const auto* directOperation = findOperation(direct, "CALL");
    check(directOperation != nullptr && direct.calls.size() == 1U,
          "direct native CALL has its required single conservative call record");
    if (directOperation != nullptr && direct.calls.size() == 1U) {
        const auto& call = direct.calls.front();
        check(call.operationId == directOperation->id && call.kind == "direct" &&
                  call.targetAddress == directOperation->directTargetAddress &&
                  call.prototypeTypeId && call.argumentVariableIds.empty() && !call.resultVariableId,
              "direct CALL preserves its native target and qualified prototype without variables");
    }

    const auto indirectRequest = makeIndirectCallRequest();
    const auto indirect = backend.decompile(indirectRequest, CancellationToken{});
    validateStructuredResult(indirectRequest, indirect);
    const auto* indirectOperation = findOperation(indirect, "CALLIND");
    check(indirectOperation != nullptr && indirect.calls.size() == 1U,
          "indirect native CALLIND has its required single conservative call record");
    if (indirectOperation != nullptr && indirect.calls.size() == 1U) {
        const auto& call = indirect.calls.front();
        check(call.operationId == indirectOperation->id && call.kind == "indirect" &&
                  !indirectOperation->directTargetAddress && !call.targetAddress && !call.targetSymbol &&
                  call.prototypeTypeId && call.argumentVariableIds.empty() && !call.resultVariableId,
              "CALLIND publishes its native prototype without fabricated direct or variable references");
    }
}

void testNativeRecoveredTypes(
    NativeStructuredProvider& provider,
    StructuredDecompilerBackend& backend
) {
    const auto availability = backend.availability();
    check(availability.capabilities.recoveredTypes,
          "native type scenario requires the recovered-types capability");

    const auto request = makeDirectCallRequest();
    const auto raw = produceOrFail(
        [&] { return provider.produce(request, CancellationToken{}); },
        "native recovered type graph"
    );
    if (!raw) return;
    validateStructuredResult(request, *raw);
    checkNativeTypeGraph(*raw);

    const auto first = backend.decompile(request, CancellationToken{});
    validateStructuredResult(request, first);
    check(first == *raw, "validated wrapper preserves the native type graph exactly");
    checkNativeTypeGraph(first);
    const auto second = backend.decompile(request, CancellationToken{});
    check(second == first, "native type graph is deterministic across repeated provider runs");

    if (!first.varnodes.empty() && first.varnodes.front().typeId) {
        auto malformed = first;
        malformed.varnodes.front().typeId = "type:missing";
        expectContractError(
            [&] { validateStructuredResult(request, malformed); },
            "unresolved native varnode type reference"
        );
    }
}

void testNativeRecoveredVariables(
    NativeStructuredProvider& provider,
    StructuredDecompilerBackend& backend
) {
    const auto availability = backend.availability();
    check(availability.capabilities.recoveredVariables,
          "native variable scenario requires the recovered-variables capability");

    const auto request = makeLoopRequest();
    const auto raw = produceOrFail(
        [&] { return provider.produce(request, CancellationToken{}); },
        "native recovered variable graph"
    );
    if (!raw) return;
    validateStructuredResult(request, *raw);
    checkNativeVariableGraph(request, *raw);

    const auto first = backend.decompile(request, CancellationToken{});
    validateStructuredResult(request, first);
    check(first == *raw, "validated wrapper preserves native recovered variables exactly");
    checkNativeVariableGraph(request, first);
    const auto second = backend.decompile(request, CancellationToken{});
    check(second == first,
          "native recovered variable graph is deterministic across repeated provider runs");

    if (!first.variables.empty()) {
        auto malformed = first;
        malformed.variables.front().storageVarnodeIds = {"varnode:missing"};
        expectContractError(
            [&] { validateStructuredResult(request, malformed); },
            "unresolved native recovered variable storage"
        );
    }
}

void testBitmapVariableIdentity(
    NativeStructuredProvider& provider,
    StructuredDecompilerBackend& backend
) {
    const auto base = detail::symbolVariableIdentity(0x42U, -1);
    check(base == "variable:symbol:0000000000000042",
          "noncolliding native symbol identity remains unchanged");
    check(detail::symbolVariableIdentity(0x42U, 0) == base + ":0",
          "native symbol offset remains explicit");
    const auto output = detail::highVariableIdentity(base, "op:0000000100000000:0000000000000000", std::nullopt);
    const auto input0 = detail::highVariableIdentity(base, "op:0000000100000000:0000000000000000", 0U);
    const auto input1 = detail::highVariableIdentity(base, "op:0000000100000000:0000000000000000", 1U);
    const auto next = detail::highVariableIdentity(base, "op:0000000100000004:0000000000000000", std::nullopt);
    check(std::set<std::string>{output, input0, input1, next}.size() == 4U,
          "same-symbol native highs remain distinct by actual operation and operand provenance");

    // Exact owned installed fixture: ldr q0,[x0]; ldr q1,[x1];
    // and v0.16b,v1.16b,v0.16b; cnt v0.16b,v0.16b;
    // uaddlv h0,v0.16b; fmov w0,s0; ret. The original provider rejected its
    // distinct native highs sharing symbol/offset before publishing the DTO.
    const auto request = makeRequestForFunction(
        "bitmap-variable-identity", "_bitmap_intersection_score",
        littleEndianWords({0x3dc00000U, 0x3dc00021U, 0x4e201c20U, 0x4e205800U,
                           0x6e303800U, 0x1e260000U, 0xd65f03c0U})
    );
    const auto raw = produceOrFail(
        [&] { return provider.produce(request, CancellationToken{}); },
        "bitmap native variable identity collision regression"
    );
    if (!raw) return;
    validateStructuredResult(request, *raw);
    checkNativeVariableGraph(request, *raw);
    std::map<std::string, std::size_t> qualifiedSymbols;
    for (const auto& variable : raw->variables) {
        const auto marker = variable.id.find(":high:");
        if (marker != std::string::npos) ++qualifiedSymbols[variable.id.substr(0, marker)];
    }
    check(std::any_of(qualifiedSymbols.begin(), qualifiedSymbols.end(),
                     [](const auto& item) { return item.second > 1U; }),
          "bitmap regression exports distinct highs sharing their real native symbol identity");
    const auto validated = backend.decompile(request, CancellationToken{});
    check(validated == *raw,
          "independent provider requests preserve deterministic collision-qualified identities and DTOs");
}

void testNativeStructuredRegions(
    StructuredDecompilerBackend& backend
) {
    const auto checkRegionEvidence = [](const AnalysisRequestView& request,
                                        const StructuredResult& result,
                                        const RegionRecord& region) {
        check(!region.blockIds.empty(), "native structured region owns at least one emitted basic block");
        for (const auto& blockId : region.blockIds) {
            check(findBlock(result, blockId) != nullptr,
                  "native structured region block reference resolves to a published block");
        }
        check(!region.sourceRanges.empty(),
              "native structured region carries direct image-qualified source evidence");
        for (const auto& range : region.sourceRanges) {
            check(range.imageId == request.image.imageId,
                  "native structured region preserves caller-owned image identity");
            check(range.startAddress >= request.function.entryAddress &&
                      range.endAddressExclusive <= request.function.endAddressExclusive &&
                      range.startAddress < range.endAddressExclusive,
                  "native structured region source range stays inside the caller-owned function");
        }
    };

    const auto checkRootAncestry = [](const StructuredResult& result,
                                     const RegionRecord& root,
                                     const RegionRecord& child) {
        check(!root.parentRegionId, "root structured region has no parent");
        check(child.parentRegionId.has_value(),
              "nested structured region records a native structured parent");
        std::set<std::string> ancestry;
        const RegionRecord* cursor = &child;
        while (cursor != nullptr && cursor->parentRegionId) {
            check(ancestry.insert(cursor->id).second,
                  "native structured region ancestry is acyclic");
            const auto parent = cursor->parentRegionId;
            const auto parentIterator = std::find_if(
                result.regions.begin(),
                result.regions.end(),
                [&parent](const RegionRecord& region) { return region.id == *parent; }
            );
            cursor = parentIterator == result.regions.end() ? nullptr : &*parentIterator;
        }
        check(cursor != nullptr && cursor->id == root.id,
              "nested structured region is owned by the native root ancestry");
    };

    const auto loopRequest = makeLoopRequest();
    const auto loopResult = backend.decompile(loopRequest, CancellationToken{});
    validateStructuredResult(loopRequest, loopResult);
    checkCapabilityTruth(loopResult);
    check(!loopResult.tokens.empty(),
          "structured region export includes directly sourced pseudocode tokens");
    const auto* loopRoot = findRegion(loopResult, "root");
    const auto* loop = findRegion(loopResult, "while");
    check(loopRoot != nullptr, "native structure export publishes a loop root region");
    check(loop != nullptr, "native structure export publishes a loop region");
    if (loopRoot != nullptr && loop != nullptr) {
        checkRootAncestry(loopResult, *loopRoot, *loop);
        check(!loop->conditionOperationId,
              "loop region does not fabricate a condition operation without direct proof");
        checkRegionEvidence(loopRequest, loopResult, *loop);
    }

    const auto conditionalRequest = makeConditionalRequest();
    const auto conditionalResult = backend.decompile(conditionalRequest, CancellationToken{});
    validateStructuredResult(conditionalRequest, conditionalResult);
    checkCapabilityTruth(conditionalResult);
    const auto* conditionalRoot = findRegion(conditionalResult, "root");
    const auto* conditional = findRegion(conditionalResult, "if");
    check(conditionalRoot != nullptr, "native structure export publishes a conditional root region");
    check(conditional != nullptr, "native structure export publishes an if region");
    if (conditionalRoot != nullptr && conditional != nullptr) {
        checkRootAncestry(conditionalResult, *conditionalRoot, *conditional);
        checkRegionEvidence(conditionalRequest, conditionalResult, *conditional);
    }

    const auto switchRequest = makeSwitchRequest();
    const auto switchResult = backend.decompile(switchRequest, CancellationToken{});
    validateStructuredResult(switchRequest, switchResult);
    checkCapabilityTruth(switchResult);
    const auto* switchRoot = findRegion(switchResult, "root");
    const auto* switchRegion = findRegion(switchResult, "switch");
    check(switchRoot != nullptr, "native structure export publishes a switch root region");
    check(switchRegion != nullptr, "native structure export publishes a switch region");
    if (switchRoot != nullptr && switchRegion != nullptr) {
        checkRootAncestry(switchResult, *switchRoot, *switchRegion);
        checkRegionEvidence(switchRequest, switchResult, *switchRegion);
    }
}

void testNativePseudocodeTokens(
    NativeStructuredProvider& provider,
    StructuredDecompilerBackend& backend
) {
    const auto request = makeLoopRequest();
    check(backend.availability().capabilities.tokenizedPseudocode,
          "qualified provider publishes native structured pseudocode tokens");

    const auto firstValue = produceOrFail(
        [&] { return provider.produce(request, CancellationToken{}); },
        "native structured pseudocode token export"
    );
    if (!firstValue) return;
    const auto& first = *firstValue;
    validateStructuredResult(request, first);
    check(!first.tokens.empty(), "native structured markup produces a non-empty token stream");

    std::set<std::string> tokenIds;
    bool sawEntityReference = false;
    bool sawOperationEvidence = false;
    const std::set<std::string> canonicalTokenKinds{
        "comment", "identifier", "keyword", "literal", "operation",
        "punctuation", "type", "whitespace",
    };
    std::uint32_t previousLine = 0;
    std::uint32_t previousColumn = 0;
    for (const auto& token : first.tokens) {
        check(tokenIds.insert(token.id).second,
              "native markup token IDs are deterministic and unique");
        check(!token.text.empty(), "native markup never publishes an empty token");
        check(canonicalTokenKinds.contains(token.kind),
              "native markup token kind is representable by the frozen MacScope wire contract");
        check(token.line > previousLine ||
                  (token.line == previousLine && token.column >= previousColumn),
              "native markup token positions preserve emitter order");
        previousLine = token.line;
        previousColumn = token.column;
        for (const auto& reference : token.entityReferences) {
            sawEntityReference = true;
            if (reference.kind == "operation") {
                sawOperationEvidence = true;
                check(token.sourceRanges.size() == 1U &&
                          token.sourceRanges.front().imageId == request.image.imageId &&
                          token.sourceRanges.front().startAddress >= request.function.entryAddress &&
                          token.sourceRanges.front().endAddressExclusive <=
                              request.function.endAddressExclusive,
                      "operation-referenced token carries exact image-qualified function evidence");
            }
        }
    }
    check(sawEntityReference, "native token stream resolves at least one semantic entity");
    check(sawOperationEvidence,
          "native token stream derives source evidence from an operation reference");

    const auto second = backend.decompile(request, CancellationToken{});
    check(second == first, "native structured pseudocode tokens are deterministic across runs");
    if (!first.tokens.empty()) {
        auto malformed = first;
        malformed.tokens.front().entityReferences.push_back({"operation", "op:missing"});
        expectContractError(
            [&] { validateStructuredResult(request, malformed); },
            "unresolved native token operation reference"
        );
    }
}

void testLoopCfg(
    NativeStructuredProvider& provider,
    StructuredDecompilerBackend& backend
) {
    const auto request = makeLoopRequest();
    const auto raw = produceOrFail(
        [&] { return provider.produce(request, CancellationToken{}); },
        "loop CFG native export"
    );
    if (!raw) return;
    validateStructuredResult(request, *raw);
    const auto validated = produceOrFail(
        [&] { return backend.decompile(request, CancellationToken{}); },
        "validated loop CFG export"
    );
    if (!validated) return;
    const auto& result = *validated;
    validateStructuredResult(request, result);
    check(result == *raw, "validated wrapper publishes the exact canonical loop CFG DTO");

    checkExactInstructionEvidence(request, result);
    checkBlockOperationOrdering(result);
    checkCapabilityTruth(result);
    check(result.blockPartition.has_value() && result.blocks.size() == 4U,
          "loop fixture retains the native empty entry, condition, body/backedge, and exit");
    check(result.edges.size() == 4U,
          "loop fixture retains the splice, two conditional edges, and backedge");

    constexpr std::string_view conditionId = "block:cfg:0000000000000001";
    constexpr std::string_view bodyId = "block:cfg:0000000000000003";
    constexpr std::string_view exitId = "block:cfg:0000000000000002";
    const auto* condition = findBlock(result, conditionId);
    const auto* body = findBlock(result, bodyId);
    const auto* exit = findBlock(result, exitId);
    check(condition != nullptr && body != nullptr && exit != nullptr,
          "loop blocks use deterministic final-CFG ordinals");
    if (condition != nullptr) {
        check(condition->terminatorKind == "conditional",
              "loop condition block has a conditional terminator");
    }
    if (body != nullptr) {
        check(body->terminatorKind == "branch",
              "loop body block has a direct-branch terminator");
    }
    if (exit != nullptr) {
        check(exit->terminatorKind == "return",
              "loop exit block has a return terminator");
    }

    const auto* falseEdge = findEdge(result, conditionId, "false");
    const auto* trueEdge = findEdge(result, conditionId, "true");
    const auto* backEdge = findEdge(result, bodyId, "branch");
    check(falseEdge != nullptr && trueEdge != nullptr && backEdge != nullptr,
          "loop CFG publishes native false, native true, and branch edges");
    if (falseEdge != nullptr) {
        check(falseEdge->targetBlockId == exitId && falseEdge->targetAddress == 0x100c,
              "native false output reaches the encoded CBZ target");
        check(falseEdge->id ==
                  "edge:block:cfg:0000000000000001:false:000000000000100c:0",
              "loop false edge has its deterministic semantic ID");
    }
    if (trueEdge != nullptr) {
        check(trueEdge->targetBlockId == bodyId && trueEdge->targetAddress == 0x1004,
              "native true output reaches the CBZ fallthrough body");
        check(trueEdge->id ==
                  "edge:block:cfg:0000000000000001:true:0000000000001004:1",
              "loop true edge has its deterministic semantic ID");
    }
    if (backEdge != nullptr) {
        check(backEdge->targetBlockId == conditionId && backEdge->targetAddress == 0x1000,
              "loop branch edge returns to the condition block");
        check(backEdge->id ==
                  "edge:block:cfg:0000000000000003:branch:0000000000001000:0",
              "loop backedge has its deterministic semantic ID");
    }
    if (condition != nullptr && falseEdge != nullptr && trueEdge != nullptr) {
        check(condition->successorEdgeIds ==
                  std::vector<std::string>{falseEdge->id, trueEdge->id},
              "condition block owns its ordered outgoing edges reciprocally");
    }
    if (body != nullptr && trueEdge != nullptr && backEdge != nullptr) {
        check(body->predecessorEdgeIds == std::vector<std::string>{trueEdge->id} &&
                  body->successorEdgeIds == std::vector<std::string>{backEdge->id},
              "loop body owns its predecessor and backedge reciprocally");
    }
    if (exit != nullptr && falseEdge != nullptr) {
        check(exit->predecessorEdgeIds == std::vector<std::string>{falseEdge->id},
              "loop exit owns its native false predecessor reciprocally");
    }

    std::size_t multiequalCount = 0U;
    for (const auto& operation : result.operations) {
        if (operation.opcode != "MULTIEQUAL") continue;
        ++multiequalCount;
        const auto binding = std::find_if(
            result.ssaBindings.begin(),
            result.ssaBindings.end(),
            [&operation](const SsaBindingRecord& candidate) {
                return candidate.operationId == operation.id;
            }
        );
        check(binding != result.ssaBindings.end(),
              "every native MULTIEQUAL retains its mandatory operation binding");
        if (binding == result.ssaBindings.end() || !binding->outputSsaValueId ||
            !operation.outputVarnodeId) {
            continue;
        }
        const auto phi = std::find_if(
            result.phis.begin(), result.phis.end(),
            [&operation](const PhiRecord& candidate) {
                return candidate.blockId == operation.blockId &&
                    candidate.varnodeId == *operation.outputVarnodeId;
            }
        );
        check(phi != result.phis.end(),
              "every native MULTIEQUAL publishes one block-and-varnode phi");
        if (phi == result.phis.end()) continue;
        check(phi->id == detail::definedPhiIdentity(operation.id) &&
                  phi->outputSsaValueId == *binding->outputSsaValueId &&
                  phi->incoming.size() == binding->inputSsaValueIds.size(),
              "native phi has deterministic identity and preserves MULTIEQUAL arity");
        std::multiset<std::string> bindingInputs(
            binding->inputSsaValueIds.begin(), binding->inputSsaValueIds.end()
        );
        std::multiset<std::string> phiInputs;
        for (const auto& incoming : phi->incoming) {
            phiInputs.insert(incoming.ssaValueId);
            if (!incoming.sourceBlockId || !incoming.edgeId) {
                const auto block = std::find_if(
                    result.blocks.begin(), result.blocks.end(),
                    [&phi](const BlockRecord& candidate) { return candidate.id == phi->blockId; }
                );
                check(!incoming.sourceBlockId && !incoming.edgeId &&
                          block != result.blocks.end() &&
                          block->startAddress == result.function.entryAddress,
                      "only the native function-entry phi input omits a CFG predecessor path");
                continue;
            }
            const auto edge = std::find_if(
                result.edges.begin(), result.edges.end(),
                [&incoming](const EdgeRecord& candidate) {
                    return candidate.id == *incoming.edgeId;
                }
            );
            check(edge != result.edges.end() &&
                      edge->sourceBlockId == *incoming.sourceBlockId &&
                      edge->targetBlockId == operation.blockId,
                      "native phi input path resolves to an edge entering its block");
        }
        check(phiInputs == bindingInputs,
              "native phi incoming values exactly preserve the MULTIEQUAL binding inputs");
    }
    check(multiequalCount > 0U && result.phis.size() == multiequalCount,
          "provider publishes exactly one PhiRecord per native MULTIEQUAL");
}

void testLoadStoreSpaceReference(StructuredDecompilerBackend& backend) {
    const auto request = makeLoadStoreRequest();
    const auto first = backend.decompile(request, CancellationToken{});
    validateStructuredResult(request, first);

    checkExactInstructionEvidence(request, first);
    checkBlockOperationOrdering(first);
    checkCapabilityTruth(first);
    const auto* load = findOperation(first, "LOAD");
    const auto* store = findOperation(first, "STORE");
    check(load != nullptr && store != nullptr,
          "load/store fixture exports both native memory operations");
    if (load != nullptr && store != nullptr) {
        check(!load->inputVarnodeIds.empty() && !store->inputVarnodeIds.empty(),
              "LOAD and STORE preserve their address-space operands");
        if (!load->inputVarnodeIds.empty() && !store->inputVarnodeIds.empty()) {
            const auto& loadSpaceId = load->inputVarnodeIds.front();
            const auto& storeSpaceId = store->inputVarnodeIds.front();
            check(loadSpaceId == storeSpaceId,
                  "LOAD and STORE share one semantic RAM space-reference varnode");
            check(loadSpaceId.find("space-ref:space:ram") != std::string::npos,
                  "space-reference ID contains the canonical RAM semantic path");
            check(loadSpaceId.find("0x") == std::string::npos,
                  "space-reference ID contains no pointer-like text");
            const auto* spaceReference = findVarnode(first, loadSpaceId);
            check(spaceReference != nullptr,
                  "space-reference operation input resolves to a VarnodeRecord");
            if (spaceReference != nullptr) {
                check(spaceReference->role == "internal",
                      "space-reference varnode is explicitly internal");
                check(spaceReference->offset == 0U,
                      "single semantic space reference receives deterministic numeric rank zero");
            }
        }
    }
    check(first.memoryVersions.empty() && first.memoryPhis.empty() &&
              first.memoryEffects.empty(),
          "false MemorySSA capability keeps all memory-dataflow records empty");

    const auto second = backend.decompile(request, CancellationToken{});
    validateStructuredResult(request, second);
    check(second == first, "LOAD/STORE semantic space rank is deterministic across analysis");
}

void testSwitchCfg(
    NativeStructuredProvider& provider,
    StructuredDecompilerBackend& backend
) {
    const auto request = makeSwitchRequest();
    const auto raw = produceOrFail(
        [&] { return provider.produce(request, CancellationToken{}); },
        "native switch CFG export"
    );
    if (!raw) return;
    validateStructuredResult(request, *raw);
    const auto validated = produceOrFail(
        [&] { return backend.decompile(request, CancellationToken{}); },
        "validated switch CFG export"
    );
    if (!validated) return;
    const auto& result = *validated;
    validateStructuredResult(request, result);
    check(result == *raw, "validated wrapper publishes the exact canonical native switch DTO");

    checkExactInstructionEvidence(request, result);
    checkBlockOperationOrdering(result);
    checkCapabilityTruth(result);
    check(result.instructions.size() == 41U,
          "switch fixture has the exact 41-instruction requested function coverage");
    check(result.blocks.size() == 11U,
          "switch fixture produces dispatch, eight cases, default, and join blocks");
    check(result.edges.size() == 18U,
          "switch fixture produces nine dispatch edges and nine join edges");

    bool sawExactWRegister = false;
    bool sawExactXRegister = false;
    for (const auto& varnode : result.varnodes) {
        if (varnode.role != "register" || !varnode.registerName) continue;
        const auto& name = *varnode.registerName;
        if (!name.empty() && name.front() == 'w') {
            sawExactWRegister = true;
            check(varnode.sizeBytes == 4U,
                  "a published w-register name has its exact four-byte storage width");
        } else if (!name.empty() && name.front() == 'x') {
            sawExactXRegister = true;
            check(varnode.sizeBytes == 8U,
                  "a published x-register name has its exact eight-byte storage width");
        }
    }
    check(sawExactWRegister && sawExactXRegister,
          "switch native p-code retains exact wN and xN register identities");

    constexpr std::string_view switchBlockId = "block:00000001000003f0";
    const auto* switchBlock = findBlock(result, switchBlockId);
    check(switchBlock != nullptr, "switch dispatch block has its semantic address ID");
    if (switchBlock != nullptr) {
        check(switchBlock->startAddress == kSwitchEntryAddress &&
                  switchBlock->endAddressExclusive == 0x10000041c,
              "switch dispatch block spans through the BRANCHIND exactly");
        check(switchBlock->terminatorKind == "switch",
              "BRANCHIND dispatch publishes a switch terminator");
    }

    const auto* branchIndirect = findOperation(result, "BRANCHIND");
    check(branchIndirect != nullptr, "native switch retains its BRANCHIND operation");
    if (branchIndirect != nullptr) {
        check(branchIndirect->sourceRanges ==
                  std::vector<SourceRange>{{request.image.imageId, 0x100000418, 0x10000041c}},
              "BRANCHIND retains its exact image-qualified source range");
        check(!branchIndirect->directTargetAddress,
              "BRANCHIND does not fabricate one direct target");
    }

    struct ExpectedSwitchEdge final {
        Address targetAddress;
        std::string_view kind;
        std::string_view targetBlockId;
        std::string_view edgeId;
    };
    constexpr std::array<ExpectedSwitchEdge, 9> expected = {{
        {0x10000041c, "switchCase", "block:000000010000041c",
         "edge:block:00000001000003f0:switchCase:000000010000041c:0"},
        {0x100000458, "switchCase", "block:0000000100000458",
         "edge:block:00000001000003f0:switchCase:0000000100000458:1"},
        {0x100000434, "switchCase", "block:0000000100000434",
         "edge:block:00000001000003f0:switchCase:0000000100000434:2"},
        {0x100000440, "switchCase", "block:0000000100000440",
         "edge:block:00000001000003f0:switchCase:0000000100000440:3"},
        {0x100000428, "switchCase", "block:0000000100000428",
         "edge:block:00000001000003f0:switchCase:0000000100000428:4"},
        {0x100000464, "switchCase", "block:0000000100000464",
         "edge:block:00000001000003f0:switchCase:0000000100000464:5"},
        {0x100000470, "switchCase", "block:0000000100000470",
         "edge:block:00000001000003f0:switchCase:0000000100000470:6"},
        {0x10000044c, "switchCase", "block:000000010000044c",
         "edge:block:00000001000003f0:switchCase:000000010000044c:7"},
        {0x10000047c, "switchDefault", "block:000000010000047c",
         "edge:block:00000001000003f0:switchDefault:000000010000047c:8"},
    }};

    std::size_t switchCaseCount = 0U;
    std::size_t switchDefaultCount = 0U;
    std::vector<std::string> expectedSuccessorIds;
    for (const auto& item : expected) {
        const auto iterator = std::find_if(
            result.edges.begin(), result.edges.end(),
            [&item, &switchBlockId](const EdgeRecord& edge) {
                return edge.sourceBlockId == switchBlockId && edge.kind == item.kind &&
                    edge.targetAddress == item.targetAddress;
            }
        );
        check(iterator != result.edges.end(),
              "native switch edge kind and exact target are preserved");
        if (iterator == result.edges.end()) continue;
        const auto& edge = *iterator;
        check(edge.id == item.edgeId,
              "switch edge uses its deterministic semantic ID and stable ordinal");
        check(edge.targetBlockId == item.targetBlockId,
              "switch edge resolves to its exact internal target block");
        check(branchIndirect != nullptr && edge.operationId == branchIndirect->id,
              "every switch edge references the defining BRANCHIND operation");
        expectedSuccessorIds.push_back(std::string(item.edgeId));
        if (edge.kind == "switchCase") ++switchCaseCount;
        if (edge.kind == "switchDefault") ++switchDefaultCount;
    }
    check(switchCaseCount == 8U,
          "eight native cases publish exactly eight switchCase CFG edges");
    check(switchDefaultCount == 1U,
          "the native default publishes exactly one switchDefault CFG edge");
    std::sort(expectedSuccessorIds.begin(), expectedSuccessorIds.end());
    if (switchBlock != nullptr) {
        check(switchBlock->successorEdgeIds == expectedSuccessorIds,
              "switch block reciprocally owns its canonical dispatch edge IDs");
    }

    const auto branchCount = static_cast<std::size_t>(std::count_if(
        result.edges.begin(), result.edges.end(),
        [](const EdgeRecord& edge) { return edge.kind == "branch"; }
    ));
    const auto fallthroughCount = static_cast<std::size_t>(std::count_if(
        result.edges.begin(), result.edges.end(),
        [](const EdgeRecord& edge) { return edge.kind == "fallthrough"; }
    ));
    check(branchCount == 8U && fallthroughCount == 1U,
          "eight case branches and one default fallthrough reach the join block");
    std::set<std::string> edgeIds;
    for (const auto& edge : result.edges) {
        check(edgeIds.insert(edge.id).second, "all switch fixture CFG edge IDs are unique");
    }

    const auto second = backend.decompile(request, CancellationToken{});
    validateStructuredResult(request, second);
    check(second == result, "switch CFG DTO is deterministic across repeated native analysis");
}

void testUnmappedSwitchTableFailsClosed(NativeStructuredProvider& provider) {
    const auto request = makeSwitchRequest(true);
    const auto first = expectContractError(
        [&] { (void)provider.produce(request, CancellationToken{}); },
        "unmapped native jump-table effective-byte view"
    );
    const auto second = expectContractError(
        [&] { (void)provider.produce(request, CancellationToken{}); },
        "repeated unmapped native jump-table effective-byte view"
    );
    check(first == "native-provider-effective-byte-read-unavailable",
          "unmapped native table reads return the exact sticky effective-byte-read-unavailable slug");
    check(second == first,
          "unmapped native table reads retain the sticky effective-byte failure reason");
    check(isStableProviderReason(first),
          "unmapped native table failure remains bounded and path-free");
}

void checkFailClosedRequest(
    NativeStructuredProvider& provider,
    const AnalysisRequestView& request,
    std::string_view scenario
) {
    const auto first = expectContractError(
        [&] { (void)provider.produce(request, CancellationToken{}); }, scenario
    );
    const auto second = expectContractError(
        [&] { (void)provider.produce(request, CancellationToken{}); }, scenario
    );
    check(first == second, "fail-closed reason is stable across repeated native analysis");
    check(isStableProviderReason(first),
          "fail-closed reason is bounded, path-free, pointer-free, and provider-scoped");
}

void testMalformedAndOutOfRangeFunctionsFailClosed(NativeStructuredProvider& provider) {
    checkFailClosedRequest(
        provider,
        makeRequestForFunction(
            "out-of-range-conditional-branch",
            "_conditionalBranchOutsideRequest",
            {0x00, 0x01, 0x00, 0xb4, 0xc0, 0x03, 0x5f, 0xd6}
        ),
        "conditional branch target outside the requested function"
    );
    checkFailClosedRequest(
        provider,
        makeRequestForFunction(
            "partial-instruction",
            "_partialFinalInstruction",
            {0x40, 0x05, 0x80, 0x52, 0xc0, 0x03}
        ),
        "partial final instruction"
    );
    checkFailClosedRequest(
        provider,
        makeRequestForFunction(
            "invalid-word",
            "_invalidInstruction",
            {0xff, 0xff, 0xff, 0xff}
        ),
        "invalid AArch64 instruction word"
    );
}

// DP10: a 4-byte `b _target` thunk (e.g. _jpeg_destroy_compress) is a tail
// call. It used to throw "Function flow out of bounds" and refuse the function.
void testUnconditionalBranchOutOfRangeIsTailCall(NativeStructuredProvider& provider) {
    const auto request = makeRequestForFunction(
        "tail-call",
        "_tailCallThunk",
        {0x08, 0x00, 0x00, 0x14},
        {SymbolRecord{"image.ghidra-provider", kEntryAddress + 0x20U, "_tailTarget", "function"}}
    );
    const auto result = provider.produce(request, CancellationToken{});
    validateStructuredResult(request, result);
    check(result.instructions.size() == 1U, "tail-call thunk decodes only its own branch");
    const auto* call = findOperation(result, "CALL");
    check(call != nullptr, "out-of-range B becomes a CALL operation");
    check(findOperation(result, "RETURN") != nullptr, "tail call is followed by a RETURN");
    check(findOperation(result, "BRANCH") == nullptr, "tail call publishes no BRANCH");
    check(result.calls.size() == 1U, "tail call publishes exactly one CallRecord");
    if (result.calls.size() == 1U) {
        check(result.calls.front().kind == "direct", "tail call is a direct call");
        check(result.calls.front().targetAddress == kEntryAddress + 0x20U,
              "tail call preserves the branch target address");
    }
    check(result.pseudocodeDocument && result.pseudocodeDocument->text.find("_tailTarget(") != std::string::npos,
          "tail-call callee prints by its request symbol, not func_0x...");
}

// DP10: 87 of the remaining libjpeg refusals end in `bl ___stack_chk_fail`
// (one in `bl _exit`); flow fell through into the next function.
// libjpeg `_term_destination` (0x234f0): refused with
// native-provider-type-identity-collision on cfa499950 although it gets no callee hints.
void testTermDestinationExports(NativeStructuredProvider& provider) {
    constexpr Address entry = 0x234f0U;
    const std::array<std::uint32_t, 41> words = {
        0xa9bd57f6U, 0xa9014ff4U, 0xa9027bfdU, 0x910083fdU, 0xaa0003f3U, 0xf9401415U, 0xf94006a8U,
        0xf140051fU, 0x540001e0U, 0x52820009U, 0xcb080134U, 0xa94282a3U, 0x52800021U, 0xaa1403e2U,
        0x9400d451U, 0xeb14001fU, 0x540000e0U, 0xf9400268U, 0x528004c9U, 0xb9002909U, 0xf9400108U,
        0xaa1303e0U, 0xd63f0100U, 0xf94016a0U, 0x9400d43bU, 0xf94016a0U, 0x9400d436U, 0x34000140U,
        0xf9400268U, 0x528004c9U, 0xb9002909U, 0xf9400101U, 0xaa1303e0U, 0xa9427bfdU, 0xa9414ff4U,
        0xa8c357f6U, 0xd61f0020U, 0xa9427bfdU, 0xa9414ff4U, 0xa8c357f6U, 0xd65f03c0U,
    };
    std::vector<std::uint8_t> effective;
    for (const auto word : words) {
        for (unsigned shift = 0; shift < 32U; shift += 8U) effective.push_back(static_cast<std::uint8_t>(word >> shift));
    }
    const auto end = entry + static_cast<Address>(effective.size());
    constexpr std::array<std::uint8_t, 4> nop = {0x1f, 0x20, 0x03, 0xd5};
    while (effective.size() < words.size() * 4U + 64U) effective.insert(effective.end(), nop.begin(), nop.end());
    const auto request = AnalysisRequestView(
        "request.ghidra-provider.term-destination", std::string(64U, 'c'),
        std::string(kLanguageId), std::string(kCompilerSpecId),
        ImageIdentity{"image.ghidra-provider", "00000000-0000-0000-0000-000000000044", 0},
        FunctionIdentity{"function.ghidra-provider.term-destination", "_term_destination", entry, end, {{entry, end}}},
        ByteProvider({MemoryRegion{"__text", entry, "r-x", std::vector<std::uint8_t>(effective.size(), 0U), effective, {}}}),
        SymbolProvider({{"image.ghidra-provider", entry, "_term_destination", "function"}}),
        TypeHintProvider({}),
        AnalysisBudgets{1U << 20U, 65536U, 262144U, 8U * 1024U * 1024U, 10'000}, 4U
    );
    try {
        const auto result = provider.produce(request, CancellationToken{});
        validateStructuredResult(request, result);
        check(true, "_term_destination exports");
    } catch (const ContractError& error) {
        check(false, std::string("_term_destination refused: ") + error.what());
    }
}

// libjpeg `_j12init_color_converter` ends in `ldp x29, x30, …; br x1` (a tail call
// through cinfo->err->error_exit). Ghidra tried a jump table there and the export
// refused the function (native-provider-switch-case-label-invalid on cfa499950).
// Operation `decompile-document`: the reply carries the document and a
// native-structure-omitted warning; every structured-graph collection is empty.
void testDocumentOnlyRequest(NativeStructuredProvider& provider) {
    auto request = makeLoadStoreRequest();
    const auto full = provider.produce(request, CancellationToken{});
    request.documentOnly = true;
    try {
        const auto document = provider.produce(request, CancellationToken{});
        validateStructuredResult(request, document);
        check(document.pseudocodeDocument && full.pseudocodeDocument &&
                  document.pseudocodeDocument->text == full.pseudocodeDocument->text,
              "the document-only text equals the full request's document");
        check(document.operations.empty() && document.varnodes.empty() && document.instructions.empty() &&
                  document.tokens.empty() && document.types.empty() && !document.blockPartition,
              "a document-only reply carries no structured graph");
        check(std::any_of(document.warnings.begin(), document.warnings.end(), [](const auto& warning) {
            return warning.code == "native-structure-omitted";
        }), "the omission is reported");
        check(structuredResultEncodedSizeUpperBound(document) < structuredResultEncodedSizeUpperBound(full),
              "the document-only reply is smaller");
        bool rejected = false;
        auto fullRequest = request;
        fullRequest.documentOnly = false;
        try { validateStructuredResult(fullRequest, document); } catch (const ContractError&) { rejected = true; }
        check(rejected, "a full request does not accept a document-only result");
    } catch (const ContractError& error) {
        check(false, std::string("document-only request refused: ") + error.what());
    }
}

void testIndirectTailCallAfterEpilogue(NativeStructuredProvider& provider) {
    // stp x29, x30, [sp, #-16]!; mov x29, sp; ldr x1, [x0]; ldp x29, x30, [sp], #16; br x1
    const auto request = makeRequestForFunction("indirect-tail", "_indirectTail", {
        0xfd, 0x7b, 0xbf, 0xa9, 0xfd, 0x03, 0x00, 0x91, 0x01, 0x00, 0x40, 0xf9,
        0xfd, 0x7b, 0xc1, 0xa8, 0x20, 0x00, 0x1f, 0xd6,
    });
    try {
        const auto result = provider.produce(request, CancellationToken{});
        validateStructuredResult(request, result);
        check(findOperation(result, "CALLIND") != nullptr, "br after the epilogue becomes CALLIND");
        check(findOperation(result, "RETURN") != nullptr, "the tail call returns");
        check(findOperation(result, "BRANCHIND") == nullptr, "no indirect branch is left for switch recovery");
    } catch (const ContractError& error) {
        check(false, std::string("indirect tail call refused: ") + error.what());
    }
}

// Real witness: libjpeg 8.3.2 `_j12init_color_converter` (0x417c..0x4744) was refused
// with native-provider-switch-case-label-invalid on cfa499950. Its three jump tables
// live in __TEXT,__const at 0x587a4.. and are supplied as a read-only region.
void testJ12InitColorConverterSwitchLabels(NativeStructuredProvider& provider) {
    constexpr Address entry = 0x417cU;
    const std::vector<std::uint32_t> words = {
        0xa9bd57f6U, 0xa9014ff4U, 0xa9027bfdU, 0x910083fdU, 0xaa0003f4U, 0xf940f808U, 0xb9402109U, 0xb9405808U, 0x34000fa9U, 0x51003509U, 0x3100113fU, 0x54000102U, 0xf9400289U, 0x5280020aU, 0x2905212aU, 0xf9400288U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0xf9400688U, 0xf9400108U, 0x52800035U, 0xaa1403e0U, 0x52800021U, 0x52800602U, 0xd63f0100U, 0xaa0003f3U, 0xf9010e80U, 0x90000008U, 0x911d1108U, 0xf9000008U, 0xb9403e88U, 0x71003d1fU, 0x54001d08U, 0x1ac822a9U, 0x529ff88aU, 0x6a0a013fU, 0x54000c60U, 0xb9403a89U, 0x900002aaU, 0x911f114aU, 0xb8685948U, 0x6b08013fU, 0x540000e0U, 0xf9400288U, 0x52800149U, 0xb9002909U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0xb9406288U, 0x7100091fU, 0x540004edU, 0x71000d1fU, 0x54000b40U, 0x7100111fU, 0x54000ec0U, 0x7100151fU, 0x540016a1U, 0xf940fa88U, 0xb9402108U, 0x34000148U, 0xb9403e88U, 0x7100151fU, 0x540000e0U, 0xf9400288U, 0x52800389U, 0xb9002909U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0xb9405e88U, 0x7100111fU, 0x540000e0U, 0xf9400288U, 0x52800169U, 0xb9002909U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0xb9403e88U, 0x7100151fU, 0x54001540U, 0x7100111fU, 0x54000e41U, 0x90000008U, 0x911e7108U, 0xf9000268U, 0xb0000008U, 0x911f9108U, 0x140000a4U, 0x7100051fU, 0x54000e60U, 0x7100091fU, 0x54001221U, 0xf940fa88U, 0xb9402108U, 0x340001a8U, 0xb9403e88U, 0x7100091fU, 0x54000140U, 0x51001908U, 0x7100291fU, 0x540000e3U, 0xf9400288U, 0x52800389U, 0xb9002909U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0xb9405e88U, 0x71000d1fU, 0x540000e0U, 0xf9400288U, 0x52800169U, 0xb9002909U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0xb9403e88U, 0x52800029U, 0x9ac82129U, 0x5282188aU, 0xea0a013fU, 0x54000080U, 0x5280288aU, 0x8a0a0129U, 0xb5000fa9U, 0x7100091fU, 0x54001661U, 0xb0000008U, 0x9100d108U, 0x1400007aU, 0x7100311fU, 0x54fff0c1U, 0x17ffff8cU, 0x52800029U, 0x1ac82129U, 0x721c053fU, 0x54000f00U, 0xb9403a88U, 0x7100111fU, 0x54fff3c1U, 0x17ffffa3U, 0xf940fa88U, 0xb9402108U, 0x34000148U, 0xb9403e88U, 0x71000d1fU, 0x540000e0U, 0xf9400288U, 0x52800389U, 0xb9002909U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0xb9405e88U, 0x71000d1fU, 0x540000e0U, 0xf9400288U, 0x52800169U, 0xb9002909U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0xb9403e88U, 0x7100091fU, 0x54000d01U, 0x90000008U, 0x911e7108U, 0xf9000268U, 0xb0000008U, 0x911b7108U, 0x14000051U, 0xf940fa88U, 0xb9402108U, 0x34000148U, 0xb9403e88U, 0x7100111fU, 0x540000e0U, 0xf9400288U, 0x52800389U, 0xb9002909U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0xb9405e88U, 0x7100111fU, 0x540000e0U, 0xf9400288U, 0x52800169U, 0xb9002909U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0xb9403e88U, 0x7100111fU, 0x540006e0U, 0xf9400288U, 0x52800389U, 0xb9002909U, 0xf9400101U, 0xaa1403e0U, 0xa9427bfdU, 0xa9414ff4U, 0xa8c357f6U, 0xd61f0020U, 0xf940fa88U, 0xb9402108U, 0x34000148U, 0xb9403e88U, 0x7100051fU, 0x540000e0U, 0xf9400288U, 0x52800389U, 0xb9002909U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0xb9405e88U, 0x7100051fU, 0x540000e0U, 0xf9400288U, 0x52800169U, 0xb9002909U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0xb9403e88U, 0x7100051fU, 0x54000b80U, 0x7100091fU, 0x54000741U, 0x90000008U, 0x911e7108U, 0xf9000268U, 0x90000008U, 0x912f4108U, 0x14000010U, 0xb9403e89U, 0x6b09011fU, 0x540000a1U, 0xb9405e88U, 0xb9403a89U, 0x6b09011fU, 0x540000e0U, 0xf9400288U, 0x52800389U, 0xb9002909U, 0xf9400108U, 0xaa1403e0U, 0xd63f0100U, 0x90000008U, 0x91316108U, 0xf9000a68U, 0xa9427bfdU, 0xa9414ff4U, 0xa8c357f6U, 0xd65f03c0U, 0x71000d1fU, 0x540000a1U, 0xb9403a88U, 0x71000d1fU, 0x54ffe4a1U, 0x17ffff2aU, 0x7100051fU, 0x54000281U, 0xb9403a88U, 0x7100051fU, 0x54ffe3e1U, 0x17ffff24U, 0x51001909U, 0x7100253fU, 0x54000408U, 0x90000008U, 0x911e7108U, 0xf9000268U, 0x900002a8U, 0x911e9108U, 0x1000008aU, 0x3869690bU, 0x8b0b094aU, 0xd61f0140U, 0xb0000008U, 0x91069108U, 0x17ffffe1U, 0xb9403a88U, 0x7100011fU, 0x54ffe18dU, 0x17ffff11U, 0x51001909U, 0x7100253fU, 0x54000388U, 0x90000008U, 0x911e7108U, 0xf9000268U, 0x900002a8U, 0x911ee108U, 0x1000008aU, 0x3869690bU, 0x8b0b094aU, 0xd61f0140U, 0x90000008U, 0x91246108U, 0x17ffffceU, 0x71000d1fU, 0x54fff281U, 0x17ffffc9U, 0x51001908U, 0x7100251fU, 0x54fff208U, 0x900002a9U, 0x911eb929U, 0x1000008aU, 0x3868692bU, 0x8b0b094aU, 0xd61f0140U, 0x90000008U, 0x91387108U, 0x17ffffbfU, 0x71000d1fU, 0x54fff0a1U, 0x90000008U, 0x911d2108U, 0x17ffffbaU, 0xb0000008U, 0x91174108U, 0x17ffffb7U, 0xb0000008U, 0x910ee108U, 0x17ffffb4U, 0xb0000008U, 0x91131108U, 0x17ffffb1U, 0x90000008U, 0x912d1108U, 0x17ffffaeU, 0x90000008U, 0x9128b108U, 0x17ffffabU, 0x90000008U, 0x912ae108U, 0x17ffffa8U, 0x90000008U, 0x913f2108U, 0x17ffffa5U, 0xb0000008U, 0x91027108U, 0x17ffffa2U, 0x90000008U, 0x913bc108U, 0x17ffff9fU, 0xb0000008U, 0x910ab108U, 0x17ffff9cU, 0x90000008U, 0x913d7108U, 0x17ffff99U, 0x90000008U, 0x91224108U, 0x17ffff96U, 0x90000008U, 0x91268108U, 0x17ffff93U, 0x90000008U, 0x9136d108U, 0x17ffff90U, 0x90000008U, 0x913a1108U, 0x17ffff8dU
    };
    std::vector<std::uint8_t> effective;
    for (const auto word : words) {
        for (unsigned shift = 0; shift < 32U; shift += 8U) effective.push_back(static_cast<std::uint8_t>(word >> shift));
    }
    const auto end = entry + static_cast<Address>(effective.size());
    constexpr std::array<std::uint8_t, 4> nop = {0x1f, 0x20, 0x03, 0xd5};
    while (effective.size() < words.size() * 4U + 64U) effective.insert(effective.end(), nop.begin(), nop.end());
    // The three byte jump tables (adrp 0x58000 + #0x7a4 …) in __TEXT,__const.
    const std::vector<std::uint8_t> tables = {
        0x0d, 0x00, 0x00, 0x00, 0x50, 0x00, 0x00, 0x00, 0x16, 0x00, 0x00, 0x00, 0x48, 0x02, 0x00, 0x00, 0x00, 0xfe, 0xff, 0xff, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x4d, 0x32, 0x38, 0x2f, 0x00, 0x32, 0x38, 0x2f, 0x43, 0x00, 0x46, 0x2b, 0x2e, 0x28, 0x00, 0x2b, 0x2e, 0x28, 0x27, 0x00, 0x2d, 0x12, 0x15, 0x0c, 0x00, 0x12, 0x15, 0x0c, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x03, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x3f, 0x00, 0x45, 0x2d, 0x30, 0x2a, 0x00, 0x2d, 0x30, 0x2a, 0x2f, 0x00, 0x32, 0x20, 0x26, 0x1a, 0x00, 0x20, 0x26, 0x1a, 0x38, 0x00, 0x3b, 0x23, 0x26, 0x20, 0x00, 0x23, 0x26, 0x20, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x03, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x3f, 0x00, 0x45, 0x2d, 0x30, 0x2a, 0x00, 0x2d, 0x30, 0x2a, 0x2f, 0x00, 0x32, 0x20, 0x26, 0x1a, 0x00, 0x20, 0x26, 0x1a, 0x38, 0x00, 0x3b, 0x23, 0x26, 0x20, 0x00, 0x23, 0x26, 0x20, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x03, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0xc5, 0x58, 0x9f, 0x53, 0x42, 0x4b, 0x00, 0x40, 0x49, 0x32, 0xa3, 0x22, 0xa8, 0x11, 0xc5, 0x58, 0x21, 0x7b, 0xfc, 0x73, 0x62, 0x68, 0xc5, 0x58, 0xbf, 0x45, 0x0b, 0x30, 0x7e, 0x18, 0x9f, 0x53, 0xfc, 0x73, 0x41, 0x6d, 0x54, 0x62, 0x9f, 0x53, 0xb3, 0x41, 0x41, 0x2d, 0x12, 0x17, 0x42, 0x4b, 0x62, 0x68, 0x54, 0x62, 0x7e, 0x58, 0x42, 0x4b, 0x21, 0x3b, 0xba, 0x28, 0xc3, 0x14, 0x00, 0x40, 0xc5, 0x58, 0x9f, 0x53, 0x42, 0x4b, 0x00, 0x40, 0x49, 0x32, 0xa3, 0x22, 0xa8, 0x11, 0x49, 0x32, 0xbf, 0x45, 0xb3, 0x41, 0x21, 0x3b, 0x49, 0x32, 0x82, 0x27, 0x37, 0x1b, 0xe0, 0x0d, 0xa3, 0x22, 0x0b, 0x30, 0x41, 0x2d, 0xba, 0x28, 0xa3, 0x22, 0x37, 0x1b, 0xbf, 0x12, 0x8e, 0x09, 0xa8, 0x11, 0x7e, 0x18, 0x12, 0x17, 0xc3, 0x14, 0xa8, 0x11, 0xe0, 0x0d, 0x8e, 0x09, 0xdf, 0x04
    };
    const auto request = AnalysisRequestView(
        "request.ghidra-provider.j12-color-converter", std::string(64U, 'd'),
        std::string(kLanguageId), std::string(kCompilerSpecId),
        ImageIdentity{"image.ghidra-provider", "00000000-0000-0000-0000-000000000045", 0},
        FunctionIdentity{"function.ghidra-provider.j12-color-converter", "_j12init_color_converter", entry, end, {{entry, end}}},
        ByteProvider({MemoryRegion{"__text", entry, "r-x", std::vector<std::uint8_t>(effective.size(), 0U), effective, {}},
                      MemoryRegion{"__const", 0x58700U, "r--", tables, tables, {}}}),
        SymbolProvider({{"image.ghidra-provider", entry, "_j12init_color_converter", "function"}}),
        TypeHintProvider({}),
        AnalysisBudgets{1U << 20U, 65536U, 262144U, 8U * 1024U * 1024U, 10'000}, 4U
    );
    try {
        const auto result = provider.produce(request, CancellationToken{});
        validateStructuredResult(request, result);
        check(std::any_of(result.edges.begin(), result.edges.end(), [](const auto& edge) {
            return edge.kind == "switchCase";
        }), "_j12init_color_converter exports its recovered switches");
    } catch (const ContractError& error) {
        check(false, std::string("_j12init_color_converter refused: ") + error.what());
    }
}

// Real witness: libjpeg 8.3.2 `_jsimd_idct_islow_neon` (0x56c40..0x57444) exported on
// 42943ba58 (budget v2) but timed out at the client on 906c03128 (budget v3): its
// provider time is <1 s, but v3 let token metadata double the encoded reply.
void testJsimdIdctIslowNeonCost(NativeStructuredProvider& provider) {
    constexpr Address entry = 0x56c40U;
    const std::vector<std::uint32_t> words = {
        0xd10283ffU, 0xa9097bfdU, 0x910243fdU, 0xd0000048U, 0xf9400d08U, 0xf9400108U, 0xf81f83a8U, 0xfd400024U,
        0xfd400820U, 0xfd401033U, 0xfd401821U, 0xfd402034U, 0xfd402831U, 0xfd403036U, 0xfd403832U, 0xfd400010U,
        0xfd400802U, 0xfd401015U, 0xfd401803U, 0x0eb41e25U, 0x0eb21ec6U, 0x0ea61ca5U, 0x9e6600a9U, 0x90000028U,
        0x91194108U, 0xb4000789U, 0xfd403817U, 0xfd403018U, 0xfd402819U, 0xfd40201aU, 0x0c406505U, 0x0e739eb3U,
        0x0e769f15U, 0x0f57a2b6U, 0x0f552276U, 0x0f55a2b5U, 0x0f662275U, 0x0e649e04U, 0x0e749f50U, 0x0e648613U,
        0x0f1da673U, 0x2e708484U, 0x0f1da484U, 0x4eb386b0U, 0x6eb58673U, 0x4ea486d4U, 0x6eb68484U, 0x0e729ef2U,
        0x0e719f31U, 0x0e619c61U, 0x0e609c40U, 0x0e618642U, 0x0e608623U, 0x0f76a075U, 0x0f772055U, 0x0f47a063U,
        0x0f762043U, 0x0f75a242U, 0x0f56a236U, 0x0f67a037U, 0x0f46a018U, 0x0f456002U, 0x0f656036U, 0x0f656237U,
        0x0f456258U, 0x4eb58440U, 0x4ea386c1U, 0x4eb586e2U, 0x4ea38703U, 0x4eb08465U, 0x0f158cb5U, 0x4eb48445U,
        0x0f158cb6U, 0x4ea48425U, 0x0f158cb7U, 0x4eb38405U, 0x0f158cb8U, 0x6ea08660U, 0x0f158c19U, 0x6ea18480U,
        0x910123e9U, 0x0c000535U, 0x0f158c1aU, 0x6ea28680U, 0x1400002cU, 0x0ea01e66U, 0x0ea11cc6U, 0x0ea51cc5U,
        0x9e6600a9U, 0xb4002969U, 0x0c406505U, 0x0e739eb1U, 0x0e649e04U, 0x0f1da484U, 0x4ea41c90U, 0x0f662230U,
        0x4ea41c92U, 0x0f666232U, 0x4ea41c93U, 0x0f552233U, 0x0f556224U, 0x0e619c61U, 0x0e609c40U, 0x0f76a002U,
        0x0f772022U, 0x0f47a003U, 0x0f762023U, 0x4ea21c51U, 0x0f456011U, 0x4ea31c74U, 0x0f656034U, 0x0f672022U,
        0x0f462003U, 0x4eb08460U, 0x0f158c15U, 0x4eb38440U, 0x0f158c16U, 0x4ea48680U, 0x0f158c17U, 0x4eb28620U,
        0x0f158c18U, 0x6eb18640U, 0x0f158c19U, 0x6eb48480U, 0x910123e9U, 0x0c000535U, 0x0f158c1aU, 0x6ea28660U,
        0x0f158c1bU, 0x6ea38600U, 0x0f158c1cU, 0x910023e9U, 0x0c000539U, 0xfd400425U, 0xfd400c23U, 0xfd401435U,
        0xfd401c24U, 0xfd402433U, 0xfd402c27U, 0xfd403434U, 0xfd403c31U, 0xfd400412U, 0x0eb31ce0U, 0x0eb11e81U,
        0x0ea11c00U, 0x0ea31ea1U, 0x0ea41c21U, 0x0ea01c21U, 0x9e660029U, 0xb4000909U, 0xfd400c06U, 0xfd401c10U,
        0xfd401416U, 0x9e66000bU, 0x910123e9U, 0x91008129U, 0x910023eaU, 0x9100814aU, 0x0c406500U, 0x0e759ed5U,
        0xb400098bU, 0xfd402416U, 0xfd402c17U, 0xfd403418U, 0xfd403c19U, 0x0e749f14U, 0x0f52a298U, 0x0f5022b8U,
        0x0f50a294U, 0x0f6122b4U, 0x0e659e45U, 0x0e739ed2U, 0x0e658653U, 0x0f1da673U, 0x2e7284a5U, 0x0f1da4a5U,
        0x4eb38692U, 0x6eb48673U, 0x4ea58714U, 0x6eb884a5U, 0x0e719f31U, 0x0e679ee7U, 0x0e649e04U, 0x0e639cc3U,
        0x0e648626U, 0x0e6384f0U, 0x0f71a215U, 0x0f7220d5U, 0x0f42a210U, 0x0f7120d0U, 0x0f70a226U, 0x0f51a0f6U,
        0x0f62a097U, 0x0f41a078U, 0x0f406066U, 0x0f606096U, 0x0f6060f7U, 0x0f406238U, 0x4eb584c0U, 0x4eb086c1U,
        0x4eb586e2U, 0x4eb08703U, 0x4eb28464U, 0x0f158c95U, 0x4eb48444U, 0x0f158c96U, 0x4ea58424U, 0x0f158c97U,
        0x4eb38404U, 0x0f158c98U, 0x6ea08660U, 0x0f158c19U, 0x6ea184a0U, 0x0f158c1aU, 0x6ea28680U, 0x0f158c1bU,
        0x6ea38640U, 0x0f158c1cU, 0x0c000535U, 0x0c000559U, 0x14000037U, 0x0ea51c20U, 0x9e660009U, 0xb40019e9U,
        0x0e659e40U, 0x0f125400U, 0x4ea01c01U, 0x4ea01c02U, 0x4ea01c03U, 0x910123e9U, 0x91008129U, 0x0c000520U,
        0x910023e9U, 0x91008129U, 0x0c000520U, 0x14000028U, 0x0e659e45U, 0x0f1da4a5U, 0x4ea51ca7U, 0x0f6122a7U,
        0x4ea51cb1U, 0x0f6162b1U, 0x4ea51cb2U, 0x0f5022b2U, 0x0f5062a5U, 0x0e649e04U, 0x0e639cc3U, 0x0f71a066U,
        0x0f722086U, 0x0f42a070U, 0x0f712090U, 0x4ea61cd3U, 0x0f406073U, 0x4eb01e14U, 0x0f606094U, 0x0f622086U,
        0x0f412070U, 0x4ea78600U, 0x0f158c00U, 0x4eb284c4U, 0x0f158c81U, 0x4ea58684U, 0x0f158c82U, 0x4eb18664U,
        0x0f158c83U, 0x6eb38624U, 0x0f158c95U, 0x6eb484a4U, 0x0f158c96U, 0x6ea68644U, 0x0f158c97U, 0x6eb084e4U,
        0x0f158c98U, 0x0c000520U, 0x0c000555U, 0x0c406500U, 0x6d4793e3U, 0x0f52a065U, 0x6d459fe6U, 0x0f5020c5U,
        0x0f50a063U, 0x0f6120c3U, 0x6d46c3e6U, 0x6d44cbf1U, 0x0e7184d3U, 0x0f1da673U, 0x2e668626U, 0x0f1da4c6U,
        0x4ea38671U, 0x6ea38663U, 0x4ea584d3U, 0x6ea584c5U, 0x0e6484e6U, 0x0e708654U, 0x0f71a295U, 0x0f7220d5U,
        0x0f42a294U, 0x0f7120d4U, 0x0f70a086U, 0x0f51a216U, 0x0f62a0f7U, 0x0f41a258U, 0x0f406246U, 0x0f6060f6U,
        0x0f606217U, 0x0f406098U, 0x4eb584c4U, 0x4eb486c6U, 0x4eb586e7U, 0x4eb48710U, 0x0e714212U, 0x4e6540d2U,
        0x0e7340f4U, 0x4e634094U, 0x0e646063U, 0x4e676263U, 0x0e6660a4U, 0x4e706224U, 0x0f0e9e45U, 0x0f0e9e86U,
        0x0f0e9c63U, 0x0f0e9c84U, 0x0f04e407U, 0x2e271cb0U, 0x2e271cd1U, 0x2e271c72U, 0x2e271c87U, 0x0e113a03U,
        0x0e117a04U, 0x0e073a45U, 0x0e077a46U, 0x2a0303e8U, 0xa9402849U, 0x8b234129U, 0x8b23414aU, 0xa941304bU,
        0x0d206123U, 0x0d206943U, 0x8b23416aU, 0x8b234189U, 0x0d207143U, 0x6d43c3e7U, 0x0f52a0f1U, 0x6d41cff2U,
        0x0f502251U, 0x0f50a0e7U, 0x0f612247U, 0x6d42d3f2U, 0x6d40dbf5U, 0x0e758657U, 0x0f1da6f7U, 0x2e7286b2U,
        0x0f1da652U, 0x4ea786f5U, 0x6ea786f7U, 0x4eb18658U, 0x6eb18651U, 0x0e708667U, 0x0e7486d2U, 0x0f71a259U,
        0x0f7220f9U, 0x0f42a252U, 0x0f7120f2U, 0x0f70a207U, 0x0f51a29aU, 0x0f62a27bU, 0x0f41a2dcU, 0x0f4062c7U,
        0x0f60627aU, 0x0f60629bU, 0x0f40621cU, 0x4eb984f0U, 0x4eb28753U, 0x4eb98774U, 0x4eb28796U, 0x4eb586c0U,
        0x4eb18661U, 0x4eb88682U, 0x4eb78607U, 0x6eb086f0U, 0x6eb48712U, 0x6eb38631U, 0x6eb686b3U, 0x0d207923U,
        0x4e525a03U, 0x4e475842U, 0x4e415800U, 0x4e535a21U, 0x0f0e9c00U, 0x0f0e9c42U, 0x0f0e9c63U, 0x0f0e9c21U,
        0x0f04e404U, 0x2e241c00U, 0x2e241c42U, 0x2e241c63U, 0x2e241c21U, 0x0e023804U, 0x0e027805U, 0x0e013866U,
        0x0e017867U, 0xa9422849U, 0x8b080129U, 0x8b08014aU, 0xa943304bU, 0x8b08016bU, 0x8b080188U, 0x0d206124U,
        0x0d206944U, 0x0d207164U, 0x0d207904U, 0xf85f83a8U, 0xb0000049U, 0xf9400d29U, 0xf9400129U, 0xeb08013fU,
        0x54000c01U, 0xa9497bfdU, 0x910283ffU, 0xd65f03c0U, 0x0e649e00U, 0x0f125400U, 0x4ea01c01U, 0x4ea01c02U,
        0x4ea01c03U, 0x910123e9U, 0x0c000520U, 0x910023e9U, 0x0c000520U, 0x17fffed8U, 0x0c406500U, 0x6d4493e3U,
        0x0f1da463U, 0x4ea31c65U, 0x6d459fe6U, 0x0f6120c5U, 0x4ea31c70U, 0x0f6160d0U, 0x4ea31c71U, 0x0f5020d1U,
        0x0f5060c3U, 0x0f71a086U, 0x0f7220e6U, 0x0f42a092U, 0x0f7120f2U, 0x4ea61cd3U, 0x0f406093U, 0x4eb21e54U,
        0x0f6060f4U, 0x0f6220e6U, 0x0f412092U, 0x0e654244U, 0x4e634284U, 0x0e7140c7U, 0x4e704267U, 0x0e736210U,
        0x4e666230U, 0x0e746063U, 0x4e7260a3U, 0x0f0e9c84U, 0x0f0e9ce5U, 0x0f0e9e06U, 0x0f0e9c63U, 0x0f04e407U,
        0x2e271c84U, 0x2e271ca5U, 0x2e271cc6U, 0x2e271c63U, 0x0e053890U, 0x0e057891U, 0x0e0338d2U, 0x0e0378d3U,
        0x2a0303e8U, 0xa9402849U, 0x8b234129U, 0x8b23414aU, 0xa941304bU, 0x8b23416bU, 0x8b23418cU, 0x0d206130U,
        0x0d206950U, 0x0d207170U, 0x0d207990U, 0x6d4093e3U, 0x0f1da463U, 0x4ea31c65U, 0x6d419fe6U, 0x0f6120c5U,
        0x4ea31c70U, 0x0f6160d0U, 0x4ea31c71U, 0x0f5020d1U, 0x0f5060c3U, 0x0f71a086U, 0x0f7220e6U, 0x0f42a093U,
        0x0f7120f3U, 0x4ea61cd2U, 0x0f406092U, 0x4eb31e74U, 0x0f6060f4U, 0x0f6220e6U, 0x0f412093U, 0x4ea58660U,
        0x4ea38681U, 0x4eb184c2U, 0x4eb08647U, 0x6eb28610U, 0x6ea68632U, 0x6eb48471U, 0x6eb384b3U, 0x17ffff81U,
        0x94000473U,
    };
    std::vector<std::uint8_t> effective;
    for (const auto word : words) {
        for (unsigned shift = 0; shift < 32U; shift += 8U) effective.push_back(static_cast<std::uint8_t>(word >> shift));
    }
    const auto end = entry + static_cast<Address>(effective.size());
    // The image's next 64 bytes (the start of _jsimd_idct_2x2_neon) follow the function.
    constexpr std::array<std::uint32_t, 16> following = {
        0xad400420U, 0x3dc00c22U, 0x3dc01423U, 0x3dc01c24U, 0xad401805U, 0x3dc00c07U, 0x3dc01410U, 0x3dc01c11U,
        0x4e609ca0U, 0x4e619cc1U, 0x4e629ce2U, 0x4e639e03U, 0x4e649e24U, 0x0f1fa405U, 0x528e7f88U, 0x4e020d06U,
    };
    for (const auto word : following) {
        for (unsigned shift = 0; shift < 32U; shift += 8U) effective.push_back(static_cast<std::uint8_t>(word >> shift));
    }
    // __TEXT,__const tail with the IDCT constants at 0x5a650 (the table runs past the
    // section end into __cstring, as in the image).
    const std::vector<std::uint8_t> constants = {
        0x06, 0x03, 0x00, 0x42, 0x3f, 0x39, 0x33, 0x2d, 0x27, 0x24, 0x21, 0x38, 0x2d, 0x22, 0x17, 0x0c,
        0x06, 0x00, 0x7f, 0x77, 0x6c, 0x61, 0x56, 0x4b, 0x45, 0x3f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x31, 0x80, 0x45, 0x80, 0x5a, 0x00, 0x27, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x8e, 0x09, 0x84, 0xf3, 0x51, 0x11, 0x7e, 0x18, 0x33, 0xe3, 0xa1, 0x25, 0x0b, 0x30, 0xdf, 0xc4,
        0x3b, 0xc1, 0xb3, 0x41, 0xfd, 0xad, 0x54, 0x62, 0x80, 0x0a, 0x00, 0x35, 0x80, 0x6c, 0x80, 0x4e,
        0xcd, 0x1c, 0x51, 0x11, 0x03, 0x52, 0xc1, 0xec, 0x3e, 0x13, 0xb0, 0xef, 0xcf, 0x29, 0xa1, 0x25,
        0x25, 0x19, 0x30, 0xd6, 0x51, 0x10, 0xdc, 0xe6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x21, 0x3b, 0x82, 0xe7, 0x3e, 0xf9, 0x75, 0x2e, 0x79, 0xba, 0xf9, 0x21, 0xb0, 0xef, 0xc2, 0xec,
        0xcd, 0x1c, 0x03, 0x52, 0x00, 0x00, 0x00, 0x00, 0x6c, 0x69, 0x62, 0x6a, 0x70, 0x65, 0x67, 0x2d,
        0x74, 0x75, 0x72, 0x62, 0x6f, 0x20, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x20, 0x33, 0x2e,
        0x32, 0x2e, 0x30, 0x20, 0x28, 0x62, 0x75, 0x69, 0x6c, 0x64, 0x20, 0x32, 0x30, 0x32, 0x36, 0x30,
        0x36, 0x33, 0x30, 0x29, 0x00, 0x25, 0x73, 0x0a, 0x00, 0x42, 0x6f, 0x67, 0x75, 0x73, 0x20, 0x6d,
        0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x20, 0x63, 0x6f, 0x64, 0x65, 0x20, 0x25, 0x64, 0x00, 0x41,
        0x4c, 0x49, 0x47, 0x4e, 0x5f, 0x54, 0x59, 0x50, 0x45, 0x20, 0x69, 0x73, 0x20, 0x77, 0x72, 0x6f,
        0x6e, 0x67, 0x2c, 0x20, 0x70, 0x6c, 0x65, 0x61, 0x73, 0x65, 0x20, 0x66, 0x69, 0x78, 0x00, 0x4d,
        0x41, 0x58, 0x5f, 0x41, 0x4c, 0x4c, 0x4f, 0x43, 0x5f, 0x43, 0x48, 0x55, 0x4e, 0x4b, 0x20, 0x69,
    };
    std::vector<std::size_t> encodedSizes;
    std::vector<std::size_t> tokenCounts;
    for (const auto& [label, cap] : std::vector<std::pair<std::string, std::uint32_t>>{
             {"v2", 8U * 1024U * 1024U}, {"v3", 32U * 1024U * 1024U}}) {
        const auto request = AnalysisRequestView(
            "request.ghidra-provider.jsimd-idct-islow-" + label, std::string(64U, 'e'),
            std::string(kLanguageId), std::string(kCompilerSpecId),
            ImageIdentity{"image.ghidra-provider", "00000000-0000-0000-0000-000000000046", 0},
            FunctionIdentity{"function.ghidra-provider.jsimd-idct-islow", "_jsimd_idct_islow_neon", entry, end, {{entry, end}}},
            ByteProvider({MemoryRegion{"__text", entry, "r-x", std::vector<std::uint8_t>(effective.size(), 0U), effective, {}},
                          MemoryRegion{"__const", 0x5a600U, "r--", constants, constants, {}}}),
            SymbolProvider({{"image.ghidra-provider", entry, "_jsimd_idct_islow_neon", "function"}}),
            TypeHintProvider({}),
            AnalysisBudgets{1U << 20U, 65536U, 262144U, cap, 30'000}, 4U
        );
        try {
            const auto result = provider.produce(request, CancellationToken{});
            encodedSizes.push_back(structuredResultEncodedSizeUpperBound(result));
            tokenCounts.push_back(result.tokens.size());
        } catch (const ContractError& error) {
            check(false, "_jsimd_idct_islow_neon " + label + " refused: " + error.what());
        }
    }
    // Measured on the fixture: v2 7,441,791 bytes / 5,667 tokens; before the token
    // ceiling v3 grew to 14,680,187 bytes / 29,663 tokens.
    check(encodedSizes.size() == 2U && encodedSizes[0] == encodedSizes[1] && tokenCounts[0] == tokenCounts[1],
          "v3 does not grow token metadata past the v2 output cap");
    check(!encodedSizes.empty() && encodedSizes[0] <= 8U * 1024U * 1024U, "the reply stays within the v2 cap");
}

// Token metadata that cannot fit is omitted with a warning; the row keeps its
// complete graph and document instead of being refused (libjpeg `_encode_one_block`
// refused with native-provider-pseudocode-markup-output-exceeded on 906c03128).
void testTokenMetadataOmittedWhenItCannotFit(NativeStructuredProvider& provider) {
    auto request = makeLoadStoreRequest();
    request.budgets.maxOutputBytes = 64U * 1024U * 1024U;
    auto bounded = provider.produce(request, CancellationToken{});
    check(!bounded.tokens.empty(), "fixture has tokens with room");
    bounded.tokens.clear();
    bounded.warnings.push_back({
        .code = "native-pseudocode-token-metadata-omitted",
        .severity = "warning",
        .message = "Native token metadata did not fit the output bounds; the instruction and SSA graph and the "
                   "pseudocode text remain.",
        .sourceRanges = {{request.image.imageId, request.function.entryAddress, request.function.endAddressExclusive}},
    });
    request.budgets.maxOutputBytes = static_cast<std::uint32_t>(structuredResultEncodedSizeUpperBound(bounded));
    try {
        const auto result = provider.produce(request, CancellationToken{});
        check(result.tokens.empty(), "no token fits");
        check(std::any_of(result.warnings.begin(), result.warnings.end(), [](const auto& warning) {
            return warning.code == "native-pseudocode-token-metadata-omitted";
        }), "the omission is reported");
        check(result.pseudocodeDocument && !result.pseudocodeDocument->text.empty(), "the document remains");
        validateStructuredResult(request, result);
    } catch (const ContractError& error) {
        check(false, std::string("token omission refused the row: ") + error.what());
    }
}

// DP12/DP13 #674: the final-BL stop is scoped to that call site. An earlier call to
// the same callee keeps its continuation (the callee prototype is not made no-return).
void testFinalCallStopDoesNotCutEarlierCallsToTheSameCallee(NativeStructuredProvider& provider) {
    // bl +0x20; mov w0, #1; bl +0x18 (both to kEntryAddress + 0x20)
    const auto request = makeRequestForFunction(
        "final-call-repeat", "_finalCallRepeat",
        {0x08, 0x00, 0x00, 0x94, 0x20, 0x00, 0x80, 0x52, 0x06, 0x00, 0x00, 0x94},
        {SymbolRecord{"image.ghidra-provider", kEntryAddress + 0x20U, "_report", "function"}}
    );
    try {
        const auto result = provider.produce(request, CancellationToken{});
        validateStructuredResult(request, result);
        check(result.instructions.size() == 3U, "flow continues after the first call to the callee");
        check(result.calls.size() == 2U, "both calls to the same callee are published");
        check(findOperation(result, "RETURN") != nullptr, "flow stops at the final call");
        check(result.pseudocodeDocument &&
                  result.pseudocodeDocument->text.find("_report(") != result.pseudocodeDocument->text.rfind("_report("),
              "the document shows both calls");
    } catch (const ContractError& error) {
        check(false, std::string("repeated final callee refused: ") + error.what());
    }
}

// DP16 #727: `br x16` is a tail call only in the veneer shape; intra-function flow through
// x16 is never turned into a successful CALLIND + RETURN document.
void testX16BranchIsATailCallOnlyAsAVeneer(NativeStructuredProvider& provider) {
    // adrp x16, 0x1000; ldr x16, [x16, #0x10]; br x16
    const auto veneer = makeRequestForFunction("x16-veneer", "_veneer", {
        0x10, 0x00, 0x00, 0x90, 0x10, 0x0a, 0x40, 0xf9, 0x00, 0x02, 0x1f, 0xd6,
    });
    try {
        const auto result = provider.produce(veneer, CancellationToken{});
        validateStructuredResult(veneer, result);
        check(findOperation(result, "CALLIND") != nullptr, "the veneer branch is an indirect tail call");
        check(findOperation(result, "RETURN") != nullptr, "the veneer returns");
    } catch (const ContractError& error) {
        check(false, std::string("veneer refused: ") + error.what());
    }
    // adr x16, #8; br x16; mov w0, #1; ret: the branch stays inside the function.
    const auto intra = makeRequestForFunction("x16-intra", "_x16Intra", {
        0x50, 0x00, 0x00, 0x10, 0x00, 0x02, 0x1f, 0xd6, 0x20, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6,
    });
    try {
        const auto result = provider.produce(intra, CancellationToken{});
        validateStructuredResult(intra, result);
        check(findOperation(result, "CALLIND") == nullptr, "intra-function br x16 is not a tail call");
    } catch (const ContractError&) {
        check(true, "intra-function br x16 fails closed instead of a wrong tail call");
    }
}

// Derive both regressions from testSwitchCfg without moving any instruction,
// branch target, case body, epilogue, or table byte. ADR replaces the two-word
// ADRP/ADD table-address materialization, freeing a slot in the old four-word
// lookback window for an X30 load that does not prove a tail call.
[[nodiscard]] AnalysisRequestView makeX30SwitchRequest(bool earlyRestore) {
    auto bytes = switchMappedEffectiveBytes();
    const auto putWord = [&](std::size_t offset, std::uint32_t word) {
        for (unsigned shift = 0; shift < 32U; shift += 8U) {
            bytes[offset + shift / 8U] = static_cast<std::uint8_t>(word >> shift);
        }
    };
    putWord(0x14U, 0x100006e9U); // adr x9, table at 0x1000004e0 (PC = 0x100000404)
    // Zero writeback reloads the saved pair without releasing the frame: the
    // original case calls and common LDP/RET remain valid. ADR/LDRB/ADD separate
    // this restore from BR X10, so it cannot be an adjacent tail-call epilogue.
    putWord(0x18U, earlyRestore ? 0xa8c07bfdU : 0xf940001eU);
    // ldp x29,x30,[sp],#0 OR ldr x30,[x0]

    auto request = makeSwitchRequest();
    request.bytes = ByteProvider({MemoryRegion{
        "__text-mapped", kSwitchEntryAddress, "r-x",
        std::vector<std::uint8_t>(bytes.size(), 0U), std::move(bytes), {"patch000043"},
    }});
    return request;
}

void checkX30SwitchRecovery(NativeStructuredProvider& provider, bool earlyRestore) {
    const std::string name = earlyRestore ? "x30-switch-early-restore" : "x30-switch-non-frame-load";
    const auto request = makeX30SwitchRequest(earlyRestore);
    try {
        const auto result = provider.produce(request, CancellationToken{});
        validateStructuredResult(request, result);
        constexpr Address dispatch = 0x100000418U;
        const auto atDispatch = [](const OperationRecord& operation) {
            return std::any_of(operation.sourceRanges.begin(), operation.sourceRanges.end(),
                [](const SourceRange& range) {
                    return range.startAddress <= dispatch && dispatch < range.endAddressExclusive;
                });
        };
        const auto branch = std::find_if(result.operations.begin(), result.operations.end(),
            [&](const OperationRecord& operation) {
                return operation.opcode == "BRANCHIND" && atDispatch(operation);
            });
        check(branch != result.operations.end(), name + ": dispatch retains BRANCHIND");
        check(std::none_of(result.operations.begin(), result.operations.end(),
            [&](const OperationRecord& operation) {
                return operation.opcode == "CALLIND" && atDispatch(operation);
            }), name + ": dispatch has no CALLIND");
        const std::set<Address> expectedTargets = {
            0x10000041cU, 0x100000428U, 0x100000434U, 0x100000440U,
            0x10000044cU, 0x100000458U, 0x100000464U, 0x100000470U,
        };
        std::set<Address> actualTargets;
        std::size_t caseCount = 0U;
        for (const auto& edge : result.edges) {
            if (edge.kind != "switchCase") continue;
            ++caseCount;
            actualTargets.insert(edge.targetAddress);
            check(branch != result.operations.end() && edge.operationId == branch->id,
                  name + ": recovered case belongs to the dispatch BRANCHIND");
        }
        check(caseCount == expectedTargets.size() && actualTargets == expectedTargets,
              name + ": recovers all eight exact switch case targets");
    } catch (const ContractError& error) {
        check(false, name + ": unexpected refusal: " + error.what());
    }
}

void testX30NonFrameLoadPreservesRecoverableSwitch(NativeStructuredProvider& provider) {
    checkX30SwitchRecovery(provider, false);
}

void testX30NonAdjacentRestorePreservesRecoverableSwitch(NativeStructuredProvider& provider) {
    checkX30SwitchRecovery(provider, true);
}

void testFinalCallIsTreatedAsNoReturn(NativeStructuredProvider& provider) {
    // mov w0, #1; bl +0x20
    const auto request = makeRequestForFunction(
        "final-call", "_finalCallFunction",
        {0x20, 0x00, 0x80, 0x52, 0x08, 0x00, 0x00, 0x94},
        {SymbolRecord{"image.ghidra-provider", kEntryAddress + 0x24U, "___stack_chk_fail", "function"}}
    );
    const auto result = provider.produce(request, CancellationToken{});
    validateStructuredResult(request, result);
    check(result.instructions.size() == 2U, "final-call function decodes only its own words");
    check(findOperation(result, "CALL") != nullptr, "final BL stays a CALL");
    check(result.calls.size() == 1U && result.calls.front().targetAddress == kEntryAddress + 0x24U,
          "final call keeps its direct target");
    // Real witness: libjpeg 8.3.2 `_error_exit` (44 bytes at 0x585d4), which ends in
    // `bl _exit` and was refused with "Function flow out of bounds".
    {
        constexpr Address entry = 0x585d4U;
        const std::array<std::uint32_t, 11> words = {
            0xa9be4ff4U, 0xa9017bfdU, 0x910043fdU, 0xaa0003f3U, 0xf9400008U, 0xf9400908U,
            0xd63f0100U, 0xaa1303e0U, 0x97ff0be5U, 0x52800020U, 0x9400000aU,
        };
        std::vector<std::uint8_t> effective;
        for (const auto word : words) {
            for (unsigned shift = 0; shift < 32U; shift += 8U) {
                effective.push_back(static_cast<std::uint8_t>(word >> shift));
            }
        }
        const auto end = entry + static_cast<Address>(effective.size());
        constexpr std::array<std::uint8_t, 4> nop = {0x1f, 0x20, 0x03, 0xd5};
        while (effective.size() < words.size() * 4U + 64U) {
            effective.insert(effective.end(), nop.begin(), nop.end());
        }
        const auto witness = AnalysisRequestView(
            "request.ghidra-provider.error-exit", std::string(64U, 'b'),
            std::string(kLanguageId), std::string(kCompilerSpecId),
            ImageIdentity{"image.ghidra-provider", "00000000-0000-0000-0000-000000000043", 0},
            FunctionIdentity{"function.ghidra-provider.error-exit", "_error_exit", entry, end,
                {{entry, end}}},
            ByteProvider({MemoryRegion{"__text", entry, "r-x",
                std::vector<std::uint8_t>(effective.size(), 0U), effective, {}}}),
            SymbolProvider({{"image.ghidra-provider", entry, "_error_exit", "function"},
                            {"image.ghidra-provider", 0x1b588U, "_jpeg_destroy", "function"},
                            {"image.ghidra-provider", 0x58624U, "_exit", "function"}}),
            TypeHintProvider({}),
            AnalysisBudgets{4096, 256, 4096, 4U * 1024U * 1024U, 10'000}, 4U
        );
        const auto real = provider.produce(witness, CancellationToken{});
        validateStructuredResult(witness, real);
        check(real.instructions.size() == words.size(), "_error_exit decodes all 11 words");
        check(std::count_if(real.calls.begin(), real.calls.end(), [](const auto& call) {
            return call.kind == "direct";
        }) == 2, "_error_exit keeps both direct calls (_jpeg_destroy, _exit)");
    }
    // A call followed by RET still returns.
    const auto returning = provider.produce(makeRequestForFunction(
        "returning-call", "_returningCallFunction",
        {0x08, 0x00, 0x00, 0x94, 0xc0, 0x03, 0x5f, 0xd6}
    ), CancellationToken{});
    check(findOperation(returning, "RETURN") != nullptr, "a call before RET is not treated as no-return");
}

void testSparsePatchedBranchUsesFileBackedCave(NativeStructuredProvider& provider) {
    // The selected cave ends at +40, while sealed executable context supplies
    // the decoder's ordinary bounded lookahead beyond the final instruction.
    auto effective = std::vector<std::uint8_t>(104U, 0U);
    constexpr std::array<std::uint8_t, 4> nop = {0x1f, 0x20, 0x03, 0xd5};
    for (std::size_t offset = 0; offset < effective.size(); offset += 4U) {
        std::copy(nop.begin(), nop.end(), effective.begin() + static_cast<std::ptrdiff_t>(offset));
    }
    // b 0x1020; the cave returns 1. Both regions have original file-backed bytes.
    effective[0] = 0x08; effective[1] = 0x00; effective[2] = 0x00; effective[3] = 0x14;
    effective[32] = 0x20; effective[33] = 0x00; effective[34] = 0x80; effective[35] = 0x52;
    effective[36] = 0xc0; effective[37] = 0x03; effective[38] = 0x5f; effective[39] = 0xd6;
    const auto request = AnalysisRequestView(
        "request.ghidra-provider.sparse-cave", std::string(64U, 'a'),
        std::string(kLanguageId), std::string(kCompilerSpecId),
        ImageIdentity{"image.ghidra-provider", "00000000-0000-0000-0000-000000000042", kEntryAddress},
        FunctionIdentity{"function.ghidra-provider.sparse-cave", "_sparsePatchedCave",
            kEntryAddress, kEntryAddress + 40U,
            {{kEntryAddress, kEntryAddress + 4U}, {kEntryAddress + 32U, kEntryAddress + 40U}}},
        ByteProvider({MemoryRegion{"__text", kEntryAddress, "r-x",
            std::vector<std::uint8_t>(effective.size(), 0U), effective, {"patch000001"}}}),
        SymbolProvider({{"image.ghidra-provider", kEntryAddress, "_sparsePatchedCave", "function"}}),
        TypeHintProvider({}),
        AnalysisBudgets{4096, 256, 4096, 4U * 1024U * 1024U, 10'000}, 4U
    );
    const auto result = provider.produce(request, CancellationToken{});
    check(result.function == request.function, "sparse result preserves exact code-range identity");
    check(result.instructions.size() == 3U, "sparse result decodes only entry and cave words");
    check(std::any_of(result.instructions.begin(), result.instructions.end(), [](const auto& instruction) {
        return instruction.address == kEntryAddress + 32U;
    }), "sparse result contains effective cave instruction");
    for (const auto& region : result.regions) {
        for (const auto& source : region.sourceRanges) {
            check(source.endAddressExclusive <= kEntryAddress + 4U ||
                      source.startAddress >= kEntryAddress + 32U,
                  "sparse region provenance never claims omitted code-gap bytes");
        }
    }
    validateStructuredResult(request, result);
}

void testOutputBudgetV2PreservesWeightedResult(NativeStructuredProvider& provider) {
    const auto v1 = productAnalysisBudgetsV1();
    const auto v2 = productAnalysisBudgetsV2();
    check(v1.profileId == "native-product-budget-v1" && v1.maxOutputBytes == 1'048'576U,
          "v2 does not reinterpret the frozen v1 profile");
    check(v2.profileId == "native-product-budget-v2" && v2.maxOutputBytes == 8'388'608U,
          "v2 has an explicit identity and 8 MiB cap");
    check(v2.maxCodeBytes == v1.maxCodeBytes && v2.maxInstructions == v1.maxInstructions &&
              v2.maxOperations == v1.maxOperations &&
              v2.maxWallTimeMilliseconds == v1.maxWallTimeMilliseconds,
          "v2 changes only the output cap");
    const auto v3 = productAnalysisBudgetsV3();
    check(v3.profileId == "native-product-budget-v3" && v3.maxOutputBytes == 33'554'432U,
          "v3 has an explicit identity and 32 MiB cap");
    check(v3.maxCodeBytes == v1.maxCodeBytes && v3.maxInstructions == v1.maxInstructions &&
              v3.maxOperations == v1.maxOperations &&
              v3.maxWallTimeMilliseconds == v1.maxWallTimeMilliseconds,
          "v3 changes only the output cap");
    auto request = makeLoadStoreRequest();
    request.budgets = v1.analysisLimits();
    request.budgets.maxOutputBytes = 64U * 1024U * 1024U;
    const auto before = provider.produce(request, CancellationToken{});
    request.budgets = v2.analysisLimits();
    const auto after = provider.produce(request, CancellationToken{});
    check(structuredResultEncodedSizeUpperBound(before) == structuredResultEncodedSizeUpperBound(after),
          "v2 does not change weighted output arithmetic");
    check(before == after, "v2 preserves the complete native result when both caps admit it");
    check(after.pseudocodeDocument && after.pseudocodeDocument->isComplete &&
              !after.pseudocodeDocument->isTruncated,
          "v2 fixture has complete presentation");
    validateStructuredResult(request, after);
    request.budgets = v3.analysisLimits();
    check(provider.produce(request, CancellationToken{}) == before,
          "v3 preserves the complete native result when both caps admit it");
}

// Classify exceptions through the existing observer using hand-assembled
// mov w0, #42; ret and the ordinary NOP decoder lookahead from makeRequest().
void testDp13TypedNativeRefusals() {
    struct Case final {
        std::function<void()> raise;
        std::string_view expected;
    };
    const std::array cases = {
        Case{[] { throw ghidra::UnimplError("private-marker", 4); }, "native-provider-unimplemented-instruction"},
        Case{[] { throw ghidra::BadDataError("private-marker"); }, "native-provider-bad-instruction-data"},
        Case{[] { throw ghidra::DataUnavailError("private-marker"); }, "native-provider-data-unavailable"},
        Case{[] { throw ghidra::DuplicateFunctionError(ghidra::Address(), "private-marker"); }, "native-provider-duplicate-function"},
        Case{[] { throw ghidra::RecovError("private-marker"); }, "native-provider-recoverable-analysis-error"},
        Case{[] { throw ghidra::ParseError("private-marker"); }, "native-provider-parse-error"},
        Case{[] { throw ghidra::SleighError("private-marker"); }, "native-provider-sleigh-error"},
        Case{[] { throw ghidra::ParamUnassignedError("private-marker"); }, "native-provider-parameter-assignment-error"},
        Case{[] { throw ghidra::EvaluationError("private-marker"); }, "native-provider-evaluation-error"},
        Case{[] { throw ghidra::JumptableThunkError("private-marker"); }, "native-provider-jumptable-thunk-error"},
        Case{[] { throw ghidra::LowlevelError("private-marker"); }, "native-provider-native-error"},
        Case{[] { throw ghidra::LowlevelError("Flow exceeded maximum allowable instructions"); }, "native-provider-instruction-budget-exceeded"},
        Case{[] { throw ghidra::DecoderError("private-marker"); }, "native-provider-decoder-error"},
        Case{[] { throw std::bad_alloc(); }, "native-provider-allocation-failed"},
        Case{[] { throw std::runtime_error("private-marker"); }, "native-provider-execution-error"},
        Case{[] { throw 7; }, "native-provider-unknown-error"},
        Case{[] { throw ContractError("native-provider-test-sentinel"); }, "native-provider-test-sentinel"},
    };
    const auto request = makeRequest();
    for (const auto& item : cases) {
        auto observer = std::make_shared<GhidraProviderObserver>();
        observer->followFlowEntered = item.raise;
        auto configuration = makeConfiguration();
        configuration.observer = observer;
        const auto provider = makeGhidraProvider(configuration);
        const auto reason = expectContractError(
            [&] { (void)provider->produce(request, CancellationToken{}); },
            "DP13 typed refusal"
        );
        check(reason == item.expected, "DP13 raw provider keeps the exact typed slug");
        check(reason.find("private-marker") == std::string::npos,
              "DP13 never publishes third-party exception text");
        const auto backend = makeGhidraBackend(configuration);
        const auto backendReason = expectContractError(
            [&] { (void)backend->decompile(request, CancellationToken{}); },
            "DP13 backend refusal envelope"
        );
        check(backendReason == "structured provider execution failed",
              "DP13 does not change the public backend contract");
        check(lastSuppressedProviderFailureReason() == item.expected,
              "DP13 typed slug survives in the suppressed wire-detail channel");
    }
    // A fresh uninjected hand-assembled slice still follows the normal path.
    const auto provider = makeGhidraProvider(makeConfiguration());
    const auto result = provider->produce(request, CancellationToken{});
    validateStructuredResult(request, result);
    check(result.instructions.size() == 2U, "DP13 benign control retains both instructions");
}

void testRawProviderBudgetsFailClosed(NativeStructuredProvider& provider) {
    auto instructionRequest = makeRequest();
    instructionRequest.budgets.maxInstructions = 1U;
    const auto instructionMessage = expectContractError(
        [&] { (void)provider.produce(instructionRequest, CancellationToken{}); },
        "raw provider instruction budget"
    );
    check(
        instructionMessage == "native-provider-instruction-budget-exceeded",
        std::string("raw provider returns the exact stable instruction-budget slug; received ") +
            instructionMessage
    );

    auto operationRequest = makeRequest();
    operationRequest.budgets.maxOperations = 1U;
    const auto operationMessage = expectContractError(
        [&] { (void)provider.produce(operationRequest, CancellationToken{}); },
        "raw provider operation budget"
    );
    check(
        operationMessage == "native-provider-operation-budget-exceeded",
        std::string("raw provider returns the exact stable operation-budget slug; received ") +
            operationMessage
    );

    auto outputRequest = makeRequest();
    outputRequest.budgets.maxOutputBytes = 1U;
    const auto outputMessage = expectContractError(
        [&] { (void)provider.produce(outputRequest, CancellationToken{}); },
        "raw provider output budget"
    );
    check(
        outputMessage == "native-provider-output-budget-exceeded",
        std::string("raw provider returns the exact stable output-budget slug; received ") +
            outputMessage
    );
}

void testOutputBudgetDiagnostics(
    NativeStructuredProvider& provider,
    StructuredDecompilerBackend& backend
) {
    using Diagnostics = OutputBudgetDiagnostics;
    using Failure = Diagnostics::Failure;
    using Category = Diagnostics::Category;
    const auto sum = [](const Diagnostics& d) {
        return d.schemaReserveBytes + d.textOccurrenceBytes + d.distinctTextObjectBytes +
            d.distinctTextContentBytes + d.scalarBytes + d.recordBytes +
            d.containerBytes + d.instructionByteBytes;
    };
    const auto reject = [&](const AnalysisRequestView& request) -> std::optional<Diagnostics> {
        try {
            (void)provider.produce(request, CancellationToken{});
            check(false, "diagnostic fixture must reject its insufficient budget");
        } catch (const ContractError& error) {
            check(std::string_view(error.what()) == "native-provider-output-budget-exceeded",
                  "numeric diagnostics preserve the exact stable budget slug");
            check(error.outputBudgetDiagnostics().has_value(),
                  "meter failure carries typed numeric diagnostics");
            if (error.outputBudgetDiagnostics()) {
                const auto d = *error.outputBudgetDiagnostics();
                check(d.maximumBytes == request.budgets.maxOutputBytes,
                      "diagnostics retain the requested limit");
                check(d.usedBytes <= d.maximumBytes && sum(d) == d.usedBytes,
                      "accepted category charges exactly reconcile to the bounded used total");
                if (d.attemptedBytes) {
                    check(*d.attemptedBytes > d.maximumBytes - d.usedBytes,
                          "rejected charge or preflight exceeds remaining capacity");
                }
                return d;
            }
        } catch (...) {
            check(false, "diagnostic fixture must fail through ContractError");
        }
        return std::nullopt;
    };

    auto request = makeRequest();
    request.budgets.maxOutputBytes = 1U;
    if (const auto d = reject(request)) {
        check(d->usedBytes == 0U && d->schemaReserveBytes == 0U &&
                  d->failure == Failure::chargeExceedsLimit &&
                  d->attemptedCategory == Category::schemaReserve &&
                  d->attemptedBytes == 16384U,
              "constructor rejection reports zero accepted bytes and the refused schema reserve");
    }
    request.budgets.maxOutputBytes = 16384U;
    if (const auto d = reject(request)) {
        check(d->usedBytes == 16384U && d->schemaReserveBytes == 16384U &&
                  d->textOccurrenceBytes == 0U &&
                  d->attemptedCategory == Category::textOccurrences && d->attemptedBytes == 8U,
              "first occurrence rejection does not charge the refused occurrence");
    }
    request.budgets.maxOutputBytes = 16384U + 8U;
    if (const auto d = reject(request)) {
        check(d->textOccurrenceBytes == 8U && d->distinctTextObjectBytes == 0U &&
                  d->attemptedCategory == Category::distinctTextObjects && d->attemptedBytes == 16U,
              "object rejection retains the accepted occurrence without charging its object");
    }
    request.budgets.maxOutputBytes = 16384U + 8U + 16U;
    if (const auto d = reject(request)) {
        check(d->textOccurrenceBytes == 8U && d->distinctTextObjectBytes == 16U &&
                  d->distinctTextContentBytes == 0U &&
                  d->attemptedCategory == Category::distinctTextContent &&
                  d->attemptedBytes == request.requestId.size(),
              "content rejection preserves the original partial-text charging order");
    }

    // Independent model-v3 accounting for the constructor's ASCII identity
    // prefix. Exact capacity here must fail its non-consuming instruction
    // lower-bound preflight, rather than pretending those bytes were charged.
    std::set<std::string> distinct;
    std::size_t contentBytes = 0U;
    for (const auto& value : {request.requestId, request.requestSha256, request.image.imageId,
                              request.image.uuid, request.function.functionId, request.function.name}) {
        check(std::all_of(value.begin(), value.end(), [](unsigned char c) { return c < 0x80U; }),
              "diagnostic prefix fixture uses ASCII identities");
        if (distinct.insert(value).second) contentBytes += value.size();
    }
    const auto scalarBytes = 3U * 32U + request.function.codeRanges.size() * 2U * 32U;
    const auto containerBytes = request.function.codeRanges.size() * 16U;
    request.budgets.maxOutputBytes = 16384U + 6U * 8U + distinct.size() * 16U +
        contentBytes + scalarBytes + containerBytes;
    if (const auto d = reject(request)) {
        check(d->usedBytes == request.budgets.maxOutputBytes &&
                  d->textOccurrenceBytes == 6U * 8U &&
                  d->distinctTextObjectBytes == distinct.size() * 16U &&
                  d->distinctTextContentBytes == contentBytes &&
                  d->scalarBytes == scalarBytes && d->containerBytes == containerBytes &&
                  d->recordBytes == 0U && d->instructionByteBytes == 0U,
              "constructor prefix accounts for deduplicated text, scalars, and containers");
        check(d->failure == Failure::preflightExceedsLimit &&
                  d->attemptedCategory == Category::preflight &&
                  d->attemptedCount == request.effectiveFunctionBytes().size() / 4U &&
                  d->attemptedWidth == 164U,
              "instruction lower bound is identified as a non-consuming preflight");
    }

    const auto baselineRequest = makeLoadStoreRequest();
    const auto baseline = provider.produce(baselineRequest, CancellationToken{});
    const auto semanticBytes = structuredResultEncodedSizeUpperBound(withoutNativePresentation(baseline));
    check(semanticBytes > 0U, "diagnostic semantic fixture has a nonzero size");
    if (semanticBytes > 0U) {
        auto bounded = baselineRequest;
        bounded.budgets.maxOutputBytes = semanticBytes - 1U;
        if (const auto d = reject(bounded)) {
            check(d->recordBytes > 0U && d->instructionByteBytes > 0U &&
                      d->containerBytes > 0U && d->scalarBytes > 0U &&
                      d->distinctTextContentBytes > 0U,
                  "later semantic failure reports all weighted output categories");
        }
    }

    request.budgets.maxOutputBytes = 1U;
    try {
        (void)backend.decompile(request, CancellationToken{});
        check(false, "validated backend must reject the same output budget");
    } catch (const ContractError& error) {
        check(std::string_view(error.what()) == "structured provider execution failed" &&
                  lastSuppressedProviderFailureReason() == "native-provider-output-budget-exceeded",
              "backend keeps its generic outward message and original suppressed reason");
        check(error.outputBudgetDiagnostics().has_value() &&
                  error.outputBudgetDiagnostics()->usedBytes == 0U &&
                  error.outputBudgetDiagnostics()->attemptedBytes == 16384U,
              "numeric budget diagnostics survive the validated typed error boundary");
    } catch (...) {
        check(false, "validated diagnostic failure remains a ContractError");
    }
    check(!ContractError("unrelated-error").outputBudgetDiagnostics(),
          "ordinary contract failures do not invent budget diagnostics");
}

void testTraversalAndOutputBudgetBoundaries(NativeStructuredProvider& provider) {
    const auto baselineRequest = makeLoadStoreRequest();
    const auto baseline = provider.produce(baselineRequest, CancellationToken{});
    validateStructuredResult(baselineRequest, baseline);
    check(!baseline.operations.empty(),
          "budget-boundary fixture produces native operations");

    auto exactOperationRequest = makeLoadStoreRequest();
    exactOperationRequest.budgets.maxOperations = baseline.operations.size();
    const auto exactOperationResult = provider.produce(
        exactOperationRequest, CancellationToken{}
    );
    validateStructuredResult(exactOperationRequest, exactOperationResult);
    check(exactOperationResult.operations.size() == baseline.operations.size(),
          "native operation traversal accepts its exact operation-count bound");

    if (baseline.operations.size() > 1U) {
        auto oneUnderOperationRequest = makeLoadStoreRequest();
        oneUnderOperationRequest.budgets.maxOperations = baseline.operations.size() - 1U;
        const auto message = expectContractError(
            [&] {
                (void)provider.produce(oneUnderOperationRequest, CancellationToken{});
            },
            "native operation traversal one below its required bound"
        );
        check(message == "native-provider-operation-budget-exceeded",
              "operation traversal rejects one-under bounds with the stable operation slug");
    }

    const auto exactOutputBytes = structuredResultEncodedSizeUpperBound(baseline);
    check(exactOutputBytes > 0U,
          "multi-input fixture has a nonzero encoded structured-result bound");
    auto exactOutputRequest = makeLoadStoreRequest();
    exactOutputRequest.budgets.maxOutputBytes = exactOutputBytes;
    const auto exactOutputResult = provider.produce(exactOutputRequest, CancellationToken{});
    checkBoundedNativePresentation(exactOutputRequest, exactOutputResult, baseline, false);

    if (exactOutputBytes > 0U) {
        auto oneUnderOutputRequest = makeLoadStoreRequest();
        oneUnderOutputRequest.budgets.maxOutputBytes = exactOutputBytes - 1U;
        const auto oneUnderOutputResult = provider.produce(
            oneUnderOutputRequest, CancellationToken{}
        );
        checkBoundedNativePresentation(oneUnderOutputRequest, oneUnderOutputResult, baseline, true);
    }
}

void testEmptyEntryScaffoldIsAcceptedWithoutPublishingPhantomState(
    NativeStructuredProvider& provider
) {
    const auto request = makeLoopRequest();
    const auto result = provider.produce(request, CancellationToken{});
    validateStructuredResult(request, result);
    checkExactInstructionEvidence(request, result);
    checkBlockOperationOrdering(result);

    check(result.blockPartition.has_value(), "empty entry uses explicit final-CFG metadata");
    if (result.blockPartition) {
        const auto* entry = findBlock(result, result.blockPartition->entryBlockId);
        check(entry != nullptr && entry->startAddress == kEntryAddress && entry->operationIds.empty() &&
                  entry->predecessorEdgeIds.empty() && entry->successorEdgeIds.size() == 1U &&
                  entry->terminatorKind == "splice",
              "native empty entry is retained with actual coverage, no phantom operation, and one splice");
        check(!result.blockPartition->instructions.empty() &&
                  result.blockPartition->instructions.front().spans.front().blockId == result.blockPartition->entryBlockId &&
                  result.blockPartition->instructions.front().spans.front().operationCount == 0U,
              "native scaffold coverage is an explicit zero-operation ownership span");
        for (const auto& phi : result.phis) for (const auto& incoming : phi.incoming) {
            check(incoming.edgeId && incoming.sourceBlockId,
                  "retained entry scaffold gives each loop phi a real predecessor path");
        }
    }
    for (const auto& edge : result.edges) {
        check(findBlock(result, edge.sourceBlockId) != nullptr && edge.targetBlockId &&
                  findBlock(result, *edge.targetBlockId) != nullptr,
              "every final successor resolves to a retained native block");
    }

    checkFailClosedRequest(
        provider,
        // An unconditional B out of range is a tail call (DP10); a conditional
        // successor outside the function still fails closed.
        makeRequestForFunction(
            "out-of-range-successor",
            "_successorOutsideRequest",
            {0x00, 0x01, 0x00, 0xb4, 0xc0, 0x03, 0x5f, 0xd6}
        ),
        "native successor outside the caller-owned function"
    );
}

struct CP4VimBody final {
        std::string_view name;
        std::vector<std::uint32_t> words;
    };
[[nodiscard]] std::array<CP4VimBody, 8> ordinaryVimBodies() {
    return {{
        CP4VimBody{"vim_100000f1c", {
            0xd503237fU, 0xa9bc5ff8U, 0xa90157f6U, 0xa9024ff4U, 0xa9037bfdU, 0x9100c3fdU,
            0xd0001597U, 0x910322f7U, 0xb94002e8U, 0x7100051fU, 0x5400042bU, 0xaa0303f5U,
            0xaa0203f6U, 0xaa0103f3U, 0xaa0003f4U, 0x9401b325U, 0x34000120U, 0xaa1403e0U,
            0xaa1303e1U, 0xaa1603e2U, 0xaa1503e3U, 0x9400001dU, 0xb40002a0U, 0x52800035U,
            0x14000014U, 0xf0001408U, 0x912a6108U, 0xf9400908U, 0xb98002e9U, 0xd37df129U,
            0xd1002129U, 0xf8696908U, 0xf9400908U, 0x38736a96U, 0x38336a9fU, 0x52800035U,
            0x9100a100U, 0x52800001U, 0xaa1403e2U, 0x52800023U, 0x9401f828U, 0x38336a96U,
            0xb5000040U, 0x52800015U, 0xaa1503e0U, 0xa9437bfdU, 0xa9424ff4U, 0xa94157f6U,
            0xa8c45ff8U, 0xd65f0fffU
        }},
        CP4VimBody{"vim_10000112c", {
            0xb4000300U, 0xf9400008U, 0xb40002c8U, 0xd503237fU, 0xa9bc5ff8U, 0xa90157f6U,
            0xa9024ff4U, 0xa9037bfdU, 0x9100c3fdU, 0xf9400d09U, 0xb4000209U, 0xf9401115U,
            0xb40001d5U, 0xaa0403f3U, 0xaa0303f4U, 0xaa0203f6U, 0xaa1503e0U, 0xaa0103f7U,
            0x34000141U, 0xaa1603e1U, 0xaa1403e2U, 0x9402e04fU, 0x37f802c0U, 0x14000009U,
            0x12800000U, 0xd65f03c0U, 0x12800000U, 0x14000013U, 0xaa1603e1U, 0xaa1403e2U,
            0x9402e00eU, 0x37f801a0U, 0xb40001d3U, 0xf9000275U, 0x1400000cU, 0xaa1503e0U,
            0xaa1603e1U, 0xaa1403e2U, 0x34000097U, 0x9402e03dU, 0x37f80080U, 0x17fffff7U,
            0x9402e002U, 0x36fffea0U, 0xf94016b5U, 0xb5fffed5U, 0xa9437bfdU, 0xa9424ff4U,
            0xa94157f6U, 0xa8c45ff8U, 0xd50323ffU, 0xd65f03c0U
        }},
        CP4VimBody{"vim_100001aa0", {
            0xd503237fU, 0xa9bc5ff8U, 0xa90157f6U, 0xa9024ff4U, 0xa9037bfdU, 0x9100c3fdU,
            0xb9400808U, 0x11000509U, 0xb9000809U, 0xf940000aU, 0xb942194bU, 0x6b0b013fU,
            0x5400042aU, 0xaa0103f3U, 0xaa0003f4U, 0xd0001416U, 0x9129e2d6U, 0x52800717U,
            0xf941154aU, 0xf869d955U, 0xf9000a95U, 0x11000908U, 0x93407d08U, 0xf9400ac9U,
            0xb98002caU, 0x9b377d4aU, 0xd100e14aU, 0xf82a6928U, 0xb4000155U, 0xaa1503e0U,
            0x94005b48U, 0x39400008U, 0x340000c8U, 0x340001b3U, 0xaa1503e0U, 0x94005b43U,
            0x9401b190U, 0x34000120U, 0xb9400a88U, 0x11000509U, 0xb9000a89U, 0xf940028aU,
            0xb942194bU, 0x6b0b013fU, 0x54fffccbU, 0xd2800015U, 0xaa1503e0U, 0xa9437bfdU,
            0xa9424ff4U, 0xa94157f6U, 0xa8c45ff8U, 0xd65f0fffU
        }},
        CP4VimBody{"vim_100001d48", {
            0xd503237fU, 0xd10103ffU, 0xa9024ff4U, 0xa9037bfdU, 0x9100c3fdU, 0xaa0103f3U,
            0xaa0003f4U, 0x91000400U, 0x94005ab4U, 0xa90103e0U, 0x39400008U, 0x340000c8U,
            0x910043e0U, 0xd2800001U, 0x9400dc6aU, 0x340002c0U, 0xf9400be0U, 0x94005aabU,
            0xf9000be0U, 0x39400008U, 0x7101f51fU, 0x54000181U, 0x910063e0U, 0xaa1303e1U,
            0x940017aeU, 0x34000180U, 0x12800000U, 0x52800021U, 0xaa1303e2U, 0x9404b96eU,
            0xf9400be8U, 0x91000500U, 0x14000006U, 0xf90003f4U, 0xd0001460U, 0x911ccc00U,
            0x9408ef4fU, 0xd2800000U, 0xa9437bfdU, 0xa9424ff4U, 0x910103ffU, 0xd65f0fffU
        }},
        CP4VimBody{"vim_100001f58", {
            0xd503237fU, 0xa9be4ff4U, 0xa9017bfdU, 0x910043fdU, 0xaa0003f3U, 0x39400008U,
            0x7100f51fU, 0x54000161U, 0x39400668U, 0x7100f11fU, 0x540003e1U, 0x39400a68U,
            0x52800020U, 0x7100f11fU, 0x54000381U, 0xb9000020U, 0x52800060U, 0x14000019U,
            0xf0001240U, 0x9138ec00U, 0xaa0803e1U, 0x94065c9bU, 0xb40000c0U, 0x39400668U,
            0x7100f51fU, 0x54000061U, 0x52800040U, 0x1400000fU, 0x39400268U, 0x7100b91fU,
            0x54000121U, 0x39400668U, 0x7100b91fU, 0x540000c1U, 0x39400a68U, 0x52800069U,
            0x7100f51fU, 0x1a9f0120U, 0x14000004U, 0x52800000U, 0x14000002U, 0x52800020U,
            0xa9417bfdU, 0xa8c24ff4U, 0xd65f0fffU
        }},
        CP4VimBody{"vim_10000200c", {
            0xd503237fU, 0xd10083ffU, 0xa9017bfdU, 0x910043fdU, 0x39400008U, 0x7101991fU,
            0x5400016cU, 0x7100fd1fU, 0x5400024cU, 0x7100911fU, 0x540003c0U, 0x7100991fU,
            0x540005a1U, 0xf90003e0U, 0xf0001440U, 0x9112e000U, 0x14000028U, 0x7101d51fU,
            0x540001ecU, 0x71019d1fU, 0x54000300U, 0x7101d11fU, 0x54000461U, 0xd0001248U,
            0x91395d08U, 0x1400001cU, 0x7101011fU, 0x54000280U, 0x7101891fU, 0x54000381U,
            0xd0001248U, 0x91392508U, 0x14000015U, 0x7101d91fU, 0x54000220U, 0x7101dd1fU,
            0x540002a1U, 0xd0001248U, 0x91394108U, 0x1400000eU, 0xf90003e0U, 0xd0001440U,
            0x913e9400U, 0x1400000dU, 0xd0001248U, 0x91390908U, 0x14000007U, 0xf90003e0U,
            0xf0001440U, 0x911a8c00U, 0x14000006U, 0xd0001248U, 0x91396d08U, 0xa90003e8U,
            0xd0001440U, 0x913df400U, 0x9408ee8aU, 0xa9417bfdU, 0x910083ffU, 0xd65f0fffU
        }},
        CP4VimBody{"vim_100003e48", {
            0x39404408U, 0x34000048U, 0xd65f03c0U, 0xd503237fU, 0xa9bd57f6U, 0xa9014ff4U,
            0xa9027bfdU, 0x910083fdU, 0xaa0103f4U, 0xaa0003f3U, 0x52800028U, 0x39004408U,
            0x91008000U, 0x9403e9ddU, 0x9100e260U, 0x9403e9f0U, 0xf9402a60U, 0xb40001e0U,
            0xb9405a68U, 0x7100051fU, 0x5400014bU, 0xd2800015U, 0xf9402a68U, 0x8b151500U,
            0x9404bf38U, 0x910006b5U, 0xb9805a68U, 0xeb0802bfU, 0x54ffff4bU, 0xf9402a60U,
            0x9403e9c5U, 0xf9002a7fU, 0xf9403260U, 0xb40001e0U, 0xb9405e68U, 0x7100051fU,
            0x5400014bU, 0xd2800015U, 0xf9403268U, 0x8b151500U, 0x9404bf28U, 0x910006b5U,
            0xb9805e68U, 0xeb0802bfU, 0x54ffff4bU, 0xf9403260U, 0x9403e9b5U, 0xf900327fU,
            0x34000074U, 0x52800028U, 0x39004268U, 0xf9400268U, 0xb4000048U, 0xb900111fU,
            0x3900467fU, 0xa9427bfdU, 0xa9414ff4U, 0xa8c357f6U, 0xd50323ffU, 0xd65f03c0U
        }},
        CP4VimBody{"vim_100005694", {
            0xd503237fU, 0xa9bd57f6U, 0xa9014ff4U, 0xa9027bfdU, 0x910083fdU, 0xaa0103f3U,
            0x52800108U, 0xb9000028U, 0x3900103fU, 0xb40002e0U, 0xaa0003f5U, 0x97ffffcbU,
            0xb4000360U, 0x52800108U, 0xb9000268U, 0xf9000660U, 0xb9401808U, 0x11000508U,
            0xb9001808U, 0xb94002b4U, 0x7100029fU, 0x540001adU, 0xf9400aa0U, 0xaa1403e1U,
            0x9403e3a2U, 0xf9400668U, 0xf9000900U, 0xf9400668U, 0xf9400909U, 0xf100013fU,
            0x1a9403f4U, 0x14000004U, 0xf900067fU, 0x14000005U, 0xf9400668U, 0xb9000114U,
            0xf9400668U, 0xb9000514U, 0x52800020U, 0xa9427bfdU, 0xa9414ff4U, 0xa8c357f6U,
            0xd65f0fffU
        }},
    }};
}

// CP4 acceptance: the eight supplied ordinary arm64e bodies must all export
// validated final CFGs under the full action list, without retry/quality markers.
void testOrdinaryVimBodies() {
    struct FallbackEvent final {
        std::string originalReason;
        std::string outcome;
    };
    std::vector<FallbackEvent> fallbackEvents;
    auto observer = std::make_shared<GhidraProviderObserver>();
    observer->actionProfileFallback = [&](std::string_view reason, std::string_view outcome) {
        fallbackEvents.push_back({std::string(reason), std::string(outcome)});
    };
    auto configuration = makeConfiguration();
    configuration.observer = observer;
    const auto providerOwner = makeGhidraProvider(std::move(configuration));
    auto& provider = *providerOwner;
    {
        // mov x0, #-1; ret: COPY of the 64-bit constant 0xffffffffffffffff, whose
        // offset + size exceeded 2^64 under the old storage check.
        const auto request = makePacRequest("minus-one", {0x9280'0000U, 0xd65f'03c0U});
        const auto result = produceOrFail(
            [&] { return provider.produce(request, CancellationToken{}); },
            "64-bit constant -1"
        );
        if (result) {
            validateStructuredResult(request, *result);
            const bool hasWrappedConstant = std::any_of(
                result->varnodes.begin(), result->varnodes.end(),
                [](const VarnodeRecord& varnode) {
                    return varnode.offset == 0xffff'ffff'ffff'ffffULL && varnode.sizeBytes == 8U;
                }
            );
            check(hasWrappedConstant, "the -1 constant is exported at its native offset");
        }
    }
    {
        // The full action list removes this branch-only block. The instruction
        // must remain explicit in the source-ownership map, not force a re-run.
        const auto request = makePacRequest("branch-only-block", {
            0xb400'0040U, // cbz x0, 0x1008
            0x1400'0003U, // b 0x1010
            0xd280'0040U, // mov x0, #2
            0xd65f'03c0U, // ret
            0xd280'0020U, // mov x0, #1
            0xd65f'03c0U, // ret
        });
        fallbackEvents.clear();
        std::string outcome = "ok";
        try {
            const auto result = provider.produce(request, CancellationToken{});
            validateStructuredResult(request, result);
            check(result.warnings.empty(), "full-quality projection carries no fallback marker");
        } catch (const ContractError& error) {
            outcome = error.what();
        }
        const std::string fallbackOutcome = fallbackEvents.empty()
            ? "-"
            : fallbackEvents.front().originalReason + "->" + fallbackEvents.front().outcome;
        std::cout << "ordinary-vim-probe synthetic_branch_only_block path="
                  << (fallbackEvents.empty() ? "full" : "fallback") << " outcome=" << outcome
                  << " fallback=" << fallbackOutcome << '\n';
        check(fallbackEvents.empty() && outcome == "ok",
              "the branch-only block decompiles under the full action list");
    }
    const auto bodies = ordinaryVimBodies();
    for (const auto& body : bodies) {
        const auto request = makePacRequest(std::string(body.name), body.words);
        fallbackEvents.clear();
        std::string outcome = "ok";
        bool marker = false;
        try {
            const auto result = provider.produce(request, CancellationToken{});
            validateStructuredResult(request, result);
            marker = std::any_of(
                result.warnings.begin(), result.warnings.end(),
                [](const DiagnosticRecord& warning) {
                    return warning.code == "native-action-profile-block-preserving-fallback" &&
                        warning.severity == "information" && warning.sourceRanges.empty() &&
                        warning.message.starts_with("actionProfile: block-preserving-fallback;");
                }
            );
            check(result.warnings.size() == (marker ? 1U : 0U),
                  "the fallback marker is the only provider diagnostic");
        } catch (const ContractError& error) {
            outcome = error.what();
        } catch (const std::exception& error) {
            ++failures;
            outcome = std::string("std::exception: ") + error.what();
        }
        check(fallbackEvents.size() <= 1U, "the fallback runs at most once per function");
        const std::string path = fallbackEvents.empty() ? "full" : "fallback";
        const std::string fallbackOutcome = fallbackEvents.empty()
            ? "-"
            : fallbackEvents.front().originalReason + "->" + fallbackEvents.front().outcome;
        std::cout << "ordinary-vim-probe " << body.name << " path=" << path
                  << " outcome=" << outcome << " fallback=" << fallbackOutcome
                  << " marker=" << (marker ? 1 : 0) << '\n';
        check(outcome.find("overflows the unsigned 64-bit address space") == std::string::npos,
              "ordinary vim bodies no longer fail on wrapped varnode offsets");
        check(outcome == "ok", std::string(body.name) + " must decompile successfully");
        check(path == "full" && fallbackEvents.empty() && !marker,
              std::string(body.name) + " must use full actions without a fallback marker");
    }
}


void testRewrittenZeroOperationBlock(NativeStructuredProvider& provider) {
    const auto request = makeLoopRequest();
    const auto result = produceOrFail(
        [&] { return provider.produce(request, CancellationToken{}); },
        "explicit native zero-operation entry scaffold"
    );
    if (!result) return;
    validateStructuredResult(request, *result);
    check(std::any_of(result->blocks.begin(), result->blocks.end(),
                     [](const BlockRecord& b) { return b.operationIds.empty(); }),
          "a real empty native entry block is retained explicitly");
    check(result->warnings.empty(), "zero-operation block uses full actions");
}

void testRewrittenMultiOwnerInstruction(NativeStructuredProvider& provider) {
    // cmp w0,#0; csel w0,w1,w2,eq; ret. Do not alter the SLEIGH csel lift.
    const auto request = makePacRequest("three-block-csel", {
        0x7100'001fU, 0x1a82'0020U, 0xd65f'03c0U,
    });
    const auto result = produceOrFail(
        [&] { return provider.produce(request, CancellationToken{}); }, "three-block csel"
    );
    if (!result) return;
    validateStructuredResult(request, *result);
    std::set<std::string> owners;
    for (const auto& op : result->operations) {
        if (std::any_of(op.sourceRanges.begin(), op.sourceRanges.end(), [](const SourceRange& r) {
            return r.startAddress == kEntryAddress + 4U;
        })) owners.insert(op.blockId);
    }
    check(owners.size() == 3U, "one csel instruction retains three distinct final block owners");
    check(result->warnings.empty(), "multi-owner instruction uses full actions");
}

void testStandaloneAutibsp(NativeStructuredProvider& provider) {
    const auto request = makePacRequest("standalone-autibsp", {0xd503'23ffU, 0xd65f'03c0U});
    const auto result = produceOrFail(
        [&] { return provider.produce(request, CancellationToken{}); }, "standalone autibsp; ret"
    );
    if (!result) return;
    validateStructuredResult(request, *result);
    check(result->instructions.size() == 2U && result->instructions.front().mnemonic == "autibsp",
          "authentication and return remain distinct decoded instructions");
    check(std::any_of(result->operations.begin(), result->operations.end(), [](const OperationRecord& op) {
        return op.userOperationName == "AuthIB" && !op.outputVarnodeId;
    }), "standalone authentication is retained without inventing an output");
    check(result->warnings.empty(), "standalone authentication uses full actions");
}


void testPacOutputEffects(NativeStructuredProvider& provider) {
    const auto request = makePacOutputRequest();
    const auto result = provider.produce(request, CancellationToken{});
    validateStructuredResult(request, result);
    checkExactInstructionEvidence(request, result);
    checkBlockOperationOrdering(result);

    std::vector<std::string> transformedNames;
    std::size_t authenticatedReturns = 0U;
    for (const auto& operation : result.operations) {
        if (operation.opcode == "CALLOTHER") {
            check(operation.userOperationName.has_value(),
                  "every CALLOTHER exports an exact attested user-operation name");
        } else {
            check(!operation.userOperationName.has_value(),
                  "non-CALLOTHER operations never export a user-operation name");
            check(operation.authenticationEffect == AuthenticationEffect{},
                  "ordinary operations retain the closed none authentication effect");
        }
        if (operation.authenticationEffect.kind ==
            AuthenticationEffectKind::transformedOutput) {
            check(operation.userOperationName.has_value(),
                  "transformed PAC effect has exact user-operation identity");
            if (operation.userOperationName) {
                transformedNames.push_back(*operation.userOperationName);
                checkTransformedUserOperation(result, operation, *operation.userOperationName);
            }
        } else if (operation.userOperationName == "AuthIA" &&
                   operation.authenticationEffect.kind ==
                       AuthenticationEffectKind::authenticatedControlTransferWithoutTransformedTarget) {
            ++authenticatedReturns;
            checkOutputlessAuthenticationEffect(
                result,
                operation,
                AuthenticationEffectKind::authenticatedControlTransferWithoutTransformedTarget
            );
        }
    }
    std::sort(transformedNames.begin(), transformedNames.end());
    auto expectedNames = std::vector<std::string>{
        "AuthDB", "AuthDB", "AuthIA", "pacia", "pacia", "pacga",
        "pacib", "pacib", "paciza", "pacizb", "xpac", "xpac",
    };
    std::sort(expectedNames.begin(), expectedNames.end());
    check(transformedNames == expectedNames,
          "standalone register/stack signing, authentication, strip, and generic PAC forms export exact identities");
    check(authenticatedReturns == 1U,
          "terminal RETAA exports one outputless authenticated-control effect");
}

void testPacMemoryEffects(NativeStructuredProvider& provider) {
    const auto request = makePacMemoryRequest();
    const auto result = provider.produce(request, CancellationToken{});
    validateStructuredResult(request, result);
    checkExactInstructionEvidence(request, result);

    for (const auto name : {std::string_view("AuthDA"), std::string_view("AuthDB")}) {
        const auto operations = findUserOperations(result, name);
        check(operations.size() == 1U,
              "LDRAA/LDRAB exports exactly one attested outputless authentication userop");
        if (operations.size() == 1U) {
            checkOutputlessAuthenticationEffect(
                result,
                *operations.front(),
                AuthenticationEffectKind::authenticatedMemoryAccessWithoutTransformedAddress
            );
        }
    }
    check(std::count_if(
              result.operations.begin(), result.operations.end(),
              [](const OperationRecord& operation) { return operation.opcode == "LOAD"; }
          ) == 2,
          "authenticated loads preserve the two governed LOAD operations");
}

void testPacControlEffects(NativeStructuredProvider& provider) {
    struct Fixture final {
        std::string_view suffix;
        std::vector<std::uint32_t> words;
        std::string_view expectedUserOperation;
        std::size_t expectedAuthenticatedOperations;
    };
    const std::array fixtures = {
        Fixture{"braa", {0xaa02'03e0U, 0x9100'03e1U, 0xd71f'0801U}, "AuthIA", 1U},
        Fixture{"brab", {0xaa02'03e0U, 0x9100'03e1U, 0xd71f'0c01U}, "AuthIB", 1U},
        Fixture{"blraa-retaa", {0xaa00'03e1U, 0x9100'03e2U, 0xd73f'0822U, 0xd65f'0bffU}, "AuthIA", 2U},
        Fixture{"blrab-retab", {0xaa00'03e3U, 0x9100'03e4U, 0xd73f'0c64U, 0xd65f'0fffU}, "AuthIB", 2U},
        Fixture{"retaa", {0xaa00'03feU, 0xd65f'0bffU}, "AuthIA", 1U},
        Fixture{"retab", {0xaa00'03feU, 0xd65f'0fffU}, "AuthIB", 1U},
        Fixture{"eretaa", {0xd100'43ffU, 0xd69f'0bffU}, "AuthIA", 1U},
        Fixture{"eretab", {0xd100'43ffU, 0xd69f'0fffU}, "AuthIB", 1U},
    };

    for (const auto& fixture : fixtures) {
        const auto request = makePacRequest(std::string(fixture.suffix), fixture.words);
        const auto result = provider.produce(request, CancellationToken{});
        validateStructuredResult(request, result);
        checkExactInstructionEvidence(request, result);
        const auto operations = findUserOperations(result, fixture.expectedUserOperation);
        check(operations.size() == fixture.expectedAuthenticatedOperations,
              "authenticated branch/call/return fixture exports every governed Auth operation");
        for (const auto* operation : operations) {
            checkOutputlessAuthenticationEffect(
                result,
                *operation,
                AuthenticationEffectKind::authenticatedControlTransferWithoutTransformedTarget
            );
        }
    }

    using Opcode = detail::PacCompanionOpcode;
    using Operation = detail::PacCompanionOperation;
    using Descriptor = detail::PacCompanionDescriptor;
    const auto classifyError = [&](Descriptor descriptor, std::string_view scenario) {
        return expectContractError(
            [&] { (void)detail::classifyPacCompanionShape(descriptor); }, scenario
        );
    };
    const auto auth = [](std::vector<std::optional<std::uintptr_t>> inputs) {
        return Operation{Opcode::other, std::nullopt, std::move(inputs), false};
    };

    check(classifyError(
              Descriptor{"AuthIA", "braa", 0, {auth({0U, 1U})}},
              "governed CALLOTHER with wrong arity"
          ) == "native-provider-pac-input-shape-invalid",
          "PAC control classification requires the exact governed CALLOTHER arity");
    check(classifyError(
              Descriptor{"AuthIA", "braa", 0, {auth({0U, std::nullopt, 2U})}},
              "governed CALLOTHER with null authenticated operand"
          ) == "native-provider-pac-input-shape-invalid",
          "PAC control classification requires a non-null authenticated operand");
    check(classifyError(
              Descriptor{
                  "AuthIA", "braa", 0,
                  {auth({0U, 1U, 2U}), Operation{Opcode::branchIndirect, std::nullopt,
                                                {3U, 1U}, false}}
              },
              "unrelated target with authenticated value in a non-target slot"
          ) == "native-provider-pac-companion-value-mismatch",
          "branch classification compares only the defined target input slot");

    const auto copiedTarget = detail::classifyPacCompanionShape(Descriptor{
        "AuthIA", "braa", 0,
        {
            auth({0U, 1U, 2U}),
            Operation{Opcode::copy, 3U, {1U}, false},
            Operation{Opcode::branchIndirect, std::nullopt, {3U, 9U}, false},
        }
    });
    check(copiedTarget == detail::PacCompanionKind::authenticatedControlTransfer,
          "defined target slot may consume the authenticated value through bounded COPY ancestry");

    Descriptor overlongCopyChain{"AuthIA", "braa", 0, {auth({0U, 1U, 2U})}};
    for (std::uintptr_t value = 3U; value < 69U; ++value) {
        overlongCopyChain.operations.emplace_back(Operation{
            Opcode::copy,
            value,
            {value == 3U ? std::optional<std::uintptr_t>{1U}
                          : std::optional<std::uintptr_t>{value - 1U}},
            false,
        });
    }
    overlongCopyChain.operations.emplace_back(
        Operation{Opcode::callIndirect, std::nullopt, {68U}, false}
    );
    check(classifyError(
              std::move(overlongCopyChain), "overlong same-instruction COPY ancestry"
          ) == "native-provider-pac-companion-value-mismatch",
          "authenticated target COPY ancestry is capped at the governed depth");

    check(classifyError(
              Descriptor{"AuthIA", "retaa", 0, {auth({0U, 1U})}},
              "sealed RETAA with incomplete CALLOTHER shape"
          ) == "native-provider-pac-input-shape-invalid",
          "sealed authenticated return qualification is conditional on complete input shape");
    check(classifyError(
              Descriptor{"AuthIA", "retaa", 0, {auth({0U, 1U, 2U})}},
              "sealed RETAA without subsequent return"
          ) == "native-provider-pac-companion-value-mismatch",
          "sealed authenticated return requires a subsequent return companion");
    check(classifyError(
              Descriptor{
                  "AuthIB", "retab", 0,
                  {
                      auth({0U, 1U, 2U}),
                      Operation{Opcode::return_, std::nullopt, {9U}, false},
                  }
              },
              "sealed RETAB with wrong-target return"
          ) == "native-provider-pac-companion-value-mismatch",
          "sealed authenticated return rejects a return to an unrelated target");
    const auto sealedCopiedReturn = detail::classifyPacCompanionShape(Descriptor{
        "AuthIA", "retaa", 1,
        {
            Operation{Opcode::copy, 1U, {7U}, false},
            auth({0U, 1U, 2U}),
            Operation{Opcode::copy, 3U, {1U}, false},
            Operation{Opcode::return_, std::nullopt, {3U}, false},
        }
    });
    check(sealedCopiedReturn == detail::PacCompanionKind::authenticatedControlTransfer,
          "raw RETAA Auth-to-COPY-to-RETURN shape qualifies exactly");
    check(classifyError(
              Descriptor{
                  "AuthIA", "eretaa", 1,
                  {
                      auth({0U, 1U, 2U}),
                      auth({0U, 1U, 2U}),
                      Operation{Opcode::return_, std::nullopt, {1U}, false},
                  }
              },
              "ERET authentication without preceding ExceptionReturn producer"
          ) == "native-provider-pac-exception-return-order-invalid",
          "ERET PAC classification requires ExceptionReturn then Auth(pc) then return");
    check(classifyError(
              Descriptor{
                  "AuthIA", "eretaa", 1,
                  {
                      Operation{Opcode::other, 1U, {0U}, true},
                      auth({0U, 1U, 2U}),
                  }
              },
              "ERET authentication without subsequent return"
          ) == "native-provider-pac-companion-value-mismatch",
          "sealed exception return requires a subsequent return companion");
    check(classifyError(
              Descriptor{
                  "AuthIB", "eretab", 1,
                  {
                      Operation{Opcode::other, 1U, {0U}, true},
                      auth({0U, 1U, 2U}),
                      Operation{Opcode::return_, std::nullopt, {9U}, false},
                  }
              },
              "ERET authentication with wrong subsequent return target"
          ) == "native-provider-pac-companion-value-mismatch",
          "sealed exception return rejects a return to an unrelated target");
    const auto sealedExceptionReturn = detail::classifyPacCompanionShape(Descriptor{
        "AuthIA", "eretaa", 1,
        {
            Operation{Opcode::other, 1U, {0U}, true},
            auth({0U, 1U, 2U}),
            Operation{Opcode::return_, std::nullopt, {1U}, false},
        }
    });
    check(sealedExceptionReturn == detail::PacCompanionKind::authenticatedControlTransfer,
          "raw ERETAA ExceptionReturn-to-Auth-to-RETURN shape qualifies exactly");
}

void testHiddenPacProfileCannotBeSelectedByEnvironment(NativeStructuredProvider& provider) {
    const auto request = makePacRequest(
        "hidden-profile-contrast",
        {0xd280'0020U, 0x9100'03e1U, 0xdac1'0020U, 0xd65f'03c0U}
    );
    const auto result = provider.produce(request, CancellationToken{});
    const auto operations = findUserOperations(result, "pacia");
    check(operations.size() == 1U,
          "production always uses the sealed visible/clobber PAC profile");
    if (operations.size() == 1U) {
        checkTransformedUserOperation(result, *operations.front(), "pacia");
    }

    const std::array stagedVariants = {
        std::pair{0x0000'0000U, ArchitectureVariant::arm64},
        std::pair{0x8000'0002U, ArchitectureVariant::arm64e},
    };
    for (const auto& [rawSubtype, expectedVariant] : stagedVariants) {
        const auto hidden = detail::observeHiddenPacProfileForTesting(request, rawSubtype);
        check(hidden.target.normalizedVariant == expectedVariant,
              "qualification uses the real target-normalization seam for each staged variant");
        check(std::find(hidden.hiddenOperations.begin(), hidden.hiddenOperations.end(), "pacia") ==
                  hidden.hiddenOperations.end(),
              "qualification-only ShowPAC=0 removes PAC userops for both staged variants");
        check(std::find(hidden.visibleOperations.begin(), hidden.visibleOperations.end(), "pacia") !=
                  hidden.visibleOperations.end(),
              "qualification-only visible profile retains the PAC userop");
        check(hidden.hiddenOperations != hidden.visibleOperations ||
                  hidden.hiddenDataflow != hidden.visibleDataflow,
              "hidden PAC qualification materially changes p-code and SSA dataflow");
    }
}

void testPacOutputBounds(NativeStructuredProvider& provider) {
    auto request = makePacOutputRequest();
    const auto baseline = provider.produce(request, CancellationToken{});
    const auto exactBound = structuredResultEncodedSizeUpperBound(baseline);
    check(exactBound <= request.budgets.maxOutputBytes,
          "normal PAC fixture fits its publication budget");

    request.budgets.maxOutputBytes = exactBound;
    const auto exact = provider.produce(request, CancellationToken{});
    checkBoundedNativePresentation(request, exact, baseline, false);

    check(exactBound > 0U, "PAC fixture has a non-zero semantic-size bound");
    request.budgets.maxOutputBytes = exactBound - 1U;
    const auto bounded = provider.produce(request, CancellationToken{});
    checkBoundedNativePresentation(request, bounded, baseline, true);
    check(bounded.operations == baseline.operations &&
              bounded.ssaValues == baseline.ssaValues &&
              bounded.ssaBindings == baseline.ssaBindings,
          "presentation truncation preserves every PAC operation and exact SSA effect");

    auto semanticPayload = baseline;
    semanticPayload.tokens.clear();
    semanticPayload.pseudocodeDocument.reset();
    const auto semanticBound = structuredResultEncodedSizeUpperBound(semanticPayload);
    check(semanticBound > 0U, "PAC fixture has a non-zero structured semantic bound");
    request.budgets.maxOutputBytes = semanticBound - 1U;
    const auto message = expectContractError(
        [&] { (void)provider.produce(request, CancellationToken{}); },
        "PAC structured semantics one byte above output budget"
    );
    check(message == "native-provider-output-budget-exceeded",
          "PAC structured semantic boundary fails with the stable path-free reason");
}

void testPacCancellation(NativeStructuredProvider& provider) {
    std::vector<std::uint32_t> words(1023U, 0xdac1'0020U); // pacia x0, x1
    words[0] = 0xd280'0020U; // mov x0, #1
    words[1] = 0x9100'03e1U; // mov x1, sp
    words[words.size() - 2U] = 0xf900'03e0U; // str x0, [sp]
    words.back() = 0xd65f'03c0U; // ret
    auto request = makePacRequest("cancellation", std::move(words));
    request.budgets = AnalysisBudgets{
        .maxCodeBytes = 4096U,
        .maxInstructions = 1024U,
        .maxOperations = 16'384U,
        .maxOutputBytes = 64U * 1024U * 1024U,
        .maxWallTimeMilliseconds = 10'000U,
    };

    std::atomic_bool cancelled = false;
    std::thread canceller([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        cancelled.store(true, std::memory_order_release);
    });
    const auto message = expectContractError(
        [&] { (void)provider.produce(request, CancellationToken(&cancelled)); },
        "PAC-heavy cancellation"
    );
    canceller.join();
    check(message == "analysis was cancelled",
          "PAC-heavy native traversal observes cancellation with the stable reason");
}

struct AuthoredObserverCounts final {
    std::size_t constructed = 0;
    std::size_t destroyed = 0;
    std::size_t catalogReadbacks = 0;
    std::size_t followFlow = 0;
    std::size_t decompileAction = 0;
};

[[nodiscard]] AuthoredType namedAuthoredType(
    AuthoredNamedKind kind,
    std::string name,
    std::uint8_t qualifiers = 0U
) {
    AuthoredQualifiedValue value;
    value.atom.tag = AuthoredAtomTag::named;
    value.atom.payload = AuthoredNamedAtom{kind, std::move(name)};
    value.qualifiers = qualifiers;
    AuthoredType type;
    type.tag = AuthoredTypeTag::qualifiedValue;
    type.payload = std::move(value);
    return type;
}

[[nodiscard]] AuthoredType scalarAuthoredType(AuthoredScalarKind kind) {
    AuthoredQualifiedValue value;
    value.atom.tag = AuthoredAtomTag::scalar;
    value.atom.payload = kind;
    AuthoredType type;
    type.tag = AuthoredTypeTag::qualifiedValue;
    type.payload = std::move(value);
    return type;
}

[[nodiscard]] AuthoredType darwinAuthoredType(AuthoredDarwinAliasKind kind) {
    AuthoredQualifiedValue value;
    value.atom.tag = AuthoredAtomTag::darwinAlias;
    value.atom.payload = kind;
    AuthoredType type;
    type.tag = AuthoredTypeTag::qualifiedValue;
    type.payload = std::move(value);
    return type;
}

[[nodiscard]] AuthoredType pointerAuthoredType(
    AuthoredType pointee,
    std::vector<std::uint8_t> qualifiers
) {
    AuthoredDataPointer pointer;
    pointer.pointee = std::make_shared<AuthoredType>(std::move(pointee));
    pointer.indirectionLevel = qualifiers.size();
    pointer.pointerQualifiersByLevel = std::move(qualifiers);
    AuthoredType type;
    type.tag = AuthoredTypeTag::dataPointer;
    type.payload = std::move(pointer);
    return type;
}

[[nodiscard]] AuthoredTypeDefinition emptyStructDefinition(std::string name) {
    AuthoredTypeDefinition definition;
    definition.kind = AuthoredTypeDefinitionKind::recordStruct;
    definition.name = std::move(name);
    definition.payload = AuthoredRecordDefinition{
        .kind = AuthoredNamedKind::struct_,
        .layoutRules = {},
        .fields = {},
    };
    return definition;
}

[[nodiscard]] AuthoredTypeDefinition authoredTypedefDefinition(
    std::string name,
    AuthoredType type
);

[[nodiscard]] AuthoredTypeDefinition scalarTypedefDefinition(
    std::string name,
    AuthoredScalarKind kind
) {
    return authoredTypedefDefinition(std::move(name), scalarAuthoredType(kind));
}

[[nodiscard]] AuthoredTypeDefinition authoredTypedefDefinition(
    std::string name,
    AuthoredType type
) {
    auto target = std::make_shared<AuthoredFieldStorage>();
    target->tag = AuthoredFieldStorageTag::value;
    target->payload = AuthoredValueStorage{std::move(type)};
    AuthoredTypeDefinition definition;
    definition.kind = AuthoredTypeDefinitionKind::typedef_;
    definition.name = std::move(name);
    definition.payload = AuthoredTypedefDefinition{std::move(target)};
    return definition;
}

[[nodiscard]] std::shared_ptr<GhidraProviderObserver> makeCountingObserver(
    AuthoredObserverCounts& counts
) {
    auto observer = std::make_shared<GhidraProviderObserver>();
    observer->architectureConstructed = [&] { ++counts.constructed; };
    observer->architectureDestroyed = [&] { ++counts.destroyed; };
    observer->authoredTypeReadback = [&](std::string_view, std::string_view) {
        ++counts.catalogReadbacks;
    };
    observer->followFlowEntered = [&] { ++counts.followFlow; };
    observer->decompileActionEntered = [&] { ++counts.decompileAction; };
    return observer;
}

void testAuthoredAtomicUnsupported() {
    auto request = makeRequest();
    AuthoredInputs authored;
    authored.typeDefinitions.push_back(emptyStructDefinition("AuthoredPayload"));

    authored.typeDefinitions.push_back(authoredTypedefDefinition(
        "UnresolvedAlias",
        namedAuthoredType(AuthoredNamedKind::struct_, "MissingPayload")
    ));
    request.authoredInputs = canonicalizedAuthoredInputs(std::move(authored));

    AuthoredObserverCounts counts;
    auto configuration = makeConfiguration();
    configuration.observer = makeCountingObserver(counts);
    auto provider = makeGhidraProvider(std::move(configuration));
    const auto message = expectContractError(
        [&] { (void)provider->produce(request, CancellationToken{}); },
        "unsupported authored record after valid catalog entry"
    );
    check(message == "authoring-input-unsupported",
          "unsupported authored record returns the stable failure");
    check(counts.constructed == 1U && counts.destroyed == 1U,
          "unsupported authored request disposes its request architecture once");
    check(counts.catalogReadbacks == 0U,
          "unresolved phase-one graph never begins catalog installation");
    check(counts.followFlow == 0U && counts.decompileAction == 0U,
          "unsupported authored request never enters flow or decompile action");
}

void testAuthoredApplicationCancellation() {
    auto request = makeRequest();
    AuthoredInputs authored;
    authored.typeDefinitions.push_back(emptyStructDefinition("AuthoredFirst"));
    authored.typeDefinitions.push_back(emptyStructDefinition("AuthoredSecond"));
    request.authoredInputs = canonicalizedAuthoredInputs(std::move(authored));

    std::atomic_bool cancelled = false;
    AuthoredObserverCounts counts;
    auto observer = makeCountingObserver(counts);
    observer->authoredCheckpoint = [&](std::string_view phase, std::size_t index) {
        if (phase == "catalog" && index == 1U) {
            cancelled.store(true, std::memory_order_release);
        }
    };
    auto configuration = makeConfiguration();
    configuration.observer = std::move(observer);
    auto provider = makeGhidraProvider(std::move(configuration));
    const auto message = expectContractError(
        [&] { (void)provider->produce(request, CancellationToken(&cancelled)); },
        "deterministic authored catalog cancellation"
    );
    check(message == "analysis was cancelled",
          "authored catalog cancellation returns the stable reason");
    check(counts.constructed == 1U && counts.destroyed == 1U,
          "cancelled authored request disposes its request architecture once");
    check(counts.followFlow == 0U && counts.decompileAction == 0U,
          "cancelled authored request never enters flow or decompile action");
}

void testAuthoredNamesAndDirectCalls() {
    auto request = makeRequestForFunction(
        "authored-direct-call",
        "_requestCaller",
        {
            0x08, 0x00, 0x00, 0x94, // bl 0x1020
            0xc0, 0x03, 0x5f, 0xd6, // ret
        }
    );
    AuthoredInputs authored;
    authored.names = {
        AuthoredName{kEntryAddress, AuthoredNameSubjectKind::function, "_authoredCaller"},
        AuthoredName{0x1020, AuthoredNameSubjectKind::function, "_authoredCallee"},
        AuthoredName{0x1024, AuthoredNameSubjectKind::label, "_authoredNonFunction"},
    };
    AuthoredSignature calleeSignature;
    calleeSignature.functionAddress = 0x1020;
    calleeSignature.returnType = std::make_shared<AuthoredType>(
        scalarAuthoredType(AuthoredScalarKind::signed32));
    calleeSignature.parameterListState = AuthoredParameterListState::authoritative;
    calleeSignature.variadicState = AuthoredVariadicState::fixed;
    calleeSignature.noReturnState = AuthoredNoReturnState::returns;
    authored.signatures.push_back(std::move(calleeSignature));
    request.authoredInputs = canonicalizedAuthoredInputs(std::move(authored));

    std::vector<std::tuple<Address, std::string, bool>> readback;
    auto observer = std::make_shared<GhidraProviderObserver>();
    bool entrySignatureReadback = false;
    observer->authoredSignatureReadback = [&](const auto&) { entrySignatureReadback = true; };
    observer->authoredNameReadback = [&](Address address, std::string_view name, bool isFunction) {
        readback.emplace_back(address, std::string(name), isFunction);
    };
    auto configuration = makeConfiguration();
    configuration.observer = std::move(observer);
    auto provider = makeGhidraProvider(std::move(configuration));
    const auto result = produceOrFail(
        [&] { return provider->produce(request, CancellationToken{}); },
        "authored names and direct calls"
    );
    if (!result) return;
    check(!entrySignatureReadback,
          "callee signature installation does not claim selected-entry ABI authority");

    check(result->function.name == "_requestCaller",
          "structured result preserves request identity while native naming is request-local");
    const auto call = std::find_if(result->calls.begin(), result->calls.end(), [](const CallRecord& item) {
        return item.targetAddress == std::optional<Address>(0x1020);
    });
    check(call != result->calls.end() &&
              call->targetSymbol == std::optional<std::string>("_authoredCallee"),
          "authored direct-call destination owns the exported call symbol");
    check(std::find(readback.begin(), readback.end(),
                    std::tuple<Address, std::string, bool>{kEntryAddress, "_authoredCaller", true}) != readback.end(),
          "selected authored name reads back as the native function");
    check(std::find(readback.begin(), readback.end(),
                    std::tuple<Address, std::string, bool>{0x1020, "_authoredCallee", true}) != readback.end(),
          "authored direct-call name reads back as the native callee function");
    check(std::find(readback.begin(), readback.end(),
                    std::tuple<Address, std::string, bool>{0x1024, "_authoredNonFunction", false}) != readback.end(),
          "authored non-function start reads back only as a label");
}

// This mirrors the signed snapshot case: pass a readonly typed object's address
// to a const-qualified record pointer, rather than testing isolated catalog readback.
// Authored-input v2 callee signature hints: a pass-through argument at a tail
// call (libjpeg `_jpeg_destroy_compress`) and a typed SDK call.
void testCalleeSignatureHints() {
    AuthoredType voidType;
    voidType.tag = AuthoredTypeTag::qualifiedValue;
    voidType.payload = AuthoredQualifiedValue{};
    const auto hint = [&](Address address, std::string name, CalleeSignatureHintSource source,
                          std::shared_ptr<AuthoredType> returnType,
                          std::vector<AuthoredParameter> parameters) {
        CalleeSignatureHint result;
        result.name = std::move(name);
        result.source = source;
        result.signature.functionAddress = address;
        result.signature.returnType = std::move(returnType);
        result.signature.parameterListState = AuthoredParameterListState::authoritative;
        result.signature.parameters = std::move(parameters);
        result.signature.variadicState = AuthoredVariadicState::fixed;
        return result;
    };
    const auto produceWith = [&](std::string suffix, std::vector<std::uint8_t> bytes, CalleeSignatureHint calleeHint) {
        auto request = makeRequestForFunction("callee-hint-" + suffix, "_hinted_" + suffix, std::move(bytes));
        AuthoredInputs authored;
        authored.schemaVersion = 2;
        authored.calleeSignatureHints.push_back(std::move(calleeHint));
        request.authoredInputs = canonicalizedAuthoredInputs(std::move(authored));
        auto provider = makeGhidraProvider(makeConfiguration());
        return produceOrFail([&] { return provider->produce(request, CancellationToken{}); },
                             "callee signature hint " + suffix);
    };
    // b +0x20: the caller's untouched x0 reaches the hinted callee.
    const auto tail = produceWith("tail", {0x08, 0x00, 0x00, 0x14},
        hint(kEntryAddress + 0x20U, "_jpeg_destroy", CalleeSignatureHintSource::debug,
             nullptr, {AuthoredParameter{"cinfo", pointerAuthoredType(voidType, {0U})}}));
    check(tail && tail->pseudocodeDocument &&
              tail->pseudocodeDocument->text.find("_jpeg_destroy(param_1)") != std::string::npos,
          "a hinted tail call passes the caller's x0 through as an argument");
    // mov x0, #0x40; bl +0x20; ret
    const auto sdk = produceWith("sdk", {0x00, 0x08, 0x80, 0xd2, 0x08, 0x00, 0x00, 0x94, 0xc0, 0x03, 0x5f, 0xd6},
        hint(kEntryAddress + 0x24U, "_malloc", CalleeSignatureHintSource::sdk,
             std::make_shared<AuthoredType>(pointerAuthoredType(voidType, {0U})),
             {AuthoredParameter{"size", darwinAuthoredType(AuthoredDarwinAliasKind::sizeT)}}));
    check(sdk && sdk->pseudocodeDocument &&
              sdk->pseudocodeDocument->text.find("_malloc(0x40)") != std::string::npos,
          "an SDK-hinted call prints by name with its typed argument");
    // Several hinted SDK callees with const-qualified pointers in one function
    // (libjpeg _empty_mem_output_buffer shape: memcpy, memset, strlen).
    {
        AuthoredType constVoid = voidType;
        std::get<AuthoredQualifiedValue>(constVoid.payload).qualifiers =
            static_cast<std::uint8_t>(AuthoredQualifier::constant);
        AuthoredType constChar = scalarAuthoredType(AuthoredScalarKind::char_);
        std::get<AuthoredQualifiedValue>(constChar.payload).qualifiers =
            static_cast<std::uint8_t>(AuthoredQualifier::constant);
        const auto voidPointer = pointerAuthoredType(voidType, {0U});
        auto request = makeRequestForFunction("callee-hint-many", "_hinted_many", {
            0x08, 0x00, 0x00, 0x94, // bl +0x20 (memcpy)
            0x08, 0x00, 0x00, 0x94, // bl +0x20 (memset)
            0x08, 0x00, 0x00, 0x94, // bl +0x20 (strlen)
            0xc0, 0x03, 0x5f, 0xd6,
        });
        AuthoredInputs authored;
        authored.schemaVersion = 2;
        authored.calleeSignatureHints = {
            hint(kEntryAddress + 0x20U, "_memcpy", CalleeSignatureHintSource::sdk,
                 std::make_shared<AuthoredType>(voidPointer),
                 {AuthoredParameter{"dst", voidPointer},
                  AuthoredParameter{"src", pointerAuthoredType(constVoid, {0U})},
                  AuthoredParameter{"n", darwinAuthoredType(AuthoredDarwinAliasKind::sizeT)}}),
            hint(kEntryAddress + 0x24U, "_memset", CalleeSignatureHintSource::sdk,
                 std::make_shared<AuthoredType>(voidPointer),
                 {AuthoredParameter{"b", voidPointer},
                  AuthoredParameter{"c", scalarAuthoredType(AuthoredScalarKind::signed32)},
                  AuthoredParameter{"len", darwinAuthoredType(AuthoredDarwinAliasKind::sizeT)}}),
            hint(kEntryAddress + 0x28U, "_strlen", CalleeSignatureHintSource::sdk,
                 std::make_shared<AuthoredType>(darwinAuthoredType(AuthoredDarwinAliasKind::sizeT)),
                 {AuthoredParameter{"s", pointerAuthoredType(constChar, {0U})}}),
        };
        request.authoredInputs = canonicalizedAuthoredInputs(std::move(authored));
        auto provider = makeGhidraProvider(makeConfiguration());
        const auto many = produceOrFail([&] { return provider->produce(request, CancellationToken{}); },
                                        "callee signature hints with const pointers");
        check(many.has_value() && many->calls.size() == 3U, "three hinted SDK calls export");
    }
    // Hints are a v2 field; a v1 request carrying one is rejected.
    AuthoredInputs v1;
    v1.calleeSignatureHints.push_back(hint(kEntryAddress + 0x20U, "_x", CalleeSignatureHintSource::sdk, nullptr, {}));
    bool rejected = false;
    try { (void)canonicalizedAuthoredInputs(std::move(v1)); } catch (const ContractError&) { rejected = true; }
    check(rejected, "authored-input v1 rejects callee signature hints");
}

// DP04 C1b, authored-input v3: a user's stack local and register names reach the
// native pseudocode.
void testAuthoredLocalNames() {
    const auto produceWith = [&](std::string suffix, std::vector<std::uint8_t> bytes, AuthoredLocalName local) {
        auto request = makeRequestForFunction("local-name-" + suffix, "_named_" + suffix, std::move(bytes));
        AuthoredInputs authored;
        authored.schemaVersion = 3;
        authored.localNames.push_back(std::move(local));
        request.authoredInputs = canonicalizedAuthoredInputs(std::move(authored));
        auto provider = makeGhidraProvider(makeConfiguration());
        return produceOrFail([&] { return provider->produce(request, CancellationToken{}); },
                             "authored local name " + suffix);
    };
    // sub sp, #0x20; add x0, sp, #8; bl +0x40; ldr x0, [sp, #8]; add sp, #0x20; ret
    // The slot at entry SP - 0x18 escapes to the call, so it is a real stack local.
    const std::vector<std::uint8_t> stackBytes = {
        0xff, 0x83, 0x00, 0xd1, 0xe0, 0x23, 0x00, 0x91, 0x10, 0x00, 0x00, 0x94,
        0xe0, 0x07, 0x40, 0xf9, 0xff, 0x83, 0x00, 0x91, 0xc0, 0x03, 0x5f, 0xd6,
    };
    const auto stack = produceWith("stack", stackBytes,
        {AuthoredLocalStorageKind::stack, -0x18, 8U, "", "count",
         std::make_shared<AuthoredType>(scalarAuthoredType(AuthoredScalarKind::unsigned64))});
    const auto stackText = stack && stack->pseudocodeDocument ? stack->pseudocodeDocument->text : std::string();
    check(stackText.find("&count") != std::string::npos,
          "an authored stack local names the escaped slot:\n" + stackText);
    // ldr x19, [x0]; str xzr, [x0]; add x0, x19, #1; ret
    // The store changes *x0, so the loaded x19 must live in a variable.
    const auto reg = produceWith("register", {
        0x13, 0x00, 0x40, 0xf9, 0x1f, 0x00, 0x00, 0xf9, 0x60, 0x06, 0x00, 0x91, 0xc0, 0x03, 0x5f, 0xd6,
    }, {AuthoredLocalStorageKind::register_, 0, 0U, "x19", "total", nullptr});
    const auto regText = reg && reg->pseudocodeDocument ? reg->pseudocodeDocument->text : std::string();
    check(regText.find("total") != std::string::npos,
          "an authored register name renames the x19 variable:\n" + regText);
    // Local names are a v3 field; a v2 request carrying one is rejected.
    AuthoredInputs v2;
    v2.schemaVersion = 2;
    v2.localNames.push_back({AuthoredLocalStorageKind::register_, 0, 0U, "x19", "total", nullptr});
    bool rejected = false;
    try { (void)canonicalizedAuthoredInputs(std::move(v2)); } catch (const ContractError&) { rejected = true; }
    check(rejected, "authored-input v2 rejects local names");
}

void testAuthoredTypedDataPointerCall() {
    auto request = makeRequestForFunction("authored-data-pointer-call", "caller", {
        0xff, 0x43, 0x00, 0xd1, // sub sp, sp, #16
        0xfe, 0x07, 0x00, 0xf9, // str x30, [sp, #8]
        0x00, 0x00, 0x84, 0xd2, // mov x0, #0x2000
        0x01, 0x00, 0x40, 0xb9, // ldr w1, [x0]
        0x3c, 0x00, 0x00, 0x94, // bl 0x1100
        0xfe, 0x07, 0x40, 0xf9, // ldr x30, [sp, #8]
        0xff, 0x43, 0x00, 0x91, // add sp, sp, #16
        0xc0, 0x03, 0x5f, 0xd6, // ret
    });
    auto regions = request.bytes.regions();
    auto calleeBytes = effectiveRegionBytes();
    const std::array<std::uint8_t, 12> callee = {
        0x00, 0x00, 0x40, 0xb9, // ldr w0, [x0]
        0x00, 0x00, 0x01, 0x0b, // add w0, w0, w1
        0xc0, 0x03, 0x5f, 0xd6,
    };
    std::copy(callee.begin(), callee.end(), calleeBytes.begin());
    regions.push_back(MemoryRegion{"callee", 0x1100, "r-x", calleeBytes, calleeBytes, {}});
    const std::vector<std::uint8_t> data = {7, 0, 0, 0};
    regions.push_back(MemoryRegion{"readonly", 0x2000, "r--", data, data, {}});
    request.bytes = ByteProvider(std::move(regions));

    auto scalar = emptyStructDefinition("Scalar");
    auto fieldStorage = std::make_shared<AuthoredFieldStorage>();
    fieldStorage->tag = AuthoredFieldStorageTag::value;
    fieldStorage->payload = AuthoredValueStorage{scalarAuthoredType(AuthoredScalarKind::signed32)};
    std::get<AuthoredRecordDefinition>(scalar.payload).fields.push_back(
        AuthoredRecordField{.name = "value", .storage = std::move(fieldStorage)});
    auto pointee = namedAuthoredType(AuthoredNamedKind::struct_, "Scalar");
    std::get<AuthoredQualifiedValue>(pointee.payload).qualifiers =
        static_cast<std::uint8_t>(AuthoredQualifier::constant);
    AuthoredSignature signature;
    signature.functionAddress = 0x1100;
    signature.returnType = std::make_shared<AuthoredType>(scalarAuthoredType(AuthoredScalarKind::signed32));
    signature.parameters = {
        AuthoredParameter{"table", pointerAuthoredType(std::move(pointee), {0U})},
        AuthoredParameter{"observed", scalarAuthoredType(AuthoredScalarKind::signed32)},
    };
    signature.parameterListState = AuthoredParameterListState::authoritative;
    signature.variadicState = AuthoredVariadicState::fixed;
    signature.noReturnState = AuthoredNoReturnState::returns;
    AuthoredInputs authored;
    authored.typeDefinitions.push_back(std::move(scalar));
    authored.names = {
        AuthoredName{0x1100, AuthoredNameSubjectKind::function, "authored_signed_callee"},
        AuthoredName{0x2000, AuthoredNameSubjectKind::data, "authored_table"},
    };
    authored.signatures.push_back(std::move(signature));
    authored.appliedTypes.push_back(AppliedType{.address = 0x2000,
        .subjectKind = AuthoredAppliedTypeSubjectKind::memoryObject,
        .typeDefinitionName = "Scalar", .byteCount = 4});
    request.authoredInputs = canonicalizedAuthoredInputs(std::move(authored));
    auto provider = makeGhidraProvider(makeConfiguration());
    const auto result = produceOrFail(
        [&] { return provider->produce(request, CancellationToken{}); }, "authored typed-data pointer call");
    if (!result) return;
    const auto call = std::find_if(result->calls.begin(), result->calls.end(), [](const auto& item) {
        return item.targetAddress == std::optional<Address>(0x1100);
    });
    check(call != result->calls.end() && call->prototypeTypeId.has_value(),
          "typed-data call retains its authored prototype");
    if (call == result->calls.end() || !call->prototypeTypeId) return;
    const auto findType = [&](const std::string& id) {
        return std::find_if(result->types.begin(), result->types.end(), [&](const auto& type) { return type.id == id; });
    };
    const auto prototype = findType(*call->prototypeTypeId);
    check(prototype != result->types.end() && prototype->parameterTypeIds.size() == 2U,
          "typed-data call retains both authored parameters");
    if (prototype == result->types.end() || prototype->parameterTypeIds.size() != 2U) return;
    const auto pointer = findType(prototype->parameterTypeIds.front());
    check(pointer != result->types.end() && pointer->pointeeTypeId.has_value(), "authored pointer retains pointee");
    if (pointer == result->types.end() || !pointer->pointeeTypeId) return;
    const auto pointeeType = findType(*pointer->pointeeTypeId);
    check(pointeeType != result->types.end() && pointeeType->name == "Scalar" &&
              pointeeType->byteSize == std::optional<std::uint64_t>(4U) &&
              pointeeType->fields.size() == 1U && pointeeType->fields.front().name == "value",
          "const-qualified authored pointee reports Scalar with its exact field layout");
    check(result->pseudocodeDocument.has_value() &&
              result->pseudocodeDocument->text.find("authored_table") != std::string::npos &&
              result->pseudocodeDocument->text.find("__macscope_authored_qualifier_") == std::string::npos &&
              result->pseudocodeDocument->text.find("const Scalar *") != std::string::npos,
          "typed-data call pseudocode retains authored data without private qualifier names");
    check(std::none_of(result->tokens.begin(), result->tokens.end(), [](const auto& token) {
        return token.text.find("__macscope_authored_qualifier_") != std::string::npos;
    }), "structured native tokens never expose private qualifier aliases");
    check(std::any_of(result->tokens.begin(), result->tokens.end(), [&](const auto& token) {
        return token.text == "const Scalar" && std::any_of(
            token.entityReferences.begin(), token.entityReferences.end(), [&](const auto& reference) {
                return reference.kind == "type" && reference.id == pointeeType->id;
            });
    }), "rendered qualified type token retains the exported native type identity");
    auto documentRequest = request;
    documentRequest.documentOnly = true;
    const auto document = produceOrFail(
        [&] { return provider->produce(documentRequest, CancellationToken{}); },
        "document-only authored typed-data pointer call");
    if (document) {
        validateStructuredResult(documentRequest, *document);
        check(document->pseudocodeDocument && result->pseudocodeDocument &&
                  document->pseudocodeDocument->text == result->pseudocodeDocument->text,
              "document-only and full requests render identical authored qualifier text");
        check(document->pseudocodeDocument &&
                  document->pseudocodeDocument->text.find("const Scalar *") != std::string::npos &&
                  document->pseudocodeDocument->text.find("__macscope_authored_qualifier") == std::string::npos,
              "document-only retains C qualifiers without private type names");
    }
    const auto repeated = produceOrFail(
        [&] { return provider->produce(request, CancellationToken{}); }, "repeated authored typed-data pointer call");
    check(repeated && repeated->types == result->types && repeated->tokens == result->tokens &&
              repeated->pseudocodeDocument == result->pseudocodeDocument,
          "render-only qualifier names are deterministic across request architectures");
    for (const bool constPointee : {false, true}) {
        auto variant = request;
        auto& parameter = variant.authoredInputs.signatures.front().parameters.front().type;
        auto& qualifiedPointer = std::get<AuthoredDataPointer>(parameter.payload);
        qualifiedPointer.pointerQualifiersByLevel = {static_cast<std::uint8_t>(AuthoredQualifier::constant)};
        qualifiedPointer.pointee = std::make_shared<AuthoredType>(*qualifiedPointer.pointee);
        std::get<AuthoredQualifiedValue>(qualifiedPointer.pointee->payload).qualifiers =
            constPointee ? static_cast<std::uint8_t>(AuthoredQualifier::constant) : 0U;
        variant.authoredInputs = canonicalizedAuthoredInputs(std::move(variant.authoredInputs));
        const auto qualifiedResult = produceOrFail(
            [&] { return provider->produce(variant, CancellationToken{}); }, "authored const-pointer call");
        if (!qualifiedResult) continue;
        const auto expected = constPointee ? "const Scalar * const" : "Scalar * const";
        check(qualifiedResult->pseudocodeDocument &&
                  qualifiedResult->pseudocodeDocument->text.find(expected) != std::string::npos,
              "pointer const and pointee const remain at their respective C declaration levels");
        check(std::none_of(qualifiedResult->tokens.begin(), qualifiedResult->tokens.end(), [](const auto& token) {
            return token.text.find("__macscope_authored_qualifier_") != std::string::npos;
        }), "per-pointer qualifier aliases never leak through native tokens");
    }
}

void testCalleeSignatureHintStorage() {
    AuthoredType voidType;
    voidType.tag = AuthoredTypeTag::qualifiedValue;
    voidType.payload = AuthoredQualifiedValue{};
    const auto hint = [&](std::optional<std::string> storage) {
        CalleeSignatureHint result;
        result.name = "_swift_callee";
        result.source = CalleeSignatureHintSource::swift;
        result.signature.functionAddress = kEntryAddress + 0x24U;
        result.signature.returnType =
            std::make_shared<AuthoredType>(scalarAuthoredType(AuthoredScalarKind::signed64));
        result.signature.parameterListState = AuthoredParameterListState::authoritative;
        result.signature.parameters = {
            {"first", scalarAuthoredType(AuthoredScalarKind::signed64)},
            {"self", pointerAuthoredType(voidType, {0U}), std::move(storage)},
        };
        result.signature.variadicState = AuthoredVariadicState::fixed;
        return result;
    };
    const auto requestWith = [&](std::string suffix, std::optional<std::string> storage) {
        auto request = makeRequestForFunction("callee-storage-" + suffix, "_caller_" + suffix, {
            0x14, 0x08, 0x80, 0xd2, // mov x20, #0x40; x1 remains untouched
            0x08, 0x00, 0x00, 0x94, // bl +0x20
            0xc0, 0x03, 0x5f, 0xd6,
        });
        AuthoredInputs authored;
        authored.schemaVersion = 2;
        authored.calleeSignatureHints.push_back(hint(std::move(storage)));
        request.authoredInputs = canonicalizedAuthoredInputs(std::move(authored));
        return request;
    };
    const auto produceWith = [&](std::string suffix, std::optional<std::string> storage) {
        auto request = requestWith(suffix, std::move(storage));
        auto provider = makeGhidraProvider(makeConfiguration());
        return produceOrFail([&] { return provider->produce(request, CancellationToken{}); },
                             "callee signature hint storage " + suffix);
    };
    const auto stored = produceWith("x20", "x20");
    const auto control = produceWith("model", std::nullopt);
    const auto callText = [](const auto& result) {
        const auto text = result && result->pseudocodeDocument
            ? result->pseudocodeDocument->text : std::string{};
        const auto start = text.find("_swift_callee(");
        return start == std::string::npos ? std::string{} : text.substr(start, text.find('\n', start) - start);
    };
    const auto storedCall = callText(stored);
    const auto controlCall = callText(control);
    check(storedCall.find("param_1,") != std::string::npos &&
              storedCall.find("0x40") != std::string::npos &&
              storedCall.find("param_2") == std::string::npos,
          "a callee hint's second argument derives from its authored x20 storage");
    check(controlCall.find("param_1,") != std::string::npos &&
              controlCall.find("param_2") != std::string::npos &&
              controlCall.find("0x40") == std::string::npos,
          "without authored callee storage the second argument derives from untouched x1");

    auto invalid = requestWith("unknown", "x99");
    std::size_t analysisCount = 0;
    auto observer = std::make_shared<GhidraProviderObserver>();
    observer->decompileActionEntered = [&] { ++analysisCount; };
    auto configuration = makeConfiguration();
    configuration.observer = std::move(observer);
    auto provider = makeGhidraProvider(std::move(configuration));
    const auto message = expectContractError(
        [&] { (void)provider->produce(invalid, CancellationToken{}); },
        "unknown callee storage register is rejected before analysis");
    check(message == "authoring-input-unsupported" && analysisCount == 0U,
          "unknown callee storage register is rejected before analysis");
}

void testAuthoredParameterStorage() {
    const std::vector<std::string> parameterNames = {"first", "second"};
    const std::vector<std::string> authoredStorage = {"x0", "x20"};
    const std::vector<std::string> modelStorage = {"x0", "x1"};
    const std::vector<std::int32_t> parameterSizes = {8, 8};
    for (int caseIndex = 0; caseIndex < 5; ++caseIndex) {
        const bool usesX1 = caseIndex == 1;
        auto request = makeRequestForFunction(
            usesX1 ? "add-x1" : "add-x20",
            usesX1 ? "_addSecondAtX1" : "_addSecondAtX20",
            {0x00, 0x00, static_cast<std::uint8_t>(usesX1 ? 0x01 : 0x14), 0x8b,
             0xc0, 0x03, 0x5f, 0xd6}
        );
        AuthoredSignature signature;
        signature.functionAddress = request.function.entryAddress;
        signature.returnType = std::make_shared<AuthoredType>(scalarAuthoredType(AuthoredScalarKind::signed64));
        signature.parameterListState = AuthoredParameterListState::authoritative;
        signature.parameters = {
            {"first", scalarAuthoredType(AuthoredScalarKind::signed64)},
            {"second", scalarAuthoredType(caseIndex == 4 ? AuthoredScalarKind::signed32 : AuthoredScalarKind::signed64)},
        };
        if (caseIndex == 0 || caseIndex == 4) signature.parameters[1].storageRegister = "x20";
        if (caseIndex == 3) signature.parameters[1].storageRegister = "x99";
        AuthoredInputs authored;
        authored.signatures.push_back(std::move(signature));
        request.authoredInputs = canonicalizedAuthoredInputs(std::move(authored));

        std::optional<GhidraProviderObserver::SignatureReadback> pre;
        std::optional<GhidraProviderObserver::SignatureReadback> post;
        std::size_t preCount = 0;
        std::size_t postCount = 0;
        std::size_t analysisCount = 0;
        auto observer = std::make_shared<GhidraProviderObserver>();
        observer->authoredSignatureReadback = [&](const auto& value) { pre = value; ++preCount; };
        observer->authoredSignatureReadbackAfterAnalysis = [&](const auto& value) { post = value; ++postCount; };
        observer->decompileActionEntered = [&] { ++analysisCount; };
        auto configuration = makeConfiguration();
        configuration.observer = std::move(observer);
        auto provider = makeGhidraProvider(std::move(configuration));
        if (caseIndex >= 3) {
            const auto checkMessage = caseIndex == 3
                ? "unknown storage register is rejected before analysis"
                : "storage register narrower or wider than the parameter type is rejected before analysis";
            const auto message = expectContractError(
                [&] { (void)provider->produce(request, CancellationToken{}); }, checkMessage);
            check(message == "authoring-input-unsupported" && analysisCount == 0U, checkMessage);
            continue;
        }
        const auto result = produceOrFail(
            [&] { return provider->produce(request, CancellationToken{}); },
            caseIndex == 0 ? "authored register storage request decompiles" :
            caseIndex == 1 ? "model-assigned two-parameter request decompiles with both readbacks" :
                             "without authored storage the model places the second parameter in x1"
        );
        const auto text = result && result->pseudocodeDocument ? result->pseudocodeDocument->text : std::string{};
        const bool bindsSecond = text.find("first + second") != std::string::npos ||
                                 text.find("second + first") != std::string::npos;
        const auto dump = [](std::string_view phase, const auto& readback) {
            std::cout << phase << ": ";
            if (!readback) { std::cout << "missing\n"; return; }
            std::cout << "parameterStorage={";
            for (std::size_t index = 0; index < readback->parameterStorage.size(); ++index) {
                if (index != 0) std::cout << ',';
                std::cout << readback->parameterStorage[index];
            }
            std::cout << "} inputLocked=" << readback->inputLocked
                      << " afterAnalysis=" << readback->afterAnalysis
                      << " outputStorage=" << readback->outputStorage << " parameterTypeSizes={";
            for (std::size_t index = 0; index < readback->parameterTypeSizes.size(); ++index) {
                if (index != 0) std::cout << ',';
                std::cout << readback->parameterTypeSizes[index];
            }
            std::cout << "}\n";
        };
        std::cout << "Case " << static_cast<char>('A' + caseIndex) << '\n';
        dump("pre", pre);
        dump("post", post);
        std::cout << "pseudocode begin\n" << text << "\npseudocode end\n";
        if (caseIndex == 0) {
            check(result.has_value(), "authored register storage request decompiles");
            check(pre && preCount == 1U && !pre->afterAnalysis && pre->inputLocked,
                  "pre-analysis readback fires once before analysis with the input lock set");
            check(pre && pre->parameterNames == parameterNames,
                  "pre-analysis readback keeps authored parameter names");
            check(pre && pre->parameterStorage == authoredStorage,
                  "pre-analysis readback reports the authored register for the second parameter");
            check(post && postCount == 1U && post->afterAnalysis,
                  "post-analysis readback fires after the decompile action");
            check(post && post->inputLocked, "input lock survives analysis");
            check(post && post->parameterNames == parameterNames && post->parameterTypeSizes == parameterSizes,
                  "parameter names and widths survive analysis");
            check(post && post->parameterStorage == authoredStorage, "authored register storage survives analysis");
            check(post && post->outputStorage == "x0", "return value stays in x0");
            check(bindsSecond, "pseudocode binds the register read to the authored parameter");
            check(text.find("in_x20") == std::string::npos && text.find("unaff_x20") == std::string::npos &&
                      text.find("yet parameter storage is locked") == std::string::npos,
                  "pseudocode has no stray register input or storage warning");
        } else if (caseIndex == 1) {
            check(result && pre && post, "model-assigned two-parameter request decompiles with both readbacks");
            check(pre && post && pre->parameterStorage == modelStorage && post->parameterStorage == modelStorage,
                  "model assigns x0 and x1 and analysis keeps them");
            check(bindsSecond, "pseudocode binds x1 to the second parameter");
        } else {
            check(result && post && post->parameterStorage == modelStorage,
                  "without authored storage the model places the second parameter in x1");
            const bool namedStray = text.find("in_x20") != std::string::npos || text.find("unaff_x20") != std::string::npos;
            check(namedStray || !bindsSecond, namedStray
                ? "without authored storage the x20 read is not the second parameter"
                : "without authored storage the x20 read is not the second parameter (alternate spelling recorded in pseudocode)");
        }
    }
}

void testAuthoredSignatureMergeMatrix() {
    std::optional<GhidraProviderObserver::SignatureReadback> readback;
    auto observer = std::make_shared<GhidraProviderObserver>();
    observer->authoredSignatureReadback = [&](const auto& value) { readback = value; };
    auto configuration = makeConfiguration();
    configuration.observer = std::move(observer);
    auto provider = makeGhidraProvider(std::move(configuration));

    const std::array<bool, 2> returnStates = {false, true};
    const std::array<AuthoredParameterListState, 3> parameterStates = {
        AuthoredParameterListState::unspecified,
        AuthoredParameterListState::authoritative,
        AuthoredParameterListState::authoritative,
    };
    const std::array<AuthoredVariadicState, 3> variadicStates = {
        AuthoredVariadicState::unspecified,
        AuthoredVariadicState::fixed,
        AuthoredVariadicState::variadic,
    };
    const std::array<AuthoredNoReturnState, 3> noReturnStates = {
        AuthoredNoReturnState::unspecified,
        AuthoredNoReturnState::returns,
        AuthoredNoReturnState::noReturn,
    };

    std::size_t caseIndex = 0;
    for (const bool hasReturn : returnStates) {
        for (std::size_t parameterCase = 0; parameterCase < parameterStates.size(); ++parameterCase) {
            for (const auto variadic : variadicStates) {
                for (const auto noReturn : noReturnStates) {
                    auto request = makeRequest();
                    AuthoredSignature signature;
                    signature.functionAddress = request.function.entryAddress;
                    if (hasReturn) {
                        signature.returnType = std::make_shared<AuthoredType>(
                            scalarAuthoredType(AuthoredScalarKind::signed32)
                        );
                    }
                    signature.parameterListState = parameterStates[parameterCase];
                    if (parameterCase == 2U) {
                        signature.parameters.push_back(AuthoredParameter{
                            "authoredValue",
                            scalarAuthoredType(AuthoredScalarKind::signed64),
                        });
                    }
                    signature.variadicState = variadic;
                    signature.noReturnState = noReturn;
                    AuthoredInputs authored;
                    authored.signatures.push_back(std::move(signature));
                    request.authoredInputs = canonicalizedAuthoredInputs(std::move(authored));
                    readback.reset();
                    const auto result = produceOrFail(
                        [&] { return provider->produce(request, CancellationToken{}); },
                        "authored signature merge matrix case " + std::to_string(caseIndex)
                    );
                    if (!result || !readback) {
                        ++caseIndex;
                        continue;
                    }
                    check(readback->variadic == (variadic == AuthoredVariadicState::variadic),
                          "signature matrix applies only the selected variadic axis");
                    check(readback->noReturn == (noReturn == AuthoredNoReturnState::noReturn),
                          "signature matrix applies only the selected no-return axis");
                    check(readback->outputLocked == hasReturn,
                          "signature matrix preserves or authors the output axis independently");
                    if (hasReturn) {
                        check(readback->outputTypeSize == 4,
                              "authored signed32 return reads back with exact width");
                    }
                    check(readback->inputLocked == (parameterCase != 0U),
                          "signature matrix preserves or authors the parameter axis independently");
                    check(readback->parameterNames.size() == (parameterCase == 2U ? 1U : 0U),
                          "signature matrix reads back authoritative empty/populated parameters");
                    if (parameterCase == 2U && !readback->parameterNames.empty()) {
                        check(readback->parameterNames.front() == "authoredValue" &&
                                  readback->parameterTypeSizes.front() == 8,
                              "authored populated parameter reads back with exact name and width");
                    }
                    ++caseIndex;
                }
            }
        }
    }
    check(caseIndex == 54U, "signature merge matrix executes all 54 Cartesian cases");
}

void testAuthoredAppliedNonCodeObjects() {
    auto request = makeRequest();
    auto regions = request.bytes.regions();
    regions.push_back(MemoryRegion{
        "__data",
        0x2000,
        "r--",
        std::vector<std::uint8_t>(16U, 0U),
        std::vector<std::uint8_t>(16U, 0U),
        {},
    });
    request.bytes = ByteProvider(std::move(regions));
    const auto baselineRequest = request;

    AuthoredInputs authored;
    authored.names = {
        AuthoredName{0x2004, AuthoredNameSubjectKind::data, "authoredTypedData"},
        AuthoredName{0x200c, AuthoredNameSubjectKind::data, "authoredByteData"},
    };
    authored.typeDefinitions.push_back(
        scalarTypedefDefinition("AuthoredUInt32", AuthoredScalarKind::unsigned32)
    );
    authored.appliedTypes.push_back(AppliedType{
        .address = 0x2004,
        .subjectKind = AuthoredAppliedTypeSubjectKind::memoryObject,
        .typeDefinitionName = "AuthoredUInt32",
        .byteCount = 4,
    });
    request.authoredInputs = canonicalizedAuthoredInputs(std::move(authored));

    std::optional<std::tuple<Address, std::uint64_t, std::string, bool>> appliedReadback;
    std::optional<std::pair<Address, Address>> flowRange;
    auto observer = std::make_shared<GhidraProviderObserver>();
    std::vector<std::tuple<Address, std::string, bool>> dataNames;
    observer->authoredNameReadback = [&](Address address, std::string_view name, bool function) {
        if (address >= 0x2000) dataNames.emplace_back(address, std::string(name), function);
    };
    observer->authoredAppliedReadback = [&](Address address, std::uint64_t byteCount,
                                            std::string_view typeName, bool isFunction) {
        appliedReadback = std::tuple<Address, std::uint64_t, std::string, bool>{
            address, byteCount, std::string(typeName), isFunction,
        };
    };
    observer->followFlowRange = [&](Address start, Address endExclusive) {
        flowRange = std::pair<Address, Address>{start, endExclusive};
    };
    auto configuration = makeConfiguration();
    configuration.observer = std::move(observer);
    auto provider = makeGhidraProvider(std::move(configuration));
    const auto baseline = produceOrFail(
        [&] { return provider->produce(baselineRequest, CancellationToken{}); },
        "applied-object baseline"
    );
    const auto result = produceOrFail(
        [&] { return provider->produce(request, CancellationToken{}); },
        "authored applied non-code object"
    );
    if (!baseline || !result) return;
    check(dataNames == std::vector<std::tuple<Address, std::string, bool>>{
              {0x2004, "authoredTypedData", false}, {0x200c, "authoredByteData", false}},
          "typed and standalone data names read back without creating functions");
    check(appliedReadback ==
              std::optional<std::tuple<Address, std::uint64_t, std::string, bool>>(
                  std::tuple<Address, std::uint64_t, std::string, bool>{
                      0x2004, 4U, "AuthoredUInt32", false,
                  }
              ),
          "applied object reads back with exact address, span, typedef, and non-function kind");
    check(flowRange == std::optional<std::pair<Address, Address>>(
                           std::pair<Address, Address>{
                               request.function.entryAddress,
                               request.function.endAddressExclusive,
                           }
                       ),
          "applied non-code object leaves requested follow-flow bounds unchanged");
    check(result->instructions == baseline->instructions && result->blocks == baseline->blocks,
          "applied non-code object does not clear code or mutate native flow ownership");
    check(result->variables == baseline->variables,
          "applied non-code object does not change variable recovery");
    auto rejected = request;
    auto invalid = rejected.authoredInputs;
    invalid.names.push_back(AuthoredName{0x2005, AuthoredNameSubjectKind::data, "interiorName"});
    rejected.authoredInputs = canonicalizedAuthoredInputs(std::move(invalid));
    check(expectContractError([&] { (void)provider->produce(rejected, CancellationToken{}); },
                              "interior authored typed-object name") == "authoring-input-unsupported",
          "an interior data name fails the whole cut rather than overlapping a typed object");
    auto writable = request;
    auto appliedOnly = writable.authoredInputs;
    appliedOnly.names.clear();
    writable.authoredInputs = canonicalizedAuthoredInputs(std::move(appliedOnly));
    auto writableRegions = writable.bytes.regions();
    writableRegions.back().permissions = "rw-";
    writable.bytes = ByteProvider(std::move(writableRegions));
    check(expectContractError([&] { (void)provider->produce(writable, CancellationToken{}); },
                              "writable applied-only authored object") == "authoring-input-unsupported",
          "an applied-only request cannot bypass readonly context admission");
}

void testAuthoredCompleteTypeCatalog() {
    const auto valueStorage = [](AuthoredType type) {
        auto storage = std::make_shared<AuthoredFieldStorage>();
        storage->tag = AuthoredFieldStorageTag::value;
        storage->payload = AuthoredValueStorage{std::move(type)};
        return storage;
    };
    const auto field = [&](std::string name, AuthoredType type) {
        return AuthoredRecordField{
            .name = std::move(name),
            .storage = valueStorage(std::move(type)),
        };
    };

    AuthoredInputs authored;
    AuthoredTypeDefinition enumeration;
    enumeration.kind = AuthoredTypeDefinitionKind::enumeration;
    enumeration.name = "AEnum";
    enumeration.payload = AuthoredEnumerationDefinition{
        .representation = AuthoredEnumRepresentation::signed32,
        .cases = {
            {"minimum", std::numeric_limits<std::int32_t>::min()},
            {"zero", 0},
            {"maximum", std::numeric_limits<std::int32_t>::max()},
        },
    };
    authored.typeDefinitions.push_back(std::move(enumeration));

    AuthoredRecordField bitField = field(
        "flag", scalarAuthoredType(AuthoredScalarKind::unsigned32)
    );
    bitField.bitWidth = 3U;
    AuthoredTypeDefinition bitfieldRecord;
    bitfieldRecord.kind = AuthoredTypeDefinitionKind::recordStruct;
    bitfieldRecord.name = "ABitfield";
    bitfieldRecord.payload = AuthoredRecordDefinition{
        .kind = AuthoredNamedKind::struct_,
        .layoutRules = {},
        .fields = {std::move(bitField)},
    };
    authored.typeDefinitions.push_back(std::move(bitfieldRecord));

    auto flexibleElement = valueStorage(scalarAuthoredType(AuthoredScalarKind::unsigned8));
    auto flexibleStorage = std::make_shared<AuthoredFieldStorage>();
    flexibleStorage->tag = AuthoredFieldStorageTag::flexibleArray;
    flexibleStorage->payload = AuthoredFlexibleArrayStorage{std::move(flexibleElement)};
    AuthoredTypeDefinition flexibleRecord;
    flexibleRecord.kind = AuthoredTypeDefinitionKind::recordStruct;
    flexibleRecord.name = "AFlexible";
    flexibleRecord.payload = AuthoredRecordDefinition{
        .kind = AuthoredNamedKind::struct_,
        .layoutRules = {},
        .fields = {
            AuthoredRecordField{.name = "values", .storage = std::move(flexibleStorage)},
        },
    };
    authored.typeDefinitions.push_back(std::move(flexibleRecord));

    auto packedFirst = field("first", scalarAuthoredType(AuthoredScalarKind::unsigned8));
    packedFirst.minimumAlignment = 1U;
    auto packedSecond = field("second", scalarAuthoredType(AuthoredScalarKind::unsigned8));
    packedSecond.minimumAlignmentType = std::make_shared<AuthoredType>(
        scalarAuthoredType(AuthoredScalarKind::unsigned8)
    );
    AuthoredTypeDefinition packedRecord;
    packedRecord.kind = AuthoredTypeDefinitionKind::recordStruct;
    packedRecord.name = "APacked";
    packedRecord.payload = AuthoredRecordDefinition{
        .kind = AuthoredNamedKind::struct_,
        .layoutRules = {
            .isPacked = true,
            .packAlignment = 1U,
            .minimumAlignment = 1U,
        },
        .fields = {std::move(packedFirst), std::move(packedSecond)},
    };
    authored.typeDefinitions.push_back(std::move(packedRecord));

    AuthoredTypeDefinition structure;
    structure.kind = AuthoredTypeDefinitionKind::recordStruct;
    structure.name = "AStruct";
    structure.payload = AuthoredRecordDefinition{
        .kind = AuthoredNamedKind::struct_,
        .layoutRules = {},
        .fields = {field("value", scalarAuthoredType(AuthoredScalarKind::signed64))},
    };
    authored.typeDefinitions.push_back(std::move(structure));

    AuthoredTypeDefinition unionDefinition;
    unionDefinition.kind = AuthoredTypeDefinitionKind::recordUnion;
    unionDefinition.name = "AUnion";
    unionDefinition.payload = AuthoredRecordDefinition{
        .kind = AuthoredNamedKind::union_,
        .layoutRules = {},
        .fields = {
            field("integer", scalarAuthoredType(AuthoredScalarKind::unsigned32)),
            field("floating", scalarAuthoredType(AuthoredScalarKind::float32)),
        },
    };
    authored.typeDefinitions.push_back(std::move(unionDefinition));

    const std::array<AuthoredScalarKind, 12> scalarKinds = {
        AuthoredScalarKind::bool_, AuthoredScalarKind::char_,
        AuthoredScalarKind::signed8, AuthoredScalarKind::unsigned8,
        AuthoredScalarKind::signed16, AuthoredScalarKind::unsigned16,
        AuthoredScalarKind::signed32, AuthoredScalarKind::unsigned32,
        AuthoredScalarKind::signed64, AuthoredScalarKind::unsigned64,
        AuthoredScalarKind::float32, AuthoredScalarKind::float64,
    };
    for (std::size_t index = 0; index < scalarKinds.size(); ++index) {
        authored.typeDefinitions.push_back(scalarTypedefDefinition(
            "Scalar" + std::to_string(index), scalarKinds[index]
        ));
    }
    const std::array<AuthoredDarwinAliasKind, 6> aliasKinds = {
        AuthoredDarwinAliasKind::sizeT, AuthoredDarwinAliasKind::ssizeT,
        AuthoredDarwinAliasKind::intptrT, AuthoredDarwinAliasKind::uintptrT,
        AuthoredDarwinAliasKind::ptrdiffT, AuthoredDarwinAliasKind::wcharT,
    };
    for (std::size_t index = 0; index < aliasKinds.size(); ++index) {
        authored.typeDefinitions.push_back(authoredTypedefDefinition(
            "DarwinAlias" + std::to_string(index), darwinAuthoredType(aliasKinds[index])
        ));
    }

    auto qualifiedValue = scalarAuthoredType(AuthoredScalarKind::signed32);
    std::get<AuthoredQualifiedValue>(qualifiedValue.payload).qualifiers =
        static_cast<std::uint8_t>(AuthoredQualifier::constant) |
        static_cast<std::uint8_t>(AuthoredQualifier::volatile_);
    authored.typeDefinitions.push_back(
        authoredTypedefDefinition("QualifierValue", std::move(qualifiedValue))
    );
    auto qualifiedPointee = scalarAuthoredType(AuthoredScalarKind::signed32);
    std::get<AuthoredQualifiedValue>(qualifiedPointee.payload).qualifiers =
        static_cast<std::uint8_t>(AuthoredQualifier::constant);
    authored.typeDefinitions.push_back(authoredTypedefDefinition(
        "QualifierPointer",
        pointerAuthoredType(
            std::move(qualifiedPointee),
            {
                static_cast<std::uint8_t>(AuthoredQualifier::constant),
                static_cast<std::uint8_t>(AuthoredQualifier::volatile_) |
                    static_cast<std::uint8_t>(AuthoredQualifier::restrict_),
            }
        )
    ));

    auto fixedElement = valueStorage(scalarAuthoredType(AuthoredScalarKind::unsigned16));
    auto fixedStorage = std::make_shared<AuthoredFieldStorage>();
    fixedStorage->tag = AuthoredFieldStorageTag::fixedArray;
    fixedStorage->payload = AuthoredFixedArrayStorage{std::move(fixedElement), 3U};
    AuthoredTypeDefinition fixedArray;
    fixedArray.kind = AuthoredTypeDefinitionKind::typedef_;
    fixedArray.name = "StorageFixedArray";
    fixedArray.payload = AuthoredTypedefDefinition{std::move(fixedStorage)};
    authored.typeDefinitions.push_back(std::move(fixedArray));

    AuthoredInlineAggregateStorage inlineAggregate;
    inlineAggregate.kind = AuthoredNamedKind::struct_;
    inlineAggregate.layoutRules = {};
    inlineAggregate.fields = {
        field("left", scalarAuthoredType(AuthoredScalarKind::unsigned8)),
        field("right", scalarAuthoredType(AuthoredScalarKind::unsigned8)),
    };
    auto inlineStorage = std::make_shared<AuthoredFieldStorage>();
    inlineStorage->tag = AuthoredFieldStorageTag::inlineAggregate;
    inlineStorage->payload = std::move(inlineAggregate);
    AuthoredTypeDefinition inlineAlias;
    inlineAlias.kind = AuthoredTypeDefinitionKind::typedef_;
    inlineAlias.name = "StorageInline";
    inlineAlias.payload = AuthoredTypedefDefinition{std::move(inlineStorage)};
    authored.typeDefinitions.push_back(std::move(inlineAlias));

    AuthoredInlineAggregateStorage promotedInline;
    promotedInline.kind = AuthoredNamedKind::struct_;
    promotedInline.layoutRules = {};
    promotedInline.fields = {
        field("promoted", scalarAuthoredType(AuthoredScalarKind::unsigned8)),
    };
    auto promotedStorage = std::make_shared<AuthoredFieldStorage>();
    promotedStorage->tag = AuthoredFieldStorageTag::inlineAggregate;
    promotedStorage->payload = std::move(promotedInline);
    AuthoredRecordField promotedField{
        .name = "",
        .storage = std::move(promotedStorage),
        .promotesInlineFields = true,
    };
    AuthoredTypeDefinition promotedRecord;
    promotedRecord.kind = AuthoredTypeDefinitionKind::recordStruct;
    promotedRecord.name = "APromoted";
    promotedRecord.payload = AuthoredRecordDefinition{
        .kind = AuthoredNamedKind::struct_,
        .layoutRules = {},
        .fields = {std::move(promotedField)},
    };
    authored.typeDefinitions.push_back(std::move(promotedRecord));

    for (const auto [name, kind] : std::array{
             std::pair{"StorageOpaqueFunction", AuthoredOpaquePointerCarrierKind::functionPointer},
             std::pair{"StorageOpaqueArray", AuthoredOpaquePointerCarrierKind::pointerToArray},
         }) {
        auto carrier = std::make_shared<AuthoredFieldStorage>();
        carrier->tag = AuthoredFieldStorageTag::opaquePointerCarrier;
        carrier->payload = AuthoredOpaquePointerCarrierStorage{kind};
        AuthoredTypeDefinition definition;
        definition.kind = AuthoredTypeDefinitionKind::typedef_;
        definition.name = name;
        definition.payload = AuthoredTypedefDefinition{std::move(carrier)};
        authored.typeDefinitions.push_back(std::move(definition));
    }

    authored.typeDefinitions.push_back(authoredTypedefDefinition(
        "NamedEnumRef", namedAuthoredType(AuthoredNamedKind::enum_, "AEnum")
    ));
    authored.typeDefinitions.push_back(authoredTypedefDefinition(
        "NamedStructRef", namedAuthoredType(AuthoredNamedKind::struct_, "AStruct")
    ));
    authored.typeDefinitions.push_back(authoredTypedefDefinition(
        "NamedUnionRef", namedAuthoredType(AuthoredNamedKind::union_, "AUnion")
    ));
    authored.typeDefinitions.push_back(
        scalarTypedefDefinition("YBaseAlias", AuthoredScalarKind::unsigned64)
    );
    authored.typeDefinitions.push_back(authoredTypedefDefinition(
        "ZTypedefChain", namedAuthoredType(AuthoredNamedKind::typedef_, "YBaseAlias")
    ));

    const auto definitionCount = authored.typeDefinitions.size();
    auto request = makeRequest();
    request.authoredInputs = canonicalizedAuthoredInputs(std::move(authored));
    std::unordered_map<std::string, std::string> descriptors;
    auto observer = std::make_shared<GhidraProviderObserver>();
    observer->authoredTypeReadback = [&](std::string_view name, std::string_view descriptor) {
        descriptors.emplace(name, descriptor);
    };
    auto configuration = makeConfiguration();
    configuration.observer = std::move(observer);
    auto provider = makeGhidraProvider(std::move(configuration));
    const auto result = produceOrFail(
        [&] { return provider->produce(request, CancellationToken{}); },
        "authored complete type catalog"
    );
    if (!result) return;
    check(descriptors.size() == definitionCount,
          "every authored definition has one native readback descriptor");
    const auto contains = [&](std::string_view name, std::string_view needle) {
        const auto iterator = descriptors.find(std::string(name));
        return iterator != descriptors.end() && iterator->second.find(needle) != std::string::npos;
    };
    check(contains("AEnum", "enum=minimum:-2147483648") &&
              contains("AEnum", "enum=maximum:2147483647"),
          "signed32 enum extrema read back exactly");
    check(contains("ABitfield", "bitfield=flag:3"),
          "bit-field width reads back exactly");
    check(contains("AFlexible", "array-count=0"),
          "flexible array reads back as a zero-count final native array");
    check(contains("APacked", "align=1") && contains("APacked", "field=second@1"),
          "packed/minimum alignment and exact field order read back");
    check(contains("StorageFixedArray", "array-count=3"),
          "fixed array count reads back exactly");
    check(contains("StorageInline", "field=left@0") &&
              contains("StorageInline", "field=right@1"),
          "inline aggregate storage reads back exactly");
    check(contains("APromoted", "field=@0") &&
              contains("APromoted", "field=promoted@0"),
          "anonymous promoted inline aggregate reads back with its nested field");
    check(contains("StorageOpaqueFunction", "meta=11") &&
              contains("StorageOpaqueArray", "array-count=1"),
          "opaque function and pointer-to-array carriers remain distinct");
    check(contains("QualifierValue", "__macscope_authored_qualifier_") &&
              contains("QualifierPointer", "__macscope_authored_qualifier_"),
          "value and per-pointer-level qualifier identities read back natively");
    check(contains("NamedStructRef", "name=AStruct") &&
              contains("NamedUnionRef", "name=AUnion") &&
              contains("NamedEnumRef", "name=AEnum") &&
              contains("ZTypedefChain", "name=YBaseAlias"),
          "named kind references and typedef chains retain exact identity");
    const std::array<std::pair<int, int>, 12> scalarShape = {
        std::pair{1, 12}, std::pair{1, 14}, std::pair{1, 14}, std::pair{1, 13},
        std::pair{2, 14}, std::pair{2, 13}, std::pair{4, 14}, std::pair{4, 13},
        std::pair{8, 14}, std::pair{8, 13}, std::pair{4, 10}, std::pair{8, 10},
    };
    for (std::size_t index = 0; index < scalarShape.size(); ++index) {
        const auto [size, metatype] = scalarShape[index];
        check(contains(
                  "Scalar" + std::to_string(index),
                  "size=" + std::to_string(size) + ";align="
              ) && contains(
                  "Scalar" + std::to_string(index),
                  "meta=" + std::to_string(metatype)
              ),
              "every scalar kind retains exact native width and metatype");
    }
    const std::array<std::tuple<std::string_view, int, int>, 6> aliasShape = {
        std::tuple{"size_t", 8, 13}, std::tuple{"ssize_t", 8, 14},
        std::tuple{"intptr_t", 8, 14}, std::tuple{"uintptr_t", 8, 13},
        std::tuple{"ptrdiff_t", 8, 14}, std::tuple{"wchar_t", 4, 14},
    };
    for (std::size_t index = 0; index < aliasShape.size(); ++index) {
        const auto [name, size, metatype] = aliasShape[index];
        check(contains(
                  "DarwinAlias" + std::to_string(index),
                  "typedef={name=" + std::string(name) + ";size=" + std::to_string(size)
              ) && contains(
                  "DarwinAlias" + std::to_string(index),
                  "meta=" + std::to_string(metatype)
              ),
              "every Darwin alias retains exact width, signedness, and typedef identity");
    }
}

#include "CP4ContractCorpus.hpp"

} // namespace

int main(int argc, char* argv[]) {
    // CTest already runs these scenarios in dedicated processes. The core
    // group covers every other selector; no-argument execution still runs all
    // scenarios. The Python integration contract checks this inventory against
    // CMake's actual registrations so neither overlap nor omission is silent.
    constexpr std::array<std::string_view, 20> kSeparatelyRegisteredScenarios = {
        "cp4-contract-corpus",
        "rewritten-zero-op",
        "rewritten-multi-owner",
        "standalone-autibsp",
        "ordinary-vim-bodies",
        "apple-profile-readiness",
        "target-normalization",
        "pac-output",
        "pac-memory",
        "pac-control",
        "hidden-pac-contrast",
        "pac-bounds",
        "pac-cancellation",
        "authored-names-and-direct-calls",
        "authored-complete-type-catalog",
        "authored-signature-merge-matrix",
        "authored-parameter-storage",
        "authored-applied-noncode-objects",
        "authored-atomic-unsupported",
        "authored-application-cancellation",
    };
    std::optional<std::string_view> selectedScenario;
    bool coreScenariosOnly = false;
    if (argc == 3 && std::string_view(argv[1]) == "--export-cp4-corpus") {
        cp4CorpusOutputPath = argv[2];
        selectedScenario = "cp4-contract-corpus";
    } else if (argc == 3 && std::string_view(argv[1]) == "--scenario") {
        selectedScenario = argv[2];
    } else if (argc == 3 && std::string_view(argv[1]) == "--scenario-group" &&
               std::string_view(argv[2]) == "core") {
        coreScenariosOnly = true;
    } else if (argc != 1) {
        std::cerr << "usage: " << argv[0]
                  << " [--scenario <name> | --scenario-group core]\n";
        return EXIT_FAILURE;
    }
    const auto shouldRun = [&](std::string_view name) {
        if (coreScenariosOnly &&
            std::find(kSeparatelyRegisteredScenarios.begin(),
                      kSeparatelyRegisteredScenarios.end(), name) !=
                kSeparatelyRegisteredScenarios.end()) {
            return false;
        }
        return !selectedScenario || *selectedScenario == name;
    };
    bool ranScenario = false;

    if (shouldRun("dp13-typed-native-refusals")) {
        ranScenario = true;
        testDp13TypedNativeRefusals();
    }
    if (shouldRun("configuration")) {
        ranScenario = true;
        testUnsupportedConfigurationFailsClosed();
    }
    if (shouldRun("apple-profile-readiness")) {
        ranScenario = true;
        testAppleProfileReadiness();
    }
    if (shouldRun("target-normalization")) {
        ranScenario = true;
        testTargetNormalization();
    }
    if (shouldRun("authored-atomic-unsupported")) {
        ranScenario = true;
        testAuthoredAtomicUnsupported();
    }
    if (shouldRun("authored-application-cancellation")) {
        ranScenario = true;
        testAuthoredApplicationCancellation();
    }
    if (shouldRun("authored-names-and-direct-calls")) {
        ranScenario = true;
        testAuthoredNamesAndDirectCalls();
        testAuthoredTypedDataPointerCall();
        testCalleeSignatureHints();
        testAuthoredLocalNames();
    }
    if (shouldRun("authored-parameter-storage")) {
        ranScenario = true;
        testAuthoredParameterStorage();
        testCalleeSignatureHintStorage();
    }
    if (shouldRun("authored-signature-merge-matrix")) {
        ranScenario = true;
        testAuthoredSignatureMergeMatrix();
    }
    if (shouldRun("authored-applied-noncode-objects")) {
        ranScenario = true;
        testAuthoredAppliedNonCodeObjects();
    }
    if (shouldRun("authored-complete-type-catalog")) {
        ranScenario = true;
        testAuthoredCompleteTypeCatalog();
    }

    const bool needsSharedProvider = !selectedScenario ||
        (*selectedScenario != "dp13-typed-native-refusals" &&
         *selectedScenario != "configuration" &&
         *selectedScenario != "apple-profile-readiness" &&
         *selectedScenario != "target-normalization" &&
         *selectedScenario != "authored-atomic-unsupported" &&
         *selectedScenario != "authored-application-cancellation" &&
         *selectedScenario != "authored-names-and-direct-calls" &&
         *selectedScenario != "authored-signature-merge-matrix" &&
         *selectedScenario != "authored-parameter-storage" &&
         *selectedScenario != "authored-applied-noncode-objects" &&
         *selectedScenario != "authored-complete-type-catalog");
    std::unique_ptr<NativeStructuredProvider> provider;
    std::unique_ptr<StructuredDecompilerBackend> backend;
    if (needsSharedProvider) {
        provider = makeGhidraProvider(makeConfiguration());
        backend = makeGhidraBackend(makeConfiguration());
        check(provider != nullptr, "raw provider factory returns an implementation");
        check(backend != nullptr, "validated backend factory returns an implementation");
    }
    if (provider != nullptr && backend != nullptr) {
        if (shouldRun("identity")) {
            ranScenario = true;
            testProviderIdentityAndAvailability(*provider, *backend);
        }
        if (shouldRun("cancellation")) {
            ranScenario = true;
            testCancellationBeforeNativeWork(*provider, *backend);
        }
        if (shouldRun("request-configuration")) {
            ranScenario = true;
            testRequestLanguageAndCompilerMismatchFailClosed(*backend);
        }
        if (shouldRun("straight-line")) {
            ranScenario = true;
            testStraightLineEffectiveByteResultAndDeterminism(*backend);
        }
        if (shouldRun("pseudocode-bounds")) {
            ranScenario = true;
            testPseudocodeOutputIsBoundedAndUtf8Valid(*provider);
        }
        if (shouldRun("conditional-cfg")) {
            ranScenario = true;
            testConditionalMultiBlockCfg(*provider, *backend);
        }
        if (shouldRun("direct-call")) {
            ranScenario = true;
            testDirectCallAndSpecialSpaceMapping(*provider, *backend);
        }
        if (shouldRun("indirect-call")) {
            ranScenario = true;
            testIndirectCall(*backend);
        }
        if (shouldRun("indexed-dot-product")) {
            ranScenario = true;
            testIndexedDotProductElementOperands(*backend);
        }
        if (shouldRun("heritage")) {
            ranScenario = true;
            testNativeHeritageAndSameProcessDeterminism(*provider, *backend);
        }
        if (shouldRun("types")) {
            ranScenario = true;
            testNativeRecoveredTypes(*provider, *backend);
        }
        if (shouldRun("variables")) {
            ranScenario = true;
            testNativeRecoveredVariables(*provider, *backend);
        }
        if (shouldRun("bitmap-variable-identity")) {
            ranScenario = true;
            testBitmapVariableIdentity(*provider, *backend);
        }
        if (shouldRun("structured-regions")) {
            ranScenario = true;
            testNativeStructuredRegions(*backend);
        }
        if (shouldRun("tokens")) {
            ranScenario = true;
            testNativePseudocodeTokens(*provider, *backend);
        }
        if (shouldRun("loop-cfg")) {
            ranScenario = true;
            testLoopCfg(*provider, *backend);
        }
        if (shouldRun("load-store-space")) {
            ranScenario = true;
            testLoadStoreSpaceReference(*backend);
        }
        if (shouldRun("switch-cfg")) {
            ranScenario = true;
            testSwitchCfg(*provider, *backend);
        }
        if (shouldRun("switch-unmapped")) {
            ranScenario = true;
            testUnmappedSwitchTableFailsClosed(*provider);
        }
        if (shouldRun("fail-closed")) {
            ranScenario = true;
            testMalformedAndOutOfRangeFunctionsFailClosed(*provider);
        }
        const auto reportScenario = [&](const char* name, const std::function<void()>& run) {
            const auto before = failures;
            run();
            std::cout << "T1 scenario " << name << ": " << (failures == before ? "PASS" : "FAIL") << '\n';
        };
        if (shouldRun("x30-switch-non-frame-load")) {
            ranScenario = true;
            reportScenario("testX30NonFrameLoadPreservesRecoverableSwitch", [&] {
                testX30NonFrameLoadPreservesRecoverableSwitch(*provider);
            });
        }
        if (shouldRun("x30-switch-early-restore")) {
            ranScenario = true;
            reportScenario("testX30NonAdjacentRestorePreservesRecoverableSwitch", [&] {
                testX30NonAdjacentRestorePreservesRecoverableSwitch(*provider);
            });
        }
        if (shouldRun("final-call")) {
            ranScenario = true;
            testFinalCallIsTreatedAsNoReturn(*provider);
            testFinalCallStopDoesNotCutEarlierCallsToTheSameCallee(*provider);
            testX16BranchIsATailCallOnlyAsAVeneer(*provider);
            testTermDestinationExports(*provider);
            reportScenario("testIndirectTailCallAfterEpilogue", [&] {
                testIndirectTailCallAfterEpilogue(*provider);
            });
            testDocumentOnlyRequest(*provider);
            reportScenario("testJ12InitColorConverterSwitchLabels", [&] {
                testJ12InitColorConverterSwitchLabels(*provider);
            });
        }
        if (shouldRun("tail-call")) {
            ranScenario = true;
            testUnconditionalBranchOutOfRangeIsTailCall(*provider);
        }
        if (shouldRun("sparse-cave")) {
            ranScenario = true;
            testSparsePatchedBranchUsesFileBackedCave(*provider);
        }
        if (shouldRun("jsimd-idct-islow-cost")) {
            ranScenario = true;
            testJsimdIdctIslowNeonCost(*provider);
            testTokenMetadataOmittedWhenItCannotFit(*provider);
        }
        if (shouldRun("output-budget-v2")) {
            ranScenario = true;
            testOutputBudgetV2PreservesWeightedResult(*provider);
        }
        if (shouldRun("budgets")) {
            ranScenario = true;
            testRawProviderBudgetsFailClosed(*provider);
        }
        if (shouldRun("output-budget-diagnostics")) {
            ranScenario = true;
            testOutputBudgetDiagnostics(*provider, *backend);
        }
        if (shouldRun("hardening-bounds")) {
            ranScenario = true;
            testTraversalAndOutputBudgetBoundaries(*provider);
        }
        if (shouldRun("empty-entry-scaffold")) {
            ranScenario = true;
            testEmptyEntryScaffoldIsAcceptedWithoutPublishingPhantomState(*provider);
        }
        if (shouldRun("ordinary-vim-bodies")) {
            ranScenario = true;
            testOrdinaryVimBodies();
        }
        if (shouldRun("cp4-contract-corpus")) {
            ranScenario = true;
            testCP4ContractCorpus(*provider);
        }
        if (shouldRun("rewritten-zero-op")) {
            ranScenario = true;
            testRewrittenZeroOperationBlock(*provider);
        }
        if (shouldRun("rewritten-multi-owner")) {
            ranScenario = true;
            testRewrittenMultiOwnerInstruction(*provider);
        }
        if (shouldRun("standalone-autibsp")) {
            ranScenario = true;
            testStandaloneAutibsp(*provider);
        }
        if (shouldRun("pac-output")) {
            ranScenario = true;
            testPacOutputEffects(*provider);
        }
        if (shouldRun("pac-memory")) {
            ranScenario = true;
            testPacMemoryEffects(*provider);
        }
        if (shouldRun("pac-control")) {
            ranScenario = true;
            testPacControlEffects(*provider);
        }
        if (shouldRun("hidden-pac-contrast")) {
            ranScenario = true;
            testHiddenPacProfileCannotBeSelectedByEnvironment(*provider);
        }
        if (shouldRun("pac-bounds")) {
            ranScenario = true;
            testPacOutputBounds(*provider);
        }
        if (shouldRun("pac-cancellation")) {
            ranScenario = true;
            testPacCancellation(*provider);
        }
    }

    if (!ranScenario) {
        std::cerr << "unknown native provider test scenario: "
                  << *selectedScenario << '\n';
        return EXIT_FAILURE;
    }

    if (failures != 0) {
        std::cerr << failures << " native provider test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "MacScope native Ghidra provider tests passed\n";
    return EXIT_SUCCESS;
}
