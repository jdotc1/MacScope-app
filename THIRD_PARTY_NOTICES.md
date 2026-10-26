# MacScope third-party notices

This file records notices for public open-source components and source-derived
data currently used by MacScope. The machine-readable authority is
`THIRD_PARTY_COMPONENTS.yml`. MacScope is presently a private-development
project; this notice file does not approve public distribution or choose a
repository license.

## EntitlementDiff exact entitlement comparison
<!-- component:entitlements-comparison -->

MacScope adapts selected Core and Model Swift source from `jdotc1/EntitlementDiff`
at commit `a28a431895a65fe6d23494038ef67f62e80bd559`, together with the comparison
table and control presentation patterns, for read-only comparison of embedded
entitlement declarations in two already loaded image slots.

Copyright (c) 2026 EntitlementDiff contributors.

Licensed under the MIT License. The complete upstream license is retained at
`ThirdParty/EntitlementDiff/LICENSE`; each ported source file preserves its MIT
copyright and permission notice. Source origins, adaptations, and the offline
build and rollback procedure are recorded in `ThirdParty/EntitlementDiff/PATCHES.md`.
The source compiles directly into `MacScopeApp` and introduces no package-manager
edge, source acquisition, Security extraction, signature validation, or network
operation. MacScope remains the authority for image identity and selected-slice
bytes. Public distribution remains subject to the repository-level decision.

## MachOKit 0.52.2
<!-- component:machokit-v2 -->

MacScope includes exactly one reviewed form of `p-x9/MachOKit`: the pinned
0.52.2 direct-source Swift package and its local direct-source closure inside
the signed `AnalysisWorkerXPCService`. The four Swift packages are licensed
under the MIT License.

Copyright (c) 2023 p-x9 and MachOKit contributors.

The local closure also includes the MIT-licensed `p-x9/swift-fileio`,
`p-x9/swift-fileio-extra`, and `p-x9/swift-binary-parse-support` sources at
the immutable identities recorded in `THIRD_PARTY_COMPONENTS.yml`. Their
complete upstream MIT license texts are retained under `ThirdParty/MachOKit/`.

The compiled `MachOKitC` target also carries source-level obligations that the
upstream top-level MIT file does not enumerate. Nine bundled Apple-origin
headers identify Apple Original Code under the Apple Public Source License
2.0. `nlist.h` and `stab.h` retain the original four-clause University of
California BSD terms; `reloc.h` retains Christopher G. Demetriou's three-clause
BSD terms; and `machine.h` plus `vm_prot.h` retain the Carnegie Mellon Mach
permission and disclaimer. The latter two files also carry Apple's exact
OSReference license header, including its operating-system-license restriction.
The complete APSL 2.0 text, the exact BSD and CMU license blocks, and the exact
Apple OSReference notice are indexed in `THIRD_PARTY_COMPONENTS.yml` and stored
under `ThirdParty/MachOKit/`.

MacScope does not modify implementation source. The reviewed local package
manifest adaptations are described in `ThirdParty/MachOKit/PATCHES.md` and
cannot introduce a remote package, binary target, or XCFramework. Normal
build, test, signing, and application paths never acquire this dependency.
The exact read-only direct-source closure is committed below
`ThirdParty/MachOKit/materialization`; its complete tree SHA-256 is
`e6796548485d32a183c3e1641989d637f5f6344c9e5af5a9cfbb83f549007950`
and its compiled source-identity marker binds
`b2f928cfc635b3a539129d1dbd50464c9d218c4a815553bc4b710ac813a790ea`.
Public distribution remains blocked pending a distribution-specific review of
these retained APSL, BSD, CMU, and OSReference obligations.

## swift-assembly selected source closure
<!-- component:swift-assembly-vendor -->

MacScope includes the 15-file direct-source ARM64/Core closure from
`swiftbin/swift-assembly` at commit
`b6798dbd0081ec989d25b5a0676ab8cbd36bd9b1`, under the MIT License.

Copyright (c) 2026 swiftbin and swift-assembly contributors.

