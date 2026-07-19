/// Parser AST node types (`regparse.h`).
///
/// The C `Node` is a tagged union; here it is a sealed class hierarchy. Node
/// kinds: String, CClass, Ctype, BackRef, Quant, Bag, Anchor, List, Alt, Call,
/// Gimmick. `List`/`Alt` are cons cells (car/cdr) as in the C source, so the
/// compiler's `car`/`cdr` traversals and splice operations port directly.
library;

import 'dart:typed_data';

import '../onig_types.dart';

/// Node status flags (`ND_ST_*`).
abstract final class NdSt {
  static const int fixedMin = 1 << 0;
  static const int fixedMax = 1 << 1;
  static const int fixedClen = 1 << 2;
  static const int mark1 = 1 << 3;
  static const int mark2 = 1 << 4;
  static const int strictRealRepeat = 1 << 5;
  static const int recursion = 1 << 6;
  static const int called = 1 << 7;
  static const int fixedAddr = 1 << 8;
  static const int namedGroup = 1 << 9;
  static const int inRealRepeat = 1 << 10;
  static const int inZeroRepeat = 1 << 11;
  static const int inMultiEntry = 1 << 12;
  static const int nestLevel = 1 << 13;
  static const int byNumber = 1 << 14;
  static const int byName = 1 << 15;
  static const int backref = 1 << 16;
  static const int checker = 1 << 17;
  static const int prohibitRecursion = 1 << 18;
  static const int superNd = 1 << 19;
  static const int emptyStatusCheck = 1 << 20;
  static const int ignoreCase = 1 << 21;
  static const int multiLine = 1 << 22;
  static const int textSegmentWord = 1 << 23;
  static const int absentWithSideEffects = 1 << 24;
  static const int fixedClenMinSure = 1 << 25;
  static const int referenced = 1 << 26;
  static const int inPeek = 1 << 27;
  static const int wholeOptions = 1 << 28;
}

/// Bag subtypes (`enum BagType`).
enum BagType { memory, option, stopBacktrack, ifElse }

/// Gimmick subtypes (`enum GimmickType`).
enum GimmickType { fail, save, updateVar, callout }

/// Quantifier body-emptiness (`enum BodyEmptyType`).
enum BodyEmpty { notEmpty, mayBeEmpty, mayBeEmptyMem, mayBeEmptyRec }

const int _bufSize = 24; // ND_STRING_BUF_SIZE

/// String node flags (`ND_STRING_*`).
const int strFlagCrude = 1 << 0;
const int strFlagCaseExpanded = 1 << 1;

/// Base sealed node.
sealed class Node {
  int status = 0;
  Node? parent;

  bool st(int flag) => (status & flag) != 0;
  void setSt(int flag) => status |= flag;
  void clearSt(int flag) => status &= ~flag;
}

/// A run of literal bytes (`StrNode`, `ND_STRING`).
final class StrNode extends Node {
  /// Accumulated bytes. Grows as adjacent literals concatenate.
  Uint8List buf;
  int len;
  int flag;

  StrNode() : buf = Uint8List(_bufSize), len = 0, flag = 0;

  bool get isCrude => (flag & strFlagCrude) != 0;
  bool get isCaseExpanded => (flag & strFlagCaseExpanded) != 0;
  void setCrude() => flag |= strFlagCrude;
  void setCaseExpanded() => flag |= strFlagCaseExpanded;

  /// Bytes as a view of [buf] of exactly [len].
  Uint8List get bytes => Uint8List.sublistView(buf, 0, len);

  void _ensure(int need) {
    if (need > buf.length) {
      var cap = buf.length;
      while (cap < need) {
        cap <<= 1;
      }
      final nb = Uint8List(cap);
      nb.setRange(0, len, buf);
      buf = nb;
    }
  }

  void catByte(int b) {
    _ensure(len + 1);
    buf[len++] = b;
  }

  void catBytes(Uint8List src, int start, int end) {
    final n = end - start;
    _ensure(len + n);
    buf.setRange(len, len + n, src, start);
    len += n;
  }
}

/// A 256-bit set for single-byte class members (`BitSet`).
class BitSet {
  final Uint32List words = Uint32List(8); // BITSET_REAL_SIZE

