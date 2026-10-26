"""Address-deduplicated function discovery and naming measurements."""

import bisect
import csv
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import threading


DEMANGLE_TIMEOUT_SECONDS = 120


def _classifier():
    path = Path(__file__).with_name("classify.py")
    spec = importlib.util.spec_from_file_location("swift_scoreboard_classify", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def address(value):
    if isinstance(value, bool):
        raise ValueError("Boolean is not an address")
    if isinstance(value, int):
        result = value
    elif isinstance(value, str):
        result = int(value, 16) if value.lower().startswith("0x") else int(value)
    else:
        raise ValueError("Missing or invalid address: {!r}".format(value))
    if result < 0:
        raise ValueError("Negative address")
    return result


def is_generated_name(name):
    """Mirror FunctionVersionFingerprinting.isGeneratedName at the source pin."""
    return (name in ("", "_entry", "__text") or
            re.fullmatch(r"(?:sub_|loc_|unk_|off_|nullsub_)(?:0[xX])?[0-9a-fA-F]+", name)
            is not None)


def parse_nm(text):
    rows = []
    for line in text.splitlines():
        match = re.match(r"^\s*([0-9a-fA-F]{16})\s+(\S)\s+(.+?)\s*$", line)
        if match:
            rows.append((int(match[1], 16), match[2], match[3]))
    return rows


def demangle_names(raw_names):
    """One installed-toolchain batch; unchanged lines retain their raw spelling."""
    names = sorted(set(raw_names))
    if not names:
        return {}
    output = _run_demangler("\n".join(names) + "\n")
    lines = output.splitlines()
    if len(lines) != len(names):
        raise ValueError("swift-demangle returned {} lines for {} names".format(len(lines), len(names)))
    return dict(zip(names, lines))


def _run_demangler(payload):
    """Drain output while a dedicated writer feeds stdin, with a hard deadline."""
    command = ["xcrun", "swift-demangle", "--compact"]
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True) as process:
        stdin = process.stdin
        # communicate owns only the output streams; the writer owns stdin.
        process.stdin = None
        errors = []

        def feed():
            try:
                with stdin:
                    stdin.write(payload)
            except BrokenPipeError:
                pass  # The exit status or missing-line check reports early closure.
            except Exception as error:
                errors.append(error)

        writer = threading.Thread(target=feed, name="demangle-input")
        writer.start()
        try:
            stdout, stderr = process.communicate(timeout=DEMANGLE_TIMEOUT_SECONDS)
        except BaseException:
            process.kill()
            process.communicate()
            raise
        finally:
            writer.join()
        if errors:
            raise errors[0]
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, command, stdout, stderr)
        return stdout


def normalized_name(raw, spellings):
    """Normalize the scripting surface's raw symbol or user-supplied name."""
    if raw.startswith(("_$s", "$s", "_$S", "$S", "_T0", "_$e")):
        if raw not in spellings:
            raise ValueError("Missing demangled spelling for {!r}".format(raw))
        return spellings[raw]
    return raw[1:] if raw.startswith("_") else raw


def parse_capture(driver_output):
    """The CLI emits one result array for each of the four requested commands."""
    if not isinstance(driver_output, list) or len(driver_output) != 4:
        raise ValueError("Expected four CLI results: sections, functions, symbols, exports")
    for command, rows in zip(("sections", "functions", "symbols", "exports"), driver_output):
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise ValueError("{} result must be an array of rows".format(command))
    sections, functions, _, _ = driver_output
    text_sections = [row for row in sections
                     if re.split(r"[.,]", row.get("originalName", row.get("name", "")))[-1] == "__text"]
    if len(text_sections) != 1:
        raise ValueError("Expected exactly one __text section; found {}".format(len(text_sections)))
    start = address(text_sections[0]["address"])
    end = start + address(text_sections[0]["size"])
    return (start, end), functions


def _fraction(numerator, denominator):
    return {"numerator": numerator, "denominator": denominator}


