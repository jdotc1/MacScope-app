# Phased x86_64 native decompilation design

Date: 2026-10-16. Source references describe revision `8b6f1ac2d2df784725e97ae4dc8d3c26cce19bff`; line numbers may move as implementation proceeds. This design does not establish implementation or runtime acceptance. All proposed APIs, paths explicitly marked **new**, test selectors, profiles and estimates below are proposals.

## 1. Recommendation and boundaries

Add a second, closed target family to the existing arm64-hosted native worker: 64-bit, little-endian, user-space macOS Mach-O x86_64, initially the ordinary C/C++/Objective-C System V ABI. Use the already vendored `x86:LE:64:default` language with compiler ID `gcc`. Treat native Swift as a separate, explicitly selected ABI profile, not as an inference from the CPU or from a Swift-looking function name. Keep the application and worker arm64 executables. This feature analyzes Intel bytes; it neither executes them nor requires Rosetta.

This is more than changing one language string. The highest-risk work is the conjunction of immutable runtime identity, profile-specific readiness, variable-length instruction boundaries, and exact function-flow ownership. The existing package content makes the language acquisition cheap; it does not establish integration correctness.

Ship a narrow useful increment: ordinary Intel Mach-O functions, real instruction sizes, direct calls/tails, read-only globals and common switch tables, with truthful native failure and disassembly fallback. Do not add an x86 MacIR semantics backend just to make the fallback label look uniform. Do not expand into i386, Windows decompilation, x86 debugging, Intel-host builds, emulation, universal output binaries, arbitrary languages or user-installed SLEIGH specs.

The current contract expressly excludes x86 decompilation (`MacScope/PARITY_CONTRACT.md:181–188,225–226`) while including x86_64 static analysis (`:46–54,201–207`). This design proposes a narrow change to that decision; it does not establish runtime support. The first PR must state the narrow scope change; all other exclusions remain.

### Evidence conventions

Paths are relative to the repository root unless otherwise stated. The following aliases are exact directory expansions, used to keep citations readable:

- **B** = `Tools/NativeDecompilerBridge`
- **W** = `MacScope/Models/NativeDecompilerWire`
- **X** = `MacScope/NativeDecompilerXPCService`
- **S** = `ThirdParty/SleighNative`
- **L** = `ThirdParty/SleighNative/package/share/sleigh/specfiles/Ghidra/Processors/x86/data/languages`

A citation such as `B/src/GhidraRuntime.cpp:142–169` means that exact file under the expansion above. “Observed” means source inspected, not executed. “Proposed” means a design choice. “Unverified” means the inspected source does not establish it. Public sources are listed with direct links in §10; moving upstream branches are not substitutes for the vendored revision.

This design claims no build, test, dependency-verification, resource-compilation, package-hash or binary-execution evidence. Existing flow-failure reports remain background rather than independently reproduced findings; unrelated investigations remain out of scope.

## 2. Current hard-coded seams and exact changes

| Current source evidence | Consequence | Proposed change |
|---|---|---|
| `B/include/MacScopeNativeDecompiler/InputModel.hpp:199–223` defines only arm64/arm64e variants and a four-element context array. `B/src/InputModel.cpp:672–734` normalizes only CPU type `0x0100000c` and returns the AppleSilicon/default profile. | CPU admission and profile construction reject Intel before lifting. | Closed target registry; add x86_64 variant and named profile. Keep bounded context storage; four x86 context defaults fit, but do not imply all future profiles have four entries. |
| `W/NativeDecompilerWireTargetProfile.swift:9–11,34–103` mirrors those exact CPU/subtype and PAC settings. | Swift must agree byte-for-byte with C++ normalization. | Same closed CPU/subtype table, profile and canonical context order in both languages. Do not trust a caller-supplied language string independently. |
| `B/src/CanonicalRequest.cpp:23–28,484–491,824–843` and `W/NativeDecompilerWireCanonicalRequest.swift:221–242` hard-code the context-profile preimage. The request itself already binds target, slice digest and profile fields in Swift at `:55–102`. | A new target needs a different context digest; reusing the A64 digest would misrepresent authority. | Parameterize context preimage by a sealed registry entry. Preserve old A64 preimages unchanged. Add cross-language x86 golden preimage/digest; do not invent a digest in this design. |
| `B/src/Backend.cpp:56–61,128–132,184–187` accepts only the governed A64 language/compiler/profile/digest. `B/src/GhidraRuntime.cpp:121–130` repeats the language/compiler gate. | Loosening just one check is insufficient and unsafe. | Validate membership of an exact admitted tuple, never independent lists that allow mixed A64/x86 combinations. |
| `B/src/GhidraPackageAttestation.cpp:104–105,1253–1258,1347–1358` binds one AARCH64 processor root. `B/src/GhidraBuildIdentity.hpp.in:15–22` embeds a single processor root. `B/CMakeLists.txt:343–345` reads it. | Package metadata, build identity and runtime resource selection must move together. | Versioned multi-profile resource-root map, bound to the complete derived package identity (§5). |
| `B/src/GhidraRuntimeInternal.hpp:27–39` includes language/compiler in process identity; `B/src/GhidraRuntime.cpp:142–169` rejects any different later identity and starts the library once. | Constructing an x86 backend after an arm backend currently conflicts even if both use the same files. | Freeze a package plus closed profile-set identity once; issue separately validated per-profile leases/readiness within it (§6). Preserve the execution mutex and failure latch. |
| `B/src/GhidraArchitecture.cpp:23–28,103–151` sets/reads PAC context unconditionally. `B/src/GhidraArchitectureInternal.hpp:77,92` exposes a four-value profile. | x86 does not have those PAC context variables. | Dispatch hooks by registry entry, retaining exact default readback. A64 PAC tests remain A64-specific. |
| `B/src/GhidraProvider.cpp:174–185,5005–5058,5062–5078,5082–5104,5113–5139` constructs A64 readiness and requires PAC userops. | A package that loads x86 still cannot pass current readiness. | Profile-specific readiness request and assertions. x86 checks long-mode context, RIP/RSP, 64-bit byte-addressed RAM and selected prototype; no PAC requirement. |
| `X/Bridge/NativeDecompilerObjCBridge.mm:90–107` prepares one AppleSilicon/default backend. `X/NativeDecompilerServiceComposition.swift:108–132` starts only after preparation and shares that bridge. | XPC has no architecture-selecting preparation path. | Eagerly prepare the fixed supported profile set, route decoded/validated requests by profile ID to prepared providers, retain pre-listener readiness and bounded scheduling. |
| `X/Bridge/NativeDecompilerWireCodec.mm:1900–1937` renormalizes targets, serializes variant with an arm64/arm64e ternary and requires context agreement. | A new enum alone can accidentally label x86 as arm64e. | Exhaustive variant conversion and profile-derived context validation; reject unknown variants. |
| `B/src/InputModel.cpp:1041–1045` requires word alignment for schema-4 ranges; `W/NativeDecompilerWireCodec.swift:268–274` mirrors it. | Byte-aligned x86 sparse ranges fail validation. | Profile-specific alignment, A64=4, x86=1, with ordering, non-overlap, mapping and total-byte limits unchanged. |
| `B/src/GhidraProvider.cpp:292–304,993–1002` requires authored function names/signatures at four-byte-aligned addresses with at least four mapped bytes. | Legitimate unaligned Intel function starts are rejected. | Use the target minimum instruction size and alignment; retain read-only executable mapping and authored-input validation. |
| `B/src/GhidraProvider.cpp:1777–1787` requires a multiple-of-four code size and estimates instruction count as bytes/4. | Incorrect rejection and output preflight for Intel. | Charge actual decoded instructions incrementally before storing records (§7.5). |
| `B/src/GhidraProvider.cpp:5285–5310,5353–5442` iterates four-byte words, decodes A64 BL/B masks, installs tail overrides and marks a final BL callee no-return. | These scans cannot inspect x86 correctly. | Keep A64-specific behavior isolated; x86 uses length-aware decoded flow, never copied word scans or blanket last-call inference (§7.3). |
| `MacScope/Models/NativeDecompilerFailureCatalog.swift:5–16` offers “MacScope Analysis” across several failures. | There is **no literal arm64 hard-code here**; the relevant assumption is availability of useful fallback for the target. | Capability-aware fallback wording/actions, not a blind string replacement. For unverified x86 MacIR, offer disassembly/CFG and disclose native failure. |
| `MacScope/PARITY_CONTRACT.md:53–54,187–193,225–227`. | Product scope and native-first/fallback language need a truthful architecture qualification. | Update the contract, roadmap and user-facing capability reporting together. |

