/// The matching VM (`match_at`, regexec.c): interprets the compiled
/// [Operation] stream against the subject with an explicit backtrack stack.
///
/// Ported from the `switch`-dispatch (non-direct-threaded) variant. All string
/// positions are `int` byte offsets into the subject `Uint8List`; captures are
/// tracked in [memStart]/[memEnd] with save/restore on the [MatchStack].
library;

import 'dart:typed_data';

import '../callout.dart';
import '../compile/operation.dart';
import '../encoding/encoding.dart';
import '../onig_errors.dart';
import '../onig_types.dart';
import '../parse/node.dart' show BitSet, CodeRangeBuffer;
import '../region.dart';
import '../regex.dart';
import '../unicode/unicode.dart' as uni;
import 'stack.dart';

/// Default catastrophic-backtracking guard (`retry_limit_in_match`; 0 = off).
const int defaultRetryLimit = 0;

class Executor {
  final Regex reg;
  final List<Operation> ops;

  // Flattened bytecode (reg.flat) — the hot loop reads interleaved scalar fields
  // from [sc] (op `i`'s fields at `sc[i*stride + offset]`, one cache line per op)
  // and object payloads from the parallel lists, instead of dereferencing an
  // Operation object per instruction.
  final Int32List sc; // interleaved scalar fields
  final List<Uint8List?> opStr;
  final List<BitSet?> opBs;
  final List<CodeRangeBuffer?> opMb;
  final List<List<int>?> opNs;
  final OnigEncoding enc;

  /// Cached [OnigEncoding.isAsciiFast]: when true, a byte `< 0x80` at a char
  /// head is a standalone ASCII char, so hot ops skip the virtual decode.
  final bool asciiFast;
  final Uint8List str; // subject bytes (offset 0 == buffer start)
  final int end;

  final MatchStack stk = MatchStack();
  late final Int32List memStart; // last completed capture start per group
  late final Int32List memEnd; // last completed capture end per group
  late final List<List<int>> _openStart; // open (unclosed) starts per group
  late final Int32List emptyCheckStk;
  late final Int32List repeatStk; // current count per OP_REPEAT id

  int retryLimit;

  /// Runtime match options (`ONIG_OPTION_*`: NOTBOL/NOTEOL/NOT_BEGIN_STRING…).
  int options;

  /// Callout callback registry (built-ins + user-registered).
  CalloutRegistry calloutRegistry;

  final Map<int, int> _calloutCounters = {};

  /// `[tag] → callout id` for every tagged callout op, built once on demand so
  /// a callout (e.g. `(*CMP{AB,…})`) can read another's counter by tag.
  Map<String, int>? _tagToIdCache;
  Map<String, int> get _calloutTagToId {
    var m = _tagToIdCache;
    if (m == null) {
      m = <String, int>{};
      for (final o in ops) {
        if ((o.opcode == Op.calloutName || o.opcode == Op.calloutContents) &&
            o.calloutTag != null) {
          m[o.calloutTag!] = o.id;
        }
      }
      _tagToIdCache = m;
    }
    return m;
  }

  int _retryCount = 0;
  int _keep = -1; // \K : overrides the match start when >= 0
  int _callNest = 0;
  static const int _callMaxNest = 4096; // recursion guard
  int _rightRange = 0; // match right boundary (used by variable look-behind)

  // ONIG_OPTION_FIND_LONGEST: best match length / start seen across the whole
  // search (persists across matchAt calls, like msa->best_len / best_s).
  int bestLen = OnigResult.mismatch;
  int bestS = -1;

  /// The original search start (`msa->start`), fixed across the whole search —
  /// `\G` (CHECK_POSITION SEARCH_START) matches only here, not at each candidate.
  int msaStart = 0;

  Executor(
    this.reg,
    this.str,
    this.end, {
    this.retryLimit = defaultRetryLimit,
    this.options = 0,
    CalloutRegistry? calloutRegistry,
  }) : ops = reg.ops,
       sc = reg.flat.scalars,
       opStr = reg.flat.str,
       opBs = reg.flat.bs,
       opMb = reg.flat.mb,
       opNs = reg.flat.ns,
       enc = reg.enc,
       asciiFast = reg.enc.isAsciiFast,
       calloutRegistry = calloutRegistry ?? defaultCalloutRegistry {
    // `msa.options = arg_option | reg->options` (regexec.c MATCH_ARG_INIT):
    // the runtime option set is the search option merged with the compile
    // options stored on the regex (NOTBOL/NOTEOL etc. may come from either).
    options |= reg.options;
    memStart = Int32List(reg.numMem + 1);
    memEnd = Int32List(reg.numMem + 1);
    _openStart = List.generate(reg.numMem + 1, (_) => <int>[]);
    emptyCheckStk = Int32List(reg.numEmptyCheck == 0 ? 1 : reg.numEmptyCheck);
    repeatStk = Int32List(reg.numRepeat == 0 ? 1 : reg.numRepeat);
  }

