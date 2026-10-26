from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_ROOT = ROOT / "Scripts" / "native-decompiler-direct"
sys.path.insert(0, str(MODULE_ROOT))

import sleigh_package  # noqa: E402

_EXTRACTOR_SPEC = importlib.util.spec_from_file_location(
    "extract_sleigh_package", MODULE_ROOT / "extract_sleigh_package.py"
)
assert _EXTRACTOR_SPEC and _EXTRACTOR_SPEC.loader
extract_sleigh_package = importlib.util.module_from_spec(_EXTRACTOR_SPEC)
_EXTRACTOR_SPEC.loader.exec_module(extract_sleigh_package)


def cmake_generator_arguments() -> list[str]:
    return ["-G", "Ninja"] if shutil.which("ninja") else []


class SleighPackageFixture:
    def __init__(self, root: pathlib.Path) -> None:
        self.root = root

    def write(self, relative: str, payload: bytes | str = b"fixture") -> pathlib.Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(payload, str):
            path.write_text(payload, encoding="utf-8")
        else:
            path.write_bytes(payload)
        return path

    def create(self) -> None:
        prefix = "${CMAKE_CURRENT_LIST_DIR}/../../.."
        self.write(
            "lib/cmake/sleigh/sleighConfig.cmake",
            "\n".join(
                [
                    "include(CMakeFindDependencyMacro)",
                    "find_dependency(ZLIB)",
                    'include("${CMAKE_CURRENT_LIST_DIR}/sleighTargets.cmake")',
                    'include("${CMAKE_CURRENT_LIST_DIR}/modules/sleighCompile.cmake")',
                    'if("Specs" IN_LIST sleigh_FIND_COMPONENTS)',
                    '  include("${CMAKE_CURRENT_LIST_DIR}/specfiles.cmake")',
                    "endif()",
                    "",
                ]
            ),
        )
        self.write(
            "lib/cmake/sleigh/sleighConfigVersion.cmake",
            "\n".join(
                [
                    'set(PACKAGE_VERSION "12.1.2")',
                    'if(PACKAGE_FIND_VERSION VERSION_EQUAL PACKAGE_VERSION)',
                    "  set(PACKAGE_VERSION_EXACT TRUE)",
                    "  set(PACKAGE_VERSION_COMPATIBLE TRUE)",
                    "endif()",
                    "",
                ]
            ),
        )
        self.write(
            "lib/cmake/sleigh/specfiles.cmake",
            f'set(sleigh_INSTALL_SPECDIR "{prefix}/share/sleigh/specfiles")\n',
        )
        self.write(
            "lib/cmake/sleigh/sleighTargets.cmake",
            "\n".join(
                [
                    "add_library(sleigh::decomp STATIC IMPORTED)",
                    "add_library(sleigh::sla STATIC IMPORTED)",
                    f'set(_sleigh_include "{prefix}/include/sleigh")',
                    "set_target_properties(sleigh::decomp PROPERTIES IMPORTED_LOCATION \"${CMAKE_CURRENT_LIST_DIR}/../../../lib/libdecomp.a\" INTERFACE_INCLUDE_DIRECTORIES \"${_sleigh_include}\" INTERFACE_LINK_LIBRARIES ZLIB::ZLIB)",
                    "set_target_properties(sleigh::sla PROPERTIES IMPORTED_LOCATION \"${CMAKE_CURRENT_LIST_DIR}/../../../lib/libsla.a\" INTERFACE_INCLUDE_DIRECTORIES \"${_sleigh_include}\" INTERFACE_LINK_LIBRARIES ZLIB::ZLIB)",
                    "",
                ]
            ),
        )
        self.write("lib/cmake/sleigh/modules/sleighCompile.cmake", "# fixture helper\n")
        self.write("lib/libdecomp.a", b"!<arch>\n")
        self.write("lib/libsla.a", b"!<arch>\n")

        # Each fixture header is an independent file.  Defining the same class
        # in all of them is a redefinition when the probe includes the complete
        # API surface in one translation unit; an empty namespace keeps the
        # headers valid without inventing duplicate declarations.
        common = "#pragma once\nnamespace ghidra {}\n"
        for name in (
            "funcdata.hh",
            "heritage.hh",
            "varnode.hh",
            "prettyprint.hh",
            "printc.hh",
        ):
            self.write(f"include/sleigh/ghidra/{name}", common)
        self.write(
            "include/sleigh/ghidra/loadimage.hh",
            "#pragma once\nnamespace ghidra { class LoadImage { public: virtual ~LoadImage() = default; }; }\n",
        )
        self.write(
            "include/sleigh/ghidra/sleigh_arch.hh",
            "#pragma once\nnamespace ghidra { class SleighArchitecture { public: virtual ~SleighArchitecture() = default; }; }\n",
        )
        self.write(
            "include/sleigh/ghidra/libdecomp.hh",
            "#pragma once\nnamespace ghidra { inline void startDecompilerLibrary(const char*) {} inline void shutdownDecompilerLibrary() {} }\n",
        )

        language_root = "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages"
        self.write(f"{language_root}/AARCH64.sla", b"sla")
        self.write(f"{language_root}/AARCH64.ldefs", "<language_definitions/>\n")
        self.write(f"{language_root}/generic.pspec", "<processor_spec/>\n")
        self.write(f"{language_root}/gcc.cspec", "<compiler_spec/>\n")
        self.write(f"{language_root}/AppleSilicon.ldefs", b"apple-ldefs")
        self.write(f"{language_root}/AARCH64_AppleSilicon.sla", b"apple-sla")
        self.write(f"{language_root}/AARCH64.pspec", b"apple-pspec")
        self.write(f"{language_root}/AARCH64_apple.cspec", b"apple-cspec")


