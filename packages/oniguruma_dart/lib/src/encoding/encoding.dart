/// The encoding abstraction (`OnigEncodingType`, oniguruma.h:130) and shared
/// ASCII tables/helpers (`regenc.c`).
///
/// The engine works on raw bytes (`Uint8List`) with integer offsets. Each
/// encoding is a subclass; the single-byte encodings share [SingleByteEncoding]
/// helpers. UTF-8 is the common fast path and is kept as tight as possible.
library;

import 'dart:typed_data';

import '../onig_types.dart';

/// Result of folding one multi-byte char: the fold bytes were written into a
/// caller buffer; this returns how many bytes were written and the new input
/// position (past the consumed source char).
typedef CaseFoldResult = ({int foldLen, int newPos});

/// One entry produced by `get_case_fold_codes_by_str` (`OnigCaseFoldCodeItem`):
/// [byteLen] source bytes fold to any of the [codes] (each a code-point list
/// forming the replacement string).
class CaseFoldCodeItem {
  final int byteLen;
  final List<int> codes; // code points of the replacement
  const CaseFoldCodeItem(this.byteLen, this.codes);
}

/// Callback used by `apply_all_case_fold` (`OnigApplyAllCaseFoldFunc`): for a
/// base code [from], the list [to] gives an equivalent (possibly multi-char)
/// folded form.
typedef ApplyAllCaseFoldFunc = void Function(int from, List<int> to);

/// Base class for all encodings (mirrors `OnigEncodingType`).
abstract class OnigEncoding {
  const OnigEncoding();

  /// Encoding name, e.g. `"UTF-8"`.
  String get name;

  /// Maximum bytes per char (`max_enc_len`).
  int get maxLength;

  /// Minimum bytes per char (`min_enc_len`).
  int get minLength;

  /// True when every char is exactly one byte (fast paths rely on this).
  bool get isSingleByte => maxLength == 1;

  /// True when a byte `< 0x80` at a character head is a standalone ASCII char
  /// (length 1, code point == the byte). Holds for UTF-8 and every single-byte
  /// encoding (all ASCII supersets here); false for UTF-16/UTF-32 (an ASCII
  /// char spans >1 byte) and conservatively for the legacy CJK multibyte
  /// encodings. Lets the executor skip the virtual decode for ASCII bytes.
  bool get isAsciiFast => isSingleByte || (isUnicodeEncoding && minLength == 1);

  /// True for Unicode encodings (UTF-8/16/32): code points are Unicode, so
  /// `\w`/`\p{}` class ctypes use the shared Unicode property ranges. Legacy
  /// multibyte encodings (EUC-JP, SJIS, …) return false and classify via
  /// [isCodeCtype] + the encoding's own property tables (`add_ctype_to_cc`).
  bool get isUnicodeEncoding => false;

  /// `ONIGENC_MBC_ENC_LEN`: byte length of the char starting at [p] in [s].
  int length(Uint8List s, int p, int end);

  /// Fast length by first byte only (valid for UTF-8 & single-byte encodings).
  int lengthByFirstByte(int b);

  /// `ONIGENC_MBC_TO_CODE`: decode the char at [p] into a code point.
  int mbcToCode(Uint8List s, int p, int end);

  /// `ONIGENC_CODE_TO_MBCLEN`: bytes needed to encode [code] (or a negative
  /// error code).
  int codeToMbcLen(int code);

  /// `ONIGENC_CODE_TO_MBC`: encode [code] into [buf] at [p]; returns bytes
  /// written (or a negative error code).
  int codeToMbc(int code, Uint8List buf, int p);

  /// `ONIGENC_IS_MBC_NEWLINE`: is the char at [p] a newline?
  bool isMbcNewline(Uint8List s, int p, int end);

  /// `onigenc_get_left_adjust_char_head`: step back from [p] to the head byte
  /// of the char it lands in (not before [start]).
  int leftAdjustCharHead(Uint8List s, int start, int p);

  /// `ONIGENC_IS_CODE_CTYPE`: does [code] belong to character type [ctype]?
  bool isCodeCtype(int code, int ctype);

  /// `ONIGENC_MBC_CASE_FOLD`: fold the char at [pp] into [fold]; returns the
  /// number of fold bytes and the advanced input position.
  CaseFoldResult mbcCaseFold(
    int flag,
    Uint8List s,
    int pp,
    int end,
    Uint8List fold,
  );

  /// `apply_all_case_fold`: invoke [f] for every case-fold pair in this
  /// encoding (used to expand ignore-case character classes).
  void applyAllCaseFold(int flag, ApplyAllCaseFoldFunc f);

  /// `get_case_fold_codes_by_str`: fold variants of the string starting at [p].
  List<CaseFoldCodeItem> getCaseFoldCodesByStr(
    int flag,
    Uint8List s,
    int p,
    int end,
  );

  /// `is_mbc_head`: is byte at [p] the first byte of a char?
  bool isMbcHead(Uint8List s, int p, int end);

