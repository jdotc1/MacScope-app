#include "GhidraPackageAttestation.hpp"
#include "GhidraPackageAttestationFixture.hpp"

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace detail = macscope::native_decompiler::detail;
namespace fs = std::filesystem;

namespace {

int failures = 0;

using macscope::native_decompiler::test_support::AttestationFixture;

void check(bool condition, std::string_view message) {
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

void expectAttestationRejected(const AttestationFixture& fixture, std::string_view scenario,
                              std::string_view expectedReason = {}) {
    try {
        (void)detail::attestGhidraPackage(fixture.configuration(), fixture.expectations());
        ++failures;
        std::cerr << "FAIL: expected package attestation rejection: " << scenario << '\n';
    } catch (const detail::GhidraPackageAttestationError& error) {
        if (!expectedReason.empty()) {
            check(error.reasonCode() == expectedReason,
                  std::string(scenario) + " rejected at the expected authority boundary");
        }
    }
}

void expectAttestationRejected(AttestationFixture::Options options, std::string_view scenario,
                              std::string_view expectedReason = {}) {
    AttestationFixture fixture(options);
    expectAttestationRejected(fixture, scenario, expectedReason);
}

void expectManifestMutationRejected(std::string_view original, std::string_view replacement,
                                   std::string_view scenario, std::string_view expectedReason) {
    AttestationFixture fixture;
    fixture.replaceManifestTextAndRewriteIdentity(original, replacement);
    expectAttestationRejected(fixture, scenario, expectedReason);
}

void expectAttestationAccepted(AttestationFixture::Options options, std::string_view scenario) {
    AttestationFixture fixture(options);
    try {
        (void)detail::attestGhidraPackage(fixture.configuration(), fixture.expectations());
    } catch (const std::exception& error) {
        ++failures;
        std::cerr << "FAIL: expected package attestation acceptance: " << scenario
                  << ": " << error.what() << '\n';
    }
}

class TemporaryTree final {
public:
    TemporaryTree() {
        std::string pattern = "/private/tmp/MacScope-DCP03B5-attestation-XXXXXX";
        pattern.push_back('\0');
        char* created = ::mkdtemp(pattern.data());
        if (created == nullptr) throw std::runtime_error("temporary-directory-failed");
        root_ = created;
        populate(root_);
    }

    ~TemporaryTree() {
        std::error_code ignored;
        fs::remove_all(root_, ignored);
        fs::remove_all(replacedRoot_, ignored);
    }

    TemporaryTree(const TemporaryTree&) = delete;
    TemporaryTree& operator=(const TemporaryTree&) = delete;

    [[nodiscard]] const fs::path& root() const noexcept { return root_; }

    void replaceRootDirectory() {
        replacedRoot_ = root_.string() + ".replaced";
        fs::rename(root_, replacedRoot_);
        populate(root_);
    }

    void replaceNestedDirectory() {
        const auto original = root_ / "spec" / "nested";
        const auto replaced = root_ / "spec" / "nested.replaced";
        fs::rename(original, replaced);
        fs::create_directory(original);
        write(original / "beta.sla", "bravo");
        fs::remove_all(replaced);
    }

    void rewriteAlphaSameSize() {
        write(root_ / "alpha.bin", "omega");
    }

    void addDeepHierarchy(std::size_t depth) {
        auto current = root_ / "deep";
        for (std::size_t index = 0; index < depth; ++index) {
            current /= "d";
        }
        fs::create_directories(current);
        write(current / "leaf.bin", "leaf");
    }

    void addEmptyDirectory() {
        fs::create_directory(root_ / "empty");
    }

    void addFifo() {
        if (::mkfifo((root_ / "named-pipe").c_str(), 0600) != 0) {
            throw std::runtime_error("temporary-fifo-create-failed");
        }
    }

private:
    static void write(const fs::path& path, std::string_view bytes) {
        std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        if (!stream) throw std::runtime_error("temporary-file-open-failed");
        stream.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
        if (!stream) throw std::runtime_error("temporary-file-write-failed");
    }

    static void populate(const fs::path& root) {
        fs::create_directories(root / "spec" / "nested");
        write(root / "alpha.bin", "alpha");
        write(root / "spec" / "nested" / "beta.sla", "bravo");
    }

    fs::path root_;
    fs::path replacedRoot_;
};

template <typename Mutation>
void expectContentDrift(Mutation mutation, std::string_view scenario) {
    TemporaryTree tree;
    const auto lease = detail::captureGhidraClosedTreeIdentityForTesting(tree.root());
    mutation(tree);
    try {
        detail::revalidateGhidraClosedTreeIdentityForTesting(lease);
        ++failures;
        std::cerr << "FAIL: expected content drift: " << scenario << '\n';
    } catch (const detail::GhidraPackageAttestationError& error) {
        check(
            error.reasonCode() == "package-attestation-content-drift",
            std::string(scenario) + " has the stable content-drift reason"
        );
    }
}

} // namespace

int main() {
    {
        AttestationFixture fixture;
        try {
            const auto expectations = fixture.expectations();
            const auto attestation = detail::attestGhidraPackage(
                fixture.configuration(), expectations
            );
            check(
                attestation.materializationManifestSha256 ==
                    expectations.materializationManifestSha256,
                "attestation publishes only the verified manifest digest"
            );
            check(
                attestation.packageTreeSha256 == expectations.packageTreeSha256,
                "attestation publishes only the verified complete-tree digest"
            );
            check(
                attestation.materializationRoot == expectations.materializationRoot &&
                    attestation.packageRoot == expectations.packageRoot &&
                    attestation.globalProcessorSpecRoot ==
                        expectations.globalProcessorSpecRoot &&
                    attestation.processorSpecRoot == expectations.processorSpecRoot,
                "attestation publishes the exact canonical package roots"
            );
            check(
                attestation.directoryIdentity != nullptr,
                "attestation retains the verified closed-tree directory identity"
            );
        } catch (const std::exception& error) {
            ++failures;
            std::cerr << "FAIL: exact Apple Silicon critical set rejected: "
                      << error.what() << '\n';
        }
    }

    expectAttestationAccepted(
        {.omitAppleSlaCriticalEntry = true},
        "critical-map entry omission with an unchanged complete identity"
    );
    expectAttestationRejected(
        {.changeAppleSlaCriticalHash = true},
        "critical-map digest drift against the observed closed tree"
    );
    expectAttestationRejected(
        {.emptyCriticalMap = true},
        "empty critical-map summary"
    );
    expectAttestationRejected(
        {.fabricateCriticalEntry = true},
        "fabricated critical-map path"
    );
    expectAttestationAccepted(
        {.substituteGenericAppleSla = true},
        "synthetic resource substitution incorporated into its complete identity"
    );
    expectAttestationRejected(
        {.mismatchCompleteTree = true},
        "complete-tree mismatch independent of critical hashes"
    );

    // Configuration and expectations deliberately expose no sanitizer override. Even when a
    // synthetic caller knows the exact manifest and tree hashes, the compiled profile wins.
    constexpr auto compiledProfile =
        macscope::native_decompiler::test_support::kAttestationFixtureSanitizerProfile;
    for (const std::uint64_t schema : {1U, 2U}) {
        const AttestationFixture::Options options{.manifestSchemaVersion = schema};
        if (compiledProfile == "none") {
            expectAttestationAccepted(options, "ordinary package in a production-profile bridge");
        } else {
            expectAttestationRejected(options, "ordinary package in a sanitizer-profile bridge",
                                      "package-attestation-sanitizer-mismatch");
        }
    }
    for (const auto profile : {"address", "undefined", "none", "thread"}) {
        const AttestationFixture::Options options{
            .manifestSchemaVersion = 3U,
            .sanitizerProfile = profile,
        };
        if (compiledProfile != "none" && compiledProfile == profile) {
            expectAttestationAccepted(options, "matching compiled sanitizer source package");
        } else {
            expectAttestationRejected(options, "foreign or unsupported sanitizer source package",
                                      "package-attestation-sanitizer-mismatch");
        }
    }
    if (compiledProfile != "none") {
        const auto otherProfile = compiledProfile == "address" ? "undefined" : "address";
        expectManifestMutationRejected(
            "\"profile\":\"" + std::string(compiledProfile) + "\"",
            "\"profile\":\"" + std::string(otherProfile) + "\"",
            "instrumentation profile disagrees with top-level sanitizer",
            "package-attestation-sanitizer-mismatch");
        expectManifestMutationRejected(
            "\"componentId\":\"sleigh-native-sanitizer-source-dcp03b4\"",
            "\"componentId\":\"sleigh-native-source-dcp03b4\"",
            "sanitizer schema reuses ordinary source component identity",
            "package-attestation-identity-mismatch");
        expectManifestMutationRejected(
            "{\"componentId\":", "{\"additional\":0,\"componentId\":",
            "extra top-level key", "package-attestation-manifest-invalid");
        expectManifestMutationRejected(
            "\"sourceBuild\":{\"buildOptions\":", "\"sourceBuild\":{\"additional\":0,\"buildOptions\":",
            "extra source-build key", "package-attestation-manifest-invalid");
        expectManifestMutationRejected(
            "\"instrumentation\":{\"archiveSha256\":", "\"instrumentation\":{\"additional\":0,\"archiveSha256\":",
            "extra instrumentation key", "package-attestation-manifest-invalid");
        expectManifestMutationRejected(
            "\"sdkRoot\":\"/fixture/sdk\",", "",
            "missing instrumentation field", "package-attestation-manifest-invalid");
        expectManifestMutationRejected(
            "\"sdkRoot\":\"/fixture/sdk\"", "\"sdkRoot\":\"relative-sdk\"",
            "relative SDK root", "package-attestation-manifest-invalid");
        expectManifestMutationRejected(
            "\"compileCommandsSha256\":\"" + std::string(64U, 'a') + "\"",
            "\"compileCommandsSha256\":\"" + std::string(64U, 'A') + "\"",
            "noncanonical compilation database digest", "package-attestation-manifest-invalid");
        expectManifestMutationRejected(
            "\"sdkSettingsSha256\":\"" + std::string(64U, 'b') + "\"",
            "\"sdkSettingsSha256\":\"b\"",
            "truncated SDK settings digest", "package-attestation-manifest-invalid");
        for (const auto target : {"sleigh_decomp", "sleigh_sla"}) {
            expectManifestMutationRejected(
                "\"" + std::string(target) + "\":1", "\"" + std::string(target) + "\":0",
                "archive has no instrumented translation units", "package-attestation-manifest-invalid");
        }
        expectManifestMutationRejected(
            "\"translationUnitCounts\":{\"sleigh_decomp\":1,\"sleigh_sla\":1}",
            "\"translationUnitCounts\":{\"sleigh_decomp\":1,\"sleigh_extra\":1,\"sleigh_sla\":1}",
            "unknown translation-unit target", "package-attestation-manifest-invalid");
        expectManifestMutationRejected(
            "\"translationUnitCounts\":{\"sleigh_decomp\":1,\"sleigh_sla\":1}",
            "\"translationUnitCounts\":{\"sleigh_decomp\":1,\"sleigh_sla\":\"1\"}",
            "noninteger translation-unit count", "package-attestation-manifest-invalid");
        {
            AttestationFixture fixture;
            const auto digest = macscope::native_decompiler::test_support::fixtureSha256(
                fixture.expectations().packageRoot / "lib/libdecomp.a");
            fixture.replaceManifestTextAndRewriteIdentity(
                "\"archiveSha256\":{\"lib/libdecomp.a\":\"" + digest + "\"",
                "\"archiveSha256\":{\"lib/libdecomp.a\":\"" + std::string(64U, '0') + "\"");
            expectAttestationRejected(fixture, "instrumented archive digest disagrees with critical file",
                                      "package-attestation-identity-mismatch");
        }
        {
            AttestationFixture fixture;
            const auto digest = macscope::native_decompiler::test_support::fixtureSha256(
                fixture.expectations().packageRoot / "lib/libsla.a");
            fixture.replaceManifestTextAndRewriteIdentity(
                ",\"lib/libsla.a\":\"" + digest + "\"}", "}");
            expectAttestationRejected(fixture, "missing instrumented archive entry",
                                      "package-attestation-manifest-invalid");
        }
    }

    {
        const auto memberLimit = detail::ghidraClosedTreeMaximumMembersForTesting();
        check(memberLimit > 0U, "member identity limit is nonzero");
        check(
            !detail::ghidraClosedTreeMemberBudgetExceededForTesting(memberLimit - 1U),
            "member identity limit-minus-one is accepted"
        );
        check(
            !detail::ghidraClosedTreeMemberBudgetExceededForTesting(memberLimit),
            "exact member identity limit is accepted"
        );
        check(
            detail::ghidraClosedTreeMemberBudgetExceededForTesting(memberLimit + 1U),
            "member identity limit-plus-one is rejected"
        );

        const auto pathByteLimit = detail::ghidraClosedTreeMaximumPathBytesForTesting();
        check(pathByteLimit > 0U, "path identity byte limit is nonzero");
        check(
            !detail::ghidraClosedTreePathBudgetExceededForTesting(pathByteLimit - 1U),
            "path identity byte limit-minus-one is accepted"
        );
        check(
            !detail::ghidraClosedTreePathBudgetExceededForTesting(pathByteLimit),
            "exact path identity byte limit is accepted"
        );
        check(
            detail::ghidraClosedTreePathBudgetExceededForTesting(pathByteLimit + 1U),
            "path identity byte limit-plus-one is rejected"
        );
    }

    {
        TemporaryTree tree;
        const auto lease = detail::captureGhidraClosedTreeIdentityForTesting(tree.root());
        try {
            detail::revalidateGhidraClosedTreeIdentityForTesting(lease);
        } catch (const std::exception& error) {
            ++failures;
            std::cerr << "FAIL: unchanged tree rejected: " << error.what() << '\n';
        }
    }

    {
        TemporaryTree tree;
        const auto lease = detail::captureGhidraClosedTreeIdentityForTesting(tree.root());
        bool replaced = false;
        try {
            detail::revalidateGhidraClosedTreeIdentityForTesting(
                lease,
                [&](std::string_view relativePath) {
                    if (!replaced && relativePath == "spec/nested/beta.sla") {
                        tree.replaceRootDirectory();
                        replaced = true;
                    }
                }
            );
            ++failures;
            std::cerr << "FAIL: expected path drift: in-scan root replacement\n";
        } catch (const detail::GhidraPackageAttestationError& error) {
            check(replaced, "in-scan root replacement hook ran during traversal");
            check(
                error.reasonCode() == "package-attestation-path-drift",
                "in-scan root replacement has the stable path-drift reason"
            );
        }
    }

    expectContentDrift([](TemporaryTree& tree) {
        std::ofstream stream(tree.root() / "alpha.bin", std::ios::binary | std::ios::trunc);
        stream << "omega";
    }, "same-size content rewrite");

    expectContentDrift([](TemporaryTree& tree) {
        const auto replacement = tree.root() / "replacement.bin";
        {
            std::ofstream stream(replacement, std::ios::binary | std::ios::trunc);
            stream << "alpha";
        }
        fs::rename(replacement, tree.root() / "alpha.bin");
    }, "inode replacement");

    expectContentDrift([](TemporaryTree& tree) {
        std::ofstream stream(tree.root() / "added.bin", std::ios::binary | std::ios::trunc);
        stream << "added";
    }, "added file");

    expectContentDrift([](TemporaryTree& tree) {
        fs::remove(tree.root() / "alpha.bin");
    }, "removed file");

    expectContentDrift([](TemporaryTree& tree) {
        const auto target = tree.root() / "spec" / "nested" / "beta.sla";
        fs::remove(target);
        fs::create_symlink("../../../alpha.bin", target);
    }, "symlink substitution");

    expectContentDrift([](TemporaryTree& tree) {
        const auto target = tree.root() / "alpha.bin";
        struct stat status {};
        if (::stat(target.c_str(), &status) != 0 ||
            ::chmod(target.c_str(), status.st_mode ^ S_IXUSR) != 0) {
            throw std::runtime_error("temporary-file-mode-change-failed");
        }
    }, "file metadata drift");

    {
        TemporaryTree tree;
        const auto lease = detail::captureGhidraClosedTreeIdentityForTesting(tree.root());
        bool mutated = false;
        try {
            detail::revalidateGhidraClosedTreeIdentityForTesting(
                lease,
                [&](std::string_view relativePath) {
                    if (!mutated && relativePath == "spec/nested/beta.sla") {
                        tree.rewriteAlphaSameSize();
                        mutated = true;
                    }
                }
            );
            ++failures;
            std::cerr << "FAIL: expected content drift: in-scan rewrite\n";
        } catch (const detail::GhidraPackageAttestationError& error) {
            check(mutated, "in-scan rewrite hook ran after the earlier file was scanned");
            check(
                error.reasonCode() == "package-attestation-content-drift",
                "in-scan rewrite has the stable content-drift reason"
            );
        }
    }

    {
        TemporaryTree tree;
        tree.addDeepHierarchy(257U);
        try {
            (void)detail::captureGhidraClosedTreeIdentityForTesting(tree.root());
            ++failures;
            std::cerr << "FAIL: expected bounded layout rejection: excessive depth\n";
        } catch (const detail::GhidraPackageAttestationError& error) {
            check(
                error.reasonCode() == "package-attestation-layout-invalid",
                "excessive depth has the stable layout-invalid reason"
            );
        }
    }

    {
        TemporaryTree tree;
        tree.addEmptyDirectory();
        try {
            (void)detail::captureGhidraClosedTreeIdentityForTesting(tree.root());
            ++failures;
            std::cerr << "FAIL: expected bounded layout rejection: empty directory\n";
        } catch (const detail::GhidraPackageAttestationError& error) {
            check(
                error.reasonCode() == "package-attestation-layout-invalid",
                "empty directory has the stable layout-invalid reason"
            );
        }
    }

    {
        TemporaryTree tree;
        tree.addFifo();
        try {
            (void)detail::captureGhidraClosedTreeIdentityForTesting(tree.root());
            ++failures;
            std::cerr << "FAIL: expected bounded layout rejection: FIFO member\n";
        } catch (const detail::GhidraPackageAttestationError& error) {
            check(
                error.reasonCode() == "package-attestation-layout-invalid",
                "FIFO member has the stable layout-invalid reason"
            );
        }
    }

    {
        TemporaryTree tree;
        const auto lease = detail::captureGhidraClosedTreeIdentityForTesting(tree.root());
        tree.replaceNestedDirectory();
        try {
            detail::revalidateGhidraClosedTreeIdentityForTesting(lease);
            ++failures;
            std::cerr << "FAIL: expected path drift: nested directory replacement\n";
        } catch (const detail::GhidraPackageAttestationError& error) {
            check(
                error.reasonCode() == "package-attestation-path-drift",
                "nested directory replacement retains the stable path-drift reason"
            );
        }
    }

    {
        TemporaryTree tree;
        const auto lease = detail::captureGhidraClosedTreeIdentityForTesting(tree.root());
        tree.replaceRootDirectory();
        try {
            detail::revalidateGhidraClosedTreeIdentityForTesting(lease);
            ++failures;
            std::cerr << "FAIL: expected path drift: directory replacement\n";
        } catch (const detail::GhidraPackageAttestationError& error) {
            check(
                error.reasonCode() == "package-attestation-path-drift",
                "directory replacement retains the stable path-drift reason"
            );
        }
    }

    if (failures != 0) {
        std::cerr << failures << " package identity test(s) failed\n";
        return 1;
    }
    std::cout << "Ghidra package identity tests passed\n";
    return 0;
}
