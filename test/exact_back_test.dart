/// Regression tests for the `C+ exact…` walk-back optimization (`optimize.dart`
/// `_setExactBack` → `reg.hasExactBack`; `search.dart` middle-exact walk-back):
/// for a pattern that starts with a greedy `C+` immediately followed by a
/// mandatory exact literal L (L[0] ∉ C), the driver walks back from each L to
/// the C-run start (the unique leftmost candidate) instead of scanning the gap.
/// Results must be byte-identical to a full scan — verified against an
/// independent oracle over thousands of random subjects.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_dart/src/encoding/encodings.dart';
import 'package:oniguruma_dart/src/region.dart';
import 'package:oniguruma_dart/src/regex.dart';
import 'package:oniguruma_dart/src/syntax.dart';
import 'package:oniguruma_dart/src/exec/search.dart';
import 'package:test/test.dart';

Regex _c(String pat) {
  final pb = Uint8List.fromList(utf8.encode(pat));
  return onigNew(pb, pb.length, utf8Encoding, onigSyntaxOniguruma, 0);
}

(int, int)? _m(String pat, String subj) {
  final r = _c(pat);
  final sb = Uint8List.fromList(utf8.encode(subj));
  final region = OnigRegion();
  final rc = onigSearch(r, sb, sb.length, 0, sb.length, region);
  return rc < 0 ? null : (region.beg[0], region.end[0]);
}

void main() {
  group('flag detection', () {
    test('set for \\w+@\\w+ style', () {
      expect(_c(r'\w+@\w+').hasExactBack, isTrue);
      expect(_c(r'[a-z]+@[a-z]+').hasExactBack, isTrue);
      expect(_c(r'\d+\.\d+').hasExactBack, isTrue);
    });
    test('NOT set when the exact byte is in the class', () {
      // '.' matches `\w`? no; but `[a-z.]+/` — '/' not in class OK. Here the
      // exact 'a' IS in [a-z] → must not use walk-back.
      expect(_c(r'[a-z]+a[a-z]+').hasExactBack, isFalse);
    });
    test('NOT set with a literal before the class', () {
      expect(_c(r'x\w+@\w+').hasExactBack, isFalse);
    });
    test('NOT set for a negated leading class', () {
      expect(_c(r'[^@]+@\w+').hasExactBack, isFalse);
    });
  });

  group('\\w+@\\w+ matches (leftmost, boundaries)', () {
    test('basic', () => expect(_m(r'\w+@\w+', 'ab@cd'), (0, 5)));
    test('leftmost start is the run head', () =>
        expect(_m(r'\w+@\w+', 'xy name@host zz'), (3, 12)));
    test('@ at start (no \\w before) → skip to a real one', () {
      expect(_m(r'\w+@\w+', '@bad ok@yes'), (5, 11));
    });
    test('@ at end (no \\w after) → no match', () =>
        expect(_m(r'\w+@\w+', 'abc@'), isNull));
    test('no @ at all → no match', () =>
        expect(_m(r'\w+@\w+', 'no at sign here'), isNull));
    test('multiple @ — first complete wins', () =>
        expect(_m(r'\w+@\w+', 'a@ @ x@y'), (5, 8)));
    test('mid-word start not chosen over run head', () {
      // "aaa@b": leftmost is index 0, not 1/2.
      expect(_m(r'\w+@\w+', 'aaa@b'), (0, 5));
    });
  });

  group('multibyte \\w before the exact', () {
    test('accented word char is part of the run', () {
      // "café@x": é is a Unicode word char, so the run head is 'c' (byte 0).
      // café = 5 bytes, @ at 5, x at 6 → (0, 7).
      expect(_m(r'\w+@\w+', 'café@x'), (0, 7));
    });
    test('non-word multibyte stops the walk-back', () {
      // "。ok@y": 。(3 bytes, non-word) then "ok@y". Run head is 'o' (byte 3).
      expect(_m(r'\w+@\w+', '。ok@y'), (3, 7));
    });
  });

  group('cclass and other separators', () {
    test('[a-z]+ colon', () => expect(_m(r'[a-z]+:[a-z]+', 'go x:y z'), (3, 6)));
    test(r'\d+\.\d+ decimal', () =>
        expect(_m(r'\d+\.\d+', 'pi is 3.14 ish'), (6, 10)));
    test('tail class mismatch → no match', () =>
        expect(_m(r'\w+@\d+', 'name@host'), isNull)); // host isn't digits
    test('tail class mismatch then a real one', () =>
        expect(_m(r'\w+@\d+', 'name@host a@42'), (10, 14))); // "a@42"
  });

  // Independent oracle: leftmost (p, e) for `\w+@\w+` over ASCII computed by a
  // naive scan; compared to the engine over random subjects.
  group('walk-back vs independent oracle (fuzz)', () {
    bool w(int c) =>
        (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x61 && c <= 0x7a) ||
        c == 0x5f;
    (int, int)? ref(String s) {
      for (var p = 0; p < s.length; p++) {
        if (!w(s.codeUnitAt(p))) continue;
        var a = p;
        while (a < s.length && w(s.codeUnitAt(a))) {
          a++;
        }
        if (a >= s.length || s.codeUnitAt(a) != 0x40) continue; // need '@'
        var b = a + 1;
        if (b >= s.length || !w(s.codeUnitAt(b))) continue; // need \w after
        while (b < s.length && w(s.codeUnitAt(b))) {
          b++;
        }
        return (p, b);
      }
      return null;
    }

    test('4000 random subjects', () {
      var rng = 0xBEEF77;
      int rand(int m) {
        rng = (rng * 1103515245 + 12345) & 0x7fffffff;
        return rng % m;
      }

      const alpha = 'abcXY_09 @@.@-!'; // '@' over-represented to force matches
      for (var iter = 0; iter < 4000; iter++) {
        final len = rand(20);
        final sb = StringBuffer();
        for (var i = 0; i < len; i++) {
          sb.write(alpha[rand(alpha.length)]);
        }
        final subj = sb.toString();
        expect(_m(r'\w+@\w+', subj), ref(subj), reason: 'subj=«$subj»');
      }
    });
  });
}
