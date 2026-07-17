/// Shared UTF-8 encoding + byte↔UTF-16 offset mapping for both backends.
///
/// Oniguruma runs in UTF-8 (so `\xHH` byte escapes in TextMate grammars — which
/// are authored against UTF-8 Oniguruma — behave correctly), but the public API
/// speaks Dart `String` indices, i.e. UTF-16 code units. This file bridges the
/// two: it encodes a string to UTF-8 once and, unless the string is pure ASCII,
/// builds the two maps needed to translate offsets in both directions.
///
/// The FFI and web backends share this so their encoding and offset maths can
/// never drift apart.
library;

import 'dart:typed_data';

/// A string encoded as UTF-8 plus the offset maps needed to convert between
/// UTF-8 byte offsets (what Oniguruma reports) and UTF-16 code-unit offsets
/// (what Dart `String` uses).
///
/// For pure-ASCII input the two coordinate systems are identical, so [ascii] is
/// true and no maps are allocated — the common case for source code, and the
/// reason the offset mapping is close to free there.
class Utf8Encoded {
  Utf8Encoded._(this.bytes, this.u16Length, this._byteToU16, this._u16ToByte)
    : ascii = false;
  Utf8Encoded._ascii(this.bytes, this.u16Length)
    : ascii = true,
      _byteToU16 = null,
      _u16ToByte = null;

  /// The UTF-8 bytes (WTF-8 for any unpaired surrogates, so the byte stream and
  /// the maps always agree).
  final Uint8List bytes;

  /// Length of the source string in UTF-16 code units (`String.length`).
  final int u16Length;

  /// Length of [bytes].
  int get byteLength => bytes.length;

  /// True when the string is pure ASCII — byte offset == UTF-16 index, so the
  /// maps are omitted and translation is the identity.
  final bool ascii;

  // byteToU16[b] = the UTF-16 index of the character that byte `b` belongs to
  // (length byteLength+1; the last entry is u16Length). Oniguruma only ever
  // reports character-start byte offsets, which map exactly.
  final Int32List? _byteToU16;
  // u16ToByte[u] = the UTF-8 byte offset where code unit `u` begins (length
  // u16Length+1; the last entry is byteLength). Both halves of a surrogate pair
  // map to the astral character's start byte.
  final Int32List? _u16ToByte;

  /// Converts a UTF-16 code-unit offset to a UTF-8 byte offset (for the start
  /// position passed into Oniguruma). Out-of-range positions are clamped to the
  /// string bounds — a tokenizer advancing past a zero-width match can ask for
  /// `length + 1`, which must behave as "at end" (no match), not throw.
  int u16ToByte(int u16) {
    if (u16 <= 0) return 0;
    if (u16 >= u16Length) return byteLength;
    return ascii ? u16 : _u16ToByte![u16];
  }

  /// Converts a UTF-8 byte offset reported by Oniguruma back to a UTF-16
  /// code-unit offset. Preserves the -1 sentinel for unmatched groups.
  int byteToU16(int b) => b < 0 ? -1 : (ascii ? b : _byteToU16![b]);
}

bool _isHigh(int c) => c >= 0xD800 && c <= 0xDBFF;
bool _isLow(int c) => c >= 0xDC00 && c <= 0xDFFF;

/// Encodes [text] to UTF-8 and, unless it is pure ASCII, builds the byte↔UTF-16
/// offset maps. Used for subject strings.
Utf8Encoded encodeWithMap(String text) {
  final n = text.length;

  // First pass: total UTF-8 byte length, and whether the string is pure ASCII.
  var byteLen = 0;
  var ascii = true;
  for (var i = 0; i < n; i++) {
    final c = text.codeUnitAt(i);
    if (c < 0x80) {
      byteLen += 1;
      continue;
    }
    ascii = false;
    if (c < 0x800) {
      byteLen += 2;
    } else if (_isHigh(c) && i + 1 < n && _isLow(text.codeUnitAt(i + 1))) {
      byteLen += 4;
      i++; // consume the low surrogate
    } else {
      byteLen += 3; // BMP char, or an unpaired surrogate as WTF-8
    }
  }

  if (ascii) {
    final bytes = Uint8List(n);
    for (var i = 0; i < n; i++) {
      bytes[i] = text.codeUnitAt(i);
    }
    return Utf8Encoded._ascii(bytes, n);
  }

  final bytes = Uint8List(byteLen);
  final byteToU16 = Int32List(byteLen + 1);
  final u16ToByte = Int32List(n + 1);
  var b = 0;
  var u = 0;
  while (u < n) {
    final c = text.codeUnitAt(u);
    final startByte = b;
    if (c < 0x80) {
      byteToU16[b] = u;
      bytes[b++] = c;
      u16ToByte[u] = startByte;
      u += 1;
    } else if (c < 0x800) {
      byteToU16[b] = u;
      bytes[b++] = 0xC0 | (c >> 6);
      byteToU16[b] = u;
      bytes[b++] = 0x80 | (c & 0x3F);
      u16ToByte[u] = startByte;
      u += 1;
    } else if (_isHigh(c) && u + 1 < n && _isLow(text.codeUnitAt(u + 1))) {
      final cp = 0x10000 + ((c - 0xD800) << 10) + (text.codeUnitAt(u + 1) - 0xDC00);
      byteToU16[b] = u;
      bytes[b++] = 0xF0 | (cp >> 18);
      byteToU16[b] = u;
      bytes[b++] = 0x80 | ((cp >> 12) & 0x3F);
      byteToU16[b] = u;
      bytes[b++] = 0x80 | ((cp >> 6) & 0x3F);
      byteToU16[b] = u;
      bytes[b++] = 0x80 | (cp & 0x3F);
      // Both surrogate halves map to the astral char's start byte.
      u16ToByte[u] = startByte;
      u16ToByte[u + 1] = startByte;
      u += 2;
    } else {
      // BMP char, or an unpaired surrogate encoded as 3-byte WTF-8.
      byteToU16[b] = u;
      bytes[b++] = 0xE0 | (c >> 12);
      byteToU16[b] = u;
      bytes[b++] = 0x80 | ((c >> 6) & 0x3F);
      byteToU16[b] = u;
      bytes[b++] = 0x80 | (c & 0x3F);
      u16ToByte[u] = startByte;
      u += 1;
    }
  }
  byteToU16[b] = u; // sentinel: byteToU16[byteLength] == u16Length
  u16ToByte[u] = b; // sentinel: u16ToByte[u16Length] == byteLength
  return Utf8Encoded._(bytes, n, byteToU16, u16ToByte);
}
