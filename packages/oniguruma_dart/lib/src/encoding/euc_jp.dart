/// EUC-JP encoding (`euc_jp.c`). ASCII-only case folding (no Unicode layer).
library;

import 'dart:typed_data';

import '../onig_errors.dart';
import 'encoding.dart';
import 'mb_shared.dart';

/// EUC-JP encoding singleton.
final EucJpEncoding eucJpEncoding = EucJpEncoding._();

// EncLen_EUCJP[b]: 0x8e→2 (JIS X 0201 kana), 0x8f→3 (JIS X 0212),
// 0xa1..0xfe→2 (JIS X 0208), everything else 1.
int _encLen(int b) {
  if (b == 0x8e) return 2;
  if (b == 0x8f) return 3;
  if (b >= 0xa1 && b <= 0xfe) return 2;
  return 1;
}

// eucjp_islead: false for the trail bytes 0xa1..0xfe, true otherwise.
bool _isLead(int c) => c < 0xa1 || c > 0xfe;

// \p{Hiragana} / \p{Katakana} range tables (flat: [count, lo, hi, ...]).
const List<int> _crHiragana = [1, 0xa4a1, 0xa4f3];
const List<int> _crKatakana = [
  3, 0xa5a1, 0xa5f6, 0xaaa6, 0xaaaf, 0xaab1, 0xaadd, //
];
const List<List<int>> _propertyList = [_crHiragana, _crKatakana];

class EucJpEncoding extends OnigEncoding {
  EucJpEncoding._();

  @override
  String get name => 'EUC-JP';

  @override
  int get maxLength => 3;

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
    if (code < 128) return 1;
    if ((code & 0xff0000) != 0) {
      if (_encLen((code >> 16) & 0xff) == 3) return 3;
    } else if ((code & 0xff00) != 0) {
      if (_encLen((code >> 8) & 0xff) == 2) return 2;
    } else if (code < 256) {
      if (_encLen(code & 0xff) == 1) return 1;
    }
    return OnigErr.invalidCodePointValue;
  }

  @override
  int codeToMbc(int code, Uint8List buf, int p) {
    final start = p;
    if ((code & 0xff0000) != 0) {
      buf[p++] = (code >> 16) & 0xff;
      buf[p++] = (code >> 8) & 0xff;
    } else if ((code & 0xff00) != 0) {
      buf[p++] = (code >> 8) & 0xff;
    }
    buf[p++] = code & 0xff;
    if (_encLen(buf[start]) != (p - start)) {
      return OnigErr.invalidCodePointValue;
    }
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
    while (!_isLead(s[q]) && q > start) {
      q--;
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
        return maxStdCtype + 1; // 15
      case 'Katakana':
        return maxStdCtype + 2; // 16
    }
    throw OnigException(OnigErr.invalidCharPropertyName, detail: name);
  }

  @override
  List<int>? encodingPropertyRanges(String name) {
    switch (name) {
      case 'Hiragana':
        return _crHiragana.sublist(1); // drop leading [count]
      case 'Katakana':
        return _crKatakana.sublist(1);
    }
    return null;
  }
}
