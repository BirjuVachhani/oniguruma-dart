/// A linear-time Thompson/Pike NFA fast path for the *safe subset* of patterns.
///
/// A backtracking VM can blow up exponentially (`(a+)+$` on non-matching input).
/// For patterns that use only regular-language constructs — literals, classes,
/// `\w`/`.`, alternation, concatenation, greedy/lazy quantifiers over a
/// non-empty body, captures, and the simple anchors `\A ^ $ \z \Z \b \B` — this
/// engine runs a Pike VM (NFA simulation with submatch tracking) that visits
/// each program state at most once per input position, so it is **O(text ×
/// program)** and cannot catastrophically backtrack.
///
/// It is designed to be *byte-identical* to the backtracking engine on the
/// subset it accepts (leftmost-first/greedy priority, the same code-point class
/// membership, the same anchor semantics). Anything outside the subset —
/// back-references, atomic/possessive groups, look-around, conditionals,
/// sub-routine calls, callouts, `\K`, ignore-case folding, or a quantifier whose
/// body can match empty — makes [buildNfa] return `null`, and the search driver
/// falls back to the backtracking VM.
library;

import 'dart:typed_data';

import '../encoding/encoding.dart';
import '../onig_types.dart';
import '../parse/node.dart';
import '../region.dart';
import '../regex.dart';

// NFA instruction opcodes.
const int _cChar = 0; // match one code point via m[pc]; on success → pc+1
const int _cSplit = 1; // a = high-priority target, b = low-priority target
const int _cJmp = 2; // → a
const int _cSave = 3; // caps[a] = pos
const int _cMatch = 4; // accept
const int _cAssert = 5; // zero-width assertion: a = Anchor.* type, b = ascii?1:0

/// Cap on emitted instructions / per-repeat expansion, to bound compile size,
/// memory, and the linear-time constant. Larger patterns fall back.
const int _maxProg = 200000;
const int _maxExpand = 1000;

/// Thrown internally to abandon compilation for an unsupported construct.
class _Bail implements Exception {
  const _Bail();
}

/// A code-point matcher for a `_cChar` instruction.
abstract class NfaMatcher {
  bool test(int code, bool isNewline);
}

class _Lit extends NfaMatcher {
  final int c;
  _Lit(this.c);
  @override
  bool test(int code, bool _) => code == c;
}

class _CC extends NfaMatcher {
  final BitSet? bs;
  final CodeRangeBuffer? mb;
  final bool not;
  final bool singleByteEnc;
  _CC(this.bs, this.mb, this.not, OnigEncoding enc)
      : singleByteEnc = enc.isSingleByte;
  @override
  bool test(int code, bool _) {
    final single = code < 0x80 || (singleByteEnc && code < 0x100);
    final member =
        (bs != null && single && bs!.at(code)) || (mb != null && mb!.contains(code));
    return not ? !member : member;
  }
}

class _Ct extends NfaMatcher {
  final int ctype;
  final bool not;
  final bool ascii;
  final OnigEncoding enc;
  _Ct(this.ctype, this.not, this.ascii, this.enc);
  @override
  bool test(int code, bool _) {
    final m = ascii ? asciiIsCodeCtype(code, ctype) : enc.isCodeCtype(code, ctype);
    return not ? !m : m;
  }
}

class _Any extends NfaMatcher {
  final bool matchesNewline; // dotall / (?s)
  _Any(this.matchesNewline);
  @override
  bool test(int code, bool isNewline) => matchesNewline || !isNewline;
}

/// A compiled NFA program (parallel arrays + a matcher side-table).
class NfaProgram {
  final Int32List op;
  final Int32List a;
  final Int32List b;
  final List<NfaMatcher?> m;
  final int startPc;
  final int nSlots; // 2 * (numMem + 1)
  NfaProgram(this.op, this.a, this.b, this.m, this.startPc, this.nSlots);
}

