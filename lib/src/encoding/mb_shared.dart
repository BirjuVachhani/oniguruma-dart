/// Shared helpers for the multi-byte, non-Unicode encodings (`regenc.c`
/// `onigenc_mbn_*`, `onigenc_mb2_*`, `onigenc_mb4_*`, `onig_is_in_code_range`).
///
/// These mirror the generic helper functions in `regenc.c` that the CJK
/// encodings (`euc_*.c`, `sjis.c`, `big5.c`, `gb18030.c`) delegate to. None of
/// these encodings use the Unicode case-fold layer: case folding is ASCII-only,
/// exactly like `ascii.c`.
library;

import 'dart:typed_data';

import '../onig_errors.dart';
import '../onig_types.dart';
import 'encoding.dart';

/// `ONIGENC_MAX_STD_CTYPE` (== `ONIGENC_CTYPE_ASCII`).
const int maxStdCtype = CType.ascii;

/// `CTYPE_IS_WORD_GRAPH_PRINT` — word / graph / print ctypes.
bool ctypeIsWordGraphPrint(int ctype) =>
    ctype == CType.word || ctype == CType.graph || ctype == CType.print;

/// `onigenc_mbn_mbc_to_code` — big-endian accumulate of the char's bytes.
int mbnMbcToCode(OnigEncoding enc, Uint8List s, int p, int end) {
  final len = enc.length(s, p, end);
  var n = s[p++];
  if (len == 1) return n;
  for (var i = 1; i < len; i++) {
    if (p >= end) break;
    final c = s[p++];
    n = (n << 8) + c;
  }
  return n;
}

/// `onigenc_mbn_mbc_case_fold` — ASCII lower for ASCII bytes, otherwise copy the
/// char's bytes verbatim.
CaseFoldResult mbnMbcCaseFold(
  OnigEncoding enc,
  int flag,
  Uint8List s,
  int pp,
  int end,
  Uint8List fold,
) {
  if (s[pp] < 128) {
    fold[0] = asciiToLowerTable[s[pp]];
    return (foldLen: 1, newPos: pp + 1);
  }
  final len = enc.length(s, pp, end);
  for (var i = 0; i < len; i++) {
    fold[i] = s[pp + i];
  }
  return (foldLen: len, newPos: pp + len);
}

/// `onigenc_mb2_code_to_mbc` — encode a code that occupies up to 2 bytes.
int mb2CodeToMbc(OnigEncoding enc, int code, Uint8List buf, int p) {
  final start = p;
  if ((code & 0xff00) != 0) {
    buf[p++] = (code >> 8) & 0xff;
  }
  buf[p++] = code & 0xff;

  if (enc.length(buf, start, p) != (p - start)) {
    return OnigErr.invalidCodePointValue;
  }
  return p - start;
}

/// `onigenc_mb4_code_to_mbc` — encode a code that occupies up to 4 bytes.
int mb4CodeToMbc(OnigEncoding enc, int code, Uint8List buf, int p) {
  final start = p;
  if ((code & 0xff000000) != 0) {
    buf[p++] = (code >> 24) & 0xff;
  }
  if ((code & 0xff0000) != 0 || p != start) {
    buf[p++] = (code >> 16) & 0xff;
  }
  if ((code & 0xff00) != 0 || p != start) {
    buf[p++] = (code >> 8) & 0xff;
  }
  buf[p++] = code & 0xff;

  if (enc.length(buf, start, p) != (p - start)) {
    return OnigErr.invalidCodePointValue;
  }
  return p - start;
}

/// `onigenc_mb2_is_code_ctype` / `onigenc_mb4_is_code_ctype` (identical bodies).
bool mbIsCodeCtype(OnigEncoding enc, int code, int ctype) {
  if (code < 128) {
    if (ctype <= maxStdCtype) {
      return asciiIsCodeCtype(code, ctype);
    }
  } else {
    if (ctypeIsWordGraphPrint(ctype)) {
      return enc.codeToMbcLen(code) > 1;
    }
  }
  return false;
}

/// `onigenc_ascii_apply_all_case_fold` — the A–Z ⇔ a–z pairs.
void asciiApplyAllCaseFold(int flag, ApplyAllCaseFoldFunc f) {
  for (var c = 0x41; c <= 0x5a; c++) {
    f(c, [c + 0x20]);
    f(c + 0x20, [c]);
  }
}

/// `onigenc_ascii_get_case_fold_codes_by_str`.
List<CaseFoldCodeItem> asciiGetCaseFoldCodesByStr(
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

/// `onigenc_is_mbc_newline_0x0a` — the ASCII-compatible newline test.
bool isMbcNewline0x0a(Uint8List s, int p, int end) => p < end && s[p] == 0x0a;

/// `onigenc_minimum_property_name_to_ctype` — the POSIX bracket names common to
/// the non-Unicode encodings. Throws [OnigException] on an unknown name.
int minimumPropertyNameToCtype(String name) {
  switch (name) {
    case 'Alnum':
      return CType.alnum;
    case 'Alpha':
      return CType.alpha;
    case 'Blank':
      return CType.blank;
    case 'Cntrl':
      return CType.cntrl;
    case 'Digit':
      return CType.digit;
    case 'Graph':
      return CType.graph;
    case 'Lower':
      return CType.lower;
    case 'Print':
      return CType.print;
    case 'Punct':
      return CType.punct;
    case 'Space':
      return CType.space;
    case 'Upper':
      return CType.upper;
    case 'XDigit':
      return CType.xdigit;
    case 'ASCII':
      return CType.ascii;
    case 'Word':
      return CType.word;
  }
  throw OnigException(OnigErr.invalidCharPropertyName, detail: name);
}

/// `onig_is_in_code_range` — binary search a flat range table `[n, lo0, hi0,
/// lo1, hi1, ...]` (`OnigCodePoint*`).
bool onigIsInCodeRange(List<int> ranges, int code) {
  final n = ranges[0];
  var low = 0;
  var high = n;
  while (low < high) {
    final x = (low + high) >> 1;
    // ranges[0] is the count; pairs start at index 1 → data[k] == ranges[1+k].
    if (code > ranges[1 + x * 2 + 1]) {
      low = x + 1;
    } else {
      high = x;
    }
  }
  return low < n && code >= ranges[1 + low * 2];
}
