/// Native (dart:ffi) backend — selected on IO platforms. Wraps the Oniguruma C
/// library compiled by hook/build.dart. Oniguruma runs in UTF-8 (so `\xHH`
/// escapes in TextMate grammars behave as authored); match offsets are mapped
/// back to UTF-16 code-unit (Dart `String`) indices via a per-string offset map
/// (see utf8_offsets.dart), so the public API is unchanged.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart' as onig;
import 'types.dart';
import 'utf8_offsets.dart';

/// No-op on IO: the native engine needs no loading. This mirrors the web
/// backend's [loadWasm] so cross-platform startup code can `await loadWasm()`
/// unconditionally; [bytes]/[url] are ignored here.
Future<void> loadWasm({Uint8List? bytes, String? url}) async {}

/// The linked Oniguruma version (e.g. `6.9.10`).
String onigVersion() => onig.shimVersion().cast<Utf8>().toDartString();

/// An input string encoded once as UTF-8 in native memory (with the byte↔UTF-16
/// offset map it needs), reusable across many [OnigScanner.findNextMatch] calls.
/// Call [dispose] when done.
class OnigString {
  OnigString(this.text) : _enc = encodeWithMap(text) {
    length = _enc.u16Length;
    byteLength = _enc.byteLength;
    final buf = malloc<Uint8>(byteLength == 0 ? 1 : byteLength);
    final bytes = _enc.bytes;
    for (var i = 0; i < byteLength; i++) {
      buf[i] = bytes[i];
    }
    ptr = buf;
  }

  final String text;

  /// UTF-8 bytes + byte↔UTF-16 offset maps for this string.
  final Utf8Encoded _enc;

  late final int length; // UTF-16 code units
  late final int byteLength; // UTF-8 bytes
  late final Pointer<Uint8> ptr;

  void dispose() => malloc.free(ptr);
}

/// A compiled set of patterns. Patterns Oniguruma can't compile are skipped
/// (never match), mirroring the forgiving behavior of the pure-Dart scanner.
class OnigScanner {
  OnigScanner(List<String> patterns) {
    final n = patterns.length;
    final pats = malloc<Pointer<Uint8>>(n == 0 ? 1 : n);
    final lens = malloc<Int32>(n == 0 ? 1 : n);
    final tmp = <Pointer<Uint8>>[];
    try {
      for (var i = 0; i < n; i++) {
        final bytes = encodeWithMap(patterns[i]).bytes;
        final len = bytes.length;
        final buf = malloc<Uint8>(len == 0 ? 1 : len);
        for (var j = 0; j < len; j++) {
          buf[j] = bytes[j];
        }
        pats[i] = buf;
        lens[i] = len;
        tmp.add(buf);
      }
      _sc = onig.shimScannerNew(pats, lens, n);
      if (_sc == nullptr) {
        throw StateError('Failed to create Oniguruma scanner');
      }
    } finally {
      for (final p in tmp) {
        malloc.free(p);
      }
      malloc.free(pats);
      malloc.free(lens);
    }
  }

  late final Pointer<onig.ShimScanner> _sc;

  static const int _cap = 64; // max capture groups read back
  final Pointer<Int32> _numRegs = malloc<Int32>();
  final Pointer<Int32> _beg = malloc<Int32>(_cap);
  final Pointer<Int32> _end = malloc<Int32>(_cap);

  /// Finds the left-most match at or after [startPosition] (UTF-16 code units),
  /// or null if none. A match exactly at [startPosition] wins immediately.
  OnigScannerMatch? findNextMatch(OnigString string, int startPosition) {
    final enc = string._enc;
    final idx = onig.shimFind(
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
    final n = _numRegs.value;
    final caps = List<OnigCapture>.generate(n, (g) {
      // Oniguruma reports UTF-8 byte offsets; map back to UTF-16 indices.
      return OnigCapture(enc.byteToU16(_beg[g]), enc.byteToU16(_end[g]));
    });
    return OnigScannerMatch(idx, caps);
  }

  /// Counts every non-overlapping match of these patterns across the whole of
  /// [string] in a single native call (one FFI crossing, regardless of how many
  /// matches there are). At each position the winning pattern is chosen exactly
  /// as [findNextMatch] chooses it, then the scan advances past the whole match.
  ///
  /// This is the fast path when you only need *how many* matches there are (or
  /// to measure native scan throughput): it never allocates a Dart object per
  /// match. Use [findNextMatch] when you need the match offsets themselves.
  int scanCount(OnigString string) =>
      onig.shimScanCount(_sc, string.ptr, string.byteLength);

  void dispose() {
    onig.shimScannerFree(_sc);
    malloc.free(_numRegs);
    malloc.free(_beg);
    malloc.free(_end);
  }
}