Do not “fix” arm64 host restrictions in `B/CMakeLists.txt:97–104` or the arm64 archive/platform identity in `B/src/GhidraPackageAttestation.cpp:92–98`. Those describe the executable that runs on this Mac, not the code it can decompile. The static engine can interpret x86 SLEIGH on an arm64 host.

## 3. Proposed sealed target and compatibility

### 3.1 Initial target profile

Proposed profile ID: `apple-x86_64-sysv-v1`.

- Container/product scope: 64-bit little-endian Mach-O user-space macOS; not all binaries with an Intel CPU type. The current target DTO has no OS/container field (`W/NativeDecompilerWireTargetProfile.swift:19–32`), so the app must gate this from its trusted loaded-image metadata before request construction. If the worker must independently enforce OS identity, introduce a new schema field and bind it canonically; do not pretend CPU type proves macOS.
- Raw CPU type: `0x01000007` (`CPU_TYPE_X86_64`). Initial accepted raw subtype: `0x00000003` (`X86_64_ALL`). Reject other capability bits rather than blindly mask them. Plan a separate exact-entry admission of `0x00000008` (`X86_64_H`) after one focused Haswell decode check; this is the same long-mode language, not an Intel host requirement. Constants are corroborated by LLVM's Mach-O header [P8].
- Normalized variant: `x86_64`. Retain raw subtype and recognized capability bits in the authority so future `x86_64h` support cannot alias a different selected slice.
- Pointer authentication ABI: absent. Non-none PAC effects on x86 results must be rejected rather than accepted merely because a userop spelling matches.
- Language ID: `x86:LE:64:default`; compiler ID: `gcc`; those exact values map to the actual vendored files (`L/x86.ldefs:84–106`). “gcc” is a SLEIGH ABI selection, not an assertion that GCC compiled the binary. Apple Clang ordinary C code belongs to this SysV baseline. Do not select `clangwindows` because the binary contains Clang producer metadata: that entry uses the Windows cspec (`L/x86.ldefs:94–98`).
- Ordered context values: `addrsize=2`, `opsize=1`, `rexprefix=0`, `longMode=1`, from `L/x86-64.pspec:10–16`. These are initial defaults, not permanent per-instruction prefix overrides. Verify the pspec's tracked `DF=0` separately (`:17–19`); it is a tracked register value, not a fifth PAC-style context bit.
- Address width 64, pointer width 8 bytes, little-endian, byte-addressed RAM; code alignment 1, instruction length 1–15. The vendored IA64 preprocessor symbol denotes the 64-bit x86 build here (`L/x86-64.slaspec:1–2`, `L/ia.sinc:3–14`), not Itanium support.
- Selected-slice SHA-256 and byte count remain mandatory, and are derived from the selected thin image, not the enclosing universal file. This design does not supply a new hash.

### 3.2 Wire version decision

Prefer an additive profile admission without changing the existing field shape: request v3 for one contiguous range, v4 for explicit sparse ranges. Those are the actual current constants (`W/NativeDecompilerWirePrimitives.swift:209–211`); C++ accepts only 3/4 (`B/src/InputModel.cpp:1024–1036`). Preserve the canonical stream version and old A64 bytes if the structure/order is unchanged. Old peers must reject the unknown profile; do not send x86 merely because a worker is “ready.” Bind dispatch to returned per-profile runtime identity.

The response envelope already has its own current schema constant of 4 (`W/NativeDecompilerWireResultModels.swift:650`), while the service's minimal failure encoder uses 3 (`X/NativeDecompilerServiceHost.swift:81–97`). Do not conflate request sparse-code v4, result schema and materialization schema. A new field or changed interpretation requiring old readers to behave differently needs an explicit version change on all participants, not a number reused opportunistically.

Profile selection is not ABI inference. Initially normalization may default a recognized x86 Mach-O to the C profile because that is the sole supported Intel ABI. Before Swift is enabled, introduce a bounded ABI choice from trusted function/project authority. The worker must validate that choice against the admitted profile, bind it to request and result identity, and reject arbitrary compiler IDs. A Mach-O can contain C, Objective-C, Swift and interop thunks; one image-wide “Swift present” flag cannot choose every function's convention.

## 4. Resource closure: actual files, not wishful reuse

### 4.1 Selected-language runtime dependency set

All of the following actual filenames were identified under **L**:

1. `x86.ldefs` (language discovery; selected entry at lines 84–106).
2. `x86-64.pspec` (RIP, long-mode context, DF tracking, register metadata).
3. `x86-64-gcc.cspec` (ordinary SysV prototype and data layout).
4. `x86-64.sla` (compiled processor language referenced at `x86.ldefs:89`). Its presence was inspected by directory metadata only; its contents, identity and runtime loadability were not revalidated.
5. For later Swift admission, additionally `x86-64-swift.cspec`, referenced at `x86.ldefs:98`.

Four files are the active **selected-profile** load dependency set, five for both compiler choices. This is not a claim that an unchanged `x86.ldefs` makes a universally self-contained four-file directory. It also advertises x86-16/x86-32/compat32, Windows and Go entries, manuals and external tool mappings (`L/x86.ldefs:4–82,94–105,107–119`). The exact standalone C++ loader's treatment of missing unselected references needs a focused readiness check, not an assumption.

Recommended first implementation: retain the existing governed package tree and add an explicit selected-profile dependency inventory plus x86 critical-member checks. Do not prune/rebuild the full vendor package to save a small amount of private-app space. The package is documented as containing complete processor specifications (`S/README.md:9–13`), but source inspection alone does not establish the installed layout. Inventory acceptance still binds the whole materialized tree, not only these four files.

If a genuinely minimal installed closure later matters, produce a separately identified, filtered `MacScope-x86-64.ldefs` (**new**) with one x86-64 language and only the admitted compiler(s), plus the same pspec/cspec/sla bytes. Remove unused manual/tool references in that derivative. Never register the same language ID from both original and filtered ldefs in the scanned root: ambiguity is rejected today (`B/src/GhidraRuntime.cpp:59–87`). Record the filtered ldefs as a derived resource, not as an unchanged upstream file. Four runtime files then means the filtered ldefs, pspec, gcc cspec and sla; five includes Swift. This minimization is optional and not in the first five PRs.

`x86.opinion` is valuable evidence for loader/ABI mapping, not a dependency of a bridge that already passes an explicit target ID. The vendored opinion maps Mach-O CPU 16777223 to gcc and separately Swift (`L/x86.opinion:64–70`). `x86-64.dwarf` is for DWARF register mapping, not instruction translation; `*.register.info`, manual indices and old language translations are not needed for this selected native decompile path. Do not drop them from an immutable baseline package to implement that observation.

### 4.2 Recompile/source closure is different

Do not compile the existing SLA for this feature when its admitted bytes are unchanged. If a future semantics patch requires compilation, the source closure is:

