// App-owned fixed C compilation/behavior launcher. No model command or policy is accepted.
#include <sys/stat.h>
#include <sys/resource.h>
#include <unistd.h>
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <pwd.h>

static void fail(const char *message) { fprintf(stderr, "source-runner: %s\n", message); exit(125); }
static void canonical(const char *input, char *output) {
    if (!realpath(input, output) || strcmp(input, output)) fail("noncanonical path");
    for (const char *p = output; *p; ++p)
        if (!( (*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
               (*p >= '0' && *p <= '9') || strchr("/ ._-", *p))) fail("unsupported path character");
}
static void regular(const char *path, off_t maximum, int executable) {
    struct stat s;
    if (lstat(path, &s) || !S_ISREG(s.st_mode) || s.st_nlink != 1 ||
        s.st_uid != getuid() || s.st_size > maximum || s.st_size < 1 ||
        (executable && !(s.st_mode & S_IXUSR))) fail("invalid owned file");
}
static void limit(int resource, rlim_t value) {
    struct rlimit r = {value, value};
    if (setrlimit(resource, &r)) { fprintf(stderr, "source-runner: limit %d: %s\n", resource, strerror(errno)); fail("resource limit unavailable"); }
}

/* Work-root authority: MACSCOPE_WORK_ROOT (absolute) or the user's home directory.
   Keep in step with MacScopeWorkRoot in Phase2ShellBrokerXPCProtocol.swift. */
static int under_work_root(const char *candidate) {
    char base[PATH_MAX], resolved[PATH_MAX];
    const char *configured = getenv("MACSCOPE_WORK_ROOT");
    if (configured && configured[0] == '/') {
        if (strlen(configured) >= sizeof base) fail("work root too long");
        strcpy(base, configured);
    } else {
        struct passwd *entry = getpwuid(getuid());
        if (!entry || !entry->pw_dir || strlen(entry->pw_dir) >= sizeof base) fail("work root unavailable");
        strcpy(base, entry->pw_dir);
    }
    if (realpath(base, resolved)) strcpy(base, resolved);
    size_t length = strlen(base);
    while (length > 1 && base[length - 1] == '/') base[--length] = 0;
    if (length == 1) return candidate[0] == '/';
    return strncmp(candidate, base, length) == 0 && candidate[length] == '/';
}

/* REA final-channel capture: independent files, never the PTY's merged diagnostics. */
static size_t read_owned(const char *path, char *bytes, size_t capacity) {
    regular(path, (off_t)capacity, 0);
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) fail("scenario input unavailable");
    size_t used = 0;
    while (used < capacity) {
        ssize_t n = read(fd, bytes + used, capacity - used);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) fail("scenario input read failed");
        if (n == 0) break;
        used += (size_t)n;
    }
    close(fd); return used;
}
static size_t split_nul(char *bytes, size_t count, char **values, size_t capacity) {
    if (count && bytes[count - 1]) fail("scenario vector not NUL terminated");
    size_t total = 0, start = 0;
    for (size_t i = 0; i < count; ++i) if (!bytes[i]) {
        if (total + 1 >= capacity) fail("scenario vector limit");
        values[total++] = bytes + start; start = i + 1;
    }
    values[total] = NULL; return total;
}
static void scenario(const char *path) {
    char root[PATH_MAX], binary[PATH_MAX], input[PATH_MAX], output[PATH_MAX], file[PATH_MAX], cwd[PATH_MAX];
    canonical(path, root);
    if (!under_work_root(root)) fail("scenario root outside authority");
    struct stat st;
    if (lstat(root, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 0777) != 0700) fail("invalid scenario root");
    if (snprintf(binary, sizeof binary, "%s/executable", root) >= PATH_MAX ||
        snprintf(input, sizeof input, "%s/input", root) >= PATH_MAX ||
        snprintf(output, sizeof output, "%s/output", root) >= PATH_MAX) fail("scenario path limit");
    regular(binary, 16777216, 1);
    char argumentBytes[65536], environmentBytes[65536], relative[4097];
    char *args[131], *env[130]; args[0] = binary;
    snprintf(file, sizeof file, "%s/arguments.bin", root);
    /* Empty vectors are represented by an empty regular file. */
    int afd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (afd < 0 || fstat(afd, &st) || !S_ISREG(st.st_mode) || st.st_size > 65536 || st.st_size < 0) fail("argument file");
    ssize_t an = read(afd, argumentBytes, sizeof argumentBytes); close(afd);
    if (an < 0 || an != st.st_size) fail("argument read");
    split_nul(argumentBytes, (size_t)an, args + 1, 130);
    snprintf(file, sizeof file, "%s/environment.bin", root);
    int efd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (efd < 0 || fstat(efd, &st) || !S_ISREG(st.st_mode) || st.st_size > 65536 || st.st_size < 0) fail("environment file");
    ssize_t en = read(efd, environmentBytes, sizeof environmentBytes); close(efd);
    if (en < 0 || en != st.st_size) fail("environment read");
    split_nul(environmentBytes, (size_t)en, env, 130);
    snprintf(file, sizeof file, "%s/working-directory.bin", root);
    size_t rn = read_owned(file, relative, 4096); relative[rn] = 0;
    if (!rn || relative[0] == '/') fail("relative working directory");
    if (strcmp(relative, ".")) {
        const char *component = relative;
        for (const char *cursor = relative; ; ++cursor) {
            if (*cursor == '/' || *cursor == 0) {
                size_t length = (size_t)(cursor - component);
                if (!length || (length == 1 && component[0] == '.') ||
                    (length == 2 && component[0] == '.' && component[1] == '.')) fail("relative working directory");
                if (!*cursor) break;
                component = cursor + 1;
            }
        }
    }
    if (!strcmp(relative, ".")) { strcpy(file, input); }
    else if (snprintf(file, sizeof file, "%s/%s", input, relative) >= PATH_MAX) fail("working directory limit");
    canonical(file, cwd);
    if (strncmp(cwd, input, strlen(input)) || (cwd[strlen(input)] && cwd[strlen(input)] != '/')) fail("working directory escapes input");
    if (getpgrp() != getpid()) fail("owned process group required");
    int descriptorCount = getdtablesize();
    if (descriptorCount < 3 || descriptorCount > 1048576) fail("descriptor limit");
    for (int fd = 3; fd < descriptorCount; ++fd) close(fd);
    limit(RLIMIT_CPU, 10); limit(RLIMIT_STACK, 8388608); limit(RLIMIT_FSIZE, 8192); limit(RLIMIT_NOFILE, 64); limit(RLIMIT_CORE, 0);
    static const char ack[] = "MACSCOPE_SOURCE_EXECUTION_ACK_V1\n";
    for (size_t i = 0; i < sizeof ack - 1; ++i) {
        char c; ssize_t n;
        do { n = read(STDIN_FILENO, &c, 1); } while (n < 0 && errno == EINTR);
        if (n != 1 || c != ack[i]) fail("scenario broker acknowledgement");
    }
    if (mkdir(output, 0700)) fail("scenario output already exists");
    for (int channel = 1; channel <= 2; ++channel) {
        snprintf(file, sizeof file, "%s/%s", output, channel == 1 ? "stdout" : "stderr");
        int fd = open(file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0 || dup2(fd, channel) < 0) fail("scenario channel unavailable");
        if (fd != channel) close(fd);
    }
    int nullInput = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (nullInput < 0 || dup2(nullInput, STDIN_FILENO) < 0) fail("scenario input isolation");
    if (nullInput != STDIN_FILENO) close(nullInput);
    if (chdir(cwd)) fail("scenario cwd unavailable");
    char profile[32768];
    int n = snprintf(profile, sizeof profile,
        "(version 1)(deny default)(allow sysctl-read)"
        "(allow file-read* (literal \"/\") (subpath \"/System/Library\") (subpath \"/usr/lib\") (literal \"/dev/null\") (literal \"/dev/urandom\") (literal \"%s\") (subpath \"%s\"))"
        "(allow file-read-metadata)(allow process-exec (literal \"%s\"))"
        "(allow file-write* (literal \"%s/stdout\") (literal \"%s/stderr\"))",
        binary, input, binary, output, output);
    if (n < 0 || (size_t)n >= sizeof profile) fail("scenario policy limit");
    char *launcher[135]; launcher[0] = "sandbox-exec"; launcher[1] = "-p"; launcher[2] = profile;
    size_t i = 0; while (args[i]) { launcher[i + 3] = args[i]; ++i; } launcher[i + 3] = NULL;
    execve("/usr/bin/sandbox-exec", launcher, env); fail("scenario confinement exec failed");
}


