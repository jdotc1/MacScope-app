# P4 owned-child supervision contract

Status: **proposed implementation contract, source-only**. Base foundations:
`27ed44b86be68930f935e6a4b360726086527a27`; Plan decision: P-ARCH,
2026-10-21 00:37 EDT, refined by P-R4SEAM 00:39 and P-I03-P4CH 00:40. This document and inert shared vocabulary do not activate
native execution, replace a scheduler, or establish sandbox/runtime qualification.
The production pattern factory remains `.unavailable()` / nil.

## 1. Ownership and present topology

Plan selects an owned native child below the **existing launchd AnalysisWorker
XPC service**. That worker is the sole spawn owner, signalling owner and reaper.
The app communicates with its signed XPC peer and never signals a child PID.
The worker's dedicated serial control queue performs admission, pipe state,
monotonic timers, nonblocking reaping and signals. Native evaluation runs in a
separate child process, never on that parent queue. No new signed target is selected.

Current source establishes these narrower facts:

- `MacScope/AnalysisWorkerService/main.swift` constructs one process controller,
  installs mutual signing, and unconditionally enters `NSXPCListener.service()`.
  It has no child-mode dispatch or owned-child reaper. Pattern stays unavailable.
- `MacScope/project.yml` lists `AnalysisWorkerXPCService` and
  `NativeDecompilerXPCService` as existing embedded XPC targets. The latter has
  the Objective-C++ bridge and SLEIGH libraries; the former does not.
- `MacScope/NativeDecompilerXPCService/main.swift` unconditionally prepares its
  native composition and enters the native XPC service. Its bridge resolves
  `NativeDecompilerPackage` relative to `NSBundle.mainBundle.resourceURL`.
- `AnalysisWorkerSupervision.swift` at the base is bookkeeping and a self-watchdog.
  Its self-SIGKILL targets the worker process. It is **not** this owned-child host,
  and its `observedExit` method is not a child `waitpid` receipt.
- Current analysis, dyld and REA paths execute in the analysis worker; current
  decompiler transport addresses a separate launchd native-decompiler service.
  Neither path is represented here as already supervised by an owned child.

The future child-mode entrypoint must run before XPC listener creation, engine
construction, package preparation, or native requests. Static loader initializers
remain an executable-wide limitation: this design isolates request execution,
not arbitrary pre-main initialization failures in the parent executable.

## 2. Executable and spawn contract

Use `posix_spawn`, never a shell, PATH lookup, fork-and-run-Swift, launchd service
lookup, or `Foundation.Process` with an independent waiter. The parent derives
absolute executable paths from its own installed bundle layout:

| Channel | Existing signed executable to spawn in child mode |
| --- | --- |
| pattern, analysis (including pinned/rehydrate), dyld, REA | `Bundle.main.executableURL`, whose installed suffix is `Contents/XPCServices/AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService` |
| decompiler | The sibling `NativeDecompilerXPCService.xpc/Contents/MacOS/NativeDecompilerXPCService` below the same containing app's `Contents/XPCServices` |

The decompiler child must execute the sibling binary so its bridge, libraries and
bundle resource resolution remain attached to the native-decompiler bundle. It
must not reinterpret the analysis worker as a SLEIGH executable. Routing to that
sibling and both early child-mode entrypoints are future owner-reviewed edits.
Use the installed bundle's existing signing policy and pinned package receipts;
do not add a new signature/hash walk as ordinary dispatch. Missing/wrong bundle
layout, unsupported child mode or failed spawn is an explicit unavailable result.
Never substitute an externally supplied executable or materialization path.

Exact proposed argv (separate string elements, no interpolation through a shell):

```
[absoluteExecutable,
 "--macscope-owned-native-child-v1",
 "--channel", oneOf("pattern", "decompiler", "analysis", "dyld", "rea")]
```

No request data, source path, bytes, request UUID or nonce enters argv. Invalid
arguments in child mode exit with usage code 64 before native initialization.
The child-mode argv and exact allowlisted environment are checked before either
listener or native initialization. The launchd/default entrypoint is used only
when this child-mode flag is absent; it must never fall through to an XPC listener after a malformed child invocation.

