#!/usr/bin/env python3
"""THE mainstream benchmark — the canonical comparison from 2026-07-14 onward.

Four engines, all measured as "median time to scan the whole corpus for every
non-overlapping match" (match counts verified identical):

  1. Oniguruma C            — the reference C library (byte API, native)
  2. V8 regex interpreter   — Node --regexp-interpret-all (Irregexp BYTECODE
                              interpreter; JS around it still JIT'd). The honest
                              like-for-like interpreter, NOT V8's machine-code JIT.
  3. Dart RegExp · VM       — dart:core RegExp on the Dart VM (V8 Irregexp
                              bytecode interpreter, interpreter-only in AOT & JIT)
  4. oniguruma_dart · VM    — this port's OnigRegex String API on the Dart VM
                              (our pure-Dart bytecode interpreter)

Usage:
  python3 benchmark/mainstream.py            # render from benchmark/mainstream_results.json
  python3 benchmark/mainstream.py --run      # re-measure all four engines, then render

Notes:
  * Absolute ms can vary with machine load; RATIOS (normalized to C, geomeans) are
    the intended signal and are stable when all engines run in one session.
  * Run with the editor/other CPU hogs idle for clean absolute numbers.
"""
import json, os, sys, re, math, subprocess, statistics

# .../packages/oniguruma_dart (parent of benchmark/) — resolves correctly
# regardless of where the repo lives (pub-workspace move safe).
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSON = os.path.join(ROOT, "benchmark/mainstream_results.json")
NODE = "node"

# 13 patterns, shared across harnesses (label, C/onig pattern, corpus, ignoreCase-for-C)
CORPUS = {"ascii": "benchmark/datasets/corpus.txt",
          "uni": "benchmark/datasets/unicode_corpus.txt"}
PATTERNS = [
    ("literal", "lorem", "ascii"),
    ("literal-unicode", "東京", "uni"),
    ("alt-5", "lorem|ipsum|dolor|sit|amet", "ascii"),
    ("class-lower", "[a-z]+", "ascii"),
    ("class-digit", "[0-9]+", "ascii"),
    ("word-w", r"\w+", "ascii"),
    ("two-words", "[a-z]+ [a-z]+", "ascii"),
    ("word-boundary", r"\b\w{5}\b", "ascii"),
    ("email-like", r"\w+@\w+", "ascii"),
    ("named-group", "(?<w>[a-z]+)", "ascii"),
    ("case-insens", "(?i)lorem", "ascii"),
    ("backref-dup", r"(\w+) \1", "ascii"),
    ("greedy-dotstar", ".*lorem", "ascii"),
]
LABELS = [p[0] for p in PATTERNS]

ENGINE_ORDER = ["ONIG_C", "V8_INTERP", "RE_VM", "ONIG_VM"]
ENGINE_NAME = {
    "ONIG_C": "Oniguruma C",
    "V8_INTERP": "V8 interp",
    "RE_VM": "Dart RegExp·VM",
    "ONIG_VM": "oniguruma_dart·VM",
}

_LINE = re.compile(r"^(\d+) matches, ([\d.]+) ns/search-scan")


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT).stdout


def _c_bench(pat, corpus, iters=30, trials=5):
    hexpat = pat.encode("utf-8").hex()
    vals, cnt = [], None
    for _ in range(trials):
        out = _run([os.path.join(ROOT, "benchmark/c/onig_cli"), "bench", hexpat,
                    os.path.join(ROOT, CORPUS[corpus]), str(iters)]).strip()
        m = _LINE.match(out)
        if m:
            cnt = int(m.group(1)); vals.append(float(m.group(2)))
    return cnt, statistics.median(vals)


def _parse_pair(text):
    """RAW\\tlabel\\tmatches\\tagree\\treNs\\togNs  ->  (re_dict, onig_dict, count)"""
    re_d, og_d, cnt = {}, {}, {}
    for ln in text.splitlines():
        if ln.startswith("RAW\t"):
            p = ln.split("\t")
            cnt[p[1]] = int(p[2]); re_d[p[1]] = float(p[4]); og_d[p[1]] = float(p[5])
    return re_d, og_d, cnt


