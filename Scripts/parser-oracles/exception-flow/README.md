# Exception metadata fixture

`exception_cases_O1.dylib` is a linked ARM64 Mach-O produced from the accompanying
C++ source with Clang 19.1.7 through Zig, targeting aarch64-macos.13.0 at O1.
`compiler-receipt.json` retains the original compiler outcome and input/output
identifiers with normalized paths. The binary was neither rebuilt nor executed
for this adoption. It is data consumed by `ExceptionFlowServiceTests`.

The native tests check four function/LSDA associations, CIE personality slots,
exact FDE offsets, action chains, reverse type lookups and 16 structural landing
pad candidates. Synthetic tests cover negative exception specifications because
the C++17 source does not produce them. This fixture is not an Apple Clang/Xcode
27 compiler receipt, Objective-C fixture, ARM64e fixture, or runtime catch test.