  bool at(int i) => (words[i >> 5] & (1 << (i & 31))) != 0;
  void set(int i) => words[i >> 5] |= (1 << (i & 31));
  void clear(int i) => words[i >> 5] &= ~(1 << (i & 31));

  void setRange(int lo, int hi) {
    for (var i = lo; i <= hi; i++) {
      set(i);
    }
  }

  void invert() {
    for (var i = 0; i < 8; i++) {
      words[i] = ~words[i] & 0xffffffff;
    }
  }

  void clearAll() {
    for (var i = 0; i < 8; i++) {
      words[i] = 0;
    }
  }

  void orWith(BitSet other) {
    for (var i = 0; i < 8; i++) {
      words[i] |= other.words[i];
    }
  }

  void andWith(BitSet other) {
    for (var i = 0; i < 8; i++) {
      words[i] &= other.words[i];
    }
  }

  bool get isEmpty {
    for (var i = 0; i < 8; i++) {
      if (words[i] != 0) return false;
    }
    return true;
  }
}

/// A growable set of multi-byte code-point ranges (`BBuf` / `mbuf`), stored as
/// flat sorted, merged `[from, to]` pairs.
class CodeRangeBuffer {
  final List<int> ranges = <int>[]; // [from0,to0, from1,to1, ...]

  int get count => ranges.length >> 1;

  /// Complement of [r] (flat sorted `[lo,hi,...]`) over `[min,max]`.
  static List<int> complement(List<int> r, int min, int max) {
    final out = <int>[];
    var prev = min;
    for (var i = 0; i < r.length; i += 2) {
      final lo = r[i], hi = r[i + 1];
      if (lo > prev) {
        out
          ..add(prev)
          ..add(lo - 1);
      }
      if (hi + 1 > prev) prev = hi + 1;
    }
    if (prev <= max) {
      out
        ..add(prev)
        ..add(max);
    }
    return out;
  }

  /// Union of two flat sorted range lists.
  static List<int> union(List<int> a, List<int> b) {
    final buf = CodeRangeBuffer();
    for (var i = 0; i < a.length; i += 2) {
      buf.add(a[i], a[i + 1]);
    }
    for (var i = 0; i < b.length; i += 2) {
      buf.add(b[i], b[i + 1]);
    }
    return buf.ranges;
  }

  /// Intersection of two flat sorted range lists.
  static List<int> intersect(List<int> a, List<int> b) {
    final out = <int>[];
    var i = 0, j = 0;
    while (i < a.length && j < b.length) {
      final lo = a[i] > b[j] ? a[i] : b[j];
      final hi = a[i + 1] < b[j + 1] ? a[i + 1] : b[j + 1];
      if (lo <= hi) {
        out
          ..add(lo)
          ..add(hi);
      }
      if (a[i + 1] < b[j + 1]) {
        i += 2;
      } else {
        j += 2;
      }
    }
    return out;
  }

  /// `add_code_range`: insert [from,to], merging overlaps/adjacency.
  void add(int from, int to) {
    if (from > to) {
      final t = from;
      from = to;
      to = t;
    }
    // Find insert / merge position.
    var i = 0;
    while (i < ranges.length && ranges[i + 1] + 1 < from) {
      i += 2;
    }
    if (i >= ranges.length) {
      ranges.add(from);
      ranges.add(to);
      return;
    }
    // Merge with overlapping/adjacent ranges starting at i.
    var lo = from, hi = to;
    var j = i;
    while (j < ranges.length && ranges[j] <= hi + 1) {
      if (ranges[j] < lo) lo = ranges[j];
      if (ranges[j + 1] > hi) hi = ranges[j + 1];
      j += 2;
    }
    ranges.replaceRange(i, j, [lo, hi]);
  }

  bool contains(int code) {
    // Linear scan is fine for typical class sizes; ranges are sorted.
    for (var i = 0; i < ranges.length; i += 2) {
      if (code < ranges[i]) return false;
      if (code <= ranges[i + 1]) return true;
    }
    return false;
  }

  bool get isEmpty => ranges.isEmpty;
}

/// Character-class flags (`FLAG_NCCLASS_*`).
const int ccFlagNot = 1 << 0;
const int ccFlagShare = 1 << 1;

/// `[...]` character class (`CClassNode`, `ND_CCLASS`).
final class CClassNode extends Node {
  int flags = 0;
  final BitSet bs = BitSet();
  CodeRangeBuffer? mbuf; // multi-byte ranges, or null

