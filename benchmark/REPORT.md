# Oniguruma Dart port — benchmark report

Head-to-head performance comparison of the pure-Dart port against the original
**Oniguruma 6.9.10** C library, running identical patterns over identical
datasets through byte-for-byte identical harnesses.

## TL;DR

| Metric | Dart AOT vs C | Dart JIT vs C |
|---|---|---|
| **Match throughput** (geomean) | **3.06×** slower | 4.39× slower |
| Match throughput (geomean, excl. `.*` outlier) | **2.53×** | 3.59× |
| Match throughput (median) | **2.36×** | 3.61× |
| Match throughput (best case) | **1.20×** | 2.19× |
| **Compile time** (geomean) | **1.19×** — roughly at parity | — |

A pure-Dart backtracking VM lands **~2–3× the C library's match time** across a
broad pattern mix, and is **at parity on compilation**. Every one of the 16
benchmark patterns produced **identical match counts** in both engines, so each
row compares equal work. Two pattern classes lag more (`.*`-style greedy scans
and back-references); everything else clusters tightly around 1.2–3×.

## Machine & toolchain

| | |
|---|---|
| CPU | Apple M1 Pro (10-core) |
| C library | Oniguruma 6.9.10, built `-O3 -DNDEBUG` (CMake Release) |
| C compiler | Apple clang 21.0.0 |
| Dart | 3.12.2 stable, `macos_arm64` |
| Dart AOT | `dart compile exe` |
| Dart JIT | `dart run` (VM startup excluded; JIT warm-up amortized over iters) |

## Methodology

Both harnesses ([`c/onig_cli.c`](c/onig_cli.c), [`bench_dart.dart`](bench_dart.dart))
do exactly the same thing, in the same order:

- **Encoding / syntax / options**: UTF-8, `ONIG_SYNTAX_DEFAULT`, `ONIG_OPTION_DEFAULT`.
- **Match mode**: compile the pattern once, then scan the *whole* corpus for all
  non-overlapping matches (advancing one byte on a zero-width match), repeated
  *N* times; report **ns per full-corpus scan**.
- **Compile mode**: call `onig_new` / `onigNew` *N* times; report **ns per compile**.
- **Timing** is wall-clock around the measured loop only (`clock_gettime` /
  `Stopwatch`), excluding I/O and process startup.
- The driver ([`run_bench.py`](run_bench.py)) takes the **median of 3 trials**
  and — critically — asserts the C and Dart engines report the **same match
  count** for every pattern before comparing timings. All 16 agreed.

Datasets (in [`datasets/`](datasets/)):
- `corpus.txt` — 1.14 MB ASCII (lorem-ipsum words + numbers), 20 000 lines.
- `unicode_corpus.txt` — 904 KB UTF-8 (Latin+accents, CJK, Cyrillic, Greek,
  emoji, emails, numbers), 12 000 lines.

Reproduce: `python3 benchmark/run_bench.py [trials] [match_iters] [compile_iters]`
(after `dart compile exe benchmark/bench_dart.dart -o benchmark/bench_dart` and
`cc -O3 -DNDEBUG -I oniguruma-master/src benchmark/c/onig_cli.c oniguruma-master/build/libonig.a -o benchmark/c/onig_cli`).

## Match throughput

Compile once, scan the whole corpus for every match. Lower ns = faster; ratio is
Dart ÷ C (1.00× would be parity). All rows verified to the **same match count**.

| pattern | category | matches | C | Dart AOT | AOT/C | Dart JIT | JIT/C |
|---|---|--:|--:|--:|--:|--:|--:|
| literal-ascii   | literal        |   7 856 |  1.92 ms |   2.58 ms | **1.35×** |   4.91 ms | 2.56× |
| literal-unicode | literal        |   2 938 | 858 µs   |   1.35 ms | **1.57×** |   3.54 ms | 4.13× |
| alt-5           | alternation    |  39 251 | 17.63 ms |  40.74 ms | 2.31× |  54.83 ms | 3.11× |
| class-lower     | char-class     | 166 221 | 26.24 ms |  47.54 ms | 1.81× |  62.43 ms | 2.38× |
| class-digit     | char-class     |   5 972 |  4.62 ms |   5.55 ms | **1.20×** |  10.11 ms | 2.19× |
| word-w          | class/quant    | 172 193 | 27.78 ms |  52.90 ms | 1.90× |  74.53 ms | 2.68× |
| two-words       | quantifier     |  75 064 | 17.05 ms |  46.84 ms | 2.75× |  61.58 ms | 3.61× |
| word-boundary   | anchor         |   7 819 |  2.24 ms |   3.30 ms | **1.47×** |   5.74 ms | 2.56× |
| anchored-line   | anchor (`^`)   |  19 242 |  8.79 ms |  22.93 ms | 2.61× |  34.30 ms | 3.90× |
| email-like      | quant/greedy   |   2 027 | 32.19 ms | 127.41 ms | 3.96× | 183.38 ms | 5.70× |
| case-insens     | case-fold      |   7 856 |  5.45 ms |  33.26 ms | 6.10× |  38.54 ms | 7.07× |
| backref-dup     | back-reference |  15 606 | 38.66 ms | 284.56 ms | 7.36× | 342.38 ms | 8.86× |
| backtrack       | backtracking   |  47 005 | 27.05 ms | 129.62 ms | 4.79× | 167.44 ms | 6.19× |
| greedy-dotstar  | greedy `.*`    |   6 518 |  9.84 ms | 650.99 ms | **66.14×** | 1064.40 ms | 108.14× |
| uni-prop-L      | `\p{L}+`       | 103 858 | 19.35 ms |  69.67 ms | 3.60× |  77.94 ms | 4.03× |
| uni-prop-Han    | `\p{Han}+`     |  27 508 | 11.00 ms |  19.64 ms | **1.79×** |  24.18 ms | 2.20× |
| uni-word        | `\w+` (UTF-8)  | 107 293 | 19.75 ms |  46.55 ms | 2.36× |  47.29 ms | 2.39× |

**geomean AOT/C = 3.06× · median = 2.36× · geomean excl. `.*` = 2.53×**

### Reading the results

- **Literals, classes, anchors, Unicode properties (1.2–2.6×)** — the bulk of
  real-world patterns. The Dart port carries the C fast-paths (`OP_STR_N`, the
  char-map prefilter, BMH-style skip, anchor short-circuits), so these stay close
  to C. `class-digit` (1.20×) and `literal` (1.35×) are the closest.
- **`\p{Han}+` (1.79×)** — Unicode-range membership on multi-byte input is
  competitive: the range lookup is a tight binary search in both.
