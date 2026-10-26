#!/usr/bin/env python3

from __future__ import annotations

import copy
import hashlib
import io
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import zlib

from Scripts.reconstruction import emit_installed_accessibility_report as emitter
from Scripts.reconstruction_gate_f.canonical_json import (
    canonical_bytes,
    canonical_sha256,
    load_canonical_json,
)


QUALIFICATION_RUN_ID = "task11-installed-accessibility"
QUALIFICATION_RUN_NONCE = "c" * 64
PREDECESSOR_OBSERVATIONS_SHA256 = "d" * 64


class InstalledAccessibilityReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.candidate = self._file("candidate.json", b"{}")
        self.matrix_path = self._file("matrix.json", b"{}")
        self.installed_app = self._directory("Applications/MacScope.app")
        self.xcresult = self._directory("Results/Installed.xcresult")
        self.candidate_sha256 = "a" * 64
        self.receipt_sha256 = "b" * 64
        self.xcresult_bundle_sha256 = "c" * 64
        self.xcresult_closed_tree_sha256 = "d" * 64
        self.catalog = emitter._catalog_projection()
        self.observed_projection = [
            {
                "observed_identifiers": sorted(item["required_identifiers"]),
                "test_identifier": item["test_identifier"],
                "vector_id": item["vector_id"],
            }
            for item in self.catalog
        ]
        self.attachments: list[dict[str, object]] = []
        for index, (
            presentation_state,
            appearance,
            window_size,
            width,
            height,
        ) in enumerate(emitter.EXPECTED_VARIANTS):
            payload = self._png(width, height, marker=index)
            path = self._file(
                f"source-{presentation_state}-{appearance}-{window_size}.png",
                payload,
            )
            self.attachments.append(
                {
                    "appearance": appearance,
                    "attachment_path": str(path),
                    "pixel_height": height,
                    "pixel_width": width,
                    "presentation_state": presentation_state,
                    "scenario": "taskEvidenceCountsAccessible",
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "test_identifier": emitter.matrix.PRESENTATION_TEST_IDENTIFIER,
                    "window_size": window_size,
                }
            )
        self.receipt = {
            "candidate": {"identity_sha256": self.candidate_sha256},
            "execution": {
                "selector_projection": self.catalog,
                "selector_projection_sha256": canonical_sha256(self.catalog),
            },
            "accessibility_observations": {
                "observed_selector_projection": self.observed_projection,
                "observed_selector_projection_sha256": canonical_sha256(
                    self.observed_projection
                ),
            },
            "presentation_screenshots": {"attachments": self.attachments},
            "products": {
                "installed_app": {"path": str(self.installed_app)},
                "xcresult": {
                    "closed_tree_sha256": self.xcresult_closed_tree_sha256,
                    "path": str(self.xcresult),
                },
            },
        }
        identifiers = [item["test_identifier"] for item in self.catalog]
        self.semantic = {
            "candidate_identity_sha256": self.candidate_sha256,
            "executed_selector_count": 22,
            "expected_selector_count": 22,
            "failed_selector_count": 0,
            "passed_selector_count": 22,
            "result": "passed",
            "schema_version": 3,
            "selector_catalog_sha256": canonical_sha256(identifiers),
            "selector_projection": self.catalog,
            "selector_projection_sha256": canonical_sha256(self.catalog),
            "observed_selector_projection": self.observed_projection,
            "observed_selector_projection_sha256": canonical_sha256(
                self.observed_projection
            ),
            "selectors": [
                {"status": "passed", "test_identifier": identifier}
                for identifier in identifiers
            ],
            "skipped_selector_count": 0,
            "source_xcresult": {
                "bundle_sha256": self.xcresult_bundle_sha256,
                "closed_tree_sha256": self.xcresult_closed_tree_sha256,
            },
        }
        self.semantic_path = self._file("semantic.json", canonical_bytes(self.semantic))
        self.artifact_root = self.root / "projection"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _file(self, relative: str, payload: bytes) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        return path

    def _directory(self, relative: str) -> Path:
        path = self.root / relative
        path.mkdir(parents=True, exist_ok=True)
        return path

    @staticmethod
    def _png(width: int, height: int, marker: int) -> bytes:
        def chunk(kind: bytes, payload: bytes) -> bytes:
            return (
                len(payload).to_bytes(4, "big")
                + kind
                + payload
                + zlib.crc32(kind + payload).to_bytes(4, "big")
            )

        pixel = bytes((marker % 256, (marker * 17) % 256, (marker * 31) % 256))
        rows = b"".join(
            b"\x00" + pixel + b"\x00\x00\x00" * (width - 1)
            for _ in range(height)
        )
        return (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows))
            + chunk(b"IEND", b"")
        )

    def arguments(self, artifact_root: Path | None = None) -> list[str]:
        return [
            "--candidate-identity",
            str(self.candidate),
            "--matrix-receipt",
            str(self.matrix_path),
            "--xcresult-semantic-manifest",
            str(self.semantic_path),
            "--artifact-root",
            str(artifact_root or self.artifact_root),
            "--qualification-run-id",
            QUALIFICATION_RUN_ID,
            "--qualification-run-nonce",
            QUALIFICATION_RUN_NONCE,
            "--predecessor-observations-sha256",
            PREDECESSOR_OBSERVATIONS_SHA256,
        ]

    def _run(self, artifact_root: Path | None = None) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(
                emitter.matrix,
                "load_receipt_with_sha256",
                return_value=(self.receipt, self.receipt_sha256),
            ),
            mock.patch.object(
                emitter.matrix,
                "validate_receipt",
                return_value=self.receipt_sha256,
            ) as validate_receipt,
            mock.patch.object(
                emitter,
                "result_bundle_sha256",
                return_value=self.xcresult_bundle_sha256,
            ),
            mock.patch.object(emitter.time, "time", side_effect=(1.0, 1.25)),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            result = emitter.main(self.arguments(artifact_root))
        self.assertEqual(
            validate_receipt.call_args.kwargs["installed_app"], self.installed_app
        )
        return result, stdout.getvalue(), stderr.getvalue()

    def test_projects_one_completed_matrix_into_a_closed_create_only_artifact_set(self) -> None:
        result, stdout, stderr = self._run()
        self.assertEqual(result, 0, stderr)
        expected_names = {
            emitter.ACCESSIBILITY_REPORT_NAME,
            emitter.PRESENTATION_MANIFEST_NAME,
            emitter.EXECUTION_REPORT_NAME,
            *emitter.SCREENSHOT_NAMES.values(),
        }
        self.assertEqual({path.name for path in self.artifact_root.iterdir()}, expected_names)
        expected_stdout = [
            f"MACSCOPE_INSTALLED_ACCESSIBILITY_REPORT={self.artifact_root / emitter.ACCESSIBILITY_REPORT_NAME}",
            f"MACSCOPE_INSTALLED_ACCESSIBILITY_PRESENTATION_MANIFEST={self.artifact_root / emitter.PRESENTATION_MANIFEST_NAME}",
            f"MACSCOPE_INSTALLED_ACCESSIBILITY_EXECUTION_REPORT={self.artifact_root / emitter.EXECUTION_REPORT_NAME}",
            *[
                "MACSCOPE_INSTALLED_ACCESSIBILITY_SCREENSHOT_"
                + "_".join(
                    part.upper().replace("-", "_")
                    for part in (presentation_state, appearance, window_size)
                )
                + "="
                + str(
                    self.artifact_root
                    / emitter.SCREENSHOT_NAMES[
                        (presentation_state, appearance, window_size)
                    ]
                )
                for presentation_state, appearance, window_size, _width, _height
                in emitter.EXPECTED_VARIANTS
            ],
        ]
        self.assertEqual(stdout.splitlines(), expected_stdout)

        accessibility = load_canonical_json(
            self.artifact_root / emitter.ACCESSIBILITY_REPORT_NAME
        )
        self.assertEqual(accessibility["counts"], {
            "executed": 22,
            "expected": 22,
            "failed": 0,
            "passed": 22,
            "skipped": 0,
        })
        self.assertEqual(len(accessibility["selectors"]), 22)
        self.assertTrue(
            all(item["required_identifiers"] for item in accessibility["selectors"])
        )
        self.assertTrue(
            all(
                item["observed_identifiers"] == sorted(item["required_identifiers"])
                for item in accessibility["selectors"]
            )
        )
        self.assertEqual(
            accessibility["selector_projection_sha256"], canonical_sha256(self.catalog)
        )
        presentation = load_canonical_json(
            self.artifact_root / emitter.PRESENTATION_MANIFEST_NAME
        )
        self.assertEqual(
            presentation["schema_version"],
            emitter.PRESENTATION_MANIFEST_SCHEMA_VERSION,
        )
        self.assertEqual(len(presentation["screenshots"]), 28)
        self.assertEqual(
            len({item["sha256"] for item in presentation["screenshots"]}),
            28,
        )
        self.assertEqual(
            {
                (
                    item["presentation_state"],
                    item["appearance"],
                    item["window_size"],
                )
                for item in presentation["screenshots"]
            },
            {
                (presentation_state, appearance, window_size)
                for presentation_state, appearance, window_size, _width, _height
                in emitter.EXPECTED_VARIANTS
            },
        )
        execution = load_canonical_json(
            self.artifact_root / emitter.EXECUTION_REPORT_NAME
        )
        self.assertEqual(
            execution,
            {
                "ended_at_unix_ms": 1_250,
                "exit_code": 0,
                "predecessor_observations_sha256": PREDECESSOR_OBSERVATIONS_SHA256,
                "qualification_run": {
                    "nonce": QUALIFICATION_RUN_NONCE,
                    "run_id": QUALIFICATION_RUN_ID,
                },
                "result": "passed",
                "schema_version": 2,
                "started_at_unix_ms": 1_000,
                "stress": None,
            },
        )
        for source in self.attachments:
            variant = (
                source["presentation_state"],
                source["appearance"],
                source["window_size"],
            )
            copied = self.artifact_root / emitter.SCREENSHOT_NAMES[variant]
            self.assertEqual(copied.read_bytes(), Path(source["attachment_path"]).read_bytes())

    def test_semantic_manifest_rejects_count_status_selector_and_candidate_drift(self) -> None:
        for field, value in (
            ("passed_selector_count", 21),
            ("failed_selector_count", 1),
            ("skipped_selector_count", 1),
            ("candidate_identity_sha256", "f" * 64),
            ("result", "failed"),
        ):
            with self.subTest(field=field):
                altered = dict(self.semantic)
                altered[field] = value
                with self.assertRaisesRegex(
                    emitter.InstalledAccessibilityReportError,
                    "exactly execute and pass",
                ):
                    emitter.validate_semantic_manifest(
                        altered,
                        candidate_identity_sha256=self.candidate_sha256,
                        receipt=self.receipt,
                        catalog=self.catalog,
                        xcresult_bundle_sha256=self.xcresult_bundle_sha256,
                    )
        altered = dict(self.semantic)
        altered["selectors"] = list(self.semantic["selectors"][:-1])
        with self.assertRaisesRegex(
            emitter.InstalledAccessibilityReportError, "exactly execute and pass"
        ):
            emitter.validate_semantic_manifest(
                altered,
                candidate_identity_sha256=self.candidate_sha256,
                receipt=self.receipt,
                catalog=self.catalog,
                xcresult_bundle_sha256=self.xcresult_bundle_sha256,
            )

    def test_catalog_projection_preserves_exact_required_identifiers(self) -> None:
        projection = emitter._catalog_projection()
        self.assertEqual(len(projection), 22)
        self.assertEqual(
            [item["vector_id"] for item in projection],
            sorted(item["vector_id"] for item in projection),
        )
        self.assertEqual(
            next(
                item for item in projection
                if item["vector_id"] == "xcui.keyboardAndMenuEquivalence"
            )["required_identifiers"],
            [
                "reconstruction.primaryAction",
                "reconstruction.pause",
                "reconstruction.resume",
                "reconstruction.cancel",
            ],
        )

    def test_required_identifiers_only_drift_cannot_mint_accessibility_claims(self) -> None:
        altered_receipt = copy.deepcopy(self.receipt)
        altered_semantic = copy.deepcopy(self.semantic)
        for container in (
            altered_receipt["execution"]["selector_projection"],
            altered_semantic["selector_projection"],
        ):
            container[0]["required_identifiers"] = ["reconstruction.result"]
        drifted_projection = altered_semantic["selector_projection"]
        drifted_digest = canonical_sha256(drifted_projection)
        altered_receipt["execution"]["selector_projection_sha256"] = drifted_digest
        altered_semantic["selector_projection_sha256"] = drifted_digest
        with self.assertRaisesRegex(
            emitter.InstalledAccessibilityReportError, "exactly execute and pass"
        ):
            emitter.validate_semantic_manifest(
                altered_semantic,
                candidate_identity_sha256=self.candidate_sha256,
                receipt=altered_receipt,
                catalog=self.catalog,
                xcresult_bundle_sha256=self.xcresult_bundle_sha256,
            )

    def test_missing_observed_identifier_cannot_mint_accessibility_claims(self) -> None:
        altered_receipt = copy.deepcopy(self.receipt)
        altered_semantic = copy.deepcopy(self.semantic)
        altered_receipt["accessibility_observations"][
            "observed_selector_projection"
        ][0]["observed_identifiers"].pop()
        altered_semantic["observed_selector_projection"][0][
            "observed_identifiers"
        ].pop()
        for document in (
            altered_receipt["accessibility_observations"],
            altered_semantic,
        ):
            document["observed_selector_projection_sha256"] = canonical_sha256(
                document["observed_selector_projection"]
            )
        with self.assertRaisesRegex(
            emitter.InstalledAccessibilityReportError, "exactly execute and pass"
        ):
            emitter.validate_semantic_manifest(
                altered_semantic,
                candidate_identity_sha256=self.candidate_sha256,
                receipt=altered_receipt,
                catalog=self.catalog,
                xcresult_bundle_sha256=self.xcresult_bundle_sha256,
            )

    def test_truncated_and_corrupt_pngs_are_not_projected(self) -> None:
        source = Path(self.attachments[0]["attachment_path"])
        original = source.read_bytes()
        for label, mutated in (
            ("truncated", original[:-12]),
            ("corrupt", original[:29] + bytes([original[29] ^ 1]) + original[30:]),
        ):
            with self.subTest(label=label):
                source.write_bytes(mutated)
                self.attachments[0]["sha256"] = hashlib.sha256(mutated).hexdigest()
                result, _stdout, stderr = self._run(self.root / f"projection-{label}")
                self.assertEqual(result, 2)
                self.assertIn("presentation PNG", stderr)
                source.write_bytes(original)
                self.attachments[0]["sha256"] = hashlib.sha256(original).hexdigest()

    def test_inputs_and_artifact_root_reject_symlinked_ancestors(self) -> None:
        physical = self._directory("physical-inputs")
        physical_file = physical / "candidate.json"
        physical_file.write_bytes(b"{}")
        alias = self.root / "input-alias"
        alias.symlink_to(physical, target_is_directory=True)
        with self.assertRaisesRegex(
            emitter.InstalledAccessibilityReportError, "symlinked ancestors"
        ):
            emitter._canonical_regular_file(alias / physical_file.name, "candidate identity")

        physical_output_parent = self._directory("physical-output")
        output_alias = self.root / "output-alias"
        output_alias.symlink_to(physical_output_parent, target_is_directory=True)
        result, _stdout, stderr = self._run(output_alias / "projection")
        self.assertEqual(result, 2)
        self.assertIn("symlinked ancestors", stderr)

    def test_existing_artifact_root_and_changed_screenshot_fail_closed(self) -> None:
        self.artifact_root.mkdir()
        result, _stdout, stderr = self._run()
        self.assertEqual(result, 2)
        self.assertIn("absent absolute path", stderr)

        second_root = self.root / "projection-2"
        Path(self.attachments[0]["attachment_path"]).write_bytes(
            self._png(1_080, 680, marker=99)
        )
        result, _stdout, stderr = self._run(second_root)
        self.assertEqual(result, 2)
        self.assertIn("changed after receipt validation", stderr)

    def test_cli_has_only_the_seven_authoritative_inputs(self) -> None:
        parsed = emitter.parse_arguments(self.arguments())
        self.assertEqual(
            set(vars(parsed)),
            {
                "candidate_identity",
                "matrix_receipt",
                "xcresult_semantic_manifest",
                "artifact_root",
                "qualification_run_id",
                "qualification_run_nonce",
                "predecessor_observations_sha256",
            },
        )
        source = Path(emitter.__file__).read_text(encoding="utf-8")
        self.assertNotIn("xcodebuild", source)
        self.assertNotIn("XCUIApplication", source)
        self.assertNotIn("subprocess", source)


if __name__ == "__main__":
    unittest.main()
