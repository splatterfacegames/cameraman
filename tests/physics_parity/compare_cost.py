#!/usr/bin/env python3
"""Prints the timings query_cost.gd writes, one file per physics engine, side by side.

usage: compare_cost.py [--markdown out.md] a.json b.json [c.json ...]
"""
import argparse
import json
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+")
    parser.add_argument("--markdown")
    args = parser.parse_args()
    documents = [json.load(open(path)) for path in args.files]
    engines = [d["engine"] for d in documents]
    lines = ["| microseconds per camera per frame | " + " | ".join(engines) + " |", "|---|" + "---|" * len(engines)]
    walks = sorted({key.split("/")[2] for key in documents[0]["rigs"]})
    for rig in ("third_person_follow", "deoccluder"):
        for walk in walks:
            on = [d["rigs"][f"{rig}/collision/{walk}"] for d in documents]
            off = [d["rigs"][f"{rig}/no_collision/{walk}"] for d in documents]
            lines.append(f"| {rig}, {walk}: update with collision | " + " | ".join(f"{r['mean_usec']:.1f}" for r in on) + " |")
            lines.append(f"| {rig}, {walk}: update without collision | " + " | ".join(f"{r['mean_usec']:.1f}" for r in off) + " |")
            lines.append(f"| {rig}, {walk}: **cost of collision** | "
                         + " | ".join(f"**{a['mean_usec'] - b['mean_usec']:.1f}**" for a, b in zip(on, off)) + " |")
            lines.append(f"| {rig}, {walk}: worst single update with collision | " + " | ".join(str(r["worst_usec"]) for r in on) + " |")
    for key in documents[0]["raw"]:
        lines.append(f"| raw {key.replace('_usec', '')}, one call | " + " | ".join(f"{d['raw'][key]:.2f}" for d in documents) + " |")
    lines.append(f"| frames timed | " + " | ".join(str(d["frames"]) for d in documents) + " |")
    text = "\n".join(lines) + "\n"
    if args.markdown:
        with open(args.markdown, "w") as handle:
            handle.write(text)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