  /// Attempt a match anchored at [sstart]; returns the match END byte offset,
  /// or [OnigResult.mismatch]. On success [region] (if non-null) is filled.
  int matchAt(int sstart, OnigRegion? region) {
    stk.reset();
    for (var i = 0; i <= reg.numMem; i++) {
      memStart[i] = OnigRegion.notFound;
      memEnd[i] = OnigRegion.notFound;
      if (_openStart[i].isNotEmpty) _openStart[i].clear();
    }
    _retryCount = 0;
    _keep = -1;
    _callNest = 0;
    _rightRange = end;
    if (_calloutCounters.isNotEmpty) _calloutCounters.clear();

    var pc = 0;
    var s = sstart;

    // Main dispatch loop. `fail:` is emulated by calling _backtrack().
    while (true) {
      final base = pc * FlatOps.stride;
      switch (sc[base + FlatOps.oOpcode]) {
        case Op.finish:
          return OnigResult.mismatch;

        case Op.end:
          // MATCH_WHOLE_STRING: the match must reach end-of-string.
          if ((options & OnigOption.matchWholeString) != 0 && s != end) {
            break;
          }
          // FIND_NOT_EMPTY: reject a zero-length match (retry elsewhere).
          if (s - sstart == 0 && (options & OnigOption.findNotEmpty) != 0) {
            break;
          }
          // FIND_LONGEST: don't return; record the longest match and keep
          // exploring (regexec.c OP_END). The search driver returns bestS.
          if ((options & OnigOption.findLongest) != 0) {
            final n = s - sstart;
            if (n > bestLen) {
              bestLen = n;
              bestS = sstart;
              _fillRegion(region, sstart, s);
            }
            break;
          }
          _fillRegion(region, sstart, s);
          return s;

        case Op.str1:
          if (s < _rightRange && str[s] == opStr[pc]![0]) {
            s++;
            pc++;
            continue;
          }
          break;

        case Op.str2:
          if (s + 2 <= _rightRange &&
              str[s] == opStr[pc]![0] &&
              str[s + 1] == opStr[pc]![1]) {
            s += 2;
            pc++;
            continue;
          }
          break;

        case Op.str3:
          if (s + 3 <= _rightRange &&
              str[s] == opStr[pc]![0] &&
              str[s + 1] == opStr[pc]![1] &&
              str[s + 2] == opStr[pc]![2]) {
            s += 3;
            pc++;
            continue;
          }
          break;

        case Op.str4:
          if (s + 4 <= _rightRange &&
              str[s] == opStr[pc]![0] &&
              str[s + 1] == opStr[pc]![1] &&
              str[s + 2] == opStr[pc]![2] &&
              str[s + 3] == opStr[pc]![3]) {
            s += 4;
            pc++;
            continue;
          }
          break;

        case Op.str5:
          if (s + 5 <= _rightRange &&
              str[s] == opStr[pc]![0] &&
              str[s + 1] == opStr[pc]![1] &&
              str[s + 2] == opStr[pc]![2] &&
              str[s + 3] == opStr[pc]![3] &&
              str[s + 4] == opStr[pc]![4]) {
            s += 5;
            pc++;
            continue;
          }
          break;

        case Op.strN:
          {
            if (sc[base + FlatOps.oFlag] == 2) {
              // code-point case-insensitive compare (opNs[pc] = pattern reps)
              final reps = opNs[pc]!;
              var q = s;
              var ok = true;
              for (var k = 0; k < reps.length; k++) {
                if (q >= _rightRange) {
                  ok = false;
                  break;
                }
                final code = enc.mbcToCode(str, q, end);
                if (enc.caseFoldRep(code) != reps[k]) {
                  ok = false;
                  break;
                }
                q += enc.length(str, q, end);
              }
              if (ok) {
                s = q;
                pc++;
                continue;
              }
              break;
            }
            final n = sc[base + FlatOps.oStrLen];
            if (s + n <= _rightRange &&
                _matchBytes(opStr[pc]!, s, n, sc[base + FlatOps.oFlag] == 1)) {
              s += n;
              pc++;
              continue;
            }
            break;
          }

        case Op.cclass:
          if (s < _rightRange) {
            // Decode the code point so ASCII members match in wide encodings
            // (UTF-16/32), where a single char spans several bytes. For an
            // ASCII byte in an ASCII-compatible encoding, code == byte and
            // len == 1 — skip the two virtual encoding calls.
            final int len;
            final int code;
            final b = str[s];
            if (b < 0x80 && asciiFast) {
              code = b;
              len = 1;
            } else {
              len = enc.length(str, s, end);
              code = enc.mbcToCode(str, s, end);
            }
            if (code < 0x80 || (enc.isSingleByte && code < 0x100)) {
              if (opBs[pc]!.at(code)) {
                s += len;
                pc++;
                continue;
              }
            }
          }
          break;

        case Op.cclassNot:
          if (s < _rightRange) {
            final int len;
            final int code;
            final b = str[s];
            if (b < 0x80 && asciiFast) {
              code = b;
              len = 1;
            } else {
              len = enc.length(str, s, end);
              code = enc.mbcToCode(str, s, end);
            }
            final single = code < 0x80 || (enc.isSingleByte && code < 0x100);
            final inSet = single && opBs[pc]!.at(code);
            if (!inSet) {
              s += len;
              pc++;
              continue;
            }
          }
          break;

        // Mixed / multibyte classes: membership is decided by the CODE POINT
        // (bitset for < 0x80 / single-byte, mbuf otherwise) — not the byte
        // length, so ASCII members match in wide encodings (UTF-16/32).
        case Op.cclassMb:
        case Op.cclassMix:
          if (s < _rightRange) {
            final int len;
            final int code;
            final b = str[s];
            if (b < 0x80 && asciiFast) {
              code = b;
              len = 1;
            } else {
              len = enc.length(str, s, end);
              code = enc.mbcToCode(str, s, end);
            }
            if (_ccMember(opBs[pc], opMb[pc], code)) {
              s += len;
              pc++;
              continue;
            }
          }
          break;

        case Op.cclassMbNot:
        case Op.cclassMixNot:
          if (s < _rightRange) {
            final int len;
            final int code;
            final b = str[s];
            if (b < 0x80 && asciiFast) {
              code = b;
              len = 1;
            } else {
              len = enc.length(str, s, end);
              code = enc.mbcToCode(str, s, end);
            }
            if (!_ccMember(opBs[pc], opMb[pc], code)) {
              s += len;
              pc++;
              continue;
            }
          }
          break;

        case Op.anychar:
          if (s < _rightRange) {
            final b = str[s];
            final len = (b < 0x80 && asciiFast) ? 1 : enc.length(str, s, end);
            if (!enc.isMbcNewline(str, s, end)) {
              s += len;
              pc++;
              continue;
            }
          }
          break;

        case Op.extendedGraphemeCluster:
          if (s < _rightRange) {
            s = sc[base + FlatOps.oFlag] == TextSegmentBoundaryType.word
                ? _wordSegmentEnd(s)
                : _graphemeEnd(s);
            pc++;
            continue;
          }
          break;

        case Op.anycharMl:
          if (s < _rightRange) {
            final b = str[s];
            s += (b < 0x80 && asciiFast) ? 1 : enc.length(str, s, end);
            pc++;
            continue;
          }
          break;

        case Op.word:
        case Op.wordAscii:
          if (s < _rightRange) {
            final b = str[s];
            final int code;
            final int len;
            if (b < 0x80 && asciiFast) {
              code = b;
              len = 1;
            } else {
              code = enc.mbcToCode(str, s, end);
              len = enc.length(str, s, end);
            }
            if (_isWord(code, sc[base + FlatOps.oOpcode] == Op.wordAscii)) {
              s += len;
              pc++;
              continue;
            }
          }
          break;

        case Op.noWord:
        case Op.noWordAscii:
          if (s < _rightRange) {
            final b = str[s];
            final int code;
            final int len;
            if (b < 0x80 && asciiFast) {
              code = b;
              len = 1;
            } else {
              code = enc.mbcToCode(str, s, end);
              len = enc.length(str, s, end);
            }
            if (!_isWord(code, sc[base + FlatOps.oOpcode] == Op.noWordAscii)) {
              s += len;
              pc++;
              continue;
            }
          }
          break;

        case Op.wordBoundary:
          if (_wordBoundary(s, sc[base + FlatOps.oFlag] == 1)) {
            pc++;
            continue;
          }
          break;

        case Op.noWordBoundary:
          if (!_wordBoundary(s, sc[base + FlatOps.oFlag] == 1)) {
            pc++;
            continue;
          }
          break;

        case Op.wordBegin:
          if (_wordBegin(s, sc[base + FlatOps.oFlag] == 1)) {
            pc++;
            continue;
          }
          break;

        case Op.wordEnd:
          if (_wordEnd(s, sc[base + FlatOps.oFlag] == 1)) {
            pc++;
            continue;
          }
          break;

        case Op.textSegmentBoundary:
          {
            final boundary = sc[base + FlatOps.oFlag] == TextSegmentBoundaryType.word
                ? _wordBoundaryAt(s)
                : _isGraphemeBoundary(s);
            if (boundary != (sc[base + FlatOps.oFlag2] == 1)) {
              pc++;
              continue;
            }
            break;
          }

        case Op.beginBuf:
          // \A : fails if NOTBOL or NOT_BEGIN_STRING (regexec.c BEGIN_BUF).
          if (s == 0 &&
              (options & OnigOption.notBol) == 0 &&
              (options & OnigOption.notBeginString) == 0) {
            pc++;
            continue;
          }
          break;

        case Op.endBuf:
          // \z : fails if NOTEOL or NOT_END_STRING (regexec.c END_BUF).
          if (s == end &&
              (options & OnigOption.notEol) == 0 &&
              (options & OnigOption.notEndString) == 0) {
            pc++;
            continue;
          }
          break;

        case Op.beginLine:
          // ^ : at string begin (fails under NOTBOL) or right after a newline;
          // never at end-of-string (regexec.c BEGIN_LINE: `else if (!ON_STR_END(s))`).
          if (s == 0) {
            if ((options & OnigOption.notBol) == 0) {
              pc++;
              continue;
            }
          } else if (s != end && _prevIsNewline(s)) {
            pc++;
            continue;
          }
          break;

        case Op.endLine:
          if (s == end) {
            if ((options & OnigOption.notEol) == 0) {
              pc++;
              continue;
            }
          } else if (_isNewlineAt(s)) {
            pc++;
            continue;
          }
          break;

        case Op.semiEndBuf:
          // \Z : end-of-string, or the newline that is the final char.
          // Both cases fail under NOTEOL / NOT_END_STRING (regexec.c
          // SEMI_END_BUF, with USE_NEWLINE_AT_END_OF_STRING_HAS_EMPTY_LINE).
          if (s == end) {
            if ((options & OnigOption.notEol) == 0 &&
                (options & OnigOption.notEndString) == 0) {
              pc++;
              continue;
            }
            break;
          }
          if (_isNewlineAt(s) && s + enc.length(str, s, end) == end) {
            if ((options & OnigOption.notEol) == 0 &&
                (options & OnigOption.notEndString) == 0) {
              pc++;
              continue;
            }
          }
          break;

        case Op.checkPosition:
          if (sc[base + FlatOps.oFlag] == CheckPositionType.searchStart) {
            // \G : the original search start, and not under NOT_BEGIN_POSITION.
            if (s == msaStart && (options & OnigOption.notBeginPosition) == 0) {
              pc++;
              continue;
            }
          } else if (sc[base + FlatOps.oFlag] == CheckPositionType.currentRightRange) {
            if (s == _rightRange) {
              pc++;
              continue;
            }
          }
          break;

        case Op.backref1:
          {
            final r = _matchBackref(1, s, sc[base + FlatOps.oFlag] == 1);
            if (r >= 0) {
              s = r;
              pc++;
              continue;
            }
            break;
          }

        case Op.backref2:
          {
            final r = _matchBackref(2, s, sc[base + FlatOps.oFlag] == 1);
            if (r >= 0) {
              s = r;
              pc++;
              continue;
            }
            break;
          }

        case Op.backrefN:
          {
            final r = _matchBackref(sc[base + FlatOps.oMem], s, sc[base + FlatOps.oFlag] == 1);
            if (r >= 0) {
              s = r;
              pc++;
              continue;
            }
            break;
          }

        case Op.backrefMulti:
          {
            var matched = -1;
            for (final g in opNs[pc]!) {
              final r = _matchBackref(g, s, sc[base + FlatOps.oFlag] == 1);
              if (r >= 0) {
                matched = r;
                break;
              }
            }
            if (matched >= 0) {
              s = matched;
              pc++;
              continue;
            }
            break;
          }

        case Op.backrefWithLevel:
          {
            final r = _backrefAtLevel(opNs[pc]!, sc[base + FlatOps.oC], s, sc[base + FlatOps.oFlag] == 1);
            if (r >= 0) {
              s = r;
              pc++;
              continue;
            }
            break;
          }

        case Op.backrefCheck:
          // condition true iff ANY of the (multiplexed) groups matched
          {
            var ok = false;
            for (final m in opNs[pc]!) {
              if (m <= reg.numMem && memEnd[m] >= 0) {
                ok = true;
                break;
              }
            }
            if (ok) {
              pc++;
              continue;
            }
            break;
          }

        case Op.memStart:
          // Non-push: set the start register directly, WITHOUT a restore frame.
          // Backtracking will not rewind it, so a failed later iteration can
          // leave the start ahead of a later-set end (C's "inverted" region).
          memStart[sc[base + FlatOps.oMem]] = s;
          pc++;
          continue;

        case Op.memStartPush:
          // Push variant: open a new capture on the group's open stack + a
          // restore frame. The completed result is set at MEM_END, so the
          // last-closed instance wins — correct for recursion and `\g<>`.
          _openStart[sc[base + FlatOps.oMem]].add(s);
          stk.push(Stk.memStart, sc[base + FlatOps.oMem], 0, s, 0); // str = start position
          pc++;
          continue;

        case Op.memEnd:
          // Non-push: set only the end register directly (no rewind on
          // backtrack). The start was set by the non-push OP_MEM_START.
          memEnd[sc[base + FlatOps.oMem]] = s;
          pc++;
          continue;

        case Op.memEndPush:
        case Op.memEndPushRec:
          {
            final g = sc[base + FlatOps.oMem];
            final open = _openStart[g];
            final st = open.isNotEmpty ? open.removeLast() : s;
            // Save the previous completed result + the popped start for undo.
            stk.push(Stk.memEnd, g, memEnd[g], memStart[g], st);
            stk.x2[stk.sp - 1] = s; // end position (for backref-with-level)
            memStart[g] = st;
            memEnd[g] = s;
            pc++;
            continue;
          }

        case Op.memEndRec:
          memEnd[sc[base + FlatOps.oMem]] = s;
          pc++;
          continue;

        case Op.call:
          if (_callNest >= _callMaxNest) break;
          _callNest++;
          stk.push(Stk.callFrame, 0, pc + 1, s, 0); // pc=retPc, x1=live(0)
          pc = sc[base + FlatOps.oAddr]; // absolute jump to callee body
          continue;

        case Op.returnOp:
          {
            final ret = _popCallReturn();
            if (ret < 0) break;
            _callNest--;
            pc = ret;
            continue;
          }

        case Op.jump:
          pc += sc[base + FlatOps.oAddr];
          continue;

        case Op.push:
        case Op.pushSuper:
          stk.pushAlt(pc + sc[base + FlatOps.oAddr], s);
          pc++;
          continue;

        case Op.pop:
          stk.sp--;
          pc++;
          continue;

        case Op.popToMark:
          _popToMark(sc[base + FlatOps.oId]);
          pc++;
          continue;

        case Op.mark:
          stk.push(Stk.mark, sc[base + FlatOps.oId], 0, s, sc[base + FlatOps.oFlag]);
          pc++;
          continue;

        case Op.cutToMark:
          {
            // flag==1: look-around, restore_pos, discard body frames.
            // flag==2: atomic cut, keep body's right_range/\K SAVE_VAL so a
            //          range-cutter boundary is undone on outer backtrack (#891).
            // flag==0: plain cut (look-behind / conditional), discard frames.
            final markStr = _cutToMark(sc[base + FlatOps.oId], sc[base + FlatOps.oFlag] == 2);
            if (sc[base + FlatOps.oFlag] == 1 && markStr >= 0) {
              s = markStr; // restore_pos (look-around)
            }
            pc++;
            continue;
          }

        case Op.stepBackStart:
          {
            // Move s back by sc[base + FlatOps.oLen] characters. Fail if not enough room.
            var q = s;
            var k = sc[base + FlatOps.oLen];
            while (k > 0 && q > 0) {
              q = enc.leftAdjustCharHead(str, 0, q - 1);
              k--;
            }
            if (k > 0) break; // not enough room → fail
            s = q;
            // Variable look-behind: sc[base + FlatOps.oC] = remaining extra step-backs (or
            // infiniteLen). Push a retry frame that steps back one more char.
            if (sc[base + FlatOps.oC] != 0) {
              stk.push(Stk.stepBack, 0, pc + 1, s, sc[base + FlatOps.oC]);
            }
            pc++;
            continue;
          }

        case Op.repeat:
        case Op.repeatNg:
          {
            final id = sc[base + FlatOps.oId];
            stk.push(Stk.repeatInc, id, 0, 0, repeatStk[id]);
            repeatStk[id] = 0;
            final rr = reg.repeatRanges[id];
            if (rr.lower == 0) {
              // greedy: prefer entering body; lazy: prefer exit.
              if (sc[base + FlatOps.oOpcode] == Op.repeat) {
                stk.pushAlt(pc + sc[base + FlatOps.oAddr], s); // alt = exit
              } else {
                stk.pushAlt(pc + 1, s); // alt = body entry
                pc += sc[base + FlatOps.oAddr]; // go to exit first (lazy)
                continue;
              }
            }
            pc++;
            continue;
          }

        case Op.repeatInc:
        case Op.repeatIncNg:
          {
            final id = sc[base + FlatOps.oId];
            final n = _getRepeatCount(id) + 1;
            final rr = reg.repeatRanges[id];
            final bodyPc = rr.bodyAddr;
            // Store the count in `str` so a recursive re-entry (`\g<>`) can find
            // this call level's count by a stack search (see _getRepeatCount).
            stk.push(Stk.repeatInc, id, 0, n, repeatStk[id]);
            repeatStk[id] = n;
            if (n >= rr.upper) {
              pc++; // done repeating
            } else if (n >= rr.lower) {
              if (sc[base + FlatOps.oOpcode] == Op.repeatInc) {
                // greedy: prefer another rep, exit as backtrack alt
                stk.pushAlt(pc + 1, s);
                pc = bodyPc;
              } else {
                // lazy: prefer exit, another rep as backtrack alt
                stk.pushAlt(bodyPc, s);
                pc++;
              }
            } else {
              pc = bodyPc; // must repeat
            }
            continue;
          }

        case Op.emptyCheckStart:
          // Push a restore entry so the baseline is undone on backtrack; a flat
          // array without this corrupts nested-loop empty detection.
          // zid = sc[base + FlatOps.oMem] so `_capsChanged` can find this START frame; the
          // MEMST end does the capture comparison via a stack-scan (no snapshot).
          stk.push(Stk.emptyCheck, sc[base + FlatOps.oMem], 0, 0, emptyCheckStk[sc[base + FlatOps.oMem]]);
          emptyCheckStk[sc[base + FlatOps.oMem]] = s;
          pc++;
          continue;

        case Op.emptyCheckEnd:
          // Empty iteration: skip the loop-back op and fall through to the loop
          // exit, PRESERVING captures (C `empty_check_found`). Not a backtrack.
          pc += (s == emptyCheckStk[sc[base + FlatOps.oMem]]) ? 2 : 1;
          continue;

        case Op.emptyCheckEndMemst:
          // Like above, but an empty iteration that *changed* a tracked capture
          // is not treated as empty — loop once more so the capture is recorded
          // (rigid `EMPTY_CHECK_END_MEMST`).
          if (s != emptyCheckStk[sc[base + FlatOps.oMem]]) {
            pc++; // position advanced → keep looping
          } else if (_capsChanged(sc[base + FlatOps.oMem], opNs[pc]!)) {
            pc++; // a capture changed this iteration → loop once more
          } else {
            pc += 2; // truly empty → stop looping
          }
          continue;

        case Op.fail:
          break;

        case Op.calloutContents:
        case Op.calloutName:
          {
            final op = ops[pc]; // callout string payloads aren't flattened
            final fn = sc[base + FlatOps.oOpcode] == Op.calloutName
                ? calloutRegistry.lookup(op.calloutName!)
                : calloutRegistry.contentsHandler;
            if (fn == null) {
              // Unknown name callout is an error; a contents callout with no
              // handler is a no-op (matches "ignore" semantics).
              if (sc[base + FlatOps.oOpcode] == Op.calloutName) {
                return OnigErr.undefinedCalloutName;
              }
              pc++;
              continue;
            }
            final res = fn(
              CalloutArgs(
                name: op.calloutName,
                contents: op.calloutContents,
                tag: op.calloutTag,
                args: op.calloutArgs ?? const [],
                strPos: s,
                counters: _calloutCounters,
                id: sc[base + FlatOps.oId],
                tagToId: _calloutTagToId,
              ),
            );
            if (res == CalloutResult.success) {
              // Callouts that also fire on retraction (e.g. COUNT/TOTAL_COUNT)
              // get an undo frame so they re-fire as the match unwinds past here.
              if (sc[base + FlatOps.oOpcode] == Op.calloutName &&
                  calloutRegistry.firesOnRetraction(op.calloutName!)) {
                stk.push(Stk.callout, sc[base + FlatOps.oId], pc, s, 0);
              }
              pc++;
              continue;
            }
            if (res == CalloutResult.error) {
              return OnigErr.invalidCalloutBody;
            }
            if (res == CalloutResult.mismatch) {
              return OnigResult.mismatch; // abort this match attempt
            }
            break; // fail → backtrack
          }

        case Op.saveVal:
          // `pc` carries the SaveType so a backtrack only rewinds right_range
          // for SAVE_RIGHT_RANGE frames — never for a SAVE_S position.
          switch (sc[base + FlatOps.oFlag]) {
            case SaveType.rightRange:
              stk.push(Stk.saveVal, sc[base + FlatOps.oId], SaveType.rightRange, 0, _rightRange);
            case SaveType.s:
              stk.push(Stk.saveVal, sc[base + FlatOps.oId], SaveType.s, 0, s);
            default: // SaveType.keep
              // \K keep: the reported match start becomes the current position.
              // Save the old value so backtracking undoes it (C's SAVE_KEEP
              // frame — the topmost surviving \K wins).
              stk.push(Stk.saveVal, sc[base + FlatOps.oId], SaveType.keep, 0, _keep);
              _keep = s;
          }
          pc++;
          continue;

        case Op.updateVar:
          switch (sc[base + FlatOps.oFlag]) {
            case UpdateVarType.rightRangeToS:
              _rightRange = s;
            case UpdateVarType.rightRangeFromStack:
            case UpdateVarType.rightRangeFromSStack:
              _rightRange = _findSaveVal(sc[base + FlatOps.oId], _rightRange);
            case UpdateVarType.rightRangeInit:
              _rightRange = end;
            case UpdateVarType.sFromStack:
              s = _findSaveVal(sc[base + FlatOps.oId], s);
          }
          pc++;
          continue;

        case Op.peekByte:
          // Alternation quick-check: enter the branch only if the current byte
          // is in its first-byte set; otherwise skip past it (no PUSH, no
          // enter-and-fail). At end-of-range a non-nullable branch can't match.
          if (s < _rightRange && opBs[pc]!.at(str[s])) {
            pc++;
            continue;
          }
          pc += sc[base + FlatOps.oAddr];
          continue;

        case Op.starGreedy:
          {
            // Greedy `*`/`+` over a single-char body op at pc+1: scan the whole
            // run here (tight loop, no per-char PUSH/JUMP dispatch), then push
            // ONE decrement-on-backtrack frame. Exit is pc+2. Semantics are
            // identical to the PUSH/body/JUMP loop (longest first, give back one
            // char per backtrack), just with O(1) live frames instead of O(n).
            //
            // The body opcode is loop-invariant, so it's switched ONCE here and
            // the hottest matchers run a specialised tight inner loop; the rest
            // fall back to _starConsume. All branches must stay byte-identical to
            // the standalone char ops (and to _starConsume).
            final bodyPc = pc + 1;
            final bodyOpc = sc[bodyPc * FlatOps.stride + FlatOps.oOpcode];
            final floor = s;
            var cur = s;
            final rr = _rightRange;
            switch (bodyOpc) {
              case Op.cclass:
                final bs = opBs[bodyPc]!;
                while (cur < rr) {
                  final b = str[cur];
                  if (b < 0x80 && asciiFast) {
                    if (!bs.at(b)) break;
                    cur++;
                  } else {
                    final code = enc.mbcToCode(str, cur, end);
                    if (!((code < 0x80 || (enc.isSingleByte && code < 0x100)) &&
                        bs.at(code))) {
                      break;
                    }
                    cur += enc.length(str, cur, end);
                  }
                }
              case Op.word:
              case Op.wordAscii:
                final asc = bodyOpc == Op.wordAscii;
                while (cur < rr) {
                  final b = str[cur];
                  if (b < 0x80 && asciiFast) {
                    if (!_isWord(b, asc)) break;
                    cur++;
                  } else {
                    if (!_isWord(enc.mbcToCode(str, cur, end), asc)) break;
                    cur += enc.length(str, cur, end);
                  }
                }
              case Op.anychar:
                while (cur < rr) {
                  final b = str[cur];
                  if (enc.isMbcNewline(str, cur, end)) break;
                  cur += (b < 0x80 && asciiFast) ? 1 : enc.length(str, cur, end);
                }
              case Op.anycharMl:
                while (cur < rr) {
                  final b = str[cur];
                  cur += (b < 0x80 && asciiFast) ? 1 : enc.length(str, cur, end);
                }
              default:
                while (cur < rr) {
                  final ns = _starConsume(bodyPc, bodyOpc, cur);
                  if (ns < 0) break;
                  cur = ns;
                }
            }
            if (cur > floor) {
              stk.push(Stk.starLoop, 0, pc + 2, cur, floor);
            }
            s = cur;
            pc += 2;
            continue;
          }

        default:
          throw StateError('unimplemented opcode ${sc[base + FlatOps.oOpcode]}');
      }

      // fall-through == failure: backtrack.
      if (retryLimit != 0 && ++_retryCount > retryLimit) {
        return OnigErr.retryLimitInMatchOver;
      }
      final r = _backtrack();
      if (r == null) return OnigResult.mismatch;
      pc = r.$1;
      s = r.$2;
    }
  }

