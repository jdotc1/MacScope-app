#include "GhidraPackageAttestation.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <dirent.h>
#include <fcntl.h>
#include <filesystem>
#include <initializer_list>
#include <limits>
#include <map>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <variant>
#include <vector>

#ifndef MACSCOPE_NATIVE_DECOMPILER_SANITIZER_PROFILE
#define MACSCOPE_NATIVE_DECOMPILER_SANITIZER_PROFILE "none"
#endif

namespace macscope::native_decompiler::detail {

struct GhidraClosedTreeMemberIdentity final {
    std::string relativePath;
    struct stat identity {};
};

class GhidraDirectoryIdentityLease final {
public:
    GhidraDirectoryIdentityLease(
        const std::vector<std::filesystem::path>& paths,
        const std::filesystem::path& closedTreeRoot
    );
    ~GhidraDirectoryIdentityLease();

    GhidraDirectoryIdentityLease(const GhidraDirectoryIdentityLease&) = delete;
    GhidraDirectoryIdentityLease& operator=(const GhidraDirectoryIdentityLease&) = delete;

    void revalidate() const;
    void revalidate(const std::function<void(std::string_view)>& memberObserver) const;

private:
    void revalidateDirectoryPaths() const;
    void revalidateImpl(
        const std::function<void(std::string_view)>* memberObserver
    ) const;

    struct Entry final {
        std::filesystem::path path;
        int descriptor = -1;
        struct stat identity {};
    };

    std::vector<Entry> entries_;
    std::size_t closedTreeRootIndex_ = 0;
    std::vector<GhidraClosedTreeMemberIdentity> closedTreeMembers_;
};

namespace {

namespace fs = std::filesystem;

constexpr std::size_t kMaximumManifestBytes = 16U * 1024U * 1024U;
constexpr std::size_t kMaximumFiles = 100'000U;
constexpr std::uint64_t kMaximumFileBytes = 2ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr std::uint64_t kMaximumTotalBytes = 8ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr std::size_t kMaximumPathBytes = 4096U;
constexpr std::size_t kMaximumIdentityPathBytes = 64U * 1024U * 1024U;
constexpr std::size_t kMaximumIdentityDepth = 256U;
constexpr std::size_t kMaximumCriticalFileEntries = 128U;

constexpr std::string_view kComponentId = "sleigh-native-dcp03b4";
constexpr std::string_view kSourceComponentId = "sleigh-native-source-dcp03b4";
constexpr std::string_view kSanitizerSourceComponentId = "sleigh-native-sanitizer-source-dcp03b4";
// This authority is a property of the bridge binary, never supplied by the caller's
// configuration or package expectations. Ordinary app builds default to production packages.
constexpr std::string_view kCompiledSanitizerProfile = MACSCOPE_NATIVE_DECOMPILER_SANITIZER_PROFILE;
static_assert(kCompiledSanitizerProfile == "none" || kCompiledSanitizerProfile == "address" ||
              kCompiledSanitizerProfile == "undefined", "unsupported native sanitizer profile");
constexpr std::string_view kSleighVersion = "12.1.2";
constexpr std::string_view kSleighRevision = "bfd38a983b4aa53dd386365e1df5ed5499b7e2fb";
constexpr std::string_view kGhidraVersion = "12.1.2";
constexpr std::string_view kGhidraRevision = "c0f584bf229fffba61b36431f3ce30c0c3e4e682";
constexpr std::string_view kArtifactFilename = "macOS-sleigh-12.1.2-1.arm64.tar.gz";
constexpr std::string_view kArtifactPlatform = "macos-arm64";
constexpr std::string_view kArtifactSha256 =
    "e1391c811de7b2d79c9e8a1f6f74cd9ade23baf55deebd75c626a3152e5e451a";
constexpr std::string_view kArtifactUrl =
    "https://github.com/lifting-bits/sleigh/releases/download/v12.1.2/"
    "macOS-sleigh-12.1.2-1.arm64.tar.gz";
constexpr std::string_view kPackageRelativeRoot = "package";
constexpr std::string_view kCMakeConfigRelativePath = "lib/cmake/sleigh/sleighConfig.cmake";
constexpr std::string_view kDecompilerLibraryRelativePath = "lib/libdecomp.a";
constexpr std::string_view kSleighLibraryRelativePath = "lib/libsla.a";
constexpr std::string_view kGlobalSpecRelativeRoot = "share/sleigh/specfiles";
constexpr std::string_view kProcessorSpecRelativeRoot =
    "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages";

[[noreturn]] void fail(std::string_view reasonCode) {
    throw GhidraPackageAttestationError(reasonCode);
}

class ScopedFileDescriptor final {
public:
    explicit ScopedFileDescriptor(int descriptor = -1) noexcept : descriptor_(descriptor) {}
    ~ScopedFileDescriptor() { reset(); }

    ScopedFileDescriptor(const ScopedFileDescriptor&) = delete;
    ScopedFileDescriptor& operator=(const ScopedFileDescriptor&) = delete;

    ScopedFileDescriptor(ScopedFileDescriptor&& other) noexcept
        : descriptor_(other.release()) {}

    ScopedFileDescriptor& operator=(ScopedFileDescriptor&& other) noexcept {
        if (this != &other) reset(other.release());
        return *this;
    }

    [[nodiscard]] int get() const noexcept { return descriptor_; }

    [[nodiscard]] int release() noexcept {
        return std::exchange(descriptor_, -1);
    }

    void reset(int descriptor = -1) noexcept {
        const int previous = std::exchange(descriptor_, descriptor);
        if (previous >= 0) (void)::close(previous);
    }

private:
    int descriptor_ = -1;
};

class ScopedDirectoryStream final {
public:
    explicit ScopedDirectoryStream(DIR* stream = nullptr) noexcept : stream_(stream) {}
    ~ScopedDirectoryStream() { (void)close(); }

    ScopedDirectoryStream(const ScopedDirectoryStream&) = delete;
    ScopedDirectoryStream& operator=(const ScopedDirectoryStream&) = delete;

    ScopedDirectoryStream(ScopedDirectoryStream&& other) noexcept
        : stream_(other.release()) {}

    ScopedDirectoryStream& operator=(ScopedDirectoryStream&& other) noexcept {
        if (this != &other) {
            (void)close();
            stream_ = other.release();
        }
        return *this;
    }

    [[nodiscard]] DIR* get() const noexcept { return stream_; }

    [[nodiscard]] DIR* release() noexcept {
        return std::exchange(stream_, nullptr);
    }

