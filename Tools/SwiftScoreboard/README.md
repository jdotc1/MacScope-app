# Swift binary scoreboard

This instrument compares MacScope's function starts, extents and display names on
stripped executables with symbol and DWARF information from their unstripped twins.
It measures discovery and naming; it does not measure decompilation correctness.
The application and corpus are inputs. No product source or corpus files are changed.

## Ground truth and counting

Only addresses within the driver's `__text` section participate. The reference set
contains each `T` or `t` symbol address and each DWARF function `low_pc` in that
section. All symbol aliases at a reference address supply acceptable names. Each
address counts once within a measure or class, even when it has several aliases.
An address may belong to several classes, so class totals can exceed the number
of unique reference addresses. A DWARF-only start has no acceptable symbol spelling
unless an nm alias exists at that address; its original DWARF name remains available
in diagnostics.

Expected Swift spellings come from one installed `xcrun swift-demangle --compact`
batch per binary, including app names. Swift prefixes `_$s`, `$s`, `_$S`, `$S`,
`_T0` and `_$e` use the demangled spelling; other names lose one leading underscore.
Both expected aliases and app names use this normalization for `name_exact` and
`name_wrong`. Existing cached spellings are reused; only previously unseen names
join a supplemental batch. A dedicated input writer runs while output is drained;
each demangle process has a 120-second deadline. Timeout or incomplete output
fails scoring without publishing partial spellings. `name_raw_exact` compares the original app name with
raw twin aliases at the same address without normalization.
A reference extent uses DWARF `high_pc` when an alignment `low_pc` exists;
an nm-only start uses the next reference start or the section end. Missing or
conflicting DWARF `high_pc` values are scoring errors. DWARF extents and the
next-start bound are distinct comparators.

Generated names use the application's rule: empty names, `_entry`, `__text`, or
`sub_`, `loc_`, `unk_`, `off_`, `nullsub_` followed by hexadecimal digits, with an
optional `0x` or `0X`. Other supplied names count as given even if they are wrong.

| Measure | Numerator | Denominator |
|---|---|---|
| `fn_start_recall` | App starts also in the reference set | Reference starts |
| `fn_start_precision` | App starts also in the reference set | App starts |
| `fn_extent_exact` | Matched starts with the expected end | Matched starts |
| `fn_extent_within` | Matched starts ending at or before the next reference start | Matched starts |
| `name_given` | Matched starts with a non-generated app name | Matched starts |
| `name_exact` | Matched starts whose normalized app name equals any expected alias | Matched starts |
| `name_raw_exact` | Matched starts whose raw app name equals a raw twin alias | Matched starts |
| `name_wrong` | Matched starts with a normalized given name unequal to every expected alias | Matched starts |
| `class_census` | Reference starts in the class | Reference starts |
| `unreached_<class>` | Reference class starts absent from the app | Reference class starts |

Recall and exact-name measures are also reported per class. Receipts retain integer
numerators and denominators; only the Markdown summary formats percentages.
Empty denominators have no measured percentage. Extra starts include the nearest
reference start and whether the address falls within a reference extent or a gap.
Wrong names and control misses are retained in full. Unreached lists show at most
500 addresses per class in JSON and all addresses in the companion text file.

## Classes

`classify.py` implements independent demangled-form and mangled-suffix classifiers.
The demangled classifier applies the following rules in order after peeling merged
and specialization prefixes. Synthetic cases exercise both classifiers. These cases do not cover every
Swift mangling grammar production.

| Class | Demangled form or non-Swift stem |
|---|---|
| `metadataAccessor` | `type metadata accessor for` |
| `metadataInstantiation` | `type metadata instantiation function for` |
| `metadataCompletion` | `type metadata completion function for` |
| `valueWitness` | A recognized operation followed by `value witness for` |
| `protocolWitness` | `protocol witness for` |
| `witnessTableAccessor` | `lazy protocol witness table accessor for` |
| `partialApply` | `partial apply forwarder for` |
| `onceInit` | `one-time initialization function for` |
| `keyPath` | `key path getter for` or `key path setter for` |
| `objcThunk` | `@objc` |
| `outlined` | Outlined copy, consume, destroy, init-with-copy, assign-with-take, retain, release, or bridged method |
| `asyncPartial` | Numbered await-resume or suspend-resume partial function |
| `reabstraction` | `reabstraction thunk helper` |
| `closure` | Numbered closure before ` in ` |
| `varInit` | `variable initialization expression of` |
| `defaultArg` | `default argument N of` |
| `accessor` | getter, setter, modify, read, or unsafeMutableAddressor |
| `initDeinit` | allocating initializer, deallocating deinitializer, deinitializer, or initializer |
| `function` | Other demangled Swift name |
| `closureContextDestructor` | `___swift_closure_destructor` |
| `boxDestructor` | `___swift__destructor` |
| `existentialDestructor` | `___swift_exist` |
| `sharedHelper` | `___swift_memcpy`, `___swift_noop_void_return`, `___swift_instantiateConcrete`, `_get_witness_table` |
| `blockHelper` | `_block_copy_helper`, `_block_destroy_helper`, `___copy_helper_block`, `___destroy_helper_block` |
| `main` | `_main` |
| `objcMethod` | `-[` or `+[` |
| `other` | Every remaining name, retained for review |

