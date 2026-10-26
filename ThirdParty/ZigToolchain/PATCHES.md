# Zig toolchain patch ledger

No Zig source or binary patch is applied by MacScope.

MacScope materializes the official Zig 0.15.2 Apple-Silicon archive, verifies
its frozen SHA-256 before extraction, and uses it only as an explicit developer
build tool for the Ghostty VT artifact. Delete the caller-selected materialized
directory to roll back the toolchain.

Any future patch requires a new immutable upstream pin, a reproducible patch
series, updated license/transitive-notice review, and a separate qualification
record. Patched Zig binaries must never replace the checksum-pinned archive
silently.
