/// Regex syntax flavours (`OnigSyntaxType`) and their flag sets.
///
/// Flag bit positions mirror `oniguruma.h`; the DEFAULT / Ruby definitions
/// mirror `regparse.c` (lines 71 / 123). The parser gates every metacharacter
/// on these flags, so they must match the C library bit-for-bit.
library;

import 'onig_types.dart';

/// `ONIG_SYN_OP_*` operator flags (word 1).
abstract final class SynOp {
  static const int variableMetaCharacters = 1 << 0;
  static const int dotAnychar = 1 << 1;
  static const int asteriskZeroInf = 1 << 2;
  static const int escAsteriskZeroInf = 1 << 3;
  static const int plusOneInf = 1 << 4;
  static const int escPlusOneInf = 1 << 5;
  static const int qmarkZeroOne = 1 << 6;
  static const int escQmarkZeroOne = 1 << 7;
  static const int braceInterval = 1 << 8;
  static const int escBraceInterval = 1 << 9;
  static const int vbarAlt = 1 << 10;
  static const int escVbarAlt = 1 << 11;
  static const int lparenSubexp = 1 << 12;
  static const int escLparenSubexp = 1 << 13;
  static const int escAzBufAnchor = 1 << 14;
  static const int escCapitalGBeginAnchor = 1 << 15;
  static const int decimalBackref = 1 << 16;
  static const int bracketCc = 1 << 17;
  static const int escWWord = 1 << 18;
  static const int escLtgtWordBeginEnd = 1 << 19;
  static const int escBWordBound = 1 << 20;
  static const int escSWhiteSpace = 1 << 21;
  static const int escDDigit = 1 << 22;
  static const int lineAnchor = 1 << 23;
  static const int posixBracket = 1 << 24;
  static const int qmarkNonGreedy = 1 << 25;
  static const int escControlChars = 1 << 26;
  static const int escCControl = 1 << 27;
  static const int escOctal3 = 1 << 28;
  static const int escXHex2 = 1 << 29;
  static const int escXBraceHex8 = 1 << 30;
  static const int escOBraceOctal = 1 << 31;
}

/// `ONIG_SYN_OP2_*` operator flags (word 2).
abstract final class SynOp2 {
  static const int escCapitalQQuote = 1 << 0;
  static const int qmarkGroupEffect = 1 << 1;
  static const int optionPerl = 1 << 2;
  static const int optionRuby = 1 << 3;
  static const int plusPossessiveRepeat = 1 << 4;
  static const int plusPossessiveInterval = 1 << 5;
  static const int cclassSetOp = 1 << 6;
  static const int qmarkLtNamedGroup = 1 << 7;
  static const int escKNamedBackref = 1 << 8;
  static const int escGSubexpCall = 1 << 9;
  static const int atmarkCaptureHistory = 1 << 10;
  static const int escCapitalCBarControl = 1 << 11;
  static const int escCapitalMBarMeta = 1 << 12;
  static const int escVVtab = 1 << 13;
  static const int escUHex4 = 1 << 14;
  static const int escGnuBufAnchor = 1 << 15;
  static const int escPBraceCharProperty = 1 << 16;
  static const int escPBraceCircumflexNot = 1 << 17;
  static const int charPropertyPrefixIs = 1 << 18;
  static const int escHXdigit = 1 << 19;
  static const int ineffectiveEscape = 1 << 20;
  static const int qmarkLparenIfElse = 1 << 21;
  static const int escCapitalKKeep = 1 << 22;
  static const int escCapitalRGeneralNewline = 1 << 23;
  static const int escCapitalNOSuperDot = 1 << 24;
  static const int qmarkTildeAbsentGroup = 1 << 25;
  static const int escXYTextSegment = 1 << 26; // == ESC_X_Y_GRAPHEME_CLUSTER
  static const int qmarkPerlSubexpCall = 1 << 27;
  static const int qmarkBraceCalloutContents = 1 << 28;
  static const int asteriskCalloutName = 1 << 29;
  static const int optionOniguruma = 1 << 30;
  static const int qmarkCapitalPName = 1 << 31;
}

