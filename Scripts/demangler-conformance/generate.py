#!/usr/bin/env python3
"""Bounded Swift compiler/oracle capture; never reads system binaries.

`capture` compiles only the three adjacent samples into a NEW external directory.
`fixture` reuses that capture without invoking the compiler or oracle again.
"""
import argparse
import json
from pathlib import Path
import subprocess

SAMPLES = ("Samples", "WeakLibrary", "WeakUse")
KINDS = ["generics", "associated-types", "primary-associated-types", "existentials",
         "closures-and-captures", "async", "throws", "typed-throws", "property-wrappers",
         "result-builders", "macro-expansions", "parameter-packs", "opaque-types", "actors",
         "distributed-actors", "objc-bridging", "has-symbol"]


def symbols_from_inventory(directory):
    symbols = {}
    other = {}
    for sample in SAMPLES:
        for raw in (directory / (sample + "-nm.txt")).read_text().splitlines():
            # nm preserves Mach-O's global underscore and LLVM's local `l_` prefix.
            # Keep local Hn/Hc/Hr/HF records: selecting globals alone loses these.
            if raw.startswith(("_$s", "_$S")):
                canonical = raw[1:]
            elif raw.startswith(("l_$s", "l_$S")):
                canonical = raw[2:]
            else:
                kind = ("symbolic-metadata-label" if raw.startswith("_symbolic ") else
                        "objc-runtime-record" if "_Tt" in raw or raw.startswith("_OBJC_") else
                        "embedded-symbol-reference" if "$s" in raw else
                        "unmangled-runtime-or-local-label")
                other.setdefault(kind, []).append({"object": sample + ".o", "name": raw})
                continue
            symbols.setdefault(canonical, []).append({"object": sample + ".o", "nmName": raw})
    if not symbols or len(symbols) > 2000:
        raise ValueError("empty or unbounded sample inventory")
    return symbols, other


def oracle_rows(text):
    rows = {}
    for block in text.split("Demangling for ")[1:]:
        lines = block.splitlines()
        symbol = lines[0]
        # --expand emits a structured tree followed by its canonical display line.
        tree = [line for line in lines[1:] if line.lstrip().startswith("kind=")]
        rendered = [line for line in lines[1:] if line and not line.lstrip().startswith("kind=")]
        if not tree or len(rendered) != 1 or rendered[0] == symbol:
            raise ValueError("oracle could not demangle " + symbol)
        if symbol in rows and rows[symbol] != rendered[0]:
            raise ValueError("conflicting oracle rows for " + symbol)
        rows[symbol] = rendered[0]
    return rows


def capture(directory):
    # Owner policy forbids implicit repeated compilation/oracle verification. Existing evidence is
    # consumed with `fixture`; callers must select a new capture for genuinely changed inputs.
    directory.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[2]
    compiler = subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).strip()
    commands = []
    for sample in SAMPLES:
        module = "ConformanceSamples" if sample == "Samples" else sample
        command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-emit-object",
                   "-module-name", module, "Scripts/demangler-conformance/" + sample + ".swift",
                   "-o", str(directory / (sample + ".o"))]
        if sample == "WeakLibrary":
            command += ["-emit-module", "-emit-module-path", str(directory / "WeakLibrary.swiftmodule")]
        if sample == "WeakUse":
            command += ["-I", str(directory)]
        commands.append(command)
        result = subprocess.run(command, cwd=root, text=True, capture_output=True)
        (directory / (sample + "-compile.log")).write_text(result.stdout + result.stderr)
        result.check_returncode()
        inventory = subprocess.check_output(["xcrun", "nm", "-j", str(directory / (sample + ".o"))], text=True)
        (directory / (sample + "-nm.txt")).write_text(inventory)
    symbols, _ = symbols_from_inventory(directory)
    oracle = subprocess.check_output(["xcrun", "swift-demangle", "--expand"],
                                     input="\n".join(sorted(symbols)) + "\n", text=True)
    (directory / "oracle-expand.txt").write_text(oracle)
    (directory / "capture.json").write_text(json.dumps({"compiler": compiler, "commands": commands}, indent=2) + "\n")


def fixture(directory, output):
    inventory, excluded = symbols_from_inventory(directory)
    oracle = {}
    for path in sorted(directory.glob("oracle*expand.txt")):
        for symbol, expected in oracle_rows(path.read_text()).items():
            if symbol in oracle and oracle[symbol] != expected:
                raise ValueError("conflicting oracle captures for " + symbol)
            oracle[symbol] = expected
    missing = set(inventory) - set(oracle)
    if missing:
        raise ValueError("missing oracle for " + repr(sorted(missing)))
    capture_metadata = json.loads((directory / "capture.json").read_text())
    value = {"schemaVersion": 1, "compiler": capture_metadata["compiler"], "sampleKinds": KINDS,
             "scope": "Every global and local stable Swift symbol in the three sample object symbol tables, including undefined references. No system binary input.",
             "comparison": "Exact canonical final line from swift-demangle --expand; the tree is retained in the external capture. No whitespace normalization or guessed expectations.",
             "symbols": [{"mangled": symbol, "expected": oracle[symbol], "origins": inventory[symbol]}
                         for symbol in sorted(inventory)],
             "otherObjectRecords": excluded}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    print(f"Wrote {len(inventory)} compiler/oracle pairs; retained {sum(map(len, excluded.values()))} non-stable records by category.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    capture_args = sub.add_parser("capture")
    capture_args.add_argument("--output-dir", type=Path, required=True)
    fixture_args = sub.add_parser("fixture")
    fixture_args.add_argument("--capture-dir", type=Path, required=True)
    fixture_args.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "capture":
        capture(args.output_dir.resolve())
    else:
        fixture(args.capture_dir.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