Construct envp explicitly as exactly `LANG=C`, `LC_ALL=C`, `TZ=UTC`.
Do not copy the parent's environment. Do not add PATH, HOME, TMPDIR, DYLD_*,
XPC_*, test injection, inference or debug settings. Pass resource locations through
bundle-relative resolution and per-request file descriptors, never environment
variables. If an existing loader genuinely requires another variable, its name
and value policy require an explicit contract revision before activation;
absence is not permission to inherit the full environment.

Create anonymous pipes before spawn. Child stdin fd 0 is a bounded framed command
stream; stdout fd 1 is the protocol stream; stderr fd 2 is diagnostic output.
A separate child fd 3 is the exact transferred read-only input descriptor, used
only when that channel's existing pinned-byte protocol requires it. Preserve its
regular-file/seekable nature and original byte authority; do not replace it with
a pipe or reopen its pathname. Close unused fd 3.
Spawn file actions duplicate the intended ends onto 0/1/2/3 and close all other
inherited descriptors. Parent ends have close-on-exec; close child ends promptly
in the parent. A future adapter must verify the SDK's close-all-except mechanism
and descriptor-collision handling; it may not leave arbitrary app descriptors open.
The child's stdin/control reader runs independently of its one native execution
queue. Child mode never starts an XPC listener, becomes another supervisor,
spawns descendants, or detaches/execs another program; a channel that requires
another executable needs a separate explicit ownership design. Parent pipe
readers are nonblocking; pipe backpressure never blocks the
parent control queue or its timeout/reap work. Drain stderr independently into a
64 KiB bounded diagnostic tail; continue draining/discarding beyond that cap so
logging cannot stop native progress. Record truncation and total bytes, without
copying private source/bytes into general logs. Drain stdout according to its
framing/caps; protocol corruption quarantines the child rather than being parsed
as a partial success. Closing stdout/stderr or seeing EOF alone never proves exit.

Child inherits the supervisor's existing credentials/sandbox through spawn; no
entitlement expansion is authorized. Whether direct execution of both XPC-bundle
executables succeeds under the shipping configuration is **unverified**. This
contract supplies no substitute for that later bounded acceptance gate.

## 3. First handshake and request identity

The worker generates a fresh spawn UUID before each spawn. It records the
`posix_spawn` returned positive PID and the worker's own startup nonce, logical
channel, request UUID and connection generation **before** dispatching any request.
Only successful `posix_spawn` creates owned-child authority. A PID learned from
NSXPC, a payload, a process lookup or a previous worker incarnation cannot do so.

1. Parent sends one UTF-8 JSON initialization line, at most 1024 bytes including
   newline: protocol version 1, operation `initialize`, parent startup nonce,
   spawn nonce, channel, request UUID and connection generation. Reject duplicate
   JSON keys, unknown fields, malformed UUIDs and unsupported versions.
2. Child's **first stdout line** is one UTF-8 JSON handshake, at most 1024 bytes
   including newline: version 1, kind `ready`, those same immutable identities,
   and its actual `getpid()` value. No native initialization/evaluation precedes it.
   The retained stdout pipe is exclusively the protocol writer's output. Before
   native execution, child duplicates that pipe into its private protocol handle,
   then redirects standard stdout to stderr; native printf/iostream output cannot
   corrupt protocol frames. The private handle is close-on-exec and is never passed
   to native adapters.
3. Parent requires complete line framing, exact nonce/key equality and actual PID
   equality with its spawn result, on this child's retained pipe endpoints. The
   startup deadline is armed before spawn and is not extended by partial output.
   Proposed policy: 2000 ms for handshake; dispatch budgets remain channel-owned.
4. Only after that validation may parent send `execute`. Child accepts one execute
   per lifetime and rejects duplicate keys/control from another spawn nonce.
   Native/package setup begins inside that operation and counts toward its budget.

