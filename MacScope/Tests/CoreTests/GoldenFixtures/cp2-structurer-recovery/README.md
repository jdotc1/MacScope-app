# CP2 structurer recovery: Mac-profile vim renderings

These are the reviewed Mac-profile renderings of the two `/usr/bin/vim` (arm64e) functions that CP2's recovery path changes. The specimen is `fixtures/specimen/vim-arm64e` in the CP2 package. They were produced on 2026-10-13 with Xcode 27.2 and the bundled SDK call-signature pack.

| File | Options |
|---|---|
| `vim-<addr>.shipped.c` | `DecompilerOptions.default`: recovery off, the pre-CP2 text, gotos included |
| `vim-<addr>.recovery-on.c` | the three recovery switches on (`DecompilerOptions.recoveryOn` in the tests) |
| `vim-summary-macos.tsv` | all 20 sweep functions: gotos and lines with recovery off and on |

| Function | Gotos (off → on) | Lines | Named breaks / continues | Labelled scopes | Maximum indent |
|---|---|---|---|---|---|
| 0x1000cc360 | 77 → 0 | 898 → 1,332 | 120 / 4 | 72 | 8 → 60 spaces |
| 0x100143bd8 | 18 → 0 | 927 → 1,051 | 33 / 1 | 26 | 8 → 36 spaces |

The other 18 functions are byte-identical with recovery on or off.

Recovery ships off because these renderings read worse than the goto text. CP6 (cloud package) owns three prerequisites before recovery can be turned on:
- labels named by target address (today `cp2_exit_<block>`);
- empty `else { }` arms dropped;
- a readability admission rule. The proposal is: named transfers ≤ removed gotos, and added nesting ≤ 3 levels over the shipped text. Both functions here fail it.

When CP6 changes the rendering, `DecompilerStructuringVimGoldenTests.testMacProfileVimGoldens` shows the difference. Update these files by review, not by copying.