  /// `is_valid_mbc_string`: are the bytes `[p, end)` a well-formed sequence of
  /// characters in this encoding? Default walks by [length]; encodings with
  /// stricter rules (e.g. UTF-8 continuation bytes) override this.
  bool isValidMbcString(Uint8List s, int p, int end) {
    while (p < end) {
      final len = length(s, p, end);
      if (len < 1 || p + len > end) return false;
      p += len;
    }
    return true;
  }

  /// `property_name_to_ctype`: resolve a `\p{name}` to a ctype id, or throw.
  int propertyNameToCtype(String name) => throw UnsupportedError(
    '$name properties not supported by $name encoding',
  );

  /// Encoding-specific `\p{name}` ranges over this encoding's *own* code values
  /// (e.g. EUC-JP Hiragana/Katakana). Returns flat `[lo,hi,…]` pairs, or null
  /// when [name] isn't an encoding property. Unicode encodings always return
  /// null and let the shared Unicode property database resolve the name.
  List<int>? encodingPropertyRanges(String name) => null;

  /// Canonical case-fold representative of [code]: two code points match
  /// case-insensitively iff their reps are equal. Base impl folds ASCII A–Z to
  /// lower; encodings with richer folding (UTF-*) override.
  int caseFoldRep(int code) =>
      (code >= 0x41 && code <= 0x5a) ? code + 0x20 : code;
}

// ---------------------------------------------------------------------------
// Shared ASCII tables (regenc.c)
// ---------------------------------------------------------------------------

/// `OnigEncAsciiCtypeTable[256]`: per-byte ctype membership bit flags.
/// Bit `n` set ⇒ the byte belongs to `ONIGENC_CTYPE_n` (see [CType]).
final Uint16List asciiCtypeTable = Uint16List.fromList(const <int>[
  // 0x00-0x0f
  0x4008, 0x4008, 0x4008, 0x4008, 0x4008, 0x4008, 0x4008, 0x4008, //
  0x4008, 0x420c, 0x4209, 0x4208, 0x4208, 0x4208, 0x4008, 0x4008,
  // 0x10-0x1f
  0x4008, 0x4008, 0x4008, 0x4008, 0x4008, 0x4008, 0x4008, 0x4008, //
  0x4008, 0x4008, 0x4008, 0x4008, 0x4008, 0x4008, 0x4008, 0x4008,
  // 0x20-0x2f
  0x4284, 0x41a0, 0x41a0, 0x41a0, 0x41a0, 0x41a0, 0x41a0, 0x41a0, //
  0x41a0, 0x41a0, 0x41a0, 0x41a0, 0x41a0, 0x41a0, 0x41a0, 0x41a0,
  // 0x30-0x3f
  0x78b0, 0x78b0, 0x78b0, 0x78b0, 0x78b0, 0x78b0, 0x78b0, 0x78b0, //
  0x78b0, 0x78b0, 0x41a0, 0x41a0, 0x41a0, 0x41a0, 0x41a0, 0x41a0,
  // 0x40-0x4f
  0x41a0, 0x7ca2, 0x7ca2, 0x7ca2, 0x7ca2, 0x7ca2, 0x7ca2, 0x74a2, //
  0x74a2, 0x74a2, 0x74a2, 0x74a2, 0x74a2, 0x74a2, 0x74a2, 0x74a2,
  // 0x50-0x5f
  0x74a2, 0x74a2, 0x74a2, 0x74a2, 0x74a2, 0x74a2, 0x74a2, 0x74a2, //
  0x74a2, 0x74a2, 0x74a2, 0x41a0, 0x41a0, 0x41a0, 0x41a0, 0x51a0,
  // 0x60-0x6f
  0x41a0, 0x78e2, 0x78e2, 0x78e2, 0x78e2, 0x78e2, 0x78e2, 0x70e2, //
  0x70e2, 0x70e2, 0x70e2, 0x70e2, 0x70e2, 0x70e2, 0x70e2, 0x70e2,
  // 0x70-0x7f
  0x70e2, 0x70e2, 0x70e2, 0x70e2, 0x70e2, 0x70e2, 0x70e2, 0x70e2, //
  0x70e2, 0x70e2, 0x70e2, 0x41a0, 0x41a0, 0x41a0, 0x41a0, 0x4008,
  // 0x80-0xff : all zero
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]);

/// `OnigEncAsciiToLowerCaseTable`: identity except A–Z ⇒ a–z.
final Uint8List asciiToLowerTable = _buildToLower();

/// Upper-case counterpart (a–z ⇒ A–Z), used by some fold paths.
final Uint8List asciiToUpperTable = _buildToUpper();

Uint8List _buildToLower() {
  final t = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    t[i] = (i >= 0x41 && i <= 0x5a) ? i + 0x20 : i;
  }
  return t;
}

Uint8List _buildToUpper() {
  final t = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    t[i] = (i >= 0x61 && i <= 0x7a) ? i - 0x20 : i;
  }
  return t;
}

/// `ONIGENC_IS_ASCII_CODE_CTYPE`: ctype test for ASCII-range code points.
bool asciiIsCodeCtype(int code, int ctype) {
  if (code < 256) {
    return (asciiCtypeTable[code] & CType.bit(ctype)) != 0;
  }
  return false;
}
