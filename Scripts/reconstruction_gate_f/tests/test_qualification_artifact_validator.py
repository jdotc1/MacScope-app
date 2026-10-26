import copy
import hashlib
import json
import os
import plistlib
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from Scripts.ws24_emit_installed_qualification_report import ReportError
from Scripts.tests.test_source_export_provenance import SourceRepository
from Scripts.source_export_provenance import SourceExportError

from Scripts.reconstruction_gate_f import qualification_artifact_validator as q


class QualificationArtifactTests(unittest.TestCase):
    def test_reviewed_dwarf_overload_gap_retains_exact_skips_without_native_credit(self):
        cases = (
            ("DWARFCFITests", "testPackage05FixtureRecoversFDEProgramsInSectionOrder"),
            ("DWARFGlobalTests", "testPackage03FixtureRecoversNamedFileScopeGlobals"),
            ("DWARFLocationTests", "testPackage02FixtureRecoversNormalizedLocations"),
            ("DWARFLoclistTests", "testPackage04FixtureRecoversNormalizedLoclists"),
            ("DWARFRnglistTests", "testPackage06FixtureRecoversLexicalBlockRanges"),
        )
        reason = "Test skipped - handoff_package/sections fixture is unavailable"
        summary = dict(result="Passed", totalTestCount=5, passedTests=0,
                       failedTests=0, skippedTests=5, expectedFailures=0)
        suites = [dict(nodeType="Test Suite", name=suite, children=[dict(
            nodeType="Test Case", nodeIdentifier=f"{suite}/{method}()", result="Skipped",
            children=[dict(nodeType="Skip Message", name=reason)])]) for suite, method in cases]
        tests = dict(testNodes=[dict(nodeType="Unit test bundle", name="CoreTests", children=suites)])
        repository = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory(dir=os.environ.get("MACSCOPE_TEST_TEMP_ROOT")) as temporary:
            root = Path(temporary)
            for suite, _ in cases:
                relative = Path("MacScope/Tests/CoreTests") / (suite + ".swift")
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((repository / relative).read_bytes())
            allowlist = root / "docs/qualification/skip-allowlist.json"
            allowlist.parent.mkdir(parents=True)
            allowlist.write_text(json.dumps(dict(schemaVersion=2,
                countingRule="direct-and-file-local-transitive-swift-test-methods",
                knownGap="same-name overloads are not resolved", entries=[])))
            candidate = SimpleNamespace(source=SimpleNamespace(commit="a", tree="b"))
            with patch.object(q, "validate_source_export", return_value={"verified": True}), \
                    patch.object(q, "_inspect_xcresult", return_value=(summary, tests, "digest")) as inspect:
                def validate():
                    return q.validate_full_coretests_xcresult(Path("/fixture"), candidate=candidate,
                        source_root=root, integration_ref="ref")
                result = validate()
                self.assertEqual(inspect.call_args.args[0], Path("/fixture"))
                self.assertEqual(result["passed_selector_count"], 0)
                self.assertEqual(result["skipped_selector_count"], 5)
                self.assertEqual({row["status"] for row in result["selectors"]}, {"skipped"})
                self.assertEqual([row["observed_reason"] for row in result["skips"]], [reason] * 5)
                self.assertTrue(all("overload" in row["reviewed_reason"] for row in result["skips"]))
                first = suites[0]["children"][0]
                for bad_reason in ("arbitrary failure", "", reason + " changed"):
                    first["children"][0]["name"] = bad_reason
                    with self.subTest(reason=bad_reason), self.assertRaises(q.QualificationArtifactError):
                        validate()
                first["children"][0]["name"] = reason
                for identifier in ("DWARFCFITests/testUnknown()",
                                   "NativeDecompilerLiveXPCTests/testSignedServiceHonorsSupervisionAndRelaunchContract()"):
                    first["nodeIdentifier"] = identifier
                    with self.subTest(identifier=identifier), self.assertRaises(q.QualificationArtifactError):
                        validate()
                first["nodeIdentifier"] = cases[0][0] + "/" + cases[0][1] + "()"
                source = root / "MacScope/Tests/CoreTests/DWARFCFITests.swift"
                original = source.read_bytes()
                source.write_bytes(original + b"\n// changed source\n")
                with self.assertRaises(q.QualificationArtifactError):
                    validate()
                source.unlink()
                with self.assertRaises(q.QualificationArtifactError):
                    validate()
                source.write_bytes(original)
                with self.assertRaises(q.QualificationArtifactError):
                    q.validate_selected_xcresult(Path("/fixture"), selected_scope="CoreTests", allowed_skips={})

    def test_release_products_use_release_identity_not_debug_qualification_hash(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("MACSCOPE_TEST_TEMP_ROOT")) as temporary:
            run = Path(temporary).resolve()
            app = run / "DerivedData/Build/Products/Release/MacScope.app"
            executable = app / "Contents/MacOS/MacScope"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"distinct sealed Release executable")
            executable.chmod(0o755)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "org.macscope.app", "CFBundleExecutable": "MacScope"}))
            signature = app / "Contents/_CodeSignature/CodeResources"
            signature.parent.mkdir()
            signature.write_bytes(b"sealed signature resource fixture")
            physical = q._bundle_identity(app, executable)
            release_sha = physical["executable_sha256"]
            debug_sha = hashlib.sha256(b"distinct Debug qualification executable").hexdigest()
            self.assertNotEqual(debug_sha, release_sha)
            application = SimpleNamespace(bundle_identifier=physical["bundle_identifier"],
                bundle_sha256=physical["content_sha256"], closed_tree_sha256=physical["closed_tree_sha256"],
                executable_sha256=release_sha, qualification_executables=(SimpleNamespace(
                    identity_id="app", bundle_identifier="org.macscope.app", sha256=debug_sha),))
            candidate = SimpleNamespace(source=SimpleNamespace(commit="a", tree="b"), application=application)
            observation = {"app_executable_sha256": release_sha}
            # Qualification transaction/source verification have their own real-fixture
            # tests; isolate the candidate binding here without mocking physical bytes.
            with patch.object(q, "validate_qualification_build", return_value=observation) as build, \
                 patch.object(q, "validate_source_export", return_value={}) as source:
                def validate(mode="release"):
                    return q.validate_qualification_products(candidate, run / "receipt.json",
                        integration_ref="refs/remotes/github/main", dependency_cache_root=run / "cache", mode=mode)
                for mode in ("release", "full-test"):
                    result = validate(mode)
                    self.assertEqual(result["bundle_sha256"], physical["content_sha256"])
                    self.assertEqual(build.call_args.args[0].app_bundle, app)
                    self.assertEqual(build.call_args.args[0].expected_mode, mode)
                    source.assert_called_with(candidate, run / "source", "refs/remotes/github/main")
                for field in ("bundle_identifier", "bundle_sha256", "closed_tree_sha256", "executable_sha256"):
                    previous = getattr(application, field)
                    setattr(application, field, "wrong")
                    with self.subTest(field=field), self.assertRaises(q.QualificationArtifactError):
                        validate()
                    setattr(application, field, previous)
                signature.write_bytes(b"mutated signature bytes")
                with self.assertRaises(q.QualificationArtifactError):
                    validate()
                signature.write_bytes(b"sealed signature resource fixture")
                observation["app_executable_sha256"] = debug_sha
                with self.assertRaises(q.QualificationArtifactError):
                    validate()
                observation["app_executable_sha256"] = release_sha
                build.side_effect = ValueError("qualification inputs rejected")
                with self.assertRaisesRegex(ValueError, "qualification inputs rejected"):
                    validate()
                build.side_effect = None
                source.side_effect = SourceExportError("source closure rejected")
                with self.assertRaisesRegex(SourceExportError, "source closure rejected"):
                    validate()

    def test_full_suite_skips_use_source_policy_not_observed_reason_as_authority(self):
        summary, tests, case = self.documents()
        case.update(result="Skipped", children=[dict(nodeType="Skip Message", name="actual fixture missing")])
        summary.update(passedTests=0, skippedTests=1)
        with tempfile.TemporaryDirectory(dir=os.environ.get("MACSCOPE_TEST_TEMP_ROOT")) as temporary:
            root = Path(temporary)
            test_source = root / "MacScope/Tests/CoreTests/Suite.swift"
            test_source.parent.mkdir(parents=True)
            test_source.write_text('class Suite: XCTestCase { func testOne() throws { throw XCTSkip("missing") } }')
            allowlist = root / "docs/qualification/skip-allowlist.json"
            allowlist.parent.mkdir(parents=True)
            document = dict(schemaVersion=2, countingRule="direct-and-file-local-transitive-swift-test-methods",
                knownGap="lexical analysis only", entries=[dict(file="CoreTests/Suite.swift", method="testOne",
                reason="Reviewed external fixture availability condition.")])
            allowlist.write_text(json.dumps(document))
            candidate = SimpleNamespace(source=SimpleNamespace(commit="a", tree="b"))
            with patch.object(q, "validate_source_export", return_value={"verified": True}), \
                 patch.object(q, "_inspect_xcresult", return_value=(summary, tests, "digest")):
                result = q.validate_full_coretests_xcresult(Path("/fixture"), candidate=candidate,
                    source_root=root, integration_ref="ref")
                self.assertEqual(result["passed_selector_count"], 0)
                self.assertEqual(result["skipped_selector_count"], 1)
                self.assertEqual(result["skips"][0]["observed_reason"], "actual fixture missing")
                self.assertEqual(result["skips"][0]["reviewed_reason"], document["entries"][0]["reason"])
                test_source.write_text('class Suite: XCTestCase { func testOne() {} }')
                with self.assertRaises(q.QualificationArtifactError):
                    q.validate_full_coretests_xcresult(Path("/fixture"), candidate=candidate,
                        source_root=root, integration_ref="ref")
            with self.assertRaises(q.QualificationArtifactError):
                q.project_xcresult(summary, tests, selected_scope="CoreTests/Suite", allowed_skips={},
                    _reviewed_full_suite_skips={"CoreTests/Suite/testOne": "reviewed reason"})

    def test_completed_restored_source_accepts_external_generated_evidence_only(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("MACSCOPE_TEST_TEMP_ROOT")) as temporary:
            base = Path(temporary).resolve()
            repository = SourceRepository(base / "repository")
            run = base / "run"
            run.mkdir()
            source = run / "source"
            exported = repository.export(source)
            self.assertEqual(exported.returncode, 0, exported.stderr)
            candidate = SimpleNamespace(source=SimpleNamespace(
                commit=repository.git("rev-parse", "HEAD"),
                tree=repository.git("rev-parse", "HEAD^{tree}"), dirty=False))
            reference = "refs/remotes/gitfox-local/feature/task11-local-premerge-current"
            retained = run / "generated-project-evidence/MacScope.xcodeproj"
            retained.mkdir(parents=True)
            (retained / "project.pbxproj").write_text("retained generated evidence")
            q.validate_source_export(candidate, source, reference)
            for relative in ("MacScope/DependencyRoots.local.xcconfig",
                             "MacScope/MacScope.xcodeproj/project.pbxproj", "unexpected.txt"):
                extra = source / relative
                extra.parent.mkdir(parents=True, exist_ok=True)
                extra.write_text("incomplete scaffold or unauthorized addition")
                with self.assertRaises(SourceExportError):
                    q.validate_source_export(candidate, source, reference)
                extra.unlink()
            (source / "MacScope/App/Main.swift").write_text("unauthorized source mutation")
            with self.assertRaises(SourceExportError):
                q.validate_source_export(candidate, source, reference)

    def documents(self):
        summary = dict(result="Passed", totalTestCount=1, passedTests=1,
                       failedTests=0, skippedTests=0, expectedFailures=0)
        case = dict(nodeType="Test Case", name="testOne()", nodeIdentifier="Suite/testOne()",
                    result="Passed", children=[])
        tests = {"testNodes": [dict(nodeType="Unit test bundle", name="CoreTests", children=[
            dict(nodeType="Test Suite", name="Suite", children=[case])])]}
        return summary, tests, case

    def project(self, summary, tests, skips=None):
        return q.project_xcresult(summary, tests,
            expected_selectors=["CoreTests/Suite/testOne"], allowed_skips=skips or {})

    def test_exact_cases_derive_counts(self):
        summary, tests, _ = self.documents()
        result = self.project(summary, tests)
        self.assertEqual(result["passed_selector_count"], 1)
        self.assertEqual(result["selectors"], [dict(test_identifier="CoreTests/Suite/testOne", status="passed")])

    def test_false_green_and_missing_or_wrong_selectors_rejected(self):
        for mutation in ("failure", "count", "missing", "duplicate", "bundle", "suite", "unexpected", "retry"):
            with self.subTest(mutation=mutation):
                summary, tests, case = self.documents()
                suite = tests["testNodes"][0]["children"][0]
                if mutation == "failure": case["result"] = "Failed"
                if mutation == "count": summary["passedTests"] = True
                if mutation == "missing": suite["children"] = []
                if mutation == "duplicate": suite["children"].append(copy.deepcopy(case))
                if mutation == "bundle": tests["testNodes"][0]["name"] = "Other"
                if mutation == "suite": suite["name"] = "Other"
                if mutation == "unexpected": case["nodeIdentifier"] = "Suite/testOther()"
                if mutation == "retry": case["children"] = [dict(nodeType="Test Case Run", result="Failed")]
                with self.assertRaises((q.QualificationArtifactError, ReportError)):
                    self.project(summary, tests)

    def test_selected_suite_proves_recorded_outcomes_not_discovery_completeness(self):
        summary, tests, _ = self.documents()
        value = q.project_xcresult(summary, tests, selected_scope="CoreTests/Suite", allowed_skips={})
        self.assertNotIn("expected_selector_count", value)
        self.assertEqual(value["executed_selector_count"], 1)
        self.assertIn("not-source-enumeration", value["coverage_claim"])
        with self.assertRaises(q.QualificationArtifactError):
            q.project_xcresult(summary, tests, selected_scope="CoreTests/Other", allowed_skips={})
        tests["testNodes"] = []
        with self.assertRaises(q.QualificationArtifactError):
            q.project_xcresult(summary, tests, selected_scope="CoreTests", allowed_skips={})

    def test_only_exact_skips_are_allowed(self):
        summary, tests, case = self.documents()
        case["result"] = "Skipped"
        case["children"] = [dict(nodeType="Skip Message", name="fixture unavailable")]
        summary.update(passedTests=0, skippedTests=1)
        with self.assertRaises(q.QualificationArtifactError): self.project(summary, tests)
        with self.assertRaises(q.QualificationArtifactError):
            self.project(summary, tests, {"CoreTests/Suite/testOne": "other"})
        self.assertEqual(self.project(summary, tests, {"CoreTests/Suite/testOne": "fixture unavailable"})["skipped_selector_count"], 1)

    def test_physical_result_mutation_rejected(self):
        summary, tests, _ = self.documents()
        with patch.object(q, "result_bundle_sha256", side_effect=["a", "a", "a", "b"]), \
             patch.object(q.shutil, "copytree"), \
             patch.object(q, "xcresult_test_summary", return_value=summary), \
             patch.object(q, "xcresult_test_nodes", return_value=tests):
            with self.assertRaises(q.QualificationArtifactError):
                q.validate_xcresult(Path("/fixture"), expected_selectors=["CoreTests/Suite/testOne"], allowed_skips={})

    def test_reader_cache_is_confined_to_verified_inspection_copy(self):
        summary, tests, _ = self.documents()
        with tempfile.TemporaryDirectory(dir=os.environ.get("MACSCOPE_TEST_TEMP_ROOT")) as temporary:
            root = Path(temporary).resolve()
            original = root / "Original.xcresult"
            original.mkdir()
            (original / "Info.plist").write_bytes(b"original")
            before = q.result_bundle_sha256(original)
            def reader(path, index):
                self.assertNotEqual(path, original)
                (path / "database.sqlite3").write_bytes(b"derived cache")
                return summary
            with patch.object(q, "xcresult_test_summary", side_effect=reader), \
                 patch.object(q, "xcresult_test_nodes", return_value=tests):
                result = q.validate_selected_xcresult(original, selected_scope="CoreTests/Suite",
                    allowed_skips={}, scratch_root=root)
            self.assertEqual(result["xcresult_bundle_sha256"], before)
            self.assertEqual(q.result_bundle_sha256(original), before)
            self.assertFalse((original / "database.sqlite3").exists())

    def test_source_identity_must_match_verified_candidate(self):
        candidate = SimpleNamespace(source=SimpleNamespace(commit="a", tree="b", dirty=False))
        provenance = dict(git_head_commit="a", git_head_tree="b", canonical_integration_commit="a",
                          canonical_integration_ref="refs/remotes/github/main", repository_clean=True)
        with patch.object(q, "load_verified_export", return_value=(provenance, {})) as verify:
            self.assertEqual(q.validate_source_export(candidate, Path("/fixture"), "refs/remotes/github/main"), provenance)
            verify.assert_called_with(Path("/fixture"), require_closed_tree=True)
            provenance["git_head_tree"] = "wrong"
            with self.assertRaises(q.QualificationArtifactError):
                q.validate_source_export(candidate, Path("/fixture"), "refs/remotes/github/main")


if __name__ == "__main__":
    unittest.main()
