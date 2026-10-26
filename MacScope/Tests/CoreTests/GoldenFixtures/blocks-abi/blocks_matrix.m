// Blocks ABI capture-layout fixtures: one function per capture shape. No system headers required.
extern void observe_block(void *);
extern void consume_id(id);
extern void consume_int(long);
extern void consume_double(double);
extern void consume_ptr(void *);
extern void consume_block(void (^)(void));
__attribute__((noinline)) void fixture_global(id input, long seed) {
    void (^value)(void) = ^{ consume_int(7); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_strong_1(id input, long seed) {
    id strong_0 = input;
    void (^value)(void) = ^{ consume_id(strong_0); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_strong_2(id input, long seed) {
    id strong_0 = input;
    id strong_1 = input;
    void (^value)(void) = ^{ consume_id(strong_0); consume_id(strong_1); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_strong_3(id input, long seed) {
    id strong_0 = input;
    id strong_1 = input;
    id strong_2 = input;
    void (^value)(void) = ^{ consume_id(strong_0); consume_id(strong_1); consume_id(strong_2); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_strong_15(id input, long seed) {
    id strong_0 = input;
    id strong_1 = input;
    id strong_2 = input;
    id strong_3 = input;
    id strong_4 = input;
    id strong_5 = input;
    id strong_6 = input;
    id strong_7 = input;
    id strong_8 = input;
    id strong_9 = input;
    id strong_10 = input;
    id strong_11 = input;
    id strong_12 = input;
    id strong_13 = input;
    id strong_14 = input;
    void (^value)(void) = ^{ consume_id(strong_0); consume_id(strong_1); consume_id(strong_2); consume_id(strong_3); consume_id(strong_4); consume_id(strong_5); consume_id(strong_6); consume_id(strong_7); consume_id(strong_8); consume_id(strong_9); consume_id(strong_10); consume_id(strong_11); consume_id(strong_12); consume_id(strong_13); consume_id(strong_14); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_strong_16(id input, long seed) {
    id strong_0 = input;
    id strong_1 = input;
    id strong_2 = input;
    id strong_3 = input;
    id strong_4 = input;
    id strong_5 = input;
    id strong_6 = input;
    id strong_7 = input;
    id strong_8 = input;
    id strong_9 = input;
    id strong_10 = input;
    id strong_11 = input;
    id strong_12 = input;
    id strong_13 = input;
    id strong_14 = input;
    id strong_15 = input;
    void (^value)(void) = ^{ consume_id(strong_0); consume_id(strong_1); consume_id(strong_2); consume_id(strong_3); consume_id(strong_4); consume_id(strong_5); consume_id(strong_6); consume_id(strong_7); consume_id(strong_8); consume_id(strong_9); consume_id(strong_10); consume_id(strong_11); consume_id(strong_12); consume_id(strong_13); consume_id(strong_14); consume_id(strong_15); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_strong_17(id input, long seed) {
    id strong_0 = input;
    id strong_1 = input;
    id strong_2 = input;
    id strong_3 = input;
    id strong_4 = input;
    id strong_5 = input;
    id strong_6 = input;
    id strong_7 = input;
    id strong_8 = input;
    id strong_9 = input;
    id strong_10 = input;
    id strong_11 = input;
    id strong_12 = input;
    id strong_13 = input;
    id strong_14 = input;
    id strong_15 = input;
    id strong_16 = input;
    void (^value)(void) = ^{ consume_id(strong_0); consume_id(strong_1); consume_id(strong_2); consume_id(strong_3); consume_id(strong_4); consume_id(strong_5); consume_id(strong_6); consume_id(strong_7); consume_id(strong_8); consume_id(strong_9); consume_id(strong_10); consume_id(strong_11); consume_id(strong_12); consume_id(strong_13); consume_id(strong_14); consume_id(strong_15); consume_id(strong_16); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_strong_31(id input, long seed) {
    id strong_0 = input;
    id strong_1 = input;
    id strong_2 = input;
    id strong_3 = input;
    id strong_4 = input;
    id strong_5 = input;
    id strong_6 = input;
    id strong_7 = input;
    id strong_8 = input;
    id strong_9 = input;
    id strong_10 = input;
    id strong_11 = input;
    id strong_12 = input;
    id strong_13 = input;
    id strong_14 = input;
    id strong_15 = input;
    id strong_16 = input;
    id strong_17 = input;
    id strong_18 = input;
    id strong_19 = input;
    id strong_20 = input;
    id strong_21 = input;
    id strong_22 = input;
    id strong_23 = input;
    id strong_24 = input;
    id strong_25 = input;
    id strong_26 = input;
    id strong_27 = input;
    id strong_28 = input;
    id strong_29 = input;
    id strong_30 = input;
    void (^value)(void) = ^{ consume_id(strong_0); consume_id(strong_1); consume_id(strong_2); consume_id(strong_3); consume_id(strong_4); consume_id(strong_5); consume_id(strong_6); consume_id(strong_7); consume_id(strong_8); consume_id(strong_9); consume_id(strong_10); consume_id(strong_11); consume_id(strong_12); consume_id(strong_13); consume_id(strong_14); consume_id(strong_15); consume_id(strong_16); consume_id(strong_17); consume_id(strong_18); consume_id(strong_19); consume_id(strong_20); consume_id(strong_21); consume_id(strong_22); consume_id(strong_23); consume_id(strong_24); consume_id(strong_25); consume_id(strong_26); consume_id(strong_27); consume_id(strong_28); consume_id(strong_29); consume_id(strong_30); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_strong_32(id input, long seed) {
    id strong_0 = input;
    id strong_1 = input;
    id strong_2 = input;
    id strong_3 = input;
    id strong_4 = input;
    id strong_5 = input;
    id strong_6 = input;
    id strong_7 = input;
    id strong_8 = input;
    id strong_9 = input;
    id strong_10 = input;
    id strong_11 = input;
    id strong_12 = input;
    id strong_13 = input;
    id strong_14 = input;
    id strong_15 = input;
    id strong_16 = input;
    id strong_17 = input;
    id strong_18 = input;
    id strong_19 = input;
    id strong_20 = input;
    id strong_21 = input;
    id strong_22 = input;
    id strong_23 = input;
    id strong_24 = input;
    id strong_25 = input;
    id strong_26 = input;
    id strong_27 = input;
    id strong_28 = input;
    id strong_29 = input;
    id strong_30 = input;
    id strong_31 = input;
    void (^value)(void) = ^{ consume_id(strong_0); consume_id(strong_1); consume_id(strong_2); consume_id(strong_3); consume_id(strong_4); consume_id(strong_5); consume_id(strong_6); consume_id(strong_7); consume_id(strong_8); consume_id(strong_9); consume_id(strong_10); consume_id(strong_11); consume_id(strong_12); consume_id(strong_13); consume_id(strong_14); consume_id(strong_15); consume_id(strong_16); consume_id(strong_17); consume_id(strong_18); consume_id(strong_19); consume_id(strong_20); consume_id(strong_21); consume_id(strong_22); consume_id(strong_23); consume_id(strong_24); consume_id(strong_25); consume_id(strong_26); consume_id(strong_27); consume_id(strong_28); consume_id(strong_29); consume_id(strong_30); consume_id(strong_31); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_weak_1(id input, long seed) {
    __weak id weak_0 = input;
    void (^value)(void) = ^{ consume_id(weak_0); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_weak_2(id input, long seed) {
    __weak id weak_0 = input;
    __weak id weak_1 = input;
    void (^value)(void) = ^{ consume_id(weak_0); consume_id(weak_1); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_weak_3(id input, long seed) {
    __weak id weak_0 = input;
    __weak id weak_1 = input;
    __weak id weak_2 = input;
    void (^value)(void) = ^{ consume_id(weak_0); consume_id(weak_1); consume_id(weak_2); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_weak_15(id input, long seed) {
    __weak id weak_0 = input;
    __weak id weak_1 = input;
    __weak id weak_2 = input;
    __weak id weak_3 = input;
    __weak id weak_4 = input;
    __weak id weak_5 = input;
    __weak id weak_6 = input;
    __weak id weak_7 = input;
    __weak id weak_8 = input;
    __weak id weak_9 = input;
    __weak id weak_10 = input;
    __weak id weak_11 = input;
    __weak id weak_12 = input;
    __weak id weak_13 = input;
    __weak id weak_14 = input;
    void (^value)(void) = ^{ consume_id(weak_0); consume_id(weak_1); consume_id(weak_2); consume_id(weak_3); consume_id(weak_4); consume_id(weak_5); consume_id(weak_6); consume_id(weak_7); consume_id(weak_8); consume_id(weak_9); consume_id(weak_10); consume_id(weak_11); consume_id(weak_12); consume_id(weak_13); consume_id(weak_14); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_weak_16(id input, long seed) {
    __weak id weak_0 = input;
    __weak id weak_1 = input;
    __weak id weak_2 = input;
    __weak id weak_3 = input;
    __weak id weak_4 = input;
    __weak id weak_5 = input;
    __weak id weak_6 = input;
    __weak id weak_7 = input;
    __weak id weak_8 = input;
    __weak id weak_9 = input;
    __weak id weak_10 = input;
    __weak id weak_11 = input;
    __weak id weak_12 = input;
    __weak id weak_13 = input;
    __weak id weak_14 = input;
    __weak id weak_15 = input;
    void (^value)(void) = ^{ consume_id(weak_0); consume_id(weak_1); consume_id(weak_2); consume_id(weak_3); consume_id(weak_4); consume_id(weak_5); consume_id(weak_6); consume_id(weak_7); consume_id(weak_8); consume_id(weak_9); consume_id(weak_10); consume_id(weak_11); consume_id(weak_12); consume_id(weak_13); consume_id(weak_14); consume_id(weak_15); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_unretained_1(id input, long seed) {
    __unsafe_unretained id unretained_0 = input;
    void (^value)(void) = ^{ consume_id(unretained_0); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_unretained_3(id input, long seed) {
    __unsafe_unretained id unretained_0 = input;
    __unsafe_unretained id unretained_1 = input;
    __unsafe_unretained id unretained_2 = input;
    void (^value)(void) = ^{ consume_id(unretained_0); consume_id(unretained_1); consume_id(unretained_2); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_unretained_16(id input, long seed) {
    __unsafe_unretained id unretained_0 = input;
    __unsafe_unretained id unretained_1 = input;
    __unsafe_unretained id unretained_2 = input;
    __unsafe_unretained id unretained_3 = input;
    __unsafe_unretained id unretained_4 = input;
    __unsafe_unretained id unretained_5 = input;
    __unsafe_unretained id unretained_6 = input;
    __unsafe_unretained id unretained_7 = input;
    __unsafe_unretained id unretained_8 = input;
    __unsafe_unretained id unretained_9 = input;
    __unsafe_unretained id unretained_10 = input;
    __unsafe_unretained id unretained_11 = input;
    __unsafe_unretained id unretained_12 = input;
    __unsafe_unretained id unretained_13 = input;
    __unsafe_unretained id unretained_14 = input;
    __unsafe_unretained id unretained_15 = input;
    void (^value)(void) = ^{ consume_id(unretained_0); consume_id(unretained_1); consume_id(unretained_2); consume_id(unretained_3); consume_id(unretained_4); consume_id(unretained_5); consume_id(unretained_6); consume_id(unretained_7); consume_id(unretained_8); consume_id(unretained_9); consume_id(unretained_10); consume_id(unretained_11); consume_id(unretained_12); consume_id(unretained_13); consume_id(unretained_14); consume_id(unretained_15); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_scalar_1(id input, long seed) {
    long scalar_0 = seed;
    void (^value)(void) = ^{ consume_int(scalar_0); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_scalar_2(id input, long seed) {
    long scalar_0 = seed;
    long scalar_1 = seed;
    void (^value)(void) = ^{ consume_int(scalar_0); consume_int(scalar_1); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_scalar_16(id input, long seed) {
    long scalar_0 = seed;
    long scalar_1 = seed;
    long scalar_2 = seed;
    long scalar_3 = seed;
    long scalar_4 = seed;
    long scalar_5 = seed;
    long scalar_6 = seed;
    long scalar_7 = seed;
    long scalar_8 = seed;
    long scalar_9 = seed;
    long scalar_10 = seed;
    long scalar_11 = seed;
    long scalar_12 = seed;
    long scalar_13 = seed;
    long scalar_14 = seed;
    long scalar_15 = seed;
    void (^value)(void) = ^{ consume_int(scalar_0); consume_int(scalar_1); consume_int(scalar_2); consume_int(scalar_3); consume_int(scalar_4); consume_int(scalar_5); consume_int(scalar_6); consume_int(scalar_7); consume_int(scalar_8); consume_int(scalar_9); consume_int(scalar_10); consume_int(scalar_11); consume_int(scalar_12); consume_int(scalar_13); consume_int(scalar_14); consume_int(scalar_15); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_pointer(id input, long seed) {
    void * pointer_0 = (void *)seed;
    void (^value)(void) = ^{ consume_ptr(pointer_0); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_byref_scalar(id input, long seed) {
    __block long byref_scalar_0 = seed;
    void (^value)(void) = ^{ consume_int(++byref_scalar_0); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_byref_scalar_2(id input, long seed) {
    __block long byref_scalar_0 = seed;
    __block long byref_scalar_1 = seed;
    void (^value)(void) = ^{ consume_int(++byref_scalar_0); consume_int(++byref_scalar_1); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_byref_strong(id input, long seed) {
    __block id byref_strong_0 = input;
    void (^value)(void) = ^{ consume_id(byref_strong_0); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_byref_weak(id input, long seed) {
    __block __weak id byref_weak_0 = input;
    void (^value)(void) = ^{ consume_id(byref_weak_0); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_block_capture(id input, long seed) {
    void (^captured_block_0)(void) = ^{ consume_int(seed); };
    void (^value)(void) = ^{ consume_block(captured_block_0); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_mixed_managed(id input, long seed) {
    id strong_0 = input;
    id strong_1 = input;
    __weak id weak_0 = input;
    __weak id weak_1 = input;
    __weak id weak_2 = input;
    __unsafe_unretained id unretained_0 = input;
    __unsafe_unretained id unretained_1 = input;
    void (^value)(void) = ^{ consume_id(strong_0); consume_id(strong_1); consume_id(weak_0); consume_id(weak_1); consume_id(weak_2); consume_id(unretained_0); consume_id(unretained_1); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_mixed_byref(id input, long seed) {
    id strong_0 = input;
    id strong_1 = input;
    __weak id weak_0 = input;
    __block long byref_scalar_0 = seed;
    __block long byref_scalar_1 = seed;
    long scalar_0 = seed;
    long scalar_1 = seed;
    void (^value)(void) = ^{ consume_id(strong_0); consume_id(strong_1); consume_id(weak_0); consume_int(++byref_scalar_0); consume_int(++byref_scalar_1); consume_int(scalar_0); consume_int(scalar_1); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_mixed_large(id input, long seed) {
    id strong_0 = input;
    id strong_1 = input;
    id strong_2 = input;
    id strong_3 = input;
    id strong_4 = input;
    id strong_5 = input;
    id strong_6 = input;
    id strong_7 = input;
    id strong_8 = input;
    id strong_9 = input;
    id strong_10 = input;
    id strong_11 = input;
    id strong_12 = input;
    id strong_13 = input;
    id strong_14 = input;
    id strong_15 = input;
    id strong_16 = input;
    __weak id weak_0 = input;
    __weak id weak_1 = input;
    __weak id weak_2 = input;
    __weak id weak_3 = input;
    __weak id weak_4 = input;
    __weak id weak_5 = input;
    __weak id weak_6 = input;
    __weak id weak_7 = input;
    __weak id weak_8 = input;
    __weak id weak_9 = input;
    __weak id weak_10 = input;
    __weak id weak_11 = input;
    __weak id weak_12 = input;
    __weak id weak_13 = input;
    __weak id weak_14 = input;
    __weak id weak_15 = input;
    __unsafe_unretained id unretained_0 = input;
    __block id byref_strong_0 = input;
    long scalar_0 = seed;
    long scalar_1 = seed;
    long scalar_2 = seed;
    void (^value)(void) = ^{ consume_id(strong_0); consume_id(strong_1); consume_id(strong_2); consume_id(strong_3); consume_id(strong_4); consume_id(strong_5); consume_id(strong_6); consume_id(strong_7); consume_id(strong_8); consume_id(strong_9); consume_id(strong_10); consume_id(strong_11); consume_id(strong_12); consume_id(strong_13); consume_id(strong_14); consume_id(strong_15); consume_id(strong_16); consume_id(weak_0); consume_id(weak_1); consume_id(weak_2); consume_id(weak_3); consume_id(weak_4); consume_id(weak_5); consume_id(weak_6); consume_id(weak_7); consume_id(weak_8); consume_id(weak_9); consume_id(weak_10); consume_id(weak_11); consume_id(weak_12); consume_id(weak_13); consume_id(weak_14); consume_id(weak_15); consume_id(unretained_0); consume_id(byref_strong_0); consume_int(scalar_0); consume_int(scalar_1); consume_int(scalar_2); };
    observe_block((__bridge void *)value);
}

__attribute__((noinline)) void fixture_all_forms(id input, long seed) {
    id strong_0 = input;
    __weak id weak_0 = input;
    __unsafe_unretained id unretained_0 = input;
    __block long byref_scalar_0 = seed;
    __block id byref_strong_0 = input;
    __block __weak id byref_weak_0 = input;
    long scalar_0 = seed;
    void * pointer_0 = (void *)seed;
    void (^captured_block_0)(void) = ^{ consume_int(seed); };
    void (^value)(void) = ^{ consume_id(strong_0); consume_id(weak_0); consume_id(unretained_0); consume_int(++byref_scalar_0); consume_id(byref_strong_0); consume_id(byref_weak_0); consume_int(scalar_0); consume_ptr(pointer_0); consume_block(captured_block_0); };
    observe_block((__bridge void *)value);
}
