/// Regression tests for the Op.starGreedy fast loop (greedy `*`/`+` over a
/// single char class / ctype / anychar): it must be byte-identical to the old
/// PUSH/body/JUMP loop, including backtracking (giving back one char at a time)
/// and zero-width (`*` matching nothing). The oracle + fuzzer cover this broadly;
/// these pin the specific give-back behaviors the optimization reorganizes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oniguruma_dart/src/encoding/encodings.dart';
import 'package:oniguruma_dart/src/region.dart';
import 'package:oniguruma_dart/src/regex.dart';
import 'package:oniguruma_dart/src/syntax.dart';
import 'package:oniguruma_dart/src/exec/search.dart';
import 'package:test/test.dart';

/// (whole-match start, end) of the first match of [pat] in [subj], or null.
(int, int)? _m(String pat, String subj) {
  final pb = Uint8List.fromList(utf8.encode(pat));
  final r = onigNew(pb, pb.length, utf8Encoding, onigSyntaxOniguruma, 0);
  final sb = Uint8List.fromList(utf8.encode(subj));
  final region = OnigRegion();
  final rc = onigSearch(r, sb, sb.length, 0, sb.length, region);
  if (rc < 0) return null;
  return (region.beg[0], region.end[0]);
}

void main() {
  group('greedy give-back (single-char loop must backtrack one char at a time)', () {
    test('[a-z]+ gives back so a following literal in-class can match', () {
      // greedy takes "aaar", needs 'r', backs off to "aaa", 'r' matches -> [0,4]
      expect(_m(r'[a-z]+r', 'aaar'), (0, 4));
    });
    test('\\w+ gives back for a following \\w literal', () {
      expect(_m(r'(\w+)x', 'aaxbb x'), isNotNull);
      expect(_m(r'\w+x', 'aaax'), (0, 4));
    });
    test('.* gives back to let the trailing literal match', () {
      expect(_m(r'.*b', 'abcbxb'), (0, 6));
      expect(_m(r'.*b', 'zzz'), isNull);
    });
    test('[0-9]+ then digit', () {
      expect(_m(r'[0-9]+5', '12345'), (0, 5));
    });
    test('negated class give-back', () {
      expect(_m(r'[^0-9]+ ', 'abc def'), (0, 4));
    });
  });

  group('zero-width and lower bounds', () {
    test('[a-z]* matches empty at a non-matching position', () {
      expect(_m(r'[a-z]*', '123'), (0, 0));
    });
    test('a* at start', () {
      expect(_m(r'a*', 'aaab'), (0, 3));
    });
    test('[a-z]{2,} needs the mandatory copies', () {
      expect(_m(r'[a-z]{2,}', 'a'), isNull);
      expect(_m(r'[a-z]{2,}', 'abcd'), (0, 4));
    });
  });

  group('multibyte give-back (UTF-8)', () {
    test('\\w+ over unicode word chars backs off correctly', () {
      // é(2 bytes)×3 then space; \w+ then a required 'x' fails -> gives back
      expect(_m(r'\w+é', 'aébéré'), isNotNull);
    });
    test('.* over multibyte then ascii literal', () {
      expect(_m(r'.*b', '東京b漢b'), isNotNull);
    });
  });

  group('longest-first ordering preserved', () {
    test('greedy prefers the longest run then backtracks minimally', () {
      // (a+)(a+) : first group greedy, gives back exactly one for the second
      final pb = Uint8List.fromList(utf8.encode(r'(a+)(a+)'));
      final r = onigNew(pb, pb.length, utf8Encoding, onigSyntaxOniguruma, 0);
      final sb = Uint8List.fromList(utf8.encode('aaaa'));
      final region = OnigRegion();
      expect(onigSearch(r, sb, sb.length, 0, sb.length, region),
          greaterThanOrEqualTo(0));
      expect([region.beg[1], region.end[1]], [0, 3]); // first group: "aaa"
      expect([region.beg[2], region.end[2]], [3, 4]); // second: "a"
    });
  });
}