  /// Pop the stack applying undo side-effects until a resume ([Stk.alt]) entry
  /// is found. Returns (pc, s) to resume, or null if the stack is exhausted.
  (int, int)? _backtrack() {
    while (stk.sp > 0) {
      final i = --stk.sp;
      switch (stk.type[i]) {
        case Stk.alt:
          return (stk.pc[i], stk.str[i]);
        case Stk.starLoop:
          {
            // Give back one character from a greedy single-item run and resume
            // the continuation at the loop exit; re-push if more can be given.
            final exitPc = stk.pc[i];
            final cur = stk.str[i];
            final floor = stk.x1[i];
            if (cur > floor) {
              final ne = enc.leftAdjustCharHead(str, floor, cur - 1);
              if (ne > floor) {
                stk.push(Stk.starLoop, 0, exitPc, ne, floor);
              }
              return (exitPc, ne);
            }
            // cur == floor: run exhausted, keep unwinding.
          }
        case Stk.stepBack:
          {
            // Look-behind: step back one more character and retry the body.
            final framePc = stk.pc[i];
            final saved = stk.str[i];
            final rem = stk.x1[i];
            if (saved <= 0) continue; // exhausted
            final q = enc.leftAdjustCharHead(str, 0, saved - 1);
            if (q >= saved) continue;
            final rem2 = rem == infiniteLen ? infiniteLen : rem - 1;
            if (rem2 != 0) {
              stk.push(Stk.stepBack, 0, framePc, q, rem2);
            }
            return (framePc, q);
          }
        case Stk.saveVal:
          // Only a SAVE_RIGHT_RANGE frame (type in pc) rewinds right_range;
          // a SAVE_S position must not touch it. SAVE_KEEP restores \K's start.
          if (stk.pc[i] == SaveType.rightRange) {
            _rightRange = stk.x1[i];
          } else if (stk.pc[i] == SaveType.keep) {
            _keep = stk.x1[i];
          }
        case Stk.memStart:
          _openStart[stk.zid[i]].removeLast(); // undo the open push
        case Stk.memEnd:
          {
            final g = stk.zid[i];
            memEnd[g] = stk.pc[i]; // restore previous completed result
            memStart[g] = stk.str[i];
            _openStart[g].add(stk.x1[i]); // re-open the popped start
          }
        case Stk.emptyCheck:
          emptyCheckStk[stk.zid[i]] = stk.x1[i];
        case Stk.repeatInc:
          repeatStk[stk.zid[i]] = stk.x1[i];
        case Stk.callFrame:
          _callNest--; // undo an (un-returned) call
        case Stk.returnMark:
          stk.x1[stk.zid[i]] = 0; // re-mark the call frame live
          _callNest++;
        case Stk.mark:
          break; // marks carry no undo
        case Stk.callout:
          {
            // Re-fire the callout in retraction as the match unwinds past it
            // (e.g. COUNT `X` decrements). Side-effect only — result ignored.
            final cop = ops[stk.pc[i]];
            final fn = calloutRegistry.lookup(cop.calloutName!);
            if (fn != null) {
              fn(
                CalloutArgs(
                  name: cop.calloutName,
                  contents: cop.calloutContents,
                  tag: cop.calloutTag,
                  args: cop.calloutArgs ?? const [],
                  strPos: stk.str[i],
                  calloutIn: CalloutIn.retraction,
                  counters: _calloutCounters,
                  id: cop.id,
                  tagToId: _calloutTagToId,
                ),
              );
            }
          }
      }
    }
    return null;
  }

