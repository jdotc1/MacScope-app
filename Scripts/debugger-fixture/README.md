# WS-18 deterministic debugger fixture

This directory contains only source and tooling for the local WS-18 debugger target. Generated app
bundles, dSYMs, manifests, signatures, and probe reports belong in an explicit temporary output root
and must not be committed.

The generated topology contains a UI-less main app executable, a lazily loaded embedded framework,
and a separately launchable helper. Main and framework export a probe in the same preferred custom
segment address but retain distinct Mach-O UUIDs. Main, helper, and framework also export stable,
no-inline checkpoint anchors.

Both executables require `--control-dir PATH --nonce TOKEN --started-after-ns N`. The harness records
`N` from the realtime clock before atomically creating a fresh mode-0700 control directory. The
runtime opens that directory without following symlinks, holds its directory descriptor, verifies
owner/mode/freshness, and creates all channels relative to that descriptor. Each role creates an
exact mode-0600 FIFO named `<role>.commands` and a mode-0600 JSONL event file named
`<role>.events.jsonl`. Commands are bounded to 4096 bytes and contain exactly `schema`, monotonic
`sequence`, `nonce`, and one of `load`, `checkpoint`, `unload`, or `exit`; duplicate or unknown fields
are rejected. EOF requests a deterministic graceful exit; debugger detach alone does not alter the
command channel or terminate the target.

`fixture_tool.py` plans Xcode-27/SDK-27 arm64 builds, requires the exact approved Apple Development
certificate by fingerprint, signs inside-out with hardened runtime and timestamping disabled, and
rejects any topology, architecture, deployment, UUID/dSYM, preferred-address, signer/team,
designated-requirement, or entitlement mismatch before atomic promotion. There is no ad-hoc
fallback and no keychain or provisioning mutation.

The executable interface is:

```sh
Scripts/debugger-fixture/fixture_tool.py build \
  --developer-directory /Applications/Xcode-beta.app/Contents/Developer \
  --signing-fingerprint APPROVED_CERTIFICATE_SHA1 \
  --output-root /tmp/MacScopeDebuggerFixture.accepted

Scripts/debugger-fixture/fixture_tool.py verify \
  --developer-directory /Applications/Xcode-beta.app/Contents/Developer \
  --root /tmp/MacScopeDebuggerFixture.accepted

Scripts/debugger-fixture/fixture_tool.py compare \
  --first /tmp/build-one/manifest.json \
  --second /tmp/build-two/manifest.json
```

`build` discovers and records the selected Xcode 27/SDK 27 toolchain, resolves the approved Apple
Development certificate, builds and signs inside-out in a same-directory staging root,
independently verifies every leaf, writes stable and volatile identity evidence, and only then
atomically promotes. `compare` ignores declared signing volatility while requiring exact unsigned,
UUID, deployment, preferred-address, source, and toolchain identity.

If the keychain contains multiple valid certificates with the approved subject, `build` fails closed
unless `--signing-fingerprint` selects exactly one of those approved identities. The fingerprint is
certificate identity metadata, not a credential, and is never used to broaden the subject/team
policy.

Focused tests run without signing or LLDB. The runtime module compiles a temporary test-owned C
helper and exercises the real bounded FIFO/JSONL protocol:

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest \
  Scripts.tests.test_debugger_fixture_tool \
  Scripts.tests.test_debugger_fixture_runtime
```

Live signed builds, LLDB launch, attach, and cleanup remain serialized integration steps owned by
the primary WS-18 operator.

## Historical WS-18 integration checkpoint

This section records WS-18 acceptance. Later local-process attach support is
described in the [current debugging playbook](../../docs/dev/DebuggingPlaybook.md).

The accepted six-cell DAP/Python/CLI matrix is local evidence at
`/tmp/MacScope-WS18-live.zHYIvJ`. The matrix executed from source commit `38ceac0`; its final
validator/checkpoint commit is `deaff3d`. The report SHA-256 is
`0c630818eda957b53f01ae26dcb639bbfa5b3ef3c80c0bd60bddcba98fc230d6`, and the append-only
journal SHA-256 is
`c6de2da56e65258de8294a92c74c9fc1b68b44f7041bf7ade2783e9d18a12adb`. Both artifacts are owned by
`example`, have mode 0600, remain local and untracked, and must not be committed.

All six cells were observed. Every cell has complete cleanup receipts and zero owned-process
residue. Structural validation and the mandatory launch, test-owned attach/detach, and persistent
CLI baseline validators exit 0. Typed selection exits 1 only with
`typedSelectionCandidateUnavailable`: neither typed candidate proved the complete frozen primary
operation matrix, so WS-18 does not authorize a typed primary migration. The hardened persistent
CLI remains the production baseline.

The process-originated readiness handshake and the run-owned, exact-identity `SIGSTOP` proof close
the launch-admission race in this fixture harness. They are harness stabilization, not evidence
that MacScope's CLI transport implements a product pause capability. Production arbitrary local
process attach remains later roadmap work, and remote debugging remains excluded.

All `Scripts/tests/test_*.py` pass 577/577. The inherited authoritative CoreTests gate remains green
at 4,004 executed / 15 skipped / 0 failures; it was not rerun because the accepted follow-up changed
only debugger-fixture scripts, tests, validation, and documentation, leaving the app/Core tree
unchanged.

Earlier evidence roots—including `/tmp/MacScope-WS18-live.986I04` (superseded after adapter
PID-reuse hardening), `/tmp/MacScope-WS18-live.FWCB7e`, `/tmp/MacScope-WS18-live.YtODyi`, and
`/tmp/MacScope-WS18-live.QWoJRb`—are historical artifacts and are not acceptance authority. Use
only the accepted root and hashes above when auditing this checkpoint.

This checkpoint merged through PR #65 as `main@67b9394`. The post-merge all-Scripts gate passes
577/577, and the structural/mandatory/typed-selection validators reproduce the accepted outcomes.
