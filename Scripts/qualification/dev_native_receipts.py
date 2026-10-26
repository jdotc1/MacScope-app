#!/usr/bin/env python3
"""Chain dev_loop native receipt roots within one DerivedData.

Source-identity receipts belong to one immutable-input run, so every run gets
a fresh private NativeIdentity.* root. The staged-package receipt that run
publishes must still reach later runs, or the next build refuses its own
staged copy ("not a complete owned attested set"). NativeIdentity.current
names the root holding the newest staged receipt; later runs pass it as
MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT. A DerivedData without the pointer keeps
the plain receipt-free mode until --native-verbose first registers one.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shlex
import stat
import sys
import tempfile

POINTER = "NativeIdentity.current"
PREFIX = "NativeIdentity."


class ReceiptRootError(ValueError):
    pass


def _private_root(derived: Path, raw: str) -> Path:
    root = Path(raw)
    if not root.is_absolute() or root.parent != derived or not root.name.startswith(PREFIX) \
            or root.name == POINTER:
        raise ReceiptRootError(f"receipt root is not a NativeIdentity.* directory of {derived}: {raw}")
    metadata = root.lstat()
    if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) & 0o077):
        raise ReceiptRootError(f"receipt root is not a private owned directory: {root}")
    return root


def _derived(raw: Path) -> Path:
    derived = raw.resolve(strict=True)
    if not derived.is_dir():
        raise ReceiptRootError(f"DerivedData is not a directory: {raw}")
    return derived


def current(derived: Path) -> Path | None:
    pointer = derived / POINTER
    if not os.path.lexists(pointer):
        return None
    metadata = pointer.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise ReceiptRootError(f"{pointer} must be an owned regular file")
    return _private_root(derived, pointer.read_text(encoding="utf-8").strip())


def begin(derived: Path, register: bool) -> dict[str, str]:
    """Return the environment for this run, or {} when receipt mode is off."""
    derived = _derived(derived)
    prior = current(derived)
    if prior is None and not register:
        return {}
    root = Path(tempfile.mkdtemp(prefix=PREFIX, dir=derived))
    environment = {"MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(root),
                   "MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view"}
    if prior is not None:
        environment["MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT"] = str(prior)
    return environment


def finish(derived: Path, root_raw: str) -> bool:
    """Point at this run's root when it published a staged receipt or none is registered."""
    derived = _derived(derived)
    root = _private_root(derived, root_raw)
    published = any(root.glob("staged-sleigh-*.json"))
    prior = current(derived)
    if not published and prior is not None:
        return False
    if prior is not None and prior != root:
        # Receipts are keyed by staged path. A run that published only some
        # copies (e.g. the golden runner's) must not orphan the others' receipts:
        # carry forward every prior receipt this run did not replace.
        for receipt in sorted(prior.glob("staged-sleigh-*.json")):
            target = root / receipt.name
            if os.path.lexists(target):
                continue
            metadata = receipt.lstat()
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
                raise ReceiptRootError(f"prior staged receipt is not an owned regular file: {receipt}")
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
            with os.fdopen(descriptor, "wb") as output:
                output.write(receipt.read_bytes())
    temporary = derived / f".{POINTER}.{os.getpid()}"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(str(root) + "\n")
    os.replace(temporary, derived / POINTER)
    return True


def main(arguments=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser("begin", help="print shell exports for this run")
    start.add_argument("--derived-data", required=True, type=Path)
    start.add_argument("--register", action="store_true",
                       help="enter receipt mode even when no root is registered yet")
    end = commands.add_parser("finish", help="register this run's root when it published")
    end.add_argument("--derived-data", required=True, type=Path)
    end.add_argument("--root", required=True)
    parsed = parser.parse_args(arguments)
    try:
        if parsed.command == "begin":
            for key, value in begin(parsed.derived_data, parsed.register).items():
                print(f"export {key}={shlex.quote(value)}")
        elif finish(parsed.derived_data, parsed.root):
            print(f"==> native receipt root registered: {parsed.root}", file=sys.stderr)
    except (OSError, ReceiptRootError) as error:
        print(f"ERROR: native receipt root: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
