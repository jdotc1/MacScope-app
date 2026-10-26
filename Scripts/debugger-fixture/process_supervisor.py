#!/usr/bin/env python3
"""Race-resistant supervision for WS-18 test-owned debugger processes.

This module deliberately contains no platform process-inspection implementation.
Live code must supply an inspector and controller; pure tests can therefore prove
every refusal path without ever signalling a host process.
"""

from __future__ import annotations

import signal
from dataclasses import dataclass
from enum import Enum
from typing import Dict, Iterable, List, Mapping, Optional, Protocol, Sequence, Tuple


MAX_DETAIL_BYTES = 4096


def _bounded(value: object) -> str:
    return str(value).encode("utf-8", errors="replace")[:MAX_DETAIL_BYTES].decode(
        "utf-8", errors="ignore"
    )


class ProcessRole(str, Enum):
    ADAPTER = "adapter"
    LAUNCHED_TARGET = "launchedTarget"
    ATTACHED_HELPER = "attachedHelper"
    LOCAL_DEBUGSERVER = "localDebugserver"


class InspectionState(str, Enum):
    EXACT = "exact"
    GONE = "gone"
    UNINSPECTABLE = "uninspectable"
    UNSTABLE = "unstableSnapshot"
    IDENTITY_MISMATCH = "identityMismatch"


@dataclass(frozen=True, order=True)
class ProcessKey:
    """Stable harness key; PID alone is intentionally insufficient."""

    pid: int
    start_seconds: int
    start_microseconds: int
    executable_device: int
    executable_inode: int


@dataclass(frozen=True)
class ImmutableProcessIdentity:
    pid: int
    start_seconds: int
    start_microseconds: int
    canonical_path: str
    executable_device: int
    executable_inode: int
    real_uid: int
    effective_uid: int
    cpu_type: int
    cpu_subtype: int
    macho_uuid: str
    signing_identity: str
    nonce: str
    role: ProcessRole

    def __post_init__(self) -> None:
        if self.pid <= 0:
            raise ValueError("PID must be positive")
        if self.start_seconds < 0 or not 0 <= self.start_microseconds < 1_000_000:
            raise ValueError("start identity is invalid")
        if not self.canonical_path.startswith("/"):
            raise ValueError("canonical executable path must be absolute")
        if self.executable_device < 0 or self.executable_inode <= 0:
            raise ValueError("executable device/inode identity is invalid")
        if self.real_uid < 0 or self.effective_uid < 0:
            raise ValueError("UID identity is invalid")
        if not self.nonce:
            raise ValueError("fixture nonce is required")

    @property
    def process_key(self) -> ProcessKey:
        return ProcessKey(
            self.pid,
            self.start_seconds,
            self.start_microseconds,
            self.executable_device,
            self.executable_inode,
        )


@dataclass(frozen=True)
class ProcessTopology:
    parent_pid: int
    process_group: int
    session_id: int
    traced: bool = False
    exited: bool = False


@dataclass(frozen=True)
class ProcessAnchor:
    pid: int
    start_seconds: int
    start_microseconds: int


@dataclass(frozen=True)
class ProcessSnapshot:
    state: InspectionState
    identity: Optional[ImmutableProcessIdentity] = None
    topology: Optional[ProcessTopology] = None
    detail: str = ""

    @classmethod
    def gone(cls, detail: str = "") -> "ProcessSnapshot":
        return cls(InspectionState.GONE, detail=_bounded(detail))


class SnapshotBackend(Protocol):
    def read_anchor(self, pid: int) -> ProcessAnchor:
        ...

    def read_identity_and_topology(
        self, pid: int
    ) -> Tuple[ImmutableProcessIdentity, ProcessTopology]:
        ...


