#!/usr/bin/env python3
"""Compares the camera tracks behaviour_paths.gd writes, one file per physics engine.

usage: compare_paths.py [--markdown out.md] a.json b.json [c.json ...]

For every rig and walk it prints, per engine, how far the camera moved relative to its target in
one frame at most (a pop is a frame where that exceeds 0.25 m) and the largest change of that
movement between two frames (jitter), then for every pair of engines the largest and the mean
distance between the two cameras on the same frame.
"""
import argparse
import itertools
import json
import math
import sys

POP = 0.25


def sub(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


def length(a):
    return math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+")
    parser.add_argument("--markdown")
    args = parser.parse_args()
    documents = [json.load(open(path)) for path in args.files]
    engines = [d["engine"] for d in documents]
    tracks = [k for k in documents[0]["paths"] if not k.startswith("target/")]

    lines = ["| rig / walk | frames | engine | largest relative step (m) | pops (> %.2f m) | largest jitter (m) |" % POP,
             "|---|---|---|---|---|---|"]
    for track in tracks:
        walk = track.split("/")[1]
        for document in documents:
            camera = document["paths"][track]
            target = document["paths"]["target/" + walk]
            relative = [sub(c, t) for c, t in zip(camera, target)]
            steps = [sub(b, a) for a, b in zip(relative, relative[1:])]
            largest = max(length(s) for s in steps)
            pops = sum(1 for s in steps if length(s) > POP)
            jitter = max(length(sub(b, a)) for a, b in zip(steps, steps[1:]))
            lines.append(f"| {track} | {len(camera)} | {document['engine']} | {largest:.4f} | {pops} | {jitter:.4f} |")

    lines.append("")
    lines.append("| rig / walk | engines | largest difference (m) | at frame | mean difference (m) | frames over 1 cm |")
    lines.append("|---|---|---|---|---|---|")
    for track in tracks:
        for a, b in itertools.combinations(range(len(documents)), 2):
            first = documents[a]["paths"][track]
            second = documents[b]["paths"][track]
            distances = [length(sub(p, q)) for p, q in zip(first, second)]
            worst = max(range(len(distances)), key=lambda i: distances[i])
            over = sum(1 for d in distances if d > 0.01)
            lines.append(f"| {track} | {engines[a]} vs {engines[b]} | {distances[worst]:.4f} | {worst} | "
                         f"{sum(distances) / len(distances):.4f} | {over} |")
    text = "\n".join(lines) + "\n"
    if args.markdown:
        with open(args.markdown, "w") as handle:
            handle.write(text)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
