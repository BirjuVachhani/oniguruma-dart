/// UTF-32BE and UTF-32LE encodings (`utf32_be.c`, `utf32_le.c`).
///
/// Structural methods are faithful to the C source; the ctype and case-fold
/// methods delegate to the shared Unicode layer (`../unicode/unicode.dart`),
/// just like `utf8.dart`.
library;

import 'dart:typed_data';

import '../unicode/unicode.dart' as uni;
import 'encoding.dart';

bool _isAscii(int c) => c < 0x80;

/// UTF-32BE encoding singleton.
final Utf32BeEncoding utf32BeEncoding = Utf32BeEncoding._();

/// UTF-32LE encoding singleton.
final Utf32LeEncoding utf32LeEncoding = Utf32LeEncoding._();

class Utf32BeEncoding extends OnigEncoding {
  @override
  bool get isUnicodeEncoding => true;

  Utf32BeEncoding._();

  @override
  String get name => 'UTF-32BE';

  @override
  int get maxLength => 4;

  @override
  int get minLength => 4;

  @override
  bool get isSingleByte => false;

  @override
  int lengthByFirstByte(int b) => 4;

  @override
  int length(Uint8List s, int p, int end) => 4;

  @override
  int mbcToCode(Uint8List s, int p, int end) =>
      (((s[p] & 0x7f) * 256 + s[p + 1]) * 256 + s[p + 2]) * 256 + s[p + 3];

  @override
  int codeToMbcLen(int code) => 4;

  @override
  int codeToMbc(int code, Uint8List buf, int p) {
    buf[p++] = (code & 0xff000000) >> 24;
    buf[p++] = (code & 0xff0000) >> 16;
    buf[p++] = (code & 0xff00) >> 8;
    buf[p] = code & 0xff;
    return 4;
  }

  @override
  bool isMbcNewline(Uint8List s, int p, int end) {
    if (p + 3 < end) {
      if (s[p + 3] == 0x0a && s[p + 2] == 0 && s[p + 1] == 0 && s[p] == 0) {
        return true;
      }
    }
    return false;
  }

  @override
  int leftAdjustCharHead(Uint8List s, int start, int p) {
    if (p <= start) return p;
    final rem = (p - start) % 4;
    return p - rem;
  }

  @override
  bool isMbcHead(Uint8List s, int p, int end) => true; // enc_len is always 4.

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
    if (_isAscii(s[pp + 3]) && s[pp + 2] == 0 && s[pp + 1] == 0 && s[pp] == 0) {
      fold[0] = 0;
      fold[1] = 0;
      fold[2] = 0;
      fold[3] = asciiToLowerTable[s[pp + 3]];
      return (foldLen: 4, newPos: pp + 4);
    }
    final rep = uni.caseFoldRep(mbcToCode(s, pp, end));
    final n = codeToMbc(rep, fold, 0);
    return (foldLen: n, newPos: pp + 4);
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
    final folds = uni.unicodeFoldCodes(code);
    if (folds.isEmpty) return const [];
    return [CaseFoldCodeItem(4, folds)];
  }
}

class Utf32LeEncoding extends OnigEncoding {
  @override
  bool get isUnicodeEncoding => true;

  Utf32LeEncoding._();

  @override
  String get name => 'UTF-32LE';

  @override
  int get maxLength => 4;

  @override
  int get minLength => 4;

  @override
  bool get isSingleByte => false;

  @override
  int lengthByFirstByte(int b) => 4;

  @override
  int length(Uint8List s, int p, int end) => 4;

  @override
  int mbcToCode(Uint8List s, int p, int end) =>
      (((s[p + 3] & 0x7f) * 256 + s[p + 2]) * 256 + s[p + 1]) * 256 + s[p];

  @override
  int codeToMbcLen(int code) => 4;

  @override
  int codeToMbc(int code, Uint8List buf, int p) {
    buf[p++] = code & 0xff;
    buf[p++] = (code & 0xff00) >> 8;
    buf[p++] = (code & 0xff0000) >> 16;
    buf[p] = (code & 0xff000000) >> 24;
    return 4;
  }

  @override
  bool isMbcNewline(Uint8List s, int p, int end) {
    if (p + 3 < end) {
      if (s[p] == 0x0a && s[p + 1] == 0 && s[p + 2] == 0 && s[p + 3] == 0) {
        return true;
      }
    }
    return false;
  }

  @override
  int leftAdjustCharHead(Uint8List s, int start, int p) {
    if (p <= start) return p;
    final rem = (p - start) % 4;
    return p - rem;
  }

  @override
  bool isMbcHead(Uint8List s, int p, int end) => true; // enc_len is always 4.

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
    if (_isAscii(s[pp]) && s[pp + 1] == 0 && s[pp + 2] == 0 && s[pp + 3] == 0) {
      fold[0] = asciiToLowerTable[s[pp]];
      fold[1] = 0;
      fold[2] = 0;
      fold[3] = 0;
      return (foldLen: 4, newPos: pp + 4);
    }
    final rep = uni.caseFoldRep(mbcToCode(s, pp, end));
    final n = codeToMbc(rep, fold, 0);
    return (foldLen: n, newPos: pp + 4);
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
    final folds = uni.unicodeFoldCodes(code);
    if (folds.isEmpty) return const [];
    return [CaseFoldCodeItem(4, folds)];
  }
}