    [[nodiscard]] int close() noexcept {
        DIR* previous = std::exchange(stream_, nullptr);
        return previous == nullptr ? 0 : ::closedir(previous);
    }

private:
    DIR* stream_ = nullptr;
};

[[nodiscard]] ScopedFileDescriptor openDirectoryPathNoFollow(
    const std::filesystem::path& absolutePath
) {
    if (!absolutePath.is_absolute()) fail("package-attestation-path-invalid");
    ScopedFileDescriptor current(::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    if (current.get() < 0) fail("package-attestation-path-invalid");
    for (const auto& component : absolutePath.relative_path()) {
        const auto name = component.string();
        ScopedFileDescriptor next(::openat(
            current.get(),
            name.c_str(),
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        ));
        if (next.get() < 0) fail("package-attestation-path-invalid");
        current = std::move(next);
    }
    return current;
}

[[nodiscard]] bool isLowerHexSha256(std::string_view value) noexcept {
    return value.size() == 64U &&
        std::all_of(value.begin(), value.end(), [](unsigned char character) {
            return (character >= '0' && character <= '9') ||
                (character >= 'a' && character <= 'f');
        });
}

[[nodiscard]] std::string asciiCasefold(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        if (character >= 'A' && character <= 'Z') {
            return static_cast<char>(character - 'A' + 'a');
        }
        return static_cast<char>(character);
    });
    return value;
}

class Sha256 final {
public:
    void update(std::span<const std::uint8_t> input) {
        totalBytes_ += input.size();
        for (const auto byte : input) {
            block_[blockSize_++] = byte;
            if (blockSize_ == block_.size()) {
                transform();
                blockSize_ = 0;
            }
        }
    }

    void update(std::string_view input) {
        update(std::span(
            reinterpret_cast<const std::uint8_t*>(input.data()),
            input.size()
        ));
    }

    [[nodiscard]] std::string finish() {
        const std::uint64_t bitCount = totalBytes_ * 8U;
        block_[blockSize_++] = 0x80U;
        if (blockSize_ > 56U) {
            std::fill(block_.begin() + static_cast<std::ptrdiff_t>(blockSize_), block_.end(), 0U);
            transform();
            blockSize_ = 0;
        }
        std::fill(
            block_.begin() + static_cast<std::ptrdiff_t>(blockSize_),
            block_.begin() + 56,
            0U
        );
        for (std::size_t index = 0; index < 8U; ++index) {
            block_[63U - index] = static_cast<std::uint8_t>(bitCount >> (index * 8U));
        }
        transform();

        constexpr char hexadecimal[] = "0123456789abcdef";
        std::string result(64U, '0');
        for (std::size_t word = 0; word < state_.size(); ++word) {
            for (std::size_t byte = 0; byte < 4U; ++byte) {
                const auto value = static_cast<std::uint8_t>(state_[word] >> ((3U - byte) * 8U));
                result[(word * 8U) + (byte * 2U)] = hexadecimal[value >> 4U];
                result[(word * 8U) + (byte * 2U) + 1U] = hexadecimal[value & 0x0fU];
            }
        }
        return result;
    }

private:
    static constexpr std::array<std::uint32_t, 64> kRoundConstants = {
        0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
        0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
        0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
        0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
        0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
        0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
        0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
        0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
        0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
        0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
        0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
        0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
        0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
        0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
        0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
        0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
    };

    static std::uint32_t rotateRight(std::uint32_t value, unsigned amount) noexcept {
        return (value >> amount) | (value << (32U - amount));
    }

    void transform() {
        std::array<std::uint32_t, 64> schedule{};
        for (std::size_t index = 0; index < 16U; ++index) {
            const auto offset = index * 4U;
            schedule[index] = (static_cast<std::uint32_t>(block_[offset]) << 24U) |
                (static_cast<std::uint32_t>(block_[offset + 1U]) << 16U) |
                (static_cast<std::uint32_t>(block_[offset + 2U]) << 8U) |
                static_cast<std::uint32_t>(block_[offset + 3U]);
        }
        for (std::size_t index = 16U; index < schedule.size(); ++index) {
            const auto lower = schedule[index - 15U];
            const auto upper = schedule[index - 2U];
            const auto sigma0 = rotateRight(lower, 7U) ^ rotateRight(lower, 18U) ^ (lower >> 3U);
            const auto sigma1 = rotateRight(upper, 17U) ^ rotateRight(upper, 19U) ^ (upper >> 10U);
            schedule[index] = schedule[index - 16U] + sigma0 + schedule[index - 7U] + sigma1;
        }

        auto a = state_[0];
        auto b = state_[1];
        auto c = state_[2];
        auto d = state_[3];
        auto e = state_[4];
        auto f = state_[5];
        auto g = state_[6];
        auto h = state_[7];
        for (std::size_t index = 0; index < schedule.size(); ++index) {
            const auto sum1 = rotateRight(e, 6U) ^ rotateRight(e, 11U) ^ rotateRight(e, 25U);
            const auto choose = (e & f) ^ (~e & g);
            const auto temporary1 = h + sum1 + choose + kRoundConstants[index] + schedule[index];
            const auto sum0 = rotateRight(a, 2U) ^ rotateRight(a, 13U) ^ rotateRight(a, 22U);
            const auto majority = (a & b) ^ (a & c) ^ (b & c);
            const auto temporary2 = sum0 + majority;
            h = g;
            g = f;
            f = e;
            e = d + temporary1;
            d = c;
            c = b;
            b = a;
            a = temporary1 + temporary2;
        }
        state_[0] += a;
        state_[1] += b;
        state_[2] += c;
        state_[3] += d;
        state_[4] += e;
        state_[5] += f;
        state_[6] += g;
        state_[7] += h;
    }

