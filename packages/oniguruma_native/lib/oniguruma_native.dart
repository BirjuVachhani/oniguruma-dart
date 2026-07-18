/// Dart bindings to the Oniguruma regular-expression library.
///
/// Two layers, backed by the real Oniguruma C engine everywhere:
///
///  * **Layer 0 — the C API.** [onigNew], [onigSearch], [onigMatch],
///    [OnigRegion], [OnigRegSet] and friends, mirroring `oniguruma.h` with
///    byte offsets — the faithful binding. On every platform, over the same
///    flat-int C shim accessors: `dart:ffi` on IO, `dart:js_interop` on web.
///  * **Layer 1 — the vscode scanner.** [OnigScanner], [OnigString],
///    [OnigScannerMatch] — the `vscode-oniguruma`-shaped surface a TextMate /
///    Shiki tokenizer drives, with UTF-16 offsets. Works on every platform.
///
/// Backends:
///  * **IO** (mobile, desktop, server): compiled from source / bundled prebuilt
///    by the build hook and called via `dart:ffi`.
///  * **Web** (dart2js / dart2wasm): the same engine compiled to WebAssembly,
///    driven over `dart:js_interop`. Behaviour is byte-identical to native.
///
/// On web, WebAssembly instantiation is asynchronous, so call [loadWasm] once
/// (and `await` it) at startup before constructing an [OnigScanner] or
/// [OnigString]:
///
/// ```dart
/// await loadWasm(); // no-op on IO; loads the wasm module on web
///
/// final scanner = OnigScanner([r'\b\w+\b', r'\d+']);
/// final s = OnigString('foo 123');
/// final m = scanner.findNextMatch(s, 0);
/// s.dispose();
/// scanner.dispose();
/// ```
///
/// On web, `loadWasm()` resolves `web/oniguruma_native.wasm` (run
/// `dart run oniguruma_native:setup` to place it) and otherwise falls back to
/// the version-matched GitHub Release asset; pass `bytes`/`url` to supply your
/// own module. Scanner offsets are UTF-16 code units matching Dart `String`
/// indices on all platforms.
library;

export 'src/types.dart';
export 'src/lowlevel_common.dart' show OnigRegion, OnigException, RegSetLead;

// Default to the web backend (no dart:ffi); upgrade to the native FFI backend
// wherever dart:ffi is available. The scanner (Layer 1) is in the backend files;
// the low-level C API (Layer 0) is in the lowlevel files.
export 'src/backend_web.dart' if (dart.library.ffi) 'src/backend_ffi.dart';
export 'src/lowlevel_web.dart' if (dart.library.ffi) 'src/lowlevel_ffi.dart';