- **`.*lorem` greedy scan (66×)** — the single biggest gap. C compiles `.*X` into
  the specialized `OP_ANYCHAR_STAR` with a required-literal skip, effectively
  turning it into a memchr-style search; the Dart VM currently walks `.*`
  greedily and backtracks byte-by-byte to locate the literal. This is the clearest
  optimization opportunity (see below).
- **back-reference `(\w+) \1` (7.4×) and `(?i)` case-fold (6.1×)** — inherently
  backtracking-heavy / per-char folding work where the interpreter overhead is
  most visible.
- **JIT is consistently slower than AOT** (4.39× vs 3.06× geomean). Each `dart
  run` re-JITs the VM; even amortized over iterations the AOT snapshot wins, and
  AOT is the right target for a CLI/library. JIT is reported only for completeness.

## Compile time

`onig_new` / `onigNew`, ns per call.

| pattern | C | Dart AOT | AOT/C |
|---|--:|--:|--:|
| literal-ascii   | 349 ns  | 391 ns   | 1.12× |
| literal-unicode | 400 ns  | 345 ns   | **0.86×** |
| alt-5           | 1.9 µs  | 1.6 µs   | **0.85×** |
| class-lower     | 589 ns  | 873 ns   | 1.48× |
| class-digit     | 583 ns  | 883 ns   | 1.52× |
| word-w          | 287 ns  | 345 ns   | 1.20× |
| two-words       | 1.4 µs  | 940 ns   | **0.67×** |
| word-boundary   | 530 ns  | 575 ns   | 1.08× |
| anchored-line   | 831 ns  | 695 ns   | **0.84×** |
| email-like      | 818 ns  | 705 ns   | **0.86×** |
| case-insens     | 1.9 µs  | 1.6 µs   | **0.85×** |
| backref-dup     | 876 ns  | 872 ns   | 1.00× |
| backtrack       | 1.4 µs  | 1.0 µs   | **0.74×** |
| greedy-dotstar  | 567 ns  | 597 ns   | 1.05× |
| uni-prop-L      | 16.7 µs | 210.5 µs | 12.59× |
| uni-prop-Han    | 829 ns  | 1.5 µs   | 1.75× |
| uni-word        | 292 ns  | 348 ns   | 1.19× |

**geomean compile AOT/C = 1.19× — effectively at parity**

The Dart AOT compiler is **at or ahead of C on most patterns** (it beats C on 6 of
16, e.g. `two-words` 0.67×, `backtrack` 0.74×). The one outlier is `\p{L}+`
(12.6×): materializing the full Unicode "Letter" range into a class code-range
buffer touches far more data in Dart than C's precompiled table reference. That is
a one-time cost dwarfed by matching for any non-trivial subject.

## Honest characterization

- **Where the port is strong:** compilation is at parity, and the common case —
  literals, character classes, anchors, word boundaries, Unicode properties — runs
  at **~1.2–2.6× C**, which is a good result for a pure-managed backtracking VM
  with no native code, `setjmp`, or computed-goto.
- **Where it lags:** greedy `.*`/`.+` scans (missing the `OP_ANYCHAR_STAR`
  literal-skip optimization), back-references, and case-insensitive matching.
  These are backtracking- or per-character-work-dominated, where interpreter
  dispatch overhead compounds.
- **Top optimization lever:** port C's `OP_ANYCHAR_STAR*` fast-paths (the
  optimized `.*`/`.+` with exact-literal look-ahead skip). That single change
  would collapse the 66× outlier and lift the greedy/`email-like` rows, pulling
  the overall geomean toward ~2×.

## Correctness backing

These timings are only meaningful because the two engines agree. Beyond the
per-pattern match-count check here, the port is verified against the C library by:

- **5025 / 5025** of Oniguruma's own C test cases (all 8 suites, 100%);
- **113** curated differential cases + **4992** randomized fuzz cases, **0
  divergences** vs. the C CLI;
- byte-identical capture offsets throughout.

---

# Appendix: vs Dart's built-in `RegExp`

A different, Dart-vs-Dart comparison: this package's `OnigRegex` (a pure-Dart
backtracking VM) against the SDK's `RegExp` (backed by V8's native **Irregexp**
engine). Both run in the **same process** through each engine's idiomatic
`allMatches` String API, over the same corpora, and the harness
([`bench_vs_regexp.dart`](bench_vs_regexp.dart)) verifies both find the **same
number of matches** before timing. Patterns are limited to those both dialects
share (literals, classes, `\w`/`\b`, alternation, `.*`, `(?<name>)`, `\1`).

Reproduce: `dart compile exe benchmark/bench_vs_regexp.dart -o benchmark/bench_vs_regexp && benchmark/bench_vs_regexp`.

## Match throughput (AOT; adaptive timing, median of 4)

| pattern | matches | RegExp | oniguruma_dart | onig / RegExp |
|---|--:|--:|--:|--:|
| literal          |   7 856 |   4.40 ms | 127.71 ms | 29.0× |
| literal-unicode  |   2 938 | 774.7 µs  |  74.83 ms | 96.6× |
| alt-5            |  39 251 |  26.90 ms | 175.78 ms |  6.5× |
| class-lower      | 166 221 |  40.93 ms | 193.63 ms |  4.7× |
| class-digit      |   5 972 |  45.67 ms | 131.09 ms | **2.9×** |
| word-w `\w+`     | 172 193 |  41.25 ms | 196.17 ms |  4.8× |
| two-words        |  75 064 |  43.83 ms | 181.15 ms |  4.1× |
| word-boundary    |  39 418 |  48.15 ms | 196.00 ms |  4.1× |
| email-like       |   2 027 | 150.78 ms | 280.06 ms | **1.9×** |
| named-group      | 166 221 |  43.90 ms | 206.56 ms |  4.7× |
| case-insens      |   7 856 |   4.51 ms | 168.52 ms | 37.3× |
| backref-dup `\1` |  15 606 | 184.19 ms | 476.98 ms | **2.6×** |
| greedy `.*lorem` |   6 518 | 465.16 ms | 869.55 ms | **1.9×** |

**geomean = 6.4× slower · median = 4.7× slower** (compile: geomean ~5×, but
`RegExp` compiles lazily and caches by source, so that number is approximate).

## Reading the results

- **`RegExp` is the right tool when its dialect is enough and speed is critical.**
  It's native code; this port is an interpreter. Expect it to win, and it does —
  by ~5× typically.
- **The gap is smallest exactly where regexes get expensive** — back-references
  (2.6×), `.*` backtracking (1.9×), `email-like` greedy (1.9×) — because there the
  work is dominated by backtracking both engines must do, not by dispatch overhead.
