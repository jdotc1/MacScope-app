"""Physical Git reader/source separation; no native qualification or patched validators."""
import copy
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from Scripts.reconstruction_gate_f import bootstrap_qualification as bootstrap
from Scripts.reconstruction_gate_f import bootstrap_reader_compatibility as reader
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes, decode_canonical_bytes
from Scripts.tests import test_gate_f_bootstrap_qualification as fixtures
from Scripts.lib.work_root import existing_work_root, work_root as macscope_work_root


class ReaderFixturePortabilityTests(unittest.TestCase):
    def test_linux_default_uses_host_temporary_root(self):
        with tempfile.TemporaryDirectory(prefix="reader-portability-",
                dir=existing_work_root() if sys.platform == "darwin" else None) as base:
            environment = {key: value for key, value in os.environ.items()
                           if key != "MACSCOPE_TEST_TEMP_ROOT"}
            case = ReaderCompatibilityTests()
            try:
                with patch.dict(os.environ, environment, clear=True), \
                        patch.object(sys, "platform", "linux"), \
                        patch.object(tempfile, "tempdir", base):
                    case.setUp()
                self.assertEqual(case.root.parent, Path(base).resolve())
            finally:
                case.doCleanups()

    def test_explicit_temporary_root_is_preserved(self):
        with tempfile.TemporaryDirectory(prefix="reader-portability-",
                dir=existing_work_root() if sys.platform == "darwin" else None) as base:
            case = ReaderCompatibilityTests()
            try:
                with patch.dict(os.environ, {"MACSCOPE_TEST_TEMP_ROOT": base}), \
                        patch.object(sys, "platform", "linux"):
                    case.setUp()
                self.assertEqual(case.root.parent, Path(base).resolve())
            finally:
                case.doCleanups()


