/// Compiled bytecode: opcodes (`enum OpCode`, regint.h) and the [Operation]
/// instruction record.
///
/// The C `Operation` is a tagged union of an opcode + typed args. Here it is a
/// single `final` class with an `int opcode` dispatched by a `switch` in the
/// executor (the direct-threaded variant is not portable to Dart). Fields are
/// flattened from the union; each opcode reads only the fields it needs.
library;

import 'dart:typed_data';

import '../parse/node.dart' show BitSet, CodeRangeBuffer;

/// Opcode ids. Values match the C `enum OpCode` with all default-build feature
/// macros (USE_CALL, USE_CALLOUT, USE_BACKREF_WITH_LEVEL, USE_OP_PUSH_OR_JUMP_EXACT)
/// enabled, so numbering is contiguous and identical to the compiled library.
abstract final class Op {
  static const int finish = 0;
  static const int end = 1;
  static const int str1 = 2;
  static const int str2 = 3;
  static const int str3 = 4;
  static const int str4 = 5;
  static const int str5 = 6;
  static const int strN = 7;
  static const int strMb2n1 = 8;
  static const int strMb2n2 = 9;
  static const int strMb2n3 = 10;
  static const int strMb2n = 11;
  static const int strMb3n = 12;
  static const int strMbn = 13;
  static const int cclass = 14;
  static const int cclassMb = 15;
  static const int cclassMix = 16;
  static const int cclassNot = 17;
  static const int cclassMbNot = 18;
  static const int cclassMixNot = 19;
  static const int anychar = 20;
  static const int anycharMl = 21;
  static const int anycharStar = 22;
  static const int anycharMlStar = 23;
  static const int anycharStarPeekNext = 24;
  static const int anycharMlStarPeekNext = 25;
  static const int word = 26;
  static const int wordAscii = 27;
  static const int noWord = 28;
  static const int noWordAscii = 29;
  static const int wordBoundary = 30;
  static const int noWordBoundary = 31;
  static const int wordBegin = 32;
  static const int wordEnd = 33;
  static const int textSegmentBoundary = 34;
  static const int beginBuf = 35;
  static const int endBuf = 36;
  static const int beginLine = 37;
  static const int endLine = 38;
  static const int semiEndBuf = 39;
  static const int checkPosition = 40;
  static const int backref1 = 41;
  static const int backref2 = 42;
  static const int backrefN = 43;
  static const int backrefNIc = 44;
  static const int backrefMulti = 45;
  static const int backrefMultiIc = 46;
  static const int backrefWithLevel = 47;
  static const int backrefWithLevelIc = 48;
  static const int backrefCheck = 49;
  static const int backrefCheckWithLevel = 50;
  static const int memStart = 51;
  static const int memStartPush = 52;
  static const int memEndPush = 53;
  static const int memEndPushRec = 54;
  static const int memEnd = 55;
  static const int memEndRec = 56;
  static const int fail = 57;
  static const int jump = 58;
  static const int push = 59;
  static const int pushSuper = 60;
  static const int pop = 61;
  static const int popToMark = 62;
  static const int pushOrJumpExact1 = 63;
  static const int pushIfPeekNext = 64;
  static const int repeat = 65;
  static const int repeatNg = 66;
  static const int repeatInc = 67;
  static const int repeatIncNg = 68;
  static const int emptyCheckStart = 69;
  static const int emptyCheckEnd = 70;
  static const int emptyCheckEndMemst = 71;
  static const int emptyCheckEndMemstPush = 72;
  static const int move = 73;
  static const int stepBackStart = 74;
  static const int stepBackNext = 75;
  static const int cutToMark = 76;
  static const int mark = 77;
  static const int saveVal = 78;
  static const int updateVar = 79;
  static const int call = 80;
  static const int returnOp = 81;
  static const int calloutContents = 82;
  static const int calloutName = 83;

  // Dart-specific synthesis (C compiles \X to a subtree; we use one opcode).
  static const int extendedGraphemeCluster = 90;

  // Dart-specific greedy-repeat fast loop (like C's OP_ANYCHAR_STAR, generalized
  // to single-char classes/ctypes): scans the whole run in a tight loop and
  // pushes ONE decrement-on-backtrack frame instead of one alt frame per char.
  // Emitted immediately before its (unchanged) single body op; exit is pc+2.
  static const int starGreedy = 91;

  // Dart-specific alternation first-byte quick-check: if str[s]'s byte is not in
  // the branch's (complete over-approximated) first-byte set, jump past the
  // branch (addr) instead of PUSHing + entering it and failing. The set lives in
  // `bs`. Only emitted for non-nullable branches with a determinable set.
  static const int peekByte = 92;
}

/// SaveType (`enum SaveType`).
abstract final class SaveType {
  static const int keep = 0;
  static const int s = 1;
  static const int rightRange = 2;
}

