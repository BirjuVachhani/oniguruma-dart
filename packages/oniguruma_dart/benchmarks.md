# oniguruma_dart — Benchmarks

Pure-Dart port of the [Oniguruma](https://github.com/kkos/oniguruma) regex engine, measured head-to-head against the native C library and the two production regex interpreters available to Dart programs.

**Measured:** 2026-07-15 · median of 5 trials, all engines back-to-back in one session. Absolute ms carry some machine-load noise; the **ratios** (normalized to C, geomeans, and the FFI-vs-port head-to-head) are the intended signal and are stable across runs because every engine pays the same contention.

## What is measured

Each number is the **median wall-clock time to scan an entire corpus for every non-overlapping match** of a pattern (compile once, then find all matches). Lower is faster. All engines run the identical scan loop over the identical input, and every run is cross-checked to report the **same match count** before timing, so no comparison is made across diverging behaviour.

### Engines

| engine | what it is |
|---|---|
| **Oniguruma C** | the original C library (native machine code) — the reference |
| **V8 JIT** | the default Node.js `RegExp` — native-compiled Irregexp (fastest; shown for reference) |
| **V8 interp** | that same engine forced to bytecode-interpret (`node --regexp-interpret-all`) — like-for-like with the other interpreters |
| **Dart RegExp** | the Dart SDK's built-in `RegExp` (V8 Irregexp inside the Dart VM) |
| **FFI · per-match** | the [`oniguruma_native`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_native) package — the *same* native C library, driven from Dart via `dart:ffi` through its real `OnigScanner.findNextMatch` API (one FFI crossing + one result object per match). Uses UTF-16LE so offsets line up with Dart `String` indices. |
| **FFI · bulk** | `oniguruma_native`'s `OnigScanner.scanCount` — the whole corpus scanned in a **single** FFI crossing (no per-match allocation): the native-from-Dart throughput ceiling, directly comparable to Oniguruma C. |
| **wasm · per-match** | `oniguruma_native`'s **web** backend — the *same* Oniguruma + shim compiled to wasm32-wasi and driven through the browser `WebAssembly` API (measured under Node/V8, the engine Chrome runs), via the same `findNextMatch` API. Isolates the wasm engine cost from the dart2js/dart2wasm marshalling layer. |
| **wasm · bulk** | the web backend's `scanCount` — the whole corpus scanned in a **single** crossing into the wasm module: the wasm throughput ceiling. |
| **port · byte** | this port's byte API — matches a `Uint8List` (UTF-8), returns byte offsets |
| **port · String** | this port's idiomatic `String` API (`OnigRegex.allMatches`) — encodes + maps offsets back to UTF-16 |

### Environment

| | |
|---|---|
| CPU | Apple M1 Pro (10 cores) |
| OS | macOS 26.5.2 (arm64) |
| Dart SDK | 3.12.2 (stable; port AOT `dart compile exe`, FFI via `dart run`) |
| Node.js | v26.4.0 |
| Oniguruma C | 6.9.10 (native `-O2` for the C baseline; `oniguruma_native` links the same 6.9.10 as UTF-16LE) |

### Corpora

- `corpus.txt — 1,135,637 bytes, 100% ASCII`
- `unicode_corpus.txt — 904,352 bytes / 568,854 UTF-16 units, 38% ASCII`

## Absolute throughput (median time per full-corpus scan)

| pattern | regex | matches | Oniguruma C | V8 JIT | V8 interp | Dart RegExp | FFI · per-match | FFI · bulk | wasm · per-match | wasm · bulk | port · byte | port · String |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| literal | `lorem` | 7,856 | 1.92 ms | 1.15 ms | 1.14 ms | 3.67 ms | 3.60 ms | 3.24 ms | 4.50 ms | 3.84 ms | 1.27 ms | 1.72 ms |
| literal-unicode | `東京` | 2,938 | 868 µs | 159 µs | 162 µs | 641 µs | 2.11 ms | 1.96 ms | 2.75 ms | 2.48 ms | 711 µs | 884 µs |
| alt-5 | `lorem\|ipsum\|dolor\|sit\|amet` | 39,251 | 17.91 ms | 4.55 ms | 11.11 ms | 21.17 ms | 19.29 ms | 18.39 ms | 30.97 ms | 27.56 ms | 17.57 ms | 19.11 ms |
| class-lower | `[a-z]+` | 166,221 | 26.38 ms | 6.72 ms | 21.38 ms | 33.52 ms | 33.52 ms | 29.91 ms | 52.26 ms | 37.78 ms | 12.48 ms | 21.34 ms |
| class-digit | `[0-9]+` | 5,972 | 4.55 ms | 330 µs | 1.31 ms | 36.22 ms | 14.32 ms | 14.23 ms | 32.71 ms | 32.20 ms | 1.68 ms | 2.00 ms |
| word-w | `\w+` | 172,193 | 27.87 ms | 6.99 ms | 20.88 ms | 34.53 ms | 31.98 ms | 28.12 ms | 48.61 ms | 33.70 ms | 14.23 ms | 24.53 ms |
| two-words | `[a-z]+ [a-z]+` | 75,064 | 21.88 ms | 5.20 ms | 21.96 ms | 35.07 ms | 25.94 ms | 24.23 ms | 48.26 ms | 41.56 ms | 12.83 ms | 16.25 ms |
| word-boundary | `\b\w{5}\b` | 39,418 | 21.30 ms | 6.34 ms | 53.30 ms | 39.39 ms | 25.82 ms | 22.25 ms | 51.29 ms | 49.23 ms | 19.23 ms | 21.32 ms |
| email-like | `\w+@\w+` | 2,027 | 32.51 ms | 14.25 ms | 76.62 ms | 125.42 ms | 35.82 ms | 36.88 ms | 89.39 ms | 88.60 ms | 2.62 ms | 2.85 ms |
| named-group | `(?<w>[a-z]+)` | 166,221 | 27.06 ms | 10.79 ms | 26.10 ms | 36.18 ms | 35.35 ms | 30.65 ms | 54.51 ms | 38.93 ms | 14.52 ms | 24.39 ms |
| case-insens | `(?i)lorem` | 7,856 | 5.65 ms | 1.26 ms | 2.64 ms | 3.74 ms | 17.70 ms | 17.54 ms | 38.46 ms | 38.04 ms | 2.28 ms | 2.78 ms |
| backref-dup | `(\w+) \1` | 15,606 | 41.14 ms | 15.03 ms | 96.00 ms | 149.75 ms | 42.07 ms | 40.09 ms | 99.33 ms | 97.54 ms | 133.32 ms | 133.34 ms |
| greedy-dotstar | `.*lorem` | 6,518 | 10.09 ms | 86.17 ms | 266.50 ms | 382.09 ms | 11.67 ms | 11.58 ms | 22.11 ms | 21.34 ms | 5.71 ms | 5.95 ms |

![Per-pattern scan time for every engine (log scale, shorter is faster)](https://raw.githubusercontent.com/BirjuVachhani/oniguruma-dart/main/packages/oniguruma_dart/benchmark/charts/absolute.png)

## Normalized to Oniguruma C  (×C — <1.00 faster than C, >1.00 slower)

| pattern | V8 JIT | V8 interp | Dart RegExp | FFI · per-match | FFI · bulk | wasm · per-match | wasm · bulk | port · byte | port · String |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| literal | 0.60× | 0.59× | 1.91× | 1.87× | 1.69× | 2.34× | 2.00× | 0.66× | 0.90× |
| literal-unicode | 0.18× | 0.19× | 0.74× | 2.43× | 2.26× | 3.17× | 2.86× | 0.82× | 1.02× |
| alt-5 | 0.25× | 0.62× | 1.18× | 1.08× | 1.03× | 1.73× | 1.54× | 0.98× | 1.07× |
| class-lower | 0.25× | 0.81× | 1.27× | 1.27× | 1.13× | 1.98× | 1.43× | 0.47× | 0.81× |
| class-digit | 0.07× | 0.29× | 7.97× | 3.15× | 3.13× | 7.19× | 7.08× | 0.37× | 0.44× |
| word-w | 0.25× | 0.75× | 1.24× | 1.15× | 1.01× | 1.74× | 1.21× | 0.51× | 0.88× |
| two-words | 0.24× | 1.00× | 1.60× | 1.19× | 1.11× | 2.21× | 1.90× | 0.59× | 0.74× |
| word-boundary | 0.30× | 2.50× | 1.85× | 1.21× | 1.04× | 2.41× | 2.31× | 0.90× | 1.00× |
| email-like | 0.44× | 2.36× | 3.86× | 1.10× | 1.13× | 2.75× | 2.72× | 0.08× | 0.09× |
| named-group | 0.40× | 0.96× | 1.34× | 1.31× | 1.13× | 2.01× | 1.44× | 0.54× | 0.90× |
| case-insens | 0.22× | 0.47× | 0.66× | 3.13× | 3.11× | 6.81× | 6.74× | 0.40× | 0.49× |
| backref-dup | 0.37× | 2.33× | 3.64× | 1.02× | 0.97× | 2.41× | 2.37× | 3.24× | 3.24× |
| greedy-dotstar | 8.54× | 26.41× | 37.87× | 1.16× | 1.15× | 2.19× | 2.11× | 0.57× | 0.59× |

### Geomean over all 13 patterns (×C)

| engine | geomean vs C |
|---|--:|
| Oniguruma C | 1.00×  ← reference |
| V8 JIT | 0.35×  **(faster than C on average)** |
| V8 interp | 1.05× |
| Dart RegExp | 2.21× |
| FFI · per-match | 1.49× |
| FFI · bulk | 1.39× |
| wasm · per-match | 2.66× |
| wasm · bulk | 2.34× |
| port · byte | 0.58×  **(faster than C on average)** |
| port · String | 0.73×  **(faster than C on average)** |

![Geometric mean of scan time vs Oniguruma C across all 13 patterns (shorter is faster; dashed line = the C baseline)](https://raw.githubusercontent.com/BirjuVachhani/oniguruma-dart/main/packages/oniguruma_dart/benchmark/charts/geomean.png)

## Primary comparison: `oniguruma_native` (native) vs the pure-Dart port

The two packages in this repo solve the same problem two ways: [`oniguruma_native`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_native) binds the **real C library** through `dart:ffi`, while `oniguruma_dart` is a **pure-Dart** re-implementation. Same corpora, same patterns, identical match counts — so this is a direct apples-to-apples of the two ways to run Oniguruma from Dart.

![oniguruma_native (native FFI) vs the pure-Dart port — median time per full-corpus scan, log scale, shorter is faster](https://raw.githubusercontent.com/BirjuVachhani/oniguruma-dart/main/packages/oniguruma_dart/benchmark/charts/ffi-vs-port.png)

| pattern | matches | FFI · per-match | FFI · bulk | port · String | port · byte | port·String ÷ FFI·per-match |
|---|--:|--:|--:|--:|--:|--:|
| literal | 7,856 | 3.60 ms | 3.24 ms | 1.72 ms | 1.27 ms | 0.48× ✅ |
| literal-unicode | 2,938 | 2.11 ms | 1.96 ms | 884 µs | 711 µs | 0.42× ✅ |
| alt-5 | 39,251 | 19.29 ms | 18.39 ms | 19.11 ms | 17.57 ms | 0.99× ✅ |
| class-lower | 166,221 | 33.52 ms | 29.91 ms | 21.34 ms | 12.48 ms | 0.64× ✅ |
| class-digit | 5,972 | 14.32 ms | 14.23 ms | 2.00 ms | 1.68 ms | 0.14× ✅ |
| word-w | 172,193 | 31.98 ms | 28.12 ms | 24.53 ms | 14.23 ms | 0.77× ✅ |
| two-words | 75,064 | 25.94 ms | 24.23 ms | 16.25 ms | 12.83 ms | 0.63× ✅ |
| word-boundary | 39,418 | 25.82 ms | 22.25 ms | 21.32 ms | 19.23 ms | 0.83× ✅ |
| email-like | 2,027 | 35.82 ms | 36.88 ms | 2.85 ms | 2.62 ms | 0.08× ✅ |
| named-group | 166,221 | 35.35 ms | 30.65 ms | 24.39 ms | 14.52 ms | 0.69× ✅ |
| case-insens | 7,856 | 17.70 ms | 17.54 ms | 2.78 ms | 2.28 ms | 0.16× ✅ |
| backref-dup | 15,606 | 42.07 ms | 40.09 ms | 133.34 ms | 133.32 ms | 3.17× |
| greedy-dotstar | 6,518 | 11.67 ms | 11.58 ms | 5.95 ms | 5.71 ms | 0.51× ✅ |

**Head-to-head (geomean over the 13 patterns):**

- **port · String ÷ FFI · per-match = 0.49×** — for bulk find-all-matches the pure-Dart String API is ~2.0× *faster* than the FFI package's real per-match API, and wins on **12/13** patterns.
- **port · byte ÷ FFI · bulk = 0.42×** — even against FFI's single-crossing bulk scan, the pure-Dart byte API is ~2.4× faster.
- **FFI · bulk ÷ C = 1.39×** — the native library driven from Dart in one crossing runs at ~1.39× raw C; the gap is mostly UTF-16LE scanning ~2× the bytes of UTF-8 on ASCII text.

**Why the pure-Dart port wins this workload:**

- **Encoding.** `oniguruma_native` uses **UTF-16LE** so match offsets map 1:1 to Dart `String` indices with no remapping — but on ASCII-heavy text that is *twice* the bytes the port's UTF-8 engine scans, so skip-search and class scans cover 2× the memory.
- **Crossings.** Enumerating matches via `findNextMatch` costs one FFI call **per match** (plus a result object); on the 100k+-match patterns that boundary cost dominates. `scanCount` (bulk) removes it and closes most — but not all — of the gap.
- **In-process fast paths.** The port stays in the Dart heap with no marshalling and applies pattern-specific optimizations (e.g. the `email-like` walk-back is ~12× C).

**Where the FFI package wins — and why you'd still reach for it:**

- **`backref-dup`**: native Oniguruma is **3.2× faster** than the port (42.07 ms vs 133.34 ms). The port's backtracking back-reference is O(word²); the C engine handles pathological backtracking far better.
- **This benchmark is bulk find-all-matches** — the pure-Dart port's home turf. `oniguruma_native` targets **TextMate / Shiki tokenizers** (one `findNextMatch` per token over short lines, with vscode-oniguruma-compatible `OnigScanner` semantics). Reach for it when you need the real engine's exact behaviour/robustness or drop-in vscode-oniguruma compatibility on IO platforms — see `../oniguruma_native` and its replay benchmark for that workload.

## Web: `oniguruma_native` (WebAssembly) vs the pure-Dart port

`oniguruma_native` also runs on the web: the **same** Oniguruma 6.9.10 + shim compiled to a wasm32-wasi module and driven over `dart:js_interop` (byte-identical results to native). The numbers below measure that wasm module through the browser `WebAssembly` API under **Node/V8** — the engine Chrome runs too — so they sit on the same footing as the other V8 rows and isolate the **wasm engine cost** from whatever the dart2js/dart2wasm compiler adds on top. `oniguruma_dart` runs on the web as plain compiled Dart (no wasm module), so this is the head-to-head for the two packages' web paths.

| pattern | matches | wasm · per-match | wasm · bulk | FFI · bulk (native) | wasm·bulk ÷ C | port · String |
|---|--:|--:|--:|--:|--:|--:|
| literal | 7,856 | 4.50 ms | 3.84 ms | 3.24 ms | 2.00× | 1.72 ms |
| literal-unicode | 2,938 | 2.75 ms | 2.48 ms | 1.96 ms | 2.86× | 884 µs |
| alt-5 | 39,251 | 30.97 ms | 27.56 ms | 18.39 ms | 1.54× | 19.11 ms |
| class-lower | 166,221 | 52.26 ms | 37.78 ms | 29.91 ms | 1.43× | 21.34 ms |
| class-digit | 5,972 | 32.71 ms | 32.20 ms | 14.23 ms | 7.08× | 2.00 ms |
| word-w | 172,193 | 48.61 ms | 33.70 ms | 28.12 ms | 1.21× | 24.53 ms |
| two-words | 75,064 | 48.26 ms | 41.56 ms | 24.23 ms | 1.90× | 16.25 ms |
| word-boundary | 39,418 | 51.29 ms | 49.23 ms | 22.25 ms | 2.31× | 21.32 ms |
| email-like | 2,027 | 89.39 ms | 88.60 ms | 36.88 ms | 2.72× | 2.85 ms |
| named-group | 166,221 | 54.51 ms | 38.93 ms | 30.65 ms | 1.44× | 24.39 ms |
| case-insens | 7,856 | 38.46 ms | 38.04 ms | 17.54 ms | 6.74× | 2.78 ms |
| backref-dup | 15,606 | 99.33 ms | 97.54 ms | 40.09 ms | 2.37× | 133.34 ms |
| greedy-dotstar | 6,518 | 22.11 ms | 21.34 ms | 11.58 ms | 2.11× | 5.95 ms |

**Head-to-head (geomean over the 13 patterns):**

- **wasm · bulk ÷ C = 2.34×** (per-match 2.66×) — the wasm build runs at ~2.3× native C; wasm is an interpreter-free but still-sandboxed target, so it trails native machine code.
- **wasm · bulk ÷ FFI · bulk = 1.68×** — the *same* engine is ~1.7× slower compiled to wasm than as native code (plus the JS↔wasm marshalling the web path pays).
- **wasm · bulk ÷ port · String = 3.20×** — against the pure-Dart port's web story, `oniguruma_native`'s wasm path is ~3.2× slower for bulk scanning, on top of shipping a ~600 KB module. **For web, `oniguruma_dart` is the lighter and faster choice**; reach for `oniguruma_native` on the web only when you need exact native-engine semantics (TextMate/Shiki) on every platform behind one API.

## Port: byte API vs String API

The byte API matches raw UTF-8 bytes; the String API adds a UTF-8 encode (memoized per input), byte→UTF-16 offset mapping, and `Match` objects. The gap is the cost of the idiomatic `String` surface.

| pattern | port · byte | port · String | String overhead |
|---|--:|--:|--:|
| literal | 1.27 ms | 1.72 ms | 1.36× |
| literal-unicode | 711 µs | 884 µs | 1.24× |
| alt-5 | 17.57 ms | 19.11 ms | 1.09× |
| class-lower | 12.48 ms | 21.34 ms | 1.71× |
| class-digit | 1.68 ms | 2.00 ms | 1.19× |
| word-w | 14.23 ms | 24.53 ms | 1.72× |
| two-words | 12.83 ms | 16.25 ms | 1.27× |
| word-boundary | 19.23 ms | 21.32 ms | 1.11× |
| email-like | 2.62 ms | 2.85 ms | 1.09× |
| named-group | 14.52 ms | 24.39 ms | 1.68× |
| case-insens | 2.28 ms | 2.78 ms | 1.22× |
| backref-dup | 133.32 ms | 133.34 ms | 1.00× |
| greedy-dotstar | 5.71 ms | 5.95 ms | 1.04× |
| **geomean** | | | **1.26×** |

## How to read the results

- On the **String API** (the number Dart programs actually get), the port is on average **0.73× C** — i.e. faster than the native library across the suite. It beats/ties C on **11/13**, beats **Dart RegExp on 12/13**, and beats the **V8 interpreter on 6/13**.
- The **byte API** is faster still (no encode, no offset mapping, no match objects) — it's the right choice when working with `Uint8List` directly.
- Against the **native library over FFI** (`oniguruma_native`), the pure-Dart String API is ~2.0× faster for bulk scanning — see the primary comparison above. The FFI package's per-match crossings and UTF-16LE scanning cost more than in-process pure-Dart matching here; it pays off for tokenizer workloads and pathological backtracking (`backref-dup`).
- `email-like` is an *algorithmic* win: the driver walks back from each mandatory `@` to the run start (one attempt per `@`) instead of scanning every position, so it is ~12× faster than C's forward scan.
- The patterns where an engine still leads the port are **capability floors**, not tuning gaps:
  - **V8 interp** leads on `literal` / `alt-5` / `class-digit` via SIMD (`memchr`, Boyer–Moore lookahead, vectorized class scan) — no byte-level SIMD exists in pure Dart.
  - **`literal-unicode`** ≈ C: the residual vs RegExp is the UTF-8↔UTF-16 bridge (RegExp scans the String's native UTF-16 with zero copy).
  - **`backref-dup`** is O(word²) backtracking — even V8's interpreter is 2.5× C here.

## Correctness

Every optimization preserves **byte-identical parity with the C library**: 5,390 ported-oracle + unit tests, differential fuzzing vs the C CLI (0 divergences), and per-pattern match-count cross-checks (byte vs String vs C all agree). `dart analyze` is clean.

## Reproduce

```sh
dart compile exe benchmark/bench_vs_regexp.dart -o benchmark/bench_vs_regexp
dart compile exe benchmark/bench_dart.dart       -o benchmark/bench_dart
python3 benchmark/mainstream.py --run   # C · V8 JIT · V8 interp · Dart RegExp · port String
python3 benchmark/byteapi_bench.py      # port byte API
python3 benchmark/ffi_bench.py          # native FFI (per-match + bulk) via ../oniguruma_native
python3 benchmark/wasm_bench.py         # oniguruma_native WebAssembly backend (per-match + bulk)
python3 benchmark/gen_benchmarks_md.py  # regenerate this file
```