def collect():
    data = {k: {} for k in ENGINE_ORDER}
    count = {}
    print("[C] onig_cli ...", flush=True)
    for lab, pat, corpus in PATTERNS:
        c, ns = _c_bench(pat, corpus)
        data["ONIG_C"][lab] = ns; count[lab] = c
    print("[Dart VM] bench_vs_regexp ...", flush=True)
    re_vm, og_vm, _ = _parse_pair(_run([os.path.join(ROOT, "benchmark/bench_vs_regexp")]))
    data["RE_VM"], data["ONIG_VM"] = re_vm, og_vm
    print("[V8 interp] node --regexp-interpret-all bench_web.js ...", flush=True)
    re_i, _og, _ = _parse_pair(_run([NODE, "--regexp-interpret-all",
                                     os.path.join(ROOT, "benchmark/web/bench_web.js")]))
    data["V8_INTERP"] = re_i
    print("[V8 JIT] node bench_web.js ...", flush=True)
    re_j, _ogj, _ = _parse_pair(_run([NODE,
                                      os.path.join(ROOT, "benchmark/web/bench_web.js")]))
    data["V8_JIT"] = re_j
    data["COUNT"] = count
    json.dump(data, open(JSON, "w"), indent=2)
    print(f"cached -> {JSON}")
    return data


def t(ns):
    if ns is None:
        return "n/a"
    if ns >= 1e6:
        return f"{ns/1e6:.2f} ms"
    if ns >= 1e3:
        return f"{ns/1e3:.0f} µs"
    return f"{ns:.0f} ns"


def gmean(xs):
    xs = [x for x in xs if x and x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else 0


def render(data):
    count = data.get("COUNT", {})
    print("# Mainstream benchmark — V8 interp · Dart RegExp · oniguruma_dart port · C\n")
    print("Median ns/ms to scan the corpus for all non-overlapping matches. "
          "V8 interp = Node --regexp-interpret-all (bytecode interpreter).\n")

    print("## Absolute\n")
    hdr = "| pattern | matches | " + " | ".join(ENGINE_NAME[e] for e in ENGINE_ORDER) + " |"
    print(hdr); print("|---|--:|" + "--:|" * len(ENGINE_ORDER))
    for lab in LABELS:
        cells = " | ".join(t(data[e].get(lab)) for e in ENGINE_ORDER)
        print(f"| {lab} | {count.get(lab, ''):,} | {cells} |")

    print("\n## Normalized to Oniguruma C (1.00× baseline; <1 faster, >1 slower)\n")
    print("| pattern | " + " | ".join(ENGINE_NAME[e] for e in ENGINE_ORDER) + " |")
    print("|---|" + "--:|" * len(ENGINE_ORDER))
    for lab in LABELS:
        c = data["ONIG_C"][lab]
        cells = " | ".join(f"{data[e][lab]/c:.2f}×" if data[e].get(lab) else "n/a"
                           for e in ENGINE_ORDER)
        print(f"| {lab} | {cells} |")

    print("\n## Geomean vs Oniguruma C (13 patterns)\n")
    print("| engine | geomean vs C |")
    print("|---|--:|")
    for e in ENGINE_ORDER:
        g = gmean([data[e][l] / data["ONIG_C"][l] for l in LABELS if data[e].get(l)])
        print(f"| {ENGINE_NAME[e]} | {g:.2f}× |")

    print("\n## Head-to-head geomeans\n")
    print("| comparison | geomean |")
    print("|---|--:|")
    pairs = [
        ("oniguruma_dart·VM / V8 interp", "ONIG_VM", "V8_INTERP"),
        ("oniguruma_dart·VM / Dart RegExp·VM", "ONIG_VM", "RE_VM"),
        ("Dart RegExp·VM / V8 interp", "RE_VM", "V8_INTERP"),
        ("Dart RegExp·VM / Oniguruma C", "RE_VM", "ONIG_C"),
    ]
    for name, a, b in pairs:
        g = gmean([data[a][l] / data[b][l] for l in LABELS if data[a].get(l) and data[b].get(l)])
        print(f"| {name} | {g:.2f}× |")


if __name__ == "__main__":
    if "--run" in sys.argv:
        d = collect()
    else:
        d = json.load(open(JSON))
    render(d)
