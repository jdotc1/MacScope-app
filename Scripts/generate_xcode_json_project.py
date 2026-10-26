#!/usr/bin/env python3
"""Generate in isolation, convert with Xcode, and publish only project.xcproj.

XcodeGen remains the declarative generator. Its legacy intermediate never
enters the working project; Xcode owns conversion to the authoritative format.
Existing user workspace data and custom schemes are preserved.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import stat
import tempfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from xcode_project_json import MAX_PROJECT_BYTES, loads_project


def _ordinary_generated_bytes(path: Path, limit: int = 1024 * 1024) -> bytes:
    if path.parent.is_symlink() or path.is_symlink():
        raise ValueError("generated data must be an ordinary file")
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise ValueError("generated data must be an ordinary file")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError("generated data must be an ordinary file")
        if (metadata.st_dev, metadata.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError("generated data changed before read")
        payload = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
        identity = lambda value: (value.st_dev, value.st_ino, value.st_size,
                                  value.st_mtime_ns, value.st_ctime_ns, value.st_nlink)
        if len(payload) > limit or identity(before) != identity(after):
            raise ValueError("generated data is oversized or changed during read")
        return payload


def _creation_mode_from_umask() -> int:
    """Mode an ordinary shell redirection would create, so callers keep their umask contract.

    Qualification runs under ``umask 077`` and its restore step requires the published local
    xcconfig to be mode 0600; a fixed 0644 broke every passing gate.
    """
    current = os.umask(0)
    os.umask(current)
    return 0o666 & ~current


def _publish_bytes_if_changed(destination: Path, payload: bytes, *, mode: int = 0o644,
                              limit: int = MAX_PROJECT_BYTES) -> bool:
    """Validate existing authority even on a byte hit; replace changed files atomically."""
    if len(payload) > limit or destination.parent.is_symlink() or destination.is_symlink():
        raise ValueError("publication must be bounded and ordinary")
    if destination.exists():
        existing = _ordinary_generated_bytes(destination, limit)
        if existing == payload and stat.S_IMODE(destination.stat().st_mode) == mode:
            return False
    descriptor, temporary = tempfile.mkstemp(prefix=".generated-", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), mode)
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def _publish_shared(source: Path, destination: Path) -> None:
    """Validate the complete shared-file closure before replacing generated files."""
    if source.is_symlink() or not source.is_dir() or destination.is_symlink():
        raise ValueError("shared project data must be ordinary")
    if destination.exists() and any(path.is_symlink() for path in destination.rglob("*")):
        raise ValueError("shared project data must not contain symlinks")
    records = []
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise ValueError("shared project data must not contain symlinks")
        target = destination / path.relative_to(source)
        if path.is_dir():
            if target.exists() and not target.is_dir():
                raise ValueError("shared project directory collides with a file")
            continue
        payload = _ordinary_generated_bytes(path)
        if target.exists():
            _ordinary_generated_bytes(target)
        records.append((target, payload))
    for target, payload in records:
        target.parent.mkdir(parents=True, exist_ok=True)
        _publish_bytes_if_changed(target, payload, limit=1024 * 1024)


def generate(source: Path, xcodegen: Path | None = None, *, unsigned_development: bool = False, cache_release: bool = False) -> None:
    source = source.resolve(strict=True)
    xcodegen = xcodegen or Path(os.environ.get("MACSCOPE_XCODEGEN", str(source.parent / "ThirdParty/XcodeGen/bin/xcodegen")))
    if not xcodegen.is_absolute():
        raise ValueError("XcodeGen must be an absolute governed tool path")
    project = source / "MacScope.xcodeproj"
    if project.is_symlink():
        raise ValueError("project bundle must not be a symlink")
    if (project / "project.pbxproj").exists() or (project / "project.pbxproj").is_symlink():
        raise ValueError("convert the existing project with xcodebuild before regeneration")
    with tempfile.TemporaryDirectory(prefix="MacScope-JSON-XcodeGen-") as temporary:
        parent = Path(temporary)
        staged = parent / source.name
        staged.mkdir()
        for entry in source.iterdir():
            if entry.name in {"project.yml", "MacScope.xcodeproj"}:
                continue
            (staged / entry.name).symlink_to(entry)
        if cache_release:
            from qualification.cache_release_inputs import specification
            (staged / "project.yml").write_text(specification((source / "project.yml").read_text()))
        elif unsigned_development:
            from unsigned_development import specification
            (staged / "project.yml").write_text(specification((source / "project.yml").read_text()))
        else:
            shutil.copy2(source / "project.yml", staged / "project.yml")
        # These are the governed sibling source inputs in project.yml. Local
        # Swift packages, including RecoveryKit, need their package root during
        # isolated generation and Xcode conversion, even in a Git-free sealed export.
        # REA identity, kernel and license resource paths share one governed root;
        # expose that same verified source view rather than copying mutable products.
        for sibling in (Path("ThirdParty/SwiftAssemblyVendor/Sources"), Path("ThirdParty/Lumen"),
                        Path("ThirdParty/REA"), Path("Packages/RecoveryKit")):
            original = source.parent / sibling
            if sibling in {Path("ThirdParty/Lumen"), Path("ThirdParty/REA"),
                           Path("Packages/RecoveryKit")} and original.is_symlink():
                raise ValueError(f"{sibling.name} input root must be an ordinary directory")
            if original.is_dir():
                (parent / sibling).parent.mkdir(parents=True, exist_ok=True)
                (parent / sibling).symlink_to(original, target_is_directory=True)
        subprocess.run([str(xcodegen), "generate"], cwd=staged, check=True)
        generated = staged / "MacScope.xcodeproj"
        subprocess.run([
            "/usr/bin/xcrun", "xcodebuild", "-convert-project", "Xcode Project",
            "-project", str(generated),
        ], cwd=staged, check=True)
        payload = generated / "project.xcproj"
        if not payload.is_file() or (generated / "project.pbxproj").exists():
            raise ValueError("Xcode conversion did not produce a single JSON project")
        project_payload = _ordinary_generated_bytes(payload, MAX_PROJECT_BYTES)
        loads_project(project_payload.decode("utf-8"))
        workspace = generated / "project.xcworkspace" / "contents.xcworkspacedata"
        workspace_payload = _ordinary_generated_bytes(workspace)
        destination_workspace = project / "project.xcworkspace"
        destination_contents = destination_workspace / "contents.xcworkspacedata"
        if destination_workspace.is_symlink() or destination_contents.is_symlink():
            raise ValueError("project workspace must not be a symlink")
        if destination_contents.exists() and _ordinary_generated_bytes(destination_contents) != workspace_payload:
            raise ValueError("existing workspace contents differ from generated authority")
        project.mkdir(exist_ok=True)
        # Publish only generated shared files; retain unrelated custom schemes,
        # workspace state, breakpoints, and per-user settings.
        shared = generated / "xcshareddata"
        if shared.exists():
            destination = project / "xcshareddata"
            _publish_shared(shared, destination)
        # A fresh qualification requires the converter's self-contained workspace.
        # Preserve user state, but never attest unrelated contents as generated.
        if not destination_contents.exists():
            destination_workspace.mkdir(exist_ok=True)
            with destination_contents.open("xb") as output:
                output.write(workspace_payload)
                output.flush()
                os.fsync(output.fileno())
        _publish_bytes_if_changed(project / "project.xcproj", project_payload,
                                  mode=stat.S_IMODE(payload.stat().st_mode))
        cache_marker = project / ".cache-release"
        if cache_release:
            cache_marker.write_text("Signed Release with explicitly admitted cache input scope.\n")
        else:
            cache_marker.unlink(missing_ok=True)
        marker = project / ".unsigned-development"
        if unsigned_development:
            marker.write_text("Debug local build only; regenerate normally for signed builds.\n")
        else:
            marker.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1] / "MacScope")
    parser.add_argument("--xcodegen", type=Path)
    parser.add_argument("--publish-file", type=Path,
                        help="atomically publish bounded stdin bytes only when changed (no generation)")
    parser.add_argument("--publish-mode", choices=("0600", "0644"), default=None,
                        help="permissions for --publish-file (default: caller umask)")
    arguments = parser.parse_args()
    if arguments.publish_file is not None:
        _publish_bytes_if_changed(arguments.publish_file, sys.stdin.buffer.read(1024 * 1024 + 1),
                                  mode=(int(arguments.publish_mode, 8) if arguments.publish_mode is not None
                                        else _creation_mode_from_umask()), limit=1024 * 1024)
    else:
        generate(arguments.source, arguments.xcodegen)
