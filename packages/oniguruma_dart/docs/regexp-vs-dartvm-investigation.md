# Investigation: oniguruma_dart vs. Dart VM `RegExp` — engine internals & the String-API gap

**Status:** investigation / reasoning phase only. No implementation here — this document
establishes *what* the Dart VM's `RegExp` actually does, *how* our port differs, *why*
our String API is slow, and a **prioritized, severity-ranked backlog** for the next phase.

**Environment:** Dart SDK 3.12.2 (stable), macos_arm64 (bundled with Flutter at
`~/flutter/bin/cache/dart-sdk`). All Dart-VM source references are against
`dart-lang/sdk@3.12.2`. All port references are against this repo's `lib/`.

---

## 0. Executive summary

Two independent gaps, with very different causes and fixes:

| Surface | Measured gap | Root cause | Fix cost |
|---|---|---|---|
| **String API** | up to **28× slower** than `RegExp` (`literal`, `case-insens`) | Wrapper rebuilds a `Map<int,int>` byte↔UTF-16 index (~1.1 M entries) on every call. **94 % of the time is index setup; the VM itself is 3 %.** | **Cheap.** Architectural but small; uses encodings we already have. |
| **Byte-API engine** | **2.24× C** geomean; ~2–3× C on class/quant patterns | Per-char virtual UTF-8 decode + a backtrack-stack push per char in deterministic loops; unused fast-path opcodes; no one-byte subject specialization. | **Medium.** Real engine work, must preserve the parity oracle. |

Headline proof (pattern `lorem`, 1.14 MB **ASCII** corpus, AOT):

```
b2c Map<int,int> build ....... 97.5 ms   (84% of String-API time)
c2b List<int> build .......... 8.8 ms
utf8.encode .................. 3.2 ms
   -> index setup total ...... 109.5 ms  (94%)
actual matching (byte VM) .... 3.3 ms    (3%)   <-- faster than RegExp's match
RegExp end-to-end ............ 4.4 ms
String-API end-to-end ........ 116 ms
```

The port's **byte engine matched faster than RegExp** here (3.3 ms vs 4.4 ms). The entire
String-API slowdown is the wrapper, not the engine.

A crucial, non-obvious finding from the SDK source: **Dart's `RegExp` is *also* a bytecode
interpreter — a near-verbatim re-import of V8's Irregexp — in both JIT and AOT.** It is not
compiled to machine code. So this is interpreter-vs-interpreter; we are not fighting a JIT.
It *is* faster per-instruction (mature C++, computed-goto dispatch, one-byte specialization),
but it is the *same class* of engine, and it is **exponential-worst-case backtracking with the
backtrack limit wired off** — an area where our linear NFA path is already strictly better.

---

## Part A — How Dart VM `RegExp` actually works (source-backed)

### A.1 It is V8 Irregexp, re-imported

In 3.12.2 the engine is not the old hand-maintained Dart fork; it is a fresh import of V8's
`src/regexp/*` living under `runtime/vm/regexp/` with V8's hyphenated filenames. The port's
own README says so:

> "The Dart VM's implementation is taken from V8, which is called Irregexp."
> — `runtime/vm/regexp/README.md:3`

`README.md:5-14` lists what Dart **disabled** vs. V8: the atom optimization, the experimental
(non-backtracking, linear) engine, **the bytecode peephole optimization**, **the machine-code
implementations**, tier-up/statistics, and match caching. Upstream pin: V8 commit
`254cc758…` (`README.md:29`).

### A.2 End-to-end pipeline

```
RegExp(source)               -> RegExp_factory: parse once (eager syntax check), cache object.
                                 NO compilation yet.  (runtime/lib/regexp.cc:20-79)
first _ExecuteMatch(str,i)   -> RegExp_ExecuteMatch native (runtime/lib/regexp.cc:140-174)
                                 validates len/start fit int32, calls RegExpStatics::Interpret.
RegExpStatics::Interpret     -> if bytecode(is_one_byte, sticky) == null: compile it now.
  (regexp.cc:492-551)           Lazy, per subject-encoding, per sticky.
compile                      -> parse -> AST -> node graph -> RegExpBytecodeGenerator
                                 emits Irregexp BYTECODE into a Uint8List.
interpret                    -> IrregexpInterpreter walks the bytecode; on success memcpy's
                                 the int32 registers into a fresh Int32List (code-unit offsets).
```

