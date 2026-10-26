#!/usr/bin/env python3

from __future__ import annotations

import copy
import hashlib
import json
import plistlib
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import zlib

from Scripts.reconstruction import installed_matrix_receipt as receipt
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
from Scripts.reconstruction_gate_f.materialize_candidate_identity import bundle_tree_digests
from Scripts.reconstruction_gate_f.tests import candidate_mapping
import Scripts.ws24_emit_installed_qualification_report as report


class InstalledMatrixReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.candidate_path = self.root / "candidate.json"
        self.preparation_path = self.root / "preparation.json"
        self.preparation_path.write_bytes(b"{}")
        self.installed_app = self.root / "Applications/MacScope.app"
        self.prepared_app = self.root / "Products/Debug/MacScope.app"
        self.ui_runner = self.root / "Products/Debug/MacScopeInstalledAppUITests-Runner.app"
        self.test_bundle = (
            self.ui_runner
            / "Contents/PlugIns/MacScopeInstalledAppUITests.xctest"
        )
        self.xctestrun = self.root / "Products/MacScopeInstalledAppUITests.xctestrun"
        self.execution_xctestrun = (
            self.root / "Products/MacScopeInstalledAppUITests-Task10OptIn.xctestrun"
        )
        self.xcresult = self.root / "Results/Installed.xcresult"
        self.receipt_path = self.root / "installed-matrix.receipt.json"
        self.developer_dir = self.root / "Xcode.app/Contents/Developer"
        (self.developer_dir / "usr/bin").mkdir(parents=True)
        (self.developer_dir / "usr/bin/xcodebuild").write_bytes(b"xcodebuild")
        (self.developer_dir / "usr/bin/xcodebuild").chmod(0o755)

        self._write_bundle(
            self.installed_app,
            "org.macscope.app",
            "MacScope",
            b"candidate-a",
        )
        self._write_bundle(
            self.prepared_app,
            "org.macscope.app",
            "MacScope",
            b"prepared-a",
        )
        self._write_bundle(
            self.test_bundle,
            "org.macscope.app.MacScopeInstalledAppUITests",
            "MacScopeInstalledAppUITests",
            b"tests-a",
        )
        self._write_bundle(
            self.ui_runner,
            "org.macscope.app.MacScopeInstalledAppUITests.xctrunner",
            "MacScopeInstalledAppUITests-Runner",
            b"runner-a",
        )
        duplicate_products = []
        for name in (
            "AIAgentWorkerXPCService",
            "AnalysisWorkerXPCService",
            "NativeDecompilerXPCService",
            "ShellBrokerXPCService",
        ):
            duplicate = self.root / f"Products/Debug/{name}.xpc"
            embedded = self.prepared_app / f"Contents/XPCServices/{name}.xpc"
            for product in (duplicate, embedded):
                self._write_bundle(
                    product,
                    f"org.macscope.app.{name}",
                    name,
                    name.encode(),
                )
            duplicate_products.append(f"__TESTROOT__/Debug/{name}.xpc")
        duplicate_package = (
            self.root
            / "Products/Debug/NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerPackage"
        )
        embedded_package = (
            self.prepared_app
            / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerPackage"
        )
        for package, mode in ((duplicate_package, 0o700), (embedded_package, 0o755)):
            package.mkdir(parents=True)
            package.chmod(mode)
            (package / "MATERIALIZATION.json").write_bytes(b"{}")
        duplicate_agent = self.root / "Products/Debug/ShellBrokerLaunchAgent"
        embedded_agent = self.prepared_app / "Contents/MacOS/ShellBrokerLaunchAgent"
        for agent in (duplicate_agent, embedded_agent):
            agent.write_bytes(b"launch-agent")
            agent.chmod(0o755)
        duplicate_products.append("__TESTROOT__/Debug/ShellBrokerLaunchAgent")
        self.xctestrun.parent.mkdir(parents=True, exist_ok=True)
        with self.xctestrun.open("wb") as stream:
            plistlib.dump(
                {
                    "__xctestrun_metadata__": {
                        "ContainerInfo": {"SchemeName": receipt.SCHEME}
                    },
                    receipt.TEST_TARGET: {
                        "BlueprintName": receipt.TEST_TARGET,
                        "EnvironmentVariables": {"TERM": "dumb"},
                        "TestingEnvironmentVariables": {
                            "XCODE_SCHEME_NAME": receipt.SCHEME
                        },
                        "TestHostPath": f"__TESTROOT__/Debug/{receipt.RUNNER_NAME}",
                        "TestBundlePath": (
                            f"__TESTHOST__/Contents/PlugIns/{receipt.TEST_BUNDLE_NAME}"
                        ),
                        "UITargetAppPath": "__TESTROOT__/Debug/MacScope.app",
                        "DependentProductPaths": [
                            "__TESTROOT__/Debug/MacScope.app",
                            f"__TESTROOT__/Debug/{receipt.RUNNER_NAME}",
                            (
                                f"__TESTROOT__/Debug/{receipt.RUNNER_NAME}/Contents/PlugIns/"
                                f"{receipt.TEST_BUNDLE_NAME}"
                            ),
                            *duplicate_products,
                        ],
                    },
                },
                stream,
            )
        receipt.write_execution_xctestrun_create_only(
            self.xctestrun,
            self.execution_xctestrun,
            self.installed_app,
        )
        self.xcresult.mkdir(parents=True)
        (self.xcresult / "Info.plist").write_bytes(b"result-a")
        self.selector_projection = report.installed_selector_projection()
        self.selectors = [
            item["test_identifier"] for item in self.selector_projection
        ]
        self.candidate = candidate_mapping()
        self.candidate["source"]["commit"] = "1" * 40
        self.candidate["source"]["tree"] = "2" * 40
        self._bind_candidate_to_installed_app()
        self._write_candidate()
        self.preparation_digest = "b" * 64

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_release_candidate_uses_exact_debug_xctestrun_placeholder(self) -> None:
        release_app = self.root / "Products/Release/MacScope.app"
        self._write_bundle(
            release_app,
            "org.macscope.app",
            "MacScope",
            b"release-candidate",
        )

        receipt._xctestrun_contract(
            self.xctestrun,
            test_bundle=self.test_bundle,
            ui_runner=self.ui_runner,
            installed_app=self.installed_app,
            prepared_app=release_app,
        )

    @staticmethod
    def _write_bundle(
        bundle: Path,
        identifier: str,
        executable_name: str,
        payload: bytes,
    ) -> None:
        executable = bundle / "Contents/MacOS" / executable_name
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_bytes(payload)
        executable.chmod(0o755)
        with (bundle / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": identifier}, stream)

    def _bind_candidate_to_installed_app(self) -> None:
        executable = self.installed_app / "Contents/MacOS/MacScope"
        digests = bundle_tree_digests(self.installed_app)
        self.candidate["application"].update(
            {
                "bundle_identifier": "org.macscope.app",
                "bundle_sha256": digests.content_sha256,
                "closed_tree_sha256": digests.closed_tree_sha256,
                "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            }
        )

    def _write_candidate(self) -> None:
        self.candidate_path.write_bytes(canonical_bytes(self.candidate))

    @staticmethod
    def _png(width: int, height: int, marker: int = 0) -> bytes:
        def chunk(kind: bytes, payload: bytes) -> bytes:
            return (
                len(payload).to_bytes(4, "big") + kind + payload
                + zlib.crc32(kind + payload).to_bytes(4, "big")
            )
        # The receipt checks the physical IHDR dimensions; an IDAT chunk keeps
        # this a real, independently parseable RGB PNG rather than a text stand-in.
        first_pixel = bytes((marker % 256, (marker * 17) % 256, (marker * 31) % 256))
        first_row = b"\x00" + first_pixel + b"\x00\x00\x00" * (width - 1)
        rows = first_row + b"".join(
            b"\x00" + b"\x00\x00\x00" * width for _ in range(height - 1)
        )
        return (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows))
            + chunk(b"IEND", b"")
        )

    def _presentation_screenshots(self) -> dict[str, object]:
        root = receipt._presentation_artifact_root(self.xcresult)
        if root.exists():
            manifest_path = root / "manifest.json"
            candidate, _ = receipt._candidate(self.candidate_path)
            return {
                "artifact_root_path": str(root),
                "manifest_path": str(manifest_path),
                "manifest_sha256": receipt.file_sha256(manifest_path),
                "attachments": receipt._manifest_attachment_rows(
                    manifest_path, artifact_root=root, candidate=candidate
                ),
            }
        root.mkdir()
        attachments = []
        for marker, (
            presentation_state, appearance, window_size, width, height
        ) in enumerate(
            receipt.PRESENTATION_VARIANTS, start=1
        ):
            exported = f"{presentation_state}-{appearance}-{window_size}.png"
            (root / exported).write_bytes(self._png(width, height, marker))
            attachments.append(
                {
                    "exportedFileName": exported,
                    "suggestedHumanReadableName": receipt._expected_presentation_attachment_name(
                        receipt._candidate(self.candidate_path)[0],
                        presentation_state,
                        appearance,
                        window_size,
                    ),
                    "isAssociatedWithFailure": False,
                    "configurationName": "Debug",
                    "deviceName": "Mac",
                    "deviceId": "mac",
                }
            )
        manifest = [{
            "testIdentifier": receipt.PRESENTATION_TEST_IDENTIFIER,
            "attachments": attachments,
        }]
        manifest_path = root / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        candidate, _ = receipt._candidate(self.candidate_path)
        return {
            "artifact_root_path": str(root),
            "manifest_path": str(manifest_path),
            "manifest_sha256": receipt.file_sha256(manifest_path),
            "attachments": receipt._manifest_attachment_rows(
                manifest_path, artifact_root=root, candidate=candidate
            ),
        }

    def _accessibility_observations(self) -> dict[str, object]:
        root = receipt._accessibility_observation_artifact_root(self.xcresult)
        if not root.exists():
            root.mkdir()
            manifest = []
            for index, item in enumerate(self.selector_projection):
                exported = f"observation-{index:02d}.json"
                observed = sorted(item["required_identifiers"])
                (root / exported).write_bytes(
                    canonical_bytes(
                        {
                            "schemaVersion": 1,
                            "vectorID": item["vector_id"],
                            "testIdentifier": item["test_identifier"],
                            "observedIdentifiers": observed,
                        }
                    )
                )
                manifest.append(
                    {
                        "testIdentifier": item["test_identifier"],
                        "attachments": [
                            {
                                "exportedFileName": exported,
                                "suggestedHumanReadableName": (
                                    receipt.ACCESSIBILITY_OBSERVATION_ATTACHMENT_NAME
                                ),
                                "isAssociatedWithFailure": False,
                            }
                        ],
                    }
                )
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        manifest_path = root / "manifest.json"
        attachments, observed_projection = (
            receipt._manifest_accessibility_observation_rows(
                manifest_path,
                artifact_root=root,
                selector_projection=self.selector_projection,
            )
        )
        return {
            "artifact_root_path": str(root),
            "manifest_path": str(manifest_path),
            "manifest_sha256": receipt.file_sha256(manifest_path),
            "attachments": attachments,
            "observed_selector_projection": observed_projection,
            "observed_selector_projection_sha256": receipt.canonical_sha256(
                observed_projection
            ),
        }

    def _preparation(self):
        return (
            {
                "source": {"commit": self.candidate["source"]["commit"]},
                "artifacts": {
                    "app": {"path": str(self.prepared_app)},
                    "xctestrun": {"path": str(self.xctestrun)},
                },
                "toolchain": {
                    "developer_dir": str(self.developer_dir),
                    "xcodebuild_sha256": receipt.file_sha256(
                        self.developer_dir / "usr/bin/xcodebuild"
                    ),
                },
            },
            self.preparation_digest,
        )

    def _create(self) -> dict[str, object]:
        command = receipt.expected_argv(
            self.developer_dir / "usr/bin/xcodebuild",
            self.execution_xctestrun,
            self.xcresult,
            self.selectors,
        )
        with (
            mock.patch.object(receipt, "_preparation", return_value=self._preparation()),
            mock.patch.object(
                receipt,
                "export_presentation_screenshots",
                side_effect=lambda *_args: self._presentation_screenshots(),
            ),
            mock.patch.object(
                receipt,
                "export_accessibility_observations",
                side_effect=lambda *_args: self._accessibility_observations(),
            ),
        ):
            return receipt.create_document(
                candidate_identity_path=self.candidate_path,
                preparation_receipt_path=self.preparation_path,
                installed_app=self.installed_app,
                prepared_xctestrun=self.xctestrun,
                execution_xctestrun=self.execution_xctestrun,
                test_bundle=self.test_bundle,
                ui_runner=self.ui_runner,
                xcresult=self.xcresult,
                argv=command,
                selectors=self.selectors,
                selector_projection=self.selector_projection,
                environment=receipt.expected_environment(
                    self.developer_dir, self.installed_app
                ),
                started_at_unix_ms=1000,
                ended_at_unix_ms=1400,
                exit_code=0,
            )

    def _validate(self, document: dict[str, object]) -> str:
        with mock.patch.object(receipt, "_preparation", return_value=self._preparation()):
            return receipt.validate_receipt(
                document,
                candidate_identity_path=self.candidate_path,
                installed_app=self.installed_app,
                expected_selector_projection=self.selector_projection,
            )

    def test_receipt_binds_candidate_preparation_products_command_and_result(self) -> None:
        document = self._create()
        self.assertEqual(self._validate(document), receipt.canonical_sha256(document))
        self.assertEqual(document["candidate"]["source_commit"], "1" * 40)
        self.assertEqual(document["execution"]["selectors"], self.selectors)
        self.assertEqual(
            document["execution"]["selector_projection"], self.selector_projection
        )
        self.assertEqual(
            document["execution"]["selector_projection_sha256"],
            receipt.canonical_sha256(self.selector_projection),
        )
        self.assertEqual(document["execution"]["result"], "passed")
        self.assertEqual(
            document["accessibility_observations"]["observed_selector_projection"],
            [
                {
                    "observed_identifiers": sorted(item["required_identifiers"]),
                    "test_identifier": item["test_identifier"],
                    "vector_id": item["vector_id"],
                }
                for item in self.selector_projection
            ],
        )
        self.assertEqual(
            set(document["products"]),
            {
                "installed_app", "prepared_xctestrun", "execution_xctestrun",
                "test_bundle", "ui_runner", "xcresult",
            },
        )
        screenshots = document["presentation_screenshots"]
        self.assertEqual(len(screenshots["attachments"]), 28)
        self.assertEqual(
            {(item["presentation_state"], item["appearance"], item["window_size"])
             for item in screenshots["attachments"]},
            {(presentation_state, appearance, window_size)
             for presentation_state, appearance, window_size, _, _
             in receipt.PRESENTATION_VARIANTS},
        )

    def test_presentation_catalog_is_exact_full_seven_by_two_by_two_cartesian_closure(self) -> None:
        self.assertEqual(receipt.PRESENTATION_STATES, (
            ("empty", "no-job"),
            ("created-active-execution", "no-job"),
            ("awaiting-model-paused", "paused-model-unavailable-awaiting-model"),
            ("active-model-round", "active-executing-reads"),
            ("partial-failure", "navigation-current"),
            ("completed", "terminal-completed"),
            ("reopen-resume", "active-retrieving"),
        ))
        self.assertEqual(len(receipt.PRESENTATION_STATES), 7)
        self.assertEqual(len(receipt.PRESENTATION_FORMATS), 4)
        self.assertEqual(len(receipt.PRESENTATION_VARIANTS), 28)
        self.assertEqual(
            set(receipt.PRESENTATION_VARIANTS),
            {
                (state_id, appearance, window_size, width, height)
                for state_id, _fixture_id in receipt.PRESENTATION_STATES
                for appearance, window_size, width, height
                in receipt.PRESENTATION_FORMATS
            },
        )

    def test_physical_receipt_emits_all_four_created_active_execution_variants(self) -> None:
        document = self._create()
        observed = {
            (row["presentation_state"], row["appearance"], row["window_size"])
            for row in document["presentation_screenshots"]["attachments"]
            if row["presentation_state"] == "created-active-execution"
        }
        self.assertEqual(observed, {
            ("created-active-execution", "light", "minimum"),
            ("created-active-execution", "light", "wide"),
            ("created-active-execution", "dark", "minimum"),
            ("created-active-execution", "dark", "wide"),
        })

    def test_retired_ingestion_images_cannot_substitute_for_created_active_execution(self) -> None:
        document = self._create()
        manifest_path = Path(document["presentation_screenshots"]["manifest_path"])
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        replacements = 0
        for attachment in manifest[0]["attachments"]:
            name = attachment["suggestedHumanReadableName"]
            if name.startswith((
                f"{receipt.PRESENTATION_SCENARIO}-created-active-execution-",
                f"{receipt.PRESENTATION_SCENARIO}-ingesting-indexing-",
            )):
                attachment["suggestedHumanReadableName"] = name.replace(
                    "created-active-execution", "ingesting-indexing"
                )
                replacements += 1
        self.assertEqual(replacements, 4)
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        document["presentation_screenshots"]["manifest_sha256"] = receipt.file_sha256(
            manifest_path
        )
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError, "unexpected scenario"
        ):
            self._validate(document)

    def test_presentation_missing_state_cannot_revalidate_full_cartesian_closure(self) -> None:
        document = self._create()
        missing_state = receipt.PRESENTATION_STATES[0][0]
        manifest_path = Path(document["presentation_screenshots"]["manifest_path"])
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        prefix = f"{receipt.PRESENTATION_SCENARIO}-{missing_state}-"
        manifest[0]["attachments"] = [
            attachment
            for attachment in manifest[0]["attachments"]
            if not attachment["suggestedHumanReadableName"].startswith(prefix)
        ]
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        document["presentation_screenshots"]["manifest_sha256"] = receipt.file_sha256(
            manifest_path
        )
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "seven-variant appearance-width Cartesian closure",
        ):
            self._validate(document)

    def test_presentation_27_physical_images_cannot_revalidate(self) -> None:
        document = self._create()
        manifest_path = Path(document["presentation_screenshots"]["manifest_path"])
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest[0]["attachments"].pop()
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        document["presentation_screenshots"]["manifest_sha256"] = receipt.file_sha256(
            manifest_path
        )
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "seven-variant appearance-width Cartesian closure",
        ):
            self._validate(document)

    def test_presentation_handoff_name_is_fixed_to_the_xcresult_basename(self) -> None:
        self.assertEqual(
            receipt.presentation_artifact_handoff_name(Path("Installed.xcresult")),
            "Installed.xcresult.presentation-screenshots",
        )

    def test_required_identifiers_only_drift_cannot_revalidate_frozen_execution(self) -> None:
        document = self._create()
        altered = copy.deepcopy(document)
        altered_projection = altered["execution"]["selector_projection"]
        altered_projection[0]["required_identifiers"] = ["reconstruction.result"]
        altered["execution"]["selector_projection_sha256"] = receipt.canonical_sha256(
            altered_projection
        )
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "selector projection differs from the canonical selector catalog",
        ):
            self._validate(altered)

    def test_missing_physically_observed_identifier_cannot_revalidate(self) -> None:
        document = self._create()
        attachment = document["accessibility_observations"]["attachments"][0]
        path = Path(attachment["attachment_path"])
        observed = json.loads(path.read_text(encoding="utf-8"))
        observed["observedIdentifiers"].pop()
        path.write_bytes(canonical_bytes(observed))
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "does not equal the frozen selector identifiers",
        ):
            self._validate(document)

    def test_presentation_receipt_refuses_missing_duplicate_and_dimension_mutations(self) -> None:
        document = self._create()
        for mutation, pattern in (
            (lambda value: value["attachments"].pop(), "physical identity differs"),
            (lambda value: value["attachments"].__setitem__(1, copy.deepcopy(value["attachments"][0])), "physical identity differs"),
            (lambda value: value["attachments"][0].__setitem__("pixel_width", 1), "physical identity differs"),
        ):
            altered = copy.deepcopy(document)
            mutation(altered["presentation_screenshots"])
            with self.subTest(mutation=pattern), self.assertRaisesRegex(
                receipt.InstalledMatrixReceiptError, pattern
            ):
                self._validate(altered)

    def test_presentation_export_uses_xcresulttool_and_requires_the_physical_closure(self) -> None:
        candidate, _ = receipt._candidate(self.candidate_path)

        def export(command: list[str], **kwargs: object) -> mock.Mock:
            self.assertEqual(command[:4], ["/usr/bin/xcrun", "xcresulttool", "export", "attachments"])
            self.assertEqual(kwargs["env"], {
                "DEVELOPER_DIR": str(self.developer_dir),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            })
            self._presentation_screenshots()
            return mock.Mock(returncode=0, stderr="")

        with mock.patch.object(receipt.subprocess, "run", side_effect=export):
            screenshots = receipt.export_presentation_screenshots(
                self.xcresult, candidate, self.developer_dir
            )
        self.assertEqual(len(screenshots["attachments"]), 28)

    def test_presentation_manifest_ignores_xcode_attachments_outside_the_governed_four(self) -> None:
        document = self._create()
        manifest_path = Path(document["presentation_screenshots"]["manifest_path"])
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        system_attachment = {
            "configurationName": "Test Scheme Action",
            "deviceId": "mac",
            "deviceName": "My Mac",
            "exportedFileName": "automatic-ui-snapshot",
            "isAssociatedWithFailure": False,
            "suggestedHumanReadableName": "UI Snapshot 2026-08-28 at 01.23.45 PM",
            "timestamp": 1_787_900_000.0,
        }
        manifest[0]["attachments"].append(system_attachment)
        manifest.append({
            "testIdentifier": "WS24InstalledAppUITests/testTask10CCancelFromActive()",
            "testIdentifierURL": (
                "test://com.apple.xcode/MacScope/MacScopeInstalledAppUITests/"
                "WS24InstalledAppUITests/testTask10CCancelFromActive"
            ),
            "attachments": [system_attachment],
        })
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        document["presentation_screenshots"]["manifest_sha256"] = receipt.file_sha256(
            manifest_path
        )
        self.assertEqual(self._validate(document), receipt.canonical_sha256(document))

    def test_presentation_export_refuses_wrong_candidate_or_appearance_in_physical_manifest(self) -> None:
        document = self._create()
        manifest_path = Path(document["presentation_screenshots"]["manifest_path"])
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest[0]["attachments"][0]["suggestedHumanReadableName"] = (
            receipt._expected_presentation_attachment_name(
                receipt._candidate(self.candidate_path)[0],
                receipt.PRESENTATION_STATES[0][0],
                "auto",
                "minimum",
            )
        )
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        # Keep the mutable receipt's manifest hash synchronized: this proves the
        # rejection comes from physical manifest semantics, not stale hash text.
        document["presentation_screenshots"]["manifest_sha256"] = receipt.file_sha256(manifest_path)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "unexpected scenario, appearance, width, or candidate",
        ):
            self._validate(document)

    def test_presentation_export_refuses_renamed_images_with_duplicate_content(self) -> None:
        document = self._create()
        by_variant = {
            (item["appearance"], item["window_size"]): Path(item["attachment_path"])
            for item in document["presentation_screenshots"]["attachments"]
        }
        # Keep valid geometry and distinct filenames. Only the repeated physical
        # pixels are corrupt, which must independently invalidate the receipt.
        by_variant[("dark", "minimum")].write_bytes(
            by_variant[("light", "minimum")].read_bytes()
        )
        by_variant[("dark", "wide")].write_bytes(
            by_variant[("light", "wide")].read_bytes()
        )
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "distinct physical content hashes for the full Cartesian closure",
        ):
            self._validate(document)

    def test_presentation_export_refuses_nonintegral_backing_scale(self) -> None:
        document = self._create()
        attachment = next(
            item
            for item in document["presentation_screenshots"]["attachments"]
            if item["appearance"] == "light" and item["window_size"] == "minimum"
        )
        Path(attachment["attachment_path"]).write_bytes(self._png(1_081, 680, 99))
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "one backing scale",
        ):
            self._validate(document)

    def test_presentation_rejects_truncated_and_corrupt_png_bytes(self) -> None:
        document = self._create()
        attachment = document["presentation_screenshots"]["attachments"][0]
        path = Path(attachment["attachment_path"])
        original = path.read_bytes()
        for label, mutated, pattern in (
            ("truncated", original[:-12], "lacks IHDR, IDAT, or IEND"),
            (
                "corrupt-crc",
                original[:29] + bytes([original[29] ^ 1]) + original[30:],
                "corrupt chunk CRC",
            ),
        ):
            with self.subTest(label=label):
                path.write_bytes(mutated)
                with self.assertRaisesRegex(
                    receipt.InstalledMatrixReceiptError, pattern
                ):
                    self._validate(document)
                path.write_bytes(original)

    def test_presentation_export_refuses_duplicate_physical_variant_even_with_a_fresh_manifest_hash(self) -> None:
        document = self._create()
        manifest_path = Path(document["presentation_screenshots"]["manifest_path"])
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest[0]["attachments"][1]["suggestedHumanReadableName"] = (
            manifest[0]["attachments"][0]["suggestedHumanReadableName"]
        )
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        document["presentation_screenshots"]["manifest_sha256"] = receipt.file_sha256(manifest_path)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "exactly the governed seven-variant appearance-width Cartesian closure",
        ):
            self._validate(document)

        # A different exact-looking candidate suffix is independently rejected.
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest[0]["attachments"][0]["suggestedHumanReadableName"] = (
            f"{receipt.PRESENTATION_SCENARIO}-empty-light-minimum-"
            f"{'0' * 40}-{'1' * 64}"
        )
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        document["presentation_screenshots"]["manifest_sha256"] = receipt.file_sha256(manifest_path)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "unexpected scenario, appearance, width, or candidate",
        ):
            self._validate(document)

    def test_execution_xctestrun_is_only_the_closed_four_entry_overlay(self) -> None:
        with self.xctestrun.open("rb") as stream:
            prepared = plistlib.load(stream)
        with self.execution_xctestrun.open("rb") as stream:
            execution = plistlib.load(stream)
        expected = copy.deepcopy(prepared)
        suite = expected[receipt.TEST_TARGET]
        for field in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            suite[field][receipt.OPT_IN_KEY] = "1"
            suite[field][receipt.INSTALLED_APP_KEY] = str(self.installed_app)
        self.assertEqual(execution, expected)
        receipt.validate_execution_xctestrun_overlay(
            self.xctestrun, self.execution_xctestrun, self.installed_app
        )

    def test_refuses_unrelated_execution_xctestrun_overlay_drift(self) -> None:
        with self.execution_xctestrun.open("rb") as stream:
            document = plistlib.load(stream)
        document[receipt.TEST_TARGET]["EnvironmentVariables"]["TERM"] = "ansi"
        with self.execution_xctestrun.open("wb") as stream:
            plistlib.dump(document, stream)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "differs from the exact installed opt-in overlay",
        ):
            self._create()

    def test_legacy_schema_two_receipt_cannot_claim_current_presentation_qualification(self) -> None:
        document = self._create()
        document["schema_version"] = 2
        document.pop("presentation_screenshots")
        document.pop("accessibility_observations")
        document["execution"].pop("selector_projection")
        document["execution"].pop("selector_projection_sha256")
        products = document["products"]
        products["xctestrun"] = products.pop("prepared_xctestrun")
        products.pop("execution_xctestrun")
        document["execution"]["argv"] = receipt.expected_argv(
            self.developer_dir / "usr/bin/xcodebuild",
            self.xctestrun,
            self.xcresult,
            self.selectors,
        )
        snapshot = copy.deepcopy(document["execution"]["input_snapshot_before"])
        snapshot["xctestrun"] = snapshot.pop("prepared_xctestrun")
        snapshot.pop("execution_xctestrun")
        document["execution"]["input_snapshot_before"] = copy.deepcopy(snapshot)
        document["execution"]["input_snapshot_after"] = copy.deepcopy(snapshot)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "predates the required physical presentation screenshot contract",
        ):
            self._validate(document)

    def test_installed_release_binds_application_not_debug_qualification_app(self) -> None:
        qualification_app = next(
            value
            for value in self.candidate["application"]["qualification_executables"]
            if value["identity_id"] == "app"
        )
        self.assertNotEqual(
            qualification_app["sha256"],
            self.candidate["application"]["executable_sha256"],
        )

        document = self._create()

        self.assertEqual(self._validate(document), receipt.canonical_sha256(document))

    def test_candidate_b_cannot_reuse_candidate_a_xcresult_and_runner_evidence(self) -> None:
        document = self._create()
        receipt.write_create_only(self.receipt_path, document)
        outer_descriptor = {
            "gate": "incremental-xcuitest",
            "proofArtifacts": [
                {
                    "kind": receipt.PROOF_ARTIFACT_KIND,
                    "path": str(self.receipt_path),
                    "sha256": receipt.file_sha256(self.receipt_path),
                },
                {"kind": "xcresult", "path": str(self.xcresult)},
            ],
        }

        candidate_b = copy.deepcopy(self.candidate)
        candidate_b["application"]["signing_certificate_sha256"] = "9" * 64
        self.candidate = candidate_b
        self._write_candidate()
        # Recompute the caller-controlled outer descriptor exactly as an
        # attacker/replayer could. It contains no candidate claims to forge.
        outer_descriptor = json.loads(json.dumps(outer_descriptor, sort_keys=True))

        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "candidate identity physical identity differs",
        ):
            self._validate(receipt.load_receipt(self.receipt_path))

    def test_ui_runner_late_mutation_is_named_as_a_physical_identity_mismatch(self) -> None:
        document = self._create()
        runner = self.ui_runner / "Contents/MacOS/MacScopeInstalledAppUITests-Runner"
        runner.write_bytes(b"runner-b")
        runner.chmod(0o755)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "ui runner physical identity differs",
        ):
            self._validate(document)

    def test_refuses_xctestrun_redirect_to_a_decoy_product(self) -> None:
        with self.xctestrun.open("rb") as stream:
            document = plistlib.load(stream)
        document[receipt.TEST_TARGET]["TestBundlePath"] = (
            "__TESTROOT__/Debug/decoy/MacScopeInstalledAppUITests.xctest"
        )
        with self.xctestrun.open("wb") as stream:
            plistlib.dump(document, stream)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError, "TestBundlePath does not bind"
        ):
            self._create()

    def test_refuses_xctestrun_redirect_to_a_decoy_test_host(self) -> None:
        with self.xctestrun.open("rb") as stream:
            document = plistlib.load(stream)
        document[receipt.TEST_TARGET]["TestHostPath"] = (
            "__TESTROOT__/Debug/DecoyInstalledAppUITests-Runner.app"
        )
        with self.xctestrun.open("wb") as stream:
            plistlib.dump(document, stream)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError, "TestHostPath does not bind"
        ):
            self._create()

    def test_refuses_uncatalogued_xcode_dependent_product(self) -> None:
        with self.xctestrun.open("rb") as stream:
            document = plistlib.load(stream)
        document[receipt.TEST_TARGET]["DependentProductPaths"].append(
            "__TESTROOT__/Debug/UncataloguedWorker.xpc"
        )
        with self.xctestrun.open("wb") as stream:
            plistlib.dump(document, stream)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "dependent product path does not bind a sealed product",
        ):
            self._create()

    def test_refuses_catalogued_duplicate_byte_drift(self) -> None:
        executable = (
            self.root
            / "Products/Debug/AIAgentWorkerXPCService.xpc/Contents/MacOS/AIAgentWorkerXPCService"
        )
        executable.write_bytes(b"drift")
        executable.chmod(0o755)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "duplicate product does not match its sealed prepared product",
        ):
            self._create()

    def test_refuses_catalogued_path_bound_to_a_decoy_product(self) -> None:
        source = (
            self.root
            / "Products/Debug/AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService"
        )
        decoy = (
            self.root
            / "Products/Debug/AIAgentWorkerXPCService.xpc/Contents/MacOS/AIAgentWorkerXPCService"
        )
        decoy.write_bytes(source.read_bytes())
        decoy.chmod(0o755)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "duplicate product does not match its sealed prepared product",
        ):
            self._create()

    def test_refuses_catalogued_duplicate_file_mode_drift(self) -> None:
        duplicate = self.root / "Products/Debug/ShellBrokerLaunchAgent"
        duplicate.chmod(0o700)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError,
            "duplicate product does not match its sealed prepared product",
        ):
            self._create()

    def test_semantic_preflight_refuses_decoy_before_any_runner_can_spawn(self) -> None:
        with self.xctestrun.open("rb") as stream:
            document = plistlib.load(stream)
        document[receipt.TEST_TARGET]["TestBundlePath"] = (
            "__TESTROOT__/Debug/decoy/MacScopeInstalledAppUITests.xctest"
        )
        with self.xctestrun.open("wb") as stream:
            plistlib.dump(document, stream)
        command = receipt.expected_argv(
            self.developer_dir / "usr/bin/xcodebuild", self.execution_xctestrun,
            self.root / "Results/future.xcresult", self.selectors,
        )
        with mock.patch.object(receipt, "_preparation", return_value=self._preparation()):
            with self.assertRaisesRegex(receipt.InstalledMatrixReceiptError, "TestBundlePath does not bind"):
                receipt.preflight_execution(
                    candidate_identity_path=self.candidate_path,
                    preparation_receipt_path=self.preparation_path,
                    installed_app=self.installed_app,
                    prepared_xctestrun=self.xctestrun,
                    execution_xctestrun=self.execution_xctestrun,
                    test_bundle=self.test_bundle,
                    ui_runner=self.ui_runner,
                    xcodebuild=self.developer_dir / "usr/bin/xcodebuild",
                    expected_xcresult=self.root / "Results/future.xcresult",
                    argv=command,
                    selectors=self.selectors,
                    selector_projection=self.selector_projection,
                    environment=receipt.expected_environment(self.developer_dir, self.installed_app),
                )

    def test_refuses_xctestrun_traversal_even_when_the_name_looks_right(self) -> None:
        with self.xctestrun.open("rb") as stream:
            document = plistlib.load(stream)
        document[receipt.TEST_TARGET]["UITargetAppPath"] = (
            f"__TESTROOT__/Debug/../Debug/{receipt.RUNNER_NAME}"
        )
        with self.xctestrun.open("wb") as stream:
            plistlib.dump(document, stream)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError, "traversal"
        ):
            self._create()

    def test_absent_xcresult_is_an_infrastructure_receipt_not_a_fake_matrix(self) -> None:
        before = receipt.capture_input_snapshot(
            candidate_identity_path=self.candidate_path,
            preparation_receipt_path=self.preparation_path,
            installed_app=self.installed_app,
            prepared_xctestrun=self.xctestrun,
            execution_xctestrun=self.execution_xctestrun,
            test_bundle=self.test_bundle,
            ui_runner=self.ui_runner,
            xcodebuild=self.developer_dir / "usr/bin/xcodebuild",
        )
        with mock.patch.object(receipt, "_preparation", return_value=self._preparation()):
            document = receipt.create_document(
                candidate_identity_path=self.candidate_path,
                preparation_receipt_path=self.preparation_path,
                installed_app=self.installed_app,
                prepared_xctestrun=self.xctestrun,
                execution_xctestrun=self.execution_xctestrun,
                test_bundle=self.test_bundle,
                ui_runner=self.ui_runner,
                xcresult=None,
                argv=receipt.expected_argv(
                    self.developer_dir / "usr/bin/xcodebuild", self.execution_xctestrun,
                    self.root / "Results/never-created.xcresult", self.selectors,
                ),
                selectors=self.selectors,
                selector_projection=self.selector_projection,
                environment=receipt.expected_environment(self.developer_dir, self.installed_app),
                started_at_unix_ms=1000,
                ended_at_unix_ms=1100,
                exit_code=2,
                failure="xcodebuild did not produce the required xcresult bundle",
                input_snapshot_before=before,
                input_snapshot_after=before,
            )
        self.assertEqual(document["execution"]["result"], "infrastructure")
        self.assertEqual(document["products"]["xcresult"], {"state": "absent"})
        with self.assertRaisesRegex(receipt.InstalledMatrixReceiptError, "not a passing"):
            self._validate(document)

    def test_input_snapshot_mutation_cannot_be_sealed_as_one_execution(self) -> None:
        before = receipt.capture_input_snapshot(
            candidate_identity_path=self.candidate_path,
            preparation_receipt_path=self.preparation_path,
            installed_app=self.installed_app,
            prepared_xctestrun=self.xctestrun,
            execution_xctestrun=self.execution_xctestrun,
            test_bundle=self.test_bundle,
            ui_runner=self.ui_runner,
            xcodebuild=self.developer_dir / "usr/bin/xcodebuild",
        )
        after = copy.deepcopy(before)
        after["xcodebuild"]["inode"] += 1
        with self.assertRaisesRegex(receipt.InstalledMatrixReceiptError, "changed during execution"):
            receipt.assert_input_snapshot_equal(before, after)

    def test_descriptor_read_refuses_in_place_xcodebuild_mutation(self) -> None:
        tool = self.developer_dir / "usr/bin/xcodebuild"
        original_read = receipt.os.read
        changed = False

        def read_and_mutate(descriptor: int, size: int) -> bytes:
            nonlocal changed
            block = original_read(descriptor, size)
            if block and not changed:
                changed = True
                tool.write_bytes(b"X" * len(tool.read_bytes()))
            return block

        with mock.patch.object(receipt.os, "read", side_effect=read_and_mutate):
            with self.assertRaisesRegex(receipt.InstalledMatrixReceiptError, "changed while it was read"):
                receipt.file_sha256(tool)

    def test_descriptor_read_refuses_in_place_xctestrun_and_preparation_mutation(self) -> None:
        original_read = receipt.os.read
        for path in (self.xctestrun, self.preparation_path):
            changed = False

            def read_and_mutate(descriptor: int, size: int, *, target: Path = path) -> bytes:
                nonlocal changed
                block = original_read(descriptor, size)
                if block and not changed:
                    changed = True
                    target.write_bytes(b"Y" * len(target.read_bytes()))
                return block

            with self.subTest(path=path), mock.patch.object(
                receipt.os, "read", side_effect=read_and_mutate
            ):
                with self.assertRaisesRegex(receipt.InstalledMatrixReceiptError, "changed while it was read"):
                    receipt._file_descriptor_identity(path)

    def test_report_derives_all_incremental_fields_from_the_sealed_receipt(self) -> None:
        document = self._create()
        receipt.write_create_only(self.receipt_path, document)
        evidence = {
            "gate": "incremental-xcuitest",
            "proofArtifacts": [
                {
                    "kind": receipt.PROOF_ARTIFACT_KIND,
                    "path": str(self.receipt_path),
                    "sha256": receipt.file_sha256(self.receipt_path),
                },
                {"kind": "xcresult", "path": str(self.xcresult)},
            ],
        }
        with (
            mock.patch.object(receipt, "_preparation", return_value=self._preparation()),
            mock.patch.object(report, "xcresult_test_summary", return_value=self._summary()),
            mock.patch.object(report, "xcresult_test_nodes", return_value=self._test_tree()),
            mock.patch.object(
                receipt,
                "validate_receipt",
                wraps=receipt.validate_receipt,
            ) as validate_receipt,
        ):
            normalized = report.normalize_input_evidence(
                [evidence],
                expected_source_commit="1" * 40,
                expected_source_tree="2" * 40,
                expected_installed_executable_sha256=document["products"]["installed_app"]["executable_sha256"],
                candidate_identity_path=self.candidate_path,
                installed_app=self.installed_app,
            )
        validate_receipt.assert_called_once()
        self.assertEqual(normalized[0]["sourceTree"], "2" * 40)
        self.assertEqual(normalized[0]["executedTestCount"], 22)
        self.assertEqual(normalized[0]["skippedTestCount"], 0)

    def test_gatef_rejects_receipt_swap_after_proof_artifact_hash(self) -> None:
        document = self._create()
        receipt.write_create_only(self.receipt_path, document)
        sealed_hash = receipt.file_sha256(self.receipt_path)
        swapped = copy.deepcopy(document)
        swapped["execution"]["started_at_unix_ms"] = 1001
        swapped["execution"]["ended_at_unix_ms"] = 1401
        swapped["execution"]["duration_ms"] = 400
        evidence = {
            "gate": "incremental-xcuitest",
            "proofArtifacts": [
                {
                    "kind": receipt.PROOF_ARTIFACT_KIND,
                    "path": str(self.receipt_path),
                    "sha256": sealed_hash,
                },
                {"kind": "xcresult", "path": str(self.xcresult)},
            ],
        }
        original_normalize = report.normalize_proof_artifacts

        def normalize_then_swap(*args: object, **kwargs: object) -> list[dict[str, object]]:
            artifacts = original_normalize(*args, **kwargs)
            self.receipt_path.write_bytes(canonical_bytes(swapped))
            return artifacts

        with (
            mock.patch.object(receipt, "_preparation", return_value=self._preparation()),
            mock.patch.object(report, "normalize_proof_artifacts", side_effect=normalize_then_swap),
            self.assertRaisesRegex(report.ReportError, "receipt bytes differ"),
        ):
            report.normalize_input_evidence(
                [evidence],
                expected_source_commit="1" * 40,
                expected_source_tree="2" * 40,
                expected_installed_executable_sha256=document["products"]["installed_app"]["executable_sha256"],
                candidate_identity_path=self.candidate_path,
                installed_app=self.installed_app,
            )

    def test_receipt_loader_rejects_terminal_and_ancestor_symlinks(self) -> None:
        document = self._create()
        receipt.write_create_only(self.receipt_path, document)
        terminal_alias = self.root / "receipt-terminal-alias.json"
        terminal_alias.symlink_to(self.receipt_path)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError, "non-symlink regular file"
        ):
            receipt.load_receipt_with_sha256(terminal_alias)
        ancestor_alias = self.root.parent / f"{self.root.name}-alias"
        ancestor_alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(
            receipt.InstalledMatrixReceiptError, "symlinked ancestors"
        ):
            receipt.load_receipt_with_sha256(ancestor_alias / self.receipt_path.name)
        loaded, digest = receipt.load_receipt_with_sha256(self.receipt_path)
        self.assertEqual(loaded["receipt_kind"], receipt.RECEIPT_KIND)
        self.assertEqual(digest, receipt.file_sha256(self.receipt_path))

    def test_selector_catalog_rejects_noncanonical_required_identifiers(self) -> None:
        source = json.loads(report.INSTALLED_SELECTOR_CATALOG.read_text(encoding="utf-8"))
        for required, label in (
            ([" reconstruction.cancel"], "leading whitespace"),
            (["reconstruction.cancel "], "trailing whitespace"),
            (["reconstruction.cancel", "reconstruction.cancel"], "duplicate"),
            (["reconstruction/cancel"], "grammar"),
        ):
            with self.subTest(label=label):
                altered = copy.deepcopy(source)
                altered["installedVectors"][0]["requiredIdentifiers"] = required
                path = self.root / f"catalog-{label.replace(' ', '-')}.json"
                path.write_text(json.dumps(altered), encoding="utf-8")
                with self.assertRaisesRegex(report.ReportError, "requiredIdentifiers"):
                    report.load_installed_selector_catalog(path)

    def _summary(self) -> dict[str, object]:
        return {
            "expectedFailures": 0,
            "failedTests": 0,
            "passedTests": 22,
            "result": "Passed",
            "skippedTests": 0,
            "title": "Test - MacScopeInstalledAppUITests",
            "totalTestCount": 22,
        }

    def _test_tree(self) -> dict[str, object]:
        cases = []
        for identifier in self.selectors:
            method = identifier.rsplit("/", 1)[-1]
            cases.append(
                {
                    "children": [
                        {
                            "children": [],
                            "name": method,
                            "nodeType": "Test Case Run",
                            "result": "Passed",
                        }
                    ],
                    "name": method,
                    "nodeIdentifier": identifier,
                    "nodeType": "Test Case",
                    "result": "Passed",
                }
            )
        return {
            "testNodes": [
                {
                    "children": [
                        {
                            "children": [
                                {
                                    "children": cases,
                                    "name": report.INSTALLED_UI_TEST_SUITE,
                                    "nodeType": "Test Suite",
                                    "result": "Passed",
                                }
                            ],
                            "name": report.INSTALLED_UI_TEST_TARGET,
                            "nodeType": "UI test bundle",
                            "result": "Passed",
                        }
                    ],
                    "name": report.INSTALLED_UI_TEST_TARGET,
                    "nodeType": "Test Plan",
                    "result": "Passed",
                }
            ]
        }


if __name__ == "__main__":
    unittest.main()
