from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest

from Scripts.qualification import generated_project_evidence as evidence
from Scripts.qualification.restore_build_source import GENERATED_PROJECT_FILES, _generated_project_identity


def make_project_evidence_fixture(run: Path, commit: str, tree: str, spec: bytes) -> Path:
    """Synthetic actual build tree and qualification inputs; no tools/builds run."""
    project = run / "source/MacScope/MacScope.xcodeproj"
    project.mkdir(parents=True)
    (project.parent / "project.yml").write_bytes(spec)
    for name in GENERATED_PROJECT_FILES:
        path = project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'{"objects":{},"rootObject":"fixture"}\n' if name == "project.xcproj" else name.encode())
    inputs = {
        "schema_version": 4, "mode": "full-test", "build_source_root": str(run / "source"),
        "source_identity": {"git_head_commit": commit, "git_head_tree": tree,
                            "source_files_sha256": "3" * 64, "repository_clean": True},
    }
    (run / "QUALIFICATION_INPUTS.json").write_bytes(evidence._canonical(inputs) + b"\n")
    return project


class GeneratedProjectEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.run = Path(self.temp.name).resolve() / "run.exact"
        self.spec = b"name: MacScope\n"
        self.project = make_project_evidence_fixture(self.run, "1" * 40, "2" * 40, self.spec)
        self.identity = _generated_project_identity(self.project, require_complete=True)
        self.arguments = dict(commit="1" * 40, tree="2" * 40, project_yml_sha256=hashlib.sha256(self.spec).hexdigest())

    def tearDown(self):
        self.temp.cleanup()

    def test_capture_retains_actual_bytes_and_survives_source_project_cleanup(self):
        retained = evidence.capture(self.run, self.identity)
        self.assertEqual(retained.read_bytes(), (self.project / "project.xcproj").read_bytes())
        self.assertEqual(len(evidence.evidence_files(self.run)), 10)
        self.assertFalse((retained.parent / "project.pbxproj").exists())
        self.assertEqual(evidence.capture(self.run, self.identity), retained)
        shutil.rmtree(self.project)
        self.assertEqual(evidence.validate(self.run, **self.arguments), retained)

    def test_missing_or_partial_evidence_has_no_fallback(self):
        with self.assertRaises(evidence.GeneratedProjectEvidenceError):
            evidence.validate(self.run, **self.arguments)
        (self.run / evidence.DIRECTORY).mkdir()
        with self.assertRaises(evidence.GeneratedProjectEvidenceError):
            evidence.capture(self.run, self.identity)

    def test_all_ten_retained_evidence_members_reject_byte_changes(self):
        evidence.capture(self.run, self.identity)
        paths = evidence.evidence_files(self.run)
        self.assertEqual(len(paths), 10)
        for path in paths:
            saved = path.read_bytes()
            with self.subTest(member=str(path.relative_to(self.run))):
                path.write_bytes(saved + b"changed")
                with self.assertRaises(evidence.GeneratedProjectEvidenceError):
                    evidence.validate(self.run, **self.arguments)
                path.write_bytes(saved)
        evidence.validate(self.run, **self.arguments)

    def test_legacy_or_dual_project_inventory_is_not_json_evidence(self):
        evidence.capture(self.run, self.identity)
        project = self.run / evidence.DIRECTORY / "MacScope.xcodeproj"
        (project / "project.pbxproj").write_bytes(b"legacy")
        with self.assertRaises(evidence.GeneratedProjectEvidenceError):
            evidence.validate(self.run, **self.arguments)
        (project / "project.xcproj").unlink()
        with self.assertRaises(evidence.GeneratedProjectEvidenceError):
            evidence.validate(self.run, **self.arguments)

    def test_pre_xcode_project_drift_is_rejected_before_capture(self):
        (self.project / "project.xcproj").write_bytes(b"changed\n")
        with self.assertRaisesRegex(evidence.GeneratedProjectEvidenceError, "pre-Xcode"):
            evidence.capture(self.run, self.identity)
        self.assertFalse((self.run / evidence.DIRECTORY).exists())

    def test_tampering_and_unsafe_retained_files_rejected(self):
        retained = evidence.capture(self.run, self.identity)
        saved = retained.read_bytes()
        retained.write_bytes(b"stale original project\n")
        with self.assertRaises(evidence.GeneratedProjectEvidenceError):
            evidence.validate(self.run, **self.arguments)
        retained.write_bytes(saved)
        alias = self.run / "hardlink"
        os.link(retained, alias)
        with self.assertRaises(evidence.GeneratedProjectEvidenceError):
            evidence.validate(self.run, **self.arguments)
        alias.unlink()
        retained.unlink()
        retained.symlink_to(self.project / "project.xcproj")
        with self.assertRaises(evidence.GeneratedProjectEvidenceError):
            evidence.validate(self.run, **self.arguments)

    def test_source_and_schema_mismatch_rejected(self):
        evidence.capture(self.run, self.identity)
        for key, value in (("commit", "4" * 40), ("tree", "4" * 40), ("project_yml_sha256", "4" * 64)):
            with self.subTest(key=key), self.assertRaises(evidence.GeneratedProjectEvidenceError):
                evidence.validate(self.run, **{**self.arguments, key: value})
        manifest = self.run / evidence.DIRECTORY / evidence.MANIFEST
        value = json.loads(manifest.read_bytes())
        value["extra"] = True
        manifest.write_bytes(evidence._canonical(value))
        with self.assertRaises(evidence.GeneratedProjectEvidenceError):
            evidence.validate(self.run, **self.arguments)

    def test_cross_run_copy_cannot_claim_same_source_as_actual_build(self):
        evidence.capture(self.run, self.identity)
        other = self.run.parent / "run.other"
        make_project_evidence_fixture(other, "1" * 40, "2" * 40, self.spec)
        shutil.copytree(self.run / evidence.DIRECTORY, other / evidence.DIRECTORY)
        with self.assertRaisesRegex(evidence.GeneratedProjectEvidenceError, "source identity"):
            evidence.validate(other, **self.arguments)

    def test_nonobject_qualification_is_a_controlled_refusal(self):
        receipt = self.run / "QUALIFICATION_INPUTS.json"
        for value in ([], {"source_identity": []}):
            receipt.write_bytes(evidence._canonical(value))
            with self.assertRaisesRegex(evidence.GeneratedProjectEvidenceError, "object source"):
                evidence.capture(self.run, self.identity)