### A.3 The interpreter-vs-compiled verdict — **bytecode interpreter only, JIT and AOT**

Proven three independent ways:

1. **Native codegen is dead code.** `RegExpImpl::Compile` has two targets; `kNative` is
   `UNREACHABLE()`:
   ```cpp
   // runtime/vm/regexp/regexp.cc:399-408
   if (data->compilation_target == RegExpCompilationTarget::kNative) {
     UNREACHABLE();
   } else {  // kBytecode
     macro_assembler.reset(new RegExpBytecodeGenerator(isolate, zone,
         is_one_byte ? RegExpMacroAssembler::LATIN1 : RegExpMacroAssembler::UC16));
   }
   ```
2. **Every caller hard-codes `kBytecode`** (`regexp.cc:178-187, 499-501`); `CanGenerateBytecode()`
   is `return true;` (`regexp.cc:104-106`).
3. **No AOT/JIT split at all.** No `DART_PRECOMPILED_RUNTIME` in any regexp source; there is no
   `FLAG_interpret_irregexp` flag in this port. The same C++ interpreter is compiled into both
   the JIT VM and the AOT runtime.

So: **there is no path that turns a regex into ARM64/x64 machine code, in either mode.** (This
finally settles the earlier question — AOT and JIT both interpret Irregexp bytecode.)

### A.4 Character/string handling — zero transcoding, offsets are code-unit indices

Dart strings are `OneByteString` (Latin-1, 1 byte/unit) or `TwoByteString` (UTF-16, 2 bytes/unit).
The interpreter reads the **raw backing store directly**, templated on element type — no UTF-8,
no conversion:

```cpp
// runtime/vm/regexp/regexp-interpreter.cc:1179-1190
if (subject_string.IsOneByteString()) {
  subject_vector = {OneByteString::DataStart(subject_string), subject_string.Length()};
  return RawMatch<const uint8_t, OneByteString>(...);
} else {
  ... TwoByteString::DataStart ...
  return RawMatch<const uint16_t, TwoByteString>(...);   // uint16_t path
}
```

A character read is a plain indexed load: `current_char = subject[pos];` where `subject` is a
`const Char*` (`regexp-interpreter.cc:642-651`). Because the input is already in the matcher's
coordinate space, the returned `Int32List` of register pairs is **already UTF-16 code-unit
offsets** into the Dart `String` — the Dart layer does no mapping (`regexp_patch.dart:110`
`input._substringUnchecked(start, end)`).

**Two bytecode programs are compiled and cached per regex — one-byte and two-byte** (× sticky =
four slots): `object.h:13026-13052`. First use against a Latin-1 subject compiles the LATIN1
program; the first two-byte subject compiles a separate UC16 program (`regexp.cc:497-505`).
Char-classes are clamped to one byte when `is_one_byte` (`regexp-compiler.cc:1435`), and
`Load4Characters` (4 code units in one 32-bit compare) is **Latin-1 only**
(`regexp-interpreter.cc:112-119`). This one-byte specialization is a big reason RegExp is fast on
ASCII/Latin-1 text.

### A.5 Prefilters / fast-starts that are actually ACTIVE

Flag reality (`runtime/vm/regexp/base.h:164-172`):
```cpp
FLAG_regexp_optimization         = false;   // V8 default is true  -> disables inline quick-check + node specialization
FLAG_regexp_quick_check          = true;
FLAG_regexp_peephole_optimization= false;   // -> most SkipUntil* variants are dead
FLAG_regexp_possessive_quantifier= false;
FLAG_regexp_unroll               = false;
FLAG_regexp_tier_up              = false;
```

- **Boyer-Moore lookahead skip — ACTIVE.** `BoyerMooreLookahead` + `EmitSkipInstructions`
  (`regexp-compiler.cc:2794-3130`), used by `EmitOptimizedUnanchoredSearch` (`:3376-3434`) for the
  implicit unanchored `.*?` prefix. Gated on `FLAG_regexp_quick_check` (**true**), so it runs.
  Lookahead window ≤ 8 chars (`regexp-compiler.h:48-51`).
