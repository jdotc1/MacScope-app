#!/usr/bin/env python3
"""Fail fast when the generated Xcode project holds a file the qualifier would refuse.

The qualifier binds the generated project through restore_build_source.GENERATED_PROJECT_FILES
/ _DIRECTORIES and refuses anything else ("generated Xcode project contains an unexpected
file"). dev_loop runs this right after project generation so a new shared scheme or target
file that is missing from that allowlist fails in the lane's own loop, not in the nightly
(#378 → #386).

usage: check_generated_project.py <MacScope.xcodeproj>   exit 0 ok, 4 refused
"""
from __future__ import annotations

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import restore_build_source  # noqa: E402


def main(argv: list[str]) -> int:
    project = Path(argv[1])
    try:
        restore_build_source._generated_project_identity(project, require_complete=True)
    except restore_build_source.BuildSourceRestoreError as error:
        unexpected = sorted(
            candidate.relative_to(project).as_posix() for candidate in project.rglob("*")
            if (candidate.is_dir() and candidate.relative_to(project).as_posix()
                not in restore_build_source.GENERATED_PROJECT_DIRECTORIES)
            or (candidate.is_file() and candidate.relative_to(project).as_posix()
                not in restore_build_source.GENERATED_PROJECT_FILES))
        print(f"ERROR: {error}: {', '.join(unexpected) or '(see restore_build_source)'}; add it to "
              "Scripts/qualification/restore_build_source.py GENERATED_PROJECT_FILES in the same PR "
              "(MACSCOPE_DEV_SKIP_PROJECT_CHECK=1 skips this check)", file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