def score_binary(driver_output, nm_text, alignment, demangled_by_raw, *, binary, opt, control=False):
    text_range, functions = parse_capture(driver_output)
    start, end = text_range
    nm_rows = parse_nm(nm_text)
    truth = {addr for addr, kind, _ in nm_rows if kind in ("T", "t") and start <= addr < end}
    extents = {}
    dwarf_names = {}
    if not isinstance(alignment, dict) or not isinstance(alignment.get("functions"), list):
        raise ValueError("Alignment must contain a functions array")
    for row in alignment["functions"]:
        if row.get("low_pc") is None:
            continue
        low = address(row["low_pc"])
        if not start <= low < end:
            continue
        high = address(row.get("high_pc"))
        if high < low:
            raise ValueError("DWARF high_pc precedes low_pc at {}".format(hex(low)))
        if low in extents and extents[low] != high:
            raise ValueError("Conflicting DWARF high_pc values at {}".format(hex(low)))
        extents[low] = high
        dwarf_names.setdefault(low, set()).update(
            value for value in (row.get("linkage_name"), row.get("name")) if value)
        truth.add(low)
    ordered = sorted(truth)
    following = {addr: ordered[index + 1] if index + 1 < len(ordered) else end
                 for index, addr in enumerate(ordered)}
    names = {addr: set() for addr in truth}
    for addr, _, name in nm_rows:
        if addr in names:
            names[addr].add(name)
    classifier = _classifier()
    classify = classifier.classify_demangled
    expected, class_sets, flags = {}, {}, {}
    for addr in ordered:
        extents.setdefault(addr, following[addr])
        expected[addr], class_sets[addr] = set(), set()
        flags[addr] = {"merged": False, "specialised": False}
        for raw in sorted(names[addr]):
            if raw not in demangled_by_raw:
                raise ValueError("Missing demangled spelling for {!r}".format(raw))
            spelling = demangled_by_raw[raw]
            expected[addr].add(normalized_name(raw, demangled_by_raw))
            result = classify(spelling, raw_name=raw)
            class_sets[addr].add(result["class"])
            for flag in flags[addr]:
                flags[addr][flag] |= result[flag]
    actual = {}
    for row in functions:
        addr = address(row.get("address"))
        if not start <= addr < end:
            continue
        if not isinstance(row.get("name"), str):
            raise ValueError("Function at {} has no display name".format(hex(addr)))
        value = {"name": row["name"], "end": address(row.get("end"))}
        if addr in actual and actual[addr] != value:
            raise ValueError("Conflicting app function rows at {}".format(hex(addr)))
        actual[addr] = value
    found = set(actual) & truth
    given = {addr for addr in found if not is_generated_name(actual[addr]["name"])}
    normalized = {addr: normalized_name(actual[addr]["name"], demangled_by_raw) for addr in found}
    exact = {addr for addr in found if normalized[addr] in expected[addr]}
    raw_exact = {addr for addr in found if actual[addr]["name"] in names[addr]}
    wrong = given - exact

    def truth_row(addr):
        return {"address": hex(addr), "twin_names": sorted(names[addr]),
                "dwarf_names": sorted(dwarf_names.get(addr, ())),
                "expected_spellings": sorted(expected[addr]), "expected_end": hex(extents[addr]),
                "classes": sorted(class_sets[addr]), **flags[addr]}

    def name_row(addr):
        return {**truth_row(addr), "app_name": actual[addr]["name"],
                "app_name_normalized": normalized[addr]}

    metrics = {
        "fn_start_recall": _fraction(len(found), len(truth)),
        "fn_start_precision": _fraction(len(found), len(actual)),
        "fn_extent_exact": _fraction(sum(actual[a]["end"] == extents[a] for a in found), len(found)),
        "fn_extent_within": _fraction(sum(actual[a]["end"] <= following[a] for a in found), len(found)),
        "name_given": _fraction(len(given), len(found)),
        "name_exact": _fraction(len(exact), len(found)),
        "name_raw_exact": _fraction(len(raw_exact), len(found)),
        "name_wrong": _fraction(len(wrong), len(found)),
    }
    classes = {}
    for class_name in sorted(set().union(*class_sets.values()) if class_sets else set()):
        members = {a for a in truth if class_name in class_sets[a]}
        reached = found & members
        missing = members - found
        classes[class_name] = {
            "class_census": _fraction(len(members), len(truth)),
            "merged": sum(flags[a]["merged"] for a in members),
            "specialised": sum(flags[a]["specialised"] for a in members),
            "fn_start_recall": _fraction(len(reached), len(members)),
            "name_given": _fraction(len(given & members), len(reached)),
            "name_exact": _fraction(len(exact & members), len(reached)),
            "unreached_" + class_name: _fraction(len(missing), len(members)),
            "unreached": [truth_row(a) for a in sorted(missing)[:500]],
            "unreached_list_truncated": len(missing) > 500,
        }
    extras = []
    # Prefix maxima handle overlapping DWARF extents without scanning every function per extra.
    prefix_max = []
    for addr in ordered:
        prefix_max.append(max(extents[addr], prefix_max[-1] if prefix_max else 0))
    for addr in sorted(set(actual) - truth):
        index = bisect.bisect_left(ordered, addr)
        neighbors = ordered[max(0, index - 1):index + 1]
        nearest = min(neighbors, key=lambda candidate: (abs(candidate - addr), candidate)) if neighbors else None
        split = index > 0 and addr < prefix_max[index - 1]
        extras.append({"address": hex(addr), "app_name": actual[addr]["name"],
                       "nearest_twin_address": hex(nearest) if nearest is not None else None,
                       "inside_twin_extent": split, "placement": "split" if split else "gap"})
    return {
        "schema_version": 2, "binary": binary, "opt": opt, "control": bool(control),
        "text": {"start": hex(start), "end": hex(end)}, "metrics": metrics, "classes": classes,
        "ground_truth": [truth_row(a) for a in ordered],
        "extra_starts": extras, "name_wrong": [name_row(a) for a in sorted(wrong)],
        "name_exact_misses": [name_row(a) for a in sorted(found - exact)],
        "fn_start_recall_misses": [truth_row(a) for a in sorted(truth - found)],
        "other_names": [truth_row(a) for a in ordered if "other" in class_sets[a]],
        "addresses_without_twin_names": [truth_row(a) for a in ordered if not names[a]],
    }


