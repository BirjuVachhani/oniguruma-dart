/// Search-start optimizer (`set_optimize_info_from_tree`, regcomp.c).
///
/// Computes where the engine should *attempt* matches, without changing which
/// strings match. A conservative but high-impact subset of the C analysis:
///   * `OPTIMIZE_STR`: a mandatory literal prefix at the match start; the
///     driver byte-searches for it instead of running the VM everywhere.
///   * `OPTIMIZE_MAP`: a 256-entry set of possible first bytes; the driver
///     skips positions whose byte can't begin a match.
///   * start anchors (`\A`, `\G`): attempt only at the search start.
/// Anything it can't prove stays [Optimize.none] (try every position), which is
/// always correct.
library;

import 'dart:typed_data';

import '../encoding/encoding.dart';
import '../onig_types.dart';
import '../parse/node.dart';
import '../regex.dart';
import '../unicode/unicode.dart' as uni;

void setOptimizeInfo(Regex reg, Node? root) {
  reg.optimize = Optimize.none;
  reg.anchor = 0;
  reg.distMin = 0;
  reg.distMax = infiniteLen;
  reg.leadingWordBoundary = false;
  reg.exactWholeMatch = false;
  reg.hasExactBack = false;
  reg.exactBackCtype = -1;
  reg.exactBackBs = null;
  reg.exactBackMb = null;
  if (root == null) return;

  // Flatten the leading concatenation.
  final head = <Node>[];
  _collectLeading(root, head);

  // Skip leading zero-width anchors; note a start-anchor.
  var i = 0;
  var otherLeadingAnchor = false;
  while (i < head.length && head[i] is AnchorNode) {
    final a = head[i] as AnchorNode;
    if (a.type == Anchor.beginBuf || a.type == Anchor.beginPosition) {
      reg.anchor |= a.type;
    } else {
      // `^`, `\b`, look-around, etc. before the body: these make the leading-`.*`
      // line-anchor fast path unsound, so remember to disable it.
      otherLeadingAnchor = true;
    }
    // A leading `\b`: every match must satisfy the word boundary at its start,
    // so the driver can skip mid-word positions (both neighbours word chars)
    // without entering the VM. Sound whatever else precedes/follows it: the
    // boundary is a zero-width test at the start position, evaluated first.
    if (a.type == Anchor.wordBoundary) reg.leadingWordBoundary = true;
    // any other zero-width anchor: keep scanning (dist stays 0)
    i++;
  }
  if (i >= head.length) return;

  final firstConsuming = head[i];

  // The literal-prefix / first-byte-map optimizations are byte-oriented and
  // assume an ASCII byte equals its code point (true for UTF-8, single-byte,
  // EUC, SJIS: all minLength 1). For wide encodings (UTF-16/32) an ASCII char
  // spans several bytes, so those maps would prune wrongly; skip them and let
  // the VM try every position. (Start anchors above still apply.)
  if (reg.enc.minLength != 1) return;

  // (1) mandatory literal prefix → OPTIMIZE_STR
  if (firstConsuming is StrNode &&
      firstConsuming.len > 0 &&
      !firstConsuming.st(NdSt.ignoreCase) &&
      !firstConsuming.isCrude) {
    _setExact(reg, Uint8List.fromList(firstConsuming.bytes), 0, 0);
    // The literal is the entire pattern (nothing after it, no capture, no
    // begin/other anchor) ⇒ a Sunday hit is the whole match; the driver can
    // fill the region directly and skip matchAt.
    reg.exactWholeMatch =
        i == head.length - 1 &&
        !otherLeadingAnchor &&
        reg.anchor == 0 &&
        reg.numMem == 0;
    return;
  }

  // (2) mandatory literal further in (a "middle exact") → OPTIMIZE_STR with a
  // distance range. The search then jumps between occurrences of that literal
  // and skips regions that can't contain it (e.g. `@` in `\w+@\w+`).
  //
  // Special case: a leading greedy `.*` / `.+` (ANCR_ANYCHAR_INF). Once the
  // exact literal is found, the leftmost match starts at the beginning of the
  // line containing it (or the whole buffer, for the newline-crossing `(?s).`
  // form), so the driver can anchor there instead of retrying every offset.
  final (anyChar, anyCharMl) = _leadingAnyCharStar(firstConsuming);
  var accMin = 0;
  var accMax = 0;
  for (var j = i; j < head.length; j++) {
    final node = head[j];
    if (node is StrNode &&
        node.len > 0 &&
        !node.st(NdSt.ignoreCase) &&
        !node.isCrude &&
        node.len >= 1) {
      _setExact(reg, Uint8List.fromList(node.bytes), accMin, accMax);
      reg.exactAnchorAnyChar = anyChar && !anyCharMl && !otherLeadingAnchor;
      reg.exactAnchorAnyCharMl = anyCharMl && !otherLeadingAnchor;
      // Walk-back candidate: the match is exactly `C+ L…` where the ONLY thing
      // before the exact `L` (here `node`) is the leading greedy `C+` (j==i+1),
      // and `L`'s first byte is not a member of C (so C+ stops right at L). Then
      // for each `L` the leftmost match starts at the head of the maximal C-run
      // ending at it: one matchAt instead of scanning the whole gap.
      if (j == i + 1 && !otherLeadingAnchor) {
        _setExactBack(reg, firstConsuming, node.bytes[0]);
      }
      return;
    }
    final (mn, mx) = _byteLen(node, reg.enc);
    accMin += mn;
    accMax = (accMax == infiniteLen || mx == infiniteLen)
        ? infiniteLen
        : accMax + mx;
    if (accMax == infiniteLen && accMin > 0) {
      // Past this point distances are unbounded; a later literal is still a
      // useful "must contain" filter: keep scanning for one.
    }
  }

  // (3) computable first-byte set → OPTIMIZE_MAP
  final map = Uint8List(256);
  // (3a) case-insensitive leading literal: the match can start with any case
  // fold of its first code point. Build a first-byte map over that fold class
  // so the driver skips positions that can't begin a match (e.g. `(?i)lorem`
  // only attempts at `l`/`L`), instead of running the fold-compare everywhere.
  final icStr = _leadingIcStr(firstConsuming);
  // (3a′) If every char of the leading ic literal folds only within ASCII (so
  // no multibyte subject char can match it), a byte-level case-insensitive
  // Sunday search jumps multiple bytes per step (like the plain-literal fast
  // path, instead of a byte-by-byte map scan). (`(?i)lorem` → skip on "lorem".)
  if (icStr != null && _setExactIc(reg, icStr)) return;
  if (icStr != null &&
      _icLeadingByteMap(icStr, map, reg.enc, reg.caseFoldFlag)) {
    reg.map = map;
    reg.optimize = Optimize.map;
    reg.distMin = 0;
    return;
  }
  if (_firstByteSet(firstConsuming, map, reg.enc)) {
    reg.map = map;
    reg.optimize = Optimize.map;
    reg.distMin = 0;
  }
}

