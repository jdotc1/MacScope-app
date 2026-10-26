// Additive concrete-risk fixtures. No Apple SDK or system headers required.
extern "C" void observe_block(void *);
extern "C" void observe_noescape(void (^block)(void) __attribute__((noescape)));
extern "C" void consume_id(id);
extern "C" void consume_int(long);

struct MixedByref {
    __strong id strong_object;
    __weak id weak_object;
    long scalar;
};

extern "C" __attribute__((noinline)) void fixture_byref_extended(id input, long seed) {
    __block MixedByref value = {input, input, seed};
    void (^block)(void) = ^{
        consume_id(value.strong_object);
        consume_id(value.weak_object);
        consume_int(++value.scalar);
    };
    observe_block((__bridge void *)block);
}

extern "C" __attribute__((noinline)) void fixture_noescape(id input, long seed) {
    long value = seed;
    observe_noescape(^{ consume_int(value); });
}

struct NontrivialToken {
    long value;
    NontrivialToken(long v) : value(v) {}
    NontrivialToken(const NontrivialToken &other) : value(other.value) {
        consume_int(value);
    }
    ~NontrivialToken() { consume_int(value); }
};

extern "C" __attribute__((noinline)) void fixture_cpp_nontrivial(id input, long seed) {
    NontrivialToken value(seed);
    void (^block)(void) = ^{ consume_int(value.value); };
    observe_block((__bridge void *)block);
}
