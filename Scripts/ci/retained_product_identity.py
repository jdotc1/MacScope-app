#!/usr/bin/env python3
"""Key CI's persistent DerivedData by toolchain/project identity (D9/D12).

CI keeps one warm run root (qualify --persistent-run). Its DerivedData is reused
while this identity key is unchanged and removed when it changes; there is no
calendar-based ("daily") clean.
"""
from __future__ import annotations
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

INPUTS = ("ThirdParty/Lumen", "ThirdParty/MachOKit", "ThirdParty/GhosttyVT",
          "ThirdParty/GhosttySurface", "ThirdParty/SleighNative", "ThirdParty/XcodeGen",
          "Scripts/dependencies", "MacScope/project.yml", "Scripts/bootstrap.sh",
          "Scripts/generate_xcode_json_project.py", "THIRD_PARTY_COMPONENTS.yml",
          "Packages/RecoveryKit")


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def command(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True,
                          text=True, timeout=30).stdout.strip()


def identity(source: Path, toolchain: dict[str, str]) -> dict:
    pins = {}
    for path in INPUTS:
        record = command("git", "ls-tree", "HEAD", "--", path, cwd=source)
        if not record or "\n" in record or record.split("\t", 1)[-1] != path:
            raise ValueError(f"missing canonical retention input: {path}")
        pins[path] = record.split("\t", 1)[0]
    return {"schema": 1, "canonical_inputs": pins, "toolchain": toolchain,
            "configuration": "Debug", "architecture": "arm64", "coverage": True,
            "signing": "development", "debug_source_identity": "runtime-only"}


PERSISTENT_RUN = "nightly"


def derived_data(work_root: Path) -> Path:
    return work_root / "runs" / f"run.{PERSISTENT_RUN}" / "DerivedData"


def warm_decision(previous_key: str | None, key: str, has_products: bool) -> tuple[str, str]:
    """Return (mode, reason): reuse DerivedData only under an unchanged key."""
    if not has_products:
        return "clean", "no retained DerivedData"
    if previous_key != key:
        return "clean", "toolchain/project identity changed"
    return "warm", "identity unchanged; incremental build"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--work-root", type=Path, required=True)
    parser.add_argument("--finalize", action="store_true")
    args = parser.parse_args()
    receipt = args.work_root / "CI_RETENTION.json"
    if args.finalize:
        if not receipt.is_file():
            return  # Failed before identity acquisition; preserve the original failure.
        value = json.loads(receipt.read_text())
        value["qualification_stage_timings"] = [
            {"path": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
             "stages": json.loads(p.read_text())}
            for p in sorted((args.work_root / "runs").glob("*/STAGE_TIMINGS.json"))]
        receipt.write_bytes(canonical(value))
        return
    toolchain = {"developer_dir": os.environ["DEVELOPER_DIR"],
                 "xcode": command("/usr/bin/xcodebuild", "-version"),
                 "sdk": command("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"),
                 "sdk_build": command("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
                 "sdk_path": command("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"),
                 "swift": command("/usr/bin/xcrun", "swiftc", "--version")}
    value = identity(args.source_root, toolchain)
    key = hashlib.sha256(canonical(value)).hexdigest()
    args.work_root.mkdir(parents=True, exist_ok=True)
    previous_key = None
    if receipt.is_file():
        try:
            previous_key = json.loads(receipt.read_text()).get("key")
        except (OSError, ValueError):
            previous_key = None
    products = derived_data(args.work_root)
    mode, reason = warm_decision(previous_key, key, products.is_dir())
    if mode == "clean" and products.exists():
        subprocess.run(["/bin/chmod", "-R", "u+w", str(products)], check=False)
        shutil.rmtree(products)
    receipt.write_bytes(canonical({"mode": mode, "key": key, "reason": reason,
        "identity": value, "source_commit": command("git", "rev-parse", "HEAD", cwd=args.source_root),
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}))
    print(f"{mode} build: {reason}", flush=True)
    print(f"retained products identity {key}", flush=True)


if __name__ == "__main__":
    main()