- **`cannot_match` pruning — ACTIVE.** Impossible alternatives dropped via `GetQuickCheckDetails`.
- **Reachable skip bytecodes:** `kSkipUntilBitInTable`, `kSkipUntilCharAnd` (interpreter hot loops
  scan forward without per-char re-dispatch, `regexp-interpreter.cc:958-1009`). The other
  `SkipUntil*` variants are peephole-only ⇒ `UNREACHABLE()` in Dart.
- **Anchors:** end-anchor back-search `SetCurrentPositionFromEnd` (`regexp.cc:424-431`),
  `CheckAtStart`/`CheckNotAtStart`.
- **Bit-table char-class check** `CheckBitInTable` (128-entry bitmap) and `CheckSpecialClassRanges`
  for `\d \w \s .` etc.

**Disabled vs V8:** inline per-alternative quick-check and node-version specialization
(`quick_check_flags = FLAG_regexp_optimization && FLAG_regexp_quick_check` = false,
`regexp-compiler.cc:3454`), peephole bytecode fusion, native codegen, tier-up, the linear engine.

### A.6 Bytecode & dispatch

~70 bytecodes (X-macro lists, `regexp-bytecodes.h`), grouped: position/register/stack mgmt,
control flow (`GoTo`, `Backtrack`, `Fail`, `Succeed`), char loads (`LoadCurrentCharacter`,
`Load2/4CurrentChars`), single-char checks (`CheckCharacter`, `…AfterAnd`, `…InRange`, `…LT/GT`),
multi-char/bitmap checks (`Check4Chars`, `CheckBitInTable`, `CheckSpecialClassRanges`),
register predicates (`IfRegisterLT/GE/EqPos`), backrefs (`CheckNotBackRef[NoCase][Unicode]…`),
and the two live skip loops.

Dispatch is **computed-goto (token-threaded) when the toolchain supports it**, else `switch`
(`regexp-interpreter.cc:22-27, 253-288`). On macos_arm64/Clang, computed-goto is active
(`base.h:55-57`): a `dispatch_table[]` of label addresses, power-of-two padded and masked so a
corrupt opcode can only reach a `Break` filler.

### A.7 Backtracking model — exponential, no step limit

Classic backtracking NFA. **Not** RE2-linear (the experimental linear engine is one of the
disabled features; `FALLBACK_TO_EXPERIMENTAL` is `UNREACHABLE()`, `regexp.cc:545`).

- Backtrack stack: `SmallVector<int,64>` growing to `kMaxSize = 64 MB / 4 = 16,777,216` entries
  (`regexp-interpreter.cc:157-162`). Overflow → `StackOverflow` **exception**, not graceful.
- **Backtrack limit is wired OFF:** `backtrack_limit = JSRegExp::kNoBacktrackLimit == 0`
  (`regexp-interpreter.cc:1132`, `regexp.cc:304-309`). The `Backtrack` bytecode's early-abort only
  triggers when a `uint32_t` counter wraps (~4.29 B backtracks) — effectively never
  (`regexp-interpreter.cc:577-581`).
- Only escape hatches: the 64 MB stack cap (bounds *depth*, not *time* — classic `(a+)+$` blows up
  in time with modest depth) and cooperative isolate interrupts (external timeout).

**Consequence:** Dart `RegExp` is fully ReDoS-susceptible. Our linear NFA path (§B.3) is a genuine
advantage on that pattern class.

---

## Part B — Our engine inventory (this repo)

### B.1 Prefilters / fast-starts we HAVE

`lib/src/compile/optimize.dart` (`setOptimizeInfo`, runs once at compile) → dispatched by
`lib/src/exec/search.dart` (`onigSearch`, on `reg.optimize`).

- **Start anchors** `\A`/`\G` → `reg.anchor`; driver attempts only at pos 0 / `start`
  (`search.dart:73-89`).
