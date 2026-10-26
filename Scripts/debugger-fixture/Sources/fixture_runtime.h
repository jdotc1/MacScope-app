#ifndef MACSCOPE_DEBUGGER_FIXTURE_RUNTIME_H
#define MACSCOPE_DEBUGGER_FIXTURE_RUNTIME_H

#include <stdint.h>

typedef uint64_t (*macscope_fixture_checkpoint_function)(void);

int macscope_fixture_run(
    const char *role,
    int argc,
    char *argv[],
    macscope_fixture_checkpoint_function checkpoint
);

#endif
