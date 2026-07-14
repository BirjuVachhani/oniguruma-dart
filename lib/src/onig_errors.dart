/// Error codes (`ONIGERR_*`) and messages, mirroring `regerror.c`.
///
/// The C API returns negative error codes; the idiomatic Dart surface throws
/// [OnigException] instead, while the low-level byte API can still surface the
/// raw code. Codes and message text match the C library exactly.
library;

/// All `ONIGERR_*` codes (values identical to `oniguruma.h`).
abstract final class OnigErr {
  static const int memory = -5;
  static const int typeBug = -6;
  static const int parserBug = -11;
  static const int stackBug = -12;
  static const int undefinedBytecode = -13;
  static const int unexpectedBytecode = -14;
  static const int matchStackLimitOver = -15;
  static const int parseDepthLimitOver = -16;
  static const int retryLimitInMatchOver = -17;
  static const int retryLimitInSearchOver = -18;
  static const int subexpCallLimitInSearchOver = -19;
  static const int timeLimitOver = -20;
  static const int defaultEncodingIsNotSet = -21;
  static const int specifiedEncodingCantConvertToWideChar = -22;
  static const int failToInitialize = -23;
  static const int invalidArgument = -30;

  static const int endPatternAtLeftBrace = -100;
  static const int endPatternAtLeftBracket = -101;
  static const int emptyCharClass = -102;
  static const int prematureEndOfCharClass = -103;
  static const int endPatternAtEscape = -104;
  static const int endPatternAtMeta = -105;
  static const int endPatternAtControl = -106;
  static const int metaCodeSyntax = -108;
  static const int controlCodeSyntax = -109;
  static const int charClassValueAtEndOfRange = -110;
  static const int charClassValueAtStartOfRange = -111;
  static const int unmatchedRangeSpecifierInCharClass = -112;
  static const int targetOfRepeatOperatorNotSpecified = -113;
  static const int targetOfRepeatOperatorInvalid = -114;
  static const int nestedRepeatOperator = -115;
  static const int unmatchedCloseParenthesis = -116;
  static const int endPatternWithUnmatchedParenthesis = -117;
  static const int endPatternInGroup = -118;
  static const int undefinedGroupOption = -119;
  static const int invalidGroupOption = -120;
  static const int invalidPosixBracketType = -121;
  static const int invalidLookBehindPattern = -122;
  static const int invalidRepeatRangePattern = -123;

  static const int tooBigNumber = -200;
  static const int tooBigNumberForRepeatRange = -201;
  static const int upperSmallerThanLowerInRepeatRange = -202;
  static const int emptyRangeInCharClass = -203;
  static const int mismatchCodeLengthInClassRange = -204;
  static const int tooManyMultiByteRanges = -205;
  static const int tooShortMultiByteString = -206;
  static const int tooBigBackrefNumber = -207;
  static const int invalidBackref = -208;
  static const int numberedBackrefOrCallNotAllowed = -209;
  static const int tooManyCaptures = -210;
  static const int tooLongWideCharValue = -212;
  static const int undefinedOperator = -213;
  static const int emptyGroupName = -214;
  static const int invalidGroupName = -215;
  static const int invalidCharInGroupName = -216;
  static const int undefinedNameReference = -217;
  static const int undefinedGroupReference = -218;
  static const int multiplexDefinedName = -219;
  static const int multiplexDefinitionNameCall = -220;
  static const int neverEndingRecursion = -221;
  static const int groupNumberOverForCaptureHistory = -222;
  static const int invalidCharPropertyName = -223;
  static const int invalidIfElseSyntax = -224;
  static const int invalidAbsentGroupPattern = -225;
  static const int invalidAbsentGroupGeneratorPattern = -226;
  static const int invalidCalloutPattern = -227;
  static const int invalidCalloutName = -228;
  static const int undefinedCalloutName = -229;
  static const int invalidCalloutBody = -230;
  static const int invalidCalloutTagName = -231;
  static const int invalidCalloutArg = -232;

  static const int invalidCodePointValue = -400;
  static const int tooBigWideCharValue = -401;
  static const int notSupportedEncodingCombination = -402;
  static const int invalidCombinationOfOptions = -403;
  static const int tooManyUserDefinedObjects = -404;
  static const int tooLongPropertyName = -405;
  static const int veryInefficientPattern = -406;
  static const int libraryIsNotInitialized = -500;
  static const int overThreadPassLimitCount = -1001;
}

