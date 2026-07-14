/// UTF-16BE and UTF-16LE encodings (`utf16_be.c`, `utf16_le.c`).
///
/// Surrogate-pair aware. Structural methods are faithful to the C source; the
/// ctype and case-fold methods delegate to the shared Unicode layer
/// (`../unicode/unicode.dart`), just like `utf8.dart`.
library;

import 'dart:typed_data';

import '../onig_errors.dart';
import '../unicode/unicode.dart' as uni;
import 'encoding.dart';

// UTF16_IS_SURROGATE_FIRST / SECOND (regenc.h).
bool _isSurrogateFirst(int c) => (c & 0xfc) == 0xd8;
bool _isSurrogateSecond(int c) => (c & 0xfc) == 0xdc;
bool _isAscii(int c) => c < 0x80;

// EncLen_UTF16[b]: 4 for a high-surrogate lead byte, otherwise 2.
int _encLen16(int b) => (b & 0xfc) == 0xd8 ? 4 : 2;

/// UTF-16BE encoding singleton.
final Utf16BeEncoding utf16BeEncoding = Utf16BeEncoding._();

/// UTF-16LE encoding singleton.
final Utf16LeEncoding utf16LeEncoding = Utf16LeEncoding._();

class Utf16BeEncoding extends OnigEncoding {
  @override
  bool get isUnicodeEncoding => true;

  Utf16BeEncoding._();

  @override
  String get name => 'UTF-16BE';

  @override
  int get maxLength => 4;

  @override
  int get minLength => 2;

  @override
  bool get isSingleByte => false;

  @override
  int lengthByFirstByte(int b) => _encLen16(b);

  @override
  int length(Uint8List s, int p, int end) => _encLen16(s[p]);

  @override
  int mbcToCode(Uint8List s, int p, int end) {
    if (_isSurrogateFirst(s[p])) {
      return ((((s[p] - 0xd8) << 2) + ((s[p + 1] & 0xc0) >> 6) + 1) << 16) +
          ((((s[p + 1] & 0x3f) << 2) + (s[p + 2] - 0xdc)) << 8) +
          s[p + 3];
    }
    return s[p] * 256 + s[p + 1];
  }

  @override
  int codeToMbcLen(int code) {
    if (code > 0xffff) {
      if (code > 0x10ffff) return OnigErr.invalidCodePointValue;
      return 4;
    }
    return 2;
  }

  @override
  int codeToMbc(int code, Uint8List buf, int p) {
    if (code > 0xffff) {
      final plane = (code >> 16) - 1;
      buf[p++] = (plane >> 2) + 0xd8;
      final high = (code & 0xff00) >> 8;
      buf[p++] = ((plane & 0x03) << 6) + (high >> 2);
      buf[p++] = (high & 0x03) + 0xdc;
      buf[p] = code & 0xff;
      return 4;
    }
    buf[p++] = (code & 0xff00) >> 8;
    buf[p] = code & 0xff;
    return 2;
  }

  @override
  bool isMbcNewline(Uint8List s, int p, int end) {
    if (p + 1 < end) {
      if (s[p + 1] == 0x0a && s[p] == 0x00) return true;
    }
    return false;
  }

  @override
  int leftAdjustCharHead(Uint8List s, int start, int p) {
    if (p <= start) return p;
    if ((p - start) % 2 == 1) p--;
    if (_isSurrogateSecond(s[p]) &&
        p > start + 1 &&
        _isSurrogateFirst(s[p - 2])) {
      p -= 2;
    }
    return p;
  }

  @override
  bool isMbcHead(Uint8List s, int p, int end) => true; // enc_len is 2 or 4.

  @override
  bool isCodeCtype(int code, int ctype) => uni.unicodeIsCodeCtype(code, ctype);

  @override
  int caseFoldRep(int code) => uni.caseFoldRep(code);

  @override
  CaseFoldResult mbcCaseFold(
    int flag,
    Uint8List s,
    int pp,
    int end,
    Uint8List fold,
  ) {
    if (_isAscii(s[pp + 1]) && s[pp] == 0) {
      fold[0] = 0;
      fold[1] = asciiToLowerTable[s[pp + 1]];
      return (foldLen: 2, newPos: pp + 2);
    }
    final len = _encLen16(s[pp]);
    final rep = uni.caseFoldRep(mbcToCode(s, pp, end));
    final n = codeToMbc(rep, fold, 0);
    return (foldLen: n, newPos: pp + len);
  }