class ABASnapshotInspector:
    """Capture A-B-A around all expensive identity inspection.

    Only failure of the first anchor read proves ``gone``. Once A exists, any
    short, denied, disappeared, or changed observation is fail-closed as
    uninspectable/unstable rather than being mistaken for clean process exit.
    """

    def __init__(self, backend: SnapshotBackend):
        self._backend = backend

    def capture(self, pid: int) -> ProcessSnapshot:
        try:
            before = self._backend.read_anchor(pid)
        except ProcessLookupError as error:
            return ProcessSnapshot.gone(error)
        except (PermissionError, OSError, RuntimeError, ValueError) as error:
            return ProcessSnapshot(InspectionState.UNINSPECTABLE, detail=_bounded(error))

        try:
            identity, topology = self._backend.read_identity_and_topology(pid)
            after = self._backend.read_anchor(pid)
        except (ProcessLookupError, PermissionError, OSError, RuntimeError, ValueError) as error:
            return ProcessSnapshot(
                InspectionState.UNSTABLE,
                detail=f"process changed or became uninspectable during A-B-A capture: {_bounded(error)}",
            )

        expected_anchor = ProcessAnchor(
            identity.pid, identity.start_seconds, identity.start_microseconds
        )
        if before != after or before != expected_anchor or identity.pid != pid:
            return ProcessSnapshot(
                InspectionState.UNSTABLE,
                identity,
                topology,
                "process identity changed during A-B-A capture",
            )
        return ProcessSnapshot(InspectionState.EXACT, identity, topology)


class ProcessInspector(Protocol):
    def capture(self, pid: int) -> ProcessSnapshot:
        ...


@dataclass(frozen=True)
class RegisteredProcess:
    process_key: ProcessKey
    identity: ImmutableProcessIdentity
    owner: str
    parent_key: Optional[ProcessKey]
    initial_topology: ProcessTopology
    topology_revision: int
    admission_snapshot: ProcessSnapshot
    admission_ancestry: Tuple[ProcessSnapshot, ...] = ()


class ProcessRegistry:
    """Append-only identity ledger for one WS-18 probe run."""

    def __init__(self, owner: str, inspector: ProcessInspector):
        if not owner:
            raise ValueError("run owner is required")
        self.owner = owner
        self._inspector = inspector
        self._by_key: Dict[ProcessKey, RegisteredProcess] = {}
        self._by_pid: Dict[int, ProcessKey] = {}
        self._by_role: Dict[ProcessRole, ProcessKey] = {}
        self._revision = 0

    @property
    def revision(self) -> int:
        return self._revision

    @property
    def registrations(self) -> Tuple[RegisteredProcess, ...]:
        return tuple(self._by_key.values())

    def lookup(self, key: ProcessKey) -> RegisteredProcess:
        try:
            return self._by_key[key]
        except KeyError as error:
            raise KeyError("process key is not registered") from error

    def by_role(self, role: ProcessRole) -> RegisteredProcess:
        return self.lookup(self._by_role[role])

    def register(
        self,
        identity: ImmutableProcessIdentity,
        *,
        parent_key: Optional[ProcessKey] = None,
    ) -> RegisteredProcess:
        if identity.role is ProcessRole.LOCAL_DEBUGSERVER:
            raise ValueError("debugserver registration requires exact ancestry")
        return self._register(identity, parent_key=parent_key)

    def _register(
        self,
        identity: ImmutableProcessIdentity,
        *,
        parent_key: Optional[ProcessKey] = None,
        admission_ancestry: Sequence[ProcessSnapshot] = (),
    ) -> RegisteredProcess:
        key = identity.process_key
        if key in self._by_key or identity.pid in self._by_pid:
            raise ValueError("PID/process identity reuse is forbidden")
        if identity.role in self._by_role:
            raise ValueError("process role reuse is forbidden")
        if parent_key is not None and parent_key not in self._by_key:
            raise ValueError("parent process must already be registered")

        snapshot = self._inspector.capture(identity.pid)
        if snapshot.state is not InspectionState.EXACT or snapshot.identity != identity:
            raise ValueError(
                f"registration requires exact A-B-A identity: {snapshot.state.value}"
            )
        assert snapshot.topology is not None
        if parent_key is not None:
            parent = self._by_key[parent_key]
            if snapshot.topology.parent_pid != parent.identity.pid:
                raise ValueError("registered parent does not match observed parentage")

        self._revision += 1
        registration = RegisteredProcess(
            key,
            identity,
            self.owner,
            parent_key,
            snapshot.topology,
            self._revision,
            snapshot,
            tuple(admission_ancestry),
        )
        self._by_key[key] = registration
        self._by_pid[identity.pid] = key
        self._by_role[identity.role] = key
        return registration

    def register_debugserver(
        self,
        identity: ImmutableProcessIdentity,
        *,
        adapter_key: ProcessKey,
        ancestry: Sequence[ProcessSnapshot],
    ) -> RegisteredProcess:
        if identity.role is not ProcessRole.LOCAL_DEBUGSERVER:
            raise ValueError("debugserver registration requires localDebugserver role")
        adapter = self.lookup(adapter_key)
        if adapter.identity.role is not ProcessRole.ADAPTER:
            raise ValueError("debugserver owner must be the registered adapter")
        if not exact_descendant_ancestry(identity, adapter.identity, ancestry):
            raise ValueError("debugserver attribution requires exact stable adapter ancestry")
        immediate_parent_pid = ancestry[0].topology.parent_pid if ancestry[0].topology else 0
        parent_key = self._by_pid.get(immediate_parent_pid)
        return self._register(
            identity,
            parent_key=parent_key,
            admission_ancestry=ancestry,
        )


