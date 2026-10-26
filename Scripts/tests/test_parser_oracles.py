"""RX-03 developer parser oracles: goldens, specimens, pins and safety rules.

Portable (standard library, Python 3.9+, any host): validates the committed
goldens and specimens without the oracle tools. The full regeneration check
runs only when MACSCOPE_PARSER_ORACLES_ROOT names materialized tools on an
Apple-Silicon Mac, and is otherwise an explicit skip.
"""

from __future__ import annotations

import json
import os
import platform
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ORACLES = ROOT / "Scripts/parser-oracles"
sys.path.insert(0, str(ORACLES))

import normalize  # noqa: E402
import oracle_toolkit as toolkit  # noqa: E402
import run_parser_oracles as runner  # noqa: E402
import specimens  # noqa: E402

ALL_FIXTURES = runner.load_fixtures()
FIXTURES = [fixture for fixture in ALL_FIXTURES if fixture["format"] != "type-inventory"]
TYPE_FIXTURES = [fixture for fixture in ALL_FIXTURES if fixture["format"] == "type-inventory"]
LOCK = toolkit.load_lock()


def golden(fixture_id: str) -> dict:
    return json.loads(runner.golden_path(fixture_id).read_text(encoding="utf-8"))


class SpecimenTests(unittest.TestCase):
    def test_committed_specimens_equal_the_deterministic_generator(self) -> None:
        for name, generator in specimens.GENERATORS.items():
            with self.subTest(name=name):
                self.assertEqual((specimens.SPECIMEN_DIR / name).read_bytes(), generator())

    def test_generator_is_deterministic(self) -> None:
        for name, generator in specimens.GENERATORS.items():
            with self.subTest(name=name):
                self.assertEqual(generator(), generator())

    def test_replaced_specimen_keeps_uuid_but_changes_bytes(self) -> None:
        original = specimens.macho_thin_arm64_exec()
        replaced = specimens.macho_thin_arm64_exec_replaced()
        self.assertNotEqual(toolkit.sha256_bytes(original), toolkit.sha256_bytes(replaced))
        self.assertIn(specimens.UUID_EXEC, original)
        self.assertIn(specimens.UUID_EXEC, replaced)

    def test_every_specimen_is_tracked_without_execute_permission(self) -> None:
        paths = [fixture["path"] for fixture in FIXTURES if not fixture.get("host_bound")]
        listing = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-s", "--", *paths],
            capture_output=True, text=True, check=True,
        ).stdout.splitlines()
        if not listing:
            self.skipTest("specimens are not in the Git index of this checkout")
        modes = {line.split("\t", 1)[1]: line.split()[0] for line in listing}
        for path in paths:
            with self.subTest(path=path):
                self.assertEqual(modes.get(path), "100644")
                self.assertFalse(os.stat(ROOT / path).st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))

    def test_corkami_files_are_byte_identical_to_the_pinned_upstream_blobs(self) -> None:
        for path, record in LOCK["specimen_sources"]["corkami-pocs"]["files"].items():
            with self.subTest(path=path):
                self.assertEqual(toolkit.git_blob_sha1((ROOT / path).read_bytes()), record["git_blob"])