/// `ONIG_SYN_*` behavior flags (word 3).
abstract final class SynBv {
  static const int contextIndepRepeatOps = 1 << 0;
  static const int contextInvalidRepeatOps = 1 << 1;
  static const int allowUnmatchedCloseSubexp = 1 << 2;
  static const int allowInvalidInterval = 1 << 3;
  static const int allowIntervalLowAbbrev = 1 << 4;
  static const int strictCheckBackref = 1 << 5;
  static const int differentLenAltLookBehind = 1 << 6;
  static const int captureOnlyNamedGroup = 1 << 7;
  static const int allowMultiplexDefinitionName = 1 << 8;
  static const int fixedIntervalIsGreedyOnly = 1 << 9;
  static const int isolatedOptionContinueBranch = 1 << 10;
  static const int variableLenLookBehind = 1 << 11;
  static const int python = 1 << 12;
  static const int wholeOptions = 1 << 13;
  static const int breAnchorAtEdgeOfSubexp = 1 << 14;
  static const int escPWithOneCharProp = 1 << 15;
  static const int notNewlineInNegativeCc = 1 << 20;
  static const int backslashEscapeInCc = 1 << 21;
  static const int allowEmptyRangeInCc = 1 << 22;
  static const int allowDoubleRangeOpInCc = 1 << 23;
  static const int warnCcOpNotEscaped = 1 << 24;
  static const int warnRedundantNestedRepeat = 1 << 25;
  static const int allowInvalidCodeEndOfRangeInCc = 1 << 26;
  static const int allowCharTypeFollowedByMinusInCc = 1 << 27;
  static const int contextIndepAnchors = 1 << 31;
}

/// Ineffective meta char marker (`ONIG_INEFFECTIVE_META_CHAR`).
const int ineffectiveMetaChar = -1;

/// Meta-char overrides (`OnigMetaCharTableType`). Ruby/Oniguruma only set `esc`.
class MetaCharTable {
  final int esc;
  final int anychar;
  final int anytime;
  final int zeroOrOneTime;
  final int oneOrMoreTime;
  final int anycharAnytime;

  const MetaCharTable({
    this.esc = 0x5c, // '\'
    this.anychar = ineffectiveMetaChar,
    this.anytime = ineffectiveMetaChar,
    this.zeroOrOneTime = ineffectiveMetaChar,
    this.oneOrMoreTime = ineffectiveMetaChar,
    this.anycharAnytime = ineffectiveMetaChar,
  });
}

/// A regex syntax flavour (`OnigSyntaxType`).
class OnigSyntax {
  final int op;
  final int op2;
  final int behavior;
  final int options;
  final MetaCharTable metaCharTable;
  final String name;

  const OnigSyntax({
    required this.name,
    required this.op,
    required this.op2,
    required this.behavior,
    required this.options,
    this.metaCharTable = const MetaCharTable(),
  });

  bool isOp(int flag) => (op & flag) != 0;
  bool isOp2(int flag) => (op2 & flag) != 0;
  bool isBehavior(int flag) => (behavior & flag) != 0;
}

// Composite building blocks (regint.h SYN_GNU_REGEX_OP / _BV).
const int _synGnuRegexOp =
    SynOp.dotAnychar |
    SynOp.bracketCc |
    SynOp.posixBracket |
    SynOp.decimalBackref |
    SynOp.braceInterval |
    SynOp.lparenSubexp |
    SynOp.vbarAlt |
    SynOp.asteriskZeroInf |
    SynOp.plusOneInf |
    SynOp.qmarkZeroOne |
    SynOp.escAzBufAnchor |
    SynOp.escCapitalGBeginAnchor |
    SynOp.escWWord |
    SynOp.escBWordBound |
    SynOp.escLtgtWordBeginEnd |
    SynOp.escSWhiteSpace |
    SynOp.escDDigit |
    SynOp.lineAnchor;

const int _synGnuRegexBv =
    SynBv.contextIndepAnchors |
    SynBv.contextIndepRepeatOps |
    SynBv.contextInvalidRepeatOps |
    SynBv.allowInvalidInterval |
    SynBv.backslashEscapeInCc |
    SynBv.allowDoubleRangeOpInCc;