const Map<int, String> _messages = {
  -1: 'mismatch',
  -2: 'no support in this configuration',
  -3: 'abort',
  OnigErr.memory: 'fail to memory allocation',
  OnigErr.matchStackLimitOver: 'match-stack limit over',
  OnigErr.parseDepthLimitOver: 'parse depth limit over',
  OnigErr.retryLimitInMatchOver: 'retry-limit-in-match over',
  OnigErr.retryLimitInSearchOver: 'retry-limit-in-search over',
  OnigErr.subexpCallLimitInSearchOver: 'subexp-call-limit-in-search over',
  OnigErr.timeLimitOver: 'time limit over',
  OnigErr.typeBug: 'undefined type (bug)',
  OnigErr.parserBug: 'internal parser error (bug)',
  OnigErr.stackBug: 'stack error (bug)',
  OnigErr.undefinedBytecode: 'undefined bytecode (bug)',
  OnigErr.unexpectedBytecode: 'unexpected bytecode (bug)',
  OnigErr.defaultEncodingIsNotSet: 'default multibyte-encoding is not set',
  OnigErr.specifiedEncodingCantConvertToWideChar:
      "can't convert to wide-char on specified multibyte-encoding",
  OnigErr.failToInitialize: 'fail to initialize',
  OnigErr.invalidArgument: 'invalid argument',
  OnigErr.endPatternAtLeftBrace: 'end pattern at left brace',
  OnigErr.endPatternAtLeftBracket: 'end pattern at left bracket',
  OnigErr.emptyCharClass: 'empty char-class',
  OnigErr.prematureEndOfCharClass: 'premature end of char-class',
  OnigErr.endPatternAtEscape: 'end pattern at escape',
  OnigErr.endPatternAtMeta: 'end pattern at meta',
  OnigErr.endPatternAtControl: 'end pattern at control',
  OnigErr.metaCodeSyntax: 'invalid meta-code syntax',
  OnigErr.controlCodeSyntax: 'invalid control-code syntax',
  OnigErr.charClassValueAtEndOfRange: 'char-class value at end of range',
  OnigErr.charClassValueAtStartOfRange: 'char-class value at start of range',
  OnigErr.unmatchedRangeSpecifierInCharClass:
      'unmatched range specifier in char-class',
  OnigErr.targetOfRepeatOperatorNotSpecified:
      'target of repeat operator is not specified',
  OnigErr.targetOfRepeatOperatorInvalid: 'target of repeat operator is invalid',
  OnigErr.nestedRepeatOperator: 'nested repeat operator',
  OnigErr.unmatchedCloseParenthesis: 'unmatched close parenthesis',
  OnigErr.endPatternWithUnmatchedParenthesis:
      'end pattern with unmatched parenthesis',
  OnigErr.endPatternInGroup: 'end pattern in group',
  OnigErr.undefinedGroupOption: 'undefined group option',
  OnigErr.invalidGroupOption: 'invalid group option',
  OnigErr.invalidPosixBracketType: 'invalid POSIX bracket type',
  OnigErr.invalidLookBehindPattern: 'invalid pattern in look-behind',
  OnigErr.invalidRepeatRangePattern: 'invalid repeat range {lower,upper}',
  OnigErr.tooBigNumber: 'too big number',
  OnigErr.tooBigNumberForRepeatRange: 'too big number for repeat range',
  OnigErr.upperSmallerThanLowerInRepeatRange:
      'upper is smaller than lower in repeat range',
  OnigErr.emptyRangeInCharClass: 'empty range in char class',
  OnigErr.mismatchCodeLengthInClassRange:
      'mismatch multibyte code length in char-class range',
  OnigErr.tooManyMultiByteRanges:
      'too many multibyte code ranges are specified',
  OnigErr.tooShortMultiByteString: 'too short multibyte code string',
  OnigErr.tooBigBackrefNumber: 'too big backref number',
  OnigErr.invalidBackref: 'invalid backref number/name',
  OnigErr.numberedBackrefOrCallNotAllowed:
      'numbered backref/call is not allowed. (use name)',
  OnigErr.tooManyCaptures: 'too many captures',
  OnigErr.tooBigWideCharValue: 'too big wide-char value',
  OnigErr.tooLongWideCharValue: 'too long wide-char value',
  OnigErr.undefinedOperator: 'undefined operator',
  OnigErr.invalidCodePointValue: 'invalid code point value',
  OnigErr.emptyGroupName: 'group name is empty',
  OnigErr.invalidGroupName: 'invalid group name <%n>',
  OnigErr.invalidCharInGroupName: 'invalid char in group name <%n>',
  OnigErr.undefinedNameReference: 'undefined name <%n> reference',
  OnigErr.undefinedGroupReference: 'undefined group <%n> reference',
  OnigErr.multiplexDefinedName: 'multiplex defined name <%n>',
  OnigErr.multiplexDefinitionNameCall: 'multiplex definition name <%n> call',
  OnigErr.neverEndingRecursion: 'never ending recursion',
  OnigErr.groupNumberOverForCaptureHistory:
      'group number is too big for capture history',
  OnigErr.invalidCharPropertyName: 'invalid character property name {%n}',
  OnigErr.invalidIfElseSyntax: 'invalid if-else syntax',
  OnigErr.invalidAbsentGroupPattern: 'invalid absent group pattern',
  OnigErr.invalidAbsentGroupGeneratorPattern:
      'invalid absent group generator pattern',
  OnigErr.invalidCalloutPattern: 'invalid callout pattern',
  OnigErr.invalidCalloutName: 'invalid callout name',
  OnigErr.undefinedCalloutName: 'undefined callout name',
  OnigErr.invalidCalloutBody: 'invalid callout body',
  OnigErr.invalidCalloutTagName: 'invalid callout tag name',
  OnigErr.invalidCalloutArg: 'invalid callout arg',
  OnigErr.notSupportedEncodingCombination: 'not supported encoding combination',
  OnigErr.invalidCombinationOfOptions: 'invalid combination of options',
  OnigErr.veryInefficientPattern: 'very inefficient pattern',
  OnigErr.libraryIsNotInitialized: 'library is not initialized',
};

/// Returns the message string for an error/return [code] (`onig_error_code_to_str`).
/// A `%n` placeholder (group name/prop name) is filled from [detail] when given.
String onigErrorCodeToStr(int code, {String? detail}) {
  final msg = _messages[code] ?? 'undefined error code';
  if (detail != null && msg.contains('%n')) {
    return msg.replaceAll('%n', detail);
  }
  return msg;
}

/// Thrown by the idiomatic API when compilation or matching fails.
class OnigException implements Exception {
  /// The raw `ONIGERR_*` code.
  final int code;

  /// Optional detail (group/property name) that fills the `%n` placeholder.
  final String? detail;

  OnigException(this.code, {this.detail});

  String get message => onigErrorCodeToStr(code, detail: detail);

  @override
  String toString() => 'OnigException($code): $message';
}
