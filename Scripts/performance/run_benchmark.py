#!/usr/bin/env python3
"""Run one serialized Release performance experiment; never claims release qualification."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from work_root import work_root as macscope_work_root  # noqa: E402

SELECTOR = "CoreTests/M1MaxPerformanceQualificationTests/testRecordControlledCorpus"
# Experiment switches read by the product, forwarded from this script's
# environment to the measured test process and recorded in context.json, so a
# paired baseline/candidate run from one build differs only in these values.
EXPERIMENT_SWITCHES = ("MACSCOPE_DYNAMIC_TILING",)
SETTINGS = ("ARCHS", "CONFIGURATION", "SWIFT_VERSION", "SWIFT_OPTIMIZATION_LEVEL",
            "SWIFT_COMPILATION_MODE", "ENABLE_TESTABILITY", "ENABLE_CODE_COVERAGE",
            "GCC_OPTIMIZATION_LEVEL", "CLANG_COVERAGE_MAPPING", "SDKROOT",
            "SDK_VERSION", "CODE_SIGN_IDENTITY", "AD_HOC_CODE_SIGNING_ALLOWED",
            "COMPILATION_CACHE_ENABLE_CACHING", "COMPILATION_CACHE_CAS_PATH")


def command(argv, cwd=None, timeout=60):
    return subprocess.run([str(item) for item in argv], cwd=cwd, check=True,
                          capture_output=True, text=True, timeout=timeout).stdout.strip()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(str(temporary), str(path))


def external_path(path, source):
    path = path.expanduser().absolute()
    if path == source or source in path.parents or path in source.parents:
        raise ValueError("Performance products and results must be outside the repository")
    if any(part.is_symlink() for part in [path] + list(path.parents)):
        raise ValueError("Use a canonical path without symbolic links")
    return path


@contextmanager
def heavy_lock(source, output):
    lock = Path(os.environ.get("MACSCOPE_GATE_LOCK",
                              str(macscope_work_root() / ".macscope-heavy-gate.lock")))
    lock.parent.mkdir(parents=True, exist_ok=True)
    helper = source / "Scripts/qualification/heavy_gate_lock.py"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(str(lock), flags, 0o600)
    acquired = False
    try:
        subprocess.run([sys.executable, str(helper), "acquire", "--fd", str(descriptor),
                        "--lock", str(lock), "--pid", str(os.getpid()),
                        "--work-root", str(source), "--integration-ref", "performance-experiment",
                        "--mode", "performance", "--run-root", str(output)],
                       pass_fds=(descriptor,), check=True)
        acquired = True
        yield
    finally:
        if acquired:
            subprocess.run([sys.executable, str(helper), "release", "--lock", str(lock),
                            "--pid", str(os.getpid())], check=False)
        os.close(descriptor)


def test_targets(document):
    if "TestConfigurations" in document:
        return [target for config in document["TestConfigurations"]
                for target in config.get("TestTargets", [])]
    return [value for key, value in document.items()
            if not key.startswith("__") and isinstance(value, dict)]


def core_target(target):
    return (target.get("BlueprintName") == "CoreTests"
            or target.get("TestTargetName") == "CoreTests"
            or "CoreTests.xctest" in str(target.get("TestBundlePath", "")))


def rebase_testroot(value, root):
    if isinstance(value, str):
        return value.replace("__TESTROOT__", str(root))
    if isinstance(value, list):
        return [rebase_testroot(item, root) for item in value]
    if isinstance(value, dict):
        return {key: rebase_testroot(item, root) for key, item in value.items()}
    return value


def prepared_xctestrun(original, destination, environment):
    with original.open("rb") as stream:
        document = rebase_testroot(plistlib.load(stream), original.parent)
    targets = [target for target in test_targets(document) if core_target(target)]
    if len(targets) != 1:
        raise ValueError("Expected exactly one CoreTests target in selected .xctestrun")
    target = targets[0]
    target.setdefault("EnvironmentVariables", {}).update(environment)
    with destination.open("xb") as stream:
        plistlib.dump(document, stream, fmt=plistlib.FMT_BINARY)


def experiment_environment(environment):
    return {key: environment[key] for key in EXPERIMENT_SWITCHES if key in environment}


def hardware():
    values = {}
    for name in ("hw.model", "machdep.cpu.brand_string", "hw.physicalcpu", "hw.logicalcpu",
                 "hw.memsize", "hw.perflevel0.physicalcpu", "hw.perflevel1.physicalcpu"):
        result = subprocess.run(["/usr/sbin/sysctl", "-n", name], capture_output=True, text=True)
        values[name] = result.stdout.strip() if result.returncode == 0 else None
    values["macOS"] = command(["/usr/bin/sw_vers", "-productVersion"])
    values["macOSBuild"] = command(["/usr/bin/sw_vers", "-buildVersion"])
    return values


def run_logged(argv, source, path):
    started = time.monotonic()
    with path.open("xb") as log:
        result = subprocess.run([str(item) for item in argv], cwd=source, stdout=log,
                                stderr=subprocess.STDOUT)
    return {"seconds": time.monotonic() - started, "exitCode": result.returncode,
            "log": path.name}


def product_seals(products):
    candidates = sorted(products.glob("Release/**/*.app/Contents/_CodeSignature/CodeResources"))
    candidates += sorted(products.glob("Release/**/*.xpc/Contents/_CodeSignature/CodeResources"))
    candidates += sorted(products.glob("Release/**/*.xctest/Contents/_CodeSignature/CodeResources"))
    if not candidates:
        raise ValueError("No signed Release product seals were found")
    return {str(path.relative_to(products)): digest(path) for path in candidates}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--reuse-build", action="store_true")
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise SystemExit("This experiment requires a native Apple-silicon Mac")
    source = args.source_root.expanduser().resolve(strict=True)
    if command(["git", "status", "--porcelain", "--untracked-files=no"], source):
        raise SystemExit("Commit the scoped experiment source before benchmarking")
    derived = external_path(args.derived_data, source)
    output = external_path(args.output_root, source)
    if not any(part.endswith(".noindex") for part in derived.parts):
        raise SystemExit("Place DerivedData under a .noindex directory")
    if not 1 <= args.jobs <= 64:
        raise SystemExit("--jobs must be 1...64")
    output.mkdir(parents=True, exist_ok=False)
    derived.mkdir(parents=True, exist_ok=True)
    cache = external_path(Path(os.environ.get("MACSCOPE_COMPILATION_CACHE_ROOT",
        str(macscope_work_root() / "MacScopeDevLoop.noindex/compilation-cache"))), source)
    if not any(part.endswith(".noindex") for part in cache.parts):
        raise SystemExit("Place the persistent Swift compilation cache under a .noindex directory")
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    metadata = cache.stat()
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
        raise SystemExit("The compilation cache must be owner-controlled and not group/world writable")
    manifest = args.manifest.expanduser().resolve(strict=True)
    shutil.copy2(str(manifest), str(output / "corpus.json"))
    xcode = command(["/usr/bin/xcodebuild", "-version"])
    if not xcode.startswith("Xcode 27.") and not xcode.startswith("Xcode 27\n"):
        raise SystemExit("Select the repository's supported Xcode 27 toolchain first")
    identity = {"sourceCommit": command(["git", "rev-parse", "HEAD"], source),
                "sourceTree": command(["git", "rev-parse", "HEAD^{tree}"], source),
                "xcode": xcode,
                "swift": command(["/usr/bin/xcrun", "swiftc", "--version"]),
                "sdk": command(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
                "developerDir": os.environ.get("DEVELOPER_DIR") or command(["/usr/bin/xcode-select", "-p"]),
                "derivedData": str(derived), "configuration": "Release", "testability": True,
                "coverage": False}
    context = {"schemaVersion": 1, "identity": identity, "hardware": hardware(),
               "manifestSHA256": digest(manifest), "runID": str(uuid.uuid4()),
               "startedAt": datetime.now(timezone.utc).isoformat(), "status": "incomplete",
               "releaseQualification": False, "stages": {},
               "experimentEnvironment": experiment_environment(os.environ)}
    write_json(output / "context.json", context)
    project = source / "MacScope/MacScope.xcodeproj"
    arguments = ["/usr/bin/xcodebuild", "-project", project, "-scheme", "MacScopeApp",
                 "-configuration", "Release", "-destination", "platform=macOS,arch=arm64",
                 "-derivedDataPath", derived, "-jobs", str(args.jobs), "-parallelizeTargets",
                 "ENABLE_TESTABILITY=YES",
                 "SWIFT_OPTIMIZATION_LEVEL=-O", "CLANG_COVERAGE_MAPPING=NO",
                 "GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO", "COMPILER_INDEX_STORE_ENABLE=NO"]
    arguments.extend(["COMPILATION_CACHE_ENABLE_CACHING=YES", "COMPILATION_CACHE_CAS_PATH=" + str(cache)])
    receipt_path = derived / "MacScopePerformanceBuild.json"
    products = derived / "Build/Products"
    with heavy_lock(source, output):
        if args.reuse_build:
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            if receipt["identity"] != identity or receipt["productSeals"] != product_seals(products):
                raise ValueError("Retained benchmark products do not match exact source/toolchain/seals")
            xctestrun = Path(receipt["xctestrun"])
            if digest(xctestrun) != receipt["xctestrunSHA256"]:
                raise ValueError("Retained .xctestrun changed")
            context["buildSettings"] = receipt["buildSettings"]
        else:
            prepare = run_logged([source / "script/build_and_run.sh", "--prepare"], source,
                                 output / "prepare.log")
            context["stages"]["prepare"] = prepare
            write_json(output / "context.json", context)
            if prepare["exitCode"]:
                raise SystemExit(prepare["exitCode"])
            settings = json.loads(command(arguments + ["-showBuildSettings", "-json"], source, timeout=120))
            context["buildSettings"] = {
                value["target"]: {key: value["buildSettings"].get(key) for key in SETTINGS}
                for value in settings
            }
            # Xcode 27 accepts -enableCodeCoverage only on test actions, not -showBuildSettings.
            stage = run_logged(arguments + ["-enableCodeCoverage", "NO", "-showBuildTimingSummary",
                                            "-only-testing:" + SELECTOR,
                                            "build-for-testing"], source, output / "build.log")
            context["stages"]["build"] = stage
            write_json(output / "context.json", context)
            if stage["exitCode"]:
                raise SystemExit(stage["exitCode"])
            candidates = []
            for path in products.glob("*.xctestrun"):
                with path.open("rb") as stream:
                    if any(core_target(target) for target in test_targets(plistlib.load(stream))):
                        candidates.append(path)
            if len(candidates) != 1:
                raise ValueError("Use dedicated benchmark DerivedData with one CoreTests .xctestrun")
            xctestrun = candidates[0]
            write_json(receipt_path, {"identity": identity, "productSeals": product_seals(products),
                                     "xctestrun": str(xctestrun), "xctestrunSHA256": digest(xctestrun),
                                     "buildSettings": context["buildSettings"]})
        prepared = output / "Performance.xctestrun"
        prepared_xctestrun(xctestrun, prepared, {
            "MACSCOPE_PERF_RUN": "1", "MACSCOPE_PERF_MANIFEST": str(output / "corpus.json"),
            "MACSCOPE_PERF_OUTPUT": str(output / "samples.jsonl"),
            "MACSCOPE_PERF_RUN_ID": context["runID"], **context["experimentEnvironment"]})
        stage = run_logged(["/usr/bin/xcodebuild", "test-without-building", "-xctestrun", prepared,
                            "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO",
                            "-only-testing:" + SELECTOR, "-resultBundlePath", output / "Results.xcresult"],
                           source, output / "test.log")
        context["stages"]["test"] = stage
        context["status"] = "complete" if stage["exitCode"] == 0 else "failed"
        context["endedAt"] = datetime.now(timezone.utc).isoformat()
        write_json(output / "context.json", context)
        if stage["exitCode"]:
            raise SystemExit(stage["exitCode"])
    print(output)


if __name__ == "__main__":
    main()
