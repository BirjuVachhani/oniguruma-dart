# Oniguruma for Dart

Dart implementations of the [Oniguruma](https://github.com/kkos/oniguruma)
regular-expression engine (the dialect used by Ruby), organized as a
[pub workspace](https://dart.dev/tools/pub/workspaces) monorepo.

## Packages

| Package | Description |
|---|---|
| [`oniguruma_dart`](packages/oniguruma_dart) | **Pure-Dart** port — no FFI, no native code. Runs everywhere Dart runs, including Web/WASM. Full Unicode, ~28 encodings, an idiomatic `String` API. |
| `oniguruma_ffi` *(planned)* | FFI bindings to the native Oniguruma C library. |

See each package's own `README.md` for installation and usage.

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
