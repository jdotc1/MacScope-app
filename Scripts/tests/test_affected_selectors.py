#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import re
import tempfile
import unittest

from Scripts.ci import affected_selectors as subject

CLASSES = {
    "MacIRBuilderTests": ["CoreTests/MacIRBuilderTests"],
    "MacIRUnknownDestinationTests": ["CoreTests/MacIRUnknownDestinationTests"],
    "ARM64DecoderTests": ["CoreTests/ARM64DecoderTests"],
    "REAInspectionProviderTests": ["Phase2Tests/REAInspectionProviderTests"],
    "WorkspaceScriptingAPITests": ["CoreTests/WorkspaceScriptingAPITests"],
    "ImageLayoutTests": ["CoreTests/ImageLayoutTests"],
    "TwoClassTests": ["CoreTests/TwoClassTests", "CoreTests/TwoClassExtraTests"],
}


class AffectedSelectorTests(unittest.TestCase):
    def select(self, *paths: str, event: str = "pull_request") -> subject.Selection:
        return subject.select(event, list(paths), CLASSES)

    def test_push_is_a_smoke_build_and_dispatch_is_the_full_suite(self) -> None:
        self.assertEqual(self.select("MacScope/Services/REA/A.swift", event="push").qualify_arguments(), "--mode smoke")
        dispatch = self.select(event="workflow_dispatch")
        self.assertEqual(dispatch.qualify_arguments(), "--mode full-test")
        self.assertTrue(dispatch.governance and dispatch.sanitizers)
        # D11/D12: the nightly schedule is the full regression net.
        nightly = self.select(event="schedule")
        self.assertEqual(nightly.qualify_arguments(), "--mode full-test")
        self.assertTrue(nightly.governance and nightly.sanitizers)

    def test_docs_and_scripts_only_changes_get_a_smoke_build(self) -> None:
        docs = self.select("docs/brand/Nomenclature.md", "README.md")
        self.assertEqual(docs.qualify_arguments(), "--mode smoke")
        self.assertFalse(docs.governance)
        scripts = self.select("Scripts/ci/affected_selectors.py", ".github/workflows/ci.yml")
        self.assertEqual(scripts.qualify_arguments(), "--mode smoke")
        self.assertTrue(scripts.governance)

    def test_source_stem_and_area_select_test_classes(self) -> None:
        selection = self.select("MacScope/Services/Decompiler/MacIRBuilder+RegisterEffects.swift")
        self.assertEqual(selection.mode, "focused-test")
        self.assertEqual(
            selection.selectors,
            ["CoreTests/MacIRBuilderTests", "CoreTests/MacIRUnknownDestinationTests"],
        )
        self.assertIn("--only-testing CoreTests/MacIRBuilderTests", selection.qualify_arguments())

    def test_changed_test_file_selects_every_class_it_declares(self) -> None:
        selection = self.select("MacScope/Tests/CoreTests/TwoClassTests.swift")
        self.assertEqual(selection.selectors, ["CoreTests/TwoClassExtraTests", "CoreTests/TwoClassTests"])

    def test_unmapped_product_change_still_compiles_tests_through_the_canary(self) -> None:
        selection = self.select("MacScope/App/Unmapped.swift")
        self.assertEqual(selection.selectors, ["CoreTests/ImageLayoutTests"])
        helper = self.select("MacScope/Tests/CoreTests/SharedFixtureSupport.swift")
        self.assertEqual(helper.selectors, ["CoreTests/ImageLayoutTests"])

    def test_bridge_changes_add_sanitizers(self) -> None:
        self.assertTrue(self.select("Tools/NativeDecompilerBridge/bridge.cpp").sanitizers)
        self.assertTrue(self.select("ThirdParty/SleighNative/patches/0004.patch").sanitizers)
        self.assertFalse(self.select("MacScope/Services/REA/A.swift").sanitizers)

    def test_large_selection_falls_back_to_the_full_suite(self) -> None:
        many = {f"Area{index}Tests": [f"CoreTests/Area{index}Tests"] for index in range(subject.FULL_SUITE_THRESHOLD + 1)}
        selection = subject.select("pull_request", ["MacScope/Services/Area.swift"], many)
        self.assertEqual(selection.qualify_arguments(), "--mode full-test")

    def test_repository_test_classes_are_discovered(self) -> None:
        classes = subject.test_classes(subject.ROOT)
        self.assertIn("ImageLayoutTests", classes)
        self.assertIn(f"CoreTests/{subject.CANARY_CLASS}", classes[subject.CANARY_CLASS])
        phase2 = [selector for selectors in classes.values() for selector in selectors if selector.startswith("Phase2Tests/")]
        self.assertTrue(phase2, "no Phase2Tests classes discovered")

    def test_decompiler_source_references_select_every_requested_family(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / subject.DECOMPILER_AREA / "Nested.swift"
            source.parent.mkdir(parents=True)
            source.write_text("struct FreshDecompilerType {}\n", encoding="utf-8")
            tests = root / subject.TESTS
            tests.mkdir(parents=True)
            names = [f"{prefix}CoverageTests" for prefix in
                     ("G2", "Callee", "F1b", "S1Vector", "D06", "Golden")]
            (tests / "Coverage.swift").write_text(
                "\n".join(f"final class {name}: XCTestCase {{}}" for name in names)
                + "\nlet value: FreshDecompilerType?\n", encoding="utf-8")
            (tests / "Unrelated.swift").write_text(
                "final class UnrelatedTests: XCTestCase {}\n"
                "let value: FreshDecompilerTypeSuffix?\n", encoding="utf-8")
            selection = subject.select(
                "pull_request", ["MacScope/Services/Decompiler/MacIRBuilder+State.swift"],
                subject.test_classes(root), root=root)
            self.assertEqual(selection.selectors, sorted(f"CoreTests/{name}" for name in names))
            self.assertEqual(selection.mode, "focused-test")

    def test_repository_decompiler_families_and_threshold(self) -> None:
        classes = subject.test_classes(subject.ROOT)
        discovered = subject.decompiler_classes(subject.ROOT)
        for prefix in ("Callee", "F1b", "S1Vector", "D06", "Golden"):
            expected = {name for names in classes.values() for name in names
                        if name.startswith(f"CoreTests/{prefix}")}
            self.assertTrue(expected, prefix)
            self.assertTrue(expected <= discovered, sorted(expected - discovered))
        selection = subject.select(
            "pull_request", ["MacScope/Services/Decompiler/MacIRBuilder+State.swift"], classes)
        if len(discovered) > subject.FULL_SUITE_THRESHOLD:
            self.assertEqual(selection.mode, "full-test")
        else:
            self.assertTrue(discovered <= set(selection.selectors))

    def test_shared_fixture_directories_select_readers_without_type_references(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / subject.DECOMPILER_AREA / "Engine.swift"
            source.parent.mkdir(parents=True)
            source.write_text("struct FixtureEngine {}\n", encoding="utf-8")
            tests = root / subject.TESTS
            tests.mkdir(parents=True)
            # A helper without a test class establishes the fixture directory.
            (tests / "Helper.swift").write_text(
                'let engine: FixtureEngine?\n'
                'let url = base.appendingPathComponent("FreshFixtures/decompiler")\n',
                encoding="utf-8")
            (tests / "Reader.swift").write_text(
                'final class FixtureReaderTests: XCTestCase {}\n'
                'let url = base.appendingPathComponent("FreshFixtures/snapshot.json")\n',
                encoding="utf-8")
            (tests / "Other.swift").write_text(
                'final class OtherReaderTests: XCTestCase {}\n'
                'let a = base.appendingPathComponent("OtherFixtures/snapshot.json")\n'
                'let b = base.appendingPathComponent("FreshFixturesSuffix/snapshot.json")\n',
                encoding="utf-8")
            selection = subject.select(
                "pull_request", ["MacScope/Services/Decompiler/MacIRBuilder+State.swift"],
                subject.test_classes(root), root=root)
            self.assertEqual(selection.selectors, ["CoreTests/FixtureReaderTests"])
            self.assertEqual(selection.mode, "focused-test")

    def test_repository_fixture_readers_and_fixture_free_gate_are_covered(self) -> None:
        # Independently inventory literal fixture paths used by type-referencing
        # sources, then require every reader of those roots in the coverage set.
        sources = [path.read_text(encoding="utf-8")
                   for path in (subject.ROOT / subject.TESTS).rglob("*.swift")]
        types = {name for path in (subject.ROOT / subject.DECOMPILER_AREA).rglob("*.swift")
                 for name in subject.TYPE_PATTERN.findall(path.read_text(encoding="utf-8"))}
        roots = {part for source in sources
                 if types.intersection(subject.IDENTIFIER_PATTERN.findall(source))
                 for literal in re.findall(r'"([^"\n]*)"', source)
                 for part in literal.split("/")
                 if re.fullmatch(r"[A-Za-z_-]*(?:fixtures?|goldens?)", part, re.I)}
        self.assertTrue(roots)
        expected = {f"CoreTests/{name}" for source in sources
                    if any(roots.intersection(literal.split("/"))
                           for literal in re.findall(r'"([^"\n]*)"', source))
                    for name in subject.CLASS_PATTERN.findall(source)}
        self.assertIn("CoreTests/PreRefactorByteIdentityTests", expected)
        expected.add("CoreTests/GoldenGateTests")
        discovered = subject.decompiler_classes(subject.ROOT)
        self.assertTrue(expected <= discovered, sorted(expected - discovered))

    def test_non_decompiler_area_keeps_its_exact_selection(self) -> None:
        selection = self.select("MacScope/Services/Disassembly/InstructionDecoder.swift")
        self.assertEqual(selection.selectors, ["CoreTests/ARM64DecoderTests"])
        self.assertEqual(selection.mode, "focused-test")
        self.assertFalse(selection.governance or selection.sanitizers)

    def test_phase2_bundle_classes_keep_their_bundle(self) -> None:
        self.assertIn("Phase2Tests/REAInspectionProviderTests",
                      self.select("MacScope/Services/REA/A.swift").selectors)
        changed = self.select("MacScope/Tests/Phase2Tests/REAInspectionProviderTests.swift")
        self.assertEqual(changed.selectors, ["Phase2Tests/REAInspectionProviderTests"])


if __name__ == "__main__":
    unittest.main()