/// `OnigSyntaxOniguruma`: the library DEFAULT (regparse.c:71).
const OnigSyntax onigSyntaxOniguruma = OnigSyntax(
  name: 'Oniguruma',
  op:
      (_synGnuRegexOp |
          SynOp.qmarkNonGreedy |
          SynOp.escOctal3 |
          SynOp.escXHex2 |
          SynOp.escXBraceHex8 |
          SynOp.escOBraceOctal |
          SynOp.escControlChars |
          SynOp.escCControl) &
      ~SynOp.escLtgtWordBeginEnd,
  op2:
      SynOp2.qmarkGroupEffect |
      SynOp2.optionOniguruma |
      SynOp2.qmarkLtNamedGroup |
      SynOp2.escKNamedBackref |
      SynOp2.qmarkLparenIfElse |
      SynOp2.qmarkTildeAbsentGroup |
      SynOp2.qmarkBraceCalloutContents |
      SynOp2.asteriskCalloutName |
      SynOp2.escXYTextSegment |
      SynOp2.escCapitalRGeneralNewline |
      SynOp2.escCapitalNOSuperDot |
      SynOp2.escCapitalKKeep |
      SynOp2.escGSubexpCall |
      SynOp2.escPBraceCharProperty |
      SynOp2.escPBraceCircumflexNot |
      SynOp2.plusPossessiveRepeat |
      SynOp2.cclassSetOp |
      SynOp2.escCapitalCBarControl |
      SynOp2.escCapitalMBarMeta |
      SynOp2.escVVtab |
      SynOp2.escHXdigit |
      SynOp2.escUHex4,
  behavior:
      _synGnuRegexBv |
      SynBv.allowIntervalLowAbbrev |
      SynBv.differentLenAltLookBehind |
      SynBv.variableLenLookBehind |
      SynBv.captureOnlyNamedGroup |
      SynBv.allowMultiplexDefinitionName |
      SynBv.fixedIntervalIsGreedyOnly |
      SynBv.allowInvalidCodeEndOfRangeInCc |
      SynBv.warnCcOpNotEscaped |
      SynBv.wholeOptions |
      SynBv.escPWithOneCharProp |
      SynBv.warnRedundantNestedRepeat,
  options: OnigOption.none,
);

/// `OnigSyntaxRuby` (regparse.c:123). Differs from Oniguruma as noted in regparse.c.
const OnigSyntax onigSyntaxRuby = OnigSyntax(
  name: 'Ruby',
  op:
      (_synGnuRegexOp |
          SynOp.qmarkNonGreedy |
          SynOp.escOctal3 |
          SynOp.escXHex2 |
          SynOp.escXBraceHex8 |
          SynOp.escOBraceOctal |
          SynOp.escControlChars |
          SynOp.escCControl) &
      ~SynOp.escLtgtWordBeginEnd,
  op2:
      SynOp2.qmarkGroupEffect |
      SynOp2.optionRuby |
      SynOp2.qmarkLtNamedGroup |
      SynOp2.escKNamedBackref |
      SynOp2.qmarkLparenIfElse |
      SynOp2.qmarkTildeAbsentGroup |
      SynOp2.escXYTextSegment |
      SynOp2.escCapitalRGeneralNewline |
      SynOp2.escCapitalNOSuperDot |
      SynOp2.escCapitalKKeep |
      SynOp2.escGSubexpCall |
      SynOp2.escPBraceCharProperty |
      SynOp2.escPBraceCircumflexNot |
      SynOp2.plusPossessiveRepeat |
      SynOp2.cclassSetOp |
      SynOp2.escCapitalCBarControl |
      SynOp2.escCapitalMBarMeta |
      SynOp2.escVVtab |
      SynOp2.escHXdigit |
      SynOp2.escUHex4,
  behavior:
      _synGnuRegexBv |
      SynBv.allowIntervalLowAbbrev |
      SynBv.differentLenAltLookBehind |
      SynBv.captureOnlyNamedGroup |
      SynBv.allowMultiplexDefinitionName |
      SynBv.fixedIntervalIsGreedyOnly |
      SynBv.warnCcOpNotEscaped |
      SynBv.warnRedundantNestedRepeat,
  options: OnigOption.none,
);

/// The active default syntax (`OnigDefaultSyntax`, regparse.c:165).
const OnigSyntax onigSyntaxDefault = onigSyntaxOniguruma;

// ---------------------------------------------------------------------------
// Additional standard syntaxes (regsyntax.c). Flag sets mirror the C source.
// ---------------------------------------------------------------------------

