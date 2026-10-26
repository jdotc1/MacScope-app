// Intentional minimal C++: cross-compiles without an Apple SDK or C++ headers.
extern "C" void may_throw(int);
extern "C" void record_cleanup(int);
struct Guard {
    int value;
    explicit Guard(int x) : value(x) {}
    ~Guard() { record_cleanup(value); }
};
extern "C" __attribute__((noinline)) int typed_catches(int n) {
    Guard a(n);
    try { may_throw(n); return 1; }
    catch (int x) { return x + 2; }
    catch (double) { return 3; }
    catch (...) { return 4; }
}
extern "C" __attribute__((noinline)) void cleanup_only(int n) {
    Guard a(n); may_throw(n);
}
extern "C" __attribute__((noinline)) int nested_handlers(int n) {
    Guard a(10);
    try {
        Guard b(20);
        try { may_throw(n); }
        catch (int) { may_throw(n + 1); return 2; }
        return 1;
    } catch (...) { return 3; }
}
extern "C" __attribute__((noinline)) int no_exception_metadata(int n) noexcept {
    return n * 3 + 1;
}
extern "C" __attribute__((noinline)) int rethrow_handler(int n) {
    try { may_throw(n); }
    catch (int) { throw; }
    return 1;
}
