# BinExport schema patches

None. `binexport2.proto` and `LICENSE` are byte-identical to google/binexport
at the pinned revision in `VERSION` (git blob `7e1dc3b3`).

MacScope consumes the schema through
`Scripts/dependencies/generate_binexport2_schema.py`, which derives
`MacScope/Services/Export/BinExport2Schema.generated.swift` once per pin. The
generated table carries the schema's SHA-256; `--check` (CI governance) and
`BinExport2InteropTests` fail when the two drift.