- `x86-64.slaspec` → `x86.slaspec`, `sgx.sinc`, `fma.sinc` (`L/x86-64.slaspec:1–6`).
- `x86.slaspec` → `ia.sinc`, `lockable.sinc`, `avx.sinc`, `avx_manual.sinc`, `avx2.sinc`, `avx2_manual.sinc`, `avx512.sinc`, `avx512_manual.sinc`, `adx.sinc`, `clwb.sinc`, `pclmulqdq.sinc`, `mpx.sinc`, `lzcnt.sinc`, `bmi1.sinc`, `bmi2.sinc`, `sha.sinc`, `smx.sinc`, `cet.sinc`, `rdrand.sinc` (`L/x86.slaspec:1–21`).
- `ia.sinc` → `macros.sinc` (`L/ia.sinc:825`).

This is the inspected textual include graph, not an executed preprocessing or compiler receipt. The admitted compiler, its platform/toolchain, source inputs, patch order and generated SLA must have distinct recorded identities if compilation ever becomes necessary. No host-x86 executable is needed to compile or interpret a target-x86 specification.

## 5. Darwin ABI and resource admission

### 5.1 Ordinary C/C++/Objective-C

Apple's archived x86-64 ABI guide explicitly bases its ordinary calling convention on SysV AMD64 [P1]. The Swift project's platform summary independently records integer argument registers RDI, RSI, RDX, RCX, R8, R9; floating arguments XMM0–7; RSP+8 aligned to 16 on entry; and the 128-byte red zone [P2]. The vendored gcc cspec models RSP and the 8-byte stack return address (`L/x86-64-gcc.cspec:30–35`), the register inputs (`:38–82`), mixed-class aggregate and hidden-return rules (`:83–113`), and nonvolatile registers (`:119–127`). Its default prototype is named `__stdcall`, but the comment and registers explicitly implement SysV (`:35–36`); do not mistake that name for Win32 callee-pop behavior.

Use this as the baseline, with bounded acceptance scope, not as proof of all Darwin semantics. Darwin-specific loader/import metadata, underscore symbol decoration, Objective-C receiver in RDI and selector in RSI, Mach-O relocation/TLS handling and C++ runtime names belong in image/type authority, not an opcode matcher. Do not import Linux syscall numbers or the Windows shadow-space/MSABI model into ordinary Darwin calls. The cspec includes additional non-default prototypes such as MSABI (`:130–209`) and syscall (`:210–235`); existence does not admit them into the product.

Red zone: leaf locals below incoming RSP must remain negative-offset stack storage; they are not global memory or outgoing parameters merely because there is no `sub rsp`. Model the 8-byte return address separately. Values in a caller's red zone cannot be assumed preserved across a call. No new unconditional “128 bytes of zero memory” mapping is appropriate. Do not copy MSABI's positive local-range entries at `L/x86-64-gcc.cspec:205–208` into the default SysV prototype. The actual decompiler recovery of red-zone locals under this cspec is unverified and needs the PR3 focused case.

Darwin long-double/x87 returns, mixed aggregates, narrow signed arguments, varargs AL/XMM bookkeeping, TLS/segment bases and exception-related control flow are explicit ABI edge cases. The gcc file declares 10-byte long-double value storage with aligned length 16 (`:16`) but its displayed default output entries are RAX/RDX and XMM (`:92–113`). Do not claim full x87/long-double calling-convention fidelity from these declarations. Preserve uncertainty or unsupported status until one actual need warrants a bounded correction. No speculative custom Darwin cspec fork in PR1.

### 5.2 Native Swift

The actual `x86-64-swift.cspec` is not a placeholder: it defines `__swiftcall`, hidden return in RAX, up to four return register pieces and aggregate rules (`L/x86-64-swift.cspec:33–145`), and a `__thiscall` model with R13 input (`:148–205`). The primary Swift ABI summary additionally assigns R12 to error return, R13 to self and R14 to async context [P2]. A file named Swift does not prove that throws, async, generics, resilient aggregates, closure contexts or mixed C/Swift call sites are fully recovered by this bridge. In particular, do not infer the complete Swift ABI from its unaffected-register list.

Phase after the first five PRs: admit `apple-x86_64-swift-v1` / `x86:LE:64:default` / `swift` with its own digest and per-function selection authority. Qualify a simple native Swift body and a C-facing thunk as different conventions. Carry authoritative function signatures/calling conventions across mixed call sites where supported; otherwise show inferred/unknown behavior and avoid a whole-image Swift switch. Native Swift can remain explicitly unqualified in the first useful C/ObjC release.

### 5.3 Preserve baseline, overlay and admission identities

Observed constraints:

- `S/MATERIALIZATION.json:1` describes the original arm64 release archive and complete package identity, with one AARCH64 processor root and AARCH64 critical members. It is one physical JSON line.
- `S/PATCHES.md:3–6,26–37` distinguishes immutable upstream bytes from the AARCH64 overlay and explicitly warns consumers must admit the two-identity contract. `S/PATCHED_RESOURCES.json` is an AARCH64 patch record, not an x86 admission record (component at line 16; patched resource root at line 144 in the referenced revision).
- The bridge's root allowlist is exactly `MATERIALIZATION.json` plus `package` (`B/src/GhidraPackageAttestation.cpp:1033–1046`). Schemas 1, 2 and 3 have closed key sets and sanitizer distinctions (`:1284–1340`). The package object has one root field and closed keys (`:1347–1358`). The closed-tree walk rejects symlinks/nonordinary files, enforces bounded counts/bytes and checks digests (`:955–1012,1372–1384`).

Therefore merely copying `PATCHED_RESOURCES.json` beside an installed materialization is not a compatible extension of the inspected consumer. The patch ledger and consumer code are not enough to prove the currently installed producer reconciles this; the producer scripts and live installation require implementation-time inspection. Resolve with the owning implementation, not by disabling a check or restarting unrelated flow experiments.

Proposed admission design:

1. Preserve the committed baseline `MATERIALIZATION.json` identity and existing AARCH64 overlay ledger unchanged unless their bytes actually change. Add a versioned **derived** multi-profile materialization schema (candidate schema 4, separate from wire version 4), with explicit parent identity and a finite `profiles` map: language/compiler/profile digest, processor-relative root and exact required member identities. If an active producer already owns schema 4, reserve a distinct next version with it; no collision is assumed resolved here.
2. Bind the derived tree to original archive/source provenance, retained AARCH64 overlay identity and unchanged x86 resource identities. Do not relabel the baseline archive digest as the combined tree. A `PATCHED_RESOURCES.json` schema extension or sibling x86 ledger is needed only for actual derived/modified x86 files, not to claim unchanged x86 bytes are patched.
3. Keep an exact root-member allowlist for each materialization schema. The simplest proposed deployed root remains the two current members, with parent/overlay identities bound inside derived `MATERIALIZATION.json`; producer records can remain in source provenance. If separate ledgers are deployed instead, add their exact names and digest relationships explicitly in the new schema, never `allow extra files`.
4. Require all members needed by each admitted profile, not merely a nonempty truthful subset of `criticalFileSha256`. The present summary loop verifies recorded members but does not itself enumerate x86 requirements (`B/src/GhidraPackageAttestation.cpp:1016–1028`). The registry defines required x86 ldefs/pspec/cspec/sla. Bind the whole package as before, including resources not selected by the product.
5. Keep canonical path, parent/child containment, ordinary-file and directory-identity leases; keep sanitizer, wrapper, engine and toolchain identity distinctions. Build identity must bind the finite profile-set digest and its map, rather than accept any processor directory under the package.
6. Reuse accepted unchanged parent receipts. Only newly derived metadata or resource bytes receive first identities; no blanket baseline re-hash/recompile/requalification is proposed.