/// Descend through leading option/capture/atomic groups (which don't change the
/// match's first byte) to the leading ignore-case [StrNode], or null. `(?i)abc`
/// parses as an option `BagNode` wrapping the string, so the string isn't the
/// bare head node.
StrNode? _leadingIcStr(Node node) {
  var n = node;
  while (true) {
    if (n is StrNode) {
      return (n.st(NdSt.ignoreCase) && !n.isCrude && n.len > 0) ? n : null;
    }
    if (n is BagNode &&
        n.body != null &&
        (n.type == BagType.option ||
            n.type == BagType.memory ||
            n.type == BagType.stopBacktrack)) {
      n = n.body!;
      continue;
    }
    if (n is ListNode) {
      n = n.car;
      continue;
    }
    return null;
  }
}

/// Fill [map] with the first byte of every case fold of the leading code point
/// of the ignore-case literal [node]. Returns false (→ no map) when it can't be
/// proven complete, notably when the first char participates in a *multi-char*
/// fold (`ß↔ss`), where a match could start with a different byte entirely.
bool _icLeadingByteMap(
  StrNode node,
  Uint8List map,
  OnigEncoding enc,
  int caseFoldFlag,
) {
  final b = node.bytes;
  if (b.isEmpty) return false;
  final firstLen = enc.length(b, 0, b.length);
  if (firstLen < 1) return false;
  final cp0 = enc.mbcToCode(b, 0, b.length);
  final multiChar = (caseFoldFlag & caseFoldMultiChar) != 0;
  if (multiChar) {
    // Inverse (single char ≡ a sequence, e.g. ß≡ss): match could start with
    // that sequence's first char → this first-byte set is incomplete. Bail.
    final inv = uni.fold2Inverse(cp0);
    if (inv != null && inv.isNotEmpty) return false;
    // Forward (first two chars fold to one, e.g. ss→ß): match could start with
    // the folded char, whose first byte differs. Bail.
    if (b.length > firstLen) {
      final cp1 = enc.mbcToCode(b, firstLen, b.length);
      if (uni.fold2Forward(cp0, cp1) != null) return false;
    }
  }
  final buf = Uint8List(8);
  bool set(int code) {
    final len = enc.codeToMbcLen(code);
    if (len < 1) return false;
    enc.codeToMbc(code, buf, 0);
    map[buf[0]] = 1;
    return true;
  }

  if (!set(cp0)) return false; // the literal char itself
  for (final m in uni.caseFoldClassMembers(cp0)) {
    if (!set(m)) return false;
  }
  return true;
}

