from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
DEPENDENCY_SCRIPTS = ROOT / "Scripts" / "dependencies"


def load_module(filename: str, module_name: str):
    path = DEPENDENCY_SCRIPTS / filename
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


inventory = load_module(
    "validate_third_party_components.py", "macscope_validate_third_party_components"
)
policy = load_module(
    "validate_policy_consistency.py", "macscope_validate_policy_consistency"
)
offline = load_module(
    "validate_offline_build_surface.py", "macscope_validate_offline_build_surface"
)
census = load_module(
    "audit_dependency_census.py", "macscope_audit_dependency_census"
)
from Scripts.dependencies.validate_third_party_components import (
    InventoryValidationError as CensusInventoryValidationError,
)


def hosted_unmaterialized_lumen(root: pathlib.Path) -> bool:
    """Only the explicit public hosted lane may exercise the missing-package contract."""
    if os.environ.get("MACSCOPE_HOSTED_UNMATERIALIZED_FIRST_PARTY") != "1":
        return False
    target = root / "ThirdParty/Lumen"
    if target.parent.is_symlink() or target.is_symlink():
        return False
    return not target.exists() or (target.is_dir() and not any(target.iterdir()))


UNMATERIALIZED_LUMEN_ERROR = (
    r"repository root does not match the Git worktree root|No such file or directory: .*ThirdParty/Lumen"
)


class GovernanceFixture:
    FILES = (
        ".gitignore",
        "MacScope/PARITY_CONTRACT.md",
        "MacScope/project.yml",
        "MacScope/Services/FunctionSignatures/FunctionSignatureCorpus.swift",
        "Scripts/bootstrap.sh",
        "Scripts/test.sh",
        "docs/dependencies/DEPENDENCY_CENSUS.md",
        "MacScope/Services/Phase2/QualificationGate/Phase2QualificationGateRuntimeCollector.swift",
        "Scripts/build_ghostty_vt.sh",
        "Scripts/ghostty-vt-source.contract",
        "Scripts/provision_ghostty_vt_ci.sh",
        "Scripts/qualify_local_private_build.sh",
        "Scripts/tests/test_decompiler_core_proof.py",
        "Scripts/tests/test_decompiler_dataflow.py",
        "Scripts/tests/test_decompiler_register_dataflow.py",
        "Scripts/tests/test_decompiler_load_image.py",
        "Scripts/tests/native_decompiler_pilot_fixtures.py",
        "Scripts/tests/test_native_decompiler_pilot.py",
        "Scripts/tests/test_native_decompiler_pilot_supervisor.py",
        "Scripts/tests/test_sleigh_native_package.py",
        "THIRD_PARTY_COMPONENTS.yml",
        "THIRD_PARTY_NOTICES.md",
        "docs/dependencies/LicenseDecision.md",
        "docs/dependencies/DependencyWorkflow.md",
        "docs/dependencies/THIRD_PARTY_COMPONENT_EXAMPLE.yml",
    )
    DIRECTORIES = (
        "Scripts/dependencies",
        "Scripts/function-signatures",
        "Scripts/decompiler-proof",
        "Tools/DecompilerCoreProof",
        "Tools/NativeDecompilerBridge",
        "Tools/NativeDecompilerPilot",
        "Scripts/native-decompiler-pilot",
        "Scripts/native-decompiler-direct",
    )

    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        for relative in self.FILES:
            source = ROOT / relative
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        for relative in self.DIRECTORIES:
            source = ROOT / relative
            destination = root / relative
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(source, destination)
        # This legacy fixture models only external components; first-party ownership
        # has real Git and sealed-export fixtures in test_first_party_dependency_governance.
        (root / "Scripts/dependencies/materialize_lumen_submodule.py").unlink(missing_ok=True)
        # Keep the synthetic repository aligned with the canonical manifest instead of
        # duplicating its governed path inventory in this fixture. This preserves the tests'
        # intended mutation target when a reviewed component gains another tracked consumer.
        manifest = json.loads(
            (root / "THIRD_PARTY_COMPONENTS.yml").read_text(encoding="utf-8")
        )
        for component in manifest["components"]:
            for relative in component["tracked_paths"]:
                source = ROOT / relative
                destination = root / relative
                if destination.exists():
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                if source.is_dir():
                    if pathlib.Path(relative).parts[0] == "ThirdParty":
                        destination.mkdir()
                    else:
                        shutil.copytree(source, destination)
                else:
                    shutil.copy2(source, destination)
            # Mutation tests need actual governance records, not another copy of every
            # vendored source/toolchain. The real-root test still audits the complete
            # repository; these isolated fixtures preserve ownership roots and records.
            for relative in (
                component["license_paths"]
                + component["notice_paths"]
                + [component["patches_path"]]
            ):
                if pathlib.Path(relative).parts[0] != "ThirdParty":
                    continue
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, destination)

    @property
    def manifest_path(self) -> pathlib.Path:
        return self.root / "THIRD_PARTY_COMPONENTS.yml"

    def manifest(self) -> dict[str, object]:
        return json.loads(self.manifest_path.read_text(encoding="utf-8"))

    def write_manifest(self, value: dict[str, object]) -> None:
        self.manifest_path.write_text(
            json.dumps(value, indent=2, sort_keys=False) + "\n", encoding="utf-8"
        )


