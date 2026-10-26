#!/usr/bin/env python3
"""Darwin runtime supervision bridge for executable WS-18 debugger probes.

The module exposes the six hooks consumed by transport_probe.py.  All process
admission is explicit PID/path/nonce based; all signalling is delegated to the
exact-identity OuterProcessSupervisor.  Importing this module has no side effects.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import signal
import stat
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable, Mapping, Optional, Sequence


HERE = Path(__file__).resolve().parent


def _load(name: str):
    if name in sys.modules:
        return sys.modules[name]
    specification = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    if specification is None or specification.loader is None:
        raise RuntimeError("unable to load " + name)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


supervision = _load("process_supervisor")
darwin = _load("darwin_process_backend")
drivers = _load("candidate_drivers")
python_bridge = _load("lldb_python_bridge")
cli_session = _load("lldb_cli_session")

APPROVED_FIXTURE_SIGNER = "Apple Development: MacScope Developer (CERT000000)"
REGISTRATION_MAX_ATTEMPTS = 3
REGISTRATION_RETRY_SECONDS = 0.01
DARWIN_PROCESS_STATUS_STOPPED = 4


class RuntimeBridgeError(RuntimeError):
    pass


@contextmanager
def _defer_termination_signals():
    """Defer the first handled signal without changing the child's signal mask."""

    previous_handlers = {}
    pending = []

    def defer(signum, frame):
        if not pending:
            pending.append((signum, frame))

    for signum in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[signum] = signal.signal(signum, defer)
    try:
        yield
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        if pending:
            signum, frame = pending[0]
            previous = previous_handlers[signum]
            if callable(previous):
                previous(signum, frame)
            elif previous == signal.SIG_DFL:
                os.kill(os.getpid(), signum)


@dataclass(frozen=True)
class RuntimeProcessFact:
    """Exact OS-owned target fact, deliberately free of protocol revisions."""

    operation: str
    targetPID: int
    identityMatched: bool
    condition: str
    evidence: Mapping[str, object]