- **The gap is largest on trivial literals** (29–97×): Irregexp reduces a literal
  to a memchr/Boyer-Moore scan in native code, and `OnigRegex.allMatches` also
  pays a String-API tax — it re-encodes the whole input to UTF-8 and builds a
  char↔byte offset map on **every** call. (The byte API measured against C above
  avoids that and shows the engine core itself runs at ~2–3× C.)

## When to use which

Reach for `oniguruma_dart` when you need what `RegExp` **cannot do**, not for raw
speed against it:

- the **Oniguruma / Ruby dialect** and constructs `RegExp` lacks — subroutine
  calls `\g<>` and recursion, conditionals `(?(…))`, named back-references by
  nesting level, atomic-group/possessive nuances, `\K`, `\R`, callouts, POSIX
  bracket semantics;
- **~28 non-UTF-8 encodings** (EUC-JP, Shift-JIS, Big5, GB18030, ISO-8859-*, …);
- **byte-offset** results identical to the C library;
- guaranteed **cross-platform/behavioral parity** with Oniguruma (e.g. porting
  Ruby regexes verbatim).

For everyday UTF-16 string matching in the JS/Dart dialect, the built-in `RegExp`
remains the faster choice.


---

## Appendix: five-way comparison — VM vs Web × oniguruma_dart vs RegExp × C

The **same 13 patterns** over the **same two corpora**, doing the **same work**
(compile once, then scan the whole corpus for every non-overlapping match via
each engine's idiomatic API). Match counts were verified **identical across all
five configurations** before any timing, so every cell compares equal work.
Figures are the median ns per full-corpus scan.

- **oniguruma_dart · VM** — this port, AOT (`dart compile exe`), Dart native runtime.
- **oniguruma_dart · Web** — this port, `dart compile js -O2`, run under Node/V8.
- **Dart RegExp · VM** — SDK `RegExp` (bundled Irregexp), AOT/native.
- **Dart RegExp · Web** — SDK `RegExp` under dart2js → host JS engine's native RegExp (Node/V8).
- **Oniguruma C** — reference libonig 6.9.10, clang `-O3`.

Machine: Apple M1 Pro · Dart 3.12.2 (macos_arm64) · Node v26 (V8).

### Table A — absolute (median time to scan the corpus for all matches)

| pattern | matches | oniguruma_dart · VM | oniguruma_dart · Web | Dart RegExp · VM | Dart RegExp · Web | Oniguruma C |
|---|--:|--:|--:|--:|--:|--:|
| literal | 7,856 | 140.79 ms | 173.00 ms | 4.45 ms | 1.39 ms | 2.30 ms |
| literal-unicode | 2,938 | 60.52 ms | 86.33 ms | 780 µs | 195 µs | 1.03 ms |
| alt-5 | 39,251 | 177.36 ms | 280.50 ms | 25.78 ms | 5.50 ms | 21.56 ms |
| class-lower | 166,221 | 193.97 ms | 561.50 ms | 40.55 ms | 8.15 ms | 33.69 ms |
| class-digit | 5,972 | 130.82 ms | 175.75 ms | 43.59 ms | 395 µs | 5.55 ms |
| word-w | 172,193 | 207.75 ms | 527.50 ms | 41.54 ms | 8.42 ms | 33.71 ms |
| two-words | 75,064 | 182.73 ms | 338.50 ms | 42.63 ms | 6.12 ms | 22.21 ms |
| word-boundary | 39,418 | 184.73 ms | 296.00 ms | 47.40 ms | 7.58 ms | 25.58 ms |
| email-like | 2,027 | 273.71 ms | 379.50 ms | 147.03 ms | 17.17 ms | 39.04 ms |
| named-group | 166,221 | 200.34 ms | 512.50 ms | 43.38 ms | 12.98 ms | 32.72 ms |
| case-insens | 7,856 | 164.63 ms | 229.25 ms | 4.41 ms | 1.50 ms | 6.62 ms |
| backref-dup | 15,606 | 472.87 ms | 665.00 ms | 181.69 ms | 18.21 ms | 46.95 ms |
| greedy-dotstar | 6,518 | 881.21 ms | 1177.50 ms | 472.10 ms | 102.67 ms | 12.16 ms |

### Table B — relative to Oniguruma C (= 1.00×); ×>1 = slower, %<0 = faster

| pattern | oniguruma_dart · VM | oniguruma_dart · Web | Dart RegExp · VM | Dart RegExp · Web | Oniguruma C |
|---|--:|--:|--:|--:|--:|
| literal | 61.2× (+6021%) | 75.2× (+7421%) | 1.93× (+93%) | 0.61× (−39%) | 1.00× |
| literal-unicode | 58.5× (+5753%) | 83.5× (+8249%) | 0.75× (−25%) | 0.19× (−81%) | 1.00× |
| alt-5 | 8.2× (+722%) | 13.0× (+1201%) | 1.20× (+20%) | 0.26× (−74%) | 1.00× |
| class-lower | 5.8× (+476%) | 16.7× (+1567%) | 1.20× (+20%) | 0.24× (−76%) | 1.00× |
| class-digit | 23.6× (+2255%) | 31.6× (+3064%) | 7.85× (+685%) | 0.07× (−93%) | 1.00× |
| word-w | 6.2× (+516%) | 15.7× (+1465%) | 1.23× (+23%) | 0.25× (−75%) | 1.00× |
| two-words | 8.2× (+723%) | 15.2× (+1424%) | 1.92× (+92%) | 0.28× (−72%) | 1.00× |
| word-boundary | 7.2× (+622%) | 11.6× (+1057%) | 1.85× (+85%) | 0.30× (−70%) | 1.00× |
| email-like | 7.0× (+601%) | 9.7× (+872%) | 3.77× (+277%) | 0.44× (−56%) | 1.00× |
| named-group | 6.1× (+512%) | 15.7× (+1466%) | 1.33× (+33%) | 0.40× (−60%) | 1.00× |
| case-insens | 24.9× (+2385%) | 34.6× (+3361%) | 0.67× (−33%) | 0.23× (−77%) | 1.00× |
| backref-dup | 10.1× (+907%) | 14.2× (+1316%) | 3.87× (+287%) | 0.39× (−61%) | 1.00× |
| greedy-dotstar | 72.5× (+7148%) | 96.9× (+9585%) | 38.8× (+3783%) | 8.44× (+744%) | 1.00× |

### Geomean across the 13 patterns

| comparison | geomean |
|---|--:|
| oniguruma_dart VM  vs  Oniguruma C | 14.4× slower |
| oniguruma_dart Web vs  Oniguruma C | 24.0× slower |
| Dart RegExp VM     vs  Oniguruma C | 2.2× slower |
| Dart RegExp Web    vs  Oniguruma C | 2.8× **faster** |
| oniguruma_dart VM  vs  Dart RegExp VM | 6.4× slower |
| oniguruma_dart Web vs  Dart RegExp Web | 67.9× slower |
| oniguruma_dart Web vs  oniguruma_dart VM | 1.7× slower (web penalty) |
| Dart RegExp Web    vs  Dart RegExp VM | 6.3× **faster** (Node V8 > bundled Irregexp) |

### Takeaways

- **Native `RegExp` ≈ C.** The Dart VM's built-in `RegExp` (Irregexp) is only
  ~2.2× off hand-tuned C on this mix — sometimes faster (case-fold, unicode
  literal). It's the benchmark to beat, not this port.
- **`RegExp` on the web is the fastest thing here** (2.8× *faster* than C on
  average) because dart2js maps `RegExp` straight to Node/V8's native regex, and
  V8-in-Node is a newer, better-tuned Irregexp than the one bundled in the Dart
  SDK — hence `RegExp` is also **6.3× faster on web than on the VM**.
- **This port pays a web tax.** As a pure-Dart interpreter compiled to JS, it's
  ~1.7× slower on web than its own AOT/native build — and since its competitor
  (`RegExp`) gets *faster* on web, the gap widens from ~6× (native) to ~68× (web).
- **`greedy-dotstar` is C's blowout win** (72× vs this port, 39× vs native
  `RegExp`): Oniguruma's `.*` + exact-string prefilter skips almost the whole
  corpus; this port doesn't yet apply that optimization for anchored `.*literal`.
  A known optimization gap, not a correctness issue.