Exact producer names visible through references, **requiring implementation-time inspection**, include `Scripts/dependencies/verify_vendored_sleigh_native.py` (`S/README.md:11–13`), `Scripts/dependencies/build_vendored_sleigh_native_source.sh` (`:18–25`), `Scripts/dependencies/internalize_sleigh_aarch64_resources.py` (`:45–51`), `Scripts/qualification/dev_dependency_cache.py` (`B/CMakeLists.txt:295–299`) and `Scripts/qualification/derive_sleigh_resource_cache.py` (`S/PATCHES.md:81`). PR2 must inspect and update the active producer/consumer route in place. These exact names are integration touchpoints, not claims about their current implementations.

## 6. Runtime and XPC: one frozen package, explicit target readiness

Keep one signed arm64 XPC service, one process-global Ghidra startup and the existing global execution lock. The lock protects architecture creation, action execution, traversal and teardown, not just each provider instance (`B/src/GhidraRuntimeInternal.hpp:61–64`; implementation `B/src/GhidraRuntime.cpp:185–198`). No new thread pool or parallel native analyses are needed for this private tool.

Proposed separation:

- **Process identity:** immutable materialization root, manifest/tree identity, global spec root, engine/wrapper identity and exact admitted profile-set identity. No target chosen by the first document gets to redefine the process later.
- **Prepared target identity:** one registry-approved language/compiler/profile/context digest and processor root, checked against that frozen set. Each provider publishes its own existing-style `PreparedGhidraRuntimeIdentity`, which already contains language/compiler/profile/digest fields (`B/include/MacScopeNativeDecompiler/Backend.hpp:40–53`).
- **Request identity:** exact selected slice, ABI selection, byte authority, function extent, authored inputs and budgets. It must match the selected provider. The current provider configuration check at `B/src/GhidraProvider.cpp:5220–5224` remains, parameterized by that provider's profile.

This is not “remove language from equality and accept anything.” The frozen set explicitly replaces that lost restriction; a second resource root, changed manifest, new profile or unlisted compiler still fails. Preserve the startup-failure latch and do not reinitialize the library while leases exist (`B/src/GhidraRuntime.cpp:137–166`). Statically load the same attested global directory once and check unique ldefs/compiler resolution for every enabled tuple before publishing readiness. A fixed small provider map is enough; do not introduce a plugin registry with filesystem discovery controlled by requests.

Readiness is per target. A64 retains PAC context and required-userop checks. For x86, assert the selected language/compiler, `RIP`/`RSP`, RAM address size/word size, initial long-mode defaults and usable default prototype. If a decode readiness probe is added, it must be explicitly bounded and profile-specific. The inspected A64 readiness constructs a request and architecture and validates context/userops (`B/src/GhidraProvider.cpp:5016–5058,5117–5139`); it should not be described as evidence of a successful real decompile.

Minimal rollout: x86 is compile-time/product-disabled until its package and readiness path is accepted. Once enabled, eager preparation of the fixed arm+x86 set preserves the existing pre-listener gate. A genuine package mismatch fails the service; a known-but-not-enabled target is rejected as unsupported. Do not silently claim global readiness implies all profiles. A later per-profile partial availability map is optional, not necessary for the first private release.

Retain request cancellation, the scheduler, watchdog and exact reply correlation. The composition currently uses a 15,000 ms maximum native wall time and 500 ms termination grace (`X/NativeDecompilerServiceComposition.swift:21–22`); service payload/response bounds are 32/64 MiB (`X/NativeDecompilerServiceHost.swift:112–113`). x86 does not justify lengthening or bypassing these. A stuck native operation remains an isolated worker failure, not a reason to move native code into the app.

## 7. Bridge semantics and publication

### 7.1 Effective bytes, memory and code space

The load image is already largely architecture-neutral: it snapshots readable effective regions, retains writability, checks exact RAM-space identity, detects overflow and gaps, and rejects nonzero VMA adjustment (`B/src/GhidraLoadImage.cpp:10–29,41–88,95–125`). `GhidraArchitecture::postSpecFile` attaches it to the default code space (`B/src/GhidraArchitecture.cpp:103–109`). The x86 source declares 8-byte RAM addresses in its 64-bit build (`L/ia.sinc:3–14`). Reuse this seam rather than introducing a second Mach-O parser in the bridge.

At x86 readiness, verify the actual translator's default code space is the expected byte-addressed 64-bit processor RAM space. Continue rejecting requests in register/unique/constant spaces. Preserve RIP-relative computation by keeping virtual addresses and unmodified effective bytes, not by translating each instruction to a zero-based buffer. FS/GS-relative addressing is not ordinary RIP-relative RAM: do not fabricate a process TLS base from static bytes. Static segment-base values remain symbolic/unknown unless trusted authority supplies them.

Distinguish three domains:

1. Owned executable instruction ranges for this function.
2. Readable same-image data needed for translation, constants, switch tables and imports.
3. Callable addresses/symbols outside the owned function, not permission to follow their bodies.

A six-byte instruction can straddle adjacent readable regions; a real unreadable hole cannot be filled with zeros. The current `loadFill` can stitch adjacent supplied regions and fails on a gap (`B/src/GhidraLoadImage.cpp:70–88`). x86 decoders may request look-ahead beyond the actual instruction length. Supply only existing authorized image bytes beyond the function where necessary; do not invent padded instructions. Whether this pinned translator asks for extra bytes at a real mapping boundary is unverified. A false rejection at a boundary needs a precise decoder/load-image fix, not suppression of `hadUnavailableRead` or a retry under weaker flow options.

### 7.2 Variable-length decoding and instruction ownership

The provider's central decode loop is already length-driven: it calls `instructionLength`, bounds the result, checks `printAssembly` agreement, reads exact bytes and advances by that length (`B/src/GhidraProvider.cpp:1240–1291`). Retain that mechanism. Add target-specific valid lengths (x86 1–15, A64 4) instead of relying on the current generic 32-byte ceiling. The same profile check belongs in C++ result validation (`B/src/OutputModel.cpp:719`) and Swift semantic validation (`W/NativeDecompilerWireSemanticValidator.swift:529–540`).

Remove only actual word assumptions: range alignment, authored function alignment/minimum mapping, bytes/4 budget preflight, per-word context loop and A64 BL/B scans. `TextValidation.hpp` UTF-8 four-byte steps and SHA-256 word arithmetic are not instruction assumptions; do not mechanically replace every “4.”

Build one request-local, bounded instruction-boundary/flow index from SLEIGH and reuse it for source ownership and flow classification. Do not derive boundaries from rendered assembly or MacScope's text decoder. The x86 initial context comes from the pspec/profile hook; prefixes must be decoded normally and reset according to the language, not overwritten at arbitrary four-byte positions.

The existing decoder linearly covers every declared code range, and validators require exact tiling (`B/src/GhidraProvider.cpp:1247–1287`; `W/NativeDecompilerWireSemanticValidator.swift:562–590`). For first x86 support, keep this truthful contract: ranges must exclude known inline data and unrelated alignment islands; unsupported overlap/mid-instruction targets fail closed. Do not claim arbitrary obfuscated or overlapping x86 instruction streams. Do not broaden a function to the next symbol merely to make it decode. Sparse ranges may represent separated owned code only when the caller has authority for them; extra read-only data ranges are not code ranges.

One x86 instruction may lower to multiple p-code blocks, especially repeated/string forms. The provider already chooses between legacy and rewritten final-block partition export (`B/src/GhidraProvider.cpp:2950–2952`). Preserve instruction-to-operation ownership without assuming one instruction equals one block or one p-code op. If a targeted REP/vector case cannot fit existing partition semantics, report it unsupported and fix that general seam, not a whole-function shape matcher or reduced-action retry.

