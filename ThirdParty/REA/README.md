# Selected REA algorithms embedded for MacScope

This attributed source fork is pinned to morluto/rea commit
`c29931ce81dc530d2623ec992714a70b1f3e50e4` (upstream package version 6.3.0).
`SOURCE_MANIFEST.json` identifies canonical Git blobs and SHA-256 hashes. Upstream
runtime files remain verbatim. `InterfaceBuilderAnalysis.ts` is reference-only:
its pure NIB normalization is attributed in the UI adapter; its I/O provider is
not bundled. `NibArchive.fixture.ts` is test source, not a runtime entry point.
The REA MIT license and each bundled dependency's license are retained.

`adapters/kernel.ts` exposes only `MacScopeREA.analyze(canonicalRequestJSON)` and
returns a real Promise of canonical response JSON. Three literal operations are
available: nativeApplication, uiResources, processComparison. The operation
schemas are in their corresponding adapters. Requests permit 16 MiB, responses
8 MiB, JSON depth 96 and 500,000 values. Unsafe integer tokens and unpaired
surrogates reject. Exact addresses must be strings. No path in a request grants
filesystem authority: the native adapter uses only its immutable inventory and
captured Mach-O facts, and requires inventoryComplete:true. Missing image facts
remain unsupported. Host receipt authentication precedes comparison admission;
caller-supplied commitment hashes do not authenticate a broker receipt.

The host supplies only __macscopeCheckpoint(), __macscopeSHA256(UTF8String), and
__macscopeSHA256Base64(canonicalBase64). Cancellation/deadline checks also belong
to the host before and after the Promise. Synchronous bounded upstream loops are
not independently preemptible; native view probes and adapter boundaries check
cancellation, and the isolated worker lifetime remains the hard containment.
There is no Node runtime, REA server, process runner, filesystem or network API in
the shipped resource. Portable tests use Node solely as a development JS engine;
they do not prove JavaScriptCore, XPC, installed UI, persistence, or accepted
scientific/behavioral equivalence in the native app.

Explicit regeneration uses external acquired tooling:

```
REA_TOOL_ROOT=/absolute/external/tool/root node Scripts/dependencies/rea_build.mjs
```

The exact npm lock pins development tooling separately from runtime sources.
Only the consumed dependency JavaScript and package metadata are retained under
`dependencies`; the generated manifest identifies each compiler-consumed file.
Ordinary builds run `python3 Scripts/dependencies/rea_verify.py` offline and copy
the checked-in generated resource. The verifier compares canonical tracked Git
blob bytes with both consumed-source receipts and checkout bytes, verifies the
upstream blob IDs, resource digest, implementation preimage, licenses, and Swift
identity. A Gitless qualification export must originate from canonical blobs;
its files are checked against the same hashes. Regeneration is never implicit.