class DependencyGovernanceTests(unittest.TestCase):
    def test_hosted_absence_boundary_never_classifies_populated_or_symlink_modules(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            target = root / "ThirdParty/Lumen"
            target.parent.mkdir()
            with mock.patch.dict(os.environ, {"MACSCOPE_HOSTED_UNMATERIALIZED_FIRST_PARTY": "1"}):
                self.assertTrue(hosted_unmaterialized_lumen(root))
                target.mkdir()
                self.assertTrue(hosted_unmaterialized_lumen(root))
                (target / "Package.swift").write_text("dirty or partial package")
                self.assertFalse(hosted_unmaterialized_lumen(root))
                (target / "Package.swift").unlink()
                target.rmdir()
                target.symlink_to(root / "absent")
                self.assertFalse(hosted_unmaterialized_lumen(root))
                target.unlink()
            with mock.patch.dict(os.environ, {"MACSCOPE_HOSTED_UNMATERIALIZED_FIRST_PARTY": "0"}):
                self.assertFalse(hosted_unmaterialized_lumen(root))

    def with_fixture(self):
        temporary = tempfile.TemporaryDirectory()
        root = pathlib.Path(temporary.name)
        return temporary, GovernanceFixture(root)

    def with_ghostty_offline_fixture(self):
        temporary = tempfile.TemporaryDirectory()
        root = pathlib.Path(temporary.name)
        for relative in (
            "Scripts/bootstrap.sh",
            "Scripts/build_ghostty_vt.sh",
            "Scripts/dependencies/build_ghostty_surface.sh",
            "Scripts/dependencies/build_vendored_ghostty_surface.sh",
            "Scripts/dependencies/materialize_ghostty_vt.sh",
        ):
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
        return temporary, root

    def test_mutation_fixture_copies_only_governance_metadata_without_aliasing_sources(self) -> None:
        original_copytree = shutil.copytree

        def reject_vendor_tree_copy(source, destination, *args, **kwargs):
            # Fail before copying gigabytes if the old fixture behavior returns.
            self.assertFalse(
                pathlib.Path(source).is_relative_to(ROOT / "ThirdParty"),
                "mutation fixtures must not recursively copy vendored payloads",
            )
            return original_copytree(source, destination, *args, **kwargs)

        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(shutil, "copytree", side_effect=reject_vendor_tree_copy):
                fixture = GovernanceFixture(pathlib.Path(temporary))

            expected_files = set()
            for component in fixture.manifest()["components"]:
                candidates = (
                    component["tracked_paths"]
                    + component["license_paths"]
                    + component["notice_paths"]
                    + [component["patches_path"]]
                )
                expected_files.update(
                    relative
                    for relative in candidates
                    if pathlib.Path(relative).parts[0] == "ThirdParty"
                    and (ROOT / relative).is_file()
                )
                for relative in component["tracked_paths"]:
                    if (ROOT / relative).is_dir():
                        self.assertTrue((fixture.root / relative).is_dir(), relative)

            copied_files = {
                path.relative_to(fixture.root).as_posix()
                for path in (fixture.root / "ThirdParty").rglob("*")
                if path.is_file()
            }
            self.assertEqual(copied_files, expected_files)
            for relative in sorted(expected_files):
                with self.subTest(relative=relative):
                    source = ROOT / relative
                    copied = fixture.root / relative
                    original_bytes = source.read_bytes()
                    self.assertFalse(copied.samefile(source))
                    self.assertEqual(copied.read_bytes(), original_bytes)
                    copied.write_bytes(b"fixture-only mutation\n")
                    self.assertEqual(source.read_bytes(), original_bytes)

    def test_repository_policy_inventory_and_offline_surface_pass(self) -> None:
        policy_summary = policy.validate_policy_consistency(ROOT)
        if hosted_unmaterialized_lumen(ROOT):
            # Public checkout deliberately has no private package credentials or
            # seed. Prove rejection, not a successful native/root qualification.
            # These exact errors occur only after committed authority checks.
            with self.assertRaisesRegex(
                inventory.InventoryValidationError,
                UNMATERIALIZED_LUMEN_ERROR,
            ):
                inventory.validate_inventory(ROOT)
            temporary, fixture = self.with_fixture()
            self.addCleanup(temporary.cleanup)
            inventory_summary = inventory.validate_inventory(fixture.root)
            with self.assertRaisesRegex(
                CensusInventoryValidationError,
                UNMATERIALIZED_LUMEN_ERROR,
            ):
                census.audit_dependency_census(ROOT)
            census_summary = census.audit_dependency_census(fixture.root)
        else:
            # Native/default runs and every populated (including dirty, partial,
            # or wrong-pin) checkout must satisfy the real-root inventory gate.
            inventory_summary = inventory.validate_inventory(ROOT)
            census_summary = census.audit_dependency_census(ROOT)
        offline_summary = offline.validate_offline_build_surface(ROOT)

        self.assertEqual(policy_summary.decision_id, "DEP-2026-07-20")
        self.assertEqual(
            inventory_summary.component_ids,
            (
                "binexport2-schema",
                "compiler-rt-signature-corpus",
                "corkami-pocs-pe-specimens",
                "entitlements-comparison",
                "ghostty-surface",
                "ghostty-vt",
                "go-macho-parser-engine",
                "libghidra-dcp03b3-pilot",
                "lief-parser-engine",
                "machokit-v2",
                "pe-parse-parser-engine",
                "pypcode-dcp03-proof",
                "rea-selected",
                "sleigh-native-dcp03b4",
                "swift-assembly-vendor",
                "xcodegen-tool",
                "zig-toolchain",
            ),
        )
        self.assertEqual(
            offline_summary.network_materializer_scripts,
            (
                "Scripts/dependencies/materialize_ghostty_surface.sh",
                "Scripts/dependencies/materialize_ghostty_vt.sh",
                "Scripts/dependencies/materialize_libghidra_dcp03b3.sh",
                "Scripts/dependencies/materialize_pypcode_dcp03.sh",
                "Scripts/dependencies/materialize_sleigh_native_dcp03b4.sh",
                "Scripts/dependencies/materialize_zig_toolchain.sh",
            ),
        )
        self.assertEqual(census_summary["surface_count"], 3)
        self.assertEqual(census_summary["source_dependency_count"], 3)

    def test_offline_validator_inventories_direct_source_materializers_without_network_classification(self) -> None:
        summary = offline.validate_offline_build_surface(ROOT)

        for materializer in (
            "Scripts/dependencies/materialize_machokit.py",
            "Scripts/dependencies/materialize_swift_assembly.py",
        ):
            with self.subTest(materializer=materializer):
                self.assertIn(materializer, summary.materializer_scripts)
                self.assertNotIn(materializer, summary.network_materializer_scripts)

        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        manifest = fixture.manifest()
        machokit = next(
            item for item in manifest["components"] if item["id"] == "machokit-v2"
        )
        machokit["materialization"]["network_allowed"] = True
        fixture.write_manifest(manifest)
        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError,
            "network-enabled materializer has no detectable network operation",
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_gate_f_command_catalog_is_explicit_declarative_qualification_metadata(self) -> None:
        relative = "Scripts/reconstruction_gate_f/command_catalog.py"
        self.assertIn(relative, offline.REFERENCE_ONLY_ACQUISITION_PATHS)
        self.assertIn("Scripts/reconstruction_gate_f/tests/", offline.TEST_PREFIXES)
        catalog_text = (ROOT / relative).read_text(encoding="utf-8")
        self.assertIn("./Scripts/qualify_local_private_build.sh", catalog_text)
        self.assertNotRegex(
            catalog_text,
            r"\\b(?:subprocess|os\\.system|Popen|check_call|check_output)\\b",
        )

    def test_offline_validator_accepts_gate_f_offline_qualification_delegate(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        relative = "Scripts/reconstruction_gate_f/bootstrap_qualification.py"
        delegate = fixture.root / relative
        delegate.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, delegate)
        cli = fixture.root / "Scripts/reconstruction_gate_f/bootstrap_cli.py"
        shutil.copy2(ROOT / "Scripts/reconstruction_gate_f/bootstrap_cli.py", cli)
        for name in ("bootstrap_verifier.py", "bootstrap_verifier_adapter.py"):
            shutil.copy2(ROOT / "Scripts/reconstruction_gate_f" / name, cli.parent / name)

        summary = offline.validate_offline_build_surface(fixture.root)
        self.assertIn(relative, summary.scanned_files)
        self.assertIn("Scripts/reconstruction_gate_f/bootstrap_cli.py", summary.scanned_files)
        cli.write_text(cli.read_text(encoding="utf-8") + "# retained policy bytes\n", encoding="utf-8")
        changed = offline.validate_offline_build_surface(fixture.root)
        self.assertNotEqual(summary.surface_sha256, changed.surface_sha256)

    def test_offline_validator_accepts_readonly_bootstrap_consumers(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        for relative in (
            "Scripts/reconstruction_gate_f/bootstrap_verifier.py",
            "Scripts/reconstruction_gate_f/bootstrap_verifier_adapter.py",
            "Scripts/reconstruction_gate_f/bootstrap_reader_compatibility.py",
        ):
            consumer = fixture.root / relative
            consumer.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, consumer)
        summary = offline.validate_offline_build_surface(fixture.root)
        self.assertIn("Scripts/reconstruction_gate_f/bootstrap_verifier.py", summary.scanned_files)
        self.assertIn("Scripts/reconstruction_gate_f/bootstrap_verifier_adapter.py", summary.scanned_files)
        self.assertIn("Scripts/reconstruction_gate_f/bootstrap_reader_compatibility.py", summary.scanned_files)

    def test_offline_validator_rejects_execution_and_acquisition_in_readonly_consumers(self) -> None:
        for filename in ("bootstrap_verifier.py", "bootstrap_verifier_adapter.py", "bootstrap_reader_compatibility.py"):
            for mutation, expected in (
                ('bootstrap.execute_bootstrap_qualification(source, run, configuration)', "qualification execution"),
                ('urlopen("https://example.invalid")', "network-backed operation"),
                ('subprocess.run(["Scripts/dependencies/materialize_ghostty_vt.sh"])', "dependency acquisition"),
                ('subprocess.run(["materialize_new_dependency.py"])', "materializer"),
            ):
                with self.subTest(filename=filename, mutation=mutation):
                    temporary, fixture = self.with_fixture()
                    self.addCleanup(temporary.cleanup)
                    consumer = fixture.root / "Scripts/reconstruction_gate_f" / filename
                    consumer.parent.mkdir(parents=True, exist_ok=True)
                    source = ROOT / "Scripts/reconstruction_gate_f" / filename
                    consumer.write_text(source.read_text(encoding="utf-8") + "\n" + mutation + "\n", encoding="utf-8")
                    with self.assertRaisesRegex(offline.OfflineBuildValidationError, expected):
                        offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_rejects_acquisition_in_gate_f_offline_delegate(self) -> None:
        mutations = (
            ('\nurlopen("https://example.invalid")\n', "network-backed operation"),
            ('\nsubprocess.run(["Scripts/dependencies/materialize_ghostty_vt.sh"])\n', "dependency acquisition"),
            ('\nsubprocess.run(["Scripts/dependencies/materialize_machokit.py"])\n', "materializer"),
            ('\nsubprocess.run(["materialize_new_dependency.py"])\n', "materializer"),
            ('\nargv.append("--materialize-dependencies")\n', "dependency acquisition"),
            ('\nsubprocess.run(["Scripts/provision_ghostty_vt_ci.sh"])\n', "dependency acquisition"),
            ('\nsubprocess.run(["Scripts/reconstruction_gate_f/bootstrap_cli.py"])\n', "dependency acquisition"),
            ('\nsubprocess.run(["Scripts/dependencies/materialize_candidate_identity.py"])\n', "materializer"),
        )
        for mutation, expected in mutations:
            with self.subTest(mutation=mutation):
                temporary, fixture = self.with_fixture()
                self.addCleanup(temporary.cleanup)
                relative = "Scripts/reconstruction_gate_f/bootstrap_qualification.py"
                delegate = fixture.root / relative
                delegate.parent.mkdir(parents=True, exist_ok=True)
                delegate.write_text((ROOT / relative).read_text(encoding="utf-8") + mutation, encoding="utf-8")
                with self.assertRaisesRegex(offline.OfflineBuildValidationError, expected):
                    offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_scans_gate_f_offline_cli_for_network_and_materializers(self) -> None:
        for mutation, expected in (
            ('\nurlopen("https://example.invalid")\n', "network-backed operation"),
            ('\nsubprocess.run(["materialize_new_dependency.py"])\n', "materializer"),
            ('\nargv.append("--materialize-dependencies")\n', "dependency acquisition"),
            ('\nsubprocess.run(["Scripts/qualify_local_private_build.sh"])\n', "dependency acquisition"),
        ):
            with self.subTest(mutation=mutation):
                temporary, fixture = self.with_fixture()
                self.addCleanup(temporary.cleanup)
                cli = fixture.root / "Scripts/reconstruction_gate_f/bootstrap_cli.py"
                cli.parent.mkdir(parents=True, exist_ok=True)
                cli.write_text("from . import bootstrap_qualification as bootstrap\n" + mutation, encoding="utf-8")
                with self.assertRaisesRegex(offline.OfflineBuildValidationError, expected):
                    offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_rejects_ordinary_calls_to_gate_f_offline_delegate(self) -> None:
        for relative, invocation in (
            ("Scripts/bootstrap.sh", "python3 Scripts/reconstruction_gate_f/bootstrap_qualification.py"),
            ("Scripts/test.sh", "python3 -m Scripts.reconstruction_gate_f.bootstrap_cli execute"),
            ("Scripts/hidden_helper.py", "from Scripts.reconstruction_gate_f import bootstrap_qualification"),
        ):
            with self.subTest(relative=relative, invocation=invocation):
                temporary, fixture = self.with_fixture()
                self.addCleanup(temporary.cleanup)
                caller = fixture.root / relative
                existing = caller.read_text(encoding="utf-8") if caller.exists() else ""
                caller.write_text(existing + '\n' + invocation + '\n', encoding="utf-8")
                with self.assertRaisesRegex(offline.OfflineBuildValidationError, "dependency acquisition"):
                    offline.validate_offline_build_surface(fixture.root)




    def test_policy_validator_rejects_superseded_clean_room_contract(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        parity = fixture.root / "MacScope/PARITY_CONTRACT.md"
        parity.write_text(
            parity.read_text(encoding="utf-8")
            + "\nClean-room implementation (binding)\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            policy.PolicyConsistencyError, "superseded policy text"
        ):
            policy.validate_policy_consistency(fixture.root)

    def test_policy_validator_rejects_public_distribution_claim_while_unresolved(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        manifest = fixture.manifest()
        manifest["distribution_policy"]["status"] = "distribution-approved"
        manifest["distribution_policy"]["public_distribution_approved"] = True
        fixture.write_manifest(manifest)

        with self.assertRaisesRegex(
            policy.PolicyConsistencyError, "public distribution|distribution disabled"
        ):
            policy.validate_policy_consistency(fixture.root)

    def test_policy_validator_rejects_pilot_authority_for_default_native_product(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        manifest = fixture.manifest()
        component = next(
            item
            for item in manifest["components"]
            if item["id"] == "sleigh-native-dcp03b4"
        )
        component["approval"] = "pilot-approved"
        component["integration_mode"] = "developer-tool"
        fixture.write_manifest(manifest)

        with self.assertRaisesRegex(
            policy.PolicyConsistencyError,
            "default native product authority",
        ):
            policy.validate_policy_consistency(fixture.root)

    def test_policy_validator_rejects_dependency_pin_drift_from_build_contract(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        manifest = fixture.manifest()
        zig = next(
            item for item in manifest["components"] if item["id"] == "zig-toolchain"
        )
        zig["pin"]["version"] = "0.15.2"
        fixture.write_manifest(manifest)

        with self.assertRaisesRegex(
            policy.PolicyConsistencyError,
            "Zig build contract disagrees with THIRD_PARTY_COMPONENTS.yml",
        ):
            policy.validate_policy_consistency(fixture.root)

    def test_policy_validator_rejects_ghostty_surface_identity_drift(self) -> None:
        for pin_key in ("git_revision", "source_sha256", "source_tree_sha256", "version"):
            with self.subTest(pin_key=pin_key):
                temporary, fixture = self.with_fixture()
                self.addCleanup(temporary.cleanup)
                manifest = fixture.manifest()
                surface = next(
                    item
                    for item in manifest["components"]
                    if item["id"] == "ghostty-surface"
                )
                surface["pin"][pin_key] = (
                    "0" * 40 if pin_key == "git_revision" else
                    "0" * 64 if pin_key.endswith("sha256") else
                    "drifted"
                )
                fixture.write_manifest(manifest)

                with self.assertRaisesRegex(
                    policy.PolicyConsistencyError,
                    "Ghostty surface contract disagrees",
                ):
                    policy.validate_policy_consistency(fixture.root)

    def test_policy_validator_rejects_ghostty_surface_authority_drift(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        manifest = fixture.manifest()
        surface = next(
            item
            for item in manifest["components"]
            if item["id"] == "ghostty-surface"
        )
        surface["targets"] = ["MacScopeApp"]
        fixture.write_manifest(manifest)

        with self.assertRaisesRegex(
            policy.PolicyConsistencyError,
            "Ghostty surface contract disagrees",
        ):
            policy.validate_policy_consistency(fixture.root)

    def test_policy_validator_rejects_machokit_direct_source_identity_drift(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        manifest = fixture.manifest()
        machokit = next(
            item for item in manifest["components"] if item["id"] == "machokit-v2"
        )
        machokit["pin"]["git_revision"] = "0" * 40
        fixture.write_manifest(manifest)

        with self.assertRaisesRegex(
            policy.PolicyConsistencyError,
            "MachOKit direct-source contract disagrees",
        ):
            policy.validate_policy_consistency(fixture.root)

    def test_policy_validator_rejects_incomplete_machokit_source_license_expression(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        manifest = fixture.manifest()
        machokit = next(
            item for item in manifest["components"] if item["id"] == "machokit-v2"
        )
        machokit["license_expression"] = "MIT"
        fixture.write_manifest(manifest)

        with self.assertRaisesRegex(
            policy.PolicyConsistencyError,
            "MachOKit direct-source contract disagrees",
        ):
            policy.validate_policy_consistency(fixture.root)

    def test_policy_validator_rejects_missing_machokit_apsl_or_bsd_record(self) -> None:
        for missing_path in (
            "ThirdParty/MachOKit/LICENSE.APSL-2.0.txt",
            "ThirdParty/MachOKit/LICENSE.BSD-4-Clause-UCB.txt",
            "ThirdParty/MachOKit/LICENSE.BSD-3-Clause-Demetriou.txt",
        ):
            with self.subTest(missing_path=missing_path):
                temporary, fixture = self.with_fixture()
                self.addCleanup(temporary.cleanup)
                manifest = fixture.manifest()
                machokit = next(
                    item
                    for item in manifest["components"]
                    if item["id"] == "machokit-v2"
                )
                machokit["license_paths"].remove(missing_path)
                fixture.write_manifest(manifest)

                with self.assertRaisesRegex(
                    policy.PolicyConsistencyError,
                    "MachOKit direct-source contract disagrees",
                ):
                    policy.validate_policy_consistency(fixture.root)

    def test_policy_validator_rejects_missing_machokit_source_license_record(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        (fixture.root / "ThirdParty/MachOKit/LICENSE.CMU-Mach.txt").unlink()

        with self.assertRaisesRegex(
            policy.PolicyConsistencyError,
            "MachOKit CMU license is missing",
        ):
            policy.validate_policy_consistency(fixture.root)

    def test_policy_validator_rejects_machokit_source_license_content_drift(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        apsl = fixture.root / "ThirdParty/MachOKit/LICENSE.APSL-2.0.txt"
        apsl.write_text(
            apsl.read_text(encoding="utf-8") + "\nunauthorized drift\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            policy.PolicyConsistencyError,
            "MachOKit APSL-2.0 license checksum drift",
        ):
            policy.validate_policy_consistency(fixture.root)

    def test_policy_validator_rejects_swift_assembly_direct_source_form_drift(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        manifest = fixture.manifest()
        swift_assembly = next(
            item
            for item in manifest["components"]
            if item["id"] == "swift-assembly-vendor"
        )
        swift_assembly["integration_mode"] = "swift-package"
        fixture.write_manifest(manifest)

        with self.assertRaisesRegex(
            policy.PolicyConsistencyError,
            "swift-assembly direct-source contract disagrees",
        ):
            policy.validate_policy_consistency(fixture.root)

    def test_policy_validator_rejects_swift_assembly_compile_owner_drift(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        manifest = fixture.manifest()
        swift_assembly = next(
            item
            for item in manifest["components"]
            if item["id"] == "swift-assembly-vendor"
        )
        swift_assembly["targets"] = ["MacScopeApp"]
        fixture.write_manifest(manifest)

        with self.assertRaisesRegex(
            policy.PolicyConsistencyError,
            "swift-assembly direct-source contract disagrees",
        ):
            policy.validate_policy_consistency(fixture.root)

    def test_inventory_rejects_duplicate_json_keys(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        original = fixture.manifest_path.read_text(encoding="utf-8")
        fixture.manifest_path.write_text(
            original.replace(
                '  "schema_version": 1,',
                '  "schema_version": 1,\n  "schema_version": 1,',
                1,
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            inventory.InventoryValidationError, "duplicate JSON key"
        ):
            inventory.validate_inventory(fixture.root)

    def test_inventory_rejects_unknown_schema_field(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        manifest = fixture.manifest()
        manifest["unexpected"] = True
        fixture.write_manifest(manifest)

        with self.assertRaisesRegex(inventory.InventoryValidationError, "unknown keys"):
            inventory.validate_inventory(fixture.root)

    def test_inventory_rejects_empty_component_inventory(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        manifest = fixture.manifest()
        manifest["components"] = []
        fixture.write_manifest(manifest)

        with self.assertRaisesRegex(
            inventory.InventoryValidationError, r"1\.\.512 entries"
        ):
            inventory.validate_inventory(fixture.root)

    def test_inventory_accepts_copyleft_shipping_component(self) -> None:
        # Owner decision 2026-10-11: copyleft licenses may ship once approved.
        for license_expression in ("GPL-3.0-only", "LGPL-2.1-or-later", "AGPL-3.0-only"):
            with self.subTest(license_expression=license_expression):
                temporary, fixture = self.with_fixture()
                self.addCleanup(temporary.cleanup)
                manifest = fixture.manifest()
                manifest["components"][0]["license_expression"] = license_expression
                fixture.write_manifest(manifest)

                inventory.validate_inventory(fixture.root)

    def test_inventory_rejects_license_checksum_drift(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        manifest = fixture.manifest()
        manifest["components"][0]["license_sha256"] = "0" * 64
        fixture.write_manifest(manifest)

        with self.assertRaisesRegex(
            inventory.InventoryValidationError, "license checksum mismatch"
        ):
            inventory.validate_inventory(fixture.root)

    def test_inventory_rejects_missing_human_notice_marker(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        notices = fixture.root / "THIRD_PARTY_NOTICES.md"
        notices.write_text(
            notices.read_text(encoding="utf-8").replace(
                "<!-- component:ghostty-vt -->", "<!-- removed -->"
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(inventory.InventoryValidationError, "notice marker"):
            inventory.validate_inventory(fixture.root)

    def test_inventory_requires_native_sleigh_provider_consumers(self) -> None:
        for missing_target in (
            "macscope_native_decompiler_contract",
            "macscope_sleigh_decomp_api_probe",
        ):
            with self.subTest(missing_target=missing_target):
                temporary, fixture = self.with_fixture()
                self.addCleanup(temporary.cleanup)
                manifest = fixture.manifest()
                component = next(
                    item
                    for item in manifest["components"]
                    if item["id"] == "sleigh-native-dcp03b4"
                )
                component["targets"] = [
                    target for target in component["targets"] if target != missing_target
                ]
                fixture.write_manifest(manifest)

                with self.assertRaisesRegex(
                    inventory.InventoryValidationError,
                    rf"required consumer.*{missing_target}",
                ):
                    inventory.validate_inventory(fixture.root)

    def test_inventory_rejects_unowned_third_party_file(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        path = fixture.root / "ThirdParty/Unlisted/payload.bin"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"unreviewed")

        with self.assertRaisesRegex(
            inventory.InventoryValidationError, "ungoverned third-party paths"
        ):
            inventory.validate_inventory(fixture.root)

    def test_inventory_ignores_generated_xcode_build_products(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        artifact = (
            fixture.root
            / "MacScope/build/Debug/NativeDecompilerXPCService.xpc/Contents/Resources/libdecomp.a"
        )
        artifact.parent.mkdir(parents=True)
        artifact.write_bytes(b"generated build product")

        inventory.validate_inventory(fixture.root)

    def test_inventory_ignores_finder_metadata_in_third_party_root(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        metadata = fixture.root / "ThirdParty/.DS_Store"
        metadata.write_bytes(b"Finder metadata")

        inventory.validate_inventory(fixture.root)

    def test_offline_validator_rejects_downloader_in_bootstrap(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        bootstrap = fixture.root / "Scripts/bootstrap.sh"
        bootstrap.write_text(
            bootstrap.read_text(encoding="utf-8")
            + "\ncurl https://example.invalid/source.tar -o /tmp/source.tar\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "network-backed operation"
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_rejects_pip_acquisition_in_bootstrap(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        bootstrap = fixture.root / "Scripts/bootstrap.sh"
        bootstrap.write_text(
            bootstrap.read_text(encoding="utf-8")
            + "\npython3 -m pip download pypcode==4.0.0\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "network-backed operation"
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_rejects_zig_fetch_in_ordinary_bootstrap(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        bootstrap = fixture.root / "Scripts/bootstrap.sh"
        bootstrap.write_text(
            bootstrap.read_text(encoding="utf-8")
            + '\n"${ZIG}" build --fetch=all\n',
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "Zig package acquisition"
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_rejects_variable_indirected_zig_fetch(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        bootstrap = fixture.root / "Scripts/bootstrap.sh"
        bootstrap.write_text(
            bootstrap.read_text(encoding="utf-8")
            + "\n$ZIG_TOOLCHAIN build --fetch=all\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "Zig package acquisition"
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_rejects_braced_and_eval_zig_fetch(self) -> None:
        for command in (
            "${ZIG_TOOLCHAIN} build --fetch=all",
            "eval '$ZIG_TOOLCHAIN build --fetch=all'",
            "sh -c '${ZIG_TOOLCHAIN} build --fetch=all'",
        ):
            with self.subTest(command=command):
                temporary, fixture = self.with_fixture()
                self.addCleanup(temporary.cleanup)
                bootstrap = fixture.root / "Scripts/bootstrap.sh"
                bootstrap.write_text(
                    bootstrap.read_text(encoding="utf-8") + "\n" + command + "\n",
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(
                    offline.OfflineBuildValidationError, "Zig package acquisition"
                ):
                    offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_rejects_second_composed_materializer_fetch(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        materializer = fixture.root / "Scripts/dependencies/materialize_ghostty_vt.sh"
        materializer.write_text(
            materializer.read_text(encoding="utf-8")
            + "\neval '$ZIG_TOOLCHAIN build --fetch=all'\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "no composed/eval/sh Zig acquisition"
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_requires_bounded_ghostty_vt_materialization(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        materializer = fixture.root / "Scripts/dependencies/materialize_ghostty_vt.sh"
        materializer.write_text(
            materializer.read_text(encoding="utf-8").replace(
                " -Dsimd=false",
                "",
                1,
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "fail-closed seed closure path"
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_requires_verified_seed_before_snapshot_and_zig(self) -> None:
        for old, expected in (
            (
                "MACSCOPE_GHOSTTY_ZIG_PACKAGE_STORE_SOURCE",
                "fail-closed seed closure path",
            ),
            (
                '--root "${package_store_seed}"',
                "fail-closed seed closure path",
            ),
            (
                'ZIG_GLOBAL_CACHE_DIR="${isolated_global_cache}"',
                "bounded Ghostty VT materialization",
            ),
        ):
            with self.subTest(old=old):
                temporary, fixture = self.with_fixture()
                self.addCleanup(temporary.cleanup)
                materializer = fixture.root / "Scripts/dependencies/materialize_ghostty_vt.sh"
                materializer.write_text(
                    materializer.read_text(encoding="utf-8").replace(old, "MUTATED", 1),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(offline.OfflineBuildValidationError, expected):
                    offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_requires_source_verification_before_zig(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        materializer = fixture.root / "Scripts/dependencies/materialize_ghostty_vt.sh"
        materializer.write_text(
            materializer.read_text(encoding="utf-8").replace(
                '  normalize_ghostty_source_alias "${source_dir}"',
                '  "${SCRIPT_DIR}/materialize_zig_toolchain.sh" "${destination}"\n'
                '  normalize_ghostty_source_alias "${source_dir}"',
                1,
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError,
            "normalized Ghostty source must be verified before any Zig invocation",
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_requires_the_ordinary_ghostty_producer_graph(self) -> None:
        for required in (
            '"${SCRIPT_DIR}/dependencies/build_vendored_ghostty_surface.sh"',
            "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT = ${GHOSTTY_SURFACE_ARTIFACT_ROOT}",
        ):
            with self.subTest(required=required):
                temporary, ghostty_root = self.with_ghostty_offline_fixture()
                self.addCleanup(temporary.cleanup)
                bootstrap = ghostty_root / "Scripts/bootstrap.sh"
                bootstrap.write_text(
                    bootstrap.read_text(encoding="utf-8").replace(
                        required,
                        "REMOVED_GHOSTTY_PRODUCER_SEAM",
                        1,
                    ),
                    encoding="utf-8",
                )

                with self.assertRaisesRegex(
                    offline.OfflineBuildValidationError,
                    "produce or reuse exactly one vendored full-surface artifact",
                ):
                    offline._validate_ghostty_zig_closure(ghostty_root)

    def test_offline_validator_rejects_verifier_only_ordinary_ghostty_bootstrap(self) -> None:
        temporary, ghostty_root = self.with_ghostty_offline_fixture()
        self.addCleanup(temporary.cleanup)
        bootstrap = ghostty_root / "Scripts/bootstrap.sh"
        call = '"${SCRIPT_DIR}/dependencies/build_vendored_ghostty_surface.sh"'
        bootstrap.write_text(
            bootstrap.read_text(encoding="utf-8").replace(
                call,
                f"{call} --verify-only",
                1,
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError,
            "produce or reuse exactly one vendored full-surface artifact",
        ):
            offline._validate_ghostty_zig_closure(ghostty_root)

    def test_offline_validator_rejects_ghostty_source_tree_outputs(self) -> None:
        temporary, ghostty_root = self.with_ghostty_offline_fixture()
        self.addCleanup(temporary.cleanup)
        builder = ghostty_root / "Scripts/build_ghostty_vt.sh"
        builder.write_text(
            builder.read_text(encoding="utf-8")
            + '\nDYLIB="${GHOSTTY_DIR}/zig-out/lib/libghostty-vt.dylib"\n',
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError,
            "keep all artifacts and caches outside",
        ):
            offline._validate_ghostty_zig_closure(ghostty_root)

    def test_offline_validator_rejects_full_surface_repository_output(self) -> None:
        temporary, ghostty_root = self.with_ghostty_offline_fixture()
        self.addCleanup(temporary.cleanup)
        wrapper = ghostty_root / "Scripts/dependencies/build_vendored_ghostty_surface.sh"
        wrapper.write_text(
            wrapper.read_text(encoding="utf-8").replace(
                'OUTPUT_ROOT="${WORK_ROOT}/GhosttySurface"',
                'OUTPUT_ROOT="${REPO_ROOT}/GhosttySurface"',
                1,
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError,
            "full-surface producer",
        ):
            offline._validate_ghostty_zig_closure(ghostty_root)

    def test_offline_validator_rejects_network_in_vendored_surface_producer(self) -> None:
        temporary, ghostty_root = self.with_ghostty_offline_fixture()
        self.addCleanup(temporary.cleanup)
        wrapper = ghostty_root / "Scripts/dependencies/build_vendored_ghostty_surface.sh"
        wrapper.write_text(
            wrapper.read_text(encoding="utf-8")
            + "\ncurl https://example.invalid/ghostty -o /tmp/ghostty\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError,
            "Ghostty producer contains network-backed operation",
        ):
            offline._validate_ghostty_zig_closure(ghostty_root)

    def test_offline_validator_requires_closed_ghostty_package_store(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        builder = fixture.root / "Scripts/build_ghostty_vt.sh"
        builder.write_text(
            builder.read_text(encoding="utf-8").replace(
                '    --system "${PACKAGE_STORE}" \\\n',
                "",
                1,
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "closed Zig toolchain/package identity"
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_rejects_implicit_materializer_call(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        bootstrap = fixture.root / "Scripts/bootstrap.sh"
        bootstrap.write_text(
            bootstrap.read_text(encoding="utf-8")
            + '\n"${SCRIPT_DIR}/dependencies/materialize_ghostty_vt.sh" /tmp/deps\n',
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "normal entry point.*dependency acquisition"
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_rejects_normal_entrypoint_calling_legacy_shim(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        bootstrap = fixture.root / "Scripts/bootstrap.sh"
        bootstrap.write_text(
            bootstrap.read_text(encoding="utf-8")
            + '\n"${SCRIPT_DIR}/provision_ghostty_vt_ci.sh" /tmp/deps\n',
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "normal entry point.*dependency acquisition"
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_rejects_indirect_materializer_helper(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        helper = fixture.root / "Scripts/hidden_dependency_helper.sh"
        helper.write_text(
            '#!/usr/bin/env bash\n"$(dirname "$0")/dependencies/materialize_ghostty_vt.sh" /tmp/deps\n',
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "ordinary build helper.*dependency acquisition"
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_limits_lumen_station_sync_to_station_tooling(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        scripts = fixture.root / "Scripts"
        (scripts / "station.sh").write_text(
            '#!/usr/bin/env bash\n/usr/bin/python3 -B "${SCRIPT_DIR}/dependencies/'
            'materialize_lumen_submodule.py" --source-root "$1" --seed-repository "$2"\n',
            encoding="utf-8",
        )
        (scripts / "dev_loop.sh").write_text(
            '#!/usr/bin/env bash\n"${SCRIPT_DIR}/station.sh" sync "${ROOT_DIR}" >&2 || true\n',
            encoding="utf-8",
        )
        offline.validate_offline_build_surface(fixture.root)

        helper = scripts / "other_helper.sh"
        helper.write_text('#!/usr/bin/env bash\n"$(dirname "$0")/station.sh" sync\n', encoding="utf-8")
        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "ordinary build helper.*Scripts/station.sh"
        ):
            offline.validate_offline_build_surface(fixture.root)
        helper.unlink()
        bootstrap = scripts / "bootstrap.sh"
        bootstrap.write_text(
            bootstrap.read_text(encoding="utf-8") + '\n"${SCRIPT_DIR}/station.sh" sync\n', encoding="utf-8"
        )
        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "normal entry point.*dependency acquisition"
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_rejects_floating_package_declaration(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)
        project = fixture.root / "MacScope/project.yml"
        project.write_text(
            project.read_text(encoding="utf-8")
            + "\npackages:\n  Example:\n    url: https://example.invalid/example\n    branch: main\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            offline.OfflineBuildValidationError, "floating package declaration"
        ):
            offline.validate_offline_build_surface(fixture.root)

    def test_offline_validator_allows_network_only_in_manifested_materializer(self) -> None:
        temporary, fixture = self.with_fixture()
        self.addCleanup(temporary.cleanup)

        summary = offline.validate_offline_build_surface(fixture.root)

        self.assertIn(
            "Scripts/dependencies/materialize_ghostty_vt.sh",
            summary.network_materializer_scripts,
        )
        self.assertNotIn(
            "Scripts/dependencies/materialize_ghostty_vt.sh",
            summary.normal_entrypoints,
        )
        materializer = (
            fixture.root / "Scripts/dependencies/materialize_ghostty_vt.sh"
        ).read_text(encoding="utf-8")
        builder = (fixture.root / "Scripts/build_ghostty_vt.sh").read_text(
            encoding="utf-8"
        )
        bootstrap = (fixture.root / "Scripts/bootstrap.sh").read_text(encoding="utf-8")
        self.assertEqual(
            materializer.count(
                'ZIG_GLOBAL_CACHE_DIR="${isolated_global_cache}" "${zig_root}/zig" build -j1 \\'
            ),
            1,
        )
        self.assertIn('MACSCOPE_GHOSTTY_ZIG_PACKAGE_STORE_SOURCE:?', materializer)
        self.assertIn('--system "${package_store}"', materializer)
        self.assertNotIn("--fetch=all", materializer)
        self.assertNotIn("--fetch", builder)
        self.assertNotIn("--fetch", bootstrap)


class AuthoredParserFixtureGovernanceTests(unittest.TestCase):
    def test_exception_specimen_requires_source_and_keeps_neighbor_governed(self) -> None:
        with tempfile.TemporaryDirectory(dir=ROOT, prefix="exception-fixture-governance-") as temporary:
            root = pathlib.Path(temporary)
            directory = root / "Scripts/parser-oracles/exception-flow"
            directory.mkdir(parents=True)
            binary = directory / "exception_cases_O1.dylib"
            source = directory / "exception_cases.cpp"
            neighbor = directory / "unlisted.dylib"
            binary.write_bytes(b"inert fixture")
            neighbor.write_bytes(b"unlisted fixture")
            with mock.patch.object(inventory, "verified_component_roots", return_value=frozenset()):
                self.assertIn(binary.relative_to(root).as_posix(), inventory._discover_governed_files(root))
                source.write_text("extern void may_throw(int);\n")
                discovered = inventory._discover_governed_files(root)
                self.assertNotIn(binary.relative_to(root).as_posix(), discovered)
                self.assertIn(neighbor.relative_to(root).as_posix(), discovered)

    SPECIMENS = (
        ("Scripts/parser-oracles/type-atlas/mixed.dylib", "Scripts/parser-oracles/type-atlas/mixed.swift"),
        ("MacScope/Tests/Fixtures/UnwindLoops.dylib", "MacScope/Tests/Fixtures/UnwindLoops.S"),
        ("MacScope/Tests/Fixtures/CFARegister.dylib", "MacScope/Tests/Fixtures/CFARegister.S"),
    )

    def test_listed_specimens_require_regular_sources_and_keep_neighbors_governed(self) -> None:
        for binary_path, source_path in self.SPECIMENS:
            for source_kind in ("regular", "missing", "symlink", "directory", "neighbor"):
                with self.subTest(binary=binary_path, source_kind=source_kind):
                    with tempfile.TemporaryDirectory(dir=ROOT.parent, prefix="authored-fixture-governance-") as temporary:
                        root = pathlib.Path(temporary)
                        GovernanceFixture(root)
                        binary = root / binary_path
                        binary.parent.mkdir(parents=True, exist_ok=True)
                        binary.write_bytes(b"authored inert parser fixture")
                        source = root / source_path
                        if source_kind in ("regular", "neighbor"):
                            source.write_text("// authored fixture source\n")
                        elif source_kind == "symlink":
                            target = source.with_name("source-target.txt")
                            target.write_text("// existing source\n")
                            source.symlink_to(target)
                        elif source_kind == "directory":
                            source.mkdir()
                        if source_kind == "regular":
                            inventory.validate_inventory(root)
                        else:
                            rejected = binary.name
                            if source_kind == "neighbor":
                                neighbor = binary.with_name("unlisted.dylib")
                                neighbor.write_bytes(b"not exempt")
                                neighbor.with_suffix(".S").write_text("// neighboring source\n")
                                rejected = neighbor.name
                            with self.assertRaisesRegex(
                                inventory.InventoryValidationError,
                                "ungoverned third-party paths:.*" + rejected,
                            ):
                                inventory.validate_inventory(root)

    def test_exact_authored_dylib_requires_source_and_does_not_hide_neighbors(self) -> None:
        with tempfile.TemporaryDirectory(dir=ROOT.parent, prefix="authored-parser-governance-") as temporary:
            root = pathlib.Path(temporary)
            directory = root / "Scripts/parser-oracles/type-atlas"
            directory.mkdir(parents=True)
            fixture = directory / "mixed.dylib"
            fixture.write_bytes(b"authored inert parser fixture")
            source = directory / "mixed.swift"
            source.write_text("public struct Authored {}\n")
            neighbor = directory / "unregistered.dylib"
            neighbor.write_bytes(b"not covered")
            with mock.patch.object(inventory, "verified_component_roots", return_value=frozenset()):
                discovered = inventory._discover_governed_files(root)
                self.assertNotIn(fixture.relative_to(root).as_posix(), discovered)
                self.assertIn(neighbor.relative_to(root).as_posix(), discovered)
                source.unlink()
                self.assertIn(fixture.relative_to(root).as_posix(), inventory._discover_governed_files(root))


if __name__ == "__main__":
    unittest.main()
