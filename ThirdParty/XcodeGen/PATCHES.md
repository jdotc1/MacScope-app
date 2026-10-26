# Local patches

No XcodeGen source patch is applied. The source archive is the official
2.46.0 release at upstream commit
`8445e778451c7e44237b90281bde622d764b0084`, selected by the Homebrew formula that supplied the accepted
local executable. The executable is retained as an arm64 prebuilt developer
tool with its checksum and version bound in `MATERIALIZATION.json`.

To replace the materialization, obtain the official release archive and a
trusted arm64 build separately, verify them with
`Scripts/dependencies/materialize_xcodegen.py materialize`, and qualify the
result before changing the frozen checksums.
