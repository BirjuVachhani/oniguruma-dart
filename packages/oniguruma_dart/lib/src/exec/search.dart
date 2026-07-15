/// Search driver (`onig_search` / `search_in_range`, regexec.c).
///
/// With `optimize == NONE` (P5) this tries each candidate start position in
/// `[start, range]`, advancing one character at a time, and returns the first
/// match. Compiled anchors make trying every position correct; the literal /
/// BMH / char-map fast starts (P9) only prune where matches are attempted.
library;

import 'dart:typed_data';

import '../callout.dart';
import '../encoding/encoding.dart';
import '../onig_types.dart';
import '../region.dart';
import '../regex.dart';
import 'executor.dart';
import 'nfa.dart';

/// One-entry Executor cache per [Regex], so a scan that calls [onigSearch] once
/// per match (the String API's `allMatches`, and the byte-API bench loop) does
/// not reallocate the Executor's stack + mem buffers on every match. Reuse is
/// gated on an identical subject + identical search params, and disabled when
/// callouts are in play (they can run user code that re-enters the same regex).
final Expando<_CachedExecutor> _executorCache = Expando<_CachedExecutor>();

class _CachedExecutor {
  final Executor ex;
  final Uint8List str;
  final int end;
  final int option;
  final int retryLimit;
  _CachedExecutor(this.ex, this.str, this.end, this.option, this.retryLimit);
}

