#!/usr/bin/env python3
"""Refuse a branch that moves a first-party gitlink without moving its recorded pin.

A station whose submodule checkout is stale can stage the old gitlink with an
unrelated change (2026-10-12: #359 moved ThirdParty/Lumen back to v0.37.0 while
FIRST_PARTY_COMPONENTS.json said v0.38.1, breaking every station synced to main).
This compares the branch with its merge base on main: if any ThirdParty/* gitlink
changed but FIRST_PARTY_COMPONENTS.json did not, it prints one line and exits 3.
Deliberate pin bumps change both together; MACSCOPE_ALLOW_PIN_CHANGE=1 overrides.

usage: Scripts/check_pin_changes.py [--repo ROOT] [--base REF]
Exit status: 0 ok (or nothing to compare), 3 refused.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys

MANIFEST = "FIRST_PARTY_COMPONENTS.json"


def git(root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, text=True, check=False)


def default_base(root: Path) -> str | None:
    for ref in ("github/main", "origin/main", "main"):
        if git(root, "rev-parse", "-q", "--verify", f"{ref}^{{commit}}").returncode == 0:
            return ref
    return None


def changed_gitlinks(root: Path, base: str) -> tuple[list[str], bool]:
    merge_base = git(root, "merge-base", "HEAD", base)
    if merge_base.returncode != 0:
        return [], False
    raw = git(root, "diff", "--raw", "--no-renames", merge_base.stdout.strip(), "HEAD")
    gitlinks, manifest = [], False
    for line in raw.stdout.splitlines():
        meta, _, path = line.partition("\t")
        fields = meta.split()
        if path == MANIFEST:
            manifest = True
        if len(fields) >= 2 and "160000" in (fields[0].lstrip(":"), fields[1]) and path.startswith("ThirdParty/"):
            gitlinks.append(path)
    return gitlinks, manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--base")
    arguments = parser.parse_args(argv)
    if os.environ.get("MACSCOPE_ALLOW_PIN_CHANGE") == "1":
        return 0
    base = arguments.base or default_base(arguments.repo)
    if base is None:
        return 0
    gitlinks, manifest = changed_gitlinks(arguments.repo, base)
    if gitlinks and not manifest:
        print(f"ERROR: this branch changes the {', '.join(gitlinks)} gitlink but not {MANIFEST} "
              f"(stale submodule staged? restore the gitlink from {base} and stage by path; "
              "stage by path; deliberate pin bump: MACSCOPE_ALLOW_PIN_CHANGE=1)", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