class _Builder {
  final OnigEncoding enc;
  final int numMem;
  final List<int> op = [];
  final List<int> a = [];
  final List<int> b = [];
  final List<NfaMatcher?> m = [];
  _Builder(this.enc, this.numMem);

  int get here => op.length;

  int _emit(int opc, [int aa = 0, int bb = 0, NfaMatcher? mm]) {
    if (op.length >= _maxProg) throw const _Bail();
    op.add(opc);
    a.add(aa);
    b.add(bb);
    m.add(mm);
    return op.length - 1;
  }

  void compile(Node? node) {
    if (node == null) return;
    switch (node) {
      case StrNode():
        if (node.isCrude || node.st(NdSt.ignoreCase)) throw const _Bail();
        final bytes = node.bytes;
        var i = 0;
        while (i < bytes.length) {
          var len = enc.length(bytes, i, bytes.length);
          if (len < 1) len = 1;
          final code = enc.mbcToCode(bytes, i, bytes.length);
          _emit(_cChar, 0, 0, _Lit(code));
          i += len;
        }
      case CClassNode():
        _emit(_cChar, 0, 0, _CC(node.bs, node.mbuf, node.isNot, enc));
      case CtypeNode():
        if (node.ctype == -1) {
          // anychar `.`
          _emit(_cChar, 0, 0, _Any(node.st(NdSt.multiLine)));
        } else if (node.ctype == CType.word) {
          // \w / \W — same code-point test as OP_WORD (`enc.isCodeCtype`).
          _emit(_cChar, 0, 0, _Ct(node.ctype, node.not, node.asciiMode, enc));
        } else {
          // \X (ctype -2, a multi-code-point grapheme) and \d/\s/etc. (compiled
          // to a bitset class we don't reconstruct here) → fall back.
          throw const _Bail();
        }
      case QuantNode():
        _compileQuant(node);
      case BagNode():
        if (node.type != BagType.memory) throw const _Bail();
        _emit(_cSave, 2 * node.regNum);
        compile(node.body);
        _emit(_cSave, 2 * node.regNum + 1);
      case AltNode():
        _compileAlt(node);
      case ListNode():
        Node? c = node;
        while (c is ListNode) {
          compile(c.car);
          c = c.cdr;
        }
        compile(c);
      case AnchorNode():
        if (node.body != null) throw const _Bail();
        switch (node.type) {
          case Anchor.beginBuf:
          case Anchor.beginLine:
          case Anchor.endBuf:
          case Anchor.endLine:
          case Anchor.semiEndBuf:
          case Anchor.wordBoundary:
          case Anchor.noWordBoundary:
            _emit(_cAssert, node.type, node.asciiMode ? 1 : 0);
          default:
            throw const _Bail();
        }
      case BackRefNode():
        throw const _Bail();
      case CallNode():
        throw const _Bail();
      case GimmickNode():
        throw const _Bail();
    }
  }

  void _compileAlt(AltNode node) {
    final branches = <Node>[];
    Node? c = node;
    while (c is AltNode) {
      branches.add(c.car);
      c = c.cdr;
    }
    if (c != null) branches.add(c);
    final jmpEnds = <int>[];
    for (var i = 0; i < branches.length; i++) {
      if (i < branches.length - 1) {
        final sp = _emit(_cSplit); // a = this branch (fall-through), b = next
        a[sp] = sp + 1;
        compile(branches[i]);
        jmpEnds.add(_emit(_cJmp));
        b[sp] = here; // next branch starts here
      } else {
        compile(branches[i]);
      }
    }
    final end = here;
    for (final j in jmpEnds) {
      a[j] = end;
    }
  }

