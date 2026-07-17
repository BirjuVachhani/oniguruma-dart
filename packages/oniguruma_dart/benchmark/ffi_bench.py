#!/usr/bin/env python3
"""Measure the sibling `oniguruma_native` package (native Oniguruma driven from
Dart via FFI) on the canonical 13 mainstream patterns, and fold the results
into mainstream_results.json as two engines:

  ONIG_FFI       the package's real per-match API (OnigScanner.findNextMatch):
                 one FFI crossing + one result object per match.
  ONIG_FFI_BULK  OnigScanner.scanCount: the whole corpus scanned in a single
                 FFI crossing, no per-match allocation (native-from-Dart
                 ceiling, directly comparable to the C loop).

Both run the identical corpora + patterns as every other engine, and the match
count is cross-checked against the suite's COUNT before the numbers are kept.

Run mainstream.py --run FIRST (it rewrites the JSON); this and byteapi_bench.py
then load-modify-save their engines on top.
"""
import json, os, re, subprocess

# .../packages/oniguruma_dart
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# .../packages/oniguruma_native (sibling package that owns the harness + build hook)
FFI_PKG = os.path.normpath(os.path.join(ROOT, "..", "oniguruma_native"))
JSON = os.path.join(ROOT, "benchmark/mainstream_results.json")
DATASETS = os.path.join(ROOT, "benchmark/datasets")
TARGET = "bin/mainstream_bench.dart"  # entry point, relative to FFI_PKG
OUTDIR = "build/bench_ffi"            # `dart build cli` output (bundle/ inside)

# RAW <label> <matches> <perMatchNs> <bulkNs>
RAW = re.compile(r"^RAW\t(\S+)\t(\d+)\t([\d.]+)\t([\d.]+)$")


def main():
    ascii_c = os.path.join(DATASETS, "corpus.txt")
    uni_c = os.path.join(DATASETS, "unicode_corpus.txt")

    # Build an AOT CLI bundle with `dart build cli`: this bundles the native
    # code asset (produced by the package's build hook) next to an AOT exe —
    # unlike `dart run` (JIT) or `dart compile exe` (which doesn't bundle the
    # code asset in this SDK). So the FFI engine is measured AOT, like the
    # port's own `dart compile exe` binaries.
    build = subprocess.run(
        ["dart", "build", "cli", "-t", TARGET, "-o", OUTDIR],
        capture_output=True, text=True, cwd=FFI_PKG)
    if build.returncode != 0:
        raise SystemExit("`dart build cli` failed:\n"
                         f"{build.stdout}\n{build.stderr}")

    # The harness self-times (median of 5 adaptive runs), so one invocation is
    # enough.
    exe = os.path.join(FFI_PKG, OUTDIR, "bundle", "bin", "mainstream_bench")
    proc = subprocess.run([exe, ascii_c, uni_c],
                          capture_output=True, text=True, cwd=FFI_PKG)
    out = proc.stdout

    per, bulk, cnt = {}, {}, {}
    for ln in out.splitlines():
        m = RAW.match(ln)
        if m:
            lab = m.group(1)
            cnt[lab] = int(m.group(2))
            per[lab] = float(m.group(3))
            bulk[lab] = float(m.group(4))

    if not per:
        raise SystemExit("no RAW lines parsed from FFI harness.\n"
                         f"stdout:\n{out}\nstderr:\n{proc.stderr}")

    data = json.load(open(JSON))
    count = data.get("COUNT", {})
    print(f"{'pattern':16}{'per-match ns':>16}{'bulk ns':>14}"
          f"{'count':>10}{'==suite?':>10}")
    ok = True
    for lab in per:
        agree = cnt[lab] == count.get(lab)
        ok = ok and agree
        print(f"{lab:16}{per[lab]:>16,.0f}{bulk[lab]:>14,.0f}"
              f"{cnt[lab]:>10,}{'yes' if agree else 'NO!!':>10}")

    data["ONIG_FFI"] = per
    data["ONIG_FFI_BULK"] = bulk
    json.dump(data, open(JSON, "w"), indent=2)
    print(f"\ncount cross-check vs suite COUNT: "
          f"{'ALL AGREE' if ok else 'MISMATCH'}")
    print(f"wrote ONIG_FFI + ONIG_FFI_BULK -> {JSON}")


if __name__ == "__main__":
    main()
