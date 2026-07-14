/// Unicode property + case-fold logic (`unicode.c`), backed by the generated
/// tables in `data/*.g.dart`.
library;

import '../onig_types.dart';
import 'data/egcb.g.dart';
import 'data/fold.g.dart';
import 'data/latin1_ctype.g.dart';
import 'data/property_ranges.g.dart';
import 'data/wb.g.dart';

/// Standard [CType] id → CR table name (matches CodeRanges[0..14] in
/// unicode_property_data.c).
const Map<int, String> _ctypeToCr = {
  0: 'NEWLINE',
  1: 'Alpha',
  2: 'Blank',
  3: 'Cntrl',
  4: 'Digit',
  5: 'Graph',
  6: 'Lower',
  7: 'Print',
  8: 'PosixPunct',
  9: 'Space',
  10: 'Upper',
  11: 'XDigit',
  12: 'Word',
  13: 'Alnum',
  14: 'ASCII',
};

/// `onigenc_unicode_is_code_ctype` — is [code] a member of standard [ctype]?
bool unicodeIsCodeCtype(int code, int ctype) {
  if (ctype <= CType.maxStd && code < 256) {
    if (ctype == CType.newline) return code == 0x0a;
    return (unicodeLatin1CtypeTable[code] & (1 << ctype)) != 0;
  }
  if (ctype == CType.newline) return code == 0x0a;
  final name = _ctypeToCr[ctype];
  if (name == null) return false;
  final ranges = unicodeCrRanges[name];
  if (ranges == null) return false;
  return inRanges(code, ranges);
}

/// Flat `[lo,hi,...]` Unicode code-point ranges for a POSIX/ctype id, or null
/// if the ctype has no Unicode range table (`ONIGENC_GET_CTYPE_CODE_RANGE`).
List<int>? unicodeCtypeCodeRange(int ctype) {
  if (ctype == CType.newline) return const [0x0a, 0x0a];
  final name = _ctypeToCr[ctype];
  if (name == null) return null;
  return unicodeCrRanges[name];
}