  /// Faithful `STACK_EMPTY_CHECK_MEM` (regexec.c): at an empty iteration
  /// (position unchanged), scan the stack from the top down to this
  /// empty-check's START frame; for each tracked group's most-recent MEM_END,
  /// compare this iteration's capture `[x1,x2]` to the previous `[str,pc]`.
  /// Returns true ("not empty" → loop once more) iff some tracked group either
  /// was never captured before, or *changed to a different non-empty span*.
  /// A capture that merely shifts between two empty spans (e.g. `[2,2]`→`[3,3]`)
  /// counts as empty — this is the exact C condition and the crux of parity.
  bool _capsChanged(int id, List<int> groups) {
    var remaining = groups.length;
    final seen = _capsSeen;
    for (final g in groups) {
      seen[g] = false;
    }
    for (var i = stk.sp - 1; i >= 0; i--) {
      final t = stk.type[i];
      if (t == Stk.emptyCheck && stk.zid[i] == id) break; // reached START frame
      if (t == Stk.memEnd) {
        final g = stk.zid[i];
        if (g < seen.length && !seen[g] && groups.contains(g)) {
          seen[g] = true;
          remaining--;
          final thisStart = stk.x1[i], thisEnd = stk.x2[i];
          final prevStart = stk.str[i], prevEnd = stk.pc[i];
          // prevEnd == notFound → group never completed before → changed.
          if (prevEnd == OnigRegion.notFound) return true;
          final changed = prevStart != thisStart || prevEnd != thisEnd;
          final bothEmpty = thisStart == thisEnd && prevStart == prevEnd;
          if (changed && !bothEmpty) return true;
          if (remaining == 0) break;
        }
      }
    }
    return false;
  }

