#!/usr/bin/env python3
"""Rank patterns by how far the port trails the best competitor.

metric = oniguruma_dart·VM / min(Oniguruma C, Dart RegExp·VM, V8 interp)
Worst (largest) first. Also shows port/C. Reads benchmark/mainstream_results.json.
"""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
d = json.load(open(os.path.join(ROOT, "benchmark/mainstream_results.json")))
C, V, R, P = d["ONIG_C"], d["V8_INTERP"], d["RE_VM"], d["ONIG_VM"]
labels = list(C.keys())


def ms(x):
    return f"{x/1e6:.2f}"


rows = []
for l in labels:
    best = min(C[l], V[l], R[l])
    who = "C" if best == C[l] else ("V8" if best == V[l] else "RE")
    rows.append((P[l] / best, P[l] / C[l], l, C[l], V[l], R[l], P[l], who))
rows.sort(reverse=True)

print(f"| rank | pattern | port | C | V8 | RegExp | port/best | best | port/C |")
print("|--:|---|--:|--:|--:|--:|--:|--:|--:|")
for i, (r, rc, l, c, v, re, p, who) in enumerate(rows, 1):
    print(f"| {i} | {l} | {ms(p)} | {ms(c)} | {ms(v)} | {ms(re)} "
          f"| {r:.2f}× | {who} | {rc:.2f}× |")
