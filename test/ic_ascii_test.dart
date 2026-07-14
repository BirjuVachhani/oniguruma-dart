/// Regression tests for the ASCII fast path in the ignore-case string op
/// (`executor.dart` `Op.strN` flag==2): an ASCII subject byte is folded via a
/// table built from `enc.caseFoldRep` instead of the virtual decode/fold/length
/// chain. The critical safety cases are ASCII pattern chars whose fold class
/// includes NON-ASCII members (`s`↔`ſ`, `k`↔Kelvin U+212A) — those subject
/// chars are multibyte, so they must still take the virtual path and match.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_dart/src/encoding/encodings.dart';
import 'package:oniguruma_dart/src/region.dart';
import 'package:oniguruma_dart/src/regex.dart';
import 'package:oniguruma_dart/src/syntax.dart';
import 'package:oniguruma_dart/src/exec/search.dart';
import 'package:test/test.dart';

(int, int)? _m(String pat, String subj) {
  final pb = Uint8List.fromList(utf8.encode(pat));
  final r = onigNew(pb, pb.length, utf8Encoding, onigSyntaxOniguruma, 0);
  final sb = Uint8List.fromList(utf8.encode(subj));
  final region = OnigRegion();
  final rc = onigSearch(r, sb, sb.length, 0, sb.length, region);
  return rc < 0 ? null : (region.beg[0], region.end[0]);
}

void main() {
  group('ASCII ignore-case (fast path)', () {
    test('all-caps subject', () => expect(_m(r'(?i)lorem', 'LOREM'), (0, 5)));
    test('mixed-case subject', () => expect(_m(r'(?i)lorem', 'LoReM'), (0, 5)));
    test('lowercase subject', () => expect(_m(r'(?i)lorem', 'lorem'), (0, 5)));
    test('mid-string', () => expect(_m(r'(?i)abc', 'xxABCyy'), (2, 5)));
    test(
      'near-miss does not match',
      () => expect(_m(r'(?i)lorem', 'loren'), isNull),
    );
    test(
      'digits/underscore unaffected',
      () => expect(_m(r'(?i)a1_b', 'A1_B'), (0, 4)),
    );
  });

  group('ASCII pattern char with NON-ASCII fold member (virtual fallback)', () {
    test(r'(?i)s matches ſ (U+017F long s)', () {
      // ſ is 2 UTF-8 bytes; must still match case-insensitive 's'.
      expect(_m(r'(?i)s', 'ſ'), (0, 2));
    });
    test(r'(?i)k matches U+212A Kelvin sign', () {
      final kelvin = String.fromCharCode(0x212a); // 3 UTF-8 bytes, folds to k
      expect(_m(r'(?i)k', kelvin), (0, 3));
    });
    test(r'(?i)st matches ſt', () {
      expect(_m(r'(?i)st', 'ſt'), (0, 3)); // ſ(2) + t(1)
    });
    test('ascii pattern still matches its ascii form too', () {
      expect(_m(r'(?i)s', 'S'), (0, 1));
      expect(_m(r'(?i)k', 'k'), (0, 1));
    });
  });

  group('mixed ASCII + multibyte subject in one match', () {
    test(r'(?i)maße vs MAßE (ß is 2 bytes, non-fold here)', () {
      // ß has no simple single-char ASCII fold; this checks the loop threads
      // ascii and multibyte chars correctly around each other.
      expect(_m(r'(?i)maße', 'MAßE'), isNotNull);
    });
  });

  // In-process fuzz for the case-insensitive Sunday search (Optimize.strIc):
  // compare `(?i)<word>` against an independent ASCII-case-insensitive oracle
  // over thousands of random subjects. Validates the multi-byte-skip search
  // finds the exact same leftmost match as a naive scan.
  group('strIc vs independent ASCII-ci oracle (fuzz)', () {
    // ASCII-fold-only words (no char has a non-ASCII fold member).
    const words = ['lorem', 'aB', 'the', 'GO', 'help', 'net', 'do', 'random'];

    int lo(int c) => (c >= 0x41 && c <= 0x5a) ? c + 0x20 : c;
    (int, int)? ref(String needle, String subj) {
      final n = needle.length;
      for (var p = 0; p + n <= subj.length; p++) {
        var ok = true;
        for (var k = 0; k < n; k++) {
          if (lo(subj.codeUnitAt(p + k)) != lo(needle.codeUnitAt(k))) {
            ok = false;
            break;
          }
        }
        if (ok) return (p, p + n);
      }
      return null;
    }

    test('4000 random subjects', () {
      var rng = 0x5eed1234;
      int rand(int m) {
        rng = (rng * 1103515245 + 12345) & 0x7fffffff;
        return rng % m;
      }

      // ASCII-only alphabet mixing case + separators (no multibyte, so the
      // ASCII-fold search domain is exercised without fold-member complications).
      const alpha = 'abBcdEGHlmnoprtu _.';
      for (var iter = 0; iter < 4000; iter++) {
        final w = words[rand(words.length)];
        final len = rand(22);
        final sb = StringBuffer();
        for (var i = 0; i < len; i++) {
          sb.write(alpha[rand(alpha.length)]);
        }
        var subj = sb.toString();
        if (rand(2) == 0) {
          // splice in the word (random case) so matches actually happen
          final at = rand(subj.length + 1);
          final cased = StringBuffer();
          for (final cu in w.codeUnits) {
            cased.writeCharCode(
              rand(2) == 0 && cu >= 0x61 && cu <= 0x7a ? cu - 0x20 : cu,
            );
          }
          subj = subj.substring(0, at) + cased.toString() + subj.substring(at);
        }
        expect(
          _m('(?i)$w', subj),
          ref(w, subj),
          reason: 'needle=$w subj=«$subj»',
        );
      }
    });
  });
}
