"""Synthetic nonnetwork children only; never real Gate F owner execution."""
import base64
from dataclasses import replace
import hashlib
import io
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

from Scripts.reconstruction_gate_f import command_execution as execution
from Scripts.reconstruction_gate_f import command_capture as capture
from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile, command_templates
from Scripts.reconstruction_gate_f.command_compiler import compile_command_plan
from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256, canonical_bytes
from Scripts.reconstruction_gate_f.runtime_resolution import ResolvedCommand, RuntimeResolution, resolve_command_record
from Scripts.reconstruction_gate_f.prerequisite_dag import LaneCIntegratedCommandPlanInput
from Scripts.reconstruction_gate_f.receipt_validator import CommandPrerequisiteExpectation, QualificationRunAuthority
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.tests import parsed_candidate
from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs


class CommandExecutionTests(unittest.TestCase):
    def test_bootstrap_verifier_admission_requires_independent_profile(self):
        import inspect
        self.assertIn("profile", inspect.signature(execution.admit_command).parameters,
                      "execution must accept the independently selected profile")
        from Scripts.reconstruction_gate_f.tests.bootstrap_repository_fixture import bootstrap_repository
        root, inputs = bootstrap_repository(self)
        inputs.update({name: str(self.root / name) for name in (
            "bootstrap_artifact_root", "bootstrap_admission_path",
            "bootstrap_fullsuite_artifact_root", "bootstrap_products_artifact_root")})
        profile = CampaignProfile.BOOTSTRAP_VERIFIER
        candidate = self.admission.candidate
        scenarios = compile_scenario_catalog(candidate)
        plan = compile_command_plan(candidate, scenarios, repository_root=root, inputs=inputs, profile=profile)
        integrated = LaneCIntegratedCommandPlanInput(plan, scenarios, root, inputs,
            {item.command_id: item for item in command_templates(profile=profile)})
        for record in plan.commands:
            if record.command_id not in {"qualification.verify-bootstrap-fullsuite", "qualification.verify-bootstrap-products"}:
                continue
            run = self.admission.qualification_run
            predecessors = tuple(CommandPrerequisiteExpectation(key, "receipt-" + str(index), "c" * 64,
                run.run_id, run.nonce) for index, key in enumerate(record.prerequisite_ids))
            admission = replace(self.admission, integrated_plan_input=integrated, admitted_predecessors=predecessors)
            scenario = record.scenario_ids[0]
            with patch("Scripts.reconstruction_gate_f.prerequisite_dag._repository_source_issues", return_value=()):
                admitted = execution.admit_command(admission, record.command_id, scenario, profile=profile)
                self.assertEqual(admitted.record, record)
                self.assertEqual(admitted.resolved_command.runtime_resolution.schema_version, 1)
                with self.assertRaises(execution.ExecutionError):
                    execution.admit_command(admission, record.command_id, scenario)
                for invalid in (replace(admission, admitted_predecessors=predecessors[1:]),
                                replace(admission, producer_source_commit="0" * 40)):
                    with self.assertRaises(execution.ExecutionError):
                        execution.admit_command(invalid, record.command_id, scenario, profile=profile)

    @classmethod
    def setUpClass(cls):
        candidate = parsed_candidate()
        inputs = command_inputs()
        scenarios = compile_scenario_catalog(candidate)
        plan = compile_command_plan(candidate, scenarios, repository_root=ROOT, inputs=inputs)
        cls.record = next(item for item in plan.commands if item.command_id == "installed.task10-workflow")
        run = QualificationRunAuthority(inputs["qualification_run_id"], inputs["qualification_run_nonce"])
        cls.admission = execution.ExecutionAdmission(candidate,
            LaneCIntegratedCommandPlanInput(plan, scenarios, ROOT, inputs, {item.command_id: item for item in command_templates()}),
            run, candidate.source.commit, candidate.source.tree,
            tuple(CommandPrerequisiteExpectation(key, "receipt-" + str(index), "c" * 64, run.run_id, run.nonce)
                  for index, key in enumerate(cls.record.prerequisite_ids)))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="capture-tests-", dir=os.environ.get("MACSCOPE_TEST_TEMP_ROOT"))
        # macOS tempfile commonly returns /var, an alias of /private/var.
        # Positive fixtures obey the production canonical-root requirement.
        self.root = Path(self.temp.name).resolve(strict=True)
        self.addCleanup(self.temp.cleanup)
        self.scenario = self.record.scenario_ids[0]

    def run_child(self, source, *, timeout=2, cancellation=None, environment=()):
        # Transport isolation only: synthetic argv replaces a record AFTER the
        # independent admission boundary is mocked. No production bypass API.
        record = replace(self.record, argv=(sys.executable, "-c", source), working_directory=str(self.root),
                         timeout_seconds=timeout, environment=environment)
        # The entire admission boundary is mocked for transport isolation only.
        resolved = ResolvedCommand(record, canonical_sha256(record), RuntimeResolution(1, (), canonical_sha256(record)))
        admitted = execution.AdmittedCommand(type("Projection", (), {"command_plan_sha256": "d" * 64})(), record, resolved)
        with patch.object(execution, "admit_command", return_value=admitted), \
             patch.object(execution, "TERM_GRACE_SECONDS", .15), \
             patch.object(execution, "KILL_GRACE_SECONDS", .2), \
             patch.object(execution, "FINAL_DRAIN_SECONDS", .1):
            result = execution.execute_admitted_command(self.admission, record.command_id, self.scenario,
                                                       capture_root=self.root, cancellation=cancellation)
        return result, capture.parse_capture(result.capture_path.read_bytes()).to_mapping()

    def test_binary_streams_and_immutable_capture(self):
        result, document = self.run_child("import os; os.write(1,b'\\x00\\xff{\"terminal\":true}'); os.write(2,b'err')")
        for stream, expected in (("stdout", b'\x00\xff{"terminal":true}'), ("stderr", b"err")):
            actual = b"".join(base64.b64decode(frame["data_base64"]) for frame in document["output_frames"] if frame["stream"] == stream)
            self.assertEqual(actual, expected)
        self.assertEqual(document["terminal"]["termination_kind"], "exited")
        self.assertEqual(document["terminal"]["exit_code"], 0)
        self.assertEqual(result.capture_sha256, hashlib.sha256(result.capture_path.read_bytes()).hexdigest())
        self.assertEqual(result.capture_path.stat().st_nlink, 1)
        self.assertFalse(list(self.root.glob("*.incomplete")))

    def test_prelaunch_prefix_and_environment_are_exact(self):
        original = subprocess.Popen
        def observed(*args, **kwargs):
            partials = list(self.root.glob("*.incomplete"))
            self.assertEqual(len(partials), 1)
            payload = partials[0].read_bytes()
            self.assertTrue(payload.startswith(b'{"intent":'))
            self.assertTrue(payload.endswith(b',"output_frames":['))
            self.assertNotIn("PYTHONPATH", kwargs["env"])
            self.assertNotIn("TOKEN", kwargs["env"])
            self.assertEqual(kwargs["env"]["LANG"], "C")
            self.assertFalse(kwargs["shell"])
            self.assertTrue(kwargs["start_new_session"])
            return original(*args, **kwargs)
        with patch.dict(os.environ, {"TOKEN": "synthetic", "PYTHONPATH": "/synthetic"}), patch.object(execution.subprocess, "Popen", side_effect=observed):
            result, document = self.run_child("print('ok')", environment=(("LANG", "C"),))
        self.assertEqual(dict(result.effective_environment)["LANG"], "C")
        self.assertEqual(document["intent"]["environment"], [["LANG", "C"]])

    def test_sync_failure_and_prelaunch_cancel_do_not_spawn(self):
        with patch.object(execution.os, "fsync", side_effect=OSError("synthetic sync")), patch.object(execution.subprocess, "Popen") as spawn:
            with self.assertRaises(execution.ExecutionError):
                self.run_child("pass")
            spawn.assert_not_called()
        event = threading.Event()
        event.set()
        with patch.object(execution.subprocess, "Popen") as spawn:
            with self.assertRaises(execution.ExecutionError):
                self.run_child("pass", cancellation=event)
            spawn.assert_not_called()
        for path in self.root.glob("*.incomplete"):
            with self.assertRaises(capture.CaptureError):
                capture.parse_capture(path.read_bytes())

    def test_launch_failure_is_not_launched_not_passed(self):
        with patch.object(execution.subprocess, "Popen", side_effect=OSError("synthetic spawn")):
            _, document = self.run_child("pass")
        self.assertEqual(document["terminal"]["termination_kind"], "launch-failed")
        self.assertEqual(document["process_observation"], {"state": "not-launched"})

    def test_timeout_and_signal_preserve_failure_cause(self):
        _, document = self.run_child("import time; time.sleep(10)", timeout=1)
        self.assertEqual(document["terminal"]["termination_kind"], "timed-out")
        self.assertEqual(document["terminal"]["signal"], signal.SIGTERM)

    def test_output_limit_and_term_ignoring_child_gets_killed(self):
        with patch.object(capture, "MAX_DECODED_BYTES", 4096):
            _, document = self.run_child("import os,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN)\nwhile True: os.write(1,b'x'*4096)")
        self.assertEqual(document["terminal"]["termination_kind"], "output-limit")
        self.assertEqual(document["terminal"]["signal"], signal.SIGKILL)
        self.assertLessEqual(document["terminal"]["stdout_length"], 4096)

    def test_cancellation_after_spawn_clean_exit_is_still_cancelled(self):
        event = threading.Event()
        ready = self.root / "ready"
        timer = threading.Thread(target=lambda: self._cancel_when_ready(ready, event))
        timer.start()
        try:
            _, document = self.run_child("import signal,time,pathlib; signal.signal(signal.SIGTERM,lambda *_:exit(0)); pathlib.Path('ready').touch(); time.sleep(10)", cancellation=event)
        finally:
            event.set()
            timer.join(timeout=2)
        self.assertEqual(document["terminal"]["termination_kind"], "cancelled")
        self.assertEqual(document["terminal"]["exit_code"], 0)

    @staticmethod
    def _cancel_when_ready(path, event):
        import time
        deadline = time.monotonic() + 2
        while not path.exists() and time.monotonic() < deadline and not event.wait(.01):
            pass
        event.set()

    def test_descendant_held_pipes_are_bounded_failure(self):
        # Grandchild self-terminates; parent intentionally cannot claim authority
        # over the numeric group after its leader has been reaped.
        with patch.object(execution.os, "killpg", wraps=os.killpg) as kill_group:
            with self.assertRaisesRegex(execution.ExecutionError, "descendant cleanup unproven"):
                self.run_child("import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time,pathlib; time.sleep(.3); pathlib.Path(\"done\").touch()'])")
            kill_group.assert_not_called()
        import time
        deadline = time.monotonic() + 2
        while not (self.root / "done").exists() and time.monotonic() < deadline:
            threading.Event().wait(.01)
        self.assertTrue((self.root / "done").exists())
        self.assertFalse(list(self.root.glob("*.json")))

    def test_full_compiler_admission_runs_and_rejects_forged_plan(self):
        # Only repository identity is synthetic; full compiler/catalog validation
        # and record equality checks run unchanged, with explicit limitation.
        with patch("Scripts.reconstruction_gate_f.prerequisite_dag._repository_source_issues", return_value=()):
            admitted = execution.admit_command(self.admission, self.record.command_id, self.scenario)
            self.assertEqual(admitted.record, self.record)
            changed = replace(self.record, argv=("/bin/true",))
            plan = self.admission.integrated_plan_input.plan
            forged = replace(plan, commands=tuple(changed if item.command_id == changed.command_id else item for item in plan.commands))
            admission = replace(self.admission, integrated_plan_input=replace(self.admission.integrated_plan_input, plan=forged))
            with self.assertRaises(execution.ExecutionError):
                execution.admit_command(admission, self.record.command_id, self.scenario)

    def test_real_compiled_scenario_less_supervision_is_command_scoped_only(self):
        record = next(item for item in self.admission.integrated_plan_input.plan.commands if item.command_id == "signed-xpc.supervision")
        self.assertEqual(record.scenario_ids, ())
        run = self.admission.qualification_run
        admission = replace(self.admission, admitted_predecessors=tuple(
            CommandPrerequisiteExpectation(key, "receipt-" + str(index), "c" * 64, run.run_id, run.nonce)
            for index, key in enumerate(record.prerequisite_ids)))
        with patch("Scripts.reconstruction_gate_f.prerequisite_dag._repository_source_issues", return_value=()):
            admitted = execution.admit_command(admission, record.command_id, record.command_id)
            self.assertEqual(admitted.record, record)
            with self.assertRaises(execution.ExecutionError):
                execution.admit_command(admission, record.command_id, "arbitrary-scenario")

    def test_real_source_guard_and_mismatched_context_fail(self):
        with self.assertRaises(execution.ExecutionError):
            execution.admit_command(self.admission, self.record.command_id, self.scenario)
        variants = (replace(self.admission, producer_source_commit="0" * 40),
                    replace(self.admission, qualification_run=QualificationRunAuthority("other-run", "b" * 64)),
                    replace(self.admission, admitted_predecessors=()))
        with patch("Scripts.reconstruction_gate_f.prerequisite_dag._repository_source_issues", return_value=()):
            for variant in variants:
                with self.subTest(admission=variant), self.assertRaises(execution.ExecutionError):
                    execution.admit_command(variant, self.record.command_id, self.scenario)

    def test_publication_collision_preserves_existing_target(self):
        token = "0" * 32
        final = self.root / ("capture-" + token + ".json")
        final.write_bytes(b"user data")
        with patch.object(execution.uuid, "uuid4", return_value=type("UUID", (), {"hex": token})()):
            with patch.object(execution.subprocess, "Popen") as spawn, self.assertRaises(execution.ExecutionError):
                self.run_child("pass")
            spawn.assert_not_called()
        self.assertEqual(final.read_bytes(), b"user data")

    def test_special_file_publication_targets_never_launch_or_overwrite(self):
        for kind in ("symlink", "hardlink", "fifo"):
            token = {"symlink": "1", "hardlink": "2", "fifo": "3"}[kind] * 32
            final = self.root / ("capture-" + token + ".json")
            retained = self.root / (kind + "-retained")
            retained.write_bytes(b"untouched")
            if kind == "symlink":
                final.symlink_to(retained)
            elif kind == "hardlink":
                os.link(retained, final)
            else:
                os.mkfifo(final)
            with self.subTest(kind=kind), patch.object(execution.uuid, "uuid4", return_value=type("UUID", (), {"hex": token})()), \
                    patch.object(execution.subprocess, "Popen") as spawn:
                with self.assertRaises(execution.ExecutionError):
                    self.run_child("pass")
                spawn.assert_not_called()
            self.assertEqual(retained.read_bytes(), b"untouched")
            self.assertTrue(final.exists())

    def test_link_source_substitution_is_detected_after_publication(self):
        link = os.link
        def substitute(source, destination, **kwargs):
            partial = self.root / source
            partial.rename(self.root / "retained-original")
            partial.write_bytes(b"substituted")
            return link(source, destination, **kwargs)
        with patch.object(execution.os, "link", side_effect=substitute):
            with self.assertRaisesRegex(execution.ExecutionError, "substituted capture"):
                self.run_child("print('genuine')")
        self.assertEqual(next(self.root.glob("*.json")).read_bytes(), b"substituted")
        capture.parse_capture((self.root / "retained-original").read_bytes())

    def test_output_write_failure_reaps_owned_child_and_closes_descriptors(self):
        real_spawn = subprocess.Popen
        real_write = execution._write_all
        processes = []
        calls = 0
        def spawn(*args, **kwargs):
            process = real_spawn(*args, **kwargs)
            processes.append(process)
            return process
        def fail_output(fd, payload):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("synthetic output write failure")
            real_write(fd, payload)
        with patch.object(execution.subprocess, "Popen", side_effect=spawn), patch.object(execution, "_write_all", side_effect=fail_output):
            with self.assertRaises(execution.ExecutionError):
                self.run_child("import os,time; os.write(1,b'x'); time.sleep(10)")
        self.assertEqual(len(processes), 1)
        self.assertIsNotNone(processes[0].poll())
        self.assertTrue(processes[0].stdout.closed)
        self.assertTrue(processes[0].stderr.closed)
        self.assertFalse(list(self.root.glob("*.json")))

    def test_double_wait_failure_still_closes_pipes_and_is_bounded_error(self):
        process = Mock(pid=123, stdout=io.BytesIO(), stderr=io.BytesIO())
        process.poll.return_value = None
        process.wait.side_effect = subprocess.TimeoutExpired("synthetic", 1)
        with patch.object(execution.os, "killpg") as kill_group:
            with self.assertRaisesRegex(execution.ExecutionError, "reap deadline"):
                execution._cleanup(process)
        self.assertEqual(process.wait.call_count, 2)
        self.assertEqual(kill_group.call_count, 2)
        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.stderr.closed)

    def test_reaped_process_never_signals_numeric_group(self):
        process = Mock(pid=123)
        process.poll.return_value = 0
        with patch.object(execution.os, "killpg") as kill_group:
            execution._signal_owned(process, signal.SIGKILL)
        kill_group.assert_not_called()

    def test_selector_setup_failure_closes_root_descriptor(self):
        before = len(os.listdir("/dev/fd"))
        with patch.object(execution.selectors, "DefaultSelector", side_effect=OSError("synthetic selector")):
            with self.assertRaises(execution.ExecutionError):
                self.run_child("pass")
        self.assertEqual(len(os.listdir("/dev/fd")), before)

    def test_alias_capture_root_is_rejected_before_launch(self):
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.root = alias
        with patch.object(execution.subprocess, "Popen") as spawn:
            with self.assertRaisesRegex(execution.ExecutionError, "canonical"):
                self.run_child("pass")
            spawn.assert_not_called()

    def test_final_sync_same_inode_mutation_is_not_returned(self):
        real_sync = os.fsync
        def mutate(fd):
            real_sync(fd)
            finals = list(self.root.glob("*.json"))
            if stat.S_ISDIR(os.fstat(fd).st_mode) and finals:
                finals[0].write_bytes(b"same inode mutated")
        with patch.object(execution.os, "fsync", side_effect=mutate):
            with self.assertRaisesRegex(execution.ExecutionError, "after synchronization"):
                self.run_child("pass")

    def test_final_sync_root_rebinding_is_not_returned(self):
        real_sync = os.fsync
        original = self.root
        retained = self.root.with_name(self.root.name + "-retained")
        def rebind(fd):
            real_sync(fd)
            if stat.S_ISDIR(os.fstat(fd).st_mode) and list(original.glob("*.json")):
                original.rename(retained)
                original.mkdir()
        try:
            with patch.object(execution.os, "fsync", side_effect=rebind):
                with self.assertRaisesRegex(execution.ExecutionError, "after synchronization"):
                    self.run_child("pass")
        finally:
            if retained.exists():
                original.rmdir()
                retained.rename(original)

    def test_simultaneous_stream_flood_is_drained_without_deadlock(self):
        _, document = self.run_child("import threading,os\ndef write(fd):\n for _ in range(16): os.write(fd,b'x'*65536)\na=threading.Thread(target=write,args=(1,)); b=threading.Thread(target=write,args=(2,)); a.start(); b.start(); a.join(); b.join()", timeout=5)
        self.assertEqual(document["terminal"]["stdout_length"], 1024 * 1024)
        self.assertEqual(document["terminal"]["stderr_length"], 1024 * 1024)
        self.assertEqual(document["terminal"]["exit_code"], 0)

    def stress_admission(self):
        inputs = dict(self.admission.integrated_plan_input.inputs)
        path = self.root / "predecessors.json"
        inputs["authority_stress_predecessor_observations"] = str(path)
        scenarios = self.admission.integrated_plan_input.scenario_catalog
        plan = compile_command_plan(self.admission.candidate, scenarios, repository_root=ROOT, inputs=inputs)
        record = next(item for item in plan.commands if item.command_id == "stress.reconstruction-authority-races")
        run = self.admission.qualification_run
        predecessors = tuple(CommandPrerequisiteExpectation(key, "receipt-" + str(index), "c" * 64,
            run.run_id, run.nonce) for index, key in enumerate(record.prerequisite_ids))
        admission = replace(self.admission, integrated_plan_input=replace(self.admission.integrated_plan_input,
            plan=plan, inputs=inputs), admitted_predecessors=predecessors)
        path.write_bytes(canonical_bytes([vars(item) for item in predecessors]))
        return admission, record, path

    def test_stress_static_file_has_exact_full_predecessor_mappings(self):
        admission, record, path = self.stress_admission()
        execution._validate_stress_predecessor_file(admission, record)
        original = path.read_bytes()
        for invalid in (original + b"\n", b"[]", b"x" * (execution.MAX_PREDECESSOR_FILE_BYTES + 1)):
            path.write_bytes(invalid)
            with self.assertRaises(execution.ExecutionError):
                execution._validate_stress_predecessor_file(admission, record)
        path.write_bytes(original)
        altered = replace(record, argv=tuple("/arbitrary" if arg == str(path) else arg for arg in record.argv))
        with self.assertRaises(execution.ExecutionError):
            execution._validate_stress_predecessor_file(admission, altered)

    def test_stress_predecessor_special_files_rejected_without_blocking(self):
        for kind in ("symlink", "hardlink", "fifo"):
            admission, record, path = self.stress_admission()
            retained = self.root / (kind + "-retained.json")
            path.rename(retained)
            if kind == "symlink":
                path.symlink_to(retained)
            elif kind == "hardlink":
                os.link(retained, path)
            else:
                os.mkfifo(path)
            try:
                with self.subTest(kind=kind), self.assertRaises(execution.ExecutionError):
                    execution._validate_stress_predecessor_file(admission, record)
            finally:
                path.unlink()

    def test_stress_file_rechecked_after_durable_intent_before_spawn(self):
        admission, record, path = self.stress_admission()
        real_sync = os.fsync
        def mutate(fd):
            real_sync(fd)
            path.write_bytes(b"[]")
        with patch("Scripts.reconstruction_gate_f.prerequisite_dag._repository_source_issues", return_value=()), \
                patch.object(execution.os, "fsync", side_effect=mutate), patch.object(execution.subprocess, "Popen") as spawn:
            with self.assertRaises(execution.ExecutionError):
                execution.execute_admitted_command(admission, record.command_id, record.scenario_ids[0], capture_root=self.root)
            spawn.assert_not_called()
        self.assertTrue(list(self.root.glob("*.incomplete")))

    def test_resolution_is_present_before_intent_is_durable_and_spawn_occurs(self):
        with patch("Scripts.reconstruction_gate_f.prerequisite_dag._repository_source_issues", return_value=()):
            admitted = execution.admit_command(self.admission, self.record.command_id, self.scenario)
        self.assertNotEqual(admitted.record.argv, admitted.resolved_command.record.argv)
        expected_argv = admitted.resolved_command.record.argv
        def observe(*args, **kwargs):
            self.assertEqual(args[0], expected_argv)
            prefix = next(self.root.glob("*.incomplete")).read_bytes()
            self.assertIn(canonical_bytes(list(expected_argv)), prefix)
            self.assertNotIn(b"@gatef-runtime:", prefix)
            self.assertIn(admitted.resolved_command.static_record_sha256.encode(), prefix)
            raise OSError("synthetic no real owner execution")
        with patch.object(execution, "admit_command", return_value=admitted), patch.object(execution.subprocess, "Popen", side_effect=observe) as spawn:
            result = execution.execute_admitted_command(self.admission, self.record.command_id, self.scenario, capture_root=self.root)
        spawn.assert_called_once()
        document = capture.parse_capture(result.capture_path.read_bytes()).to_mapping()
        self.assertEqual(document["schema_version"], 2)
        self.assertEqual(document["intent"]["command_record_sha256"], admitted.resolved_command.static_record_sha256)


if __name__ == "__main__":
    unittest.main()
