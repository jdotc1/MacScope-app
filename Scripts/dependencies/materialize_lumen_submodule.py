#!/usr/bin/env python3
"""Explicit offline preparation of MacScope's pinned Lumen submodule.

The pin is the committed `ThirdParty/Lumen` gitlink, so a pin bump changes only
the gitlink, docs/dependencies/Lumen.md and FIRST_PARTY_COMPONENTS.json. A clean
checkout at any other published Lumen commit (one the local seed also has) is
moved to the pin offline; dirty, flagged or unpublished checkouts are preserved.
SwiftPM/Xcode state that the pinned Lumen .gitignore excludes and the tools
recreate on the next build (.swiftpm/, .build/) is not content: when it is the
only thing that makes a checkout look dirty, it is removed before verification.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

LUMEN_URL = "https://github.com/jdotc1/Lumen.git"
LUMEN_PATH = "ThirdParty/Lumen"
# Top-level directories Xcode/SwiftPM regenerate inside the package checkout
# (workspace state, xcuserdata, build products). Lumen's own .gitignore lists them.
REGENERABLE_DIRECTORIES = (".swiftpm", ".build")


class MaterializationError(RuntimeError):
    pass


def _git(repository: Path, *arguments: str) -> str:
    # Local config cannot grant transport authority. No credential helper,
    # global rewrite, inherited object store, hooks or interactive prompt is used.
    environment = {
        key: value for key, value in os.environ.items()
        if not key.startswith("GIT_") or key in {"GIT_TRACE", "GIT_TRACE2"}
    }
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_TERMINAL_PROMPT="0", GIT_NO_LAZY_FETCH="1",
                       GIT_NO_REPLACE_OBJECTS="1", GIT_OPTIONAL_LOCKS="0")
    result = subprocess.run(
        ["git", "-c", "protocol.allow=never", "-c", "protocol.file.allow=always",
         "-c", "credential.helper=", "-c", "core.hooksPath=/dev/null",
         "-c", "core.fsmonitor=false", "-C", str(repository), *arguments],
        env=environment, text=True, capture_output=True, timeout=120,
    )
    if result.returncode:
        # Do not echo arbitrary repository config, credential-bearing remotes,
        # or subprocess diagnostics into CI logs.
        raise MaterializationError(f"Git {arguments[0]} failed during offline preparation")
    return result.stdout.strip()


def _has_commit(repository: Path, commit: str) -> bool:
    try:
        return _git(repository, "cat-file", "-t", commit) == "commit"
    except MaterializationError:
        return False


def _contract(source: Path) -> tuple[str, str]:
    if Path(_git(source, "rev-parse", "--show-toplevel")).resolve() != source:
        raise MaterializationError("source root must be the repository root")
    head = _git(source, "rev-parse", "HEAD")
    modules = source / ".gitmodules"
    if modules.is_symlink() or not modules.is_file():
        raise MaterializationError(".gitmodules must be an ordinary committed file")
    committed = _git(source, "show", "HEAD:.gitmodules")
    if modules.read_text().strip() != committed:
        raise MaterializationError(".gitmodules differs from committed authority")
    _git(source, "diff", "--cached", "--quiet", "HEAD", "--", ".gitmodules", LUMEN_PATH)
    prefix = f"submodule.{LUMEN_PATH}"
    if _git(source, "config", "--blob", "HEAD:.gitmodules", "--get-all", prefix + ".path") != LUMEN_PATH:
        raise MaterializationError("committed Lumen submodule path is invalid")
    if _git(source, "config", "--blob", "HEAD:.gitmodules", "--get-all", prefix + ".url") != LUMEN_URL:
        raise MaterializationError("committed Lumen URL differs from canonical authority")
    entry = _git(source, "ls-tree", "HEAD", "--", LUMEN_PATH)
    match = re.fullmatch(r"160000 commit ([0-9a-f]{40})\t" + re.escape(LUMEN_PATH), entry)
    if match is None:
        raise MaterializationError("committed Lumen gitlink is missing or invalid")
    return head, match.group(1)


def _verify_checkout(target: Path, expected_commit: str) -> None:
    if not (target / ".git").exists():
        raise MaterializationError("existing Lumen directory is not a Git checkout")
    if Path(_git(target, "rev-parse", "--show-toplevel")).resolve() != target:
        raise MaterializationError("existing Lumen checkout root is invalid")
    if _git(target, "rev-parse", "HEAD") != expected_commit:
        raise MaterializationError("existing Lumen checkout differs from approved pin")
    if _git(target, "remote", "get-url", "origin") != LUMEN_URL:
        raise MaterializationError("existing Lumen checkout URL differs from canonical authority")
    if _git(target, "status", "--porcelain", "--untracked-files=all", "--ignored=matching"):
        raise MaterializationError("existing Lumen checkout is dirty; preserving its contents")
    # Status trusts index flags and core.filemode. Compare physical files with
    # canonical pinned blobs instead; never refresh/reset the user's index.
    object_format = _git(target, "rev-parse", "--show-object-format")
    if object_format not in {"sha1", "sha256"}:
        raise MaterializationError("unsupported Lumen Git object format")
    for entry in _git(target, "ls-tree", "-rz", expected_commit).split("\0"):
        if not entry:
            continue
        metadata, relative = entry.split("\t", 1)
        mode, kind, expected = metadata.split()
        parts = relative.split("/")
        if (kind != "blob" or mode not in {"100644", "100755"}
                or any(part in {"", ".", "..", ".git"} for part in parts)):
            raise MaterializationError("unsupported entry in pinned Lumen checkout")
        physical = target
        for part in parts[:-1]:
            physical /= part
            if not stat.S_ISDIR(physical.lstat().st_mode):
                raise MaterializationError("existing Lumen checkout is dirty; preserving its contents")
        physical /= parts[-1]
        info = physical.lstat()
        actual_mode = "100755" if info.st_mode & stat.S_IXUSR else "100644"
        if not stat.S_ISREG(info.st_mode) or actual_mode != mode:
            raise MaterializationError("existing Lumen checkout is dirty; preserving its contents")
        digest = hashlib.new(object_format, usedforsecurity=False)
        digest.update(f"blob {info.st_size}\0".encode("ascii"))
        with physical.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            raise MaterializationError("existing Lumen checkout is dirty; preserving its contents")


def _remove_regenerable_state(target: Path) -> list[str]:
    """Remove ignored tool state when it is the checkout's only non-pinned content.

    Anything else untracked, ignored or modified keeps the checkout dirty and
    nothing is removed; verification then refuses it as before. Only a real,
    ignored, untracked top-level directory of the canonical checkout qualifies.
    """
    if (Path(_git(target, "rev-parse", "--show-toplevel")).resolve() != target
            or _git(target, "remote", "get-url", "origin") != LUMEN_URL):
        return []
    entries = [entry for entry in _git(
        target, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching",
    ).split("\0") if entry]
    regenerable = {f"!! {name}/": name for name in REGENERABLE_DIRECTORIES}
    if not entries or any(entry not in regenerable for entry in entries):
        return []
    removed = []
    for entry in entries:
        name = regenerable[entry]
        path = target / name
        if (path.is_symlink() or not path.is_dir()
                or _git(target, "ls-files", "-z", "--", name)):
            return removed
        shutil.rmtree(path)
        removed.append(name)
    return sorted(removed)


def _verified_seed(seed: Path, pin: str) -> Path:
    if not seed.is_dir():
        raise MaterializationError("verified local Lumen seed repository is missing; no network acquisition attempted")
    seed = seed.resolve(strict=True)
    if _git(seed, "remote", "get-url", "origin") != LUMEN_URL:
        raise MaterializationError("local Lumen seed URL differs from canonical authority")
    if not _has_commit(seed, pin):
        raise MaterializationError("local Lumen seed does not contain the pinned commit")
    return seed


def _import_pin(target: Path, seed: Path, pin: str) -> None:
    # Only file transport is allowed, importing real objects (no shared
    # alternates/hardlinks and no working-tree bytes from the seed).
    _git(target, "-c", "fetch.fsckObjects=true", "fetch", "--quiet", "--no-tags",
         "--no-recurse-submodules", "--no-write-fetch-head", str(seed), pin)


def _verify_previous_checkout(target: Path, previous: str) -> None:
    _verify_checkout(target, previous)
    # Updating flagged entries can retain old files despite a new HEAD.
    # Preserve those flags and reject the transition instead of clearing them.
    if any(entry and not entry.startswith("H ")
           for entry in _git(target, "ls-files", "-v", "-z").split("\0")):
        raise MaterializationError("previous Lumen checkout has index flags; preserving its contents")


def _normalize_modes(target: Path, commit: str) -> int:
    """Give verified files their canonical 0644/0755 bits (a caller's umask may have left 0600).

    Only permission bits change, and only on files whose bytes _verify_checkout has
    already matched to the pinned blobs; bootstrap's first-party check needs exact modes.
    """
    changed = 0
    for entry in _git(target, "ls-tree", "-rz", commit).split("\0"):
        if not entry:
            continue
        metadata, relative = entry.split("\t", 1)
        mode = metadata.split()[0]
        wanted = 0o755 if mode == "100755" else 0o644
        physical = target / relative
        if stat.S_IMODE(physical.lstat().st_mode) != wanted:
            os.chmod(physical, wanted, follow_symlinks=False)
            changed += 1
    return changed


def materialize(source: Path, seed: Path) -> dict[str, object]:
    source = source.resolve(strict=True)
    head, pin = _contract(source)
    target = source / LUMEN_PATH
    if target.parent.is_symlink() or target.is_symlink():
        raise MaterializationError("Lumen destination must not traverse a symlink")
    previous = None
    normalized = 0
    removed: list[str] = []
    if target.exists() and (not target.is_dir() or any(target.iterdir())):
        if not (target / ".git").exists():
            raise MaterializationError("existing Lumen directory is not a Git checkout")
        removed = _remove_regenerable_state(target)
        current = _git(target, "rev-parse", "HEAD")
        if current == pin:
            _verify_checkout(target, pin)
            normalized = _normalize_modes(target, pin)
            action = "reused"
        else:
            # Only a clean checkout of a published Lumen commit moves; local
            # commits, edits, untracked files and index flags are preserved.
            _verify_previous_checkout(target, current)
            seed = _verified_seed(seed, pin)
            if not _has_commit(seed, current):
                raise MaterializationError(
                    "existing Lumen checkout is not at a published pin; preserving its contents")
            _import_pin(target, seed, pin)
            if _contract(source) != (head, pin):
                raise MaterializationError("source HEAD changed during Lumen preparation")
            _verify_previous_checkout(target, current)
            _git(target, "checkout", "--quiet", "--detach", "--no-recurse-submodules", pin)
            _verify_checkout(target, pin)
            normalized = _normalize_modes(target, pin)
            if _contract(source) != (head, pin):
                raise MaterializationError("source HEAD changed during Lumen preparation")
            action, previous = "updated", current
    else:
        seed = _verified_seed(seed, pin)
        target.parent.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".lumen-materialization-", dir=target.parent) as temporary:
            staged = Path(temporary) / "checkout"
            staged.mkdir()
            _git(staged, "init", "--quiet")
            _git(staged, "remote", "add", "origin", LUMEN_URL)
            _import_pin(staged, seed, pin)
            _git(staged, "checkout", "--quiet", "--detach", pin)
            _verify_checkout(staged, pin)
            normalized = _normalize_modes(staged, pin)
            if _contract(source) != (head, pin):
                raise MaterializationError("source HEAD changed during Lumen preparation")
            if target.is_symlink() or (target.exists() and (not target.is_dir() or any(target.iterdir()))):
                raise MaterializationError("Lumen destination changed during preparation")
            staged.rename(target)
        action = "materialized"
    result = {"action": action, "path": LUMEN_PATH, "commit": pin,
              "url": LUMEN_URL, "network_used": False}
    if previous is not None:
        result["previous_commit"] = previous
    if removed:
        result["removed_regenerable"] = removed
    if normalized:
        result["normalized_modes"] = normalized
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--seed-repository", type=Path, required=True)
    arguments = parser.parse_args(argv)
    # dev_loop.sh runs under umask 077; a checkout made under it would leave 0600
    # files that bootstrap's first-party check (exact 0644/0755) rejects.
    os.umask(0o022)
    try:
        result = materialize(arguments.source_root, arguments.seed_repository)
    except (MaterializationError, OSError, subprocess.TimeoutExpired) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
