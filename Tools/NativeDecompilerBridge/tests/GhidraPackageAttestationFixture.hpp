#pragma once

#include "../src/GhidraPackageAttestation.hpp"

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unistd.h>
#include <utility>
#include <vector>

#ifndef MACSCOPE_NATIVE_DECOMPILER_SANITIZER_PROFILE
#define MACSCOPE_NATIVE_DECOMPILER_SANITIZER_PROFILE "none"
#endif

namespace macscope::native_decompiler::test_support {

namespace detail = macscope::native_decompiler::detail;
namespace fs = std::filesystem;

inline constexpr std::string_view kAttestationFixtureSanitizerProfile =
    MACSCOPE_NATIVE_DECOMPILER_SANITIZER_PROFILE;

inline constexpr std::array<std::string_view, 4> kAppleSiliconCriticalPaths = {
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AppleSilicon.ldefs",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_AppleSilicon.sla",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.pspec",
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_apple.cspec",
};

[[nodiscard]] inline std::string fixtureSha256(const fs::path& path) {
    const auto command = "/usr/bin/shasum -a 256 " + path.string();
    std::unique_ptr<FILE, decltype(&::pclose)> stream(::popen(command.c_str(), "r"), ::pclose);
    if (!stream) throw std::runtime_error("sha256-process-failed");
    std::array<char, 80> output{};
    if (::fgets(output.data(), static_cast<int>(output.size()), stream.get()) == nullptr) {
        throw std::runtime_error("sha256-output-failed");
    }
    const std::string digest(output.data(), 64U);
    if (digest.size() != 64U || digest.find_first_not_of("0123456789abcdef") != std::string::npos) {
        throw std::runtime_error("sha256-output-invalid");
    }
    return digest;
}

class AttestationFixture final {
public:
    struct Options final {
        bool omitAppleSlaCriticalEntry;
        bool changeAppleSlaCriticalHash;
        bool substituteGenericAppleSla;
        bool mismatchCompleteTree;
        bool includeAppleSlaSuffixDecoy;
        bool emptyCriticalMap;
        bool fabricateCriticalEntry;
        // Valid synthetic fixtures follow the same compile-time boundary as the runtime.
        // Explicit overrides exist only to exercise production/sanitizer rejection tests.
        std::uint64_t manifestSchemaVersion = kAttestationFixtureSanitizerProfile == "none" ? 1U : 3U;
        std::string sanitizerProfile = std::string(kAttestationFixtureSanitizerProfile);
    };

    AttestationFixture() : AttestationFixture(Options{}) {}

    explicit AttestationFixture(Options options) : options_(options) {
        std::string pattern = "/private/tmp/MacScope-DCP05C-attestation-XXXXXX";
        pattern.push_back('\0');
        char* created = ::mkdtemp(pattern.data());
        if (created == nullptr) throw std::runtime_error("temporary-directory-failed");
        materializationRoot_ = created;
        packageRoot_ = materializationRoot_ / "package";
        processorSpecRoot_ = packageRoot_ /
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages";
        populate();
        writeManifest();
    }

    ~AttestationFixture() {
        std::error_code ignored;
        fs::remove_all(materializationRoot_, ignored);
    }

    AttestationFixture(const AttestationFixture&) = delete;
    AttestationFixture& operator=(const AttestationFixture&) = delete;

    [[nodiscard]] GhidraBackendConfiguration configuration() const {
        return {
            .packageRoot = packageRoot_.string(),
            .packageManifestSha256 = manifestSha256_,
            .processorSpecRoot = processorSpecRoot_.string(),
            .languageId = "AARCH64:LE:64:AppleSilicon",
            .compilerSpecId = "default",
        };
    }

    [[nodiscard]] detail::GhidraPackageAttestationExpectations expectations() const {
        return {
            .materializationRoot = materializationRoot_,
            .materializationManifestSha256 = manifestSha256_,
            .packageTreeSha256 = recordedTreeSha256_,
            .packageRoot = packageRoot_,
            .globalProcessorSpecRoot = packageRoot_ / "share/sleigh/specfiles",
            .processorSpecRoot = processorSpecRoot_,
        };
    }

    void removeLiteralAppleSlaAndRewriteIdentity() {
        if (!fs::remove(packageRoot_ / kAppleSiliconCriticalPaths[1])) {
            throw std::runtime_error("literal-apple-sla-removal-failed");
        }
        writeManifest();
    }

