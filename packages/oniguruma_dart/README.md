# oniguruma_dart

A **pure-Dart** port of the [Oniguruma](https://github.com/kkos/oniguruma)
regular-expression engine (the rich, Ruby-flavoured regex dialect) with **no
FFI and no native code**. It runs anywhere Dart runs (VM, AOT, Flutter, and
**Web/WASM**), needs zero toolchain or build setup, and is verified byte-for-byte
against the reference C library.

You get Oniguruma's full feature set, named groups, look-around, atomic groups,
possessive quantifiers, conditionals, subroutine calls, `\K`, `\R`, `\X`,
callouts, `\p{Script}`, multi-character case folds, ~28 text encodings, and a
choice of regex dialects (Ruby, Perl, Java, Python, grep, POSIX, …), behind an
idiomatic `String` API that works just like `dart:core`'s `RegExp`.

Three API surfaces, all pure Dart:

- **`OnigRegex`**: the idiomatic `String` API (`firstMatch` / `allMatches` /
  `replace`), the default choice ([Usage](#usage)).
- **`OnigScanner`**: a `vscode-oniguruma`-shaped multi-pattern scanner for
  **TextMate-grammar / Shiki** tokenizers; the same surface the sibling FFI
  package [`oniguruma_native`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_native)
  exposes, so tokenizer code is swappable between them
  ([Scanner](#scanner-vscode-oniguruma--textmate-grammars)).
- **The low-level byte C API**: `onigNew` / `onigSearch` / `onigMatch` /
  `OnigRegion` / `OnigRegSet`, mirroring `oniguruma.h` with byte offsets
  ([byte API](#non-utf-8-text--the-low-level-byte-api)).

## Features

### Why this over the built-in `RegExp`?

Dart's built-in `RegExp` is an ECMAScript engine (V8's Irregexp). It's fast and
perfectly fine for everyday patterns, but its dialect is comparatively small.
`oniguruma_dart` gives you the far richer Oniguruma/Ruby dialect (the same one
Ruby, TextMate grammars, and many editors are written for) while keeping a
`RegExp`-like surface. Reach for it when you need:

- **Regex constructs ECMAScript doesn't have**: atomic groups, possessive
  quantifiers, conditionals, subroutine/recursion `\g<>`, `\K`, `\R`, `\X`,
  POSIX classes, inline modifiers, free-spacing mode, and more (see the table).
- **True Unicode case-insensitivity**: multi-character folds such as `ß` ↔ `ss`
  and `ﬁ` ↔ `fi`, which `RegExp` does not perform.
- **Unicode properties without a flag**: `\p{Han}`, `\p{L}`, `\p{Greek}` work by
  default; in `RegExp` they require `unicode: true`.
- **Non-UTF-8 / non-Unicode text**: match over Shift-JIS, EUC-JP/KR/TW, Big5,
  GB18030, the ISO-8859 family, KOI8, and ~28 encodings, directly on bytes.
- **A specific regex dialect**: run patterns written for Ruby, Perl, Java,
  Python, grep, Emacs, or POSIX BRE/ERE with those exact semantics.
- **Byte offsets**: C-identical byte positions, alongside the usual `String`
  (UTF-16) offsets.

### Supported patterns vs. `dart:core` `RegExp`

Both engines share the everyday syntax; the differences are where Oniguruma's
dialect pulls ahead. `✅` = supported, `⚠️` = supported with a caveat, `❌` = not
supported.

| Pattern / feature | `oniguruma_dart` | Dart `RegExp` |
|---|:--:|:--:|
| `*` `+` `?` `{n,m}` and lazy `*?` `+?` | ✅ | ✅ |
| Alternation `\|`, char classes, ranges, negation | ✅ | ✅ |
| Capturing `( )` and non-capturing `(?: )` groups | ✅ | ✅ |
| Named groups `(?<name>…)` and backref `\k<name>` | ✅ | ✅ |
| Numeric back-references `\1` | ✅ | ✅ |
| Look-ahead `(?=…)` `(?!…)` | ✅ | ✅ |
| Look-behind `(?<=…)` `(?<!…)` | ✅ | ✅ |
| Anchors `^` `$` `\b` `\B`, dot-all / multiline flags | ✅ | ✅ |
| Buffer anchors `\A` `\z` `\Z` `\G` | ✅ | ❌ |
| Unicode properties `\p{…}` `\P{…}` | ✅ (default) | ⚠️ needs `unicode: true` |
| Case-insensitive **multi-char folds** (`ß`↔`ss`) | ✅ | ❌ |
| Atomic groups `(?>…)` | ✅ | ❌ |
| Possessive quantifiers `a++` `a*+` `a?+` | ✅ | ❌ |
| Conditionals `(?(cond)yes\|no)` | ✅ | ❌ |
| Subroutine calls & recursion `\g<name>` `\g<0>` | ✅ | ❌ |
| Back-ref by name/number & nesting level `\k<n-1>` | ✅ | ❌ |
| Keep `\K`, line-break `\R`, grapheme cluster `\X` | ✅ | ❌ |
| POSIX classes `[[:alpha:]]` | ✅ | ❌ |
| Leading inline modifiers `(?i)` `(?x)` `(?m)` | ✅ | ❌ |
| Free-spacing / extended mode + comments `(?#…)` | ✅ | ❌ |
| Callouts (of contents `(?{…})` / of name `(*NAME)`) | ✅ | ❌ |
| Selectable syntax (Ruby / Perl / POSIX / grep / …) | ✅ | ❌ |
| Non-Unicode encodings (Shift-JIS, EUC, Big5, …) | ✅ (~28) | ❌ (UTF-16 only) |
| Byte-offset results | ✅ | ❌ |

## Installation

```console
dart pub add oniguruma_dart
```

For a Flutter app:

```console
flutter pub add oniguruma_dart
```

Then import it:

```dart
import 'package:oniguruma_dart/oniguruma_dart.dart';
```

No build hooks, native toolchain, or prebuilt binaries: it's pure Dart, so it
works out of the box on every target including Web/WASM.

## Usage

Use the idiomatic **`OnigRegex`** API. It works like `dart:core`'s `RegExp`,
with `String` in and `String` out (offsets are UTF-16 code-unit indices):

```dart
import 'package:oniguruma_dart/oniguruma_dart.dart';

void main() {
  final re = OnigRegex.compile(r'(?<user>\w+)@(?<host>[\w.]+)');

  final m = re.firstMatch('contact bob@acme.com today');
  print(m?.group(0));            // bob@acme.com
  print(m?.namedGroup('user'));  // bob
  print(m?.namedGroup('host'));  // acme.com
  print(m?.start);               // 8
}
```

### Find matches

```dart
final re = OnigRegex.compile(r'\d+');

re.hasMatch('abc 42');                       // true
re.stringMatch('abc 42');                    // "42"  (whole match, or null)
re.firstMatch('a1 b22')?.group(0);           // "1"

// All non-overlapping matches (lazy Iterable):
re.allMatches('a1 b22 c333')
  .map((m) => m.group(0))
  .toList();                                 // ["1", "22", "333"]
```

### Groups & offsets

`OnigMatch` mirrors `Match`: `group(i)` (0 = whole match), `namedGroup`,
`groupCount`, `start`/`end`, and per-group `startOf(i)`/`endOf(i)`.

```dart
final m = OnigRegex.compile(r'(\d{4})-(\d{2})-(\d{2})').firstMatch('2026-07-13')!;
m.groupCount;        // 3
m.group(1);          // "2026"
m.group(2);          // "07"
m.startOf(3);        // 8
m.endOf(3);          // 10
```

### Replace

`replaceAll`/`replaceFirst` take a callback that receives the match:

```dart
OnigRegex.compile(r'\s+').replaceAll('a  b   c', (_) => '_');       // "a_b_c"

OnigRegex.compile(r'(\w+)@(\w+)')
  .replaceFirst('bob@acme', (m) => '${m.group(2)}/${m.group(1)}');  // "acme/bob"
```

### Options

Pass flags to `compile` (either the booleans or `OnigOption.*`):

```dart
OnigRegex.compile(r'hello', ignoreCase: true).hasMatch('HELLO');   // true
OnigRegex.compile(r'^b', multiLine: true).allMatches('a\nb\nc');   // 1 match
OnigRegex.compile(r'\d+  # a number', extended: true);             // free-spacing
```

### A different regex syntax

The default is the Oniguruma dialect. Choose another with `syntax:`:

```dart
// grep: \| is alternation.
OnigRegex.compile(r'cat\|dog', syntax: onigSyntaxGrep).stringMatch('a dog'); // "dog"

// POSIX Basic (BRE): + and ? are literal characters.
OnigRegex.compile(r'a+', syntax: onigSyntaxPosixBasic).hasMatch('aaa'); // false
OnigRegex.compile(r'a+', syntax: onigSyntaxPosixBasic).hasMatch('a+');  // true
```

Available: `onigSyntaxOniguruma` (default), `onigSyntaxRuby`, `onigSyntaxPerl`,
`onigSyntaxPerlNg`, `onigSyntaxJava`, `onigSyntaxPython`, `onigSyntaxGrep`,
`onigSyntaxEmacs`, `onigSyntaxPosixBasic`, `onigSyntaxPosixExtended`,
`onigSyntaxGnuRegex`.

### Unicode

```dart
OnigRegex.compile(r'\p{Han}+').stringMatch('東京タワー');           // "東京"
OnigRegex.compile(r'\X').allMatches('a👨‍👩‍👧e').length;               // grapheme clusters
OnigRegex.compile(r'(?i)straße').hasMatch('STRASSE');             // true (ß ↔ ss)
```

### Scanner (vscode-oniguruma / TextMate grammars)

For syntax highlighting you drive a **multi-pattern scanner**, not a single
regex. `OnigScanner` mirrors the `vscode-oniguruma` API (also exposed by
`oniguruma_native`, so tokenizer code is swappable): compile many patterns, then
ask for the winning match from a position. Offsets are UTF-16 code units.

```dart
final scanner = OnigScanner([r'\d+', r'[a-z]+', r'\s+']);
final line = OnigString('ab 12');

final m = scanner.findNextMatch(line, 0)!;
m.index;                       // 1  → the [a-z]+ pattern won
m.captureIndices.first.start;  // 0
m.captureIndices.first.end;    // 2  ("ab")
```

## Advanced features

Everything below is standard Oniguruma syntax: the rich constructs that make
the dialect worth reaching for, none of which Dart's built-in `RegExp` can
express. Every snippet runs as-is against the `OnigRegex` API shown above.

### Possessive quantifiers & atomic groups

`a++`, `a*+`, `a?+` and `(?>…)` match without ever giving anything back, so they
never backtrack. That is the fast, ReDoS-resistant way to say "take it all or
fail":

```dart
OnigRegex.compile(r'a+a').hasMatch('aaaa');     // true  (greedy a+ backtracks one 'a')
OnigRegex.compile(r'a++a').hasMatch('aaaa');    // false (possessive a++ keeps them all)
OnigRegex.compile(r'(?>a+)a').hasMatch('aaaa'); // false (atomic group, same effect)
```

### Named & numbered back-references

Match text that has to repeat. `\k<name>` (or `\1`) must re-match exactly what
the group captured:

```dart
OnigRegex.compile(r'\b(?<word>\w+)\s+\k<word>\b').stringMatch('the the end'); // "the the"
OnigRegex.compile(r'(\w+)=\1').stringMatch('x foo=foo');                      // "foo=foo"
```

### Subroutine calls & recursion

`\g<name>` / `\g<1>` re-run a group's *sub-pattern* (unlike a back-reference,
which re-matches its captured *text*); `\g<0>` recurses the whole pattern, so
you can match nested, balanced structures a classic regex cannot:

```dart
// Reuse a sub-pattern by name:
OnigRegex.compile(r'(?<n>\d+)-\g<n>-\g<n>').stringMatch('12-345-6'); // "12-345-6"

// Recurse the whole pattern for balanced parentheses:
OnigRegex.compile(r'\((?:[^()]|\g<0>)*\)').stringMatch('a(b(c)d)e'); // "(b(c)d)"
```

### Conditionals

`(?(id)yes|no)` chooses a branch depending on whether an earlier group matched:

```dart
// "if group 1 matched, require b, otherwise require c":
final re = OnigRegex.compile(r'^(a)?(?(1)b|c)$');
re.hasMatch('ab'); // true
re.hasMatch('c');  // true
re.hasMatch('ac'); // false
```

### Look-around, including variable-length look-behind

Full look-ahead and look-behind, and unlike many engines the look-behind may
be variable-length:

```dart
OnigRegex.compile(r'\d+(?= ?px)').stringMatch('12px');         // "12"
OnigRegex.compile(r'(?<=\w{2,4}@)\w+').stringMatch('bob@host'); // "host"
```

### `\K`, `\R`, `\X`

Keep-out, any line break, and whole grapheme clusters:

```dart
OnigRegex.compile(r'foo\Kbar').stringMatch('foobar');   // "bar" (\K drops "foo" from the match)
OnigRegex.compile(r'a\Rb').hasMatch('a\r\nb');          // true  (\R = CRLF / LF / …)
OnigRegex.compile(r'\X').allMatches('a👨‍👩‍👧e').length;    // 3     (grapheme clusters)
```

### Character-class set operations & POSIX classes

Intersect classes with `&&`, and use POSIX class names:

```dart
OnigRegex.compile(r'[a-z&&[^aeiou]]+').stringMatch('xyzaei'); // "xyz" (consonants only)
OnigRegex.compile(r'[[:alpha:]]+').stringMatch('ab12');       // "ab"
```

### Unicode properties & multi-char case folds

`\p{…}` works with no flag, and case-insensitive matching performs true Unicode
folds that `RegExp` won't (`ß` ↔ `ss`):

```dart
OnigRegex.compile(r'\p{Han}+').stringMatch('東京タワー');        // "東京"
OnigRegex.compile(r'\p{Greek}+').stringMatch('αβγabc');        // "αβγ"
OnigRegex.compile(r'(?i)straße').hasMatch('STRASSE');          // true
```

### Inline modifiers, free-spacing & comments

Flip flags on inside the pattern, lay it out with whitespace, and annotate it:

```dart
OnigRegex.compile(r'(?i)hello').hasMatch('HELLO');              // true
OnigRegex.compile(r'(?x) \d{4}  # a year').stringMatch('2026'); // "2026"
OnigRegex.compile(r'ab(?#ignored)c').hasMatch('abc');           // true
```

## Examples

Ready-to-use patterns for common tasks, all against the `OnigRegex` API.

### Parse an email into named parts

```dart
final re = OnigRegex.compile(
    r'(?<local>[\w.+-]+)@(?<domain>[a-zA-Z\d-]+(?:\.[a-zA-Z\d-]+)+)');
final m = re.firstMatch('reach me at bob.smith+news@mail.example.co.uk')!;
m.namedGroup('local');  // "bob.smith+news"
m.namedGroup('domain'); // "mail.example.co.uk"
```

### Pull the fields out of an ISO date

```dart
final m = OnigRegex.compile(r'(?<y>\d{4})-(?<mo>\d{2})-(?<d>\d{2})')
    .firstMatch('build 2026-07-19 ok')!;
(m.namedGroup('y'), m.namedGroup('mo'), m.namedGroup('d')); // (2026, 07, 19)
```

### Match an HTML/XML element and its matching close tag

The closing tag has to reuse the opening tag's name, a back-reference:

```dart
final m = OnigRegex.compile(r'<(?<tag>\w+)>(?<body>.*?)</\k<tag>>')
    .firstMatch('<b>bold</b> and <i>x</i>')!;
m.namedGroup('tag');  // "b"
m.namedGroup('body'); // "bold"
```

### Extract a balanced `{…}` block (recursion)

```dart
OnigRegex.compile(r'\{(?:[^{}]|\g<0>)*\}').stringMatch('cfg = {a {b} c};'); // "{a {b} c}"
```

### Find every doubled word

```dart
OnigRegex.compile(r'\b(?<w>\w+)\s+\k<w>\b')
    .allMatches('this is is a a test')
    .map((m) => m.namedGroup('w'))
    .toList(); // [is, a]
```

### Collapse runs of whitespace

```dart
OnigRegex.compile(r'\s+').replaceAll('a  b\t\tc', (_) => ' '); // "a b c"
```

### Parse a semantic-version string

```dart
final m = OnigRegex.compile(r'(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)')
    .firstMatch('v1.24.3-rc')!;
'${m.namedGroup('major')}.${m.namedGroup('minor')}.${m.namedGroup('patch')}'; // "1.24.3"
```

## Non-UTF-8 text & the low-level byte API

For non-UTF-8 encodings, or when you need C-identical **byte offsets** and want
to avoid `String` allocation, use the low-level API. It mirrors the C library
(`onig_new` / `onig_search` / `OnigRegion`) and operates on `Uint8List`. Pick the
encoding by passing a different encoding constant to `onigNew`:

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:oniguruma_dart/oniguruma_dart.dart';

void main() {
  final pattern = Uint8List.fromList(utf8.encode(r'(\w+)@(\w+)'));
  final subject = Uint8List.fromList(utf8.encode('bob@acme'));

  // Swap utf8Encoding for eucJpEncoding, sjisEncoding, big5Encoding, … as needed.
  final reg = onigNew(pattern, pattern.length, utf8Encoding, onigSyntaxDefault,
      OnigOption.defaultOption);

  final region = OnigRegion();
  final r = onigSearch(reg, subject, subject.length, 0, subject.length, region);
  if (r >= 0) {
    for (var i = 0; i < region.numRegs; i++) {
      print('group $i: bytes [${region.beg[i]}, ${region.end[i]})');
    }
  }
}
```

Encodings include `utf8Encoding`, `utf16BeEncoding`, `utf16LeEncoding`,
`eucJpEncoding`, `sjisEncoding`, `big5Encoding`, `gb18030Encoding`, the
`iso88591Encoding`…`iso885916Encoding` family, `koi8REncoding`, `asciiEncoding`,
and more. A runnable version is in
[`example/`](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_dart/example/oniguruma_dart_example.dart).

## Correctness

`oniguruma_dart` is a 1:1 port validated against the reference C library:

- **5025 / 5025** of Oniguruma's own C test cases pass (all 8 suites).
- **113** curated differential cases + **thousands** of randomized fuzz cases run
  against the C CLI with **0 divergences**: byte-identical match offsets,
  captures, and error codes.

## Performance

Pure-Dart and AOT-compiled, `oniguruma_dart` is **competitive with (and on this
benchmark suite, on average faster than) the native C library**, and it beats
Dart's built-in `RegExp` on nearly every pattern:

- **String API** (what you get from `OnigRegex`): **0.73× the C library's time**
  on average (geometric mean over 13 patterns), i.e. faster than native C across
  the suite, beating C on 10 of 13 patterns and `dart:core`'s `RegExp` on
  **12 of 13**.
- The lower-level **byte API** is faster still: **0.58× C** on average.

It is even faster than the **native C library driven from Dart over FFI**: for
bulk find-all-matches the String API is **~2× faster** than the sibling
[`oniguruma_native`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_native) package (which pays a UTF-16LE scan and an
FFI crossing per match), winning on 12 of 13 patterns.

![Geometric-mean scan time per engine, normalized to Oniguruma C (shorter is faster; dashed line = C). The port's byte (0.58×) and String (0.73×) APIs sit left of the C baseline; Dart RegExp, the FFI paths, and the web WebAssembly path sit right of it.](https://raw.githubusercontent.com/BirjuVachhani/oniguruma-dart/main/packages/oniguruma_dart/benchmark/charts/geomean.png)

Throughput is workload-dependent, and a few pathological cases (heavy
back-references) remain slower than C, and than `oniguruma_native`. Full
methodology, per-pattern tables, the FFI head-to-head, and an interactive chart
are in [`benchmarks.md`](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_dart/benchmarks.md).

## `oniguruma_dart` (pure Dart) vs `oniguruma_native` (native)

This repo ships two ways to run Oniguruma from Dart. Reach for **this package**
(`oniguruma_dart`, pure Dart) when you want:

- **The lightest, fastest web build**: pure Dart, so no embedded WebAssembly
  module to download (the FFI package runs on web too, but ships a ~600 KB wasm
  blob and is ~3× slower here for bulk scanning).
- **Zero native setup**: no C toolchain, no build hooks, no prebuilt binaries to
  ship, no `flutter config --enable-native-assets`.
- **Bulk matching**: `firstMatch` / `allMatches` / `replace` over `String` or
  `Uint8List`; it's ~2× faster than the FFI package here and often faster than C
  itself.
- A **full idiomatic regex API**: named groups, captures, replace, and both
  `String` and byte offsets.
- The **same three surfaces on every platform**: the low-level C API
  (`onigNew` / `onigSearch` / `OnigRegion`), the idiomatic `OnigRegex` String
  API, **and** a `vscode-oniguruma`-shaped `OnigScanner` / `OnigString` /
  `OnigScannerMatch` for **TextMate grammars / Shiki** tokenizers, byte-identical
  to the C engine, with no wasm to host on web.

Reach for **[`oniguruma_native`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_native)** instead when you want the
**reference C engine itself**: for provenance (behaviour tracks Ruby / VS Code /
Shiki by construction), incremental per-token tokenization (one match per FFI
crossing, its sweet spot), or robustness on pathological backtracking. Both
packages ship the same `OnigScanner` surface and are byte-identical, so for
TextMate / Shiki either works. `oniguruma_native` is the drop-in when you're
porting code already written against the `vscode-oniguruma` npm package. It runs
on every platform too (WebAssembly on web), just with a heavier web bundle. See the
[comparison in the root README](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/README.md#which-package-should-i-use)
and [`benchmarks.md`](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_dart/benchmarks.md) for the head-to-head.

## Contributing

The unit tests (including the ported C suites) run with just:

```console
dart test
```

The **differential** and **fuzz** tests and the **benchmarks** compare against
the real C library, so they additionally need Oniguruma built locally (it is not
vendored in this repo):

```console
git clone --branch v6.9.10 https://github.com/kkos/oniguruma oniguruma-master
cd oniguruma-master && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
cd .. && dart run test/differential/run_diff.dart   # then: python3 benchmark/run_bench.py
```

## License

```
BSD 2-Clause License

Copyright (c) 2026 Birju Vachhani (oniguruma_dart, the Dart port)
Copyright (c) 2002-2021 K.Kosako (Oniguruma, the original C library)
All rights reserved.

oniguruma_dart is a source-code port of the Oniguruma regular-expression
library (https://github.com/kkos/oniguruma). As a derivative work it is
distributed under Oniguruma's original BSD 2-Clause license, reproduced below,
and retains the original copyright notice as that license requires.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.
```
