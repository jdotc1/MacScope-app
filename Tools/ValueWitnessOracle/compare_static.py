#!/usr/bin/env python3
"""Compare runtime value witnesses with independently recorded layout facts."""

import argparse
import json
from pathlib import Path


FIELDS = ("size", "stride", "alignment", "extraInhabitantCount", "flags")


def integer(value):
    """Accept JSON integers and the hexadecimal addresses used by some receipts."""
    if isinstance(value, bool):
        raise ValueError("boolean is not a witness integer")
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value, 16 if value.lower().startswith("0x") else 10)
    raise ValueError("expected integer, got {!r}".format(value))


def oracle_rows(document):
    if isinstance(document, list):
        return document
    for key in ("types", "rows", "records"):
        if isinstance(document.get(key), list):
            return document[key]
    raise ValueError("oracle must contain a types array")


def witness_values(row):
    values = row.get("vwt", row)
    result = {}
    for field in FIELDS:
        aliases = (field, "extraInhabitants") if field == "extraInhabitantCount" else (field,)
        for alias in aliases:
            if alias in values:
                result[field] = integer(values[alias])
                break
    return result


def unique_index(rows, key, convert):
    result = {}
    for row in rows:
        if row.get(key) is None:
            continue
        identity = convert(row[key])
        if identity in result:
            # Field metadata can repeat the same concrete type. Reuse identical
            # observations, but never conceal conflicting observations.
            if witness_values(result[identity]) != witness_values(row):
                raise ValueError("conflicting duplicate {} {!r}".format(key, identity))
        else:
            result[identity] = row
    return result


def compare_rows(runtime, recorded, runtime_key, recorded_key, fields=FIELDS):
    convert = integer if runtime_key == "metadataVA" else str
    left = unique_index(runtime, runtime_key, convert)
    right = unique_index(recorded, recorded_key, convert)
    joined = sorted(left.keys() & right.keys())
    rows = []
    for identity in joined:
        oracle = left[identity]
        static = right[identity]
        actual, expected = witness_values(oracle), witness_values(static)
        differences = {}
        for field in fields:
            if field not in actual or field not in expected or actual[field] != expected[field]:
                differences[field] = {"oracle": actual.get(field), "static": expected.get(field)}
        rows.append({runtime_key: identity,
                     "qualifiedName": oracle.get("qualifiedName", static.get("typeName")),
                     "status": "disagree" if differences else "agree",
                     "differences": differences})
    agree = sum(row["status"] == "agree" for row in rows)
    return {"status": "complete", "joined": len(joined), "agree": agree,
            "disagree": len(joined) - agree,
            "oracleOnly": len(left.keys() - right.keys()),
            "staticOnly": len(right.keys() - left.keys()), "types": rows}


def compare_static(oracle, census):
    if census is None:
        return {"status": "pending", "reason": "no census receipt"}
    if not isinstance(census, dict) or not isinstance(census.get("valueWitnesses"), list):
        raise ValueError("census must contain a valueWitnesses array")
    # An external address has no unslid identity in the input image.
    rows = [row for row in oracle_rows(oracle) if not row.get("external", False) and "vwt" in row]
    return compare_rows(rows, census["valueWitnesses"], "metadataVA", "metadataAddress")


def compare_memorylayout(oracle, document):
    if document is None:
        return {"status": "pending", "reason": "no memorylayout receipt"}
    if isinstance(document, list):
        rows = document
    else:
        rows = next((document[key] for key in ("types", "layouts", "rows", "records")
                     if isinstance(document.get(key), list)), None)
        if rows is None:
            # A name-keyed map is convenient for a small Swift MemoryLayout dump.
            if all(isinstance(value, dict) for value in document.values()):
                rows = [dict(value, qualifiedName=name) for name, value in document.items()]
            else:
                raise ValueError("memorylayout must contain named layout rows")
    # MemoryLayout exposes size, stride and alignment, not witness flags or
    # extra inhabitants. Compare any additional facts only when recorded.
    fields = tuple(field for field in FIELDS if field in ("size", "stride", "alignment")
                   or any(field in witness_values(row) for row in rows))
    return compare_rows([row for row in oracle_rows(oracle) if "vwt" in row], rows,
                        "qualifiedName", "qualifiedName", fields)


def read_optional(path):
    return json.loads(path.read_text()) if path is not None and path.exists() else None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("oracle", type=Path)
    parser.add_argument("census", type=Path, help="matching census receipt; may be absent")
    parser.add_argument("--memorylayout", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    oracle = json.loads(args.oracle.read_text())
    result = compare_static(oracle, read_optional(args.census))
    if args.memorylayout is not None:
        result["memorylayout"] = compare_memorylayout(oracle, read_optional(args.memorylayout))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 1 if result.get("disagree", 0) or result.get("memorylayout", {}).get("disagree", 0) else 0


if __name__ == "__main__":
    raise SystemExit(main())
