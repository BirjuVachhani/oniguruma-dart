// Dev-only: categorize C-suite failures to guide engine fixes. Not a test.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:oniguruma_dart/oniguruma_dart.dart';
import '../test/c_suite/c_parse.dart';

void main(List<String> argv) {
  final files = {
    'utf8': ('oniguruma-master/test/test_utf8.c', false),
    'back': ('oniguruma-master/test/test_back.c', true),
  };
  final filter = argv.isNotEmpty ? argv[0] : '';
  for (final e in files.entries) {
    final (path, backward) = e.value;
    final calls = extractCalls(File(path).readAsStringSync(encoding: latin1), {
      'x2',
      'x3',
      'n',
      'e',
    });
    var pass = 0;
    final fails = <String>[];
    for (final c in calls) {
      final r = _run(c, backward);
      if (r == null) {
        pass++;
      } else {
        fails.add(r);
      }
    }
    stdout.writeln('=== ${e.key}: $pass pass, ${fails.length} fail ===');
    for (final f in fails) {
      if (filter.isEmpty || f.contains(filter)) stdout.writeln(f);
    }
  }
}

String? _run(CCall c, bool backward) {
  final pat = decodeCString(c.args[0]);
  Uint8List sub = c.name == 'e' || c.args.length < 2
      ? Uint8List(0)
      : decodeCString(c.args[1]);
  try {
    final reg = onigNew(
      pat,
      pat.length,
      utf8Encoding,
      onigSyntaxDefault,
      OnigOption.none,
    );
    final rg = OnigRegion();
    final start = backward ? sub.length : 0;
    final range = backward ? 0 : sub.length;
    final r = onigSearch(
      reg,
      sub,
      sub.length,
      start,
      range,
      rg,
      retryLimit: 10000000,
    );
    switch (c.name) {
      case 'n':
        return r < 0
            ? null
            : 'N #${c.line} /${_p(pat)}/ "${_p(sub)}" got ${rg.beg[0]},${rg.end[0]}';
      case 'e':
        return 'E #${c.line} /${_p(pat)}/ want ${c.args[2]} got ${r < 0 ? r : "match"}';
      case 'x2':
        final f = int.parse(c.args[2]), t = int.parse(c.args[3]);
        if (r < 0) return 'NM #${c.line} /${_p(pat)}/ "${_p(sub)}"';
        return (rg.beg[0] == f && rg.end[0] == t)
            ? null
            : 'X #${c.line} /${_p(pat)}/ "${_p(sub)}" want $f-$t got ${rg.beg[0]}-${rg.end[0]}';
      case 'x3':
        final f = int.parse(c.args[2]),
            t = int.parse(c.args[3]),
            m = int.parse(c.args[4]);
        if (r < 0) return 'NM #${c.line} /${_p(pat)}/';
        return (rg.beg[m] == f && rg.end[m] == t)
            ? null
            : 'X3 #${c.line} /${_p(pat)}/ "${_p(sub)}" g$m want $f-$t got ${rg.beg[m]}-${rg.end[m]}';
    }
  } on OnigException catch (ex) {
    if (c.name == 'e') {
      return ex.code.toString() == c.args[2] || _errName(ex.code) == c.args[2]
          ? null
          : 'E #${c.line} /${_p(pat)}/ want ${c.args[2]} got ${ex.code}';
    }
    return 'CE #${c.line} /${_p(pat)}/ : ${ex.code}';
  } catch (ex) {
    return 'EXC #${c.line} /${_p(pat)}/ : $ex';
  }
  return null;
}

const _errMap = {
  -103: 'ONIGERR_PREMATURE_END_OF_CHAR_CLASS',
  -112: 'ONIGERR_UNMATCHED_RANGE_SPECIFIER_IN_CHAR_CLASS',
  -113: 'ONIGERR_TARGET_OF_REPEAT_OPERATOR_NOT_SPECIFIED',
  -114: 'ONIGERR_TARGET_OF_REPEAT_OPERATOR_INVALID',
  -117: 'ONIGERR_END_PATTERN_WITH_UNMATCHED_PARENTHESIS',
  -120: 'ONIGERR_INVALID_GROUP_OPTION',
  -121: 'ONIGERR_INVALID_POSIX_BRACKET_TYPE',
  -122: 'ONIGERR_INVALID_LOOK_BEHIND_PATTERN',
  -201: 'ONIGERR_TOO_BIG_NUMBER_FOR_REPEAT_RANGE',
  -202: 'ONIGERR_UPPER_SMALLER_THAN_LOWER_IN_REPEAT_RANGE',
  -203: 'ONIGERR_EMPTY_RANGE_IN_CHAR_CLASS',
  -206: 'ONIGERR_TOO_SHORT_MULTI_BYTE_STRING',
  -208: 'ONIGERR_INVALID_BACKREF',
  -209: 'ONIGERR_NUMBERED_BACKREF_OR_CALL_NOT_ALLOWED',
  -212: 'ONIGERR_TOO_LONG_WIDE_CHAR_VALUE',
  -213: 'ONIGERR_UNDEFINED_OPERATOR',
  -217: 'ONIGERR_UNDEFINED_NAME_REFERENCE',
  -218: 'ONIGERR_UNDEFINED_GROUP_REFERENCE',
  -221: 'ONIGERR_NEVER_ENDING_RECURSION',
  -223: 'ONIGERR_INVALID_CHAR_PROPERTY_NAME',
  -229: 'ONIGERR_UNDEFINED_CALLOUT_NAME',
  -400: 'ONIGERR_INVALID_CODE_POINT_VALUE',
  -401: 'ONIGERR_TOO_BIG_WIDE_CHAR_VALUE',
};
String _errName(int c) => _errMap[c] ?? '$c';
String _p(Uint8List b) => b
    .map(
      (x) => x >= 32 && x < 127
          ? String.fromCharCode(x)
          : '\\x${x.toRadixString(16).padLeft(2, '0')}',
    )
    .join();