The spawn nonce is correlation, not code-signing proof or a kernel audit token.
Parent-child relationship, exclusive unreaped ownership and private inherited
pipe endpoints establish signalling authority. The handshake catches wiring,
replacement and replay errors. Native package validation keeps its existing
receipt-reuse rules; a handshake does not create a verification receipt.

After the handshake line, stdin/stdout use a 4-byte unsigned big-endian length
followed by exactly that many payload bytes. No later line-based parsing occurs.
Controls are bounded to 1024 bytes. Work/result outer frames are bounded by the
selected channel's existing encoded limits; include outer-envelope overhead in
that check and refuse an unknown channel/limit before allocation. Pattern uses
its existing 2 MiB encoded request and 6 MiB encoded worker-reply bounds; it retains
the existing 4 MiB native-document bound. No new lower cap silently truncates an
analysis or decompiler payload. Attachments use the descriptor mechanism, without
base64 expansion or reopening a caller's path.

Every work/control/terminal frame carries actual parent startup nonce, spawn nonce,
channel, request UUID and connection generation. Child return is a typed union:
`nativeReturned` with the unchanged channel reply bytes, or `rejectedBeforeNative`
with a typed failure. A cancel acknowledgement is advisory, never terminal.
Parent validates full identity before considering a terminal frame. A mismatched,
malformed, oversized or partial terminal frame establishes no native return.

## 4. Exclusive reaping and safe signalling

One serial owner queue holds every child record from successful spawn through
positive reaping. It alone calls `waitpid(exactChildPID, &status, WNOHANG)` and
`kill(exactChildPID, signal)`. Poll reaping on an independent monotonic 10 ms timer;
no blocking wait runs on the control queue. SIGCHLD delivery is not required.
No broad `wait`, `waitpid(-1, ...)`, dispatch-process watcher reaper, Foundation
termination handler, generic child library or second queue may reap these children.

Keep process-wide SIGCHLD disposition `SIG_DFL`; **never** set `SIG_IGN` or
`SA_NOCLDWAIT`. Assert/check that prerequisite before spawn; conflict disables this
capability rather than silently changing another subsystem's handler. A future
SIGCHLD wake-up optimization must preserve the same sole waitpid owner. Current
source does not establish this process-wide prerequisite at runtime.

Serialization is the PID-reuse protection: an exited child remains unreaped until
this queue calls waitpid, so its PID cannot be reassigned before that reap. All
kill decisions happen on that same queue before the record becomes reaped. After
reaping, remove signalling authority **before** scheduling any external callbacks.
A stale timeout can never signal a newly recycled PID. Check the retained spawn
nonce and full dispatch key as well as record state; do not unlock between checking
ownership and sending a signal. Never signal process groups, PID zero, PID -1,
parent/app PIDs, descendants, or a replacement process located by numeric PID.

`waitpid == 0` means still unresolved. `EINTR` leaves the same record pending.
`ECHILD` is an ownership-contract violation, not successful exit; quarantine and
retain admission, report the exact failure, and disable new work. Other errors
also quarantine. A positive exact PID return with a terminal wait status is the
only `waitpid` exit receipt. Stopped/continued status is not exit. Preserve raw
status and decoded `WIFEXITED`/`WEXITSTATUS` or `WIFSIGNALED`/`WTERMSIG`/core-dump
information; do not confuse signal numbers with ordinary exit codes.

## 5. Deadline, result and lease state machine

The control queue owns one monotonic deadline covering spawn, handshake and work,
with the work sub-budget supplied by the existing channel policy. Handshake uses
the smaller of its 2000 ms policy and remaining total budget. Proposed abort grace
is 250 ms for pattern; preserve the decompiler's existing request budget and
500 ms grace, rather than borrowing a pattern deadline for it. Analysis/dyld/REA
retain their documented policy inputs. No infinite or guessed default is admitted.

