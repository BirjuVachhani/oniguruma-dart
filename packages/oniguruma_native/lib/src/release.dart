/// Release coordinates for the web WebAssembly module.
///
/// On web the Oniguruma engine ships as a separate `oniguruma_native.wasm`
/// artifact rather than embedded in the package. The web runtime can't read
/// `pubspec.yaml`, so the version-matched GitHub Release URL that [loadWasm]
/// falls back to, and that `dart run oniguruma_native:setup` downloads, is
/// built from the [packageVersion] constant here.
///
/// `test/version_test.dart` asserts [packageVersion] equals `version:` in
/// `pubspec.yaml`, so the release tag can never drift out of sync.
library;

/// This package's version. **Must** match `version:` in `pubspec.yaml`
/// (enforced by `test/version_test.dart`).
const String packageVersion = '1.0.1+2';

/// The GitHub repository that hosts the released wasm assets.
const String _repoBaseUrl = 'https://github.com/BirjuVachhani/oniguruma-dart';

/// File name of the web WebAssembly module: both the release asset name and the
/// local copy `setup` writes into the app's `web/` directory. [loadWasm]'s
/// zero-argument default fetches this as a relative URL from the app's web root.
const String wasmAssetName = 'oniguruma_native.wasm';

/// The version-matched GitHub Release download URL for [wasmAssetName].
///
/// Tag scheme: plain semver, e.g. `1.2.0`, the same string as [packageVersion].
String releaseWasmUrl([String version = packageVersion]) =>
    '$_repoBaseUrl/releases/download/$version/$wasmAssetName';
