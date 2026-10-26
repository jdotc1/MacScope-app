#!/usr/bin/env python3
"""Compare runtime witnesses, static census witnesses and DWARF sizes per image.

Usage: compare_three.py <run-folder> --out <directory>

Reads <run>/receipts/run.json, the oracle receipts, the census receipts
grouped by <run>/census/<group>/inputs.txt, and the DWARF row files. Writes
one compare-<name>.json per image, crossbuild.json and summary-tables.md in
the output directory, and scoreboard.csv and disagreements.csv beside it.
A run's receipt path and the run document's census_run_dir/dwarf_run_dir
can reference retained receipts directly; those inputs are read only.
"""

import argparse
import csv
import importlib.util
import json
from pathlib import Path


HERE = Path(__file__).resolve().parent


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


static_tool = load_module("compare_static")
layout_tool = load_module("layout_v0")

WITNESS = ("size", "stride", "alignment", "extraInhabitantCount")
# Cross-build pairs: (project, product, first opt, second opt).
CROSS_BUILD = (
    ("sample-app", "SampleApp", "O", "Osize"),
    ("sample_tool", "SampleTool", "O", "Osize"),
    ("sample-kit", "SampleKit", "O", "Osize"),
    ("swift-collections", "collections-client", "O", "Osize"),
    ("swift-argument-parser", "math", "O", "Osize"),
    ("sample-framework", "SampleFramework", "O", "O-resilient"),
)


def read_json(path):
    path = Path(path)
    return json.loads(path.read_text()) if path.exists() else None


def census_index(run_dir):
    """Map (mode, absolute input path) to the census receipt path, if written."""
    index = {}
    for inputs in sorted((Path(run_dir) / "census").glob("*/inputs.txt")):
        group = inputs.parent.name
        mode = "unstripped" if "unstripped" in group else "stripped"
        for line in inputs.read_text().splitlines():
            if not line.strip():
                continue
            receipt = Path(run_dir) / "receipts" / "census" / group / (
                "census-" + Path(line).stem + ".json")
            index[(mode, line)] = receipt
    return index


def top_rows(oracle):
    return [row for row in oracle.get("types", []) if "vwt" in row and row.get("mangled")]


def key_of(row):
    mangled = row.get("mangled")
    return mangled[2:] if mangled and mangled.startswith("$s") else mangled


def runtime_section(oracle):
    summary = oracle.get("summary", {})
    reasons = {}
    for row in oracle.get("unanswered", []):
        reasons[row.get("reason", "unknown")] = reasons.get(row.get("reason", "unknown"), 0) + 1
    rows = top_rows(oracle)
    concrete = [row for row in rows if row.get("metadataVA") is not None]
    return {"status": oracle.get("status"), "askable": summary.get("askable"),
            "answered": summary.get("answered"), "dependent": summary.get("dependent"),
            "rate": summary.get("rate"), "unanswered": reasons,
            "answeredTypeRows": len(rows), "concreteTypes": len(concrete),
            "externalRows": len(rows) - len(concrete)}


def static_section(oracle, census):
    result = static_tool.compare_static(oracle, census)
    if result.get("status") == "pending":
        return {"status": "pending", "reason": result["reason"]}
    census_rows = static_tool.unique_index(census["valueWitnesses"], "metadataAddress", static_tool.integer)
    for row in result["types"]:
        if census_rows[row["metadataVA"]].get("isIncomplete"):
            row["status"] = "incomplete"
    summary = {key: result[key] for key in ("joined", "oracleOnly", "staticOnly")}
    for status in ("agree", "disagree"):
        summary[status] = sum(row["status"] == status for row in result["types"])
    summary["incompleteJoined"] = sum(row["status"] == "incomplete" for row in result["types"])
    summary["types"] = result["types"]
    summary["runtimeOnly"] = summary.pop("oracleOnly")
    summary["status"] = "complete"
    summary["staticWitnesses"] = len(census["valueWitnesses"])
    summary["incomplete"] = sum(1 for row in census["valueWitnesses"] if row.get("isIncomplete"))
    summary["diagnosticCountsValueWitness"] = census.get("diagnosticCounts", {}).get("valueWitness")
    summary["disagreements"] = [row for row in result["types"] if row["status"] == "disagree"]
    return summary


