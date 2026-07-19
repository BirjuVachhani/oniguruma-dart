/// The compiled regex object (`regex_t` / `re_pattern_buffer`, regint.h) and
/// the top-level compile entry point (`onig_new` / `onig_compile`).
library;

import 'dart:typed_data';

import 'compile/compiler.dart';
import 'compile/operation.dart';
import 'encoding/encoding.dart';
import 'exec/nfa.dart';
import 'onig_errors.dart';
import 'onig_types.dart';
import 'parse/node.dart' show BitSet, CodeRangeBuffer;
import 'parse/parser.dart';
import 'syntax.dart';

/// A compiled pattern: the bytecode plus the metadata the executor needs.
class Regex {
  /// Compiled instruction stream (kept for compilation + cold paths).
  List<Operation> ops = <Operation>[];

  /// [ops] flattened into parallel arrays for the executor's hot loop.
  late FlatOps flat;

  /// Number of capture groups (counted from 1); registers = numMem + 1.
  int numMem = 0;

  /// Number of *named* capture groups (used to reject numbered backrefs).
  int numNamed = 0;

  /// Counters allocated during compilation.
  int numRepeat = 0;
  int numEmptyCheck = 0;
  int numCall = 0;

  /// `{lower,upper,bodyAddr}` per repeat id.
  List<RepeatRange> repeatRanges = <RepeatRange>[];

  /// Group name → group numbers.
  Map<String, List<int>> nameTable = <String, List<int>>{};

  /// Group number → its AST node (index 0 unused). Used for subexp calls.
  List<Object?> memNodes = <Object?>[null];

  final OnigEncoding enc;
  final OnigSyntax syntax;
  int options;
  int caseFoldFlag;

  /// Linear-time NFA fast path for the safe subset (null ⇒ use backtracking).
  NfaProgram? nfa;

  // --- search-start optimization (set by the optimizer) -------------------
  int optimize = 0; // Optimize.*
  int anchor = 0; // ANCR_* aggregate
  int ancDistMin = 0;
  int ancDistMax = 0;
  int thresholdLen = 0;
  Uint8List? exact; // literal prefix for BMH/quick search
  Uint16List? exactSkip; // Sunday/BMH bad-char skip table for [exact]
  // The whole pattern IS the exact literal (no captures, anchors, or trailing
  // ops): a Sunday hit is the match, so the driver can fill the region directly
  // and skip the per-match matchAt re-verification.
  bool exactWholeMatch = false;
  Uint8List? exactIc; // ASCII-lower-folded needle for a case-insensitive search
  Uint16List? exactIcSkip; // Sunday skip table over [exactIc] (folded bytes)
  // Leading `C+ L…`: the match starts with a greedy one-or-more of char class C
  // immediately followed by the exact literal L (with L's first byte ∉ C). The
  // driver walks back from an L occurrence over C to the run start, the unique
  // leftmost candidate for that L, and tries matchAt there once, instead of
  // every position in the gap (turns `\w+@\w+`'s O(n) attempts into O(#L)).
  bool hasExactBack = false;
  int exactBackCtype = -1; // >=0: ctype id (word/digit/space/…); -1: use bs/mb
  bool exactBackCtypeAscii = false; // ctype restricted to ASCII members
  BitSet? exactBackBs; // char-class members < 0x100
  CodeRangeBuffer? exactBackMb; // char-class multibyte members
  bool exactAnchorAnyChar = false; // leading greedy `.*` (ANCR_ANYCHAR_INF)
  bool exactAnchorAnyCharMl = false; // leading greedy `(?s).*` (crosses lines)
  Uint8List? map; // 256-entry char map / BMH skip
  int mapOffset = 0;
  // A leading zero-width `\b` (word boundary) is present, so the driver may
  // skip any candidate where str[s] and str[s-1] are both ASCII word chars:
  // `\b` is provably false there, so matchAt would mismatch without entering.
  bool leadingWordBoundary = false;
  int distMin = 0;
  int distMax = 0;
  int subAnchor = 0;

  Regex(this.enc, this.syntax, this.options, this.caseFoldFlag);
}

/// Case-fold flag bits (`oniguruma.h`).
const int caseFoldAsciiOnly = 1; // ONIGENC_CASE_FOLD_ASCII_ONLY
const int caseFoldTurkishAzeri = 1 << 20; // ONIGENC_CASE_FOLD_TURKISH_AZERI
const int caseFoldMultiChar = 1 << 30; // INTERNAL_ONIGENC_CASE_FOLD_MULTI_CHAR

/// Case-fold flag default (`ONIGENC_CASE_FOLD_MIN` = MULTI_CHAR): full Unicode
/// folding with multi-char (ß↔ss) folds enabled.
const int onigCaseFoldDefault = caseFoldMultiChar;

/// Compile [pattern] `[0,end)` into a [Regex] (`onig_new` / `onig_compile`).
/// Throws [OnigException] on any parse/compile failure.
Regex onigNew(
  Uint8List pattern,
  int end,
  OnigEncoding enc,
  OnigSyntax syntax,
  int options, {
  int caseFoldFlag = onigCaseFoldDefault,
}) {
  // `onig_reg_init`: merge the syntax's default options (e.g. Perl/Python set
  // SINGLE_LINE so ^/$ mean \A/\Z). NEGATE_SINGLELINE flips that default off.
  if ((options & OnigOption.negateSingleLine) != 0) {
    options |= syntax.options;
    options &= ~OnigOption.singleLine;
  } else {
    options |= syntax.options;
  }

  // `onig_reg_init`: ONIG_OPTION_IGNORECASE_IS_ASCII restricts folding to
  // ASCII and disables multi-char / Turkish-Azeri folds.
  if ((options & OnigOption.ignoreCaseIsAscii) != 0) {
    caseFoldFlag &= ~(caseFoldMultiChar | caseFoldTurkishAzeri);
    caseFoldFlag |= caseFoldAsciiOnly;
  }
  try {
    final parsed = parseTree(pattern, end, enc, syntax, options, caseFoldFlag);
    // `set_whole_options`: `(?I/L/C)` options apply to the entire regex.
    if ((parsed.wholeOptions & OnigOption.ignoreCaseIsAscii) != 0) {
      caseFoldFlag &= ~(caseFoldMultiChar | caseFoldTurkishAzeri);
      caseFoldFlag |= caseFoldAsciiOnly;
    }
    final reg = Regex(enc, syntax, options | parsed.wholeOptions, caseFoldFlag)
      ..numMem = parsed.numMem
      ..numNamed = parsed.numNamed
      ..nameTable = parsed.nameTable
      ..memNodes = parsed.memNodes;
    compile(reg, parsed.root);
    return reg;
  } on ParseError catch (e) {
    throw OnigException(e.code, detail: e.detail);
  }
}
