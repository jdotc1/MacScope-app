"""Physical T10C closure tests; no replacement of public admission validators."""
from __future__ import annotations

import copy
import hashlib
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from Scripts.reconstruction_gate_f import t10c_closure_adapter as adapter
from Scripts.reconstruction_gate_f.tests import parsed_candidate
from Scripts.reconstruction_gate_f.schema import EvidenceStatus
from Scripts.reconstruction_task10_adjudication import core

REPOSITORY = Path(__file__).resolve().parents[3]


class T10CClosurePhysicalTests(unittest.TestCase):
    def setUp(self):
        configured = os.environ.get("MACSCOPE_T10C_HISTORICAL_ROOT")
        if not configured or not Path(configured).is_dir():
            self.skipTest("MACSCOPE_T10C_HISTORICAL_ROOT is not available")
        historical = Path(configured)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.historical = self.root / "historical"
        shutil.copytree(historical, self.historical)
        self.digest = hashlib.sha256((self.historical / "bundle.sha256").read_bytes()).hexdigest()

    def test_historical_exact_physical_closure_retains_three_gaps(self):
        fence = adapter._Fence()
        _ledger, _source, adjudication = adapter._historical_bundle(self.historical, self.digest, fence)
        self.assertEqual(adjudication["outcomeCounts"]["confirmed-current-evidence-gap"], 3)
        fence.check()

    def _physical_producer_source(self):
        source = self.root / "sealed-source"
        shutil.copytree(REPOSITORY / "Scripts", source / "Scripts",
                        ignore=shutil.ignore_patterns("__pycache__", "tests"))
        catalog = Path("Scripts/acceptance/installed_selectors.json")
        (source / catalog).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPOSITORY / catalog, source / catalog)
        return source

    def test_producer_closure_uses_real_repository_relative_module_and_catalog_paths(self):
        source = self._physical_producer_source()
        fence = adapter._Fence()
        adapter._producer_closure(None, source, fence)
        self.assertIn((source, "Scripts/reconstruction_gate_f/t10c_closure_adapter.py"), fence.observations)
        self.assertIn((REPOSITORY, "Scripts/acceptance/installed_selectors.json"),
                      fence.observations)
        fence.check()

    def test_producer_closure_rejects_changed_loaded_module_and_selector_catalog_bytes(self):
        source = self._physical_producer_source()
        for relative in ("Scripts/reconstruction_gate_f/t10c_closure_adapter.py",
                         "Scripts/acceptance/installed_selectors.json"):
            with self.subTest(relative=relative):
                path = source / relative
                original = path.read_bytes()
                path.write_bytes(original + b"\n")
                with self.assertRaisesRegex(ValueError, "differs from sealed source"):
                    adapter._producer_closure(None, source, adapter._Fence())
                path.write_bytes(original)

    def test_producer_closure_keeps_final_identity_fences_for_module_and_catalog(self):
        source = self._physical_producer_source()
        for relative in ("Scripts/reconstruction_gate_f/t10c_closure_adapter.py",
                         "Scripts/acceptance/installed_selectors.json"):
            with self.subTest(relative=relative):
                fence = adapter._Fence()
                adapter._producer_closure(None, source, fence)
                path = source / relative
                replacement = path.with_suffix(path.suffix + ".replacement")
                shutil.copyfile(path, replacement)
                os.replace(replacement, path)
                with self.assertRaisesRegex(ValueError, "final fence"):
                    fence.check()

    def test_every_historical_member_is_checked(self):
        for name in sorted(adapter.gates._T10C_BUNDLE_FILES):
            with self.subTest(name=name):
                path = self.historical / name
                original = path.read_bytes()
                path.write_bytes(original + b" ")
                with self.assertRaises(ValueError):
                    adapter._historical_bundle(self.historical, self.digest, adapter._Fence())
                path.write_bytes(original)

    def test_substituted_historical_ledger_rejected(self):
        with self.assertRaises(ValueError):
            adapter._historical_bundle(self.historical, "0" * 64, adapter._Fence())

    def test_fence_rejects_same_bytes_inode_replacement(self):
        fence = adapter._Fence()
        path = self.historical / "README.md"
        data = fence.read(self.historical, path.name)
        path.unlink()
        path.write_bytes(data)
        with self.assertRaises(ValueError):
            fence.check()

    def test_fence_rejects_symlink_hardlink_directory_and_traversal(self):
        original = self.historical / "README.md"
        (self.root / "link").symlink_to(original)
        os.link(original, self.root / "hardlink")
        for root, name in ((self.root, "link"), (self.root, "hardlink"),
                           (self.root, "historical"), (self.historical, "../link")):
            with self.subTest(name=name), self.assertRaises((ValueError, OSError)):
                adapter._Fence().read(root, name)

    def test_source_is_freshly_derived_from_gitless_physical_files(self):
        source = self.root / "source"
        for spec in core.FINDING_SPECS:
            target = source / spec.current_path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPOSITORY / spec.current_path, target)
        candidate = parsed_candidate()
        fence = adapter._Fence()
        drift = adapter._source_drift(candidate, source, fence)
        self.assertEqual(drift["mappingCount"], 18)
        self.assertEqual(drift["currentSource"]["headCommit"], candidate.source.commit)
        self.assertEqual([row["findingID"] for row in drift["mappings"]],
                         [spec.finding_id for spec in core.FINDING_SPECS])
        fence.check()
        first = source / core.FINDING_SPECS[0].current_path
        first.write_bytes(first.read_bytes() + b"\n// source mutation\n")
        with self.assertRaises(ValueError):
            fence.check()

    def test_exact_tokens_and_unique_anchor_are_required(self):
        source = self.root / "source"
        for spec in core.FINDING_SPECS:
            path = source / spec.current_path
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPOSITORY / spec.current_path, path)
        spec = core.FINDING_SPECS[0]
        path = source / spec.current_path
        original = path.read_text()
        for changed in (original.replace(spec.required_tokens[0], "removed-token"),
                        original + "\n" + spec.anchor):
            path.write_text(changed)
            with self.assertRaises(ValueError):
                adapter._source_drift(parsed_candidate(), source, adapter._Fence())

    def test_schema2_changes_exact_three_classifications(self):
        _, drift, old = adapter._historical_bundle(self.historical, self.digest, adapter._Fence())
        before = copy.deepcopy(old)
        drift = copy.deepcopy(drift)
        drift["mappings"] = [row for row in drift["mappings"] if row["findingID"] != core.RETIRED_FINDING_ID]
        drift["mappingCount"] = len(drift["mappings"])
        new = adapter._adjudication(old, drift)
        self.assertEqual(old, before)
        self.assertEqual(new["schemaVersion"], 2)
        self.assertEqual(new["openSeverityCounts"], {"P1": 0, "P2": 0})
        self.assertEqual(new["findingCount"], 18)
        self.assertEqual(old["findingCount"], 19)
        prior_by_id = {row["findingID"]: row for row in old["findings"]}
        changed = [row["findingID"] for row in new["findings"]
                   if row != prior_by_id[row["findingID"]]]
        self.assertEqual(changed, list(adapter.gates._T10C_EVIDENCE_GAP_IDS))

    def test_unknown_or_favorable_historical_schema_rejected(self):
        path = self.historical / "FINDING_ADJUDICATION.json"
        import json
        original = json.loads(path.read_bytes())
        for version in (2, 3):
            value = copy.deepcopy(original)
            value["schemaVersion"] = version
            path.write_bytes(core.canonical_json_bytes(value))
            ledger = {name: hashlib.sha256((self.historical / name).read_bytes()).hexdigest()
                      for name in adapter.gates._T10C_BUNDLE_FILES}
            raw = adapter._ledger_bytes(ledger)
            (self.historical / "bundle.sha256").write_bytes(raw)
            with self.assertRaises(ValueError):
                adapter._historical_bundle(self.historical, hashlib.sha256(raw).hexdigest(), adapter._Fence())

    def _installed_factory(self):
        from Scripts.reconstruction_gate_f.tests.test_executor_receipt import GateFExecutorReceiptTests
        fixture = GateFExecutorReceiptTests(methodName="runTest")
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        return fixture

    def _physical_matrix(self, fixture, request):
        adapter.gates.validate_installed_task10_workflow_artifacts(
            candidate=fixture.candidate, command_id=request["command_id"],
            artifacts=request["artifacts"], artifact_root=fixture.root,
            execution_report_artifact_id=request["execution_report_artifact_id"],
            result=EvidenceStatus.PASSED,
            generated_artifacts=request["command_authority"]["generated_artifacts"],
            generated_logs=request["command_authority"]["generated_logs"])

    def test_matrix_screenshot_handoff_is_metadata_fenced(self):
        fixture = self._installed_factory()
        request = fixture._installed_workflow_request()
        self._physical_matrix(fixture, request)
        fence = adapter._Fence()
        adapter._matrix_handoff(request, SimpleNamespace(artifact_root=fixture.root),
                                {"installed_matrix_receipt": "@installed_matrix_receipt@"}, fence)
        fence.check()
        png = next((root / name) for root, name in fence.observations if name.endswith(".png"))
        payload = png.read_bytes()
        png.unlink()
        png.write_bytes(payload)
        # Physical semantic equality alone cannot detect identical-byte inode substitution.
        self._physical_matrix(fixture, request)
        with self.assertRaisesRegex(ValueError, "final fence"):
            fence.check()

    def test_physical_matrix_rejects_failed_skipped_and_missing_screenshots(self):
        for options in ({"matrix_result": "failed"}, {"skipped_selector_count": 1},
                        {"semantic_manifest_failed": True}, {"presentation_image_count": 27}):
            with self.subTest(options=options):
                fixture = self._installed_factory()
                request = fixture._installed_workflow_request(**options)
                with self.assertRaises(ValueError):
                    self._physical_matrix(fixture, request)

    def test_accessibility_physical_screenshot_mutation_rejected(self):
        fixture = self._installed_factory()
        request = fixture._installed_accessibility_request()
        arguments = dict(candidate=fixture.candidate, command_id=request["command_id"],
            artifacts=request["artifacts"], artifact_root=fixture.root,
            execution_report_artifact_id=request["execution_report_artifact_id"],
            result=EvidenceStatus.PASSED,
            generated_artifacts=request["command_authority"]["generated_artifacts"],
            generated_logs=request["command_authority"]["generated_logs"])
        adapter.gates.validate_installed_accessibility_artifacts(**arguments)
        image = next(a for a in request["artifacts"] if a["media_type"] == "image/png")
        path = fixture.root / image["relative_path"]
        path.write_bytes(path.read_bytes() + b"mutation")
        with self.assertRaises(ValueError):
            adapter.gates.validate_installed_accessibility_artifacts(**arguments)

    def test_public_entrypoints_require_retained_typed_admission(self):
        for function in (adapter.derive_t10c_closure, adapter.validate_t10c_closure):
            for value in (None, {}, {"schema_version": 2, "result": "passed", "p1_count": 0}):
                with self.subTest(function=function.__name__, value=value), self.assertRaises(ValueError):
                    function(value)


if __name__ == "__main__":
    unittest.main()
