## 1.0.0

Initial release — a 1:1 Dart port of the Oniguruma 6.9.10 regex engine.

- Full parse → compile → backtracking-VM pipeline (all ~90 opcodes).
- Quantifiers (greedy/lazy/possessive, counted `{n,m}`), alternation,
  character classes (ranges, POSIX, negation, set nesting, `\p{}`),
  groups (capturing/named/atomic/option), look-ahead, look-behind
  (fixed + variable length), conditionals, back-references, subexp calls
  `\g<>` with recursion, `\R \N \O \K \X \y`.
- Full Unicode (properties, case folding, grapheme clusters) generated from
  the C sources; Unicode-correct case-insensitive matching.
- ~28 encodings: UTF-8/16/32, EUC-JP/KR/TW, SJIS, Big5, GB18030,
  ISO-8859-1..16, CP1251, KOI8-R/U, ASCII.
- Three API layers: the low-level byte C API (`onigNew`/`onigSearch`/`onigMatch`/
  `OnigRegion`/`OnigRegSet`, plus `onigVersion` and `onig_number_of_captures` /
  name-lookup introspection), the idiomatic `String` API (`OnigRegex`/
  `OnigMatch`), and a `vscode-oniguruma`-shaped `OnigScanner` / `OnigString` /
  `OnigScannerMatch` for TextMate-grammar / Shiki tokenizers — the same scanner
  surface as `oniguruma_native`, so tokenizer code is swappable between them.
- Verified byte-for-byte against the C library (differential + fuzz suites).
- Fast: on a broad pattern mix the `String` API averages ~0.73× the time of the
  hand-tuned C library (i.e. faster than native C across the suite) and beats
  Dart's built-in `RegExp` on nearly every pattern. See `benchmarks.md`.
