# oniguruma_native

Dart bindings to the [Oniguruma](https://github.com/kkos/oniguruma)
regular-expression library — the engine TextMate grammars (and therefore
Shiki / VS Code syntax highlighting) are written for.

It presents **one API on every platform** (`OnigScanner`, `OnigString`,
`OnigMatch`), backed by the **same real Oniguruma C engine everywhere** — native
`dart:ffi` on IO, the same engine compiled to WebAssembly on web — so results are
bit-for-bit identical to the C library the rest of the tooling ecosystem uses.

| Platform | Engine |
|----------|--------|
| Android / iOS / macOS / Linux / Windows / server | Real Oniguruma C, compiled/bundled by a Dart **build hook** and called via `dart:ffi` |
| Web (dart2js / dart2wasm) | The same C engine compiled to **WebAssembly**, driven over `dart:js_interop` |

## Features

### Why this over the built-in `RegExp`?

Dart's built-in `RegExp` is an ECMAScript engine (V8's Irregexp). It can't host a
TextMate grammar: those grammars are written in the **Oniguruma dialect**, and
tokenizers drive them through a very specific multi-pattern *scanner* interface.
This package gives you exactly that. Reach for it when you need:

- **The real Oniguruma engine, bit-for-bit** — the same behaviour as Ruby,
  VS Code, and Shiki, so a TextMate grammar tokenizes identically to those tools.
- **vscode-oniguruma-compatible scanning** — an `OnigScanner` that compiles many
  patterns at once and returns the winning match from a position, the exact
  operation a syntax-highlighting tokenizer performs per token.
- **The full Oniguruma dialect** — atomic groups, possessive quantifiers,
  conditionals, subroutine/recursion `\g<>`, `\K`, `\R`, `\X`, POSIX classes,
  and more (see the table) — the constructs `RegExp` simply doesn't have.
- **Robustness on pathological patterns** — the mature C engine handles heavy
  back-references / catastrophic backtracking far better than a from-scratch
  backtracker.
- **One import, every platform** — a conditional import selects `dart:ffi` on IO
  and WebAssembly on web automatically; you write one `import` and never deal
  with platform specifics.

