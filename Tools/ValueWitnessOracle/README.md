# Runtime value witness oracle

A standalone arm64 macOS command-line host, a static-receipt comparer, and a
first struct-layout calculator. These tools have no application target or CI
membership. The host targets macOS 15.0 and uses the installed toolchain.

## Files

- `main.swift`: command-line handling, child supervision, timeout and self-test.
- `ImageTypes.swift`: Mach-O image ranges, type descriptors, context paths and
  binary symbolic-reference strings.
- `RuntimeQueries.swift`: metadata resolution, field records and witness reads.
- `build.sh`, `run.sh`: compiler invocation and executable wrapper.
- `compare_static.py`: unslid metadata-address joins and optional named
  MemoryLayout comparisons.
- `layout_v0.py`: sequential struct field layout and runtime comparison.
- `tests/test_compare_static.py`, `tests/test_layout_v0.py` and
  `tests/fixtures/*.json`: fixed small examples.

## Build and run

Run from the checkout root, with an absolute output directory outside the
checkout:

```sh
OUT=/absolute/developer/output/build Tools/ValueWitnessOracle/build.sh
OUT=/absolute/developer/output/build Tools/ValueWitnessOracle/run.sh --self-test
OUT=/absolute/developer/output/build Tools/ValueWitnessOracle/run.sh \
  /absolute/path/to/image --fields --names /absolute/path/to/names.txt \
  --timeout 120 --out /absolute/developer/output/oracle.json
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
  -import-objc-header Tools/ValueWitnessOracle/ProcessIsolation.h \
  /absolute/developer/output/build/ProcessIsolation.o \
  Tools/ValueWitnessOracle/IsolatedQuery.swift \
  Tools/ValueWitnessOracle/tests/IsolationChecks.swift \
  -o /absolute/developer/output/isolation-checks
VWO_HOST=/absolute/developer/output/build/vwo \
VWO_ISOLATION_TEST_BINARY=/absolute/developer/output/isolation-checks \
  python3 -I -m unittest discover -s Tools/ValueWitnessOracle/tests
python3 Tools/ValueWitnessOracle/compare_static.py \
  oracle.json census.json --out compare.json --memorylayout memorylayout.json
python3 Tools/ValueWitnessOracle/layout_v0.py oracle.json --out engine.json
```

`--names` is optional, one prefix-free Swift mangled name per line. `--fields`
is optional. `--memorylayout` is optional. Missing census files produce a
pending result and exit successfully; differing joined witnesses exit nonzero.
The layout calculator records disagreements in its output without failing its
process. Rates are fractions. A zero computable denominator has a null engine
rate.

Every image loads with `RTLD_NOW | RTLD_LOCAL` in a new subprocess. The parent
terminates a timed-out child and reports crashes as failed queries. No image
entry point is invoked, but loader initialization and metadata accessors run
native code. Use the intended local fixture and research images. Dependencies
can be supplied through `DYLD_FRAMEWORK_PATH` when their existing build bundle
is available. The tool makes no system-setting changes.

## Runtime records

The JSON root has `status`, `image`, `types`, `unanswered` and `summary`.
`types` contains resolved nominal descriptors plus explicit `--names` queries.
Each row includes its runtime name, mangled name, kind, resolution `source`,
and `vwt`. Struct rows include `fields` with `--fields`. Field resolution uses
`_getTypeByMangledNameInContext` on original loaded bytes, retaining symbolic
references. Field rows carry `source: mangled` and their own witness values.
Generic descriptors remain in `unanswered` with `reason: generic`; their
fields are still inspected, closed fields queried, and dependent fields counted.
Dependent manglings contain `x`, or `q` followed by `d`, a digit or underscore,
excluding binary symbolic-reference payloads. This is the bounded detection
rule, not a complete Swift mangling interpreter.

Metadata, descriptor and field metadata addresses are emitted only within the
loaded image's mapped segments, after subtracting its slide. Other metadata
has `external: true` and no invented image address. The static join includes
only oracle rows with image-local `metadataVA`; it does not establish coverage
for external runtime allocations or field-only generic specializations.
Descriptor names follow the module/nominal path grammar; anonymous contexts
use their non-generic descriptor accessor. Runtime nil results remain explicit.

