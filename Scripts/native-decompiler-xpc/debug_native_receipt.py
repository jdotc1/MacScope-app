#!/usr/bin/env python3
"""Consume retained native evidence for one explicit signed Debug continuation.

This receipt never confers Release qualification or a new full-golden result.
The old golden object remains unchanged; the later CP4 boundary proof is separate.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess

ENV = "MACSCOPE_NATIVE_DEBUG_CONTINUATION_RECEIPT"
LIVE = "MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING"
TOOLCHAIN_KEYS = {"DEVELOPER_DIR", "SDKROOT", "SDK_NAME", "SDK_VERSION", "SDK_PRODUCT_BUILD_VERSION",
                  "ARCHS", "MACOSX_DEPLOYMENT_TARGET"}
FIELDS = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
HARNESS = (
    "MacScope/Tests/CoreTests/NativeDecompilerObjCBridgeTests.mm",
    "MacScope/Tests/CoreTests/NativeDecompilerObjCBridgeCrossLanguageTests.swift",
)
CONSUMERS = (
    "Scripts/native-decompiler-xpc/debug_native_receipt.py",
    "Scripts/native-decompiler-xpc/run_native_bridge_golden.sh",
    "Scripts/native-decompiler-xpc/NativeDecompilerBridgeGoldenInputs.xcfilelist",
    "Scripts/generate_release_build_provenance.py",
)
TOP_KEYS = {"version", "repository", "head", "tree", "oldProfile", "sources", "blobs",
            "oldGolden", "oldProvenance", "nativeArchive", "nativeEntry", "stagedReceipt", "oldEmbeddedPackage",
            "oldService", "proof", "toolchain", "receiptDirectory"}


class DebugReceiptError(RuntimeError):
    pass


def fields(path: Path) -> list[int]:
    value = path.lstat()
    if (path.resolve(strict=True) != path or value.st_uid != os.getuid()
            or not stat.S_ISREG(value.st_mode) or value.st_nlink != 1):
        raise DebugReceiptError("evidence must be an ordinary owner-controlled file")
    return [getattr(value, name) for name in FIELDS]


def record(path: Path) -> dict:
    return {"path": str(path), "fields": fields(path)}


def read_json(path: Path, *, immutable=False) -> dict:
    before = fields(path)
    if immutable and before[2] & 0o222:
        raise DebugReceiptError("admission receipt must be immutable")
    if before[4] > 8 * 1024 * 1024:
        raise DebugReceiptError("admission receipt is oversized")
    def closed(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise DebugReceiptError("duplicate receipt field")
            result[key] = value
        return result
    value = json.loads(path.read_bytes(), object_pairs_hook=closed)
    if fields(path) != before or not isinstance(value, dict):
        raise DebugReceiptError("receipt changed while being read")
    return value


def bound_json(item: dict, *, immutable=False) -> dict:
    if set(item) != {"path", "fields"} or fields(Path(item["path"])) != item["fields"]:
        raise DebugReceiptError("bound receipt metadata differs")
    return read_json(Path(item["path"]), immutable=immutable)


def snapshot(root: Path) -> dict[str, list[int]]:
    if root.resolve(strict=True) != root or not root.is_dir() or root.lstat().st_uid != os.getuid():
        raise DebugReceiptError("package root is not an ordinary canonical directory")
    result = {}
    for path in sorted(root.rglob("*")):
        value = path.lstat()
        if (value.st_uid != os.getuid() or stat.S_ISLNK(value.st_mode)
                or not (stat.S_ISDIR(value.st_mode) or stat.S_ISREG(value.st_mode))
                or (stat.S_ISREG(value.st_mode) and value.st_nlink != 1)):
            raise DebugReceiptError("package contains an unsafe entry")
        result[str(path.relative_to(root))] = [getattr(value, name) for name in FIELDS]
    return result


def verify_package(root: Path, prior: dict, expected: list, cutoff: int, receipts: Path) -> None:
    """Reuse old files; compare each new destination leaf once to retained digests."""
    observed = snapshot(root)
    accepted = {relative: (kind, metadata, digest) for relative, kind, metadata, digest in expected}
    if set(observed) != set(prior) or set(observed) != set(accepted):
        raise DebugReceiptError("closed package membership differs")
    for relative, current in observed.items():
        kind, source, digest = accepted[relative]
        old = prior[relative]
        old_mode = stat.S_IMODE(old[2])
        current_mode = stat.S_IMODE(current[2])
        # Xcode's builtin-copy normalizes brand-new resources for bundle readers.
        # It may add read/search bits, never write bits or executable file bits.
        copied_mode = old_mode | (0o055 if kind == "directory" else 0o044)
        mode_matches = current_mode == old_mode or (
            current[:2] != old[:2] and current_mode == copied_mode and not current_mode & 0o022)
        if (stat.S_IFMT(current[2]) != stat.S_IFMT(source[2])
                or not mode_matches or current[3] != old[3]):
            raise DebugReceiptError("package entry kind, mode or link count differs")
        if kind == "directory":
            if current[:2] == old[:2] and current != old:
                raise DebugReceiptError("old package directory metadata changed")
            continue
        if current[4] != source[4] or old[4] != source[4] or old[6] > cutoff:
            raise DebugReceiptError("old package lacks a pre-provenance size/time binding")
        if current == old:
            continue
        if current[:2] == old[:2] or current[6] <= cutoff:
            raise DebugReceiptError("old package leaf changed; repeated verification refused")
        key = hashlib.sha256((str(root / relative) + repr(current)).encode()).hexdigest()
        receipt = receipts / ("new-native-leaf-" + key + ".json")
        wanted = {"path": str(root / relative), "fields": current, "sha256": digest}
        if receipt.exists():
            if read_json(receipt, immutable=True) != wanted:
                raise DebugReceiptError("new destination receipt differs")
            continue
        value = hashlib.sha256()
        with (root / relative).open("rb") as stream:
            while block := stream.read(1024 * 1024):
                value.update(block)
        if fields(root / relative) != current or value.hexdigest() != digest:
            raise DebugReceiptError("new destination bytes differ from retained source")
        publish(receipt, wanted)


def publish(path: Path, value: dict) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")


def production_paths(repository: Path) -> set[str]:
    specification = importlib.util.spec_from_file_location(
        "debug_receipt_source_profile", Path(__file__).with_name("native_decompiler_source_identity.py"))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return set(module.profile_paths(repository, "golden"))


def admit(repository: Path, golden_path: Path, environment=None) -> dict:
    environment = os.environ if environment is None else environment
    if (environment.get("CONFIGURATION") != "Debug"
            or environment.get("MACSCOPE_DEBUG_SOURCE_IDENTITY") != "runtime-only"):
        raise DebugReceiptError("continuation is only for the exact signed Debug build")
    raw = environment.get(ENV)
    if not raw:
        raise DebugReceiptError("missing explicit continuation receipt")
    value = read_json(Path(raw), immutable=True)
    if (set(value) - {"priorAdmission", "nativeMode"} != TOP_KEYS
            or value["version"] != 1 or value["repository"] != str(repository)):
        raise DebugReceiptError("unsupported continuation receipt")
    if "nativeMode" in value and value["nativeMode"] != "ordinary":
        raise DebugReceiptError("unsupported native Debug continuation mode")
    expected_condition = "" if value.get("nativeMode") == "ordinary" else LIVE
    if environment.get("MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION", "") != expected_condition:
        raise DebugReceiptError("native Debug continuation mode differs from effective compilation")
    if "priorAdmission" in value:
        prior = bound_json(value["priorAdmission"], immutable=True)
        fixed = TOP_KEYS - {"head", "tree", "sources", "blobs"}
        if any(value[key] != prior[key] for key in fixed):
            raise DebugReceiptError("amendment changed an already accepted proof or baseline")
        for relative, metadata in prior["sources"].items():
            if relative not in CONSUMERS and value["sources"].get(relative) != metadata:
                raise DebugReceiptError("amendment changed an unchanged source binding")
    for key in ("head", "tree"):
        query = "HEAD" if key == "head" else "HEAD^{tree}"
        actual = subprocess.check_output(["git", "-C", str(repository), "rev-parse", query], text=True).strip()
        if actual != value[key]:
            raise DebugReceiptError("committed continuation authority changed")
    old = bound_json(value["oldProfile"], immutable=True)
    old_sources = {row[0]: row[1:] for row in old["files"]}
    sources = value["sources"]
    if production_paths(repository) != set(old_sources):
        raise DebugReceiptError("production source membership changed")
    if set(sources) != set(old_sources) | set(CONSUMERS):
        raise DebugReceiptError("production source closure differs")
    exceptions = set(HARNESS) | {"Scripts/native-decompiler-xpc/run_native_bridge_golden.sh"}
    for relative, current in sources.items():
        if fields(repository / relative) != current:
            raise DebugReceiptError("admitted source metadata changed")
        if relative in old_sources and relative not in exceptions and old_sources[relative] != current:
            raise DebugReceiptError("unchanged production source differs from old golden proof")
    if set(value["blobs"]) != set(HARNESS) | set(CONSUMERS):
        raise DebugReceiptError("harness/consumer blob closure differs")
    for relative, blob in value["blobs"].items():
        actual = subprocess.check_output(["git", "-C", str(repository), "rev-parse", "HEAD:" + relative], text=True).strip()
        if actual != blob:
            raise DebugReceiptError("harness/consumer committed blob differs")
    golden = bound_json(value["oldGolden"])
    provenance = bound_json(value["oldProvenance"])
    if (golden.get("passed") is not True or golden.get("goldenSourceSHA256") != old["sha256"]
            or provenance.get("configuration") != "Debug" or provenance.get("qualification_eligible") is not False
            or provenance.get("native_decompiler_golden_result") != golden
            or read_json(golden_path) != golden):
        raise DebugReceiptError("retained golden/provenance identity differs")
    if (not isinstance(value["toolchain"], dict) or set(value["toolchain"]) != TOOLCHAIN_KEYS
            or any(not isinstance(item, str) or not item for item in value["toolchain"].values())):
        raise DebugReceiptError("complete nonempty toolchain/settings identity is required")
    for key, expected in value["toolchain"].items():
        if environment.get(key) != expected:
            raise DebugReceiptError("effective toolchain/target differs: " + key)
    archive = value["nativeArchive"]
    entry = bound_json(value["nativeEntry"], immutable=True)
    archive_rows = [row for row in entry["payload_records"] if row["path"] == "libmacscope_native_decompiler_contract.a"]
    if (fields(Path(archive["path"])) != archive["fields"] or archive["fields"][6] > value["oldGolden"]["fields"][5]
            or len(archive_rows) != 1 or archive_rows[0]["sha256"] != golden["contractArchiveSHA256"]
            or archive_rows[0]["size"] != archive["fields"][4]):
        raise DebugReceiptError("retained native archive metadata/digest differs")
    proof = value["proof"]
    if (set(proof) != {"commit", "scope", "result", "fixtures"} or proof["scope"] != "cp4-production-boundary-only"
            or len(proof["fixtures"]) != 6):
        raise DebugReceiptError("unsupported CP4 proof scope")
    for relative in HARNESS:
        proved_blob = subprocess.check_output(["git", "-C", str(repository), "rev-parse", proof["commit"] + ":" + relative], text=True).strip()
        if proved_blob != value["blobs"][relative]:
            raise DebugReceiptError("CP4 proof did not execute the admitted harness")
    if fields(Path(proof["result"]["path"])) != proof["result"]["fields"]:
        raise DebugReceiptError("CP4 proof result changed")
    if not Path(proof["result"]["path"]).read_text().startswith("CP4 production ObjC-to-Swift proof PASS:"):
        raise DebugReceiptError("CP4 boundary did not pass")
    for item in proof["fixtures"]:
        if fields(Path(item["path"])) != item["fields"]:
            raise DebugReceiptError("CP4 fixture evidence changed")
    staged = bound_json(value["stagedReceipt"], immutable=True)
    if staged["identity"]["package"]["treeSha256"] != golden["materializationTreeSHA256"]:
        raise DebugReceiptError("staged package identity differs from golden proof")
    actual_staged = snapshot(Path(staged["root"]))
    expected_staged = {relative: metadata for relative, _kind, metadata, _digest in staged["snapshot"]}
    if actual_staged != expected_staged:
        raise DebugReceiptError("staged package metadata changed")
    directory = Path(value["receiptDirectory"])
    mode = directory.lstat()
    if (directory.resolve(strict=True) != directory or not stat.S_ISDIR(mode.st_mode)
            or mode.st_uid != os.getuid() or mode.st_mode & 0o077):
        raise DebugReceiptError("output receipts require a private owner directory")
    value["golden"] = golden
    value["provenance"] = provenance
    value["staged"] = staged
    return value


def new_service_digest(path: Path, current: list[int], role: str) -> str:
    payload = path.read_bytes()
    if role == "info_plist":
        try:
            info = plistlib.loads(payload)
        except (ValueError, plistlib.InvalidFileException) as error:
            raise DebugReceiptError("new service Info.plist is malformed") from error
        if (not isinstance(info, dict) or info.get("CFBundleIdentifier") != "org.macscope.app.NativeDecompiler"
                or info.get("CFBundleExecutable") != "NativeDecompilerXPCService" or info.get("CFBundlePackageType") != "XPC!"):
            raise DebugReceiptError("new service Info.plist identity differs")
    digest = hashlib.sha256(payload).hexdigest()
    if fields(path) != current:
        raise DebugReceiptError("new service output changed during first proof")
    return digest


def runtime_evidence(value: dict, golden_path: Path) -> dict:
    provenance = value["provenance"]
    cutoff = value["oldProvenance"]["fields"][5]
    receipts = Path(value["receiptDirectory"])
    verify_package(golden_path.parent / "NativeDecompilerPackage", value["oldEmbeddedPackage"],
                   value["staged"]["snapshot"], cutoff, receipts)
    evidence = {key: item for key, item in provenance.items()
                if key.startswith("native_decompiler_")
                and key != "native_decompiler_debug_cp4_supplement"}
    service = golden_path.parents[1]
    leaves = {"info_plist": service / "Info.plist", "executable": service / "MacOS/NativeDecompilerXPCService",
              "code_resources": service / "_CodeSignature/CodeResources"}
    for name, path in leaves.items():
        current = fields(path)
        old = value["oldService"][name]
        key = "native_decompiler_embedded_service_" + name + "_sha256"
        if old[6] > cutoff:
            raise DebugReceiptError("old service leaf lacks pre-provenance binding")
        if current == old:
            continue
        if current[:2] == old[:2] and current[6] <= cutoff:
            raise DebugReceiptError("old service identity differs")
        receipt_key = hashlib.sha256((str(path) + repr(current)).encode()).hexdigest()
        receipt = receipts / ("new-native-service-" + receipt_key + ".json")
        if receipt.exists():
            recorded = read_json(receipt, immutable=True)
            if recorded.get("path") != str(path) or recorded.get("fields") != current:
                raise DebugReceiptError("service receipt metadata differs")
            digest = recorded["sha256"]
        else:
            digest = new_service_digest(path, current, name)
            publish(receipt, {"path": str(path), "fields": current, "sha256": digest})
        evidence[key] = digest
    # The CP4 supplement remains in the immutable external admission receipt.
    # The runtime Debug provenance schema is closed; proof bookkeeping is not
    # a product runtime field and must not leak from an older baseline either.
    return evidence


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--golden-result", type=Path, required=True)
    arguments = parser.parse_args()
    admit(arguments.repository_root, arguments.golden_result)
    print("==> retained full-golden identity plus separate CP4-only supplement consumed; no checks replayed")
