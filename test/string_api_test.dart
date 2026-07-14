/// Tests for the idiomatic String API (`lib/src/api/string_api.dart`), focused
/// on the byte↔UTF-16 offset mapping across the four string classes:
///   * pure ASCII        (identity fast path, no maps)
///   * Latin-1 (>= 0x80) (2-byte UTF-8, dense tables)
///   * BMP non-Latin     (3-byte UTF-8)
///   * supplementary     (4-byte UTF-8 / surrogate-pair code units)
///
/// The universal invariant that pins the mapping regardless of pattern or
/// input: for every match/group, `input.substring(start, end) == group`. This
/// catches any byte-offset → code-unit-index error introduced by the ASCII fast
/// path or the typed-table rewrite.
library;

import 'package:oniguruma_dart/oniguruma_dart.dart';
import 'package:test/test.dart';

/// Assert `input.substring(m.start, m.end) == group(0)` and the same for every
/// set capture group, for every match of [pat] in [input].
void _checkOffsets(String pat, String input) {
  final re = OnigRegex.compile(pat);
  for (final m in re.allMatches(input)) {
    expect(input.substring(m.start, m.end), m.group(0),
        reason: 'whole-match offsets for /$pat/ in "$input"');
    for (var i = 0; i <= m.groupCount; i++) {
      final s = m.startOf(i), e = m.endOf(i);
      if (s >= 0 && e >= 0) {
        expect(input.substring(s, e), m.group(i),
            reason: 'group $i offsets for /$pat/ in "$input"');
      }
    }
  }
}