| State/event | Required transition and authority |
| --- | --- |
| admitted -> spawning -> awaitingHandshake | Hold process-wide native admission before spawn; successful spawn records immutable ownership. No work before matching first handshake. |
| matching handshake -> running | Register the full request before writing execute; one operation per child. |
| valid native terminal frame -> nativeReturned | Publish at most one correlated result if caller still owns its waiter. Do not revive an already timed-out waiter. Ask child to shut down and continue reaping. |
| deadline/caller cancellation | Settle that waiter once; quarantine child admission; send nonce/key-bound `abort`. Caller task cancellation never owns the native lease. Deadline still runs when delivery/caller disappears. |
| deadline -> abortRequested | Arm grace escalation **before** writing abort. A blocked pipe/native cancel cannot postpone the timer. Keep the record and admission. |
| grace -> killRequested | On owner queue, if exact child remains unreaped and no sufficient terminal evidence ended native execution, send SIGKILL to that child only. Signal success, ESRCH or an abort acknowledgement proves no exit. |
| killRequested -> exitUnconfirmed | Continue sole-reaper polling; no timeout may simply drop this record or reopen admission. A kill failure is reported while quarantine continues. |
| exact terminal waitpid -> reaped | Clear signalling authority, cancel timers, map result, finish any remaining waiter once, then release native admission. Keep bounded lifetime nonce/key tombstones. |
| spawn failure before child exists | No PID ownership; close pipes and release the unused lease with explicit unavailable/spawn failure. |
| any malformed handshake/result or pipe failure after successful spawn | Fail waiter once, quarantine, follow abort/kill/reap; uncertainty is not no-work evidence. |

For the single-use child this contract conservatively releases the **spawn/admission
slot after confirmed reap**, including normal native return. A genuine native
return is sufficient evidence that that operation ended; keeping its slot until
cleanup avoids accumulating returned-but-unreaped children. If native return
arrives during grace, end the native deadline and request shutdown; a separate
bounded 250 ms shutdown grace may still kill a child hung after return. That
cleanup escalation is also limited to the same unreaped child. A timed-out result
never reopens admission or replaces timeout with success.

