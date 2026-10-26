"""Receipt-bound MacScope executable selection for the native client suite.

The native suite (``test_macscope.py``) runs only against an executable whose bytes match
a digest recorded at qualification time. There is no search of ``PATH``, local build
directories or ``$MACSCOPE_BINARY``: an unbound environment skips with a reason, and a
binding that is present but wrong (malformed receipt, missing file, digest mismatch,
ambiguous configuration) is an error rather than a skip.

Two binding forms are accepted (exactly one may be set):

* ``MACSCOPE_NATIVE_TEST_RECEIPT``: a qualification preparation receipt
  (``NativeLivePreparation.receipt.json`` or ``InstalledUIPreparation.receipt.json`` in the
  run's ``candidate-artifacts`` directory, written by
  ``Scripts/qualify_local_private_build.sh``). Its ``artifacts.app.path`` names the
  candidate app and ``artifacts.app.executable_sha256`` the digest of
  ``Contents/MacOS/MacScope``.
* ``MACSCOPE_NATIVE_TEST_EXECUTABLE`` together with ``MACSCOPE_NATIVE_TEST_EXECUTABLE_SHA256``:
  an executable path and the SHA-256 recorded for it by such a receipt.

Standard library only; Python 3.9 compatible.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from pathlib import Path
from typing import Any, Mapping, NamedTuple, Optional

RECEIPT_ENV = "MACSCOPE_NATIVE_TEST_RECEIPT"
EXECUTABLE_ENV = "MACSCOPE_NATIVE_TEST_EXECUTABLE"
EXECUTABLE_SHA256_ENV = "MACSCOPE_NATIVE_TEST_EXECUTABLE_SHA256"

# Mirrors Scripts/reconstruction/native_live_preparation_receipt.py (RECEIPT_KIND and the
# schema versions its parse_document accepts).
RECEIPT_KIND = "native-live-xpc-preparation"
RECEIPT_SCHEMA_VERSIONS = frozenset({1, 2})
APP_EXECUTABLE_RELATIVE_PATH = Path("Contents/MacOS/MacScope")

_SHA256 = re.compile(r"[0-9a-f]{64}")

UNBOUND_REASON = (
    "native MacScope suite is not bound to a qualified executable: set "
    f"{RECEIPT_ENV} to a qualification preparation receipt "
    "(<run-root>/candidate-artifacts/NativeLivePreparation.receipt.json), or set both "
    f"{EXECUTABLE_ENV} and {EXECUTABLE_SHA256_ENV}. $MACSCOPE_BINARY, PATH and local "
    "build directories are deliberately not consulted."
)


class BindingError(ValueError):
    """A binding was configured but does not establish a verified executable."""


class Binding(NamedTuple):
    executable: str
    sha256: str
    receipt: Optional[str]
    source_commit: Optional[str]


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require_digest(value: Any, where: str) -> str:
    if not isinstance(value, str) or not _SHA256.fullmatch(value):
        raise BindingError(f"{where} is not a lowercase hex SHA-256 digest: {value!r}")
    return value


def _verified_executable(path_text: str, expected_sha256: str, where: str) -> str:
    path = Path(path_text)
    if not path.is_absolute():
        raise BindingError(f"{where} is not an absolute path: {path_text}")
    try:
        metadata = path.stat()
    except OSError as error:
        raise BindingError(f"{where} does not exist: {path_text} ({error})") from error
    if not stat.S_ISREG(metadata.st_mode) or not os.access(path, os.X_OK):
        raise BindingError(f"{where} is not an executable regular file: {path_text}")
    actual = file_sha256(path)
    if actual != expected_sha256:
        raise BindingError(
            f"{where} does not match its recorded digest: {path_text} has sha256 {actual}, "
            f"recorded {expected_sha256}"
        )
    return str(path)


def binding_from_receipt(receipt_path: str) -> Binding:
    path = Path(receipt_path)
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise BindingError(f"{RECEIPT_ENV} is not a readable JSON receipt: {receipt_path} ({error})") from error
    if not isinstance(document, dict):
        raise BindingError(f"receipt is not a JSON object: {receipt_path}")
    if document.get("receipt_kind") != RECEIPT_KIND:
        raise BindingError(
            f"receipt kind {document.get('receipt_kind')!r} is not {RECEIPT_KIND!r}: {receipt_path}"
        )
    if document.get("schema_version") not in RECEIPT_SCHEMA_VERSIONS:
        raise BindingError(
            f"receipt schema {document.get('schema_version')!r} is unsupported: {receipt_path}"
        )
    artifacts = document.get("artifacts")
    app = artifacts.get("app") if isinstance(artifacts, dict) else None
    if not isinstance(app, dict) or not isinstance(app.get("path"), str):
        raise BindingError(f"receipt has no artifacts.app.path: {receipt_path}")
    expected = _require_digest(app.get("executable_sha256"), "receipt artifacts.app.executable_sha256")
    app_path = Path(app["path"])
    if app_path.suffix != ".app":
        raise BindingError(f"receipt artifacts.app.path is not an app bundle: {app_path}")
    executable = _verified_executable(
        str(app_path / APP_EXECUTABLE_RELATIVE_PATH), expected, "receipt app executable"
    )
    source = document.get("source")
    commit = source.get("commit") if isinstance(source, dict) else None
    return Binding(executable, expected, str(path), commit if isinstance(commit, str) else None)


def resolve_binding(environ: Optional[Mapping[str, str]] = None) -> Optional[Binding]:
    """Return the verified binding, ``None`` when no binding is configured, or raise
    :class:`BindingError` when a configured binding is invalid."""
    env = os.environ if environ is None else environ
    receipt = env.get(RECEIPT_ENV) or None
    executable = env.get(EXECUTABLE_ENV) or None
    digest = env.get(EXECUTABLE_SHA256_ENV) or None
    if receipt and (executable or digest):
        raise BindingError(
            f"set either {RECEIPT_ENV} or {EXECUTABLE_ENV}+{EXECUTABLE_SHA256_ENV}, not both"
        )
    if receipt:
        return binding_from_receipt(receipt)
    if executable or digest:
        if not (executable and digest):
            raise BindingError(
                f"{EXECUTABLE_ENV} and {EXECUTABLE_SHA256_ENV} must be set together"
            )
        expected = _require_digest(digest.lower(), EXECUTABLE_SHA256_ENV)
        return Binding(_verified_executable(executable, expected, EXECUTABLE_ENV), expected, None, None)
    return None