def write_receipt(receipt, scoreboard_path, unreached_path):
    scoreboard_path, unreached_path = Path(scoreboard_path), Path(unreached_path)
    scoreboard_path.parent.mkdir(parents=True, exist_ok=True)
    scoreboard_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    with unreached_path.open("w") as stream:
        stream.write("class\taddress\ttwin_names\tdwarf_names\n")
        for row in receipt["fn_start_recall_misses"]:
            for class_name in row["classes"] or ["(no twin name)"]:
                stream.write("{}\t{}\t{}\t{}\n".format(
                    class_name, row["address"], json.dumps(row["twin_names"]), json.dumps(row["dwarf_names"])))


def score_capture(capture_path, nm_path, alignment_path, output_path, metadata, *, demangle_cache_path=None):
    nm_text = Path(nm_path).read_text()
    capture = json.loads(Path(capture_path).read_text())
    _, functions = parse_capture(capture)
    raw_names = {name for _, _, name in parse_nm(nm_text)}
    batch_names = raw_names | {row["name"] for row in functions}
    cache = Path(demangle_cache_path) if demangle_cache_path is not None else None
    if cache is not None and cache.exists():
        spellings = json.loads(cache.read_text())
        if not isinstance(spellings, dict) or not raw_names.issubset(spellings) or any(
                not isinstance(value, str) for value in spellings.values()):
            raise ValueError("Demangle cache does not match the nm name set")
    else:
        spellings = {}
    missing = batch_names - spellings.keys()
    if missing:
        spellings.update(demangle_names(missing))
        if cache is not None:
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(json.dumps(spellings, indent=2, sort_keys=True) + "\n")
    receipt = score_binary(
        capture, nm_text,
        json.loads(Path(alignment_path).read_text()), spellings,
        binary=metadata["binary"], opt=metadata["opt"], control=metadata.get("control", False))
    if "repository" in metadata:
        receipt["repository"] = metadata["repository"]
    output_path = Path(output_path)
    basename = output_path.name.removesuffix(".scoreboard.json")
    write_receipt(receipt, output_path, output_path.with_name(basename + ".unreached.txt"))
    return receipt