Merged and specialised flags are address-level unions over aliases, and their
counts are reported within each class. They do not remove an address from its
class. Unclassified symbols remain visible instead of being silently discarded.

## Execution and receipts

Build the supplied application once with the repository's standard development
loop. Its executable is under `Build/Products/Debug/MacScope.app/Contents/MacOS/MacScope`.
Use the CLI help for required path arguments:

```sh
/usr/bin/python3 -I Tools/SwiftScoreboard/run_scoreboard.py --help
/usr/bin/python3 -I -m unittest discover -s Tools/SwiftScoreboard/tests
```

With `CORPUS`, `APP`, `OUTPUT`, `APP_SOURCE_SHA` and `PROGRESS_WATCH` set to the
chosen input and output locations, capture and score in one invocation:

```sh
/usr/bin/python3 -I Tools/SwiftScoreboard/run_scoreboard.py \
  --corpus "$CORPUS" --app "$APP" --output "$OUTPUT" \
  --git-sha "$APP_SOURCE_SHA" --progress-watch "$PROGRESS_WATCH"
```

`--only 'sample-app/O/SampleApp'` restricts capture and scoring to that exact
`repository/opt/product` identifier; repeat `--only` to select several products.
Controls require their own `control/repository/opt/product` identifier. The full
manifest count, control and corpus-path validation still runs before selection;
unknown identifiers fail, and `run.json` records the requested `only` list.

`--capture-only` retains application output without scoring. `--score-only`
scores retained captures without launching the application. After a scorer code
correction, `--score-only --rescore` explicitly regenerates scores from retained captures and
cached demangled spellings. Failed or interrupted application work is never
automatically retried.

Supply the corpus root, output directory, application executable, exact source
commit and the existing progress-watch script as arguments. Paths are never
compiled into the instrument. The manifest selects main products and supplies their paths, digests and UUIDs.
Discovery compares manifest digests with sorted `build*.json` receipts listing the
same product name and path; at least one matching receipt is required. Twin digests
must also agree when present in a matching receipt. The selected provenance receipt
is the first built match, or the first match if none has built status. Its status,
build success and failure reason are recorded alongside all matching receipt names.
Collection failure does not exclude a recorded main. Discovery does not read
`builds.csv`. Corpus digest checks compare metadata only; input files are never hashed.
It records the app digest, source commit, installed toolchain, exact subprocess
environment, selected products, elapsed times, exits and first stderr lines.

The application receives only `PATH`, `HOME` and `MACSCOPE_SSA_LIFTER=1` in its
environment. It executes one script containing `sections`, `functions`, `symbols`
and `exports`, in that order, with empty argument objects. Its stdout is retained
verbatim. Each process has an 1800-second deadline and a five-minute CPU-progress
watch; a stalled process is sampled and stopped. A failed capture remains a
failure record while the remaining binaries proceed. The driver never pages
around the application's output limit.

The same command sequence captures unstripped sample-app, sample-tool and math
controls. Their recall and exact-name misses are diagnostics without an acceptance
floor. The scripting surface returns parsed symbols or user overrides and never
invokes MacScope's demangler. Comparing that demangler with `swift-demangle` is
outside this instrument's scope and belongs to `Scripts/demangler-conformance`.
Every remaining name miss retains `app_name`, `app_name_normalized` and
`expected_spellings`; the receipt alone does not assign its cause.

The output directory contains `run.json`, per-binary raw captures and scoreboard
JSON, full unreached text, `scoreboard.csv` and `SUMMARY.md`. The summary has a
per-main table, an aggregate class table and a control table. Retained successful
captures and digest checks are reused when resuming; interruption must never
silently launch the same analysis a second time. Correcting scorer arithmetic
uses the existing captures rather than repeating application analysis.