class _Context:
    def __init__(self, owner: str, process_api: object, macho_reader: object,
                 signing_reader: object, process_factory: Callable[..., object],
                 approved_fixture_signer: str,
                 fixture_exit: Optional[Callable[[object, float], object]] = None) -> None:
        self.owner = owner
        self.process_api = process_api
        self.claims = darwin.SelectedProcessClaims()
        backend = darwin.DarwinSnapshotBackend(process_api, self.claims, macho_reader, signing_reader)
        self.inspector = supervision.ABASnapshotInspector(backend)
        self.registry = supervision.ProcessRegistry(owner, self.inspector)
        self.child_enumerator = darwin.DarwinExactChildEnumerator(
            process_api, self.registry, self.inspector)
        self.process_factory = process_factory
        self.approved_fixture_signer = approved_fixture_signer
        self.processes: dict[object, object] = {}
        self.detach_ack_pid: Optional[int] = None
        self.detach_sequence_before = 0
        self.detach_receipt = None
        callbacks = {supervision.ProcessRole.ADAPTER: self._graceful_adapter}
        if fixture_exit is not None:
            callbacks[supervision.ProcessRole.ATTACHED_HELPER] = fixture_exit
            callbacks[supervision.ProcessRole.LAUNCHED_TARGET] = fixture_exit
        controller = darwin.DarwinRegisteredProcessController(
            self.registry, self.inspector, callbacks)
        self.controller = controller
        waiter = darwin.DarwinRegisteredProcessWaiter(self.registry, self.inspector)
        self.supervisor = supervision.OuterProcessSupervisor(
            self.registry, self.inspector, controller, waiter)
        self.cleanup_receipts = ()
        self.adapter_receipts: dict[object, object] = {}
        self.descendant_receipts: dict[object, object] = {}
        self.fixture_path: Optional[str] = None
        self.residue = None
        self.closed = False
        self.mode = "unconfigured"
        self.candidate = {
            "dap": "xcode-lldb-dap",
            "cli": "macscope-lldb-cli-baseline",
            "python": "xcode-lldb-python-json",
            "preflight": "preflight",
        }.get(owner.split("-", 1)[0], owner)

    def _graceful_adapter(self, registration, timeout):
        process = self.processes.get(registration.process_key)
        if process is None or process.poll() is not None:
            return supervision.GracefulAction(False, True, "alreadyExited")
        # Controller has just revalidated the exact registered identity.
        adapter_input = getattr(process, "stdin", None)
        if adapter_input is not None and not adapter_input.closed:
            adapter_input.close()
        process.terminate()
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            return supervision.GracefulAction(
                True, False, "terminateExactAdapterTimedOut", str(error))
        return supervision.GracefulAction(True, True, "terminateExactAdapter")

    def register(self, pid: int, path: str, nonce: str, role,
                 executable_identity: str = "",
                 expected_start_ns: Optional[int] = None) -> object:
        if self.closed:
            raise RuntimeBridgeError("closed runtime context cannot admit another process")
        canonical = os.path.realpath(path)
        self.claims.add(darwin.SelectedProcessClaim(pid, canonical, nonce, role,
                                                    executable_identity))
        snapshot = None
        for attempt in range(REGISTRATION_MAX_ATTEMPTS):
            snapshot = self.inspector.capture(pid)
            if (snapshot.state is supervision.InspectionState.EXACT
                    and snapshot.identity is not None):
                break
            if (snapshot.state is not supervision.InspectionState.UNSTABLE
                    or attempt + 1 == REGISTRATION_MAX_ATTEMPTS):
                break
            time.sleep(REGISTRATION_RETRY_SECONDS)
        if snapshot is None:
            raise RuntimeBridgeError("exact A-B-A registration did not inspect the process")
        if snapshot.state is not supervision.InspectionState.EXACT or snapshot.identity is None:
            detail = str(snapshot.detail).encode(
                "utf-8", errors="replace"
            )[:supervision.MAX_DETAIL_BYTES].decode("utf-8", errors="ignore")
            raise RuntimeBridgeError(
                "exact A-B-A registration failed: "
                + json.dumps({
                    "attempts": REGISTRATION_MAX_ATTEMPTS,
                    "detail": detail,
                    "state": snapshot.state.value,
                }, sort_keys=True, separators=(",", ":")))
        identity = snapshot.identity
        observed_start_ns = (identity.start_seconds * 1_000_000_000
                             + identity.start_microseconds * 1_000)
        if (expected_start_ns is not None
                and observed_start_ns != expected_start_ns):
            raise RuntimeBridgeError(
                "process start anchor changed before registry admission")
        if role in {supervision.ProcessRole.ATTACHED_HELPER,
                    supervision.ProcessRole.LAUNCHED_TARGET}:
            if identity.signing_identity != self.approved_fixture_signer:
                raise RuntimeBridgeError("fixture process does not have the approved signing identity")
        elif identity.signing_identity in {"unsigned", "ad-hoc-or-no-authority"}:
            raise RuntimeBridgeError("debugger adapter is not certificate signed")
        return self.registry.register(identity)

    def spawn_adapter(self, argv: Sequence[str], *, stdin,
                      stderr=subprocess.PIPE,
                      env: Optional[Mapping[str, str]] = None) -> tuple[object, object]:
        if not argv or not os.path.isabs(argv[0]):
            raise RuntimeBridgeError("adapter executable must be an absolute selected-Xcode path")
        spawn_options = {"stdin": stdin, "stdout": subprocess.PIPE,
            "stderr": stderr, "start_new_session": True, "close_fds": True}
        if env is not None:
            spawn_options["env"] = env
        with _defer_termination_signals():
            process = self.process_factory(tuple(argv), **spawn_options)
            try:
                registration = self.register(
                    process.pid, argv[0], self.owner + "-adapter",
                    supervision.ProcessRole.ADAPTER,
                )
            except BaseException:
                # Popen.poll() uses waitpid(WNOHANG): a None result proves this
                # exact direct child is still unreaped, so its PID cannot yet be
                # recycled. Only that bounded proof permits pre-admission cleanup.
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=1.0)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=1.0)
                raise
            self.processes[registration.process_key] = process
        return process, registration

    def spawn_fixture(self, path: str, control_dir: Path, nonce: str,
                      started_after_ns: int, executable_identity: str,
                      launcher: Callable[..., object]) -> object:
        if self.closed or self.registry.registrations:
            raise RuntimeBridgeError("attach helper is already prepared")
        argv = (path, "--control-dir", str(control_dir), "--nonce", nonce,
                "--started-after-ns", str(started_after_ns))
        # Fixture protocol evidence is file/FIFO based.  Its conventional output
        # is neither authoritative nor consumed, so pipes would only introduce a
        # backpressure deadlock during a long run.
        with _defer_termination_signals():
            process = launcher(
                argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True,
            )
            try:
                registration = self.register(
                    process.pid, path, nonce,
                    supervision.ProcessRole.ATTACHED_HELPER, executable_identity,
                )
            except BaseException:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=1.0)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=1.0)
                raise
            self.processes[registration.process_key] = process
        return registration

    def cleanup_adapter(self, registration: object) -> object:
        if registration.identity.role is not supervision.ProcessRole.ADAPTER:
            raise RuntimeBridgeError("candidate close may clean only its adapter")
        for descendant in self.discover_debugger_descendants(registration):
            descendant_receipt = self.descendant_receipts.get(
                descendant.process_key)
            if descendant_receipt is None:
                descendant_receipt = self.supervisor._cleanup_one(descendant)
                self.descendant_receipts[descendant.process_key] = descendant_receipt
        receipt = self.adapter_receipts.get(registration.process_key)
        if receipt is None:
            process = self.processes.get(registration.process_key)
            poll_result = None
            if process is not None:
                # Popen.poll() reaps only this retained direct child.  Reaping
                # before the supervisor's first anchor lets a true exit prove
                # GONE without weakening the generic A-B-A disappearance rule.
                poll_result = process.poll()
            if process is not None and poll_result is not None:
                # The exact retained child was reaped, so its PID is reusable.
                # Take exactly one immediate capture: absence is terminal;
                # every other state becomes a refusal without a second read.
                terminal = self.inspector.capture(registration.identity.pid)
                if terminal.state is supervision.InspectionState.GONE:
                    receipt = self.supervisor._receipt(
                        registration,
                        terminal,
                        supervision.GracefulAction(
                            False, False, "alreadyGone"),
                        terminal,
                        False,
                        False,
                        terminal,
                        True,
                    )
                else:
                    refusal = self.supervisor._refusal_for(
                        terminal, registration.identity)
                    receipt = self.supervisor._receipt(
                        registration,
                        terminal,
                        supervision.GracefulAction(False, False, "refused"),
                        terminal,
                        False,
                        False,
                        terminal,
                        False,
                        refusal or "refused reaped adapter PID remains occupied",
                    )
            else:
                # An unreaped retained child cannot have suffered PID reuse;
                # adapters without a retained Popen use the generic exact path.
                receipt = self.supervisor._cleanup_one(registration)
            self.adapter_receipts[registration.process_key] = receipt
            if receipt.complete:
                if process is not None:
                    for stream in (getattr(process, "stdin", None),
                                   getattr(process, "stdout", None),
                                   getattr(process, "stderr", None)):
                        if stream is not None and not stream.closed:
                            stream.close()
        return receipt

    def discover_debugger_descendants(self, adapter_registration: object) -> tuple[object, ...]:
        if adapter_registration.identity.role is not supervision.ProcessRole.ADAPTER:
            raise RuntimeBridgeError("debugger descendants require an adapter owner")
        existing = tuple(
            item for item in self.registry.registrations
            if item.identity.role is supervision.ProcessRole.LOCAL_DEBUGSERVER)
        if existing:
            return existing
        adapter_snapshot = self.inspector.capture(adapter_registration.identity.pid)
        if adapter_snapshot.state is supervision.InspectionState.GONE:
            # Absence of the adapter is not evidence that an unregistered local
            # debugserver also exited.  A child admitted earlier under exact
            # ancestry is returned above; without that ledger entry the run must
            # fail closed rather than publish an incomplete residue audit.
            raise RuntimeBridgeError(
                "adapter exited before debugger descendant admission")
        if (adapter_snapshot.state is not supervision.InspectionState.EXACT
                or adapter_snapshot.identity != adapter_registration.identity):
            raise RuntimeBridgeError(
                "debugger descendant observation requires the exact registered adapter")
        registered_pids = {item.identity.pid for item in self.registry.registrations}
        fixture_path = getattr(self, "fixture_path", None)
        observations = tuple(
            item for item in self.child_enumerator.enumerate(
                adapter_registration, excluded_pids=registered_pids)
            if item.pid not in registered_pids
            and (fixture_path is None or item.canonical_path != fixture_path)
        )
        if len(observations) > 1:
            raise RuntimeBridgeError(
                "ambiguous exact adapter descendants cannot be assigned cleanup authority")
        if not observations:
            return ()
        observation = observations[0]
        if observation.parent_pid != adapter_registration.identity.pid:
            raise RuntimeBridgeError("debugger descendant is not an exact direct adapter child")
        registration = self.register_debugger_descendant(
            observation.pid,
            observation.canonical_path,
            "%s-debugger-child-%d" % (self.owner, observation.pid),
            adapter_registration,
        )
        identity = registration.identity
        if (identity.pid != observation.pid
                or identity.canonical_path != observation.canonical_path
                or identity.start_seconds != observation.start_seconds
                or identity.start_microseconds != observation.start_microseconds):
            raise RuntimeBridgeError(
                "debugger descendant changed after exact child enumeration")
        return (registration,)

    def observe_debugger_descendants(self) -> tuple[object, ...]:
        try:
            adapter = self.registry.by_role(supervision.ProcessRole.ADAPTER)
        except KeyError:
            return ()
        return self.discover_debugger_descendants(adapter)

    def ensure_target(self, pid: int, path: str, nonce: str, attached: bool,
                      executable_identity: str,
                      expected_start_ns: Optional[int] = None) -> object:
        role = (supervision.ProcessRole.ATTACHED_HELPER if attached
                else supervision.ProcessRole.LAUNCHED_TARGET)
        try:
            existing = self.registry.by_role(role)
            observed_start_ns = (
                existing.identity.start_seconds * 1_000_000_000
                + existing.identity.start_microseconds * 1_000)
            if (existing.identity.pid != pid
                    or expected_start_ns is not None
                    and observed_start_ns != expected_start_ns):
                raise RuntimeBridgeError("registered target identity disagrees")
            return existing
        except KeyError:
            return self.register(
                pid, path, nonce, role, executable_identity, expected_start_ns)

    def register_debugger_descendant(self, pid: int, path: str, nonce: str,
                                     adapter_registration: object,
                                     executable_identity: str = "") -> object:
        if self.closed:
            raise RuntimeBridgeError("closed runtime context cannot admit a debugger descendant")
        canonical = os.path.realpath(path)
        role = supervision.ProcessRole.LOCAL_DEBUGSERVER
        self.claims.add(darwin.SelectedProcessClaim(
            pid, canonical, nonce, role, executable_identity))
        descendant = self.inspector.capture(pid)
        adapter = self.inspector.capture(adapter_registration.identity.pid)
        if (descendant.state is not supervision.InspectionState.EXACT
                or descendant.identity is None
                or adapter.state is not supervision.InspectionState.EXACT):
            def bounded_detail(value: object) -> str:
                return str(value).encode(
                    "utf-8", errors="replace"
                )[:supervision.MAX_DETAIL_BYTES].decode(
                    "utf-8", errors="ignore"
                )

            diagnostic = {
                "pid": pid,
                "path": canonical,
                "descendantState": descendant.state.value,
                "descendantDetail": bounded_detail(descendant.detail),
                "adapterState": adapter.state.value,
                "adapterDetail": bounded_detail(adapter.detail),
            }
            raise RuntimeBridgeError(
                "debugger descendant identity is not exact: "
                + json.dumps(diagnostic, sort_keys=True, separators=(",", ":"))
            )
        return self.registry.register_debugserver(
            descendant.identity,
            adapter_key=adapter_registration.process_key,
            ancestry=(descendant, adapter),
        )

    def exact(self, pid: int, expected: Optional[drivers.ExactAttachTarget] = None) -> bool:
        snapshot = self.inspector.capture(pid)
        if snapshot.state is not supervision.InspectionState.EXACT or snapshot.identity is None:
            return False
        identity = snapshot.identity
        if expected is None:
            return True
        return (
            identity.pid == expected.pid
            and identity.start_seconds * 1_000_000_000 + identity.start_microseconds * 1_000 == expected.startTimeNS
            and identity.real_uid == expected.realUID and identity.effective_uid == expected.effectiveUID
            and identity.canonical_path == os.path.realpath(expected.canonicalPath)
            and identity.cpu_type == expected.cpuType and identity.cpu_subtype == expected.cpuSubtype
            and identity.executable_device == expected.executableDevice
            and identity.executable_inode == expected.executableInode
            and getattr(identity, "executable_identity", None) == expected.executableIdentity
            and identity.macho_uuid == expected.machOUUID
            and identity.signing_identity == expected.signingIdentity
            and identity.nonce == expected.nonce
        )

    def cleanup(self) -> None:
        if self.closed:
            return
        cleanup_pass = self.supervisor.cleanup_all()
        authoritative = dict(self.descendant_receipts)
        authoritative.update(self.adapter_receipts)
        self.cleanup_receipts = tuple(
            authoritative.get(receipt.process_key, receipt)
            for receipt in cleanup_pass
        )
        self.residue = self.supervisor.audit_residue()
        gone_debugservers = {
            entry.process_key
            for entry in getattr(self.residue, "entries", ())
            if (entry.role is supervision.ProcessRole.LOCAL_DEBUGSERVER
                and entry.absent
                and entry.state is supervision.InspectionState.GONE)
        }
        self.cleanup_receipts = tuple(
            replace(
                receipt,
                final_state=supervision.InspectionState.GONE,
                complete=True,
                detail="; ".join(filter(None, (
                    receipt.detail,
                    "final residue audit proved absence after exact SIGTERM",
                )))[:supervision.MAX_DETAIL_BYTES],
            )
            if (isinstance(receipt, supervision.CleanupReceipt)
                and not receipt.complete
                and receipt.role is supervision.ProcessRole.LOCAL_DEBUGSERVER
                and receipt.process_key in gone_debugservers
                and receipt.term_attempted and receipt.term_sent
                and receipt.identity_revalidated
                and receipt.stable_exact_descendant_chain
                and receipt.ownership_ancestor_revalidated
                and not receipt.refusal)
            else receipt
            for receipt in self.cleanup_receipts
        )
        self.closed = True

    def report(self) -> Mapping[str, object]:
        if not self.closed:
            raise RuntimeBridgeError("supervisor snapshot requested before candidate cleanup")
        residue = self.residue or self.supervisor.audit_residue()
        receipts_complete = supervision.cleanup_receipts_are_complete(
            self.registry, self.cleanup_receipts)
        if not receipts_complete or not residue.complete:
            diagnostic = _cleanup_failure_diagnostic(
                self.cleanup_receipts, residue,
                receipts_complete=receipts_complete)
            raise RuntimeBridgeError(
                "supervisor cleanup or residue evidence is incomplete: "
                + json.dumps(diagnostic, sort_keys=True, separators=(",", ":")))
        identities = [_identity_projection(item.identity)
                      for item in self.registry.registrations]
        registrations = {item.identity.role: item
                         for item in self.registry.registrations}
        return {
            "candidate": self.candidate,
            "mode": self.mode,
            "processRegistry": [
                {"role": _report_role(item.identity.role),
                 "identity": _identity_projection(item.identity)}
                for item in self.registry.registrations
            ],
            "cleanupReceipts": [
                _cleanup_projection(item, registrations) for item in self.cleanup_receipts
            ],
            "residueAudit": {
                "auditedIdentities": identities,
                "remainingIdentities": [],
                "complete": residue.complete,
                "evidence": {
                    "reinspection": "exactIdentity",
                    "registryDigest": hashlib.sha256(json.dumps(
                        identities, sort_keys=True, separators=(",", ":")
                    ).encode("utf-8")).hexdigest(),
                    "remainingCount": 0,
                },
            },
            "signingEvidence": [{
                "role": _report_role(item.identity.role),
                "signingIdentity": item.identity.signing_identity,
            } for item in self.registry.registrations],
        }