const int _synPosixCommonOp =
    SynOp.dotAnychar |
    SynOp.posixBracket |
    SynOp.decimalBackref |
    SynOp.bracketCc |
    SynOp.asteriskZeroInf |
    SynOp.lineAnchor |
    SynOp.escControlChars;

const int _optSingleMulti = OnigOption.singleLine | OnigOption.multiLine;

const int _perlLikeOp =
    (_synGnuRegexOp |
        SynOp.qmarkNonGreedy |
        SynOp.escOctal3 |
        SynOp.escXHex2 |
        SynOp.escXBraceHex8 |
        SynOp.escOBraceOctal |
        SynOp.escControlChars |
        SynOp.escCControl) &
    ~SynOp.escLtgtWordBeginEnd;

/// `OnigSyntaxASIS`: literal text, no metacharacters.
const OnigSyntax onigSyntaxAsis = OnigSyntax(
  name: 'ASIS',
  op: 0,
  op2: SynOp2.ineffectiveEscape,
  behavior: 0,
  options: OnigOption.none,
);

/// `OnigSyntaxPosixBasic` (BRE).
const OnigSyntax onigSyntaxPosixBasic = OnigSyntax(
  name: 'POSIX-Basic',
  op: _synPosixCommonOp | SynOp.escLparenSubexp | SynOp.escBraceInterval,
  op2: 0,
  behavior: SynBv.breAnchorAtEdgeOfSubexp,
  options: _optSingleMulti,
);

/// `OnigSyntaxPosixExtended` (ERE).
const OnigSyntax onigSyntaxPosixExtended = OnigSyntax(
  name: 'POSIX-Extended',
  op:
      _synPosixCommonOp |
      SynOp.lparenSubexp |
      SynOp.braceInterval |
      SynOp.plusOneInf |
      SynOp.qmarkZeroOne |
      SynOp.vbarAlt,
  op2: 0,
  behavior:
      SynBv.contextIndepAnchors |
      SynBv.contextIndepRepeatOps |
      SynBv.contextInvalidRepeatOps |
      SynBv.allowUnmatchedCloseSubexp |
      SynBv.allowDoubleRangeOpInCc,
  options: _optSingleMulti,
);

/// `OnigSyntaxEmacs`.
const OnigSyntax onigSyntaxEmacs = OnigSyntax(
  name: 'Emacs',
  op:
      SynOp.dotAnychar |
      SynOp.bracketCc |
      SynOp.escBraceInterval |
      SynOp.escLparenSubexp |
      SynOp.escVbarAlt |
      SynOp.asteriskZeroInf |
      SynOp.plusOneInf |
      SynOp.qmarkZeroOne |
      SynOp.decimalBackref |
      SynOp.lineAnchor |
      SynOp.escControlChars,
  op2: SynOp2.escGnuBufAnchor | SynOp2.qmarkGroupEffect,
  behavior: SynBv.allowEmptyRangeInCc,
  options: OnigOption.none,
);

/// `OnigSyntaxGrep`.
const OnigSyntax onigSyntaxGrep = OnigSyntax(
  name: 'grep',
  op:
      SynOp.dotAnychar |
      SynOp.bracketCc |
      SynOp.posixBracket |
      SynOp.escBraceInterval |
      SynOp.escLparenSubexp |
      SynOp.escVbarAlt |
      SynOp.asteriskZeroInf |
      SynOp.escPlusOneInf |
      SynOp.escQmarkZeroOne |
      SynOp.lineAnchor |
      SynOp.escWWord |
      SynOp.escBWordBound |
      SynOp.escLtgtWordBeginEnd |
      SynOp.decimalBackref,
  op2: 0,
  behavior:
      SynBv.allowEmptyRangeInCc |
      SynBv.notNewlineInNegativeCc |
      SynBv.breAnchorAtEdgeOfSubexp,
  options: OnigOption.none,
);

/// `OnigSyntaxGnuRegex`.
const OnigSyntax onigSyntaxGnuRegex = OnigSyntax(
  name: 'GNU-Regex',
  op: _synGnuRegexOp,
  op2: 0,
  behavior: _synGnuRegexBv,
  options: OnigOption.none,
);