The witness ABI used here is 64-bit: metadata minus 8 contains the table
pointer; table offsets 64, 72, 80 and 84 hold size, stride, flags and extra
inhabitants. Alignment is `(flags & 255) + 1`. POD, bitwise-takable, enum-witness
and incomplete bits are decoded from the flags. `--self-test` checks the pinned
`Optional<String>` witness facts before image runs. Sample validation additionally
checks `t.V`, `Array<t.S>`, the `t.S`/`t.V` name source and descriptor accessor
relative-offset agreement with `nm` symbols.

## Layout model and limits

The calculator handles structs with complete resolved field records. It aligns
each field, advances by field size, takes the maximum alignment, rounds stride
up (minimum one), combines POD and bitwise-takable booleans, and takes the
maximum field extra-inhabitant count. It reports every metric difference and
the first differing metric. Enums, classes and tuples are unsupported as
layout roots; unresolved fields are excluded from the computable denominator.
An explicit external array query has no descriptor field records and is
unresolved by this calculator.

Empty structs use size zero, stride one and alignment one. Class-reference
fields contribute their pointer extra inhabitants; nested optionals consume
extra inhabitants. This initial model can disagree with compiler layouts;
real disagreements remain in receipts rather than modifying expectations.

## Recorded qualification

Results, fixture sources, binaries, compiler transcripts and per-image loader
outcomes live outside the checkout in the assigned receipt directory. Consult
its `SUMMARY.md` and `last-message.md` for exact counts and the local commit.
The standalone host builds cleanly with installed Swift 6.4.2 and the macOS
27.2 SDK. The sample fixture requires `-parse-as-library` for its `@main` type.
Ten Python unit tests passed. No application build, test, installation or GUI
qualification was performed. Static-reader and MemoryLayout comparison remain
pending when their independently produced receipts are absent.

The initial corpus observations and self-test are retained from the first host
build. A subsequent change inspects generic-descriptor fields without changing
non-generic resolution; its focused layouts observation counts the dependent
field. The existing dependency build bundle supplies its framework search directory;
that environment change resolves its initial missing-framework loader result.
Other initial corpus observations were reused without repeating runs. Corpus
measurements are report-only; expanded generic/corpus qualification is separate.

## Corpus run

Two scripts compare recorded runtime witnesses with the static census and with DWARF byte sizes. Use
Python 3 with `-I`; paths are arguments, nothing is written next to the inputs.

```sh
python3 -I Tools/ValueWitnessOracle/dwarf_sizes.py /absolute/path/Product.json.debug-info.txt --out /absolute/run-folder/receipts/dwarf/name.json
python3 -I Tools/ValueWitnessOracle/compare_three.py /absolute/run-folder --out /absolute/run-folder/receipts/compare
```

- `dwarf_sizes.py` streams dwarfdump text and writes one row per
  `DW_TAG_structure_type` with a Swift linkage name (`$s…D`) and a byte size:
  `mangled`, `byteSize`, `dieOffset`. Duplicate DIEs are kept.
- `compare_three.py` reads the run folder: census receipts are located through
  `census/<group>/inputs.txt` (group names containing `unstripped` are the
  symbol-aided pass) and written under `receipts/census/<group>/`. It writes
  `compare-<name>.json` per image, `crossbuild.json` and `summary-tables.md` in
  `--out`, and `scoreboard.csv` and `disagreements.csv` in its parent. A
  `conflicting duplicate` in the static comparer stops the run with status 2.

## Isolated queries and incomplete static tables

`--isolate` loads the image once in the supervised process, then forks a child
for each runtime type query, including field types and explicit names. Children
return JSON through a pipe; no child-allocated metadata pointers reach the
parent. A signal death records `reason: host-crash`, the query identity and
signal, then the next query proceeds. Pipe, fork and transport failures stop
the host. The image timeout terminates the process group, including any active
query child. Loader failures remain image-level failures. Isolation does not
make a failed query an answer or recover layouts that require that query.

The three-way comparer classifies joined census rows with `isIncomplete` as
`incomplete`, retaining the emitted template values in the per-row details.
`static_incomplete_joined_unstripped` and `static_incomplete_joined_stripped`
count these over all joined rows. Agreement is measured over joined rows minus
incomplete rows. `static_incomplete_stripped` still counts incomplete tables
across all static witnesses. Incomplete rows are excluded from disagreements.

A run record can cite an existing oracle receipt by its absolute `receipt`
path. Optional `census_run_dir` and `dwarf_run_dir` roots reference retained
census and DWARF receipts. This permits recomputation with a changed comparer
without copying receipts or re-running the oracle, census or DWARF extraction.
Each run retains its own `host_sha256`; mixed-host reports must cite both
identities and identify the freshly measured images.