### 7.3 Flow options, direct tails and no-return

The current source enables `error_outofbounds`, `error_unimplemented`, `error_reinterpreted` and `error_toomanyinstructions` (`B/src/GhidraProvider.cpp:5269–5272`). It already converts A64 unconditional B transfers beyond the enclosing function interval to CALL_RETURN (`:5382–5409`) and separately treats a terminal BL callee as no-return (`:5412–5441`). These source facts do not establish the cause of previously reported flow failures.

The pinned upstream `FlowInfo::handleOutOfBounds` throws when `error_outofbounds` is enabled [P7]. Therefore a corresponding unhandled x86 `jmp` outside the followed interval is expected to hit the same policy. That is a source-based prediction, not an observed x86 run. Keep the strict flag; do not fix tails by globally removing out-of-bounds errors, widening the extent to the whole executable map, or retrying with a smaller action list.

Proposed classification, before full flow:

- Direct call: record its typed target and callable symbol. External callee body is not part of the caller.
- Direct unconditional jump to an owned instruction boundary: ordinary intra-function branch, even if a symbol is present.
- Direct unconditional jump outside all owned ranges with independently established callable destination or authored tail-transfer authority: CALL_RETURN override at the actual instruction address. Preserve the source instruction range and expose the tail-call relation.
- Jump into a gap, middle of an instruction or unowned block without callable evidence: do not automatically call it a tail. Reject or leave explicitly unresolved under the closed publication policy.
- Indirect jump through a known import stub: use the loader's proven import/thunk identity, not the lazy pointer's unresolved disk value (§7.4).
- Other indirect jump: distinguish switch recovery from tail transfer using recovered native flow and available authority. Do not convert every indirect jump to CALL_RETURN.
- Conditional transfer outside owned code: initially unsupported unless a precise representation is added. Never promote it to an unconditional tail.
- Terminal call: no-return only from an explicit trusted signature/runtime-import fact or established semantic evidence. “Last instruction in the requested extent” can mean the extent is wrong or truncated. Do not copy the present A64 final-BL inference into x86; correcting that existing A64 behavior is a separate owner-coordinated concern.

Membership must be in the union of owned ranges, not merely between entry and maximum end. `followFlow` currently receives one enclosing entry/end interval (`B/src/GhidraProvider.cpp:5281–5284,5453–5459`); it cannot by that call alone protect holes in sparse code. Retain post-flow source ownership checks and add an explicit pre-follow membership validation for reachable targets/fallthrough. If native discovery still attempts to execute a hole, reject the result. Do not label data-readable space as executable-owned to avoid the rejection.

Use SLEIGH raw flow operations/addresses where feasible to classify transfer, not an additional general-purpose handwritten x86 decoder. Filter internal p-code relative branches from actual machine-address branches. A narrowly specified adapter may expose direct CALL/BRANCH/BRANCHIND and length metadata; its output is explanatory authority, not a rendered-mnemonic parser.

### 7.4 Mach-O stubs, lazy binding and switches

Apple's ld64 source has six-byte x86_64 `__stubs` using RIP-relative indirect jumps, alongside lazy-pointer/helper and non-lazy GOT variants [P3]. This is a common layout, not permission to assume all stubs are six bytes or to infer imports from any `ff 25` bytes. Respect section type, `reserved2` stride, indirect symbol table and dyld binding/fixup metadata; LLVM's Mach-O header documents the stub stride field and indirect-symbol markers [P8]. The app's current parsing of these requires implementation-time inspection.

Proposed pipeline: `LoadedBinary` resolves a stub address/pointer slot to a qualified import identity using static Mach-O metadata. The request carries existing symbol/authoring authority sufficient to name callable stubs; if it cannot express the relation, add a bounded typed import-thunk record in a future explicit schema, not an overloaded invented symbol address. The worker names a call to the stub or represents an indirect call with import provenance. It does not execute `dyld_stub_binder`, treat `__stub_helper` as the user's callee, or mutate a writable lazy pointer to a fabricated resolved address. Calls through a non-lazy GOT slot and calls to `__stubs` are different address relationships even when they name the same import.

Common x86 switch forms include indexed tables of absolute destinations and PIC tables of signed relative offsets combined with a base. Let Ghidra's native p-code/SSA switch recovery do this; do not add an x86 byte-pattern switch recognizer. The vendored pspec sets `useOperandReferenceAnalyzerSwitchTables=true` (`L/x86-64.pspec:5`), but the Java program analyzer is not magically instantiated by embedding the C++ decompiler. Ghidra exposes a separate Java `DecompilerSwitchAnalysisCmd` [P5]; native `jumptable.cc` is the relevant recovery mechanism in this bridge [P6].

The bridge already requires one matched recovered, labelled, nonpartial jump table, positive bounded entry count and a valid default block (`B/src/GhidraProvider.cpp:3835–3874`). Preserve these invariants for x86. Read table bytes from admitted readable regions even when they lie outside the code extent; do not fold a writable table as constant merely because bytes were snapshotted. Preserve signed relative offsets and checked address arithmetic. Missing table bytes, unowned target blocks, partial recovery or ambiguous defaults must not become fabricated cases or successful but silently incomplete pseudocode.

One focused x86 PIC-switch example with a mapped read-only table and its missing-table variant answers more than a corpus. The existing fixture documentation already distinguishes function code from mapped `__const` table bytes (`B/tests/Fixtures/README.md:67–82`), but its compile targets and switch lowering are arm64-specific (`:27–46,56–60`), not accepted x86 evidence.

### 7.5 Output and work budgets

The current product budget v2 keeps 1 MiB code, 65,536 instructions, 262,144 operations and 5,000 ms, changing output to 8 MiB; v1 stays 1 MiB output (`W/NativeDecompilerWireTargetProfile.swift:129–154`; C++ counterpart `B/src/InputModel.cpp:654–669`). Keep those identities frozen. x86 flags, register aliases, string operations and vector expansions may change operation/output cost per instruction; this design supplies no measured ratio.

Remove bytes/4 as an x86 lower bound. Do not replace it with bytes/1 and call that a lower bound: it is a worst-case instruction count and would falsely reject long instructions. Prefer incremental output charging during the bounded decode before appending each record, followed by existing operation/SSA/block/token accounting. If an early lower bound is retained, `ceil(codeBytes/15)` for a fully tiled x86 range is a valid instruction-count lower bound, not a reserve or a prediction of p-code size. Overflow checks remain mandatory.

Retain both semantic structured-result accounting and encoded-response bounds, including text and pseudocode limits; increasing one does not authorize exceeding the other. The provider's pseudocode cap is separately 1 MiB (`B/src/GhidraProvider.cpp:189`; `B/src/OutputModel.cpp:21,50–56`). Do not truncate a successful DTO and present it as complete. Do not auto-resubmit the same failed request under larger budgets. If one measured real function warrants different limits, add a new sealed budget profile with explicit acceptance and wire parity, not mutable magic values.

The checkpoint wall-time guard is cooperative (`B/src/GhidraProvider.cpp:1218–1230`); upstream work between checkpoints is not a proven immediate interrupt. Retain XPC watchdog/crash isolation. This design does not claim the existing operation budget bounds every intermediate allocation inside upstream Ghidra. Extra upstream instrumentation is a separate change only if a focused case demonstrates a need.

## 8. Product integration and current-status limits

### 8.1 Fat Mach-O selection

Verified product declaration: universal/fat loading and x86_64 static analysis are in scope (`MacScope/PARITY_CONTRACT.md:46–51`). Verified native wire fact: selected-slice digest/count and raw CPU/subtype are already part of target identity (`W/NativeDecompilerWireTargetProfile.swift:19–32,84–101`; canonical binding `W/NativeDecompilerWireCanonicalRequest.swift:55–102`). **Unverified:** the actual loader's current default slice selection, UI switcher, cache key, native-request adapter, and persistence behavior. Those implementations are not in the referenced revision. Do not claim a working picker exists or that the app always chooses arm64.

