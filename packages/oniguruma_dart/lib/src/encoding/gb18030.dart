/// GB18030 encoding (`gb18030.c`). ASCII-only case folding.
///
/// GB18030 has 1-, 2- and 4-byte characters. `left_adjust_char_head` uses the
/// same backward-scanning state machine as the C source: because a byte in
/// 0x30..0x39 can be both a plain digit (C4 role) and the 2nd/4th byte of a
/// multi-byte sequence, the head must be found by replaying the automaton
/// backwards over the `C1/C2/C4/CM` byte classes.
library;

import 'dart:typed_data';

import '../onig_errors.dart';
import 'encoding.dart';
import 'mb_shared.dart';

/// GB18030 encoding singleton.
final Gb18030Encoding gb18030Encoding = Gb18030Encoding._();

// GB18030_MAP byte classes.
const int _c1 = 0; // one-byte char
const int _c2 = 1; // one-byte or 2nd of two-byte
const int _c4 = 2; // one-byte or 2nd/4th of four-byte
const int _cm = 3; // first of two-/four-byte, or 2nd of two-byte

/// `GB18030_MAP` (gb18030.c).
final Uint8List _map = Uint8List.fromList(const <int>[
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c4,
  _c4,
  _c4,
  _c4,
  _c4,
  _c4,
  _c4,
  _c4,
  _c4,
  _c4,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c1,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c2,
  _c1,
  _c2,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _cm,
  _c1,
]);

class Gb18030Encoding extends OnigEncoding {
  Gb18030Encoding._();

  @override
  String get name => 'GB18030';

  @override
  int get maxLength => 4;

  @override
  int get minLength => 1;

  @override
  bool get isSingleByte => false;

  @override
  int lengthByFirstByte(int b) => _map[b] != _cm ? 1 : 2;

  @override
  int length(Uint8List s, int p, int end) {
    if (_map[s[p]] != _cm) return 1;
    if (p + 1 >= end) return 2;
    if (_map[s[p + 1]] == _c4) return 4;
    return 2;
  }

  @override
  int mbcToCode(Uint8List s, int p, int end) => mbnMbcToCode(this, s, p, end);

