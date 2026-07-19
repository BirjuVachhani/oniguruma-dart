# Regex Engine Deep Dive: Q&A

A preserved question-and-answer record covering the `oniguruma_dart` benchmarks
against Dart's built-in `RegExp` and Oniguruma C, and the engine-architecture
discussion that followed. Every performance figure is a median ns-per-full-corpus
scan on **Apple M1 Pro · Dart 3.12.2 (macos_arm64) · Node v26 (V8) · clang -O3**,
with match counts verified identical across engines before timing. Source claims
in the final section are cited to primary sources.

**Contents**

1. [Benchmark: oniguruma_dart vs Dart's built-in RegExp](#1-benchmark-oniguruma_dart-vs-darts-built-in-regexp)
2. [Was the benchmark web or Dart VM?](#2-was-the-benchmark-web-or-dart-vm)
3. [Five-way comparison with % and × metrics](#3-five-way-comparison-with--and--metrics)
4. [Why is the port slower than C / V8 / RegExp?](#4-why-is-the-port-slower-than-c--v8--regexp)
5. [What is Irregexp? Newer in Node vs Dart?](#5-what-is-irregexp-newer-in-node-vs-dart)
6. [Backtracking vs other engine types; compiled vs interpreted](#6-backtracking-vs-other-engine-types-compiled-vs-interpreted)
7. [Linear engines, JIT vs AOT, and how JS regex is compiled](#7-linear-engines-jit-vs-aot-and-how-js-regex-is-compiled)
8. [Primary-source proofs: Dart & V8 internals, external, PCRE2, greedy-dotstar](#8-primary-source-proofs)

---

## 1. Benchmark: oniguruma_dart vs Dart's built-in RegExp

**Q: Can you benchmark this dart port against Dart's built-in RegExp?**

Both engines run the **same 13 patterns** over the **same corpora** through each
engine's idiomatic `allMatches` API (AOT-compiled, native Dart VM). Match counts
agreed on all 13 patterns. Figures are median ns per full-corpus scan.

| pattern | category | matches | RegExp | oniguruma_dart | onig / RegExp |
|---|---|--:|--:|--:|--:|
| literal | literal | 7,856 | 4.45 ms | 140.79 ms | 31.7× |
| literal-unicode | literal | 2,938 | 780 µs | 60.52 ms | 77.6× |
| alt-5 | alternation | 39,251 | 25.78 ms | 177.36 ms | 6.9× |
| class-lower | char-class | 166,221 | 40.55 ms | 193.97 ms | 4.8× |
| class-digit | char-class | 5,972 | 43.59 ms | 130.82 ms | 3.0× |
| word-w | class/quant | 172,193 | 41.54 ms | 207.75 ms | 5.0× |
| two-words | quantifier | 75,064 | 42.63 ms | 182.73 ms | 4.3× |
| word-boundary | anchor | 39,418 | 47.40 ms | 184.73 ms | 3.9× |
| email-like | quant/greedy | 2,027 | 147.03 ms | 273.71 ms | 1.9× |
| named-group | capture | 166,221 | 43.38 ms | 200.34 ms | 4.6× |
| case-insens | case-fold | 7,856 | 4.41 ms | 164.63 ms | 37.3× |
| backref-dup | back-reference | 15,606 | 181.69 ms | 472.87 ms | 2.6× |
| greedy-dotstar | greedy `.*` | 6,518 | 472.10 ms | 881.21 ms | 1.9× |

**geomean = 6.4× slower · median = 4.6× slower.** Best cases (~1.9×) are the
backtracking-heavy patterns (email, backref, greedy `.*`); worst cases are the
patterns where `RegExp` has a fast literal/case-fold scan (literal, unicode
literal, case-insensitive).

Reach for `oniguruma_dart` for what `RegExp` **cannot do** (the Oniguruma/Ruby
dialect, ~28 encodings, byte-offset parity), not for raw speed. For everyday
UTF-16 matching the built-in `RegExp` is faster.

---

## 2. Was the benchmark web or Dart VM?

**Q: Was this benchmarking test against web or Dart VM?**

**It was the Dart VM (native), not web.**

- Built with `dart compile exe` → an **AOT-compiled native executable** (ARM64
  machine code), run on the Dart Native runtime.
- The "Dart JIT" column in the C benchmark used `dart run`: same VM in JIT mode,
  still native, still not web.
- None of it was `dart compile js` (web) or `dart compile wasm`. The harness even
  reads the corpus with `dart:io`, which only exists on native.

Why it matters: `RegExp`'s implementation differs per target.

| Target | What `RegExp` actually is |
|---|---|
| Dart Native (what was tested) | V8's Irregexp, compiled into the Dart runtime |
| Web (`dart compile js`) | delegates to the **host JS engine's** `RegExp` (V8 in Node) |
| WASM (`dart compile wasm`) | different path again |

`oniguruma_dart` is pure Dart, so it *also* changes target: on native it's AOT
machine code; on the web it becomes JavaScript, while `RegExp` there is the
browser's native regex, so the gap would likely be **larger** on the web. The
measured ratios therefore apply to the native/AOT Dart VM, not the web.

---

## 3. Five-way comparison with % and × metrics

**Q: I want all 5 side by side: Oniguruma Dart VM, Oniguruma Web, Dart RegExp VM,
Dart RegExp Web, Oniguruma C. Use % and × faster/slower metrics.**

Same 13 patterns / same corpora / same work (scan whole corpus for all
non-overlapping matches). Match counts verified identical across all five configs.

- **oniguruma_dart · VM**: this port, AOT native (`dart compile exe`)
- **oniguruma_dart · Web**: this port, `dart compile js -O2` under Node/V8
- **Dart RegExp · VM**: SDK `RegExp`, native
- **Dart RegExp · Web**: SDK `RegExp` under dart2js → Node/V8's native regex
- **Oniguruma C**: reference libonig 6.9.10

### Table A: absolute (median time to scan the corpus for all matches)

| pattern | matches | onig·VM | onig·Web | RegExp·VM | RegExp·Web | C |
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

### Table B: × and % relative to Oniguruma C (=1.00×); ×>1 slower, %<0 faster

| pattern | onig·VM | onig·Web | RegExp·VM | RegExp·Web |
|---|--:|--:|--:|--:|
| literal | 61.2× (+6021%) | 75.2× (+7421%) | 1.93× (+93%) | 0.61× (−39%) |
| literal-unicode | 58.5× (+5753%) | 83.5× (+8249%) | 0.75× (−25%) | 0.19× (−81%) |
| alt-5 | 8.2× (+722%) | 13.0× (+1201%) | 1.20× (+20%) | 0.26× (−74%) |
| class-lower | 5.8× (+476%) | 16.7× (+1567%) | 1.20× (+20%) | 0.24× (−76%) |
| class-digit | 23.6× (+2255%) | 31.6× (+3064%) | 7.85× (+685%) | 0.07× (−93%) |
| word-w | 6.2× (+516%) | 15.7× (+1465%) | 1.23× (+23%) | 0.25× (−75%) |
| two-words | 8.2× (+723%) | 15.2× (+1424%) | 1.92× (+92%) | 0.28× (−72%) |
| word-boundary | 7.2× (+622%) | 11.6× (+1057%) | 1.85× (+85%) | 0.30× (−70%) |
| email-like | 7.0× (+601%) | 9.7× (+872%) | 3.77× (+277%) | 0.44× (−56%) |
| named-group | 6.1× (+512%) | 15.7× (+1466%) | 1.33× (+33%) | 0.40× (−60%) |
| case-insens | 24.9× (+2385%) | 34.6× (+3361%) | 0.67× (−33%) | 0.23× (−77%) |
| backref-dup | 10.1× (+907%) | 14.2× (+1316%) | 3.87× (+287%) | 0.39× (−61%) |
| greedy-dotstar | 72.5× (+7148%) | 96.9× (+9585%) | 38.8× (+3783%) | 8.44× (+744%) |

### Geomean across the 13 patterns

| comparison | geomean |
|---|--:|
| oniguruma_dart VM → Oniguruma C | **14.4× slower** (+1339%) |
| oniguruma_dart Web → Oniguruma C | **24.0× slower** (+2296%) |
| Dart RegExp VM → Oniguruma C | 2.2× slower (+124%) |
| Dart RegExp Web → Oniguruma C | **2.8× faster** (−65%) |
| oniguruma_dart VM → Dart RegExp VM | 6.4× slower |
| oniguruma_dart Web → Dart RegExp Web | 67.9× slower |
| oniguruma_dart Web → oniguruma_dart VM | 1.7× slower (web tax) |
| Dart RegExp Web → Dart RegExp VM | **6.3× faster** |

### Takeaways

- **Native `RegExp` ≈ C** (2.2×): it's the bar to beat, not this port.
- **`RegExp` on the web is the fastest thing here** (2.8× faster than C) because
  dart2js maps it onto Node/V8's native regex; that's also why it's **6.3× faster
  on web than on the VM**.
- **This port pays a web tax** (~1.7× vs its own AOT build); since its opponent
  speeds up on web, the gap widens from ~6× (native) to ~68× (web).
- **`greedy-dotstar` is C's blowout** (72× vs this port). See §8.5.
- Choose `oniguruma_dart` for dialect/encodings/byte-parity, not raw speed.

---

## 4. Why is the port slower than C / V8 / RegExp?

**Q: (1) Why is the Dart port magnitudes slower than the C lib? (2) How is V8 a lot
faster than the C lib? (3) Why is the port magnitudes slower than Dart RegExp?**

The key reframing: isolating the **raw byte engine** (`bench_dart`, the same
harness style as C) from the **String API** (`allMatches`, what the 5-way table
used) shows the "magnitudes" are mostly *not* the engine.

| pattern | Oniguruma C | port · byte engine | port · String API | byte ÷ C | String ÷ byte |
|---|--:|--:|--:|--:|--:|
| literal | 2.30 ms | 3.09 ms | 140.79 ms | **1.34×** | **45.6×** |
| class-lower | 33.69 ms | 55.66 ms | 193.97 ms | 1.65× | 3.5× |
| word-w | 33.71 ms | 61.54 ms | 207.75 ms | 1.83× | 3.4× |
| case-insens | 6.62 ms | 40.39 ms | 164.63 ms | 6.10× | 4.1× |
| greedy-dotstar | 12.16 ms | 786 ms | 881 ms | **64.7×** | 1.1× |

### (1) Port vs C: three stacked factors, only one is the "engine"

**(a) The String convenience layer: biggest factor for most patterns.** Per scan,
`OnigRegex.allMatches(String)` UTF-8-encodes the subject, builds **two dense O(n)
index arrays** mapping byte↔UTF-16 offsets, and allocates a region + match object
per match, none of which C's raw-byte harness pays. For `literal`, actual
matching is 3 ms but String-wrapping makes it 140 ms (a 45× tax unrelated to regex
speed). Strip it and the byte engine is **1.3–1.8× off C** on ordinary patterns.

**(b) The irreducible interpreter tax (~1.3–2×).** Both C-Oniguruma and the port
are the same algorithm, a backtracking bytecode interpreter, but C gets three
things Dart can't: **computed-goto** dispatch (Dart has no `&&label`),
**contiguous struct opcodes** (the port has a `List<Operation>` of heap references,
one pointer-hop per instruction), and **no bounds checks / safepoints** on every
byte access.

**(c) A couple of real optimizer gaps.** `greedy-dotstar` is 65× slower *at the
byte level*, a genuine deficiency (see §8.5). The exact-search is a naive
first-byte scan, not C's Boyer-Moore-Sunday skip table.

### (2) V8 vs hand-tuned C

V8's Irregexp **JIT-compiles each pattern to native machine code**, whereas C
*interprets* bytecode. A compiled, pattern-specialized matcher has no dispatch
loop, so it beats even hand-tuned interpreted C on simple patterns. It also has an
aggressive first-character / Boyer-Moore scan (`[0-9]+` over alpha text = 395 µs on
web-V8). But it isn't universal: on `greedy-dotstar`, C's `.*`+exact prefilter
**beats V8** (12 ms vs 103 ms), and Irregexp is still backtracking, so it can blow
up on pathological patterns.

### (3) Port vs Dart's RegExp

Dart's `RegExp` *is* V8's Irregexp, so this is (1)+(2) compounding: compiled-native
(or a heavily-tuned engine) vs an interpreted Dart VM driven through the String
layer. That's the 6.4× native gap. The **web** gap balloons to 68× mechanically:
compiled to JS the port becomes an interpreter running on another interpreter
(~1.7× slower than its native build), while `RegExp` maps onto Node/V8's native
regex (~6× faster than on the VM). Numerator slows, denominator speeds up.

**Honest summary:** the port's *core byte engine* is only ~1.3–2× off C on ordinary
patterns. The "magnitudes" come from the ergonomic String API, two optimizer gaps,
and the fact that C and especially `RegExp` are tightly/JIT-compiled. None of it is
a correctness cost.

---

## 5. What is Irregexp? Newer in Node vs Dart?

**Q: What is Irregexp? What do you mean by newer Irregexp in Node vs Dart?**

**Irregexp is V8's regular-expression engine** (Chrome, Node). Its defining trait:
instead of *interpreting* a pattern, it **compiles each regex into native machine
code** at construction: parse → automaton-node graph → optimization passes →
per-architecture code generator emits a specialized machine-code matcher. On
platforms without runtime codegen it falls back to an **Irregexp bytecode**
interpreter.

Two things make it fast: **compiled, not interpreted** (no dispatch loop), and a
**"quick check" / Boyer-Moore prefilter** that fast-forwards over positions that
can't start a match. It is still a **backtracking** engine (backrefs, lookaround),
so it can blow up on pathological patterns. Firefox/SpiderMonkey adopted Irregexp
too.

**"Newer in Node vs Dart":** Dart's `RegExp` is a **port of V8's Irregexp** into the
SDK. Node embeds a **current** V8 (updated every release); Dart carries its **own
in-tree copy** that doesn't track upstream. Same engine lineage, different vintage,
consistent with web `RegExp` (host V8) beating VM `RegExp` (Dart's copy). *(This
vintage framing is refined by proof in §8.1: on Dart 3.12+ the VM copy is bytecode-
interpreter-only, so the decisive factor is interpreter-vs-native-JIT, not vintage.)*

---

## 6. Backtracking vs other engine types; compiled vs interpreted

**Q: (1) What does "still backtracking" mean, and what are the alternatives?
(2) Why is Oniguruma interpreted? Do its features require it? (3) Why is V8
"compiled" but not Oniguruma C, when both are C/C++? (4) What does Oniguruma buy
you over V8/RegExp? (5) Could a package give Dart a compiled engine?**

### (1) Two engine families

**Backtracking engines** explore depth-first and back up on failure → support
backreferences, lookaround, atomic groups, recursion; worst case **exponential**
(catastrophic backtracking). → Oniguruma, PCRE, Perl, Python `re`, Java, .NET, V8
Irregexp.

**Automaton engines** (Thompson NFA / DFA) track the *set of all possible states at
once* → **linear time**, no blowup, but can't do backreferences (non-regular) and
traditionally not lookaround. → RE2, Rust `regex`, Go `regexp`, grep, Hyperscan.

"Irregexp is *still* backtracking" = compiling it to fast native code made each step
quicker but kept the family-A algorithm: rich features *and* exponential worst
case. (Terminology trap: Friedl's book calls the backtracking engine the "NFA
engine", the opposite of CS usage.)

### (2) Why Oniguruma is interpreted, and features are orthogonal

It compiles patterns to its own **bytecode** walked by a fixed `match_at` switch.
Reasons: **portability** (runs anywhere a C compiler exists: a JIT needs a
machine-code generator per arch), **embeddability/safety** (no writable-executable
memory), **cheap pattern build**.

Crucially, **compiled-vs-interpreted is orthogonal to features.** Compilation
governs speed per step, not expressiveness: V8 is compiled *and* supports
lookaround/backrefs. Oniguruma's rich features come from being **backtracking**
(which V8 also is); JS lacks `\g<>`/callouts because the **spec** omits them, not
because a compiled engine can't. The one feature more *natural* in an interpreter
is callouts, but PCRE supports callouts with its JIT too.

### (3) Why V8 is "compiled" but Oniguruma isn't (both are C/C++)

The distinction is about **what happens to *your pattern* at runtime**:

| | your pattern becomes… | who executes it |
|---|---|---|
| Oniguruma | **bytecode (data)** | one fixed interpreter loop (`match_at`) |
| V8 Irregexp | **fresh native machine code** at RegExp construction | the CPU runs *that* code |

Same idea as CPython (bytecode interpreter) vs a JIT: both engines' *source* is
compiled C++, but only the JIT turns *your program* into machine code. "Compiled
regex" = the *pattern* is JIT'd to native code; "interpreted" = the pattern stays
data.

### (4) What Oniguruma C buys you over V8 / RegExp

1. **A far richer dialect**: `\g<>` recursion, `\k<n+1>`, conditionals, callouts,
   `\K`, `(?~…)`, plus **12 selectable syntaxes**.
2. **~20 native encodings** (EUC-JP, Shift-JIS, Big5, GB18030, ISO-8859-*, …) on
   raw bytes; V8/Dart only match UTF-16.
3. **Byte-accurate offsets** in the source encoding.
4. **Portability & JIT-free operation** (sandboxes/iOS, smaller attack surface).
5. **Predictable, cheap compile cost**.
6. **It *is* Ruby's engine**: port Ruby regexes verbatim.

Trade-off: raw throughput on hot patterns. That list is exactly why the pure-Dart
port exists: dialect/encodings/byte-parity, not speed.

### (5) Could a package give Dart a compiled engine?

**A pure-Dart package cannot JIT**: Dart exposes no runtime code-generation API, so
any pure-Dart regex engine is structurally an **interpreter**. Options:

1. **FFI to a native compiled engine**: PCRE2 (has a real JIT), RE2, Rust `regex`.
   Native-only, no web; the FFI route this project avoided.
2. **Build-time codegen for *static* patterns**: a macro/build_runner that turns a
   regex literal into a specialized Dart function, AOT-compiled to native. Works
   everywhere, but only for compile-time-known patterns.
3. **Improve the pure-Dart interpreter**: BMH prefilters, flattened `Int32List`
   bytecode, a linear Thompson-NFA fast path (RE2-style guarantees). No JIT, but
   closes most of the gap and removes catastrophic backtracking.
4. **Web-only curiosity**: `eval`/`new Function` via JS interop borrows the host
   JIT, i.e. basically "use the host RegExp."

Updating the SDK's `RegExp` itself is only the SDK team's call (re-syncing their
Irregexp fork); a package can't touch it.

---

## 7. Linear engines, JIT vs AOT, and how JS regex is compiled

**Q: (1) Why are RE2/Rust always linear? Don't they need backtracking? How do you
backtrack in those languages? (2) Would Dart JIT RegExp be faster than AOT? (3) Does
Oniguruma use an interpreter internally too? (4) Because JS is "not compiled" on web,
it JITs the regex to native code and is fastest?**

### (1) RE2/Rust never backtrack, and reject backref patterns

They use a different algorithm. Example `a(b|c)d` on `acd`: a backtracking engine
tries `b`, fails, backs up, tries `c`. A linear engine, after `a`, is in the state-
*set* {expecting-b, expecting-c}; reading `c`, "expecting-b" dies and "expecting-c"
advances, no backing up. It reads each character once and the state-set is bounded
by the pattern size → **O(input × pattern)**, linear. The deep reason: linear
engines never revisit the same (position, state) twice; pure backtracking has no
such memory and re-explores exponentially.

**How do you do backreferences there? You don't. They refuse.** A regex without
backrefs is a **regular language** (linear-time recognizable); one with a backref
like `(a+)\1` is **non-regular** and matching is **NP-complete**. So RE2 and Rust's
`regex` **reject backreferences and lookaround at compile time**. If you need them
you switch to a *backtracking* library: Rust's `fancy-regex`, or bindings to
PCRE2/Oniguruma; Go would cgo to PCRE. (Capturing groups for *extraction* work in
linear engines via tagged-NFA; it's *back-references* specifically that force
backtracking.)

### (2) JIT vs AOT RegExp (measured: no difference)

Running the same benchmark under JIT (`dart run`) vs AOT (`dart compile exe`):

| pattern | RegExp·AOT | RegExp·JIT | port·AOT | port·JIT |
|---|--:|--:|--:|--:|
| literal | 4.45 ms | 4.60 ms | 140.8 ms | 186.0 ms |
| class-lower | 40.55 ms | 40.17 ms | 194.0 ms | 272.3 ms |
| backref-dup | 181.7 ms | 180.8 ms | 472.9 ms | 655.7 ms |
| greedy-dotstar | 472.1 ms | 464.8 ms | 881.2 ms | 1751.2 ms |

`RegExp` is **identical within noise** across JIT and AOT (and the port ran *slower*
under JIT). So the earlier hypothesis "AOT interprets, JIT compiles-native" is
**wrong for this SDK**: on the Dart VM, JIT vs AOT makes no difference for `RegExp`.
The genuine JIT-to-native win only appeared on the **web** (host V8). *(Proven and
explained in §8.1: Dart 3.12 removed native regex codegen entirely.)*

### (3) Oniguruma is always an interpreter

**Oniguruma has no JIT, ever.** The C *engine* is compiled to native code, but the
*pattern* is always bytecode walked by `match_at`. Contrast PCRE2, which is normally
an interpreter but ships an *optional* JIT (`pcre2_jit_compile`). Oniguruma-C,
Dart-VM `RegExp`, and this port are the same shape: native engine + interpreted
pattern.

### (4) JS *is* compiled, by the JIT, at runtime

Fix the premise: JS on the web **is compiled**, by the browser's JIT, at runtime.
Modern engines compile hot JS *and* regexes to native machine code, and browser/Node
processes are allowed to generate executable code (unlike iOS/AOT). So yes: the
pattern is JIT'd to native → fast. But "fastest here" is JIT + a modern V8 + low
allocation overhead together, and not unconditional: **iOS forbids JS JIT** (regex
runs interpreted), **catastrophic backtracking still blows up**, and C's prefilter
beat web-V8 on `greedy-dotstar`.

**Unifying rule:** every engine is `{backtracking | linear} × {interpreted |
JIT-native}`, and you only get the JIT-native half where the platform permits
runtime code generation. Desktop/Node: yes; iOS and any AOT build (Flutter release,
this compiled port): no.

---

## 8. Primary-source proofs

**Q: (1) Look into current Dart SDK internals for JIT and AOT and Node's V8, no
assumptions. (2) Where do `RegExp`'s `external` methods come from; can packages use
`external`? (3) Oniguruma vs PCRE2. (4) If Node is compiled to an exe, does it lose
native regex and get slower? (5) How did Oniguruma C beat web-V8 on greedy-dotstar?**

### 8.1 Dart VM: JIT and AOT both interpret (as of 3.12)

**Headline (proven):** Dart **3.12.0 removed native regex code generation from the
VM entirely.** On 3.12.2, `RegExp` runs the V8 Irregexp **bytecode interpreter in
both JIT and AOT**, which is exactly why the JIT≈AOT benchmark held.

**Your era (3.12.0+):** native target is unreachable,
[`regexp.cc` @ 3.12.2 L399](https://github.com/dart-lang/sdk/blob/3.12.2/runtime/vm/regexp/regexp.cc#L399):
```cpp
if (data->compilation_target == RegExpCompilationTarget::kNative) {
  UNREACHABLE();
} else {                       // the only path taken
  macro_assembler.reset(new RegExpBytecodeGenerator(...));
```
Matching runs `IrregexpInterpreter::MatchForCallFromRuntime(...)`; tier-up is stubbed
`UNREACHABLE(); // No tier up in Dart.` The `--interpret-irregexp` flag is gone.

**Old era (≤ 3.11):** the classic model held: JIT compiled to native, AOT used the
interpreter. `CompileIR` (native) exists only under `!FLAG_interpret_irregexp` and is
`#if !defined(DART_PRECOMPILED_RUNTIME)`-compiled out of AOT, and AOT force-sets the
flag,
[`compiler.cc` @ 3.11.0 L91](https://github.com/dart-lang/sdk/blob/3.11.0/runtime/vm/compiler/jit/compiler.cc#L91):
```cpp
static void PrecompilationModeHandler(bool value) {
  if (value) { ... FLAG_interpret_irregexp = true; ... }
```
So on Dart ≤ 3.11 you *would* have measured JIT (native) faster than AOT (bytecode).

Irregexp's V8 origin is explicit: files headed `// Copyright 2012 the V8 project
authors`, with `IrregexpInterpreter`, `RegExpBytecodeGenerator`, and Dart edits like
`// No tier up in Dart.`

**Correction this proves:** the web `RegExp` being ~6× faster than VM `RegExp` is
decisively **interpreter (VM, 3.12+) vs native-JIT (host V8 on web)**, not "newer
vintage."

### 8.2 Node's V8: native by default

Default mode "compile[s] directly to native code on first use." `regexp.cc` picks
`CompilationTarget::kNative`; the arch macro-assembler emits instructions finalized
into a `Code` object of `CodeKind::REGEXP`
([v8/regexp.cc](https://github.com/v8/v8/blob/main/src/regexp/regexp.cc),
[regexp-macro-assembler-x64.cc](https://github.com/v8/v8/blob/main/src/regexp/x64/regexp-macro-assembler-x64.cc)).
> "Irregexp jit-compiles RegExps to specialized native code … and is thus extremely
> fast for most patterns." ([v8.dev/blog/non-backtracking-regexp](https://v8.dev/blog/non-backtracking-regexp))

Only `--jitless` (or a JIT-forbidden OS) drops to the interpreter:
`DEFINE_IMPLICATION(jitless, regexp_interpret_all)`. iOS/smart-TVs/consoles forbid
executable memory → interpreter ([v8.dev/blog/jitless](https://v8.dev/blog/jitless)).
V8 also ships an opt-in **linear-time non-backtracking** engine under
`src/regexp/experimental/` (the `l` flag).

### 8.3 `external` methods: where they come from; packages

`RegExp`'s public API is `external`
([dart-sdk/lib/core/regexp.dart L274](https://github.com/dart-lang/sdk/blob/main/sdk/lib/core/regexp.dart)):
```dart
external factory RegExp(String source, {bool multiLine, bool caseSensitive, ...});
```
`external` means "the implementation is supplied elsewhere," resolved per platform:

- **VM (native/AOT):** bound to a **VM C++ native** via a pragma:
  `@pragma("vm:external-name", "RegExp_ExecuteMatch") external Int32List? _ExecuteMatch(...)`
  (the Irregexp engine compiled into the runtime).
- **Web (dart2js):** calls the **host JS RegExp**:
  `JS('...', 'new RegExp(source, modifiers)')` and `#.exec(#)`.
- **Wasm:** JS interop:
  `extension type JSNativeRegExp implements JSObject { external JSNativeMatch? exec(JSString s); }`.

**Can a package use `external`? Yes**: the wasm file above *is* the package-style
mechanism. Packages get two sanctioned bindings: **`dart:ffi`** (`@Native<...>()
external ...` → a symbol in a native library) and **JS interop** (`@JS` external
members → JavaScript, web only). What's **SDK-only** is the mechanism `RegExp`
happens to use: `@patch` files and `vm:external-name` VM natives. A package cannot
register new VM C++ natives or patch core libraries. So a package can have `external`
methods, just not backed by hand-written VM C++.

### 8.4 Oniguruma vs PCRE2

| | Oniguruma | PCRE2 |
|---|---|---|
| Core matcher | backtracking interpreter: **no JIT, no DFA** | backtracking interpreter |
| JIT (→ native) | **none** | **yes**: `pcre2_jit_compile` (SLJIT) |
| Non-backtracking mode | none | **yes**: `pcre2_dfa_match` (no captures/backrefs) |
| Native byte encodings | **~20+** (EUC-JP, Shift-JIS, Big5, GB18030, …) | 8/16/32-bit units, UTF only: **no legacy CJK** |
| Selectable syntaxes | **12** | **one** (Perl-compatible) |
| Lookbehind | fixed-width only | **variable-length** (bounded, since 10.43) |
| Licence | BSD-2-Clause | BSD-3-Clause + PCRE2 exception |
| Status | archived Apr 2025 (6.9.10) | actively maintained (10.x) |
| Users | PHP `mbstring`, jq, VS Code; Ruby via **Onigmo** fork | PHP `preg_*`, nginx, Apache, `git grep -P`, R |

PCRE2 sits on *both* sides of the architecture axes: normally interpreted, but
`pcre2_jit_compile()` "further processes a compiled pattern into machine code that
executes much faster" ([pcre2jit](https://www.pcre.org/current/doc/html/pcre2jit.html)),
and `pcre2_dfa_match()` gives a non-backtracking mode ("does not backtrack," "no
captured substrings," "substantially slower")
([pcre2matching](https://www.pcre.org/current/doc/html/pcre2matching.html)).
**Oniguruma has neither**: its API exposes no JIT and no DFA entry point. PCRE2-JIT
speedups (from the SLJIT author's own benchmarks, not the man page) are ~3–5× average,
up to ~10.9× best case.

**Why port Oniguruma and not PCRE2?** The two rows PCRE2 can't match: ~20 native byte
encodings and 12 selectable dialects (plus Ruby semantics and `(?~…)`). If you only
needed Perl-dialect UTF speed, PCRE2-JIT-via-FFI would win easily.

### 8.5 How Oniguruma C beat web-V8 on `.*lorem`

Oniguruma turns a greedy-scan pattern into a fast substring hunt (all verified in
the vendored `oniguruma-master/src`):

1. **Extracts the mandatory literal "lorem" + builds a Boyer-Moore/Sunday skip
   table** (`regcomp.c` `set_optimize_exact`): `reg->exact = "lorem"`,
   `set_sunday_quick_search_or_bmh_skip_table(...)`, `reg->optimize = OPTIMIZE_STR_FAST`.
2. **Skips multiple bytes at a time** (`regexec.c` `sunday_quick_search`):
   `s += reg->map[*(s + map_offset)];`: sublinear scan, landing only near "lorem".
3. **Recognizes the leading `.*` as an anchor** (`ANCR_ANYCHAR_INF`), so it matches
   `.*` back to the line start **once** instead of retrying every offset.
4. **`.*` is a dedicated `OP_ANYCHAR_STAR` opcode**, dispatched via **computed-goto**
   (`USE_DIRECT_THREADED_CODE`, enabled for clang/gcc).

Net: C touches only a fraction of the corpus → **12 ms**.

**Why V8 loses here:** V8's fast-skip is a *bounded-window* Boyer-Moore lookahead. A
leading `.*` makes "lorem" appear at an **unbounded** offset from the match start,
defeating the window, so V8 runs the greedy `.*` (consume to end-of-line, then
backtrack) line after line, including lines with no "lorem" → **103 ms**.

**Why this port was even slower (786 ms):** it *does* extract "lorem" but searches
with a naive first-byte scan (no skip table) and, with `distMax = ∞`, retries
`matchAt` at **every** offset up to the "lorem" hit: it never learned the
`ANCR_ANYCHAR_INF` anchor trick. That's the specific, fixable gap.

---

### The whole thread in one law

An engine is **`{backtracking | linear} × {interpreted | native-code}`**, and you
only get the native-code half where the platform permits runtime code generation.

- **Backtracking vs linear**: rich features + exponential risk (Oniguruma, PCRE2, V8)
  vs linear-but-no-backrefs (RE2, Rust, V8's experimental engine, PCRE2 `dfa_match`).
- **Interpreted vs native**: Oniguruma is *always* interpreted; PCRE2 can JIT via
  SLJIT; V8 is native-JIT except jitless/iOS; **Dart's VM `RegExp` (3.12+) is now
  always interpreted**, and Dart's only native regex is on the **web**, borrowed from
  the host JS engine.
- **This port** is pure-Dart *interpreted backtracking*, the same category as Dart's
  own VM `RegExp` today, which is why its real gap to `RegExp` on the VM is far
  smaller than the headline number, and why its reason to exist is Oniguruma's
  **encodings + dialects + byte-parity**, not raw throughput.

*Sources: Dart SDK at tags 3.11.0 / 3.12.2, V8 `main`, Node.js docs, PCRE2 man pages
(pcre.org), and the vendored Oniguruma 6.9.10 tree. Explicitly non-primary: PCRE2-JIT
speedup multipliers (SLJIT author's benchmarks) and `pkg`/`nexe` JIT-retention
(mechanism-inferred).*
