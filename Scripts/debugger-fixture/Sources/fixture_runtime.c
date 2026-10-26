#include "fixture_runtime.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define FIXTURE_SCHEMA 1
#define MAX_COMMAND_BYTES 4096
#define MAX_NONCE_BYTES 128

typedef struct {
    const char *role;
    const char *nonce;
    FILE *events;
    uint64_t event_sequence;
    uint64_t next_command_sequence;
    uint64_t checkpoint_count;
    uint64_t load_count;
    uint64_t unload_count;
    bool framework_loaded;
    bool exiting;
    void *framework_handle;
    macscope_fixture_checkpoint_function own_checkpoint;
    macscope_fixture_checkpoint_function framework_checkpoint;
} fixture_state;

static bool safe_token(const char *value) {
    size_t length = strlen(value);
    if (length == 0 || length > MAX_NONCE_BYTES) {
        return false;
    }
    for (size_t index = 0; index < length; index++) {
        char character = value[index];
        bool allowed = (character >= 'a' && character <= 'z') ||
            (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') ||
            character == '-' || character == '_' || character == '.';
        if (!allowed) {
            return false;
        }
    }
    return true;
}

static int emit_event(
    fixture_state *state,
    const char *operation,
    const char *result,
    uint64_t command_sequence,
    bool has_command_sequence
) {
    state->event_sequence++;
    int written = fprintf(
        state->events,
        "{\"commandSequence\":%" PRIu64
        ",\"counters\":{\"checkpoint\":%" PRIu64
        ",\"load\":%" PRIu64 ",\"unload\":%" PRIu64
        "},\"exiting\":%s,\"frameworkLoaded\":%s,\"nonce\":\"%s\""
        ",\"operation\":\"%s\",\"pid\":%d,\"result\":\"%s\""
        ",\"role\":\"%s\",\"schema\":%d,\"sequence\":%" PRIu64 "}\n",
        has_command_sequence ? command_sequence : UINT64_C(0),
        state->checkpoint_count,
        state->load_count,
        state->unload_count,
        state->exiting ? "true" : "false",
        state->framework_loaded ? "true" : "false",
        state->nonce,
        operation,
        getpid(),
        result,
        state->role,
        FIXTURE_SCHEMA,
        state->event_sequence
    );
    if (written < 0 || fflush(state->events) != 0 || fsync(fileno(state->events)) != 0) {
        return -1;
    }
    return 0;
}

typedef struct {
    const char *cursor;
} json_cursor;

static void skip_whitespace(json_cursor *cursor) {
    while (*cursor->cursor == ' ' || *cursor->cursor == '\t' ||
           *cursor->cursor == '\r' || *cursor->cursor == '\n') {
        cursor->cursor++;
    }
}

static bool consume_character(json_cursor *cursor, char expected) {
    skip_whitespace(cursor);
    if (*cursor->cursor != expected) {
        return false;
    }
    cursor->cursor++;
    return true;
}

static bool parse_json_string(json_cursor *cursor, char *output, size_t capacity) {
    skip_whitespace(cursor);
    if (*cursor->cursor != '"') {
        return false;
    }
    cursor->cursor++;
    size_t length = 0;
    while (*cursor->cursor != '\0' && *cursor->cursor != '"') {
        unsigned char character = (unsigned char)*cursor->cursor;
        if (character < 0x20 || character == '\\' || length + 1 >= capacity) {
            return false;
        }
        output[length++] = (char)character;
        cursor->cursor++;
    }
    if (*cursor->cursor != '"') {
        return false;
    }
    cursor->cursor++;
    output[length] = '\0';
    return true;
}

static bool parse_json_uint64(json_cursor *cursor, uint64_t *output) {
    skip_whitespace(cursor);
    if (*cursor->cursor < '0' || *cursor->cursor > '9') {
        return false;
    }
    uint64_t value = 0;
    while (*cursor->cursor >= '0' && *cursor->cursor <= '9') {
        uint64_t digit = (uint64_t)(*cursor->cursor - '0');
        if (value > (UINT64_MAX - digit) / UINT64_C(10)) {
            return false;
        }
        value = value * UINT64_C(10) + digit;
        cursor->cursor++;
    }
    *output = value;
    return true;
}

static bool parse_command(
    const char *line,
    const char *expected_nonce,
    uint64_t expected_sequence,
    char operation[32]
) {
    if (line == NULL) {
        return false;
    }
    uint64_t schema = 0;
    uint64_t sequence = 0;
    char nonce[MAX_NONCE_BYTES + 1];
    nonce[0] = '\0';
    operation[0] = '\0';
    unsigned int seen = 0;
    json_cursor cursor = {.cursor = line};
    if (!consume_character(&cursor, '{')) {
        return false;
    }
    for (int field_index = 0; field_index < 4; field_index++) {
        char key[32];
        if (!parse_json_string(&cursor, key, sizeof(key)) ||
            !consume_character(&cursor, ':')) {
            return false;
        }
        unsigned int bit = 0;
        if (strcmp(key, "schema") == 0) {
            bit = 1U << 0;
            if (!parse_json_uint64(&cursor, &schema)) return false;
        } else if (strcmp(key, "sequence") == 0) {
            bit = 1U << 1;
            if (!parse_json_uint64(&cursor, &sequence)) return false;
        } else if (strcmp(key, "nonce") == 0) {
            bit = 1U << 2;
            if (!parse_json_string(&cursor, nonce, sizeof(nonce))) return false;
        } else if (strcmp(key, "operation") == 0) {
            bit = 1U << 3;
            if (!parse_json_string(&cursor, operation, 32)) return false;
        } else {
            return false;
        }
        if ((seen & bit) != 0) {
            return false;
        }
        seen |= bit;
        if (field_index < 3) {
            if (!consume_character(&cursor, ',')) return false;
        }
    }
    if (seen != 0x0fU || !consume_character(&cursor, '}')) {
        return false;
    }
    skip_whitespace(&cursor);
    if (*cursor.cursor != '\0') {
        return false;
    }
    if (schema != FIXTURE_SCHEMA || sequence != expected_sequence ||
        strcmp(nonce, expected_nonce) != 0) {
        return false;
    }
    return strcmp(operation, "load") == 0 || strcmp(operation, "checkpoint") == 0 ||
        strcmp(operation, "unload") == 0 || strcmp(operation, "exit") == 0;
}

static int framework_path(char output[PATH_MAX]) {
    uint32_t capacity = PATH_MAX;
    if (_NSGetExecutablePath(output, &capacity) != 0) {
        return -1;
    }
    char *last_component = strrchr(output, '/');
    if (last_component == NULL) {
        return -1;
    }
    *last_component = '\0';
    size_t used = strlen(output);
    const char *suffix =
        "/../Frameworks/MacScopeDebuggerFixtureRuntime.framework/"
        "MacScopeDebuggerFixtureRuntime";
    if (used + strlen(suffix) + 1 > PATH_MAX) {
        return -1;
    }
    memcpy(output + used, suffix, strlen(suffix) + 1);
    return 0;
}

static int load_framework(fixture_state *state) {
    if (state->framework_loaded) {
        return -1;
    }
    char path[PATH_MAX];
    if (framework_path(path) != 0) {
        return -1;
    }
    state->framework_handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (state->framework_handle == NULL) {
        return -1;
    }
    state->framework_checkpoint = (macscope_fixture_checkpoint_function)dlsym(
        state->framework_handle,
        "macscope_fixture_framework_checkpoint"
    );
    if (state->framework_checkpoint == NULL) {
        dlclose(state->framework_handle);
        state->framework_handle = NULL;
        return -1;
    }
    state->framework_loaded = true;
    state->load_count++;
    return 0;
}

static int unload_framework(fixture_state *state) {
    if (!state->framework_loaded || state->framework_handle == NULL) {
        return -1;
    }
    if (dlclose(state->framework_handle) != 0) {
        return -1;
    }
    state->framework_handle = NULL;
    state->framework_checkpoint = NULL;
    state->framework_loaded = false;
    state->unload_count++;
    return 0;
}

static uint64_t modification_time_ns(const struct stat *metadata) {
#if defined(__APPLE__)
    return (uint64_t)metadata->st_mtimespec.tv_sec * UINT64_C(1000000000) +
        (uint64_t)metadata->st_mtimespec.tv_nsec;
#else
    return (uint64_t)metadata->st_mtim.tv_sec * UINT64_C(1000000000) +
        (uint64_t)metadata->st_mtim.tv_nsec;
#endif
}

static int open_control_root(
    const char *path,
    uint64_t started_after_ns,
    int *directory_fd
) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        return -1;
    }
    struct stat metadata;
    if (fstat(fd, &metadata) != 0 || !S_ISDIR(metadata.st_mode) ||
        (metadata.st_mode & 0777) != 0700 || metadata.st_uid != geteuid() ||
        modification_time_ns(&metadata) < started_after_ns) {
        close(fd);
        return -1;
    }
    *directory_fd = fd;
    return 0;
}