class ReaderCompatibilityTests(unittest.TestCase):
    def setUp(self):
        base = os.environ.get("MACSCOPE_TEST_TEMP_ROOT")
        if base is None and sys.platform == "darwin":
            base = str(existing_work_root()) if existing_work_root() else None
        self.temp = tempfile.TemporaryDirectory(prefix="bootstrap-reader-test-", dir=base)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.git("init", "-q", "-b", "fixture")
        for relative in bootstrap.PRODUCER_MANIFEST_PATHS:
            self.write(relative, (relative + " original\n").encode())
        self.write("MacScope/App.swift", b"native input\n")
        self.write("Scripts/reconstruction/app_quiescence.py", b"original quiescence policy\n")
        self.write("Scripts/tests/test_app_quiescence.py", b"original policy tests\n")
        self.commit("original")
        self.original = self.git("rev-parse", "HEAD").decode().strip()
        self.tree = self.git("rev-parse", "HEAD^{tree}").decode().strip()
        self.manifest = [{"relative_path": p, "sha256": hashlib.sha256((self.root / p).read_bytes()).hexdigest()}
                         for p in bootstrap.PRODUCER_MANIFEST_PATHS]
        self.write(reader.READER_PATH, b"reader implementation\n")
        self.write(reader.BOOTSTRAP_PATH, b"current bootstrap reader\n")
        self.commit("reader-only")

    def git(self, *args):
        return subprocess.run(["/usr/bin/git", *args], cwd=self.root, check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

    def write(self, relative, payload):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)

    def commit(self, message):
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", message)

    def observe(self, manifest=None, original=None, tree=None):
        return reader.observe_reader_identity(repository_root=self.root,
            original_commit=original or self.original, original_tree=tree or self.tree,
            original_manifest=self.manifest if manifest is None else manifest,
            producer_paths=bootstrap.PRODUCER_MANIFEST_PATHS)

    def test_descendant_reader_binds_both_identities_and_exact_path_hashes(self):
        identity = self.observe()
        self.assertEqual(identity["original_source"], {"commit": self.original, "tree": self.tree})
        self.assertEqual(identity["commit"], self.git("rev-parse", "HEAD").decode().strip())
        self.assertEqual(identity["tree"], self.git("rev-parse", "HEAD^{tree}").decode().strip())
        self.assertEqual([x["relative_path"] for x in identity["changed_paths"]],
                         [reader.BOOTSTRAP_PATH, reader.READER_PATH])
        reader.validate_reader_identity_shape(identity)
        self.assertEqual(self.manifest[bootstrap.PRODUCER_MANIFEST_PATHS.index(reader.BOOTSTRAP_PATH)]["sha256"],
                         identity["changed_paths"][0]["original_sha256"])

    def test_native_drift_is_rejected_even_with_allowed_reader_change(self):
        self.write("MacScope/App.swift", b"native drift\n")
        self.commit("native drift")
        with self.assertRaisesRegex(ValueError, "unlisted"):
            self.observe()

    def test_exact_quiescence_consumer_amendments_are_recorded(self):
        for relative in ("Scripts/reconstruction/app_quiescence.py", "Scripts/tests/test_app_quiescence.py"):
            self.write(relative, b"reviewed tooling amendment\n")
        self.commit("consumer policy and governance amendment")
        identity = self.observe()
        changed = {item["relative_path"]: item for item in identity["changed_paths"]}
        self.assertIsNotNone(changed["Scripts/reconstruction/app_quiescence.py"]["original_sha256"])
        self.assertEqual(set(changed), {reader.BOOTSTRAP_PATH, reader.READER_PATH,
            "Scripts/reconstruction/app_quiescence.py", "Scripts/tests/test_app_quiescence.py"})

    def test_uncommitted_and_untracked_changes_are_rejected(self):
        for relative in (reader.BOOTSTRAP_PATH, "untracked.txt"):
            with self.subTest(relative=relative):
                self.write(relative, b"dirty\n")
                with self.assertRaisesRegex(ValueError, "clean"):
                    self.observe()
                if relative == reader.BOOTSTRAP_PATH:
                    self.write(relative, b"current bootstrap reader\n")
                else:
                    (self.root / relative).unlink()

    def test_missing_original_producer_is_rejected(self):
        self.write("missing-original-marker", b"marker")
        self.git("rm", bootstrap.PRODUCER_MANIFEST_PATHS[0])
        self.commit("incomplete original")
        original = self.git("rev-parse", "HEAD").decode().strip()
        tree = self.git("rev-parse", "HEAD^{tree}").decode().strip()
        self.write(reader.BOOTSTRAP_PATH, b"next reader\n")
        self.commit("next")
        with self.assertRaisesRegex(ValueError, "regular"):
            self.observe(original=original, tree=tree)

    def test_altered_original_manifest_is_rejected(self):
        altered = copy.deepcopy(self.manifest)
        altered[0]["sha256"] = "a" * 64
        with self.assertRaisesRegex(ValueError, "original producer"):
            self.observe(manifest=altered)
        with self.assertRaisesRegex(ValueError, "manifest"):
            self.observe(manifest=self.manifest[:-1])

    def test_wrong_original_tree_and_nonancestor_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "tree"):
            self.observe(tree="a" * 40)
        self.git("checkout", "--orphan", "unrelated")
        self.write(reader.BOOTSTRAP_PATH, b"unrelated reader\n")
        self.commit("unrelated")
        with self.assertRaisesRegex(ValueError, "ancestor"):
            self.observe()

    def test_deleted_allowed_file_and_unchanged_reader_are_rejected(self):
        self.git("rm", reader.BOOTSTRAP_PATH)
        self.commit("deleted reader")
        with self.assertRaisesRegex(ValueError, "regular"):
            self.observe()

    def test_reader_record_shape_is_closed_and_source_bound(self):
        identity = self.observe()
        identity["unreviewed"] = True
        with self.assertRaises(ValueError):
            reader.validate_reader_identity_shape(identity)
        identity = self.observe()
        identity["changed_paths"][0]["relative_path"] = "MacScope/App.swift"
        with self.assertRaisesRegex(ValueError, "unlisted"):
            reader.validate_reader_identity_shape(identity)