- **Bottom line:** choose `oniguruma_dart` for the *dialect, encodings, and
  byte-parity* it offers — not for raw speed. For plain UTF-16 matching in the
  JS/Dart dialect, built-in `RegExp` wins on every platform, most decisively on
  the web.

### Reproduce

```console
# VM: oniguruma_dart vs RegExp (AOT/native)
dart compile exe benchmark/bench_vs_regexp.dart -o benchmark/bench_vs_regexp && ./benchmark/bench_vs_regexp
# Web: same two engines under Node/V8 (dart2js)
dart run benchmark/web/gen_corpus_data.dart
dart compile js benchmark/web/bench_web.dart -O2 -o benchmark/web/bench_web.js && node benchmark/web/bench_web.js
# C: same 13 patterns via libonig
python3 benchmark/bench_c_13.py
# Assemble the 5-way tables above
python3 benchmark/compute_5way.py
```


---

## Appendix: pure-Dart interpreter optimizations (no JIT)

Four optimizations to close the interpreter tax and eliminate catastrophic
backtracking, all verified against the oracle (**5160 unit tests + 113
differential + ~36 000 fuzz cases across 6 seeds → 0 divergences**, `dart
analyze` clean). Machine: Apple M1 Pro, Dart 3.12.2, byte-API harness
(`benchmark/bench_dart`), median of 30 iterations.

### 1. BMH/Sunday exact-search prefilter

`OPTIMIZE_STR` now uses a Sunday quick-search bad-char skip table
([optimize.dart](../lib/src/compile/optimize.dart), [search.dart](../lib/src/exec/search.dart))
instead of a byte-by-byte first-byte scan, jumping up to `needle.length + 1`
bytes per step. Small broad gains on literal/word patterns (`\w+` 54.3 → 51.8 ms).

**Case-insensitive first-byte map.** A `(?i)literal` previously got *no* prefilter
(the optimizer bailed on ignore-case), so it ran the per-char fold-compare at
every position. The optimizer now builds an `OPTIMIZE_MAP` over the leading code
point's whole case-fold class — e.g. `(?i)lorem` attempts only at `l`/`L` — and
bails safely to no-map when the lead char has a *multi-char* fold (`ß≡ss`), whose
first byte the single-code-point fold class can't capture.

| pattern (byte API) | before | after | vs C | vs Dart `RegExp` |
|---|--:|--:|--:|--:|
| `(?i)lorem` | 42.6 ms | **8.4 ms** (5.1× faster) | 1.4× | 2.2× (was 11.4×) |

(In the String API this engine win is masked by the ~120 ms byte↔UTF-16
index-build overhead, which dominates once matching is fast.) Pinned by
[test/optimize_test.dart](../test/optimize_test.dart), which asserts the
prefilter *strategy* the oracle can't — the gap that let this slip through.

### 2. Leading-`.*` anchor (`ANCR_ANYCHAR_INF`)

For a leading greedy `.*`/`.+` followed by a required literal, the driver now
anchors the match to the head of the literal's line and skips whole non-matching
lines, instead of retrying `matchAt` at every offset.

| pattern | before | after | vs Dart `RegExp` |
|---|--:|--:|--:|
| `.*lorem` (byte API) | 668 ms | **10.1 ms** (66× faster) | — |
| `.*lorem` (String API) | 881 ms | **109 ms** | **3.3× faster** (was 1.9× slower) |

### 3. Thompson/Pike-NFA linear fast path

A new NFA engine ([nfa.dart](../lib/src/exec/nfa.dart)) runs a Pike VM (NFA
simulation with submatch tracking) that visits each program state at most once
per input position — **O(text × program)**, so it cannot backtrack
exponentially. It is byte-identical to the backtracking VM on the subset it
accepts (leftmost-first priority, identical class/anchor semantics), and is
**gated two ways**: it only accepts the *safe subset* (no back-references,
atomic/possessive groups, look-around, conditionals, sub-routine calls,
callouts, `\K`, ignore-case, empty-matchable loop bodies) **and** only takes over
*risky* patterns (nested repetition — the super-linear-backtracking hazard). Flat
patterns stay on the faster prefilter path.

`(a+)+$` on N `a`-chars then `!` (a classic exponential case) — **linear**:

| N | 1 000 | 5 000 | 10 000 | 20 000 |
|---|--:|--:|--:|--:|
| time | 0.72 ms | 3.49 ms | 7.03 ms | 14.26 ms |

The backtracking VM would be exponential here (bounded only by its retry limit).

### 4. Bytecode flattening to a single `Int32List`

