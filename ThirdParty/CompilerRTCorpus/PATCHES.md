# compiler-rt corpus local patch record

No compiler-rt implementation source is vendored or patched. MacScope's offline
generator reads a checksum-pinned Xcode `libclang_rt.osx.a` as oracle input and
emits a conservative, MacScope-owned signature corpus plus provenance and
rejection records.

The generated corpus is not represented as an upstream source modification.
Any future copied or patched compiler-rt source must receive a separate pinned
component entry and a reproducible patch series before it can enter the tree.