def _identity_projection(identity: object) -> Mapping[str, object]:
    return {
        "pid": identity.pid,
        "startTimeNS": identity.start_seconds * 1_000_000_000
            + identity.start_microseconds * 1_000,
        "realUID": identity.real_uid,
        "effectiveUID": identity.effective_uid,
        "canonicalPath": identity.canonical_path,
        "cpuType": identity.cpu_type,
        # Darwin exposes cpu_subtype_t as a signed int32, but capability bits
        # (for example arm64e's 0x81000002) are part of the unsigned wire value.
        "cpuSubtype": int(identity.cpu_subtype) & 0xFFFFFFFF,
        "executableIdentity": getattr(identity, "executable_identity", ""),
        "nonce": identity.nonce,
        "role": _report_role(identity.role),
        "device": identity.executable_device,
        "inode": identity.executable_inode,
        "machOUUID": identity.macho_uuid,
    }


def _report_role(role: object) -> str:
    return {
        supervision.ProcessRole.ADAPTER: "adapter",
        supervision.ProcessRole.LAUNCHED_TARGET: "target",
        supervision.ProcessRole.ATTACHED_HELPER: "helper",
        supervision.ProcessRole.LOCAL_DEBUGSERVER: "debugserver",
    }[role]


def _cleanup_projection(receipt: object,
                        registrations: Mapping[object, object]) -> Mapping[str, object]:
    registration = registrations[receipt.role]
    expected_identity = _identity_projection(registration.identity)
    observed_identity = (
        _identity_projection(receipt.observed_identity)
        if receipt.observed_identity is not None else None
    )
    action = ("terminate" if receipt.term_sent else
              "fixtureExit" if receipt.graceful_action == "fixtureExit" else
              "alreadyExited" if receipt.graceful_action in {"alreadyGone", "alreadyExited"}
              else "gracefulExit")
    ownership = None
    if receipt.role is supervision.ProcessRole.LOCAL_DEBUGSERVER:
        ownership = {
            "stableExactDescendantChain": receipt.stable_exact_descendant_chain,
            "adapterIdentityRevalidated": receipt.ownership_ancestor_revalidated,
            "ancestorIdentity": (
                _identity_projection(receipt.ownership_ancestor_identity)
                if receipt.ownership_ancestor_identity is not None else None
            ),
        }
    return {
        "role": _report_role(receipt.role),
        "expectedIdentity": expected_identity,
        "observedIdentity": observed_identity,
        "revalidated": receipt.identity_revalidated,
        "action": action,
        "terminalState": "gone" if receipt.final_state is supervision.InspectionState.GONE
                         else "exited",
        "complete": receipt.complete,
        "detail": receipt.detail or receipt.graceful_action or "exact cleanup complete",
        "ownershipEvidence": ownership,
    }


class _DAPLifecycle:
    def __init__(self, context: _Context): self.context = context
    def spawn_and_register(self, adapter: Path):
        return self.context.spawn_adapter((str(adapter),), stdin=subprocess.PIPE)
    def cleanup_adapter(self, registration):
        receipt = self.context.cleanup_adapter(registration)
        return {"role": "adapter", "registration": registration,
                "complete": receipt is not None and receipt.complete,
                "diagnostic": (_cleanup_receipt_diagnostic(receipt)
                               if receipt is not None else None)}
    def register_debugger_descendant(self, pid, path, nonce, registration,
                                     executable_identity=""):
        return self.context.register_debugger_descendant(
            pid, path, nonce, registration, executable_identity)


class _CLILifecycle:
    def __init__(self, context: _Context,
                 owner: Optional["WS18RunContext"] = None):
        self.context = context
        self.owner = owner

    def execute_and_cleanup(self, argv: Sequence[str], timeout: float):
        del argv, timeout
        raise RuntimeBridgeError(
            "one-shot LLDB CLI execution is retired; use the registered persistent session")
    def open_cli_session(self, argv: Sequence[str]):
        if (len(argv) != 2 or not os.path.isabs(argv[0])
                or argv[1] != "--no-lldbinit"):
            raise RuntimeBridgeError(
                "persistent CLI adapter must start in the frozen inert profile")
        process, registration = self.context.spawn_adapter(
            argv, stdin=subprocess.PIPE, stderr=subprocess.STDOUT)
        if process.stdin is None or process.stdout is None:
            self.context.cleanup_adapter(registration)
            raise RuntimeBridgeError("registered LLDB CLI process lacks required pipes")
        return cli_session.PipeCLIChannel(
            process.stdin, process.stdout, process.stderr, process=process,
        ), registration
    def close_cli_session(self, registration, timeout: float = 1.0):
        del timeout
        receipt = self.context.cleanup_adapter(registration)
        return {"role": "adapter", "registration": registration,
                "receipt": receipt, "complete": receipt.complete}
    def authorize_launch(self, executable: str, arguments: Sequence[str], cwd: str,
                         environment: Mapping[str, str]) -> Mapping[str, object]:
        owner = self.owner
        if owner is None or owner.mode != "launch":
            return {"authorized": False, "reason": "CLI launch has no run authority"}
        expected_arguments = tuple(str(value) for value in
                                   _argument(owner.arguments, "argument", ()))
        expected_cwd = str(Path(owner.authorization.path).parent.resolve())
        expected_environment = dict(_argument(owner.arguments, "environment", {}))
        if (os.path.realpath(executable) != owner.authorization.path
                or tuple(arguments) != expected_arguments
                or os.path.realpath(cwd) != expected_cwd
                or dict(environment) != expected_environment):
            return {"authorized": False,
                    "reason": "CLI launch configuration differs from frozen run authority"}
        return {"authorized": True, "nonce": owner.authorization.nonce,
                "launch": {"executable": owner.authorization.path,
                    "arguments": list(expected_arguments),
                    "workingDirectory": expected_cwd,
                    "environment": expected_environment}}
    def begin_launch_readiness(
            self, pid: int, authorization: Mapping[str, object],
            timeout: float) -> None:
        owner = self.owner
        if (owner is None or authorization.get("authorized") is not True
                or authorization.get("nonce") != owner.authorization.nonce):
            raise RuntimeBridgeError(
                "CLI launch readiness lacks exact run authority")
        owner._begin_cli_launch_readiness(pid, timeout)
    def accept_launch(self, pid: int, authorization: Mapping[str, object],
                      timeout: float) -> None:
        owner = self.owner
        if (owner is None or authorization.get("authorized") is not True
                or authorization.get("nonce") != owner.authorization.nonce):
            raise RuntimeBridgeError("CLI launch acceptance lacks exact run authority")
        owner._await_cli_launch_readiness(pid, timeout=timeout)
        owner._admit_launch_target(pid)
    def accept_launch_stop(
            self, pid: int, authorization: Mapping[str, object],
            timeout: float) -> Mapping[str, object]:
        owner = self.owner
        if (owner is None or authorization.get("authorized") is not True
                or authorization.get("nonce") != owner.authorization.nonce):
            raise RuntimeBridgeError(
                "CLI launch stop lacks exact run authority")
        return owner._accept_cli_launch_stop(pid, timeout)
    def register_debugger_descendant(self, pid, path, nonce, registration,
                                     executable_identity=""):
        return self.context.register_debugger_descendant(
            pid, path, nonce, registration, executable_identity)


