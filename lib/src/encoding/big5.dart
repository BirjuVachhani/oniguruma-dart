/// Big5 encoding (`big5.c`). ASCII-only case folding.
library;

import 'dart:typed_data';

import '../onig_errors.dart';
import 'encoding.dart';
import 'mb_shared.dart';

/// Big5 encoding singleton.
final Big5Encoding big5Encoding = Big5Encoding._();

// EncLen_BIG5[b]: 0xa1..0xfe → 2, everything else 1.
int _encLen(int b) => (b >= 0xa1 && b <= 0xfe) ? 2 : 1;

bool _isMbFirst(int b) => _encLen(b) > 1;
bool _isMbTrail(int b) => _big5Trail[b] != 0;

/// `BIG5_CAN_BE_TRAIL_TABLE` (big5.c).
final Uint8List _big5Trail = Uint8List.fromList(const <int>[
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
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
]);

class Big5Encoding extends OnigEncoding {
  Big5Encoding._();

  @override
  String get name => 'Big5';

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
    if ((code & ~0xffff) != 0) return OnigErr.invalidCodePointValue;
    if ((code & 0xff00) != 0) {
      if (_encLen((code >> 8) & 0xff) == 2) return 2;
    } else {
      if (_encLen(code & 0xff) == 1) return 1;
    }
    return OnigErr.invalidCodePointValue;
  }

  @override
  int codeToMbc(int code, Uint8List buf, int p) =>
      mb2CodeToMbc(this, code, buf, p);

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