- **`Optimize.str`** — mandatory exact literal + **Sunday/BMH** 256-entry skip table
  (`_setExact`/`_buildSundaySkip`, `optimize.dart:262-284`; scan `_searchExact`, `search.dart:201-223`).
  Works for a leading literal *or* a middle literal with a byte-distance window (e.g. `@` in `\w+@\w+`).
  - Sub-mode: **leading `.*`/`.+` anchor** (`exactAnchorAnyChar[Ml]`) — finds the required literal,
    then anchors to line start / whole-buffer (`search.dart:125-145`). This is the fix that put
    `.*lorem` at parity with C.
- **`Optimize.map`** — 256-entry first-byte set; driver skips positions where `map[str[s]]==0`
  (`search.dart:167-182`). Built for (a) a **case-insensitive leading literal** via the fold class
  (`_icLeadingByteMap`, bails on multi-char folds like `ß↔ss`), and (b) a **computable first-byte set**
  over `StrNode` / single-byte `CClassNode` / `lower≥1` quantifiers / alternations / groups.

**Bails to `Optimize.none`:** wide encodings (`enc.minLength != 1`) get **no** str/map prefilter at
all (`optimize.dart:57`); **`CtypeNode` (`\w \d \s .`) never builds a map** (`optimize.dart:332-335`);
negated / multibyte classes excluded.

### B.2 Executor hot-path cost model

Bytecode is the flattened interleaved `Int32List` (`FlatOps`, stride 11), dispatched by a flat-array
switch — good, no per-op object deref for scalars:
```dart
// lib/src/exec/executor.dart:138-139
final base = pc * FlatOps.stride;
switch (sc[base + FlatOps.oOpcode]) {
```
But object payloads (`opStr[pc]`, `opBs[pc]`, …) are still bounds-checked array derefs, and the
**per-character cost is the problem.** For `[a-z]+` over ASCII, each *additional* matched char runs:

- `Op.push` (backtrack-stack push) + `Op.cclass` + `Op.jump` — **3 dispatches**, because the greedy
  tail compiles to `PUSH exit; class; JUMP back` (`compiler.dart:_greedyInfinite`), and
- inside `Op.cclass` (`executor.dart:256-270`): **two virtual encoding calls** —
  `enc.length(...)` **and** `enc.mbcToCode(...)` (full code-point decode) — even though the class is
  pure ASCII and a byte test would suffice, plus `opBs[pc]!.at(code)` (object deref + bitset word), and
- **one backtrack-stack push per char** (the deterministic loop still records a choice point).

`enc` is the abstract `OnigEncoding` (`encoding.dart:33`); `length`/`mbcToCode`/`isMbcNewline` are
interface calls not devirtualized in the source. `Op.str1..str5` are the cheap paths (direct byte
compare, no decode). Backtrack stack is struct-of-arrays typed lists (`stack.dart:29-77`) — zero
per-push allocation, but still touched once per deterministic-loop char.

### B.3 Linear-time NFA coverage (we have something RegExp does NOT)

`lib/src/exec/nfa.dart` is a Pike/Thompson NFA giving **O(text × program)**. But it is **opt-in for
risky patterns only**: `buildNfa` returns null unless `_isRisky(root)` — a quantifier whose body can
itself branch/repeat (nested repetition like `(a+)+`, `(a|ab)*`). Flat patterns (`[a-z]+`, `a.*b`)
deliberately stay on the backtracking VM to keep the prefilters. It also bails on ignore-case,
backrefs, calls, look-around, atomic, `\d`/`\s`/`\X`, empty-capable loops, and is gated at search
time by `nfaUnsafeOptions` (findLongest/findNotEmpty/matchWholeString/ignoreCase/…).

**Net: for nested-repetition patterns we are linear where Dart RegExp is exponential.** Confirmed by
the earlier benchmark (`(a+)+` on 5000 chars < 1.5 ms for us; RegExp/backtracking blows up).

### B.4 Fast-path gaps vs Irregexp (from the inventory)

- **No one-byte / ASCII subject specialization** — always virtual-decodes a full code point.
- **Virtual encoding dispatch in the hot loop** — not monomorphized/inlined.
- **Declared-but-unused fast opcodes:** `anycharStar`, `anycharMlStar`, and the `*PeekNext`
  quick-check ops exist in the enum but are **never emitted or handled** (executor `default` throws).
  So Oniguruma's own peek/quick-check and specialized `.*` loop are absent from our build.
