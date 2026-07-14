/// Shared base for single-byte encodings (`regenc.c` `onigenc_single_byte_*`)
/// and the ASCII encoding (`ascii.c`).
library;

import 'dart:typed_data';

import 'encoding.dart';

/// Base class for encodings where every char is exactly one byte.
/// Subclasses supply [name] and the ctype/fold behaviour for bytes ≥ 0x80.
abstract class SingleByteEncoding extends OnigEncoding {
  const SingleByteEncoding();

  @override
  int get maxLength => 1;

  @override
  int get minLength => 1;

  @override
  bool get isSingleByte => true;

  @override
  int lengthByFirstByte(int b) => 1;

  @override
  int length(Uint8List s, int p, int end) => 1;

  @override
  int mbcToCode(Uint8List s, int p, int end) => s[p];

  @override
  int codeToMbcLen(int code) => 1;

  @override
  int codeToMbc(int code, Uint8List buf, int p) {
    buf[p] = code & 0xff;
    return 1;
  }

  @override
  bool isMbcNewline(Uint8List s, int p, int end) => p < end && s[p] == 0x0a;

  @override
  int leftAdjustCharHead(Uint8List s, int start, int p) => p;

  @override
  bool isMbcHead(Uint8List s, int p, int end) => true;
}

/// ASCII / US-ASCII encoding (`ascii.c`).
final AsciiEncoding asciiEncoding = AsciiEncoding._();

class AsciiEncoding extends SingleByteEncoding {
  AsciiEncoding._();

  @override
  String get name => 'US-ASCII';

  @override
  bool isCodeCtype(int code, int ctype) => asciiIsCodeCtype(code, ctype);

  @override
  CaseFoldResult mbcCaseFold(
    int flag,
    Uint8List s,
    int pp,
    int end,
    Uint8List fold,
  ) {
    fold[0] = asciiToLowerTable[s[pp]];
    return (foldLen: 1, newPos: pp + 1);
  }

  @override
  void applyAllCaseFold(int flag, ApplyAllCaseFoldFunc f) {
    for (var c = 0x41; c <= 0x5a; c++) {
      f(c, [c + 0x20]);
      f(c + 0x20, [c]);
    }
  }

  @override
  List<CaseFoldCodeItem> getCaseFoldCodesByStr(
    int flag,
    Uint8List s,
    int p,
    int end,
  ) {
    final c = s[p];
    if (c >= 0x41 && c <= 0x5a) {
      return [
        CaseFoldCodeItem(1, [c + 0x20]),
      ];
    }
    if (c >= 0x61 && c <= 0x7a) {
      return [
        CaseFoldCodeItem(1, [c - 0x20]),
      ];
    }
    return const [];
  }
}
