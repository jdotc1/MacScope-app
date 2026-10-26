from __future__ import annotations

from dataclasses import replace
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest

from Scripts.reconstruction import network_process_watch as watch


def event(pid=42, token=1, *, flags=0x20, fflags=watch.NOTE_EXEC, data=0, filter=-5):
    return SimpleNamespace(ident=pid, udata=token, filter=filter, flags=flags, fflags=fflags, data=data)


class Clock:
    def __init__(self): self.value = 100
    def __call__(self):
        self.value += 1
        return self.value


class Queue:
    def __init__(self):
        self.closed = False
        self.batches = []
        self.receipt = None
        self.registrations = []
    def control(self, changes, maximum, timeout):
        if changes:
            self.registrations.extend(changes)
            if isinstance(self.receipt, Exception): raise self.receipt
            if self.receipt is not None: return self.receipt
            request = changes[0]
            return [event(request.ident, request.udata, flags=watch.SUCCESS_RECEIPT_FLAGS, fflags=watch.EVENT_FFLAGS_MASK)]
        batch = self.batches.pop(0) if self.batches else []
        if isinstance(batch, Exception): raise batch
        return batch
    def close(self): self.closed = True


def registration_event(ident, *, filter, flags, fflags, udata):
    return SimpleNamespace(ident=ident, filter=filter, flags=flags,
                           fflags=fflags, udata=udata, data=0)