def canonical_manifest(package: pathlib.Path) -> dict[str, object]:
    artifact = sleigh_package.APPROVED_ARTIFACTS["linux-x86_64"]
    return sleigh_package.materialization_value(artifact, sleigh_package.analyze_package(package))


class SleighPackageContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.package = self.root / "package"
        self.package.mkdir()
        SleighPackageFixture(self.package).create()

    def test_valid_package_is_deterministic(self) -> None:
        first = sleigh_package.analyze_package(self.package)
        second = sleigh_package.analyze_package(self.package)
        self.assertEqual(first, second)
        self.assertEqual(first["fileCount"], 23)
        self.assertRegex(first["treeSha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(first["cmakeConfigRelativePath"], "lib/cmake/sleigh/sleighConfig.cmake")

    def test_apple_silicon_profile_resources_are_explicit_critical_files(self) -> None:
        analysis = sleigh_package.analyze_package(self.package)
        expected = {
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AppleSilicon.ldefs",
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_AppleSilicon.sla",
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64.pspec",
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/AARCH64_apple.cspec",
        }
        self.assertTrue(expected.issubset(set(analysis["criticalFileSha256"])))

    def test_apple_silicon_profile_critical_files_are_required_and_tamper_evident(self) -> None:
        target = self.package / (
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/"
            "AARCH64_AppleSilicon.sla"
        )
        target.unlink()
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "AARCH64_AppleSilicon.sla"):
            sleigh_package.analyze_package(self.package)
        SleighPackageFixture(self.package).create()
        materialization = self.root / "materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        (materialization / "MATERIALIZATION.json").write_text(
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        with (materialization / "package" / target.relative_to(self.package)).open("ab") as stream:
            stream.write(b"tamper")
        with self.assertRaises(sleigh_package.PackageContractError) as caught:
            sleigh_package.verify_materialization(materialization)
        message = str(caught.exception)
        self.assertIn("totalBytes", message)
        self.assertIn("treeSha256", message)
        self.assertNotIn("criticalFileSha256", message)

    def test_apple_silicon_profile_suffix_decoy_does_not_change_literal_selection(self) -> None:
        relative = (
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/"
            "AARCH64_AppleSilicon.sla"
        )
        literal = self.package / relative
        decoy = literal.with_name("000_AARCH64_AppleSilicon.sla")
        decoy.write_bytes(b"suffix-decoy")
        analysis = sleigh_package.analyze_package(self.package)
        self.assertEqual(
            analysis["criticalFileSha256"][relative],
            hashlib.sha256(b"apple-sla").hexdigest(),
        )

    def test_apple_silicon_profile_symlink_is_rejected(self) -> None:
        relative = (
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/"
            "AARCH64_AppleSilicon.sla"
        )
        target = self.package / relative
        target.unlink()
        try:
            target.symlink_to("AARCH64.sla")
        except (OSError, NotImplementedError):
            self.skipTest("symlinks unavailable")
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "AARCH64_AppleSilicon.sla"):
            sleigh_package.analyze_package(self.package)

    def test_apple_silicon_profile_generic_substitution_is_rejected(self) -> None:
        target = self.package / (
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/"
            "AARCH64_AppleSilicon.sla"
        )
        target.unlink()
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "AARCH64_AppleSilicon.sla"):
            sleigh_package.analyze_package(self.package)

    def test_apple_silicon_profile_manifest_summary_drift_is_not_an_identity_failure(self) -> None:
        materialization = self.root / "materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        relative = (
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/"
            "AARCH64_AppleSilicon.sla"
        )
        del value["package"]["criticalFileSha256"][relative]
        (materialization / "MATERIALIZATION.json").write_text(
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        self.assertEqual(sleigh_package.verify_materialization(materialization), value)

    def test_apple_silicon_profile_manifest_duplicate_critical_key_is_rejected(self) -> None:
        materialization = self.root / "materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        relative = (
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/"
            "AARCH64_AppleSilicon.sla"
        )
        key_value = json.dumps(relative) + ":" + json.dumps(
            value["package"]["criticalFileSha256"][relative]
        )
        payload = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
        self.assertEqual(payload.count(key_value), 1)
        (materialization / "MATERIALIZATION.json").write_text(
            payload.replace(key_value, f"{key_value},{key_value}", 1),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            sleigh_package.PackageContractError,
            "duplicate key: .*AARCH64_AppleSilicon.sla",
        ):
            sleigh_package.verify_materialization(materialization)

    def test_critical_manifest_change_does_not_change_complete_tree_preimage(self) -> None:
        first = sleigh_package.analyze_package(self.package)
        second = sleigh_package.analyze_package(self.package)
        self.assertEqual(first["treeSha256"], second["treeSha256"])
        value = sleigh_package.materialization_value(
            sleigh_package.APPROVED_ARTIFACTS["linux-x86_64"], first
        )
        original_manifest = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        changed = json.loads(original_manifest)
        del changed["package"]["criticalFileSha256"][
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages/"
            "AARCH64_AppleSilicon.sla"
        ]
        changed_manifest = json.dumps(changed, sort_keys=True, separators=(",", ":")).encode()
        self.assertNotEqual(
            hashlib.sha256(original_manifest).hexdigest(),
            hashlib.sha256(changed_manifest).hexdigest(),
        )

    def test_install_prefix_discovery_rejects_extraneous_archive_files(self) -> None:
        extraction = self.root / "extract"
        outer = extraction / "sleigh-12.1.2-1.x86_64"
        outer.parent.mkdir()
        shutil.move(self.package, outer)
        (extraction / "unexpected.txt").write_text("unexpected", encoding="utf-8")
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "outside"):
            sleigh_package.discover_install_prefix(extraction)

    def test_install_prefix_discovery_accepts_one_outer_directory(self) -> None:
        extraction = self.root / "extract"
        outer = extraction / "sleigh-12.1.2-1.x86_64"
        outer.parent.mkdir()
        shutil.move(self.package, outer)
        self.assertEqual(sleigh_package.discover_install_prefix(extraction), outer.resolve())

    def test_missing_required_header_is_rejected(self) -> None:
        (self.package / "include/sleigh/ghidra/heritage.hh").unlink()
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "heritage.hh"):
            sleigh_package.analyze_package(self.package)

    def test_java_or_gpl_payload_is_rejected(self) -> None:
        (self.package / "tool.jar").write_bytes(b"jar")
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "Java"):
            sleigh_package.analyze_package(self.package)
        (self.package / "tool.jar").unlink()
        (self.package / "GPL").mkdir()
        (self.package / "GPL/code").write_bytes(b"code")
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "GPL"):
            sleigh_package.analyze_package(self.package)

    def test_materialization_rejects_unrecorded_empty_directory(self) -> None:
        materialization = self.root / "materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        (materialization / "MATERIALIZATION.json").write_text(
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

        (materialization / "package" / "unexpected-empty").mkdir()

        with self.assertRaisesRegex(sleigh_package.PackageContractError, "empty directory"):
            sleigh_package.verify_materialization(materialization)

    def test_materialization_rejects_empty_gpl_directory(self) -> None:
        materialization = self.root / "materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        (materialization / "MATERIALIZATION.json").write_text(
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

        (materialization / "package" / "GPL").mkdir()

        with self.assertRaisesRegex(sleigh_package.PackageContractError, "GPL"):
            sleigh_package.verify_materialization(materialization)

    def test_symlink_is_rejected(self) -> None:
        link = self.package / "include/sleigh/ghidra/link.hh"
        try:
            link.symlink_to("libdecomp.hh")
        except (OSError, NotImplementedError):
            self.skipTest("symlinks unavailable")
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "link"):
            sleigh_package.analyze_package(self.package)

    def test_missing_targets_or_specs_are_rejected(self) -> None:
        (self.package / "lib/cmake/sleigh/specfiles.cmake").unlink()
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "specfiles.cmake"):
            sleigh_package.analyze_package(self.package)
        SleighPackageFixture(self.package).create()
        target = self.package / "lib/cmake/sleigh/sleighTargets.cmake"
        target.write_text("add_library(sleigh::sla INTERFACE IMPORTED)\n", encoding="utf-8")
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "sleigh::decomp"):
            sleigh_package.analyze_package(self.package)
        SleighPackageFixture(self.package).create()
        language_root = self.package / (
            "share/sleigh/specfiles/Ghidra/Processors/AARCH64/data/languages"
        )
        for path in language_root.glob("*.sla"):
            path.unlink()
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "AARCH64_AppleSilicon.sla"):
            sleigh_package.analyze_package(self.package)

    def test_materialization_manifest_round_trip_and_tamper_detection(self) -> None:
        materialization = self.root / "materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        payload = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
        (materialization / "MATERIALIZATION.json").write_text(payload, encoding="utf-8")
        self.assertEqual(sleigh_package.verify_materialization(materialization), value)
        with (materialization / "package/lib/libdecomp.a").open("ab") as stream:
            stream.write(b"tamper")
        with self.assertRaises(sleigh_package.PackageContractError) as caught:
            sleigh_package.verify_materialization(materialization)
        message = str(caught.exception)
        self.assertIn("totalBytes", message)
        self.assertIn("delta=+6", message)
        self.assertIn("treeSha256", message)
        self.assertNotIn("criticalFileSha256", message)
        self.assertNotIn("fileCount", message)

    def test_recorded_resource_overlay_requires_linked_identity_and_exact_root(self) -> None:
        manifest = canonical_manifest(self.package)
        (self.root / "MATERIALIZATION.json").write_text(
            sleigh_package.canonical_json(manifest) + "\n", encoding="utf-8")
        # A prepared package has a different resource tree from its archive.
        resource = self.package / sleigh_package.APPLE_SILICON_CRITICAL_FILE_RELATIVE_PATHS[1]
        resource.write_bytes(b"patched fixture sla")
        observed = sleigh_package.analyze_package(self.package)
        record = {
            "schemaVersion": 1,
            "componentId": "sleigh-native-dcp03b4-aarch64-patched-resources",
            "baseline": {
                "artifactSha256": manifest["artifact"]["sha256"],
                "packageTreeSha256": manifest["package"]["treeSha256"],
            },
            "patched": {
                "packageTreeSha256WithResourceOverlay": observed["treeSha256"],
                "packageFileCountWithResourceOverlay": observed["fileCount"],
                "packageTotalBytesWithResourceOverlay": observed["totalBytes"],
            },
        }
        record_path = self.root / "PATCHED_RESOURCES.json"
        record_path.write_text(json.dumps(record))
        self.assertEqual(sleigh_package.verify_materialization(self.root), manifest)
        for section, field, invalid in (
            ("baseline", "artifactSha256", "0" * 64),
            ("baseline", "packageTreeSha256", "0" * 64),
            ("patched", "packageTreeSha256WithResourceOverlay", "0" * 64),
            ("patched", "packageFileCountWithResourceOverlay", observed["fileCount"] + 1),
            ("patched", "packageTotalBytesWithResourceOverlay", observed["totalBytes"] + 1),
            ("patched", "packageFileCountWithResourceOverlay", True),
        ):
            with self.subTest(section=section, field=field):
                damaged = json.loads(json.dumps(record))
                damaged[section][field] = invalid
                record_path.write_text(json.dumps(damaged))
                with self.assertRaises(sleigh_package.PackageContractError):
                    sleigh_package.verify_materialization(self.root)
        record_path.write_text(json.dumps(record))
        extra = self.root / "UNRECORDED.json"
        extra.write_text("{}")
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "unexpected entries"):
            sleigh_package.verify_materialization(self.root)
        extra.unlink()
        record_path.unlink()
        record_path.symlink_to(self.root / "MATERIALIZATION.json")
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "ordinary file"):
            sleigh_package.verify_materialization(self.root)

    def test_resource_overlay_record_rejects_malformed_and_duplicate_json(self) -> None:
        manifest = canonical_manifest(self.package)
        (self.root / "MATERIALIZATION.json").write_text(
            sleigh_package.canonical_json(manifest) + "\n", encoding="utf-8")
        record_path = self.root / "PATCHED_RESOURCES.json"
        for payload in ('{', '{"schemaVersion":1,"schemaVersion":1}', '[]', '{}'):
            with self.subTest(payload=payload):
                record_path.write_text(payload)
                with self.assertRaises(sleigh_package.PackageContractError):
                    sleigh_package.verify_materialization(self.root)

    def test_component_id_mismatch_names_expected_and_supplied_ids(self) -> None:
        materialization = self.root / "materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        value["componentId"] = "sleigh-native-dcp05c"
        (materialization / "MATERIALIZATION.json").write_text(
            sleigh_package.canonical_json(value) + "\n",
            encoding="utf-8",
        )

        with self.assertRaises(sleigh_package.PackageContractError) as caught:
            sleigh_package.verify_materialization(materialization)

        self.assertEqual(
            str(caught.exception),
            'MATERIALIZATION.json componentId mismatch: expected '
            '"sleigh-native-dcp03b4", supplied "sleigh-native-dcp05c"',
        )

    def test_critical_map_mismatch_is_not_a_complete_identity_failure(self) -> None:
        materialization = self.root / "materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        value["package"]["criticalFileSha256"]["recorded-only"] = "0" * 64
        (materialization / "MATERIALIZATION.json").write_text(
            sleigh_package.canonical_json(value) + "\n",
            encoding="utf-8",
        )
        self.assertEqual(sleigh_package.verify_materialization(materialization), value)

    def test_package_comparison_fields_cover_every_analyzer_key(self) -> None:
        analysis = sleigh_package.analyze_package(self.package)
        separately_validated = set(
            sleigh_package.PACKAGE_IDENTITY_SEPARATELY_VALIDATED_FIELDS
        )
        self.assertEqual(separately_validated, {"relativeRoot", "criticalFileSha256"})
        covered = set(sleigh_package.PACKAGE_IDENTITY_COMPARISON_FIELDS) | separately_validated
        self.assertEqual(set(analysis) | {"relativeRoot"}, covered)

    def test_component_mismatch_cli_is_hard_and_actionable(self) -> None:
        materialization = self.root / "materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        value["componentId"] = "sleigh-native-dcp05c"
        (materialization / "MATERIALIZATION.json").write_text(
            sleigh_package.canonical_json(value) + "\n",
            encoding="utf-8",
        )

        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_ROOT / "verify_sleigh_package.py"),
                "verify",
                "--materialization-root",
                str(materialization),
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("ERROR:", result.stderr)
        self.assertIn("sleigh-native-dcp03b4", result.stderr)
        self.assertIn("sleigh-native-dcp05c", result.stderr)

    def test_manifest_rejects_unknown_and_duplicate_fields(self) -> None:
        materialization = self.root / "materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        value["unknown"] = True
        (materialization / "MATERIALIZATION.json").write_text(
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "unknown"):
            sleigh_package.verify_materialization(materialization)
        (materialization / "MATERIALIZATION.json").write_text(
            '{"schemaVersion":1,"schemaVersion":1}\n', encoding="utf-8"
        )
        with self.assertRaisesRegex(sleigh_package.PackageContractError, "duplicate"):
            sleigh_package.verify_materialization(materialization)

    def test_default_cmake_build_does_not_require_sleigh(self) -> None:
        if shutil.which("cmake") is None:
            self.skipTest("cmake unavailable")
        build = self.root / "default-build"
        subprocess.run(
            [
                "cmake",
                *cmake_generator_arguments(),
                "-S",
                str(ROOT / "Tools/NativeDecompilerBridge"),
                "-B",
                str(build),
                "-DBUILD_TESTING=OFF",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        )
        subprocess.run(
            ["cmake", "--build", str(build), "--parallel", "2"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=180,
        )

    def test_optional_cmake_probe_requires_materialization_root(self) -> None:
        if shutil.which("cmake") is None:
            self.skipTest("cmake unavailable")
        build = self.root / "missing-root-build"
        completed = subprocess.run(
            [
                "cmake",
                *cmake_generator_arguments(),
                "-S",
                str(ROOT / "Tools/NativeDecompilerBridge"),
                "-B",
                str(build),
                "-DBUILD_TESTING=OFF",
                "-DMACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE=ON",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("MACSCOPE_SLEIGH_MATERIALIZATION_ROOT", completed.stdout)

    def test_cmake_verifies_package_before_executing_upstream_config(self) -> None:
        if shutil.which("cmake") is None:
            self.skipTest("cmake unavailable")
        materialization = self.root / "tampered-materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        (materialization / "MATERIALIZATION.json").write_text(
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        marker = "UNTRUSTED_SLEIGH_CONFIG_EXECUTED"
        config = materialization / "package/lib/cmake/sleigh/sleighConfig.cmake"
        config.write_text(f'message(FATAL_ERROR "{marker}")\n', encoding="utf-8")
        build = self.root / "tampered-probe-build"
        completed = subprocess.run(
            [
                "cmake",
                *cmake_generator_arguments(),
                "-S",
                str(ROOT / "Tools/NativeDecompilerBridge"),
                "-B",
                str(build),
                "-DBUILD_TESTING=OFF",
                "-DMACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE=ON",
                f"-DMACSCOPE_SLEIGH_MATERIALIZATION_ROOT={materialization}",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("native package verification failed", completed.stdout)
        self.assertNotIn(marker, completed.stdout)

    def test_cmake_rejects_symlink_materialization_root(self) -> None:
        if shutil.which("cmake") is None:
            self.skipTest("cmake unavailable")
        materialization = self.root / "real-materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        (materialization / "MATERIALIZATION.json").write_text(
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        link = self.root / "linked-materialized"
        try:
            link.symlink_to(materialization, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks unavailable")
        build = self.root / "linked-probe-build"
        completed = subprocess.run(
            [
                "cmake",
                *cmake_generator_arguments(),
                "-S",
                str(ROOT / "Tools/NativeDecompilerBridge"),
                "-B",
                str(build),
                "-DBUILD_TESTING=OFF",
                "-DMACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE=ON",
                f"-DMACSCOPE_SLEIGH_MATERIALIZATION_ROOT={link}",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("native package verification failed", completed.stdout)

    def test_optional_cmake_probe_builds_and_executes_with_contract_fixture(self) -> None:
        if shutil.which("cmake") is None:
            self.skipTest("cmake unavailable")
        materialization = self.root / "materialized"
        materialization.mkdir()
        shutil.move(self.package, materialization / "package")
        value = canonical_manifest(materialization / "package")
        (materialization / "MATERIALIZATION.json").write_text(
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        build = self.root / "probe-build"
        subprocess.run(
            [
                "cmake",
                *cmake_generator_arguments(),
                "-S",
                str(ROOT / "Tools/NativeDecompilerBridge"),
                "-B",
                str(build),
                "-DBUILD_TESTING=ON",
                "-DMACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE=ON",
                f"-DMACSCOPE_SLEIGH_MATERIALIZATION_ROOT={materialization}",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        )
        subprocess.run(
            [
                "cmake", "--build", str(build), "--parallel", "2",
                "--target", "macscope_sleigh_decomp_api_probe",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        )
        subprocess.run(
            ["ctest", "--test-dir", str(build), "-R", "macscope_sleigh_decomp_api_probe", "--output-on-failure"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        )


class SafeExtractionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)

    def archive(self, members: list[tuple[tarfile.TarInfo, bytes]]) -> pathlib.Path:
        path = self.root / "archive.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for info, payload in members:
                archive.addfile(info, io.BytesIO(payload) if info.isfile() else None)
        return path

    def test_valid_archive_extracts_ordinary_files(self) -> None:
        directory = tarfile.TarInfo("prefix")
        directory.type = tarfile.DIRTYPE
        file = tarfile.TarInfo("prefix/file")
        file.size = 4
        file.mode = 0o755
        destination = self.root / "destination"
        destination.mkdir()
        extract_sleigh_package.extract(self.archive([(directory, b""), (file, b"data")]), destination)
        self.assertEqual((destination / "prefix/file").read_bytes(), b"data")
        self.assertTrue(os.access(destination / "prefix/file", os.X_OK))

    def test_traversal_link_and_duplicate_members_are_rejected(self) -> None:
        traversal = tarfile.TarInfo("../escape")
        traversal.size = 1
        link = tarfile.TarInfo("link")
        link.type = tarfile.SYMTYPE
        link.linkname = "target"
        first = tarfile.TarInfo("duplicate")
        first.size = 1
        second = tarfile.TarInfo("duplicate")
        second.size = 1
        for index, members in enumerate(
            [
                [(traversal, b"x")],
                [(link, b"")],
                [(first, b"a"), (second, b"b")],
            ]
        ):
            destination = self.root / f"destination-{index}"
            destination.mkdir()
            with self.assertRaises(extract_sleigh_package.ExtractionError):
                extract_sleigh_package.extract(self.archive(members), destination)
            (self.root / "archive.tar.gz").unlink()

    def test_nonempty_destination_is_rejected(self) -> None:
        file = tarfile.TarInfo("file")
        file.size = 1
        destination = self.root / "destination"
        destination.mkdir()
        (destination / "existing").write_text("x", encoding="utf-8")
        with self.assertRaisesRegex(extract_sleigh_package.ExtractionError, "empty"):
            extract_sleigh_package.extract(self.archive([(file, b"x")]), destination)


class MaterializerSurfaceTests(unittest.TestCase):
    def test_materializer_contains_immutable_artifact_contract(self) -> None:
        script = (ROOT / "Scripts/dependencies/materialize_sleigh_native_dcp03b4.sh").read_text(
            encoding="utf-8"
        )
        for artifact in sleigh_package.APPROVED_ARTIFACTS.values():
            self.assertIn(artifact.filename, script)
            self.assertIn(artifact.sha256, script)
            self.assertIn(artifact.url.rsplit("/", 1)[0], script)
        self.assertIn("extract_sleigh_package.py", script)
        self.assertIn("verify_sleigh_package.py", script)
        self.assertIn("--proto '=https'", script)
        self.assertGreaterEqual(script.count('"${PYTHON}" -B'), 5)
        self.assertIn("--connect-timeout 30", script)
        self.assertIn("--max-time 1800", script)
        self.assertNotIn("pip install", script)
        self.assertNotIn("git clone", script)

    def test_normal_entrypoints_do_not_invoke_materializer(self) -> None:
        token = "materialize_sleigh_native_dcp03b4"
        for relative in ("Scripts/bootstrap.sh", "Scripts/test.sh", "MacScope/project.yml"):
            self.assertNotIn(token, (ROOT / relative).read_text(encoding="utf-8"))

    def test_test_entrypoint_prepares_repository_native_inputs_and_preserves_overrides(self) -> None:
        script = (ROOT / "Scripts/test.sh").read_text(encoding="utf-8")
        self.assertIn('if [[ -z "${MACSCOPE_SLEIGH_MATERIALIZATION_ROOT:-}" ]]', script)
        self.assertIn("prepare_repository_sleigh_materialization.py", script)
        self.assertIn("${REPO_ROOT}/ThirdParty/SleighNative", script)
        self.assertIn("${REPO_ROOT}/ThirdParty/MachOKit/materialization", script)
        self.assertIn('XCODEBUILD_INPUT_SETTINGS=()', script)
        self.assertNotIn('XCODEBUILD_INPUT_SETTINGS+=("MACSCOPE_GHOSTTY_SOURCE_DIR=', script)
        self.assertNotIn("MACSCOPE_GHOSTTY_VT_WORK_ROOT", script)
        self.assertIn(
            'XCODEBUILD_INPUT_SETTINGS+=("MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=${MACSCOPE_SLEIGH_MATERIALIZATION_ROOT}")',
            script,
        )
        self.assertIn('"${XCODEBUILD_INPUT_SETTINGS[@]}"', script)
        self.assertEqual(script.count("COMPILER_INDEX_STORE_ENABLE=NO"), 1)
        self.assertNotIn("COMPILER_INDEX_STORE_ENABLE", (ROOT / "MacScope/project.yml").read_text())

    def test_bootstrap_publishes_the_repository_sleigh_component(self) -> None:
        script = (ROOT / "Scripts/bootstrap.sh").read_text(encoding="utf-8")
        self.assertIn('if [[ -z "${SLEIGH_ROOT}" ]]', script)
        self.assertIn("prepare_repository_sleigh_materialization.py", script)
        self.assertIn('${REPO_ROOT}/ThirdParty/SleighNative', script)
        self.assertIn('MACSCOPE_SLEIGH_MATERIALIZATION_WORK_ROOT', script)

    def test_bootstrap_forwards_both_verified_dependency_roots_to_xcode(self) -> None:
        script = (ROOT / "Scripts/bootstrap.sh").read_text(encoding="utf-8")
        self.assertIn('SLEIGH_ROOT="${MACSCOPE_SLEIGH_MATERIALIZATION_ROOT:-}"', script)
        self.assertIn(
            'MACSCOPE_SLEIGH_COMPONENT_ROOT = ${SLEIGH_COMPONENT_ROOT}',
            script,
        )
        self.assertIn(
            'MACSCOPE_SLEIGH_MATERIALIZATION_ROOT = ${SLEIGH_ROOT}',
            script,
        )


if __name__ == "__main__":
    unittest.main()
