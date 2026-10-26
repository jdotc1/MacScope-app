#!/usr/bin/env python3
"""Preflight the local host for WS-24 installed-app XCUITest execution.

This command is intentionally read-only. It does not grant, reset, or modify
TCC permissions; it only reports whether the current macOS privacy database has
the entries that WS-24's installed-app UI gate needs before invoking XCTest.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import sqlite3
import sys
import time
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


DEFAULT_TCC_DB = Path("/Library/Application Support/com.apple.TCC/TCC.db")
DEFAULT_XCODE_BUNDLE_ID = "com.apple.dt.Xcode"
DEFAULT_XCODE_HELPER_BUNDLE_ID = "com.apple.dt.Xcode-Helper"
DEFAULT_XCODE_HELPER_APP = Path(
    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/"
    "Developer/Library/Xcode/Agents/Xcode Helper.app"
)
DEFAULT_DERIVED_DATA_ROOT = Path.home() / "Library/Developer/Xcode/DerivedData"
DEFAULT_RUNNER_APP_NAME = "MacScopeInstalledAppUITests-Runner.app"

ACCESSIBILITY = "kTCCServiceAccessibility"
DEVELOPER_TOOL = "kTCCServiceDeveloperTool"

@dataclass(frozen=True)
class TCCGrant:
    service: str
    client: str
    auth_value: int | None
    granted: bool

    def to_json(self) -> dict[str, object]:
        return {
            "service": self.service,
            "client": self.client,
            "authValue": self.auth_value,
            "granted": self.granted,
        }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check local host permissions for WS-24 installed-app XCUITest."
    )
    parser.add_argument(
        "--tcc-db",
        type=Path,
        default=DEFAULT_TCC_DB,
        help="Path to the macOS TCC.db to inspect.",
    )
    parser.add_argument(
        "--xcode-bundle-id",
        default=DEFAULT_XCODE_BUNDLE_ID,
        help="Bundle identifier for the Xcode app that drives UI testing.",
    )
    parser.add_argument(
        "--xcode-helper-bundle-id",
        help=(
            "Bundle identifier for Xcode's UI-testing helper. Defaults to the "
            "identifier in Xcode Helper.app when present."
        ),
    )
    parser.add_argument(
        "--xcode-helper-app",
        type=Path,
        default=DEFAULT_XCODE_HELPER_APP,
        help="Xcode Helper.app bundle to inspect for its bundle identifier.",
    )
    parser.add_argument(
        "--runner-app",
        type=Path,
        help=(
            "Built *-Runner.app whose bundle identifier should be checked. "
            "Defaults to the newest MacScopeInstalledAppUITests-Runner.app in DerivedData."
        ),
    )
    parser.add_argument(
        "--runner-bundle-id",
        help="Explicit UI-test runner bundle identifier. Overrides --runner-app.",
    )
    parser.add_argument(
        "--generated-at-unix-ms",
        type=int,
        help="Deterministic timestamp override for tests.",
    )
    return parser.parse_args(argv)


def bundle_identifier_for_app(app: Path) -> str:
    info_plist = app / "Contents" / "Info.plist"
    if not info_plist.is_file():
        raise ValueError(f"runner app Info.plist is missing: {info_plist}")
    with info_plist.open("rb") as handle:
        payload = plistlib.load(handle)
    identifier = payload.get("CFBundleIdentifier")
    if not isinstance(identifier, str) or not identifier:
        raise ValueError(f"runner app has no CFBundleIdentifier: {info_plist}")
    return identifier


def xcode_helper_bundle_identifier(args: argparse.Namespace) -> str:
    if args.xcode_helper_bundle_id:
        return args.xcode_helper_bundle_id
    if args.xcode_helper_app and args.xcode_helper_app.is_dir():
        return bundle_identifier_for_app(args.xcode_helper_app)
    return DEFAULT_XCODE_HELPER_BUNDLE_ID


def find_default_runner_app(derived_data_root: Path | None = None) -> Path:
    derived_data_root = derived_data_root or DEFAULT_DERIVED_DATA_ROOT
    candidates = []
    if derived_data_root.is_dir():
        for candidate in derived_data_root.glob(
            f"MacScope-*/Build/Products/*/{DEFAULT_RUNNER_APP_NAME}"
        ):
            info_plist = candidate / "Contents" / "Info.plist"
            if info_plist.is_file():
                candidates.append(candidate)
    if not candidates:
        raise ValueError(
            "could not find MacScopeInstalledAppUITests-Runner.app in DerivedData; "
            "build MacScopeInstalledAppUITests or pass --runner-app"
        )
    return max(candidates, key=lambda candidate: candidate.stat().st_mtime)


def fetch_grants(database: Path, checks: Iterable[tuple[str, str]]) -> list[TCCGrant]:
    if not database.is_file():
        raise ValueError(f"TCC database is missing: {database}")

    with closing(sqlite3.connect(f"file:{database}?mode=ro", uri=True)) as connection:
        rows = []
        for service, client in checks:
            cursor = connection.execute(
                """
                SELECT auth_value
                FROM access
                WHERE service = ? AND client = ?
                ORDER BY last_modified DESC
                LIMIT 1
                """,
                (service, client),
            )
            row = cursor.fetchone()
            auth_value = int(row[0]) if row is not None and row[0] is not None else None
            rows.append(
                TCCGrant(
                    service=service,
                    client=client,
                    auth_value=auth_value,
                    granted=auth_value == 2,
                )
            )
        return rows


def make_report(args: argparse.Namespace) -> dict[str, object]:
    if args.runner_bundle_id:
        runner_bundle_id = args.runner_bundle_id
    elif args.runner_app:
        runner_bundle_id = bundle_identifier_for_app(args.runner_app)
    else:
        args.runner_app = find_default_runner_app()
        runner_bundle_id = bundle_identifier_for_app(args.runner_app)
    helper_bundle_id = xcode_helper_bundle_identifier(args)

    checks = [
        (DEVELOPER_TOOL, args.xcode_bundle_id),
        (ACCESSIBILITY, args.xcode_bundle_id),
        (ACCESSIBILITY, helper_bundle_id),
        (ACCESSIBILITY, runner_bundle_id),
    ]
    grants = fetch_grants(args.tcc_db, checks)
    missing = [
        {"service": grant.service, "client": grant.client}
        for grant in grants
        if not grant.granted
    ]

    return {
        "schemaVersion": 1,
        "generatedAtUnixMs": args.generated_at_unix_ms
        if args.generated_at_unix_ms is not None
        else int(time.time() * 1000),
        "accepted": not missing,
        "tccDatabase": str(args.tcc_db),
        "xcodeBundleIdentifier": args.xcode_bundle_id,
        "xcodeHelperBundleIdentifier": helper_bundle_id,
        "xcodeHelperApp": str(args.xcode_helper_app) if args.xcode_helper_app else None,
        "runnerApp": str(args.runner_app) if args.runner_app else None,
        "runnerBundleIdentifier": runner_bundle_id,
        "requiredGrants": [grant.to_json() for grant in grants],
        "missingGrants": missing,
        "diagnostic": (
            "WS-24 installed-app XCUITest host preflight passed."
            if not missing
            else "WS-24 installed-app XCUITest host preflight failed before app launch."
        ),
    }


def main(argv: list[str] | None = None) -> int:
    try:
        report = make_report(parse_args(argv or sys.argv[1:]))
    except Exception as error:  # noqa: BLE001 - command-line diagnostic boundary.
        print(f"error: {error}", file=sys.stderr)
        return 2

    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["accepted"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