class ProcessWatchPortabilityTests(unittest.TestCase):
    def test_import_without_kqueue_and_live_collection_fails_closed(self):
        script = """
import select
import tempfile
from pathlib import Path
for name in ('kqueue', 'kevent'):
    if hasattr(select, name):
        delattr(select, name)
from Scripts.reconstruction import network_process_watch as watch
from Scripts.tests.test_network_process_watch import Clock, Queue, registration_event
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory).resolve()
    candidate, foreign = root / 'candidate', root / 'foreign'
    candidate.write_bytes(b'candidate')
    foreign.write_bytes(b'foreign')
    for options in ({}, {'queue_factory': Queue}, {'event_factory': registration_event}):
        try:
            watch.ProcessWatchCollector([str(candidate)], **options)
        except watch.ProcessWatchError:
            pass
        else:
            raise AssertionError('missing native capability admitted')
    clock = Clock()
    with watch.ProcessWatchCollector(
        [str(candidate)], queue_factory=Queue, event_factory=registration_event,
        path_probe=lambda pid: str(foreign), clock=clock,
    ) as collector:
        collector.arm([42])
        collector.observer_started(clock())
        collector.observer_eof(clock())
        result = collector.finalize([42])
        assert result.healthy and len(result.proofs) == 1
"""
        result = subprocess.run([sys.executable, "-c", script],
                                cwd=Path(__file__).resolve().parents[2],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class ProcessWatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.candidate, self.foreign = self.root / "candidate", self.root / "foreign"
        self.candidate.write_bytes(b"candidate")
        self.foreign.write_bytes(b"foreign")
        self.queue, self.clock = Queue(), Clock()
        self.path = str(self.foreign)
        self.collector = watch.ProcessWatchCollector(
            [str(self.candidate)], queue_factory=lambda: self.queue,
            event_factory=registration_event,
            path_probe=lambda pid: self.path, clock=self.clock,
        )
    def tearDown(self):
        self.collector.close()
        self.temp.cleanup()
    def observe(self):
        self.collector.observer_started(self.clock())
        self.collector.observer_eof(self.clock())
    def test_success_receipt_without_python_receipt_constant_and_closed_exact_dto(self):
        self.assertEqual(watch.EV_RECEIPT, 0x40)
        self.collector.arm([42]); self.observe()
        result = self.collector.finalize([42])
        self.assertTrue(result.healthy); self.assertTrue(self.queue.closed)
        proof, = result.proofs
        self.assertEqual(set(proof), {"proof_kind", "observation_id", "pid", "watch_token", "registration",
                                     "initial_probe", "final_probe", "initial_drain_id", "pre_final_drain_id", "post_final_drain_id"})
        self.assertEqual(proof["proof_kind"], "prearmed-kqueue-path-v1")
        self.assertEqual(proof["registration"]["receipt_errno"], 0)
        self.assertNotIn("start_time_unix_us", str(proof))
        self.assertEqual(len(result.drains), 3)
        self.assertTrue(all(d["completed_to_empty"] for d in result.drains))
        self.assertGreaterEqual(result.queue_closed_ns, result.drains[-1]["end_monotonic_ns"])
    def test_registration_errno_or_path_denial_cannot_prove_foreign(self):
        self.queue.receipt = [event(flags=watch.SUCCESS_RECEIPT_FLAGS, fflags=watch.EVENT_FFLAGS_MASK, data=1)]
        self.collector.arm([42]); self.observe()
        self.assertEqual(self.collector.finalize([42]).proofs, ())
    def test_path_probe_denial_keeps_watch_but_never_invents_start_identity(self):
        def denied(pid): raise PermissionError("protected")
        self.collector._probe = denied
        self.collector.arm([42]); self.observe()
        result = self.collector.finalize([42])
        self.assertFalse(result.proofs)
        self.assertEqual(result.diagnostics[0].code, "initial-path-unavailable-or-candidate")
    def test_missing_duplicate_mismatched_receipt_closes_queue(self):
        self.queue.receipt = [event(token=2, flags=watch.SUCCESS_RECEIPT_FLAGS, fflags=0)]
        with self.assertRaises(watch.ProcessWatchError): self.collector.arm([42])
        self.assertTrue(self.queue.closed)
    def test_duplicate_pid_is_never_registered_again(self):
        with self.assertRaises(watch.ProcessWatchError): self.collector.arm([42, 42])
        self.assertEqual(len(self.queue.registrations), 1)
        self.assertTrue(self.queue.closed)
    def test_no_retroactive_registration_after_spawn(self):
        self.collector.arm([42]); self.collector.observer_started(self.clock())
        with self.assertRaises(watch.ProcessWatchError): self.collector.arm([43])
        self.assertTrue(self.queue.closed)
    def test_exec_away_and_back_disqualifies_equal_final_path(self):
        self.collector.arm([42]); self.collector.observer_started(self.clock())
        self.queue.batches = [[event()], []]
        self.collector.drain(); self.collector.observer_eof(self.clock())
        result = self.collector.finalize([42])
        self.assertFalse(result.proofs); self.assertEqual(len(result.drains[1]["events"]), 1)
    def test_initial_pending_exit_disqualifies_reused_pid_without_replacement(self):
        self.queue.batches = [[event(flags=0x8031, fflags=watch.NOTE_EXIT)], []]
        self.collector.arm([42]); self.observe()
        self.assertFalse(self.collector.finalize([42]).proofs)
        self.assertEqual(len(self.queue.registrations), 1)
    def test_drain_reads_through_full_and_short_batches_until_actual_empty(self):
        self.collector._limits = replace(self.collector._limits, batch=1)
        self.collector.arm([42]); self.collector.observer_started(self.clock())
        self.queue.batches = [[event()], [event(fflags=watch.NOTE_EXIT)], []]
        drain = self.collector.drain()
        self.assertEqual(len(drain["events"]), 2); self.assertTrue(drain["completed_to_empty"])
        self.assertEqual(self.queue.batches, [])
    def test_pending_event_after_final_path_is_not_lost(self):
        self.collector.arm([42]); self.observe()
        self.queue.batches = [[], [event()], []]
        self.assertFalse(self.collector.finalize([42]).proofs)
    def test_queue_read_error_or_nonempty_bound_closes_queue(self):
        self.collector.arm([42]); self.collector.observer_started(self.clock())
        self.queue.batches = [OSError("read failure")]
        with self.assertRaisesRegex(watch.ProcessWatchError, "queue-read-failed"): self.collector.drain()
        self.assertTrue(self.queue.closed)
        self.assertFalse(self.collector.failure_snapshot().healthy)
        self.assertEqual(self.collector.failure_snapshot().proofs, ())
    def test_drain_bound_is_global_failure_not_short_batch_success(self):
        self.collector._limits = replace(self.collector._limits, reads_per_drain=1)
        self.queue.batches = [[event()]]
        with self.assertRaises(watch.ProcessWatchError): self.collector.arm([42])
        self.assertTrue(self.queue.closed)
    def test_candidate_path_hardlink_and_symlink_are_not_foreign(self):
        os.link(self.candidate, self.root / "hardlink")
        self.path = str(self.root / "hardlink")
        self.collector.arm([42]); self.observe()
        self.assertFalse(self.collector.finalize([42]).proofs)
    def test_final_path_mismatch_and_missing_prearm_never_prove_foreign(self):
        self.collector.arm([42]); self.observe()
        self.path = str(self.candidate)
        self.assertFalse(self.collector.finalize([42, 43]).proofs)
    def test_finalize_requires_explicit_eof_and_closes_on_misuse(self):
        self.collector.arm([42])
        with self.assertRaises(watch.ProcessWatchError): self.collector.finalize([42])
        self.assertTrue(self.queue.closed)
    def test_context_cancellation_closes_owned_queue(self):
        with self.assertRaises(RuntimeError):
            with self.collector:
                self.collector.arm([42]); raise RuntimeError("cancel")
        self.assertTrue(self.queue.closed)
    def test_unknown_event_flags_fail_globally_not_just_one_pid(self):
        self.collector.arm([42]); self.collector.observer_started(self.clock())
        self.queue.batches = [[event(flags=0x4000)], []]
        with self.assertRaisesRegex(watch.ProcessWatchError, "event-state-invalid"):
            self.collector.drain()
        self.assertTrue(self.queue.closed)
    def test_receipt_flag_echo_on_runtime_transition_is_retained(self):
        self.collector.arm([42]); self.observe()
        self.queue.batches = [[event(flags=0x8075, fflags=watch.EVENT_FFLAGS_MASK)], []]
        result = self.collector.finalize([42])
        self.assertFalse(result.proofs)
        self.assertEqual(result.drains[1]["events"][0]["flags"], 0x8075)
    def test_spawn_equality_is_rejected_before_healthy_publication(self):
        self.collector.arm([42])
        with self.assertRaises(watch.ProcessWatchError):
            self.collector.observer_started(self.collector._drains[-1]["end_monotonic_ns"])
        self.assertTrue(self.queue.closed)
    def test_eof_equality_is_rejected_before_healthy_publication(self):
        self.collector.arm([42]); spawn = self.clock()
        self.collector.observer_started(spawn)
        with self.assertRaises(watch.ProcessWatchError): self.collector.observer_eof(spawn)
        self.assertTrue(self.queue.closed)
    def test_queue_close_timestamp_overflow_or_equality_is_unhealthy(self):
        self.collector.arm([42])
        self.collector._clock = lambda: 2**63
        self.collector.close()
        self.assertIsNone(self.collector.failure_snapshot().queue_closed_ns)
        self.assertFalse(self.collector.failure_snapshot().healthy)
    def test_configured_limits_and_candidate_inventory_are_bounded(self):
        with self.assertRaises(ValueError): watch.WatchLimits(events=65537)
        with self.assertRaises(ValueError): watch.WatchLimits(batch=True)
        with self.assertRaises(watch.ProcessWatchError):
            watch.ProcessWatchCollector(iter([str(self.candidate)]))
    def test_missing_or_duplicate_registration_receipt_is_global_failure(self):
        self.queue.receipt = []
        with self.assertRaisesRegex(watch.ProcessWatchError, "receipt-count"):
            self.collector.arm([42])
        self.assertTrue(self.queue.closed)
    def test_symlinked_foreign_path_is_ineligible(self):
        alias = self.root / "alias"; alias.symlink_to(self.foreign)
        self.path = str(alias)
        self.collector.arm([42]); self.observe()
        self.assertFalse(self.collector.finalize([42]).proofs)
    def test_final_probe_path_error_is_unavailable_without_claiming_same_identity(self):
        self.collector.arm([42]); self.observe()
        self.collector._probe = lambda pid: (_ for _ in ()).throw(PermissionError())
        self.assertFalse(self.collector.finalize([42]).proofs)
    def test_success_result_does_not_expose_mutable_collector_drain_ledger(self):
        self.collector.arm([42]); self.observe()
        result = self.collector.finalize([42])
        result.drains[0]["events"].append({"changed": True})
        self.assertEqual(self.collector._drains[0]["events"], [])


@unittest.skipUnless(sys.platform == "darwin", "public kqueue is macOS-specific")
class NativeProcessWatchTests(unittest.TestCase):
    def candidate(self, root):
        path = root / "unrelated-candidate"; path.write_bytes(b"candidate")
        return str(path)
    def test_real_pipe_controlled_exec_exit_disqualifies_retained_token(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = self.candidate(Path(directory).resolve())
            child = subprocess.Popen([sys.executable, "-c",
                "import os,sys; print('ready',flush=True); sys.stdin.buffer.read(1); os.execv('/bin/sleep',['sleep','0.05'])"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.assertTrue(select.select([child.stdout], [], [], 5)[0])
                self.assertEqual(child.stdout.readline(), b"ready\n")
                with watch.ProcessWatchCollector([candidate]) as collector:
                    collector.arm([child.pid]); collector.observer_started(time.monotonic_ns())
                    child.stdin.write(b"x"); child.stdin.flush()
                    child.wait(timeout=5)
                    collector.drain(); collector.observer_eof(time.monotonic_ns())
                    result = collector.finalize([child.pid])
                    self.assertFalse(result.proofs)
                    self.assertTrue(any(e["fflags"] & (watch.NOTE_EXEC | watch.NOTE_EXIT)
                                        for d in result.drains for e in d["events"]))
            finally:
                if child.poll() is None: child.kill(); child.wait(timeout=5)
                for stream in (child.stdin, child.stdout, child.stderr): stream.close()
    def test_real_same_user_nonchild_and_pid1_path_only_watch(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = self.candidate(Path(directory).resolve())
            with watch.ProcessWatchCollector([candidate]) as collector:
                collector.arm([os.getppid(), 1]); collector.observer_started(time.monotonic_ns())
                collector.drain(); collector.observer_eof(time.monotonic_ns())
                result = collector.finalize([os.getppid(), 1])
                self.assertTrue(result.healthy)
                self.assertEqual({p["pid"] for p in result.proofs}, {os.getppid(), 1}, result.diagnostics)
                self.assertTrue(all("start_time_unix_us" not in str(p) for p in result.proofs))


if __name__ == "__main__": unittest.main()
