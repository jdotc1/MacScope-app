# libghidra DCP-03B3 pilot patch record

No upstream source or wheel file is modified by DCP-03B3.

The explicit materializer verifies the exact v0.0.2 release wheel and extracts it
unchanged into an ignored developer environment. MacScope loads the wheel's
native extension through a MacScope-owned adapter and never copies libghidra
Python model types into repository source.

Rollback: remove the `libghidra-dcp03b3` manifest entry, the explicit
materializer, `Tools/NativeDecompilerPilot`, and the DCP-03B3 scripts/tests/docs.
The existing DCP-03B2 effective-load-image SLEIGH proof and current Swift decompiler remain unchanged.
