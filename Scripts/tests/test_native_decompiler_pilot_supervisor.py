from __future__ import annotations

import copy
import json
import pathlib
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE = ROOT / "Tools" / "DecompilerCoreProof"
PILOT = ROOT / "Tools" / "NativeDecompilerPilot"
sys.path[:0] = [str(PILOT), str(CORE), str(ROOT / "Scripts" / "tests")]

from macscope_decompiler_proof.canonical import canonical_json_bytes, canonical_sha256
from macscope_native_decompiler_pilot.carrier import build_macho_carrier
from macscope_native_decompiler_pilot.normalize import build_result
from native_decompiler_pilot_fixtures import FIXTURE_PATH, fixture_provider_output, fixture_request


class NativeDecompilerPilotSupervisorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.supervisor = ROOT / "Scripts" / "native-decompiler-pilot" / "run_dcp03b3_native_pilot.py"
        cls.request = fixture_request()
        cls.valid_result = build_result(
            request=cls.request,
            carrier=build_macho_carrier(cls.request),
            output=fixture_provider_output(),
        )

    @staticmethod
    def fake_python(
        root: pathlib.Path,
        *,
        stdout: bytes,
        stderr: bytes = b"",
        exit_code: int = 0,
        delay_seconds: float = 0.0,
        descendant_marker: pathlib.Path | None = None,
    ) -> pathlib.Path:
        stdout_path = root / "child.stdout"
        stderr_path = root / "child.stderr"
        stdout_path.write_bytes(stdout)
        stderr_path.write_bytes(stderr)
        script = root / "fake-python"
        descendant = ""
        if descendant_marker is not None:
            descendant = (
                "import subprocess\n"
                "subprocess.Popen([sys.executable, '-c', "
                + repr(
                    "import pathlib,time;time.sleep(0.8);"
                    f"pathlib.Path({str(descendant_marker)!r}).write_text('orphan', encoding='utf-8')"
                )
                + "])\n"
            )
        script.write_text(
            "#!/usr/bin/env python3\n"
            "import pathlib, sys, time\n"
            + descendant
            + f"time.sleep({delay_seconds!r})\n"
            + f"sys.stdout.buffer.write(pathlib.Path({str(stdout_path)!r}).read_bytes())\n"
            + f"sys.stderr.buffer.write(pathlib.Path({str(stderr_path)!r}).read_bytes())\n"
            + f"raise SystemExit({exit_code})\n",
            encoding="utf-8",
        )
        script.chmod(0o755)
        return script

    @staticmethod
    def materialization(root: pathlib.Path) -> pathlib.Path:
        path = root / "MATERIALIZATION.json"
        path.write_text("{}\n", encoding="utf-8")
        return path

    def invoke(
        self,
        root: pathlib.Path,
        fake_python: pathlib.Path,
        *,
        output: pathlib.Path | None = None,
        cancel: pathlib.Path | None = None,
        materialization: pathlib.Path | None = None,
        input_path: pathlib.Path = FIXTURE_PATH,
    ) -> subprocess.CompletedProcess[bytes]:
        output = output or root / "result.json"
        materialization = materialization or self.materialization(root)
        command = [
            sys.executable,
            str(self.supervisor),
            "--python",
            str(fake_python),
            "--materialization",
            str(materialization),
            "--input",
            str(input_path),
            "--output",
            str(output),
        ]
        if cancel is not None:
            command.extend(("--cancel-file", str(cancel)))
        return subprocess.run(command, cwd=ROOT, check=False, capture_output=True)

    def _forged(self, mutate) -> bytes:
        value = copy.deepcopy(self.valid_result)
        mutate(value)
        value["contentHash"] = canonical_sha256({k: v for k, v in value.items() if k != "contentHash"})
        return canonical_json_bytes(value)

    def test_valid_child_result_is_validated_and_atomically_published(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            payload = canonical_json_bytes(self.valid_result)
            fake = self.fake_python(root, stdout=payload)
            output = root / "result.json"
            completed = self.invoke(root, fake, output=output)
            self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
            self.assertEqual(completed.stderr, b"")
            self.assertEqual(output.read_bytes(), payload)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o644)

    def test_preexisting_cancellation_fails_before_child_publication(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            cancel = root / "cancel"
            cancel.write_text("cancel", encoding="utf-8")
            fake = self.fake_python(root, stdout=canonical_json_bytes(self.valid_result))
            output = root / "result.json"
            completed = self.invoke(root, fake, output=output, cancel=cancel)
            self.assertEqual(completed.returncode, 6)
            self.assertFalse(output.exists())
            self.assertEqual(json.loads(completed.stderr)["error"]["code"], "analysis.cancelled")

    def test_inflight_cancellation_terminates_the_child_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            cancel = root / "cancel"
            descendant_marker = root / "orphan-marker"
            fake = self.fake_python(
                root,
                stdout=canonical_json_bytes(self.valid_result),
                delay_seconds=30.0,
                descendant_marker=descendant_marker,
            )
            output = root / "result.json"
            timer = threading.Timer(0.25, cancel.write_text, args=("cancel",), kwargs={"encoding": "utf-8"})
            started = time.monotonic()
            timer.start()
            try:
                completed = self.invoke(root, fake, output=output, cancel=cancel)
            finally:
                timer.cancel()
            elapsed = time.monotonic() - started
            self.assertEqual(completed.returncode, 6, completed.stderr.decode(errors="replace"))
            self.assertLess(elapsed, 5.0)
            self.assertFalse(output.exists())
            self.assertEqual(json.loads(completed.stderr)["error"]["code"], "analysis.cancelled")
            time.sleep(1.0)
            self.assertFalse(descendant_marker.exists(), "a supervised descendant survived cancellation")

    def test_forged_instruction_bytes_are_rejected_even_with_valid_content_hash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            payload = self._forged(
                lambda value: value["backendRecords"]["instructions"][0].update(effectiveBytesHex="00000000")
            )
            fake = self.fake_python(root, stdout=payload)
            output = root / "result.json"
            completed = self.invoke(root, fake, output=output)
            self.assertEqual(completed.returncode, 70)
            self.assertFalse(output.exists())
            error = json.loads(completed.stderr)
            self.assertEqual(error["error"]["code"], "child.invalid_output")
            self.assertIn("semantic validation", error["error"]["message"])

    def test_forged_instruction_source_hash_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            payload = self._forged(
                lambda value: value["backendRecords"]["instructions"][0].update(effectiveSourceSha256="0" * 64)
            )
            fake = self.fake_python(root, stdout=payload)
            output = root / "result.json"
            completed = self.invoke(root, fake, output=output)
            self.assertEqual(completed.returncode, 70)
            self.assertFalse(output.exists())

    def test_forged_function_record_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            payload = self._forged(
                lambda value: value["backendRecords"]["function"].update(size=24)
            )
            fake = self.fake_python(root, stdout=payload)
            output = root / "result.json"
            completed = self.invoke(root, fake, output=output)
            self.assertEqual(completed.returncode, 70)
            self.assertFalse(output.exists())

    def test_noncanonical_child_result_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            payload = json.dumps(self.valid_result, indent=2).encode("utf-8")
            fake = self.fake_python(root, stdout=payload)
            output = root / "result.json"
            completed = self.invoke(root, fake, output=output)
            self.assertEqual(completed.returncode, 70)
            self.assertFalse(output.exists())
            self.assertIn(b"not canonical JSON", completed.stderr)

    def test_success_with_stderr_is_rejected_without_leaking_native_text(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fake = self.fake_python(
                root,
                stdout=canonical_json_bytes(self.valid_result),
                stderr=b"native failure at /secret/path\n",
            )
            output = root / "result.json"
            completed = self.invoke(root, fake, output=output)
            self.assertEqual(completed.returncode, 70)
            self.assertFalse(output.exists())
            self.assertNotIn(b"/secret/path", completed.stderr)
            self.assertIn(b"unexpected diagnostics", completed.stderr)

    def test_invalid_child_error_is_replaced_with_bounded_supervisor_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fake = self.fake_python(
                root,
                stdout=b"",
                stderr=b"segmentation fault at /secret/path\n",
                exit_code=139,
            )
            output = root / "result.json"
            completed = self.invoke(root, fake, output=output)
            self.assertEqual(completed.returncode, 70)
            self.assertFalse(output.exists())
            self.assertNotIn(b"/secret/path", completed.stderr)
            self.assertEqual(json.loads(completed.stderr)["error"]["code"], "child.failed")

    def test_input_output_alias_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fake = self.fake_python(root, stdout=canonical_json_bytes(self.valid_result))
            completed = self.invoke(root, fake, output=FIXTURE_PATH)
            self.assertEqual(completed.returncode, 2)
            self.assertEqual(json.loads(completed.stderr)["error"]["code"], "supervisor.invalid_configuration")

    def test_output_directory_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            real = root / "real"
            real.mkdir()
            link = root / "link"
            link.symlink_to(real, target_is_directory=True)
            fake = self.fake_python(root, stdout=canonical_json_bytes(self.valid_result))
            completed = self.invoke(root, fake, output=link / "result.json")
            self.assertEqual(completed.returncode, 7)
            self.assertFalse((real / "result.json").exists())

    def test_unknown_success_property_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            payload = self._forged(lambda value: value.update(unapproved=True))
            fake = self.fake_python(root, stdout=payload)
            completed = self.invoke(root, fake)
            self.assertEqual(completed.returncode, 70)


if __name__ == "__main__":
    unittest.main()
