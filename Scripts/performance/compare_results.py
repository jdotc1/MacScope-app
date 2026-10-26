#!/usr/bin/env python3
"""Compare complete controlled runs. Exit 2 means invalid/inconclusive; exit 1 means regression."""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
import hashlib
import math
from pathlib import Path
import random
import statistics

METRICS = ("analyzeMS", "listingPrepareMS", "wireEncodeMS", "wireDecodeMS",
           "totalMS", "cpuMS", "wireBytes", "footprintBytes", "mainQueueDelayP95MS")


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        raise ValueError("No values")
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def load_run(root):
    context = json.loads((root / "context.json").read_text(encoding="utf-8"))
    manifest = json.loads((root / "corpus.json").read_text(encoding="utf-8"))
    if hashlib.sha256((root / "corpus.json").read_bytes()).hexdigest() != context.get("manifestSHA256"):
        raise ValueError("Corpus bytes no longer match the recorded manifest hash")
    if context.get("schemaVersion") != 1 or context.get("status") != "complete":
        raise ValueError("Run is incomplete or unsupported: {}".format(root))
    if manifest.get("schemaVersion") != 1:
        raise ValueError("Unsupported corpus manifest")
    rows = [json.loads(line) for line in (root / "samples.jsonl").read_text(encoding="utf-8").splitlines()
            if line.strip()]
    expected = {item["id"]: item for item in manifest["inputs"]}
    if len(expected) != len(manifest["inputs"]):
        raise ValueError("Duplicate corpus input IDs")
    grouped = defaultdict(list)
    all_grouped = defaultdict(list)
    warmups, measured = manifest["warmupIterations"], manifest["measuredIterations"]
    if not 1 <= warmups <= 5 or not 20 <= measured <= 200:
        raise ValueError("Insufficient or unbounded experiment sample count")
    for row in rows:
        identifier = row.get("inputID")
        if identifier not in expected or row.get("schemaVersion") != 1:
            raise ValueError("Unexpected sample input/schema")
        source = expected[identifier]
        if row.get("runID") != context["runID"] or row.get("inputSHA256") != source["sha256"] \
                or row.get("mode") != source["mode"]:
            raise ValueError("Sample provenance mismatch")
        index = row.get("iteration")
        if type(index) is not int or not 0 <= index < warmups + measured \
                or type(row.get("warmup")) is not bool or row["warmup"] != (index < warmups):
            raise ValueError("Invalid iteration identity")
        for metric in METRICS:
            value = row.get(metric)
            if value is not None and (type(value) not in (int, float) or not math.isfinite(value) or value < 0):
                raise ValueError("Invalid metric {}".format(metric))
        if any(row.get(metric) is None for metric in METRICS[:7]):
            raise ValueError("Missing required timing/size metric")
        all_grouped[identifier].append(row)
        if not row["warmup"]:
            grouped[identifier].append(row)
    for identifier in expected:
        samples = all_grouped[identifier]
        if len(samples) != warmups + measured or {row["iteration"] for row in samples} != set(range(warmups + measured)):
            raise ValueError("Missing or duplicate iterations for " + identifier)
        # No trimming slow results and no silently excluding thermal outliers.
        if any(row.get("thermalState") != 0 or row.get("lowPowerMode") is not False for row in grouped[identifier]):
            raise ValueError("Nominal-power comparison is inconclusive: retain thermal/low-power samples separately")
        fingerprints = {row.get("facetSHA256") for row in samples}
        if len(fingerprints) != 1 or None in fingerprints:
            raise ValueError("Derived semantic facets changed within a run")
        for count in ("instructionCount", "procedureCount", "listingRowCount"):
            if len({row.get(count) for row in samples}) != 1:
                raise ValueError("Output count changed within a run: " + count)
    return context, manifest, dict(grouped)


def bootstrap_ratio(first, second, repeats=2000):
    if not first or not second or statistics.median(first) <= 0:
        return None
    randomizer = random.Random(1729)
    ratios = []
    for _ in range(repeats):
        baseline = statistics.median(randomizer.choices(first, k=len(first)))
        candidate = statistics.median(randomizer.choices(second, k=len(second)))
        if baseline > 0:
            ratios.append(candidate / baseline)
    if not ratios:
        return None
    return [percentile(ratios, 0.025), percentile(ratios, 0.975)]