- **No deterministic-quantifier no-backtrack** — `[a-z]+` pushes a backtrack frame per char.
- **`\d \s \w .` never yield a first-byte map**; wide encodings get no prefilter.
- **No Boyer-Moore skip *over a class*** (only Sunday over a single exact literal). Irregexp keeps
  BM lookahead over classes (window ≤ 8).

---

## Part C — Head-to-head

| Dimension | Dart VM `RegExp` (Irregexp) | oniguruma_dart |
|---|---|---|
| Engine class | Bytecode **interpreter** (JIT & AOT) | Bytecode **interpreter** |
| Dispatch | Computed-goto threaded | Flat-`Int32List` `switch` |
| Subject form | **Native**: one-byte Latin-1 *or* two-byte UTF-16, read directly | **UTF-8 bytes** (`Uint8List`) |
| Per-char (ASCII class) | indexed load + bitmap/range compare, one-byte program | `enc.length` + `enc.mbcToCode` (virtual, full decode) + bitset |
| One-byte specialization | **Yes** (separate compiled program, 4-char bulk compares) | **No** |
| Start prefilter | Boyer-Moore skip (≤8) + `cannot_match`, bit-table | Sunday/BMH over exact literal; first-byte map; `.*` anchor |
| Class-start prefilter | Derived from classes generally | Only literals / single-byte classes; **not** `\w \d \s .` |
| Offsets | **Code-unit indices, free** | Byte offsets → mapped back to code units (String API) |
| Catastrophic backtracking | **Exponential, limit wired off** | **Linear NFA** for nested-repetition subset ✅ |
| Backref / look-around / atomic | Backtracking | Backtracking |

**Reading:** at the *engine* level we are the same class, a constant factor behind on per-char work
(one-byte specialization + devirtualized reads + fewer backtrack pushes explain most of the 2–3× on
class/quant patterns). At the *worst-case* level we are ahead (linear NFA). At the *String-API* level
the gap is not the engine at all — it's the wrapper.

---

## Part D — The String-API gap, dissected

### D.1 What the wrapper does per call (`lib/src/api/string_api.dart`)

`firstMatch`/`allMatches` build a `_Utf8Index(input)` (`string_api.dart:157-213`) which, **every call**:
1. `Uint8List.fromList(utf8.encode(input))` — full re-encode.
2. `List<int>.filled(n+1)` `_c2b` (code-unit→byte), one `input.runes` pass.
3. `Map<int,int>` `_b2c` (byte→code-unit) — a hashmap with **one entry per character boundary**,
   a *second* `input.runes` pass.
4. `charAt(byteOffset)` does a hashmap lookup per result offset, with an **O(n) linear scan of the
   whole map** as a fallback (`string_api.dart:199-205`).

### D.2 Measured cost (pattern `lorem`, 1.14 MB ASCII, AOT)

| component | time | share |
|---|--:|--:|
| `Map<int,int>` `_b2c` build | **97.5 ms** | **84 %** |
| `List<int>` `_c2b` build | 8.8 ms | 8 % |
| `utf8.encode` | 3.2 ms | 3 % |
| **matching (byte VM)** | **3.3 ms** | **3 %** |
| String-API end-to-end | 116 ms | 100 % |
| `RegExp` end-to-end | 4.4 ms | — |

(Harness: `benchmark/bench_stringapi_breakdown.dart`.) The corpus is **`ascii-only=true`**, so
`_b2c`/`_c2b` are the *identity map* — 106 ms of pure waste. The VM matched faster than RegExp.

### D.3 Why RegExp pays ~0 for the same work

It matches on the string's native buffer (§A.4) and returns code-unit offsets directly. No encode,
no index, no back-mapping; group strings are materialized lazily only on `group()`. Setup cost is
zero because the subject is *already* in the matcher's coordinate space.

### D.4 The path (uses encodings we already ship)

The port already has `iso8859_1` (single-byte) and `utf16` encodings, and `onigSearch` is
encoding-agnostic (subject is just a `Uint8List` + the `Regex` carries its encoding). So we can mirror
Irregexp's one-byte/two-byte specialization exactly:

