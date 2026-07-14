#!/usr/bin/env python3
"""Measure the port's BYTE API (bench_dart, mirrors onig_cli) on the canonical
13 mainstream patterns, and fold the result into mainstream_results.json as
ONIG_BYTE. Directly comparable to ONIG_C (identical scan-all-matches harness)."""
import json, os, re, statistics, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "benchmark/bench_dart")
JSON = os.path.join(ROOT, "benchmark/mainstream_results.json")
CORPUS = {"ascii": os.path.join(ROOT, "benchmark/datasets/corpus.txt"),
          "uni": os.path.join(ROOT, "benchmark/datasets/unicode_corpus.txt")}
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
LINE = re.compile(r"^(\d+) matches, ([\d.]+) ns/search-scan")


def bench(pat, corpus, iters=30, trials=5):
    vals, cnt = [], None
    for _ in range(trials):
        out = subprocess.run([BIN, "bench", pat, CORPUS[corpus], str(iters)],
                             capture_output=True, text=True, cwd=ROOT).stdout.strip()
        m = LINE.match(out)
        if m:
            cnt = int(m.group(1)); vals.append(float(m.group(2)))
    return cnt, statistics.median(vals)


def main():
    data = json.load(open(JSON))
    count = data["COUNT"]
    byte = {}
    print(f"{'pattern':16}{'byte ns':>14}{'count':>10}{'== String count?':>18}")
    ok = True
    for lab, pat, corpus in PATTERNS:
        c, ns = bench(pat, corpus)
        byte[lab] = ns
        agree = c == count.get(lab)
        ok = ok and agree
        print(f"{lab:16}{ns:>14,.0f}{c:>10,}{'yes' if agree else 'NO!!':>18}")
    data["ONIG_BYTE"] = byte
    json.dump(data, open(JSON, "w"), indent=2)
    print(f"\ncount cross-check vs String API: {'ALL AGREE' if ok else 'MISMATCH'}")
    print(f"wrote ONIG_BYTE -> {JSON}")


if __name__ == "__main__":
    main()