Proposed behavior:

1. Keep the normal arm slice as default for a universal image on this Apple-silicon Mac; expose a small explicit architecture selector to choose the Intel slice. For Intel-only input, select its single supported slice automatically.
2. Read CPU/subtype from the chosen thin Mach-O and validate its consistency with the fat entry. File offsets are relative to the selected slice where the format requires it; virtual addresses remain image virtual addresses. Bounds-check offset+size and reject malformed overlaps. Do not combine symbol tables or bytes from different slices.
3. Changing slice cancels obsolete work and selects a different image/analysis identity. Invalidate native output, byte patches, source links, authored function/type assumptions and caches that are slice-specific. Stable display names are not sufficient cache identity.
4. Bind result publication to request digest, slice and profile identity. A late arm reply must never populate an Intel view. Persist selected slice identity with a versioned workspace representation only if it is not already covered.
5. MCP/scripting decompile should report actual target/profile/backend, and an unavailable native x86 result must not masquerade as an arm64 MacIR decompile.

`LoadedBinary` must remain byte/address authority by repository rule. Its host integration must be inspected before selecting exact edit sites for the above changes. PR5 below explicitly identifies new proposed adapter/test files and the missing host integration review rather than inventing current class names.

### 8.2 Compare with MacScope's X86_64Decoder

`MacScope/Services/Disassembly/X86_64Decoder.swift:19–29` is a real second `Disassembler` implementation. The comment claiming ARM64Decoder is the sole implementor at `Disassembler.swift:38–41` is stale relative to that source. The shared model has address, bytes, mnemonic/operand text, optional direct target and neutral flow (`Disassembler.swift:19–31`). The x86 decoder advances by decoded byte count, falls back to single-byte raw output for unknown encodings as documented (`X86_64Decoder.swift:6–18,24–29`), and distinguishes direct/indirect call and jump from target presence (`:33–43`). VEX, EVEX and x87 dispatch are present (`:120–132`); the opening “first increment” comment is not a complete current coverage inventory.

Use it as the existing disassembly surface and a diagnostic comparison, not the native decompiler's boundary oracle. Compare, on one named function or bounded vector set:

- `(address, bytes.count, exact bytes)` first;
- direct target and neutral flow second;
- mnemonic/operands only after syntax/alias normalization, because the decoder deliberately prints AT&T (`X86_64Decoder.swift:10–11`) and SLEIGH text may differ.

A `.byte` placeholder is not successful semantic agreement. Length disagreement invalidates confidence in downstream function/CFG boundaries; record the first divergence with the exact target, range and bytes, and repair the relevant general decoder path only when required. Never patch native semantics to match the app's rendered string or the other way around. Full x86 instruction coverage and the correctness of the decoder's fallback synchronization are unverified; no decoder run was made.

### 8.3 MacIR fallback status

The parity contract only promises ARM64 pseudocode (`MacScope/PARITY_CONTRACT.md:53–54`). The MacIR builder and native-first routing require implementation-time inspection. Operand reparsing alone is not evidence of x86 lifting support. Consequently “there is no x86 MacIR fallback today” is **not independently confirmed**. The current design assumption is “x86 semantic fallback not demonstrated.”

Until the owner verifies such a lifter, treat x86 MacIR decompilation as unavailable. Native failure may still leave useful x86 disassembly, symbols, xrefs and CFG. State that distinction in the UI/MCP; preserve exact prior output only when its byte/slice/profile authority still matches. The failure catalog's generic “Use MacScope Analysis” can mean analysis rather than pseudocode, but the action must lead to a real supported surface (`MacScope/Models/NativeDecompilerFailureCatalog.swift:6–16`). Do not manufacture a C-like fallback from mnemonic text.

### 8.4 What to skip

Skip a parallel Intel-host app build, Rosetta runtime support, x86 debugging, 32-bit/compat mode, PE/ELF native decompilation, automatic whole-program cross-slice decompilation, perfect SIMD/x87 coverage, full Swift async reconstruction, commercial-tool parity campaigns, telemetry dashboards, broad architecture plugin frameworks and a new x86 MacIR backend. Reuse current XPC isolation, byte authority, display and persistence seams. A single selector plus accurate capability/error presentation is sufficient for this private tool.

## 9. First five PRs, estimates and focused evidence

These are ordered implementation phases for the area owners. Estimates are focused engineer-days including one directly relevant check, excluding toolchain/tooling repair waits. They are not timing measurements. Respect the repository's no-repeat/no-corpus/minimal-testing guidance. No blanket suites, cold rebuilds or separate validation campaign are proposed.

A “new” path below is a proposed file, not a claim that it exists. Proposed test names are selectors to add, not passed selectors. Existing test drivers may host them instead if cheaper. Where a producer/app host file has not been inspected, its exact implementation must be read before writing: the uncertainty is part of the estimate, not permission to guess.

### PR1 — Seal Intel target contract

**Outcome:** explicit product scope and a closed x86 SysV DTO profile, rejected by unavailable runtime rather than misinterpreted. Keep x86 production exposure off.

**Files to change:**

- `MacScope/PARITY_CONTRACT.md`.
- `B/include/MacScopeNativeDecompiler/InputModel.hpp`.
- `B/src/InputModel.cpp`, `B/src/CanonicalRequest.cpp`, `B/src/CanonicalRequest.hpp`.
- `W/NativeDecompilerWireTargetProfile.swift`, `W/NativeDecompilerWireCanonicalRequest.swift`, `W/NativeDecompilerWireCodec.swift`.
- `X/Bridge/NativeDecompilerWireCodec.mm`.
- `B/tests/CanonicalRequestTests.cpp`, `B/tests/ContractTests.cpp`.
- **New proposed:** `MacScope/Tests/CoreTests/NativeDecompilerX86TargetContractTests.swift` (test target membership requires `MacScope/project.yml` inspection).

**One focused check:** `NativeDecompilerX86TargetContractTests/testSealedSysVProfileCrossLanguageParity`, a small parameterized contract case: baseline x86 subtype accepted; unknown capability/subtype rejected; Windows compiler with x86 Darwin profile rejected; x86 byte-aligned sparse ranges accepted; A64 misalignment remains rejected; same bytes under a different selected-slice/profile produce a different canonical identity. Reuse the existing A64 canonical golden, not a new broad rerun. Establish C++/Swift canonical preimage equality in the same seam.

**Risk/estimate:** medium, 1–2 days. Main risks are false ABI selection and digest/version drift. No native pseudocode support is advertised after this PR.

### PR2 — Admit governed x86 resources

**Outcome:** a derived multi-profile package identity and strict resource-root/member admission; no x86 semantics patch or recompile.

**Files to change:**

- `B/src/GhidraPackageAttestation.cpp`, `B/src/GhidraPackageAttestation.hpp`, `B/src/GhidraBuildIdentity.hpp.in`, `B/CMakeLists.txt`.
- `S/README.md`, `S/PATCHES.md`; change the schema/producer interpretation of `S/PATCHED_RESOURCES.json` only if deploying a new ledger format, not its unchanged A64 patch bytes.
- `B/tests/GhidraPackageIdentityTests.cpp`, `B/tests/GhidraPackageAttestationFixture.hpp`.
- **New proposed:** `ThirdParty/SleighNative/X86_64_RESOURCES.json` for the closed required-member/profile inventory, derived from actual unchanged vendor identities by the owner once.
- **Inspect before implementation:** `Scripts/dependencies/verify_vendored_sleigh_native.py`, `Scripts/dependencies/build_vendored_sleigh_native_source.sh`, `Scripts/qualification/dev_dependency_cache.py`, and the actual packaging/staging route it calls. If `Scripts/qualification/derive_sleigh_resource_cache.py` produces the active overlay view, extend it rather than introduce a bypass producer.

