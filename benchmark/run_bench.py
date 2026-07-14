#!/usr/bin/env python3
"""Head-to-head benchmark driver: Dart port (AOT + JIT) vs. C libonig.

Runs the SAME patterns over the SAME datasets through identical harnesses
(compile-once-then-scan-all-matches, and compile-N-times). For every pattern it
also verifies the C and Dart engines report the same match count, so a
comparison is never made across diverging behaviour.

    python3 benchmark/run_bench.py [trials] [match_iters] [compile_iters]
"""
import subprocess, sys, re, statistics, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C_CLI = os.path.join(ROOT, "benchmark/c/onig_cli")
DART_AOT = os.path.join(ROOT, "benchmark/bench_dart")
DART_SRC = os.path.join(ROOT, "benchmark/bench_dart.dart")
ASCII = os.path.join(ROOT, "benchmark/datasets/corpus.txt")
UNI = os.path.join(ROOT, "benchmark/datasets/unicode_corpus.txt")

TRIALS = int(sys.argv[1]) if len(sys.argv) > 1 else 5
MITERS = int(sys.argv[2]) if len(sys.argv) > 2 else 30
CITERS = int(sys.argv[3]) if len(sys.argv) > 3 else 100000

# (label, pattern, corpus, category)
PATTERNS = [
    ("literal-ascii",   "lorem",                         ASCII, "literal"),
    ("literal-unicode", "東京",                            UNI,   "literal"),
    ("alt-5",           "lorem|ipsum|dolor|sit|amet",    ASCII, "alternation"),
    ("class-lower",     "[a-z]+",                        ASCII, "char-class"),
    ("class-digit",     "[0-9]+",                        ASCII, "char-class"),
    ("word-w",          "\\w+",                          ASCII, "class/quant"),
    ("two-words",       "[a-z]+ [a-z]+",                 ASCII, "quantifier"),
    ("word-boundary",   "\\benim\\b",                    ASCII, "anchor"),
    ("anchored-line",   "(?m)^[a-z]+",                   ASCII, "anchor"),
    ("email-like",      "\\w+@\\w+",                     ASCII, "quant/greedy"),
    ("case-insens",     "(?i)lorem",                     ASCII, "case-fold"),
    ("backref-dup",     "(\\w+) \\1",                    ASCII, "backreference"),
    ("backtrack",       "[a-z]*o[a-z]*r",                ASCII, "backtracking"),
    ("greedy-dotstar",  ".*lorem",                       ASCII, "greedy-.*"),
    ("uni-prop-L",      "\\p{L}+",                       UNI,   "unicode-prop"),
    ("uni-prop-Han",    "\\p{Han}+",                     UNI,   "unicode-prop"),
    ("uni-word",        "\\w+",                          UNI,   "unicode-class"),
]

MATCH_RE = re.compile(r"^(\d+) matches, ([\d.]+) ns/search-scan")
COMP_RE = re.compile(r"compiled, ([\d.]+) ns/compile")


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT).stdout.strip()


def c_bench(pat, corpus, iters):
    hexpat = pat.encode("utf-8").hex()
    out = run([C_CLI, "bench", hexpat, corpus, str(iters)])
    m = MATCH_RE.match(out)
    return (int(m.group(1)), float(m.group(2))) if m else (None, None)


def dart_bench(cmd_prefix, pat, corpus, iters):
    out = run(cmd_prefix + ["bench", pat, corpus, str(iters)])
    m = MATCH_RE.match(out)
    return (int(m.group(1)), float(m.group(2))) if m else (None, None)


def c_compile(pat, iters):
    out = run([C_CLI, "compile", pat.encode("utf-8").hex(), str(iters)])
    m = COMP_RE.search(out)
    return float(m.group(1)) if m else None


def dart_compile(cmd_prefix, pat, iters):
    out = run(cmd_prefix + ["compile", pat, str(iters)])
    m = COMP_RE.search(out)
    return float(m.group(1)) if m else None