def exact_descendant_ancestry(
    descendant: ImmutableProcessIdentity,
    ancestor: ImmutableProcessIdentity,
    ancestry: Sequence[ProcessSnapshot],
) -> bool:
    """Prove a contiguous child-to-ancestor identity chain.

    Basename or executable path is never considered ownership evidence.
    """

    if not ancestry or ancestry[0].identity != descendant:
        return False
    expected_pid = descendant.pid
    for index, snapshot in enumerate(ancestry):
        if (
            snapshot.state is not InspectionState.EXACT
            or snapshot.identity is None
            or snapshot.topology is None
            or snapshot.identity.pid != expected_pid
        ):
            return False
        if snapshot.identity == ancestor:
            return index == len(ancestry) - 1
        expected_pid = snapshot.topology.parent_pid
    return False


@dataclass(frozen=True)
class GracefulAction:
    requested: bool
    acknowledged: bool
    action: str
    detail: str = ""


class ProcessController(Protocol):
    def request_graceful(
        self, registration: RegisteredProcess, timeout_seconds: float
    ) -> GracefulAction:
        ...

    def send_signal(self, registration: RegisteredProcess, signal_number: int) -> bool:
        ...


class ProcessWaiter(Protocol):
    def wait_after_action(
        self,
        identity: ImmutableProcessIdentity,
        timeout_seconds: float,
    ) -> ProcessSnapshot:
        ...


@dataclass(frozen=True)
class DetachEvidence:
    adapter_proven_pid: int
    explicit_acknowledgement: bool
    fixture_nonce: str
    control_sequence_before: int
    control_sequence_after: int


@dataclass(frozen=True)
class DetachReceipt:
    process_key: ProcessKey
    acknowledged: bool
    identity_revalidated: bool
    control_correlated: bool
    helper_remained_alive: bool
    complete: bool
    detail: str = ""


@dataclass(frozen=True)
class CleanupReceipt:
    process_key: ProcessKey
    role: ProcessRole
    owner: str
    topology_revision: int
    pre_action_state: InspectionState
    graceful_action: str
    graceful_acknowledged: bool
    after_graceful_state: InspectionState
    term_attempted: bool
    term_sent: bool
    final_state: InspectionState
    complete: bool
    refusal: str = ""
    detail: str = ""
    observed_identity: Optional[ImmutableProcessIdentity] = None
    identity_revalidated: bool = False
    stable_exact_descendant_chain: bool = False
    ownership_ancestor_identity: Optional[ImmutableProcessIdentity] = None
    ownership_ancestor_revalidated: bool = False


