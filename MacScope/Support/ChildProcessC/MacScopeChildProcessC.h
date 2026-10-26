#ifndef MACSCOPE_CHILD_PROCESS_C_H
#define MACSCOPE_CHILD_PROCESS_C_H

#include <signal.h>
#include <stddef.h>

// Read only. No caller can provide a replacement disposition through this API.
static inline int MacScopeReadSignalDisposition(int signalNumber,
                                                struct sigaction *previous) {
    return sigaction(signalNumber, NULL, previous);
}

#endif
