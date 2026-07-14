/// Shift_JIS encoding (`sjis.c`). ASCII-only case folding.
library;

import 'dart:typed_data';

import '../onig_errors.dart';
import 'encoding.dart';
import 'mb_shared.dart';

/// Shift_JIS encoding singleton.
final SjisEncoding sjisEncoding = SjisEncoding._();

// EncLen_SJIS[b]: lead (2-byte) for 0x81..0x9f and 0xe0..0xfc, else 1.
int _encLen(int b) =>
    ((b >= 0x81 && b <= 0x9f) || (b >= 0xe0 && b <= 0xfc)) ? 2 : 1;

bool _isMbFirst(int b) => _encLen(b) > 1;
bool _isMbTrail(int b) => _sjisTrail[b] != 0;

/// `SJIS_CAN_BE_TRAIL_TABLE` (sjis.c) — bytes that may be a second byte.
final Uint8List _sjisTrail = Uint8List.fromList(const <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0,
]);

// \p{Hiragana} / \p{Katakana} range tables (flat: [count, lo, hi, ...]).
const List<int> _crHiragana = [1, 0x829f, 0x82f1];
const List<int> _crKatakana = [
  4, 0x00a6, 0x00af, 0x00b1, 0x00dd, 0x8340, 0x837e, 0x8380, 0x8396, //
];
const List<List<int>> _propertyList = [_crHiragana, _crKatakana];

class SjisEncoding extends OnigEncoding {
  SjisEncoding._();

  @override
  String get name => 'Shift_JIS';

  @override
  int get maxLength => 2;

  @override
  int get minLength => 1;

  @override
  bool get isSingleByte => false;

  @override
  int lengthByFirstByte(int b) => _encLen(b);

  @override
  int length(Uint8List s, int p, int end) => _encLen(s[p]);

  @override
  int mbcToCode(Uint8List s, int p, int end) => mbnMbcToCode(this, s, p, end);

  @override
  int codeToMbcLen(int code) {
    if (code < 256) {
      if (_encLen(code) == 1) return 1;
    } else if (code < 0x10000) {
      if (_encLen((code >> 8) & 0xff) == 2) return 2;
    }
    return OnigErr.invalidCodePointValue;
  }

  @override
  int codeToMbc(int code, Uint8List buf, int p) {
    final start = p;
    if ((code & 0xff00) != 0) buf[p++] = (code >> 8) & 0xff;
    buf[p++] = code & 0xff;
    return p - start;
  }

  @override
  bool isMbcNewline(Uint8List s, int p, int end) => isMbcNewline0x0a(s, p, end);

  @override
  CaseFoldResult mbcCaseFold(
    int flag,
    Uint8List s,
    int pp,
    int end,
    Uint8List fold,
  ) => mbnMbcCaseFold(this, flag, s, pp, end, fold);

  @override
  int leftAdjustCharHead(Uint8List s, int start, int p) {
    if (p <= start) return p;
    var q = p;
    if (_isMbTrail(s[q])) {
      while (q > start) {
        if (!_isMbFirst(s[--q])) {
          q++;
          break;
        }
      }
    }
    final len = _encLen(s[q]);
    if (q + len > p) return q;
    q += len;
    return q + ((p - q) & ~1);
  }

  @override
  bool isMbcHead(Uint8List s, int p, int end) => length(s, p, end) != 1;

  @override
  bool isCodeCtype(int code, int ctype) {
    if (ctype <= maxStdCtype) {
      if (code < 128) return asciiIsCodeCtype(code, ctype);
      if (ctypeIsWordGraphPrint(ctype)) return codeToMbcLen(code) > 1;
      return false;
    }
    final idx = ctype - (maxStdCtype + 1);
    if (idx >= _propertyList.length) return false;
    return onigIsInCodeRange(_propertyList[idx], code);
  }

  @override
  void applyAllCaseFold(int flag, ApplyAllCaseFoldFunc f) =>
      asciiApplyAllCaseFold(flag, f);

  @override
  List<CaseFoldCodeItem> getCaseFoldCodesByStr(
    int flag,
    Uint8List s,
    int p,
    int end,
  ) => asciiGetCaseFoldCodesByStr(flag, s, p, end);

  @override
  int propertyNameToCtype(String name) {
    switch (name) {
      case 'Hiragana':
        return maxStdCtype + 1;
      case 'Katakana':
        return maxStdCtype + 2;
    }
    throw OnigException(OnigErr.invalidCharPropertyName, detail: name);
  }
}
