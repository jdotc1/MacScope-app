# MacScope Capability Contract

Authoritative, binding scope + acceptance contract for MacScope's capability
surface. Where this file and any status document disagree, **this file wins**.

## 1. Capability scope

**Current product direction (2026-10-20):** native SLEIGH is the default decompiler; MacIR is the challenger and retained analysis/fallback substrate. SSA remains default-off. SEC lanes are off.

**Current local AI provider decision (2026-10-05):** MTPLX is the only supported
product inference integration. LM Studio features, provider selection and model
lifecycle integration are retired. Historical receipts and persisted legacy
configuration may be retained as historical data, but must not activate a
legacy provider or be silently converted into MTPLX authority. MacScope does
not delete user preferences/model directories or download models as part of
this change. MTPLX owns model loading, unloading and context management;
MacScope retains explicit loopback endpoint, bounded request policy and model
selection authority behind its existing worker boundary.

**Permanent remaining-work freeze (2026-10-05):** every unfinished LM Studio
work item is reference-only, permanently frozen and excluded from the active
backlog, including older plans labeled active, pending or required. Historical
LM Studio designs may inform MTPLX modeling, but do not authorize new LM Studio
implementation, tuning, qualification or runtime activation. Preserve historical
receipts and inert legacy compatibility; do not relabel incomplete work passed,
silently migrate provider authority or delete user data.

**Active MTPLX precision-first contract:** integration and tuning prioritize
grounded accuracy and faithful semantics over speed. Accept only explicit valid
MTPLX policy and exact observed endpoint/model/context authority; desired model
names and stored preferences are not observations of a ready runtime. Reasoning
and context choices must be quality-evaluated rather than reduced solely for
latency. Unknown or insufficient evidence remains explicit, and malformed,
stale or ungrounded outputs cannot become workspace truth. Retain bounded
requests, cancellation/drain semantics, typed result validation and existing
app-owned tool authorization; tuning grants no additional execution authority.
Live quality evidence and synthetic transport evidence are distinct. This decision does not claim that live tuning or installed acceptance is complete.

MacScope's target is a **comprehensive, native Apple-Silicon macOS
binary-analysis workbench** — defined on its own terms, not relative to any
other product. The material capability surface is:

- **Loading:** Mach-O executables, app bundles, dylibs, frameworks, XPC
  services, universal/fat containers, dyld shared-cache images; plus ELF and PE
  for cross-format inspection.
- **Static analysis:** ARM64 + x86_64 disassembly, control-flow graphs,
  cross-references, symbol and import/export recovery, Objective-C
  class/metadata and Swift metadata/demangling, code signatures, chained fixups,
  DWARF/dSYM debug info.
- **Decompilation:** ARM64 pseudocode with structured control flow and
  typed-local recovery.
- **Debugging:** LLDB-backed launch and arbitrary local process attach for
  macOS ARM64 targets. Local attach is an in-scope capability (explicit product
  decision, 2026-07-13), subject to macOS signing, hardened-runtime,
  authorization, user-boundary, SIP, and platform protections. The product
  must provide process identity/compatibility checks, precise denial
  diagnostics, PID-reuse protection, and distinct detach-versus-terminate
  semantics; “arbitrary” does not promise that macOS permits every target.
- **Editing & automation:** byte patching + an ARM64/x86 assembler behind an
  app-owned assembler boundary; reviewed pure-Swift encoder implementations may
  run in the app, while native or otherwise crash-prone assembler engines remain
  service-isolated; a scripting/command surface (in-process API, MCP) and a
  native plugin story.
- **Workspaces:** the current `.mscope` package (`manifest.json` plus
  attachments, atomically replaced) and its SQLite serialization/staging
  layer, with document lifecycle, autosave, and conflict handling. Phase 2
  durable identity and recovery requirements are frozen independently of the
  future physical package representation, which remains an F1 decision.
- **AI investigation (Phase 2):** a local-first, evidence-grounded assistant
  whose first release uses typed read-only MacScope operations and current,
  image-qualified citations. Later authority tiers remain separately gated.

Code presence alone is **not** completion — see §3. Behavioral correctness is
validated against **authorized external reference oracles** (see §7) and
MacScope-owned semantic contracts; adopting an approved dependency does not by
itself establish correctness.

## 2. Project status

- **First-party design-system reuse (2026-10-03).** The owner authorizes the
  pinned Lumen submodule and local Swift package described in
  docs/dependencies/Lumen.md. This first-party code requires no external
  license/notice record. Exact commit/tree provenance, offline ordinary builds,
  source-bound qualification and preserved user settings remain required.
