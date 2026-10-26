#!/usr/bin/env python3
"""Compare a first struct-layout calculation with runtime witness records."""

import argparse
import json
from pathlib import Path


METRICS = (
    "size", "stride", "alignment", "isPOD", "isBitwiseTakable",
    "extraInhabitants",
)


def align_up(value, alignment):
    return ((value + alignment - 1) // alignment) * alignment


def compute_layout(fields):
    """Lay out resolved fields in their declaration order."""
    end = 0
    alignment = 1
    offsets = []
    is_pod = True
    is_bitwise_takable = True
    extra_inhabitants = 0
    for field in fields:
        witness = field["vwt"]
        field_alignment = witness["alignment"]
        if field_alignment < 1:
            raise ValueError("field alignment must be positive")
        offset = align_up(end, field_alignment)
        offsets.append({"name": field.get("name"), "offset": offset})
        end = offset + witness["size"]
        alignment = max(alignment, field_alignment)
        is_pod = is_pod and witness["isPOD"]
        is_bitwise_takable = is_bitwise_takable and witness["isBitwiseTakable"]
        extra_inhabitants = max(extra_inhabitants, witness["extraInhabitants"])
    return {
        "size": end,
        "stride": max(1, align_up(end, alignment)),
        "alignment": alignment,
        "isPOD": is_pod,
        "isBitwiseTakable": is_bitwise_takable,
        "extraInhabitants": extra_inhabitants,
        "fieldOffsets": offsets,
    }


def compare_layouts(oracle):
    rows = []
    counts = {"computable": 0, "agree": 0, "disagree": 0,
              "unsupported": 0, "unresolved": 0}
    for nominal in oracle.get("types", []):
        row = {key: nominal[key] for key in ("qualifiedName", "mangled", "kind")
               if key in nominal}
        if nominal.get("kind") != "struct":
            row.update(status="unsupported", reason="only structs are supported")
            counts["unsupported"] += 1
            rows.append(row)
            continue
        fields = nominal.get("fields")
        own_witness = nominal.get("vwt")
        if fields is None:
            reason = "field records absent; run the oracle with --fields"
        elif not own_witness or any(key not in own_witness for key in METRICS):
            reason = "struct witness incomplete or absent"
        elif any(not field.get("vwt") or field.get("dependent")
                 or field.get("status") == "dependent"
                 or any(key not in field["vwt"] for key in METRICS)
                 for field in fields):
            reason = "one or more field witnesses unresolved"
        else:
            reason = None
        if reason:
            row.update(status="unresolved", reason=reason)
            counts["unresolved"] += 1
            rows.append(row)
            continue
        computed = compute_layout(fields)
        differences = [
            {"field": key, "computed": computed[key], "oracle": own_witness[key]}
            for key in METRICS if computed[key] != own_witness[key]
        ]
        row.update(status="disagree" if differences else "agree",
                   computed=computed,
                   oracle={key: own_witness[key] for key in METRICS},
                   firstDifference=differences[0] if differences else None,
                   differences=differences)
        counts["computable"] += 1
        counts[row["status"]] += 1
        rows.append(row)
    return {"types": rows, **counts,
            "rate": counts["agree"] / counts["computable"]
            if counts["computable"] else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("oracle", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    report = compare_layouts(json.loads(args.oracle.read_text()))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