The full upstream license and the frozen source-identity receipt are retained
under `ThirdParty/SwiftAssemblyVendor/`. MacScope does not include the upstream
package manifest, examples, tests, generated products, Git metadata, a binary
product, an XCFramework, or a package-manager edge. No upstream source patch is
applied; the component-local patch ledger records that fact. Normal builds do
not download or resolve this source.

## Ghostty libghostty-vt
<!-- component:ghostty-vt -->

MacScope builds and links the `libghostty-vt` terminal-state engine from the
pinned, repository-owned Ghostty source snapshot and closed Zig package store
recorded in `THIRD_PARTY_COMPONENTS.yml`,
`Scripts/ghostty-vt-source.contract`, and `ThirdParty/GhosttyVT/PROVENANCE.md`.

Copyright (c) 2024 Mitchell Hashimoto and Ghostty contributors.
Licensed under the MIT License. The complete license text is stored at
`ThirdParty/GhosttyVT/LICENSE.txt`.

The complete reviewed source snapshot is committed at
`ThirdParty/GhosttyVT/Source`; its repository-container identity is
`7e4ee3fccd169f96068fcaf5a93024651bed82ccb042b6e5262d2ffd4e8dd661`.
The source-local closed package-store identity is
`70147cac57344d68a8dd812b7dd85b1d0eae984da531064e424128f937105d0f`.
Normal builds verify these repository inputs without network access and write
the generated arm64 macOS dylib, C headers, module map, SDK overlay, caches,
and governed manifest only into the caller's explicit external work root.
MacScope explicitly disables XCFramework emission and consumes no Ghostty
application/windowing, updater, networking, iOS, Simulator, or universal-static
product.

## GhosttyKit host-fed external-I/O surface
<!-- component:ghostty-surface -->

MacScope carries a checksum-pinned patch series over Ghostty
`f64f4aca2c29b554d111b36c3d946a9bddd159ff` for the private GST-01 full
terminal surface. The patch adds a bounded host-fed external-I/O backend and
size-prefixed C ABI v1. Ghostty does not launch, own, resize, signal, or wait
for the host shell process or its PTY through this backend.

Copyright (c) 2024 Mitchell Hashimoto and Ghostty contributors.
Licensed under the MIT License. The complete license text, patch ledger,
semantic ABI contract, baseline identity, patched-tree identity, and rollback
procedure are stored under `ThirdParty/GhosttySurface/`.

The closed dependency store contains `libxev` at upstream revision
`9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf`, with a checksum-pinned local
network-capability patch. Copyright (c) 2023 Mitchell Hashimoto; licensed
under the MIT License. Its complete license text is stored at
`ThirdParty/GhosttySurface/libxev-LICENSE.txt`.

The patched source and closed Zig package store are repository-owned. Generated
build snapshots, caches, and the GhosttyKit framework remain in an explicit
external work root and are not committed. Public distribution remains blocked
by the repository-level distribution and transitive-notice review. The
frozen private framework build disables Ghostty's Sentry/Breakpad crash-reporting
dependency and emits no Ghostty application, updater, executable, tests,
documentation, terminfo, termcap, themes, or web data.
It also disables the root Zig networking capability and every direct libxev
socket entry point in the private external-I/O build. The artifact verifier
freezes the five unreachable POSIX imports still emitted by Zig 0.16.0's root
I/O vtable and rejects any expansion of that set.

## Zig build toolchain
<!-- component:zig-toolchain -->

The explicit Ghostty VT dependency materializer uses the official
Apple-Silicon Zig 0.16.0 archive whose SHA-256 is recorded in
`THIRD_PARTY_COMPONENTS.yml` and `Scripts/ghostty-vt-source.contract`.
Zig is licensed under the MIT License. The complete upstream 0.16.0 license
text is stored at `ThirdParty/Zig/zig-0.16.0/LICENSE` and retained in the
pre-vendoring governance record at `ThirdParty/ZigToolchain/LICENSE.txt`.