class GoldenTests(unittest.TestCase):
    def test_one_golden_per_fixture_and_no_orphans(self) -> None:
        expected = {f"{fixture['id']}.json" for fixture in ALL_FIXTURES}
        self.assertEqual({path.name for path in runner.GOLDEN_DIR.glob("*.json")}, expected)

    def test_curated_set_covers_the_required_shapes(self) -> None:
        by_id = {fixture["id"]: fixture for fixture in FIXTURES}
        self.assertGreaterEqual(len(FIXTURES), 10)
        self.assertEqual({fixture["format"] for fixture in FIXTURES}, {"macho", "pe", "dyld"})
        self.assertEqual(by_id["macho-fat-x86_64-arm64"]["selections"], ["x86_64", "arm64"])
        self.assertTrue(any(fixture["classification"] == "malformed" for fixture in FIXTURES))
        self.assertIn("macho-thin-arm64-exec-replaced", by_id)
        self.assertIn("pe-import-name-amplification", by_id)

    def test_goldens_are_canonical_json(self) -> None:
        for fixture in FIXTURES:
            with self.subTest(fixture=fixture["id"]):
                payload = runner.golden_path(fixture["id"]).read_bytes()
                self.assertEqual(toolkit.canonical_json_bytes(json.loads(payload)), payload)

    def test_goldens_bind_input_hashes(self) -> None:
        for fixture in FIXTURES:
            document = golden(fixture["id"])
            with self.subTest(fixture=fixture["id"]):
                self.assertEqual(document["schema"], runner.GOLDEN_SCHEMA)
                self.assertEqual(document["fixture"]["id"], fixture["id"])
                identity = document["input"]
                if fixture.get("host_bound"):
                    self.assertTrue(identity["host_bound"])
                    self.assertTrue(identity["cache_files"])
                    for record in identity["cache_files"]:
                        self.assertRegex(record["sha256"], r"^[0-9a-f]{64}$")
                    self.assertTrue(identity["macos"]["build_version"])
                else:
                    payload = (ROOT / fixture["path"]).read_bytes()
                    self.assertEqual(identity["path"], fixture["path"])
                    self.assertEqual(identity["size"], len(payload))
                    self.assertEqual(identity["sha256"], toolkit.sha256_bytes(payload))

    def test_goldens_bind_pinned_engine_identities(self) -> None:
        current = toolkit.engine_identities()
        for fixture in FIXTURES:
            document = golden(fixture["id"])
            for identity in document["tools"]:
                name = identity["oracle"]
                with self.subTest(fixture=fixture["id"], oracle=name):
                    self.assertIn(name, fixture["oracles"])
                    if identity["kind"] == "platform-tool":
                        self.assertIn(name, LOCK["platform_tools"])
                        self.assertRegex(identity["executable_sha256"], r"^[0-9a-f]{64}$")
                        continue
                    # Version, revision and the vendored source trees the worker links.
                    self.assertEqual(identity, current[name])

    def test_commands_run_an_oracle_and_pass_the_specimen_only_as_data(self) -> None:
        programs = {runner.DUMP_PLACEHOLDER, "<dyld_info>"}
        for fixture in FIXTURES:
            for result in golden(fixture["id"])["results"]:
                with self.subTest(fixture=fixture["id"], oracle=result["oracle"]):
                    command = result["command"]
                    self.assertIn(command[0], programs)
                    self.assertNotIn(runner.SPECIMEN_PLACEHOLDER, command[:1])
                    if not fixture.get("host_bound"):
                        self.assertEqual(command[-1], runner.SPECIMEN_PLACEHOLDER)
                    text = json.dumps(command)
                    self.assertNotIn(str(Path.home()), text)

    def test_results_cover_every_oracle_and_selection(self) -> None:
        for fixture in FIXTURES:
            results = golden(fixture["id"])["results"]
            with self.subTest(fixture=fixture["id"]):
                self.assertEqual({result["oracle"] for result in results}, set(fixture["oracles"]))
                for result in results:
                    self.assertIn(result["status"], {"parsed", "rejected"})
                    self.assertEqual(result["facts"] is None, result["status"] == "rejected")
                    if result["status"] == "rejected":
                        self.assertTrue(result["error"])

    def test_agreement_is_recomputable_from_results(self) -> None:
        for fixture in FIXTURES:
            document = golden(fixture["id"])
            with self.subTest(fixture=fixture["id"]):
                self.assertEqual(runner.agreement(fixture, document["results"]), document["agreement"])

    def test_valid_specimens_parse_in_every_oracle(self) -> None:
        for fixture in FIXTURES:
            if fixture["classification"] != "valid":
                continue
            with self.subTest(fixture=fixture["id"]):
                for entry in golden(fixture["id"])["agreement"]:
                    self.assertEqual(set(entry["statuses"].values()), {"parsed"})

    def test_valid_macho_specimens_agree_across_oracles(self) -> None:
        for fixture in FIXTURES:
            if fixture["format"] != "macho" or fixture["classification"] != "valid":
                continue
            with self.subTest(fixture=fixture["id"]):
                for entry in golden(fixture["id"])["agreement"]:
                    self.assertEqual(entry["disagreed"], {})
                    self.assertIn("segments", entry["agreed"])
                    self.assertIn("uuid", entry["agreed"])
                    self.assertIn("sections", entry["agreed"])

    def test_uuid_cannot_distinguish_replaced_bytes(self) -> None:
        original = golden("macho-thin-arm64-exec")
        replaced = golden("macho-thin-arm64-exec-replaced")
        self.assertNotEqual(original["input"]["sha256"], replaced["input"]["sha256"])
        for left, right in zip(original["results"], replaced["results"]):
            self.assertEqual(left["facts"]["uuid"], right["facts"]["uuid"])

    def test_fact_strings_are_bounded(self) -> None:
        def walk(value):
            if isinstance(value, str):
                yield value
            elif isinstance(value, dict):
                for item in value.values():
                    yield from walk(item)
            elif isinstance(value, list):
                for item in value:
                    yield from walk(item)

        for fixture in FIXTURES:
            for result in golden(fixture["id"])["results"]:
                for text in walk(result["facts"]):
                    self.assertLessEqual(len(text), normalize.MAX_FACT_STRING + 96)