/// `OnigSyntaxJava`.
const OnigSyntax onigSyntaxJava = OnigSyntax(
  name: 'Java',
  op:
      (_synGnuRegexOp |
          SynOp.qmarkNonGreedy |
          SynOp.escControlChars |
          SynOp.escCControl |
          SynOp.escOctal3 |
          SynOp.escXHex2) &
      ~(SynOp.escLtgtWordBeginEnd | SynOp.posixBracket),
  op2:
      SynOp2.escCapitalQQuote |
      SynOp2.qmarkGroupEffect |
      SynOp2.optionPerl |
      SynOp2.plusPossessiveRepeat |
      SynOp2.plusPossessiveInterval |
      SynOp2.cclassSetOp |
      SynOp2.escVVtab |
      SynOp2.escUHex4 |
      SynOp2.escPBraceCharProperty,
  behavior:
      _synGnuRegexBv |
      SynBv.isolatedOptionContinueBranch |
      SynBv.differentLenAltLookBehind |
      SynBv.variableLenLookBehind |
      SynBv.allowCharTypeFollowedByMinusInCc,
  options: OnigOption.singleLine,
);

const int _perlOp2 =
    SynOp2.escCapitalQQuote |
    SynOp2.qmarkGroupEffect |
    SynOp2.optionPerl |
    SynOp2.plusPossessiveRepeat |
    SynOp2.plusPossessiveInterval |
    SynOp2.qmarkLparenIfElse |
    SynOp2.qmarkTildeAbsentGroup |
    SynOp2.qmarkBraceCalloutContents |
    SynOp2.asteriskCalloutName |
    SynOp2.escXYTextSegment |
    SynOp2.escPBraceCharProperty |
    SynOp2.escPBraceCircumflexNot |
    SynOp2.escCapitalKKeep |
    SynOp2.escCapitalRGeneralNewline |
    SynOp2.escCapitalNOSuperDot;

/// `OnigSyntaxPerl`.
const OnigSyntax onigSyntaxPerl = OnigSyntax(
  name: 'Perl',
  op: _perlLikeOp,
  op2: _perlOp2,
  behavior:
      _synGnuRegexBv |
      SynBv.isolatedOptionContinueBranch |
      SynBv.allowCharTypeFollowedByMinusInCc |
      SynBv.escPWithOneCharProp,
  options: OnigOption.singleLine,
);

/// `OnigSyntaxPerl_NG` (named groups).
const OnigSyntax onigSyntaxPerlNg = OnigSyntax(
  name: 'Perl+NamedGroup',
  op: _perlLikeOp,
  op2:
      _perlOp2 |
      SynOp2.qmarkLtNamedGroup |
      SynOp2.escKNamedBackref |
      SynOp2.escGSubexpCall |
      SynOp2.qmarkPerlSubexpCall,
  behavior:
      _synGnuRegexBv |
      SynBv.isolatedOptionContinueBranch |
      SynBv.captureOnlyNamedGroup |
      SynBv.allowMultiplexDefinitionName |
      SynBv.allowCharTypeFollowedByMinusInCc |
      SynBv.escPWithOneCharProp,
  options: OnigOption.singleLine,
);

/// `OnigSyntaxPython`.
const OnigSyntax onigSyntaxPython = OnigSyntax(
  name: 'Python',
  op:
      (_synGnuRegexOp |
          SynOp.qmarkNonGreedy |
          SynOp.escOctal3 |
          SynOp.escXHex2 |
          SynOp.escControlChars |
          SynOp.escCControl) &
      ~(SynOp.escLtgtWordBeginEnd | SynOp.posixBracket),
  op2:
      SynOp2.qmarkGroupEffect |
      SynOp2.optionPerl |
      SynOp2.qmarkLparenIfElse |
      SynOp2.asteriskCalloutName |
      SynOp2.escPBraceCharProperty |
      SynOp2.escPBraceCircumflexNot |
      SynOp2.qmarkCapitalPName |
      SynOp2.escCapitalKKeep |
      SynOp2.escVVtab |
      SynOp2.escUHex4,
  behavior:
      _synGnuRegexBv |
      SynBv.isolatedOptionContinueBranch |
      SynBv.allowIntervalLowAbbrev |
      SynBv.python,
  options: OnigOption.singleLine,
);
