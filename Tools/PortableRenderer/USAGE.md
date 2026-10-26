# Portable production MacIR renderer

Prerequisites: Swift 6.4.1 Linux, system zlib headers/library, official swift-crypto 3.12.3 and swift-asn1 1.3.1. No reimplementation or extracted evaluator is used. The source list drives complete byte-identical staging copies of shipped files; only documented SDK/ABI overlays differ. No generated source symlinks are created. Source/staged SHA-256 identities and overlay descriptions are recorded for every selected file. Input trees are not modified.

Apply numbered patches in order when integrating locally. Local patch ancestry records the supplied snapshot honestly, not an invented original pin. The contract's tree-pin validation must use the supplied PIN-TREES.txt and complete REPO trees.

## One measurement command

Set these environment variables:

- SWIFT: retained compiler executable.
- PORTABLE_SWIFT_CRYPTO: unchanged official swift-crypto source directory (with the official swift-asn1 sibling).
- PORTABLE_BUILD_PATH: the retained external build directory. Do not clear it or replace it after failure.
- PORTABLE_BINARY: exact witness binary.
- PORTABLE_PIN: full admitted source-tree revision, used as provenance, not created as a Git commit.
- PORTABLE_METRIC: byte_identical_functions_vs_pinned_dump for the first calibration; byte_identical_functions_vs_pin_6467045e0_dump for the second.

Then run the retained harness against the explicit tree and reference dump:

    Tools/PortableRenderer/measure.sh <repo-dir> <dump-path> <out-dir>

The command uses its own harness directory and explicitly binds PORTABLE_REPO to the argument, overriding inherited values. The output directory must be absent or empty. It builds Debug in the retained build root, admits exact tree resources, executes production analysis/cache warming/export, and writes complete build/render receipts, source/resource provenance, rerender/pseudocode-all.txt, census/calibration.csv, census/mismatch-details.json, census/summary.json, payoff.csv, and predicted-diff/*.before.txt/*.after.txt. Prediction keys include the full pin plus name and start address, so neither duplicate symbols nor separate pins overwrite each other. The selected metric is recorded in each payoff row and summary.

Review every mismatch and write census/MISMATCHES.md per pin. H0 Amendment B requires 914/914 at BOTH pins; a lower score is not COMPLETE. The comparator records failures rather than hiding or pruning them. Its summary is a measurement, not a contract acceptance decision. Use both per-pin payoff inventories when constructing the final handback; preserve the metric names and pin-qualified prediction keys.

## Runtime resources

resources.json records the required exact SDK JSON identity. stage_resources.py reads only the supplied tree resource and copies those unchanged bytes beside the actual executable, the candidate location for Foundation Bundle.main on Linux. It does not reconstruct signatures or alter product loading. At runtime, main.swift requires the unchanged production Bundle.main lookup to resolve a resource whose bytes equal the selected tree file, and requires CallSignaturePack.bundled to pass the product's strict decoder. The render log records the actual lookup path, size and SHA-256. Failure stops before analysis/rendering. Resource placement is not considered proven until this actual runtime admission succeeds.

Before either calibration, reconcile census/RESOURCES.md against that pin's selected source closure and record every reached resource's supplied-tree identity. Missing tree/resource data prohibits partial rendering. First-pin sources staged from the old incomplete packet must not be mistaken for either admitted full tree.

## Calibration test

After the authorized build/resource admission step, use explicit paths:

    PORTABLE_REPO=<tree> PORTABLE_REFERENCE_DUMP=<dump> PORTABLE_BINARY=<binary> PORTABLE_BUILD_PATH=<retained-build> PORTABLE_CALIBRATION_OUT=<new-output-file> python3 Tools/PortableRenderer/Tests/CalibrationTests/test_calibration.py

Run once per distinct pin/resource configuration. The test uses the same production executable, checks the complete ordered 914-function identity inventory, and requires all 914 texts to match. It refuses to overwrite evidence. Do not rerun an accepted calibration for reassurance.

## Later feature measurements

Reuse accepted H0 evidence when source, binary, resource and environment identities match. Otherwise measure the distinct baseline once. Apply the feature patch series and use its baseline render as the comparison dump. stmt_multiset_sha is SHA-256 of newline-separated sorted trimmed nonempty lines, with one terminal newline. This harness's current built-in metrics measure byte identity only. Later item metrics must use their exact witness definitions, not classifier estimates or regex substitutes.

The launcher creates a private empty HOME/XDG_CONFIG_HOME, fixes UTF-8 locale, UTC and deterministic Swift hashing, and clears optional MACSCOPE tiling/diagnostic flags for source defaults. No product behavior is patched to force parity. All failures and previous diagnostic runs remain evidence.
