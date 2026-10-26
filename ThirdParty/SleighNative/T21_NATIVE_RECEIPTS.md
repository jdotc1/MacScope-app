# T21: one-time native acceptance and installed resource selection

Authorized by CLX-D19-0046 and the compute addendum, section T21. This tranche
separates installed resource selection, actual vendored-lifter evidence, and
signed native-provider acceptance. It does not execute AArch64 instructions on
hardware or qualify their numerical semantics.

## Installed resource selection

`T21_INSTALLED_RESOURCE_RECEIPT.json` records one authorized read-only inspection
of `/Applications/MacScope.app`, Release commit
`63a3b991a8239a800535315a674373351bb49345`. The bridge source at that exact commit
constructs `NativeDecompilerPackage` beneath the XPC service's bundle resources
and requests `AARCH64:LE:64:AppleSilicon/default`. The attested global spec root
is passed to Ghidra, and the installed `AppleSilicon.ldefs` selects
`AARCH64_AppleSilicon.sla`.

The selected 518,760-byte file has SHA-256
`dfc99de03ffc783a787d47c6650b3f55a9ca3cc6da74d219976d9c8fe9dd82c5`.
It matches the existing patched-overlay receipt, including the #438 SME overlay,
and differs from the archive baseline
`5ac26c9f5e13554d2347c82632fd901c5d830054782a3cdc5078787e2bdda1ae`.
Only this selected file was hashed. No app launch, signing check, dependency-tree
rehash, or runtime file-open observation was performed. The conclusion is a
source-and-bundle path trace of the resource the provider is configured to load.

## Retained SME evidence

`RX18_VALIDATION.json` already records the actual patched vendored-lifter result
for the original 39 checked-in RX18 words: 3 `normal_path`, 35 `decode_only`, and
1 `still_fail_closed`, separately for LE, BE, and Apple. The remaining allocated
failure is `25231057` (`whilegt p7.b, x2, x3`). That receipt's compiled Apple
`.sla` identity matches the installed selected file above. This is existing
lifter evidence, reused without repeating the harness; it is not native-provider
or hardware acceptance.

The broader RX18 input contains 132 rows representing 120 unique allocated
words, plus 12 separate reserved guards. The RX17 native input contains 16 unique
words. Those two sets and the eight BFMLAL indexed words are disjoint. Repeated
rows would be deduplicated before any native dispatch, and reserved guards
remain separate from allocated decode coverage.

## Native admission attempt

The bounded captured Mach-O has two functions containing the eight existing
`ARM64BF16Tests.testBFMLALByElement` words (four BFMLALB, four BFMLALT), followed
by return scaffolding. It is input data for decompilation and is never launched.
The ordinary admission selector first attests the actual Debug host, then uses
the production analysis and native XPC providers. Its XCTest host selects
`Settings { EmptyView() }`, avoiding production windows.

The final run receipt records the actual outcome and any unexecuted obligations.
Provider success by itself would not prove the RX17 input's SSA-aware helper,
exception, accumulator, or numerical semantic obligations. Those remain distinct
from decode admission.

## Recorded result (2026-10-13)

`T21_NATIVE_VALIDATION.json` contains the exact word-to-function mapping,
configuration diagnostic paths, request outcomes, runtime identity, and timings.
All five test hosts attested. BFMLALB/T passed (two native function admissions,
eight indexed vectors). The subsequent four-configuration command failed with
exit 65 and was not rerun.

| Native input | Admitted functions | Rejected functions | Words in admitted functions | Words in rejected functions |
| --- | ---: | ---: | ---: | ---: |
| BFMLAL indexed | 2 | 0 | 8 | 0 |
| RX17 | 4 | 4 | 6 | 10 |
| RX18 allocated, excluding known WHILEGT gap | 4 | 3 | 33 | 86 |
| RX18 reserved guards | 0 | 12 | 0 | 12 |
| Known allocated WHILEGT gap | 0 | 1 | 0 | 1 |

RX17 admitted the BFDOT, SUDOT, USDOT and FCMLA groups; FJCVTZS, BFCVT,
FRINT32 and FRINT64 groups returned `terminalProviderResult` with native
observations `providerFailure(nativeFailure)`. RX18 admitted state/memory/zero,
LUTI2, MOVA and tile-add groups; the remaining original RX18 group, outer-product
group and tile-memory group returned that same failure. The 13 single-word
guards/gap were rejected as expected. The seven unexpected rejected groups
remain genuine open native-acceptance gaps; no failure was relabeled as passed.

There were 30 function requests containing 156 distinct feature/guard words: the
eight BFMLAL vectors plus 148 remaining words, each submitted once. **A rejected function group does not establish that every
contained instruction decoded or individually failed.** The original 39-word
native batch therefore supplies a rejected 38-word group and one independently
rejected WHILEGT input, not a new per-word native decode count. The exact
3/35/1 lifter count above remains separate evidence. Full prepared-vector
SSA/semantic acceptance remains incomplete even for admitted groups.

The first supported developer loop used three Xcode jobs and three shared
heavy-job slots: wait 8.7 s, preparation 66.9 s, build 397.1 s, test 10.0 s,
total 482.7 s. It exited 0 despite nonfatal compiler-cache diagnostics. The
remaining configurations reused those compiled products in one
`test-without-building` command under one shared heavy lock, taking 21.130 s.
Configurations ran serially because they use the same app-hosted native runtime
and retained products. No automatic retry/repetition was enabled.

Two command-line rejections preceded that remaining batch and executed no tests:
Xcode disallowed explicit `-test-iterations 1`, then refused the result bundle
created by the rejected first command. Both logs and the partial bundle remain
in `lane21-evidence`; removing the repetition option
and preserving the partial output enabled the single actual batch execution.
No native vector, source/dependency check, or installed-file hash was repeated.

The retained diagnostics are the next native-provider owner's investigation
input. T21 makes no production change and performs no corrective replay.