- **One-byte strings** (all code units ≤ 0xFF — every ASCII string, most Western text): Dart's
  internal `OneByteString` *is* Latin-1. Compile the pattern with **`iso8859_1`** and match directly
  on the code units as bytes. **Byte offset == code-unit index (identity).** No map, no hashmap.
- **Two-byte strings** (any code unit > 0xFF): compile with **`utf16`**, match on the UTF-16 bytes.
  **Offset conversion collapses to `byte >> 1`** — O(1), no map.
- Keep the current **UTF-8** engine for the byte API and callers who want UTF-8 semantics; for that
  path, replace the `Map` + O(n) fallback with a **monotonic forward cursor** (matches arrive in
  increasing byte order, so byte→char is O(total) with no hashmap).

Open questions to settle in the implementation phase (not blockers):
- Compile up to 3 encoding variants of a pattern, lazily + cached (like Irregexp's per-encoding
  compile). Compile is microseconds; negligible.
- Verify Oniguruma semantics (`\w`, `\p`, case-fold, `.`/newline) are identical across the utf8 /
  latin1 / utf16 encodings for the same pattern — the oracle already exercises these encodings, so
  parity is checkable.
- `input.codeUnits` → `Uint8List` for the one-byte path still copies O(n) (a memcpy, ~3 ms), far
  cheaper than 106 ms of map building. A zero-copy view of the internal buffer isn't available in
  pure Dart; the copy is acceptable.

---

## Part E — Prioritized, severity-ranked backlog

**Severity** = performance impact when the relevant pattern/input is hit.
**Effort** = implementation size. **Parity risk** = chance of disturbing the byte-exact C oracle.
Ordered by recommended execution (P0 first).

### Group 1 — String API (largest, cheapest wins)

| ID | Item | Severity | Effort | Parity risk | Expected win |
|---|---|:--:|:--:|:--:|---|
| **S1** | **One-byte (Latin-1/ASCII) subject fast path** — match one-byte strings via `iso8859_1` on `input.codeUnits`; identity offsets; **delete the index maps** for this case | **Critical** | Low–Med | Low | ~**20–28×** on ASCII String-API (removes 94 % setup); brings `literal`/`case-insens` to ≈ RegExp |
| **S2** | **Kill `Map<int,int>` in the UTF-8 path** — monotonic forward byte→char cursor; remove the O(n) `charAt` fallback | High | Low | Low | Removes 84 % for non-Latin-1 UTF-8 String-API use |
| **S3** | **Two-byte (UTF-16) subject path** — match via `utf16`; offset = `byte>>1` | High | Med | Low | Generalizes S1 to CJK/emoji text without any map |
| **S4** | Don't rebuild per `allMatches`; cache encoded subject + per-encoding compiled `Regex`; typed `Int32List` if any dense array remains | Med | Low | Low | Repeated-scan & many-match workloads |
| **S5** | Lazy group materialization audit (match RegExp: only build substrings on `group()`) | Low | Low | Low | Micro; capture-heavy loops |

> S1 + S3 together = full Irregexp-style one-byte/two-byte subject specialization at the API layer,
> which is the *correct* long-term design and removes the hashmap entirely. S2 is the fallback for
> anyone who keeps a UTF-8 subject.

### Group 2 — Engine (byte-API / general throughput vs C and RegExp)