  bool get isNot => (flags & ccFlagNot) != 0;
  void setNot() => flags |= ccFlagNot;
  void clearNot() => flags &= ~ccFlagNot;
}

/// `\d \w \s` etc. as a character-type test (`CtypeNode`, `ND_CTYPE`).
final class CtypeNode extends Node {
  int ctype;
  bool not;
  bool asciiMode;
  CtypeNode(this.ctype, {this.not = false, this.asciiMode = false});
}

const int backRefsInline = 6; // ND_BACKREFS_SIZE

/// `\1`, `\k<name>` back-reference (`BackRefNode`, `ND_BACKREF`).
final class BackRefNode extends Node {
  List<int> back; // group numbers
  int nestLevel = 0;
  bool hasLevel = false; // an explicit ±n level was given (e.g. \k<b+0>)
  bool ignoreCase = false; // captured span compared case-insensitively
  BackRefNode(this.back);
}

/// `*` `+` `?` `{n,m}` quantifier (`QuantNode`, `ND_QUANT`).
final class QuantNode extends Node {
  Node? body;
  int lower;
  int upper;
  bool greedy;
  BodyEmpty emptiness = BodyEmpty.notEmpty;
  Node? headExact;
  Node? nextHeadExact;
  bool includeReferred = false;
  int emptyStatusMem = 0;

  QuantNode(
    this.lower,
    this.upper, {
    this.greedy = true,
    bool byNumber = false,
  }) {
    if (byNumber) setSt(NdSt.byNumber);
  }

  bool get isByNumber => st(NdSt.byNumber);
}

/// Grouping construct (`BagNode`, `ND_BAG`): capture, option scope, atomic
/// group, or if-else conditional.
final class BagNode extends Node {
  Node? body;
  BagType type;

  // BAG_MEMORY
  int regNum = 0;
  int calledAddr = -1;
  int entryCount = 1;

  // BAG_OPTION
  int options = 0;

  // BAG_IF_ELSE
  Node? then_;
  Node? else_;

  // cached lengths (optimizer)
  int minLen = 0;
  int maxLen = 0;
  int minCharLen = 0;
  int maxCharLen = 0;
  int optCount = 0;

  BagNode(this.type);
}

/// Zero-width anchor / assertion (`AnchorNode`, `ND_ANCHOR`).
/// [type] holds `ANCR_*` bits; [body] is present for look-around.
final class AnchorNode extends Node {
  int type;
  Node? body;
  int charMinLen = 0;
  int charMaxLen = 0;
  bool asciiMode = false;
  Node? leadNode;
  AnchorNode(this.type);
}

/// Concatenation cons cell (`ND_LIST`): [car] then [cdr].
final class ListNode extends Node {
  Node car;
  Node? cdr;
  ListNode(this.car, [this.cdr]);
}

/// Alternation cons cell (`ND_ALT`): [car] `|` [cdr].
final class AltNode extends Node {
  Node car;
  Node? cdr;
  AltNode(this.car, [this.cdr]);
}

/// `\g<name>` subexpression call (`CallNode`, `ND_CALL`).
final class CallNode extends Node {
  Node? body; // target BagNode(BAG_MEMORY)
  bool byNumber;
  int calledGnum;
  String? name;
  int entryCount = 0;
  CallNode({this.byNumber = false, this.calledGnum = -1, this.name});
}

/// Side-effecting marker (`GimmickNode`, `ND_GIMMICK`): fail / \K save /
/// update-var / callout.
final class GimmickNode extends Node {
  GimmickType type;
  int detailType = 0;
  int num = 0;
  int id = 0;
  // callout payload (type == GimmickType.callout)
  bool calloutIsName = false;
  String? calloutName;
  String? calloutContents;
  String? calloutTag;
  List<String> calloutArgs = const [];
  GimmickNode(this.type);
}

// -- small constructors mirroring onig_node_new_* --------------------------

/// Build a right-leaning cons `ListNode` from [items].
Node? nodeNewListFrom(List<Node> items) {
  Node? tail;
  for (var i = items.length - 1; i >= 0; i--) {
    tail = ListNode(items[i], tail);
  }
  return tail;
}

/// A code point used as an anchor's implicit body etc.
typedef Cp = OnigCodePoint;