- **Platform/toolchain decision (2026-07-13).** MacScope requires Apple
  Silicon, macOS 27.0 or newer, and the current Xcode 27 major line with its
  bundled Swift compiler in Swift 6 language mode and bundled LLDB. Xcode
  27 beta, RC, and patch/build revisions are accepted; a transient build
  number is not part of the product contract.
- **Local signing/distribution decision (2026-07-13).** Keep certificate-backed
  Apple Development signing for stable local development and installed-app
  validation. Developer ID distribution signing, notarization, and public
  packaging are explicitly deferred until a later product program; they are
  not gates for the current roadmap.
- **Phase 2 foundation acceptance.** F0 requires frozen authority,
  persistence, threat, capability, corpus, and evaluation contracts plus a
  fail-closed executable validator. Volatile branch, review, and gate status is outside this capability contract.
- **Phase 2 authority decision.** The MacScope app alone owns durable reducer
  state, authorization, dispatch/routing, result and evidence acceptance,
  canonical commit, persistence, and final user-visible truth. A worker may
  mechanically execute only a declared app-authorized operation within its
  narrow role and returns a versioned typed proposal/result without inheriting
  app authority.
- **Phase 2 release ceilings.** R0 is foundation-only and has no execution
  authority. The first user-visible goal, R1 Grounded Local Assistant, is
  limited to typed native read operations; it has no shell, debugger control,
  workspace mutation, or external-tool execution.
- **Phase 2 F0 historical non-claims.** F0 itself did not select or integrate a provider/model,
  added a new XPC target, exposed a shell or PTY, or applied a Phase 2
  persistence migration.
- **Debug Assist boundary.** Arbitrary local process attach remains in scope for
  later typed, read-only-first Debug Assist after debugger identity/lifecycle
  prerequisites. Remote debugging remains an explicit exclusion.
- **Selected REA integration (owner-authorized, 2026-10-11).** The pinned
  `morluto/rea` native/dyld, compiled UI and captured-process comparison algorithms
  may be selectively copied with their reviewed permissive dependency closure
  into a digest-bound JavaScriptCore resource hosted only by AnalysisWorker.
  MacScope retains loader, process, capture, evidence acceptance and persistence
  authority. No REA server, Node runtime, arbitrary scripts, new inference provider
  or automatic target execution is introduced. Each capability remains unavailable
  until its affected native/worker and installed acceptance passes; existing
  successful reconstruction evidence retains its original source identity.
- **Approved open-source reuse (binding, 2026-07-20).** Public open-source
  components recorded in `THIRD_PARTY_COMPONENTS.yml` may be
  vendored, linked, invoked, adapted, or selectively copied only in the stated
  approval and integration mode. Every dependency-bearing change must use an
  immutable revision/checksum, preserve applicable licenses and notices, be
  recorded in `THIRD_PARTY_COMPONENTS.yml`, avoid implicit build-time downloads,
  keep dependency-specific objects behind MacScope-owned protocols/DTOs, and pass
  the required security, determinism, differential, rollback, and full-suite
  gates. Proprietary, non-public, unapproved, or license-incompatible source and
  binary resources remain prohibited. Required public open-source license and
  notice files are authorized repository content; this authorization does not
  extend to proprietary reference-tool code, resources, branding, or SDK
  implementation code.

## 3. Capability status vocabulary

Target: **full functional and behavioral coverage** of the capability scope in
§1, except the explicit exclusions. Code presence alone is **not** completion.
Every tracked capability is one of these states:

1. `absent` — not implemented.
2. `implemented_unreachable` — code exists but no user/menu/shortcut/scripting
   path reaches it.
3. `reachable_unvalidated` — user-reachable, but not validated end to end.
4. `internally_validated` — exercised by MacScope tests.
5. `behaviorally_equivalent` — output matches an authorized external reference
   oracle on reference inputs (§7).
6. `approved_deviation` — an intentional difference backed by a recorded
   decision (below).
7. `explicit_exclusion` — a documented non-goal (below).

Acceptance: a capability is "done" only at `internally_validated` or higher (or
is an `approved_deviation` / `explicit_exclusion`). A claim of full coverage
additionally requires `behaviorally_equivalent` evidence (a normalized
golden-output match against an external oracle).

### Milestone-gate status vocabulary

Roadmap milestone gates use a separate three-state program vocabulary:

1. `PASSED` — every criterion is satisfied by recorded, current evidence.
2. `BLOCKED` — at least one named criterion remains unsatisfied; the blocker is
   recorded and may be evidence-, environment-, policy-, or engineering-bound.
3. `GATED` — evaluation or activation is intentionally deferred until a named
   prerequisite gate reaches `PASSED`.

