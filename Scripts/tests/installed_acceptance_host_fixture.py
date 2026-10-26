"""Test-only physical stand-ins for frozen macOS interpreter paths.

Acceptance environment/E2E tests use simulated command runners. Keep their
production argv unchanged while validating canonical executable fixture files;
interpreter rejection and race tests exercise the real admission functions.
"""
from __future__ import annotations

import contextlib
from pathlib import Path
from unittest import mock

from Scripts.reconstruction import run_installed_acceptance_transaction as driver


@contextlib.contextmanager
def macos_interpreter_files(root: Path):
    directory = root / "macos-interpreter-fixtures"
    directory.mkdir()
    files = {}
    for original, name in ((Path("/bin/bash"), "bash"), (Path("/usr/bin/python3"), "python3")):
        executable = directory / name
        executable.write_bytes(b"#!/bin/sh\nexit 0\n")
        executable.chmod(0o700)
        files[original] = executable
    canonical_existing = driver._canonical_existing
    trusted_python = driver._trusted_system_python

    def canonical(path, *, directory, label):
        if path == Path("/bin/bash") and label.startswith("gate ") and not directory:
            canonical_existing(files[path], directory=False, label=label)
            return path
        return canonical_existing(path, directory=directory, label=label)

    def python(path):
        if path != Path("/usr/bin/python3"):
            return trusted_python(path)
        with mock.patch.object(driver, "SYSTEM_PYTHON", files[path]):
            trusted_python(files[path])
        return path

    with (
        mock.patch.object(driver, "_canonical_existing", side_effect=canonical),
        mock.patch.object(driver, "_trusted_system_python", side_effect=python),
    ):
        yield
