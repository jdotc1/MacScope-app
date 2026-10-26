# Offline macOS SDK call-signature pack

`generate_sdk_signature_pack.py` extracts external C FunctionDecls from a bounded,
listed macOS SDK header set with clang JSON and text ASTs. It does not open system
binaries or perform prevalence/corpus scans. The text AST supplies semantic format,
CF/NS ownership, and availability attributes absent from clang's JSON dump.

The format remains `macscope.call-signature-pack`, version 1. Existing `type` and
`returns` fields retain readable header spellings (floating typedefs become scalar
spellings, as before). Additive `sourceType`/`sourceReturns` preserve the original
cleaned spelling; `abiType`/`abiReturns` provide compiler-resolved scalar widths for
the catalog. Ownership, availability and source header paths are retained as
evidence, not interpreted as memory-management or deployment guarantees. Unnamed
parameters use explicitly positional `argN` labels.

## Current scope and measured result

macOS 27.2 SDK, Apple clang 21.0.0 (clang-2100.3.34.2), arm64 C ABI. The pre-existing
Objective-C dispatch family uses its documented x86_64 old-prototype extraction
mode to obtain the C dispatch prototypes; all other families target arm64.

| Family | Accepted functions |
|---|---:|
| libSystem C headers | 1,525 |
| pthread | 107 |
| dispatch | 91 |
| os_log / os_signpost | 17 |
| Objective-C runtime | 139 |
| CoreFoundation | 754 |
| Foundation C API | 91 |
| Security | 630 |
| IOKit C APIs | 301 |
| CoreGraphics | 609 |
| Metal C APIs | 7 |
| Total | 4,271 |

The pack is **2,251,092 bytes**, with **1,209 type spellings** and **573 rejected
declarations**. It grows from 1,722 to 4,271 functions (2.48x), not the requested
10x. The listed frameworks do not provide 17,220 safely representable external C
functions in these public umbrellas. Objective-C methods, inline helpers, aliases
and unsafe signatures are not counted to inflate coverage. Seven Metal entries
reflect its small C surface; most Metal APIs are Objective-C methods.

`SDKCallSignaturePack.json` is the bundled runtime artifact. The sibling
`sdk_signature_manifest.json` records SDK/compiler/target identity and SHA-256/size
for 1,071 unique dependency headers; `sdk_signature_rejections.json` records every
in-scope rejected declaration and reason. These provenance/diagnostic files are
not additional app resources.

Reject: by-value aggregates, vectors, complex and 128-bit values, unknown typedefs
or unfixed enum widths, conflicting redeclarations/symbol aliases, unavailable
functions, internal/inline helpers, and parameter sequences that exceed the
catalog's eight registers per integer/FP bank. Public umbrella selection is bounded,
not a claim to every header in each framework. No guessed aggregate ABI is emitted.
Existing hand-written seeds retain precedence over the generated pack.

## Generation and reuse

```sh
python3 Scripts/signatures/generate_sdk_signature_pack.py \
  --work-root t7-sdk.noindex
```

The first extraction records new header hashes, raw ASTs and compiler inputs in the
external work root. Overlapping families reuse recorded header hashes. Parser edits
reuse the retained ASTs and provenance; they do not reparse or rehash unchanged SDK
headers. Use a new explicitly chosen work root when intentionally changing SDK input
identity. Cached inputs are a generation record, not a renewed source verification.
`--check` requires retained ASTs and compares artifacts without reopening SDK headers.
There is no verification-bypass option. Do not run it as a routine duplicate check.

## Focused evidence

The Python suite uses synthetic AST/type fixtures plus the committed JSON and
manifest. It does not invoke SDK extraction. Tests cover deterministic ordering,
size/count/provenance closure, ambiguity rejection, integer/FP widths, annotations,
and retained-AST reuse. Run only changed or previously unrun selectors:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s Scripts/signatures/tests -v
Scripts/dev_loop.sh CoreTests/CallSignaturePackTests
```

The native class exercises strict legacy/new pack decoding, seed precedence,
source metadata, IOKit integer width, mixed CoreGraphics integer/FP registers, and
two synthetic decompiler call goldens for Security and CoreGraphics. It is headless
source-level evidence, not installed native decompiler or GUI acceptance.
