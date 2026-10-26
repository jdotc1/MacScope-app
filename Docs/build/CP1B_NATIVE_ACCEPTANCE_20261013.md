# CP1b focused native acceptance — 2026-10-13

Product source: `344f57034`, based on main `c5017731d` (#512). This is signed Debug native/XPC evidence, qualification-ineligible. No installed, GUI, Release or Save/reopen claim.

The four formerly refused maximum-row MOVA forms now pass ordinary production admission with the unchanged 1,048,576-byte request cap. The native codec additionally rejects any actual serialized reply exceeding that cap. All core operations/stores remain; only presentation token metadata may retain a genuine prefix with an explicit warning. All four C documents were complete.

| Word | Operations | Stores | Model v3 bound (bytes) | Typed result binary plist (bytes) | Token metadata warning |
|---|---:|---:|---:|---:|---|
| `c000ffef` | 857 | 256 | 1028890 | 464933 | native-pseudocode-token-metadata-truncated |
| `c040ffef` | 491 | 128 | 941788 | 438949 | none |
| `c080ffef` | 307 | 64 | 633757 | 294265 | none |
| `c0c0ffef` | 362 | 32 | 812514 | 382063 | none |

The table's binary-plist sizes are the typed result diagnostic encoding, not the complete wire reply. Eight focused native/Swift serialization probes separately checked actual complete replies, ASCII/Unicode text, source-address and integer sharing, UInt32 positions, floating types, all result families, matching size bounds and canonical byte round trips. The native/Swift variable-role and floating-type spelling mismatches found by those probes were corrected.

## Evidence and exclusions

- Four-word test: local evidence (not included), 1 selected XCTest / four functions, zero failures, 12.570 seconds total; execution itself 4.796 seconds. Jobs=3; serial configuration because it shares native XPC admission state. Diagnostic JSON: `macscope-ordinary-native-admission-8E00554A-AE5B-4794-98A6-B9992A883A2B/diagnostics.json`.
- Earlier 29 passing words: local evidence (not included). Reused, never repeated. This is split evidence, not a new 33-word run on the final head.
- New floating-type probes: local evidence (not included); eight native replies and eight Swift checks passed. The preceding probe failures and corrected runs remain separately named.
- Three changed SLAs: `compile-results.json`, three workers, 38.057 seconds; unchanged compiler/package/upstream receipts reused. Resource cache, identity helper and guard-negative checks retain their earlier focused receipts; no repeats.
- Real app and worker compilation/linking completed for the corrected source. `v3-compile-fix.log` retains the successful c3d5961eb build-for-testing. `v3-float-parity-resume.log` and `v3-interrupted-compile-resume.log` retain the later corrected compilation/linking and successful native golden. The resumed build consumed the golden without replay. Its Xcode wrapper exited 65 at Debug receipt publication after builtin-copy changed embedded metadata; this is not relabeled a successful Xcode build. The existing external host-publication route then copied the signed worker from the retained verified source, published current ineligible Debug provenance and signed the changed app. `native4-v3-runner.log` records successful publication and native execution. The retained test bundle's selected test code is unchanged from the successful build.
- Native golden receipt: `retained-v3-native-golden.json`; source/dependency verification was reused. No broad CoreTests, corpus pass, confidence rerun, dependency rehash, GUI or installed execution.

