/// Shared case-fold machinery for the table-driven single-byte encodings
/// (ISO-8859-*, CP1251, KOI8*). Mirrors `regenc.c`
/// `onigenc_apply_all_case_fold_with_map`,
/// `onigenc_get_case_fold_codes_by_str_with_map`, `ss_apply_all_case_fold` and
/// the per-file `mbc_case_fold` / `is_code_ctype` bodies, which are structurally
/// identical across those files (only the tables and the `ess_tsett` flag
/// differ).
library;

import 'dart:typed_data';

import '../onig_types.dart';
import 'encoding.dart';
import 'mb_shared.dart';
import 'single_byte.dart';

// Case-fold flags (`oniguruma.h`).
const int caseFoldAsciiOnly = 1; // ONIGENC_CASE_FOLD_ASCII_ONLY
const int internalCaseFoldMultiChar = 1 << 30; // INTERNAL_..._MULTI_CHAR

bool caseFoldIsAsciiOnly(int flag) => (flag & caseFoldAsciiOnly) != 0;
bool caseFoldIsNotAsciiOnly(int flag) => (flag & caseFoldAsciiOnly) == 0;

const int _largeS = 0x53; // 'S'
const int _smallS = 0x73; // 's'

/// One `from`⇔`to` fold pair (`OnigPairCaseFoldCodes`).
class SbFoldPair {
  final int from;
  final int to;
  const SbFoldPair(this.from, this.to);
}

/// Base for the table-driven single-byte encodings.
///
/// Subclasses provide the 256-entry [ctypeTable], the 256-entry [toLowerTable]
/// (for pure-ASCII-case encodings this is [asciiToLowerTable]), the
/// [caseFoldMap] (empty for ASCII-only encodings) and [essTsett] (the German
/// ß / "ss" handling flag; `ess_tsett_flag` in C).
abstract class SingleByteFoldEncoding extends SingleByteEncoding {
  SingleByteFoldEncoding();

  Uint16List get ctypeTable;
  Uint8List get toLowerTable;
  List<SbFoldPair> get caseFoldMap;
  bool get essTsett;

  Map<int, int>? _repCache;

  @override
  int caseFoldRep(int code) {
    if (code >= 0x41 && code <= 0x5a) return code + 0x20; // ASCII upper → lower
    // Each fold pair marks `from` and `to` as case-equivalent; map `from` onto
    // `to` so both share the representative `to` (ß → "ss" is multi-char and is
    // intentionally left as its own representative here).
    final m = _repCache ??= {for (final p in caseFoldMap) p.from: p.to};
    return m[code] ?? code;
  }

  @override
  bool isCodeCtype(int code, int ctype) {
    if (code < 256) {
      if (ctype > CType.maxStd) return false;
      return (ctypeTable[code] & CType.bit(ctype)) != 0;
    }
    return false;
  }

  @override
  CaseFoldResult mbcCaseFold(
    int flag,
    Uint8List s,
    int pp,
    int end,
    Uint8List fold,
  ) {
    final c = s[pp];
    if (essTsett && c == 0xdf && (flag & internalCaseFoldMultiChar) != 0) {
      fold[0] = _smallS;
      fold[1] = _smallS;
      return (foldLen: 2, newPos: pp + 1);
    }
    if (caseFoldIsNotAsciiOnly(flag) || c < 0x80) {
      fold[0] = toLowerTable[c];
    } else {
      fold[0] = c;
    }
    return (foldLen: 1, newPos: pp + 1);
  }

  @override
  void applyAllCaseFold(int flag, ApplyAllCaseFoldFunc f) {
    // onigenc_apply_all_case_fold_with_map: ASCII first, then the map, then ss.
    for (var c = 0x41; c <= 0x5a; c++) {
      f(c, [c + 0x20]);
      f(c + 0x20, [c]);
    }
    if (caseFoldIsAsciiOnly(flag)) return;
    for (final m in caseFoldMap) {
      f(m.from, [m.to]);
      f(m.to, [m.from]);
    }
    if (essTsett) {
      f(0xdf, [_smallS, _smallS]);
    }
  }

  @override
  List<CaseFoldCodeItem> getCaseFoldCodesByStr(
    int flag,
    Uint8List s,
    int p,
    int end,
  ) {
    return getCaseFoldCodesByStrWithMap(caseFoldMap, essTsett, flag, s, p, end);
  }

  @override
  int propertyNameToCtype(String name) => minimumPropertyNameToCtype(name);
}

/// `onigenc_get_case_fold_codes_by_str_with_map`.
List<CaseFoldCodeItem> getCaseFoldCodesByStrWithMap(
  List<SbFoldPair> map,
  bool essTsett,
  int flag,
  Uint8List s,
  int p,
  int end,
) {
  final sa = const [_largeS, _smallS];
  final c = s[p];

  if (c >= 0x41 && c <= 0x5a) {
    // A - Z
    if (c == _largeS &&
        essTsett &&
        end > p + 1 &&
        (s[p + 1] == _largeS || s[p + 1] == _smallS) &&
        caseFoldIsNotAsciiOnly(flag)) {
      return _ssCombination(sa, s, p);
    }
    return [
      CaseFoldCodeItem(1, [c + 0x20]),
    ];
  } else if (c >= 0x61 && c <= 0x7a) {
    // a - z
    if (c == _smallS &&
        essTsett &&
        end > p + 1 &&
        (s[p + 1] == _smallS || s[p + 1] == _largeS) &&
        caseFoldIsNotAsciiOnly(flag)) {
      return _ssCombination(sa, s, p);
    }
    return [
      CaseFoldCodeItem(1, [c - 0x20]),
    ];
  } else if (c == 0xdf && essTsett && caseFoldIsNotAsciiOnly(flag)) {
    return [
      CaseFoldCodeItem(1, [_smallS, _smallS]),
      CaseFoldCodeItem(1, [_largeS, _largeS]),
      CaseFoldCodeItem(1, [_smallS, _largeS]),
      CaseFoldCodeItem(1, [_largeS, _smallS]),
    ];
  } else {
    if (caseFoldIsAsciiOnly(flag)) return const [];
    for (final m in map) {
      if (c == m.from) {
        return [
          CaseFoldCodeItem(1, [m.to]),
        ];
      } else if (c == m.to) {
        return [
          CaseFoldCodeItem(1, [m.from]),
        ];
      }
    }
  }
  return const [];
}

List<CaseFoldCodeItem> _ssCombination(List<int> sa, Uint8List s, int p) {
  final items = <CaseFoldCodeItem>[
    CaseFoldCodeItem(2, [0xdf]),
  ];
  for (var i = 0; i < 2; i++) {
    for (var j = 0; j < 2; j++) {
      if (sa[i] == s[p] && sa[j] == s[p + 1]) continue;
      items.add(CaseFoldCodeItem(2, [sa[i], sa[j]]));
    }
  }
  return items;
}