  late final List<bool> _capsSeen = List<bool>.filled(reg.numMem + 1, false);

  /// Nearest saved right_range value for [id], else [fallback].
  int _findSaveVal(int id, int fallback) {
    for (var i = stk.sp - 1; i >= 0; i--) {
      if (stk.type[i] == Stk.saveVal && stk.zid[i] == id) return stk.x1[i];
    }
    return fallback;
  }

  /// Find the topmost live call frame, mark it consumed (reversibly, via a
  /// returnMark), and return its saved return pc; -1 if none.
  /// Current counted-repeat count for [id]. Without subexp calls the flat
  /// [repeatStk] is authoritative; with calls it's shared across recursion
  /// levels, so search the stack for THIS call level's REPEAT_INC frame,
  /// skipping any completed inner-call region (regexec.c
  /// STACK_GET_REPEAT_COUNT_SEARCH — returnMark…callFrame balance).
  int _getRepeatCount(int id) {
    if (reg.numCall == 0) return repeatStk[id];
    var k = stk.sp;
    while (k > 0) {
      k--;
      final t = stk.type[k];
      if (t == Stk.repeatInc && stk.zid[k] == id) {
        return stk.str[k];
      } else if (t == Stk.returnMark) {
        var level = -1;
        while (k > 0) {
          k--;
          final tt = stk.type[k];
          if (tt == Stk.callFrame) {
            level++;
            if (level == 0) break;
          } else if (tt == Stk.returnMark) {
            level--;
          }
        }
      }
    }
    return 0;
  }