@dataclass(frozen=True)
class ResidueEntry:
    process_key: ProcessKey
    role: ProcessRole
    state: InspectionState
    absent: bool
    detail: str = ""


@dataclass(frozen=True)
class ResidueAudit:
    entries: Tuple[ResidueEntry, ...]
    complete: bool


class OuterProcessSupervisor:
    """Adapter-independent, exact-identity cleanup owner.

    Cleanup is intentionally idempotent. It requests a role-appropriate graceful
    action, waits a bounded interval, and may escalate only to SIGTERM after a
    fresh exact identity capture immediately before the signal.
    """

    _CLEANUP_ORDER: Mapping[ProcessRole, int] = {
        ProcessRole.ATTACHED_HELPER: 10,
        ProcessRole.LAUNCHED_TARGET: 10,
        ProcessRole.LOCAL_DEBUGSERVER: 20,
        ProcessRole.ADAPTER: 30,
    }

    def __init__(
        self,
        registry: ProcessRegistry,
        inspector: ProcessInspector,
        controller: ProcessController,
        waiter: ProcessWaiter,
        *,
        graceful_timeout_seconds: float = 1.0,
        term_timeout_seconds: float = 1.0,
    ):
        if graceful_timeout_seconds <= 0 or term_timeout_seconds <= 0:
            raise ValueError("cleanup deadlines must be positive")
        self.registry = registry
        self._inspector = inspector
        self._controller = controller
        self._waiter = waiter
        self._graceful_timeout = graceful_timeout_seconds
        self._term_timeout = term_timeout_seconds
        self._receipts: Optional[Tuple[CleanupReceipt, ...]] = None

    def prove_nonterminating_detach(
        self, helper_key: ProcessKey, evidence: DetachEvidence
    ) -> DetachReceipt:
        registration = self.registry.lookup(helper_key)
        identity = registration.identity
        if identity.role is not ProcessRole.ATTACHED_HELPER:
            raise ValueError("detach proof applies only to the attached helper")

        snapshot = self._inspector.capture(identity.pid)
        identity_ok = (
            snapshot.state is InspectionState.EXACT and snapshot.identity == identity
        )
        control_ok = (
            evidence.fixture_nonce == identity.nonce
            and evidence.control_sequence_after > evidence.control_sequence_before
        )
        acknowledged = (
            evidence.explicit_acknowledgement
            and evidence.adapter_proven_pid == identity.pid
        )
        complete = acknowledged and identity_ok and control_ok
        problems: List[str] = []
        if not acknowledged:
            problems.append("detach acknowledgement/PID proof missing")
        if not identity_ok:
            problems.append("same immutable helper identity not alive after detach")
        if not control_ok:
            problems.append("post-detach fixture control response is not nonce/sequence correlated")
        return DetachReceipt(
            helper_key,
            acknowledged,
            identity_ok,
            control_ok,
            identity_ok,
            complete,
            "; ".join(problems),
        )

    def cleanup_all(self) -> Tuple[CleanupReceipt, ...]:
        if self._receipts is not None:
            return self._receipts
        ordered = sorted(
            self.registry.registrations,
            key=lambda item: (self._CLEANUP_ORDER[item.identity.role], item.topology_revision),
        )
        receipts = [self._cleanup_one(item) for item in ordered]
        self._receipts = tuple(receipts)
        return self._receipts

    def _cleanup_one(self, registration: RegisteredProcess) -> CleanupReceipt:
        expected = registration.identity
        pre = self._inspector.capture(expected.pid)
        if pre.state is InspectionState.GONE:
            return self._receipt(
                registration,
                pre,
                GracefulAction(False, False, "alreadyGone"),
                pre,
                False,
                False,
                pre,
                True,
            )
        refusal = self._refusal_for(pre, expected)
        if refusal:
            return self._receipt(
                registration,
                pre,
                GracefulAction(False, False, "refused"),
                pre,
                False,
                False,
                pre,
                False,
                refusal,
            )

        try:
            graceful = self._controller.request_graceful(
                registration, self._graceful_timeout
            )
        except BaseException as error:
            graceful = GracefulAction(False, False, "gracefulError", _bounded(error))
        try:
            after_graceful = self._waiter.wait_after_action(
                expected, self._graceful_timeout
            )
        except BaseException as error:
            after_graceful = ProcessSnapshot(
                InspectionState.UNINSPECTABLE, detail=_bounded(error)
            )
        if after_graceful.state is InspectionState.GONE:
            return self._receipt(
                registration,
                pre,
                graceful,
                after_graceful,
                False,
                False,
                after_graceful,
                True,
            )

        # Immediate pre-signal capture closes the PID-reuse race after the wait.
        pre_term = self._inspector.capture(expected.pid)
        refusal = self._refusal_for(pre_term, expected)
        if refusal:
            return self._receipt(
                registration,
                pre,
                graceful,
                after_graceful,
                False,
                False,
                pre_term,
                False,
                refusal,
            )

        term_sent = False
        detail = graceful.detail
        try:
            term_sent = self._controller.send_signal(registration, signal.SIGTERM)
        except BaseException as error:
            detail = "; ".join(filter(None, (detail, _bounded(error))))
        try:
            final = self._waiter.wait_after_action(expected, self._term_timeout)
        except BaseException as error:
            final = ProcessSnapshot(InspectionState.UNINSPECTABLE, detail=_bounded(error))
        complete = term_sent and final.state is InspectionState.GONE
        if not complete and not detail:
            detail = "SIGTERM did not prove exact process exit"
        return self._receipt(
            registration,
            pre,
            graceful,
            after_graceful,
            True,
            term_sent,
            final,
            complete,
            detail=detail,
        )

    @staticmethod
    def _refusal_for(
        snapshot: ProcessSnapshot, expected: ImmutableProcessIdentity
    ) -> str:
        if snapshot.state is not InspectionState.EXACT:
            return f"refused {snapshot.state.value} identity"
        if snapshot.identity != expected:
            return "refused immutable identity mismatch"
        return ""

    def _receipt(
        self,
        registration: RegisteredProcess,
        pre: ProcessSnapshot,
        graceful: GracefulAction,
        after_graceful: ProcessSnapshot,
        term_attempted: bool,
        term_sent: bool,
        final: ProcessSnapshot,
        complete: bool,
        refusal: str = "",
        detail: str = "",
    ) -> CleanupReceipt:
        combined_detail = "; ".join(
            item
            for item in (graceful.detail, after_graceful.detail, final.detail, detail)
            if item
        )
        exact_observations = tuple(
            snapshot.identity
            for snapshot in (final, after_graceful, pre)
            if snapshot.state is InspectionState.EXACT
            and snapshot.identity is not None
        )
        already_gone = (
            pre.state is InspectionState.GONE
            and after_graceful.state is InspectionState.GONE
            and final.state is InspectionState.GONE
            and graceful.action == "alreadyGone"
            and not term_attempted
            and not term_sent
        )
        observed_identity = exact_observations[0] if exact_observations else (
            registration.admission_snapshot.identity if already_gone else None
        )
        identity_revalidated = any(
            identity == registration.identity for identity in exact_observations
        )
        stable_ancestry, ownership_ancestor, ownership_revalidated = (
            self._debugserver_ownership_evidence(registration)
        )
        return CleanupReceipt(
            registration.process_key,
            registration.identity.role,
            registration.owner,
            registration.topology_revision,
            pre.state,
            graceful.action,
            graceful.acknowledged,
            after_graceful.state,
            term_attempted,
            term_sent,
            final.state,
            complete,
            refusal,
            _bounded(combined_detail),
            observed_identity,
            identity_revalidated,
            stable_ancestry,
            ownership_ancestor,
            ownership_revalidated,
        )

    def _debugserver_ownership_evidence(
        self, registration: RegisteredProcess
    ) -> Tuple[bool, Optional[ImmutableProcessIdentity], bool]:
        if registration.identity.role is not ProcessRole.LOCAL_DEBUGSERVER:
            return False, None, False
        ancestry = registration.admission_ancestry
        if not ancestry or ancestry[-1].identity is None:
            return False, None, False
        admitted_ancestor = ancestry[-1].identity
        stable_ancestry = exact_descendant_ancestry(
            registration.identity, admitted_ancestor, ancestry
        )
        if not stable_ancestry or admitted_ancestor.role is not ProcessRole.ADAPTER:
            return False, admitted_ancestor, False
        observed_ancestor = self._inspector.capture(admitted_ancestor.pid)
        if observed_ancestor.identity is not None:
            ancestor_identity = observed_ancestor.identity
        else:
            # Retain the exact admission-time ancestor when both processes have
            # already exited.  `revalidated` remains false unless this capture
            # independently observes the same live immutable identity.
            ancestor_identity = admitted_ancestor
        revalidated = (
            observed_ancestor.state is InspectionState.EXACT
            and ancestor_identity == admitted_ancestor
        )
        return True, ancestor_identity, revalidated

    def audit_residue(self) -> ResidueAudit:
        entries: List[ResidueEntry] = []
        for registration in self.registry.registrations:
            snapshot = self._inspector.capture(registration.identity.pid)
            absent = snapshot.state is InspectionState.GONE
            entries.append(
                ResidueEntry(
                    registration.process_key,
                    registration.identity.role,
                    snapshot.state,
                    absent,
                    _bounded(snapshot.detail),
                )
            )
        return ResidueAudit(tuple(entries), all(item.absent for item in entries))


