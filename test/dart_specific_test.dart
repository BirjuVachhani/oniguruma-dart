// Dart-specific robustness tests: the idiomatic `String` API, the byte-core
// model (Uint8List / byte offsets), error surfaces, and focused coverage of the
// features added while porting the C suite (backward search, absent operator,
// ASCII-mode options, nested classes / set-ops, conditionals, escapes, and the
// multi-byte encodings). These complement the 1:1 C-suite translations.
import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_dart/oniguruma_dart.dart';
import 'package:test/test.dart';

Uint8List u8(String s) => Uint8List.fromList(utf8.encode(s));

/// Search [pat] in [sub] (UTF-8, default syntax); returns "beg,end g1 g2…" or
/// "NOMATCH", or "ERR:<code>".
String search(
  String pat,
  String sub, {
  int start = 0,
  int? range,
  int option = OnigOption.none,
}) {
  final pb = u8(pat), sb = u8(sub);
  try {
    final reg = onigNew(pb, pb.length, utf8Encoding, onigSyntaxDefault, option);
    final region = OnigRegion();
    // Runtime options (NOT_BOL/NOT_EOL/…) are applied at search time.
    final r = onigSearch(
      reg,
      sb,
      sb.length,
      start,
      range ?? sb.length,
      region,
      retryLimit: 10000000,
      option: option,
    );
    if (r < 0) return 'NOMATCH';
    final b = StringBuffer('${region.beg[0]},${region.end[0]}');
    for (var i = 1; i < region.numRegs; i++) {
      b.write(' ${region.beg[i]},${region.end[i]}');
    }
    return b.toString();
  } on OnigException catch (e) {
    return 'ERR:${e.code}';
  }
}