  int _popCallReturn() {
    for (var i = stk.sp - 1; i >= 0; i--) {
      if (stk.type[i] == Stk.callFrame && stk.x1[i] == 0) {
        stk.x1[i] = 1;
        final ret = stk.pc[i];
        stk.push(Stk.returnMark, i, 0, 0, 0);
        _callNest--;
        return ret;
      }
    }
    return -1;
  }

  /// `cut_to_mark`: discard entries down to and including the mark [id],
  /// committing (no undo). Returns the mark's saved string position.
  int _cutToMark(int id, bool preserveSaveVal) {
    // `cut_to_mark`: discard the choice points down to (and including) the mark.
    // C's STACK_TO_VOID_TO_MARK keeps non-choice frames; the only such frame
    // whose survival is observable here is SAVE_VAL — it restores right_range/\K
    // when the enclosing scope later backtracks. A range-cutter `(?~|…)` inside
    // an atomic sets right_range and pushes that restore; truncating it outright
    // would leak the cut boundary past the atomic (#891). So (for atomic/absent
    // cuts) truncate to the mark but re-establish any SAVE_VAL frames above it.
    var i = stk.sp - 1;
    while (i >= 0) {
      if (stk.type[i] == Stk.mark && stk.zid[i] == id) {
        final savedStr = stk.str[i];
        final top = stk.sp;
        List<int>? saved;
        if (preserveSaveVal) {
          for (var j = i + 1; j < top; j++) {
            if (stk.type[j] == Stk.saveVal) {
              (saved ??= <int>[])
                ..add(stk.zid[j])
                ..add(stk.pc[j])
                ..add(stk.str[j])
                ..add(stk.x1[j]);
            }
          }
        }
        stk.sp = i;
        if (saved != null) {
          for (var k = 0; k < saved.length; k += 4) {
            stk.push(
              Stk.saveVal,
              saved[k],
              saved[k + 1],
              saved[k + 2],
              saved[k + 3],
            );
          }
        }
        return savedStr;
      }
      i--;
    }
    return -1;
  }

  /// `pop_to_mark`: discard entries down to and including the mark [id].
  void _popToMark(int id) {
    var i = stk.sp - 1;
    while (i >= 0) {
      if (stk.type[i] == Stk.mark && stk.zid[i] == id) {
        stk.sp = i;
        return;
      }
      i--;
    }
  }

  // --- helpers -------------------------------------------------------------

  /// `\k<name±n>` — match the capture of one of [groups] at call-nesting level
  /// [nest] (`backref_match_at_nested_level`). Returns the new position or -1.
  int _backrefAtLevel(List<int> groups, int nest, int s, [bool ic = false]) {
    var level = 0;
    var pend = -1;
    for (var i = stk.sp - 1; i >= 0; i--) {
      final t = stk.type[i];
      if (t == Stk.callFrame) {
        level--;
      } else if (t == Stk.returnMark) {
        level++;
      } else if (level == nest) {
        if (t == Stk.memEnd && groups.contains(stk.zid[i])) {
          pend = stk.x2[i];
        } else if (t == Stk.memStart && groups.contains(stk.zid[i])) {
          if (pend >= 0) {
            final pstart = stk.str[i];
            final len = pend - pstart;
            if (len < 0) return -1;
            if (!ic) {
              if (s + len > end) return -1;
              for (var k = 0; k < len; k++) {
                if (str[s + k] != str[pstart + k]) return -1;
              }
              return s + len;
            }
            // case-insensitive: fold-compare code point by code point.
            var sp = s;
            var bp = pstart;
            while (bp < pend) {
              if (sp >= end) return -1;
              final cCap = enc.mbcToCode(str, bp, pend);
              final cIn = enc.mbcToCode(str, sp, end);
              if (enc.caseFoldRep(cCap) != enc.caseFoldRep(cIn)) return -1;
              bp += enc.length(str, bp, pend);
              sp += enc.length(str, sp, end);
            }
            return sp;
          }
        }
      }
    }
    return -1;
  }

  bool _matchBytes(Uint8List pat, int at, int n, bool ic) {
    if (!ic) {
      for (var i = 0; i < n; i++) {
        if (str[at + i] != pat[i]) return false;
      }
      return true;
    }
    for (var i = 0; i < n; i++) {
      var b = str[at + i];
      if (b >= 0x41 && b <= 0x5a) b += 0x20; // ASCII fold
      if (b != pat[i]) return false;
    }
    return true;
  }

  /// Class membership for a code point: bitset covers `<0x80` (and `<0x100`
  /// for single-byte encodings), the multibyte range buffer covers the rest.
  bool _ccMember(BitSet? bs, CodeRangeBuffer? mb, int code) {
    if (bs != null &&
        (code < 0x80 || (enc.isSingleByte && code < 0x100)) &&
        bs.at(code)) {
      return true;
    }
    return mb != null && mb.contains(code);
  }

  /// Match ONE character of the [Op.starGreedy] body op (at [bodyPc], opcode
  /// [bodyOpc]) at position [at]; returns the advanced position, or -1 on no
  /// match. Caller guarantees `at < _rightRange`. This must stay byte-identical
  /// to the standalone char ops (cclass*/word*/anychar*) it mirrors.
  int _starConsume(int bodyPc, int bodyOpc, int at) {
    final b = str[at];
    switch (bodyOpc) {
      case Op.cclass:
        {
          final int len;
          final int code;
          if (b < 0x80 && asciiFast) {
            code = b;
            len = 1;
          } else {
            len = enc.length(str, at, end);
            code = enc.mbcToCode(str, at, end);
          }
          if ((code < 0x80 || (enc.isSingleByte && code < 0x100)) &&
              opBs[bodyPc]!.at(code)) {
            return at + len;
          }
          return -1;
        }
      case Op.cclassNot:
        {
          final int len;
          final int code;
          if (b < 0x80 && asciiFast) {
            code = b;
            len = 1;
          } else {
            len = enc.length(str, at, end);
            code = enc.mbcToCode(str, at, end);
          }
          final single = code < 0x80 || (enc.isSingleByte && code < 0x100);
          return (single && opBs[bodyPc]!.at(code)) ? -1 : at + len;
        }
      case Op.cclassMb:
      case Op.cclassMix:
        {
          final int len;
          final int code;
          if (b < 0x80 && asciiFast) {
            code = b;
            len = 1;
          } else {
            len = enc.length(str, at, end);
            code = enc.mbcToCode(str, at, end);
          }
          return _ccMember(opBs[bodyPc], opMb[bodyPc], code) ? at + len : -1;
        }
      case Op.cclassMbNot:
      case Op.cclassMixNot:
        {
          final int len;
          final int code;
          if (b < 0x80 && asciiFast) {
            code = b;
            len = 1;
          } else {
            len = enc.length(str, at, end);
            code = enc.mbcToCode(str, at, end);
          }
          return _ccMember(opBs[bodyPc], opMb[bodyPc], code) ? -1 : at + len;
        }
      case Op.word:
      case Op.wordAscii:
        {
          final int code;
          final int len;
          if (b < 0x80 && asciiFast) {
            code = b;
            len = 1;
          } else {
            code = enc.mbcToCode(str, at, end);
            len = enc.length(str, at, end);
          }
          return _isWord(code, bodyOpc == Op.wordAscii) ? at + len : -1;
        }
      case Op.noWord:
      case Op.noWordAscii:
        {
          final int code;
          final int len;
          if (b < 0x80 && asciiFast) {
            code = b;
            len = 1;
          } else {
            code = enc.mbcToCode(str, at, end);
            len = enc.length(str, at, end);
          }
          return _isWord(code, bodyOpc == Op.noWordAscii) ? -1 : at + len;
        }
      case Op.anychar:
        {
          final len = (b < 0x80 && asciiFast) ? 1 : enc.length(str, at, end);
          return enc.isMbcNewline(str, at, end) ? -1 : at + len;
        }
      case Op.anycharMl:
        return at + ((b < 0x80 && asciiFast) ? 1 : enc.length(str, at, end));
      default:
        return -1; // unreachable for _isStarEligible bodies
    }
  }