def median_match(fn, *a):
    vals, count = [], None
    for _ in range(TRIALS):
        c, ns = fn(*a)
        if ns is None:
            return None, None
        count = c
        vals.append(ns)
    return count, statistics.median(vals)


def median_compile(fn, *a):
    vals = [fn(*a) for _ in range(TRIALS)]
    vals = [v for v in vals if v is not None]
    return statistics.median(vals) if vals else None


DART_JIT = ["dart", "run", DART_SRC]
DART_AOT_CMD = [DART_AOT]


def fmt_ns(ns):
    if ns is None:
        return "n/a"
    if ns >= 1e6:
        return f"{ns/1e6:.2f}ms"
    if ns >= 1e3:
        return f"{ns/1e3:.1f}µs"
    return f"{ns:.0f}ns"


def main():
    print(f"# trials={TRIALS} match_iters={MITERS} compile_iters={CITERS}\n")
    rows = []
    for label, pat, corpus, cat in PATTERNS:
        cn, cns = median_match(c_bench, pat, corpus, MITERS)
        an, ans = median_match(lambda p, c, i: dart_bench(DART_AOT_CMD, p, c, i), pat, corpus, MITERS)
        jn, jns = median_match(lambda p, c, i: dart_bench(DART_JIT, p, c, i), pat, corpus, MITERS)
        cc = median_compile(c_compile, pat, CITERS)
        ac = median_compile(lambda p, i: dart_compile(DART_AOT_CMD, p, i), pat, CITERS)
        agree = (cn == an == jn)
        rows.append((label, cat, corpus, cn, an, jn, cns, ans, jns, cc, ac, agree))
        print(f"  {label:16} matches C={cn} AOT={an} JIT={jn} agree={agree}")

    # ---- match throughput table ----
    print("\n## Match throughput (compile once, scan whole corpus for all matches)\n")
    hdr = f"| {'pattern':16} | {'category':13} | {'matches':>8} | {'C':>9} | {'Dart AOT':>9} | {'AOT/C':>6} | {'Dart JIT':>9} | {'JIT/C':>6} |"
    print(hdr)
    print("|" + "-" * 18 + "|" + "-" * 15 + "|" + "-" * 10 + "|" + "-" * 11 + "|" + "-" * 11 + "|" + "-" * 8 + "|" + "-" * 11 + "|" + "-" * 8 + "|")
    aot_ratios, jit_ratios = [], []
    for (label, cat, corpus, cn, an, jn, cns, ans, jns, cc, ac, agree) in rows:
        ar = ans / cns if cns else 0
        jr = jns / cns if cns else 0
        aot_ratios.append(ar); jit_ratios.append(jr)
        flag = "" if agree else " ⚠"
        print(f"| {label:16} | {cat:13} | {cn:>8} | {fmt_ns(cns):>9} | {fmt_ns(ans):>9} | {ar:>5.2f}x | {fmt_ns(jns):>9} | {jr:>5.2f}x |{flag}")
    print(f"\n**geomean AOT/C = {gmean(aot_ratios):.2f}x, JIT/C = {gmean(jit_ratios):.2f}x**")

    # ---- compile table ----
    print("\n## Compile time (ns per onig_new)\n")
    print(f"| {'pattern':16} | {'C':>9} | {'Dart AOT':>9} | {'AOT/C':>6} |")
    print("|" + "-" * 18 + "|" + "-" * 11 + "|" + "-" * 11 + "|" + "-" * 8 + "|")
    cratios = []
    for (label, cat, corpus, cn, an, jn, cns, ans, jns, cc, ac, agree) in rows:
        r = ac / cc if cc else 0
        cratios.append(r)
        print(f"| {label:16} | {fmt_ns(cc):>9} | {fmt_ns(ac):>9} | {r:>5.2f}x |")
    print(f"\n**geomean compile AOT/C = {gmean(cratios):.2f}x**")


def gmean(xs):
    xs = [x for x in xs if x and x > 0]
    if not xs:
        return 0
    p = 1.0
    for x in xs:
        p *= x
    return p ** (1.0 / len(xs))


if __name__ == "__main__":
    main()