The exact Zig executable, library tree, and canonical receipt are
repository-owned developer-tool inputs under `ThirdParty/Zig/`. They are not
linked into MacScope or acquired by normal build/test commands. Derived output
is written only to the caller's explicit external work root.

## XcodeGen project generator
<!-- component:xcodegen-tool -->

MacScope carries the official XcodeGen 2.46.0 source archive from
`yonaskolb/XcodeGen` at commit
`8445e778451c7e44237b90281bde622d764b0084` and the accepted arm64 executable
used for local project generation. XcodeGen is licensed under the MIT License;
the complete upstream license text is retained at `ThirdParty/XcodeGen/LICENSE`.

The source archive SHA-256 is
`c83c7bd70255b0ddf4116dadce16bdf0e5939165b43a544e124de294ec84aa27`
and the arm64 executable SHA-256 is
`5b5d393779d405bbe78a2de8130f0bfaa4f90f7295cd3c8436d620b04aaee49a`.
Both are repository-owned developer-tool inputs. Ordinary project generation
uses the tracked executable without PATH, package-manager, or network
authority. XcodeGen is not linked or copied into MacScopeApp. The explicit
replacement tool accepts only caller-supplied files and performs no acquisition.

## LLVM compiler-rt signature source evidence
<!-- component:compiler-rt-signature-corpus -->

MacScope's function-signature corpus was generated from a checksum-pinned arm64
slice of Xcode's `libclang_rt.osx.a`. Upstream compiler-rt is part of the LLVM
Project and is distributed under the Apache License 2.0 with LLVM Exceptions,
including retained legacy notices. The complete license and notices used by
this project are stored at
`Scripts/function-signatures/LICENSE.compiler-rt.txt`.

The Xcode archive and extracted object files are input evidence only and are not
committed. The checked-in corpus, source-oracle fixtures, manifest, and
rejection ledger are MacScope-generated artifacts whose input checksums are
recorded under `Scripts/function-signatures/`.

## pypcode native SLEIGH proof
<!-- component:pypcode-dcp03-proof -->

MacScope's non-shipping DCP-03 developer proof may explicitly materialize
`pypcode` 4.0.0 to execute native Ghidra SLEIGH decoding and raw p-code lifting
for one caller-supplied AArch64 function. MacScope-owned code may then derive
exact-storage SSA, operand heritage, conservative single-partition MemorySSA,
canonical `xN`/`wN` and `sp`/`wsp` GPR SSA, 19-input/56-clobber base
Darwin AAPCS64 call semantics, and an authority-preserving effective-memory
view for a frozen AArch64 Mach-O relocation and normalized dyld-pointer subset.
These MacScope-owned layers do not constitute native Ghidra decompiler
heritage, complete architecture register SSA, complete Mach-O/dyld loading, or
full source decompilation.
The component is not linked into or distributed with MacScope, and normal
bootstrap/build/test paths do not acquire it.

The pypcode wrapper code is distributed under the BSD 2-Clause License. Its
bundled SLEIGH runtime and processor specifications originate from Ghidra and
are distributed under the Apache License 2.0 with the retained Ghidra NOTICE
and disclaimer. The native package also contains zlib 1.3.1 code under the zlib
License. Exact upstream records are stored under `ThirdParty/PyPcodeProof/`.

The pilot's exact Git revision, source-archive hash, selected macOS arm64 wheel
hash, Linux validation artifact hash, materialization boundary, and rollback
state are recorded in `THIRD_PARTY_COMPONENTS.yml`, the DCP-03A, DCP-03B0,
DCP-03B1, and DCP-03B2 specifications, and
`ThirdParty/PyPcodeProof/PATCHES.md`. Public
distribution remains blocked.

## libghidra effective-image native decompiler pilot
<!-- component:libghidra-dcp03b3-pilot -->

MacScope's non-shipping DCP-03B3 developer pilot may explicitly materialize
`libghidra` 0.0.2 to decompile one caller-supplied AArch64 function through its
native local backend. MacScope first derives DCP-03B2's bounded, fail-closed
effective memory from caller-owned raw bytes and relocation/fixup evidence. A
deterministic thin Mach-O transport carrier contains those effective bytes only;
raw bytes, effective bytes, patch identifiers, and image-qualified source ranges
remain explicit provenance in the result.

