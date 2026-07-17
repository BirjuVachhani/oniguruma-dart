# Oniguruma for Dart

Dart implementations of the [Oniguruma](https://github.com/kkos/oniguruma)
regular-expression engine (the dialect used by Ruby), organized as a
[pub workspace](https://dart.dev/tools/pub/workspaces) monorepo.

## Packages

| Package | Description |
|---|---|
| [`oniguruma_dart`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_dart) | **Pure-Dart** port — no FFI, no native code. Runs everywhere Dart runs, including Web/WASM. Full Unicode, ~28 encodings, an idiomatic `String` API. |
| [`oniguruma_native`](https://github.com/BirjuVachhani/oniguruma-dart/tree/main/packages/oniguruma_native) | Bindings to the native Oniguruma C library: **`dart:ffi`** on IO (built/bundled by a Dart build hook) and **WebAssembly** on web. vscode-oniguruma-compatible `OnigScanner` for TextMate/Shiki tokenizers. Runs everywhere. |

See each package's own `README.md` for installation and usage.

## Which package should I use?

Both run Oniguruma from Dart on **every platform** (`oniguruma_native` uses
`dart:ffi` on IO and WebAssembly on web); they make opposite trade-offs.

| If you need… | Use |
|---|---|
| Zero native setup (no toolchain/build hooks) or the smallest, fastest web bundle | **`oniguruma_dart`** |
| Bulk matching — `allMatches` / `replace` over a whole input | **`oniguruma_dart`** (~2× faster here, see below) |
| A full idiomatic API: named groups, captures, replace, `String` **and** byte offsets | **`oniguruma_dart`** |
| Exact vscode-oniguruma `OnigScanner` semantics for **TextMate grammars / Shiki** | **`oniguruma_native`** |
| Incremental tokenization (one `findNextMatch` per token) | **`oniguruma_native`** |
| The mature C engine's robustness on pathological backtracking (heavy back-refs) | **`oniguruma_native`** |

**Rule of thumb:** default to **`oniguruma_dart`** — it's portable, needs no
toolchain, is faster for bulk matching, and has the lightest web build. Choose
**`oniguruma_native`** when you specifically need native-engine compatibility for
TextMate/Shiki tokenizers. Both run on web; on web `oniguruma_native` carries an
embedded ~600 KB WebAssembly module, needs a one-time `await loadWasm()`, and is
~3× slower than the pure-Dart port for bulk scanning — so for web-only targets
`oniguruma_dart` is the lighter, faster pick.

### Head-to-head (same corpora, same 13 patterns, identical match counts)

Geometric mean of "time to scan a corpus for every match", normalized to the
native C library (lower is faster):

| Engine | geomean vs C |
|---|--:|
| `oniguruma_dart` · byte API | **0.58×** |
| `oniguruma_dart` · String API | **0.73×** |
| `oniguruma_native` · bulk (`scanCount`, one FFI crossing) | 1.39× |
| `oniguruma_native` · per-match (`findNextMatch` API) | 1.49× |
| `oniguruma_native` · web (WebAssembly, bulk) | 2.34× |

![Geometric-mean scan time per engine, normalized to Oniguruma C — the pure-Dart port's byte (0.58×) and String (0.73×) APIs are faster than native C, while driving the C library from Dart over FFI costs 1.39–1.49× and as WebAssembly on the web 2.34× (bulk)](https://raw.githubusercontent.com/BirjuVachhani/oniguruma-dart/main/packages/oniguruma_dart/benchmark/charts/geomean.png)

For **bulk find-all-matches** the pure-Dart port is **~2× faster** than the FFI
package (it wins 12 of 13 patterns): the FFI package scans UTF-16LE (≈2× the
bytes of UTF-8 on ASCII) and crosses the FFI boundary once per match. The FFI
package wins where the native engine's maturity matters — e.g. `backref-dup`
(pathological backtracking), where it is ~3× faster than the port. This is a
*bulk* benchmark, though; `oniguruma_native` is built for tokenizer workloads (one
match per call). Full methodology, per-pattern tables, and an interactive chart:
[`packages/oniguruma_dart/benchmarks.md`](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_dart/benchmarks.md)
and [`benchmark/index.html`](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/packages/oniguruma_dart/benchmark/index.html).

![Per-pattern comparison of the two packages: FFI per-match, FFI bulk, port byte, and port String — the pure-Dart port (blue/green) is shorter (faster) than native FFI (pink) on 12 of 13 patterns, the exception being backref-dup](https://raw.githubusercontent.com/BirjuVachhani/oniguruma-dart/main/packages/oniguruma_dart/benchmark/charts/ffi-vs-port.png)

> Measured on Apple M1 Pro, Dart 3.12.2 / Node 26.4.0 / Oniguruma 6.9.10; median
> of 5 trials, all engines back-to-back. Absolute times carry machine-load noise;
> the ratios are the stable signal.

## Development

This repository is a **pub workspace** (requires Dart 3.6+). A single
`dart pub get` at the root resolves every package together, sharing one
lockfile and one `.dart_tool/`:

```sh
dart pub get                          # resolve the whole workspace
dart analyze                          # analyze all packages
dart test packages/oniguruma_dart     # run one package's tests
```

## License

BSD 2-Clause. These packages are derivative works of Oniguruma and are
distributed under its original BSD 2-Clause license, retaining the original
copyright (© 2002–2021 K.Kosako). See [LICENSE](https://github.com/BirjuVachhani/oniguruma-dart/blob/main/LICENSE).
