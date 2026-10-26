#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import time
import types
import unittest
from unittest import mock

from Scripts.reconstruction import run_ws24_installed_live_gates as runner
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes


class WS24InstalledLiveGateRunnerTests(unittest.TestCase):
    source_commit = "a" * 40
    source_tree = "b" * 40
    installed_digest = "c" * 64

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name).resolve()
        self.authority = types.SimpleNamespace(
            source_commit=self.source_commit,
            source_tree=self.source_tree,
            installed_executable_sha256=self.installed_digest,
            exposed_at_unix_ns=1_000_000_000,
            developer_directory=Path(
                "/Applications/Xcode-beta.app/Contents/Developer"
            ),
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def frozen_arguments(self, *, timeout: str | None = "1800") -> list[str]:
        values = [
            "--candidate-identity",
            str(self.root / "candidate.json"),
            "--source-app",
            str(self.root / "source.app"),
            "--installed-app",
            "/Applications/MacScope.app",
            "--installation-pending-state",
            str(self.root / "pending" / "transaction.json"),
            "--preparation-receipt",
            str(self.root / "NativeLivePreparation.receipt.json"),
            "--qualification-run-id",
            "run-1",
            "--qualification-run-nonce",
            "d" * 64,
            "--output-root",
            str(self.root / "installed-live-gates"),
        ]
        if timeout is not None:
            values.extend(("--timeout-seconds", timeout))
        return values

    def attempt(
        self,
        *,
        index: int,
        scenario: str,
        seed: int | None,
        peak: int | None,
    ) -> dict[str, object]:
        return {
            "attemptIndex": index,
            "endedAtUnixMilliseconds": 2_000 + index,
            "exitCode": 0,
            "failure": None,
            "peakResidentMemoryMegabytes": peak,
            "scenario": scenario,
            "seed": seed,
            "startedAtUnixMilliseconds": 2_000,
            "timedOut": False,
        }

    def report(self, spec: runner.GateSpec) -> dict[str, object]:
        if spec.gate in {
            "installed-launch-smoke",
            "direct-debugger-transport-contracts",
        }:
            attempts = [
                self.attempt(index=1, scenario=spec.gate, seed=None, peak=None)
            ]
        elif spec.gate in runner.STRESS_GATES:
            attempts = [
                self.attempt(
                    index=index,
                    scenario=spec.gate,
                    seed=runner.deterministic_seed(
                        self.authority,
                        report_gate=spec.gate,
                        scenario=spec.gate,
                        attempt_index=index,
                    ),
                    peak=None,
                )
                for index in range(1, 11)
            ]
        else:
            attempts = [
                self.attempt(
                    index=index,
                    scenario=scenario,
                    seed=runner.deterministic_seed(
                        self.authority,
                        report_gate=spec.gate,
                        scenario=scenario,
                        attempt_index=index,
                    ),
                    peak=128,
                )
                for scenario in (
                    "repeated-launch-detach-stress",
                    "repeated-attach-detach-stress",
                    "repeated-restart-stress",
                )
                for index in range(1, 11)
            ]
        return {
            "attempts": attempts,
            "gate": spec.gate,
            "installedExecutableSHA256": self.installed_digest,
            "schemaVersion": 1,
            "sourceCommit": self.source_commit,
            "sourceTree": self.source_tree,
        }

    def release_provenance(self) -> dict[str, object]:
        return {
            "architecture": "arm64",
            "configuration": "Release",
            "deployment_target": "27.0",
            "git_head_commit": self.source_commit,
            "git_head_tree": self.source_tree,
            "qualification_eligible": True,
            "repository_clean": True,
            "schema_version": 1,
        }

    @staticmethod
    def signing_provenance_bytes(document: dict[str, object]) -> bytes:
        return (
            json.dumps(
                document,
                ensure_ascii=True,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")

    def test_frozen_ordered_argv_and_timeout_bounds(self) -> None:
        parsed = runner.parse_arguments(self.frozen_arguments())
        self.assertEqual(parsed.timeout_seconds, 1_800)
        self.assertEqual(parsed.installed_app, Path("/Applications/MacScope.app"))
        self.assertEqual(
            runner.parse_arguments(self.frozen_arguments(timeout=None)).timeout_seconds,
            1_800,
        )
        for invalid in ("0", "3601", "1.5"):
            with self.subTest(invalid=invalid), self.assertRaises(
                runner.LiveGateRunnerError
            ):
                runner.parse_arguments(self.frozen_arguments(timeout=invalid))
        reordered = self.frozen_arguments()
        reordered[0], reordered[2] = reordered[2], reordered[0]
        with self.assertRaises(runner.LiveGateRunnerError):
            runner.parse_arguments(reordered)

    def test_only_exact_applications_bundle_is_accepted(self) -> None:
        arguments = self.frozen_arguments()
        arguments[arguments.index("--installed-app") + 1] = str(
            self.root / "prepared.app"
        )
        with self.assertRaisesRegex(
            runner.LiveGateRunnerError,
            "exactly /Applications/MacScope.app",
        ):
            runner.parse_arguments(arguments)

    def test_seed_is_stable_candidate_and_scenario_bound(self) -> None:
        seed = runner.deterministic_seed(
            self.authority,
            report_gate="repeated-launch-detach-stress",
            scenario="repeated-launch-detach-stress",
            attempt_index=1,
        )
        self.assertEqual(seed, 4_694_912_104_982_801_247)
        self.assertNotEqual(
            seed,
            runner.deterministic_seed(
                self.authority,
                report_gate="performance-gate",
                scenario="repeated-launch-detach-stress",
                attempt_index=1,
            ),
        )

    def test_release_provenance_decoder_accepts_real_signing_policy_format(self) -> None:
        document = self.release_provenance()
        payload = self.signing_provenance_bytes(document)
        self.assertTrue(payload.endswith(b"\n"))
        self.assertFalse(payload.endswith(b"\n\n"))
        self.assertEqual(
            runner.decode_release_provenance_bytes(
                payload,
                expected_sha256=hashlib.sha256(payload).hexdigest(),
            ),
            document,
        )

    def test_release_provenance_decoder_rejects_missing_or_extra_lf(self) -> None:
        payload = self.signing_provenance_bytes(self.release_provenance())
        for malformed in (payload[:-1], payload + b"\n"):
            with self.subTest(malformed=malformed[-2:]), self.assertRaisesRegex(
                runner.LiveGateRunnerError,
                "one trailing LF",
            ):
                runner.decode_release_provenance_bytes(
                    malformed,
                    expected_sha256=hashlib.sha256(malformed).hexdigest(),
                )

    def test_release_provenance_decoder_rejects_noncanonical_encoding(self) -> None:
        document = self.release_provenance()
        payload = (json.dumps(document, indent=2) + "\n").encode("utf-8")
        with self.assertRaisesRegex(
            runner.LiveGateRunnerError,
            "canonical signing-policy JSON encoding",
        ):
            runner.decode_release_provenance_bytes(
                payload,
                expected_sha256=hashlib.sha256(payload).hexdigest(),
            )

    def test_release_provenance_decoder_rejects_pending_digest_mismatch(self) -> None:
        payload = self.signing_provenance_bytes(self.release_provenance())
        with self.assertRaisesRegex(
            runner.LiveGateRunnerError,
            "digest differs from pending authority",
        ):
            runner.decode_release_provenance_bytes(
                payload,
                expected_sha256="0" * 64,
            )

    def test_validator_accepts_only_closed_canonical_candidate_reports(self) -> None:
        for spec in runner.GATES:
            with self.subTest(gate=spec.gate):
                payload = canonical_bytes(self.report(spec))
                self.assertEqual(
                    runner.validate_report_payload(payload, spec, self.authority),
                    payload,
                )
                self.assertFalse(payload.endswith(b"\n"))

        report = self.report(runner.GATES[0])
        report["status"] = "passed"
        with self.assertRaises(runner.LiveGateRunnerError):
            runner.validate_report_payload(
                canonical_bytes(report), runner.GATES[0], self.authority
            )

    def test_validator_rejects_forged_seed_timing_memory_and_pass_fields(self) -> None:
        stress_spec = runner.GATES[2]
        stress = self.report(stress_spec)
        stress["attempts"][0]["seed"] = 7  # type: ignore[index]
        with self.assertRaises(runner.LiveGateRunnerError):
            runner.validate_report_payload(
                canonical_bytes(stress), stress_spec, self.authority
            )

        smoke_spec = runner.GATES[0]
        smoke = self.report(smoke_spec)
        smoke["attempts"][0]["startedAtUnixMilliseconds"] = 999  # type: ignore[index]
        with self.assertRaises(runner.LiveGateRunnerError):
            runner.validate_report_payload(
                canonical_bytes(smoke), smoke_spec, self.authority
            )

        performance_spec = runner.GATES[-1]
        performance = self.report(performance_spec)
        performance["attempts"][0]["peakResidentMemoryMegabytes"] = 2_049  # type: ignore[index]
        with self.assertRaises(runner.LiveGateRunnerError):
            runner.validate_report_payload(
                canonical_bytes(performance), performance_spec, self.authority
            )

        failed = self.report(smoke_spec)
        failed["attempts"][0]["exitCode"] = 1  # type: ignore[index]
        with self.assertRaises(runner.LiveGateRunnerError):
            runner.validate_report_payload(
                canonical_bytes(failed), smoke_spec, self.authority
            )

    def test_internal_argv_targets_only_installed_executable(self) -> None:
        argv = runner.installed_gate_argv(runner.GATES[0], self.authority)
        self.assertEqual(argv[0], "/Applications/MacScope.app/Contents/MacOS/MacScope")
        self.assertEqual(argv[1:3], ["--ws24-installed-live-gate", "installed-launch-smoke"])
        self.assertNotIn("source.app", " ".join(argv))
        self.assertNotIn("prepared.app", " ".join(argv))

    def test_environment_is_closed_and_cannot_inject_runtime_authority(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "HOME": "/tmp/home",
                "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
                "MACSCOPE_FAKE_PASS": "1",
                "HTTPS_PROXY": "http://127.0.0.1:1",
            },
            clear=True,
        ):
            environment = runner._installed_process_environment(self.authority)
        self.assertEqual(environment["HOME"], "/tmp/home")
        self.assertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertNotIn("DYLD_INSERT_LIBRARIES", environment)
        self.assertNotIn("MACSCOPE_FAKE_PASS", environment)
        self.assertNotIn("HTTPS_PROXY", environment)

    def test_publication_is_exact_create_only_private_and_no_lf(self) -> None:
        output_root = self.root / "installed-live-gates"
        reports = [
            (spec, canonical_bytes(self.report(spec))) for spec in runner.GATES
        ]
        runner.publish_reports(
            output_root,
            reports,
            exposed_at_unix_ns=time.time_ns() - 1_000_000_000,
        )
        self.assertEqual(
            sorted(path.name for path in output_root.iterdir()),
            sorted(spec.filename for spec in runner.GATES),
        )
        self.assertEqual(stat.S_IMODE(output_root.stat().st_mode), 0o700)
        for spec, payload in reports:
            path = output_root / spec.filename
            metadata = path.stat()
            self.assertTrue(stat.S_ISREG(metadata.st_mode))
            self.assertEqual(metadata.st_nlink, 1)
            self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
            self.assertEqual(path.read_bytes(), payload)
            self.assertFalse(payload.endswith(b"\n"))
        with self.assertRaises(runner.LiveGateRunnerError):
            runner.publish_reports(
                output_root,
                reports,
                exposed_at_unix_ns=1,
            )

    def test_failure_before_publication_leaves_no_favorable_files(self) -> None:
        arguments = runner.parse_arguments(self.frozen_arguments(timeout="30"))
        with (
            mock.patch.object(runner, "load_authority", return_value=self.authority),
            mock.patch.object(
                runner,
                "run_installed_gate",
                side_effect=runner.LiveGateRunnerError("live failure"),
            ),
        ):
            with self.assertRaises(runner.LiveGateRunnerError):
                runner.run(arguments)
        self.assertFalse(arguments.output_root.exists())


if __name__ == "__main__":
    unittest.main()
