// One-shot generator: translates Oniguruma's C test files into static,
// compile-time Dart test files under test/c_suite/. Run:
//   dart run tool/gen_c_suite.dart
//
// Cases are emitted as literal Dart (no runtime reads of the C sources). Each C
// string literal is re-emitted byte-exact (every byte is a code unit, via
// `\xHH` or literal ASCII), decoded by CSuite.b().
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../test/c_suite/c_parse.dart';

const Map<String, int> onigErr = {
  'ONIGERR_PREMATURE_END_OF_CHAR_CLASS': -103,
  'ONIGERR_UNMATCHED_RANGE_SPECIFIER_IN_CHAR_CLASS': -112,
  'ONIGERR_TARGET_OF_REPEAT_OPERATOR_NOT_SPECIFIED': -113,
  'ONIGERR_TARGET_OF_REPEAT_OPERATOR_INVALID': -114,
  'ONIGERR_END_PATTERN_WITH_UNMATCHED_PARENTHESIS': -117,
  'ONIGERR_INVALID_GROUP_OPTION': -120,
  'ONIGERR_INVALID_POSIX_BRACKET_TYPE': -121,
  'ONIGERR_INVALID_LOOK_BEHIND_PATTERN': -122,
  'ONIGERR_TOO_BIG_NUMBER_FOR_REPEAT_RANGE': -201,
  'ONIGERR_UPPER_SMALLER_THAN_LOWER_IN_REPEAT_RANGE': -202,
  'ONIGERR_EMPTY_RANGE_IN_CHAR_CLASS': -203,
  'ONIGERR_TOO_SHORT_MULTI_BYTE_STRING': -206,
  'ONIGERR_INVALID_BACKREF': -208,
  'ONIGERR_NUMBERED_BACKREF_OR_CALL_NOT_ALLOWED': -209,
  'ONIGERR_TOO_LONG_WIDE_CHAR_VALUE': -212,
  'ONIGERR_UNDEFINED_OPERATOR': -213,
  'ONIGERR_UNDEFINED_GROUP_REFERENCE': -218,
  'ONIGERR_UNDEFINED_NAME_REFERENCE': -217,
  'ONIGERR_NEVER_ENDING_RECURSION': -221,
  'ONIGERR_INVALID_CHAR_PROPERTY_NAME': -223,
  'ONIGERR_UNDEFINED_CALLOUT_NAME': -229,
  'ONIGERR_INVALID_CODE_POINT_VALUE': -400,
  'ONIGERR_TOO_BIG_WIDE_CHAR_VALUE': -401,
};

const Map<String, String> optMap = {
  'ONIG_OPTION_NONE': 'OnigOption.none',
  'ONIG_OPTION_IGNORECASE': 'OnigOption.ignoreCase',
  'ONIG_OPTION_EXTEND': 'OnigOption.extend',
  'ONIG_OPTION_MULTI_LINE': 'OnigOption.multiLine',
  'ONIG_OPTION_SINGLE_LINE': 'OnigOption.singleLine',
  'ONIG_OPTION_FIND_LONGEST': 'OnigOption.findLongest',
  'ONIG_OPTION_FIND_NOT_EMPTY': 'OnigOption.findNotEmpty',
  'ONIG_OPTION_NOTBOL': 'OnigOption.notBol',
  'ONIG_OPTION_NOTEOL': 'OnigOption.notEol',
  'ONIG_OPTION_NOT_BEGIN_STRING': 'OnigOption.notBeginString',
  'ONIG_OPTION_NOT_END_STRING': 'OnigOption.notEndString',
  'ONIG_OPTION_NOT_BEGIN_POSITION': 'OnigOption.notBeginPosition',
  'ONIG_OPTION_IGNORECASE_IS_ASCII': 'OnigOption.ignoreCaseIsAscii',
  'ONIG_OPTION_WORD_IS_ASCII': 'OnigOption.wordIsAscii',
  'ONIG_OPTION_DIGIT_IS_ASCII': 'OnigOption.digitIsAscii',
  'ONIG_OPTION_SPACE_IS_ASCII': 'OnigOption.spaceIsAscii',
  'ONIG_OPTION_POSIX_IS_ASCII': 'OnigOption.posixIsAscii',
  'ONIG_OPTION_MATCH_WHOLE_STRING': 'OnigOption.matchWholeString',
};

