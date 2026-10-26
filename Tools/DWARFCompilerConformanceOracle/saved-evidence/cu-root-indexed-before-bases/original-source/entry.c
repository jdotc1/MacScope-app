extern volatile int sink; void _start(void) { sink=1; for(;;) { __asm__ volatile("" ::: "memory"); } }