  int _matchBackref(int n, int s, [bool ic = false]) {
    if (n > reg.numMem) return -1;
    final b = memStart[n];
    final e = memEnd[n];
    // An unset group makes the back-reference FAIL (C `goto fail`), not match
    // empty. `e < b` (Oniguruma's inverted region) still yields a length-0 ok.
    if (b < 0 || e < 0) return -1;
    final len = e - b;
    if (len <= 0) return s;
    if (!ic) {
      if (s + len > _rightRange) return -1;
      for (var i = 0; i < len; i++) {
        if (str[s + i] != str[b + i]) return -1;
      }
      return s + len;
    }
    // Case-insensitive: compare code point by code point via canonical folds.
    var sp = s;
    var bp = b;
    while (bp < e) {
      if (sp >= _rightRange) return -1;
      final cCap = enc.mbcToCode(str, bp, e);
      final cIn = enc.mbcToCode(str, sp, _rightRange);
      if (enc.caseFoldRep(cCap) != enc.caseFoldRep(cIn)) return -1;
      bp += enc.length(str, bp, e);
      sp += enc.length(str, sp, _rightRange);
    }
    return sp;
  }

  bool _isWord(int code, bool ascii) {
    // ASCII word membership is identical under ascii-mode and Unicode-mode
    // (both are [A-Za-z0-9_] in [0,0x80)), so use the ASCII ctype table for any
    // code < 0x80 and only pay the virtual `enc.isCodeCtype` for wider chars.
    if (ascii || code < 0x80) return asciiIsCodeCtype(code, CType.word);
    return enc.isCodeCtype(code, CType.word);
  }

  int _prevCharCode(int s) {
    final prev = enc.leftAdjustCharHead(str, 0, s - 1);
    return enc.mbcToCode(str, prev, end);
  }

  bool _wordBoundary(int s, bool ascii) {
    final left = (s > 0) && _isWord(_prevCharCode(s), ascii);
    final right = (s < end) && _isWord(enc.mbcToCode(str, s, end), ascii);
    return left != right;
  }

  bool _wordBegin(int s, bool ascii) {
    final left = (s > 0) && _isWord(_prevCharCode(s), ascii);
    final right = (s < end) && _isWord(enc.mbcToCode(str, s, end), ascii);
    return !left && right;
  }

  bool _wordEnd(int s, bool ascii) {
    final left = (s > 0) && _isWord(_prevCharCode(s), ascii);
    final right = (s < end) && _isWord(enc.mbcToCode(str, s, end), ascii);
    return left && !right;
  }

  bool _prevIsNewline(int s) {
    final prev = enc.leftAdjustCharHead(str, 0, s - 1);
    return enc.isMbcNewline(str, prev, end);
  }

  bool _isNewlineAt(int s) => s < end && enc.isMbcNewline(str, s, end);

  /// End byte offset of the extended grapheme cluster starting at [p] (UAX#29,
  /// `\X`). Implements GB3–GB13 with forward RI/emoji state.
  int _graphemeEnd(int p) {
    var code = enc.mbcToCode(str, p, end);
    var prev = uni.unicodeEgcbClass(code);
    var q = p + enc.length(str, p, end);
    // forward state: emoji chain (ExtPict (Extend|ZWJ)*), consecutive RI count.
    var emoji = uni.unicodeIsExtendedPictographic(code);
    var riRun = prev == uni.Egcb.regionalIndicator ? 1 : 0;

    while (q < end) {
      final c = enc.mbcToCode(str, q, end);
      final cur = uni.unicodeEgcbClass(c);
      if (_egcbBreak(prev, cur, c, emoji, riRun)) break;
      q += enc.length(str, q, end);
      // update state
      if (cur == uni.Egcb.regionalIndicator) {
        riRun++;
      } else {
        riRun = 0;
      }
      if (uni.unicodeIsExtendedPictographic(c)) {
        emoji = true;
      } else if (cur != uni.Egcb.extend && cur != uni.Egcb.zwj) {
        emoji = false;
      }
      prev = cur;
    }
    return q;
  }

  /// Is byte position [s] on a grapheme-cluster boundary (`\y`)? Uses a short
  /// backscan to establish the RI-parity / emoji-ZWJ context for GB11–GB13.
  bool _isGraphemeBoundary(int s) {
    if (s <= 0 || s >= end) return true; // GB1 / GB2
    final prevHead = enc.leftAdjustCharHead(str, 0, s - 1);
    final prevCode = enc.mbcToCode(str, prevHead, end);
    final curCode = enc.mbcToCode(str, s, end);
    final prevCls = uni.unicodeEgcbClass(prevCode);
    final curCls = uni.unicodeEgcbClass(curCode);

    // RI run length ending at prevHead (count consecutive RI backwards).
    var riRun = 0;
    if (prevCls == uni.Egcb.regionalIndicator) {
      var q = prevHead;
      while (q > 0) {
        riRun++;
        final ph = enc.leftAdjustCharHead(str, 0, q - 1);
        if (ph >= q) break;
        if (uni.unicodeEgcbClass(enc.mbcToCode(str, ph, end)) !=
            uni.Egcb.regionalIndicator) {
          break;
        }
        q = ph;
      }
    }

    // Emoji context for GB11: prevHead is ZWJ preceded (through Extend*) by an
    // Extended_Pictographic.
    var emoji = false;
    if (prevCls == uni.Egcb.zwj) {
      var q = prevHead;
      while (q > 0) {
        final ph = enc.leftAdjustCharHead(str, 0, q - 1);
        if (ph >= q) break;
        final code = enc.mbcToCode(str, ph, end);
        if (uni.unicodeIsExtendedPictographic(code)) {
          emoji = true;
          break;
        }
        if (uni.unicodeEgcbClass(code) != uni.Egcb.extend) break;
        q = ph;
      }
    }
    return _egcbBreak(prevCls, curCls, curCode, emoji, riRun);
  }

  // --- UAX#29 word boundaries (`(?y{w})` \y / \X) --------------------------

  static bool _wbIgnoreTail(int t) =>
      t == uni.Wb.extend || t == uni.Wb.format || t == uni.Wb.zwj;
  static bool _wbAH(int t) => t == uni.Wb.aLetter || t == uni.Wb.hebrewLetter;
  static bool _wbMidNumLetQ(int t) =>
      t == uni.Wb.midNumLet || t == uni.Wb.singleQuote;