/// UpdateVarType (`enum UpdateVarType`).
abstract final class UpdateVarType {
  static const int keepFromStackLast = 0;
  static const int sFromStack = 1;
  static const int rightRangeFromStack = 2;
  static const int rightRangeFromSStack = 3;
  static const int rightRangeToS = 4;
  static const int rightRangeInit = 5;
}

/// CheckPositionType (`enum CheckPositionType`).
abstract final class CheckPositionType {
  static const int searchStart = 0;
  static const int currentRightRange = 1;
}

/// TextSegmentBoundaryType.
abstract final class TextSegmentBoundaryType {
  static const int extendedGraphemeCluster = 0;
  static const int word = 1;
}

/// One compiled instruction. `opcode` selects which fields are meaningful.
///
/// Relative addresses ([addr]) are op-index offsets from this op's own slot
/// (`pc += addr`), matching the C convention where every `OPSIZE_*` is 1.
final class Operation {
  int opcode;

  // Relative / absolute address for jump/push/repeat/call/step-back.
  int addr = 0;

  // Generic small integer args (meaning depends on opcode).
  int id = 0; // mark / cut / pop_to_mark / repeat id / save id / callout id
  int mem = 0; // memory number / empty-check mem / backref single n
  int num = 0; // counts (backref count, callout num)
  int len = 0; // look-behind len / step-back initial
  int c = 0; // peek char / move distance / remaining
  int flag = 0; // mode / not / save_pos / restore_pos / clear / type
  int flag2 = 0; // secondary flag (empty_status_mem, etc.)

  // Object payloads.
  Uint8List? str; // exact bytes (OP_STR_*)
  int strLen = 0; // byte length of str
  int strN = 0; // char count of str
  BitSet? bs; // cclass bitset
  CodeRangeBuffer? mb; // cclass multibyte ranges
  List<int>? ns; // multi backref group list

  // callout payload (OP_CALLOUT_*)
  String? calloutName;
  String? calloutContents;
  String? calloutTag;
  List<String>? calloutArgs;

  Operation(this.opcode);
}

/// The [Operation] stream decomposed into parallel arrays — flat `Int32List`
/// slots for the scalar fields, typed lists for the object payloads. The
/// executor's hot loop reads `code[pc]`, `opFlag[pc]`, … directly instead of
/// chasing a pointer to a heap [Operation] object on every instruction (one
/// array load per field instead of an array load *plus* an object deref).
///
/// Callout string payloads are rare (callout opcodes only) and are left on the
/// original [Operation] list, which [Regex] still keeps for cold paths.
class FlatOps {
  /// Slot stride and scalar-field offsets within [scalars]: op `i`'s fields live
  /// contiguously at `scalars[i * stride + offset]` (one cache line per op).
  static const int stride = 11;
  static const int oOpcode = 0;
  static const int oAddr = 1;
  static const int oId = 2;
  static const int oMem = 3;
  static const int oNum = 4;
  static const int oLen = 5;
  static const int oC = 6;
  static const int oFlag = 7;
  static const int oFlag2 = 8;
  static const int oStrLen = 9;
  static const int oStrN = 10;

  /// Interleaved scalar fields, `stride` ints per op.
  final Int32List scalars;
  // Object payloads, indexed by op-index (still one pointer, but no per-op
  // Operation deref in the hot loop).
  final List<Uint8List?> str;
  final List<BitSet?> bs;
  final List<CodeRangeBuffer?> mb;
  final List<List<int>?> ns;

  FlatOps._(this.scalars, this.str, this.bs, this.mb, this.ns);

  factory FlatOps.from(List<Operation> ops) {
    final n = ops.length;
    final scalars = Int32List(n * stride);
    final str = List<Uint8List?>.filled(n, null);
    final bs = List<BitSet?>.filled(n, null);
    final mb = List<CodeRangeBuffer?>.filled(n, null);
    final ns = List<List<int>?>.filled(n, null);
    for (var i = 0; i < n; i++) {
      final o = ops[i];
      final b = i * stride;
      scalars[b + oOpcode] = o.opcode;
      scalars[b + oAddr] = o.addr;
      scalars[b + oId] = o.id;
      scalars[b + oMem] = o.mem;
      scalars[b + oNum] = o.num;
      scalars[b + oLen] = o.len;
      scalars[b + oC] = o.c;
      scalars[b + oFlag] = o.flag;
      scalars[b + oFlag2] = o.flag2;
      scalars[b + oStrLen] = o.strLen;
      scalars[b + oStrN] = o.strN;
      str[i] = o.str;
      bs[i] = o.bs;
      mb[i] = o.mb;
      ns[i] = o.ns;
    }
    return FlatOps._(scalars, str, bs, mb, ns);
  }
}

/// A `{lower, upper}` counted-repeat descriptor indexed by repeat id
/// (`RepeatRange`). [bodyAddr] is the op index of the repeated body.
class RepeatRange {
  int lower;
  int upper;
  int bodyAddr;
  RepeatRange(this.lower, this.upper, this.bodyAddr);
}