| ID | Item | Severity | Effort | Parity risk | Expected win |
|---|---|:--:|:--:|:--:|---|
| **E1** | **One-byte subject specialization in the executor** — a Latin-1/ASCII hot loop that indexes `str[s]` and tests `bitset[byte]` with no `enc.length`+`enc.mbcToCode` decode (mirrors Irregexp's one-byte program). Pairs with S1. | High | Med–High | Med | Big per-char cut on ASCII class/quant (`[a-z]+`, `\w+`) |
| **E2** | **Emit the specialized `.*`/anychar-star loop + peek/quick-check opcodes** that are declared-but-unused; add a `SkipUntilBitInTable`-style in-VM class skip | High | Med | Med | `.*`, `[class]*`, unanchored scans; fewer dispatches + backtrack pushes |
| **E3** | **Deterministic-quantifier no-backtrack** — for `X+`/`X*` where `X` is one non-overlapping class/char, don't push a backtrack frame per char (possessive-style) | Med | Med | Med | Removes per-char stack push in the commonest loops |
| **E4** | **First-byte map for `\w \d \s`** and negation/multibyte-aware classes (Irregexp derives start sets from classes) | Med | Low–Med | Low | `\d+…`, `\w+@`, etc. gain a start prefilter |
| **E5** | **Devirtualize the UTF-8 hot loop** — monomorphic decode / per-encoding executor specialization (template-like), inline the ASCII branch of `mbcToCode` | Med | Med | Low | Constant-factor across all UTF-8 matching |
| **E6** | **Boyer-Moore skip over a class / longer factor** at search start (extend beyond single exact literal, window like Irregexp's ≤8) | Low–Med | Med | Low | Class-led patterns without an exact literal |
| **E7** | Wide-encoding (UTF-16/32) prefilters — we currently bail entirely | Low | Med | Low | Only if we push UTF-16 as an engine subject (ties to S3) |
| **E8** | **Broaden linear-NFA coverage** (or lazy-DFA) beyond nested-repetition — an area where we already beat RegExp; extend to more flat patterns safely | Strategic | High | Med | Worst-case guarantees on more patterns; differentiator |

### Suggested sequencing

1. **S1** (critical, cheap, uses existing `iso8859_1`) — collapses the headline 28×.
2. **S2 + S3** — finish the String-API story for non-ASCII; no hashmap anywhere.
3. **E1 + E5** — one-byte executor + devirtualized UTF-8 loop (E1 amplifies S1: the String API
   would then feed Latin-1 bytes into a fast one-byte engine).
4. **E2 + E3 + E4** — reclaim the unused fast-path opcodes and per-char backtrack pushes.
5. **E6 / E7 / E8** — longer-horizon.

Every engine item (E-group) must be validated against the full oracle (5169 C-suite tests +
differential fuzz vs the C CLI, 0 divergences) before landing — the parity-risk column flags where
to be most careful (E1/E2/E3 touch the match core).

---

## Part F — What we already do BETTER than Dart RegExp (preserve)

- **Linear-time NFA** for nested-repetition patterns — Dart RegExp is exponential with the backtrack
  limit wired off (§A.7). This is a real, demonstrated advantage; don't regress it, and consider E8.
- **Oniguruma feature surface** — syntaxes, ~28 encodings, full Unicode property/fold DB, callouts,
  subexp calls, `\K`, conditionals — beyond what `dart:core` `RegExp` exposes.
- **Byte-exact C parity** — the whole point; the oracle guards it.

---

## Appendix — source references

**Dart VM (`dart-lang/sdk@3.12.2`)**
- Provenance / disabled features: `runtime/vm/regexp/README.md:3,5-14,29`
- Natives + int32 validation: `runtime/lib/regexp.cc:20-79,140-174`
- Interpreter-only proof: `runtime/vm/regexp/regexp.cc:104-106,178-187,399-408,492-551`
- Per-encoding × sticky bytecode slots: `runtime/vm/object.h:13026-13052`
- Interpreter loop / dispatch / char loads / one-two-byte split / backtrack:
  `runtime/vm/regexp/regexp-interpreter.cc:22-27,126-163,253-288,424,577-602,642-651,958-1009,1179-1205`
- Bytecodes: `runtime/vm/regexp/regexp-bytecodes.h`
- Compiler / prefilters / BM: `runtime/vm/regexp/regexp-compiler.cc:1435,2794-3130,3376-3434,3454`
- Flags / dispatch config: `runtime/vm/regexp/base.h:55-57,164-176`
- Dart layer: `dart-sdk/lib/_internal/vm/lib/regexp_patch.dart` (read locally)

**Port (`lib/`)**
- Optimizer: `lib/src/compile/optimize.dart:22,36-120,262-362`
- Search driver: `lib/src/exec/search.dart:22-89,109-223`
- Executor hot path: `lib/src/exec/executor.dart:100,138-139,256-366,633-637`
- Flat bytecode: `lib/src/compile/operation.dart:183-234`
- NFA: `lib/src/exec/nfa.dart:313-319,352-503`
- String API: `lib/src/api/string_api.dart:47-213`
- Breakdown harness: `benchmark/bench_stringapi_breakdown.dart`
```
