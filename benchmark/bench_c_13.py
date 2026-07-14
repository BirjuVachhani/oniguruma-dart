#!/usr/bin/env python3
"""C (libonig) numbers for the SAME 13 patterns as benchmark/bench_vs_regexp.dart.

Runs onig_cli's `bench` mode (compile once, scan whole corpus for all
non-overlapping matches) over the same corpora, so the ns/scan is directly
comparable to the Dart-VM and web harnesses. Auto-calibrates iters to ~300ms and
reports the median of 5 trials. Emits `RAW <label> <matches> <ns>` lines.
"""
import subprocess, re, statistics, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C_CLI = os.path.join(ROOT, "benchmark/c/onig_cli")
ASCII = os.path.join(ROOT, "benchmark/datasets/corpus.txt")
UNI = os.path.join(ROOT, "benchmark/datasets/unicode_corpus.txt")

# (label, pattern, corpus) — pattern is the C/Oniguruma equivalent of the
# bench_vs_regexp Case; case-insens uses inline (?i) instead of an option flag.
PATTERNS = [
    ("literal",         "lorem",                      ASCII),
    ("literal-unicode", "東京",                         UNI),
    ("alt-5",           "lorem|ipsum|dolor|sit|amet", ASCII),
    ("class-lower",     "[a-z]+",                     ASCII),
    ("class-digit",     "[0-9]+",                     ASCII),
    ("word-w",          r"\w+",                       ASCII),
    ("two-words",       "[a-z]+ [a-z]+",              ASCII),
    ("word-boundary",   r"\b\w{5}\b",                 ASCII),
    ("email-like",      r"\w+@\w+",                   ASCII),
    ("named-group",     "(?<w>[a-z]+)",               ASCII),
    ("case-insens",     "(?i)lorem",                  ASCII),
    ("backref-dup",     r"(\w+) \1",                  ASCII),
    ("greedy-dotstar",  ".*lorem",                    ASCII),
]

LINE = re.compile(r"^(\d+) matches, ([\d.]+) ns/search-scan")


def bench(pat, corpus, iters):
    hexpat = pat.encode("utf-8").hex()
    out = subprocess.run([C_CLI, "bench", hexpat, corpus, str(iters)],
                         capture_output=True, text=True, cwd=ROOT).stdout.strip()
    m = LINE.match(out)
    if not m:
        raise RuntimeError(f"onig_cli failed for {pat!r}: {out!r}")
    return int(m.group(1)), float(m.group(2))


def main():
    print("# C (libonig) — 13 patterns, ns per full-corpus scan (median of 5)\n")
    for label, pat, corpus in PATTERNS:
        # calibrate: one cheap run to size iters for ~300ms
        _, ns0 = bench(pat, corpus, 3)
        iters = max(5, min(20000, int(300e6 / ns0)))
        vals, count = [], None
        for _ in range(5):
            count, ns = bench(pat, corpus, iters)
            vals.append(ns)
        med = statistics.median(vals)
        print(f"RAW\t{label}\t{count}\t{med:.1f}")
    print("\ndone")


if __name__ == "__main__":
    main()
