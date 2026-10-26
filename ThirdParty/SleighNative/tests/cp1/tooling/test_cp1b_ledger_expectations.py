#!/usr/bin/env python3
"""Check CP1b admission expectations, historical receipts, and raw Linux lifts.

Raw one-instruction p-code is not native-provider admission evidence. This test
does not change ledgers or use the old RX18 opaque-helper effect assumptions.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys

WORDS = {
    "c0020200": ("MOVAZ_Z_RZA_B", "movaz z0.b, za0h.b[w12, 0]", 0xC0020200, 0xFFFF1E00, "movaz_z_rza.xml#L75"),
    "25231057": ("WHILEGT_P_P_RR__", "whilegt p7.b, x2, x3", 0x25200010, 0xFF20EC10, "whilegt_p_p_rr.xml#L38"),
}
VARIANTS = {"le": "AARCH64.sla", "be": "AARCH64BE.sla", "apple": "AARCH64_AppleSilicon.sla"}
FILES = ("RX18_VALIDATION.json", "T21_NATIVE_VALIDATION.json", "tests/rx18_feature_vectors.json")
PIN = "836d4cab97342d7eb22d51648757ae51608a5572"


def normal(text):
    # Existing SLEIGH syntax retains an optional # on numeric immediates.
    # Normalize only that marker; register names and numeric values stay exact.
    text = re.sub(r"(?<![a-z0-9_])#(?=(?:0x[0-9a-f]+|[0-9]+)\b)", "", text.lower())
    text = re.sub(r"(?<![a-z0-9])0x([0-9a-f]+)", lambda m: str(int(m[1], 16)), text.lower())
    return re.sub(r"\s+", "", text)


def verify_expectations(repo, before_dir, baseline_repo=None):
    import copy
    assert normal("movaz z0.b, za0h.b[w12, #0x0]") == normal("movaz z0.b, za0h.b[w12, 0]")
    assert normal("movaz z0.b, za0h.b[w12, #0x1]") != normal("movaz z0.b, za0h.b[w12, 0]")
    assert normal("movaz z0x0.b, za0h.b[w12, #0x0]") != normal("movaz z0.b, za0h.b[w12, 0]")
    assert normal("whilegt p0x7.b, x2, x3") != normal("whilegt p7.b, x2, x3")
    assert normal("movaz z0.b, za0h.b[w#12, 0]") != normal("movaz z0.b, za0h.b[w12, 0]")
    root = repo / "ThirdParty/SleighNative"
    documents = {name: json.loads((root / name).read_text()) for name in FILES}
    originals = {}
    for name, value in documents.items():
        assert "cp1b" in value, f"{name}: CP1b current expectations/provenance missing"
        metadata = value["cp1b"]
        source = (before_dir / name).read_bytes()
        originals[name] = json.loads(source)
        assert metadata["sourceRevision"] == "910b72e19"
        assert metadata["originalFileSHA256"] == hashlib.sha256(source).hexdigest(), f"{name}: before-receipt hash changed"
        assert metadata["originalReceipt"] == "receipts/ledgers-before/" + name
        assert metadata["nativeAcceptance"] == "not_executed_in_cp1b_linux"
        if baseline_repo is not None:
            assert source == (baseline_repo / "ThirdParty/SleighNative" / name).read_bytes(), f"{name}: before receipt lost original bytes"

    fixture = documents[FILES[2]]
    assert len(fixture["rows"]) == 133
    assert len({row["word"] for row in fixture["rows"]}) == 121
    assert len(fixture["reserved"]) == 11
    assert len({row["word"] for row in fixture["rows"]} | set(fixture["reserved"])) == 132
    assert fixture["expectedStillFailClosed"] == {}
    for word, (form, assembly, base, mask, xml) in WORDS.items():
        assert word not in fixture["reserved"], f"{word}: valid opcode remains reserved"
        rows = [row for row in fixture["rows"] if row["word"] == word]
        assert len(rows) == 1, f"{word}: require exactly one allocated fixture"
        assert normal(rows[0]["expected"]) == normal(assembly)
        assert rows[0]["arm_xml"].endswith(xml) and PIN in rows[0]["arm_xml"]
        assert int(word, 16) & mask == base

    rx18, t21 = documents[FILES[0]], documents[FILES[1]]
    for ledger in (rx18, t21):
        assert set(ledger["cp1b"]["currentExpectations"]) == set(WORDS)
        for word, (form, assembly, base, mask, xml) in WORDS.items():
            row = ledger["cp1b"]["currentExpectations"][word]
            assert row["kind"] == "allocated"
            assert row["expectedNativeOutcome"] == "admitted"
            assert row["expectedPcodeStatus"] == "normal_path"
            assert row["form"] == form
            assert row["nativeObservation"] == "pending_mac_governed_recompile_and_acceptance"
            assert row["arm_xml"].endswith(xml) and PIN in row["arm_xml"]
            assert row["encoding"] == {"base": f"0x{base:08x}", "mask": f"0x{mask:08x}"}
            assert normal(row["assembly"]) == normal(assembly)
    assert rx18["expectedStillFailClosed"] == {}
    rows = [row for row in rx18["resultTable"] if row["word"] in WORDS]
    assert len(rx18["resultTable"]) == len(originals[FILES[0]]["resultTable"])
    assert {(row["variant"], row["word"]) for row in rows} == {(variant, word) for variant in VARIANTS for word in WORDS}
    assert len(rows) == 6
    for row in rows:
        assert row["status"] == "expected_admission"
        assert row["expectedPcodeStatus"] == "normal_path"
        assert row["observedNativeOutcome"] is None
        assert row["historicalObservation"]["status"] == "still_fail_closed"

    functions = [row for configuration in t21["remainingConfigurations"] for row in configuration["functions"] if len(row["words"]) == 1 and row["words"][0] in WORDS]
    assert len(functions) == 2
    for row in functions:
        assert row["expected"] == "admitted"
        assert row["kind"] == "allocated"
        assert row["actual"] == row["historicalObservation"]["actual"] == "provider_rejected"
        assert row["nativeRecord"] == row["historicalObservation"]["nativeRecord"]
        assert row["observationScope"] == "Historical T21 observation; CP1b native acceptance is pending."
        assert row["historicalExpectation"]["expected"] == "provider_rejection"
    assert t21["cp1b"]["currentPreparedSet"] == {"rows": 133, "uniqueAllocatedWords": 121, "reservedGuards": 11}

    # Reconstruct every original document from current rows plus local history.
    # Exact equality checks all unaffected fields, rows, counters and diagnostics.
    recovered = copy.deepcopy(documents)
    recovered[FILES[0]]["expectedStillFailClosed"] = rx18["cp1b"]["historicalExpectedStillFailClosed"]
    recovered[FILES[0]]["resultTable"] = [row["historicalObservation"] if row["word"] in WORDS else row for row in recovered[FILES[0]]["resultTable"]]
    for configuration in recovered[FILES[1]]["remainingConfigurations"]:
        for row in configuration["functions"]:
            if len(row["words"]) == 1 and row["words"][0] in WORDS:
                row.update(row.pop("historicalExpectation"))
                row.pop("historicalObservation")
                row.pop("observationScope")
    restored_fixture = recovered[FILES[2]]
    restored_fixture["rows"] = [row["historicalExpectation"] if row["word"] == "25231057" else row for row in restored_fixture["rows"] if row["word"] != "c0020200"]
    restored_fixture["reserved"] = fixture["cp1b"]["historicalReserved"]
    restored_fixture["expectedStillFailClosed"] = fixture["cp1b"]["historicalExpectedStillFailClosed"]
    for name, value in recovered.items():
        value.pop("cp1b")
        assert value == originals[name], f"{name}: unrelated content or historical observation changed"

    cp1 = json.loads((root / "tests/cp1/sme-decoder-vectors.json").read_text())
    if baseline_repo is not None:
        assert (root / "tests/cp1/sme-decoder-vectors.json").read_bytes() == (baseline_repo / "ThirdParty/SleighNative/tests/cp1/sme-decoder-vectors.json").read_bytes(), "CP1 oracle was altered"
    catalogue = {row["instruction"]: row for row in cp1["catalogue"]}
    for word, (form, assembly, base, mask, xml) in WORDS.items():
        assert catalogue[form]["encoding"]["base"] == f"0x{base:08x}"
        assert catalogue[form]["encoding"]["mask"] == f"0x{mask:08x}"
        assert any(row["instruction"] == form and row["encoding"] == "0x" + word and "outcome" not in row["expected"] for row in cp1["vectors"])
        assert not any(row["encoding"] == "0x" + word for row in cp1["reserved_vectors"])
    return {"status": "PASS", "files": list(FILES), "historyPreserved": "Byte-exact before receipts; reversible per-row changes; all unaffected fields/rows equal", "baselineComparison": baseline_repo is not None}


def verify_lifts(lifter, resources):
    results = []
    for variant, filename in VARIANTS.items():
        sla = resources / filename
        command = [str(lifter.resolve()), "batch", str(sla.resolve()), "-s", str((resources / "AARCH64.pspec").resolve())]
        completed = subprocess.run(command, input="".join(int(word, 16).to_bytes(4, "little").hex() + "\n" for word in WORDS), capture_output=True, text=True, check=True)
        rows = [json.loads(line) for line in completed.stdout.splitlines()]
        assert len(rows) == 2
        for word, row in zip(WORDS, rows):
            assert row["bytes"] == int(word, 16).to_bytes(4, "little").hex()
            assert row["decoded"] and not row["error"], (variant, word, row["error"])
            text = row["mnemonic"] + " " + row["body"]
            assert normal(text) == normal(WORDS[word][1]), (variant, word, text)
            assert row["pcode"].strip(), (variant, word, "missing p-code")
            ops = [line.split(" = ", 1)[-1].split()[0] for line in row["pcode"].splitlines() if line.strip()]
            assert not set(ops) & {"BRANCH", "CBRANCH", "BRANCHIND", "CALL", "CALLIND", "RETURN", "CALLOTHER"}, (variant, word, "p-code is not a branch-free explicit normal path")
            results.append({"variant": variant, "word": word, "status": "PASS", "scope": "Raw one-instruction Linux SLEIGH lift; not native provider admission or numerical execution", "command": command, "slaSHA256": hashlib.sha256(sla.read_bytes()).hexdigest(), "opCount": len(ops), "pcodeSHA256": hashlib.sha256(row["pcode"].encode()).hexdigest(), **row})
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=pathlib.Path)
    parser.add_argument("--baseline-repo", type=pathlib.Path)
    parser.add_argument("--before-dir", required=True, type=pathlib.Path)
    parser.add_argument("--lifter", type=pathlib.Path)
    parser.add_argument("--resources", type=pathlib.Path)
    parser.add_argument("--expectations-only", action="store_true", help="Static ledger/history checks only; no claim that raw lifts ran")
    parser.add_argument("--report", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if not args.expectations_only and (args.lifter is None or args.resources is None):
        parser.error("--lifter and --resources are required unless --expectations-only is explicit")
    report = {"scope": "CP1b corrected expectations and historical preservation; no native admission claim", "command": sys.argv, "status": "FAIL", "liftsExecuted": False, "results": []}
    try:
        report["ledgerChecks"] = verify_expectations(args.repo, args.before_dir, args.baseline_repo)
        if not args.expectations_only:
            report["results"] = verify_lifts(args.lifter, args.resources)
            report["liftsExecuted"] = True
        report["status"] = "PASS"
    except Exception as error:
        report["failure"] = f"{type(error).__name__}: {error}"
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "results"}, indent=2))
    return int(report["status"] != "PASS")


if __name__ == "__main__":
    raise SystemExit(main())
