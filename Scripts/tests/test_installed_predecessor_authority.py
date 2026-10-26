from __future__ import annotations

import contextlib
import io
import os
import stat
import tempfile
import unittest
from pathlib import Path

from Scripts.reconstruction import emit_installed_predecessor_authority as producer
from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction_gate_f.canonical_json import decode_canonical_bytes


class InstalledPredecessorAuthorityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.applications = self.root / "Applications"
        self.applications.mkdir()
        self.installed = self.applications / "MacScope.app"
        self.output = self.root / "InstalledPredecessor.authority.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _run(self, output: Path | None = None) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = producer.main(
                [
                    "--installed-app",
                    str(self.installed),
                    "--output",
                    str(output or self.output),
                ],
                _allow_test_destination=True,
            )
        return status, stdout.getvalue(), stderr.getvalue()

    def _make_installed_app(self) -> None:
        executable = self.installed / "Contents" / "MacOS" / "MacScope"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"installed predecessor")
        executable.chmod(0o755)

    def test_absent_destination_publishes_exact_canonical_authority(self) -> None:
        status, stdout, stderr = self._run()

        self.assertEqual(status, 0, stderr)
        expected = installer._predecessor_digest(False, None)
        self.assertEqual(stdout, expected + "\n")
        document = decode_canonical_bytes(self.output.read_bytes())
        self.assertEqual(
            set(document),
            {
                "authority_kind",
                "installed_app_path",
                "observation",
                "predecessor_observations_sha256",
                "schema_version",
            },
        )
        self.assertEqual(document["schema_version"], 1)
        self.assertEqual(document["authority_kind"], producer.AUTHORITY_KIND)
        self.assertEqual(document["installed_app_path"], str(self.installed))
        self.assertEqual(document["observation"], {"identity": None, "present": False})
        self.assertEqual(document["predecessor_observations_sha256"], expected)
        metadata = self.output.lstat()
        self.assertTrue(stat.S_ISREG(metadata.st_mode))
        self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
        self.assertEqual(metadata.st_nlink, 1)

    def test_present_destination_uses_installer_identity_and_digest(self) -> None:
        self._make_installed_app()
        expected = installer.capture_predecessor_observation(self.installed)

        status, stdout, stderr = self._run()

        self.assertEqual(status, 0, stderr)
        self.assertEqual(stdout, expected.sha256 + "\n")
        document = decode_canonical_bytes(self.output.read_bytes())
        self.assertEqual(document["observation"], expected.document)
        self.assertEqual(
            document["predecessor_observations_sha256"], expected.sha256
        )

    def test_output_is_create_only_and_rejects_symlinks(self) -> None:
        self.output.write_bytes(b"preserve")
        status, stdout, stderr = self._run()
        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertIn("output path must be absent", stderr)
        self.assertEqual(self.output.read_bytes(), b"preserve")

        self.output.unlink()
        target = self.root / "target"
        target.write_bytes(b"preserve")
        os.symlink(target, self.output)
        status, stdout, stderr = self._run()
        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertIn("output path must be absent", stderr)
        self.assertEqual(target.read_bytes(), b"preserve")

    def test_public_cli_rejects_nonproduction_destination(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = producer.main(
                [
                    "--installed-app",
                    str(self.installed),
                    "--output",
                    str(self.output),
                ]
            )
        self.assertEqual(status, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("must be exactly /Applications/MacScope.app", stderr.getvalue())
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