/// `onig_search` — find the first match beginning in `[start, range]`.
/// Returns the match **start** byte offset, or [OnigResult.mismatch], or a
/// negative error code. Fills [region] on success.
int onigSearch(
  Regex reg,
  Uint8List str,
  int end,
  int start,
  int range,
  OnigRegion? region, {
  int retryLimit = defaultRetryLimit,
  int option = 0,
  CalloutRegistry? callouts,
}) {
  // Linear-time NFA fast path for the safe subset: forward, leftmost-first.
  // FIND_LONGEST needs longest-match semantics this Pike VM doesn't model, and
  // backward search (range < start) isn't supported — both fall through.
  final nfa = reg.nfa;
  final effOptions = option | reg.options;
  if (nfa != null && (effOptions & nfaUnsafeOptions) == 0 && range >= start) {
    return nfaSearch(nfa, reg, str, end, start, range, region, effOptions);
  }

  // Reuse a per-Regex Executor across a scan (same subject + params, no
  // callouts) to avoid reallocating its stack/mem buffers on every match.
  final Executor ex;
  if (callouts == null) {
    final cached = _executorCache[reg];
    if (cached != null &&
        identical(cached.str, str) &&
        cached.end == end &&
        cached.option == option &&
        cached.retryLimit == retryLimit) {
      ex = cached.ex..resetForReuse();
    } else {
      ex = Executor(reg, str, end, retryLimit: retryLimit, options: option);
      _executorCache[reg] = _CachedExecutor(ex, str, end, option, retryLimit);
    }
  } else {
    ex = Executor(
      reg,
      str,
      end,
      retryLimit: retryLimit,
      options: option,
      calloutRegistry: callouts,
    );
  }
  ex.msaStart = start; // \G anchors to the fixed original start

  final enc = reg.enc;

  // ONIG_OPTION_FIND_LONGEST: examine every start in [start, range] and return
  // the longest match (earliest start on ties). matchAt records bestLen/bestS
  // internally and always "fails" at OP_END so all alternatives are explored.
  if ((ex.options & OnigOption.findLongest) != 0) {
    var s = start;
    while (true) {
      final r = ex.matchAt(s, region);
      if (r < OnigResult.mismatch) return r; // error code
      if (s >= range) break;
      final len = enc.length(str, s, end);
      s += len < 1 ? 1 : len;
      if (s > range) break;
    }
    return ex.bestLen >= 0 ? ex.bestS : OnigResult.mismatch;
  }

  // \G / begin-position: the match can begin only at the search `start`
  // (both directions). Takes precedence over \A (regexec.c onig_search).
  if ((reg.anchor & Anchor.beginPosition) != 0) {
    final r = ex.matchAt(start, region);
    return r >= 0 ? start : (r < OnigResult.mismatch ? r : OnigResult.mismatch);
  }
  // \A / begin-buffer: the only candidate is the buffer head (position 0).
  // Forward search is valid only when it starts there; backward search only
  // when its range reaches there. Without this, a backward search (start=end)
  // would wrongly probe the end position where \A can never match.
  if ((reg.anchor & Anchor.beginBuf) != 0) {
    if (range > start) {
      if (start != 0) return OnigResult.mismatch;
    } else if (range > 0) {
      return OnigResult.mismatch;
    }
    final r = ex.matchAt(0, region);
    return r >= 0 ? 0 : (r < OnigResult.mismatch ? r : OnigResult.mismatch);
  }

  // Backward search (range < start): try each character head from `start` down
  // to `range`, returning the first (highest) match. Mirrors C `onig_search`
  // when the caller passes start=end, range=0.
  if (range < start) {
    var sb = start;
    while (true) {
      final r = ex.matchAt(sb, region);
      if (r >= 0) return sb;
      if (r < OnigResult.mismatch) return r;
      if (sb <= range) break;
      sb = enc.leftAdjustCharHead(str, range, sb - 1);
      if (sb < range) break;
    }
    return OnigResult.mismatch;
  }

  var s = start;

  switch (reg.optimize) {
    case Optimize.str:
      // Required-literal search: the match must contain reg.exact at a byte
      // distance in [distMin, distMax] from the start. A Sunday/BMH skip table
      // jumps multiple bytes per step to the next occurrence; then the candidate
      // start window for that occurrence is tried.
      final exact = reg.exact!;
      final skip = reg.exactSkip!;
      final distMin = reg.distMin;
      final distMax = reg.distMax;
      final anyChar = reg.exactAnchorAnyChar;
      final anyCharMl = reg.exactAnchorAnyCharMl;
      // Pure-literal fast path: the whole pattern is the exact literal, so a
      // Sunday hit at `found` IS the match — fill the region directly and skip
      // the per-match matchAt. Disabled under options that change OP_END
      // semantics (whole-string / not-empty; find-longest early-returns above).
      final wholeLit =
          reg.exactWholeMatch &&
          ((option | reg.options) &
                  (OnigOption.matchWholeString | OnigOption.findNotEmpty)) ==
              0;
      final hasBack = reg.hasExactBack;
      while (s <= range) {
        final found = _searchExact(str, exact, skip, s + distMin, end);
        if (found < 0) return OnigResult.mismatch;

        if (wholeLit) {
          if (found > range) return OnigResult.mismatch;
          if (region != null) {
            region.resize(1);
            region.beg[0] = found;
            region.end[0] = found + exact.length;
          }
          return found;
        }

        if (hasBack) {
          // The match is `C+ exact …`; walk back over C from `found` to the
          // run start — the unique leftmost candidate for this occurrence of
          // the exact — and try matchAt there once (not every gap position).
          var q = found;
          while (q > s) {
            final prev = enc.leftAdjustCharHead(str, s, q - 1);
            if (!_inBackClass(reg, enc.mbcToCode(str, prev, end), enc)) break;
            q = prev;
          }
          if (q <= range) {
            final r = ex.matchAt(q, region);
            if (r >= 0) return q;
            if (r < OnigResult.mismatch) return r;
          }
          s = found + 1; // this occurrence yields no match; jump to the next
          continue;
        }

        if (anyCharMl) {
          // Leading `(?s).*`: `.*` from `s` reaches any later occurrence, so a
          // single attempt at `s` is exhaustive for the whole remaining buffer.
          final r = ex.matchAt(s, region);
          if (r >= 0) return s;
          return r < OnigResult.mismatch ? r : OnigResult.mismatch;
        }
        if (anyChar) {
          // Leading `.*` (`.`≠newline, ANCR_ANYCHAR_INF): the leftmost match
          // starts at the head of `found`'s line (clamped to >= s). matchAt
          // there is exhaustive for that line; on failure skip past the line
          // instead of retrying every offset.
          final cand = _lineStart(str, found, s, enc, end);
          final r = ex.matchAt(cand, region);
          if (r >= 0) return cand;
          if (r < OnigResult.mismatch) return r;
          final nl = _nextLineStart(str, found, end, enc);
          if (nl > range) return OnigResult.mismatch;
          s = nl;
          continue;
        }

        var lo = (distMax == infiniteLen) ? s : (found - distMax);
        if (lo < s) lo = s;
        var hi = found - distMin;
        if (hi > range) hi = range;
        if (hi < lo) {
          s = found + 1;
          continue;
        }
        var cand = lo;
        while (cand <= hi) {
          final r = ex.matchAt(cand, region);
          if (r >= 0) return cand;
          if (r < OnigResult.mismatch) return r;
          final len = enc.length(str, cand, end);
          cand += len < 1 ? 1 : len;
        }
        s = hi + 1;
      }
      return OnigResult.mismatch;

    case Optimize.map:
      final map = reg.map!;
      final wordStart = reg.leadingWordBoundary;
      while (s <= range) {
        // Tight skip over a run of ASCII bytes that can't begin a match — no
        // virtual `enc.length` per byte (map-optimized regexes always use a
        // minLength==1 encoding, so an ASCII byte is exactly one char). This is
        // our analog of V8's SkipUntilBitInTable.
        var b = 0;
        while (s < end && s <= range && (b = str[s]) < 0x80 && map[b] == 0) {
          s++;
        }
        if (s > range) break;
        // A multibyte char whose lead byte isn't in the map: skip by its length.
        if (s < end && map[str[s]] == 0) {
          final len = enc.length(str, s, end);
          s += len < 1 ? 1 : len;
          continue;
        }
        // Leading `\b`: when this candidate and the byte before it are both
        // ASCII word chars, the boundary is provably false here, so matchAt
        // would mismatch without consuming — skip it without entering the VM.
        // (Both ASCII ⇒ single-byte, so advancing by 1 stays on a char head.)
        if (wordStart &&
            s > 0 &&
            s < end &&
            (b = str[s]) < 0x80 &&
            _asciiWord(b)) {
          final p = str[s - 1];
          if (p < 0x80 && _asciiWord(p)) {
            s++;
            continue;
          }
        }
        final r = ex.matchAt(s, region);
        if (r >= 0) return s;
        if (r < OnigResult.mismatch) return r;
        if (s >= range) break;
        final len = enc.length(str, s, end);
        s += len < 1 ? 1 : len;
      }
      return OnigResult.mismatch;

    case Optimize.strIc:
      // Case-insensitive Sunday search: jump multiple bytes per step to the next
      // folded occurrence of the needle (built for a leading ic literal whose
      // fold class is ASCII-only), then verify + capture with matchAt.
      final needle = reg.exactIc!;
      final skip = reg.exactIcSkip!;
      while (s <= range) {
        final found = _searchExactIc(str, needle, skip, s, end);
        if (found < 0 || found > range) return OnigResult.mismatch;
        final r = ex.matchAt(found, region);
        if (r >= 0) return found;
        if (r < OnigResult.mismatch) return r;
        s = found + 1;
      }
      return OnigResult.mismatch;

    default:
      while (true) {
        final r = ex.matchAt(s, region);
        if (r >= 0) return s;
        if (r < OnigResult.mismatch) return r;
        if (s >= range) break;
        final len = enc.length(str, s, end);
        s += len < 1 ? 1 : len;
        if (s > range) break;
      }
      return OnigResult.mismatch;
  }
}

