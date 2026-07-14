/// Search-start optimizer (`set_optimize_info_from_tree`, regcomp.c).
///
/// Computes where the engine should *attempt* matches, without changing which
/// strings match. A conservative but high-impact subset of the C analysis:
///   * `OPTIMIZE_STR`  — a mandatory literal prefix at the match start; the
///     driver byte-searches for it instead of running the VM everywhere.
///   * `OPTIMIZE_MAP`  — a 256-entry set of possible first bytes; the driver
///     skips positions whose byte can't begin a match.
///   * start anchors (`\A`, `\G`) — attempt only at the search start.
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
    // any other zero-width anchor: keep scanning (dist stays 0)
    i++;
  }
  if (i >= head.length) return;

  final firstConsuming = head[i];

  // The literal-prefix / first-byte-map optimizations are byte-oriented and
  // assume an ASCII byte equals its code point (true for UTF-8, single-byte,
  // EUC, SJIS — all minLength 1). For wide encodings (UTF-16/32) an ASCII char
  // spans several bytes, so those maps would prune wrongly; skip them and let
  // the VM try every position. (Start anchors above still apply.)
  if (reg.enc.minLength != 1) return;

  // (1) mandatory literal prefix → OPTIMIZE_STR
  if (firstConsuming is StrNode &&
      firstConsuming.len > 0 &&
      !firstConsuming.st(NdSt.ignoreCase) &&
      !firstConsuming.isCrude) {
    _setExact(reg, Uint8List.fromList(firstConsuming.bytes), 0, 0);
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
      return;
    }
    final (mn, mx) = _byteLen(node, reg.enc);
    accMin += mn;
    accMax = (accMax == infiniteLen || mx == infiniteLen)
        ? infiniteLen
        : accMax + mx;
    if (accMax == infiniteLen && accMin > 0) {
      // Past this point distances are unbounded; a later literal is still a
      // useful "must contain" filter — keep scanning for one.
    }
  }

  // (3) computable first-byte set → OPTIMIZE_MAP
  final map = Uint8List(256);
  // (3a) case-insensitive leading literal: the match can start with any case
  // fold of its first code point. Build a first-byte map over that fold class
  // so the driver skips positions that can't begin a match (e.g. `(?i)lorem`
  // only attempts at `l`/`L`), instead of running the fold-compare everywhere.
  final icStr = _leadingIcStr(firstConsuming);
  if (icStr != null &&
      _icLeadingByteMap(icStr, map, reg.enc, reg.caseFoldFlag)) {
    reg.map = map;
    reg.optimize = Optimize.map;
    reg.distMin = 0;
    return;
  }
  if (_firstByteSet(firstConsuming, map)) {
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
/// proven complete — notably when the first char participates in a *multi-char*
/// fold (`ß↔ss`), where a match could start with a different byte entirely.
bool _icLeadingByteMap(
    StrNode node, Uint8List map, OnigEncoding enc, int caseFoldFlag) {
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
/// mandatory — i.e. matches at least one char). Returns false if the set can't
/// be proven a proper subset (caller should not use the map).
bool _firstByteSet(Node node, Uint8List map) {
  switch (node) {
    case StrNode():
      if (node.len == 0 || node.st(NdSt.ignoreCase)) return false;
      map[node.bytes[0]] = 1;
      return true;
    case CClassNode():
      if (node.mbuf != null && !node.mbuf!.isEmpty) return false; // MB: skip
      var any = false;
      for (var b = 0; b < 256; b++) {
        final inSet = node.bs.at(b);
        final member = node.isNot ? !inSet : inSet;
        if (member) {
          map[b] = 1;
          any = true;
        }
      }
      // A negated class over multibyte would also admit MB lead bytes; only
      // trust the map for single-byte-safe cases.
      return any && !node.isNot;
    case CtypeNode():
      if (node.ctype == -1) return false; // anychar
      // ASCII members of the ctype (Unicode extends this in P6 → skip then).
      return false;
    case QuantNode():
      if (node.lower < 1) return false; // optional: first byte may be later
      return _firstByteSet(node.body!, map);
    case BagNode():
      switch (node.type) {
        case BagType.memory:
        case BagType.option:
        case BagType.stopBacktrack:
          return node.body == null ? false : _firstByteSet(node.body!, map);
        case BagType.ifElse:
          return false;
      }
    case AltNode():
      // union of all branches; all must be computable
      var cur = node as Node?;
      while (cur is AltNode) {
        if (!_firstByteSet(cur.car, map)) return false;
        cur = cur.cdr;
      }
      if (cur != null && !_firstByteSet(cur, map)) return false;
      return true;
    case ListNode():
      return _firstByteSet(node.car, map);
    default:
      return false;
  }
}