  void _compileQuant(QuantNode node) {
    final body = node.body;
    if (body == null || _canBeEmpty(body)) throw const _Bail();
    final lo = node.lower;
    final hi = node.upper; // infiniteRepeat (-1) = unbounded
    if (lo > _maxExpand || (hi != infiniteRepeat && hi - lo > _maxExpand)) {
      throw const _Bail();
    }
    for (var k = 0; k < lo; k++) {
      compile(body);
    }
    if (hi == infiniteRepeat) {
      // greedy: L: split(body, end); body; jmp L; end:
      final l = here;
      final sp = _emit(_cSplit);
      compile(body);
      final j = _emit(_cJmp);
      a[j] = l;
      final end = here;
      if (node.greedy) {
        a[sp] = sp + 1;
        b[sp] = end;
      } else {
        a[sp] = end;
        b[sp] = sp + 1;
      }
    } else {
      final splits = <int>[];
      for (var k = 0; k < hi - lo; k++) {
        splits.add(_emit(_cSplit));
        compile(body);
      }
      final end = here;
      for (final sp in splits) {
        if (node.greedy) {
          a[sp] = sp + 1;
          b[sp] = end;
        } else {
          a[sp] = end;
          b[sp] = sp + 1;
        }
      }
    }
  }

  NfaProgram finish() => NfaProgram(Int32List.fromList(op), Int32List.fromList(a),
      Int32List.fromList(b), m, 0, 2 * (numMem + 1));
}

/// True if [node] can match the empty string (used to reject quantifiers whose
/// body may be empty — those have subtle empty-check semantics we don't model).
bool _canBeEmpty(Node? node) {
  if (node == null) return true;
  switch (node) {
    case StrNode():
      return node.len == 0;
    case CClassNode():
    case CtypeNode():
      return false; // always consumes exactly one char
    case QuantNode():
      return node.lower == 0 || _canBeEmpty(node.body);
    case BagNode():
      return node.type == BagType.ifElse ? true : _canBeEmpty(node.body);
    case AltNode():
      Node? c = node;
      while (c is AltNode) {
        if (_canBeEmpty(c.car)) return true;
        c = c.cdr;
      }
      return _canBeEmpty(c);
    case ListNode():
      Node? c = node;
      while (c is ListNode) {
        if (!_canBeEmpty(c.car)) return false;
        c = c.cdr;
      }
      return _canBeEmpty(c);
    case AnchorNode():
      return true; // zero-width
    case BackRefNode():
    case CallNode():
    case GimmickNode():
      return true; // conservatively empty (also unsupported → bail)
  }
}

/// Effective options whose *search-time* semantics the Pike VM does not model.
/// If any is set (in the search option or `reg.options`), the driver must fall
/// back to the backtracking engine even when an NFA program exists:
///  - findLongest      — leftmost-longest, not leftmost-first
///  - findNotEmpty     — empty matches suppressed
///  - matchWholeString — the match must span the whole string
///  - posixRegion      — a different region layout
///  - ignoreCase*      — case folding (incl. multi-char)
///  - checkValidity*   — input-encoding validation may reject/alter results
const int nfaUnsafeOptions = OnigOption.findLongest |
    OnigOption.findNotEmpty |
    OnigOption.matchWholeString |
    OnigOption.posixRegion |
    OnigOption.ignoreCase |
    OnigOption.ignoreCaseIsAscii |
    OnigOption.checkValidityOfString;

/// True if [node] can itself branch/repeat (a quantifier or alternation),
/// looking through groups/lists — the shape that, nested under a quantifier,
/// causes exponential backtracking.
bool _canBranch(Node? node) {
  switch (node) {
    case QuantNode():
    case AltNode():
      return true;
    case BagNode():
      return _canBranch(node.body) ||
          _canBranch(node.then_) ||
          _canBranch(node.else_);
    case ListNode():
      Node? c = node;
      while (c is ListNode) {
        if (_canBranch(c.car)) return true;
        c = c.cdr;
      }
      return _canBranch(c);
    case AnchorNode():
      return _canBranch(node.body);
    default:
      return false;
  }
}

