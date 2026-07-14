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