/// ASCII upper→lower fold of a single byte (non-ASCII bytes pass through, so a
/// UTF-8 multibyte byte — always >= 0x80 — never folds into a needle byte).
int _foldByte(int b) => (b >= 0x41 && b <= 0x5a) ? b + 0x20 : b;

/// Is code point [code] a member of the recorded leading class C (for the
/// `C+ exact…` walk-back)? Mirrors the executor's ctype / char-class test.
bool _inBackClass(Regex reg, int code, OnigEncoding enc) {
  final ct = reg.exactBackCtype;
  if (ct >= 0) {
    if (reg.exactBackCtypeAscii || code < 0x80) {
      return asciiIsCodeCtype(code, ct);
    }
    return enc.isCodeCtype(code, ct);
  }
  final bs = reg.exactBackBs;
  if (bs != null &&
      (code < 0x80 || (enc.isSingleByte && code < 0x100)) &&
      bs.at(code)) {
    return true;
  }
  final mb = reg.exactBackMb;
  return mb != null && mb.contains(code);
}

/// Leftmost index in `[from, end)` where [needle] matches case-insensitively
/// (both sides ASCII-folded), or -1, using a Sunday skip over folded bytes.
int _searchExactIc(
  Uint8List hay,
  Uint8List needle,
  Uint16List skip,
  int from,
  int end,
) {
  final n = needle.length;
  if (n == 0) return from <= end ? from : -1;
  final last = end - n;
  var i = from < 0 ? 0 : from;
  if (i > last) return -1;
  final first = needle[0];
  final lastByte = needle[n - 1];
  while (true) {
    if (_foldByte(hay[i]) == first && _foldByte(hay[i + n - 1]) == lastByte) {
      var k = 1;
      while (k < n - 1 && _foldByte(hay[i + k]) == needle[k]) {
        k++;
      }
      if (k >= n - 1) return i;
    }
    final nextPos = i + n;
    if (nextPos >= end) return -1;
    i += skip[_foldByte(hay[nextPos])];
    if (i > last) return -1;
  }
}

