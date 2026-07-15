/// UTF-8 encoding (`utf8.c`). The primary fast-path encoding.
library;

import 'dart:typed_data';

import '../onig_errors.dart';
import '../unicode/unicode.dart' as uni;
import 'encoding.dart';

/// `EncLen_UTF8[256]` — byte length keyed by first byte (non-RFC3629 build,
/// matching the default C configuration).
final Uint8List _encLenUtf8 = _buildEncLen();

Uint8List _buildEncLen() {
  // RFC 3629: UTF-8 is capped at 4 bytes (0x10FFFF). Lead bytes 0xF5-0xFF are
  // invalid and map to length 1 (matches C EncLen_UTF8 with USE_RFC3629_RANGE).
  final t = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    if (i < 0xc0) {
      t[i] = 1; // ASCII (0x00-0x7f) and continuation bytes (0x80-0xbf)
    } else if (i < 0xe0) {
      t[i] = 2;
    } else if (i < 0xf0) {
      t[i] = 3;
    } else if (i < 0xf5) {
      t[i] = 4; // 0xf0-0xf4
    } else {
      t[i] = 1; // 0xf5-0xff are invalid leads
    }
  }
  return t;
}

bool _isLead(int c) => (c & 0xc0) != 0x80;

/// UTF-8 encoding singleton.
final Utf8Encoding utf8Encoding = Utf8Encoding._();

class Utf8Encoding extends OnigEncoding {
  @override
  bool get isUnicodeEncoding => true;

  Utf8Encoding._();

  @override
  String get name => 'UTF-8';

  @override
  int get maxLength => 6;

  @override
  int get minLength => 1;

  @override
  bool get isSingleByte => false;

  @override
  int lengthByFirstByte(int b) => _encLenUtf8[b];

  @override
  int length(Uint8List s, int p, int end) => _encLenUtf8[s[p]];

  @override
  bool isValidMbcString(Uint8List s, int p, int end) {
    // Ported from utf8.c is_valid_mbc_string (RFC 3629 range).
    while (p < end) {
      final b = s[p];
      if (b > 0xf4 || (b > 0x7f && b < 0xc2)) return false;
      final len = _encLenUtf8[b];
      p++;
      for (var i = 1; i < len; i++) {
        if (p >= end) return false;
        final t = s[p++];
        if (t < 0x80 || t > 0xbf) return false; // not a UTF-8 tail byte
      }
    }
    return true;
  }

  @override
  int mbcToCode(Uint8List s, int p, int end) {
    var len = _encLenUtf8[s[p]];
    final avail = end - p;
    if (len > avail) len = avail;

    var c = s[p++];
    if (len > 1) {
      len--;
      var n = c & ((1 << (6 - len)) - 1);
      while (len-- > 0) {
        c = s[p++];
        n = (n << 6) | (c & 0x3f);
      }
      return n;
    }
    return c;
  }

  @override
  int codeToMbcLen(int code) {
    // RFC 3629: UTF-8 is capped at 4 bytes (0x1FFFFF); larger → invalid.
    if ((code & 0xffffff80) == 0) return 1;
    if ((code & 0xfffff800) == 0) return 2;
    if ((code & 0xffff0000) == 0) return 3;
    if ((code & 0xffe00000) == 0) return 4;
    return OnigErr.invalidCodePointValue;
  }

  @override
  int codeToMbc(int code, Uint8List buf, int p) {
    if ((code & 0xffffff80) == 0) {
      buf[p] = code;
      return 1;
    }
    final start = p;
    if ((code & 0xfffff800) == 0) {
      buf[p++] = ((code >> 6) & 0x1f) | 0xc0;
    } else if ((code & 0xffff0000) == 0) {
      buf[p++] = ((code >> 12) & 0x0f) | 0xe0;
      buf[p++] = ((code >> 6) & 0x3f) | 0x80;
    } else if ((code & 0xffe00000) == 0) {
      buf[p++] = ((code >> 18) & 0x07) | 0xf0;
      buf[p++] = ((code >> 12) & 0x3f) | 0x80;
      buf[p++] = ((code >> 6) & 0x3f) | 0x80;
    } else {
      // RFC 3629: values above 0x1FFFFF cannot be encoded.
      return OnigErr.invalidCodePointValue;
    }
    buf[p++] = (code & 0x3f) | 0x80;
    return p - start;
  }

  @override
  bool isMbcNewline(Uint8List s, int p, int end) => p < end && s[p] == 0x0a;

  @override
  int leftAdjustCharHead(Uint8List s, int start, int p) {
    if (p <= start) return p;
    var q = p;
    while (!_isLead(s[q]) && q > start) {
      q--;
    }
    return q;
  }

  @override
  bool isMbcHead(Uint8List s, int p, int end) => _isLead(s[p]);

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
    final c = s[pp];
    if (c < 0x80) {
      fold[0] = asciiToLowerTable[c];
      return (foldLen: 1, newPos: pp + 1);
    }
    // Fold the multibyte char toward its canonical case-equivalent rep.
    final len = _encLenUtf8[c];
    final code = mbcToCode(s, pp, end);
    final rep = uni.caseFoldRep(code);
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
    final len = _encLenUtf8[s[p]];
    final folds = uni.unicodeFoldCodes(code);
    if (folds.isEmpty) return const [];
    return [CaseFoldCodeItem(len, folds)];
  }
}
