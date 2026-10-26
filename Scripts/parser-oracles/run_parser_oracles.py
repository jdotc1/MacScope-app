#!/usr/bin/env python3
"""Produce or verify normalized parser-oracle goldens (RX-03).

One command:

    Scripts/parser-oracles/run_parser_oracles.py --write    # regenerate goldens/
    Scripts/parser-oracles/run_parser_oracles.py --check    # prove goldens are current

The oracles are the same natively built engines the analysis worker links
(vendored LIEF 1.0.0, pe-parse 2.1.1 and go-macho 1.1.283 behind MacScope's C
bridge), reached through the bridge's developer CLI, plus Apple's dyld_info for
the host dyld shared cache. The runner first stages the engines from the shared
content-addressed dependency cache (Scripts/dependencies/build_parser_engines.py
stage; a no-op when nothing changed, a one-time build on a new pin or toolchain).
It never downloads anything.

For every fixture in fixtures.json each oracle's output is normalized into
MacScope's closed fact schema (normalize.py); agreement and disagreement between
oracles are recorded; one canonical JSON golden per fixture binds the input by
SHA-256 and every engine by version, revision and vendored source-tree SHA-256.

Specimens are never executed: each is copied into a private scratch directory
without execute permission and passed only as a data argument to a verified
oracle program; any other program, or a specimen as program, is refused. Oracles
run with an empty HOME, a minimal PATH, no stdin, a deadline and an output bound.
Standard library only; Python 3.9 compatible.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import normalize  # noqa: E402
import oracle_toolkit as toolkit  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from work_root import work_root as macscope_work_root  # noqa: E402

ORACLE_DIR = toolkit.ORACLE_DIR
ROOT = toolkit.ROOT
FIXTURES_PATH = ORACLE_DIR / "fixtures.json"
GOLDEN_DIR = ORACLE_DIR / "goldens"
GOLDEN_SCHEMA = "macscope.parser-oracle-golden.v2"
BUILDER = ROOT / "Scripts/dependencies/build_parser_engines.py"
TOOL_TIMEOUT_SECONDS = 180
MAX_TOOL_OUTPUT_BYTES = 64 * 1024 * 1024
SPECIMEN_PLACEHOLDER = "<specimen>"
DUMP_PLACEHOLDER = "<macscope-parser-dump>"
DEFAULT_CACHE_ROOT = macscope_work_root() / "MacScopeQualificationCache-20260920"
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


class OracleRunError(RuntimeError):
    pass


def load_fixtures() -> List[Dict[str, Any]]:
    document = json.loads(FIXTURES_PATH.read_text(encoding="utf-8"))
    if document.get("schema") != "macscope.parser-oracle-fixtures.v1":
        raise OracleRunError("unexpected fixtures.json schema")
    fixtures = document["fixtures"]
    identifiers = [fixture["id"] for fixture in fixtures]
    if len(identifiers) != len(set(identifiers)):
        raise OracleRunError("fixture ids must be unique")
    return fixtures


def golden_path(fixture_id: str) -> Path:
    return GOLDEN_DIR / f"{fixture_id}.json"


def default_engines_root() -> Path:
    worktree = hashlib.sha256(str(ROOT).encode("utf-8")).hexdigest()[:12]
    return toolkit.environment_root(
        "MACSCOPE_PARSER_ENGINES_STAGE",
        macscope_work_root() / "MacScopeParserEngines.noindex" / f"stage-{worktree}",
    )


def stage_engines(engines_root: Path, cache_root: Path) -> Dict[str, Any]:
    completed = subprocess.run(
        ["/usr/bin/python3", "-B", str(BUILDER), "stage", "--destination", str(engines_root),
         "--cache-root", str(cache_root)],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=7200,
    )
    if completed.returncode != 0:
        raise OracleRunError(f"parser-engine staging failed:\n{completed.stderr[-4000:]}")
    return json.loads((engines_root / "STAGED.json").read_text(encoding="utf-8"))


# --- tools -----------------------------------------------------------------

class Toolset:
    """The verified oracle programs and their machine-independent golden identities."""

    def __init__(self, engines_root: Path, needed: Sequence[str]):
        lock = toolkit.load_lock()
        self.programs: Dict[str, str] = {}
        self.identities: Dict[str, Dict[str, Any]] = {}
        engine_ids = toolkit.engine_identities()
        dump = engines_root / lock["bridge"]["dump"]
        for name in sorted(set(needed)):
            if name == "dyld_info":
                path = lock["platform_tools"]["dyld_info"]["path"]
                if not Path(path).is_file():
                    raise OracleRunError("Apple dyld_info is not available on this host")
                self.programs[name] = path
                self.identities[name] = {
                    "oracle": name, "kind": "platform-tool",
                    "executable_sha256": toolkit.sha256_file(Path(path)),
                    "macos": macos_identity(),
                }
            elif name in lock["engines"]:
                if not dump.is_file():
                    raise OracleRunError(f"bridge dump CLI is not staged at {dump}")
                self.programs[name] = str(dump)
                self.identities[name] = engine_ids[name]
            else:
                raise OracleRunError(f"unknown oracle {name}")

    def assert_safe(self, argv: Sequence[str], data_paths: Sequence[str], staged_paths: Sequence[str]) -> None:
        assert_safe_argv(argv, self.programs.values(), data_paths, staged_paths)


def assert_safe_argv(argv: Sequence[str], programs, data_paths: Sequence[str],
                     staged_paths: Sequence[str] = ()) -> None:
    """Refuse anything but a verified oracle program; a specimen is only ever data.

    `data_paths` are inputs that must never be the program (the read-only host
    dyld cache). `staged_paths` are the runner's private specimen copies, which
    must also carry no execute permission.
    """
    if not argv:
        raise OracleRunError("empty oracle command")
    program = argv[0]
    if program not in set(programs):
        raise OracleRunError(f"refusing to run unverified program: {program}")
    for path in list(data_paths) + list(staged_paths):
        if os.path.realpath(program) == os.path.realpath(path):
            raise OracleRunError("refusing to execute a specimen")
    for path in staged_paths:
        mode = os.stat(path).st_mode
        if not stat.S_ISREG(mode) or mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH):
            raise OracleRunError(f"specimen copy is not an inert regular file: {path}")


def macos_identity() -> Dict[str, str]:
    result: Dict[str, str] = {}
    for key, flag in (("product_version", "-productVersion"), ("build_version", "-buildVersion")):
        completed = subprocess.run(["/usr/bin/sw_vers", flag], capture_output=True, text=True,
                                   timeout=30, stdin=subprocess.DEVNULL)
        result[key] = completed.stdout.strip()
    return result


# --- invocation ----------------------------------------------------------

def stage_specimen(source: Path, scratch: Path) -> Path:
    """Copy the specimen bytes to a private, non-executable file."""
    staged = scratch / f"specimen-{toolkit.sha256_file(source)[:16]}.bin"
    if staged.exists():
        staged.chmod(0o600)
        staged.unlink()
    with source.open("rb") as reader, staged.open("wb") as writer:
        shutil.copyfileobj(reader, writer)
    staged.chmod(0o444)
    return staged


def invoke(tools: Toolset, argv: List[str], scratch: Path, data_paths: Sequence[str] = (),
           staged_paths: Sequence[str] = ()) -> Tuple[int, str, str]:
    tools.assert_safe(argv, data_paths, staged_paths)
    home = scratch / "home"
    home.mkdir(exist_ok=True)
    environment = {"HOME": str(home), "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
                   "NO_COLOR": "1", "TMPDIR": str(scratch)}
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=environment, cwd=str(scratch))
    buffers: Dict[str, bytearray] = {"stdout": bytearray(), "stderr": bytearray()}
    overflow = threading.Event()

    def drain(name: str, stream) -> None:
        # Read both pipes concurrently so the child can never block on a full pipe;
        # kill it once the fixed output bound is crossed.
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            buffers[name] += chunk
            if len(buffers[name]) > MAX_TOOL_OUTPUT_BYTES:
                overflow.set()
                process.kill()
                break

    readers = [threading.Thread(target=drain, args=(name, getattr(process, name)), daemon=True)
               for name in ("stdout", "stderr")]
    for reader in readers:
        reader.start()
    try:
        process.wait(timeout=TOOL_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise OracleRunError(f"{Path(argv[0]).name} exceeded the {TOOL_TIMEOUT_SECONDS}s deadline")
    finally:
        for reader in readers:
            reader.join()
    if overflow.is_set():
        raise OracleRunError(f"{Path(argv[0]).name} output exceeds the fixed bound")
    return (process.returncode, buffers["stdout"].decode("utf-8", "replace"),
            buffers["stderr"].decode("utf-8", "replace"))


def tool_error(stdout: str, stderr: str) -> str:
    lines = [_ANSI.sub("", line).strip() for line in (stderr + "\n" + stdout).splitlines()]
    lines = [line for line in lines if line]
    return normalize.bounded(lines[-1] if lines else "no diagnostic")


def result(oracle: str, selection: Optional[str], command: List[str], status: str,
           error: Optional[str] = None, facts: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    return {"oracle": oracle, "selection": selection, "command": command, "status": status,
            "error": error, "facts": facts}


def engine_document(tools: Toolset, oracle: str, format_name: str, specimen: Path,
                    scratch: Path) -> Tuple[List[str], Dict[str, Any]]:
    argv = [tools.programs[oracle], oracle, format_name, str(specimen)]
    shown = [DUMP_PLACEHOLDER, oracle, format_name, SPECIMEN_PLACEHOLDER]
    code, out, err = invoke(tools, argv, scratch, staged_paths=[str(specimen)])
    if code != 0:
        return shown, {"status": "rejected", "error": tool_error(out, err)}
    try:
        return shown, json.loads(out)
    except ValueError:
        return shown, {"status": "rejected", "error": "engine output is not JSON"}


def run_macho(tools: Toolset, fixture: Dict[str, Any], specimen: Path, scratch: Path) -> List[Dict[str, Any]]:
    results: List[Dict[str, Any]] = []
    for oracle in fixture["oracles"]:
        shown, raw = engine_document(tools, oracle, "macho", specimen, scratch)
        slices = []
        if raw.get("status") == "parsed":
            slices = [normalize.normalize_raw_macho_slice(item) for item in raw.get("slices") or []]
        for selection in fixture["selections"]:
            if raw.get("status") != "parsed":
                results.append(result(oracle, selection, shown, "rejected", normalize.bounded(raw.get("error", ""))))
                continue
            chosen = [item for item in slices if selection is None or item["arch"] == selection]
            if selection is None and len(slices) != 1:
                chosen = []
            if len(chosen) != 1:
                results.append(result(oracle, selection, shown, "rejected", "selection not present"))
            else:
                results.append(result(oracle, selection, shown, "parsed", facts=chosen[0]))
    return results


def run_pe(tools: Toolset, fixture: Dict[str, Any], specimen: Path, scratch: Path) -> List[Dict[str, Any]]:
    results: List[Dict[str, Any]] = []
    for oracle in fixture["oracles"]:
        shown, raw = engine_document(tools, oracle, "pe", specimen, scratch)
        if raw.get("status") == "parsed":
            results.append(result(oracle, None, shown, "parsed", facts=normalize.normalize_pe(raw)))
        else:
            results.append(result(oracle, None, shown, "rejected", normalize.bounded(raw.get("error", ""))))
    return results


def run_dyld(tools: Toolset, fixture: Dict[str, Any], scratch: Path) -> List[Dict[str, Any]]:
    image = fixture["image"]
    argv = [tools.programs["dyld_info"], "-platform", "-segments", "-dependents", image]
    code, out, err = invoke(tools, argv, scratch, data_paths=[fixture["cache"]])
    shown = ["<dyld_info>"] + argv[1:]
    if code != 0:
        return [result("dyld_info", "image", shown, "rejected", tool_error(out, err))]
    return [result("dyld_info", "image", shown, "parsed", facts=normalize.normalize_dyld_info(out))]


# --- agreement -----------------------------------------------------------

def agreement(fixture: Dict[str, Any], results: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    selections: List[Optional[str]] = []
    for item in results:
        if item["selection"] not in selections:
            selections.append(item["selection"])
    entries = []
    for selection in selections:
        group = [item for item in results if item["selection"] == selection]
        statuses = {item["oracle"]: item["status"] for item in group}
        entry: Dict[str, Any] = {"selection": selection, "statuses": statuses,
                                 "status_agree": len(set(statuses.values())) == 1}
        parsed = [item for item in group if item["status"] == "parsed"]
        if len(parsed) >= 2:
            views = {item["oracle"]: item["facts"] for item in parsed}
            keys = [set(view) for view in views.values()]
            common = set.intersection(*keys)
            entry["agreed"] = sorted(
                key for key in common
                if len({json.dumps(view[key], sort_keys=True) for view in views.values()}) == 1
            )
            entry["disagreed"] = {
                key: {oracle: view[key] for oracle, view in sorted(views.items())}
                for key in sorted(common) if key not in entry["agreed"]
            }
            entry["single_oracle_facts"] = sorted(set.union(*keys) - common)
        entries.append(entry)
    return entries


# --- goldens -------------------------------------------------------------

def host_cache_identity(cache: str) -> List[Dict[str, Any]]:
    base = Path(cache)
    files = sorted(path for path in base.parent.iterdir()
                   if path.name == base.name or path.name.startswith(base.name + "."))
    return [{"name": path.name, "size": path.stat().st_size, "sha256": toolkit.sha256_file(path)} for path in files]


def build_golden(tools: Toolset, fixture: Dict[str, Any], scratch: Path) -> Dict[str, Any]:
    description = {key: fixture[key] for key in ("id", "format", "classification", "provenance", "consumers", "selections")}
    if fixture["format"] == "dyld":
        input_identity: Dict[str, Any] = {
            "host_bound": True, "cache": fixture["cache"], "image": fixture["image"],
            "cache_files": host_cache_identity(fixture["cache"]), "macos": macos_identity(),
        }
        results = run_dyld(tools, fixture, scratch)
    else:
        source = ROOT / fixture["path"]
        input_identity = {"host_bound": False, "path": fixture["path"], "size": source.stat().st_size,
                          "sha256": toolkit.sha256_file(source)}
        specimen = stage_specimen(source, scratch)
        runner = run_macho if fixture["format"] == "macho" else run_pe
        results = runner(tools, fixture, specimen, scratch)
    return {
        "schema": GOLDEN_SCHEMA,
        "fixture": description,
        "input": input_identity,
        "tools": [tools.identities[name] for name in sorted(set(fixture["oracles"]))],
        "results": results,
        "agreement": agreement(fixture, results),
    }


def run_type_inventories(engines_root: Path, fixtures: List[Dict[str, Any]], *, write: bool) -> int:
    # Consume the completed stage receipt; do not re-hash unchanged vendored sources.
    from types import SimpleNamespace
    dump = str(engines_root / "parser-engine-bridge/bin/macscope-parser-dump")
    stage = json.loads((engines_root / "STAGED.json").read_text())
    tools = SimpleNamespace(programs={"go-macho": dump},
                            assert_safe=lambda argv, data, staged: assert_safe_argv(argv, [dump], data, staged))
    failures = []
    scratch_root = engines_root / "type-oracle-scratch"
    scratch_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch_root) as temporary:
        scratch = Path(temporary)
        for fixture in fixtures:
            source = ROOT / fixture["path"]
            data = source.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            specimen = scratch / (fixture["id"] + ".bin")
            specimen.write_bytes(data)
            specimen.chmod(0o444)
            _, document = engine_document(tools, "go-macho", "types", specimen, scratch)
            if document.get("status") not in ("parsed", "partial"):
                raise OracleRunError(f"{fixture['id']}: {document}")
            golden = {"schema": "macscope.type-inventory-golden.v1", "fixture": fixture,
                      "engineKey": stage["keys"]["parser-engine-go-macho"],
                      "input": {"sha256": digest, "size": len(data)}, "inventory": document}
            payload = toolkit.canonical_json_bytes(golden)
            path = golden_path(fixture["id"])
            if write:
                path.write_bytes(payload)
                print(f"wrote {path.relative_to(ROOT)}")
            elif not path.is_file() or path.read_bytes() != payload:
                failures.append(fixture["id"])
    if failures:
        raise OracleRunError("changed type inventories: " + ", ".join(failures))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="regenerate goldens/")
    mode.add_argument("--check", action="store_true", help="fail when a golden differs from a fresh run")
    parser.add_argument("--engines-root", type=Path, default=default_engines_root(),
                        help="staged parser-engine root (default: $MACSCOPE_PARSER_ENGINES_STAGE or a per-worktree .noindex root)")
    parser.add_argument("--cache-root", type=Path,
                        default=toolkit.environment_root("MACSCOPE_DEPENDENCY_CACHE_ROOT", DEFAULT_CACHE_ROOT),
                        help="shared content-addressed dependency cache")
    parser.add_argument("--no-stage", action="store_true", help="use --engines-root as already staged")
    parser.add_argument("--only", action="append", default=[], help="limit to fixture id (repeatable)")
    parser.add_argument("--skip-host", action="store_true", help="skip host-bound dyld fixtures")
    parser.add_argument("--type-inventory", action="store_true", help="only the three K1 metadata specimens; requires --no-stage")
    parser.add_argument("--receipt", type=Path, help="write a run receipt (timings, engine cache keys) here")
    args = parser.parse_args(argv)
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise OracleRunError("the parser engines are built for Apple-Silicon macOS")
    engines_root = toolkit.require_external(args.engines_root)
    fixtures = [fixture for fixture in load_fixtures()
                if (fixture["format"] == "type-inventory") == args.type_inventory
                and (not args.only or fixture["id"] in args.only)]
    if args.type_inventory:
        unknown = sorted(set(args.only) - {fixture["id"] for fixture in fixtures})
        if unknown or not fixtures:
            raise OracleRunError("unknown or empty type inventory selection: " + ", ".join(unknown))
        if not args.no_stage:
            raise OracleRunError("type inventory requires --no-stage and the once-built archive")
        return run_type_inventories(engines_root, fixtures, write=args.write)
    if args.skip_host:
        fixtures = [fixture for fixture in fixtures if not fixture.get("host_bound")]
    unknown = sorted(set(args.only) - {fixture["id"] for fixture in fixtures})
    if unknown:
        raise OracleRunError(f"unknown fixture id(s): {', '.join(unknown)}")
    started = time.monotonic()
    staged = {} if args.no_stage else stage_engines(engines_root, toolkit.require_external(args.cache_root))
    stage_seconds = round(time.monotonic() - started, 3)
    tools = Toolset(engines_root, [oracle for fixture in fixtures for oracle in fixture["oracles"]])
    failures: List[str] = []
    stale_host: List[str] = []
    timings: Dict[str, float] = {}
    GOLDEN_DIR.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="macscope-parser-oracles-") as scratch_name:
        scratch = Path(scratch_name)
        scratch.chmod(0o700)
        for fixture in fixtures:
            begun = time.monotonic()
            payload = toolkit.canonical_json_bytes(build_golden(tools, fixture, scratch))
            timings[fixture["id"]] = round(time.monotonic() - begun, 3)
            path = golden_path(fixture["id"])
            if args.write:
                path.write_bytes(payload)
                print(f"wrote {path.relative_to(ROOT)} ({timings[fixture['id']]}s)")
                continue
            if path.is_file() and path.read_bytes() == payload:
                print(f"ok    {fixture['id']} ({timings[fixture['id']]}s)")
                continue
            if fixture.get("host_bound") and path.is_file():
                committed = json.loads(path.read_text(encoding="utf-8"))
                current = json.loads(payload)
                if committed["input"]["cache_files"] != current["input"]["cache_files"]:
                    stale_host.append(fixture["id"])
                    print(f"stale {fixture['id']}: host dyld cache changed "
                          f"({committed['input']['macos']} -> {current['input']['macos']})")
                    continue
            failures.append(fixture["id"])
            print(f"FAIL  {fixture['id']}: golden differs from a fresh oracle run", file=sys.stderr)
    if args.receipt:
        args.receipt.write_bytes(toolkit.canonical_json_bytes({
            "schema": "macscope.parser-oracle-run.v2", "mode": "write" if args.write else "check",
            "fixtures": [fixture["id"] for fixture in fixtures], "timings_seconds": timings,
            "stage_seconds": stage_seconds, "engine_cache_keys": staged.get("keys", {}),
            "failures": failures, "stale_host": stale_host, "completed_unix": int(time.time()),
        }))
    if failures:
        return 1
    print(f"{len(fixtures)} fixture(s) {'written' if args.write else 'verified'} (engine staging {stage_seconds}s)"
          + (f"; {len(stale_host)} host-bound golden(s) stale" if stale_host else ""))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OracleRunError, toolkit.OracleToolkitError, normalize.NormalizationError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
