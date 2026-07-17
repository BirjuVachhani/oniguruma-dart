# oniguruma_dart

A **pure-Dart** port of the [Oniguruma](https://github.com/kkos/oniguruma)
regular-expression engine — the rich, Ruby-flavoured regex dialect — with **no
FFI and no native code**. It runs anywhere Dart runs (VM, AOT, Flutter, and
**Web/WASM**), needs zero toolchain or build setup, and is verified byte-for-byte
against the reference C library.

You get Oniguruma's full feature set — named groups, look-around, atomic groups,
possessive quantifiers, conditionals, subroutine calls, `\K`, `\R`, `\X`,
callouts, `\p{Script}`, multi-character case folds, ~28 text encodings, and a
choice of regex dialects (Ruby, Perl, Java, Python, grep, POSIX, …) — behind an
idiomatic `String` API that works just like `dart:core`'s `RegExp`.

## Features

### Why this over the built-in `RegExp`?

Dart's built-in `RegExp` is an ECMAScript engine (V8's Irregexp). It's fast and
perfectly fine for everyday patterns, but its dialect is comparatively small.
`oniguruma_dart` gives you the far richer Oniguruma/Ruby dialect — the same one
Ruby, TextMate grammars, and many editors are written for — while keeping a
`RegExp`-like surface. Reach for it when you need:

- **Regex constructs ECMAScript doesn't have** — atomic groups, possessive
  quantifiers, conditionals, subroutine/recursion `\g<>`, `\K`, `\R`, `\X`,
  POSIX classes, inline modifiers, free-spacing mode, and more (see the table).
- **True Unicode case-insensitivity** — multi-character folds such as `ß` ↔ `ss`
  and `ﬁ` ↔ `fi`, which `RegExp` does not perform.
- **Unicode properties without a flag** — `\p{Han}`, `\p{L}`, `\p{Greek}` work by
  default; in `RegExp` they require `unicode: true`.
- **Non-UTF-8 / non-Unicode text** — match over Shift-JIS, EUC-JP/KR/TW, Big5,
  GB18030, the ISO-8859 family, KOI8, and ~28 encodings, directly on bytes.
- **A specific regex dialect** — run patterns written for Ruby, Perl, Java,
  Python, grep, Emacs, or POSIX BRE/ERE with those exact semantics.
- **Byte offsets** — C-identical byte positions, alongside the usual `String`
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

No build hooks, native toolchain, or prebuilt binaries — it's pure Dart, so it
works out of the box on every target including Web/WASM.

## Usage

Use the idiomatic **`OnigRegex`** API — it works like `dart:core`'s `RegExp`,
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
  against the C CLI with **0 divergences** — byte-identical match offsets,
  captures, and error codes.

## Performance

Pure-Dart and AOT-compiled, `oniguruma_dart` is **competitive with — and on this
benchmark suite, on average faster than — the native C library**, and it beats
Dart's built-in `RegExp` on nearly every pattern:

- **String API** (what you get from `OnigRegex`): **0.73× the C library's time**
  on average (geometric mean over 13 patterns) — i.e. faster than native C across
  the suite — beating C on 10 of 13 patterns and `dart:core`'s `RegExp` on
  **12 of 13**.
- The lower-level **byte API** is faster still — **0.58× C** on average.

It is even faster than the **native C library driven from Dart over FFI**: for
bulk find-all-matches the String API is **~2× faster** than the sibling
[`oniguruma_native`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_native) package (which pays a UTF-16LE scan and an
FFI crossing per match), winning on 12 of 13 patterns.

![Geometric-mean scan time per engine, normalized to Oniguruma C (shorter is faster; dashed line = C). The port's byte (0.58×) and String (0.73×) APIs sit left of the C baseline; Dart RegExp, the FFI paths, and the web WebAssembly path sit right of it.](https://raw.githubusercontent.com/BirjuVachhani/oniguruma-dart/main/packages/oniguruma_dart/benchmark/charts/geomean.png)

Throughput is workload-dependent, and a few pathological cases (heavy
back-references) remain slower than C — and than `oniguruma_native`. Full
methodology, per-pattern tables, the FFI head-to-head, and an interactive chart
are in [`benchmarks.md`](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_dart/benchmarks.md).

## `oniguruma_dart` (pure Dart) vs `oniguruma_native` (native)

This repo ships two ways to run Oniguruma from Dart. Reach for **this package**
(`oniguruma_dart`, pure Dart) when you want:

- **The lightest, fastest web build** — pure Dart, so no embedded WebAssembly
  module to download (the FFI package runs on web too, but ships a ~600 KB wasm
  blob and is ~3× slower here for bulk scanning).
- **Zero native setup** — no C toolchain, no build hooks, no prebuilt binaries to
  ship, no `flutter config --enable-native-assets`.
- **Bulk matching** — `firstMatch` / `allMatches` / `replace` over `String` or
  `Uint8List`; it's ~2× faster than the FFI package here and often faster than C
  itself.
- A **full idiomatic regex API**: named groups, captures, replace, and both
  `String` and byte offsets.

Reach for **[`oniguruma_native`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_native)** instead when you need the real C
engine's exact behaviour — driving **TextMate grammars / Shiki** with
vscode-oniguruma-compatible `OnigScanner` semantics, incremental tokenization
(one match per call), or robustness on pathological backtracking. It runs on
every platform too (WebAssembly on web), just with a heavier web bundle. See the
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

BSD 2-Clause. This is a source port of Oniguruma and is distributed under
Oniguruma's original BSD 2-Clause license, retaining the original copyright
(© 2002–2021 K.Kosako). See [LICENSE](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_dart/LICENSE).