Gate status never substitutes for the capability states above. A gate may be
`BLOCKED` or `GATED` even when individual capabilities are internally validated,
and it may become `PASSED` only from evidence rather than source presence.

## 4. Explicit exclusions (approved omissions — NOT gaps)

These are intentional product decisions. They are **not** unresolved questions,
missing work, release blockers, defects, or future implementation tasks, and
they are **excluded from coverage calculations and validation matrices**. Do not
implement them, create tasks/fixtures/loaders/ decoders/UI/tests/benchmarks for
them, or list them as gaps/blockers/decisions.

1. x86 debugging.
2. x86 decompilation outside the staged macOS x86_64 SysV native profile described
   in `docs/design/X86_64_NATIVE_PROFILE.md`. The sealed DTO contract is admitted;
   production request construction and native runtime exposure remain disabled.
   Resource admission, runtime readiness and semantic acceptance are later phases.
   i386, Windows, native Swift ABI and an x86 MacIR backend remain excluded.
3. Windows debugging.
4. Windows decompilation.
5. **PowerPC disassembly and analysis.**
6. **Hexagon disassembly and analysis.**
7. **i386 / 32-bit x86 disassembly and analysis.**
8. **Remote debugging of a target process on another system.** Local ARM64
   launch and arbitrary local process attach on the same Mac remain in scope.
9. **32-bit ARM / Thumb (AArch32: A32 and T32/Thumb-2) disassembly and
   analysis** (decided 2026-10-17).

> **Approved architecture omissions:** MacScope intentionally omits PowerPC,
> Hexagon, i386/32-bit-x86, and 32-bit ARM/Thumb (AArch32) disassembly and
> analysis. These omissions are
> explicit product decisions. They are not coverage gaps, unresolved deviations,
> release blockers, or future implementation requirements, and they are excluded
> from coverage calculations and validation matrices. x86_64 loading,
> disassembly, and static analysis remain in scope.

**Scope guards (do not over-broaden the exclusions):**

- The exclusions do **not** generalize to **x86_64**: x86_64 loading,
  disassembly, and static analysis remain **in scope**.
- The exclusions do **not** generalize to **ARM64**: ARM64 loading, disassembly,
  analysis, decompilation, and macOS debugging remain **in scope**. The 32-bit
  ARM exclusion covers the AArch32 instruction sets only, not arm64 or arm64e.
- Windows/PE **loading, disassembly, static analysis, symbols, imports, exports,
  relocations, and metadata** remain **in scope** — only Windows _debugging_ and
  _decompilation_ are excluded.
- Other architectures (68k, 6502, etc.) are **not decided** by
  this contract; do not silently classify them as excluded. They are open
  product questions.
- When a finding couples an excluded architecture with an in-scope concern (e.g.
  "PowerPC + arm64e PAC semantics"), remove only the excluded-architecture
  portion and keep the in-scope part.

## 5. Approved deviations (with evidence)

Intentional design choices, recorded so they are not re-litigated as gaps:

- **LLDB-only debugger backend** (debugger via LLDB public APIs).
- **ARM64 production decompilation**; macOS x86_64 SysV has a staged, disabled
  native target contract. No Intel pseudocode capability is advertised yet.
- **Apple-Silicon / macOS-centric** platform focus.
- **MacScope-owned `.mscope` package** as the stable project format. The
  current GUI package is a JSON manifest plus attachments; SQLite is used as a
  serialization/staging authority. A future physical package/schema change is
  not approved until the F1 migration and recovery design is frozen.
- **Python SDK object-model deferral** + native-plugin v1 extensibility story.
- **Auto-update / Updates-preferences deferral.**

## 6. Open product questions (not settled by this contract)

These remain open unless a stronger recorded decision resolves them:

- Byte editing, instruction assembly, and patched-executable production (an
  ARM64 encoder exists behind the app-owned assembler boundary; UI scope is
  undecided).
- Full dyld shared-cache depth (sub-cache stitching + symbolication).
- Residual scripting primitives beyond the approved SDK deferral.
- Live AppleScript runtime integration.
- BinDiff / BinExport2 interoperability.
- Other architecture families (68k, 6502, …).

## 7. Behavioral-equivalence acceptance rule

Reaching `behaviorally_equivalent` for an in-scope capability requires a
normalized golden-output comparison against an **authorized external reference
oracle** on a fixed binary set. MacScope's side ships in
`MacScope/Tests/CoreTests/Support/Golden/GoldenOutput.swift`; the fixture layout reserves private,
git-ignored slots for reference outputs (see
`Tests/CoreTests/GoldenFixtures/README.md`). Stored reference outputs are normalized to the same schema. Do **not** generate or require golden
fixtures for PowerPC, Hexagon, i386, or 32-bit ARM/Thumb.
