# Tier 2j old-writer packages (pre-T27)

Genuine `.mscope` packages written by the installed **Tier 2j Release** build. They are the evidence that
T27 (reconstruction replay; design-review correction 10) needs to prove two things:
- **New reader, old package:** T27 code opens packages written before T27.
- **Old reader, new package:** packages saved by T27 code with no active replay records still match what this
  build wrote.

The installed app wrote the original packages. In this public copy, only the descriptive
host paths in the two manifests were replaced with neutral fixture paths. Embedded attachment
paths and data are retained; historical manifest hashes below describe the originals, not
the sanitized manifests. No hashes or runtime checks were rerun for this edit.

## Writer
- App: `/Applications/MacScope.app`, signed Release, `git_head_commit` **8c91f2134751545beb1ff07c78e8ab55b6886d82**
  (Tier 2j, installed 2026-10-13 ~02:00 EDT). Its build provenance receipt is copied here as `tier2j-app-provenance.json`
  (sha256 `4b10d65d55109a957b1f09ea5a41cd49acbd0b1dee01547ce1c1c48635ea35c0`).
- Mode: headless `--run-script` (no window, no GUI), 2026-10-13 03:14 EDT, by the MacScope build lead. No other
  MacScope process was running.
- Input binary: `MacScope/Tests/CoreTests/GoldenFixtures/reconstruction-c-sample/original-arm64`
  (33,656 B, sha256 `e4aaf1e887ae299011a9b1611a29aebd5bd48054c1d0c6d7145230dd89263ff0`). Each package embeds it as
  an attachment.

## Commands
```
APP=/Applications/MacScope.app/Contents/MacOS/MacScope
BIN=MacScope/Tests/CoreTests/GoldenFixtures/reconstruction-c-sample/original-arm64

# plain-c-sample.mscope
"$APP" --run-script plain.json "$BIN"
#   plain.json = [{"command":"save-workspace","arguments":{"path":"<abs>/plain-c-sample.mscope"}}]

# annotated-c-sample.mscope
"$APP" --run-script annotated.json "$BIN"
#   annotated.json = [
#     {"command":"rename","arguments":{"address":"0x100000460","name":"saturating_increment"}},
#     {"command":"set-comment","arguments":{"address":"0x1000004a0","comment":"T27 old-writer fixture (Tier 2j 8c91f2134)"}},
#     {"command":"save-workspace","arguments":{"path":"<abs>/annotated-c-sample.mscope"}}]
```
Both runs exited 0 and reported `analyzerVersion 1, functionCount 2` (`_reconstructed` 0x100000460,
`_main` 0x1000004a0).

## Original files (historical sha256, bytes)
| File | sha256 | Bytes |
|---|---|---|
| `plain-c-sample.mscope/manifest.json` | `bac027ed672cdaee0e5572a1736809445d30a45292a8dc5ddceae7a82751b8bd` | 15,134 |
| `plain-c-sample.mscope/instructions.bin` | `04845c87774903b3fe55b6954001282fe087d5ed31c01f6f7cd4932e6d3225e8` | 6,857 |
| `plain-c-sample.mscope/attachments/b45c6f3e-c084-479a-b9fa-ddcc53223e06/original-arm64` | `e4aaf1e887ae299011a9b1611a29aebd5bd48054c1d0c6d7145230dd89263ff0` | 33,656 |
| `annotated-c-sample.mscope/manifest.json` | `fadb8ded8aa19bef699cefb4801d9a444ebd7075af2d854990a66294d2b14177` | 15,417 |
| `annotated-c-sample.mscope/instructions.bin` | `53bc870ea1b181b206ea149676835514f0bd37791833b2da9bff4927f7d9cd42` | 6,857 |
| `annotated-c-sample.mscope/attachments/b403dd00-93f9-4ee3-b2c7-84d683eee82f/original-arm64` | `e4aaf1e887ae299011a9b1611a29aebd5bd48054c1d0c6d7145230dd89263ff0` | 33,656 |
| `tier2j-app-provenance.json` | `4b10d65d55109a957b1f09ea5a41cd49acbd0b1dee01547ce1c1c48635ea35c0` | — |

## Limits
- **No job-bearing package.** 8c91f2134's scripting surface can't start or stage a reconstruction job:
  `reconstruction-jobs` is read-only. Any package with a job in it has to come from a later writer, or from a
  fixture built through the production persistence path in a test, labelled as such.
- Each binary is embedded as an attachment. The reader uses `attachmentRelativePath` within
  the package; sanitized `binaryPath` and `originalPath` fields are descriptive metadata.
- Do not regenerate these fixtures with a newer build. The public manifests retain the
  old-writer structure with the host-path sanitization documented above.
