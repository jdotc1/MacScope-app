# XcodeGen 2.46.0

MacScope carries the exact official `yonaskolb/XcodeGen` 2.46.0 source
archive and the accepted arm64 executable used by the local toolchain. The
archive and executable identities are pinned in `MATERIALIZATION.json`.

Normal project generation can consume `bin/xcodegen` without relying on PATH.
The executable is a repository-owned developer tool, not an app dependency.
Run `python3 Scripts/dependencies/materialize_xcodegen.py verify` for an
offline check. Explicit replacement accepts only caller-supplied files whose
checksums, archive safety, Mach-O architecture, and `--version` output match
the frozen identity.

The official MIT license is retained in `LICENSE`.
