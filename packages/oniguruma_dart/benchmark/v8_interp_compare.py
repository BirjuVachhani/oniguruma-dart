#!/usr/bin/env python3
"""Compare V8's regex bytecode interpreter (node --regexp-interpret-all) against
the JIT (normal node), our pure-Dart interpreter, Dart-VM RegExp (also a V8
Irregexp interpreter), and Oniguruma C.

Reads:
  /tmp/web_normal.txt   node                       (reNs = V8 JIT machine-code regex)
  /tmp/web_interp.txt   node --regexp-interpret-all (reNs = V8 regex bytecode interpreter)
  /tmp/web_jitless.txt  node --jitless             (reNs = interpreter + interpreted harness)
  benchmark/bench_results.json  (cached full-run: ONIG_C, ONIG_VM, RE_VM, RE_WEB, ...)
"""
import json, os, math

ROOT = "/Users/birjuvachhani/Documents/Projects/oniguruma"


def parse_pair(path):
    re_d, og_d = {}, {}
    for ln in open(path):
        if ln.startswith("RAW\t"):
            p = ln.rstrip("\n").split("\t")
            re_d[p[1]] = float(p[4])   # reNs
            og_d[p[1]] = float(p[5])   # ogNs
    return re_d, og_d


RE_JIT, OG_WEB_NORMAL = parse_pair("/tmp/web_normal.txt")
RE_INTERP, OG_WEB_INTERP = parse_pair("/tmp/web_interp.txt")
RE_JITLESS, OG_WEB_JITLESS = parse_pair("/tmp/web_jitless.txt")

cache = json.load(open(os.path.join(ROOT, "benchmark/bench_results.json")))
ONIG_C = cache["ONIG_C"]
ONIG_VM = cache["ONIG_VM"]     # our pure-Dart interpreter (String API, Dart VM)
RE_VM = cache["RE_VM"]         # Dart-VM RegExp = V8 Irregexp interpreter (in Dart VM)

labels = list(ONIG_C.keys())


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


print("## V8 regex: JIT (machine code) vs bytecode interpreter, Node, same session\n")
print("| pattern | V8 JIT (normal) | V8 interp (--regexp-interpret-all) | interp/JIT |")
print("|---|--:|--:|--:|")
for lab in labels:
    if lab in RE_JIT and lab in RE_INTERP:
        r = RE_INTERP[lab] / RE_JIT[lab]
        print(f"| {lab} | {t(RE_JIT[lab])} | {t(RE_INTERP[lab])} | {r:.1f}× |")
g = gmean([RE_INTERP[l] / RE_JIT[l] for l in labels if l in RE_JIT and l in RE_INTERP])
print(f"\n**geomean interp/JIT = {g:.1f}×: the pure cost of turning OFF V8's regex JIT.**")

print("\n## Interpreter-vs-interpreter: V8 regex bytecode interp vs our Dart interp vs C\n")
print("| pattern | Oniguruma C | oniguruma_dart·VM (our interp) | Dart RegExp·VM (V8 interp in DartVM) | V8 regex interp (Node) | V8 JIT (Node) |")
print("|---|--:|--:|--:|--:|--:|")
for lab in labels:
    print(f"| {lab} | {t(ONIG_C[lab])} | {t(ONIG_VM[lab])} | {t(RE_VM[lab])} "
          f"| {t(RE_INTERP.get(lab))} | {t(RE_JIT.get(lab))} |")

print("\n## Geomeans vs Oniguruma C (interpreters only, lower = closer to C)\n")
print("| engine | geomean vs C |")
print("|---|--:|")
for name, d in [
    ("oniguruma_dart · VM (our Dart interp)", ONIG_VM),
    ("Dart RegExp · VM (V8 interp in Dart VM)", RE_VM),
    ("V8 regex interp (Node --regexp-interpret-all)", RE_INTERP),
    ("V8 regex JIT (Node normal)", RE_JIT),
]:
    g = gmean([d[l] / ONIG_C[l] for l in labels if l in d])
    print(f"| {name} | {g:.2f}× |")

print("\n## Our Dart interpreter vs V8's regex bytecode interpreter (both interpreters)\n")
print("| comparison | geomean |")
print("|---|--:|")
g1 = gmean([ONIG_VM[l] / RE_INTERP[l] for l in labels if l in RE_INTERP])
g2 = gmean([RE_VM[l] / RE_INTERP[l] for l in labels if l in RE_INTERP])
print(f"| oniguruma_dart·VM / V8-regex-interp | {g1:.2f}× |")
print(f"| Dart RegExp·VM / V8-regex-interp (both V8 Irregexp, DartVM vs Node) | {g2:.2f}× |")

print("\n## --jitless (everything interpreted, incl. harness), context only\n")
print("| pattern | V8 regex interp (clean) | --jitless RegExp | --jitless our port (JS interpreted) |")
print("|---|--:|--:|--:|")
for lab in labels:
    print(f"| {lab} | {t(RE_INTERP.get(lab))} | {t(RE_JITLESS.get(lab))} | {t(OG_WEB_JITLESS.get(lab))} |")
