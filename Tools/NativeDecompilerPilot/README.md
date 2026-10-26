# DCP-03B3 native libghidra effective-image pilot

This directory contains a developer-only, shadow-mode backend for one
caller-bounded AArch64 function. It proves a real native Ghidra decompiler API
boundary without changing MacScope's application, `LoadedBinary`, MacIR, or
default pseudocode path.

The pilot targets the exact `libghidra` 0.0.2 native wheel selected by
`Scripts/dependencies/materialize_libghidra_dcp03b3.sh`. It constructs a
deterministic thin Mach-O transport carrier from DCP-03B2's independently
verified **effective** memory view and calls only address-driven local APIs:

- `get_decompilation` for presentation-only native pseudocode;
- `get_function` for the native function record; and
- `list_instructions` for structured instruction records.

The result preserves raw provenance bytes, effective analysis bytes, hashes,
applied patch identities, and image-qualified source ranges for every accepted
instruction and function range. Relocation/fixup application remains the
MacScope-owned bounded DCP-03B2 model; libghidra is never allowed to reopen the
original Mach-O or establish a competing image/address authority.

Local-mode basic-block and CFG enumeration are not part of this contract.
Tokens, locals, recovered variables, recovered types, heritage, SSA,
MemorySSA, structured regions, structured calls, type-hint injection, MacIR2
import, and application/XPC integration are reported unavailable. Rendered
pseudocode is never reparsed to manufacture any of those records.

## Authority and trust boundary

The request remains authoritative for image identity, UUID, preferred address,
function extent, raw memory bytes, permissions, symbols, normalized
relocations/fixups, type hints, and budgets. DCP-03B2 derives the effective
analysis image before the native extension is imported. The carrier is only a
deterministic transport artifact; it is not a reconstructed application and
does not claim the original process entry point.

The child converts native mappings into closed MacScope-owned dataclasses. The
external supervisor then:

1. parses the original request with duplicate-key rejection;
2. imposes wall-clock, CPU, address-space, file-size, descriptor, output, and
   diagnostic bounds where the host supports them;
3. independently rebuilds the effective load image and deterministic carrier;
4. reconstructs the normalized result from the original request plus the
   accepted native DTOs;
5. validates all byte, range, hash, patch, count, identity, capability, and
   warning relationships; and
6. publishes canonical JSON atomically.

Native mnemonic, operand, disassembly, prototype, and pseudocode text remain
opaque upstream records. The verifier proves their bounded identity and source
binding, not independent semantic correctness.

## Dependency materialization

Materialization is explicit and network-capable. Ordinary bootstrap, Xcode
project generation, build, and test commands never invoke it:

```sh
./Scripts/dependencies/materialize_libghidra_dcp03b3.sh
```

The script requires CPython 3.13, selects only an approved host wheel, verifies
its exact SHA-256, extracts ordinary archive members through a fail-closed
manual extractor, writes canonical `MATERIALIZATION.json`, verifies the native
extension hash, loads the exact extension, and checks the local-service and
capability identities. The resulting `/libghidra-dcp03b3/` directory is ignored
and is not shipped.

## Dependency-free qualification

```sh
PYTHONPATH="Tools/DecompilerCoreProof:Tools/NativeDecompilerPilot:Scripts/tests:." \
  python3 -m unittest -v \
  Scripts.tests.test_native_decompiler_pilot \
  Scripts.tests.test_native_decompiler_pilot_supervisor
```

The checked-in `fixtures/conditional-call.contract-result.json` is a synthetic
contract fixture produced from MacScope-owned fake native DTOs. It is not
represented as output from a downloaded wheel.

## Explicit native execution

After materialization, execute the isolated child through the supervisor:

```sh
./Scripts/native-decompiler-pilot/run_dcp03b3_native_pilot.sh \
  --python ./libghidra-dcp03b3/bin/python3 \
  --materialization ./libghidra-dcp03b3/MATERIALIZATION.json \
  --input Tools/DecompilerCoreProof/fixtures/conditional-call.request.json \
  --output /tmp/macscope-dcp03b3-result.json
```

This remains a non-shipping historical pilot and is not the DCP-04 service
backend. DCP-03B5 later supplied the MacScope-owned direct C++ structured
provider, and DCP-04 hosts it behind a dedicated signed XPC shadow boundary.
No explicit promotion decision has been made: native results remain
developer-only, opt-in, non-authoritative, and outside persisted/default output.