def _percent(metric):
    n, d = metric["numerator"], metric["denominator"]
    return "{}/{} ({:.2f}%)".format(n, d, 100 * n / d) if d else "0/0 (n/a)"


def _cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def write_aggregate(receipts, output_dir, failures=None):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    mains = [r for r in receipts if not r["control"]]
    controls = [r for r in receipts if r["control"]]
    failures = failures or []
    with (output_dir / "scoreboard.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(("binary", "opt", "class", "measure", "numerator", "denominator"))
        for receipt in receipts:
            label = receipt["binary"] + (" (unstripped control)" if receipt["control"] else "")
            for measure, count in receipt["metrics"].items():
                writer.writerow((label, receipt["opt"], "all", measure, count["numerator"], count["denominator"]))
            for class_name, measures in receipt["classes"].items():
                for measure, count in measures.items():
                    if isinstance(count, dict) and "numerator" in count:
                        writer.writerow((label, receipt["opt"], class_name, measure,
                                         count["numerator"], count["denominator"]))
                for flag in ("merged", "specialised"):
                    writer.writerow((label, receipt["opt"], class_name, flag, measures[flag],
                                     measures["class_census"]["numerator"]))
        for failure in failures:
            label = failure.get("binary", failure.get("product", "unknown"))
            if failure.get("control"):
                label += " (unstripped control)"
            writer.writerow((label, failure.get("opt", ""), "all", "unavailable", "", ""))
    lines = ["# Swift function scoreboard", "", "Ratios use unique addresses; aliases accept any expected spelling. "
             "Class memberships may overlap, so class totals are not additive.", ""]
    measures = ("fn_start_recall", "fn_start_precision", "fn_extent_exact", "name_given", "name_exact", "name_raw_exact")
    lines.append("{} scored of {} mains; {} controls scored.".format(
        len(mains), len(mains) + sum(not f.get("control") for f in failures), len(controls)))
    lines.append("")

    def binary_table(title, rows, control=False):
        lines.extend([title, "", "| Binary | Opt | " + " | ".join(measures) + " |",
                      "| --- | --- | " + " | ".join(["---"] * len(measures)) + " |"])
        for receipt in rows:
            lines.append("| {} | {} | {} |".format(_cell(receipt["binary"]), _cell(receipt["opt"]),
                         " | ".join(_percent(receipt["metrics"][m]) for m in measures)))
        failed = [f for f in failures if bool(f.get("control")) == control]
        for failure in failed:
            lines.append("| {} | {} | {} |".format(
                _cell(failure.get("binary", failure.get("product", "unknown"))),
                _cell(failure.get("opt", "")), " | ".join([failure.get("unavailable_reason", "unavailable")] * len(measures))))
        if not rows and not failed:
            lines.append("| No completed captures | — | " + " | ".join(["—"] * len(measures)) + " |")
        lines.append("")

    binary_table("## Stripped mains", mains)
    lines.extend(["## Classes across stripped mains", "",
                  "| Class | Twin addresses | Found | Named | Exact | Merged | Specialised |",
                  "| --- | --- | --- | --- | --- | --- | --- |"])
    for class_name in sorted({name for r in mains for name in r["classes"]}):
        rows = [r["classes"][class_name] for r in mains if class_name in r["classes"]]
        counts = [sum(r[m]["numerator"] for r in rows)
                  for m in ("class_census", "fn_start_recall", "name_given", "name_exact")]
        counts.extend(sum(r[flag] for r in rows) for flag in ("merged", "specialised"))
        lines.append("| {} | {} |".format(_cell(class_name), " | ".join(map(str, counts))))
    lines.append("")
    binary_table("## Unstripped sanity controls", controls, control=True)
    lines.append("Every control name mismatch and missing start is retained in its JSON receipt. "
                 "No acceptance floor is applied to these measurements.")
    if failures:
        lines.extend(["", "## Unavailable captures", ""])
        for failure in failures:
            lines.append("- " + _cell(json.dumps(failure, sort_keys=True)))
    (output_dir / "SUMMARY.md").write_text("\n".join(lines) + "\n")