static int open_channels(
    int control_fd,
    const char *role,
    FILE **events,
    FILE **commands
) {
    char event_name[64];
    char command_name[64];
    int event_length = snprintf(event_name, sizeof(event_name), "%s.events.jsonl", role);
    int command_length = snprintf(command_name, sizeof(command_name), "%s.commands", role);
    if (event_length < 0 || (size_t)event_length >= sizeof(event_name) ||
        command_length < 0 || (size_t)command_length >= sizeof(command_name)) {
        return -1;
    }
    bool event_created = false;
    bool command_created = false;
    int event_fd = openat(
        control_fd,
        event_name,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0600
    );
    if (event_fd < 0) {
        return -1;
    }
    event_created = true;
    struct stat event_metadata;
    if (fchmod(event_fd, 0600) != 0 || fstat(event_fd, &event_metadata) != 0 ||
        !S_ISREG(event_metadata.st_mode) || (event_metadata.st_mode & 0777) != 0600 ||
        event_metadata.st_uid != geteuid()) {
        if (event_fd >= 0) close(event_fd);
        goto fail;
    }
    if (mkfifoat(control_fd, command_name, 0600) != 0) {
        close(event_fd);
        goto fail;
    }
    command_created = true;
    if (fchmodat(control_fd, command_name, 0600, 0) != 0) {
        close(event_fd);
        goto fail;
    }
    struct stat command_metadata;
    if (fstatat(control_fd, command_name, &command_metadata, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISFIFO(command_metadata.st_mode) || (command_metadata.st_mode & 0777) != 0600 ||
        command_metadata.st_uid != geteuid()) {
        close(event_fd);
        goto fail;
    }
    *events = fdopen(event_fd, "w");
    if (*events == NULL) {
        close(event_fd);
        goto fail;
    }
    int command_fd = openat(control_fd, command_name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (command_fd < 0) {
        fclose(*events);
        *events = NULL;
        goto fail;
    }
    *commands = fdopen(command_fd, "r");
    if (*commands == NULL) {
        close(command_fd);
        fclose(*events);
        *events = NULL;
        goto fail;
    }
    return 0;

fail:
    if (command_created) unlinkat(control_fd, command_name, 0);
    if (event_created) unlinkat(control_fd, event_name, 0);
    return -1;
}

static bool parse_uint64_argument(const char *value, uint64_t *output) {
    if (value == NULL || *value == '\0' || *value == '-') return false;
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0') return false;
    *output = (uint64_t)parsed;
    return true;
}

static int parse_arguments(
    int argc,
    char *argv[],
    const char **control_root,
    const char **nonce,
    uint64_t *started_after_ns
) {
    *control_root = NULL;
    *nonce = NULL;
    *started_after_ns = 0;
    if (argc != 7) {
        return -1;
    }
    unsigned int seen = 0;
    for (int index = 1; index + 1 < argc; index += 2) {
        if (strcmp(argv[index], "--control-dir") == 0) {
            if ((seen & 1U) != 0) return -1;
            *control_root = argv[index + 1];
            seen |= 1U;
        } else if (strcmp(argv[index], "--nonce") == 0) {
            if ((seen & 2U) != 0) return -1;
            *nonce = argv[index + 1];
            seen |= 2U;
        } else if (strcmp(argv[index], "--started-after-ns") == 0) {
            if ((seen & 4U) != 0 ||
                !parse_uint64_argument(argv[index + 1], started_after_ns)) {
                return -1;
            }
            seen |= 4U;
        } else {
            return -1;
        }
    }
    return seen == 7U && safe_token(*nonce) ? 0 : -1;
}

int macscope_fixture_run(
    const char *role,
    int argc,
    char *argv[],
    macscope_fixture_checkpoint_function checkpoint
) {
    const char *control_root = NULL;
    const char *nonce = NULL;
    uint64_t started_after_ns = 0;
    if (parse_arguments(argc, argv, &control_root, &nonce, &started_after_ns) != 0) {
        return 64;
    }
    int control_fd = -1;
    if (open_control_root(control_root, started_after_ns, &control_fd) != 0) {
        return 64;
    }
    FILE *events = NULL;
    FILE *commands = NULL;
    if (open_channels(control_fd, role, &events, &commands) != 0) {
        close(control_fd);
        return 65;
    }
    close(control_fd);
    fixture_state state = {
        .role = role,
        .nonce = nonce,
        .events = events,
        .event_sequence = 0,
        .next_command_sequence = 1,
        .own_checkpoint = checkpoint,
    };
    if (emit_event(&state, "ready", "ok", 0, false) != 0) {
        fclose(commands);
        fclose(events);
        return 66;
    }

    int exit_status = 0;
    char line[MAX_COMMAND_BYTES + 2];
    while (!state.exiting) {
        errno = 0;
        if (fgets(line, sizeof(line), commands) == NULL) {
            if (ferror(commands)) {
                if (errno == EINTR) {
                    clearerr(commands);
                    continue;
                }
                state.exiting = true;
                emit_event(&state, "commandReadError", "failed", 0, false);
                exit_status = 69;
                break;
            }
            state.exiting = true;
            emit_event(&state, "commandEOF", "gracefulExit", 0, false);
            break;
        }
        size_t length = strlen(line);
        bool has_newline = length > 0 && line[length - 1] == '\n';
        bool oversized = length > MAX_COMMAND_BYTES || (!has_newline && !feof(commands));
        if (oversized) {
            int character = 0;
            while (!has_newline && (character = fgetc(commands)) != EOF) {
                if (character == '\n') has_newline = true;
            }
            emit_event(
                &state,
                "protocolError",
                "rejected",
                state.next_command_sequence,
                true
            );
            exit_status = 67;
            break;
        }
        char operation[32];
        uint64_t command_sequence = state.next_command_sequence;
        if (!parse_command(line, nonce, command_sequence, operation)) {
            emit_event(&state, "protocolError", "rejected", command_sequence, true);
            exit_status = 67;
            break;
        }
        int operation_status = 0;
        if (strcmp(operation, "load") == 0) {
            operation_status = load_framework(&state);
        } else if (strcmp(operation, "checkpoint") == 0) {
            state.own_checkpoint();
            if (state.framework_loaded) state.framework_checkpoint();
            state.checkpoint_count++;
        } else if (strcmp(operation, "unload") == 0) {
            operation_status = unload_framework(&state);
        } else if (strcmp(operation, "exit") == 0) {
            state.exiting = true;
        }
        state.next_command_sequence++;
        if (emit_event(
                &state,
                operation,
                operation_status == 0 ? "ok" : "rejected",
                command_sequence,
                true
            ) != 0 || operation_status != 0) {
            exit_status = 68;
            break;
        }
    }
    if (state.framework_loaded) unload_framework(&state);
    fclose(commands);
    fclose(events);
    return exit_status;
}