  @override
  int codeToMbcLen(int code) {
    if ((code & 0xff000000) != 0) {
      if (_map[(code >> 24) & 0xff] == _cm) {
        if (_map[(code >> 16) & 0xff] == _c4) return 4;
      }
    } else if ((code & 0xff0000) != 0) {
      return OnigErr.invalidCodePointValue;
    } else if ((code & 0xff00) != 0) {
      if (_map[(code >> 8) & 0xff] == _cm) {
        final c = _map[code & 0xff];
        if (c == _cm || c == _c2) return 2;
      }
    } else {
      if (_map[code & 0xff] != _cm) return 1;
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
  int leftAdjustCharHead(Uint8List s, int start, int p) =>
      _leftAdjust(s, start, p);

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

// enum state (gb18030.c).
enum _S {
  start,
  oneC2,
  oneC4,
  oneCM,
  oddCMoneCX,
  evenCMoneCX,
  oneCMC4,
  oddCMC4,
  oneC4oddCMC4,
  evenCMC4,
  oneC4evenCMC4,
  oddCModdCMC4,
  evenCModdCMC4,
  oddCMevenCMC4,
  evenCMevenCMC4,
  oddC4CM,
  oneCModdC4CM,
  evenC4CM,
  oneCMevenC4CM,
  evenCModdC4CM,
  oddCModdC4CM,
  evenCMevenC4CM,
  oddCMevenC4CM,
}

/// Faithful port of `gb18030_left_adjust_char_head`. [p] is the query position,
/// [start] the string start; returns the head offset of the char covering [p].
int _leftAdjust(Uint8List s, int start, int p) {
  var state = _S.start;
  for (var q = p; q >= start; q--) {
    final m = _map[s[q]];
    switch (state) {
      case _S.start:
        if (m == _c1) return p;
        state = m == _c2 ? _S.oneC2 : (m == _c4 ? _S.oneC4 : _S.oneCM);
        break;
      case _S.oneC2:
        if (m != _cm) return p;
        state = _S.oddCMoneCX;
        break;
      case _S.oneC4:
        if (m != _cm) return p;
        state = _S.oneCMC4;
        break;
      case _S.oneCM:
        if (m == _c1 || m == _c2) return p;
        state = m == _c4 ? _S.oddC4CM : _S.oddCMoneCX;
        break;
      case _S.oddCMoneCX:
        if (m != _cm) return p - 1;
        state = _S.evenCMoneCX;
        break;
      case _S.evenCMoneCX:
        if (m != _cm) return p;
        state = _S.oddCMoneCX;
        break;
      case _S.oneCMC4:
        if (m == _c1 || m == _c2) return p - 1;
        state = m == _c4 ? _S.oneC4oddCMC4 : _S.evenCMoneCX;
        break;
      case _S.oddCMC4:
        if (m == _c1 || m == _c2) return p - 1;
        state = m == _c4 ? _S.oneC4oddCMC4 : _S.oddCModdCMC4;
        break;
      case _S.oneC4oddCMC4:
        if (m != _cm) return p - 1;
        state = _S.evenCMC4;
        break;
      case _S.evenCMC4:
        if (m == _c1 || m == _c2) return p - 3;
        state = m == _c4 ? _S.oneC4evenCMC4 : _S.oddCMevenCMC4;
        break;
      case _S.oneC4evenCMC4:
        if (m != _cm) return p - 3;
        state = _S.oddCMC4;
        break;
      case _S.oddCModdCMC4:
        if (m != _cm) return p - 3;
        state = _S.evenCModdCMC4;
        break;
      case _S.evenCModdCMC4:
        if (m != _cm) return p - 1;
        state = _S.oddCModdCMC4;
        break;
      case _S.oddCMevenCMC4:
        if (m != _cm) return p - 1;
        state = _S.evenCMevenCMC4;
        break;
      case _S.evenCMevenCMC4:
        if (m != _cm) return p - 3;
        state = _S.oddCMevenCMC4;
        break;
      case _S.oddC4CM:
        if (m != _cm) return p;
        state = _S.oneCModdC4CM;
        break;
      case _S.oneCModdC4CM:
        if (m == _c1 || m == _c2) return p - 2;
        state = m == _c4 ? _S.evenC4CM : _S.evenCModdC4CM;
        break;
      case _S.evenC4CM:
        if (m != _cm) return p - 2;
        state = _S.oneCMevenC4CM;
        break;
      case _S.oneCMevenC4CM:
        if (m == _c1 || m == _c2) return p;
        state = m == _c4 ? _S.oddC4CM : _S.evenCMevenC4CM;
        break;
      case _S.evenCModdC4CM:
        if (m != _cm) return p;
        state = _S.oddCModdC4CM;
        break;
      case _S.oddCModdC4CM:
        if (m != _cm) return p - 2;
        state = _S.evenCModdC4CM;
        break;
      case _S.evenCMevenC4CM:
        if (m != _cm) return p - 2;
        state = _S.oddCMevenC4CM;
        break;
      case _S.oddCMevenC4CM:
        if (m != _cm) return p;
        state = _S.evenCMevenC4CM;
        break;
    }
  }

  return switch (state) {
    _S.start => p,
    _S.oneC2 => p,
    _S.oneC4 => p,
    _S.oneCM => p,
    _S.oddCMoneCX => p - 1,
    _S.evenCMoneCX => p,
    _S.oneCMC4 => p - 1,
    _S.oddCMC4 => p - 1,
    _S.oneC4oddCMC4 => p - 1,
    _S.evenCMC4 => p - 3,
    _S.oneC4evenCMC4 => p - 3,
    _S.oddCModdCMC4 => p - 3,
    _S.evenCModdCMC4 => p - 1,
    _S.oddCMevenCMC4 => p - 1,
    _S.evenCMevenCMC4 => p - 3,
    _S.oddC4CM => p,
    _S.oneCModdC4CM => p - 2,
    _S.evenC4CM => p - 2,
    _S.oneCMevenC4CM => p,
    _S.evenCModdC4CM => p,
    _S.oddCModdC4CM => p - 2,
    _S.evenCMevenC4CM => p - 2,
    _S.oddCMevenC4CM => p,
  };
}