/// Byte-length range `(min, max)` a node consumes (max may be [infiniteLen]).
(int, int) _byteLen(Node node, OnigEncoding enc) {
  switch (node) {
    case StrNode():
      // An ignore-case string can fold to shorter/longer forms per char
      // (e.g. `s` → `ſ` is 2 bytes), so its byte span is a range, not fixed.
      if (node.st(NdSt.ignoreCase) && !node.isCrude) {
        return _icStrByteLen(node, enc);
      }
      return (node.len, node.len);
    case CClassNode():
    case CtypeNode():
      return (1, node is CtypeNode && node.ctype == -1 ? infiniteLen : 6);
    case AnchorNode():
      return (0, 0);
    case QuantNode():
      final (bmn, bmx) = _byteLen(node.body!, enc);
      final lo = bmn * node.lower;
      final hi = (node.upper == infiniteRepeat || bmx == infiniteLen)
          ? infiniteLen
          : bmx * node.upper;
      return (lo, hi);
    case BagNode():
      if (node.type == BagType.memory ||
          node.type == BagType.option ||
          node.type == BagType.stopBacktrack) {
        return node.body == null ? (0, 0) : _byteLen(node.body!, enc);
      }
      return (0, infiniteLen);
    case ListNode():
      var lo = 0, hi = 0;
      Node? c = node;
      while (c is ListNode) {
        final (a, b) = _byteLen(c.car, enc);
        lo += a;
        hi = (hi == infiniteLen || b == infiniteLen) ? infiniteLen : hi + b;
        c = c.cdr;
      }
      if (c != null) {
        final (a, b) = _byteLen(c, enc);
        lo += a;
        hi = (hi == infiniteLen || b == infiniteLen) ? infiniteLen : hi + b;
      }
      return (lo, hi);
    default:
      return (0, infiniteLen);
  }
}

/// Per-char fold byte-length range of an ignore-case string (`s`→`ſ` widens it).
(int, int) _icStrByteLen(StrNode node, OnigEncoding enc) {
  final b = node.bytes;
  var lo = 0, hi = 0, i = 0;
  while (i < b.length) {
    final len = enc.length(b, i, b.length);
    final code = enc.mbcToCode(b, i, b.length);
    var mn = len, mx = len;
    for (final m in uni.caseFoldClassMembers(code)) {
      final ml = enc.codeToMbcLen(m);
      if (ml < 0) continue;
      if (ml < mn) mn = ml;
      if (ml > mx) mx = ml;
    }
    lo += mn;
    hi += mx;
    i += len;
  }
  return (lo, hi);
}

/// If [before] is a leading greedy `C+` over a single non-negated char class C
/// and the exact literal's first byte [exactByte] is not a member of C, record C
/// so the driver can walk back from an L occurrence to the C-run start (the
/// unique leftmost match candidate for that L). `L[0] ∉ C` guarantees C+ stops
/// exactly at L, so the maximal C-run before L is what C+ must consume.
void _setExactBack(Regex reg, Node before, int exactByte) {
  if (before is! QuantNode || !before.greedy || before.lower < 1) return;
  final body = before.body;
  if (body is CtypeNode) {
    if (body.ctype < 0 || body.not) return; // anychar / negated
    if (_ctypeHasByte(body, exactByte)) return; // L must not be in C
    reg.exactBackCtype = body.ctype;
    reg.exactBackCtypeAscii = body.asciiMode;
    reg.hasExactBack = true;
  } else if (body is CClassNode) {
    if (body.isNot) return; // negated (complement) → skip
    if (exactByte < 0x80 && body.bs.at(exactByte)) return; // L in C
    if (exactByte >= 0x80) return; // multibyte L head → be conservative
    reg.exactBackBs = body.bs;
    reg.exactBackMb = body.mbuf;
    reg.hasExactBack = true;
  }
}