> If you want an idiomatic `firstMatch` / `allMatches` / `replace` API over
> `String` (rather than a scanner) and don't need native-engine parity, the
> sibling pure-Dart [`oniguruma_dart`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_dart)
> is usually the better fit — see [below](#when-to-use-this-vs-oniguruma_dart-pure-dart).

### Supported patterns vs. `dart:core` `RegExp`

Because this is the real Oniguruma engine, it accepts the full Oniguruma dialect
— the syntax TextMate grammars rely on and that ECMAScript's `RegExp` cannot
express. `✅` = supported, `⚠️` = supported with a caveat, `❌` = not supported.

| Pattern / feature | `oniguruma_native` | Dart `RegExp` |
|---|:--:|:--:|
| `*` `+` `?` `{n,m}`, lazy `*?`, alternation, char classes | ✅ | ✅ |
| Capturing / non-capturing / named groups, back-references | ✅ | ✅ |
| Look-ahead `(?=…)` `(?!…)` and look-behind `(?<=…)` `(?<!…)` | ✅ | ✅ |
| Buffer anchors `\A` `\z` `\Z` `\G` | ✅ | ❌ |
| Unicode properties `\p{…}` `\P{…}` | ✅ (default) | ⚠️ needs `unicode: true` |
| Case-insensitive **multi-char folds** (`ß`↔`ss`) | ✅ | ❌ |
| Atomic groups `(?>…)` and possessive quantifiers `a++` | ✅ | ❌ |
| Conditionals `(?(cond)yes\|no)` | ✅ | ❌ |
| Subroutine calls & recursion `\g<name>` `\g<0>` | ✅ | ❌ |
| Keep `\K`, line-break `\R`, grapheme cluster `\X` | ✅ | ❌ |
| POSIX classes `[[:alpha:]]` | ✅ | ❌ |
| Leading inline modifiers `(?i)` `(?x)`, comments `(?#…)` | ✅ | ❌ |

## Installation

```console
dart pub add oniguruma_native
```

For a Flutter app:

```console
flutter pub add oniguruma_native
flutter config --enable-native-assets   # required for the native (IO) build
```

Then import it:

```dart
import 'package:oniguruma_native/oniguruma_native.dart';
```

On IO the native library is provided by a Dart build hook: it bundles a
SHA-256-verified prebuilt for your target when one ships (macOS, iOS, Linux,
Android, Windows), otherwise it downloads and compiles the pinned Oniguruma
source (which needs a C toolchain). On web the WebAssembly module is embedded in
the package, so nothing needs to be hosted or fetched — see
[How the native build works](#how-the-native-build-works) and
[Web (WebAssembly)](#web-webassembly).

## Usage

Call `loadWasm()` once and `await` it before constructing a scanner. On web it
loads the embedded WebAssembly module (instantiation is asynchronous); on IO it
is a **no-op**, so the same startup code is portable across every platform:

```dart
import 'package:oniguruma_native/oniguruma_native.dart';

Future<void> main() async {
  await loadWasm(); // web: loads the embedded module; IO: returns immediately

  print('oniguruma ${onigVersion()}'); // e.g. "6.9.10"

  // A scanner compiles several patterns at once and, from a position, returns
  // the earliest/left-most match across all of them — what a tokenizer does.
  final scanner = OnigScanner([r'\d+', r'[a-z]+', r'\s+']);
  final input = OnigString('ab 12');

  var pos = 0;
  while (true) {
    final m = scanner.findNextMatch(input, pos);
    if (m == null) break;
    final span = m.captureIndices.first;   // whole match, in UTF-16 code units
    final text = input.text.substring(span.start, span.end);
    print('pattern #${m.index} matched "$text" at [${span.start}, ${span.end})');
    pos = span.end > pos ? span.end : pos + 1;
  }

  // scanCount runs the whole non-overlapping scan inside the engine in a single
  // crossing (one FFI call on IO / one JS→wasm call on web).
  print('total matches: ${scanner.scanCount(input)}');

  input.dispose();
  scanner.dispose();
}
```

After `loadWasm()` resolves, every call is synchronous on all platforms. Offsets
are UTF-16 code units (matching Dart `String` indices); the engine uses
Oniguruma's UTF-16LE encoding, so no offset remapping is needed.

`OnigString` and `OnigScanner` hold native memory — call `dispose()` on each when
you're done. A runnable version of the above is in
[`example/`](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_native/example/oniguruma_native_example.dart).

## When to use this vs `oniguruma_dart` (pure Dart)

This repo ships two ways to run Oniguruma from Dart. Reach for **this package**
(`oniguruma_native`, the real C library over FFI) when you want:

- **Exact native-engine behaviour** — driving **TextMate grammars / Shiki**
  syntax highlighting through vscode-oniguruma-compatible `OnigScanner`
  semantics, bit-for-bit with the C library other tooling uses.
- **Incremental tokenization** — one `OnigScanner.findNextMatch` per token over
  short lines (what a tokenizer does), rather than bulk find-all-matches.
- **Robustness on pathological patterns** — the mature C engine handles heavy
  back-references / catastrophic backtracking far better than a from-scratch
  backtracker (e.g. it is ~3× faster than the pure-Dart port on `backref-dup`).

Reach for **[`oniguruma_dart`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_dart)** (pure Dart) instead when you
want **zero native setup** (no build hooks or prebuilt binaries), a **smaller web
bundle** (this package embeds a ~600 KB WebAssembly module), or are doing **bulk
matching** — for scanning a whole input for every match, the pure-Dart port is
about **2× faster** than this package and works everywhere Dart runs. Both
packages run on web; on web `oniguruma_dart` is the lighter, faster choice.

Why pure Dart wins bulk scanning: this package uses **UTF-16LE** (so offsets map
1:1 to Dart `String` indices) — roughly 2× the bytes to scan on ASCII text — and
its `findNextMatch` API costs one **FFI crossing per match**. Those are the right
trade-offs for a tokenizer, not for enumerating hundreds of thousands of matches
in one call.

![Per-pattern, per-full-corpus-scan time (log scale, shorter is faster): this package's FFI per-match and bulk paths (pink) vs oniguruma_dart's byte and String APIs (blue/green). The pure-Dart port is faster on 12 of 13 patterns; this package wins backref-dup, where the native engine handles pathological backtracking far better.](https://raw.githubusercontent.com/BirjuVachhani/oniguruma-dart/main/packages/oniguruma_dart/benchmark/charts/ffi-vs-port.png)

See the full head-to-head in
[`../oniguruma_dart/benchmarks.md`](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_dart/benchmarks.md).

## How the native build works

`hook/build.dart` produces the `package:oniguruma_native/oniguruma_native` code asset in
one of two ways:

1. **Prebuilt (default).** If a library ships for the target under `prebuilt/`,
   it is bundled directly — no compiler and no network — after a SHA-256 check
   against `prebuilt/checksums.sha256` (a mismatch fails the build). Each blob is
   one dynamic library containing Oniguruma plus our shim
   (`src/oniguruma_shim.c`). Since Oniguruma is archived, they never change.
2. **Build from source (fallback).** For any target without a prebuilt — or
   when a consumer sets the `oniguruma.from_source` user-define — the hook
   downloads the pinned Oniguruma source release, verifies its SHA-256,
   extracts it, and compiles it with the shim via `package:native_toolchain_c`'s
   `CBuilder`. The C sources are **not** vendored in the package; they are
   fetched on demand. This path needs a C toolchain.

The shim runs the whole multi-pattern `findNextMatch` scan loop in C so there is
exactly one FFI crossing per query.

- Flutter apps must enable native assets: `flutter config --enable-native-assets`.
- Per-platform `config.h` variants for the source fallback live in `src/config/`.

## Web (WebAssembly)

On web the same Oniguruma + shim is compiled to a self-contained wasm32-wasi
module and driven over `dart:js_interop`; it works under both dart2js and
dart2wasm. There is no shared memory between Dart and the module, so subjects and
patterns are marshalled into its heap through the module's own `malloc`/`free` —
the same UTF-16LE bytes the FFI backend passes natively — so results are
byte-identical to the native engine.

- **Call `await loadWasm()` once** before constructing a scanner. Instantiation
  is asynchronous (browsers won't instantiate a module this size synchronously on
  the main thread), so this step is required on web; it is a no-op on IO.
- **Zero setup by default** — the wasm module is embedded in the package, so
  nothing needs to be hosted or fetched.
- **Bring your own module** to trim your bundle: `await loadWasm(bytes: ...)`
  (e.g. from a Flutter asset via `rootBundle`) or `await loadWasm(url: ...)`.

Web is the portability option, not the speed option. The wasm build runs at
roughly **2.3× native C** for a bulk scan (the same engine is ~1.7× slower as
sandboxed wasm than as native machine code), carries the embedded module
(~600 KB), and marshals across the JS boundary — measured under Node/V8, the
engine Chrome runs; see the
[web head-to-head in `benchmarks.md`](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_dart/benchmarks.md#web-oniguruma_native-webassembly-vs-the-pure-dart-port).
If you only target web and want the smallest, fastest option, prefer the
pure-Dart [`oniguruma_dart`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_dart)
(about **3× faster** here, with no wasm blob to download).

## Status

Version 1.0.0. Native backend verified on macOS/arm64; the WebAssembly backend
verified in Chrome under both dart2js and dart2wasm (byte-identical offsets to
native). Prebuilt native binaries and the wasm module are regenerated by the
`prebuild-oniguruma` workflow.

## License

BSD 2-Clause. This package links/bundles Oniguruma and is distributed under
Oniguruma's original BSD 2-Clause license, retaining the original copyright
(© 2002–2021 K.Kosako). See [LICENSE](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_native/LICENSE).
