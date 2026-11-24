#!/usr/bin/env python3
"""Compares the JSON files parity_queries.gd writes, one per physics engine.

usage: compare_parity.py [--tolerance 0.001] [--ignore field,field] [--all] [--markdown out.md]
                         a.json b.json [c.json ...]

Prints every query whose results differ between engines by more than the tolerance (metres, or
a plain difference for fractions and counts), and a count of the ones that agree. Exit status is
always 0: a difference is a finding to read, not a failure.
"""
import argparse
import json
import sys


def differs(a, b, tolerance):
    if isinstance(a, bool) or isinstance(b, bool):
        return a != b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(a - b) > tolerance
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        return any(differs(x, y, tolerance) for x, y in zip(a, b))
    return a != b


def show(value):
    if value is None:
        return "-"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, float):
        return f"{value:.4f}".rstrip("0").rstrip(".")
    if isinstance(value, list):
        return "(" + ", ".join(show(v) for v in value) + ")"
    return str(value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+")
    parser.add_argument("--tolerance", type=float, default=0.001)
    parser.add_argument("--markdown")
    parser.add_argument("--all", action="store_true", help="also list the queries that agree")
    parser.add_argument("--ignore", default="", help="comma-separated fields to leave out, for example face_index")
    args = parser.parse_args()

    ignored = set(filter(None, args.ignore.split(",")))
    documents = [json.load(open(path)) for path in args.files]
    engines = [d["engine"] for d in documents]
    keys = []
    for d in documents:
        for key in d["results"]:
            if key not in keys:
                keys.append(key)

    lines = []
    same = 0
    different = 0
    per_scenario = {}
    lines.append("| query | call | field | " + " | ".join(engines) + " |")
    lines.append("|---|---|---|" + "---|" * len(engines))
    for key in keys:
        records = [d["results"].get(key) for d in documents]
        fields = []
        for record in records:
            for field in record or {}:
                if field != "call" and field not in fields and field not in ignored:
                    fields.append(field)
        call = next((r["call"] for r in records if r), "?")
        key_differs = False
        rows = []
        for field in fields:
            values = [(r or {}).get(field) for r in records]
            field_differs = any(differs(values[0], v, args.tolerance) for v in values[1:])
            # A miss has no position: only the hit flag is worth a row then.
            if field_differs:
                key_differs = True
            if field_differs or args.all:
                mark = "" if field_differs else " (same)"
                rows.append(f"| {key} | {call} | {field}{mark} | " + " | ".join(show(v) for v in values) + " |")
        scenario = key.split("/")[0]
        totals = per_scenario.setdefault(scenario, [0, 0])
        if key_differs:
            different += 1
            totals[1] += 1
        else:
            same += 1
            totals[0] += 1
        lines.extend(rows)

    summary = ["| scenario | queries that agree | queries that differ |", "|---|---|---|"]
    for scenario, (agree, differ) in per_scenario.items():
        summary.append(f"| {scenario} | {agree} | {differ} |")
    summary.append(f"| total | {same} | {different} |")

    text = "\n".join(summary) + "\n\n" + "\n".join(lines) + "\n"
    if args.markdown:
        with open(args.markdown, "w") as handle:
            handle.write(text)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
