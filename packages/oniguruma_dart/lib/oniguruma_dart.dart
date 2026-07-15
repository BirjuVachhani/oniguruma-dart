/// A 1:1 Dart port of the Oniguruma regular-expression engine.
///
/// Two layers:
///  * a low-level byte API mirroring the C library (`onigNew`, `onigSearch`,
///    `OnigRegion`) operating on `Uint8List` with byte offsets;
///  * (P8) an idiomatic `String`-based wrapper.
library;

export 'src/onig_types.dart'
    show OnigResult, OnigOption, CType, Anchor, Optimize;
export 'src/onig_errors.dart' show OnigErr, OnigException, onigErrorCodeToStr;
export 'src/region.dart' show OnigRegion;
export 'src/syntax.dart'
    show
        OnigSyntax,
        onigSyntaxDefault,
        onigSyntaxRuby,
        onigSyntaxOniguruma,
        onigSyntaxAsis,
        onigSyntaxPosixBasic,
        onigSyntaxPosixExtended,
        onigSyntaxEmacs,
        onigSyntaxGrep,
        onigSyntaxGnuRegex,
        onigSyntaxJava,
        onigSyntaxPerl,
        onigSyntaxPerlNg,
        onigSyntaxPython;
export 'src/posix.dart'
    show
        Reg,
        PosixRegex,
        PosixMatch,
        PosixRegexHolder,
        posixRegcomp,
        posixRegexec,
        posixRegfree,
        posixRegerror;
export 'src/gnu.dart' show reCompilePattern, reSearch, reMatch;
export 'src/callout.dart'
    show
        CalloutResult,
        CalloutArgs,
        CalloutFunc,
        CalloutRegistry,
        defaultCalloutRegistry;
export 'src/encoding/encodings.dart';
export 'src/regex.dart' show Regex, onigNew;
export 'src/exec/search.dart' show onigSearch, onigMatch;
export 'src/regset.dart' show OnigRegSet, RegSetLead;
export 'src/api/string_api.dart' show OnigRegex, OnigMatch;