class _PythonLifecycle:
    def __init__(self, context: _Context, owner: Optional["WS18RunContext"] = None):
        self.context = context
        self.owner = owner
    def spawn_and_register(self, argv, env):
        expected_script = os.path.realpath(str(HERE / "lldb_python_bridge.py"))
        if (len(argv) != 3 or not os.path.isabs(argv[0])
                or os.path.realpath(str(argv[1])) != expected_script
                or argv[2] != "--child"):
            raise RuntimeBridgeError(
                "Python adapter must start in the frozen inert child profile")
        return self.context.spawn_adapter(argv, stdin=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={**os.environ, **dict(env)})
    def cleanup_bridge(self, registration):
        receipt = self.context.cleanup_adapter(registration)
        return {"role": "adapter", "registration": registration,
                "complete": receipt is not None and receipt.complete,
                "diagnostic": (_cleanup_receipt_diagnostic(receipt)
                               if receipt is not None else None)}
    def accept_unpublished_launch_abort(self, protocol):
        if self.owner is None:
            raise RuntimeBridgeError(
                "Python lifecycle has no run-owned abort authority")
        self.owner.accept_unpublished_launch_abort(protocol)
    def register_debugger_descendant(self, pid, path, nonce, registration,
                                     executable_identity=""):
        return self.context.register_debugger_descendant(
            pid, path, nonce, registration, executable_identity)


def _explicit_lldb_pid(output: str) -> Optional[int]:
    values = {int(value) for value in re.findall(r"\bProcess\s+([1-9][0-9]*)\b", output)}
    return next(iter(values)) if len(values) == 1 else None


def _cleanup_receipt_diagnostic(receipt: object) -> Mapping[str, object]:
    return {
        "afterGracefulState": receipt.after_graceful_state.value,
        "detail": str(receipt.detail)[:supervision.MAX_DETAIL_BYTES],
        "finalState": receipt.final_state.value,
        "gracefulAcknowledged": receipt.graceful_acknowledged,
        "gracefulAction": receipt.graceful_action,
        "preActionState": receipt.pre_action_state.value,
        "termAttempted": receipt.term_attempted,
        "termSent": receipt.term_sent,
    }


def _cleanup_failure_diagnostic(
        receipts: Sequence[object], residue: object, *,
        receipts_complete: bool) -> Mapping[str, object]:
    """Bound the fail-closed cleanup reason without exposing process arguments."""
    receipt_items = []
    for receipt in tuple(receipts)[:32]:
        item = dict(_cleanup_receipt_diagnostic(receipt))
        item.update({
            "complete": bool(receipt.complete),
            "identityRevalidated": bool(receipt.identity_revalidated),
            "ownershipAncestorRevalidated": bool(
                receipt.ownership_ancestor_revalidated),
            "role": _report_role(receipt.role),
            "stableExactDescendantChain": bool(
                receipt.stable_exact_descendant_chain),
        })
        receipt_items.append(item)
    residue_entries = tuple(getattr(residue, "entries", ()))
    residue_items = [{
        "absent": bool(entry.absent),
        "detail": str(entry.detail)[:supervision.MAX_DETAIL_BYTES],
        "role": _report_role(entry.role),
        "state": entry.state.value,
    } for entry in residue_entries[:32]]
    return {
        "receiptCount": len(tuple(receipts)),
        "receipts": receipt_items,
        "receiptsComplete": receipts_complete,
        "residue": residue_items,
        "residueComplete": bool(getattr(residue, "complete", False)),
        "residueCount": len(residue_entries),
    }


_CANDIDATES = frozenset({
    "xcode-lldb-dap",
    "xcode-lldb-python-json",
    "macscope-lldb-cli-baseline",
})
_MODES = frozenset({"launch", "attach"})
_MISSING = object()


def _argument(arguments: object, name: str, default: object = _MISSING) -> object:
    if isinstance(arguments, Mapping):
        value = arguments.get(name, _MISSING)
    else:
        value = getattr(arguments, name, _MISSING)
    if value is _MISSING:
        if default is not _MISSING:
            return default
        raise RuntimeBridgeError("run context requires argument " + name)
    return value


@dataclass(frozen=True)
class _RunAuthorization:
    path: str
    nonce: str
    executable_identity: str
    macho_uuid: str
    signing_identity: str
    attached: bool
    exact_attach_target: Optional[drivers.ExactAttachTarget] = None

    def __post_init__(self) -> None:
        if (not self.path.startswith("/") or os.path.realpath(self.path) != self.path
                or not os.path.isfile(self.path)):
            raise RuntimeBridgeError("fixture path must be an existing canonical absolute file")
        if re.fullmatch(r"sha256:[0-9a-f]{64}", self.executable_identity) is None:
            raise RuntimeBridgeError("fixture executable identity must be canonical SHA-256")
        if re.fullmatch(
                r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}",
                self.macho_uuid) is None:
            raise RuntimeBridgeError("fixture Mach-O UUID is invalid")
        if self.signing_identity != APPROVED_FIXTURE_SIGNER:
            raise RuntimeBridgeError("fixture signing identity is not approved")
        if not self.nonce:
            raise RuntimeBridgeError("fixture nonce is required")
        if not self.attached and self.exact_attach_target is not None:
            raise RuntimeBridgeError("attach authorization shape is inconsistent")


