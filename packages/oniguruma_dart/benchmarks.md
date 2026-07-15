# oniguruma_dart — Benchmarks

Pure-Dart port of the [Oniguruma](https://github.com/kkos/oniguruma) regex engine, measured head-to-head against the native C library and the two production regex interpreters available to Dart programs.

**Measured:** 2026-07-14 · editor-idle, background indexing quiesced · AOT builds · median of 5 trials.

## What is measured

Each number is the **median wall-clock time to scan an entire corpus for every non-overlapping match** of a pattern (compile once, then find all matches). Lower is faster. All engines run the identical scan loop over the identical input, and every run is cross-checked to report the **same match count** before timing, so no comparison is made across diverging behaviour.

### Engines

| engine | what it is |
|---|---|
| **Oniguruma C** | the original C library (native machine code) — the reference |
| **V8 JIT** | the default Node.js `RegExp` — native-compiled Irregexp (fastest; shown for reference) |
| **V8 interp** | that same engine forced to bytecode-interpret (`node --regexp-interpret-all`) — like-for-like with the other interpreters |
| **Dart RegExp** | the Dart SDK's built-in `RegExp` (V8 Irregexp inside the Dart VM) |
| **port · byte** | this port's byte API — matches a `Uint8List` (UTF-8), returns byte offsets |
| **port · String** | this port's idiomatic `String` API (`OnigRegex.allMatches`) — encodes + maps offsets back to UTF-16 |

### Environment

| | |
|---|---|
| CPU | Apple M1 Pro (10 cores) |
| OS | macOS 26.5.2 (arm64) |
| Dart SDK | 3.12.2 (stable, AOT `dart compile exe`) |
| Node.js | v26.4.0 |
| Oniguruma C | 6.9.10 (native, `-O2`) |

### Corpora

- `corpus.txt — 1,135,637 bytes, 100% ASCII`
- `unicode_corpus.txt — 904,352 bytes / 568,854 UTF-16 units, 38% ASCII`

## Absolute throughput (median time per full-corpus scan)

| pattern | regex | matches | Oniguruma C | V8 JIT | V8 interp | Dart RegExp | port · byte | port · String |
|---|---|--:|--:|--:|--:|--:|--:|--:|
| literal | `lorem` | 7,856 | 1.96 ms | 1.17 ms | 1.17 ms | 3.70 ms | 1.30 ms | 1.75 ms |
| literal-unicode | `東京` | 2,938 | 898 µs | 167 µs | 166 µs | 649 µs | 703 µs | 917 µs |
| alt-5 | `lorem\|ipsum\|dolor\|sit\|amet` | 39,251 | 17.84 ms | 4.69 ms | 11.31 ms | 21.72 ms | 17.53 ms | 19.12 ms |
| class-lower | `[a-z]+` | 166,221 | 25.66 ms | 6.92 ms | 21.33 ms | 33.35 ms | 12.55 ms | 20.11 ms |
| class-digit | `[0-9]+` | 5,972 | 4.62 ms | 365 µs | 1.34 ms | 36.52 ms | 1.72 ms | 1.93 ms |
| word-w | `\w+` | 172,193 | 28.20 ms | 7.17 ms | 21.21 ms | 33.97 ms | 14.22 ms | 22.14 ms |
| two-words | `[a-z]+ [a-z]+` | 75,064 | 17.34 ms | 5.22 ms | 22.57 ms | 35.17 ms | 12.84 ms | 15.96 ms |
| word-boundary | `\b\w{5}\b` | 39,418 | 21.39 ms | 6.53 ms | 54.40 ms | 40.01 ms | 19.36 ms | 21.02 ms |
| email-like | `\w+@\w+` | 2,027 | 32.78 ms | 14.53 ms | 77.88 ms | 124.76 ms | 2.58 ms | 2.87 ms |
| named-group | `(?<w>[a-z]+)` | 166,221 | 26.39 ms | 11.43 ms | 26.00 ms | 36.92 ms | 14.51 ms | 22.36 ms |
| case-insens | `(?i)lorem` | 7,856 | 5.88 ms | 1.28 ms | 2.69 ms | 3.76 ms | 2.26 ms | 2.80 ms |
| backref-dup | `(\w+) \1` | 15,606 | 39.30 ms | 15.44 ms | 99.17 ms | 151.35 ms | 135.62 ms | 135.67 ms |
| greedy-dotstar | `.*lorem` | 6,518 | 10.04 ms | 89.00 ms | 274.50 ms | 396.84 ms | 5.75 ms | 6.07 ms |

## Normalized to Oniguruma C  (×C — <1.00 faster than C, >1.00 slower)

| pattern | V8 JIT | V8 interp | Dart RegExp | port · byte | port · String |
|---|--:|--:|--:|--:|--:|
| literal | 0.60× | 0.60× | 1.89× | 0.66× | 0.89× |
| literal-unicode | 0.19× | 0.18× | 0.72× | 0.78× | 1.02× |
| alt-5 | 0.26× | 0.63× | 1.22× | 0.98× | 1.07× |
| class-lower | 0.27× | 0.83× | 1.30× | 0.49× | 0.78× |
| class-digit | 0.08× | 0.29× | 7.90× | 0.37× | 0.42× |
| word-w | 0.25× | 0.75× | 1.20× | 0.50× | 0.79× |
| two-words | 0.30× | 1.30× | 2.03× | 0.74× | 0.92× |
| word-boundary | 0.31× | 2.54× | 1.87× | 0.90× | 0.98× |
| email-like | 0.44× | 2.38× | 3.81× | 0.08× | 0.09× |
| named-group | 0.43× | 0.99× | 1.40× | 0.55× | 0.85× |
| case-insens | 0.22× | 0.46× | 0.64× | 0.38× | 0.48× |
| backref-dup | 0.39× | 2.52× | 3.85× | 3.45× | 3.45× |
| greedy-dotstar | 8.86× | 27.33× | 39.51× | 0.57× | 0.60× |

### Geomean over all 13 patterns (×C)

| engine | geomean vs C |
|---|--:|
| Oniguruma C | 1.00×  ← reference |
| V8 JIT | 0.37×  **(faster than C on average)** |
| V8 interp | 1.09× |
| Dart RegExp | 2.26× |
| port · byte | 0.59×  **(faster than C on average)** |
| port · String | 0.73×  **(faster than C on average)** |

## Port: byte API vs String API

The byte API matches raw UTF-8 bytes; the String API adds a UTF-8 encode (memoized per input), byte→UTF-16 offset mapping, and `Match` objects. The gap is the cost of the idiomatic `String` surface.

| pattern | port · byte | port · String | String overhead |
|---|--:|--:|--:|
| literal | 1.30 ms | 1.75 ms | 1.35× |
| literal-unicode | 703 µs | 917 µs | 1.30× |
| alt-5 | 17.53 ms | 19.12 ms | 1.09× |
| class-lower | 12.55 ms | 20.11 ms | 1.60× |
| class-digit | 1.72 ms | 1.93 ms | 1.13× |
| word-w | 14.22 ms | 22.14 ms | 1.56× |
| two-words | 12.84 ms | 15.96 ms | 1.24× |
| word-boundary | 19.36 ms | 21.02 ms | 1.09× |
| email-like | 2.58 ms | 2.87 ms | 1.11× |
| named-group | 14.51 ms | 22.36 ms | 1.54× |
| case-insens | 2.26 ms | 2.80 ms | 1.24× |
| backref-dup | 135.62 ms | 135.67 ms | 1.00× |
| greedy-dotstar | 5.75 ms | 6.07 ms | 1.06× |
| **geomean** | | | **1.24×** |

## How to read the results

- On the **String API** (the number Dart programs actually get), the port is on average **0.73× C** — i.e. faster than the native library across the suite. It beats/ties C on **10/13**, beats **Dart RegExp on 12/13**, and beats the **V8 interpreter on 6/13**.
- The **byte API** is faster still (no encode, no offset mapping, no match objects) — it's the right choice when working with `Uint8List` directly.
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
python3 benchmark/mainstream.py --run   # C · V8 interp · Dart RegExp · port String
python3 benchmark/byteapi_bench.py      # port byte API
python3 benchmark/gen_benchmarks_md.py  # regenerate this file
```
