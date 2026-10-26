#!/usr/bin/env python3
"""Capture and score stripped Swift executable function inventories."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

SCRIPT = [{"command": name, "arguments": {}}
          for name in ("sections", "functions", "symbols", "exports")]
CONTROL_REPOSITORIES = ("sample-app", "sample-tool", "swift-argument-parser")


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def file_identity(path):
    stat = Path(path).stat()
    return {"path": str(Path(path).resolve()), "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns, "inode": stat.st_ino}


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def discover_products(corpus, expected_count=24):
    """Resolve manifest mains through matching build receipts without hashing inputs."""
    corpus = Path(corpus).resolve()
    manifest = read_json(corpus / "manifest.json")
    products = []
    seen = set()
    for repository in manifest:
        for product in repository.get("products", []):
            if product.get("main_executable") is not True:
                continue
            binary = Path(product["path"])
            relative = binary.resolve().relative_to(corpus / "inputs")
            if len(relative.parts) != 3:
                raise ValueError(f"Unexpected input path: {binary}")
            repo, opt, name = relative.parts
            if repo != repository["name"] or name != product["name"]:
                raise ValueError(f"Manifest product identity mismatch: {binary}")
            key = (repo, opt, name)
            if key in seen:
                raise ValueError(f"Duplicate main executable: {key}")
            seen.add(key)
            oracle = corpus / "oracle" / repo / opt
            receipts = []
            identity_matches = False
            for receipt_path in sorted(oracle.glob("build*.json")):
                receipt = read_json(receipt_path)
                matches = [p for p in receipt.get("products", [])
                           if p["name"] == name and Path(p["path"]) == binary]
                identity_matches = identity_matches or bool(matches)
                matching = [p for p in matches if p["sha256"] == product["sha256"]]
                for recorded in matching:
                    if ("unstripped_sha256" in recorded and
                            recorded["unstripped_sha256"] != product["unstripped_sha256"]):
                        raise ValueError(f"Manifest/build digest mismatch: {key} (unstripped)")
                if matching:
                    receipts.append((receipt_path, receipt))
            if not receipts:
                if identity_matches:
                    raise ValueError(f"Manifest/build digest mismatch: {key}")
                raise ValueError(f"No build receipt lists {key}")
            build_path, build = next(((path, receipt) for path, receipt in receipts
                                      if receipt.get("status") == "built"), receipts[0])
            paths = {"binary": binary, "twin": Path(product["unstripped_path"]),
                     "nm": Path(product["nm_file"]),
                     "alignment": oracle / "align-dwarfdump" / (name + ".json")}
            for path in paths.values():
                if not path.is_file():
                    raise ValueError(f"Missing corpus input: {path}")
                path.resolve().relative_to(corpus)
            products.append({"repository": repo, "opt": opt, "product": name,
                             **{k: str(v) for k, v in paths.items()},
                             "build_receipt": str(build_path),
                             "build_status": build.get("status"),
                             "build_succeeded": build.get("build_succeeded"),
                             "fail_reason": build.get("fail_reason"),
                             "build_receipts": [path.name for path, _ in receipts],
                             "expected_sha256": product["sha256"],
                             "unstripped_sha256": product["unstripped_sha256"],
                             "uuid": product.get("uuid")})
    if len(products) != expected_count:
        raise ValueError(f"Expected {expected_count} main executables, found {len(products)}")
    return products


def control_products(products):
    controls = []
    for repository in CONTROL_REPOSITORIES:
        matches = [p for p in products if p["repository"] == repository and p["opt"] == "O"]
        if repository == "swift-argument-parser":
            matches = [p for p in matches if p["product"] == "math"]
        if len(matches) != 1:
            raise ValueError(f"Expected one -O control for {repository}")
        controls.append(matches[0])
    return controls


def installed_toolchain():
    commands = {"swift": ["/usr/bin/xcrun", "swift", "--version"],
                "xcode": ["/usr/bin/xcodebuild", "-version"],
                "sdk": ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]}
    return {name: subprocess.run(command, capture_output=True, text=True,
                                 check=True).stdout.strip()
            for name, command in commands.items()}


def process_environment():
    return {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"],
            "MACSCOPE_SSA_LIFTER": "1"}


def cpu_seconds(value):
    days, sep, clock = value.partition("-")
    if not sep:
        clock, days = days, "0"
    total = 0.0
    for part in clock.split(":"):
        total = total * 60 + float(part)
    return int(days) * 86400 + total


def process_cpu_tree(root):
    result = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,time="],
                            capture_output=True, text=True, check=True)
    rows = {}
    for line in result.stdout.splitlines():
        pid, parent, cpu = line.split()
        rows[int(pid)] = (int(parent), cpu_seconds(cpu))
    descendants = {root}
    changed = True
    while changed:
        added = {pid for pid, (parent, _) in rows.items() if parent in descendants}
        changed = not added.issubset(descendants)
        descendants.update(added)
    return {pid: rows[pid][1] for pid in descendants if pid in rows}


def terminate_group(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def capture(app, binary, script, destination, environment, progress_watch,
            timeout=1800, idle_timeout=300):
    """Keep raw output and stop the process tree after bounded CPU inactivity."""
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    stderr_path = destination.with_suffix(".stderr.txt")
    watch_path = destination.with_suffix(".progress.txt")
    sample_path = destination.with_suffix(".sample.txt")
    started = time.monotonic()
    stopped = None
    process = watcher = None
    returncode = None
    error_text = ""
    stage = "app_launch"
    try:
        with destination.open("wb") as stdout, stderr_path.open("wb") as stderr, \
                watch_path.open("wb") as watch:
            process = subprocess.Popen([str(app), "--run-script", str(script), str(binary)],
                                       env=environment, stdout=stdout, stderr=stderr,
                                       start_new_session=True)
            stage = "watchdog"
            watcher = subprocess.Popen(["/bin/zsh", str(progress_watch), str(stderr_path),
                                        str(binary), "5", re.escape(str(Path(app).parents[3]))],
                                       stdout=watch, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            previous_cpu = {}
            last_progress = started
            while process.poll() is None:
                now = time.monotonic()
                current_cpu = process_cpu_tree(process.pid)
                if any(value > previous_cpu.get(pid, 0) for pid, value in current_cpu.items()):
                    last_progress = now
                previous_cpu = current_cpu
                if now - started >= timeout:
                    stopped = "timeout"
                elif now - last_progress >= idle_timeout:
                    stopped = "no_cpu_progress"
                if stopped:
                    with sample_path.open("wb") as sample:
                        subprocess.run(["/usr/bin/sample", str(process.pid), "1"],
                                       stdout=sample, stderr=subprocess.STDOUT, timeout=15,
                                       check=False)
                    terminate_group(process)
                    break
                time.sleep(1)
            returncode = process.wait()
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        error_text = str(error).splitlines()[0] if str(error) else type(error).__name__
        stopped = "launch_error" if stage == "app_launch" else "tooling_error"
    finally:
        if process is not None:
            terminate_group(process)
        if watcher is not None:
            terminate_group(watcher)
    if process is not None:
        returncode = process.returncode
    lines = stderr_path.read_text(errors="replace").splitlines() if stderr_path.exists() else []
    return {"exit_code": returncode, "wall_seconds": round(time.monotonic() - started, 3),
            "first_stderr_line": lines[0] if lines else error_text, "stop_reason": stopped,
            "driver_error": error_text or None,
            "stdout": str(destination), "stderr": str(stderr_path),
            "progress_log": str(watch_path),
            "sample": str(sample_path) if sample_path.exists() else None}


def import_scorer():
    # Isolated Python omits the script directory from sys.path.
    import importlib.util
    spec = importlib.util.spec_from_file_location("swift_scoreboard_score", Path(__file__).with_name("score.py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def run(args):
    corpus, output, app = args.corpus.resolve(), args.output.resolve(), args.app.resolve()
    try:
        output.relative_to(corpus)
    except ValueError:
        pass
    else:
        raise ValueError("Output must be outside the read-only corpus")
    products = discover_products(corpus)
    controls = control_products(products)
    only = args.only
    candidates = [(False, p) for p in products] + [(True, p) for p in controls]
    def identifier(control, product):
        return ("control/" if control else "") + "/".join(
            (product["repository"], product["opt"], product["product"]))
    known = {identifier(control, product) for control, product in candidates}
    unknown = set(only) - known
    if unknown:
        raise ValueError(f"Unknown product identifier(s): {', '.join(sorted(unknown))}")
    selected = [(control, product) for control, product in candidates
                if not only or identifier(control, product) in only]
    environment = process_environment()
    output.mkdir(parents=True, exist_ok=True)
    run_path = output / "run.json"
    script = output / "script.json"
    app_identity = file_identity(app)
    if run_path.exists():
        run_info = read_json(run_path)
        if run_info.get("only", []) != only:
            raise ValueError("Cannot reuse run: changed only")
        for key, expected in (("app_identity", app_identity), ("git_sha", args.git_sha),
                              ("environment", environment), ("products", products)):
            if run_info[key] != expected:
                raise ValueError(f"Cannot reuse run: changed {key}")
    else:
        if args.score_only:
            raise ValueError("Scoring requires an existing run.json")
        run_info = {"schema_version": 1, "app_identity": app_identity,
                    "app_sha256": sha256(app), "git_sha": args.git_sha,
                    "toolchain": installed_toolchain(),
                    "corpus_toolchain": read_json(corpus / "toolchain.json"),
                    "environment": environment, "products": products, "only": only, "analyses": [],
                    "sha_checks": {}, "timeout_seconds": 1800,
                    "no_cpu_progress_seconds": 300, "progress_watch": str(args.progress_watch.resolve())}
        write_json(run_path, run_info)
    if any(a["status"] == "tooling_failed" for a in run_info["analyses"]):
        raise ValueError("Recorded tooling failure requires source repair and operator review before continuing")
    if not script.exists():
        write_json(script, SCRIPT)
    elif read_json(script) != SCRIPT:
        raise ValueError("Existing command script differs")
    scorer = None if args.capture_only else import_scorer()
    receipts = []
    for control, product in selected:
        key = "/".join((product["repository"], product["opt"], product["product"]))
        capture_key = ("control/" if control else "") + key
        previous = next((a for a in run_info["analyses"] if a["key"] == capture_key), None)
        if previous is None and args.score_only:
            continue
        if previous is not None and previous["status"] == "running":
            raise ValueError(f"Interrupted capture requires operator review; not rerunning {capture_key}")
        if previous is None:
            identity = file_identity(product["binary"])
            check = run_info["sha_checks"].get(key)
            if check is None:
                check = {"identity": identity, "method": "manifest_build_metadata",
                         "expected": product["expected_sha256"],
                         "build_receipt": product["build_receipt"], "passed": True}
                run_info["sha_checks"][key] = check
                write_json(run_path, run_info)
            elif check["identity"] != identity:
                raise ValueError(f"Changed stripped input identity: {key}")
            print(f"Capturing {capture_key}", flush=True)
            previous = {"key": capture_key, "repository": product["repository"],
                        "binary": product["product"], "opt": product["opt"],
                        "control": control, "status": "running", "sha_check": check}
            run_info["analyses"].append(previous)
            write_json(run_path, run_info)
            if not check["passed"]:
                previous.update(status="sha_mismatch", exit_code=None, wall_seconds=0,
                                first_stderr_line="Stripped binary SHA-256 differs from build receipt")
            else:
                target = product["twin"] if control else product["binary"]
                folder = output / ("controls" if control else "") / product["repository"] / product["opt"]
                result = capture(app, target, script, folder / (product["product"] + ".functions.json"),
                                 environment, args.progress_watch)
                previous.update(result)
                print(f"Captured {capture_key}: exit {result['exit_code']}, {result['wall_seconds']} seconds", flush=True)
                previous["status"] = ("tooling_failed" if result["stop_reason"] == "tooling_error" else
                                      "captured" if result["exit_code"] == 0 and not result["stop_reason"] else "driver_failed")
            write_json(run_path, run_info)
            if previous["status"] == "tooling_failed":
                return 2
        if scorer is not None and previous["status"] in ("captured", "scored", "score_failed"):
            receipt_path = Path(previous["stdout"]).with_name(product["product"] + ".scoreboard.json")
            if previous["status"] == "scored" and receipt_path.is_file() and not args.rescore:
                receipts.append(read_json(receipt_path))
                continue
            try:
                receipt = scorer.score_capture(previous["stdout"], product["nm"], product["alignment"],
                                               receipt_path, {"binary": product["product"], "opt": product["opt"],
                                                              "control": control, "repository": product["repository"]},
                                               demangle_cache_path=output / product["repository"] / product["opt"] /
                                               (product["product"] + ".demangled.json"))
                receipts.append(receipt)
                previous.update(status="scored", scoreboard=str(receipt_path))
                previous.pop("score_error", None)
            except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
                previous.update(status="score_failed", score_error=str(error))
            write_json(run_path, run_info)
    if scorer is not None:
        scorer.write_aggregate(receipts, output, failures=[a for a in run_info["analyses"]
                                                        if a["status"] not in ("scored",)])
    return 1 if any(a["status"] in ("driver_failed", "sha_mismatch", "score_failed") for a in run_info["analyses"]) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--progress-watch", required=True, type=Path)
    parser.add_argument("--rescore", action="store_true",
                        help="Recompute scores from saved captures after scorer changes; requires --score-only")
    parser.add_argument("--only", action="append", default=[], metavar="IDENTIFIER",
                        help="Capture/score only repo/opt/product; prefix control/ for an unstripped control (repeatable)")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--capture-only", action="store_true")
    modes.add_argument("--score-only", action="store_true")
    args = parser.parse_args()
    if args.rescore and not args.score_only:
        parser.error("--rescore requires --score-only; native captures are never repeated")
    if not re.fullmatch(r"[0-9a-f]{40}", args.git_sha):
        parser.error("--git-sha must be a full 40-character commit SHA")
    if not args.progress_watch.is_file():
        parser.error("--progress-watch must name the existing progress-watch.sh")
    try:
        return run(args)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