    std::array<std::uint32_t, 8> state_ = {
        0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
        0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U,
    };
    std::array<std::uint8_t, 64> block_{};
    std::size_t blockSize_ = 0;
    std::uint64_t totalBytes_ = 0;
};

struct FileContents final {
    std::string bytes;
    std::uint64_t size = 0;
    std::string sha256;
};

[[nodiscard]] bool sameFileTimes(const struct stat& lhs, const struct stat& rhs) noexcept {
#if defined(__APPLE__)
    return lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
        lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
        lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec;
#else
    return lhs.st_mtim.tv_sec == rhs.st_mtim.tv_sec &&
        lhs.st_mtim.tv_nsec == rhs.st_mtim.tv_nsec &&
        lhs.st_ctim.tv_sec == rhs.st_ctim.tv_sec &&
        lhs.st_ctim.tv_nsec == rhs.st_ctim.tv_nsec;
#endif
}

[[nodiscard]] bool sameFileIdentity(const struct stat& lhs, const struct stat& rhs) noexcept {
    return lhs.st_dev == rhs.st_dev &&
        lhs.st_ino == rhs.st_ino &&
        lhs.st_mode == rhs.st_mode &&
        lhs.st_uid == rhs.st_uid &&
        lhs.st_gid == rhs.st_gid &&
        lhs.st_nlink == rhs.st_nlink &&
        lhs.st_size == rhs.st_size &&
        sameFileTimes(lhs, rhs);
}

[[nodiscard]] bool boundedIdentityBudgetExceeded(
    std::size_t limit,
    std::initializer_list<std::size_t> allocations
) noexcept {
    std::size_t used = 0;
    for (const auto amount : allocations) {
        if (amount > limit - used) return true;
        used += amount;
    }
    return false;
}

[[nodiscard]] bool identityPathBudgetExceeded(
    std::initializer_list<std::size_t> allocations
) noexcept {
    return boundedIdentityBudgetExceeded(kMaximumIdentityPathBytes, allocations);
}

[[nodiscard]] bool identityMemberBudgetExceeded(
    std::initializer_list<std::size_t> allocations
) noexcept {
    return boundedIdentityBudgetExceeded(kMaximumFiles, allocations);
}

[[nodiscard]] ScopedFileDescriptor openRelativeDirectoryNoFollow(
    int rootDescriptor,
    std::string_view relativePath,
    std::string_view failureReason
) {
    ScopedFileDescriptor current(::openat(
        rootDescriptor,
        ".",
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    ));
    if (current.get() < 0) fail(failureReason);

    std::size_t start = 0;
    while (start < relativePath.size()) {
        const auto separator = relativePath.find('/', start);
        const auto end = separator == std::string_view::npos
            ? relativePath.size()
            : separator;
        const auto componentView = relativePath.substr(start, end - start);
        if (componentView.empty()) fail(failureReason);
        const std::string component(componentView);
        ScopedFileDescriptor next(::openat(
            current.get(),
            component.c_str(),
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        ));
        if (next.get() < 0) fail(failureReason);
        current = std::move(next);
        if (separator == std::string_view::npos) break;
        start = separator + 1U;
    }
    return current;
}

[[nodiscard]] std::vector<GhidraClosedTreeMemberIdentity> scanClosedTreeIdentity(
    int rootDescriptor,
    std::string_view failureReason,
    const std::function<void(std::string_view)>* memberObserver = nullptr
) {
    using Member = GhidraClosedTreeMemberIdentity;
    struct PendingDirectory final {
        std::string relativePath;
        std::size_t depth = 0;
    };

    std::vector<Member> members;
    members.reserve(4096U);
    std::vector<PendingDirectory> pendingDirectories;
    pendingDirectories.push_back({});
    std::size_t retainedPathBytes = 0;

    while (!pendingDirectories.empty()) {
        auto directory = std::move(pendingDirectories.back());
        pendingDirectories.pop_back();
        if (directory.relativePath.size() > retainedPathBytes) fail(failureReason);
        retainedPathBytes -= directory.relativePath.size();
        if (directory.depth > kMaximumIdentityDepth) fail(failureReason);

        auto directoryDescriptor = openRelativeDirectoryNoFollow(
            rootDescriptor,
            directory.relativePath,
            failureReason
        );

        struct stat directoryBefore {};
        if (::fstat(directoryDescriptor.get(), &directoryBefore) != 0 ||
            !S_ISDIR(directoryBefore.st_mode)) {
            fail(failureReason);
        }

        ScopedFileDescriptor iterationDescriptor(::openat(
            directoryDescriptor.get(),
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        ));
        if (iterationDescriptor.get() < 0) fail(failureReason);
        ScopedDirectoryStream stream(::fdopendir(iterationDescriptor.get()));
        if (stream.get() == nullptr) fail(failureReason);
        (void)iterationDescriptor.release();

        std::vector<std::string> names;
        std::size_t nameBytes = 0;
        errno = 0;
        while (const auto* entry = ::readdir(stream.get())) {
            const std::string_view name(entry->d_name);
            if (name == "." || name == "..") continue;
            if (name.empty() || name.size() > kMaximumPathBytes) fail(failureReason);
            if (identityPathBudgetExceeded({
                    retainedPathBytes,
                    directory.relativePath.size(),
                    nameBytes,
                    name.size(),
                })) {
                fail(failureReason);
            }
            nameBytes += name.size();
            names.emplace_back(name);
            if (identityMemberBudgetExceeded({
                    members.size(),
                    pendingDirectories.size(),
                    names.size(),
                    1U,
                })) {
                fail(failureReason);
            }
            errno = 0;
        }
        const int iterationError = errno;
        const int closeError = stream.close();
        if (closeError != 0 || iterationError != 0) fail(failureReason);
        std::sort(names.begin(), names.end());
        if (names.empty() && !directory.relativePath.empty()) fail(failureReason);
        if (std::adjacent_find(names.begin(), names.end()) != names.end()) {
            fail(failureReason);
        }

        for (const auto& name : names) {
            const auto relative = directory.relativePath.empty()
                ? name
                : directory.relativePath + "/" + name;
            if (relative.size() > kMaximumPathBytes) fail(failureReason);

            struct stat noFollowStatus {};
            if (::fstatat(
                    directoryDescriptor.get(),
                    name.c_str(),
                    &noFollowStatus,
                    AT_SYMLINK_NOFOLLOW
                ) != 0 ||
                (!S_ISDIR(noFollowStatus.st_mode) && !S_ISREG(noFollowStatus.st_mode))) {
                fail(failureReason);
            }

            const int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC |
                (S_ISDIR(noFollowStatus.st_mode) ? O_DIRECTORY : O_NONBLOCK);
            ScopedFileDescriptor childDescriptor(
                ::openat(directoryDescriptor.get(), name.c_str(), flags)
            );
            if (childDescriptor.get() < 0) fail(failureReason);

            struct stat openedStatus {};
            if (::fstat(childDescriptor.get(), &openedStatus) != 0 ||
                !sameFileIdentity(noFollowStatus, openedStatus)) {
                fail(failureReason);
            }

            if (S_ISDIR(openedStatus.st_mode)) {
                if (directory.depth >= kMaximumIdentityDepth ||
                    identityPathBudgetExceeded({
                        retainedPathBytes,
                        directory.relativePath.size(),
                        nameBytes,
                        relative.size(),
                    })) {
                    fail(failureReason);
                }
                retainedPathBytes += relative.size();
                pendingDirectories.push_back({relative, directory.depth + 1U});
                continue;
            }
            if (identityPathBudgetExceeded({
                    retainedPathBytes,
                    directory.relativePath.size(),
                    nameBytes,
                    relative.size(),
                })) {
                fail(failureReason);
            }
            retainedPathBytes += relative.size();
            members.push_back(Member{relative, openedStatus});
            if (identityMemberBudgetExceeded({members.size()})) fail(failureReason);
            if (memberObserver != nullptr) {
                (*memberObserver)(members.back().relativePath);
            }
        }

        struct stat directoryAfter {};
        if (::fstat(directoryDescriptor.get(), &directoryAfter) != 0 ||
            !sameFileIdentity(directoryBefore, directoryAfter)) {
            fail(failureReason);
        }
        const auto selfRelative = directory.relativePath.empty() ? "." : directory.relativePath;
        if (identityPathBudgetExceeded({
                retainedPathBytes,
                directory.relativePath.size(),
                nameBytes,
                selfRelative.size(),
            })) {
            fail(failureReason);
        }
        retainedPathBytes += selfRelative.size();
        members.push_back(Member{selfRelative, directoryAfter});
        if (identityMemberBudgetExceeded({members.size()})) fail(failureReason);
        if (memberObserver != nullptr) {
            (*memberObserver)(members.back().relativePath);
        }
    }

    std::sort(members.begin(), members.end(), [](const Member& lhs, const Member& rhs) {
        return lhs.relativePath < rhs.relativePath;
    });
    return members;
}

enum class ClosedTreeDrift {
    none,
    path,
    content,
};

[[nodiscard]] ClosedTreeDrift compareClosedTreeIdentity(
    const std::vector<GhidraClosedTreeMemberIdentity>& expected,
    const std::vector<GhidraClosedTreeMemberIdentity>& observed
) noexcept {
    if (expected.size() != observed.size()) return ClosedTreeDrift::content;
    auto drift = ClosedTreeDrift::none;
    for (std::size_t index = 0; index < expected.size(); ++index) {
        if (expected[index].relativePath != observed[index].relativePath) {
            return ClosedTreeDrift::content;
        }
        if (!sameFileIdentity(expected[index].identity, observed[index].identity)) {
            const auto expectedIsDirectory = S_ISDIR(expected[index].identity.st_mode);
            const auto observedIsDirectory = S_ISDIR(observed[index].identity.st_mode);
            if (expectedIsDirectory && observedIsDirectory &&
                (expected[index].identity.st_dev != observed[index].identity.st_dev ||
                 expected[index].identity.st_ino != observed[index].identity.st_ino)) {
                return ClosedTreeDrift::path;
            }
            drift = ClosedTreeDrift::content;
        }
    }
    return drift;
}

[[nodiscard]] FileContents readOrdinaryFile(
    const fs::path& path,
    std::uint64_t maximumBytes,
    bool retainBytes
) {
    ScopedFileDescriptor descriptor(::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
    if (descriptor.get() < 0) {
        fail("package-attestation-file-invalid");
    }

    struct stat before {};
    if (::fstat(descriptor.get(), &before) != 0 || !S_ISREG(before.st_mode) ||
        before.st_size < 0 ||
        static_cast<std::uint64_t>(before.st_size) > maximumBytes) {
        fail("package-attestation-file-invalid");
    }

    FileContents result;
    result.size = static_cast<std::uint64_t>(before.st_size);
    if (retainBytes) {
        result.bytes.reserve(static_cast<std::size_t>(result.size));
    }
    Sha256 digest;
    // Reuse a bounded per-thread buffer. This avoids both a 1 MiB automatic
    // allocation on 512 KiB macOS pthread stacks and thousands of heap
    // allocations while hashing the closed package tree.
    thread_local std::array<std::uint8_t, 64U * 1024U> buffer{};
    std::uint64_t observed = 0;
    while (true) {
        const auto count = ::read(descriptor.get(), buffer.data(), buffer.size());
        if (count < 0) {
            if (errno == EINTR) continue;
            fail("package-attestation-file-invalid");
        }
        if (count == 0) break;
        const auto amount = static_cast<std::size_t>(count);
        observed += amount;
        if (observed > maximumBytes) fail("package-attestation-file-invalid");
        digest.update(std::span(buffer.data(), amount));
        if (retainBytes) {
            result.bytes.append(reinterpret_cast<const char*>(buffer.data()), amount);
        }
    }

    struct stat after {};
    if (::fstat(descriptor.get(), &after) != 0 || observed != result.size ||
        !sameFileIdentity(before, after)) {
        fail("package-attestation-file-mutated");
    }
    result.sha256 = digest.finish();
    return result;
}

struct JsonValue final {
    using Array = std::vector<JsonValue>;
    using Object = std::map<std::string, JsonValue>;
    std::variant<std::string, std::uint64_t, Array, Object> storage;
};
using JsonArray = JsonValue::Array;
using JsonObject = JsonValue::Object;

class CanonicalJsonParser final {
public:
    explicit CanonicalJsonParser(std::string_view input) : input_(input) {}

    [[nodiscard]] JsonValue parse() {
        if (input_.empty() || input_.back() != '\n') fail("package-attestation-manifest-invalid");
        const auto value = parseValue();
        if (position_ + 1U != input_.size() || input_[position_] != '\n') {
            fail("package-attestation-manifest-invalid");
        }
        if (render(value) + "\n" != input_) fail("package-attestation-manifest-invalid");
        return value;
    }

private:
    [[nodiscard]] JsonValue parseValue() {
        if (position_ >= input_.size()) fail("package-attestation-manifest-invalid");
        if (input_[position_] == '{') return JsonValue{parseObject()};
        if (input_[position_] == '[') return JsonValue{parseArray()};
        if (input_[position_] == '"') return JsonValue{parseString()};
        if (input_[position_] >= '0' && input_[position_] <= '9') return JsonValue{parseUnsigned()};
        fail("package-attestation-manifest-invalid");
    }

    [[nodiscard]] JsonObject parseObject() {
        ++position_;
        JsonObject result;
        if (position_ < input_.size() && input_[position_] == '}') {
            ++position_;
            return result;
        }
        while (true) {
            if (position_ >= input_.size() || input_[position_] != '"') {
                fail("package-attestation-manifest-invalid");
            }
            auto key = parseString();
            if (position_ >= input_.size() || input_[position_++] != ':') {
                fail("package-attestation-manifest-invalid");
            }
            auto [_, inserted] = result.emplace(std::move(key), parseValue());
            if (!inserted) fail("package-attestation-manifest-invalid");
            if (position_ >= input_.size()) fail("package-attestation-manifest-invalid");
            const char delimiter = input_[position_++];
            if (delimiter == '}') break;
            if (delimiter != ',') fail("package-attestation-manifest-invalid");
        }
        return result;
    }

    [[nodiscard]] JsonArray parseArray() {
        ++position_;
        JsonArray result;
        if (position_ < input_.size() && input_[position_] == ']') {
            ++position_;
            return result;
        }
        while (true) {
            result.push_back(parseValue());
            if (position_ >= input_.size()) fail("package-attestation-manifest-invalid");
            const char delimiter = input_[position_++];
            if (delimiter == ']') break;
            if (delimiter != ',') fail("package-attestation-manifest-invalid");
        }
        return result;
    }

    [[nodiscard]] std::string parseString() {
        ++position_;
        std::string result;
        while (position_ < input_.size()) {
            const unsigned char character = static_cast<unsigned char>(input_[position_++]);
            if (character == '"') return result;
            if (character == '\\' || character < 0x20U || character > 0x7eU) {
                fail("package-attestation-manifest-invalid");
            }
            result.push_back(static_cast<char>(character));
            if (result.size() > kMaximumPathBytes) fail("package-attestation-manifest-invalid");
        }
        fail("package-attestation-manifest-invalid");
    }

    [[nodiscard]] std::uint64_t parseUnsigned() {
        const auto start = position_;
        if (input_[position_] == '0') {
            ++position_;
            if (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') {
                fail("package-attestation-manifest-invalid");
            }
            return 0;
        }
        while (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') {
            ++position_;
        }
        std::uint64_t result = 0;
        const auto conversion = std::from_chars(
            input_.data() + static_cast<std::ptrdiff_t>(start),
            input_.data() + static_cast<std::ptrdiff_t>(position_),
            result
        );
        if (conversion.ec != std::errc{} || conversion.ptr != input_.data() + position_) {
            fail("package-attestation-manifest-invalid");
        }
        return result;
    }

    static std::string render(const JsonValue& value) {
        if (const auto* text = std::get_if<std::string>(&value.storage)) {
            return "\"" + *text + "\"";
        }
        if (const auto* number = std::get_if<std::uint64_t>(&value.storage)) {
            return std::to_string(*number);
        }
        if (const auto* array = std::get_if<JsonArray>(&value.storage)) {
            std::string result = "[";
            bool first = true;
            for (const auto& child : *array) {
                if (!first) result.push_back(',');
                first = false;
                result += render(child);
            }
            result.push_back(']');
            return result;
        }
        const auto& object = std::get<JsonObject>(value.storage);
        std::string result = "{";
        bool first = true;
        for (const auto& [key, child] : object) {
            if (!first) result.push_back(',');
            first = false;
            result += "\"" + key + "\":" + render(child);
        }
        result.push_back('}');
        return result;
    }

    std::string_view input_;
    std::size_t position_ = 0;
};

[[nodiscard]] const JsonObject& requireObject(const JsonValue& value) {
    const auto* object = std::get_if<JsonObject>(&value.storage);
    if (object == nullptr) fail("package-attestation-manifest-invalid");
    return *object;
}

[[nodiscard]] const JsonArray& requireArray(const JsonValue& value) {
    const auto* array = std::get_if<JsonArray>(&value.storage);
    if (array == nullptr) fail("package-attestation-manifest-invalid");
    return *array;
}

[[nodiscard]] const JsonValue& requireField(const JsonObject& object, std::string_view key) {
    const auto iterator = object.find(std::string(key));
    if (iterator == object.end()) fail("package-attestation-manifest-invalid");
    return iterator->second;
}

void requireExactKeys(const JsonObject& object, std::initializer_list<std::string_view> keys) {
    if (object.size() != keys.size()) fail("package-attestation-manifest-invalid");
    for (const auto key : keys) {
        if (!object.contains(std::string(key))) fail("package-attestation-manifest-invalid");
    }
}

[[nodiscard]] std::string_view requireString(
    const JsonObject& object,
    std::string_view key
) {
    const auto* value = std::get_if<std::string>(&requireField(object, key).storage);
    if (value == nullptr) fail("package-attestation-manifest-invalid");
    return *value;
}

[[nodiscard]] std::uint64_t requireUnsigned(
    const JsonObject& object,
    std::string_view key
) {
    const auto* value = std::get_if<std::uint64_t>(&requireField(object, key).storage);
    if (value == nullptr) fail("package-attestation-manifest-invalid");
    return *value;
}

void requireEqual(std::string_view observed, std::string_view expected) {
    if (observed != expected) fail("package-attestation-identity-mismatch");
}

void requireSanitizerInstrumentation(const JsonObject& instrumentation,
                                    const JsonObject& criticalFileSha256) {
    requireExactKeys(instrumentation, {
        "archiveSha256", "compileCommandsSha256", "profile", "sdkRoot",
        "sdkSettingsSha256", "translationUnitCounts",
    });
    if (requireString(instrumentation, "profile") != kCompiledSanitizerProfile) {
        fail("package-attestation-sanitizer-mismatch");
    }
    if (!isLowerHexSha256(requireString(instrumentation, "compileCommandsSha256")) ||
        !isLowerHexSha256(requireString(instrumentation, "sdkSettingsSha256")) ||
        !fs::path(requireString(instrumentation, "sdkRoot")).is_absolute()) {
        fail("package-attestation-manifest-invalid");
    }
    const auto& counts = requireObject(requireField(instrumentation, "translationUnitCounts"));
    requireExactKeys(counts, {"sleigh_decomp", "sleigh_sla"});
    if (requireUnsigned(counts, "sleigh_decomp") == 0U || requireUnsigned(counts, "sleigh_sla") == 0U) {
        fail("package-attestation-manifest-invalid");
    }
    const auto& archives = requireObject(requireField(instrumentation, "archiveSha256"));
    requireExactKeys(archives, {kDecompilerLibraryRelativePath, kSleighLibraryRelativePath});
    for (const auto path : {kDecompilerLibraryRelativePath, kSleighLibraryRelativePath}) {
        const auto digest = requireString(archives, path);
        if (!isLowerHexSha256(digest)) fail("package-attestation-manifest-invalid");
        requireEqual(digest, requireString(criticalFileSha256, path));
    }
}

[[nodiscard]] bool pathIsWithin(const fs::path& child, const fs::path& parent) {
    auto childIterator = child.begin();
    for (auto parentIterator = parent.begin(); parentIterator != parent.end();
         ++parentIterator, ++childIterator) {
        if (childIterator == child.end() || *childIterator != *parentIterator) return false;
    }
    return child != parent;
}

[[nodiscard]] fs::path requireCanonicalOrdinaryDirectory(const fs::path& input) {
    if (!input.is_absolute() || input.empty()) fail("package-attestation-path-invalid");
    std::error_code error;
    const auto normalized = input.lexically_normal();
    const auto canonical = fs::canonical(input, error);
    if (error || normalized != canonical) fail("package-attestation-path-invalid");

    fs::path current;
    for (const auto& component : canonical) {
        current /= component;
        const auto status = fs::symlink_status(current, error);
        if (error || status.type() != fs::file_type::directory) {
            fail("package-attestation-path-invalid");
        }
    }
    return canonical;
}

[[nodiscard]] std::string relativePortablePath(const fs::path& path, const fs::path& root) {
    std::error_code error;
    const auto relative = fs::relative(path, root, error).generic_string();
    if (error || relative.empty() || relative.starts_with("../") || relative == ".." ||
        relative.size() > kMaximumPathBytes || relative.find('\0') != std::string::npos) {
        fail("package-attestation-layout-invalid");
    }
    return relative;
}

struct TreeIdentity final {
    std::size_t fileCount = 0;
    std::uint64_t totalBytes = 0;
    std::string sha256;
    std::map<std::string, std::string> fileSha256;
};

[[nodiscard]] TreeIdentity analyzeClosedTree(const fs::path& packageRoot) {
    std::error_code error;
    std::vector<std::pair<std::string, fs::path>> files;
    for (fs::recursive_directory_iterator iterator(
             packageRoot,
             fs::directory_options::none,
             error
         ), end;
         iterator != end;
         iterator.increment(error)) {
        if (error) fail("package-attestation-layout-invalid");
        const auto status = iterator->symlink_status(error);
        if (error || fs::is_symlink(status) ||
            (!fs::is_directory(status) && !fs::is_regular_file(status))) {
            fail("package-attestation-layout-invalid");
        }
        auto relative = relativePortablePath(iterator->path(), packageRoot);
        const fs::path relativePath(relative);
        for (const auto& component : relativePath) {
            if (asciiCasefold(component.string()) == "gpl") {
                fail("package-attestation-layout-invalid");
            }
        }
        if (fs::is_directory(status)) {
            const bool empty = fs::is_empty(iterator->path(), error);
            if (error || empty) fail("package-attestation-layout-invalid");
            continue;
        }
        const auto extension = asciiCasefold(relativePath.extension().string());
        if (extension == ".jar" || extension == ".class") {
            fail("package-attestation-layout-invalid");
        }
        files.emplace_back(std::move(relative), iterator->path());
        if (files.size() > kMaximumFiles) fail("package-attestation-layout-invalid");
    }
    if (error || files.empty()) fail("package-attestation-layout-invalid");
    std::sort(files.begin(), files.end(), [](const auto& lhs, const auto& rhs) {
        return lhs.first < rhs.first;
    });

    TreeIdentity result;
    Sha256 treeDigest;
    for (const auto& [relative, path] : files) {
        const auto file = readOrdinaryFile(path, kMaximumFileBytes, false);
        if (file.size > kMaximumTotalBytes - result.totalBytes) {
            fail("package-attestation-layout-invalid");
        }
        result.totalBytes += file.size;
        result.fileSha256.emplace(relative, file.sha256);
        treeDigest.update(relative);
        treeDigest.update(std::string_view("\0", 1U));
        treeDigest.update(std::to_string(file.size));
        treeDigest.update(std::string_view("\0", 1U));
        treeDigest.update(file.sha256);
        treeDigest.update(std::string_view("\0", 1U));
    }
    result.fileCount = files.size();
    result.sha256 = treeDigest.finish();
    return result;
}

void requireTruthfulCriticalFileSummary(
    const JsonObject& recorded,
    const TreeIdentity& observed
) {
    if (recorded.empty() || recorded.size() > kMaximumCriticalFileEntries) {
        fail("package-attestation-critical-map-mismatch");
    }
    for (const auto& [relativePath, value] : recorded) {
        const auto* digest = std::get_if<std::string>(&value.storage);
        const auto observedDigest = observed.fileSha256.find(relativePath);
        if (digest == nullptr || !isLowerHexSha256(*digest) ||
            observedDigest == observed.fileSha256.end() || observedDigest->second != *digest) {
            fail("package-attestation-critical-map-mismatch");
        }
    }
}

void requireExactRootLayout(const fs::path& materializationRoot) {
    std::error_code error;
    std::vector<std::string> names;
    for (fs::directory_iterator iterator(materializationRoot, error), end;
         iterator != end;
         iterator.increment(error)) {
        if (error) fail("package-attestation-layout-invalid");
        names.push_back(iterator->path().filename().string());
    }
    if (error) fail("package-attestation-layout-invalid");
    std::sort(names.begin(), names.end());
    if (names != std::vector<std::string>{"MATERIALIZATION.json", "package"}) {
        fail("package-attestation-layout-invalid");
    }
}

} // namespace

GhidraDirectoryIdentityLease::GhidraDirectoryIdentityLease(
    const std::vector<std::filesystem::path>& paths,
    const std::filesystem::path& closedTreeRoot
) {
    entries_.reserve(paths.size());
    try {
        bool foundClosedTreeRoot = false;
        for (const auto& path : paths) {
            auto descriptor = openDirectoryPathNoFollow(path);
            struct stat status {};
            if (::fstat(descriptor.get(), &status) != 0 || !S_ISDIR(status.st_mode)) {
                fail("package-attestation-path-invalid");
            }
            entries_.push_back({
                .path = path,
                .descriptor = -1,
                .identity = status,
            });
            entries_.back().descriptor = descriptor.release();
            if (path == closedTreeRoot) {
                if (foundClosedTreeRoot) fail("package-attestation-path-invalid");
                foundClosedTreeRoot = true;
                closedTreeRootIndex_ = entries_.size() - 1U;
            }
        }
        if (!foundClosedTreeRoot) fail("package-attestation-path-invalid");
        closedTreeMembers_ = scanClosedTreeIdentity(
            entries_[closedTreeRootIndex_].descriptor,
            "package-attestation-layout-invalid"
        );
    } catch (...) {
        for (const auto& entry : entries_) {
            if (entry.descriptor >= 0) ::close(entry.descriptor);
        }
        throw;
    }
}

GhidraDirectoryIdentityLease::~GhidraDirectoryIdentityLease() {
    for (const auto& entry : entries_) {
        if (entry.descriptor >= 0) ::close(entry.descriptor);
    }
}

void GhidraDirectoryIdentityLease::revalidate() const {
    revalidateImpl(nullptr);
}

void GhidraDirectoryIdentityLease::revalidate(
    const std::function<void(std::string_view)>& memberObserver
) const {
    revalidateImpl(&memberObserver);
}

void GhidraDirectoryIdentityLease::revalidateDirectoryPaths() const {
    for (const auto& entry : entries_) {
        struct stat retained {};
        if (::fstat(entry.descriptor, &retained) != 0 ||
            !S_ISDIR(retained.st_mode) ||
            retained.st_dev != entry.identity.st_dev ||
            retained.st_ino != entry.identity.st_ino ||
            retained.st_mode != entry.identity.st_mode) {
            fail("package-attestation-path-drift");
        }

        ScopedFileDescriptor currentDescriptor;
        try {
            currentDescriptor = openDirectoryPathNoFollow(entry.path);
        } catch (const GhidraPackageAttestationError&) {
            fail("package-attestation-path-drift");
        }
        struct stat current {};
        if (::fstat(currentDescriptor.get(), &current) != 0 ||
            !S_ISDIR(current.st_mode) ||
            current.st_dev != entry.identity.st_dev ||
            current.st_ino != entry.identity.st_ino ||
            current.st_mode != entry.identity.st_mode) {
            fail("package-attestation-path-drift");
        }
    }
}

void GhidraDirectoryIdentityLease::revalidateImpl(
    const std::function<void(std::string_view)>* memberObserver
) const {
    revalidateDirectoryPaths();

    auto drift = ClosedTreeDrift::none;
    try {
        const auto observed = scanClosedTreeIdentity(
            entries_[closedTreeRootIndex_].descriptor,
            "package-attestation-content-drift",
            memberObserver
        );
        const auto confirmed = scanClosedTreeIdentity(
            entries_[closedTreeRootIndex_].descriptor,
            "package-attestation-content-drift"
        );
        const auto scanDrift = compareClosedTreeIdentity(observed, confirmed);
        const auto baselineDrift = compareClosedTreeIdentity(closedTreeMembers_, confirmed);
        drift = scanDrift == ClosedTreeDrift::path ||
                baselineDrift == ClosedTreeDrift::path
            ? ClosedTreeDrift::path
            : (scanDrift == ClosedTreeDrift::content ||
                      baselineDrift == ClosedTreeDrift::content
                  ? ClosedTreeDrift::content
                  : ClosedTreeDrift::none);
    } catch (...) {
        revalidateDirectoryPaths();
        throw;
    }
    revalidateDirectoryPaths();
    switch (drift) {
    case ClosedTreeDrift::none:
        break;
    case ClosedTreeDrift::path:
        fail("package-attestation-path-drift");
    case ClosedTreeDrift::content:
        fail("package-attestation-content-drift");
    }
}

void revalidateGhidraPackageDirectories(const GhidraPackageAttestation& attestation) {
    if (!attestation.directoryIdentity) fail("package-attestation-path-drift");
    attestation.directoryIdentity->revalidate();
}

std::shared_ptr<const GhidraDirectoryIdentityLease>
captureGhidraClosedTreeIdentityForTesting(const std::filesystem::path& root) {
    const auto canonicalRoot = requireCanonicalOrdinaryDirectory(root);
    return std::make_shared<GhidraDirectoryIdentityLease>(
        std::vector<fs::path>{canonicalRoot},
        canonicalRoot
    );
}

void revalidateGhidraClosedTreeIdentityForTesting(
    const std::shared_ptr<const GhidraDirectoryIdentityLease>& identity
) {
    if (!identity) fail("package-attestation-path-drift");
    identity->revalidate();
}

void revalidateGhidraClosedTreeIdentityForTesting(
    const std::shared_ptr<const GhidraDirectoryIdentityLease>& identity,
    const std::function<void(std::string_view)>& memberObserver
) {
    if (!identity) fail("package-attestation-path-drift");
    identity->revalidate(memberObserver);
}

std::size_t ghidraClosedTreeMaximumMembersForTesting() noexcept {
    return kMaximumFiles;
}

std::size_t ghidraClosedTreeMaximumPathBytesForTesting() noexcept {
    return kMaximumIdentityPathBytes;
}

bool ghidraClosedTreeMemberBudgetExceededForTesting(std::size_t members) noexcept {
    return identityMemberBudgetExceeded({members});
}

bool ghidraClosedTreePathBudgetExceededForTesting(std::size_t bytes) noexcept {
    return identityPathBudgetExceeded({bytes});
}

GhidraPackageAttestationError::GhidraPackageAttestationError(std::string_view reasonCode)
    : std::runtime_error(std::string(reasonCode)), reasonCode_(reasonCode) {
    if (reasonCode_.empty() || reasonCode_.size() > 96U ||
        !std::all_of(reasonCode_.begin(), reasonCode_.end(), [](unsigned char character) {
            return (character >= 'a' && character <= 'z') ||
                (character >= '0' && character <= '9') || character == '-';
        })) {
        throw std::invalid_argument("invalid-package-attestation-reason");
    }
}

const std::string& GhidraPackageAttestationError::reasonCode() const noexcept {
    return reasonCode_;
}

GhidraPackageAttestation attestGhidraPackage(
    const GhidraBackendConfiguration& configuration,
    const GhidraPackageAttestationExpectations& expectations
) {
    if (!isLowerHexSha256(configuration.packageManifestSha256) ||
        !isLowerHexSha256(expectations.materializationManifestSha256) ||
        !isLowerHexSha256(expectations.packageTreeSha256) ||
        configuration.packageManifestSha256 != expectations.materializationManifestSha256) {
        fail("package-attestation-configuration-mismatch");
    }

    const auto materializationRoot =
        requireCanonicalOrdinaryDirectory(expectations.materializationRoot);
    requireExactRootLayout(materializationRoot);
    const auto packageRoot = requireCanonicalOrdinaryDirectory(expectations.packageRoot);
    const auto globalSpecRoot =
        requireCanonicalOrdinaryDirectory(expectations.globalProcessorSpecRoot);
    const auto processorSpecRoot =
        requireCanonicalOrdinaryDirectory(expectations.processorSpecRoot);

    if (packageRoot != materializationRoot / kPackageRelativeRoot ||
        globalSpecRoot != packageRoot / kGlobalSpecRelativeRoot ||
        processorSpecRoot != packageRoot / kProcessorSpecRelativeRoot ||
        !pathIsWithin(packageRoot, materializationRoot) ||
        !pathIsWithin(globalSpecRoot, packageRoot) ||
        !pathIsWithin(processorSpecRoot, globalSpecRoot)) {
        fail("package-attestation-layout-invalid");
    }
    auto directoryIdentity = std::make_shared<GhidraDirectoryIdentityLease>(
        std::vector<fs::path>{materializationRoot, packageRoot, globalSpecRoot, processorSpecRoot},
        materializationRoot
    );

    const auto configuredPackageRoot =
        requireCanonicalOrdinaryDirectory(fs::path(configuration.packageRoot));
    const auto configuredProcessorSpecRoot =
        requireCanonicalOrdinaryDirectory(fs::path(configuration.processorSpecRoot));
    if (configuredPackageRoot != packageRoot || configuredProcessorSpecRoot != processorSpecRoot) {
        fail("package-attestation-configuration-mismatch");
    }

    const auto manifest = readOrdinaryFile(
        materializationRoot / "MATERIALIZATION.json",
        kMaximumManifestBytes,
        true
    );
    if (manifest.sha256 != configuration.packageManifestSha256 ||
        manifest.sha256 != expectations.materializationManifestSha256) {
        fail("package-attestation-manifest-mismatch");
    }

    const auto rootValue = CanonicalJsonParser(manifest.bytes).parse();
    const auto& root = requireObject(rootValue);
    const auto schemaVersion = requireUnsigned(root, "schemaVersion");
    if ((schemaVersion == 1U || schemaVersion == 2U) && kCompiledSanitizerProfile != "none") {
        fail("package-attestation-sanitizer-mismatch");
    }
    const JsonObject* sanitizerInstrumentation = nullptr;
    if (schemaVersion == 1U) {
        requireExactKeys(root, {
            "artifact", "componentId", "ghidraGitRevision", "ghidraVersion",
            "package", "schemaVersion", "sleighGitRevision", "sleighVersion",
        });
        requireEqual(requireString(root, "componentId"), kComponentId);
        const auto& artifact = requireObject(requireField(root, "artifact"));
        requireExactKeys(artifact, {"filename", "platform", "sha256", "url"});
        requireEqual(requireString(artifact, "filename"), kArtifactFilename);
        requireEqual(requireString(artifact, "platform"), kArtifactPlatform);
        requireEqual(requireString(artifact, "sha256"), kArtifactSha256);
        requireEqual(requireString(artifact, "url"), kArtifactUrl);
    } else if (schemaVersion == 2U || schemaVersion == 3U) {
        if (schemaVersion == 3U) {
            requireExactKeys(root, {
                "componentId", "ghidraGitRevision", "ghidraVersion", "package", "sanitizer",
                "schemaVersion", "sleighGitRevision", "sleighVersion", "sourceBuild",
            });
            if (kCompiledSanitizerProfile == "none" ||
                requireString(root, "sanitizer") != kCompiledSanitizerProfile) {
                fail("package-attestation-sanitizer-mismatch");
            }
            requireEqual(requireString(root, "componentId"), kSanitizerSourceComponentId);
        } else {
            requireExactKeys(root, {
                "componentId", "ghidraGitRevision", "ghidraVersion", "package",
                "schemaVersion", "sleighGitRevision", "sleighVersion", "sourceBuild",
            });
            requireEqual(requireString(root, "componentId"), kSourceComponentId);
        }
        const auto& sourceBuild = requireObject(requireField(root, "sourceBuild"));
        if (schemaVersion == 3U) {
            requireExactKeys(sourceBuild, {
                "buildOptions", "ghidraGitTree", "ghidraTreeSha256", "instrumentation", "patches",
                "sleighGitTree", "sleighTreeSha256", "sourceManifestSha256", "toolchain",
            });
            sanitizerInstrumentation = &requireObject(requireField(sourceBuild, "instrumentation"));
        } else {
            requireExactKeys(sourceBuild, {
                "buildOptions", "ghidraGitTree", "ghidraTreeSha256", "patches",
                "sleighGitTree", "sleighTreeSha256", "sourceManifestSha256", "toolchain",
            });
        }
        if (requireArray(requireField(sourceBuild, "buildOptions")).empty() ||
            requireArray(requireField(sourceBuild, "patches")).empty()) {
            fail("package-attestation-manifest-invalid");
        }
        (void)requireObject(requireField(sourceBuild, "toolchain"));
    } else {
        fail("package-attestation-identity-mismatch");
    }
    requireEqual(requireString(root, "sleighVersion"), kSleighVersion);
    requireEqual(requireString(root, "sleighGitRevision"), kSleighRevision);
    requireEqual(requireString(root, "ghidraVersion"), kGhidraVersion);
    requireEqual(requireString(root, "ghidraGitRevision"), kGhidraRevision);

    const auto& package = requireObject(requireField(root, "package"));
    requireExactKeys(package, {
        "cmakeConfigRelativePath", "criticalFileSha256", "decompilerLibraryRelativePath",
        "fileCount", "processorSpecRelativeRoot", "relativeRoot", "sleighLibraryRelativePath",
        "totalBytes", "treeSha256",
    });
    requireEqual(requireString(package, "relativeRoot"), kPackageRelativeRoot);
    requireEqual(requireString(package, "cmakeConfigRelativePath"), kCMakeConfigRelativePath);
    requireEqual(
        requireString(package, "processorSpecRelativeRoot"),
        kProcessorSpecRelativeRoot
    );
    requireEqual(
        requireString(package, "decompilerLibraryRelativePath"),
        kDecompilerLibraryRelativePath
    );
    requireEqual(requireString(package, "sleighLibraryRelativePath"), kSleighLibraryRelativePath);

    const auto& criticalFileSha256 = requireObject(
        requireField(package, "criticalFileSha256")
    );
    if (sanitizerInstrumentation != nullptr) {
        requireSanitizerInstrumentation(*sanitizerInstrumentation, criticalFileSha256);
    }

    const auto manifestTreeSha256 = requireString(package, "treeSha256");
    if (!isLowerHexSha256(manifestTreeSha256) ||
        manifestTreeSha256 != expectations.packageTreeSha256) {
        fail("package-attestation-tree-mismatch");
    }

    const auto tree = analyzeClosedTree(packageRoot);
    if (tree.fileCount != requireUnsigned(package, "fileCount") ||
        tree.totalBytes != requireUnsigned(package, "totalBytes") ||
        tree.sha256 != manifestTreeSha256 || tree.sha256 != expectations.packageTreeSha256) {
        fail("package-attestation-tree-mismatch");
    }
    requireTruthfulCriticalFileSummary(criticalFileSha256, tree);

    GhidraPackageAttestation result{
        .materializationRoot = materializationRoot,
        .materializationManifestSha256 = manifest.sha256,
        .packageTreeSha256 = tree.sha256,
        .packageRoot = packageRoot,
        .globalProcessorSpecRoot = globalSpecRoot,
        .processorSpecRoot = processorSpecRoot,
        .directoryIdentity = std::move(directoryIdentity),
    };
    revalidateGhidraPackageDirectories(result);
    return result;
}

} // namespace macscope::native_decompiler::detail