def cleanup_receipts_are_complete(
    registry: ProcessRegistry, receipts: Iterable[CleanupReceipt]
) -> bool:
    """Reject missing, duplicate, foreign, or incomplete cleanup receipts."""

    receipt_list = list(receipts)
    registrations = {item.process_key: item for item in registry.registrations}
    adapters = [
        item for item in registry.registrations
        if item.identity.role is ProcessRole.ADAPTER
    ]
    adapter_identity = adapters[0].identity if len(adapters) == 1 else None
    adapter_receipts = [
        item for item in receipt_list if item.role is ProcessRole.ADAPTER
    ]

    def already_gone(item: CleanupReceipt) -> bool:
        return (
            item.complete
            and item.pre_action_state is InspectionState.GONE
            and item.graceful_action == "alreadyGone"
            and item.after_graceful_state is InspectionState.GONE
            and not item.term_attempted
            and not item.term_sent
            and item.final_state is InspectionState.GONE
        )

    terminal_adapter_chain = (
        len(adapter_receipts) == 1 and already_gone(adapter_receipts[0])
    )
    expected = set(registrations)
    observed = [item.process_key for item in receipt_list]
    return (
        len(observed) == len(set(observed))
        and set(observed) == expected
        and all(
            item.complete
            and item.role is registrations[item.process_key].identity.role
            and item.owner == registrations[item.process_key].owner
            and item.topology_revision == registrations[item.process_key].topology_revision
            and item.observed_identity == registrations[item.process_key].identity
            and (
                item.identity_revalidated
                or already_gone(item)
            )
            and (
                item.role is not ProcessRole.LOCAL_DEBUGSERVER
                or (
                    item.stable_exact_descendant_chain
                    and item.ownership_ancestor_identity == adapter_identity
                    and (
                        item.ownership_ancestor_revalidated
                        or (already_gone(item) and terminal_adapter_chain)
                    )
                )
            )
            for item in receipt_list
        )
    )
