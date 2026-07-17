@TestOn('browser')
library;

import 'package:oniguruma_native/oniguruma_native.dart';
import 'package:test/test.dart';

/// The web (WebAssembly) backend runs the same Oniguruma + shim as the FFI
/// backend, so these mirror the IO suite's behavioural assertions — offsets and
/// semantics must be byte-identical through the wasm boundary (UTF-8 in the
/// module, mapped back to UTF-16 Dart String indices). Run under both compilers:
///   dart test test/oniguruma_web_test.dart -p chrome
///   dart test test/oniguruma_web_test.dart -p chrome -c dart2wasm
void main() {
  setUpAll(() async {
    await loadWasm(); // instantiate the embedded module once
  });

  test('loadWasm is idempotent', () async {
    await loadWasm();
    await loadWasm();
    expect(onigVersion(), matches(RegExp(r'^\d+\.\d+\.\d+')));
  });

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

  test('scanCount counts every non-overlapping match in one crossing', () {
    final scanner = OnigScanner([r'\w+']);
    final s = OnigString('foo 123 bar');
    addTearDown(() {
      s.dispose();
      scanner.dispose();
    });
    expect(scanner.scanCount(s), 3); // "foo", "123", "bar"
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

  group('UTF-16 offset correctness', () {
    test('multibyte BMP (CJK) offsets are code-unit indices', () {
      final scanner = OnigScanner([r'[a-z]+']);
      const text = '日本語abc';
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
      expect(m.captureIndices[0].start, 2);
      expect(m.captureIndices[0].end, 4);
      expect(text.substring(2, 4), 'ab');
    });

    test('a non-BMP code point is matched as a single character', () {
      final scanner = OnigScanner([r'.']);
      const text = '\u{1F600}x';
      final s = OnigString(text);
      addTearDown(() {
        s.dispose();
        scanner.dispose();
      });
      final m = scanner.findNextMatch(s, 0)!;
      expect(m.captureIndices[0].start, 0);
      expect(m.captureIndices[0].end, 2);
      expect(text.substring(0, 2), '\u{1F600}');
    });
  });

  // The cases the old UTF-16LE marshalling got wrong: `\xHH` is a raw byte, and
  // TextMate grammars author those bytes as UTF-8. Running Oniguruma in UTF-8
  // fixes the parity while offsets stay UTF-16 code-unit indices.
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
      final m = first(r'\xC3\xA9', 'abécd');
      expect(m, isNotNull);
      expect((m!.start, m.end), (2, 3));
    });

    test('char class with wide-hex code-point range matches accented chars', () {
      final m = first(
        r'[a-zA-Z\x{00C0}-\x{00FF}][a-zA-Z0-9\x{00C0}-\x{00FF}]*',
        'café {',
      );
      expect(m, isNotNull);
      expect((m!.start, m.end), (0, 4));
    });

    test(r'\x{...} wide-hex still matches (BMP + non-BMP)', () {
      expect(first(r'\x{00E9}', 'abécd')?.start, 2);
      final emoji = first(r'\x{1F600}', 'x\u{1F600}y');
      expect(emoji, isNotNull);
      expect((emoji!.start, emoji.end), (1, 3));
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
      expect(m.captureIndices[0].start, 0);
      expect(m.captureIndices[0].end, 2);
      expect(m.captureIndices[1].start, 0);
      expect(m.captureIndices[1].end, 1);
      expect(m.captureIndices[2].start, -1); // (b)? did not participate
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
        final seen = <(int, int, int)>[];
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

  group('capture-group readback', () {
    test('many capture groups are read back correctly', () {
      // 10 single-char groups -> whole match + 10 groups = 11 regions.
      final scanner = OnigScanner([r'(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)']);
      final s = OnigString('abcdefghij');
      addTearDown(() {
        s.dispose();
        scanner.dispose();
      });
      final m = scanner.findNextMatch(s, 0)!;
      expect(m.captureIndices.length, 11);
      expect(m.captureIndices[0].start, 0); // whole match
      expect(m.captureIndices[0].end, 10);
      for (var g = 1; g <= 10; g++) {
        expect(m.captureIndices[g].start, g - 1);
        expect(m.captureIndices[g].end, g);
      }
    });

    test(
      'Unicode property classes work (full tables linked into the wasm)',
      () {
        final scanner = OnigScanner([r'\p{Han}+']);
        final s = OnigString('東京タワー'); // 東京 are Han; タワー are not
        addTearDown(() {
          s.dispose();
          scanner.dispose();
        });
        final m = scanner.findNextMatch(s, 0)!;
        expect(m.captureIndices[0].start, 0);
        expect(m.captureIndices[0].end, 2);
      },
    );
  });

  // The web backend marshals through the wasm heap, which grows when a subject
  // exceeds the initial ~4 MB. Growth detaches every heap view, so the backend
  // re-derives views per call; these guard that offsets and counts stay exact
  // across the growth point — a hazard the small subjects above never reach.
  group('memory growth (wasm heap view detachment)', () {
    test('a subject larger than the initial heap still matches correctly', () {
      final filler = ' ' * (6 * 1024 * 1024); // 6M spaces -> 12 MB UTF-16
      final needleAt = filler.length; // UTF-16 index of "needle"
      final scanner = OnigScanner([r'needle']);
      final s = OnigString('${filler}needle$filler');
      addTearDown(() {
        s.dispose();
        scanner.dispose();
      });
      final m = scanner.findNextMatch(s, 0)!;
      expect(m.captureIndices[0].start, needleAt);
      expect(m.captureIndices[0].end, needleAt + 'needle'.length);
      expect(scanner.scanCount(s), 1);
    });

    test('bulk scanCount over a multi-megabyte subject is exact', () {
      const n = 500000; // "x " repeated -> n one-char \w+ matches
      final scanner = OnigScanner([r'\w+']);
      final s = OnigString('x ' * n); // 1M units = 2 MB
      addTearDown(() {
        s.dispose();
        scanner.dispose();
      });
      expect(scanner.scanCount(s), n);
    });
  });
}