def dwarf_section(oracle, dwarf_rows):
    if dwarf_rows is None:
        return {"status": "no-debug-info"}
    sizes = {}
    for row in dwarf_rows:
        sizes.setdefault(row["mangled"], set()).add(row["byteSize"])
    by_kind = {}
    disagreements = []
    seen = set()
    for row in top_rows(oracle):
        key = key_of(row)
        if key not in sizes or key in seen:
            continue
        seen.add(key)
        kind = by_kind.setdefault(row.get("kind", "unknown"), {"joined": 0, "agree": 0, "disagree": 0})
        kind["joined"] += 1
        if sizes[key] == {row["vwt"]["size"]}:
            kind["agree"] += 1
        else:
            kind["disagree"] += 1
            disagreements.append({"mangled": key, "kind": row.get("kind"),
                                  "runtime": row["vwt"]["size"], "dwarf": sorted(sizes[key])})
    return {"status": "complete", "dwarfRows": len(dwarf_rows), "dwarfTypes": len(sizes),
            "joined": sum(v["joined"] for v in by_kind.values()),
            "agree": sum(v["agree"] for v in by_kind.values()),
            "disagree": len(disagreements), "byKind": by_kind,
            "disagreements": disagreements}


def engine_section(oracle):
    report = layout_tool.compare_layouts(oracle)
    section = {key: report[key] for key in
               ("computable", "agree", "disagree", "unsupported", "unresolved", "rate")}
    section["disagreements"] = [row for row in report["types"] if row["status"] == "disagree"]
    return section


def compare_image(run, oracle, census_pair, dwarf_rows):
    result = {"name": run["name"], "image": run["image"], "opt": run["opt"],
              "product": run["product"]}
    if oracle is None or oracle.get("status") != "ok":
        result["runtime"] = {"status": "failed" if oracle else "missing",
                             "reason": run.get("reason")}
        result["dwarfRows"] = None if dwarf_rows is None else len(dwarf_rows)
        return result
    result["runtime"] = runtime_section(oracle)
    unstripped, stripped = census_pair
    result["staticUnstripped"] = static_section(oracle, unstripped)
    result["staticStripped"] = static_section(oracle, stripped)
    reach = None
    joined_unstripped = result["staticUnstripped"].get("joined")
    joined_stripped = result["staticStripped"].get("joined")
    if joined_unstripped:
        reach = (joined_stripped or 0) / joined_unstripped
    result["symbolFreeReach"] = reach
    result["dwarf"] = dwarf_section(oracle, dwarf_rows)
    result["engine"] = engine_section(oracle)
    return result


def cross_build(results, oracles):
    reports = []
    for project, product, first, second in CROSS_BUILD:
        names = ["{}-{}-{}".format(project, opt, product) for opt in (first, second)]
        report = {"image": project, "product": product, "builds": [first, second]}
        pair = [oracles.get(name) for name in names]
        if any(item is None or item.get("status") != "ok" for item in pair):
            report["status"] = "unavailable"
            report["reason"] = "no oracle receipt for: " + ", ".join(
                n for n, item in zip(names, pair) if item is None or item.get("status") != "ok")
        else:
            left = {}
            right = {}
            for table, document in ((left, pair[0]), (right, pair[1])):
                for row in top_rows(document):
                    table.setdefault(key_of(row), row)
            joined = sorted(left.keys() & right.keys())
            differing = []
            for key in joined:
                a = static_tool.witness_values(left[key])
                b = static_tool.witness_values(right[key])
                changes = {field: [a.get(field), b.get(field)] for field in WITNESS
                           if a.get(field) != b.get(field)}
                if changes:
                    differing.append({"mangled": key, "kind": left[key].get("kind"),
                                      "differences": changes})
            report.update(status="complete", joined=len(joined),
                          equal=len(joined) - len(differing), differing=differing,
                          onlyFirst=len(left.keys() - right.keys()),
                          onlySecond=len(right.keys() - left.keys()))
        for opt, name in zip((first, second), names):
            item = results.get(name, {})
            report[opt] = {"staticIncompleteStripped": item.get("staticStripped", {}).get("incomplete"),
                           "symbolFreeReach": item.get("symbolFreeReach")}
        reports.append(report)
    return reports


