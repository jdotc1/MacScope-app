#!/usr/bin/env python3
"""Pure safety tests for the WS-18 outer process supervisor."""

from __future__ import annotations

import importlib.util
import signal
import sys
import unittest
from dataclasses import replace
from pathlib import Path
from typing import Dict, List


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "debugger-fixture"
    / "process_supervisor.py"
)
SPEC = importlib.util.spec_from_file_location("ws18_process_supervisor", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


ABASnapshotInspector = MODULE.ABASnapshotInspector
CleanupReceipt = MODULE.CleanupReceipt
DetachEvidence = MODULE.DetachEvidence
GracefulAction = MODULE.GracefulAction
ImmutableProcessIdentity = MODULE.ImmutableProcessIdentity
InspectionState = MODULE.InspectionState
OuterProcessSupervisor = MODULE.OuterProcessSupervisor
ProcessAnchor = MODULE.ProcessAnchor
ProcessRegistry = MODULE.ProcessRegistry
ProcessRole = MODULE.ProcessRole
ProcessSnapshot = MODULE.ProcessSnapshot
ProcessTopology = MODULE.ProcessTopology
cleanup_receipts_are_complete = MODULE.cleanup_receipts_are_complete
exact_descendant_ancestry = MODULE.exact_descendant_ancestry


def identity(
    pid: int,
    role: ProcessRole,
    *,
    parent: int = 1,
    nonce: str = "run-nonce",
    path: str | None = None,
) -> ImmutableProcessIdentity:
    del parent
    return ImmutableProcessIdentity(
        pid=pid,
        start_seconds=1_700_000_000 + pid,
        start_microseconds=pid % 1_000_000,
        canonical_path=path or f"/private/tmp/ws18/{role.value}-{pid}",
        executable_device=42,
        executable_inode=10_000 + pid,
        real_uid=501,
        effective_uid=501,
        cpu_type=0x0100000C,
        cpu_subtype=0,
        macho_uuid=f"00000000-0000-0000-0000-{pid:012d}",
        signing_identity="Apple Development: Test (TEAM)",
        nonce=nonce,
        role=role,
    )


def exact_snapshot(
    process: ImmutableProcessIdentity,
    *,
    parent_pid: int = 1,
    process_group: int | None = None,
    session_id: int | None = None,
) -> ProcessSnapshot:
    return ProcessSnapshot(
        InspectionState.EXACT,
        process,
        ProcessTopology(
            parent_pid,
            process_group if process_group is not None else process.pid,
            session_id if session_id is not None else process.pid,
        ),
    )


class FakeInspector:
    def __init__(self) -> None:
        self.current: Dict[int, ProcessSnapshot] = {}
        self.queued: Dict[int, List[ProcessSnapshot]] = {}
        self.calls: List[int] = []

    def set(self, snapshot: ProcessSnapshot) -> None:
        assert snapshot.identity is not None
        self.current[snapshot.identity.pid] = snapshot

    def queue(self, pid: int, *snapshots: ProcessSnapshot) -> None:
        self.queued.setdefault(pid, []).extend(snapshots)

    def capture(self, pid: int) -> ProcessSnapshot:
        self.calls.append(pid)
        queue = self.queued.get(pid, [])
        if queue:
            return queue.pop(0)
        return self.current.get(pid, ProcessSnapshot.gone("not present"))


class FakeController:
    def __init__(self) -> None:
        self.graceful: Dict[int, GracefulAction] = {}
        self.graceful_calls: List[int] = []
        self.signal_calls: List[tuple[int, int]] = []
        self.raise_graceful: Dict[int, BaseException] = {}
        self.raise_signal: Dict[int, BaseException] = {}
        self.signal_result = True

    def request_graceful(self, registration, timeout_seconds: float) -> GracefulAction:
        self.graceful_calls.append(registration.identity.pid)
        if registration.identity.pid in self.raise_graceful:
            raise self.raise_graceful[registration.identity.pid]
        return self.graceful.get(
            registration.identity.pid,
            GracefulAction(True, True, "gracefulExit"),
        )

    def send_signal(self, registration, signal_number: int) -> bool:
        self.signal_calls.append((registration.identity.pid, signal_number))
        if registration.identity.pid in self.raise_signal:
            raise self.raise_signal[registration.identity.pid]
        return self.signal_result


class FakeWaiter:
    def __init__(self) -> None:
        self.results: Dict[int, List[ProcessSnapshot]] = {}
        self.calls: List[int] = []

    def queue(self, pid: int, *results: ProcessSnapshot) -> None:
        self.results.setdefault(pid, []).extend(results)

    def wait_after_action(self, expected, timeout_seconds: float) -> ProcessSnapshot:
        self.calls.append(expected.pid)
        results = self.results.get(expected.pid, [])
        if not results:
            return exact_snapshot(expected)
        return results.pop(0)


class FakeSnapshotBackend:
    def __init__(self, process, topology) -> None:
        self.process = process
        self.topology = topology
        anchor = ProcessAnchor(
            process.pid, process.start_seconds, process.start_microseconds
        )
        self.anchors: List[object] = [anchor, anchor]

    def read_anchor(self, pid: int):
        result = self.anchors.pop(0)
        if isinstance(result, BaseException):
            raise result
        return result

    def read_identity_and_topology(self, pid: int):
        return self.process, self.topology


class ProcessSupervisorTests(unittest.TestCase):
    def make_registry(self, *processes: ImmutableProcessIdentity):
        inspector = FakeInspector()
        registry = ProcessRegistry("ws18-run-1", inspector)
        for process in processes:
            if process.role is ProcessRole.LOCAL_DEBUGSERVER:
                adapter = registry.by_role(ProcessRole.ADAPTER)
                inspector.set(exact_snapshot(
                    process, parent_pid=adapter.identity.pid))
                registry.register_debugserver(
                    process,
                    adapter_key=adapter.process_key,
                    ancestry=(
                        exact_snapshot(process, parent_pid=adapter.identity.pid),
                        exact_snapshot(adapter.identity, parent_pid=1),
                    ),
                )
            else:
                inspector.set(exact_snapshot(process))
                registry.register(process)
        return inspector, registry

    def test_generic_registration_rejects_debugserver_without_exact_ancestry(self):
        debugserver = identity(129, ProcessRole.LOCAL_DEBUGSERVER)
        inspector = FakeInspector()
        inspector.set(exact_snapshot(debugserver))
        registry = ProcessRegistry("ws18-run-1", inspector)

        with self.assertRaisesRegex(ValueError, "requires exact ancestry"):
            registry.register(debugserver)

    def make_supervisor(self, inspector, registry):
        controller = FakeController()
        waiter = FakeWaiter()
        return (
            OuterProcessSupervisor(registry, inspector, controller, waiter),
            controller,
            waiter,
        )

    def test_aba_capture_returns_exact_only_for_stable_complete_identity(self) -> None:
        process = identity(101, ProcessRole.ADAPTER)
        topology = ProcessTopology(1, 101, 101)
        inspector = ABASnapshotInspector(FakeSnapshotBackend(process, topology))

        snapshot = inspector.capture(101)

        self.assertEqual(snapshot.state, InspectionState.EXACT)
        self.assertEqual(snapshot.identity, process)
        self.assertEqual(snapshot.topology, topology)

    def test_aba_disappearance_after_first_anchor_is_unstable_not_gone(self) -> None:
        process = identity(102, ProcessRole.ADAPTER)
        backend = FakeSnapshotBackend(process, ProcessTopology(1, 102, 102))
        backend.anchors[1] = ProcessLookupError("reused or exited")

        snapshot = ABASnapshotInspector(backend).capture(102)

        self.assertEqual(snapshot.state, InspectionState.UNSTABLE)
        self.assertIn("during A-B-A", snapshot.detail)

    def test_only_initial_lookup_failure_proves_gone(self) -> None:
        process = identity(103, ProcessRole.ADAPTER)
        backend = FakeSnapshotBackend(process, ProcessTopology(1, 103, 103))
        backend.anchors[0] = ProcessLookupError("no such process")

        snapshot = ABASnapshotInspector(backend).capture(103)

        self.assertEqual(snapshot.state, InspectionState.GONE)

    def test_registry_records_owner_topology_revision_and_forbids_pid_or_role_reuse(self) -> None:
        adapter = identity(110, ProcessRole.ADAPTER)
        inspector, registry = self.make_registry(adapter)
        registration = registry.by_role(ProcessRole.ADAPTER)

        self.assertEqual(registration.owner, "ws18-run-1")
        self.assertEqual(registration.process_key, adapter.process_key)
        self.assertEqual(registration.topology_revision, 1)
        self.assertEqual(registry.revision, 1)

        same_pid = identity(110, ProcessRole.LAUNCHED_TARGET)
        inspector.set(exact_snapshot(same_pid))
        with self.assertRaisesRegex(ValueError, "reuse"):
            registry.register(same_pid)

        same_role = identity(111, ProcessRole.ADAPTER)
        inspector.set(exact_snapshot(same_role))
        with self.assertRaisesRegex(ValueError, "role reuse"):
            registry.register(same_role)

    def test_registration_refuses_identity_that_changed_before_capture(self) -> None:
        expected = identity(112, ProcessRole.ADAPTER)
        replacement = identity(112, ProcessRole.ADAPTER, nonce="other-run")
        inspector = FakeInspector()
        inspector.set(exact_snapshot(replacement))
        registry = ProcessRegistry("ws18-run-1", inspector)

        with self.assertRaisesRegex(ValueError, "exact A-B-A"):
            registry.register(expected)

    def test_debugserver_attribution_requires_contiguous_exact_adapter_ancestry(self) -> None:
        adapter = identity(120, ProcessRole.ADAPTER)
        debugserver = identity(121, ProcessRole.LOCAL_DEBUGSERVER)
        chain = [
            exact_snapshot(debugserver, parent_pid=adapter.pid),
            exact_snapshot(adapter, parent_pid=1),
        ]

        self.assertTrue(exact_descendant_ancestry(debugserver, adapter, chain))
        broken = [
            exact_snapshot(debugserver, parent_pid=999),
            exact_snapshot(adapter, parent_pid=1),
        ]
        self.assertFalse(exact_descendant_ancestry(debugserver, adapter, broken))

        suffixed = chain + [exact_snapshot(identity(124, ProcessRole.LAUNCHED_TARGET))]
        self.assertFalse(exact_descendant_ancestry(debugserver, adapter, suffixed))

    def test_debugserver_same_path_without_ancestry_is_not_owned(self) -> None:
        adapter = identity(122, ProcessRole.ADAPTER)
        debugserver = identity(
            123,
            ProcessRole.LOCAL_DEBUGSERVER,
            path="/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/debugserver",
        )
        unrelated = identity(999, ProcessRole.LAUNCHED_TARGET, path=debugserver.canonical_path)
        chain = [
            exact_snapshot(debugserver, parent_pid=unrelated.pid),
            exact_snapshot(unrelated, parent_pid=1),
        ]

        self.assertFalse(exact_descendant_ancestry(debugserver, adapter, chain))

    def test_graceful_exit_records_complete_receipt_without_signal(self) -> None:
        helper = identity(130, ProcessRole.ATTACHED_HELPER)
        inspector, registry = self.make_registry(helper)
        supervisor, controller, waiter = self.make_supervisor(inspector, registry)
        waiter.queue(helper.pid, ProcessSnapshot.gone("fixture exit acknowledged"))

        receipts = supervisor.cleanup_all()

        self.assertEqual(controller.graceful_calls, [helper.pid])
        self.assertEqual(controller.signal_calls, [])
        self.assertTrue(receipts[0].complete)
        self.assertEqual(receipts[0].final_state, InspectionState.GONE)
        self.assertEqual(receipts[0].observed_identity, helper)
        self.assertTrue(receipts[0].identity_revalidated)
        self.assertTrue(cleanup_receipts_are_complete(registry, receipts))

    def test_already_gone_receipt_retains_admission_identity_without_revalidation(self):
        helper = identity(131, ProcessRole.ATTACHED_HELPER)
        inspector, registry = self.make_registry(helper)
        supervisor, controller, _ = self.make_supervisor(inspector, registry)
        inspector.current[helper.pid] = ProcessSnapshot.gone("already exited")

        receipt = supervisor.cleanup_all()[0]

        self.assertTrue(receipt.complete)
        self.assertEqual(receipt.observed_identity, helper)
        self.assertFalse(receipt.identity_revalidated)
        self.assertEqual(controller.graceful_calls, [])
        self.assertTrue(cleanup_receipts_are_complete(registry, (receipt,)))

    def test_already_gone_receipt_uses_preserved_admission_observation(self):
        helper = identity(132, ProcessRole.ATTACHED_HELPER)
        inspector, registry = self.make_registry(helper)
        registration = registry.by_role(ProcessRole.ATTACHED_HELPER)
        supervisor, _, _ = self.make_supervisor(inspector, registry)
        inspector.current[helper.pid] = ProcessSnapshot.gone("already exited")

        receipt = supervisor.cleanup_all()[0]

        self.assertIs(
            receipt.observed_identity,
            registration.admission_snapshot.identity,
        )
        self.assertFalse(receipt.identity_revalidated)

    def test_debugserver_ownership_requires_fresh_exact_adapter_capture(self):
        adapter = identity(133, ProcessRole.ADAPTER)
        debugserver = identity(134, ProcessRole.LOCAL_DEBUGSERVER)
        inspector, registry = self.make_registry(adapter, debugserver)
        supervisor, _, waiter = self.make_supervisor(inspector, registry)
        replacement = identity(133, ProcessRole.ADAPTER, nonce="replacement")
        inspector.set(exact_snapshot(replacement))
        waiter.queue(debugserver.pid, ProcessSnapshot.gone("graceful exit"))

        receipt = supervisor._cleanup_one(
            registry.by_role(ProcessRole.LOCAL_DEBUGSERVER)
        )

        self.assertTrue(receipt.complete)
        self.assertTrue(receipt.stable_exact_descendant_chain)
        self.assertEqual(receipt.ownership_ancestor_identity, replacement)
        self.assertFalse(receipt.ownership_ancestor_revalidated)
        self.assertIn(adapter.pid, inspector.calls)

    def test_already_gone_debugger_chain_preserves_admitted_ownership(self):
        adapter = identity(136, ProcessRole.ADAPTER)
        debugserver = identity(137, ProcessRole.LOCAL_DEBUGSERVER)
        inspector, registry = self.make_registry(adapter, debugserver)
        supervisor, controller, _ = self.make_supervisor(inspector, registry)
        inspector.current[adapter.pid] = ProcessSnapshot.gone("adapter exited")
        inspector.current[debugserver.pid] = ProcessSnapshot.gone("debugserver exited")

        receipts = supervisor.cleanup_all()
        debugserver_receipt = next(
            item for item in receipts
            if item.role is ProcessRole.LOCAL_DEBUGSERVER)

        self.assertEqual(controller.signal_calls, [])
        self.assertTrue(debugserver_receipt.stable_exact_descendant_chain)
        self.assertEqual(
            debugserver_receipt.ownership_ancestor_identity, adapter)
        self.assertFalse(debugserver_receipt.ownership_ancestor_revalidated)
        self.assertTrue(cleanup_receipts_are_complete(registry, receipts))

        adapter_receipt = next(
            item for item in receipts if item.role is ProcessRole.ADAPTER)
        nonterminal_adapter = replace(
            adapter_receipt,
            pre_action_state=InspectionState.EXACT,
            graceful_action="gracefulExit",
            identity_revalidated=True,
        )
        self.assertFalse(cleanup_receipts_are_complete(
            registry,
            tuple(nonterminal_adapter if item.role is ProcessRole.ADAPTER else item
                  for item in receipts),
        ))

    def test_receipt_completeness_binds_role_owner_and_topology_revision(self):
        helper = identity(135, ProcessRole.ATTACHED_HELPER)
        inspector, registry = self.make_registry(helper)
        supervisor, _, waiter = self.make_supervisor(inspector, registry)
        waiter.queue(helper.pid, ProcessSnapshot.gone("graceful exit"))
        receipt = supervisor.cleanup_all()[0]

        self.assertFalse(cleanup_receipts_are_complete(
            registry, (replace(receipt, role=ProcessRole.ADAPTER),)))
        self.assertFalse(cleanup_receipts_are_complete(
            registry, (replace(receipt, owner="other-run"),)))
        self.assertFalse(cleanup_receipts_are_complete(
            registry, (replace(receipt, topology_revision=999),)))

    def test_cleanup_uses_role_safe_order_then_exact_sigterm_escalation(self) -> None:
        adapter = identity(140, ProcessRole.ADAPTER)
        target = identity(141, ProcessRole.LAUNCHED_TARGET)
        debugserver = identity(142, ProcessRole.LOCAL_DEBUGSERVER)
        inspector, registry = self.make_registry(adapter, target, debugserver)
        supervisor, controller, waiter = self.make_supervisor(inspector, registry)
        for process in (target, debugserver, adapter):
            waiter.queue(process.pid, exact_snapshot(process), ProcessSnapshot.gone("term"))

        receipts = supervisor.cleanup_all()

        self.assertEqual(controller.graceful_calls, [141, 142, 140])
        self.assertEqual(
            controller.signal_calls,
            [(141, signal.SIGTERM), (142, signal.SIGTERM), (140, signal.SIGTERM)],
        )
        self.assertTrue(all(receipt.complete for receipt in receipts))
        debugserver_receipt = next(
            item for item in receipts
            if item.role is ProcessRole.LOCAL_DEBUGSERVER)
        self.assertTrue(debugserver_receipt.stable_exact_descendant_chain)
        self.assertEqual(
            debugserver_receipt.ownership_ancestor_identity, adapter)
        self.assertTrue(debugserver_receipt.ownership_ancestor_revalidated)
        self.assertTrue(cleanup_receipts_are_complete(registry, receipts))

    def test_identity_mismatch_before_cleanup_never_calls_controller(self) -> None:
        helper = identity(150, ProcessRole.ATTACHED_HELPER)
        inspector, registry = self.make_registry(helper)
        replacement = identity(150, ProcessRole.ATTACHED_HELPER, nonce="unrelated")
        inspector.set(exact_snapshot(replacement))
        supervisor, controller, _ = self.make_supervisor(inspector, registry)

        receipt = supervisor.cleanup_all()[0]

        self.assertFalse(receipt.complete)
        self.assertIn("identity mismatch", receipt.refusal)
        self.assertEqual(receipt.observed_identity, replacement)
        self.assertFalse(receipt.identity_revalidated)
        self.assertEqual(controller.graceful_calls, [])
        self.assertEqual(controller.signal_calls, [])

    def test_pid_reuse_between_graceful_wait_and_term_refuses_signal(self) -> None:
        helper = identity(151, ProcessRole.ATTACHED_HELPER)
        inspector, registry = self.make_registry(helper)
        replacement = identity(151, ProcessRole.ATTACHED_HELPER, nonce="unrelated")
        supervisor, controller, waiter = self.make_supervisor(inspector, registry)
        waiter.queue(helper.pid, exact_snapshot(helper))
        inspector.queue(helper.pid, exact_snapshot(helper), exact_snapshot(replacement))

        receipt = supervisor.cleanup_all()[0]

        self.assertFalse(receipt.complete)
        self.assertIn("identity mismatch", receipt.refusal)
        self.assertEqual(controller.signal_calls, [])

    def test_uninspectable_pre_signal_state_refuses_escalation(self) -> None:
        target = identity(152, ProcessRole.LAUNCHED_TARGET)
        inspector, registry = self.make_registry(target)
        supervisor, controller, waiter = self.make_supervisor(inspector, registry)
        waiter.queue(target.pid, exact_snapshot(target))
        inspector.queue(
            target.pid,
            exact_snapshot(target),
            ProcessSnapshot(InspectionState.UNINSPECTABLE, detail="denied"),
        )

        receipt = supervisor.cleanup_all()[0]

        self.assertFalse(receipt.complete)
        self.assertEqual(receipt.final_state, InspectionState.UNINSPECTABLE)
        self.assertEqual(controller.signal_calls, [])

    def test_controller_exception_is_structured_and_cannot_skip_revalidation(self) -> None:
        adapter = identity(153, ProcessRole.ADAPTER)
        inspector, registry = self.make_registry(adapter)
        supervisor, controller, waiter = self.make_supervisor(inspector, registry)
        controller.raise_graceful[adapter.pid] = RuntimeError("adapter pipe broke")
        waiter.queue(adapter.pid, exact_snapshot(adapter), ProcessSnapshot.gone("term"))

        receipt = supervisor.cleanup_all()[0]

        self.assertTrue(receipt.complete)
        self.assertIn("adapter pipe broke", receipt.detail)
        self.assertEqual(controller.signal_calls, [(adapter.pid, signal.SIGTERM)])

    def test_semantic_detach_requires_pid_ack_same_identity_and_correlated_control(self) -> None:
        helper = identity(160, ProcessRole.ATTACHED_HELPER)
        inspector, registry = self.make_registry(helper)
        supervisor, _, _ = self.make_supervisor(inspector, registry)

        receipt = supervisor.prove_nonterminating_detach(
            helper.process_key,
            DetachEvidence(helper.pid, True, helper.nonce, 7, 8),
        )

        self.assertTrue(receipt.complete)
        self.assertTrue(receipt.helper_remained_alive)

        failed = supervisor.prove_nonterminating_detach(
            helper.process_key,
            DetachEvidence(helper.pid + 1, True, helper.nonce, 8, 8),
        )
        self.assertFalse(failed.complete)
        self.assertIn("PID proof", failed.detail)
        self.assertIn("nonce/sequence", failed.detail)

    def test_cleanup_success_does_not_change_failed_detach_receipt(self) -> None:
        helper = identity(161, ProcessRole.ATTACHED_HELPER)
        inspector, registry = self.make_registry(helper)
        supervisor, _, waiter = self.make_supervisor(inspector, registry)
        detach = supervisor.prove_nonterminating_detach(
            helper.process_key,
            DetachEvidence(helper.pid, False, helper.nonce, 1, 2),
        )
        waiter.queue(helper.pid, ProcessSnapshot.gone("emergency cleanup"))

        cleanup = supervisor.cleanup_all()

        self.assertFalse(detach.complete)
        self.assertTrue(cleanup[0].complete)

    def test_cleanup_is_idempotent_and_never_signals_twice(self) -> None:
        target = identity(170, ProcessRole.LAUNCHED_TARGET)
        inspector, registry = self.make_registry(target)
        supervisor, controller, waiter = self.make_supervisor(inspector, registry)
        waiter.queue(target.pid, exact_snapshot(target), ProcessSnapshot.gone("term"))

        first = supervisor.cleanup_all()
        second = supervisor.cleanup_all()

        self.assertEqual(first, second)
        self.assertEqual(controller.signal_calls, [(target.pid, signal.SIGTERM)])

    def test_residue_audit_requires_every_recorded_identity_to_be_absent(self) -> None:
        adapter = identity(180, ProcessRole.ADAPTER)
        helper = identity(181, ProcessRole.ATTACHED_HELPER)
        inspector, registry = self.make_registry(adapter, helper)
        supervisor, _, _ = self.make_supervisor(inspector, registry)
        inspector.current[adapter.pid] = ProcessSnapshot.gone("exited")

        audit = supervisor.audit_residue()

        self.assertFalse(audit.complete)
        self.assertEqual([entry.absent for entry in audit.entries], [True, False])

    def test_receipt_completeness_rejects_missing_duplicate_or_foreign_receipts(self) -> None:
        target = identity(190, ProcessRole.LAUNCHED_TARGET)
        inspector, registry = self.make_registry(target)
        supervisor, _, waiter = self.make_supervisor(inspector, registry)
        waiter.queue(target.pid, ProcessSnapshot.gone("done"))
        receipt = supervisor.cleanup_all()[0]

        self.assertFalse(cleanup_receipts_are_complete(registry, []))
        self.assertFalse(cleanup_receipts_are_complete(registry, [receipt, receipt]))
        incomplete = CleanupReceipt(
            receipt.process_key,
            receipt.role,
            receipt.owner,
            receipt.topology_revision,
            receipt.pre_action_state,
            receipt.graceful_action,
            receipt.graceful_acknowledged,
            receipt.after_graceful_state,
            receipt.term_attempted,
            receipt.term_sent,
            receipt.final_state,
            False,
        )
        self.assertFalse(cleanup_receipts_are_complete(registry, [incomplete]))


if __name__ == "__main__":
    unittest.main()
