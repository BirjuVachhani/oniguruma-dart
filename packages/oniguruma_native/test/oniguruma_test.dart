@TestOn('vm')
library;

import 'package:oniguruma_native/oniguruma_native.dart';
import 'package:test/test.dart';

void main() {
  test('links and reports a version', () {
    expect(onigVersion(), matches(RegExp(r'^\d+\.\d+\.\d+')));
  });

  test('scanner finds the left-most / earliest pattern', () {
    final scanner = OnigScanner([r'\d+', r'[a-z]+']);
    final s = OnigString('  abc123');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });

    final m = scanner.findNextMatch(s, 0);
    expect(m, isNotNull);
    expect(m!.index, 1); // [a-z]+ matches at 2, before \d+ at 5
    expect(m.captureIndices[0].start, 2);
    expect(m.captureIndices[0].end, 5);
  });

  test('capture group offsets are correct (UTF-16 indices)', () {
    final scanner = OnigScanner([r'(\w+)@(\w+)']);
    final s = OnigString('x foo@bar');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });

    final m = scanner.findNextMatch(s, 0)!;
    expect(m.captureIndices[0].start, 2); // whole match "foo@bar"
    expect(m.captureIndices[0].end, 9);
    expect(m.captureIndices[1].start, 2); // group 1 "foo"
    expect(m.captureIndices[1].end, 5);
    expect(m.captureIndices[2].start, 6); // group 2 "bar"
    expect(m.captureIndices[2].end, 9);
  });

  test('no match returns null', () {
    final scanner = OnigScanner([r'\d+']);
    final s = OnigString('no digits here');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });
    expect(scanner.findNextMatch(s, 0), isNull);
  });

  test('scanCount counts every non-overlapping match in one native call', () {
    final scanner = OnigScanner([r'\w+']);
    final s = OnigString('foo 123 bar');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });
    // "foo", "123", "bar": three non-overlapping runs.
    expect(scanner.scanCount(s), 3);
  });

  test('scanCount agrees with a manual findNextMatch scan loop', () {
    final scanner = OnigScanner([r'\d+', r'[a-z]+']);
    final s = OnigString('ab 12 cd 34 ef');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });

    var start = 0, manual = 0;
    while (true) {
      final m = scanner.findNextMatch(s, start);
      if (m == null) break;
      manual++;
      final end = m.captureIndices[0].end;
      start = end > start ? end : start + 1;
    }
    expect(scanner.scanCount(s), manual);
    expect(manual, 5); // ab, 12, cd, 34, ef
  });

  test('scanCount is 0 when nothing matches', () {
    final scanner = OnigScanner([r'\d+']);
    final s = OnigString('no digits here');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });
    expect(scanner.scanCount(s), 0);
  });

  // The package's premise is that offsets are UTF-16 code units matching Dart
  // String indices. Oniguruma runs in UTF-8 and reports byte offsets; these pin
  // down that the byte→UTF-16 offset map restores Dart String indices exactly.
  group('UTF-16 offset correctness', () {
    test('multibyte BMP (CJK) offsets are code-unit indices', () {
      final scanner = OnigScanner([r'[a-z]+']);
      const text = '日本語abc'; // 3 CJK (1 code unit each) + "abc"
      final s = OnigString(text);
      addTearDown(() {
        s.dispose();
        scanner.dispose();
      });
      final m = scanner.findNextMatch(s, 0)!;
      expect(m.captureIndices[0].start, 3);
      expect(m.captureIndices[0].end, 6);
      expect(text.substring(3, 6), 'abc');
    });

    test('non-BMP (surrogate pair) shifts later offsets by 2 code units', () {
      final scanner = OnigScanner([r'[a-z]+']);
      const text = '\u{1F600}ab'; // 😀 is one code point = 2 UTF-16 units
      final s = OnigString(text);
      addTearDown(() {
        s.dispose();
        scanner.dispose();
      });
      final m = scanner.findNextMatch(s, 0)!;
      expect(m.captureIndices[0].start, 2); // after the 2-unit emoji
      expect(m.captureIndices[0].end, 4);
      expect(text.substring(2, 4), 'ab');
    });

    test('a non-BMP code point is matched as a single character', () {
      final scanner = OnigScanner([r'.']); // ANYCHAR = one code point
      const text = '\u{1F600}x';
      final s = OnigString(text);
      addTearDown(() {
        s.dispose();
        scanner.dispose();
      });
      final m = scanner.findNextMatch(s, 0)!;
      // The emoji spans both surrogate code units: [0, 2).
      expect(m.captureIndices[0].start, 0);
      expect(m.captureIndices[0].end, 2);
      expect(text.substring(0, 2), '\u{1F600}');
    });
  });

  // These are the cases the old UTF-16LE encoding got wrong: `\xHH` is a RAW
  // BYTE in Oniguruma, and TextMate/VS Code grammars author those bytes as
  // UTF-8. Under UTF-16LE they matched the wrong character or failed to compile
  // (and were silently skipped). Running Oniguruma in UTF-8 fixes the parity.
  group(r'\xHH grammar parity (UTF-8)', () {
    ({int start, int end})? first(String pattern, String subject) {
      final sc = OnigScanner([pattern]);
      final s = OnigString(subject);
      addTearDown(() {
        s.dispose();
        sc.dispose();
      });
      final m = sc.findNextMatch(s, 0);
      if (m == null) return null;
      final c = m.captureIndices[0];
      return (start: c.start, end: c.end);
    }

    test(r'\x41 matches ASCII "A"', () {
      final m = first(r'\x41', 'zzAzz');
      expect(m, isNotNull);
      expect((m!.start, m.end), (2, 3));
    });

    test(r'\xC3\xA9 (UTF-8 bytes of é) matches é', () {
      final m = first(r'\xC3\xA9', 'abécd'); // é at UTF-16 index 2
      expect(m, isNotNull);
      expect((m!.start, m.end), (2, 3));
    });

    test('char class with wide-hex code-point range matches accented chars', () {
      // The correct UTF-8 idiom for an accented-identifier class (raw \xHH would
      // be incomplete high bytes); this is how real CSS/HTML grammars write it.
      final m = first(
        r'[a-zA-Z\x{00C0}-\x{00FF}][a-zA-Z0-9\x{00C0}-\x{00FF}]*',
        'café {',
      );
      expect(m, isNotNull);
      expect((m!.start, m.end), (0, 4)); // "café"
    });

    test(r'\x{...} wide-hex still matches (BMP + non-BMP)', () {
      expect(first(r'\x{00E9}', 'abécd')?.start, 2); // é
      final emoji = first(r'\x{1F600}', 'x\u{1F600}y');
      expect(emoji, isNotNull);
      expect((emoji!.start, emoji.end), (1, 3)); // surrogate pair
    });

    test('a literal non-ASCII pattern matches its character', () {
      final m = first('é', 'abécd');
      expect(m, isNotNull);
      expect((m!.start, m.end), (2, 3));
    });
  });

  group('scanner semantics', () {
    test('findNextMatch resumes from a non-zero start position', () {
      final scanner = OnigScanner([r'cat']);
      final s = OnigString('cat dog cat');
      addTearDown(() {
        s.dispose();
        scanner.dispose();
      });
      final first = scanner.findNextMatch(s, 0)!;
      expect(first.captureIndices[0].start, 0);
      final next = scanner.findNextMatch(s, first.captureIndices[0].end)!;
      expect(next.captureIndices[0].start, 8);
      expect(next.captureIndices[0].end, 11);
    });

    test('patterns that fail to compile are skipped, not fatal', () {
      // '(' is an unterminated group: Oniguruma rejects it. The scanner must
      // still work with the remaining valid pattern (forgiving behavior).
      final scanner = OnigScanner([r'(', r'\d+']);
      final s = OnigString('abc123');
      addTearDown(() {
        s.dispose();
        scanner.dispose();
      });
      final m = scanner.findNextMatch(s, 0)!;
      expect(m.index, 1); // pattern 0 was skipped; pattern 1 (\d+) matched
      expect(m.captureIndices[0].start, 3);
      expect(m.captureIndices[0].end, 6);
    });

    test('an unmatched optional group reports (-1, -1)', () {
      final scanner = OnigScanner([r'(a)(b)?c']);
      final s = OnigString('ac');
      addTearDown(() {
        s.dispose();
        scanner.dispose();
      });
      final m = scanner.findNextMatch(s, 0)!;
      expect(m.captureIndices[0].start, 0); // whole match "ac"
      expect(m.captureIndices[0].end, 2);
      expect(m.captureIndices[1].start, 0); // group 1 "a"
      expect(m.captureIndices[1].end, 1);
      expect(m.captureIndices[2].start, -1); // group 2 (b)? did not participate
      expect(m.captureIndices[2].end, -1);
    });

    test(
      'multi-pattern tokenize: left-most wins, advancing through the input',
      () {
        final scanner = OnigScanner([r'\d+', r'[a-z]+', r'\s+']);
        final s = OnigString('ab 12');
        addTearDown(() {
          s.dispose();
          scanner.dispose();
        });
        final seen = <(int, int, int)>[]; // (patternIndex, start, end)
        var start = 0;
        while (true) {
          final m = scanner.findNextMatch(s, start);
          if (m == null) break;
          final c = m.captureIndices[0];
          seen.add((m.index, c.start, c.end));
          start = c.end > start ? c.end : start + 1;
        }
        expect(seen, [
          (1, 0, 2), // "ab"  -> [a-z]+
          (2, 2, 3), // " "   -> \s+
          (0, 3, 5), // "12"  -> \d+
        ]);
        expect(scanner.scanCount(s), 3);
      },
    );
  });

  group('edge cases', () {
    test('empty subject: no match, zero count', () {
      final scanner = OnigScanner([r'\d+']);
      final s = OnigString('');
      addTearDown(() {
        s.dispose();
        scanner.dispose();
      });
      expect(scanner.findNextMatch(s, 0), isNull);
      expect(scanner.scanCount(s), 0);
    });

    test('empty pattern list: no match, zero count', () {
      final scanner = OnigScanner([]);
      final s = OnigString('anything at all');
      addTearDown(() {
        s.dispose();
        scanner.dispose();
      });
      expect(scanner.findNextMatch(s, 0), isNull);
      expect(scanner.scanCount(s), 0);
    });
  });
}
