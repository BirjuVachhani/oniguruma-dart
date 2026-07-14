/// Backtracking stack for the executor (`StackType`, regexec.c).
///
/// Struct-of-arrays layout in growable typed lists with a single stack pointer
/// [sp]. This is the key performance decision: pushes touch preallocated typed
/// arrays with **zero per-push object allocation**, unlike a `List<StackEntry>`.
library;

import 'dart:typed_data';

/// Stack entry kinds. Only [alt] is a resume point (restores pc + string pos on
/// backtrack); the others carry undo information applied while unwinding.
abstract final class Stk {
  static const int voided =
      0; // cut-to-mark blanked a choice point (skip on pop)
  static const int alt = 1; // backtrack point: resume at (pc, s)
  static const int memStart = 2; // restore mem_start_stk[zid]
  static const int memEnd = 3; // restore mem_end_stk[zid]
  static const int emptyCheck = 4; // record string pos for null-loop check
  static const int mark = 5; // position marker (atomic / look-around)
  static const int repeatInc = 6; // counted-repeat counter frame
  static const int callFrame = 7; // subexp call return frame
  static const int returnMark = 8; // marks a consumed call frame (reversible)
  static const int saveVal =
      9; // saved right_range value (variable look-behind)
  static const int stepBack = 10; // look-behind step-back retry point
  static const int callout = 11; // callout retraction frame (re-fire on undo)
}

class MatchStack {
  static const int _initCap = 128;

  Int32List type;
  Int32List zid; // group / mark / empty-check id
  Int32List pc; // op index (alt resume / mark)
  Int32List str; // string position (mem-start position for backref-with-level)
  Int32List x1; // prev value (mem restore) / count / prev-index
  Int32List x2; // secondary (mem-end position for backref-with-level)
  int sp = 0;

  MatchStack()
    : type = Int32List(_initCap),
      zid = Int32List(_initCap),
      pc = Int32List(_initCap),
      str = Int32List(_initCap),
      x1 = Int32List(_initCap),
      x2 = Int32List(_initCap);

  void reset() => sp = 0;

  void _grow() {
    final n = type.length << 1;
    type = _copy(type, n);
    zid = _copy(zid, n);
    pc = _copy(pc, n);
    str = _copy(str, n);
    x1 = _copy(x1, n);
    x2 = _copy(x2, n);
  }

  static Int32List _copy(Int32List src, int n) {
    final dst = Int32List(n);
    dst.setRange(0, src.length, src);
    return dst;
  }

  void push(int t, int z, int p, int s, int e1) {
    if (sp >= type.length) _grow();
    final i = sp++;
    type[i] = t;
    zid[i] = z;
    pc[i] = p;
    str[i] = s;
    x1[i] = e1;
  }

  void pushAlt(int p, int s) => push(Stk.alt, 0, p, s, 0);
}
