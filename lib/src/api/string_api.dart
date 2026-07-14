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

/// A compiled pattern with an ergonomic, `RegExp`-like surface.
class OnigRegex {
  final Regex _reg;

  /// The original pattern string.
  final String pattern;

  OnigRegex._(this._reg, this.pattern);

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
    final map = _Utf8Index(input);
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
    final map = _Utf8Index(input);
    final end = map.bytes.length;
    var bpos = map.byteAt(start);
    while (bpos <= end) {
      final region = OnigRegion();
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
  final OnigRegion _region;
  final _Utf8Index _map;
  final Map<String, List<int>> _names;

  OnigMatch._(this.input, this._region, this._map, this._names);

  /// Number of capture groups (excluding the whole match).
  int get groupCount => _region.numRegs - 1;

  /// Whole-match start (code-unit index).
  int get start => _map.charAt(_region.beg[0]);

  /// Whole-match end (code-unit index).
  int get end => _map.charAt(_region.end[0]);

  /// Group [i]'s substring (0 = whole match), or null if unset.
  String? group(int i) {
    if (i < 0 || i >= _region.numRegs) return null;
    final b = _region.beg[i];
    if (b < 0) return null;
    return input.substring(_map.charAt(b), _map.charAt(_region.end[i]));
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
  int startOf(int i) => (i < _region.numRegs && _region.beg[i] >= 0)
      ? _map.charAt(_region.beg[i])
      : -1;

  /// End code-unit index of group [i] (-1 if unset).
  int endOf(int i) => (i < _region.numRegs && _region.end[i] >= 0)
      ? _map.charAt(_region.end[i])
      : -1;

  @override
  String toString() => 'OnigMatch(${group(0)})';
}

/// Maps between UTF-8 byte offsets and UTF-16 code-unit indices for a string.
class _Utf8Index {
  final Uint8List bytes;
  // byte offset (at char boundaries + end) -> code-unit index
  final Map<int, int> _b2c = {};
  final List<int> _c2b; // code-unit index -> byte offset (dense)

  _Utf8Index._(this.bytes, this._c2b);

  factory _Utf8Index(String input) {
    final bytes = Uint8List.fromList(utf8.encode(input));
    final c2b = List<int>.filled(input.length + 1, 0);
    var bytePos = 0;
    var cu = 0;
    for (final rune in input.runes) {
      final runeBytes = _utf8Len(rune);
      final runeUnits = rune > 0xffff ? 2 : 1;
      for (var k = 0; k < runeUnits; k++) {
        c2b[cu + k] = bytePos; // both surrogate halves map to the rune start
      }
      bytePos += runeBytes;
      cu += runeUnits;
    }
    c2b[cu] = bytePos; // end
    final idx = _Utf8Index._(bytes, c2b);
    // build byte->char at boundaries
    var bp = 0, c = 0;
    for (final rune in input.runes) {
      idx._b2c[bp] = c;
      bp += _utf8Len(rune);
      c += rune > 0xffff ? 2 : 1;
    }
    idx._b2c[bp] = c;
    return idx;
  }

  int byteAt(int codeUnitIndex) => codeUnitIndex <= 0
      ? 0
      : (codeUnitIndex >= _c2b.length ? bytes.length : _c2b[codeUnitIndex]);

  int charAt(int byteOffset) {
    final v = _b2c[byteOffset];
    if (v != null) return v;
    // Not on a boundary (shouldn't happen for whole-char matches): find nearest.
    var best = 0;
    _b2c.forEach((b, c) {
      if (b <= byteOffset && b >= best) best = b;
    });
    return _b2c[best] ?? 0;
  }

  static int _utf8Len(int rune) {
    if (rune < 0x80) return 1;
    if (rune < 0x800) return 2;
    if (rune < 0x10000) return 3;
    return 4;
  }
}
