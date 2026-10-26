# Ghostty VT source provenance

- Upstream project: `ghostty-org/ghostty`
- Canonical repository: `https://github.com/ghostty-org/ghostty`
- Upstream revision: `94d775fefc21f74d9cc85a46b34c4e1d85318fd0`
- Upstream version metadata: `1.3.2-dev`
- Upstream fingerprint: `0x64407a2a0b4147e5`
- Reviewed upstream archive SHA-256:
  `dcafd130a3bc64ccfc009876404b193cd495b0eb672833577529d9a75a625c76`
- Repository source-tree SHA-256 (upstream snapshot plus the recorded
  source-container `.gitattributes` metadata patch):
  `7e4ee3fccd169f96068fcaf5a93024651bed82ccb042b6e5262d2ffd4e8dd661`
- Closed Zig package-store SHA-256:
  `70147cac57344d68a8dd812b7dd85b1d0eae984da531064e424128f937105d0f`
- Required Zig version: `0.16.0`

The governed source and package store exclude Finder `.DS_Store` and
AppleDouble `._*` metadata; identity validation rejects either form.

The upstream source snapshot was copied byte-for-byte from MacScope's
previously accepted local materialization for that revision, then received the
repository-container metadata patches recorded in `PATCHES.md`. The source
identity excludes only `.git`, `.zig-cache`, `zig-out`, `zig-pkg`, and
`.DS_Store`; the package store has its own complete ordinary-file identity. Both
are verified by
`Scripts/dependencies/zig_toolchain_receipt.py` before and after every build.

The upstream MIT license is retained as both `LICENSE.txt` and
`Source/LICENSE`. The package-store snapshot retains its upstream license and
notice files in place; there are 49 files named `LICENSE*`, `COPYING*`, or
`NOTICE*` within the accepted closure. No implementation patch is applied; see
`PATCHES.md`.

To verify the committed inputs without building:

```sh
/usr/bin/python3 -B Scripts/dependencies/zig_toolchain_receipt.py \
  ghostty-source \
  --root ThirdParty/GhosttyVT/Source \
  --expected-sha256 7e4ee3fccd169f96068fcaf5a93024651bed82ccb042b6e5262d2ffd4e8dd661

/usr/bin/python3 -B Scripts/dependencies/zig_toolchain_receipt.py \
  package-store \
  --root ThirdParty/GhosttyVT/Source/zig-pkg \
  --expected-sha256 70147cac57344d68a8dd812b7dd85b1d0eae984da531064e424128f937105d0f
```
