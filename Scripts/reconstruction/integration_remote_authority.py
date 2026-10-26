"""Closed, offline URL policy shared by installed-acceptance entrypoints.

This validates identity syntax only. Callers must separately bind the existing
local tracking ref, commit/tree and sealed source provenance. It never fetches
or claims that a local tracking ref reflects the current remote server.
"""

from __future__ import annotations

import os
from pathlib import Path
import stat


CANONICAL_GITHUB_URL = "https://github.com/jdotc1/MacScope-app.git"


def validate_integration_remote_url(remote_url: str) -> None:
    """Accept the exact owner-approved GitHub URL or a canonical local directory."""
    if remote_url == CANONICAL_GITHUB_URL:
        return
    if (
        not remote_url
        or len(remote_url) > 2048
        or not remote_url.startswith("/")
        or "://" in remote_url
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in remote_url)
        or str(Path(remote_url)) != remote_url
        or os.path.normpath(remote_url) != remote_url
    ):
        raise ValueError(
            "integration remote must use the exact canonical GitHub URL or one "
            "canonical absolute local-filesystem directory URL"
        )
    path = Path(remote_url)
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise ValueError(f"local integration remote directory is unavailable: {error}") from error
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or resolved != path:
        raise ValueError("local integration remote must be a canonical non-symlink directory")
