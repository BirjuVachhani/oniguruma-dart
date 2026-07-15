# Oniguruma for Dart

Dart implementations of the [Oniguruma](https://github.com/kkos/oniguruma)
regular-expression engine (the dialect used by Ruby), organized as a
[pub workspace](https://dart.dev/tools/pub/workspaces) monorepo.

## Packages

| Package | Description |
|---|---|
| [`oniguruma_dart`](packages/oniguruma_dart) | **Pure-Dart** port — no FFI, no native code. Runs everywhere Dart runs, including Web/WASM. Full Unicode, ~28 encodings, an idiomatic `String` API. |
| [`oniguruma_ffi`](packages/oniguruma_ffi) | **FFI bindings** to the native Oniguruma C library (built/bundled by a Dart build hook). vscode-oniguruma-compatible `OnigScanner` for TextMate/Shiki tokenizers. IO platforms only. |

See each package's own `README.md` for installation and usage.

## Which package should I use?

Both run Oniguruma from Dart; they make opposite trade-offs.

| If you need… | Use |
|---|---|
| Web / WASM, or zero native setup (no toolchain, no build hooks) | **`oniguruma_dart`** |
| Bulk matching — `allMatches` / `replace` over a whole input | **`oniguruma_dart`** (~2× faster here, see below) |
| A full idiomatic API: named groups, captures, replace, `String` **and** byte offsets | **`oniguruma_dart`** |
| Exact vscode-oniguruma `OnigScanner` semantics for **TextMate grammars / Shiki** | **`oniguruma_ffi`** |
| Incremental tokenization (one `findNextMatch` per token) on IO platforms | **`oniguruma_ffi`** |
| The mature C engine's robustness on pathological backtracking (heavy back-refs) | **`oniguruma_ffi`** |

**Rule of thumb:** default to **`oniguruma_dart`** — it's portable, needs no
toolchain, and is faster for bulk matching. Choose **`oniguruma_ffi`** when you
specifically need native-engine compatibility for TextMate/Shiki tokenizers on
IO platforms.

### Head-to-head (same corpora, same 13 patterns, identical match counts)

Geometric mean of "time to scan a corpus for every match", normalized to the
native C library (lower is faster):

| Engine | geomean vs C |
|---|--:|
| `oniguruma_dart` · byte API | **0.58×** |
| `oniguruma_dart` · String API | **0.73×** |
| `oniguruma_ffi` · bulk (`scanCount`, one FFI crossing) | 1.39× |
| `oniguruma_ffi` · per-match (`findNextMatch` API) | 1.49× |

For **bulk find-all-matches** the pure-Dart port is **~2× faster** than the FFI
package (it wins 12 of 13 patterns): the FFI package scans UTF-16LE (≈2× the
bytes of UTF-8 on ASCII) and crosses the FFI boundary once per match. The FFI
package wins where the native engine's maturity matters — e.g. `backref-dup`
(pathological backtracking), where it is ~3× faster than the port. This is a
*bulk* benchmark, though; `oniguruma_ffi` is built for tokenizer workloads (one
match per call). Full methodology, per-pattern tables, and an interactive chart:
[`packages/oniguruma_dart/benchmarks.md`](packages/oniguruma_dart/benchmarks.md)
and [`benchmark/index.html`](packages/oniguruma_dart/benchmark/index.html).

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
copyright (© 2002–2021 K.Kosako). See [LICENSE](LICENSE).
