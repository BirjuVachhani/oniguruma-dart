/// Web backend: selected when `dart:ffi` is unavailable (browsers).
///
/// This drives a WebAssembly build of the **same** Oniguruma + shim the FFI
/// backend uses (`src/oniguruma_shim.c`, wasm32-wasi), so `OnigScanner`,
/// `OnigString`, and `OnigScannerMatch` behave byte-identically to native. The module
/// is instantiated by the JS host and driven over `dart:js_interop`; it works
/// under both dart2js and dart2wasm (see [wasm_bindings]).
///
/// Because `WebAssembly.instantiate` is asynchronous, and browsers refuse to
/// instantiate a module this size synchronously on the main thread, web code
/// must call [loadWasm] **once** before constructing an [OnigScanner] or
/// [OnigString]. After it completes, every call here is synchronous, exactly
/// like the FFI backend. On IO, [loadWasm] exists as a no-op so startup code is
/// portable across platforms.
library;

import 'dart:typed_data';

import 'release.dart';
import 'types.dart';
import 'utf8_offsets.dart';
import 'web/wasm_bindings.dart';

/// Loads the Oniguruma WebAssembly module. Call once, and `await` it, before
/// using [OnigScanner]/[OnigString] on web.
///
/// Resolution order:
/// 1. [bytes]: instantiate the module you supply directly.
/// 2. [url]: fetch and instantiate from that URL (used as-is; no fallback).
/// 3. Otherwise the **default**: fetch `oniguruma_native.wasm` from the app's
///    web root (where `dart run oniguruma_native:setup` writes it) and, if
///    that isn't present (setup was never run), fall back to the version-matched
///    module on the GitHub Release. So web works with zero setup, and running
///    `setup` upgrades you to a locally-hosted, cached, offline/CSP-friendly copy.
///
/// Idempotent; a second call returns immediately.
///
/// On IO platforms this is a no-op (the FFI backend needs no loading); the
/// symbol exists so cross-platform startup code can `await loadWasm()`
/// unconditionally.
Future<void> loadWasm({Uint8List? bytes, String? url}) async {
  if (OnigWasmModule.isLoaded) return;
  if (bytes != null) {
    await OnigWasmModule.load(bytes);
    return;
  }
  if (url != null) {
    await OnigWasmModule.loadFromUrl(url); // explicit URL: honour it, no fallback
    return;
  }
  // Default: the locally-hosted copy first, then the release-asset fallback.
  try {
    await OnigWasmModule.loadFromUrl(wasmAssetName);
  } catch (localErr) {
    final release = releaseWasmUrl();
    try {
      await OnigWasmModule.loadFromUrl(release);
    } catch (releaseErr) {
      throw StateError(
        "Could not load '$wasmAssetName'. Tried the local copy (run "
        '`dart run oniguruma_native:setup` to create it in web/) and the '
        "release fallback '$release'. Check your network/CSP, or pass "
        'loadWasm(bytes: ...) / loadWasm(url: ...) with your own module. '
        'Local error: $localErr; release error: $releaseErr',
      );
    }
  }
}

/// The linked Oniguruma version (e.g. `6.9.10`). Requires [loadWasm].
String onigVersion() {
  final m = OnigWasmModule.instance;
  return m.readCString(m.version());
}

/// An input string encoded once as UTF-8 in the wasm heap (with the byte↔UTF-16
/// offset map it needs), reusable across many [OnigScanner.findNextMatch] calls.
/// Call [dispose] when done.
class OnigString {
  OnigString(this.text) : _enc = encodeWithMap(text) {
    final m = OnigWasmModule.instance;
    length = _enc.u16Length;
    byteLength = _enc.byteLength;
    ptr = m.malloc(byteLength == 0 ? 1 : byteLength);
    m.writeBytes(ptr, _enc.bytes);
  }

  final String text;

  /// UTF-8 bytes + byte↔UTF-16 offset maps for this string.
  final Utf8Encoded _enc;

  late final int length; // UTF-16 code units
  late final int byteLength; // UTF-8 bytes
  late final int ptr; // offset into the wasm heap

  void dispose() => OnigWasmModule.instance.free(ptr);
}

/// A compiled set of patterns. Patterns Oniguruma can't compile are skipped
/// (never match), mirroring the FFI backend and the pure-Dart scanner.
class OnigScanner {
  OnigScanner(List<String> patterns)
    : _numRegs = OnigWasmModule.instance.malloc(4),
      _beg = OnigWasmModule.instance.malloc(_cap * 4),
      _end = OnigWasmModule.instance.malloc(_cap * 4) {
    final m = OnigWasmModule.instance;
    final n = patterns.length;
    final patsPtr = m.malloc((n == 0 ? 1 : n) * 4);
    final lensPtr = m.malloc((n == 0 ? 1 : n) * 4);
    final tmp = <int>[];
    try {
      for (var i = 0; i < n; i++) {
        final bytes = encodeWithMap(patterns[i]).bytes;
        final p = m.malloc(bytes.isEmpty ? 1 : bytes.length);
        m.writeBytes(p, bytes);
        m.writeUint32(patsPtr + i * 4, p);
        m.writeInt32(lensPtr + i * 4, bytes.length);
        tmp.add(p);
      }
      _sc = m.scannerNew(patsPtr, lensPtr, n);
      if (_sc == 0) {
        throw StateError('Failed to create Oniguruma scanner');
      }
    } finally {
      for (final p in tmp) {
        m.free(p);
      }
      m.free(patsPtr);
      m.free(lensPtr);
    }
  }

  late final int _sc; // ShimScanner* as a heap offset

  static const int _cap = 64; // max capture groups read back
  final int _numRegs;
  final int _beg;
  final int _end;

  /// Finds the left-most match at or after [startPosition] (UTF-16 code units),
  /// or null if none. A match exactly at [startPosition] wins immediately.
  OnigScannerMatch? findNextMatch(OnigString string, int startPosition) {
    final m = OnigWasmModule.instance;
    final enc = string._enc;
    final idx = m.find(
      _sc,
      string.ptr,
      string.byteLength,
      enc.u16ToByte(startPosition), // UTF-16 index -> UTF-8 byte offset
      _numRegs,
      _beg,
      _end,
      _cap,
    );
    if (idx < 0) return null;
    final n = m.readInt32(_numRegs);
    final beg = m.readInt32List(_beg, n);
    final end = m.readInt32List(_end, n);
    final caps = List<OnigCapture>.generate(n, (g) {
      // Oniguruma reports UTF-8 byte offsets; map back to UTF-16 indices.
      return OnigCapture(enc.byteToU16(beg[g]), enc.byteToU16(end[g]));
    });
    return OnigScannerMatch(idx, caps);
  }

  /// Counts every non-overlapping match across the whole of [string] in a
  /// single crossing into wasm. Semantics match the FFI backend's [scanCount].
  int scanCount(OnigString string) =>
      OnigWasmModule.instance.scanCount(_sc, string.ptr, string.byteLength);

  void dispose() {
    final m = OnigWasmModule.instance;
    m.scannerFree(_sc);
    m.free(_numRegs);
    m.free(_beg);
    m.free(_end);
  }
}