class WS18RunContext:
    """One candidate/mode ownership domain for adapter, debuggee, and descendants."""

    def __init__(self, candidate: str, mode: str, arguments: object, *,
                 process_api: object, macho_reader: object, signing_reader: object,
                 process_factory: Callable[..., object] = subprocess.Popen,
                 fixture_launcher: Optional[Callable[..., object]] = None,
                 approved_fixture_signer: str = APPROVED_FIXTURE_SIGNER) -> None:
        if candidate not in _CANDIDATES:
            raise RuntimeBridgeError("unknown WS-18 candidate")
        if mode not in _MODES:
            raise RuntimeBridgeError("unknown WS-18 run mode")
        declared_mode = _argument(arguments, "command", mode)
        if declared_mode != mode:
            raise RuntimeBridgeError("run mode disagrees with parsed arguments")
        self.candidate = candidate
        self.mode = mode
        self.arguments = arguments
        self.control_dir = Path(str(_argument(arguments, "control_dir"))).resolve()
        if not self.control_dir.is_dir():
            raise RuntimeBridgeError("fixture control directory is unavailable")
        self.started_after_ns = int(_argument(arguments, "started_after_ns"))
        if self.started_after_ns <= 0:
            raise RuntimeBridgeError("fixture freshness threshold must be positive")
        if self.control_dir.stat().st_mtime_ns < self.started_after_ns:
            raise RuntimeBridgeError("fixture control directory predates this run")
        if any(self.control_dir.iterdir()):
            raise RuntimeBridgeError("fixture control directory must be fresh and empty")
        self.authorization = self._authorization(mode, arguments)
        self.context = _Context(
            candidate + "-" + mode,
            process_api,
            macho_reader,
            signing_reader,
            process_factory,
            approved_fixture_signer,
            self._fixture_exit,
        )
        self.context.candidate = candidate
        self.context.mode = mode
        self.context.fixture_path = self.authorization.path
        self._closed = False
        self._last_fact: Optional[RuntimeProcessFact] = None
        self._attach_target: Optional[drivers.ExactAttachTarget] = None
        self._launch_control: Optional[drivers.FixtureControlClient] = None
        self._launch_proven_pid: Optional[int] = None
        self._launch_start_ns: Optional[int] = None
        self._cli_launch_readiness_thread: Optional[threading.Thread] = None
        self._cli_launch_readiness_pid: Optional[int] = None
        self._cli_launch_readiness_timeout = 0.0
        self._cli_launch_readiness_error: Optional[BaseException] = None
        self._unpublished_launch_aborted = False
        self._fixture_launcher = fixture_launcher or process_factory

    def _begin_cli_launch_readiness(self, pid: int, timeout: float) -> None:
        """Open the fixture control peer while LLDB resumes the exact PID."""
        if self._closed or self.mode != "launch" or pid <= 0:
            raise RuntimeBridgeError(
                "CLI launch readiness requires one active launch authority")
        if (self._cli_launch_readiness_thread is not None
                or self._cli_launch_readiness_pid is not None):
            raise RuntimeBridgeError("CLI launch readiness is already active")
        proof_timeout = min(float(timeout), 30.0)
        if proof_timeout <= 0:
            raise RuntimeBridgeError("CLI launch readiness timeout must be positive")

        def prove() -> None:
            try:
                self._prove_launch_origin(pid, timeout=proof_timeout)
            except BaseException as error:
                self._cli_launch_readiness_error = error

        worker = threading.Thread(
            target=prove,
            name="MacScope-WS18-CLI-readiness-%d" % pid,
            daemon=False,
        )
        self._cli_launch_readiness_pid = pid
        self._cli_launch_readiness_timeout = proof_timeout
        self._cli_launch_readiness_error = None
        self._cli_launch_readiness_thread = worker
        try:
            worker.start()
        except BaseException:
            self._cli_launch_readiness_thread = None
            self._cli_launch_readiness_pid = None
            self._cli_launch_readiness_timeout = 0.0
            self._cli_launch_readiness_error = None
            raise

    def _await_cli_launch_readiness(
            self, pid: Optional[int] = None, *,
            timeout: Optional[float] = None) -> None:
        """Join the sole CLI proof worker before launch-state inspection."""
        worker = getattr(self, "_cli_launch_readiness_thread", None)
        expected_pid = getattr(self, "_cli_launch_readiness_pid", None)
        if worker is None:
            if pid is not None:
                raise RuntimeBridgeError("CLI launch readiness was not started")
            return
        if pid is not None and pid != expected_pid:
            raise RuntimeBridgeError("CLI launch readiness PID changed")
        proof_timeout = getattr(self, "_cli_launch_readiness_timeout", 0.0)
        requested_timeout = proof_timeout if timeout is None else float(timeout)
        join_timeout = max(proof_timeout, min(requested_timeout, 30.0)) + 0.5
        worker.join(timeout=join_timeout)
        if worker.is_alive():
            raise RuntimeBridgeError("CLI launch readiness worker exceeded its bound")
        error = getattr(self, "_cli_launch_readiness_error", None)
        if error is not None:
            raise error
        if (getattr(self, "_launch_proven_pid", None) != expected_pid
                or getattr(self, "_launch_start_ns", None) is None
                or getattr(self, "_launch_control", None) is None):
            raise RuntimeBridgeError(
                "CLI launch readiness completed without exact origin evidence")

    def _accept_cli_launch_stop(
            self, pid: int, timeout: float) -> Mapping[str, object]:
        """Stabilize and prove the already-admitted exact launch target stopped."""
        try:
            registration = self.context.registry.by_role(
                supervision.ProcessRole.LAUNCHED_TARGET)
        except KeyError as error:
            raise RuntimeBridgeError(
                "CLI launch stop has no admitted target") from error
        if registration.identity.pid != pid:
            raise RuntimeBridgeError("CLI launch stop PID changed")
        if not self.context.controller.send_signal(registration, signal.SIGSTOP):
            raise RuntimeBridgeError(
                "CLI launch exact SIGSTOP was refused")
        deadline = time.monotonic() + min(float(timeout), 30.0)
        last_error: Optional[BaseException] = None
        while time.monotonic() < deadline:
            try:
                before = self.context.inspector.capture(pid)
                info = self.context.process_api.bsd_info(pid)
                after = self.context.inspector.capture(pid)
                if (before.state is supervision.InspectionState.EXACT
                        and after.state is supervision.InspectionState.EXACT
                        and before.identity == registration.identity
                        and after.identity == registration.identity
                        and info.pid == pid
                        and info.status == DARWIN_PROCESS_STATUS_STOPPED):
                    return {"source": "run-owned-exact-sigstop-and-darwin-bsd-info",
                            "pid": pid, "status": info.status,
                            "identityStable": True}
            except BaseException as error:
                last_error = error
            time.sleep(0.01)
        detail = (": " + str(last_error)) if last_error is not None else ""
        raise RuntimeBridgeError(
            "CLI launch did not reach an exact stopped state" + detail)

    def _prove_launch_origin(self, pid: int, *, timeout: float = 5.0) -> None:
        """Prove fresh process-originated nonce/PID evidence before registration."""
        if self.mode != "launch":
            return
        proven_pid = getattr(self, "_launch_proven_pid", None)
        if proven_pid is not None:
            if proven_pid != pid:
                raise RuntimeBridgeError("launch protocol PID changed after origin proof")
            return
        before_info = self.context.process_api.bsd_info(pid)
        before_start = (before_info.start_seconds * 1_000_000_000
                        + before_info.start_microseconds * 1_000)
        if before_info.pid != pid or before_start < self.started_after_ns:
            raise RuntimeBridgeError("launch process predates this run")
        deadline = time.monotonic() + timeout
        client = drivers.FixtureControlClient(
            self.control_dir, "main", self.authorization.nonce, pid,
            minimum_event_mtime_ns=self.started_after_ns)
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeBridgeError("launch readiness deadline expired before control open")
            client.open(timeout=remaining)
            ready = None
            while time.monotonic() < deadline:
                ready = next((event for event in client._events()
                              if event.get("operation") == "ready"
                              and event.get("result") == "ok"), None)
                if ready is not None:
                    break
                time.sleep(0.01)
            if ready is None:
                raise RuntimeBridgeError(
                    "launch target did not publish nonce-correlated readiness evidence")
            after_info = self.context.process_api.bsd_info(pid)
            after_start = (after_info.start_seconds * 1_000_000_000
                           + after_info.start_microseconds * 1_000)
            if after_info.pid != pid or after_start != before_start:
                raise RuntimeBridgeError(
                    "launch process changed across readiness observation")
        except BaseException:
            client.close()
            raise
        self._launch_control = client
        self._launch_proven_pid = pid
        self._launch_start_ns = before_start

    def _admit_launch_target(self, pid: int) -> object:
        self._prove_launch_origin(pid)
        try:
            registration = self.context.ensure_target(
                pid, self.authorization.path, self.authorization.nonce, False,
                self.authorization.executable_identity,
                self._launch_start_ns)
        except BaseException:
            launch_control = getattr(self, "_launch_control", None)
            if launch_control is not None:
                launch_control.close()
                self._launch_control = None
            self._launch_proven_pid = None
            self._launch_start_ns = None
            raise
        return registration

    def _fixture_event_pid(self) -> Optional[int]:
        """Read one run-owned fixture PID from its securely created event stream."""
        role = "helper" if self.mode == "attach" else "main"
        path = self.control_dir / (role + ".events.jsonl")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags)
        except FileNotFoundError:
            return None
        try:
            metadata = os.fstat(descriptor)
            if (not stat.S_ISREG(metadata.st_mode)
                    or stat.S_IMODE(metadata.st_mode) != 0o600
                    or metadata.st_uid != os.geteuid()
                    or metadata.st_size > drivers.MAX_FIXTURE_EVENT_BYTES
                    or metadata.st_mtime_ns < self.started_after_ns):
                raise RuntimeBridgeError("fixture event stream ownership is invalid")
            raw = bytearray()
            while len(raw) <= drivers.MAX_FIXTURE_EVENT_BYTES:
                chunk = os.read(descriptor, min(
                    64 * 1024, drivers.MAX_FIXTURE_EVENT_BYTES + 1 - len(raw)))
                if not chunk:
                    break
                raw.extend(chunk)
            if len(raw) > drivers.MAX_FIXTURE_EVENT_BYTES:
                raise RuntimeBridgeError("fixture event stream exceeds configured bound")
            after = os.fstat(descriptor)
            if ((after.st_dev, after.st_ino) != (metadata.st_dev, metadata.st_ino)
                    or after.st_uid != metadata.st_uid):
                raise RuntimeBridgeError("fixture event stream identity changed during admission")
        finally:
            os.close(descriptor)
        events = []
        for line in bytes(raw).splitlines():
            if not line:
                continue
            try:
                event = json.loads(line)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise RuntimeBridgeError("fixture event stream is invalid JSONL") from error
            if (not isinstance(event, Mapping)
                    or event.get("schema") != drivers.FIXTURE_SCHEMA
                    or event.get("nonce") != self.authorization.nonce
                    or event.get("role") != role
                    or not isinstance(event.get("pid"), int)
                    or isinstance(event.get("pid"), bool)
                    or event.get("pid", 0) <= 0
                    or not isinstance(event.get("sequence"), int)
                    or isinstance(event.get("sequence"), bool)
                    or event.get("sequence", 0) <= 0):
                raise RuntimeBridgeError("fixture event stream identity is invalid")
            events.append(event)
        for previous, current in zip(events, events[1:]):
            if (current["sequence"] <= previous["sequence"]
                    or current["pid"] != previous["pid"]):
                raise RuntimeBridgeError("fixture event chronology is invalid")
        ready = [event for event in events
                 if event.get("operation") == "ready" and event.get("result") == "ok"]
        if len(ready) > 1:
            raise RuntimeBridgeError("fixture event stream has duplicate readiness evidence")
        return int(ready[0]["pid"]) if ready else None

    def reconcile_process_admission(self) -> None:
        """Admit exact fixture/debugger identities before a queued signal can escape."""
        if self._closed:
            raise RuntimeBridgeError("closed run cannot reconcile process admission")
        errors: list[BaseException] = []

        def registration(role):
            try:
                return self.context.registry.by_role(role)
            except KeyError:
                return None

        if self.mode == "launch":
            if getattr(self, "_cli_launch_readiness_thread", None) is not None:
                try:
                    self._await_cli_launch_readiness()
                except BaseException as error:
                    errors.append(error)
            proven_pid = getattr(self, "_launch_proven_pid", None)
            if (proven_pid is not None
                    and registration(supervision.ProcessRole.LAUNCHED_TARGET) is None):
                try:
                    self._admit_launch_target(proven_pid)
                except BaseException as error:
                    errors.append(error)
            admitted = registration(supervision.ProcessRole.LAUNCHED_TARGET)
            if admitted is not None:
                try:
                    self._prove_launch_origin(admitted.identity.pid)
                    snapshot = self.context.inspector.capture(admitted.identity.pid)
                    if (snapshot.state is not supervision.InspectionState.EXACT
                            or snapshot.identity != admitted.identity):
                        raise RuntimeBridgeError(
                            "launch target changed before signal replay")
                except BaseException as error:
                    errors.append(error)
        try:
            self.context.observe_debugger_descendants()
        except BaseException as error:
            errors.append(error)
        if (self.mode == "launch"
                and registration(supervision.ProcessRole.LAUNCHED_TARGET) is None):
            debugservers = tuple(
                item for item in self.context.registry.registrations
                if item.identity.role is supervision.ProcessRole.LOCAL_DEBUGSERVER)
            if len(debugservers) > 1:
                errors.append(RuntimeBridgeError(
                    "multiple registered debugservers cannot own one launch target"))
            elif debugservers:
                try:
                    registered = {item.identity.pid
                                  for item in self.context.registry.registrations}
                    children = tuple(
                        item for item in
                        self.context.child_enumerator.enumerate_debugserver_children(
                            debugservers[0], excluded_pids=registered)
                        if item.pid not in registered)
                    fixture_children = tuple(
                        item for item in children
                        if item.canonical_path == self.authorization.path)
                    if len(children) != len(fixture_children) or len(fixture_children) != 1:
                        raise RuntimeBridgeError(
                            "debugserver descendants do not prove one launch target")
                    self._admit_launch_target(fixture_children[0].pid)
                except BaseException as error:
                    errors.append(error)
        if (self.mode == "launch"
                and registration(supervision.ProcessRole.LAUNCHED_TARGET) is None
                and not getattr(self, "_unpublished_launch_aborted", False)):
            errors.append(RuntimeBridgeError(
                "launch target was not exactly admitted before signal replay"))
        if errors:
            primary = errors[0]
            if hasattr(primary, "add_note"):
                for error in errors[1:]:
                    primary.add_note(str(error))
            raise primary

    def accept_unpublished_launch_abort(
            self, protocol: Mapping[str, object]) -> None:
        """Accept only the Python bridge's exact terminal pre-admission proof."""
        cleanup = protocol.get("evidence")
        cleanup = cleanup.get("cleanup") if isinstance(cleanup, Mapping) else None
        valid = (
            not self._closed
            and self.candidate == "xcode-lldb-python-json"
            and self.mode == "launch"
            and protocol.get("operation") == "configuredLaunch"
            and protocol.get("ownership") == "none"
            and protocol.get("targetDisposition") == "exited"
            and protocol.get("result") == {}
            and isinstance(cleanup, Mapping)
            and cleanup.get("killRequested") is True
            and cleanup.get("complete") is True
            and cleanup.get("targetDisposition") == "exited"
        )
        if not valid:
            raise RuntimeBridgeError(
                "Python unpublished launch abort proof is incomplete")
        self._unpublished_launch_aborted = True

    @contextmanager
    def admission_boundary(self):
        """Defer parent termination through exact process admission and reconciliation."""
        with _defer_termination_signals():
            try:
                yield
            finally:
                self.reconcile_process_admission()

    @staticmethod
    def _authorization(mode: str, arguments: object) -> _RunAuthorization:
        if mode == "launch":
            path = os.path.realpath(str(_argument(arguments, "executable")))
            executable_identity = _argument(arguments, "executable_identity", None)
            executable_sha256 = _argument(arguments, "executable_sha256", None)
            if executable_identity is None:
                if not isinstance(executable_sha256, str):
                    raise RuntimeBridgeError(
                        "launch requires executable_identity or executable_sha256")
                executable_identity = "sha256:" + executable_sha256
            return _RunAuthorization(
                path,
                str(_argument(arguments, "nonce")),
                str(executable_identity),
                str(_argument(arguments, "macho_uuid")),
                str(_argument(arguments, "signing_identity")),
                False,
            )
        return _RunAuthorization(
            os.path.realpath(str(_argument(arguments, "helper"))),
            str(_argument(arguments, "nonce")),
            str(_argument(arguments, "executable_identity")),
            str(_argument(arguments, "macho_uuid")),
            str(_argument(arguments, "signing_identity")),
            True,
        )

    def prepare_attach_helper(
            self) -> tuple[drivers.ExactAttachTarget,
                           drivers.FixtureControlClient]:
        if self.mode != "attach":
            raise RuntimeBridgeError("launch run cannot prepare an attach helper")
        if self._closed:
            raise RuntimeBridgeError("closed run cannot prepare an attach helper")
        if self._attach_target is not None:
            raise RuntimeBridgeError("attach helper is already prepared")
        authorization = self.authorization
        registration = self.context.spawn_fixture(
            authorization.path, self.control_dir, authorization.nonce,
            self.started_after_ns, authorization.executable_identity,
            self._fixture_launcher)
        identity = registration.identity
        started = (identity.start_seconds * 1_000_000_000
                   + identity.start_microseconds * 1_000)
        if (started < self.started_after_ns
                or registration.initial_topology.session_id != identity.pid
                or getattr(identity, "executable_identity", "")
                    != authorization.executable_identity
                or identity.macho_uuid != authorization.macho_uuid
                or identity.signing_identity != authorization.signing_identity):
            self.close()
            raise RuntimeBridgeError(
                "spawned helper differs from fresh signed fixture authorization")
        client = drivers.FixtureControlClient(
            self.control_dir, "helper", authorization.nonce, identity.pid)
        try:
            client.open(timeout=5.0)
            deadline = time.monotonic() + 5.0
            ready = None
            while time.monotonic() < deadline:
                ready = next((event for event in client._events()
                              if event.get("operation") == "ready"
                              and event.get("result") == "ok"), None)
                if ready is not None and client.command_path.exists():
                    break
                time.sleep(0.01)
            if ready is None or not client.command_path.exists():
                raise RuntimeBridgeError(
                    "fresh helper did not publish bounded readiness evidence")
        except BaseException:
            try:
                client.close()
            finally:
                self.close()
            raise
        self._attach_target = drivers.ExactAttachTarget(
            identity.pid, started, identity.real_uid, identity.effective_uid,
            identity.canonical_path, identity.cpu_type, identity.cpu_subtype,
            identity.executable_identity, identity.executable_device,
            identity.executable_inode, identity.macho_uuid,
            identity.signing_identity, identity.nonce)
        return self._attach_target, client

    def lifecycle(self):
        if self._closed:
            raise RuntimeBridgeError("closed run context has no lifecycle")
        if self.candidate == "xcode-lldb-dap":
            return _DAPLifecycle(self.context)
        if self.candidate == "xcode-lldb-python-json":
            return _PythonLifecycle(self.context, self)
        return _CLILifecycle(self.context, self)

    def _candidate_lifecycle(self, candidate: str):
        if self.candidate != candidate:
            raise RuntimeBridgeError(
                "run context belongs to %s, not %s" % (self.candidate, candidate))
        return self.lifecycle()

    def make_dap_lifecycle(self):
        return self._candidate_lifecycle("xcode-lldb-dap")

    def make_python_lifecycle(self):
        return self._candidate_lifecycle("xcode-lldb-python-json")

    def make_cli_lifecycle(self):
        return self._candidate_lifecycle("macscope-lldb-cli-baseline")

    def python_attach_identity(self) -> Mapping[str, object]:
        target = self._attach_target
        if self.mode != "attach" or target is None:
            raise RuntimeBridgeError("attach helper has not been prepared")
        return {
            "pid": target.pid,
            "startTimeNS": target.startTimeNS,
            "realUID": target.realUID,
            "effectiveUID": target.effectiveUID,
            "canonicalPath": target.canonicalPath,
            "cpuType": target.cpuType,
            "cpuSubtype": target.cpuSubtype,
            "executableIdentity": target.executableIdentity,
            "executableDevice": target.executableDevice,
            "executableInode": target.executableInode,
            "machOUUID": target.machOUUID,
            "signingIdentity": target.signingIdentity,
            "nonce": target.nonce,
            "role": target.role,
        }

    def make_python_authority(self):
        self._candidate_lifecycle("xcode-lldb-python-json")
        module = python_bridge
        owner = self

        class ModeBoundAuthority(module.ExactFixtureAuthority):
            def authorize_launch(self, executable, arguments, cwd, environment):
                if owner.mode != "launch":
                    return {"authorized": False,
                            "reasonCode": "launchOutsideRunMode",
                            "reason": "attach run cannot authorize a launch"}
                return super().authorize_launch(
                    executable, arguments, cwd, environment)

            def authorize_attach(self, identity):
                if owner.mode != "attach":
                    return {"authorized": False,
                            "reasonCode": "attachOutsideRunMode",
                            "reason": "launch run cannot authorize an attach"}
                return super().authorize_attach(identity)

        launch_arguments = list(_argument(self.arguments, "argument", ()))
        working_directory = str(Path(self.authorization.path).parent.resolve())
        environment = dict(_argument(self.arguments, "environment", {}))
        allowed_launch = {
            "executable": self.authorization.path,
            "arguments": launch_arguments,
            "workingDirectory": working_directory,
            "environment": environment,
            "canonicalPath": self.authorization.path,
            "nonce": self.authorization.nonce,
            "role": "target",
        }
        allowed_attach = ([self.python_attach_identity()]
                          if self.mode == "attach" else [])
        return ModeBoundAuthority(
            allowed_launch=allowed_launch,
            allowed_attach_identities=allowed_attach,
            process_observer=self._python_process_observer,
            detach_observer=self._python_detach_observer,
        )

    def _python_process_observer(self, operation: str, pid: int,
                                 expected: Mapping[str, object]) -> Mapping[str, object]:
        expected_path = expected.get("canonicalPath")
        expected_nonce = expected.get("nonce")
        if (expected_path != self.authorization.path
                or expected_nonce != self.authorization.nonce):
            return {"identityMatched": False, "pid": pid,
                    "reasonCode": "runtimeAuthorizationMismatch"}
        fact = self.observe_process(pid, operation)
        return {"identityMatched": fact.identityMatched, "pid": fact.targetPID,
                "canonicalPath": fact.evidence["canonicalPath"],
                "nonce": fact.evidence["nonce"]}

    def _python_detach_observer(self, identity: Mapping[str, object],
                                pid: int) -> Mapping[str, object]:
        if (self.mode != "attach" or identity != self.python_attach_identity()
                or not self.revalidate(self._attach_target)):
            return {"sameIdentity": False, "alive": False,
                    "controllable": False, "checkpointSequence": 0, "pid": pid}
        client = drivers.FixtureControlClient(
            self.control_dir, "helper", self.authorization.nonce, pid)
        try:
            sequences = [event.get("commandSequence", 0)
                         for event in client._events()]
            client.next_command_sequence = max(sequences or [0]) + 1
            event = client.send("checkpoint", timeout=5.0)
            return {"sameIdentity": self.revalidate(
                        self._attach_target),
                    "alive": True, "controllable": True,
                    "checkpointSequence": int(event["commandSequence"]),
                    "pid": pid, "canonicalPath": self.authorization.path,
                    "nonce": self.authorization.nonce}
        except BaseException:
            return {"sameIdentity": False, "alive": False,
                    "controllable": False, "checkpointSequence": 0, "pid": pid}
        finally:
            client.close()

    def post_detach_probe(self, pid: int) -> Mapping[str, object]:
        target = self._attach_target
        if (self.mode != "attach" or target is None or pid != target.pid):
            return {"sameIdentity": False, "alive": False,
                    "controllable": False, "checkpointSequence": 0, "pid": pid}
        return self._python_detach_observer(self.python_attach_identity(), pid)

    def observe_process(self, protocol_pid: int,
                        operation: str = "process") -> RuntimeProcessFact:
        if self._closed:
            raise RuntimeBridgeError("closed run context cannot observe a process")
        if (not isinstance(protocol_pid, int) or isinstance(protocol_pid, bool)
                or protocol_pid <= 0):
            raise RuntimeBridgeError("protocol must prove one positive target PID")
        authorization = self.authorization
        if authorization.attached:
            registration = self.context.ensure_target(
                protocol_pid, authorization.path, authorization.nonce, True,
                authorization.executable_identity)
        else:
            registration = self._admit_launch_target(protocol_pid)
        identity = registration.identity
        matches = (
            identity.pid == protocol_pid
            and identity.canonical_path == authorization.path
            and getattr(identity, "executable_identity", "")
                == authorization.executable_identity
            and identity.macho_uuid == authorization.macho_uuid
            and identity.signing_identity == authorization.signing_identity
            and identity.nonce == authorization.nonce
        )
        if self._attach_target is not None:
            matches = matches and self.context.exact(
                protocol_pid, self._attach_target)
        elif authorization.attached:
            raise RuntimeBridgeError("attach helper has not been prepared")
        if not matches:
            raise RuntimeBridgeError("runtime process differs from frozen fixture identity")
        evidence = dict(_identity_projection(identity))
        evidence["signingIdentity"] = identity.signing_identity
        fact = RuntimeProcessFact(
            operation,
            protocol_pid,
            True,
            "exact registered target identity proven",
            evidence,
        )
        self._last_fact = fact
        return fact

    def revalidate(self, target: Optional[drivers.ExactAttachTarget] = None) -> bool:
        if self._closed:
            return False
        authorization = self.authorization
        if target is not None and target != self._attach_target:
            return False
        try:
            if authorization.attached:
                if self._attach_target is None:
                    return False
                registration = self.context.ensure_target(
                    self._attach_target.pid,
                    authorization.path,
                    authorization.nonce,
                    True,
                    authorization.executable_identity,
                )
                return self.context.exact(
                    registration.identity.pid, self._attach_target)
            if self._last_fact is None:
                return False
            return self.context.exact(self._last_fact.targetPID)
        except (RuntimeBridgeError, ValueError):
            return False

    def _fixture_exit(self, registration, timeout):
        role = "helper" if self.mode == "attach" else "main"
        launch_control = getattr(self, "_launch_control", None)
        client = (launch_control if self.mode == "launch"
                  and getattr(self, "_launch_proven_pid", None)
                      == registration.identity.pid
                  else None)
        if client is None:
            client = drivers.FixtureControlClient(
                self.control_dir, role, registration.identity.nonce,
                registration.identity.pid)
        try:
            sequences = [event.get("commandSequence", 0)
                         for event in client._events()]
            client.next_command_sequence = max(sequences or [0]) + 1
            client.send("exit", timeout=timeout)
            process = self.context.processes.get(registration.process_key)
            if process is not None:
                process.wait(timeout=timeout)
            return supervision.GracefulAction(True, True, "fixtureExit")
        except subprocess.TimeoutExpired as error:
            return supervision.GracefulAction(
                True, False, "fixtureExitTimedOut", str(error))
        except BaseException as error:
            return supervision.GracefulAction(
                True, False, "fixtureExitFailed", str(error))
        finally:
            client.close()
            if client is getattr(self, "_launch_control", None):
                self._launch_control = None

    def close(self) -> None:
        if not self._closed:
            readiness_error = None
            try:
                self._await_cli_launch_readiness()
            except BaseException as error:
                readiness_error = error
            cleanup_error = None
            try:
                self.context.cleanup()
            except BaseException as error:
                cleanup_error = error
            else:
                self._closed = True
            if readiness_error is not None:
                if cleanup_error is not None and hasattr(readiness_error, "add_note"):
                    readiness_error.add_note("cleanup: " + str(cleanup_error))
                raise readiness_error
            if cleanup_error is not None:
                raise cleanup_error

    def supervisor_snapshot(self) -> Mapping[str, object]:
        if not self._closed:
            raise RuntimeBridgeError("run context must close before supervisor snapshot")
        report = dict(self.context.report())
        report["cleanupComplete"] = True
        registrations = {item.identity.role: item
                         for item in self.context.registry.registrations}
        adapter = registrations.get(supervision.ProcessRole.ADAPTER)
        debuggee_role = (supervision.ProcessRole.ATTACHED_HELPER
                         if self.mode == "attach"
                         else supervision.ProcessRole.LAUNCHED_TARGET)
        debuggee = registrations.get(debuggee_role)
        metadata = {
            "adapterStartedInNewSession": bool(
                adapter is not None
                and adapter.initial_topology.session_id == adapter.identity.pid),
        }
        if self.mode == "attach":
            metadata.update({
                "helperStartedInNewSession": bool(
                    debuggee is not None
                    and debuggee.initial_topology.session_id == debuggee.identity.pid),
                "adapterHelperSessionsDistinct": bool(
                    adapter is not None and debuggee is not None
                    and adapter.initial_topology.session_id
                        != debuggee.initial_topology.session_id),
                "pidEvidenceSource": (
                    "adapter" if self._last_fact is not None
                    and debuggee is not None
                    and self._last_fact.targetPID == debuggee.identity.pid
                    else "unproven"),
            })
        report["metadata"] = metadata
        report["closed"] = True
        return report


