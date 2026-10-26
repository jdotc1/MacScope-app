# Security triage v1 fixture

These small arm64 dylibs are defensive detection shapes, not exploits. `security_cases.c`
contains three positive and three safe functions for each of R1-R4. `xpc_peer_trust.m`
contains two risky and two mitigated `listener:shouldAcceptNewConnection:` implementations
for R5. `build.sh` builds each source at `-O1` and `-O2` for macOS 27.
Implicit SDK fortification is disabled for the C fixture so the unbounded-copy positives
remain direct sinks; the explicit `__builtin___memcpy_chk` safe twin remains fortified.
Allocation and fixed-argument format cases retain call results through an empty compiler
barrier so both optimization levels preserve a returning call instead of a tail branch.
The R1 constant and dominating-guard twins copy into a dedicated 16-byte data section,
giving the test harness an exact object range without inventing a stack extent.

The checked-in binaries are canonical test inputs. A rebuild may change `LC_UUID` and the
ad-hoc signature page hash because clang uses randomly named temporary object files.