    void replaceManifestTextAndRewriteIdentity(std::string_view original, std::string_view replacement) {
        const auto path = materializationRoot_ / "MATERIALIZATION.json";
        std::ifstream stream(path, std::ios::binary);
        std::ostringstream contents;
        contents << stream.rdbuf();
        auto bytes = contents.str();
        const auto offset = bytes.find(original);
        if (!stream || offset == std::string::npos ||
            bytes.find(original, offset + original.size()) != std::string::npos) {
            throw std::runtime_error("fixture-manifest-mutation-not-unique");
        }
        bytes.replace(offset, original.size(), replacement);
        write(path, bytes);
        manifestSha256_ = fixtureSha256(path);
    }

private:
    static void write(const fs::path& path, std::string_view bytes) {
        fs::create_directories(path.parent_path());
        std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        if (!stream) throw std::runtime_error("temporary-file-open-failed");
        stream.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
        if (!stream) throw std::runtime_error("temporary-file-write-failed");
    }

    static std::string quoted(std::string_view value) {
        if (value.find_first_of("\\\"\n\r\t") != std::string_view::npos) {
            throw std::runtime_error("fixture-json-string-invalid");
        }
        return "\"" + std::string(value) + "\"";
    }

    void populate() {
        write(packageRoot_ / "lib/cmake/sleigh/sleighConfig.cmake", "config\n");
        write(packageRoot_ / "lib/libdecomp.a", "decomp\n");
        write(packageRoot_ / "lib/libsla.a", "sla\n");
        write(packageRoot_ / kAppleSiliconCriticalPaths[0], "apple-ldefs\n");
        if (options_.substituteGenericAppleSla) {
            write(processorSpecRoot_ / "AARCH64_Generic.sla", "generic-sla\n");
        } else {
            write(packageRoot_ / kAppleSiliconCriticalPaths[1], "apple-sla\n");
        }
        if (options_.includeAppleSlaSuffixDecoy) {
            write(processorSpecRoot_ / "000_AARCH64_AppleSilicon.sla", "suffix-decoy\n");
        }
        write(packageRoot_ / kAppleSiliconCriticalPaths[2], "apple-pspec\n");
        write(packageRoot_ / kAppleSiliconCriticalPaths[3], "apple-cspec\n");
    }