/// True if [node] contains a quantifier whose body can itself branch/repeat —
/// i.e. nested repetition, the classic super-linear-backtracking hazard
/// (`(a+)+`, `(a|ab)*`). Flat / single-level patterns are linear under the
/// backtracking VM and keep its literal/map prefilters, so only these "risky"
/// patterns are worth diverting to the NFA.
bool _isRisky(Node? node) {
  switch (node) {
    case QuantNode():
      return _canBranch(node.body) || _isRisky(node.body);
    case BagNode():
      return _isRisky(node.body) ||
          _isRisky(node.then_) ||
          _isRisky(node.else_);
    case ListNode():
      Node? c = node;
      while (c is ListNode) {
        if (_isRisky(c.car)) return true;
        c = c.cdr;
      }
      return _isRisky(c);
    case AltNode():
      Node? c = node;
      while (c is AltNode) {
        if (_isRisky(c.car)) return true;
        c = c.cdr;
      }
      return _isRisky(c);
    case AnchorNode():
      return _isRisky(node.body);
    default:
      return false;
  }
}

/// Compile [root] to an NFA program, or return `null` if the pattern is not
/// worth diverting from the backtracking VM (not prone to super-linear
/// backtracking) or uses any construct outside the safe subset.
NfaProgram? buildNfa(Regex reg, Node? root) {
  if ((reg.options & OnigOption.ignoreCase) != 0) return null;
  // Only take over patterns that could backtrack super-linearly; flat patterns
  // are faster on the backtracking VM (literal/BMH/map/anchor prefilters).
  if (!_isRisky(root)) return null;
  final b = _Builder(reg.enc, reg.numMem);
  try {
    b._emit(_cSave, 0); // group 0 start
    b.compile(root);
    b._emit(_cSave, 1); // group 0 end
    b._emit(_cMatch);
  } on _Bail {
    return null;
  }
  return b.finish();
}

/// A Pike-VM thread list: closed program counters (only `_cChar`/`_cMatch`) in
/// priority order, each with its own capture slots, plus a generation-stamped
/// membership set for O(1) dedup per input position.
class _TL {
  final List<int> pc = [];
  final List<List<int>> caps = [];
  final Int32List seen;
  int gen = 0;
  _TL(int progLen) : seen = Int32List(progLen);
}

