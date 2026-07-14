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
    final map = _Subject(input);
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
    final map = _Subject(input);
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
  final _Subject _map;
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

/// The subject bytes fed to the UTF-8 engine, plus the mapping between engine
/// byte offsets and Dart `String` UTF-16 code-unit indices.
///
/// Two implementations, chosen per input (mirrors how the VM's `RegExp`
/// specializes on one-byte vs two-byte strings):
///  * [_AsciiSubject] — every code unit is `< 0x80`, so the code units *are* the
///    UTF-8 bytes and byte offset == code-unit index. No maps built; conversion
///    is the identity. This is the common case (all ASCII text).
///  * [_Utf8Subject] — has non-ASCII code units; encodes to UTF-8 once and builds
///    dense typed byte↔code-unit tables (no hashmap, O(1) lookup).
abstract class _Subject {
  /// Bytes handed to the engine (`onigSearch`).
  Uint8List get bytes;

  /// Code-unit index → engine byte offset (for a search `start`).
  int byteAt(int codeUnitIndex);

  /// Engine byte offset → UTF-16 code-unit index (for a result offset).
  int charAt(int byteOffset);

  /// Build the right subject for [input] in a single pass: if any code unit is
  /// `>= 0x80` fall back to the UTF-8 subject, else keep the ASCII fast path.
  factory _Subject(String input) {
    final n = input.length;
    final bytes = Uint8List(n);
    for (var i = 0; i < n; i++) {
      final cu = input.codeUnitAt(i);
      if (cu >= 0x80) return _Utf8Subject(input);
      bytes[i] = cu;
    }
    return _AsciiSubject(bytes);
  }
}

/// All-ASCII: bytes == code units, offsets are the identity. Zero setup maps.
class _AsciiSubject implements _Subject {
  @override
  final Uint8List bytes;
  _AsciiSubject(this.bytes);

  @override
  int byteAt(int c) => c < 0 ? 0 : (c > bytes.length ? bytes.length : c);

  @override
  int charAt(int b) => b;
}

/// Non-ASCII: UTF-8 subject with a lazy, bidirectional byte↔code-unit cursor.
///
/// The old dense `Int32List` tables cost an O(n) allocate-and-fill up front even
/// when few offsets are ever queried. Instead we keep only the encoded bytes and
/// a single memoised `(byte, codeUnit)` cursor: [charAt] walks the cursor to the
/// requested byte offset (forward or backward). Match/group offsets are queried
/// in mostly-increasing order, so the total walk is amortised O(n) with no big
/// array — and short scans that only touch the start of a large corpus pay only
/// for what they read.
class _Utf8Subject implements _Subject {
  @override
  final Uint8List bytes;
  int _cByte = 0; // cursor byte offset (a char head, or bytes.length)
  int _cChar = 0; // UTF-16 code-unit index at _cByte

  _Utf8Subject(String input)
      : bytes = Uint8List.fromList(utf8.encode(input));

  /// Byte length of the UTF-8 char whose lead byte is [b0]. A 4-byte sequence is
  /// one supplementary code point = **two** UTF-16 code units.
  static int _blen(int b0) =>
      b0 < 0x80 ? 1 : (b0 < 0xe0 ? 2 : (b0 < 0xf0 ? 3 : 4));

  void _forward() {
    final bl = _blen(bytes[_cByte]);
    _cByte += bl;
    _cChar += bl == 4 ? 2 : 1;
  }

  void _backward() {
    var p = _cByte - 1;
    while (p > 0 && (bytes[p] & 0xc0) == 0x80) {
      p--; // skip UTF-8 continuation bytes to the char head
    }
    _cByte = p;
    _cChar -= _blen(bytes[p]) == 4 ? 2 : 1;
  }

  @override
  int charAt(int byteOffset) {
    if (byteOffset <= 0) {
      _cByte = 0;
      _cChar = 0;
      return 0;
    }
    final n = bytes.length;
    final target = byteOffset >= n ? n : byteOffset;
    while (_cByte < target) {
      _forward();
    }
    while (_cByte > target) {
      _backward();
    }
    return _cChar;
  }

  @override
  int byteAt(int codeUnitIndex) {
    // Only used for a search `start` (usually 0); walk from the buffer head so
    // the [charAt] cursor is left undisturbed. A code unit inside a surrogate
    // pair resolves to its rune's start byte (matches the old dense mapping).
    if (codeUnitIndex <= 0) return 0;
    var byte = 0, chr = 0;
    final n = bytes.length;
    while (byte < n) {
      final bl = _blen(bytes[byte]);
      final cu = bl == 4 ? 2 : 1;
      if (chr + cu > codeUnitIndex) return byte;
      byte += bl;
      chr += cu;
    }
    return n;
  }
}