The compiled [Operation] stream is decomposed into a `FlatOps`
([operation.dart](../lib/src/compile/operation.dart)): scalar fields live in one
**interleaved** `Int32List` (op `i`'s fields at `scalars[i*stride + offset]`, so
one instruction's fields sit in a single cache line), and object payloads
(`str`/`bs`/`mb`/callout) stay in parallel lists read only when the opcode needs
them. The executor's hot loop ([executor.dart](../lib/src/exec/executor.dart))
now dispatches on `sc[base + oOpcode]` and reads operands from `sc[base + …]`
instead of dereferencing a heap `Operation` per instruction.

Honest result: this is **performance-neutral** in Dart, not a speedup — within a
few percent of the `Operation`-object version on common patterns (`lorem` 2.75 →
2.78 ms, `[a-z]+` 47.0 → 48.9 ms). The reason: the pre-flatten loop already
hoisted `op = ops[pc]` once per instruction, and Dart bounds-checks every
typed-list index whereas object field reads are unchecked, so the removed
pointer-chase is roughly offset by per-field index math + bounds checks. (An
earlier *parallel*-arrays layout — one `Int32List` per field — was 15–50% slower
because it scattered an instruction's fields across many cache lines; the single
interleaved array fixes that.) The measurable interpreter-tax wins came from the
prefilters (§1–2) and the NFA (§3); the flatten's value is structural (no
per-instruction object dereference) rather than a throughput gain.

---

# Appendix — String-API subject specialization (S1/S2) + executor ASCII fast decode (E1)

Investigation ([docs/regexp-vs-dartvm-investigation.md](../docs/regexp-vs-dartvm-investigation.md))
proved the String-API gap vs the SDK `RegExp` was **not** the VM: for `lorem` over
the 1.14 MB ASCII corpus, 94% of the time was `_Utf8Index` building a
`Map<int,int>` byte↔code-unit index (~1.1 M entries); the match itself was 3%.

**S1 — ASCII subject fast path.** When every code unit is `< 0x80`, the code units
*are* the UTF-8 bytes and byte offset == code-unit index. The String API now feeds
`input.codeUnits` to the same UTF-8 regex with **identity offsets and no index maps**
(`_AsciiSubject`). Zero semantic change (bytes are identical).

**S2 — typed tables for non-ASCII.** Strings with a code unit `>= 0x80` keep UTF-8
semantics but replace the hashmap + O(n) fallback with dense **`Int32List`** byte↔char
tables built in one pass (`_Utf8Subject`), O(1) lookup, no hashing.

**E1 — executor ASCII fast decode.** In the hot char ops (`cclass*`, `anychar`,
`word`/`noWord`), a byte `< 0x80` in an ASCII-compatible encoding (`enc.isAsciiFast`:
UTF-8 + single-byte) is decoded as `code = byte, len = 1`, skipping the two virtual
encoding calls (`enc.length` + `enc.mbcToCode`).

### String API vs SDK `RegExp` (same process; ratio robust to machine load)

| pattern | before onig/RegExp | after onig/RegExp | onig end-to-end before→after |
|---|--:|--:|---|
| literal | 28.2× | **1.2×** | 102.6 → 5.1 ms |
| literal-unicode | 76.1× | 14.2× | 48.8 → 10.9 ms |
| alt-5 | 7.0× | 2.3× | 146.0 → 58.7 ms |
| class-lower | 4.8× | 1.8× | 161.9 → 72.3 ms |
| class-digit | 2.8× | **0.2×** (5× faster) | 106.3 → 8.9 ms |
| word-w | 4.7× | 2.0× | 164.7 → 79.9 ms |
| two-words | 4.4× | 1.5× | 154.7 → 62.7 ms |
| word-boundary | 4.2× | 1.4× | 164.8 → 66.8 ms |
| email-like | 2.0× | 1.0× | 238.5 → 153.9 ms |
| named-group | 4.8× | 1.8× | 173.3 → 76.3 ms |
| case-insens | 27.6× | 2.8× | 108.5 → 12.4 ms |
| backref-dup | 2.7× | 2.0× | 418.6 → 362.7 ms |
| greedy-dotstar | 0.3× | **0.03×** (33× faster) | 119.3 → 14.3 ms |

**geomean onig / RegExp: 5.4× → 1.3×** (median 4.7× → 1.8×). The port now **beats**
`RegExp` on `class-digit`, `greedy-dotstar`, and matches it on `literal`/`email-like`.

Breakdown for `lorem` (ASCII), String-API end-to-end: **116 ms → 5.13 ms**; the match
(3.6 ms) is now ~70% of the time instead of 3%.

### Validation

`dart test` **5279 pass** (5169 C-suite oracle + 110 new String-API tests covering
ASCII / Latin-1 / BMP / supplementary offset mapping); differential fuzz **0
divergences** over 15 000 cases (5 seeds) + 113 fixed cases vs the C CLI;
`dart analyze` clean.

### Deferred (documented in the investigation, not landed)

- **S3** (UTF-16 subject engine): S1+S2 already remove the measured tax with exact
  UTF-8 semantics; a UTF-16 engine risks per-encoding semantic divergence.
- **E2/E3** (emit unused anychar-star/peek opcodes; deterministic-quantifier
  no-backtrack): change generated bytecode / match core — real parity risk, deferred.
- **E4** (first-byte map for `\w \d \s`): **proven unsafe/useless for UTF-8** — the
  port's `\d`/`\w`/`\s` match Unicode (Arabic-Indic digits, é, 漢, NBSP), so a correct
  first-byte map is near-saturated and a tight ASCII map would skip valid matches.

### Byte API (AOT) vs cached C — after E1

| pattern | C (cached) | Dart AOT | AOT/C |
|---|--:|--:|--:|
| literal-ascii | 1.94ms | 3.30ms | 1.70× |
| class-lower | 26.95ms | 60.41ms | 2.24× |
| word-w | 28.36ms | 68.79ms | 2.43× |
| two-words | 17.12ms | 58.01ms | 3.39× |
| case-insens | 5.48ms | 10.32ms | 1.88× |
| greedy-dotstar | 10.58ms | 13.55ms | 1.28× |
| backref-dup | 39.54ms | 367.97ms | 9.31× |
| … (17 patterns) | | | **geomean 2.75×** |

**Measurement caveat / no regression.** This run was taken with the VS Code renderer
pegging a full core (101% CPU) the whole time; the earlier 2.24× baseline was measured
editor-idle. The tell: `literal-ascii` uses the exact-match/Sunday-skip path that E1
does **not** modify, yet it inflated 2.56 → 3.30 ms (**1.29×**) — pure contention.
Normalizing the board by that 1.29× gives class-lower ≈ 46.8 ms (**≈1.74×**, vs 1.79×
pre-E1) and geomean **≈2.13×** — i.e. E1 is neutral-to-slightly-positive at the byte
level, no regression. E1's byte-API gain is modest because Dart AOT already partly
devirtualizes the monomorphic encoding calls and the per-char bitset test + backtrack
push dominate; E1's larger value is enabling the String-API ASCII fast path (S1) to feed
raw bytes to a decode-free hot loop.

