"""Shared helper: resolve the MacScope work root.

The work root is the folder that holds MacScope caches, lanes and evidence
(dev-loop output, qualification caches, heavy-gate lock, lane checkouts).
Resolution order:
  1. MACSCOPE_WORK_ROOT in the environment.
  2. MACSCOPE_WORK_ROOT=... in a gitignored .env.local at the repository root.
  3. The parent directory of the main checkout (same answer from every worktree).
"""
import os
import subprocess
from pathlib import Path
from typing import Optional

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def _from_env_file(repo: Path) -> str:
    env_file = repo / ".env.local"
    if not env_file.is_file():
        return ""
    value = ""
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("MACSCOPE_WORK_ROOT="):
            value = line.split("=", 1)[1].strip().strip("'\"")
    return value


def _from_git(repo: Path) -> str:
    try:
        common = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            check=True, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""
    return str(Path(common).parent.parent) if common else ""


def work_root() -> Path:
    value = os.environ.get("MACSCOPE_WORK_ROOT", "") or _from_env_file(REPOSITORY_ROOT) or _from_git(REPOSITORY_ROOT)
    if not value:
        raise RuntimeError("cannot resolve the MacScope work root; set MACSCOPE_WORK_ROOT")
    return Path(value)


def existing_work_root() -> Optional[Path]:
    """The work root when it resolves and exists, else None (tests fall back to the default temp dir)."""
    try:
        root = work_root()
    except RuntimeError:
        return None
    return root if root.is_dir() else None