bool _ctypeHasByte(CtypeNode c, int b) {
  if (b >= 0x80) return true; // multibyte lead → conservatively "maybe in C"
  return asciiIsCodeCtype(b, c.ctype);
}

/// Set up a case-insensitive Sunday search over the leading ic literal [icStr],
/// returning true on success. Only valid when EVERY char is ASCII and its fold
/// class is entirely ASCII (no multibyte fold member): then no multibyte
/// subject char can match, and since every UTF-8 multibyte byte is >= 0x80, a
/// byte-level fold (ASCII upper→lower) can never turn one into a needle byte, so
/// a byte search is exact. Bails when multi-char folding is enabled (ß↔ss etc.).
bool _setExactIc(Regex reg, StrNode icStr) {
  final enc = reg.enc;
  final multiChar = (reg.caseFoldFlag & caseFoldMultiChar) != 0;
  final b = icStr.bytes;
  // Decode to ASCII code points (any multibyte pattern char disqualifies).
  final cps = <int>[];
  var i = 0;
  while (i < b.length) {
    final len = enc.length(b, i, b.length);
    if (len != 1 || b[i] >= 0x80) return false;
    cps.add(b[i]);
    i += 1;
  }
  if (cps.isEmpty) return false;
  final folded = Uint8List(cps.length);
  for (var j = 0; j < cps.length; j++) {
    final cp = cps[j];
    // Every fold-class member must be ASCII, else a multibyte subject char
    // (e.g. ſ for s, Kelvin for k) could match and a byte search would miss it.
    for (final m in uni.caseFoldClassMembers(cp)) {
      if (m >= 0x80) return false;
    }
    // No char may participate in a multi-char fold (would let a single subject
    // char stand in for a needle substring, invisible to a byte search). This
    // is the compiler's `anyMulti` condition; for ASCII, only the forward
    // pair-fold can occur (e.g. `ss`←`ß`), inverse never (no ASCII char expands).
    if (multiChar) {
      if (j + 1 < cps.length && uni.fold2Forward(cp, cps[j + 1]) != null) {
        return false;
      }
      final inv = uni.fold2Inverse(cp);
      if (inv != null && inv.isNotEmpty) return false;
    }
    // Fold to ASCII-lower: the SAME convention the search's `_foldByte` uses
    // (not `enc.caseFoldRep`, whose rep may be upper-case: consistency between
    // needle and the folded hay is what matters; matchAt verifies the rest).
    folded[j] = (cp >= 0x41 && cp <= 0x5a) ? cp + 0x20 : cp;
  }
  final needle = folded;
  reg.exactIc = needle;
  reg.exactIcSkip = _buildSundaySkip(needle);
  reg.optimize = Optimize.strIc;
  reg.distMin = 0;
  reg.distMax = 0;
  return true;
}

/// Record an OPTIMIZE_STR exact-literal search plus a Sunday/BMH bad-char skip
/// table, so the driver can jump multiple bytes per step instead of scanning
/// byte-by-byte (`set_sunday_quick_search_or_bmh_skip_table`, regcomp.c).
void _setExact(Regex reg, Uint8List bytes, int distMin, int distMax) {
  reg.exact = bytes;
  reg.exactSkip = _buildSundaySkip(bytes);
  reg.optimize = Optimize.str;
  reg.distMin = distMin;
  reg.distMax = distMax;
}

/// Sunday quick-search bad-char table: `skip[b]` = how far to jump when the byte
/// one past the window is `b`. Default `len+1` (byte absent from needle); for a
/// needle byte the rightmost occurrence gives the smallest safe skip.
Uint16List _buildSundaySkip(Uint8List needle) {
  final n = needle.length;
  final def = (n + 1) > 0xffff ? 0xffff : n + 1;
  final skip = Uint16List(256);
  for (var b = 0; b < 256; b++) {
    skip[b] = def;
  }
  for (var j = 0; j < n; j++) {
    skip[needle[j]] = n - j;
  }
  return skip;
}

