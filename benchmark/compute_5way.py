#!/usr/bin/env python3
"""Assemble the 5-way comparison from the three harness runs.

All numbers are median ns to scan the whole corpus for every non-overlapping
match (same unit across engines; match counts verified identical). Sources:
  - Oniguruma C          : benchmark/bench_c_13.py       (onig_cli bench)
  - oniguruma_dart VM/Web: benchmark/bench_vs_regexp + benchmark/web/bench_web.js
  - Dart RegExp VM/Web   : same two harnesses (RegExp column)
"""
import math

# label -> ns per full-corpus scan, per engine (pasted from the RAW lines).
COUNT = {
    "literal": 7856, "literal-unicode": 2938, "alt-5": 39251,
    "class-lower": 166221, "class-digit": 5972, "word-w": 172193,
    "two-words": 75064, "word-boundary": 39418, "email-like": 2027,
    "named-group": 166221, "case-insens": 7856, "backref-dup": 15606,
    "greedy-dotstar": 6518,
}
ONIG_C = {
    "literal": 2300254.0, "literal-unicode": 1034080.9, "alt-5": 21564000.0,
    "class-lower": 33687888.9, "class-digit": 5554384.6, "word-w": 33705555.6,
    "two-words": 22213307.7, "word-boundary": 25580888.9, "email-like": 39039428.6,
    "named-group": 32716777.8, "case-insens": 6623977.3, "backref-dup": 46954666.7,
    "greedy-dotstar": 12158583.3,
}
ONIG_VM = {
    "literal": 140788250.0, "literal-unicode": 60520600.0, "alt-5": 177362000.0,
    "class-lower": 193970750.0, "class-digit": 130823250.0, "word-w": 207749500.0,
    "two-words": 182728750.0, "word-boundary": 184727500.0, "email-like": 273707500.0,
    "named-group": 200339250.0, "case-insens": 164625250.0, "backref-dup": 472872500.0,
    "greedy-dotstar": 881214000.0,
}
ONIG_WEB = {
    "literal": 173000000.0, "literal-unicode": 86333333.3, "alt-5": 280500000.0,
    "class-lower": 561500000.0, "class-digit": 175750000.0, "word-w": 527500000.0,
    "two-words": 338500000.0, "word-boundary": 296000000.0, "email-like": 379500000.0,
    "named-group": 512500000.0, "case-insens": 229250000.0, "backref-dup": 665000000.0,
    "greedy-dotstar": 1177500000.0,
}
RE_VM = {
    "literal": 4445447.4, "literal-unicode": 779814.8, "alt-5": 25775100.0,
    "class-lower": 40550357.1, "class-digit": 43592166.7, "word-w": 41537571.4,
    "two-words": 42629750.0, "word-boundary": 47402666.7, "email-like": 147029750.0,
    "named-group": 43382083.3, "case-insens": 4412096.5, "backref-dup": 181687250.0,
    "greedy-dotstar": 472104000.0,
}
RE_WEB = {
    "literal": 1394487.5, "literal-unicode": 195421.3, "alt-5": 5500000.0,
    "class-lower": 8145161.3, "class-digit": 394953.6, "word-w": 8416666.7,
    "two-words": 6121951.2, "word-boundary": 7582442.1, "email-like": 17166666.7,
    "named-group": 12980263.2, "case-insens": 1504509.1, "backref-dup": 18214285.7,
    "greedy-dotstar": 102666666.7,
}

LABELS = list(COUNT.keys())
ENGINES = [
    ("oniguruma_dart · VM", ONIG_VM),
    ("oniguruma_dart · Web", ONIG_WEB),
    ("Dart RegExp · VM", RE_VM),
    ("Dart RegExp · Web", RE_WEB),
    ("Oniguruma C", ONIG_C),
]


def t(ns):
    if ns >= 1e6:
        return f"{ns/1e6:.2f} ms"
    if ns >= 1e3:
        return f"{ns/1e3:.0f} µs"
    return f"{ns:.0f} ns"


def gmean(xs):
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


print("## Table A — absolute: median time to scan the corpus for all matches\n")
print("| pattern | matches | " + " | ".join(n for n, _ in ENGINES) + " |")
print("|---|--:|" + "--:|" * len(ENGINES))
for lab in LABELS:
    cells = " | ".join(t(d[lab]) for _, d in ENGINES)
    print(f"| {lab} | {COUNT[lab]:,} | {cells} |")

print("\n## Table B — normalized to Oniguruma C (= 1.00×). ×>1 slower, %<0 faster.\n")
print("| pattern | " + " | ".join(n for n, _ in ENGINES) + " |")
print("|---|" + "--:|" * len(ENGINES))
for lab in LABELS:
    c = ONIG_C[lab]
    cells = []
    for _, d in ENGINES:
        x = d[lab] / c
        pct = (x - 1) * 100
        cells.append(f"{x:.2f}× ({pct:+.0f}%)")
    print(f"| {lab} | " + " | ".join(cells) + " |")

print("\n## Geomean (across 13 patterns)\n")
print("| comparison | geomean × | as % |")
print("|---|--:|--:|")
pairs = [
    ("oniguruma_dart VM  vs  Oniguruma C", ONIG_VM, ONIG_C),
    ("oniguruma_dart Web vs  Oniguruma C", ONIG_WEB, ONIG_C),
    ("Dart RegExp VM     vs  Oniguruma C", RE_VM, ONIG_C),
    ("Dart RegExp Web    vs  Oniguruma C", RE_WEB, ONIG_C),
    ("oniguruma_dart VM  vs  Dart RegExp VM", ONIG_VM, RE_VM),
    ("oniguruma_dart Web vs  Dart RegExp Web", ONIG_WEB, RE_WEB),
    ("oniguruma_dart Web vs  oniguruma_dart VM", ONIG_WEB, ONIG_VM),
    ("Dart RegExp Web    vs  Dart RegExp VM", RE_WEB, RE_VM),
]
for name, a, b in pairs:
    g = gmean([a[lab] / b[lab] for lab in LABELS])
    pct = (g - 1) * 100
    verb = "slower" if g >= 1 else "faster"
    show = g if g >= 1 else 1 / g
    print(f"| {name} | {g:.2f}× | {pct:+.0f}%  ({show:.1f}× {verb}) |")
