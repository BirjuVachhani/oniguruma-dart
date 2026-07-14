/// EUC-TW encoding (`euc_tw.c`). ASCII-only case folding.
///
/// EUC-TW uses SS2 (0x8e) plane-selector 4-byte sequences plus the usual
/// 0xa1..0xfe two-byte plane. `code_to_mbc` therefore uses the 4-byte helper.
library;

import 'dart:typed_data';

import '../onig_errors.dart';
import 'encoding.dart';
import 'mb_shared.dart';

/// EUC-TW encoding singleton.
final EucTwEncoding eucTwEncoding = EucTwEncoding._();

// EncLen_EUCTW[b]: 0x8e → 4 (SS2 + plane + 2 bytes), 0xa1..0xfe → 2, else 1.
int _encLen(int b) {
  if (b == 0x8e) return 4;
  if (b >= 0xa1 && b <= 0xfe) return 2;
  return 1;
}

// euctw_islead: false for trail bytes 0xa1..0xfe, true otherwise.
bool _isLead(int c) => c < 0xa1 || c > 0xfe;

class EucTwEncoding extends OnigEncoding {
  EucTwEncoding._();

  @override
  String get name => 'EUC-TW';

  @override
  int get maxLength => 4;

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
    if ((code & 0xff000000) != 0) {
      if (_encLen((code >> 24) & 0xff) == 4) return 4;
    } else if ((code & 0xff0000) != 0) {
      return OnigErr.invalidCodePointValue;
    } else if ((code & 0xff00) != 0) {
      if (_encLen((code >> 8) & 0xff) == 2) return 2;
    } else {
      if (_encLen(code & 0xff) == 1) return 1;
    }
    return OnigErr.invalidCodePointValue;
  }

  @override
  int codeToMbc(int code, Uint8List buf, int p) =>
      mb4CodeToMbc(this, code, buf, p);

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
  bool isCodeCtype(int code, int ctype) => mbIsCodeCtype(this, code, ctype);

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
  int propertyNameToCtype(String name) => minimumPropertyNameToCtype(name);
}
