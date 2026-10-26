# Native SLEIGH/Ghidra decompiler package record

This directory contains the complete verified macOS arm64 native package and
the app-required AArch64 processor-resource closure used by the private
`NativeDecompilerXPCService`. The accepted inputs are SLEIGH 12.1.2 revision
`bfd38a983b4aa53dd386365e1df5ed5499b7e2fb` and Ghidra revision
`c0f584bf229fffba61b36431f3ce30c0c3e4e682`.

The committed `package/` tree includes the native static archives, public
headers, tools, and complete processor specifications from the accepted
upstream release package. `Scripts/dependencies/verify_vendored_sleigh_native.py`
verifies it offline and rejects links while binding the complete tree digest,
file count, byte count, and critical member digests in `MATERIALIZATION.json`.
No external package root is required as a source input.

`Source/` contains the exact repository-owned upstream source closure and its
component-local provenance, license, notice, exclusion, patch, and immutable
identity records. `Scripts/dependencies/build_vendored_sleigh_native_source.sh`
is the offline source-build producer: it verifies the tracked source, builds
only below a caller-supplied absolute external work root, and qualifies the
resulting arm64 package against this governed seam. Ordinary
`Scripts/bootstrap.sh` invokes this producer when no explicit diagnostic or
rollback materialization override is supplied. `Scripts/test.sh` instead
publishes the verified repository `package/` closure beneath its per-worktree
external DerivedData dependency root before bootstrap. Neither path requires
`MACSCOPE_SLEIGH_MATERIALIZATION_ROOT`, downloads source, or writes generated
products into the repository.

Canonical qualification source-builds or reuses this same repository-owned
closure through content-addressed cache entries and run-owned views below its
absolute external `--work-root`. An explicitly supplied
`MACSCOPE_SLEIGH_MATERIALIZATION_ROOT` remains a diagnostic/rollback override,
not an ordinary prerequisite, and is reverified before consumption. Source or
tool acquisition, if deliberately required by a separate workflow, must remain
an explicit pinned/checksummed materializer operation; it is never part of
ordinary bootstrap, test, or qualification.

The signed embedded `NativeDecompilerXPCService` is the only app-bundle target
permitted to link the native archives or load these processor resources.
`MacScopeApp` must not load either directly. Staging must preserve and reverify
the complete materialization contract before signing and again before native
runtime startup. The native service is default-on only for the private product;
public distribution remains blocked by its separate review.

`AARCH64/` is a byte-for-byte repository-owned copy of the complete 25-file
AArch64 processor-resource subset from the same accepted package. It is not a
recreated specification. `Scripts/dependencies/internalize_sleigh_aarch64_resources.py`
copies those files offline into an explicitly supplied external work root and
writes `MATERIALIZATION.json` there. The script refuses repository destinations,
pre-existing destinations, links, and any closure whose count or digest does
not match the pin. This resource staging path does not grant `MacScopeApp`
native-engine authority.