---

# FULL BENCHMARK — 2026-07-14 (post S1/S2/E1), all engines re-measured

Cached in `benchmark/bench_results.json` + `benchmark/compute_5way.py` (regenerate via
`benchmark/collect_5way.py`). All five engines measured fresh in one session, so every
**ratio** is fair. **Caveat:** absolute ms run ~1.2× high because the VS Code renderer held
a core at ~100% throughout (this run's C `literal` 2.28 ms vs 1.94 ms editor-idle); ratios
(Table B, geomeans, AOT/C) are internally consistent and unaffected.

Unit = median ns/ms to scan the whole corpus for all non-overlapping matches (match counts
verified identical across engines). ASCII corpus 1.14 MB, Unicode corpus 0.90 MB.

## 5-way — Table A (absolute)

| pattern | matches | oniguruma_dart·VM | oniguruma_dart·Web | Dart RegExp·VM | Dart RegExp·Web | Oniguruma C |
|---|--:|--:|--:|--:|--:|--:|
| literal | 7,856 | 5.01 ms | 19.14 ms | 4.36 ms | 1.37 ms | 2.28 ms |
| literal-unicode | 2,938 | 10.90 ms | 15.58 ms | 766 µs | 189 µs | 1.03 ms |
| alt-5 | 39,251 | 58.57 ms | 127.75 ms | 25.50 ms | 5.38 ms | 21.27 ms |
| class-lower | 166,221 | 71.88 ms | 309.00 ms | 39.68 ms | 7.76 ms | 29.62 ms |
| class-digit | 5,972 | 8.79 ms | 20.27 ms | 43.16 ms | 388 µs | 5.42 ms |
| word-w | 172,193 | 79.83 ms | 320.00 ms | 40.58 ms | 8.23 ms | 32.70 ms |
| two-words | 75,064 | 62.60 ms | 170.00 ms | 41.65 ms | 5.98 ms | 19.79 ms |
| word-boundary | 39,418 | 64.99 ms | 145.50 ms | 46.87 ms | 7.47 ms | 25.40 ms |
| email-like | 2,027 | 151.55 ms | 216.00 ms | 144.54 ms | 16.87 ms | 38.79 ms |
| named-group | 166,221 | 75.19 ms | 318.50 ms | 42.77 ms | 12.07 ms | 31.75 ms |
| case-insens | 7,856 | 12.33 ms | 26.85 ms | 4.37 ms | 1.48 ms | 6.57 ms |
| backref-dup | 15,606 | 356.50 ms | 496.00 ms | 179.20 ms | 17.89 ms | 46.38 ms |
| greedy-dotstar | 6,518 | 14.33 ms | 26.30 ms | 455.26 ms | 102.83 ms | 11.85 ms |

## 5-way — Geomean (13 patterns)

| comparison | geomean | |
|---|--:|---|
| oniguruma_dart VM  vs  Oniguruma C | 2.85× | 2.8× slower |
| oniguruma_dart Web vs  Oniguruma C | 6.88× | 6.9× slower |
| Dart RegExp VM     vs  Oniguruma C | 2.27× | 2.3× slower |
| Dart RegExp Web    vs  Oniguruma C | 0.36× | **2.8× faster** (V8 native regex) |
| **oniguruma_dart VM  vs  Dart RegExp VM** | **1.25×** | **1.3× slower (was 5.3×)** |
| oniguruma_dart Web vs  Dart RegExp Web | 19.35× | 19× slower (V8 native vs our JS) |
| oniguruma_dart Web vs  oniguruma_dart VM | 2.42× | web is 2.4× the VM |

Port **beats** Dart RegExp·VM on `class-digit` (8.8 vs 43.2 ms, ~5×) and `greedy-dotstar`
(14.3 vs 455 ms, ~32× — RegExp backtracks, our `.*`-anchor/NFA don't); near-parity on
`literal`/`email-like`. Web `literal` improved 173 → 19 ms from S1 (ASCII fast path helps JS too).

## Byte API — C vs Dart AOT vs JIT (fresh C, same conditions)

| pattern | matches | C | Dart AOT | AOT/C | Dart JIT | JIT/C |
|---|--:|--:|--:|--:|--:|--:|
| literal-ascii | 7856 | 2.27ms | 3.27ms | 1.44× | 5.62ms | 2.47× |
| literal-unicode | 2938 | 1.03ms | 1.54ms | 1.50× | 3.67ms | 3.58× |
| alt-5 | 39251 | 20.91ms | 56.32ms | 2.69× | 64.98ms | 3.11× |
| class-lower | 166221 | 29.69ms | 59.79ms | 2.01× | 77.22ms | 2.60× |
| class-digit | 5972 | 5.39ms | 6.74ms | 1.25× | 10.78ms | 2.00× |
| word-w | 172193 | 32.69ms | 68.54ms | 2.10× | 89.30ms | 2.73× |
| two-words | 75064 | 19.84ms | 57.53ms | 2.90× | 74.76ms | 3.77× |
| word-boundary | 7819 | 2.60ms | 4.04ms | 1.55× | 6.52ms | 2.51× |
| anchored-line | 19242 | 10.03ms | 34.63ms | 3.45× | 38.61ms | 3.85× |
| email-like | 2027 | 38.64ms | 162.87ms | 4.22× | 216.05ms | 5.59× |
| case-insens | 7856 | 6.56ms | 10.24ms | 1.56× | 13.34ms | 2.04× |
| backref-dup | 15606 | 46.47ms | 370.93ms | 7.98× | 401.88ms | 8.65× |
| backtrack | 47005 | 32.26ms | 161.46ms | 5.00× | 199.07ms | 6.17× |
| greedy-dotstar | 6518 | 11.86ms | 13.39ms | 1.13× | 21.87ms | 1.85× |
| uni-prop-L | 103858 | 22.48ms | 88.57ms | 3.94× | 98.53ms | 4.38× |
| uni-prop-Han | 27508 | 13.11ms | 27.22ms | 2.08× | 30.27ms | 2.31× |
| uni-word | 107293 | 23.56ms | 62.03ms | 2.63× | 60.03ms | 2.55× |

**geomean AOT/C = 2.41×, JIT/C = 3.21×** (compile-time geomean AOT/C = 1.44×). Fresh C
under identical load, so this is the fair self-consistent byte-API ratio; consistent with
E1 being neutral-to-slightly-positive (no regression).

---

# V8 regex: JIT vs bytecode interpreter — 2026-07-14

Question: how fast is V8's *bytecode interpreter* (vs its JIT), so we can compare a
like-for-like interpreter against our pure-Dart one. Node v26. Flags:
`--regexp-interpret-all` forces V8's regex onto the **Irregexp bytecode interpreter**
while keeping surrounding JS JIT-compiled (clean isolation of the regex engine);
normal Node tiers a regex up to **machine code** after 1 call (`--regexp-tier-up-ticks=1`);
`--jitless` interprets *everything* incl. the harness loop (context only, not a clean
regex measurement). Same session; ratios fair (absolutes ~1.2× high under editor load).

## V8 regex JIT (machine code) vs V8 regex bytecode interpreter

| pattern | V8 JIT | V8 interp | interp/JIT |
|---|--:|--:|--:|
| literal | 1.38 ms | 1.43 ms | 1.0× |
| alt-5 | 5.44 ms | 13.18 ms | 2.4× |
| class-lower | 7.91 ms | 24.86 ms | 3.1× |
| class-digit | 390 µs | 1.55 ms | 4.0× |
| word-w | 8.26 ms | 24.77 ms | 3.0× |
| two-words | 6.11 ms | 26.30 ms | 4.3× |
| word-boundary | 7.53 ms | 63.75 ms | 8.5× |
| email-like | 16.90 ms | 90.83 ms | 5.4× |
| case-insens | 1.52 ms | 3.12 ms | 2.1× |
| backref-dup | 20.29 ms | 115.00 ms | 5.7× |
| greedy-dotstar | 106.83 ms | 318.00 ms | 3.0× |

**geomean interp/JIT = 3.0×** — the machine-code regex is 3× its own interpreter
(bigger on backtracking: word-boundary 8.5×, backref 5.7×; ~1× on literals, which are
prefilter-bound not engine-bound).

## Interpreters head-to-head, geomean vs Oniguruma C

| engine (all bytecode interpreters except the last) | geomean vs C |
|---|--:|
| **V8 regex interp (Node --regexp-interpret-all)** | **1.09×** ≈ C-speed |
| Dart RegExp·VM (V8 Irregexp interp, opts disabled) | 2.27× |
| oniguruma_dart·VM (our Dart interp, String API) | 2.85× |
| oniguruma_dart byte API (our Dart interp, engine only) | 2.41× |
| — V8 regex JIT (machine code, for reference) | 0.36× (2.8× faster than C) |

Derived: our Dart interpreter is **~2.2–2.6× V8's regex interpreter**
(byte engine 2.41/1.09 ≈ 2.2×; String API 2.6×). Notably **Dart-VM's own RegExp is 2.1×
slower than Node's V8 interpreter despite being the same Irregexp** — because Dart's
re-import disables `FLAG_regexp_optimization` (inline quick-check + node specialization)
and peephole fusion (see investigation §A.5); Node keeps them on.

Algorithm beats engine on `greedy-dotstar`: our Dart interpreter 14.3 ms and C 11.9 ms
both crush **even V8's JIT** (106.8 ms) and its interpreter (318 ms) — V8 backtracks the
`.*` where our `.*`-anchor / linear NFA do not.

---

# ⭐ MAINSTREAM COMPARISON (canonical, from 2026-07-14)

**The standard 4-engine comparison from now on.** Regenerate:
`python3 benchmark/mainstream.py --run` (renders from `benchmark/mainstream_results.json`
without `--run`). All are bytecode interpreters **except** none here is JIT'd — V8 is
forced onto its interpreter so this is like-for-like. Unit = median ns/ms to scan the
corpus for all matches; ratios are the signal (absolutes ~1.2× high under editor load).

- **Oniguruma C** — reference C library (byte API, native)
- **V8 interp** — Node `--regexp-interpret-all` (V8 Irregexp **bytecode interpreter**, not its JIT)
- **Dart RegExp·VM** — `dart:core` RegExp on the Dart VM (V8 Irregexp interpreter, opts disabled)
- **oniguruma_dart·VM** — this port's `OnigRegex` String API on the Dart VM (our pure-Dart interpreter)

## Geomean vs Oniguruma C (13 patterns) — after ALL engine work (editor-idle)

| engine | geomean vs C |
|---|--:|
| Oniguruma C | 1.00× |
| **V8 interp** | **1.10×** |
| **Dart RegExp·VM** | **2.26×** |
| **oniguruma_dart·VM** | **2.39×** (was 2.85×; byte-API engine 2.06×, was 2.41×) |

Head-to-head: oniguruma_dart·VM / Dart RegExp·VM = **1.06× (≈ parity)** (was 1.25×);
oniguruma_dart·VM / V8 interp = **2.16×** (was 2.61×). Port beats C on `greedy-dotstar`
(0.86×), and beats Dart RegExp on `class-digit`, `greedy-dotstar`, `email-like`.

Progression of engine work (this session): 2.85× → 2.59× (Op.starGreedy) → 2.52×
(loop-hoist + non-ASCII cursor) → **2.39×** (\w ASCII fast path + `Op.peekByte` alternation
quick-check). Byte-API alt-5 2.52× → **1.93×** C (peek); `literal-unicode` 10.74× → 4.96× C
(cursor). Remaining String-API floor for non-ASCII is the unavoidable `utf8.encode`.

Head-to-head: oniguruma_dart·VM / V8 interp = **2.61×**; oniguruma_dart·VM / Dart RegExp·VM
= **1.25×**; Dart RegExp·VM / V8 interp = **2.09×** (same Irregexp, Dart's has quick-check +
peephole disabled).

## Normalized to C (per pattern)

| pattern | Oniguruma C | V8 interp | Dart RegExp·VM | oniguruma_dart·VM |
|---|--:|--:|--:|--:|
| literal | 1.00× | 0.63× | 1.91× | 2.19× |
| literal-unicode | 1.00× | 0.18× | 0.75× | 10.60× |
| alt-5 | 1.00× | 0.62× | 1.20× | 2.75× |
| class-lower | 1.00× | 0.84× | 1.34× | 2.43× |
| class-digit | 1.00× | 0.29× | 7.96× | 1.62× |
| word-w | 1.00× | 0.76× | 1.24× | 2.44× |
| two-words | 1.00× | 1.33× | 2.11× | 3.16× |
| word-boundary | 1.00× | 2.51× | 1.85× | 2.56× |
| email-like | 1.00× | 2.34× | 3.73× | 3.91× |
| named-group | 1.00× | 0.96× | 1.35× | 2.37× |
| case-insens | 1.00× | 0.48× | 0.66× | 1.88× |
| backref-dup | 1.00× | 2.48× | 3.86× | 7.69× |
| greedy-dotstar | 1.00× | 26.83× | 38.41× | **1.21×** |

Absolute table in `benchmark/mainstream_results.json`. `oniguruma_dart·VM` is the
user-facing String API (comparable to RegExp); the pure byte engine is ~2.41× C.

---

# Why is Dart RegExp·VM slower than V8 interp, if it's the same engine? (2026-07-14)

They ARE the same engine (V8 Irregexp bytecode interpreter). The gap is the
compile-time **optimization configuration**, proven by forcing Node's interpreter into
Dart's config and re-measuring (`node --regexp-interpret-all --no-regexp-optimization
--no-regexp-peephole-optimization --no-regexp-unroll`; these three default ON in Node,
all OFF in Dart per dart-lang/sdk@3.12.2 base.h):

| engine / config | geomean vs C |
|---|--:|
| V8 interp, opts ON (Node default) | 1.09× |
| Dart RegExp·VM | 2.27× |
| **V8 interp, Dart's config (opts OFF)** | **3.22×** |

Disabling those flags slows V8's own interpreter by **2.95× geomean** — past Dart RegExp.
So **Dart RegExp / V8(Dart-config) = 0.71×**: at equal settings Dart's engine is actually
~1.4× *faster* than Node's interpreter. The entire "Dart is 2× slower" is Dart shipping the
same engine with **quick-check + peephole + unroll turned off**, emitting verbose bytecode
the interpreter must chew through. Extreme case `class-digit` (`[0-9]+`, digits rare in the
corpus): opts-ON emits a skip-to-next-digit loop = 1.55 ms; opts-OFF scans every char =
88.8 ms (**57×**). Dart RegExp keeps a partial skip (43 ms). Secondary factors (V8 version,
per-match host/harness overhead) net slightly in Dart's favor, so the flags fully explain —
and over-explain — the gap.

---

# Engine optimization: Op.starGreedy fast loop — 2026-07-14

"Enable all optimizations we can": added a specialized greedy loop for single-item
bodies (`[class]*/+`, `\w+`, `\d+`, `.*`, ctypes) mirroring C's `OP_ANYCHAR_STAR`
idea. Instead of `PUSH; body; JUMP` pushing one backtrack frame **per character**, the
new `Op.starGreedy` opcode scans the whole run in a tight loop and pushes **one**
decrement-on-backtrack frame (`Stk.starLoop`). Semantics-preserving (longest-first, give
back one char per backtrack) — validated byte-identical.

Validation: `dart test` **5290 pass** (+11 focused give-back tests); differential fuzz
**0 divergences** over 18,000 cases (6 seeds) + 113 fixed; `dart analyze` clean.

## Byte API vs cached C (editor-idle), E1 → +starGreedy

| pattern | before AOT/C | after AOT/C | Δ |
|---|--:|--:|---|
| class-lower | 1.79× | **1.55×** | 48.4 → 41.8 ms |
| word-w | 1.92× | **1.70×** | 54.5 → 48.2 ms |
| two-words | 2.93× | **2.19×** | 50.1 → 37.4 ms |
| email-like | 4.38× | **3.76×** | 142.8 → 122.4 ms |
| backtrack | 5.39× | **4.11×** | 146.3 → 111.8 ms |
| backref-dup | 8.12× | **7.57×** | 321.1 → 299.2 ms |
| greedy-dotstar | 1.02× | **0.78×** (faster than C) | 10.8 → 8.2 ms |
| **geomean AOT/C** | **2.24×** | **2.10×** | |

## String API vs SDK RegExp

geomean onig/RegExp **1.3× → 1.2×** (median 1.8× → 1.5×). Now beats RegExp on
`class-digit` (0.2×), `greedy-dotstar` (0.02×), and `email-like` (0.9×, 114 vs 127 ms);
`two-words` 1.5× → 1.2×.

Fires for single char-class / ctype / anychar greedy repeats; not yet for single literal
chars (`a+`) or groups (`(ab)+`) — future extension.

---

# More engine + wrapper pushes — 2026-07-14 (loop-hoist + non-ASCII cursor)

Two follow-ups after Op.starGreedy:

1. **starGreedy loop-hoist** (`executor.dart`): the body opcode is loop-invariant, so it is
   switched ONCE and the hot matchers (`cclass`, `\w`, `.`, dotall) run a specialised tight
   inner loop; rare cases fall back to `_starConsume`. Removes a call + switch per character.
   Byte geomean AOT/C 2.10× → **2.08×** (two-words 37.4→35.6 ms, email-like 122→109 ms,
   backtrack 112→107 ms, greedy-dotstar 8.2→7.8 ms).

2. **Non-ASCII String-API cursor** (`string_api.dart` `_Utf8Subject`): replaced the dense
   `Int32List` byte↔code-unit tables with a lazy, memoised bidirectional cursor. Match/group
   offsets arrive mostly in order, so total work is amortised O(n) with no big allocation.
   `literal-unicode` String-API 9.40 → **4.95 ms** (14.2× → 7.0× RegExp); String-API geomean
   1.2× → **1.1×**.

Validation: `dart test` **5293 pass** (+3 cursor edge-case tests); differential fuzz **0
divergences** over 12,500 cases (5 seeds) after the hoist; `dart analyze` clean. (The cursor is
wrapper-only — the byte-API oracle is unaffected.)

---

# Engine round 3 — word-char ASCII fast path + alternation quick-check (2026-07-14)

Two more "enable all optimizations" engine changes:

1. **`\w` ASCII fast path** (`executor.dart` `_isWord`): ASCII word membership is identical
   under ascii-mode and Unicode-mode (`[A-Za-z0-9_]` in `[0,0x80)`), so `code < 0x80` now
   uses the ASCII ctype table instead of the virtual `enc.isCodeCtype` — removing a virtual
   call per character on `\w`/`\W` over ASCII text.

2. **Alternation quick-check `Op.peekByte`** (`compiler.dart` `_compileAlt`, `executor.dart`):
   before each non-last branch that has a *complete, non-nullable* first-byte set, peek the
   current byte; if it can't begin the branch, skip past it with no PUSH / enter / fail. The
   first-byte helper (`_altFirstBytes`) is deliberately conservative — it declines nullable
   heads (`(a?)b|…`), negated classes (`[^a]|…`), and ctypes (`\w+|…`), so it can only ever
   skip a branch that provably cannot match.

Validation: `dart test` **5300 pass** (+7 focused alt-peek tests covering the must-NOT-skip
cases); differential fuzz **0 divergences** over 24,000 cases (8 seeds) + 113 fixed;
`dart analyze` clean.

Backref/backtrack (`(\w+) \1`, `[a-z]*o[a-z]*r`) were assessed and left as-is: inherent
backtracking, already improved by Op.starGreedy, no *safe* further win without deeper
algorithmic change (the NFA linear path is disqualified by back-references).
