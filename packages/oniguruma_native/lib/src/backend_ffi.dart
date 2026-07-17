/// Native (dart:ffi) backend — selected on IO platforms. Wraps the Oniguruma C
/// library compiled by hook/build.dart. Strings are handled as UTF-16LE so
/// match offsets line up 1:1 with Dart `String` indices.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart' as onig;
import 'types.dart';

/// No-op on IO: the native engine needs no loading. This mirrors the web
/// backend's [loadWasm] so cross-platform startup code can `await loadWasm()`
/// unconditionally; [bytes]/[url] are ignored here.
Future<void> loadWasm({Uint8List? bytes, String? url}) async {}

/// The linked Oniguruma version (e.g. `6.9.10`).
String onigVersion() => onig.shimVersion().cast<Utf8>().toDartString();

/// An input string encoded once as UTF-16LE in native memory, reusable across
/// many [OnigScanner.findNextMatch] calls. Call [dispose] when done.
class OnigString {
  OnigString(this.text) {
    final units = text.codeUnits;
    length = units.length;
    byteLength = units.length * 2;
    final buf = malloc<Uint16>(units.isEmpty ? 1 : units.length);
    for (var i = 0; i < units.length; i++) {
      buf[i] = units[i];
    }
    ptr = buf.cast<Uint8>();
  }

  final String text;
  late final int length; // UTF-16 code units
  late final int byteLength;
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
        final units = patterns[i].codeUnits;
        final buf = malloc<Uint16>(units.isEmpty ? 1 : units.length);
        for (var j = 0; j < units.length; j++) {
          buf[j] = units[j];
        }
        final p = buf.cast<Uint8>();
        pats[i] = p;
        lens[i] = units.length * 2;
        tmp.add(p);
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
  OnigMatch? findNextMatch(OnigString string, int startPosition) {
    final idx = onig.shimFind(
      _sc,
      string.ptr,
      string.byteLength,
      startPosition * 2,
      _numRegs,
      _beg,
      _end,
      _cap,
    );
    if (idx < 0) return null;
    final n = _numRegs.value;
    final caps = List<OnigCapture>.generate(n, (g) {
      final b = _beg[g];
      final e = _end[g];
      return OnigCapture(b < 0 ? -1 : b >> 1, e < 0 ? -1 : e >> 1);
    });
    return OnigMatch(idx, caps);
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