/// Is [node] a leading greedy infinite any-char repeat (`.*` / `.+`)? Returns
/// `(isAnyCharStar, matchesNewline)`. When true, a following exact literal lets
/// the driver anchor the match to the start of its line (`ANCR_ANYCHAR_INF`).
(bool, bool) _leadingAnyCharStar(Node node) {
  if (node is QuantNode &&
      node.greedy &&
      node.upper == infiniteRepeat &&
      node.body is CtypeNode &&
      (node.body as CtypeNode).ctype == -1) {
    return (true, node.body!.st(NdSt.multiLine));
  }
  return (false, false);
}

void _collectLeading(Node node, List<Node> out) {
  Node? cur = node;
  while (cur is ListNode) {
    out.add(cur.car);
    cur = cur.cdr;
  }
  if (cur != null) out.add(cur);
}

/// Fill [map] with every byte that could begin a match of [node] (which must be
/// mandatory, i.e. matches at least one char). Returns false if the set can't
/// be proven a proper subset (caller should not use the map).
bool _firstByteSet(Node node, Uint8List map, OnigEncoding enc) {
  switch (node) {
    case StrNode():
      if (node.len == 0 || node.st(NdSt.ignoreCase)) return false;
      map[node.bytes[0]] = 1;
      return true;
    case CClassNode():
      // Negated classes admit the complement (incl. MB lead bytes); bail.
      if (node.isNot) return false;
      var any = false;
      for (var b = 0; b < 256; b++) {
        if (node.bs.at(b)) {
          map[b] = 1;
          any = true;
        }
      }
      final hasMb = node.mbuf != null && !node.mbuf!.isEmpty;
      if (hasMb) {
        // Multibyte members present (e.g. `\d`/`\s`/`\p{L}` carry Unicode
        // ranges in mbuf): any could begin with a UTF-8 lead byte 0xC2..0xF4.
        // Set them all (complete over-approximation) for Unicode encodings;
        // legacy CJK multibyte lead ranges vary, so bail there.
        if (!enc.isUnicodeEncoding) return false;
        for (var b = 0xc2; b <= 0xf4; b++) {
          map[b] = 1;
        }
        any = true;
      }
      return any;
    case CtypeNode():
      // `\w`/`\d`/`\s` (and friends). Negated forms admit almost any byte, so
      // bail. Otherwise build a COMPLETE over-approximation of the first byte:
      // ASCII members directly, plus every byte that could begin a matching
      // non-ASCII char: for single-byte encodings the exact 0x80..0xFF members,
      // for UTF-8 all valid lead bytes 0xC2..0xF4 (covers any Unicode member).
      if (node.ctype < 0 || node.not) return false; // anychar/grapheme/negated
      var any = false;
      for (var b = 0; b < 0x80; b++) {
        if (asciiIsCodeCtype(b, node.ctype)) {
          map[b] = 1;
          any = true;
        }
      }
      if (node.asciiMode) {
        return any; // ASCII-only ctype: no multibyte members to admit
      }
      if (enc.isSingleByte) {
        for (var b = 0x80; b < 256; b++) {
          if (enc.isCodeCtype(b, node.ctype)) {
            map[b] = 1;
            any = true;
          }
        }
        return any;
      }
      if (enc.isUnicodeEncoding) {
        for (var b = 0xc2; b <= 0xf4; b++) {
          map[b] = 1;
        }
        return true;
      }
      return false; // legacy CJK multibyte: lead-byte ranges vary → bail
    case QuantNode():
      if (node.lower < 1) return false; // optional: first byte may be later
      return _firstByteSet(node.body!, map, enc);
    case BagNode():
      switch (node.type) {
        case BagType.memory:
        case BagType.option:
        case BagType.stopBacktrack:
          return node.body == null
              ? false
              : _firstByteSet(node.body!, map, enc);
        case BagType.ifElse:
          return false;
      }
    case AltNode():
      // union of all branches; all must be computable
      var cur = node as Node?;
      while (cur is AltNode) {
        if (!_firstByteSet(cur.car, map, enc)) return false;
        cur = cur.cdr;
      }
      if (cur != null && !_firstByteSet(cur, map, enc)) return false;
      return true;
    case ListNode():
      return _firstByteSet(node.car, map, enc);
    default:
      return false;
  }
}