def make_run_context(candidate: str, mode: str, arguments: object) -> WS18RunContext:
    """Create one live Darwin ownership domain; importing the module creates none."""

    runner = darwin.BoundedCommandRunner()
    return WS18RunContext(
        candidate,
        mode,
        arguments,
        process_api=darwin.DarwinLibprocAPI(),
        macho_reader=darwin.MachOIdentityReader(),
        signing_reader=darwin.CodesignIdentityReader(runner),
    )


class WS18RuntimeBridge:
    def __init__(self, *, process_api: object, macho_reader: object,
                 signing_reader: object, process_factory: Callable[..., object] = subprocess.Popen,
                 approved_fixture_signer: str = APPROVED_FIXTURE_SIGNER) -> None:
        self.process_api, self.macho_reader = process_api, macho_reader
        self.signing_reader, self.process_factory = signing_reader, process_factory
        self.approved_fixture_signer = approved_fixture_signer
        self.target_pid: Optional[int] = None
        self.target_path: Optional[str] = None
        self.target_nonce: Optional[str] = None
        self.target_executable_identity: Optional[str] = None
        self.target_attached = False
        self.control_dir: Optional[Path] = None
        self.launch_arguments: tuple[str, ...] = ()
        self.launch_cwd: Optional[str] = None
        self.launch_environment: dict[str, str] = {}
        self.attach_identity: Optional[dict[str, object]] = None
        self.dap_context = self._context("dap-adapter")
        self.cli_context = self._context("cli-adapter")
        self.python_context = self._context("python-adapter")
        self.dap_target_context = self._context("dap-target", fixture_exit=self._fixture_exit)
        self.cli_target_context = self._context("cli-target", fixture_exit=self._fixture_exit)
        self.python_target_context = self._context("python-target", fixture_exit=self._fixture_exit)
        self.attached_target_context = self._context(
            "shared-attached-fixture", fixture_exit=self._fixture_exit)
        self.mode = "unconfigured"

    def _context(self, owner: str, fixture_exit=None) -> _Context:
        return _Context(owner, self.process_api, self.macho_reader, self.signing_reader,
                        self.process_factory, self.approved_fixture_signer, fixture_exit)

    def configure(self, arguments: argparse.Namespace) -> None:
        self.mode = arguments.command
        for context in self._contexts():
            context.mode = self.mode
        if arguments.command == "attach":
            self.control_dir = arguments.control_dir
            self.attach_target(arguments.pid, str(arguments.path), arguments.nonce,
                               arguments.executable_identity)
            self.attach_identity = {"pid": arguments.pid,
                "startTimeNS": arguments.start_time_ns, "realUID": arguments.real_uid,
                "effectiveUID": arguments.effective_uid,
                "canonicalPath": str(arguments.path.resolve()), "cpuType": arguments.cpu_type,
                "cpuSubtype": arguments.cpu_subtype, "executableDevice": arguments.device,
                "executableInode": arguments.inode,
                "executableIdentity": arguments.executable_identity,
                "machOUUID": arguments.macho_uuid,
                "signingIdentity": arguments.signing_identity,
                "nonce": arguments.nonce, "role": "helper"}
        elif arguments.command == "launch":
            self.control_dir = arguments.control_dir
            self.launch_arguments = tuple(arguments.argument)
            self.launch_cwd = str(arguments.executable.parent.resolve())
            self.launch_target(str(arguments.executable), getattr(arguments, "nonce", ""),
                               getattr(arguments, "executable_identity", ""))

    def launch_target(self, path: str, nonce: str, executable_identity: str = "") -> None:
        if not nonce or not executable_identity:
            raise RuntimeBridgeError("fixture launch nonce and accepted executable identity are required")
        self.target_pid, self.target_path = None, os.path.realpath(path)
        self.target_nonce, self.target_attached = nonce, False
        self.target_executable_identity = executable_identity

    def attach_target(self, pid: int, path: str, nonce: str,
                      executable_identity: str) -> None:
        self.target_pid, self.target_path = pid, os.path.realpath(path)
        self.target_nonce, self.target_attached = nonce, True
        self.target_executable_identity = executable_identity

    def make_dap_lifecycle(self): return _DAPLifecycle(self.dap_context)
    def make_cli_lifecycle(self): return _CLILifecycle(self.cli_context)
    def make_python_lifecycle(self): return _PythonLifecycle(self.python_context)

    def make_python_authority(self):
        module = python_bridge
        allowed_launch = {"executable": self.target_path,
            "arguments": list(self.launch_arguments), "workingDirectory": self.launch_cwd,
            "environment": dict(self.launch_environment), "canonicalPath": self.target_path,
            "nonce": self.target_nonce, "role": "target"}
        identities = [self.attach_identity] if self.attach_identity is not None else []
        return module.ExactFixtureAuthority(allowed_launch=allowed_launch,
            allowed_attach_identities=identities,
            process_observer=self._python_process_observer,
            detach_observer=self._python_detach_observer)

    def _python_process_observer(self, operation, pid, expected):
        context = (self.attached_target_context if operation == "attach"
                   else self.python_target_context)
        registration = context.ensure_target(pid,
            str(expected["canonicalPath"]), str(expected["nonce"]),
            operation == "attach", str(expected.get("executableIdentity") or
                self.target_executable_identity or ""))
        return {"identityMatched": context.exact(pid), "pid": pid,
            "canonicalPath": registration.identity.canonical_path,
            "nonce": registration.identity.nonce}

    def _python_detach_observer(self, identity, pid):
        context = self.attached_target_context if self.target_attached else self.python_target_context
        registration = next((item for item in context.registry.registrations
                             if item.identity.pid == pid), None)
        if registration is None or self.control_dir is None:
            return {"sameIdentity": False, "alive": False, "controllable": False,
                    "checkpointSequence": 0, "pid": pid}
        client = drivers.FixtureControlClient(self.control_dir,
            "helper" if self.target_attached else "main", registration.identity.nonce, pid)
        try:
            sequences = [event.get("commandSequence", 0)
                         for event in client._events()]
            client.next_command_sequence = max(sequences or [0]) + 1
            event = client.send("checkpoint", timeout=5.0)
        except BaseException:
            return {"sameIdentity": False, "alive": False, "controllable": False,
                    "checkpointSequence": 0, "pid": pid}
        finally:
            client.close()
        return {"sameIdentity": context.exact(pid),
            "alive": True, "controllable": True,
            "checkpointSequence": int(event["commandSequence"]), "pid": pid,
            "canonicalPath": registration.identity.canonical_path,
            "nonce": registration.identity.nonce}

    def revalidate(self, target: drivers.ExactAttachTarget) -> bool:
        # Preflight does not register the helper into every candidate registry.
        # Each candidate admits it lazily only after that candidate proves a PID.
        context = self._context("preflight-target")
        context.mode = self.mode
        try:
            context.ensure_target(target.pid, target.canonicalPath, target.nonce, True,
                                  target.executableIdentity)
            return context.exact(target.pid, target)
        except (RuntimeBridgeError, ValueError):
            return False

    def _process_fact(self, operation: str, pid: Optional[int], *, candidate: str,
                      result=None) -> RuntimeProcessFact:
        actual_pid = pid or (_explicit_lldb_pid(result.stdout) if result is not None else self.target_pid)
        contexts = {"dap": self.dap_target_context, "cli": self.cli_target_context,
                    "python": self.python_target_context}
        context = self.attached_target_context if self.target_attached else contexts[candidate]
        if actual_pid is None or self.target_path is None or self.target_nonce is None:
            raise RuntimeBridgeError("debugger did not explicitly prove one target PID")
        if self.target_executable_identity is None:
            raise RuntimeBridgeError("accepted executable identity is unavailable")
        registration = context.ensure_target(actual_pid, self.target_path, self.target_nonce,
                                             self.target_attached,
                                             self.target_executable_identity)
        if not context.exact(actual_pid):
            raise RuntimeBridgeError("target identity changed at postcondition")
        evidence = dict(_identity_projection(registration.identity))
        return RuntimeProcessFact(operation, actual_pid, True,
            "exact registered target identity proven", evidence)

    def observe_dap(self, operation, acknowledgement, pid):
        del acknowledgement
        return self._process_fact(operation, pid, candidate="dap")
    def observe_cli(self, operation, result, pid):
        return self._process_fact(operation, pid, candidate="cli", result=result)

    def _contexts(self):
        return (self.dap_context, self.cli_context, self.python_context,
                self.dap_target_context, self.cli_target_context,
                self.python_target_context, self.attached_target_context)

    def close(self) -> None:
        for context in self._contexts():
            if context.registry.registrations and not context.cleanup_receipts:
                context.cleanup()

    def _fixture_exit(self, registration, timeout):
        if self.control_dir is None:
            return supervision.GracefulAction(False, False, "missingFixtureControl")
        client = drivers.FixtureControlClient(self.control_dir, "helper" if self.target_attached else "main",
                                              registration.identity.nonce, registration.identity.pid)
        try:
            sequences = [event.get("commandSequence", 0)
                         for event in client._events()]
            client.next_command_sequence = max(sequences or [0]) + 1
            client.send("exit", timeout=timeout)
            return supervision.GracefulAction(True, True, "fixtureExit")
        except BaseException as error:
            return supervision.GracefulAction(True, False, "fixtureExitFailed", str(error))
        finally:
            client.close()

    def supervisor_snapshot(self) -> Mapping[str, object]:
        contexts = [context.report() for context in self._contexts()
                    if context.registry.registrations]
        return {"cleanupComplete": True, "contexts": contexts}