/// ASCII word char (`[0-9A-Za-z_]`) — the `\w` membership test used by the
/// leading-`\b` word-start skip (byte already known to be `< 0x80`).
bool _asciiWord(int b) =>
    (b >= 0x30 && b <= 0x39) || // 0-9
    (b >= 0x41 && b <= 0x5a) || // A-Z
    (b >= 0x61 && b <= 0x7a) || // a-z
    b == 0x5f; // _

/// Leftmost index of [needle] in [hay] within `[from, end)`, or -1, using
/// Sunday quick search with the precomputed bad-char [skip] table (jumps up to
/// `needle.length + 1` bytes per mismatch instead of scanning one at a time).
int _searchExact(
  Uint8List hay,
  Uint8List needle,
  Uint16List skip,
  int from,
  int end,
) {
  final n = needle.length;
  if (n == 0) return from <= end ? from : -1;
  final last = end - n; // last valid start offset
  var i = from < 0 ? 0 : from;
  if (i > last) return -1;
  final first = needle[0];
  final lastByte = needle[n - 1];
  while (true) {
    if (hay[i] == first && hay[i + n - 1] == lastByte) {
      var k = 1;
      while (k < n - 1 && hay[i + k] == needle[k]) {
        k++;
      }
      if (k >= n - 1) return i; // all middle bytes matched (n == 1 → k=1>=0)
    }
    final nextPos = i + n; // byte just past the window
    if (nextPos >= end) return -1;
    i += skip[hay[nextPos]];
    if (i > last) return -1;
  }
}

/// Head of the line containing byte offset [found], clamped to `>= floor`: walk
/// back to just after the previous newline (or `floor`). Used by the leading-`.*`
/// anchor (the match starts at its line head).
int _lineStart(Uint8List str, int found, int floor, OnigEncoding enc, int end) {
  var p = found;
  while (p > floor) {
    final prev = enc.leftAdjustCharHead(str, floor, p - 1);
    if (enc.isMbcNewline(str, prev, end)) break;
    p = prev;
  }
  return p;
}

/// Start of the line after the one containing [found] (the offset just past the
/// next newline at/after [found]), or `> range`-signalling `end + 1` if none.
int _nextLineStart(Uint8List str, int found, int end, OnigEncoding enc) {
  var p = found;
  while (p < end) {
    if (enc.isMbcNewline(str, p, end)) {
      final len = enc.length(str, p, end);
      return p + (len < 1 ? 1 : len);
    }
    final len = enc.length(str, p, end);
    p += len < 1 ? 1 : len;
  }
  return end + 1;
}

/// `onig_match` — attempt a match anchored exactly at [at] (no scanning).
int onigMatch(
  Regex reg,
  Uint8List str,
  int end,
  int at,
  OnigRegion? region, {
  int retryLimit = defaultRetryLimit,
  int option = 0,
}) {
  final ex = Executor(reg, str, end, retryLimit: retryLimit, options: option)
    ..msaStart = at;
  final r = ex.matchAt(at, region);
  if (r >= 0) return r - at; // C returns matched byte length
  return r;
}
