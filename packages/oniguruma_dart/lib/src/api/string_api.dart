/// Idiomatic Dart `String`-based API layered over the byte engine.
///
/// The engine matches UTF-8 bytes and reports byte offsets; this layer encodes
/// the input once, runs the engine, and maps byte offsets back to UTF-16
/// code-unit indices so results behave like `dart:core` [RegExp]/[Match].
library;

import 'dart:convert';
import 'dart:typed_data';

import '../encoding/utf8.dart';
import '../onig_types.dart';
import '../region.dart';
import '../regex.dart';
import '../syntax.dart';
import '../exec/search.dart';
import 'subject.dart';

/// A compiled pattern with an ergonomic, `RegExp`-like surface.
class OnigRegex {
  final Regex _reg;

  /// The original pattern string.
  final String pattern;

  OnigRegex._(this._reg, this.pattern);

  // One-entry memo of the last input's encoding, keyed by String identity.
  // Repeated scans of the same String (the common case: firstMatch then
  // allMatches, replace, or a loop) then skip the O(n) encode — the analog of
  // the C/byte harness reading its byte buffer once and reusing it. Strings are
  // immutable, so caching the bytes is always safe; a fresh [Subject] (with a
  // fresh offset cursor) is built per call.
  String? _cacheInput;
  Uint8List? _cacheBytes;
  bool _cacheAscii = false;

  Subject _subjectFor(String input) {
    var bytes = _cacheBytes;
    if (!identical(input, _cacheInput) || bytes == null) {
      final (b, ascii) = encodeSubjectBytes(input);
      bytes = b;
      _cacheInput = input;
      _cacheBytes = bytes;
      _cacheAscii = ascii;
    }
    return makeSubject(bytes, _cacheAscii);
  }

  /// Compile [pattern] (UTF-8). [options] are `OnigOption.*` flags; [syntax]
  /// defaults to Oniguruma. Throws [OnigException] on a malformed pattern.
  factory OnigRegex.compile(
    String pattern, {
    int options = OnigOption.none,
    OnigSyntax syntax = onigSyntaxDefault,
    bool ignoreCase = false,
    bool multiLine = false,
    bool extended = false,
  }) {
    var opt = options;
    if (ignoreCase) opt |= OnigOption.ignoreCase;
    if (multiLine) opt |= OnigOption.multiLine;
    if (extended) opt |= OnigOption.extend;
    final pb = Uint8List.fromList(utf8.encode(pattern));
    final reg = onigNew(pb, pb.length, utf8Encoding, syntax, opt);
    return OnigRegex._(reg, pattern);
  }

  /// The first match at or after code-unit [start], or null.
  OnigMatch? firstMatch(String input, {int start = 0}) {
    final map = _subjectFor(input);
    final bstart = map.byteAt(start);
    final region = OnigRegion();
    final r = onigSearch(
      _reg,
      map.bytes,
      map.bytes.length,
      bstart,
      map.bytes.length,
      region,
    );
    if (r < 0) return null;
    return OnigMatch._(input, region, map, _reg.nameTable);
  }

  /// True if the pattern matches anywhere in [input].
  bool hasMatch(String input) => firstMatch(input) != null;

  /// The matched substring of the first match, or null.
  String? stringMatch(String input) => firstMatch(input)?.group(0);

  /// All non-overlapping matches in [input] (lazy).
  Iterable<OnigMatch> allMatches(String input, [int start = 0]) sync* {
    final map = _subjectFor(input);
    final end = map.bytes.length;
    var bpos = map.byteAt(start);
    // One region reused across the whole scan: onigSearch overwrites it each
    // call and OnigMatch snapshots the offsets it needs at construction, so no
    // per-match OnigRegion allocation (the dominant per-match cost for dense,
    // simple patterns — e.g. literal scans over a large corpus).
    final region = OnigRegion();
    while (bpos <= end) {
      final r = onigSearch(_reg, map.bytes, end, bpos, end, region);
      if (r < 0) break;
      yield OnigMatch._(input, region, map, _reg.nameTable);
      final nextByte = region.end[0];
      bpos = nextByte == bpos ? bpos + 1 : nextByte;
    }
  }

  /// Replace the first match using [replace] (receives the match).
  String replaceFirst(String input, String Function(OnigMatch) replace) {
    final m = firstMatch(input);
    if (m == null) return input;
    return input.substring(0, m.start) + replace(m) + input.substring(m.end);
  }

  /// Replace all non-overlapping matches using [replace].
  String replaceAll(String input, String Function(OnigMatch) replace) {
    final sb = StringBuffer();
    var last = 0;
    for (final m in allMatches(input)) {
      sb.write(input.substring(last, m.start));
      sb.write(replace(m));
      last = m.end;
    }
    sb.write(input.substring(last));
    return sb.toString();
  }
}

/// A single match result, with `Match`-like accessors (code-unit offsets).
class OnigMatch {
  final String input;

  /// Snapshotted engine byte offsets, interleaved `[beg0, end0, beg1, end1, …]`.
  /// Copied out of the [OnigRegion] at construction so the region can be reused
  /// across an `allMatches` scan without a per-match allocation (see below).
  final Int32List _regs;

  /// Register count (whole match + capture groups).
  final int numRegs;

  final Subject _map;
  final Map<String, List<int>> _names;

  OnigMatch._(this.input, OnigRegion region, this._map, this._names)
    : numRegs = region.numRegs,
      _regs = _snapshot(region);

  static Int32List _snapshot(OnigRegion r) {
    final n = r.numRegs;
    final a = Int32List(n << 1);
    for (var i = 0; i < n; i++) {
      a[i << 1] = r.beg[i];
      a[(i << 1) + 1] = r.end[i];
    }
    return a;
  }

  /// Number of capture groups (excluding the whole match).
  int get groupCount => numRegs - 1;

  /// Whole-match start (code-unit index).
  int get start => _map.charAt(_regs[0]);

  /// Whole-match end (code-unit index).
  int get end => _map.charAt(_regs[1]);

  /// Group [i]'s substring (0 = whole match), or null if unset.
  String? group(int i) {
    if (i < 0 || i >= numRegs) return null;
    final b = _regs[i << 1];
    if (b < 0) return null;
    return input.substring(_map.charAt(b), _map.charAt(_regs[(i << 1) + 1]));
  }

  /// Named group's substring, or null.
  String? namedGroup(String name) {
    final nums = _names[name];
    if (nums == null) return null;
    for (final n in nums) {
      final g = group(n);
      if (g != null) return g;
    }
    return null;
  }

  /// Start code-unit index of group [i] (-1 if unset).
  int startOf(int i) =>
      (i < numRegs && _regs[i << 1] >= 0) ? _map.charAt(_regs[i << 1]) : -1;

  /// End code-unit index of group [i] (-1 if unset).
  int endOf(int i) => (i < numRegs && _regs[(i << 1) + 1] >= 0)
      ? _map.charAt(_regs[(i << 1) + 1])
      : -1;

  @override
  String toString() => 'OnigMatch(${group(0)})';
}

// The byte↔UTF-16 `Subject` (ASCII fast path + lazy UTF-8 cursor) lives in
// `subject.dart`, shared with the vscode-style `OnigScanner`/`OnigString` layer.