class TypeInventoryGoldenTests(unittest.TestCase):
    def test_three_metadata_goldens_keep_independent_inventory_schema(self) -> None:
        self.assertEqual({fixture["id"] for fixture in TYPE_FIXTURES},
                         {"type-atlas-swift-app", "type-atlas-mixed", "type-atlas-objc"})
        for fixture in TYPE_FIXTURES:
            document = golden(fixture["id"])
            self.assertEqual(document["schema"], "macscope.type-inventory-golden.v1")
            self.assertEqual(document["fixture"], fixture)
            self.assertRegex(document["engineKey"], r"^[0-9a-f]{64}$")
            # Identity is recorded at creation; do not re-hash accepted specimen bytes.
            self.assertRegex(document["input"]["sha256"], r"^[0-9a-f]{64}$")
            self.assertGreater(document["input"]["size"], 0)
            self.assertEqual(document["inventory"]["status"], "parsed")
            self.assertEqual(set(document["inventory"]["inventories"]),
                             {"objcClasses", "objcCategories", "objcProtocols", "swiftTypes",
                              "swiftProtocols", "swiftConformances"})

    def test_unknown_type_selection_refuses_before_any_oracle_runs(self) -> None:
        with mock.patch.object(runner.platform, "system", return_value="Darwin"), \
             mock.patch.object(runner.platform, "machine", return_value="arm64"), \
             mock.patch.object(runner, "run_type_inventories") as run:
            with self.assertRaisesRegex(runner.OracleRunError, "unknown or empty"):
                runner.main(["--check", "--type-inventory", "--no-stage", "--only", "typo",
                             "--engines-root", str(ROOT.parent / "unused-type-oracle-stage")])
            run.assert_not_called()


class NormalizerTests(unittest.TestCase):
    def test_raw_engine_vocabulary_is_normalized(self) -> None:
        lief = normalize.normalize_raw_macho_slice({
            "cputype": 0x0100000C, "cpusubtype": 0x80000002, "filetype": 6, "ncmds": 0, "sizeofcmds": 0,
            "flags": 0x80000001, "commands": [0x19, 0x8000001F], "segments": [], "uuid": "00" * 16,
            "dylibs": [], "id_dylib": None, "entry_offset": None,
            "build_version": {"platform": 1, "minos": [14, 0, 0], "sdk": [15, 0]},
        })
        self.assertEqual((lief["arch"], lief["ptrauth_abi"], lief["filetype"]), ("arm64e", True, "dylib"))
        self.assertEqual(lief["flags"], ["dylib_in_cache", "noundefs"])
        self.assertEqual(lief["load_commands"], ["LC_SEGMENT_64", "LC_REEXPORT_DYLIB"])
        self.assertEqual(lief["build_version"], {"platform": "macos", "minos": "14.0.0", "sdk": "15.0.0"})
        self.assertEqual(lief["uuid"], "00000000-0000-0000-0000-000000000000")

    def test_long_strings_become_digest_stand_ins(self) -> None:
        text = normalize.bounded("A" * 5000)
        self.assertTrue(text.startswith("<bounded length=5000 sha256="))
        self.assertEqual(normalize.bounded("short"), "short")

    def test_untrusted_types_are_rejected(self) -> None:
        with self.assertRaises(normalize.NormalizationError):
            normalize.integer(True)
        with self.assertRaises(normalize.NormalizationError):
            normalize.bounded(7)
        with self.assertRaises(normalize.NormalizationError):
            normalize.uuid_text("not-a-uuid")

    def test_pe_module_names_compare_case_insensitively(self) -> None:
        raw = {"machine": 0x8664, "optional_magic": 0x20B, "number_of_sections": 0, "image_base": 0,
               "entry_point_va": None, "sections": [], "exports": [],
               "imports": [{"module": "KERNEL32.DLL", "function": "ExitProcess"}]}
        facts = normalize.normalize_pe(raw)
        self.assertEqual(facts["imports"], [{"module": "kernel32.dll", "function": "ExitProcess"}])
        self.assertEqual((facts["machine"], facts["format"]), ("amd64", "pe32+"))

    def test_dyld_info_text(self) -> None:
        text = (
            "/usr/lib/libx.dylib [arm64e]:\n    -platform:\n        platform     minOS      sdk\n"
            " zippered(macOS/Catalyst)     27.2      27.2   \n    -segments:\n"
            "        unslid-addr    segment   section        sect-size  seg-size   init/max-prot\n"
            "        0x180404000    __TEXT                             317KB     r.x/r.x\n"
            "        0x300809290           __text            254204\n"
            "    -linked_dylibs:\n        attributes       load path\n"
            "                         /usr/lib/libSystem.B.dylib\n"
            "        lazy-load        /usr/lib/swift/libswiftCore.dylib\n"
        )
        facts = normalize.normalize_dyld_info(text)
        self.assertEqual(facts["platform"]["minos"], "27.2.0")
        self.assertEqual(facts["segments"][0], {"name": "__TEXT", "vmaddr": 0x180404000, "size_kb": 317,
                                                "initprot": "r-x", "maxprot": "r-x"})
        self.assertEqual(facts["sections"][0]["size"], 254204)
        self.assertEqual(facts["dependents"], ["/usr/lib/libSystem.B.dylib", "/usr/lib/swift/libswiftCore.dylib"])


