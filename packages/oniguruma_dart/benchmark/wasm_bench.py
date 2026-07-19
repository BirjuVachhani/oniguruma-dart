#!/usr/bin/env python3
"""Measure the `oniguruma_native` package's WebAssembly backend on the canonical 13
mainstream patterns and fold the results into mainstream_results.json as two
engines:

  ONIG_WASM       the package's real per-match API (OnigScanner.findNextMatch)
                  running under WebAssembly: one wasm crossing + one result
                  object per match: the engine cost of oniguruma_native's *web*
                  path (what a browser consumer pays to enumerate matches).
  ONIG_WASM_BULK  onig_shim_scan_count under wasm: the whole corpus scanned in a
                  single crossing into the module (the wasm throughput ceiling).

It is the SAME Oniguruma 6.9.10 + shim as the FFI backend, compiled to
wasm32-wasi and driven through the browser `WebAssembly` API, measured here
under Node/V8 (the engine Chrome runs too), exactly like the suite's other V8
engines, so the numbers are directly comparable. This isolates the wasm engine
cost from the dart2js/dart2wasm compiler's own marshalling overhead.

Run mainstream.py --run FIRST (it rewrites the JSON); this then loads-modifies-
saves its two engines on top, like ffi_bench.py and byteapi_bench.py.
"""
import json, os, re, subprocess

# .../packages/oniguruma_dart
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSON = os.path.join(ROOT, "benchmark/mainstream_results.json")
HARNESS = os.path.join(ROOT, "benchmark/web/bench_wasm.mjs")
NODE = "node"

# RAW <label> <matches> <perMatchNs> <bulkNs>
RAW = re.compile(r"^RAW\t(\S+)\t(\d+)\t([\d.]+)\t([\d.]+)$")


def main():
    proc = subprocess.run([NODE, HARNESS], capture_output=True, text=True, cwd=ROOT)
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
        raise SystemExit("no RAW lines parsed from wasm harness.\n"
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

    data["ONIG_WASM"] = per
    data["ONIG_WASM_BULK"] = bulk
    json.dump(data, open(JSON, "w"), indent=2)
    print(f"\ncount cross-check vs suite COUNT: "
          f"{'ALL AGREE' if ok else 'MISMATCH'}")
    print(f"wrote ONIG_WASM + ONIG_WASM_BULK -> {JSON}")


if __name__ == "__main__":
    main()
