# oniguruma_native

Dart bindings to the [Oniguruma](https://github.com/kkos/oniguruma)
regular-expression library — the engine TextMate grammars (and therefore
Shiki / VS Code syntax highlighting) are written for.

It exposes Oniguruma in **two layers**, backed by the **same real C engine
everywhere** — native `dart:ffi` on IO, the same engine compiled to WebAssembly
on web — so results are bit-for-bit identical to the C library the rest of the
tooling ecosystem uses:

- **Layer 0 — the C API.** `onigNew`, `onigSearch`, `onigMatch`, `OnigRegion`,
  `OnigRegSet` and friends, mirroring `oniguruma.h` with byte offsets. On every
  platform, over the same flat-int C shim accessors — `dart:ffi` on IO,
  `dart:js_interop` on web.
- **Layer 1 — the vscode scanner.** `OnigScanner`, `OnigString`,
  `OnigScannerMatch` — the `vscode-oniguruma`-shaped surface a TextMate / Shiki
  tokenizer drives, with UTF-16 offsets. Works on every platform.

The sibling pure-Dart [`oniguruma_dart`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_dart)
presents the **same two layers** (plus an idiomatic `String` API), so low-level
and scanner code is swappable between the FFI and pure-Dart packages.

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
source (which needs a C toolchain). On web the WebAssembly module is fetched at
runtime, with an optional one-line step to self-host it — see
[How the native build works](#how-the-native-build-works) and
[Web (WebAssembly)](#web-webassembly).

## Usage

Call `loadWasm()` once and `await` it before constructing a scanner. On web it
loads the WebAssembly module (instantiation is asynchronous — see
[Web (WebAssembly)](#web-webassembly)); on IO it is a **no-op**, so the same
startup code is portable across every platform:

```dart
import 'package:oniguruma_native/oniguruma_native.dart';

Future<void> main() async {
  await loadWasm(); // web: loads the wasm module; IO: returns immediately

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
are UTF-16 code units (matching Dart `String` indices). The engine runs Oniguruma
in **UTF-8** — the encoding TextMate/VS Code grammars are authored against, so
`\xHH` byte escapes match as intended — and maps the reported byte offsets back
to UTF-16 indices via a per-string offset map (skipped entirely for ASCII).

`OnigString` and `OnigScanner` hold native memory — call `dispose()` on each when
you're done. A runnable version of the above is in
[`example/`](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_native/example/oniguruma_native_example.dart).

### Low-level C API (Layer 0)

When you need the raw engine rather than a scanner, the `onig_*` surface mirrors
`oniguruma.h` (byte offsets, `Uint8List` subjects) on every platform — driven
through the same flat-int C shim accessors (`dart:ffi` on IO, `dart:js_interop`
on web). This is the same API `oniguruma_dart` exposes, so low-level code is
swappable between the two packages. On web, `await loadWasm()` first (as for the
scanner).

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:oniguruma_native/oniguruma_native.dart';

final pattern = Uint8List.fromList(utf8.encode(r'(\d+)-(\d+)'));
final reg = onigNew(pattern, pattern.length, utf8Encoding, onigSyntaxOniguruma, 0);

final subject = Uint8List.fromList(utf8.encode('id 12-345'));
final region = OnigRegion();
final pos = onigSearch(reg, subject, subject.length, 0, subject.length, region);
// pos == 3 (byte offset); region.beg/end hold the group byte offsets.

reg.dispose(); // frees native memory (onig_free)
```

## When to use this vs `oniguruma_dart` (pure Dart)

This repo ships two ways to run Oniguruma from Dart. Reach for **this package**
(`oniguruma_native`, the real C library over FFI) when you want:

- **A `vscode-oniguruma`-shaped API** — `OnigScanner` / `OnigString` /
  `findNextMatch(line, pos)` mirror the JS package Shiki and VS Code are built on,
  so a ported TextMate tokenizer drops straight in. (`oniguruma_dart` is *also*
  byte-identical to the C engine and *also* ships this scanner — the difference is
  provenance and the performance profile below, not correctness.)
- **Incremental tokenization** — one `OnigScanner.findNextMatch` per token over
  short lines (what a tokenizer does), rather than bulk find-all-matches.
- **The reference engine itself** — this *is* the C library, so behaviour tracks
  Ruby / VS Code / Shiki by construction; and it handles pathological patterns
  (heavy back-references, catastrophic backtracking) more robustly (e.g. ~3×
  faster than the pure-Dart port on `backref-dup`).

Reach for **[`oniguruma_dart`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_dart)** (pure Dart) instead when you
want **zero native setup** (no build hooks or prebuilt binaries), a **lighter web
story** (no separate ~600 KB WebAssembly module to fetch or host), or are doing
**bulk matching** — for scanning a whole input for every match, the pure-Dart
port is about **2× faster** than this package and works everywhere Dart runs.
Both packages run on web; on web `oniguruma_dart` is the lighter, faster choice.

Why pure Dart wins bulk scanning: this package's `findNextMatch` API costs one
**FFI crossing per match**, and each non-ASCII result is translated through a
byte→UTF-16 offset map. Those are the right trade-offs for a tokenizer scanning
short lines, not for enumerating hundreds of thousands of matches in one call.
(The benchmark numbers linked below were measured against the previous UTF-16LE
build; the switch to UTF-8 mainly affects ASCII byte counts and shifts the FFI
figures somewhat — the overall picture is unchanged.)

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
the same UTF-8 bytes the FFI backend passes natively — so results are
byte-identical to the native engine.

**Call `await loadWasm()` once** before constructing a scanner. Instantiation is
asynchronous (browsers won't instantiate a module this size synchronously on the
main thread), so this step is required on web; it is a no-op on IO.

### Web Setup

The WebAssembly module (~600 KB) is **not** bundled into your app — it ships as a
per-version asset on this package's GitHub Release. On web, `loadWasm()` loads a
local `web/oniguruma_native.wasm` if present and otherwise falls back to that
release asset, so it works with **zero setup**. For production, self-host it (one
command): that streaming-compiles the module, lets the browser cache the compiled
code, and works **offline and under a strict CSP** (no third-party fetch).

**Steps**

1. Add the dependency:

   ```console
   dart pub add oniguruma_native      # or: flutter pub add oniguruma_native
   ```

2. Download the module into your app's `web/` directory:

   ```console
   dart run oniguruma_native:setup
   ```

   This fetches the `oniguruma_native.wasm` matching your installed version,
   verifies it against the package's SHA-256 manifest, and writes
   `web/oniguruma_native.wasm`.

3. Commit `web/oniguruma_native.wasm` — or add it to `.gitignore` and run the
   command from step 2 in CI before building for web.

4. Load it once at startup, before constructing a scanner:

   ```dart
   await loadWasm(); // fetches web/oniguruma_native.wasm; a no-op on IO
   ```

**How `loadWasm()` resolves the module** (first match wins):

1. `loadWasm(bytes: ...)` / `loadWasm(url: ...)` — a module you supply explicitly.
2. `web/oniguruma_native.wasm` — the local copy from step 2 (the default; served
   from your app's web root).
3. The version-matched **GitHub Release** asset — the zero-setup fallback used
   when no local copy is found.

One file serves both the JS (dart2js) and WasmGC (dart2wasm) builds. To host the
module on your own CDN pass `loadWasm(url: ...)`; to supply raw bytes (e.g. a
Flutter asset via `rootBundle`) pass `loadWasm(bytes: ...)`.

Web is the portability option, not the speed option. The wasm build runs at
roughly **2.3× native C** for a bulk scan (the same engine is ~1.7× slower as
sandboxed wasm than as native machine code) and marshals across the JS boundary —
measured under Node/V8, the engine Chrome runs; see the
[web head-to-head in `benchmarks.md`](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_dart/benchmarks.md#web-oniguruma_native-webassembly-vs-the-pure-dart-port).
If you only target web and want the smallest, fastest option, prefer the
pure-Dart [`oniguruma_dart`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_dart)
(about **3× faster** here, with no wasm module to fetch).

## Status

Version 1.0.0. Native backend verified on macOS/arm64; the WebAssembly backend
verified in Chrome under both dart2js and dart2wasm (byte-identical offsets to
native). Prebuilt native binaries and the wasm module are regenerated by the
`refresh-prebuilts` workflow; the wasm is published to the GitHub Release (and
fetched by `dart run oniguruma_native:setup` / `loadWasm`) by `release-wasm`.

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