The accepted native records are limited to those populated by the pinned local
backend: rendered pseudocode, one function record, and contiguous address-driven
instruction records. Tokens, locals, native CFG records, heritage, SSA,
MemorySSA, recovered types, structured regions, and structured calls remain
unavailable and are not inferred by parsing rendered C. The pilot is not wired
into an app or XPC target and does not change MacScope's default decompiler.

The libghidra wrapper is distributed under the Mozilla Public License 2.0. The
embedded native Ghidra decompiler and processor resources retain the Apache
License 2.0, Ghidra NOTICE, and government disclaimer. The distributed native
resource set also carries zlib-licensed code. Exact license and notice records
are stored under `ThirdParty/LibGhidraPilot/`.

The exact revision, release version, approved macOS arm64 and Linux validation
wheel hashes, explicit materialization boundary, and rollback state are recorded
in `THIRD_PARTY_COMPONENTS.yml`, the DCP-03B3 specification and plan, and
`ThirdParty/LibGhidraPilot/PATCHES.md`. Public distribution remains blocked
pending MPL-2.0 source-form and complete transitive-notice review.

## Native SLEIGH and Ghidra decompiler developer package
<!-- component:sleigh-native-dcp03b4 -->

MacScope's DCP-03B4 qualification and DCP-03B5 direct structured-provider work
may explicitly materialize the lifting-bits/sleigh v12.1.2 standalone native
package. That package exposes the Apache-2.0 Ghidra SLEIGH and native
decompiler libraries, public C++ headers, CMake targets, and compiled processor
specifications without requiring the Ghidra Java user interface at runtime.

The approved macOS arm64 and Linux x86_64 release-archive hashes, exact upstream
revision, Ghidra source revision, materialization rules, and rollback state are
recorded in `THIRD_PARTY_COMPONENTS.yml` and `ThirdParty/SleighNative/`.
The complete verified macOS arm64 package is repository-owned at
`ThirdParty/SleighNative/package`; its 4,055-file, 338,010,000-byte closed-tree
SHA-256 is
`9cc94c918e6af5659a211330561a7fed7099a00fa3ea05c54698051827498460`.
The 25-file AArch64 processor-resource subset is also retained byte-for-byte at
`ThirdParty/SleighNative/AARCH64` with tree SHA-256
`5d4ed653137cd15a26413818b0e96debeebd691bc2a20a9614b7691521e86d4f`.
The offline verifier rejects links and binds critical archives, headers,
processor resources, file count, byte count, and complete tree identity.
Normal bootstrap, build, test, and Xcode generation perform no acquisition.

The lifting-bits/sleigh build project and the included Ghidra native decompiler
sources are distributed under the Apache License 2.0. The complete license,
Ghidra NOTICE, and government disclaimer retained for this qualification are
stored under `ThirdParty/SleighNative/`.

DCP-03B4 freezes the MacScope-owned structured-provider validation boundary.
DCP-03B5 added an explicit provider to
`macscope_native_decompiler_contract`; `macscope_sleigh_decomp_api_probe`
remains the separate compile/link/runtime probe. Both consumers require the
verified repository-owned materialization. The standalone contract/probe remain
outside all app and XPC targets and excluded from normal bootstrap/build/test
execution.
DCP-04 introduced the signed embedded
`NativeDecompilerXPCService` to statically link the governed native archives
and load a complete bundle-local copy of an already verified materialization.
That copy is staged and reverified before signing, sealed with the nested XPC,
and reverified before native startup. The app process does not load the native
engine. DCP-05 promotes this service to MacScope's default-on private product runtime:
validated native output is the default pseudocode and LM Studio read source, while
MacScope analysis remains available for comparison and fallback. Native output is
transient and cannot mutate persisted workspace authority. No rendered C is parsed to reconstruct semantics, and no
package execution is claimed on hosts where the package was not verified and
materialized. Public distribution remains blocked.