const Map<String, String> synMap = {
  'ONIG_SYNTAX_ONIGURUMA': 'onigSyntaxOniguruma',
  'ONIG_SYNTAX_RUBY': 'onigSyntaxRuby',
  'ONIG_SYNTAX_PERL': 'onigSyntaxPerl',
  'ONIG_SYNTAX_PERL_NG': 'onigSyntaxPerlNg',
  'ONIG_SYNTAX_JAVA': 'onigSyntaxJava',
  'ONIG_SYNTAX_PYTHON': 'onigSyntaxPython',
  'ONIG_SYNTAX_GREP': 'onigSyntaxGrep',
  'ONIG_SYNTAX_EMACS': 'onigSyntaxEmacs',
  'ONIG_SYNTAX_POSIX_BASIC': 'onigSyntaxPosixBasic',
  'ONIG_SYNTAX_POSIX_EXTENDED': 'onigSyntaxPosixExtended',
  'ONIG_SYNTAX_ASIS': 'onigSyntaxAsis',
};

String dartLit(Uint8List bytes) {
  final sb = StringBuffer("'");
  for (final b in bytes) {
    if (b == 0x27) {
      sb.write("\\'");
    } else if (b == 0x5c) {
      sb.write('\\\\');
    } else if (b == 0x24) {
      sb.write('\\\$');
    } else if (b >= 0x20 && b < 0x7f) {
      sb.writeCharCode(b);
    } else {
      sb.write('\\x${b.toRadixString(16).padLeft(2, '0')}');
    }
  }
  sb.write("'");
  return sb.toString();
}

