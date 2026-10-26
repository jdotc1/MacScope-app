# Blocks ABI fixtures

Source for the compiler-emitted byte vectors in `Tests/CoreTests/BlocksABITests.swift`.
The tests embed the bytes directly; these files are kept so the vectors can be regenerated
and extended. Nothing here is compiled into a target.

- `blocks_matrix.m`: one function per capture shape (global, strong/weak/unretained/byref
  word counts, mixed managed captures, non-object tails).
- `blocks_extended.mm`: a `__block` C++ aggregate with strong and weak members (EXTENDED byref
  layout), a `noescape` literal and a non-trivial C++ capture (HAS_CTOR).

Vectors in the tests came from upstream clang 20.1.2 at -O0 and -O2:

```
clang -target aarch64-macos-none -fblocks -fobjc-arc -fno-stack-protector -fno-builtin -g0 \
  -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables -O0 -c blocks_matrix.m
```

Apple clang from the Xcode 27 toolchain has not been checked against these vectors yet.

Reference for the encodings: libclosure-96 `Block_private.h` and `runtime.cpp`
(apple-oss-distributions/libclosure, commit 3668b0837f47be3cc1c404fb5e360f4ff178ca13, APSL 2.0;
referenced, not vendored).