## Adding a component

A new component must not enter a normal build until all of the following exist:

1. an immutable pin and complete component entry in
   `THIRD_PARTY_COMPONENTS.yml`;
2. upstream license and notice files at the paths declared by the manifest;
3. a patch ledger, even when it states that no patches exist;
4. an explicit materialization path that is never invoked implicitly by normal
   bootstrap, build, or test commands;
5. architecture, security, deterministic-build, malformed-input, cancellation,
   rollback, and differential qualification evidence appropriate to its role;
6. a notice section containing `<!-- component:COMPONENT_ID -->`.

<!-- component:rea-selected -->
## REA selected algorithms

REA 6.3.0, morluto/rea commit `c29931ce81dc530d2623ec992714a70b1f3e50e4`, is used under the MIT license retained at `ThirdParty/REA/LICENSE`. The embedded worker resource includes the precisely pinned runtime closures of Zod 4.4.3, canonicalize 3.0.0, Buffer 6.0.3, base64-js 1.5.1 and ieee754 1.2.1; their licenses are retained under `ThirdParty/REA/licenses/`. Exact npm integrity and consumed file identities are recorded in `DEPENDENCIES.json`, `package-lock.json` and `generated/RESOURCE_MANIFEST.json`. The resource runs only in the signed analysis worker and grants no filesystem, process, or network authority.

## Parser engines (RX-03)

Linked into the analysis worker (and CoreTests) as cross-check engines, built offline from the
vendored sources below into the shared dependency cache. Not linked into the app process.

<!-- component:lief-parser-engine -->
### LIEF 1.0.0

`lief-project/LIEF` commit `d05b3499b6934137e917c009a4df0a9dc8cb11c5`, Apache License 2.0
(`ThirdParty/LIEF/LICENSE`). Bundled build closure, licenses under `ThirdParty/LIEF/licenses/`:
mbedtls / TF-PSA-Crypto (Apache-2.0 OR GPL-2.0-or-later), spdlog (MIT; includes fmt, MIT),
frozen (Apache-2.0), tl::expected (CC0-1.0), utfcpp (BSL-1.0) and tcb-span (BSL-1.0, Copyright
Tristan Brindle 2018; terms in its header).

<!-- component:pe-parse-parser-engine -->
### pe-parse 2.1.1

`trailofbits/pe-parse` commit `7888f1f8de2f6bc302c291a5b4519fad926c0133`. MIT License; Copyright
(c) 2013 Andrew Ruef (`ThirdParty/PEParse/LICENSE`).

<!-- component:binexport2-schema -->
### google/binexport BinExport2 schema

`binexport2.proto` from `google/binexport` commit `c4c5b5f1c2793b03e5adc6264f100ba597430a1b`
(git blob `7e1dc3b3`). Apache License 2.0; Copyright Google LLC (`ThirdParty/BinExport/LICENSE`).

<!-- component:go-macho-parser-engine -->
### go-macho 1.1.283 and go-dwarf 1.0.14

`blacktop/go-macho` commit `0b3c4a4cb4548a0d1284c1b5fc0de6f4422c0246` and `blacktop/go-dwarf`
commit `6368b8ca72705d7d99e8ab93317669b81bb0bbd6`. MIT License; Copyright (c) blacktop
(`ThirdParty/GoMachO/go-macho/LICENSE`, `ThirdParty/GoMachO/go-dwarf/LICENSE`).

<!-- component:corkami-pocs-pe-specimens -->
### corkami/pocs PE specimens

Four PE files from `corkami/pocs` commit `6d277c83efdceb6916ee8c6efe6ff0639cc6193f`
(`PE/bin/normal.exe`, `normal64.exe`, `tiny.exe`, `nosectionW7.exe`), Ange Albertini. The
repository has no license file; `PE/readme.txt`, retained unmodified at
`ThirdParty/CorkamiPocs/PE/readme.txt`, states "BSD Licence, 2009-2013" for the PE corpus.
The files are inert test inputs and are never executed.