/// `#define NAME (…)` aliases for option combos (e.g. test_options.c's `OIA`).
Map<String, String> _optAliases(String src) {
  final out = <String, String>{};
  final re = RegExp(r'#define\s+(\w+)\s+\(([^)]*ONIG_OPTION[^)]*)\)');
  for (final m in re.allMatches(src)) {
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

String optExpr(String cExpr, Map<String, String> aliases) {
  final parts = cExpr.split('|').map((e) => e.trim());
  final mapped = parts.expand((p) {
    if (aliases.containsKey(p)) {
      return aliases[p]!
          .split('|')
          .map((e) => optMap[e.trim()] ?? 'OnigOption.none');
    }
    return [optMap[p] ?? 'OnigOption.none'];
  }).toList();
  return mapped.length == 1 ? mapped.first : mapped.join(' | ');
}

enum Kind { utf8, back, options, syntax, enc, posix }

class SuiteSpec {
  final String cFile, outFile, suiteName;
  final Kind kind;
  final String? enc; // for Kind.enc
  const SuiteSpec(
    this.cFile,
    this.outFile,
    this.suiteName,
    this.kind, {
    this.enc,
  });
}

void main() {
  const base = 'oniguruma-master/test';
  const out = 'test/c_suite';
  final specs = <SuiteSpec>[
    SuiteSpec(
      '$base/test_utf8.c',
      '$out/utf8_test.dart',
      'test_utf8',
      Kind.utf8,
    ),
    SuiteSpec(
      '$base/test_back.c',
      '$out/back_test.dart',
      'test_back',
      Kind.back,
    ),
    SuiteSpec(
      '$base/test_options.c',
      '$out/options_test.dart',
      'test_options',
      Kind.options,
    ),
    SuiteSpec(
      '$base/test_syntax.c',
      '$out/syntax_test.dart',
      'test_syntax',
      Kind.syntax,
    ),
    SuiteSpec(
      '$base/testu.c',
      '$out/utf16_test.dart',
      'testu',
      Kind.enc,
      enc: 'utf16BeEncoding',
    ),
    SuiteSpec(
      '$base/testc.c',
      '$out/euc_test.dart',
      'testc',
      Kind.enc,
      enc: 'eucJpEncoding',
    ),
    SuiteSpec('$base/testp.c', '$out/posix_test.dart', 'testp', Kind.posix),
  ];

  for (final spec in specs) {
    final source = File(spec.cFile).readAsStringSync(encoding: latin1);
    final calls = extractCalls(source, {'x2', 'x3', 'n', 'e'});
    final syntaxByLine = spec.kind == Kind.syntax
        ? _syntaxAssignments(source)
        : null;
    final aliases = _optAliases(source);
    final b = StringBuffer();
    b.writeln('// GENERATED by tool/gen_c_suite.dart from ${spec.cFile}.');
    b.writeln('// 1:1 translation of the Oniguruma C test cases. Do not edit.');
    b.writeln("import 'package:oniguruma_dart/oniguruma_dart.dart';");
    b.writeln("import 'c_harness.dart';");
    b.writeln();
    b.writeln('void main() {');
    b.writeln("  group('${spec.suiteName}', () {");
    var emitted = 0;
    if (spec.kind == Kind.syntax) {
      for (final line in _genSyntaxSuite(source, calls, aliases, spec)) {
        b.writeln('    $line');
        emitted++;
      }
    } else {
      for (final c in calls) {
        final line = _emitCall(c, spec, syntaxByLine, aliases);
        if (line != null) {
          b.writeln('    $line');
          emitted++;
        }
      }
    }
    b.writeln('  });');
    b.writeln('}');
    File(spec.outFile).writeAsStringSync(b.toString());
    stdout.writeln('${spec.outFile}: $emitted cases');
  }
}

/// Map each `Syntax = ONIG_SYNTAX_X;` line → the Dart syntax name.
List<MapEntry<int, String>> _syntaxAssignments(String src) {
  final out = <MapEntry<int, String>>[];
  final lines = src.split('\n');
  final re = RegExp(r'Syntax\s*=\s*(ONIG_SYNTAX_[A-Z_]+)');
  for (var i = 0; i < lines.length; i++) {
    final m = re.firstMatch(lines[i]);
    if (m != null) {
      out.add(MapEntry(i + 1, synMap[m.group(1)] ?? 'onigSyntaxOniguruma'));
    }
  }
  return out;
}

/// test_syntax.c puts cases in `static int test_X()` functions and `main()`
/// runs each under one or more syntaxes (`Syntax = X; test_X();`). Emit each
/// function's cases once per (syntax, function) invocation, mirroring the run.
List<String> _genSyntaxSuite(
  String src,
  List<CCall> calls,
  Map<String, String> aliases,
  SuiteSpec spec,
) {
  final lines = src.split('\n');
  // 1. function ranges: name → [startLine, endLine).
  final fnStart = <String, int>{};
  final defRe = RegExp(r'^\s*static\s+int\s+(test_\w+)\s*\(');
  final mainRe = RegExp(r'\bmain\s*\(');
  var mainLine = lines.length + 1;
  final order = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final m = defRe.firstMatch(lines[i]);
    if (m != null) {
      fnStart[m.group(1)!] = i + 1;
      order.add(m.group(1)!);
    } else if (mainRe.hasMatch(lines[i]) && lines[i].contains('int')) {
      mainLine = i + 1;
    }
  }
  final fnRange = <String, List<int>>{};
  for (var k = 0; k < order.length; k++) {
    final start = fnStart[order[k]]!;
    final end = k + 1 < order.length ? fnStart[order[k + 1]]! : mainLine;
    fnRange[order[k]] = [start, end];
  }
  // 2. calls per function.
  final callsByFn = <String, List<CCall>>{};
  for (final c in calls) {
    for (final e in fnRange.entries) {
      if (c.line >= e.value[0] && c.line < e.value[1]) {
        (callsByFn[e.key] ??= []).add(c);
        break;
      }
    }
  }
  // 3. main() sequence: Syntax=X; test_fn();
  final seqRe = RegExp(
    r'Syntax\s*=\s*(ONIG_SYNTAX_[A-Z_]+)|(test_\w+)\s*\(\s*\)',
  );
  var curSyn = 'onigSyntaxOniguruma';
  final emitted = <String>[];
  for (var i = mainLine - 1; i < lines.length; i++) {
    for (final m in seqRe.allMatches(lines[i])) {
      if (m.group(1) != null) {
        curSyn = synMap[m.group(1)] ?? 'onigSyntaxOniguruma';
      } else {
        final fn = m.group(2)!;
        for (final c in callsByFn[fn] ?? const <CCall>[]) {
          final line = _emitSyntaxCall(c, curSyn, aliases);
          if (line != null) emitted.add(line);
        }
      }
    }
  }
  return emitted;
}

String? _emitSyntaxCall(CCall c, String syn, Map<String, String> aliases) {
  if (c.args.isEmpty || !c.args[0].trimLeft().startsWith('"')) return null;
  final cfg = 'enc: utf8Encoding, syntax: $syn';
  final p = dartLit(decodeCString(c.args[0]));
  final head = 'CSuite($cfg)';
  switch (c.name) {
    case 'x2':
      return '$head.x2($p, ${dartLit(decodeCString(c.args[1]))}, ${c.args[2]}, ${c.args[3]}, ${c.line});';
    case 'x3':
      return '$head.x3($p, ${dartLit(decodeCString(c.args[1]))}, ${c.args[2]}, ${c.args[3]}, ${c.args[4]}, ${c.line});';
    case 'n':
      return '$head.n($p, ${dartLit(decodeCString(c.args[1]))}, ${c.line});';
    case 'e':
      return '$head.e($p, ${dartLit(decodeCString(c.args[1]))}, ${onigErr[c.args[2]] ?? 0}, ${c.line});';
  }
  return null;
}

String _cfg(
  SuiteSpec spec,
  CCall c,
  List<MapEntry<int, String>>? syntaxByLine,
  Map<String, String> aliases,
) {
  switch (spec.kind) {
    case Kind.utf8:
      return 'enc: utf8Encoding';
    case Kind.back:
      return 'enc: utf8Encoding, backward: true';
    case Kind.enc:
      return 'enc: ${spec.enc}';
    case Kind.posix:
      // `onig_posix_regcomp(REG_EXTENDED | REG_NEWLINE)` → Oniguruma syntax with
      // NEGATE_SINGLELINE (^/$ match at line boundaries).
      return 'enc: utf8Encoding, syntax: onigSyntaxOniguruma, '
          'option: OnigOption.negateSingleLine';
    case Kind.options:
      final opt = optExpr(c.args[0], aliases);
      return 'enc: utf8Encoding, option: $opt';
    case Kind.syntax:
      var syn = 'onigSyntaxOniguruma';
      for (final e in syntaxByLine!) {
        if (e.key < c.line) syn = e.value;
      }
      return 'enc: utf8Encoding, syntax: $syn';
  }
}

String? _emitCall(
  CCall c,
  SuiteSpec spec,
  List<MapEntry<int, String>>? syntaxByLine,
  Map<String, String> aliases,
) {
  // test_options/test_syntax x2/x3/n/e take an extra leading arg (opt / -).
  final off = spec.kind == Kind.options ? 1 : 0;
  // Skip non-invocations (e.g. the C `static void x2(...)` definitions, whose
  // args are C declarations, not string literals).
  if (c.args.length <= off || !c.args[off].trimLeft().startsWith('"')) {
    return null;
  }
  final cfg = _cfg(spec, c, syntaxByLine, aliases);
  final p = dartLit(_strBytes(c.args[off], spec));
  final head = 'CSuite($cfg)';
  switch (c.name) {
    case 'x2':
      final s = dartLit(_strBytes(c.args[off + 1], spec));
      return '$head.x2($p, $s, ${c.args[off + 2]}, ${c.args[off + 3]}, ${c.line});';
    case 'x3':
      final s = dartLit(_strBytes(c.args[off + 1], spec));
      return '$head.x3($p, $s, ${c.args[off + 2]}, ${c.args[off + 3]}, ${c.args[off + 4]}, ${c.line});';
    case 'n':
      final s = dartLit(_strBytes(c.args[off + 1], spec));
      return '$head.n($p, $s, ${c.line});';
    case 'e':
      final s = dartLit(_strBytes(c.args[off + 1], spec));
      final code = onigErr[c.args[off + 2]] ?? 0;
      return '$head.e($p, $s, $code, ${c.line});';
    default:
      return null;
  }
}

/// Decode a C literal, truncating at the encoding's NUL terminator (C `testu`
/// measures lengths with `onigenc_str_bytelen_null`). UTF-16 uses a 2-byte NUL.
Uint8List _strBytes(String arg, SuiteSpec spec) {
  final bytes = decodeCString(arg);
  if (spec.kind == Kind.enc && spec.enc!.startsWith('utf16')) {
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      if (bytes[i] == 0 && bytes[i + 1] == 0) {
        return Uint8List.sublistView(bytes, 0, i);
      }
    }
  }
  return bytes;
}