class SafetyTests(unittest.TestCase):
    def test_runner_refuses_unverified_programs_and_specimen_execution(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            staged = runner.stage_specimen(specimens.SPECIMEN_DIR / "macho-thin-arm64-exec.bin", Path(directory))
            self.assertFalse(staged.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
            programs = ["/usr/bin/true"]
            runner.assert_safe_argv(["/usr/bin/true", str(staged)], programs, [], [str(staged)])
            with self.assertRaises(runner.OracleRunError):
                runner.assert_safe_argv([str(staged)], programs + [str(staged)], [], [str(staged)])
            with self.assertRaises(runner.OracleRunError):
                runner.assert_safe_argv(["/bin/sh", "-c", str(staged)], programs, [], [str(staged)])
            staged.chmod(0o755)
            with self.assertRaises(runner.OracleRunError):
                runner.assert_safe_argv(["/usr/bin/true", str(staged)], programs, [], [str(staged)])

    def test_work_root_must_be_outside_the_repository(self) -> None:
        with self.assertRaises(toolkit.OracleToolkitError):
            toolkit.require_external(ROOT / "build")

    def test_parser_engine_builder_is_offline_and_never_writes_into_the_repository(self) -> None:
        builder = (ROOT / "Scripts/dependencies/build_parser_engines.py").read_text(encoding="utf-8")
        for forbidden in ("urlopen", "curl", "git fetch", "pip install"):
            self.assertNotIn(forbidden, builder)
        self.assertIn('"GOPROXY": "off"', builder)
        self.assertIn('"GOTOOLCHAIN": "local"', builder)


class PinGovernanceTests(unittest.TestCase):
    def test_lock_matches_the_third_party_inventory_and_builder(self) -> None:
        inventory = {component["id"]: component
                     for component in json.loads((ROOT / "THIRD_PARTY_COMPONENTS.yml").read_text())["components"]}
        sys.path.insert(0, str(ROOT / "Scripts/dependencies"))
        import build_parser_engines as builder  # noqa: E402
        for name, pin in LOCK["engines"].items():
            with self.subTest(engine=name):
                component = inventory[pin["component"]]
                self.assertEqual(component["pin"]["git_revision"], pin["git_revision"])
                self.assertEqual(component["pin"]["version"], pin["version"])
                self.assertEqual(component["integration_mode"], "vendored-source")
                self.assertEqual(component["tracked_paths"], [pin["source"]])
                self.assertIn("AnalysisWorkerXPCService", component["targets"])
                self.assertEqual(builder.ENGINE_IDENTITY[name],
                                 {"version": pin["version"], "git_revision": pin["git_revision"]})
        corkami = LOCK["specimen_sources"]["corkami-pocs"]
        self.assertEqual(inventory[corkami["component"]]["pin"]["git_revision"], corkami["git_revision"])

    def test_builder_keys_bind_sources_builder_and_toolchain(self) -> None:
        sys.path.insert(0, str(ROOT / "Scripts/dependencies"))
        import build_parser_engines as builder  # noqa: E402
        self.assertEqual(builder.ORDER[-1], "parser-engine-bridge")
        self.assertEqual(set(builder.COMPONENTS["parser-engine-bridge"]["deps"]), set(builder.ORDER[:-1]))
        for name, spec in builder.COMPONENTS.items():
            with self.subTest(component=name):
                self.assertTrue(spec["sources"])
                self.assertIn("clang", spec["tools"])
                self.assertIn("sdk", spec["tools"])
        self.assertIn("go", builder.COMPONENTS["parser-engine-go-macho"]["tools"])


@unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64",
                     "the pinned oracle binaries are Apple-Silicon macOS builds")
class RegenerationTests(unittest.TestCase):
    def test_fresh_engine_run_reproduces_every_committed_golden(self) -> None:
        stage = runner.default_engines_root()
        if not (stage / "STAGED.json").is_file():
            self.skipTest("parser engines are not staged for this worktree (run run_parser_oracles.py once)")
        completed = subprocess.run(
            [sys.executable, str(ORACLES / "run_parser_oracles.py"), "--check", "--skip-host", "--no-stage"],
            capture_output=True, text=True, timeout=900,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)


if __name__ == "__main__":
    unittest.main()
