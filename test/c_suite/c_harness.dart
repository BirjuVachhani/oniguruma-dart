// Shared harness for the Dart translations of Oniguruma's C test files.
//
// Each generated `*_test.dart` file is a static, 1:1 translation of one C test
// file: the C `x2/x3/n/e` macro calls become Dart calls with the pattern and
// subject as byte-exact string literals (every byte is a code unit < 256).
// These helpers mirror the C `xx` harness: compile, search (forward or, for the
// backref suite, backward), and assert region offsets / no-match / error code.
import 'dart:typed_data';

import 'package:oniguruma_dart/oniguruma_dart.dart';
import 'package:test/test.dart';

export 'package:test/test.dart' show group, test;

/// Per-file configuration, set once at the top of each generated `main()`.
class CSuite {
  final OnigEncoding enc;
  final OnigSyntax syntax;
  final bool backward;
  final int option;
  const CSuite({
    required this.enc,
    this.syntax = onigSyntaxOniguruma,
    this.backward = false,
    this.option = OnigOption.none,
  });

  /// Byte-exact decode: each UTF-16 code unit of [s] is one byte (the generator
  /// only emits code units < 256, via `\xHH` escapes or literal ASCII).
  static Uint8List b(String s) => Uint8List.fromList(s.codeUnits);

  int _run(Uint8List pat, Uint8List sub, OnigRegion region) {
    final reg = onigNew(pat, pat.length, enc, syntax, option);
    final start = backward ? sub.length : 0;
    final range = backward ? 0 : sub.length;
    return onigSearch(
      reg,
      sub,
      sub.length,
      start,
      range,
      region,
      retryLimit: 10000000,
    );
  }

  /// C `x2`: whole-match (mem 0) spans [from,to].
  void x2(String p, String s, int from, int to, int line) =>
      x3(p, s, from, to, 0, line);

  /// C `x3`: capture group [mem] spans [from,to].
  void x3(String p, String s, int from, int to, int mem, int line) {
    test('#$line /${_name(p)}/', () {
      final region = OnigRegion();
      final r = _run(b(p), b(s), region);
      expect(r, greaterThanOrEqualTo(0), reason: 'expected a match');
      expect([region.beg[mem], region.end[mem]], [from, to]);
    });
  }

  /// C `n`: no match.
  void n(String p, String s, int line) {
    test('#$line /${_name(p)}/ (no match)', () {
      final region = OnigRegion();
      final r = _run(b(p), b(s), region);
      expect(r, lessThan(0), reason: 'expected no match');
    });
  }

  /// C `e`: compilation (or search) fails with error code [errNo].
  void e(String p, String s, int errNo, int line) {
    test('#$line /${_name(p)}/ (err $errNo)', () {
      int got;
      try {
        final region = OnigRegion();
        got = _run(b(p), b(s), region);
      } on OnigException catch (ex) {
        got = ex.code;
      }
      expect(got, errNo);
    });
  }

  static String _name(String p) {
    final sb = StringBuffer();
    for (final c in p.codeUnits) {
      sb.write(
        c >= 0x20 && c < 0x7f
            ? String.fromCharCode(c)
            : '\\x${c.toRadixString(16).padLeft(2, '0')}',
      );
    }
    final out = sb.toString();
    return out.length > 60 ? '${out.substring(0, 60)}…' : out;
  }
}