**No edit to immutable baseline** `S/MATERIALIZATION.json` or `L/*` merely to add support. The derived output manifest, with its new profile map, is produced under the existing accepted materialization route. If an explicit baseline metadata migration is chosen instead, retain its original identity as provenance and document the migration; do not silently reuse the old manifest digest.

**One focused check:** add `x86-resource-profile-admission` to `GhidraPackageIdentityTests.cpp`: the admitted x86 tuple resolves all required members under the governed root, while one missing required member, wrong member digest, an unlisted compiler tuple and an extra/symlink root member are rejected in parameterized test fixtures. Use existing parent receipts for unchanged real dependencies. These are contract mutations in test fixtures, not requested live-package corruption or new hash sweeps.

**Risk/estimate:** high, 2–3 days. Uninspected producer/staging code and existing overlay-consumer mismatch may add 1–3 days. On a tooling failure, stop that step and report the source fix needed; do not create an alternate materialization root to evade it.

### PR3 — Prepare x86 runtime and byte-sized instructions

**Outcome:** a bounded simple x86 function can return a verified native result without weakening A64 or package admission.

**Files to change:**

- `B/src/GhidraRuntimeInternal.hpp`, `B/src/GhidraRuntime.cpp`, `B/src/Backend.cpp` and `B/include/MacScopeNativeDecompiler/Backend.hpp` only as needed for the identity separation.
- `B/src/GhidraArchitectureInternal.hpp`, `B/src/GhidraArchitecture.cpp`, `B/src/GhidraProvider.cpp`.
- `B/src/GhidraLoadImage.cpp` only if the focused boundary case demonstrates a real look-ahead issue; not a preemptive padding workaround.
- `B/src/OutputModel.cpp`, `W/NativeDecompilerWireSemanticValidator.swift`.
- `X/Bridge/NativeDecompilerObjCBridge.mm`, `X/Bridge/NativeDecompilerObjCBridge.h`, `X/NativeDecompilerServiceComposition.swift`.
- **New proposed:** `B/src/NativeTargetProfiles.hpp` for the finite registry, `B/tests/GhidraX86ProviderTests.cpp`; register the latter in `B/CMakeLists.txt`. Extend `B/tests/GhidraProviderLocationTests.cpp` only if the changed package identity path requires it.

**One focused check:** `x86-length-runtime-budget` in the proposed provider test file. Use one short known x86 function with mixed instruction lengths, an unaligned start and a negative-RSP leaf local, then tightly parameterized malformed/truncated-length and exact/one-under output-bound variants. Include A64→x86→A64 provider selection in the same process to detect frozen-identity/context contamination, without restarting global state. Keep its byte/region authority explicit; do not run the whole provider suite.

**Risk/estimate:** high, 3–5 days. x86 decoder look-ahead, profile-set identity and output accounting can expose hidden assumptions. The owner must supply one named real third-party x86 function for the required pseudocode-change evidence before treating a decompiler PR as qualified; this design supplies no accepted Intel example. An authored fixture alone does not satisfy the repository's real-binary gate. No fabricated before/after is supplied here.

### PR4 — Recover x86 transfers and switches

**Outcome:** useful ordinary calls, proven tails, import-stub naming and a common PIC switch, without accepting unknown flow as valid.

**Files to change:**

- `B/src/GhidraProvider.cpp` to replace x86 word-scan assumptions with the typed boundary/flow index and preserve strict publication.
- **New proposed:** `B/src/NativeInstructionFlow.hpp`, `B/src/NativeInstructionFlow.cpp` for a small architecture-neutral adapter over SLEIGH flow, listed in `B/CMakeLists.txt`.
- `B/src/GhidraBlockPartition.cpp`, `B/src/BlockPartition.cpp`, `B/src/OutputModel.cpp` only for any demonstrated general partition/instruction-ownership issue, not speculative rewrites.
- `B/tests/GhidraX86ProviderTests.cpp` (created in PR3).
- `B/tests/Fixtures/c_calls.c`, `B/tests/Fixtures/c_control_flow.c`, `B/tests/Fixtures/README.md` only if the owner uses source-generated bounded Intel examples. Their current arm64 compile instructions are not Intel evidence.
- **New proposed app adapter:** `MacScope/Services/NativeDecompiler/NativeDecompilerX86ImportAuthority.swift`, consuming existing `LoadedBinary` metadata. Actual loader/request-builder host call sites must be inspected before integration; do not introduce a second Mach-O parser in this file.

**One focused check:** `x86-flow-authority-matrix`: one bounded record set covering a direct external tail, an internal jump, an import stub, an unresolved indirect jump, a final returning call and a PIC switch with table bytes in read-only memory. Expected negative cases: conditional escape, target in a sparse gap/mid-instruction, missing table bytes and unsupported final-call truncation fail closed. This is one targeted semantic matrix, not a binary-wide sweep; select only the affected cases if the actual patch is smaller. Name the real Intel function whose pseudocode changes and retain exact before/after with the owner.

**Risk/estimate:** high, 3–5 days. Hardest distinction is tail vs missing function extent; switch recovery depends on available data and actual native analysis, not just decoder support. A blanket CALL_RETURN or no-return heuristic is unacceptable.

### PR5 — Expose selected Intel slice truthfully

**Outcome:** private app/MCP can request and display x86 native decompilation for an explicitly selected slice and offer honest fallback.

**Files to change:**

- `W/NativeDecompilerWireTargetProfile.swift` for the product exposure flag/selection seam if still gated.
- `MacScope/Models/NativeDecompilerFailureCatalog.swift` for capability-aware alternatives.
- `MacScope/Services/Disassembly/Disassembler.swift` to correct the stale sole-implementor comment; do not rewrite `X86_64Decoder.swift` merely for text parity.
- `MacScope/PARITY_CONTRACT.md` to record qualified vs deferred scope.
- **New proposed:** `MacScope/Services/NativeDecompiler/NativeDecompilerSliceAdmission.swift`, `MacScope/Models/NativeDecompilerTargetCapabilities.swift`, `MacScope/Tests/CoreTests/NativeDecompilerX86SliceAdmissionTests.swift`.
- **Mandatory owner inspection:** the concrete `LoadedBinary` definition, fat-slice selector/view model, native request builder, cache/persistence integration and MCP decompile routing. Integration touchpoints include the scripting family `MacScope/Services/Scripting/WorkspaceScriptingAPI*.swift` and persistence touchpoints `MacScope/Stores/WorkspaceDatabase.swift` and `MacScope/Models/AnalysisModels+DocumentPackage.swift`, but their exact declarations and required edits remain to be established. `MacScope/project.yml` is the source-membership authority; its current content must be inspected. Do not claim this is a complete implementation file list until those host files are read.

**One focused check:** `NativeDecompilerX86SliceAdmissionTests/testSwitchSliceRejectsStaleNativeReply`: a small two-slice image authority switches arm→Intel while an arm reply is pending; verify the Intel digest/profile binds the new request, the late arm response is rejected, native capability/fallback messaging is correct and reopening keeps the selected slice if persistence changed. Include the existing decoder only to compare lengths/targets for that same bounded Intel function. This can be a headless model test; no automatic GUI/release/installed-app campaign is needed.

**Risk/estimate:** medium-high, 2–4 days, conditional on loader/MCP code being already well-factored. Do not promise x86 MacIR fallback. If actual host integration is materially larger, split PR5 at its adapter seam rather than expanding this design into a platform rewrite.

