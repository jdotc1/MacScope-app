#include "ProcessIsolation.h"
#include <unistd.h>

/* Swift does not import fork as callable. Keep this POSIX operation in C. */
pid_t vwo_fork(void) {
    return fork();
}