/* Fixed Apple asset metadata reader: no arbitrary executable or argument input. */
static void asset_catalog(const char *path) {
    char root[PATH_MAX], catalog[PATH_MAX], output[PATH_MAX], file[PATH_MAX];
    canonical(path, root);
    if (!under_work_root(root)) fail("asset root outside authority");
    struct stat st;
    if (lstat(root, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 0777) != 0700) fail("invalid asset root");
    if (snprintf(catalog, sizeof catalog, "%s/catalog.car", root) >= PATH_MAX ||
        snprintf(output, sizeof output, "%s/output", root) >= PATH_MAX) fail("asset path limit");
    regular(catalog, 67108864, 0);
    if (lstat("/usr/bin/assetutil", &st) || !S_ISREG(st.st_mode) || st.st_uid != 0 || !(st.st_mode & S_IXUSR)) fail("invalid system asset tool");
    if (getpgrp() != getpid()) fail("owned process group required");
    int descriptors = getdtablesize();
    if (descriptors < 3 || descriptors > 1048576) fail("descriptor limit");
    for (int fd = 3; fd < descriptors; ++fd) close(fd);
    limit(RLIMIT_CPU, 10); limit(RLIMIT_STACK, 8388608); limit(RLIMIT_FSIZE, 8388609); limit(RLIMIT_NOFILE, 64); limit(RLIMIT_CORE, 0);
    static const char ack[] = "MACSCOPE_SOURCE_EXECUTION_ACK_V1\n";
    for (size_t i = 0; i < sizeof ack - 1; ++i) {
        char c; ssize_t n; do { n = read(STDIN_FILENO, &c, 1); } while (n < 0 && errno == EINTR);
        if (n != 1 || c != ack[i]) fail("asset broker acknowledgement");
    }
    if (mkdir(output, 0700)) fail("asset output already exists");
    for (int channel = 1; channel <= 2; ++channel) {
        snprintf(file, sizeof file, "%s/%s", output, channel == 1 ? "stdout" : "stderr");
        int fd = open(file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0 || dup2(fd, channel) < 0) fail("asset channel unavailable");
        if (fd != channel) close(fd);
    }
    int input = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (input < 0 || dup2(input, STDIN_FILENO) < 0) fail("asset input isolation");
    if (input != STDIN_FILENO) close(input);
    if (chdir(root)) fail("asset cwd unavailable");
    char profile[32768];
    int n = snprintf(profile, sizeof profile,
        "(version 1)(deny default)(allow sysctl-read)"
        "(allow file-read* (literal \"/\") (subpath \"/System/Library\") (subpath \"/usr/lib\") (literal \"/usr/bin/assetutil\") (literal \"/dev/null\") (literal \"/dev/urandom\") (literal \"%s\"))"
        "(allow file-read-metadata)(allow process-exec (literal \"/usr/bin/assetutil\"))"
        "(allow file-write* (literal \"%s/stdout\") (literal \"%s/stderr\"))", catalog, output, output);
    if (n < 0 || (size_t)n >= sizeof profile) fail("asset policy limit");
    char *args[] = {"sandbox-exec", "-p", profile, "/usr/bin/assetutil", "--info", catalog, NULL};
    char *env[] = {"LANG=C", "LC_ALL=C", NULL};
    execve("/usr/bin/sandbox-exec", args, env); fail("asset confinement exec failed");
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "asset-catalog")) { asset_catalog(argv[2]); return 125; }
    if (argc == 3 && !strcmp(argv[1], "scenario")) { scenario(argv[2]); return 125; }
    /* This exact unversioned argv grammar is the immutable scalar-u32-v1 mode.
       A future profile needs a distinct grammar; extra mode/profile arguments fail below. */
    int compile = argc == 6 && !strcmp(argv[1], "compile");
    int inspect = argc == 6 && !strcmp(argv[1], "inspect");
    int compiler = compile || inspect;
    int behavior = argc == 3 && !strcmp(argv[1], "behavior");
    if (!compiler && !behavior) fail("expected inspect/compile ROOT CLANG SDK TOOLCHAIN or behavior ROOT");
    char root[PATH_MAX], clang[PATH_MAX], sdk[PATH_MAX], toolchain[PATH_MAX];
    canonical(argv[2], root);
    if (!under_work_root(root)) fail("run root outside work root authority");
    struct stat s;
    if (stat(root, &s) || !S_ISDIR(s.st_mode) || s.st_uid != getuid() ||
        (s.st_mode & 0777) != 0700) fail("run root must be private and owned");
    char candidate[PATH_MAX], harness[PATH_MAX], output[PATH_MAX], binary[PATH_MAX];
    if (snprintf(candidate, sizeof candidate, "%s/candidate.c", root) >= PATH_MAX ||
        snprintf(harness, sizeof harness, "%s/harness.c", root) >= PATH_MAX ||
        snprintf(output, sizeof output, "%s/%s", root, inspect ? "inspection" : "output") >= PATH_MAX ||
        snprintf(binary, sizeof binary, "%s/output/candidate", root) >= PATH_MAX) fail("path limit");
    regular(candidate, 65536, 0); regular(harness, 65536, 0);
    if (compiler) {
        canonical(argv[3], clang); canonical(argv[4], sdk); canonical(argv[5], toolchain);
        char expected[PATH_MAX];
        if (snprintf(expected, sizeof expected, "%s/usr/bin/clang", toolchain) >= PATH_MAX ||
            strcmp(expected, clang) || strncmp(toolchain, "/Applications/", 14) ||
            strncmp(sdk, "/Applications/", 14)) fail("invalid toolchain closure");
        if (access(clang, X_OK) || stat(sdk, &s) || !S_ISDIR(s.st_mode)) fail("toolchain unavailable");
        if (mkdir(output, 0700)) fail("output must not preexist");
    } else {
        char actual[PATH_MAX]; canonical(output, actual);
        if (stat(output, &s) || !S_ISDIR(s.st_mode) || s.st_uid != getuid() ||
            (s.st_mode & 0777) != 0700) fail("invalid output directory");
        regular(binary, 1048576, 1);
    }
    // ShellBroker is the process owner; never create another session or supervisor.
    if (getpgrp() != getpid()) fail("owned process group required");
    int descriptorCount = getdtablesize();
    if (descriptorCount < 3 || descriptorCount > 1048576) fail("unsupported descriptor table");
    for (int fd = 3; fd < descriptorCount; ++fd) close(fd);
    limit(RLIMIT_CPU, 10); /* macOS rejects AS/DATA caps; RSS watchdog remains an integration prerequisite. */ limit(RLIMIT_STACK, 8388608); limit(RLIMIT_FSIZE, 1048576);
    limit(RLIMIT_NOFILE, 64); limit(RLIMIT_CORE, 0);
    if (chdir(root)) fail("working directory unavailable");
    // The profile is produced here from canonical paths only; callers cannot supply SBPL.
    char profile[32768];
    const char *base = "(version 1)(deny default)"
        "(allow file-read* (literal \"/\") (subpath \"/System/Library\") (subpath \"/usr/lib\")"
        " (literal \"/dev/null\") (literal \"/dev/urandom\"))"
        "(allow sysctl-read)(allow file-read-metadata (literal \"/System\") (literal \"/usr\") (literal \"/dev\"))";
    char metadata[16384] = "(allow file-read-metadata";
    const char *paths[] = {root, compiler ? clang : binary, compiler ? sdk : output};
    for (size_t i = 0; i < 3; ++i) {
        char parent[PATH_MAX]; strcpy(parent, paths[i]);
        for (;;) {
            size_t used = strlen(metadata);
            int n = snprintf(metadata + used, sizeof metadata - used, " (literal \"%s\")", parent);
            if (n < 0 || (size_t)n >= sizeof metadata - used) fail("metadata policy limit");
            char *slash = strrchr(parent, '/');
            if (!slash || slash == parent) break;
            *slash = 0;
        }
    }
    strcat(metadata, ")");
    int count;
    if (compiler) {
        count = snprintf(profile, sizeof profile,
            "%s%s(allow file-read* (subpath \"%s\") (subpath \"%s\")"
            " (literal \"%s\") (literal \"%s\") (subpath \"%s\"))"
            "(allow file-write* (subpath \"%s\") (literal \"/dev/null\"))"
            "(allow process-fork)(allow process-exec (subpath \"%s\"))",
            base, metadata, toolchain, sdk, candidate, harness, output, output, toolchain);
    } else {
        count = snprintf(profile, sizeof profile,
            "%s%s(allow file-read* (literal \"%s\"))"
            "(allow process-exec (literal \"%s\"))", base, metadata, binary, binary);
    }
    if (count < 0 || (size_t)count >= sizeof profile) fail("profile limit");
    if (access("/usr/bin/sandbox-exec", X_OK)) fail("confinement unavailable");
    char temp[PATH_MAX + 16]; snprintf(temp, sizeof temp, "TMPDIR=%s", output);
    char *env[] = {"PATH=/usr/bin:/bin", "LANG=C", "LC_ALL=C", "HOME=/nonexistent", temp, NULL};
    // ShellBroker sends this only after observing the exact signed launcher PID/group.
    // The PTY is raw/non-echo before spawn; no scheduling delay can stand in for authority.
    static const char acknowledgement[] = "MACSCOPE_SOURCE_EXECUTION_ACK_V1\n";
    char received[sizeof acknowledgement]; size_t receivedCount = 0;
    while (receivedCount < sizeof acknowledgement - 1) {
        ssize_t n = read(STDIN_FILENO, received + receivedCount, 1);
        if (n < 0 && errno == EINTR) continue;
        if (n != 1 || received[receivedCount] != acknowledgement[receivedCount])
            fail("broker acknowledgement missing or invalid");
        ++receivedCount;
    }
    int nullInput = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (nullInput < 0 || dup2(nullInput, STDIN_FILENO) < 0) fail("input isolation failed");
    if (nullInput != STDIN_FILENO) close(nullInput);
    if (inspect) {
        char ast[PATH_MAX];
        if (snprintf(ast, sizeof ast, "%s/candidate.ast.json", output) >= PATH_MAX) fail("AST path limit");
        int astOutput = open(ast, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (astOutput < 0 || fchmod(astOutput, 0400) || dup2(astOutput, STDOUT_FILENO) < 0)
            fail("AST output unavailable");
        if (astOutput != STDOUT_FILENO) close(astOutput);
        char *args[] = {"sandbox-exec", "-p", profile, clang, "-std=c11", "-O0", "-Wall",
            "-Wextra", "-Werror", "-target", "arm64-apple-macos27.0", "-isysroot", sdk,
            "-ffreestanding", "-fno-builtin", "-ferror-limit=8",
            "-fsyntax-only", "-Xclang", "-ast-dump=json", candidate, NULL};
        execve("/usr/bin/sandbox-exec", args, env);
    } else if (compile) {
        char *args[] = {"sandbox-exec", "-p", profile, clang, "-std=c11", "-O0", "-Wall",
            "-Wextra", "-Werror", "-target", "arm64-apple-macos27.0", "-isysroot", sdk,
            "-ffreestanding", "-fno-builtin", "-ferror-limit=8",
            candidate, harness, "-o", binary, NULL};
        execve("/usr/bin/sandbox-exec", args, env);
    } else {
        char *args[] = {"sandbox-exec", "-p", profile, binary, NULL};
        execve("/usr/bin/sandbox-exec", args, env);
    }
    fail("confinement exec failed");
}
