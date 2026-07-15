/// Parser tokens (`TokenSyms` / `PToken`, regparse.c).
library;

/// Token kinds. Values in the top group are used by `fetchToken`; the `cc*`
/// group by `fetchTokenInCc` (inside a character class).
enum TokenType {
  eot, // end of pattern
  crudeByte, // raw byte (part of an MBC being assembled)
  char, // a single decoded character
  string, // (unused placeholder; strings are assembled in prs_exp)
  codePoint, // \x{..}, \u.., \o{..}
  anychar, // .
  charType, // \d \w \s \h ...
  backref, // \1, \k<name>
  call, // \g<name>
  anchor, // ^ $ \A \z \Z \b \B \G ...
  repeat, // * + ?
  interval, // {n,m}
  anycharAnytime, // .*
  alt, // |
  subexpOpen, // (
  subexpClose, // )
  openCc, // [
  quoteOpen, // \Q
  charProperty, // \p{..}
  keep, // \K
  generalNewline, // \R
  noNewline, // \N
  trueAnychar, // \O
  textSegment, // \X \y
  // inside character class:
  ccClose, // ]
  ccRange, // -
  ccPosixBracketOpen, // [:name:]
  ccAnd, // &&
  ccOpenCc, // [ (nested)
}

/// Anchor subtypes carried by a [TokenType.anchor] token (map to `ANCR_*`).
/// Value is the `Anchor` bit(s).

/// A parsed token with its payload (`PToken`).
class PToken {
  TokenType type = TokenType.eot;

  /// Raw byte value for byte/char tokens; escaped flag for backslash tokens.
  int byteVal = 0;
  bool escaped = false;

  /// Decoded code point for [TokenType.char] / [TokenType.codePoint].
  int code = 0;

  /// Extended `\x{a b c}` / `\o{...}` multi-code-point list (else null); the
  /// first element also lives in [code].
  List<int>? codePoints;

  /// [TokenType.anchor]: the `ANCR_*` subtype bits.
  int anchorSubtype = 0;
  bool anchorAsciiMode = false;

  /// [TokenType.charType]: ctype id, negation, ascii-mode.
  int propCtype = 0;
  bool propNot = false;

  /// [TokenType.charProperty]: the `\p{name}` property name.
  String propName = '';

  // repeat / interval
  int repeatLower = 0;
  int repeatUpper = 0;
  bool repeatGreedy = true;
  bool repeatPossessive = false;
  bool repeatByNumber = false;

  // backref
  int backrefNum = 0;
  int backrefRef1 = 0;
  List<int>? backrefRefs;
  bool backrefByName = false;
  bool backrefExistLevel = false;
  int backrefLevel = 0;

  // call
  int? callGnum;
  int callNameStart = 0;
  int callNameEnd = 0;
  bool callByNumber = false;

  /// Start offset (in the pattern) of this token's first byte (`backp`).
  int backp = 0;
}