class AmendedAdmissionTests(unittest.TestCase):
    def fixture(self):
        fixture = fixtures.BootstrapPhysicalAdmissionTests("test_admission_reuses_candidate_and_full_suite_authority")
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.fixture()
        return fixture

    def advance_reader(self, fixture):
        original_intent = fixture.retained.intent_path.read_bytes()
        original_capture = fixture.retained.capture_path.read_bytes()
        helper = fixture.repository / reader.READER_PATH
        helper.write_bytes(Path(reader.__file__).read_bytes())
        bootstrap_path = fixture.repository / reader.BOOTSTRAP_PATH
        bootstrap_path.write_bytes(bootstrap_path.read_bytes() + b"\n# reader-only fixture amendment\n")
        fixture.git("add", ".")
        fixture.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "reader-only amendment")
        active_path = patch.object(reader, "__file__", str(helper))
        active_path.start()
        self.addCleanup(active_path.stop)
        active_bytes = patch.object(bootstrap, "_active_producer_bytes",
            side_effect=lambda relative: (fixture.repository / relative).read_bytes())
        active_bytes.start()
        self.addCleanup(active_bytes.stop)
        return original_intent, original_capture

    def test_v1_unchanged_and_v2_replays_same_physical_evidence(self):
        fixture = self.fixture()
        ordinary = bootstrap.admit_bootstrap_qualification(fixture.retained, fixture.candidate,
            output=fixture.artifacts / "ordinary.json")
        ordinary_doc = bootstrap.parse_bootstrap_admission(ordinary.admission_path.read_bytes())
        self.assertEqual(ordinary_doc["schema_version"], 1)
        self.assertNotIn("reader_identity", ordinary_doc)
        # These two files were created by this temporary fixture's v1 exercise.
        # Remove only its derived sidecars so v2 can exercise the unchanged
        # create-only publication path; production never overwrites a v1 record.
        for key in ("generated_project_manifest", "dependency_manifest"):
            (fixture.artifacts / ordinary_doc["qualification"][key]["relative_path"]).unlink()
        old_intent, old_capture = self.advance_reader(fixture)
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            bootstrap.admit_bootstrap_qualification(fixture.retained, fixture.candidate,
                output=fixture.artifacts / "strict.json")
        amended = bootstrap.admit_bootstrap_qualification(fixture.retained, fixture.candidate,
            output=fixture.artifacts / "amended.json", allow_reader_compatibility=True)
        document = bootstrap.parse_bootstrap_admission(amended.admission_path.read_bytes())
        self.assertEqual(document["schema_version"], 2)
        self.assertEqual(document["source"], ordinary_doc["source"])
        for key in set(ordinary_doc) - {"schema_version"}:
            self.assertEqual(document[key], ordinary_doc[key], key)
        self.assertEqual(fixture.retained.intent_path.read_bytes(), old_intent)
        self.assertEqual(fixture.retained.capture_path.read_bytes(), old_capture)
        arguments = dict(artifact_root=fixture.artifacts, admission_relative_path="amended.json",
            candidate=fixture.candidate, expected_run=fixture.run, expected_source=fixture.source)
        with self.assertRaisesRegex(bootstrap.BootstrapQualificationError, "explicit"):
            bootstrap.load_and_revalidate_bootstrap_qualification(**arguments)
        self.assertEqual(bootstrap.load_and_revalidate_bootstrap_qualification(**arguments,
            allow_reader_compatibility=True), amended)
        # A physically present, structurally valid forgery still fails replay.
        forged = copy.deepcopy(document)
        forged["reader_identity"]["commit"] = "a" * 40
        amended.admission_path.write_bytes(canonical_bytes(forged))
        with self.assertRaisesRegex(bootstrap.BootstrapQualificationError, "independently revalidated"):
            bootstrap.load_and_revalidate_bootstrap_qualification(**arguments, allow_reader_compatibility=True)
        forged = copy.deepcopy(document)
        forged["reader_identity"]["original_source"]["commit"] = "a" * 40
        with self.assertRaisesRegex(bootstrap.BootstrapQualificationError, "original source"):
            bootstrap.parse_bootstrap_admission(canonical_bytes(forged))

    def test_amended_reader_retains_capture_commitment_and_creation_strictness(self):
        fixture = self.fixture()
        self.advance_reader(fixture)
        with self.assertRaises(bootstrap.BootstrapQualificationError):
            bootstrap.execute_bootstrap_qualification(fixture.source, fixture.run, fixture.configuration)
        captured = decode_canonical_bytes(fixture.retained.capture_path.read_bytes())
        captured["intent_sha256"] = "a" * 64
        fixture.retained.capture_path.write_bytes(canonical_bytes(captured))
        with self.assertRaisesRegex(bootstrap.BootstrapQualificationError, "intent commitment"):
            bootstrap.revalidate_bootstrap_execution(fixture.retained, expected_source=fixture.source,
                expected_run=fixture.run, allow_reader_compatibility=True)
        # Even rewriting both self-bound records cannot relocate the original
        # invocation: expected_source remains the independent path authority.
        intent = decode_canonical_bytes(fixture.retained.intent_path.read_bytes())
        relocated = str(fixture.repository.parent / "invented-source")
        intent["source"]["repository_root"] = relocated
        intent["invocation"]["working_directory"] = relocated
        intent["invocation"]["argv"][2] = relocated
        fixture.retained.intent_path.write_bytes(canonical_bytes(intent))
        captured["intent_sha256"] = hashlib.sha256(canonical_bytes(intent)).hexdigest()
        fixture.retained.capture_path.write_bytes(canonical_bytes(captured))
        with self.assertRaisesRegex(bootstrap.BootstrapQualificationError, "independent authority"):
            bootstrap.revalidate_bootstrap_execution(fixture.retained, expected_source=fixture.source,
                expected_run=fixture.run, allow_reader_compatibility=True)


if __name__ == "__main__":
    unittest.main()
