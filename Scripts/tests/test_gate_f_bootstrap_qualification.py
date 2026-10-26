"""Portable source admission and real synthetic child observations; no native builds."""
import ast
import base64
from dataclasses import replace
import hashlib
import copy
import json
import os
from pathlib import Path
import shutil
import plistlib
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from Scripts.reconstruction_gate_f import bootstrap_qualification as bootstrap
from Scripts.reconstruction_gate_f import command_execution as transport
from Scripts.reconstruction_gate_f import command_capture as capture
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes, decode_canonical_bytes
from Scripts.reconstruction_gate_f.receipt_validator import QualificationRunAuthority
from Scripts.reconstruction_gate_f.schema import parse_candidate_identity, candidate_to_mapping
from Scripts.reconstruction_gate_f.tests import candidate_mapping
from Scripts.tests.test_qualification_product_identity import QualificationBuildFixture, canonical_line
from Scripts.tests.test_sleigh_native_package import SleighPackageFixture, sleigh_package
from Scripts.qualification.restore_build_source import GENERATED_PROJECT_FILES, _generated_project_identity
from Scripts.reconstruction_gate_f.tests import test_qualification_artifact_validator as full_suite_fixtures
from Scripts.lib.work_root import existing_work_root, work_root as macscope_work_root


class BootstrapQualificationTests(unittest.TestCase):
    def setUp(self):
        base = os.environ.get("MACSCOPE_TEST_TEMP_ROOT")
        if base is None and existing_work_root() is not None:
            base = str(existing_work_root())
        self.temp = tempfile.TemporaryDirectory(prefix="bootstrap-capture-test-", dir=base)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repository = self.root / "source"
        self.repository.mkdir()
        active = Path(__file__).resolve().parents[2]
        for relative in bootstrap.PRODUCER_MANIFEST_PATHS:
            target = self.repository / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(active / relative, target)
        self.git("init", "-q", "-b", "bootstrap-source")
        self.git("add", ".")
        self.git("-c", "user.name=Portable Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "source fixture")
        self.source = bootstrap.BootstrapSourceAuthority(self.repository, "refs/heads/bootstrap-source",
            self.git("rev-parse", "HEAD"), self.git("rev-parse", "HEAD^{tree}"))
        self.run = QualificationRunAuthority("qualification-test", "a" * 64)
        self.artifacts = self.root / "artifacts"
        self.work = self.artifacts / "qualification"
        self.cache = self.root / "cache"
        self.developer = self.root / "Xcode.app/Contents/Developer"
        for directory in (self.work, self.cache, self.developer / "usr/bin"):
            directory.mkdir(parents=True, exist_ok=True)
        tool = self.developer / "usr/bin/xcodebuild"
        tool.write_text("#!/bin/sh\nprintf 'Xcode 27.2\\nBuild version 18A42\\n'\n")
        tool.chmod(0o755)
        self.configuration = bootstrap.BootstrapConfiguration(self.artifacts, self.work, self.cache, self.developer)
        self.output_base = patch.object(bootstrap, "OUTPUT_BASE", self.root)
        self.output_base.start()
        self.addCleanup(self.output_base.stop)

    def git(self, *arguments):
        result = subprocess.run(["git", *arguments], cwd=self.repository, capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def execute(self, source="print('observed')", *, cancellation=None, timeout=2, launch_failure=False):
        original = subprocess.Popen
        def spawn(argv, **kwargs):
            intents = list(self.artifacts.glob("*.intent.json"))
            self.assertGreaterEqual(len(intents), 1)
            intent_path = max(intents, key=lambda path: path.stat().st_mtime_ns)
            intent = decode_canonical_bytes(intent_path.read_bytes())
            self.assertEqual(intent["invocation"]["argv"], list(argv))
            self.assertEqual(intent["qualification_run"], {"run_id": "qualification-test", "nonce": "a" * 64})
            self.assertEqual(kwargs["env"]["DEVELOPER_DIR"], str(self.developer))
            self.assertNotIn("PYTHONPATH", kwargs["env"])
            self.assertNotIn("TOKEN", kwargs["env"])
            self.assertFalse(kwargs["shell"])
            self.assertTrue(kwargs["start_new_session"])
            if launch_failure:
                raise OSError("synthetic launch failure")
            return original([sys.executable, "-c", source], **kwargs)
        with patch.object(bootstrap, "_spawn_qualifier", side_effect=spawn), \
             patch.object(bootstrap, "FULL_TEST_TIMEOUT_SECONDS", timeout), \
             patch.object(transport, "TERM_GRACE_SECONDS", .15), \
             patch.object(transport, "KILL_GRACE_SECONDS", .2), \
             patch.object(transport, "FINAL_DRAIN_SECONDS", .1):
            return bootstrap.execute_bootstrap_qualification(self.source, self.run, self.configuration,
                cancellation=cancellation)

    def replay(self, result, **overrides):
        arguments = {"expected_source": self.source, "expected_run": self.run}
        arguments.update(overrides)
        return bootstrap.revalidate_bootstrap_execution(result, **arguments)

    def test_bootstrap_intent_has_no_candidate_or_command_hashes(self):
        with patch.dict(os.environ, {"TOKEN": "synthetic", "PYTHONPATH": "/synthetic"}):
            result = self.execute("import os; os.write(1,b'\\x00\\xff'); os.write(2,b'err')")
        intent = decode_canonical_bytes(result.intent_path.read_bytes())
        self.assertEqual(set(intent), {"schema_version", "record_kind", "bootstrap_id", "qualification_run",
            "source", "producer", "invocation", "started_at_unix_ms"})
        self.assertEqual(intent["source"], {"repository_root": str(self.repository), "integration_ref": "refs/heads/bootstrap-source",
            "commit": self.source.commit, "tree": self.source.tree, "repository_clean": True})
        self.assertEqual(intent["producer"]["source_commit"], self.source.commit)
        self.assertEqual(intent["producer"]["source_tree"], self.source.tree)
        invocation = intent["invocation"]
        self.assertEqual(invocation["argv"], ["./Scripts/qualify_local_private_build.sh", "--source-root", str(self.repository),
            "--work-root", str(self.work), "--dependency-cache-root", str(self.cache), "--mode", "full-test",
            "--signing", "development", "--xcode-output", "quiet", "--integration-ref", "refs/heads/bootstrap-source"])
        self.assertEqual(invocation["developer_dir"], str(self.developer))
        self.assertEqual(invocation["policy_id"], "offline-development-full-test-v1")
        document = decode_canonical_bytes(result.capture_path.read_bytes())
        self.assertEqual(set(document), {"schema_version", "record_kind", "intent_sha256", "process_observation", "output_frames", "terminal"})
        self.assertEqual(document["intent_sha256"], hashlib.sha256(result.intent_path.read_bytes()).hexdigest())
        self.assertEqual(self.replay(result)[2], {"stdout": b"\x00\xff", "stderr": b"err"})
        self.assertEqual(result.capture_path.stat().st_nlink, 1)
        self.assertFalse(list(self.artifacts.glob("*.incomplete")))

    def test_admission_requires_final_marker_exit_and_one_run(self):
        # A preexisting input receipt and observed exit zero supply no final
        # completion marker. Admission must reject before product observation.
        receipt = self.work / "runs/run.synthetic/QUALIFICATION_INPUTS.json"
        receipt.parent.mkdir(parents=True)
        receipt.write_text("{}")
        result = self.execute()
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            bootstrap.admit_bootstrap_qualification(result, None,
                output=self.artifacts / "admission.json")

    def test_replay_requires_independent_admission_authority(self):
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            bootstrap.load_and_revalidate_bootstrap_qualification(
                artifact_root=self.artifacts, admission_relative_path="missing.json",
                candidate=None, expected_run=self.run, expected_source=self.source)

    def test_bootstrap_rejects_unapproved_invocation(self):
        result = self.execute()
        original = decode_canonical_bytes(result.intent_path.read_bytes())
        for option in ("--materialize-dependencies", "--resume-run", "--only-testing", "--extra"):
            with self.subTest(option=option):
                intent = decode_canonical_bytes(canonical_bytes(original))
                intent["invocation"]["argv"].append(option)
                with self.assertRaises(bootstrap.BootstrapQualificationError):
                    bootstrap.parse_bootstrap_intent(canonical_bytes(intent))
        for mode in ("mirror", "log-only", "QUIET"):
            with self.subTest(output_mode=mode):
                intent = decode_canonical_bytes(canonical_bytes(original))
                index = intent["invocation"]["argv"].index("--xcode-output")
                intent["invocation"]["argv"][index + 1] = mode
                with self.assertRaises(bootstrap.BootstrapQualificationError):
                    bootstrap.parse_bootstrap_intent(canonical_bytes(intent))
        for index, value in ((8, "smoke"), (10, "isolated-ci")):
            intent = decode_canonical_bytes(canonical_bytes(original))
            intent["invocation"]["argv"][index] = value
            with self.assertRaises(bootstrap.BootstrapQualificationError):
                bootstrap.parse_bootstrap_intent(canonical_bytes(intent))
        for configuration in (replace(self.configuration, qualification_work_root=self.repository),
                              replace(self.configuration, artifact_root=self.repository),
                              replace(self.configuration, dependency_cache_root=self.repository)):
            with self.assertRaises(bootstrap.BootstrapQualificationError):
                bootstrap.execute_bootstrap_qualification(self.source, self.run, configuration)
        (self.repository / "untracked").write_text("dirty")
        with self.assertRaisesRegex(bootstrap.BootstrapQualificationError, "clean"):
            bootstrap.execute_bootstrap_qualification(self.source, self.run, self.configuration)

    def test_bootstrap_terminal_is_observed_not_requested(self):
        cases = (("raise SystemExit(7)", {}, "exited"),
                 ("import time; time.sleep(10)", {"timeout": .05}, "timed-out"),
                 ("pass", {"launch_failure": True}, "launch-failed"))
        for child, options, expected in cases:
            with self.subTest(expected=expected):
                result = self.execute(child, **options)
                _, document, _ = self.replay(result)
                self.assertEqual(document["terminal"]["termination_kind"], expected)
                with self.assertRaises(bootstrap.BootstrapQualificationError):
                    self.replay(result, require_success=True)
                # Each call reserves a new ID, never overwrites failed evidence.
                self.assertTrue(result.intent_path.exists())

    def test_cancellation_output_budget_and_inherited_pipe_fail_closed(self):
        event = threading.Event()
        ready = self.artifacts / "child-ready"
        def cancel_when_ready():
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline and not event.wait(.01):
                pass
            event.set()
        timer = threading.Thread(target=cancel_when_ready)
        timer.start()
        self.addCleanup(timer.join)
        self.addCleanup(event.set)
        result = self.execute("import signal,time,pathlib; signal.signal(signal.SIGTERM,lambda *_:exit(0)); "
            + "pathlib.Path(" + repr(str(ready)) + ").touch(); time.sleep(10)", cancellation=event)
        self.assertEqual(self.replay(result)[1]["terminal"]["termination_kind"], "cancelled")
        self.assertEqual(self.replay(result)[1]["terminal"]["exit_code"], 0)
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            self.replay(result, require_success=True)
        with patch.object(capture, "MAX_DECODED_BYTES", 1024):
            result = self.execute("import os; os.write(1,b'x'*65536)")
            self.assertEqual(self.replay(result)[1]["terminal"]["termination_kind"], "output-limit")
            with self.assertRaises(bootstrap.BootstrapQualificationError):
                self.replay(result, require_success=True)
        with patch.object(transport.os, "killpg", wraps=os.killpg) as signal_group:
            with self.assertRaisesRegex(bootstrap.BootstrapQualificationError, "descendant cleanup unproven"):
                self.execute("import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(.3)'])")
            signal_group.assert_not_called()
        self.assertTrue(list(self.artifacts.glob("*.incomplete")))
        time.sleep(.35)

    def test_bootstrap_rejects_self_asserted_source_and_capture(self):
        receipt = self.work / "runs/run.synthetic/QUALIFICATION_INPUTS.json"
        receipt.parent.mkdir(parents=True)
        receipt.write_text("{}")
        result = self.execute()
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            self.replay(result, require_success=True)
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            self.replay(result, expected_run=QualificationRunAuthority("other-run", "b" * 64))
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            self.replay(result, expected_source=replace(self.source, tree="b" * 40))
        with patch.object(bootstrap, "_active_producer_bytes", return_value=b"another checkout"):
            with self.assertRaisesRegex(bootstrap.BootstrapQualificationError, "producer"):
                self.replay(result)
        # Self-consistent edits to both documents still cannot change authority.
        intent = decode_canonical_bytes(result.intent_path.read_bytes())
        intent["qualification_run"] = {"run_id": "forged-run", "nonce": "c" * 64}
        result.intent_path.write_bytes(canonical_bytes(intent))
        document = decode_canonical_bytes(result.capture_path.read_bytes())
        document["intent_sha256"] = hashlib.sha256(result.intent_path.read_bytes()).hexdigest()
        result.capture_path.write_bytes(canonical_bytes(document))
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            self.replay(result)

    def test_success_marker_is_unique_and_bound_to_owned_run(self):
        receipt = self.work / "runs/run.synthetic/QUALIFICATION_INPUTS.json"
        receipt.parent.mkdir(parents=True)
        receipt.write_text("{}")
        result = self.execute("print(" + repr("MACSCOPE_QUALIFICATION_RECEIPT=" + str(receipt)) + ")")
        self.assertEqual(self.replay(result, require_success=True)[2]["stdout"],
            ("MACSCOPE_QUALIFICATION_RECEIPT=" + str(receipt) + "\n").encode())
        result = self.execute("print(" + repr("MACSCOPE_QUALIFICATION_RECEIPT=" + str(receipt)) + "); print('after success marker')")
        with self.assertRaisesRegex(bootstrap.BootstrapQualificationError, "final"):
            self.replay(result, require_success=True)
        for marker in (str(self.cache / "QUALIFICATION_INPUTS.json"), str(receipt) + "\nMACSCOPE_QUALIFICATION_RECEIPT=" + str(receipt)):
            (self.cache / "QUALIFICATION_INPUTS.json").write_text("{}")
            result = self.execute("print(" + repr("MACSCOPE_QUALIFICATION_RECEIPT=" + marker) + ")")
            with self.assertRaises(bootstrap.BootstrapQualificationError):
                self.replay(result, require_success=True)

    def test_closed_canonical_documents_and_manifest_cover_imports(self):
        result = self.execute()
        payload = result.intent_path.read_bytes()
        for bad in (payload + b"\n", payload.replace(b'"schema_version":1', b'"schema_version":true'),
                    payload.replace(b'"schema_version":1', b'"schema_version":1,"schema_version":1')):
            with self.assertRaises(bootstrap.BootstrapQualificationError):
                bootstrap.parse_bootstrap_intent(bad)
        intent = decode_canonical_bytes(payload)
        manifest = intent["producer"]["file_manifest"]
        self.assertEqual([item["relative_path"] for item in manifest], sorted(bootstrap.PRODUCER_MANIFEST_PATHS))
        for item in manifest:
            expected = subprocess.run(["git", "show", self.source.commit + ":" + item["relative_path"]],
                cwd=self.repository, check=True, capture_output=True).stdout
            self.assertEqual(item["sha256"], hashlib.sha256(expected).hexdigest())
        tree = ast.parse((self.repository / "Scripts/reconstruction_gate_f/bootstrap_qualification.py").read_text())
        direct = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.level == 1:
                if node.module:
                    direct.add("Scripts/reconstruction_gate_f/" + node.module.split(".")[0] + ".py")
                else:
                    direct.update("Scripts/reconstruction_gate_f/" + name.name + ".py" for name in node.names)
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module and node.module.startswith("Scripts."):
                prefix = node.module.replace(".", "/")
                if node.module in {"Scripts.qualification", "Scripts.reconstruction"}:
                    direct.update(prefix + "/" + name.name + ".py" for name in node.names)
                else:
                    direct.add(prefix + ".py")
        # v2-only compatibility has a separate current-reader manifest. Adding
        # it to this v1 intent list would rewrite the historical run commitment.
        from Scripts.reconstruction_gate_f import bootstrap_reader_compatibility as reader
        separately_bound = {reader.READER_PATH}
        self.assertTrue(separately_bound <= reader.ALLOWED_PATHS)
        self.assertFalse(separately_bound & set(bootstrap.PRODUCER_MANIFEST_PATHS))
        self.assertTrue(direct <= set(bootstrap.PRODUCER_MANIFEST_PATHS) | separately_bound)

    def test_replay_rejects_changed_developer_authority_and_closed_capture(self):
        result = self.execute()
        original = decode_canonical_bytes(result.intent_path.read_bytes())
        alternate = self.root / "alternate-Xcode"
        alternate.mkdir()
        intent = decode_canonical_bytes(canonical_bytes(original))
        intent["invocation"]["developer_dir"] = str(alternate)
        environment = dict(intent["invocation"]["effective_environment"])
        environment["DEVELOPER_DIR"] = str(alternate)
        intent["invocation"]["effective_environment"] = [list(pair) for pair in sorted(environment.items())]
        result.intent_path.write_bytes(canonical_bytes(intent))
        document = decode_canonical_bytes(result.capture_path.read_bytes())
        document["intent_sha256"] = hashlib.sha256(result.intent_path.read_bytes()).hexdigest()
        result.capture_path.write_bytes(canonical_bytes(document))
        with self.assertRaisesRegex(bootstrap.BootstrapQualificationError, "independent"):
            self.replay(result)
        result.intent_path.write_bytes(canonical_bytes(original))
        document["intent_sha256"] = hashlib.sha256(result.intent_path.read_bytes()).hexdigest()
        for malformed in (dict(document, candidate_identity_sha256="b" * 64), dict(document, schema_version=True)):
            with self.assertRaises(bootstrap.BootstrapQualificationError):
                bootstrap.parse_bootstrap_capture(canonical_bytes(malformed), intent=original)

    def test_moved_source_and_durable_record_collision_never_spawn(self):
        result = self.execute()
        bootstrap_id = decode_canonical_bytes(result.intent_path.read_bytes())["bootstrap_id"]
        fixed_uuid = type("FixedID", (), {"hex": bootstrap_id.removeprefix("bootstrap-")})()
        previous = result.intent_path.read_bytes()
        with patch.object(bootstrap.uuid, "uuid4", return_value=fixed_uuid), patch.object(bootstrap, "_spawn_qualifier") as spawn:
            with self.assertRaises(bootstrap.BootstrapQualificationError):
                bootstrap.execute_bootstrap_qualification(self.source, self.run, self.configuration)
            spawn.assert_not_called()
        self.assertEqual(result.intent_path.read_bytes(), previous)
        self.repository.rename(self.root / "moved-source")
        with patch.object(bootstrap, "_spawn_qualifier") as spawn:
            with self.assertRaises(bootstrap.BootstrapQualificationError):
                bootstrap.execute_bootstrap_qualification(self.source, self.run, self.configuration)
            spawn.assert_not_called()

    def test_prelaunch_cancellation_and_sync_failure_leave_incomplete_evidence(self):
        event = threading.Event()
        event.set()
        with patch.object(bootstrap, "_spawn_qualifier") as spawn:
            with self.assertRaises(bootstrap.BootstrapQualificationError):
                bootstrap.execute_bootstrap_qualification(self.source, self.run, self.configuration, cancellation=event)
            spawn.assert_not_called()
        self.assertEqual(len(list(self.artifacts.glob("*.intent.json"))), 1)
        with patch.object(bootstrap.os, "fsync", side_effect=OSError("synthetic fsync")), \
             patch.object(bootstrap, "_spawn_qualifier") as spawn:
            with self.assertRaises(bootstrap.BootstrapQualificationError):
                bootstrap.execute_bootstrap_qualification(self.source, self.run, self.configuration)
            spawn.assert_not_called()
        self.assertTrue(list(self.artifacts.glob("*.incomplete")))


class BootstrapPhysicalAdmissionTests(unittest.TestCase):
    """Existing physical validators consume synthetic files, with tool I/O only faked."""
    setUp = BootstrapQualificationTests.setUp
    git = BootstrapQualificationTests.git
    execute = BootstrapQualificationTests.execute

    def fixture(self, *, skipped=False):
        active = Path(__file__).resolve().parents[2]
        extra = ("THIRD_PARTY_COMPONENTS.yml", "THIRD_PARTY_NOTICES.md",
            "ThirdParty/SleighNative/MATERIALIZATION.json", "ThirdParty/SleighNative/Source/MATERIALIZATION.json",
            "Scripts/ghostty-vt-source.contract")
        for relative in extra:
            target = self.repository / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(active / relative, target)
        for relative, payload in (("MacScope/project.yml", b"name: MacScope\n"),
            ("ThirdParty/Zig/zig-0.16.0/zig", b"#!/bin/sh\nexit 0\n"),
            ("ThirdParty/GhosttyVT/Source/fixture", b"source bytes"),
            ("MacScope/Tests/CoreTests/Suite.swift", b'class Suite: XCTestCase { func testOne() throws { throw XCTSkip("missing") } }' if skipped else b"class Suite: XCTestCase { func testOne() {} }")):
            target = self.repository / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
        (self.repository / "ThirdParty/Zig/zig-0.16.0/zig").chmod(0o755)
        policy = {"schemaVersion": 2, "countingRule": "direct-and-file-local-transitive-swift-test-methods", "knownGap": "Synthetic fixture policy", "entries": []}
        policy["entries"] = ([dict(file="CoreTests/Suite.swift", method="testOne", reason="Reviewed external fixture availability condition.")] if skipped else [])
        allowlist = self.repository / "docs/qualification/skip-allowlist.json"
        allowlist.parent.mkdir(parents=True)
        allowlist.write_bytes(canonical_bytes(policy))
        self.git("remote", "add", "github", "https://github.com/jdotc1/MacScope-app.git")
        self.git("add", ".")
        self.git("-c", "user.name=Portable Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "physical source fixture")
        self.source = replace(self.source, commit=self.git("rev-parse", "HEAD"), tree=self.git("rev-parse", "HEAD^{tree}"))
        self.source = replace(self.source, integration_ref="refs/remotes/github/bootstrap-source")
        self.git("update-ref", self.source.integration_ref, self.source.commit)
        fixture_type = type("ExactBuildFixture", (QualificationBuildFixture,), dict(
            commit=self.source.commit, tree=self.source.tree, integration_ref=self.source.integration_ref))
        f = fixture_type(self.artifacts, mode="full-test")
        self.work, self.cache = f.run.parent.parent, f.cache
        self.configuration = replace(self.configuration, qualification_work_root=self.work, dependency_cache_root=self.cache)
        shutil.rmtree(f.source)
        export = subprocess.run([sys.executable, "-B", str(active / "Scripts/source_export_provenance.py"), "create",
            "--repository-root", str(self.repository), "--destination", str(f.source), "--integration-ref", self.source.integration_ref],
            capture_output=True, text=True)
        self.assertEqual(export.returncode, 0, export.stderr)
        f.source_identity = json.loads((f.source / "SOURCE_PROVENANCE.json").read_bytes())
        f.receipt_document["source_identity"] = f.source_identity
        pins = {i["id"]: i["pin"] for i in f.source_identity["dependency_contract"]["component_pins"]}
        vt_bytes = f.vt_manifest.read_bytes() + ("source_revision=" + pins["ghostty-vt"]["git_revision"] + "\nsource_tree_sha256=" + pins["ghostty-vt"]["source_tree_sha256"] + "\n").encode()
        for path in (f.vt_manifest, f.ghostty_vt / "artifacts/lib/.macscope-ghostty-vt-manifest", f.xcode_vt / "artifacts/lib/.macscope-ghostty-vt-manifest"):
            path.write_bytes(vt_bytes)
        f.receipt_document["ghostty_artifact_manifest_sha256"] = hashlib.sha256(vt_bytes).hexdigest()
        SleighPackageFixture(f.sleigh / "package").create()
        f.sleigh_manifest.unlink()
        toolchain = {name: dict(path="/synthetic/" + name, sha256="c" * 64, version=version)
            for name, version in (("compiler", "Apple clang version 21.0.0"), ("cmake", "cmake version 4.0.0"), ("ninja", "1.12.1"))}
        manifest = sleigh_package.write_source_materialization(f.sleigh / "package", toolchain, f.sleigh_manifest)
        f.receipt_document["sleigh_materialization_manifest_sha256"] = hashlib.sha256(f.sleigh_manifest.read_bytes()).hexdigest()
        f.write_receipt()
        provenance = json.loads(f.provenance.read_bytes())
        provenance.update(sleigh_materialization_manifest_sha256=f.receipt_document["sleigh_materialization_manifest_sha256"],
            sleigh_materialization_schema_version=2, sleigh_materialization_component_id=manifest["componentId"],
            sleigh_materialization_tree_sha256=manifest["package"]["treeSha256"])
        f.provenance.write_bytes(canonical_line(provenance))
        project = f.source / "MacScope/MacScope.xcodeproj"
        project.mkdir()
        for relative in GENERATED_PROJECT_FILES:
            path = project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'{"objects":{},"rootObject":"fixture"}\n' if relative == "project.xcproj" else relative.encode())
        retained = bootstrap.generated_project_evidence.capture(f.run, _generated_project_identity(project, require_complete=True))
        shutil.rmtree(project)
        def bundle(path, executable, identifier, payload):
            exe = path / "Contents/MacOS" / executable
            exe.parent.mkdir(parents=True, exist_ok=True)
            exe.write_bytes(payload)
            exe.chmod(0o755)
            (path / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(CFBundleExecutable=executable, CFBundleIdentifier=identifier)))
        debug = f.derived / "Build/Products/Debug/MacScope.app"
        bundle(debug, "MacScope", "org.macscope.app", b"distinct Debug fixture")
        bundle(debug / "Contents/XPCServices/AIAgentWorkerXPCService.xpc", "AIAgentWorkerXPCService", "org.macscope.app.AIAgentWorker", b"ai worker")
        bundle(f.app / "Contents/XPCServices/NativeDecompilerXPCService.xpc", "NativeDecompilerXPCService", "org.macscope.app.NativeDecompiler", b"native worker")
        for executable in ("AIAgentWorkerXPCService", "AnalysisWorkerXPCService", "ShellBrokerXPCService"):
            bundle(f.app / "Contents/XPCServices" / (executable + ".xpc"), executable, "fixture." + executable, executable.encode())
        core = debug / "Contents/PlugIns/CoreTests.xctest"
        bundle(core, "CoreTests", "org.macscope.app.CoreTests", b"CoreTests fixture")
        products = f.derived / "Build/Products"
        ui_runner = products / "Debug/MacScopeInstalledAppUITests-Runner.app"
        ui_test = ui_runner / "Contents/PlugIns/MacScopeInstalledAppUITests.xctest"
        bundle(ui_runner, "MacScopeInstalledAppUITests-Runner", "fixture.runner", b"UI runner")
        bundle(ui_test, "MacScopeInstalledAppUITests", "fixture.uitests", b"UI tests")
        native_run = products / "MacScopeApp.xctestrun"
        native_run.write_bytes(plistlib.dumps({"__xctestrun_metadata__": {"ContainerInfo": {"SchemeName": "MacScopeApp"}},
            "CoreTests": dict(BlueprintName="CoreTests", IsAppHostedTestBundle=True, TestHostBundleIdentifier="org.macscope.app",
                TestHostPath="__TESTROOT__/Debug/MacScope.app", TestBundlePath="__TESTHOST__/Contents/PlugIns/CoreTests.xctest",
                DependentProductPaths=["__TESTROOT__/Debug/MacScope.app", "__TESTROOT__/Debug/MacScope.app/Contents/PlugIns/CoreTests.xctest"])}))
        ui_run = products / "MacScopeInstalledAppUITests.xctestrun"
        ui_run.write_bytes(plistlib.dumps({"__xctestrun_metadata__": {"ContainerInfo": {"SchemeName": "MacScopeInstalledAppUITests"}},
            "UITests": dict(BlueprintName="MacScopeInstalledAppUITests", TestHostPath="__TESTROOT__/Debug/MacScopeInstalledAppUITests-Runner.app",
                TestBundlePath="__TESTHOST__/Contents/PlugIns/MacScopeInstalledAppUITests.xctest", UITargetAppPath="__TESTROOT__/Debug/MacScope.app",
                DependentProductPaths=["__TESTROOT__/Debug/MacScope.app"])}))
        m = bootstrap.materializer
        mapping = candidate_mapping()
        mapping["source"].update(repository="fixture:MacScope", branch_label="bootstrap-source", commit=self.source.commit, tree=self.source.tree,
            base_commit=self.source.commit, base_tree=self.source.tree, project_yml_sha256=hashlib.sha256((f.source / "MacScope/project.yml").read_bytes()).hexdigest(),
            generated_project_sha256=hashlib.sha256(retained.read_bytes()).hexdigest())
        original_run = m._run
        def signing_tool(argv, **kwargs):
            if argv[0] != "/usr/bin/codesign":
                return original_run(argv, **kwargs)
            stdout, stderr = "", ""
            if "--verbose=4" in argv:
                stderr = "Authority=Fixture Development Certificate\nTeamIdentifier=FIXTURE123\nCodeDirectory fixture flags=0x10000(runtime)\n"
            elif "-r-" in argv:
                stdout = "designated => fixture development requirement\n"
            elif "--entitlements" in argv:
                stdout = b"fixture entitlements"
                stderr = b""
            else:
                for argument in argv:
                    if argument.startswith("--extract-certificates="):
                        Path(argument.split("=", 1)[1] + "0").write_bytes(b"fixture certificate")
            return subprocess.CompletedProcess(argv, 0, stdout, stderr)
        self.signing_patch = patch.object(m, "_run", side_effect=signing_tool)
        self.signing_patch.start()
        self.addCleanup(self.signing_patch.stop)
        signing = m._codesign_identity(f.app)
        mapping["application"].update(signing)
        snapshot = m.capture_bundle_snapshot(f.app)
        mapping["application"].update(bundle_sha256=snapshot.digests.content_sha256, closed_tree_sha256=snapshot.digests.closed_tree_sha256,
            root_mode=f.app.stat().st_mode & 0o7777, executable_sha256=m._sha256_file(f.app / "Contents/MacOS/MacScope"),
            embedded_executables=m._embedded_executables(f.app), qualification_executables=m._qualification_executables(debug, f.app))
        # Only external signing tool I/O is substituted. Every tree, receipt,
        # dependency and semantic xcresult validator remains real.
        authority = m._capture_qualification_dependency_authority(repository_root=self.repository, qualification_receipt_path=f.receipt,
            qualification=f.receipt_document, release_app=f.app, provenance=provenance, commit=self.source.commit, tree=self.source.tree)
        mapping["dependencies"] = sorted(m._materialization_dependency(f.receipt_document, self.repository, authority), key=lambda i: i["dependency_id"])
        mapping["packages"] = [dict(package_id="native-sleigh", manifest_sha256=m._sha256_file(f.sleigh_manifest), tree_sha256=manifest["package"]["treeSha256"])]
        prep_toolchain = {key: "fixture" for key in bootstrap.preparation.TOOLCHAIN_FIELDS}
        prep_toolchain.update(developer_dir=str(self.developer), xcodebuild_sha256="c" * 64, swiftc_sha256="d" * 64,
            sdk_settings_sha256="e" * 64, xcode_version="27.2", xcode_build="18A42", swift_version="Apple Swift version 6.4", sdk_version="27.2")
        self.preparation_toolchain = prep_toolchain
        self.toolchain_observations = []
        original_subprocess_run = subprocess.run
        def toolchain_subprocess(argv, **kwargs):
            if argv[:3] == ["/usr/bin/python3", "-B", "-c"] and "_toolchain_identity" in argv[3]:
                self.toolchain_observations.append((argv, kwargs))
                self.assertEqual(kwargs["cwd"], self.repository)
                self.assertEqual(kwargs["env"]["DEVELOPER_DIR"], str(self.developer))
                self.assertNotIn("PYTHONPATH", kwargs["env"])
                self.assertEqual(kwargs["timeout"], 30)
                self.assertTrue(kwargs["check"])
                return subprocess.CompletedProcess(argv, 0, canonical_bytes(self.preparation_toolchain), b"")
            return original_subprocess_run(argv, **kwargs)
        subprocess_patch = patch.object(subprocess, "run", side_effect=toolchain_subprocess)
        subprocess_patch.start()
        self.addCleanup(subprocess_patch.stop)
        mapping["tools"] = sorted([i for i in mapping["tools"] if i["tool_id"] not in {"xcode", "swift", "sdk"}] + [dict(tool_id=name, version=version, identity_sha256=digest) for name, version, digest in (
            ("xcode", "Xcode 27.2 | Build version 18A42", "c" * 64), ("swift", "Apple Swift version 6.4", "d" * 64), ("sdk", "27.2", "e" * 64))], key=lambda i: i["tool_id"])
        self.candidate, issues = parse_candidate_identity(mapping)
        self.assertFalse(issues, issues)
        self.assertIsNotNone(self.candidate)
        prep_source = {key: mapping["source"][key] for key in ("repository", "branch_label", "commit", "tree", "dirty", "project_yml_sha256", "generated_project_sha256")}
        def file_record(path):
            return dict(path=str(path), sha256=m._sha256_file(path))
        def bundle_record(path, executable):
            return dict(path=str(path), closed_tree_sha256=m.capture_bundle_snapshot(path).digests.closed_tree_sha256, executable_sha256=m._sha256_file(path / "Contents/MacOS" / executable))
        for filename, mode, xctestrun, artifacts in (
            ("NativeLivePreparation.receipt.json", bootstrap.preparation.NATIVE_LIVE_PREPARATION_MODE, native_run, dict(core_tests=bundle_record(core, "CoreTests"), native_decompiler=file_record(f.app / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/MacOS/NativeDecompilerXPCService"))),
            ("InstalledUIPreparation.receipt.json", "installed-ui-matrix", ui_run, dict(ui_test_bundle=bundle_record(ui_test, "MacScopeInstalledAppUITests"), ui_runner=bundle_record(ui_runner, "MacScopeInstalledAppUITests-Runner")))):
            native = mode == bootstrap.preparation.NATIVE_LIVE_PREPARATION_MODE
            document = dict(schema_version=2, receipt_kind="native-live-xpc-preparation", source=prep_source, toolchain=prep_toolchain,
                build=dict(scheme="MacScopeApp" if native else "MacScopeInstalledAppUITests", configuration="Debug", destination="platform=macOS,arch=arm64",
                    live_test_condition="MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING" if native else "MACSCOPE_WS24_RUN_INSTALLED_XCUITEST", preparation_mode=mode),
                artifacts=dict(xctestrun=file_record(xctestrun), app=bundle_record(f.app, "MacScope"), **artifacts))
            target = f.run / "candidate-artifacts" / filename
            target.parent.mkdir(exist_ok=True)
            target.write_bytes(canonical_bytes(document))
        self.summary, self.tests, case = full_suite_fixtures.QualificationArtifactTests().documents()
        if skipped:
            case.update(result="Skipped", children=[dict(nodeType="Skip Message", name="actual fixture missing")])
            self.summary.update(passedTests=0, skippedTests=1)
        self.xcresult = f.run / "TestResults.xcresult"
        self.xcresult.mkdir()
        self.summary_path = self.xcresult / "summary.json"
        self.tests_path = self.xcresult / "tests.json"
        self.summary_path.write_bytes(canonical_bytes(self.summary))
        self.tests_path.write_bytes(canonical_bytes(self.tests))
        for name, filename in (("xcresult_test_summary", "summary.json"), ("xcresult_test_nodes", "tests.json")):
            tool_patch = patch.object(bootstrap.qualification_validator, name,
                side_effect=lambda path, _code, filename=filename: json.loads((path / filename).read_bytes()))
            tool_patch.start()
            self.addCleanup(tool_patch.stop)
        (f.run / "COVERAGE.json").write_bytes(b'{"targets":[]}\n')
        # Timing identity is checked against the actual observed interval below;
        # empty synthetic stage observations make no claim that a build ran.
        timing = bootstrap.stage_timing.expected_identity(type("Args", (), dict(source_commit=self.source.commit, source_tree=self.source.tree, run_root=f.run, mode="full-test"))())
        (f.run / "STAGE_TIMINGS.json").write_bytes(bootstrap.stage_timing.canonical_json(timing))
        child = "print(" + repr("MACSCOPE_TEST_RESULTS=" + str(self.xcresult)) + "); print(" + repr("MACSCOPE_COVERAGE_JSON=" + str(f.run / "COVERAGE.json")) + "); print(" + repr("MACSCOPE_QUALIFICATION_RECEIPT=" + str(f.receipt)) + ")"
        self.retained = self.execute(child)
        self.fixture_build = f
        return f

    def test_admission_reuses_candidate_and_full_suite_authority(self):
        f = self.fixture()
        q = bootstrap.qualification_validator
        with patch.object(q, "validate_qualification_products", wraps=q.validate_qualification_products) as products, \
             patch.object(q, "validate_full_coretests_xcresult", wraps=q.validate_full_coretests_xcresult) as full:
            admitted = bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=self.artifacts / "admission.json")
            products.assert_called_with(self.candidate, f.receipt, integration_ref=self.source.integration_ref, dependency_cache_root=self.cache, mode="full-test")
            full.assert_called_with(self.xcresult, candidate=self.candidate, source_root=f.source, integration_ref=self.source.integration_ref)
        document = bootstrap.parse_bootstrap_admission(admitted.admission_path.read_bytes())
        self.assertNotEqual(document["products"]["release"]["executable_sha256"], document["products"]["debug"]["executable_sha256"])
        self.assertEqual(document["tests"]["observations"]["executed_selector_count"], 1)
        self.assertEqual(self.replay_admission(), admitted)

    def replay_admission(self, **overrides):
        arguments = dict(artifact_root=self.artifacts, admission_relative_path="admission.json", candidate=self.candidate, expected_run=self.run, expected_source=self.source)
        arguments.update(overrides)
        return bootstrap.load_and_revalidate_bootstrap_qualification(**arguments)

    def test_replay_rejects_changed_physical_authority(self):
        f = self.fixture()
        bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=self.artifacts / "admission.json")
        document = bootstrap.parse_bootstrap_admission((self.artifacts / "admission.json").read_bytes())
        paths = (f.source / "MacScope/Tests/CoreTests/Suite.swift", f.vt_manifest,
            f.run / "generated-project-evidence/MacScope.xcodeproj/project.xcproj", f.app / "Contents/MacOS/MacScope",
            f.run / "candidate-artifacts/NativeLivePreparation.receipt.json", f.run / "candidate-artifacts/InstalledUIPreparation.receipt.json",
            self.tests_path, f.run / "COVERAGE.json", f.run / "STAGE_TIMINGS.json", f.receipt,
            f.sleigh / "package/lib/libdecomp.a",
            *(self.artifacts / document["qualification"][key]["relative_path"] for key in ("generated_project_manifest", "dependency_manifest")))
        for path in paths:
            saved = path.read_bytes()
            with self.subTest(artifact=str(path.relative_to(self.artifacts))):
                path.write_bytes(saved + b"changed")
                with self.assertRaises(bootstrap.BootstrapQualificationError):
                    self.replay_admission()
                path.write_bytes(saved)
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            self.replay_admission(expected_run=QualificationRunAuthority(self.run.run_id, "b" * 64))
        changed = candidate_to_mapping(self.candidate)
        changed["application"]["root_mode"] = 0o700
        other, issues = parse_candidate_identity(changed)
        self.assertFalse(issues)
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            self.replay_admission(candidate=other)
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            self.replay_admission(admission_relative_path="../admission.json")
        coverage = f.run / "COVERAGE.json"
        saved = coverage.read_bytes()
        coverage.unlink()
        coverage.symlink_to(self.tests_path)
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            self.replay_admission()
        coverage.unlink()
        coverage.write_bytes(saved)
        debug = f.derived / "Build/Products/Debug/MacScope.app"
        displaced = debug.with_name("Displaced.app")
        debug.rename(displaced)
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            self.replay_admission()
        displaced.rename(debug)
        self.replay_admission()

    def test_admission_rejects_mixed_preparation_run_and_publication_mutation(self):
        f = self.fixture()
        preparation = f.run / "candidate-artifacts/NativeLivePreparation.receipt.json"
        original = preparation.read_bytes()
        document = json.loads(original)
        document["artifacts"]["app"]["path"] = str(self.artifacts / "another-run/Release/MacScope.app")
        preparation.write_bytes(canonical_bytes(document))
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=self.artifacts / "admission.json")
        preparation.write_bytes(original)
        observed = bootstrap._observe_qualification
        def mutate_after_observation(*args):
            value = observed(*args)
            (f.app / "Contents/MacOS/MacScope").write_bytes(b"changed during admission")
            return value
        with patch.object(bootstrap, "_observe_qualification", side_effect=mutate_after_observation), self.assertRaises(bootstrap.BootstrapQualificationError):
            bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=self.artifacts / "admission.json")
        self.assertFalse((self.artifacts / "admission.json").exists())

    def test_closed_admission_and_manifest_snapshot_fence(self):
        self.fixture()
        admitted = bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=self.artifacts / "admission.json")
        original = bootstrap.parse_bootstrap_admission(admitted.admission_path.read_bytes())
        for target, key, value in (((), "schema_version", True), (("products", "release"), "root_mode", True),
            (("tests", "observations"), "passed_selector_count", True), (("qualification", "receipt"), "relative_path", "../escape"),
            (("tests",), "passed", True)):
            document = copy.deepcopy(original)
            nested = document
            for part in target:
                nested = nested[part]
            nested[key] = value
            with self.subTest(key=key), self.assertRaises(bootstrap.BootstrapQualificationError):
                bootstrap.parse_bootstrap_admission(canonical_bytes(document))
        reference = original["qualification"]["generated_project_manifest"]
        (self.artifacts / reference["relative_path"]).write_bytes(b"changed after manifest revalidation")
        with self.assertRaisesRegex(bootstrap.BootstrapQualificationError, "manifest changed"):
            bootstrap._manifest_snapshots(self.artifacts, original)

    def test_toolchain_probe_reobserves_full_identity_in_isolated_environment(self):
        f = self.fixture()
        environment_before = dict(os.environ)
        bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=self.artifacts / "admission.json")
        self.assertEqual(dict(os.environ), environment_before)
        self.assertEqual(len(self.toolchain_observations), 1)
        self.replay_admission()
        self.assertEqual(len(self.toolchain_observations), 2)
        original = dict(self.preparation_toolchain)
        for field in ("sdk_build", "sdk_path", "xcode_build", "swiftc_sha256"):
            self.preparation_toolchain = {**original, field: "f" * 64 if field.endswith("sha256") else "changed"}
            with self.subTest(field=field), self.assertRaises(bootstrap.BootstrapQualificationError):
                self.replay_admission()
        self.preparation_toolchain = original
        preparation_path = f.run / "candidate-artifacts/InstalledUIPreparation.receipt.json"
        document = json.loads(preparation_path.read_bytes())
        document["toolchain"]["sdk_build"] = "forged recorded build"
        preparation_path.write_bytes(canonical_bytes(document))
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=self.artifacts / "drift.json")

    def test_initial_publication_preserves_prevalidation_file_and_debug_snapshots(self):
        f = self.fixture()
        timing_validator = bootstrap._check_timings
        header = f.ghostty_vt / "artifacts/include/ghostty/vt.h"
        paths = (self.retained.intent_path, self.retained.capture_path, f.receipt, f.run / "STAGE_TIMINGS.json", header)
        for index, path in enumerate(paths):
            saved = path.read_bytes()
            output = self.artifacts / ("mutation-" + str(index) + ".json")
            def validate_then_change(*args):
                timing_validator(*args)
                path.write_bytes(saved + b"changed after validation")
            with self.subTest(path=path.name), patch.object(bootstrap, "_check_timings", side_effect=validate_then_change), self.assertRaises(bootstrap.BootstrapQualificationError):
                bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=output)
            self.assertFalse(output.exists())
            path.write_bytes(saved)
        debug_executable = f.derived / "Build/Products/Debug/MacScope.app/Contents/MacOS/MacScope"
        original = debug_executable.read_bytes()
        qualification_executables = bootstrap.materializer._qualification_executables
        def validate_then_change_debug(*args):
            values = qualification_executables(*args)
            debug_executable.write_bytes(b"changed after executable validation")
            return values
        with patch.object(bootstrap.materializer, "_qualification_executables", side_effect=validate_then_change_debug), self.assertRaises(bootstrap.BootstrapQualificationError):
            bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=self.artifacts / "debug-mutation.json")
        self.assertFalse((self.artifacts / "debug-mutation.json").exists())
        debug_executable.write_bytes(original)

    def test_publication_rejects_sidecar_ancestor_symlink_substitution(self):
        f = self.fixture()
        validator = bootstrap._check_timings
        evidence = f.run / "generated-project-evidence"
        displaced = f.run / "displaced-project-evidence"
        def validate_then_redirect(*args):
            validator(*args)
            evidence.rename(displaced)
            evidence.symlink_to(displaced, target_is_directory=True)
        with patch.object(bootstrap, "_check_timings", side_effect=validate_then_redirect), self.assertRaises(bootstrap.BootstrapQualificationError):
            bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=self.artifacts / "redirect.json")
        self.assertFalse((self.artifacts / "redirect.json").exists())
        evidence.unlink()
        displaced.rename(evidence)
        def validate_then_add_entry(*args):
            validator(*args)
            (evidence / "unexpected.json").write_bytes(b"{}")
        with patch.object(bootstrap, "_check_timings", side_effect=validate_then_add_entry), self.assertRaises(bootstrap.BootstrapQualificationError):
            bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=self.artifacts / "addition.json")
        self.assertFalse((self.artifacts / "addition.json").exists())

    def test_bootstrap_full_suite_retains_existing_failure_and_skip_policy(self):
        f = self.fixture(skipped=True)
        admitted = bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=self.artifacts / "admission.json")
        observation = bootstrap.parse_bootstrap_admission(admitted.admission_path.read_bytes())["tests"]["observations"]
        self.assertEqual(observation["skips"][0]["reviewed_reason"], "Reviewed external fixture availability condition.")
        self.assertEqual(observation["skip_policy"]["source_commit"], self.source.commit)
        self.assertEqual(observation["coverage_claim"], "all-recorded-cases-in-selected-scope-not-source-enumeration")
        for mutation in ("failed", "duplicate", "retry-failed", "unexpected", "unauthorized-skip"):
            tests = copy.deepcopy(self.tests)
            suite = tests["testNodes"][0]["children"][0]
            case = suite["children"][0]
            if mutation == "failed":
                case["result"] = "Failed"
            elif mutation == "duplicate":
                suite["children"].append(copy.deepcopy(case))
            elif mutation == "retry-failed":
                case.update(result="Passed", children=[dict(nodeType="Test Case Run", name="Run 1", result="Failed", children=[])])
            else:
                case["nodeIdentifier"] = "Suite/testUnauthorized()"
                if mutation == "unexpected":
                    tests["testNodes"][0]["name"] = "UnexpectedBundle"
            self.tests_path.write_bytes(canonical_bytes(tests))
            with self.subTest(mutation=mutation), self.assertRaises(bootstrap.BootstrapQualificationError):
                bootstrap.admit_bootstrap_qualification(self.retained, self.candidate, output=self.artifacts / (mutation + ".json"))
        self.tests_path.write_bytes(canonical_bytes(self.tests))


if __name__ == "__main__":
    unittest.main()
