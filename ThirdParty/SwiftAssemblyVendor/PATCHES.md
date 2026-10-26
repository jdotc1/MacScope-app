# Local patches

MacScope applies no source patches to the reviewed swift-assembly closure.

`Scripts/dependencies/materialize_swift_assembly.py` copies the exact allowlisted upstream files
and verifies every byte against `ThirdParty/SwiftAssemblyVendor/SOURCE_IDENTITY.json`. Any future
source modification requires a separately reviewed patch record, updated checksums and tree
identity, and requalification of the assembler fallback boundary.