/// Run the Pike VM: find the leftmost match whose start is in `[start, range]`,
/// filling [region] and returning the match-start byte offset, or
/// [OnigResult.mismatch]. Behaviour matches the backtracking VM on the subset
/// [buildNfa] accepts.
int nfaSearch(NfaProgram prog, Regex reg, Uint8List str, int end, int start,
    int range, OnigRegion? region, int option) {
  final enc = reg.enc;
  final nSlots = prog.nSlots;
  final op = prog.op, pa = prog.a, pb = prog.b, mm = prog.m;

  int prevHead(int sp) => enc.leftAdjustCharHead(str, 0, sp - 1);
  bool isWord(int code, bool ascii) =>
      ascii ? asciiIsCodeCtype(code, CType.word) : enc.isCodeCtype(code, CType.word);
  bool wordBoundary(int sp, bool ascii) {
    final left = sp > 0 && isWord(enc.mbcToCode(str, prevHead(sp), end), ascii);
    final right = sp < end && isWord(enc.mbcToCode(str, sp, end), ascii);
    return left != right;
  }

  bool assertOk(int type, bool ascii, int sp) {
    switch (type) {
      case Anchor.beginBuf:
        return sp == 0 &&
            (option & OnigOption.notBol) == 0 &&
            (option & OnigOption.notBeginString) == 0;
      case Anchor.beginLine:
        if (sp == 0) return (option & OnigOption.notBol) == 0;
        return sp != end && enc.isMbcNewline(str, prevHead(sp), end);
      case Anchor.endBuf:
        return sp == end &&
            (option & OnigOption.notEol) == 0 &&
            (option & OnigOption.notEndString) == 0;
      case Anchor.endLine:
        if (sp == end) return (option & OnigOption.notEol) == 0;
        return enc.isMbcNewline(str, sp, end);
      case Anchor.semiEndBuf:
        final okEnd = (option & OnigOption.notEol) == 0 &&
            (option & OnigOption.notEndString) == 0;
        if (sp == end) return okEnd;
        if (enc.isMbcNewline(str, sp, end) &&
            sp + enc.length(str, sp, end) == end) {
          return okEnd;
        }
        return false;
      case Anchor.wordBoundary:
        return wordBoundary(sp, ascii);
      case Anchor.noWordBoundary:
        return !wordBoundary(sp, ascii);
      default:
        return false;
    }
  }

  // Epsilon-closure: add [startPc] (following split/jmp/save/assert) to [list],
  // appending reached _cChar/_cMatch states in priority order. Explicit stack to
  // avoid deep recursion on large programs.
  final stackPc = <int>[];
  final stackCaps = <List<int>>[];
  void addThread(_TL list, int startPc, List<int> startCaps, int sp) {
    stackPc.add(startPc);
    stackCaps.add(startCaps);
    while (stackPc.isNotEmpty) {
      final pc = stackPc.removeLast();
      final caps = stackCaps.removeLast();
      if (list.seen[pc] == list.gen) continue;
      list.seen[pc] = list.gen;
      switch (op[pc]) {
        case _cJmp:
          stackPc.add(pa[pc]);
          stackCaps.add(caps);
        case _cSplit:
          // Push low priority first so high priority (a) pops/DFS first.
          stackPc.add(pb[pc]);
          stackCaps.add(caps);
          stackPc.add(pa[pc]);
          stackCaps.add(caps);
        case _cSave:
          final nc = List<int>.of(caps);
          nc[pa[pc]] = sp;
          stackPc.add(pc + 1);
          stackCaps.add(nc);
        case _cAssert:
          if (assertOk(pa[pc], pb[pc] == 1, sp)) {
            stackPc.add(pc + 1);
            stackCaps.add(caps);
          }
        default: // _cChar / _cMatch
          list.pc.add(pc);
          list.caps.add(caps);
      }
    }
  }

  var cur = _TL(op.length)..gen = 1;
  var next = _TL(op.length)..gen = 0;
  var sp = start;
  List<int>? matched;

  while (true) {
    final hasChar = sp < end;
    var clen = 1;
    var code = 0;
    var isNL = false;
    if (hasChar) {
      clen = enc.length(str, sp, end);
      if (clen < 1) clen = 1;
      code = enc.mbcToCode(str, sp, end);
      isNL = enc.isMbcNewline(str, sp, end);
    }

    // Seed a new start thread (lowest priority) until a match is found.
    if (matched == null && sp <= range) {
      addThread(cur, prog.startPc, List<int>.filled(nSlots, -1), sp);
    }

    next.pc.clear();
    next.caps.clear();
    next.gen++;
    for (var i = 0; i < cur.pc.length; i++) {
      final pc = cur.pc[i];
      if (op[pc] == _cMatch) {
        matched = cur.caps[i]; // higher priority overrides earlier matches
        break; // cut lower-priority threads at this position
      }
      // _cChar
      if (hasChar && mm[pc]!.test(code, isNL)) {
        addThread(next, pc + 1, cur.caps[i], sp + clen);
      }
    }

    if (!hasChar) break;
    final tmp = cur;
    cur = next;
    next = tmp;
    sp += clen;
    if (cur.pc.isEmpty && (matched != null || sp > range)) break;
  }

  if (matched == null) return OnigResult.mismatch;
  if (region != null) {
    region.resize(reg.numMem + 1);
    for (var i = 0; i <= reg.numMem; i++) {
      region.beg[i] = matched[2 * i];
      region.end[i] = matched[2 * i + 1];
    }
  }
  return matched[0];
}
