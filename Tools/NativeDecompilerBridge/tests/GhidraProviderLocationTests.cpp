#include "MacScopeNativeDecompiler/Backend.hpp"
#include "MacScopeNativeDecompiler/GhidraProvider.hpp"
#include "GhidraPackageAttestationFixture.hpp"

#include <algorithm>
#include <filesystem>
#include <iostream>
#include <string>
#include <string_view>
#include <utility>

#if !defined(MACSCOPE_TEST_SLEIGH_MATERIALIZATION_ROOT)
#error "location tests require MACSCOPE_TEST_SLEIGH_MATERIALIZATION_ROOT"
#endif
#if !defined(MACSCOPE_TEST_SLEIGH_MANIFEST_SHA256)
#error "location tests require MACSCOPE_TEST_SLEIGH_MANIFEST_SHA256"
#endif
#if !defined(MACSCOPE_TEST_SLEIGH_TREE_SHA256)
#error "location tests require MACSCOPE_TEST_SLEIGH_TREE_SHA256"
#endif

using namespace macscope::native_decompiler;
namespace fs = std::filesystem;
namespace detail = macscope::native_decompiler::detail;
using macscope::native_decompiler::test_support::AttestationFixture;

namespace {

int failures = 0;

void check(bool condition, std::string_view message) {
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

template <typename Function>
void expectStableContractError(Function function, std::string_view expected) {
    try {
        function();
        ++failures;
        std::cerr << "FAIL: expected ContractError: " << expected << '\n';
    } catch (const ContractError& error) {
        check(error.what() == expected, "invalid roots use the stable path-free reason");
    } catch (...) {
        ++failures;
        std::cerr << "FAIL: invalid root raised a non-contract exception\n";
    }
}

} // namespace

int main() {
    {
        AttestationFixture fixture({.includeAppleSlaSuffixDecoy = true});
        try {
            (void)detail::attestGhidraPackage(
                fixture.configuration(), fixture.expectations()
            );
        } catch (const std::exception& error) {
            ++failures;
            std::cerr << "FAIL: literal Apple SLA plus suffix decoy rejected: "
                      << error.what() << '\n';
        }

    }

    const fs::path materializationRoot(MACSCOPE_TEST_SLEIGH_MATERIALIZATION_ROOT);
    const auto configuration = makeGhidraBackendConfigurationForMaterialization(
        materializationRoot.string(),
        "AARCH64:LE:64:AppleSilicon",
        "default"
    );
    check(
        fs::path(configuration.packageRoot) == materializationRoot / "package",
        "helper derives the frozen package relationship"
    );
    check(
        fs::path(configuration.processorSpecRoot) ==
            materializationRoot /
                "package/share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages",
        "helper derives the frozen processor-spec relationship"
    );
    check(
        configuration.packageManifestSha256 == MACSCOPE_TEST_SLEIGH_MANIFEST_SHA256,
        "helper retains the compiled exact manifest digest"
    );
    check(
        configuration.languageId == "AARCH64:LE:64:AppleSilicon",
        "helper retains the Apple-Silicon language ID"
    );
    check(configuration.compilerSpecId == "default", "helper retains compiler-spec ID");

    try {
        const auto provider = makeGhidraProvider(configuration);
        const auto availability = provider->availability();
        check(
            availability.available,
            "helper configuration initializes the fully attested native provider"
        );
        check(availability.runtimeIdentity.has_value(),
              "explicit-root provider publishes its prepared runtime identity");
        const auto isCanonicalDigest = [](std::string_view value, std::size_t length) {
            return value.size() == length &&
                std::all_of(value.begin(), value.end(), [](unsigned char character) {
                    return (character >= '0' && character <= '9') ||
                        (character >= 'a' && character <= 'f');
                });
        };
        if (availability.runtimeIdentity) {
            const auto& identity = *availability.runtimeIdentity;
            check(identity.backendId == "ghidra-native-decompiler",
                  "explicit-root provider publishes the frozen backend ID");
            check(identity.engineVersion == "12.1.2",
                  "explicit-root provider publishes the compiled engine version");
            check(
                identity.engineRevision ==
                    "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
                "explicit-root provider publishes the compiled engine revision"
            );
            check(identity.wrapperVersion == "dcp05c-v1",
                  "explicit-root provider publishes the compiled wrapper version");
            check(isCanonicalDigest(identity.wrapperRevision, 40U) ||
                      isCanonicalDigest(identity.wrapperRevision, 64U),
                  "explicit-root provider publishes a canonical wrapper revision");
            check(identity.packageManifestSha256 == MACSCOPE_TEST_SLEIGH_MANIFEST_SHA256,
                  "explicit-root provider publishes the compiled attested manifest digest");
            check(
                identity.packageTreeSha256 ==
                    MACSCOPE_TEST_SLEIGH_TREE_SHA256,
                "explicit-root provider publishes the exact attested complete-tree digest"
            );
            check(identity.languageId == "AARCH64:LE:64:AppleSilicon" &&
                      identity.compilerSpecId == "default",
                  "explicit-root provider publishes only its prepared language/compiler pair");
            check(identity.targetProfileId == "apple-aarch64-pac-visible-clobber-v1",
                  "explicit-root provider publishes the sealed target profile");
            check(
                identity.contextProfileSha256 ==
                    "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5",
                "explicit-root provider publishes the applied context profile"
            );
        }
    } catch (const std::exception& error) {
        ++failures;
        std::cerr << "FAIL: explicit-root provider initialization failed: "
                  << error.what() << '\n';
    }

    expectStableContractError(
        [&configuration] {
            auto mismatched = configuration;
            mismatched.processorSpecRoot += ".mismatch";
            (void)makeGhidraProvider(std::move(mismatched));
        },
        "package-attestation-configuration-mismatch"
    );

    expectStableContractError(
        [] {
            (void)makeGhidraBackendConfigurationForMaterialization(
                "relative/materialization", "AARCH64:LE:64:AppleSilicon", "default"
            );
        },
        "native-provider-materialization-root-invalid"
    );
    expectStableContractError(
        [] {
            (void)makeGhidraBackendConfigurationForMaterialization(
                "/private/tmp/../tmp/materialization",
                "AARCH64:LE:64:AppleSilicon",
                "default"
            );
        },
        "native-provider-materialization-root-invalid"
    );

    if (failures != 0) {
        std::cerr << failures << " provider location test(s) failed\n";
        return 1;
    }
    std::cout << "Ghidra provider location tests passed\n";
    return 0;
}
