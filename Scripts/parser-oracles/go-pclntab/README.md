# Go pclntab function metadata (K2)

`fixture.go` is authored parser data, compiled once with:

```
go build -p=4 -trimpath -ldflags='-s -w' -o stripped.bin fixture.go
```

The fixture is never executed. `GoPclntabTests` checks compiler-recorded names,
source lines, discovery seeds, real-symbol precedence, and malformed-table refusal.
The Homebrew witness is selected explicitly with
`TEST_RUNNER_MACSCOPE_GO_GH_WITNESS=1`; it reports metadata seed/symbol counts and
names, not native decompilation or a completed real-binary function list.

The Go implementation adapts the user-supplied `code/go-pcln/pcln.go` prototype
from `MacScope_GitHub_Integration_Scout_2026-10-13.zip`, in the existing c-archive.
No additional module, dependency download, prototype/ABI inference or type
recovery is introduced. Go's standard `debug/gosym` performs the actual parsing.

Admission follows the reviewed I3 descriptor and source-map validators for
little-endian 64-bit Go 1.2/1.16/1.18/1.20 table formats. The worker still admits
only ARM64-aligned intervals. Nonzero header text bases must match `__TEXT,__text`.
A zero historical header is admitted only for Go 1.20-format tables with embedded
build info exactly `go1.27.1` or `go1.27.2`; provenance is explicit in JSON. I3
retains the official 1.27.1 linker evidence; the installed Go 1.27.2 linker source
(`src/cmd/link/internal/ld/pcln.go`) likewise writes the header word as unused.
Unknown, devel, older and unaudited future versions still refuse zero headers.

Preflight validates file/command extents, counts, table offsets, descriptor entry
agreement, advertised file names, CU references and bounded PC-value streams
before gosym. Invalid mappings refuse without partial rows. Limits: 64 MiB image,
16 MiB table/output, 50,000 functions/files, 4,096 bytes per name/path, and 32 MiB
source-stream decoding operations. Swift additionally bounds total strings to
12 MiB. Cooperative deadline checks allow two seconds.

Production worker calls also
arm a 3-second process-local watchdog: if the synchronous foreign call stalls,
the isolated analysis worker exits and the existing XPC invalidation path reports
failure. This watchdog is excluded from the app-hosted test bundle. Its timeout
retirement path has not been exercised. No hard deadline is claimed for direct
in-process test calls.

The worker checks for `__gopclntab` before invoking Go and passes captured selected
slice bytes only. It validates returned ranges against LoadedBinary text bounds,
adds function starts, and appends names only at addresses with no existing symbol.
Symbol kind is `Go pclntab`, rawLinkageName remains nil. Existing DWARF/workspace
name overrides retain their separate authority. Function range ends remain owned
by MacScope discovery; the bridge's source-file/line and exact end fields are not
currently persisted as DWARF records.

Acceptance: all four GoPclntabTests cases passed across the retained focused runs,
including the real gh case. It parsed 42,388 metadata rows and admitted 42,385
function seeds/names, excluding the three Go linker-data markers. Native K1
comparison passed separately in the same retained products. See
`../I3-COMPARISON.md` for adoption decisions, exact counts and name witnesses.

Uncovered: full gh function-list/native-pseudocode analysis and worker-watchdog
timeout execution. Neither was substituted with the metadata counts. No install
or running-app action was performed.
