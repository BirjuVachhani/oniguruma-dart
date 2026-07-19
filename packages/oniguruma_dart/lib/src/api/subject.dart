/// The subject bytes fed to the UTF-8 engine, plus the mapping between engine
/// byte offsets and Dart `String` UTF-16 code-unit indices.
///
/// Shared by the idiomatic String API ([OnigRegex]) and the vscode-style
/// [OnigScanner]/[OnigString] layer, so their offset math can never drift.
///
/// Two implementations, chosen per input (mirrors how the VM's `RegExp`
/// specializes on one-byte vs two-byte strings):
///  * [AsciiSubject]: every code unit is `< 0x80`, so the code units *are* the
///    UTF-8 bytes and byte offset == code-unit index. No maps built; conversion
///    is the identity. This is the common case (all-ASCII source code).
///  * [Utf8Subject]: has non-ASCII code units; UTF-8 bytes + a lazy cursor.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Encode [input] to the bytes handed to the engine, returning the bytes and
/// whether the input was pure ASCII.
///
/// Fused ASCII detect + fill: builds the byte buffer while scanning, and falls
/// back to a full UTF-8 encode on the first code unit `>= 0x80`.
(Uint8List bytes, bool ascii) encodeSubjectBytes(String input) {
  final n = input.length;
  final b = Uint8List(n);
  var ascii = true;
  for (var i = 0; i < n; i++) {
    final cu = input.codeUnitAt(i);
    if (cu >= 0x80) {
      ascii = false;
      break;
    }
    b[i] = cu;
  }
  final Uint8List bytes = ascii ? b : utf8.encode(input);
  return (bytes, ascii);
}

/// Build the [Subject] for already-encoded [bytes] (see [encodeSubjectBytes]).
Subject makeSubject(Uint8List bytes, bool ascii) =>
    ascii ? AsciiSubject(bytes) : Utf8Subject(bytes);

/// Convenience: encode [input] and return a fresh [Subject] over it.
Subject subjectOf(String input) {
  final (bytes, ascii) = encodeSubjectBytes(input);
  return makeSubject(bytes, ascii);
}

/// Bytes fed to the engine plus a bidirectional byte↔code-unit offset map.
abstract class Subject {
  /// Bytes handed to the engine (`onigSearch`).
  Uint8List get bytes;

  /// Code-unit index → engine byte offset (for a search `start`).
  int byteAt(int codeUnitIndex);

  /// Engine byte offset → UTF-16 code-unit index (for a result offset).
  int charAt(int byteOffset);
}

/// All-ASCII: bytes == code units, offsets are the identity. Zero setup maps.
class AsciiSubject implements Subject {
  @override
  final Uint8List bytes;
  AsciiSubject(this.bytes);

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
/// array, and short scans that only touch the start of a large corpus pay only
/// for what they read.
class Utf8Subject implements Subject {
  @override
  final Uint8List bytes;
  int _cByte = 0; // cursor byte offset (a char head, or bytes.length)
  int _cChar = 0; // UTF-16 code-unit index at _cByte

  Utf8Subject(this.bytes);

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