void main() {
  group('offset mapping invariant (substring == group)', () {
    // A pattern set exercising literals, classes, quantifiers, captures, dot.
    const pats = [
      'b',
      r'\w+',
      r'[a-z]+',
      '.',
      '(.)(.)',
      r'(\w)(\w*)',
      'a.c',
      r'\w+@\w+',
    ];
    const inputs = [
      // ASCII (identity fast path)
      'foo bar foo baz',
      'a1 b2 c3',
      'user@host and me@there',
      // Latin-1, code units 0x80..0xFF (2-byte UTF-8)
      'café résumé naïve',
      'aébéc déf',
      'Grüße Straße',
      // BMP non-Latin (3-byte UTF-8)
      '東b京 x漢y字z',
      'αβγ a bc δ',
      // Supplementary / surrogate pairs (4-byte UTF-8, 2 code units each)
      '😀b😀 c😀d',
      '𝕏y𝕐z ab',
      // Mixed
      'a😀é東b',
    ];
    for (final p in pats) {
      for (final inp in inputs) {
        test('/$p/ over "$inp"', () => _checkOffsets(p, inp));
      }
    }
  });

  group('exact offsets across string classes', () {
    test('ASCII: literal finds all occurrences at code-unit offsets', () {
      final re = OnigRegex.compile('foo');
      final ms = re.allMatches('foo bar foo').toList();
      expect(ms.length, 2);
      expect([ms[0].start, ms[0].end], [0, 3]);
      expect([ms[1].start, ms[1].end], [8, 11]);
      expect(ms.map((m) => m.group(0)), ['foo', 'foo']);
    });

    test('Latin-1: char after é is at the right code-unit index', () {
      // a(0) é(1) b(2) é(3) c(4)
      final m = OnigRegex.compile('b').firstMatch('aébéc')!;
      expect([m.start, m.end], [2, 3]);
      expect(m.group(0), 'b');
    });

    test('BMP: char between CJK is at the right code-unit index', () {
      // 東(0) b(1) 京(2)
      final m = OnigRegex.compile('b').firstMatch('東b京')!;
      expect([m.start, m.end], [1, 2]);
    });

    test('supplementary: emoji spans two code units', () {
      // 😀 = U+1F600 -> code units 0,1 ; b at index 2
      final m = OnigRegex.compile('b').firstMatch('😀b')!;
      expect([m.start, m.end], [2, 3]);
      expect(m.group(0), 'b');
    });

    test('match spanning non-ASCII: dot matches the multi-byte char', () {
      // a(0) é(1) c(2) -> /a.c/ matches [0,3)
      final m = OnigRegex.compile('a.c').firstMatch('aéc')!;
      expect([m.start, m.end], [0, 3]);
      expect(m.group(0), 'aéc');
    });
  });

  group('parity with SDK RegExp on ASCII (offsets + text)', () {
    // On ASCII, Oniguruma and RegExp agree on [a-z]+/\w+/\d+; assert identical
    // match spans and texts so the identity fast path is verified end-to-end.
    for (final pat in [r'[a-z]+', r'\w+', r'\d+', r'\w+@\w+']) {
      for (final inp in [
        'the quick brown fox',
        'a1b2 c3d4  e5',
        'mail me@here.org or you@there.net',
      ]) {
        test('/$pat/ over "$inp"', () {
          final og = OnigRegex.compile(pat).allMatches(inp).toList();
          final re = RegExp(pat).allMatches(inp).toList();
          expect(og.length, re.length, reason: 'match count');
          for (var i = 0; i < og.length; i++) {
            expect([og[i].start, og[i].end], [re[i].start, re[i].end],
                reason: 'span $i');
            expect(og[i].group(0), re[i].group(0), reason: 'text $i');
          }
        });
      }
    }
  });

  group('replace helpers map offsets correctly', () {
    test('replaceAll across non-ASCII', () {
      final re = OnigRegex.compile('b');
      final out = re.replaceAll('aébéc', (m) => '[${m.group(0)}]');
      expect(out, 'aé[b]éc');
    });

    test('replaceAll simple', () {
      final re = OnigRegex.compile(r'\d+');
      expect(re.replaceAll('a1b22c333', (m) => '#'), 'a#b#c#');
    });

    test('replaceFirst with non-ASCII context', () {
      final re = OnigRegex.compile('京');
      expect(re.replaceFirst('東京東京', (m) => 'X'), '東X東京');
    });
  });

  group('non-ASCII cursor edge cases', () {
    test('allMatches with a non-zero start over non-ASCII (byteAt > 0)', () {
      // é(0) b(1) é(2) b(3) é(4) ; start at code unit 2 -> find 'b' at 3
      final ms = OnigRegex.compile('b').allMatches('ébébé', 2).toList();
      expect(ms.map((m) => m.start), [3]);
      expect(ms.single.group(0), 'b');
    });

    test('start inside a supplementary char resolves correctly', () {
      // 😀(0,1) x(2) 😀(3,4) x(5) ; start at code unit 2
      final ms = OnigRegex.compile('x').allMatches('😀x😀x', 2).toList();
      expect(ms.map((m) => m.start), [2, 5]);
    });

    test('group offsets queried out of order (forces backward cursor walk)', () {
      // \w matches all of 東 a b é 京 (Unicode word chars); match starts at 0.
      const s = '東abé京';
      final m = OnigRegex.compile(r'(\w)(\w)(\w)').firstMatch(s)!;
      // Query groups back-to-front so charAt must walk the cursor backward.
      expect(m.group(3), 'b');
      expect(m.group(2), 'a');
      expect(m.group(1), '東');
      for (var i = 1; i <= 3; i++) {
        expect(s.substring(m.startOf(i), m.endOf(i)), m.group(i));
      }
      expect(s.substring(m.start, m.end), m.group(0));
    });
  });

  group('encode cache correctness', () {
    test('one regex, repeated + interleaved scans of different strings', () {
      final re = OnigRegex.compile(r'\w+');
      const a = 'foo bar baz'; // ASCII
      const b = 'héllo 東京 wörld'; // non-ASCII
      const c = 'x1 y2 z3'; // ASCII, different
      // Hit (a,a), rebuild (b), back to a, alternate — every scan must be right.
      for (final s in [a, a, b, a, c, b, b, a]) {
        final ms = re.allMatches(s).toList();
        for (final m in ms) {
          expect(s.substring(m.start, m.end), m.group(0),
              reason: 'scan of "$s"');
        }
        expect(ms, isNotEmpty);
      }
    });

    test('many matches with captures reuse the Executor without corruption', () {
      // Long multi-match input + capture groups: every allMatches step reuses
      // the cached Executor, so memStart/memEnd must reset per match. Compare
      // exhaustively against RegExp (they agree on this pattern).
      final buf = StringBuffer();
      for (var i = 0; i < 500; i++) {
        buf.write('a${i}b c${i}d ');
      }
      final s = buf.toString();
      final pat = r'(\w)(\w+)(\w)';
      final og = OnigRegex.compile(pat).allMatches(s).toList();
      final re = RegExp(pat).allMatches(s).toList();
      expect(og.length, re.length);
      expect(og.length, greaterThan(500));
      for (var i = 0; i < og.length; i++) {
        for (var g = 0; g <= 3; g++) {
          expect(og[i].group(g), re[i].group(g), reason: 'match $i group $g');
        }
      }
    });

    test('firstMatch then allMatches on the same string agree', () {
      final re = OnigRegex.compile('京');
      const s = '東京東京東';
      final fm = re.firstMatch(s)!;
      final am = re.allMatches(s).first;
      expect([fm.start, fm.end], [am.start, am.end]);
      expect([fm.start, fm.end], [1, 2]);
    });
  });

  group('start offset + empty matches', () {
    test('allMatches honors start (code-unit) offset', () {
      final ms = OnigRegex.compile('a').allMatches('aXaXa', 1).toList();
      expect(ms.map((m) => m.start), [2, 4]);
    });

    test('zero-width matches advance by one code unit', () {
      final ms = OnigRegex.compile('').allMatches('ab').toList();
      // empty pattern matches at each position: 0,1,2
      expect(ms.map((m) => m.start), [0, 1, 2]);
    });
  });
}
