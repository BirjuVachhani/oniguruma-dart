/// Dart bindings to the Oniguruma regular-expression library.
///
/// Presents one API on every platform — [OnigScanner], [OnigString],
/// [OnigMatch] — backed by the real Oniguruma C engine everywhere:
///
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
/// await loadWasm(); // no-op on IO; loads the embedded module on web
///
/// final scanner = OnigScanner([r'\b\w+\b', r'\d+']);
/// final s = OnigString('foo 123');
/// final m = scanner.findNextMatch(s, 0);
/// s.dispose();
/// scanner.dispose();
/// ```
///
/// [isOnigurumaSupported] is `true` on every platform. The embedded wasm makes
/// web zero-setup; pass `bytes`/`url` to [loadWasm] to supply your own module
/// and trim the bundle. Offsets are UTF-16 code units matching Dart `String`
/// indices on all platforms.
library;

export 'src/types.dart';

// Default to the web backend (no dart:ffi); upgrade to the native FFI backend
// wherever dart:ffi is available.
export 'src/backend_web.dart' if (dart.library.ffi) 'src/backend_ffi.dart';