/// Binary-search membership over a flat `[lo,hi,lo,hi,...]` sorted range list.
bool inRanges(int code, List<int> r) {
  var lo = 0;
  var hi = (r.length >> 1) - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final a = r[mid << 1];
    final b = r[(mid << 1) + 1];
    if (code < a) {
      hi = mid - 1;
    } else if (code > b) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

// -- \p{name} property resolution ------------------------------------------

Map<String, String>? _normIndex;

String _norm(String s) {
  final sb = StringBuffer();
  for (final c in s.codeUnits) {
    if (c == 0x20 || c == 0x2d || c == 0x5f) continue; // space, '-', '_'
    sb.writeCharCode((c >= 0x41 && c <= 0x5a) ? c + 0x20 : c);
  }
  return sb.toString();
}

/// A few common `\p{}` aliases not spelled exactly like a CR table.
const Map<String, String> _aliases = {
  'letter': 'L',
  'mark': 'M',
  'number': 'N',
  'punctuation': 'P',
  'symbol': 'S',
  'separator': 'Z',
  'other': 'C',
  'any': 'Any',
  'assigned': 'Assigned',
  'word': 'Word',
  'alphabetic': 'Alphabetic',
};

/// Ranges for a `\p{name}` property, or null if the name is unknown.
List<int>? unicodePropertyRanges(String rawName) {
  final idx = _normIndex ??= {
    for (final k in unicodeCrRanges.keys) _norm(k): k,
  };
  final n = _norm(rawName);
  final cr = idx[n] ?? _aliases[n];
  if (cr == null) return null;
  return unicodeCrRanges[cr] ??
      (idx[cr] != null ? unicodeCrRanges[idx[cr]!] : null);
}

// -- case folding ----------------------------------------------------------

/// Single code point → its case-fold equivalents (excluding itself), or empty.
List<int> unicodeFoldCodes(int code) => unicodeFold1[code] ?? const [];

/// `apply_all_case_fold` — invoke [f] for each single-char fold pair.
void unicodeApplyAllCaseFold(void Function(int from, List<int> to) f) {
  unicodeFold1.forEach(f);
}

// Union-find over fold1 to derive a canonical representative per
// case-equivalence class (used for case-insensitive single-char matching).
Map<int, int>? _rep;

int _find(Map<int, int> parent, int x) {
  var root = x;
  while (parent[root] != null && parent[root] != root) {
    root = parent[root]!;
  }
  // path-compress
  var c = x;
  while (parent[c] != null && parent[c] != root) {
    final nxt = parent[c]!;
    parent[c] = root;
    c = nxt;
  }
  return root;
}

void _union(Map<int, int> parent, int a, int b) {
  parent[a] ??= a;
  parent[b] ??= b;
  final ra = _find(parent, a);
  final rb = _find(parent, b);
  if (ra != rb) {
    // keep the smaller as root for determinism
    if (ra < rb) {
      parent[rb] = ra;
    } else {
      parent[ra] = rb;
    }
  }
}

Map<int, int> _buildRep() {
  final parent = <int, int>{};
  unicodeFold1.forEach((from, tos) {
    if (tos.length == 1) {
      _union(parent, from, tos[0]);
    } else {
      for (final t in tos) {
        _union(parent, from, t);
      }
    }
  });
  // flatten to representative map
  final rep = <int, int>{};
  for (final k in parent.keys) {
    rep[k] = _find(parent, k);
  }
  return rep;
}

/// Canonical case-fold representative of [code] (same class ⇒ same value).
/// Two code points match case-insensitively iff their reps are equal.
int caseFoldRep(int code) {
  final r = _rep ??= _buildRep();
  return r[code] ?? code;
}

Map<int, List<int>>? _classMembers;

/// All single-char case-equivalents of [code] (including itself).
List<int> caseFoldClassMembers(int code) {
  final r = _rep ??= _buildRep();
  final root = r[code] ?? code;
  final cm = _classMembers ??= _buildClassMembers(r);
  final members = cm[root];
  if (members == null) return [code];
  return members.contains(code) ? members : [code, ...members];
}

Map<int, List<int>> _buildClassMembers(Map<int, int> rep) {
  final m = <int, List<int>>{};
  rep.forEach((k, root) => (m[root] ??= <int>[]).add(k));
  return m;
}

// -- multi-char case folds (Folds2) ----------------------------------------

Map<int, List<int>>? _fold2Fwd; // (a<<21|b) -> single-char targets
Map<int, List<List<int>>>? _fold2Inv; // target -> list of [a,b] sequences

void _buildFold2() {
  final fwd = <int, List<int>>{};
  final inv = <int, List<List<int>>>{};
  var i = 0;
  while (i + 3 <= unicodeFold2.length) {
    final a = unicodeFold2[i], b = unicodeFold2[i + 1];
    final n = unicodeFold2[i + 2];
    if (i + 3 + n > unicodeFold2.length) break;
    final targets = unicodeFold2.sublist(i + 3, i + 3 + n);
    fwd[(a << 21) | b] = targets;
    for (final t in targets) {
      (inv[t] ??= <List<int>>[]).add([a, b]);
    }
    i += 3 + n;
  }
  _fold2Fwd = fwd;
  _fold2Inv = inv;
}

/// Single-char targets for the 2-char sequence [a],[b] (e.g. s,s → ß,ẞ), or null.
List<int>? fold2Forward(int a, int b) {
  _fold2Fwd ??= (() {
    _buildFold2();
    return _fold2Fwd!;
  })();
  return _fold2Fwd![(a << 21) | b];
}

/// Multi-char sequences equivalent to [code] (e.g. ß → [[s,s]]), or null.
List<List<int>>? fold2Inverse(int code) {
  if (_fold2Inv == null) _buildFold2();
  return _fold2Inv![code];
}

/// Every code point that has a multi-char case fold (e.g. ß, ﬀ) — the sources
/// used to expand an ignore-case character class into an alternation.
Iterable<int> multiCharFoldSources() {
  if (_fold2Inv == null) _buildFold2();
  return _fold2Inv!.keys;
}

// -- grapheme-cluster break (UAX#29) ---------------------------------------

/// Grapheme_Cluster_Break class ids (see egcb.g.dart header).
abstract final class Egcb {
  static const int other = 0;
  static const int cr = 1;
  static const int lf = 2;
  static const int control = 3;
  static const int extend = 4;
  static const int zwj = 5;
  static const int prepend = 6;
  static const int spacingMark = 7;
  static const int l = 8;
  static const int v = 9;
  static const int t = 10;
  static const int lv = 11;
  static const int lvt = 12;
  static const int regionalIndicator = 13;
}

/// Grapheme_Cluster_Break class of [code] (binary search over [egcbRanges]).
int unicodeEgcbClass(int code) {
  var lo = 0;
  var hi = (egcbRanges.length ~/ 3) - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final a = egcbRanges[mid * 3];
    final b = egcbRanges[mid * 3 + 1];
    if (code < a) {
      hi = mid - 1;
    } else if (code > b) {
      lo = mid + 1;
    } else {
      return egcbRanges[mid * 3 + 2];
    }
  }
  return Egcb.other;
}

/// UAX#29 Word_Break class ids (match wb.g.dart generator order).
abstract final class Wb {
  static const int any = 0;
  static const int aLetter = 1;
  static const int cr = 2;
  static const int doubleQuote = 3;
  static const int extend = 4;
  static const int extendNumLet = 5;
  static const int format = 6;
  static const int hebrewLetter = 7;
  static const int katakana = 8;
  static const int lf = 9;
  static const int midLetter = 10;
  static const int midNum = 11;
  static const int midNumLet = 12;
  static const int newline = 13;
  static const int numeric = 14;
  static const int regionalIndicator = 15;
  static const int singleQuote = 16;
  static const int wSegSpace = 17;
  static const int zwj = 18;
}

/// Word_Break class of [code] (binary search over [wbRanges]); 0 = Any.
int unicodeWbClass(int code) {
  var lo = 0;
  var hi = (wbRanges.length ~/ 3) - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final a = wbRanges[mid * 3];
    final b = wbRanges[mid * 3 + 1];
    if (code < a) {
      hi = mid - 1;
    } else if (code > b) {
      lo = mid + 1;
    } else {
      return wbRanges[mid * 3 + 2];
    }
  }
  return Wb.any;
}

List<int>? _extPict;

/// Extended_Pictographic membership (used by GB11).
bool unicodeIsExtendedPictographic(int code) {
  final r = _extPict ??= unicodeCrRanges['Extended_Pictographic'] ?? const [];
  return inRanges(code, r);
}
