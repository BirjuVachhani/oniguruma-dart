/// Core constants and small value types for the Oniguruma port.
///
/// Values mirror `oniguruma.h` / `regint.h` exactly so the engine behaves
/// identically to the C library. Grouped into `abstract final` namespaces of
/// `static const int` for zero-cost, monomorphic access in the hot path.
library;

/// A Unicode code point (C `OnigCodePoint`, an unsigned 32-bit value).
typedef OnigCodePoint = int;

/// A length in bytes (C `OnigLen`).
typedef OnigLen = int;

/// Sentinel for "infinite" length (`INFINITE_LEN` in regint.h).
const int infiniteLen = 0x7fffffff;

/// Repeat "infinity" (`INFINITE_REPEAT` = -1 in regint.h).
const int infiniteRepeat = -1;

/// Search / match return codes (`oniguruma.h`).
///
/// Non-negative return values from a search are the match start position.
abstract final class OnigResult {
  static const int normal = 0;
  static const int mismatch = -1;
  static const int noSupportConfig = -2;
  static const int abort = -3;
}

/// Compile & match options (`ONIG_OPTION_*`). Bit flags.
abstract final class OnigOption {
  static const int none = 0;
  static const int ignoreCase = 1;
  static const int extend = ignoreCase << 1;
  static const int multiLine = extend << 1;
  static const int singleLine = multiLine << 1;
  static const int findLongest = singleLine << 1;
  static const int findNotEmpty = findLongest << 1;
  static const int negateSingleLine = findNotEmpty << 1;
  static const int dontCaptureGroup = negateSingleLine << 1;
  static const int captureGroup = dontCaptureGroup << 1;

  static const int notBol = captureGroup << 1;
  static const int notEol = notBol << 1;
  static const int posixRegion = notEol << 1;
  static const int checkValidityOfString = posixRegion << 1;

  // Note the `<< 3` gap in the C header (reserved bits).
  static const int ignoreCaseIsAscii = checkValidityOfString << 3;
  static const int wordIsAscii = ignoreCaseIsAscii << 1;
  static const int digitIsAscii = wordIsAscii << 1;
  static const int spaceIsAscii = digitIsAscii << 1;
  static const int posixIsAscii = spaceIsAscii << 1;
  static const int textSegmentExtendedGraphemeCluster = posixIsAscii << 1;
  static const int textSegmentWord = textSegmentExtendedGraphemeCluster << 1;
  static const int notBeginString = textSegmentWord << 1;
  static const int notEndString = notBeginString << 1;
  static const int notBeginPosition = notEndString << 1;
  static const int callbackEachMatch = notBeginPosition << 1;
  static const int matchWholeString = callbackEachMatch << 1;

  static const int defaultOption = none;
}

/// Character-type ids (`ONIGENC_CTYPE_*`).
abstract final class CType {
  static const int newline = 0;
  static const int alpha = 1;
  static const int blank = 2;
  static const int cntrl = 3;
  static const int digit = 4;
  static const int graph = 5;
  static const int lower = 6;
  static const int print = 7;
  static const int punct = 8;
  static const int space = 9;
  static const int upper = 10;
  static const int xdigit = 11;
  static const int word = 12;
  static const int alnum = 13; // alpha || digit
  static const int ascii = 14;
  static const int maxStd = ascii;

  /// Bit-flag form (`ONIGENC_CTYPE_*` as `(1<<n)`), used by
  /// `is_code_ctype` fast paths and `ctype_to_cc` merges.
  static int bit(int ctype) => 1 << ctype;
}

/// Anchor bit flags (`ANCR_*`, regint.h). Stored on `AnchorNode` and
/// aggregated into `reg.anchor` by the optimizer.
abstract final class Anchor {
  static const int precRead = 1 << 0; // (?=...)
  static const int precReadNot = 1 << 1; // (?!...)
  static const int lookBehind = 1 << 2; // (?<=...)
  static const int lookBehindNot = 1 << 3; // (?<!...)

  static const int beginBuf = 1 << 4; // \A
  static const int beginLine = 1 << 5; // ^
  static const int beginPosition = 1 << 6; // \G
  static const int endBuf = 1 << 7; // \z
  static const int semiEndBuf = 1 << 8; // \Z
  static const int endLine = 1 << 9; // $
  static const int wordBoundary = 1 << 10; // \b
  static const int noWordBoundary = 1 << 11; // \B
  static const int wordBegin = 1 << 12; // \<
  static const int wordEnd = 1 << 13; // \>
  static const int anycharInf = 1 << 14;
  static const int anycharInfMl = 1 << 15;
  static const int textSegmentBoundary = 1 << 16; // \y
  static const int noTextSegmentBoundary = 1 << 17; // \Y

  static const int ancharMask = anycharInf | anycharInfMl;
  static const int endBufMask = endBuf | semiEndBuf;
}

/// Search-start optimization kind (`OPTIMIZE_*`, regint.h).
abstract final class Optimize {
  static const int none = 0;
  static const int str = 1; // plain literal
  static const int strFast = 2; // Sunday quick-search / BMH
  static const int strFastStepForward = 3;
  static const int map = 4; // 256-entry char map
}

/// Word-boundary / anchor "mode" for OP_WORD_BOUNDARY etc. (ascii flag).
abstract final class WordMode {
  static const int normal = 0;
  static const int ascii = 1;
}