    void writeManifest() {
        std::vector<std::pair<std::string, fs::path>> files;
        for (const auto& entry : fs::recursive_directory_iterator(packageRoot_)) {
            if (entry.is_regular_file()) {
                files.emplace_back(
                    fs::relative(entry.path(), packageRoot_).generic_string(),
                    entry.path()
                );
            }
        }
        std::sort(files.begin(), files.end(), [](const auto& lhs, const auto& rhs) {
            return lhs.first < rhs.first;
        });

        std::map<std::string, std::string> critical;
        std::uint64_t totalBytes = 0;
        std::string treePreimage;
        for (const auto& [relative, path] : files) {
            const auto size = fs::file_size(path);
            const auto digest = fixtureSha256(path);
            totalBytes += size;
            critical.emplace(relative, digest);
            treePreimage += relative + '\0' + std::to_string(size) + '\0' + digest + '\0';
        }
        const auto preimagePath = materializationRoot_ / ".tree-preimage";
        write(preimagePath, treePreimage);
        const auto actualTreeSha256 = fixtureSha256(preimagePath);
        fs::remove(preimagePath);
        recordedTreeSha256_ = options_.mismatchCompleteTree
            ? std::string(64U, '0')
            : actualTreeSha256;
        const auto decompilerArchiveSha256 = critical.at("lib/libdecomp.a");
        const auto sleighArchiveSha256 = critical.at("lib/libsla.a");

        if (options_.omitAppleSlaCriticalEntry) {
            critical.erase(std::string(kAppleSiliconCriticalPaths[1]));
        }
        if (options_.changeAppleSlaCriticalHash) {
            critical[std::string(kAppleSiliconCriticalPaths[1])] = std::string(64U, '0');
        }
        if (options_.emptyCriticalMap) {
            critical.clear();
        }
        if (options_.fabricateCriticalEntry) {
            critical.clear();
            critical["totally/made/up.sla"] = std::string(64U, '0');
        }

        std::ostringstream criticalJson;
        criticalJson << '{';
        bool first = true;
        for (const auto& [relative, digest] : critical) {
            if (!first) criticalJson << ',';
            first = false;
            criticalJson << quoted(relative) << ':' << quoted(digest);
        }
        criticalJson << '}';

        std::ostringstream manifest;
        manifest << '{';
        if (options_.manifestSchemaVersion == 1U) {
            manifest << "\"artifact\":{"
            << "\"filename\":\"macOS-sleigh-12.1.2-1.arm64.tar.gz\","
            << "\"platform\":\"macos-arm64\","
            << "\"sha256\":\"e1391c811de7b2d79c9e8a1f6f74cd9ade23baf55deebd75c626a3152e5e451a\","
            << "\"url\":\"https://github.com/lifting-bits/sleigh/releases/download/v12.1.2/macOS-sleigh-12.1.2-1.arm64.tar.gz\"},";
        }
        const auto componentId = options_.manifestSchemaVersion == 1U ? "sleigh-native-dcp03b4"
            : options_.manifestSchemaVersion == 2U ? "sleigh-native-source-dcp03b4"
            : "sleigh-native-sanitizer-source-dcp03b4";
        manifest
            << "\"componentId\":" << quoted(componentId) << ','
            << "\"ghidraGitRevision\":\"c0f584bf229fffba61b36431f3ce30c0c3e4e682\","
            << "\"ghidraVersion\":\"12.1.2\","
            << "\"package\":{"
            << "\"cmakeConfigRelativePath\":\"lib/cmake/sleigh/sleighConfig.cmake\","
            << "\"criticalFileSha256\":" << criticalJson.str() << ','
            << "\"decompilerLibraryRelativePath\":\"lib/libdecomp.a\","
            << "\"fileCount\":" << files.size() << ','
            << "\"processorSpecRelativeRoot\":\"share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages\","
            << "\"relativeRoot\":\"package\","
            << "\"sleighLibraryRelativePath\":\"lib/libsla.a\","
            << "\"totalBytes\":" << totalBytes << ','
            << "\"treeSha256\":" << quoted(recordedTreeSha256_) << "},";
        if (options_.manifestSchemaVersion == 3U) {
            manifest << "\"sanitizer\":" << quoted(options_.sanitizerProfile) << ',';
        }
        manifest
            << "\"schemaVersion\":" << options_.manifestSchemaVersion << ','
            << "\"sleighGitRevision\":\"bfd38a983b4aa53dd386365e1df5ed5499b7e2fb\","
            << "\"sleighVersion\":\"12.1.2\"";
        if (options_.manifestSchemaVersion != 1U) {
            manifest << ",\"sourceBuild\":{"
                << "\"buildOptions\":[\"fixture\"],"
                << "\"ghidraGitTree\":" << quoted(std::string(40U, 'a')) << ','
                << "\"ghidraTreeSha256\":" << quoted(std::string(64U, 'a')) << ',';
            if (options_.manifestSchemaVersion == 3U) {
                manifest << "\"instrumentation\":{\"archiveSha256\":{"
                    << "\"lib/libdecomp.a\":" << quoted(decompilerArchiveSha256) << ','
                    << "\"lib/libsla.a\":" << quoted(sleighArchiveSha256) << "},"
                    << "\"compileCommandsSha256\":" << quoted(std::string(64U, 'a')) << ','
                    << "\"profile\":" << quoted(options_.sanitizerProfile) << ','
                    << "\"sdkRoot\":\"/fixture/sdk\","
                    << "\"sdkSettingsSha256\":" << quoted(std::string(64U, 'b')) << ','
                    << "\"translationUnitCounts\":{\"sleigh_decomp\":1,\"sleigh_sla\":1}},";
            }
            manifest << "\"patches\":[\"fixture\"],"
                << "\"sleighGitTree\":" << quoted(std::string(40U, 'a')) << ','
                << "\"sleighTreeSha256\":" << quoted(std::string(64U, 'a')) << ','
                << "\"sourceManifestSha256\":" << quoted(std::string(64U, 'a')) << ','
                << "\"toolchain\":{\"architecture\":\"arm64\"}}";
        }
        manifest << "}\n";
        const auto manifestPath = materializationRoot_ / "MATERIALIZATION.json";
        write(manifestPath, manifest.str());
        manifestSha256_ = fixtureSha256(manifestPath);
    }

    Options options_;
    fs::path materializationRoot_;
    fs::path packageRoot_;
    fs::path processorSpecRoot_;
    std::string manifestSha256_;
    std::string recordedTreeSha256_;
};

} // namespace macscope::native_decompiler::test_support
