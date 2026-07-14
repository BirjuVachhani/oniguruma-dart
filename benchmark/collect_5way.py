#!/usr/bin/env python3
"""Collect fresh numbers from the three 5-way harnesses, cache them into
compute_5way.py (rewriting its dict literals) and benchmark/bench_results.json.

Inputs (produced by the caller):
  /tmp/c13.txt   <- python3 benchmark/bench_c_13.py     (RAW\tlabel\tmatches\tns)
  /tmp/vsre.txt  <- ./benchmark/bench_vs_regexp         (RAW\tlabel\tmatches\tagree\treNs\togNs)
  /tmp/web.txt   <- node benchmark/web/bench_web.js     (RAW\tlabel\tmatches\tagree\treNs\togNs)
"""
import re, os, json

ROOT = "/Users/birjuvachhani/Documents/Projects/oniguruma"


def parse_c(path):
    onig_c, count = {}, {}
    for ln in open(path):
        if ln.startswith("RAW\t"):
            _, lbl, m, ns = ln.rstrip("\n").split("\t")
            onig_c[lbl] = float(ns)
            count[lbl] = int(m)
    return onig_c, count


def parse_pair(path):
    """Returns (re_dict, onig_dict) from a bench_vs_regexp / bench_web RAW dump."""
    re_d, og_d = {}, {}
    for ln in open(path):
        if ln.startswith("RAW\t"):
            parts = ln.rstrip("\n").split("\t")
            lbl, _m, _agree, re_ns, og_ns = parts[1], parts[2], parts[3], parts[4], parts[5]
            re_d[lbl] = float(re_ns)
            og_d[lbl] = float(og_ns)
    return re_d, og_d


ONIG_C, COUNT = parse_c("/tmp/c13.txt")
RE_VM, ONIG_VM = parse_pair("/tmp/vsre.txt")
RE_WEB, ONIG_WEB = parse_pair("/tmp/web.txt")

cache = {
    "COUNT": COUNT, "ONIG_C": ONIG_C, "ONIG_VM": ONIG_VM,
    "ONIG_WEB": ONIG_WEB, "RE_VM": RE_VM, "RE_WEB": RE_WEB,
}
with open(os.path.join(ROOT, "benchmark/bench_results.json"), "w") as f:
    json.dump(cache, f, indent=2)


def fmt_dict(name, d):
    items = ", ".join(f'"{k}": {v}' for k, v in d.items())
    return f"{name} = {{\n    {items}\n}}"


# Rewrite the six dict literals inside compute_5way.py (no nested braces in them).
path = os.path.join(ROOT, "benchmark/compute_5way.py")
src = open(path).read()
for name, d in cache.items():
    src = re.sub(rf"{name} = \{{[^}}]*\}}", fmt_dict(name, d), src, count=1)
open(path, "w").write(src)

labels = list(COUNT.keys())
print(f"cached {len(labels)} patterns x 5 engines -> benchmark/bench_results.json"
      f" + compute_5way.py")
missing = [n for n, d in cache.items() if set(d) != set(COUNT)]
print("label-set mismatch:" , missing if missing else "none")
