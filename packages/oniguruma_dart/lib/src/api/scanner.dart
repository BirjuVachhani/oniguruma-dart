/// A `vscode-oniguruma`-shaped multi-pattern scanner layered over the byte
/// engine.
///
/// This is the same API surface `oniguruma_native` exposes (`OnigScanner`,
/// `OnigString`, `OnigScannerMatch`, `OnigCapture`), the interface a TextMate /
/// Shiki tokenizer drives, so the two packages are drop-in swappable. Offsets
/// are **UTF-16 code-unit** indices (like `vscode-oniguruma`); the byte↔UTF-16
/// mapping is the shared [Subject] used by the idiomatic String API.
library;

import 'dart:typed_data';

import '../encoding/utf8.dart';
import '../exec/search.dart';
import '../onig_errors.dart';
import '../onig_types.dart';
import '../regex.dart';
import '../region.dart';
import '../syntax.dart';
import 'subject.dart';

/// No-op on the pure-Dart engine: there is no WebAssembly module to load.
///
/// Mirrors `oniguruma_native`'s `loadWasm` so identical startup code
/// (`await loadWasm()`) compiles and runs against either package.
Future<void> loadWasm({Uint8List? bytes, String? url}) async {}

/// A capture group's `[start, end)` range, in UTF-16 code units. An unmatched
/// group reports `start == end == -1`.
class OnigCapture {
  const OnigCapture(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start;
}

/// The result of [OnigScanner.findNextMatch]: which pattern matched
/// ([index], into the constructor's pattern list) and the capture ranges
/// ([captureIndices], index 0 is the whole match).
class OnigScannerMatch {
  const OnigScannerMatch(this.index, this.captureIndices);
  final int index;
  final List<OnigCapture> captureIndices;
}

/// An input string encoded once (UTF-8 bytes + byte↔UTF-16 offset map), reusable
/// across many [OnigScanner.findNextMatch] calls over the same line.
///
/// [dispose] is a no-op (pure Dart, GC-managed); it exists so consumer code
/// written against `oniguruma_native` compiles unchanged.
class OnigString {
  OnigString(this.text) {
    final (bytes, ascii) = encodeSubjectBytes(text);
    _bytes = bytes;
    _subject = makeSubject(bytes, ascii);
  }

  final String text;
  late final Uint8List _bytes;
  late final Subject _subject;

  /// Length in UTF-16 code units.
  int get length => text.length;

  /// Length of the UTF-8 encoding in bytes.
  int get byteLength => _bytes.length;

  void dispose() {}
}

/// A compiled set of patterns searched together. Patterns Oniguruma can't
/// compile are skipped (they never match), mirroring `oniguruma_native`'s
/// forgiving scanner, so pattern index N always lines up with input index N.
class OnigScanner {
  OnigScanner(List<String> patterns)
    : _regexes = List<Regex?>.filled(patterns.length, null) {
    for (var i = 0; i < patterns.length; i++) {
      final pb = encodeSubjectBytes(patterns[i]).$1;
      try {
        _regexes[i] = onigNew(
          pb,
          pb.length,
          utf8Encoding,
          onigSyntaxOniguruma,
          OnigOption.captureGroup,
        );
      } on OnigException {
        _regexes[i] = null; // uncompilable → never matches (index preserved)
      }
    }
  }

  final List<Regex?> _regexes;

  // One region reused across every pattern search: onigSearch overwrites it each
  // call, so the winner's offsets are snapshotted the moment it becomes best.
  final OnigRegion _region = OnigRegion();

  /// The left-most match at or after [startPosition] (UTF-16 code units), or
  /// null if none. Ported 1:1 from the native shim's `onig_shim_find`: a match
  /// exactly at [startPosition] wins immediately; otherwise the left-most start
  /// wins, ties broken by the earliest pattern in the set.
  OnigScannerMatch? findNextMatch(OnigString string, int startPosition) {
    final subject = string._subject;
    final bytes = string._bytes;
    final end = bytes.length;
    final start = subject.byteAt(startPosition); // UTF-16 index → UTF-8 byte

    var bestIdx = -1;
    var bestStart = 0x7fffffff;
    List<int>? bestBeg; // winner's byte offsets, snapshotted
    List<int>? bestEnd;

    for (var i = 0; i < _regexes.length; i++) {
      final reg = _regexes[i];
      if (reg == null) continue;
      final r = onigSearch(reg, bytes, end, start, end, _region);
      if (r < 0) continue; // mismatch or error → skip (forgiving)
      final ms = _region.beg[0];
      if (ms == start || ms < bestStart) {
        bestIdx = i;
        bestStart = ms;
        final n = _region.numRegs;
        final nb = List<int>.filled(n, OnigRegion.notFound);
        final ne = List<int>.filled(n, OnigRegion.notFound);
        for (var g = 0; g < n; g++) {
          nb[g] = _region.beg[g];
          ne[g] = _region.end[g];
        }
        bestBeg = nb;
        bestEnd = ne;
        if (ms == start) break; // exact-start match wins immediately
      }
    }

    if (bestIdx < 0) return null;
    final beg = bestBeg!;
    final endReg = bestEnd!;
    final caps = List<OnigCapture>.generate(beg.length, (g) {
      final b = beg[g];
      // Oniguruma reports UTF-8 byte offsets; map back to UTF-16 indices.
      if (b < 0) return const OnigCapture(-1, -1);
      return OnigCapture(subject.charAt(b), subject.charAt(endReg[g]));
    });
    return OnigScannerMatch(bestIdx, caps);
  }

  /// Counts every non-overlapping match of these patterns across the whole of
  /// [string]. At each position the winning pattern is chosen exactly as
  /// [findNextMatch] chooses it, then the scan advances past the whole match
  /// (a zero-width match advances one whole UTF-8 character). Ported 1:1 from
  /// the native shim's `onig_shim_scan_count`.
  int scanCount(OnigString string) {
    final bytes = string._bytes;
    final end = bytes.length;
    var count = 0;
    var startByte = 0;
    while (startByte <= end) {
      var bestBeg = -1, bestEnd = -1, bestStart = 0x7fffffff;
      for (var i = 0; i < _regexes.length; i++) {
        final reg = _regexes[i];
        if (reg == null) continue;
        final r = onigSearch(reg, bytes, end, startByte, end, _region);
        if (r < 0) continue;
        final ms = _region.beg[0];
        if (ms == startByte) {
          bestBeg = ms;
          bestEnd = _region.end[0];
          break;
        }
        if (ms < bestStart) {
          bestStart = ms;
          bestBeg = ms;
          bestEnd = _region.end[0];
        }
      }
      if (bestBeg < 0) break;
      count++;
      var next = bestEnd;
      if (next == startByte) {
        // Zero-width match: advance one whole UTF-8 char (never split an mbc).
        next += startByte < bytes.length ? _utf8Len(bytes[startByte]) : 1;
      }
      startByte = next;
    }
    return count;
  }

  void dispose() {}

  static int _utf8Len(int b0) =>
      b0 < 0x80 ? 1 : (b0 < 0xe0 ? 2 : (b0 < 0xf0 ? 3 : 4));
}