### Effort envelope and later phase

First five PRs: approximately **11–19 engineer-days**; allow **1–3 additional days** if the resource producer/overlay contract needs source repair. Planning assessment: value 3 / effort 4; this is not a configuration-only change. Useful ordinary C/ObjC support should not wait for complete native Swift or SIMD semantics.

Optional later Swift/mixed-ABI phase: **3–7 days** for one explicitly selected Swift profile and bounded interop evidence; throws/async/resilient aggregates may require additional work and remain separately unqualified. Optional x86_64h admission: **0.5–1 day** if the selected language and metadata need no new semantics. Full x87/AVX/obfuscated-code coverage is not estimated because it is not the target outcome.

### Principal risk register and stopping criteria

| Risk | Severity | Minimal control / stop criterion |
|---|---|---|
| Wrong CPU or compiler spec produces plausible but wrong C | High | Closed tuple, canonical identity and independently authoritative ABI selection. Reject unknown choices. |
| First prepared language locks out later slice | High | Frozen package/profile-set identity, per-profile readiness, one same-process switch test. Never reset global state to force success. |
| Resource additions bypass current attestation | High | Explicit derived schema/member map, whole-tree binding, existing receipt reuse. Stop on producer mismatch; no alternate package route. |
| Incorrect x86 instruction boundaries contaminate CFG | High | SLEIGH lengths, exact byte tiling and boundary checks. Raw `.byte` output is not native semantic evidence. |
| Tail heuristic hides wrong function extent | High | Proven callable target/authority, union-of-ranges membership, no blanket indirect-tail or final-call no-return. |
| Native jump recovery lacks required bytes/analyzer context | High | Read-only data authority plus nonpartial native table checks. Missing evidence remains failure, not guessed cases. |
| ABI edge cases produce overconfident parameters | Medium-high | Initially qualify ordinary scalar/aggregate use; disclose Swift/x87/varargs edges until bounded evidence. |
| P-code/SSA expansion overwhelms a byte-based budget | Medium-high | Actual incremental record/operation accounting, immutable budget profiles, hard XPC isolation. No automatic budget retry. |
| Fat-slice change reuses old pseudocode, patches or types | High | Slice-qualified request/cache/persistence identity; cancel/reject stale work. |
| Fallback claims x86 semantics that do not exist | Medium-high | Capability-specific native failure and real disassembly/CFG fallback; MacIR fallback remains unverified. |

## 10. Native engine and ABI references

Consulted 2026-10-16. These sources describe ABI facts and native-engine integration boundaries.

### Ghidra

Ghidra's published Mach-O loader enumerates universal members and presents preferred load specifications for processor selection, then matches the selected member when loading [P4]. The vendored x86 opinion separately maps Mach-O to gcc or Swift (`L/x86.opinion:64–70`). Its architecture is a loader plus language/compiler choice plus analysis, not “CPU type is the whole decompiler.” Its Java switch-analysis command is separate from the native recovery code [P5, P6]. The MacScope integration requires explicit slice and ABI separation; do not assume embedding C++ imports all Ghidra Java analyzers or loader facts. Public master may differ from the pinned 12.1.2 snapshot.

### Direct reference links

- **P1 — Apple, x86-64 Function Calling Conventions:** https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/LowLevelABI/140-x86-64_Function_Calling_Conventions/x86_64.html . Archived ABI source; establishes SysV basis, not a live product support matrix.
- **P2 — Swift project, Calling Convention Summary, x86-64:** https://github.com/swiftlang/swift/blob/main/docs/ABI/CallingConventionSummary.rst#x86-64 . Register roles, stack alignment and red zone; moving main branch.
- **P3 — Apple ld64, x86_64 stubs:** https://raw.githubusercontent.com/apple-oss-distributions/ld64/main/src/ld/passes/stubs/stub_x86_64.hpp . Stub/lazy/GOT/helper implementation; moving main branch.
- **P4 — Ghidra MachoLoader:** https://github.com/NationalSecurityAgency/ghidra/blob/master/Ghidra/Features/Base/src/main/java/ghidra/app/util/opinion/MachoLoader.java . Universal member/load-spec selection; moving master.
- **P5 — Ghidra DecompilerSwitchAnalysisCmd API:** https://ghidra.re/ghidra_docs/api/ghidra/app/cmd/function/DecompilerSwitchAnalysisCmd.html . Separate Java command surface, not evidence it runs in this bridge.
- **P6 — Ghidra native jump-table implementation:** https://raw.githubusercontent.com/NationalSecurityAgency/ghidra/master/Ghidra/Features/Decompiler/src/decompile/cpp/jumptable.cc . Native recovery reference; moving master, not a qualified runtime test.
- **P7 — Ghidra flow implementation at the pinned revision:** https://raw.githubusercontent.com/NationalSecurityAgency/ghidra/c0f584bf229fffba61b36431f3ce30c0c3e4e682/Ghidra/Features/Decompiler/src/decompile/cpp/flow.cc . `newAddress`, `processInstruction`, `handleOutOfBounds` and flow overrides; source inspection only.
- **P8 — LLVM Mach-O format definitions:** https://raw.githubusercontent.com/llvm/llvm-project/main/llvm/include/llvm/BinaryFormat/MachO.h . CPU/subtype constants, stub section/stride, indirect-symbol flags and data-in-code kinds; moving main.

## 11. Unverified scope and decisions for the owner

1. Source-level design inspection does not establish installed-app behavior. Current app slice selection, request construction, persistence/cache invalidation, x86 import binding and MacIR lifting are not independently established. Exact host edit paths must be resolved from the active checkout before PR5.
2. The x86 SLA file exists, but loadability, accepted digest, compiler provenance and packaging closure were not rechecked. No new pins or accepted receipts are claimed. The four-file selected-profile closure is not an unconditional standalone-package claim.
3. The active producer's treatment of AARCH64 overlays versus the inspected strict two-member consumer is unresolved by the design evidence. PR2 must use the owning source fix, not a second pipeline or relaxed checker.
4. No Intel instruction/function, tail, stub, jump table, Swift ABI, red-zone local, budget limit, XPC round trip, cancellation, crash or UI path was executed. Proposed tests are unrun.
5. No real third-party Intel binary/function was supplied as accepted semantic evidence. The owner must name one already available local x86 specimen and function for before/after acceptance; do not scan a corpus to find it. The existing ordinary Vim test is explicitly arm64e (`B/tests/GhidraProviderTests.cpp:3066–3068`) and cannot stand in for Intel acceptance.
6. Choose whether first exposure includes only subtype 3 or also a separately checked subtype 8, and whether C-profile unknown-ABI functions should be labelled “SysV assumed” or rejected without authority. This design recommends subtype 3 and explicit inference disclosure.
7. Native Swift, x87/long-double ABI edges, writable switches, exceptional flow and overlapping/obfuscated x86 remain separately qualified work, not implied by a successful basic profile.
8. Previously reported flow diagnoses remain background rather than independently verified runtime findings. This work does not reopen unrelated flow investigations. The observed A64-only tail and terminal-BL code is documented separately; related A64 correction belongs to its current owner.
9. Package, signing and installation changes are outside design acceptance. Implementation and runtime acceptance remain separate deliverables.

## 12. Definition of a useful first completion

The first increment is complete when the owner has accepted the narrow contract change, an attested arm64 worker can decompile one named real Intel function under the explicit SysV profile, variable-length bytes and owned flow survive C++/Swift validation, a selected Intel slice cannot reuse an arm reply, and native failure leads to an honest existing analysis surface. Reuse each accepted result; do not add a corpus or a second verification campaign. It is not necessary to claim universal x86, full Swift, native x86 MacIR, or commercial-tool parity.

End of complete design.
