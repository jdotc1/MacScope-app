#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import io
import json
import os
import plistlib
import sqlite3
import sys
import tempfile
import unittest
from contextlib import closing, redirect_stderr, redirect_stdout
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY_ROOT / "Scripts" / "ws24_check_xcuitest_host.py"


def load_module():
    specification = importlib.util.spec_from_file_location(
        "ws24_check_xcuitest_host",
        SCRIPT,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load WS-24 XCUITest host script")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


ws24_host = load_module()


class WS24CheckXCUITestHostTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.tcc_db = self.root / "TCC.db"
        self.runner_app = self.root / "MacScopeInstalledAppUITests-Runner.app"
        self.runner_bundle_id = "org.macscope.app.MacScopeInstalledAppUITests.xctrunner"
        self.xcode_helper_app = self.root / "Xcode Helper.app"
        self.xcode_helper_bundle_id = "com.apple.dt.Xcode-Helper"
        self.create_tcc_database()
        self.write_runner_app()
        self.write_xcode_helper_app()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_accepts_when_xcode_and_runner_have_required_tcc_grants(self) -> None:
        self.insert_grant(ws24_host.DEVELOPER_TOOL, ws24_host.DEFAULT_XCODE_BUNDLE_ID)
        self.insert_grant(ws24_host.ACCESSIBILITY, ws24_host.DEFAULT_XCODE_BUNDLE_ID)
        self.insert_grant(ws24_host.ACCESSIBILITY, self.xcode_helper_bundle_id)
        self.insert_grant(ws24_host.ACCESSIBILITY, self.runner_bundle_id)

        result = self.run_command()

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["accepted"])
        self.assertEqual(payload["missingGrants"], [])
        self.assertEqual(payload["xcodeHelperBundleIdentifier"], self.xcode_helper_bundle_id)
        self.assertEqual(payload["runnerBundleIdentifier"], self.runner_bundle_id)

    def test_rejects_when_xcode_helper_grant_is_missing(self) -> None:
        self.insert_grant(ws24_host.DEVELOPER_TOOL, ws24_host.DEFAULT_XCODE_BUNDLE_ID)
        self.insert_grant(ws24_host.ACCESSIBILITY, ws24_host.DEFAULT_XCODE_BUNDLE_ID)
        self.insert_grant(ws24_host.ACCESSIBILITY, self.runner_bundle_id)

        result = self.run_command()

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["accepted"])
        self.assertEqual(
            payload["missingGrants"],
            [
                {"service": ws24_host.ACCESSIBILITY, "client": self.xcode_helper_bundle_id},
            ],
        )

    def test_rejects_when_runner_grant_is_missing(self) -> None:
        self.insert_grant(ws24_host.DEVELOPER_TOOL, ws24_host.DEFAULT_XCODE_BUNDLE_ID)
        self.insert_grant(ws24_host.ACCESSIBILITY, ws24_host.DEFAULT_XCODE_BUNDLE_ID)
        self.insert_grant(ws24_host.ACCESSIBILITY, self.xcode_helper_bundle_id)

        result = self.run_command()

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["accepted"])
        self.assertIn(
            {"service": ws24_host.ACCESSIBILITY, "client": self.runner_bundle_id},
            payload["missingGrants"],
        )

    def test_rejects_when_existing_grant_is_denied(self) -> None:
        self.insert_grant(ws24_host.DEVELOPER_TOOL, ws24_host.DEFAULT_XCODE_BUNDLE_ID)
        self.insert_grant(ws24_host.ACCESSIBILITY, ws24_host.DEFAULT_XCODE_BUNDLE_ID)
        self.insert_grant(ws24_host.ACCESSIBILITY, self.xcode_helper_bundle_id, auth_value=0)
        self.insert_grant(ws24_host.ACCESSIBILITY, self.runner_bundle_id)

        result = self.run_command()

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertIn(
            {"service": ws24_host.ACCESSIBILITY, "client": self.xcode_helper_bundle_id},
            payload["missingGrants"],
        )

    def test_rejects_when_runner_grant_is_denied(self) -> None:
        self.insert_grant(ws24_host.DEVELOPER_TOOL, ws24_host.DEFAULT_XCODE_BUNDLE_ID)
        self.insert_grant(ws24_host.ACCESSIBILITY, ws24_host.DEFAULT_XCODE_BUNDLE_ID)
        self.insert_grant(ws24_host.ACCESSIBILITY, self.xcode_helper_bundle_id)
        self.insert_grant(ws24_host.ACCESSIBILITY, self.runner_bundle_id, auth_value=0)

        result = self.run_command()

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["accepted"])
        self.assertIn(
            {"service": ws24_host.ACCESSIBILITY, "client": self.runner_bundle_id},
            payload["missingGrants"],
        )

    def test_reports_invalid_runner_app_as_command_error(self) -> None:
        result = self.run_command(runner_app=self.root / "Missing.app")

        self.assertEqual(result.returncode, 2)
        self.assertIn("Info.plist is missing", result.stderr)

    def test_discovers_newest_runner_app_when_runner_app_is_not_provided(self) -> None:
        older = self.root / "DerivedData/MacScope-older/Build/Products/Debug/MacScopeInstalledAppUITests-Runner.app"
        newer = self.root / "DerivedData/MacScope-newer/Build/Products/Debug/MacScopeInstalledAppUITests-Runner.app"
        self.write_runner_app_at(older, "org.macscope.app.OlderRunner.xctrunner")
        self.write_runner_app_at(newer, self.runner_bundle_id)
        os.utime(older, (1_775_299_000, 1_775_299_000))
        os.utime(newer, (1_775_300_000, 1_775_300_000))

        self.insert_grant(ws24_host.DEVELOPER_TOOL, ws24_host.DEFAULT_XCODE_BUNDLE_ID)
        self.insert_grant(ws24_host.ACCESSIBILITY, ws24_host.DEFAULT_XCODE_BUNDLE_ID)
        self.insert_grant(ws24_host.ACCESSIBILITY, self.xcode_helper_bundle_id)
        self.insert_grant(ws24_host.ACCESSIBILITY, self.runner_bundle_id)

        original_root = ws24_host.DEFAULT_DERIVED_DATA_ROOT
        ws24_host.DEFAULT_DERIVED_DATA_ROOT = self.root / "DerivedData"
        try:
            result = self.run_command(runner_app=False)
        finally:
            ws24_host.DEFAULT_DERIVED_DATA_ROOT = original_root

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["runnerApp"], str(newer))
        self.assertEqual(payload["runnerBundleIdentifier"], self.runner_bundle_id)

    def run_command(self, runner_app: Path | bool | None = None) -> object:
        stdout = io.StringIO()
        stderr = io.StringIO()
        arguments = [
            "--tcc-db",
            str(self.tcc_db),
            "--xcode-helper-app",
            str(self.xcode_helper_app),
            "--generated-at-unix-ms",
            "1775300000000",
        ]
        if runner_app is not False:
            arguments += [
                "--runner-app",
                str(runner_app or self.runner_app),
            ]
        with redirect_stdout(stdout), redirect_stderr(stderr):
            returncode = ws24_host.main(arguments)
        return type(
            "Result",
            (),
            {
                "returncode": returncode,
                "stdout": stdout.getvalue(),
                "stderr": stderr.getvalue(),
            },
        )()

    def create_tcc_database(self) -> None:
        with closing(sqlite3.connect(self.tcc_db)) as connection:
            connection.execute(
                """
                CREATE TABLE access (
                    service TEXT NOT NULL,
                    client TEXT NOT NULL,
                    auth_value INTEGER,
                    last_modified INTEGER
                )
                """
            )
            connection.commit()

    def insert_grant(
        self,
        service: str,
        client: str,
        auth_value: int = 2,
    ) -> None:
        with closing(sqlite3.connect(self.tcc_db)) as connection:
            connection.execute(
                """
                INSERT INTO access (service, client, auth_value, last_modified)
                VALUES (?, ?, ?, ?)
                """,
                (service, client, auth_value, 1),
            )
            connection.commit()

    def write_runner_app(self) -> None:
        self.write_runner_app_at(self.runner_app, self.runner_bundle_id)

    def write_xcode_helper_app(self) -> None:
        contents = self.xcode_helper_app / "Contents"
        contents.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": self.xcode_helper_bundle_id}, handle)

    def write_runner_app_at(self, runner_app: Path, bundle_identifier: str) -> None:
        contents = runner_app / "Contents"
        contents.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": bundle_identifier}, handle)


if __name__ == "__main__":
    unittest.main()
