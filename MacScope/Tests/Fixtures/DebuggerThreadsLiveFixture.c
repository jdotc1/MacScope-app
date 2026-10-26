// Live multi-thread fixture for the persistent LLDB thread-selection proof (lane AQ).
// Main plus three named workers. Worker 3 calls `rendezvous` once all workers are ready; a
// breakpoint there stops with four live threads. After `rendezvous` returns, every worker leaves
// its park loop and the process exits 0, so a Continue from the breakpoint runs to exit (unless
// launched with `--hold`).
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static volatile int ready = 0;
static volatile int released = 0;
// `--hold` (lane AU, §4.100): park in sleep(600), matching the installed C6 GUI fixture.
// A Continue leaves the same four-thread process for Pause to interrupt; thread #2 is in
// __semwait_signal instead of repeatedly waking from the ordinary fixture's 1 ms usleep.
static volatile int hold = 0;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

__attribute__((noinline)) void rendezvous(int id) {
    printf("worker %d at rendezvous\n", id);
    released = 1;
}

__attribute__((noinline)) static void park_alpha(void) { if (hold) sleep(600); else while (!released) usleep(1000); }
__attribute__((noinline)) static void park_beta(void) { if (hold) sleep(600); else while (!released) usleep(1000); }
__attribute__((noinline)) static void park_gamma(void) { if (hold) sleep(600); else while (!released) usleep(1000); }

static void *worker(void *arg) {
    int id = (int)(long)arg;
    char name[32];
    snprintf(name, sizeof name, "macscope.worker.%d", id);
    pthread_setname_np(name);
    pthread_mutex_lock(&lock);
    ready++;
    pthread_mutex_unlock(&lock);
    if (id == 3) {
        while (ready < 3) usleep(1000);
        rendezvous(id);
    }
    if (id == 1) park_alpha(); else if (id == 2) park_beta(); else park_gamma();
    while (hold) usleep(1000);
    return NULL;
}

int main(int argc, char **argv) {
    hold = argc > 1 && strcmp(argv[1], "--hold") == 0;
    pthread_t threads[3];
    for (long i = 0; i < 3; i++) pthread_create(&threads[i], NULL, worker, (void *)(i + 1));
    for (int i = 0; i < 3; i++) pthread_join(threads[i], NULL);
    return 0;
}