void main() {
  group('idiomatic String API', () {
    test('firstMatch + groups + char offsets', () {
      final re = OnigRegex.compile(r'(?<user>\w+)@(?<host>\w+)');
      final m = re.firstMatch('contact bob@acme today')!;
      expect(m.group(0), 'bob@acme');
      expect(m.namedGroup('user'), 'bob');
      expect(m.namedGroup('host'), 'acme');
      expect(m.start, 8);
      expect(m.end, 16);
    });

    test('allMatches', () {
      final re = OnigRegex.compile(r'\d+');
      expect(re.allMatches('a1 b22 c333').map((m) => m.group(0)).toList(), [
        '1',
        '22',
        '333',
      ]);
    });

    test('replaceAll', () {
      final re = OnigRegex.compile(r'\s+');
      expect(re.replaceAll('a  b   c', (_) => '_'), 'a_b_c');
    });

    test('no match returns null', () {
      expect(OnigRegex.compile(r'z+').firstMatch('aaa'), isNull);
    });

    test('char offsets map across multi-byte (UTF-16 units)', () {
      // "café🎉x": é is 1 UTF-16 unit, 🎉 is a surrogate pair (2 units).
      final re = OnigRegex.compile(r'x');
      final m = re.firstMatch('café🎉x')!;
      expect(m.group(0), 'x');
      // café(4) + 🎉(2 UTF-16 units) = 6
      expect(m.start, 6);
    });
  });

  group('byte-core API', () {
    test(
      'empty pattern matches empty at 0',
      () => expect(search('', ''), '0,0'),
    );
    test('empty pattern on non-empty', () => expect(search('', 'abc'), '0,0'));
    test('literal byte offsets (not char)', () {
      // "é" is 2 UTF-8 bytes; the match after it is at byte offset 2.
      expect(search('b', 'éb'), '2,3');
    });
    test('region reuse across searches', () {
      final pb = u8(r'\d+');
      final reg = onigNew(pb, pb.length, utf8Encoding, onigSyntaxDefault, 0);
      final region = OnigRegion();
      expect(onigSearch(reg, u8('x12'), 3, 0, 3, region), 1);
      expect([region.beg[0], region.end[0]], [1, 3]);
      // reuse the same region object
      expect(onigSearch(reg, u8('999'), 3, 0, 3, region), 0);
      expect([region.beg[0], region.end[0]], [0, 3]);
    });
    test('onigMatch anchors at position (no scan)', () {
      final pb = u8(r'\d+');
      final reg = onigNew(pb, pb.length, utf8Encoding, onigSyntaxDefault, 0);
      final sb = u8('a12');
      expect(onigMatch(reg, sb, sb.length, 0, OnigRegion()), lessThan(0));
      expect(onigMatch(reg, sb, sb.length, 1, OnigRegion()), 2); // matched len
    });
  });

  group('backward search', () {
    test('finds highest match ≤ start', () {
      final pb = u8('a');
      final reg = onigNew(pb, pb.length, utf8Encoding, onigSyntaxDefault, 0);
      final sb = u8('aaa');
      final region = OnigRegion();
      final r = onigSearch(reg, sb, sb.length, sb.length, 0, region);
      expect(r, 2);
      expect([region.beg[0], region.end[0]], [2, 3]);
    });
  });

  group('absent operator', () {
    test(
      '(?~ab) longest run without "ab"',
      () => expect(search('(?~ab)', 'ccc\ndab'), '0,5'),
    );
    test(
      '(?~abc) empty when abc at start',
      () => expect(search('(?~abc)', 'abc'), '0,0'),
    );
    test(
      '(?~|ab|.*) generator + stopper',
      () => expect(search('(?~|ab|.*)', 'ccc\nddd'), '0,3'),
    );
  });

  group('ASCII-mode options', () {
    test(
      r'(?W:\w) is ASCII-only',
      () => expect(search(r'(?W:\w)', 'あ'), 'NOMATCH'),
    );
    test(
      r'\w matches Unicode by default',
      () => expect(search(r'\w', 'あ'), '0,3'),
    );
    test(
      r'(?P:\d) ASCII digits only',
      () => expect(search(r'(?P:\d)', '３'), 'NOMATCH'),
    ); // fullwidth 3
  });

  group('char-class set operations', () {
    test('nested [[ab]c]', () => expect(search('[[ab]c]', 'c'), '0,1'));
    test(
      'intersection a-z && b-y',
      () => expect(search('[a-z&&b-y]', 'b'), '0,1'),
    );
    test(
      'negated intersection',
      () => expect(search('[^a-z&&b-y]', 'a'), '0,1'),
    );
    test(r'class ctype [\d]', () => expect(search(r'[\d]', '5'), '0,1'));
  });

  group('conditionals', () {
    test(
      '(?(1)…) with group set',
      () => expect(search(r'(a)(?(1)b|c)', 'ab'), '0,2 0,1'),
    );
    test(
      '(?(1)…) with group unset',
      () => expect(search(r'(a)?(?(1)b|c)', 'c'), '0,1 -1,-1'),
    );
  });

  group('escapes', () {
    test(r'\ca control', () => expect(search(r'\ca', '\x01'), '0,1'));
    test(r'\o{101} octal', () => expect(search(r'\o{101}', 'A'), '0,1'));
    test(r'\x{61} hex', () => expect(search(r'\x{61}', 'a'), '0,1'));
    test(
      r'\x{61 62 63} multi-code-point',
      () => expect(search(r'\x{61 62 63}', 'abc'), '0,3'),
    );
  });

  group('errors surface as OnigException codes', () {
    test('unmatched (', () => expect(search('(a', 'a'), 'ERR:-117'));
    test('target of repeat', () => expect(search('*', 'a'), 'ERR:-113'));
    test(
      'valid backref matches',
      () => expect(search(r'(a)\1', 'aa'), '0,2 0,1'),
    );
    // \x{110000} is still encodable as 4-byte UTF-8 (RFC 3629 caps at
    // 0x1FFFFF); a value beyond that is rejected as an invalid code point.
    test(
      'too-big code point',
      () => expect(search(r'\x{7fffffff}', 'a'), 'ERR:-400'),
    );
  });

  group('multi-byte encodings', () {
    test('EUC-JP literal', () {
      // U+3042 あ in EUC-JP = 0xA4 0xA2.
      final pat = Uint8List.fromList([0xa4, 0xa2]);
      final reg = onigNew(pat, pat.length, eucJpEncoding, onigSyntaxDefault, 0);
      final region = OnigRegion();
      final sub = Uint8List.fromList([0xa4, 0xa2]);
      expect(onigSearch(reg, sub, sub.length, 0, sub.length, region), 0);
      expect([region.beg[0], region.end[0]], [0, 2]);
    });
    test('UTF-16BE class [a-c]', () {
      Uint8List be(List<int> cps) {
        final b = <int>[];
        for (final c in cps) {
          b
            ..add((c >> 8) & 0xff)
            ..add(c & 0xff);
        }
        return Uint8List.fromList(b);
      }

      final pat = be([0x5b, 0x61, 0x2d, 0x63, 0x5d]); // [a-c]
      final reg = onigNew(
        pat,
        pat.length,
        utf16BeEncoding,
        onigSyntaxDefault,
        0,
      );
      final region = OnigRegion();
      final sub = be([0x62]); // b
      expect(onigSearch(reg, sub, sub.length, 0, sub.length, region), 0);
      expect([region.beg[0], region.end[0]], [0, 2]);
    });
  });

  group('runtime match options', () {
    test(
      'NOT_BOL',
      () => expect(search('^a', 'a', option: OnigOption.notBol), 'NOMATCH'),
    );
    test(
      'NOTEOL',
      () => expect(search(r'a$', 'a', option: OnigOption.notEol), 'NOMATCH'),
    );
  });
}