  int _wbPrevHead(int p) => p <= 0 ? -1 : enc.leftAdjustCharHead(str, 0, p - 1);

  /// The next non-ignore-tail Word_Break type after the char at [p], or -1.
  int _wbNextMain(int p) {
    var q = p + enc.length(str, p, end);
    while (q < end) {
      final t = uni.unicodeWbClass(enc.mbcToCode(str, q, end));
      if (!_wbIgnoreTail(t)) return t;
      q += enc.length(str, q, end);
    }
    return -1;
  }

  /// Is byte position [p] a UAX#29 word boundary?
  bool _wordBoundaryAt(int p) {
    if (p <= 0 || p >= end) return true; // WB1 / WB2
    var prev = _wbPrevHead(p);
    if (prev < 0) return true;
    var from = uni.unicodeWbClass(enc.mbcToCode(str, prev, end));
    final cto = enc.mbcToCode(str, p, end);
    final to = uni.unicodeWbClass(cto);
    if (from == 0 && to == 0) return true; // WB999 shortcut
    if (from == uni.Wb.cr && to == uni.Wb.lf) return false; // WB3
    if (from == uni.Wb.newline || from == uni.Wb.cr || from == uni.Wb.lf) {
      return true; // WB3a
    }
    if (to == uni.Wb.newline || to == uni.Wb.cr || to == uni.Wb.lf) {
      return true; // WB3b
    }
    if (from == uni.Wb.zwj && uni.unicodeIsExtendedPictographic(cto)) {
      return false; // WB3c
    }
    if (from == uni.Wb.wSegSpace && to == uni.Wb.wSegSpace) {
      return false; // WB3d
    }
    // WB4: X (Extend|Format|ZWJ)* → treat run as X.
    if (_wbIgnoreTail(to)) return false;
    if (_wbIgnoreTail(from)) {
      var pp = prev;
      while (true) {
        final h = _wbPrevHead(pp);
        if (h < 0) break;
        pp = h;
        from = uni.unicodeWbClass(enc.mbcToCode(str, pp, end));
        prev = pp;
        if (!_wbIgnoreTail(from)) break;
      }
    }
    if (_wbAH(from)) {
      if (_wbAH(to)) return false; // WB5
      if (to == uni.Wb.midLetter || _wbMidNumLetQ(to)) {
        // WB6
        final t2 = _wbNextMain(p);
        if (t2 != -1 && _wbAH(t2)) return false;
      }
    }
    // WB7: AHLetter (MidLetter|MidNumLetQ) + AHLetter
    if (from == uni.Wb.midLetter || _wbMidNumLetQ(from)) {
      if (_wbAH(to) && _wbAH(_wbPrevMain(prev))) return false;
    }
    if (from == uni.Wb.hebrewLetter) {
      if (to == uni.Wb.singleQuote) return false; // WB7a
      if (to == uni.Wb.doubleQuote) {
        final t2 = _wbNextMain(p); // WB7b
        if (t2 == uni.Wb.hebrewLetter) return false;
      }
    }
    if (from == uni.Wb.doubleQuote && to == uni.Wb.hebrewLetter) {
      if (_wbPrevMain(prev) == uni.Wb.hebrewLetter) return false; // WB7c
    }
    if (to == uni.Wb.numeric) {
      if (from == uni.Wb.numeric) return false; // WB8
      if (_wbAH(from)) return false; // WB9
      if (from == uni.Wb.midNum || _wbMidNumLetQ(from)) {
        if (_wbPrevMain(prev) == uni.Wb.numeric) return false; // WB11
      }
    }
    if (from == uni.Wb.numeric) {
      if (_wbAH(to)) return false; // WB10
      if (to == uni.Wb.midNum || _wbMidNumLetQ(to)) {
        final t2 = _wbNextMain(p); // WB12
        if (t2 == uni.Wb.numeric) return false;
      }
    }
    if (from == uni.Wb.katakana && to == uni.Wb.katakana) return false; // WB13
    if ((_wbAH(from) ||
            from == uni.Wb.numeric ||
            from == uni.Wb.katakana ||
            from == uni.Wb.extendNumLet) &&
        to == uni.Wb.extendNumLet) {
      return false; // WB13a
    }
    if (from == uni.Wb.extendNumLet &&
        (_wbAH(to) || to == uni.Wb.numeric || to == uni.Wb.katakana)) {
      return false; // WB13b
    }
    if (from == uni.Wb.regionalIndicator && to == uni.Wb.regionalIndicator) {
      // WB15/16: break only after an even number of preceding RIs.
      var n = 0;
      var q = prev;
      while (true) {
        q = _wbPrevHead(q);
        if (q < 0) break;
        if (uni.unicodeWbClass(enc.mbcToCode(str, q, end)) !=
            uni.Wb.regionalIndicator) {
          break;
        }
        n++;
      }
      if (n % 2 == 0) return false;
    }
    return true; // WB999
  }

  /// Word_Break type of the previous main (non-ignore-tail) char before [p].
  int _wbPrevMain(int p) {
    var q = p;
    while (true) {
      final h = _wbPrevHead(q);
      if (h < 0) return uni.Wb.any;
      q = h;
      final t = uni.unicodeWbClass(enc.mbcToCode(str, q, end));
      if (!_wbIgnoreTail(t)) return t;
    }
  }

  /// End of the word segment starting at [p] (`\X` under `(?y{w})`).
  int _wordSegmentEnd(int p) {
    var q = p;
    if (q < end) q += enc.length(str, q, end);
    while (q < end && !_wordBoundaryAt(q)) {
      q += enc.length(str, q, end);
    }
    return q;
  }

  bool _egcbBreak(int prev, int cur, int curCode, bool emoji, int riRun) {
    const cr = uni.Egcb.cr,
        lf = uni.Egcb.lf,
        ctrl = uni.Egcb.control,
        ext = uni.Egcb.extend,
        zwj = uni.Egcb.zwj,
        prep = uni.Egcb.prepend,
        sm = uni.Egcb.spacingMark,
        l = uni.Egcb.l,
        v = uni.Egcb.v,
        t = uni.Egcb.t,
        lv = uni.Egcb.lv,
        lvt = uni.Egcb.lvt,
        ri = uni.Egcb.regionalIndicator;
    if (prev == cr && cur == lf) return false; // GB3
    if (prev == ctrl || prev == cr || prev == lf) return true; // GB4
    if (cur == ctrl || cur == cr || cur == lf) return true; // GB5
    if (prev == l && (cur == l || cur == v || cur == lv || cur == lvt)) {
      return false; // GB6
    }
    if ((prev == lv || prev == v) && (cur == v || cur == t)) {
      return false; // GB7
    }
    if ((prev == lvt || prev == t) && cur == t) return false; // GB8
    if (cur == ext || cur == zwj) return false; // GB9
    if (cur == sm) return false; // GB9a
    if (prev == prep) return false; // GB9b
    if (prev == zwj && emoji && uni.unicodeIsExtendedPictographic(curCode)) {
      return false; // GB11
    }
    if (prev == ri && cur == ri && riRun.isOdd) return false; // GB12/13
    return true; // GB999
  }

  void _fillRegion(OnigRegion? region, int sstart, int s) {
    if (region == null) return;
    region.resize(reg.numMem + 1);
    region.beg[0] = _keep >= 0 ? _keep : sstart;
    region.end[0] = s;
    for (var i = 1; i <= reg.numMem; i++) {
      region.beg[i] = memStart[i];
      region.end[i] = memEnd[i];
    }
  }
}