  @override
  void applyAllCaseFold(int flag, ApplyAllCaseFoldFunc f) =>
      uni.unicodeApplyAllCaseFold(f);

  @override
  List<CaseFoldCodeItem> getCaseFoldCodesByStr(
    int flag,
    Uint8List s,
    int p,
    int end,
  ) {
    final code = mbcToCode(s, p, end);
    final len = _encLen16(s[p]);
    final folds = uni.unicodeFoldCodes(code);
    if (folds.isEmpty) return const [];
    return [CaseFoldCodeItem(len, folds)];
  }
}

class Utf16LeEncoding extends OnigEncoding {
  @override
  bool get isUnicodeEncoding => true;

  Utf16LeEncoding._();

  @override
  String get name => 'UTF-16LE';

  @override
  int get maxLength => 4;

  @override
  int get minLength => 2;

  @override
  bool get isSingleByte => false;

  @override
  int lengthByFirstByte(int b) => _encLen16(b);

  @override
  int length(Uint8List s, int p, int end) {
    // mbc_enc_len reads the high byte (p+1) in little-endian.
    final hi = (p + 1 < end) ? s[p + 1] : 0;
    return _encLen16(hi);
  }

  @override
  int mbcToCode(Uint8List s, int p, int end) {
    final c0 = s[p];
    final c1 = s[p + 1];
    if (_isSurrogateFirst(c1)) {
      return ((((c1 - 0xd8) << 2) + ((c0 & 0xc0) >> 6) + 1) << 16) +
          ((((c0 & 0x3f) << 2) + (s[p + 3] - 0xdc)) << 8) +
          s[p + 2];
    }
    return c1 * 256 + s[p];
  }

  @override
  int codeToMbcLen(int code) {
    if (code > 0xffff) {
      if (code > 0x10ffff) return OnigErr.invalidCodePointValue;
      return 4;
    }
    return 2;
  }

  @override
  int codeToMbc(int code, Uint8List buf, int p) {
    if (code > 0xffff) {
      final plane = (code >> 16) - 1;
      final high = (code & 0xff00) >> 8;
      buf[p++] = ((plane & 0x03) << 6) + (high >> 2);
      buf[p++] = (plane >> 2) + 0xd8;
      buf[p++] = code & 0xff;
      buf[p] = (high & 0x03) + 0xdc;
      return 4;
    }
    buf[p++] = code & 0xff;
    buf[p] = (code & 0xff00) >> 8;
    return 2;
  }

  @override
  bool isMbcNewline(Uint8List s, int p, int end) {
    if (p + 1 < end) {
      if (s[p] == 0x0a && s[p + 1] == 0x00) return true;
    }
    return false;
  }

  @override
  int leftAdjustCharHead(Uint8List s, int start, int p) {
    if (p <= start) return p;
    if ((p - start) % 2 != 0) p--;
    if (_isSurrogateSecond(s[p + 1]) &&
        p > start + 1 &&
        _isSurrogateFirst(s[p - 1])) {
      p -= 2;
    }
    return p;
  }

  @override
  bool isMbcHead(Uint8List s, int p, int end) => true; // enc_len is 2 or 4.

  @override
  bool isCodeCtype(int code, int ctype) => uni.unicodeIsCodeCtype(code, ctype);

  @override
  int caseFoldRep(int code) => uni.caseFoldRep(code);

  @override
  CaseFoldResult mbcCaseFold(
    int flag,
    Uint8List s,
    int pp,
    int end,
    Uint8List fold,
  ) {
    if (_isAscii(s[pp]) && s[pp + 1] == 0) {
      fold[0] = asciiToLowerTable[s[pp]];
      fold[1] = 0;
      return (foldLen: 2, newPos: pp + 2);
    }
    final len = length(s, pp, end);
    final rep = uni.caseFoldRep(mbcToCode(s, pp, end));
    final n = codeToMbc(rep, fold, 0);
    return (foldLen: n, newPos: pp + len);
  }

  @override
  void applyAllCaseFold(int flag, ApplyAllCaseFoldFunc f) =>
      uni.unicodeApplyAllCaseFold(f);

  @override
  List<CaseFoldCodeItem> getCaseFoldCodesByStr(
    int flag,
    Uint8List s,
    int p,
    int end,
  ) {
    final code = mbcToCode(s, p, end);
    final len = length(s, p, end);
    final folds = uni.unicodeFoldCodes(code);
    if (folds.isEmpty) return const [];
    return [CaseFoldCodeItem(len, folds)];
  }
}
