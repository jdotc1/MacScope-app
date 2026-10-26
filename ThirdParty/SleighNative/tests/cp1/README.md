# CP1 p-code execution harness

This is a normal-path checkpoint, not a hardware emulator or a native-XPC acceptance test. `cp1_vm.py` subclasses the shipped RX17 byte-addressed p-code VM; `rx17_semantics.py` is the unchanged bundled harness copy. The repository's larger RX17/FRINT module is not replaced. No instruction word, fixture ID, expected state, or QEMU observation drives VM execution: the VM receives the actual raw SLEIGH p-code. `cp1_fixtures.py` initializes inputs and independently applies explicit expected-state directives for comparison. Unsupported userops stop execution; they never become zero or a no-op.

The canonical input is `sme-decoder-vectors.json`, unchanged, SHA256 `5919c4c14d09f3c9221563763b4df2bd7116e33a9eae902dbe1474b8b5742f9a`. Its 125 allocated forms have 842 semantic/context cases; 11 reserved cases add seven labels outside the allocated catalogue. Thus a result report has 132 family keys, not 132 allocated forms.

From this cp1 directory, with the CP1 frontend built:

```sh
python3 emulator/run_vectors.py \
  --fixture sme-decoder-vectors.json \
  --lifter "$CP1_SLEIGH_LIFT" \
  --sla "$REPO/ThirdParty/SleighNative/AARCH64/AARCH64_AppleSilicon.sla" \
  --report /tmp/cp1-vector-results.json
python3 emulator/run_vectors.py \
  --fixture sme-decoder-vectors.json \
  --lifter "$CP1_SLEIGH_LIFT" \
  --sla "$REPO/ThirdParty/SleighNative/AARCH64/AARCH64_AppleSilicon.sla" \
  --report /tmp/cp1-decode-only.json --decode-only
python3 -m unittest discover -s emulator -p 'test_*.py'
```

Repeat the vector command for `AARCH64.sla` and `AARCH64BE.sla`. `--form REGEX --require-normal` is a development test that turns unsupported normal cases into failures; do not use it to obscure the whole-corpus result. The final whole-corpus ledger is 492 PASS, 0 FAIL, 102 UNSUPPORTED, 259 GATE per variant. A process exit of zero means no unexpected FAIL, not full coverage. Access/feature/reserved/exception cases are lifted but **not executed** and are GATE, never PASS. The 50-class decode-only report uses PASS solely for recognized assembly followed by opaque p-code or explicit `unimpl`; it is not semantic credit.

The VM models full Z/P/PN/FFR aliases, maximum-size ZA rows, ZT0, SVCR, SVL, nonstreaming VL and FP configuration/status storage. It bounds varnode ranges and relative branches, exposes memory-access logging, and compares storage constrained by the fixture contract. It does not implement SME exception entry, dynamic hardware feature/access checks, predicated ZA memory semantics, fused outer products, or FP8 evaluation. FPMR field descriptions are retained as metadata, not silently packed or interpreted. Reserved FP8 formats are not collapsed to a deterministic NaN.

For the legacy RX17 suite, the tree argument must contain `Ghidra/Processors/AARCH64/data/languages/`. Use a copy or a symlink of the final owned resources at that location, then:

```sh
python3 emulator/rx17_semantics.py --tree "$SPEC_TREE" \
  --lifter "$CP1_SLEIGH_LIFT" --suite all --variant apple \
  --report /tmp/cp1-rx17-apple.json
```

The frontend is the included `sleigh_lift.cpp`, built against the vendored library. It is **not** the omitted upstream `package/bin/sleigh-lift`: its batch/metadata API is specific to these tests. LOAD/STORE space pointers are serialized as stable space indices with an explicit metadata map; p-code semantics and varnode sizes are not rewritten. See the accompanying handback’s `DESIGN.md` for the storage ABI and `FAMILY_COVERAGE.md` for exact scope; the repository ledger is `../../PATCHES.md`.