def scoreboard_rows(results, crossbuilds):
    rows = []

    def add(item, measure, numerator, denominator):
        rows.append([item["image"] + "/" + item["product"], item["opt"], measure, numerator, denominator])

    for item in results.values():
        runtime = item["runtime"]
        if runtime["status"] in ("failed", "missing"):
            continue
        add(item, "rt_answered", runtime["answered"], runtime["askable"])
        add(item, "rt_concrete", runtime["concreteTypes"], runtime["answeredTypeRows"])
        for label in ("Unstripped", "Stripped"):
            section = item["static" + label]
            low = label.lower()
            if section["status"] == "pending":
                continue
            add(item, "static_joined_" + low, section["joined"], runtime["concreteTypes"])
            add(item, "static_incomplete_joined_" + low, section["incompleteJoined"], section["joined"])
            add(item, "static_agree_" + low, section["agree"],
                section["joined"] - section["incompleteJoined"])
            if label == "Stripped":
                add(item, "static_incomplete_stripped", section["incomplete"], section["staticWitnesses"])
        reach = item["symbolFreeReach"]
        if reach is not None:
            add(item, "symbol_free_reach", item["staticStripped"].get("joined", 0),
                item["staticUnstripped"]["joined"])
        if item["dwarf"]["status"] == "complete":
            add(item, "dwarf_joined", item["dwarf"]["joined"], runtime["answeredTypeRows"])
            add(item, "dwarf_agree", item["dwarf"]["agree"], item["dwarf"]["joined"])
        add(item, "engine_agree", item["engine"]["agree"], item["engine"]["computable"])
    for report in crossbuilds:
        if report["status"] != "complete":
            continue
        rows.append([report["image"] + "/" + report["product"], report["builds"][0] + "->" + report["builds"][1],
                     "xbuild_equal", report["equal"], report["joined"]])
    return rows


def dwarf_size_map(rows):
    sizes = {}
    for row in rows or []:
        sizes.setdefault(row["mangled"], set()).add(row["byteSize"])
    return sizes


def disagreement_rows(results, oracles, crossbuilds, dwarf_run_dir):
    rows = []
    for name, item in results.items():
        if "dwarf" not in item:
            continue
        index = {row.get("metadataVA"): row for row in top_rows(oracles[name])
                 if row.get("metadataVA") is not None}
        dwarf_sizes = dwarf_size_map(read_json(Path(dwarf_run_dir) / "receipts" / "dwarf" / (name + ".json")))
        for label in ("Unstripped", "Stripped"):
            for entry in item["static" + label].get("disagreements", []):
                row = index.get(entry["metadataVA"], {})
                for field, values in entry["differences"].items():
                    rows.append([item["image"] + "/" + item["product"], item["opt"], row.get("mangled", ""),
                                 row.get("kind", ""), "static-" + label.lower() + "." + field,
                                 values["oracle"], values["static"],
                                 ";".join(str(v) for v in sorted(dwarf_sizes.get(key_of(row), ())))])
        for entry in item["dwarf"].get("disagreements", []):
            rows.append([item["image"] + "/" + item["product"], item["opt"], entry["mangled"], entry["kind"],
                         "dwarf.size", entry["runtime"], "", ";".join(str(v) for v in entry["dwarf"])])
        for entry in item["engine"]["disagreements"]:
            for change in entry["differences"]:
                rows.append([item["image"] + "/" + item["product"], item["opt"], entry.get("mangled", ""),
                             entry.get("kind", ""), "engine." + change["field"], change["oracle"],
                             change["computed"], ""])
    for report in crossbuilds:
        for entry in report.get("differing", []):
            for field, (first, second) in entry["differences"].items():
                rows.append([report["image"] + "/" + report["product"], "/".join(report["builds"]),
                             entry["mangled"], entry["kind"], "xbuild." + field, first, second, ""])
    return rows


def fraction(numerator, denominator):
    return "{}/{}".format(numerator, denominator)


