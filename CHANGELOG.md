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
- Byte API (`onigNew`/`onigSearch`), idiomatic `String` API
  (`OnigRegex`/`OnigMatch`), and multi-pattern `OnigRegSet`.
- Verified byte-for-byte against the C library (differential + fuzz suites);
  benchmarked at ~1.1–1.9× of hand-tuned C on typical patterns.
- Known limitations documented in `benchmark/REPORT.md`.