def compare(first, second):
    baseline, before_manifest, before = first
    candidate, after_manifest, after = second
    for key in ("xcode", "swift", "sdk", "configuration", "testability", "coverage"):
        if baseline["identity"].get(key) != candidate["identity"].get(key):
            raise ValueError("Toolchain/configuration differs: " + key)
    if baseline["identity"].get("configuration") != "Release" or baseline["identity"].get("coverage") is not False:
        raise ValueError("Comparison requires Release with coverage disabled")
    for context in (baseline, candidate):
        settings = context.get("buildSettings", {}).get("MacScopeApp", {})
        if settings.get("SWIFT_OPTIMIZATION_LEVEL") != "-O" or settings.get("ARCHS") != "arm64":
            raise ValueError("Effective app build settings are absent or are not optimized native arm64")
    for key in ("hw.model", "machdep.cpu.brand_string", "hw.memsize", "hw.logicalcpu", "macOSBuild"):
        if baseline["hardware"].get(key) != candidate["hardware"].get(key) or baseline["hardware"].get(key) is None:
            raise ValueError("Hardware/OS identity differs or is absent: " + key)
    if before_manifest != after_manifest or baseline["manifestSHA256"] != candidate["manifestSHA256"]:
        raise ValueError("Corpus manifests differ")
    if set(before) != set(after):
        raise ValueError("Input cohorts differ")
    result = {"schemaVersion": 1, "baselineCommit": baseline["identity"]["sourceCommit"],
              "candidateCommit": candidate["identity"]["sourceCommit"], "inputs": {},
              "hardRegressions": [], "qualificationComplete": False,
              "scope": "Controlled analysis/listing preparation/codec microbenchmarks; installed UI and native worker throughput require their own evidence"}
    for identifier in sorted(before):
        left, right = before[identifier], after[identifier]
        if left[0]["facetSHA256"] != right[0]["facetSHA256"]:
            raise ValueError("Semantic facet mismatch: " + identifier)
        for key in ("instructionCount", "procedureCount", "listingRowCount"):
            if left[0][key] != right[0][key]:
                raise ValueError("Output count mismatch: " + identifier + "/" + key)
        values = {}
        for metric in METRICS:
            left_values = [row[metric] for row in left if row.get(metric) is not None]
            right_values = [row[metric] for row in right if row.get(metric) is not None]
            if not left_values or not right_values:
                values[metric] = {"status": "unmeasured"}
                continue
            before_median, after_median = statistics.median(left_values), statistics.median(right_values)
            before_p95, after_p95 = percentile(left_values, 0.95), percentile(right_values, 0.95)
            ratio = after_median / before_median if before_median > 0 else None
            p95_ratio = after_p95 / before_p95 if before_p95 > 0 else None
            values[metric] = {"baselineP50": before_median, "candidateP50": after_median,
                              "baselineP95": before_p95, "candidateP95": after_p95,
                              "p50Ratio": ratio, "p95Ratio": p95_ratio,
                              "medianRatioBootstrap95": bootstrap_ratio(left_values, right_values),
                              "baselineCount": len(left_values), "candidateCount": len(right_values)}
            # Wall-clock analysis and the synthetic combined benchmark must not regress >10%.
            # Tiny sub-ms operations are reported, not turned into noisy percentage failures.
            if metric in ("analyzeMS", "totalMS") and before_median >= 10 \
                    and (ratio > 1.10 or (p95_ratio is not None and p95_ratio > 1.10)):
                result["hardRegressions"].append(identifier + "/" + metric)
        result["inputs"][identifier] = values
    return result


def markdown(result):
    lines = ["# MacScope performance comparison", "",
             "Baseline: `{}`. Candidate: `{}`.".format(result["baselineCommit"], result["candidateCommit"]), "",
             result["scope"] + ".", "",
             "Ratios are candidate ÷ baseline; values below 1 are faster or smaller. No samples were trimmed.", ""]
    for identifier, metrics in result["inputs"].items():
        lines += ["## " + identifier, "", "| Metric | Baseline p50 | Candidate p50 | p50 ratio | p95 ratio |",
                  "|---|---:|---:|---:|---:|"]
        for name, value in metrics.items():
            if value.get("status") == "unmeasured":
                lines.append("| {} | Unmeasured | Unmeasured | — | — |".format(name))
            else:
                ratio = "—" if value["p50Ratio"] is None else "{:.3f}".format(value["p50Ratio"])
                p95 = "—" if value["p95Ratio"] is None else "{:.3f}".format(value["p95Ratio"])
                lines.append("| {} | {:.3f} | {:.3f} | {} | {} |".format(
                    name, value["baselineP50"], value["candidateP50"], ratio, p95))
        lines.append("")
    lines += ["## Decision", "",
              "Regression gate: " + ("FAIL — " + ", ".join(result["hardRegressions"]) if result["hardRegressions"] else "PASS for measured cohorts"), "",
              "This report does not complete the installed UI, worker-isolation, persistence, memory-pressure or energy qualification gates.", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = compare(load_run(args.baseline), load_run(args.candidate))
    except (ValueError, KeyError, OSError, TypeError) as error:
        parser.exit(2, "INCONCLUSIVE: {}\n".format(error))
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "comparison.json").write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
    (args.output / "comparison.md").write_text(markdown(result))
    raise SystemExit(1 if result["hardRegressions"] else 0)


if __name__ == "__main__":
    main()