def tables(results, runs, crossbuilds, disagreements, csv_name):
    lines = ["Table 1: per image (compare-<name>.json; n/d)", "",
             "| image | opt | rt_answered | rt_concrete | static joined (unstripped) | incomplete joined (unstripped) | static agree (unstripped) | "
             "static joined (stripped) | incomplete joined (stripped) | static agree (stripped) | reach | incomplete (stripped) | "
             "dwarf joined | dwarf agree | engine agree |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    failures = []
    for run in runs:
        item = results.get(run["name"])
        if item is None or item["runtime"]["status"] in ("failed", "missing"):
            failures.append(run)
            continue
        runtime = item["runtime"]
        su, ss, dw, en = item["staticUnstripped"], item["staticStripped"], item["dwarf"], item["engine"]

        def pair(section, key, denominator):
            return "pending" if section["status"] == "pending" else fraction(section[key], denominator)
        reach = item["symbolFreeReach"]
        lines.append("| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
            item["image"] + "/" + item["product"], item["opt"],
            fraction(runtime["answered"], runtime["askable"]),
            fraction(runtime["concreteTypes"], runtime["answeredTypeRows"]),
            pair(su, "joined", runtime["concreteTypes"]), pair(su, "incompleteJoined", su.get("joined")),
            pair(su, "agree", su.get("joined", 0) - su.get("incompleteJoined", 0)),
            pair(ss, "joined", runtime["concreteTypes"]), pair(ss, "incompleteJoined", ss.get("joined")),
            pair(ss, "agree", ss.get("joined", 0) - ss.get("incompleteJoined", 0)),
            "n/a" if reach is None else "{:.3f}".format(reach),
            "pending" if ss["status"] == "pending" else fraction(ss["incomplete"], ss["staticWitnesses"]),
            "none" if dw["status"] != "complete" else fraction(dw["joined"], runtime["answeredTypeRows"]),
            "none" if dw["status"] != "complete" else fraction(dw["agree"], dw["joined"]),
            fraction(en["agree"], en["computable"])))
    lines += ["", "Table 2: load failures and timeouts (run.json, oracle receipt)", "",
              "| image | opt | outcome | reason |", "|---|---|---|---|"]
    for run in failures:
        lines.append("| {} | {} | {} | {} |".format(run["image"] + "/" + run["product"], run["opt"],
                                                     run.get("outcome", "failed"),
                                                     str(run.get("reason", "")).replace("\n", " ").replace("|", "/")[:240]))
    lines += ["", "Table 3: disagreements ({} rows; all in {})".format(len(disagreements), csv_name), ""]
    if len(disagreements) <= 200:
        lines += ["| image | opt | mangled | kind | field | runtime | static | dwarf |", "|---|---|---|---|---|---|---|---|"]
        for row in disagreements:
            lines.append("| " + " | ".join(str(v).replace("|", "/") for v in row) + " |")
    lines += ["", "Table 4: cross-build (crossbuild.json)", "",
              "| image | builds | joined | equal | differing | only first | only second | static incomplete (stripped) | symbol-free reach |",
              "|---|---|---|---|---|---|---|---|---|"]
    for report in crossbuilds:
        first, second = report["builds"]
        incomplete = "{} / {}".format(report[first]["staticIncompleteStripped"], report[second]["staticIncompleteStripped"])
        reach = " / ".join("n/a" if report[o]["symbolFreeReach"] is None else "{:.3f}".format(report[o]["symbolFreeReach"])
                           for o in (first, second))
        if report["status"] != "complete":
            lines.append("| {}/{} | {} vs {} | unavailable: {} | | | | | {} | {} |".format(
                report["image"], report["product"], first, second, report["reason"], incomplete, reach))
        else:
            lines.append("| {}/{} | {} vs {} | {} | {} | {} | {} | {} | {} | {} |".format(
                report["image"], report["product"], first, second, report["joined"], report["equal"],
                len(report["differing"]), report["onlyFirst"], report["onlySecond"], incomplete, reach))
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    run_dir = args.run_dir
    run_document = read_json(run_dir / "receipts" / "run.json")
    index = census_index(run_document.get("census_run_dir", run_dir))
    dwarf_run_dir = Path(run_document.get("dwarf_run_dir", run_dir))
    results, oracles = {}, {}
    for run in run_document["runs"]:
        oracle = read_json(run.get("receipt", run_dir / "receipts" / "oracle" / (run["name"] + ".json")))
        dwarf_rows = read_json(dwarf_run_dir / "receipts" / "dwarf" / (run["name"] + ".json"))
        pair = []
        for mode, path in (("unstripped", run["path"] + ".unstripped"), ("stripped", run["path"])):
            receipt = index.get((mode, path))
            pair.append(read_json(receipt) if receipt else None)
        try:
            item = compare_image(run, oracle, pair, dwarf_rows)
        except ValueError as error:
            print("STOP: {} {}".format(run["name"], error))
            return 2
        results[run["name"]] = item
        if oracle is not None:
            oracles[run["name"]] = oracle
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / ("compare-" + run["name"] + ".json")).write_text(
            json.dumps(item, indent=2, sort_keys=True) + "\n")
    crossbuilds = cross_build(results, oracles)
    (args.out / "crossbuild.json").write_text(json.dumps(crossbuilds, indent=2, sort_keys=True) + "\n")
    scoreboard = scoreboard_rows(results, crossbuilds)
    with open(args.out.parent / "scoreboard.csv", "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["image", "opt", "measure", "numerator", "denominator"])
        writer.writerows(scoreboard)
    disagreements = disagreement_rows(results, oracles, crossbuilds, dwarf_run_dir)
    with open(args.out.parent / "disagreements.csv", "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["image", "opt", "mangled", "kind", "field", "runtime", "static", "dwarf"])
        writer.writerows(disagreements)
    (args.out / "summary-tables.md").write_text(
        tables(results, run_document["runs"], crossbuilds, disagreements, "receipts/disagreements.csv"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