Child exit code 0 plus a valid native terminal frame yields that frame's existing
channel result. Exit 0 without it is protocol failure. Nonzero exit without it is
child failure with exact code. A terminal native return followed by cleanup failure
retains the already returned channel result and records cleanup failure separately;
never settle the waiter twice. A signal before terminal return maps to the
initiating deadline (`timedOut`), explicit caller cancellation (`cancelled`), or
unexpected worker failure (`workerCrashed`/the channel's existing equivalent).
Store the actual signal separately, including SIGKILL; do not report every
SIGKILL as timeout or fabricate a valid native document.

## 6. All-channel integration and authority

The shared inert `AnalysisWorkerOwnedChild*` vocabulary names the eventual common
registry. It is not wired into the base self-watchdog or host reducer. The future
registry uses `(parent startup nonce, spawn nonce, channel, request UUID,
connection generation)` and one process-wide native admission lease across all
member connections. It keeps waiter lifetime separate from native-flight/reap
lifetime. Equal request UUIDs in different channels remain distinct. Tombstones
are bounded and saturation refuses work without evicting identity fences.

| Channel | Adapter required before declaring it supervised |
| --- | --- |
| pattern | Worker-only PatternNativeJob construction in analysis child mode; preserve structural validator/native-document bounds and selection authority in app. Factory remains nil until complete integration. |
| analysis/pinned/rehydrate | Existing payload codecs and transferred byte descriptors pass through parent into analysis child. Child performs parser/AnalysisEngine calls; parent never falls back to synchronous native parsing on its control queue. Preserve LoadedBinary/source-descriptor authority. |
| dyld/REA | Separate typed codecs/cancellation controls, same parent admission/reap registry. Existing process lease/provider retirement is not child exit evidence. REA JavaScript executes in its analysis-executable child with its own bundle resource. |
| decompiler | AnalysisWorker parent spawns the existing sibling native-decompiler executable in child mode. Preserve schema-v3 codec, structured output, bounded scheduler, native package receipts and bridge cancellation. Parent does not link or parse rendered pseudocode to simulate its result. App's existing direct launchd-native transport needs explicit routing adaptation; it is not automatically a member. |

All production constructors must choose one immutable supervised mode and the same
registry before activation. Old UUID-only selectors cannot bypass membership in
that mode. A legacy-used process refuses activation rather than adopting unknown
work. App timeout/invalidation fails waiters but cannot reset child admission.
No default flip, app adapter, channel routing or worker entrypoint is implemented
by this contract. Existing unmodified channel paths retain their present behavior;
none is counted as owned-child coverage.

## 7. Parent death, remaining feasibility and maintainer decision boundary

The existing-worker topology is sufficient for safe owned-child signalling/reaping
**while the parent supervisor remains alive and responsive**. A native child
freeze does not occupy that parent's control loop. The 27ed self-watchdog alone
does not provide this separation and must not be treated as satisfying it.

If AnalysisWorker dies, crashes or freezes, its child may remain alive/orphaned.
NSXPC interruption, invalidation, parent exit, pipe EOF or a replacement worker's
fresh nonce does **not** prove child exit. The app must retain an unresolved
operation/quarantine record for that exact former parent/child incarnation and
refuse automatic retry/admission that would assume the old native work stopped.
A new worker cannot adopt the old PID, reap another process's child, or signal it.
Do not claim launchd automatically kills descendants; this has not been established.
The app must retain that unresolved barrier across supervisor reconnection, and
must not silently lose it through workspace/transport reconstruction. Restart
recovery with unresolved children is a separate design obligation before broad
activation; no persistence mechanism is supplied in this slice.

**Concrete decision only if recovery after supervisor loss is required:**
(B) retain the recommended existing owned-child topology with explicit indefinite
quarantine when child exit cannot be confirmed, or (A) authorize a **new signed
supervisor helper executable** that owns native children independently of the
on-demand AnalysisWorker's lifetime, including its target, signing/entitlements
and IPC/lifecycle acceptance. The need for A would be inability to accept B's
unconfirmed-orphan quarantine or a demonstrated shipping sandbox refusal to spawn
the existing executables. A helper also needs an explicit failure/recovery design;
its mere existence does not prove orphan cleanup. This contract selects B per
Plan; it does not select or create A. No current source establishes that B is
impossible, and no runtime feasibility experiment was authorized/performed.

## 8. Future acceptance selectors; evidence reuse

No tests are added or run for this contract-only commit. Reuse the 27ed foundation
source preparation and the previously accepted slice-1 45/0/0 receipt at b62e1bae0;
do not describe the 27ed foundations as runtime-qualified. Plan owns pending
foundation compilation/testing and all later changed-input gates.

Proposed exact future unit selectors (not existing tests and not execution claims),
under `CoreTests/AnalysisWorkerOwnedChildSupervisorTests`:

- `testSpawnUsesAllowlistedExistingExecutableArgumentsEnvironmentAndDescriptors`
- `testHandshakeRequiresSpawnNonceActualPIDAndFullDispatchIdentity`
- `testNoNativeDispatchBeforeHandshakeOrAfterHandshakeDeadline`
- `testOwnedUnreapedPIDCannotBeSignalledAfterReapOrByStaleTimer`
- `testSoleReaperRejectsSIGCHLDIgnoreAndECHILDWithoutReleasingAdmission`
- `testDeadlineArmsEscalationBeforeAbortAndHoldsLeaseUntilWaitpid`
- `testNativeReturnFollowedByHungCleanupStillRequiresReap`
- `testExitCodeSignalAndMissingTerminalFrameMapWithoutFabricatedSuccess`
- `testAllChannelsShareAdmissionAndKeepWaiterSeparateFromNativeFlight`
- `testSupervisorLossRetainsOrphanQuarantineAndRejectsPIDAdoption`

These must use fake spawn/pipe/clock/kill/waitpid adapters first. A later Plan grant
must name bounded real child-mode acceptance for both executables and shipping
signing/sandbox configuration; neither a fake test nor this contract proves it.
